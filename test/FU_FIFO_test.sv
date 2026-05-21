`timescale 1ns/1ps
`include "def.svh"

module fu_fifo_tb;

    localparam int ISSUE_WIDTH = 2;
    localparam int FU_NUM      = 6;
    localparam int FIFO_DEPTH  = 4;
    localparam int XLEN        = 64;
    localparam int CNT_BITS    = $clog2(FIFO_DEPTH+1);

    // Clock / reset
    logic clk, reset;

    // DUT I/O
    logic          [FU_NUM-1:0]       fu_fifo_wr_en;
    issue_packet_t [FU_NUM-1:0]       fu_fifo_wr_pkt;
    logic          [FU_NUM-1:0]       fu_fifo_full;
    logic          [CNT_BITS-1:0]     fu_free_slots [FU_NUM];
    logic          [FU_NUM-1:0]       fu_rd_en;
    issue_packet_t [FU_NUM-1:0]       fu_issue_pkt_o;
    logic          [FU_NUM-1:0]       fu_fifo_empty;

    // Instantiate DUT
    FU_FIFO #(
        .ISSUE_WIDTH(ISSUE_WIDTH),
        .FU_NUM(FU_NUM),
        .FIFO_DEPTH(FIFO_DEPTH),
        .XLEN(XLEN)
    ) dut (
        .clk(clk),
        .reset(reset),
        .fu_fifo_wr_en(fu_fifo_wr_en),
        .fu_fifo_wr_pkt(fu_fifo_wr_pkt),
        .fu_fifo_full(fu_fifo_full),
        .fu_free_slots(fu_free_slots),
        .fu_rd_en(fu_rd_en),
        .fu_issue_pkt(fu_issue_pkt_o),
        .fu_fifo_empty(fu_fifo_empty)
    );

    // --------------------------------------------------------
    // Clock generation
    // --------------------------------------------------------
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // --------------------------------------------------------
    // Helper: create packet
    // --------------------------------------------------------
    function automatic issue_packet_t make_pkt(int id, fu_type_e fu);
        issue_packet_t p;
        p.valid     = 1;
        p.rob_idx   = id;
        p.imm       = id * 10;
        p.fu_type   = fu;
        p.opcode    = id + 1;
        p.dest_tag  = id + 2;
        p.src1_val  = 64'hAAAA_0000_0000_0000 + id;
        p.src2_val  = 64'hBBBB_0000_0000_0000 + id;
        return p;
    endfunction

    // --------------------------------------------------------
    // Monitor
    // --------------------------------------------------------
    task automatic show_fifo_state();
        $display("\n[Time %0t] === DUT FIFO States ===", $time);
        $display("ALU0: entries=%0d head=%0d tail=%0d full=%b empty=%b",
            dut.alu0_fifo.entries, dut.alu0_fifo.head, dut.alu0_fifo.tail,
            dut.alu0_fifo.full_o, dut.alu0_fifo.empty_o);
        for (int i = 0; i < FIFO_DEPTH; i++) begin
            $display("  mem[%0d] valid=%b rob=%0d", i,
                dut.alu0_fifo.mem[i].valid,
                dut.alu0_fifo.mem[i].rob_idx);
        end
    endtask

// --------------------------------------------------------
// Test sequence
// --------------------------------------------------------
initial begin
    reset = 1;
    fu_fifo_wr_en = '0;
    fu_rd_en = '0;
    #20 reset = 0;

// --------------------------------------------------------
// ALU
// --------------------------------------------------------
    @(negedge clk);
    fu_fifo_wr_en[0] = 1;
    fu_fifo_wr_pkt[0] = make_pkt(1, FU_ALU);
    @(posedge clk);

    @(negedge clk);
    fu_fifo_wr_pkt[0] = make_pkt(2, FU_ALU);
    @(posedge clk);

    @(negedge clk);
    fu_fifo_wr_pkt[0] = make_pkt(3, FU_ALU);
    @(posedge clk);
    @(posedge clk);
    
    show_fifo_state();

    fu_fifo_wr_en = '0;

    // --- read one packet ---
    @(negedge clk);
    fu_rd_en[0] = 1;
    @(posedge clk);
    $display("Read packet: rob_idx=%0d", fu_issue_pkt_o[0].rob_idx);

    fu_rd_en = '0;

    #50;
    $display("==== TEST COMPLETE ====");
    $finish;
end


endmodule



