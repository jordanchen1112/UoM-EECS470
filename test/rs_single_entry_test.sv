`timescale 1ns/1ps
`include "def.svh"

module rs_single_entry_tb;

  // ------------------------------------------------------------------------
  // Parameters
  // ------------------------------------------------------------------------
  localparam PHYS_REGS = 16;
  localparam CDB_WIDTH = 2;
  localparam FU_NUM    = 4;

  // ------------------------------------------------------------------------
  // DUT I/O
  // ------------------------------------------------------------------------
  logic clk, reset, flush;
  logic disp_enable_i;
  rs_entry_t rs_packets_i;
  logic empty_o;
  logic issue_i;
  rs_entry_t rs_single_entry_o;
  logic [$clog2(FU_NUM)-1:0] fu_type_o;
  logic ready_o;
  logic [CDB_WIDTH-1:0] cdb_valid_single_i;
  logic [CDB_WIDTH-1:0][$clog2(PHYS_REGS)-1:0] cdb_tag_single_i;

  // ------------------------------------------------------------------------
  // DUT instance
  // ------------------------------------------------------------------------
  rs_single_entry #(
    .PHYS_REGS(PHYS_REGS),
    .CDB_WIDTH(CDB_WIDTH),
    .FU_NUM(FU_NUM)
  ) dut (
    .clk(clk),
    .reset(reset),
    .flush(flush),
    .disp_enable_i(disp_enable_i),
    .rs_packets_i(rs_packets_i),
    .empty_o(empty_o),
    .issue_i(issue_i),
    .rs_single_entry_o(rs_single_entry_o),
    .fu_type_o(fu_type_o),
    .ready_o(ready_o),
    .cdb_valid_single_i(cdb_valid_single_i),
    .cdb_tag_single_i(cdb_tag_single_i)
  );

  // ------------------------------------------------------------------------
  // Clock and reset
  // ------------------------------------------------------------------------
  always #5 clk = ~clk;

  task automatic reset_dut();
    reset = 1; flush = 0;
    disp_enable_i = 0; issue_i = 0;
    cdb_valid_single_i = '0; cdb_tag_single_i = '0;
    #20;
    reset = 0;
  endtask

  // ------------------------------------------------------------------------
  // Utility: display entry contents each cycle
  // ------------------------------------------------------------------------
  task automatic show_state(string tag);
    $display("[%0t] %s | empty=%b ready=%b fu=%0d src1=%0d(%0b) src2=%0d(%0b) dest=%0d valid=%b",
             $time, tag,
             empty_o, ready_o, fu_type_o,
             rs_single_entry_o.src1_tag, rs_single_entry_o.src1_ready,
             rs_single_entry_o.src2_tag, rs_single_entry_o.src2_ready,
             rs_single_entry_o.dest_tag,
             dut.rs_entry_next.valid);
  endtask

  // ------------------------------------------------------------------------
  // Test sequence
  // ------------------------------------------------------------------------
  initial begin
    clk = 0;
    reset_dut();

    $display("=== rs_single_entry Test Start ===");

    // ----------------------------------------------------------
    // Phase 1: Dispatch instruction into empty slot
    // ----------------------------------------------------------
    @(negedge clk);

    rs_packets_i.valid      = 1;
    rs_packets_i.rob_idx    = 1;
    rs_packets_i.imm        = 32'h1234;
    rs_packets_i.fu_type    = 2;
    rs_packets_i.opcode     = 3;
    rs_packets_i.dest_tag   = 8;
    rs_packets_i.src1_tag   = 5;
    rs_packets_i.src2_tag   = 6;
    rs_packets_i.src1_ready = 0;
    rs_packets_i.src2_ready = 0;

    disp_enable_i = 1;
    @(posedge clk);
    #1; //一定要等一下訊號穩定
    disp_enable_i = 0;
    show_state("After dispatch");

    // ----------------------------------------------------------
    // Phase 2: Wake up one operand via CDB
    // ----------------------------------------------------------
    @(posedge clk);
    cdb_valid_single_i[0] = 1;
    cdb_tag_single_i[0]   = 5;  // src1 ready
    @(posedge clk);
    #1;
    cdb_valid_single_i = '0;
    show_state("After CDB src1 wakeup");

    // ----------------------------------------------------------
    // Phase 3: Wake up second operand
    // ----------------------------------------------------------
    @(posedge clk);
    cdb_valid_single_i[0] = 1;
    cdb_tag_single_i[0]   = 6;  // src2 ready
    @(posedge clk);
    #1;
    cdb_valid_single_i = '0;
    show_state("After CDB src2 wakeup");

    // ----------------------------------------------------------
    // Phase 4: Issue instruction (both ready)
    // ----------------------------------------------------------
    issue_i = 1;
    @(posedge clk);
    #1;
    issue_i = 0;
    show_state("After issue (should be empty)");

    // ----------------------------------------------------------
    // Phase 5: Flush test
    // ----------------------------------------------------------
    @(posedge clk);
    disp_enable_i = 1;
    @(posedge clk);
    flush = 1;
    @(posedge clk);
    flush = 0;
    #1;
    show_state("After flush");

    $display("=== rs_single_entry Test Complete ===");
    $finish;
  end
endmodule
