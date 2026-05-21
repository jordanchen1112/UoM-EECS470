`timescale 1ns/1ps
`include "def.svh"

module RS_tb;
  parameter RS_DEPTH = 8;
  parameter DISPATCH_WIDTH = 2;
  parameter ISSUE_WIDTH = 2;
  parameter CDB_WIDTH = 2;
  parameter PHYS_REGS = 128;
  parameter OPCODE_N        = 8;
  parameter FU_NUM = 8;
  parameter XLEN = 64;

  // --- Inputs/Outputs ---
  logic clk, reset, flush;
  logic [DISPATCH_WIDTH-1:0] disp_valid_i;
  rs_entry_t [DISPATCH_WIDTH-1:0] rs_packets_i;
  logic [DISPATCH_WIDTH-1:0] disp_rs_rd_wen_i;
  logic [$clog2(DISPATCH_WIDTH+1)-1:0] free_slots_o;
  logic rs_full_o;
  logic [CDB_WIDTH-1:0] cdb_valid_i;
  logic [CDB_WIDTH-1:0][$clog2(PHYS_REGS)-1:0] cdb_tag_i;
  logic [RS_DEPTH-1:0] issue_enable_i;
  rs_entry_t [RS_DEPTH-1:0] rs_entries_o;
  logic [RS_DEPTH-1:0] rs_ready_o;
  fu_type_e fu_type_o [RS_DEPTH];

  // --- Clock ---
  always #5 clk = ~clk;

  // --- DUT ---
  RS #(
    .RS_DEPTH(RS_DEPTH),
    .DISPATCH_WIDTH(DISPATCH_WIDTH),
    .ISSUE_WIDTH(ISSUE_WIDTH),
    .CDB_WIDTH(CDB_WIDTH),
    .PHYS_REGS(PHYS_REGS),
    .FU_NUM(FU_NUM),
    .OPCODE_N(OPCODE_N),
    .XLEN(XLEN)
  ) dut (
    .clk(clk),
    .reset(reset),
    .flush(flush),
    .disp_valid_i(disp_valid_i),
    .rs_packets_i(rs_packets_i),
    .disp_rs_rd_wen_i(disp_rs_rd_wen_i),
    .free_slots_o(free_slots_o),
    .rs_full_o(rs_full_o),
    .cdb_valid_i(cdb_valid_i),
    .cdb_tag_i(cdb_tag_i),
    .issue_enable_i(issue_enable_i),
    .rs_entries_o(rs_entries_o),
    .rs_ready_o(rs_ready_o),
    .fu_type_o(fu_type_o)
  );
  // Ground truth signals
  int       correct_free_slots; // saturate at DISPATCH_WIDTH
  int       correct_real_free_slots;
  bit                                correct_full;
  logic [RS_DEPTH-1:0]               correct_ready_vec;
  logic [RS_DEPTH-1:0]               rs_ready_o;
  assign correct_free_slots          = (correct_real_free_slots > DISPATCH_WIDTH) ? DISPATCH_WIDTH : correct_real_free_slots;
  assign correct_full                = (correct_free_slots == 0);

  // Helper tasks
  task automatic reset_dut();
    reset = 1; flush = 0;
    disp_valid_i = '0; issue_enable_i = '0;
    cdb_valid_i = '0; cdb_tag_i = '0;
    disp_rs_rd_wen_i = '0;
    rs_packets_i = {default: '0};
    correct_real_free_slots = RS_DEPTH;
    correct_ready_vec = '0;

    #100; reset = 0;
    $display("[TB] Reset complete.");
  endtask

  task automatic update_ground_truth();
    correct_real_free_slots = 0;
    for (int i = 0; i < RS_DEPTH; i++)
      if (!rs_entries_o[i].valid)
        correct_real_free_slots++;
  endtask

  task automatic show_disp_grant();
    $display("disp_grant_vec = %b", dut.disp_grant_vec);
    $display("rs_empty = %b", dut.rs_empty);
    $display("disp_valid_i = %b", dut.disp_valid_i);
  endtask

  task automatic show_status();
    $display("RS Entries:");
    for (int i = 0; i < RS_DEPTH; i++) begin
      $display("Entry %0d: valid=%b, rob_idx=%0d, fu_type=%0d, dest_tag=%0d, src1_tag=%0d(%b), src2_tag=%0d(%b)", 
        i, rs_entries_o[i].valid, rs_entries_o[i].rob_idx, rs_entries_o[i].fu_type, 
        rs_entries_o[i].dest_tag, rs_entries_o[i].src1_tag, rs_entries_o[i].src1_ready,
        rs_entries_o[i].src2_tag, rs_entries_o[i].src2_ready);
    end
  endtask

  task automatic check_ready();
    for (int i = 0; i < RS_DEPTH; i++) begin
      if (rs_entries_o[i].valid && rs_entries_o[i].src1_ready && rs_entries_o[i].src2_ready) begin
          if (!rs_ready_o[i])
            $display("[MISMATCH]Should be ready but not ready at entry %0d", i);
      end
    end
  endtask

  task automatic check_rs_entry(
    input int idx,
    input int fu_type,
    input int src1_tag,
    input bit src1_ready,
    input int src2_tag,
    input bit src2_ready,
    input int dest_tag,
    input int rob_idx
  );
  if (rs_entries_o[idx].valid !== 1'b1)
    $display("[MISMATCH] Entry %0d valid mismatch (got %b)", idx, rs_entries_o[idx].valid);
  if (rs_entries_o[idx].fu_type !== fu_type)
    $display("[MISMATCH] Entry %0d fu_type exp=%0d got=%0d", idx, fu_type, rs_entries_o[idx].fu_type);
  if (rs_entries_o[idx].src1_tag !== src1_tag)
    $display("[MISMATCH] Entry %0d src1_tag exp=%0d got=%0d", idx, src1_tag, rs_entries_o[idx].src1_tag);
  if (rs_entries_o[idx].src1_ready !== src1_ready)
    $display("[MISMATCH] Entry %0d src1_ready exp=%0b got=%0b", idx, src1_ready, rs_entries_o[idx].src1_ready);
  if (rs_entries_o[idx].src2_tag !== src2_tag)
    $display("[MISMATCH] Entry %0d src2_tag exp=%0d got=%0d", idx, src2_tag, rs_entries_o[idx].src2_tag);
  if (rs_entries_o[idx].src2_ready !== src2_ready)
    $display("[MISMATCH] Entry %0d src2_ready exp=%0b got=%0b", idx, src2_ready, rs_entries_o[idx].src2_ready);
  if (rs_entries_o[idx].dest_tag !== dest_tag)
    $display("[MISMATCH] Entry %0d dest_tag exp=%0d got=%0d", idx, dest_tag, rs_entries_o[idx].dest_tag);
  if (rs_entries_o[idx].rob_idx !== rob_idx)
    $display("[MISMATCH] Entry %0d rob_idx exp=%0d got=%0d", idx, rob_idx, rs_entries_o[idx].rob_idx);
  if (free_slots_o !== correct_free_slots)
    $display("[MISMATCH] Free slots exp=%0d got=%0d", correct_free_slots, free_slots_o);
  if (rs_full_o !== correct_full)
    $display("[MISMATCH] RS full exp=%0b got=%0b", correct_full, rs_full_o);
    
  endtask

  task automatic dispatch_instr(
    input int idx, //which slots (n-way)
    input int fu_type,
    input int src1_tag,
    input bit src1_ready,
    input int src2_tag,
    input bit src2_ready,
    input int dest_tag,
    input int rob_idx
  );
    rs_packets_i[idx].valid      = 1'b1;
    rs_packets_i[idx].rob_idx    = rob_idx;
    rs_packets_i[idx].fu_type    = fu_type;
    rs_packets_i[idx].opcode     = 0;
    rs_packets_i[idx].dest_tag   = dest_tag;
    rs_packets_i[idx].src1_tag   = src1_tag;
    rs_packets_i[idx].src2_tag   = src2_tag;
    rs_packets_i[idx].src1_ready = src1_ready;
    rs_packets_i[idx].src2_ready = src2_ready;
    disp_valid_i[idx] = 1'b1;

  endtask

  // Test Sequence
  initial begin
    clk = 0;
    reset_dut();

    // -------------------------------------------------------
    // Phase 1: Single Dispatch
    // -------------------------------------------------------
    $display("=== Phase 1: Single Dispatch ===");
    @(negedge clk);
    dispatch_instr(0, 0, 2, 0, 3, 1, 5, 0);
    @(posedge clk);
    show_disp_grant(); // #10 之前才會是正確的數值 (因為是comb所以#10之後會變新的數值)
    #1;
    update_ground_truth();
    show_status();
    check_rs_entry(0, 0, 2, 0, 3, 1, 5, 0);
    disp_valid_i = '0;

    // -------------------------------------------------------
    // Phase 2: Dual Dispatch (multi-slot)
    // -------------------------------------------------------
    $display("=== Phase 2: Dual Dispatch ===");
    reset_dut();
    #20;

    @(negedge clk);
    dispatch_instr(0, 2, 10, 1, 11, 1, 20, 1);
    dispatch_instr(1, 3, 12, 0, 13, 0, 21, 2);
    @(posedge clk);
    disp_valid_i = '0;
    #1;
    update_ground_truth();
    show_status();
    check_rs_entry(0, 2, 10, 1, 11, 1, 20, 1);
    check_rs_entry(1, 3, 12, 0, 13, 0, 21, 2);

    // -------------------------------------------------------
    // Phase 3: CDB Wakeup 
    // -------------------------------------------------------
    $display("=== Phase 3: CDB Wakeup ===");
    @(negedge clk);
    cdb_valid_i[0] = 1;
    cdb_tag_i[0]   = 12; // Wakeup src1_tag of entry 1
    cdb_valid_i[1] = 1;
    cdb_tag_i[1]   = 13; // Wakeup src1_tag of entry 1
    @(posedge clk);
    cdb_valid_i = '0;
    #1;
    update_ground_truth();
    show_status();
    check_rs_entry(1, 3, 12, 1, 13, 1, 21, 2);
    check_ready();

  // -------------------------------------------------------
  // Phase 4: Issue ready entries
  // -------------------------------------------------------
  $display("=== Phase 4: Issue ready entries ===");
  @(negedge clk);
  issue_enable_i[0] = 1;  // issue entry 0
  issue_enable_i[1] = 1;  // issue entry 1
  @(posedge clk);
  issue_enable_i = '0;
  #1;
  update_ground_truth();
  show_status();

  // -------------------------------------------------------
  // Phase 5: Flush RS
  // -------------------------------------------------------
  $display("=== Phase 5: Flush RS ===");
  flush = 1;
  @(posedge clk);
  flush = 0;
  #1;
  update_ground_truth();
  show_status();

  // -------------------------------------------------------
  // Phase 6: Refill after flush
  // -------------------------------------------------------
  $display("=== Phase 6: Refill after flush ===");
  @(negedge clk);
  dispatch_instr(0, 4, 20, 1, 21, 1, 30, 3);
  dispatch_instr(1, 5, 21, 1, 22, 1, 31, 4);
  @(posedge clk);
  disp_valid_i = '0;
  #1;
  update_ground_truth();
  show_status();
  check_rs_entry(0, 4, 20, 1, 21, 1, 30, 3);
  check_rs_entry(1, 5, 21, 1, 22, 1, 31, 4);

  $display("=== RS Test Complete ===");
  $finish;
  
  end
endmodule
