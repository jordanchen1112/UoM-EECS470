`timescale 1ns/1ps
// `include "fu_if.svh"
// `include "fu.sv"
`include "../verilog/def.svh"

// parameter int XLEN        = 64;
// parameter int PHYS_REGS   = 128;
parameter int ROB_DEPTH   = 64;
parameter int ALU_COUNT   = 2;
parameter int MUL_COUNT   = 1;
parameter int LOAD_COUNT  = 1;
parameter int BR_COUNT    = 1;
parameter int TOTAL_FU    = ALU_COUNT + MUL_COUNT + LOAD_COUNT + BR_COUNT;

module fu_test;

  
  fu_req_t alu_req   [0:ALU_COUNT-1];
  fu_req_t mul_req   [0:MUL_COUNT-1];
  fu_req_t load_req  [0:LOAD_COUNT-1];
  fu_req_t br_req    [0:BR_COUNT-1];

  logic alu_ready_o  [0:ALU_COUNT-1];
  logic mul_ready_o  [0:MUL_COUNT-1];
  logic load_ready_o [0:LOAD_COUNT-1];
  logic br_ready_o   [0:BR_COUNT-1];

  fu_resp_t fu_resp_bus [0:TOTAL_FU-1];

  logic [TOTAL_FU-1:0] fu_valid_o;
  logic [TOTAL_FU-1:0][XLEN-1:0] fu_value_o;
  logic [TOTAL_FU-1:0][$clog2(PHYS_REGS)-1:0] fu_dest_prf_o;
  logic [TOTAL_FU-1:0][$clog2(ROB_DEPTH)-1:0] fu_rob_idx_o;
  logic [TOTAL_FU-1:0] fu_exception_o;
  logic [TOTAL_FU-1:0] fu_mispred_o;

  // -------------------------------------------------------------
  // DUT instantiation
  // -------------------------------------------------------------
  fu #(
    .XLEN(XLEN),
    .PHYS_REGS(PHYS_REGS),
    .ROB_DEPTH(ROB_DEPTH),
    .ALU_COUNT(ALU_COUNT),
    .MUL_COUNT(MUL_COUNT),
    .LOAD_COUNT(LOAD_COUNT),
    .BR_COUNT(BR_COUNT)
  ) dut (
    .alu_req(alu_req),
    .mul_req(mul_req),
    .load_req(load_req),
    .br_req(br_req),
    .alu_ready_o(alu_ready_o),
    .mul_ready_o(mul_ready_o),
    .load_ready_o(load_ready_o),
    .br_ready_o(br_ready_o),
    .fu_resp_bus(fu_resp_bus),
    .fu_valid_o(fu_valid_o),
    .fu_value_o(fu_value_o),
    .fu_dest_prf_o(fu_dest_prf_o),
    .fu_rob_idx_o(fu_rob_idx_o),
    .fu_exception_o(fu_exception_o),
    .fu_mispred_o(fu_mispred_o)
  );

  // -------------------------------------------------------------
  // Clock / Time
  // -------------------------------------------------------------
  logic clk;
  initial begin
    clk = 0;
    forever #5 clk = ~clk; // 10ns period
  end

  // -------------------------------------------------------------
  // Task: initialize req bus
  // -------------------------------------------------------------
  task clear_all_reqs;
    for (int i = 0; i < ALU_COUNT; i++) alu_req[i]  = '0;
    for (int i = 0; i < MUL_COUNT; i++) mul_req[i]  = '0;
    for (int i = 0; i < LOAD_COUNT; i++) load_req[i] = '0;
    for (int i = 0; i < BR_COUNT; i++) br_req[i]    = '0;
  endtask

  // -------------------------------------------------------------
  // Monitor (show results like CDB broadcast)
  // -------------------------------------------------------------
  always @(posedge clk) begin
    for (int k = 0; k < TOTAL_FU; k++) begin
      if (fu_valid_o[k]) begin
        $display("[T=%0t] FU[%0d] ROB=%0d → PRF[%0d]=0x%016h",
                 $time, k, fu_rob_idx_o[k], fu_dest_prf_o[k], fu_value_o[k]);
      end
    end
  end

  // -------------------------------------------------------------
  // Stimulus
  // -------------------------------------------------------------
  initial begin
    clear_all_reqs();
    #10;

    // ---------------- Test 1 ----------------
    $display("\n===== Test 1: Simple ALU ADD =====");
    alu_req[0].valid       = 1;
    alu_req[0].src1_value  = 10;
    alu_req[0].src2_value  = 32;
    alu_req[0].opcode      = 4'd0; // ADD
    alu_req[0].dest_prf    = 5;
    alu_req[0].rob_idx     = 10;
    #10;
    clear_all_reqs();

    // ---------------- Test 2 ----------------
    $display("\n===== Test 2: Multi-ALU parallel =====");
    alu_req[0].valid       = 1;
    alu_req[0].src1_value  = 20;
    alu_req[0].src2_value  = 4;
    alu_req[0].opcode      = 4'd1; // SUB
    alu_req[0].dest_prf    = 1;
    alu_req[0].rob_idx     = 11;

    alu_req[1].valid       = 1;
    alu_req[1].src1_value  = 3;
    alu_req[1].src2_value  = 7;
    alu_req[1].opcode      = 4'd0; // ADD
    alu_req[1].dest_prf    = 2;
    alu_req[1].rob_idx     = 12;
    #10;
    clear_all_reqs();

    // ---------------- Test 3 ----------------
    $display("\n===== Test 3: Multiply =====");
    mul_req[0].valid      = 1;
    mul_req[0].src1_value = 5;
    mul_req[0].src2_value = 9;
    mul_req[0].opcode     = 0;
    mul_req[0].dest_prf   = 8;
    mul_req[0].rob_idx    = 20;
    #10;
    clear_all_reqs();

    // ---------------- Test 4 ----------------
    $display("\n===== Test 4: Load Address =====");
    load_req[0].valid      = 1;
    load_req[0].src1_value = 64'h1000;
    load_req[0].src2_value = 64'h0000000000000008; // imm=8
    load_req[0].opcode     = 0;
    load_req[0].dest_prf   = 9;
    load_req[0].rob_idx    = 21;
    #10;
    clear_all_reqs();

    // ---------------- Test 5 ----------------
    $display("\n===== Test 5: Branch compare =====");
    br_req[0].valid       = 1;
    br_req[0].src1_value  = 64'd5;
    br_req[0].src2_value  = 64'd7;
    br_req[0].opcode      = 3'b100; // BLT
    br_req[0].dest_prf    = 10;
    br_req[0].rob_idx     = 22;
    #10;
    clear_all_reqs();

    // ---------------- Test 6 ----------------
    $display("\n===== Test 6: 4 ALUs in parallel (ADD + SUB + XOR + OR) =====");
    alu_req[0] = '{valid:1, src1_value:64'd2, src2_value:64'd3, opcode:4'd0, dest_prf:11, rob_idx:30}; // ADD
    alu_req[1] = '{valid:1, src1_value:64'd10, src2_value:64'd4, opcode:4'd1, dest_prf:12, rob_idx:31}; // SUB
    alu_req[2] = '{valid:1, src1_value:64'hF0, src2_value:64'h0F, opcode:4'd6, dest_prf:13, rob_idx:32}; // XOR
    alu_req[3] = '{valid:1, src1_value:64'hAA, src2_value:64'h55, opcode:4'd5, dest_prf:14, rob_idx:33}; // OR
    #10;
    clear_all_reqs();

    // ---------------- Test 7 ----------------
    $display("\n===== Test 7: Mixed FU (ALU + MUL + LOAD + BRANCH) =====");
    alu_req[0] = '{valid:1, src1_value:64'd8, src2_value:64'd9, opcode:4'd0, dest_prf:15, rob_idx:40};
    mul_req[0] = '{valid:1, src1_value:64'd6, src2_value:64'd7, opcode:4'd0, dest_prf:16, rob_idx:41};
    load_req[0] = '{valid:1, src1_value:64'h2000, src2_value:64'd4, opcode:4'd0, dest_prf:17, rob_idx:42};
    br_req[0] = '{valid:1, src1_value:64'd10, src2_value:64'd10, opcode:3'b000, dest_prf:18, rob_idx:43}; // BEQ
    #10;
    clear_all_reqs();

    // ---------------- Test 8 ----------------
    $display("\n===== Test 8: 8-way stress (ALU x4 + MUL x2 + LOAD + BRANCH) =====");
    // 4 ALUs
    for (int i = 0; i < ALU_COUNT; i++) begin
      alu_req[i].valid       = 1;
      alu_req[i].src1_value  = i + 5;
      alu_req[i].src2_value  = 100 + i;
      alu_req[i].opcode      = 4'd0; // ADD
      alu_req[i].dest_prf    = 20 + i;
      alu_req[i].rob_idx     = 50 + i;
    end
    // 2 MULs
    for (int i = 0; i < MUL_COUNT; i++) begin
      mul_req[i].valid       = 1;
      mul_req[i].src1_value  = i + 3;
      mul_req[i].src2_value  = 5;
      mul_req[i].opcode      = 4'd0;
      mul_req[i].dest_prf    = 25 + i;
      mul_req[i].rob_idx     = 55 + i;
    end
    // 1 LOAD
    load_req[0] = '{valid:1, src1_value:64'h4000, src2_value:64'd8, opcode:4'd0, dest_prf:27, rob_idx:57};
    // 1 BRANCH
    br_req[0] = '{valid:1, src1_value:64'd2, src2_value:64'd3, opcode:3'b100, dest_prf:28, rob_idx:58};
    #10;
    clear_all_reqs();

    // ---------------- Done ----------------
    #10;
    $display("\n@@@ All FU N-way tests finished @@@\n");
    #20 $finish;
  end


endmodule
