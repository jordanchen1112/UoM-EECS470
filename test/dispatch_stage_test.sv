`timescale 1ns/1ps
`include "def.svh"

module dispatch_stage_tb;

  // -------------------------------------------------------
  // Parameters
  // -------------------------------------------------------
  localparam int FETCH_WIDTH    = 2;
  localparam int DISPATCH_WIDTH = 2;
  localparam int PHYS_REGS      = 128;
  localparam int ARCH_REGS      = 64;
  localparam int DEPTH          = 64;
  localparam int ADDR_WIDTH     = 32;

  // -------------------------------------------------------
  // Clock / Reset
  // -------------------------------------------------------
  logic clock;
  logic reset;
  always #5 clock = ~clock;  // 10ns period

  // -------------------------------------------------------
  // DUT I/O signals
  // -------------------------------------------------------
  // Free List
  IF_ID_PACKET [FETCH_WIDTH-1:0] if_packet_i;

  logic [$clog2(DISPATCH_WIDTH+1)-1:0] free_regs_i;
  logic empty_i;
  logic [DISPATCH_WIDTH-1:0][$clog2(PHYS_REGS)-1:0] new_reg_i;
  logic [DISPATCH_WIDTH-1:0] alloc_req_o;

  // Map Table
  logic [DISPATCH_WIDTH-1:0] src1_ready_i;
  logic [DISPATCH_WIDTH-1:0] src2_ready_i;
  logic [DISPATCH_WIDTH-1:0][$clog2(PHYS_REGS)-1:0] src1_phys_i;
  logic [DISPATCH_WIDTH-1:0][$clog2(PHYS_REGS)-1:0] src2_phys_i;
  logic [DISPATCH_WIDTH-1:0][$clog2(PHYS_REGS)-1:0] dest_reg_old_i;

  logic [DISPATCH_WIDTH-1:0] rename_valid_o;
  logic [DISPATCH_WIDTH-1:0][$clog2(ARCH_REGS)-1:0] dest_arch_o;
  logic [DISPATCH_WIDTH-1:0][$clog2(ARCH_REGS)-1:0] src1_arch_o;
  logic [DISPATCH_WIDTH-1:0][$clog2(ARCH_REGS)-1:0] src2_arch_o;

  // RS
  logic [$clog2(DISPATCH_WIDTH+1)-1:0] free_rs_slots_i;
  logic rs_full_i;
  logic [DISPATCH_WIDTH-1:0] disp_rs_valid_o;
  logic [DISPATCH_WIDTH-1:0] disp_rs_rd_wen_o;
  rs_entry_t [DISPATCH_WIDTH-1:0] rs_packets_o;

  // ROB
  logic [$clog2(DISPATCH_WIDTH+1)-1:0] free_rob_slots_i;
  logic [DISPATCH_WIDTH-1:0] disp_rob_ready_i; // unused for now
  logic [DISPATCH_WIDTH-1:0][$clog2(DEPTH)-1:0] disp_rob_idx_i;

  logic [DISPATCH_WIDTH-1:0] disp_rob_valid_o;
  logic [DISPATCH_WIDTH-1:0] disp_rob_rd_wen_o;
  logic [DISPATCH_WIDTH-1:0][$clog2(ARCH_REGS)-1:0] disp_rd_arch_o;
  logic [DISPATCH_WIDTH-1:0][$clog2(PHYS_REGS)-1:0] disp_rd_new_prf_o;
  logic [DISPATCH_WIDTH-1:0][$clog2(PHYS_REGS)-1:0] disp_rd_old_prf_o;

  DISP_PACKET [DISPATCH_WIDTH-1:0] disp_packet_o;
  logic stall;

  // -------------------------------------------------------
  // Instantiate DUT
  // -------------------------------------------------------
  dispatch_stage #(
    .FETCH_WIDTH(FETCH_WIDTH),
    .DISPATCH_WIDTH(DISPATCH_WIDTH),
    .PHYS_REGS(PHYS_REGS),
    .ARCH_REGS(ARCH_REGS),
    .DEPTH(DEPTH),
    .ADDR_WIDTH(ADDR_WIDTH)
  ) dut (
    .clock(clock),
    .reset(reset),

    .if_packet_i(if_packet_i),
    .free_regs_i(free_regs_i),
    .empty_i(empty_i),
    .new_reg_i(new_reg_i),
    .alloc_req_o(alloc_req_o),

    .src1_ready_i(src1_ready_i),
    .src2_ready_i(src2_ready_i),
    .src1_phys_i(src1_phys_i),
    .src2_phys_i(src2_phys_i),
    .dest_reg_old_i(dest_reg_old_i),

    .rename_valid_o(rename_valid_o),
    .dest_arch_o(dest_arch_o),
    .src1_arch_o(src1_arch_o),
    .src2_arch_o(src2_arch_o),

    .free_rs_slots_i(free_rs_slots_i),
    .rs_full_i(rs_full_i),

    .disp_rs_valid_o(disp_rs_valid_o),
    .disp_rs_rd_wen_o(disp_rs_rd_wen_o),
    .rs_packets_o(rs_packets_o),

    .free_rob_slots_i(free_rob_slots_i),
    .disp_rob_ready_i(disp_rob_ready_i),
    .disp_rob_idx_i(disp_rob_idx_i),

    .disp_rob_valid_o(disp_rob_valid_o),
    .disp_rob_rd_wen_o(disp_rob_rd_wen_o),
    .disp_rd_arch_o(disp_rd_arch_o),
    .disp_rd_new_prf_o(disp_rd_new_prf_o),
    .disp_rd_old_prf_o(disp_rd_old_prf_o),

    .disp_packet_o(disp_packet_o),
    .stall(stall)
  );

  // -------------------------------------------------------
  // Monitors
  // -------------------------------------------------------
  task print_outputs(string tag);
    $display("[%0t] %s", $time, tag);

    for (int i = 0; i < DISPATCH_WIDTH; i++) begin
      $display(
        "  IN[%0d]: free_regs=%0d empty=%b new_reg=%0d | Map: s1_ready=%0b s2_ready=%0b s1_phys=%0d s2_phys=%0d dest_old=%0d | RS: free_rs=%0d rs_full=%0b | ROB: free_rob=%0d rob_idx=%0d",
        i, free_regs_i, empty_i, new_reg_i[i],
        src1_ready_i[i], src2_ready_i[i], src1_phys_i[i], src2_phys_i[i], dest_reg_old_i[i],
        free_rs_slots_i, rs_full_i, free_rob_slots_i, disp_rob_idx_i[i]
      );
    end

    for (int i = 0; i < DISPATCH_WIDTH; i++) begin
      $display(
        "  OUT[%0d]: alloc_req=%0b | Map: valid=%0b rd_arch=%0d r1_arch=%0d r2_arch=%0d | RS: valid=%0b rd_wen=%0b | ROB: valid=%0b rd_wen=%0b rd_arch=%0d T_new=%0d T_old=%0d",
        i, alloc_req_o[i],
        rename_valid_o[i], dest_arch_o[i], src1_arch_o[i], src2_arch_o[i],
        disp_rs_valid_o[i], disp_rs_rd_wen_o[i],
        disp_rob_valid_o[i], disp_rob_rd_wen_o[i], disp_rd_arch_o[i], disp_rd_new_prf_o[i], disp_rd_old_prf_o[i]
      );
      //$display("if_packet_i[%0d].inst.r.rd =%0d, if_packet_i[%0d].inst.r.r1 =%0d, if_packet_i[%0d].inst.r.r2 =%0d", i, if_packet_i[i].inst.r.rd,  i, if_packet_i[i].inst.r.rs1, i, if_packet_i[i].inst.r.rs2);
    end

    $display("  stall=%0b\n", stall);
  endtask

  // -------------------------------------------------------
  // Test sequence (ground truth case)
  // -------------------------------------------------------
  initial begin
    $dumpfile("dispatch_stage_tb.vcd");
    $dumpvars(0, dispatch_stage_tb);

    clock = 0;
    reset = 1;

    // Clear inputs
    for (int i = 0; i < FETCH_WIDTH; i++) begin
      if_packet_i[i] = '{default: '0};
    end
    free_regs_i      = '0;
    empty_i          = 0;
    new_reg_i        = '{default: '0};

    src1_ready_i     = '0;
    src2_ready_i     = '0;
    src1_phys_i      = '{default: '0};
    src2_phys_i      = '{default: '0};
    dest_reg_old_i   = '{default: '0};

    free_rs_slots_i  = '0;
    rs_full_i        = 0;

    free_rob_slots_i = '0;
    disp_rob_ready_i = '0;
    disp_rob_idx_i   = '{default: '0};

    #20; reset = 0;
    #10;

    // Case 1: Normal dispatch of 2 instructions
    for (int i = 0; i < FETCH_WIDTH; i++) begin
      if_packet_i[i].valid = 1'b1;
      if_packet_i[i].PC    = 32'h1000 + i;
    end

    if_packet_i[0].inst = 32'h00B300B3; // ADD x1, x6, x11
    if_packet_i[1].inst = 32'h00552823; // SW x5, 8(x10)

    free_regs_i = 2;      // example: two physical regs available
    empty_i     = 0;
    new_reg_i[0] = 7'd31;
    new_reg_i[1] = 7'd99;

    src1_ready_i = 2'b11;
    src2_ready_i = 2'b11;
    src1_phys_i[0] = 7'd11; src1_phys_i[1] = 7'd22;
    src2_phys_i[0] = 7'd33; src2_phys_i[1] = 7'd44;
    dest_reg_old_i[0] = 7'd55; dest_reg_old_i[1] = 7'd66;

    free_rs_slots_i = 2;
    rs_full_i = 0;

    free_rob_slots_i = 2;
    disp_rob_idx_i[0] = 6'd10; disp_rob_idx_i[1] = 6'd20;

    #10;
    print_outputs("Normal dispatch (2 instructions)");


    // -------------------------------
    // Case 2: Stall due to no free registers
    // -------------------------------
    for (int i = 0; i < FETCH_WIDTH; i++) begin
      if_packet_i[i].valid = 1'b1;
      if_packet_i[i].PC    = 32'h2000 + i;
    end

    // Two instructions: ADD and SW again
    if_packet_i[0].inst = 32'h00B300B3; // ADD x1, x6, x11
    if_packet_i[1].inst = 32'h00552823; // SW x5, 8(x10)

    // *** Force stall condition ***
    free_regs_i = 0;      // no physical registers available
    empty_i     = 1;
    new_reg_i   = '{default:'1}; // irrelevant, since no free regs

    src1_ready_i = 2'b11;
    src2_ready_i = 2'b11;
    src1_phys_i[0] = 7'd11; src1_phys_i[1] = 7'd22;
    src2_phys_i[0] = 7'd33; src2_phys_i[1] = 7'd44;
    dest_reg_old_i[0] = 7'd55; dest_reg_old_i[1] = 7'd66;

    free_rs_slots_i = 2;
    rs_full_i = 0;

    free_rob_slots_i = 2;
    disp_rob_idx_i[0] = 6'd30; disp_rob_idx_i[1] = 6'd40;

    #10;
    print_outputs("Stall case: no free registers");

    // -------------------------------
    // Case 3: Stall due to limited ROB slots (n=1)
    // -------------------------------
    for (int i = 0; i < FETCH_WIDTH; i++) begin
      if_packet_i[i].valid = 1'b1;
      if_packet_i[i].PC    = 32'h3000 + i;
    end

    // Two instructions: ADD and SW again
    if_packet_i[0].inst = 32'h40A60733; // SUB x14, x12, x10
    if_packet_i[1].inst = 32'h02F3A023; // SW x15, 16(x7)

    // Free list and RS have plenty of space
    free_regs_i     = 2;      
    empty_i         = 0;
    new_reg_i[0]    = 7'd66;
    new_reg_i[1]    = 7'd87;

    src1_ready_i    = 2'b11;
    src2_ready_i    = 2'b11;
    src1_phys_i[0]  = 7'd15; src1_phys_i[1] = 7'd25;
    src2_phys_i[0]  = 7'd35; src2_phys_i[1] = 7'd45;
    dest_reg_old_i[0] = 7'd88; dest_reg_old_i[1] = 7'd89;

    free_rs_slots_i = 2;
    rs_full_i       = 0;

    // *** Force stall condition: only 1 ROB slot free ***
    free_rob_slots_i = 1;
    disp_rob_idx_i[0] = 6'd13;
    disp_rob_idx_i[1] = 6'd23;

    #10;
    print_outputs("Stall case: only 1 ROB slot available");

    #10;
    $finish;
  end

endmodule
