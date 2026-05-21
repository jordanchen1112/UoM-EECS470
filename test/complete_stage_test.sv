`timescale 1ns/1ps
`include "../verilog/def.svh"  // for cdb_entry_t typedef

module complete_stage_tb;

    // ----------------------------------------------
    // Parameters (match DUT)
    // ----------------------------------------------
    localparam int XLEN       = 64;
    localparam int PHYS_REGS  = 128;
    localparam int ROB_DEPTH  = 64;
    localparam int WB_WIDTH   = 4;
    localparam int CDB_WIDTH  = 4;

    // ----------------------------------------------
    // DUT I/O signals
    // ----------------------------------------------
    logic clk, reset;

    // From FU
    logic [WB_WIDTH-1:0]                    fu_valid_i;
    logic [WB_WIDTH-1:0][XLEN-1:0]          fu_value_i;
    logic [WB_WIDTH-1:0][$clog2(PHYS_REGS)-1:0] fu_dest_prf_i;
    logic [WB_WIDTH-1:0][$clog2(ROB_DEPTH)-1:0] fu_rob_idx_i;
    logic [WB_WIDTH-1:0]                    fu_exception_i;
    logic [WB_WIDTH-1:0]                    fu_mispred_i;

    // To PRF
    logic [WB_WIDTH-1:0]                    prf_wr_en_o;
    logic [WB_WIDTH-1:0][$clog2(PHYS_REGS)-1:0] prf_waddr_o;
    logic [WB_WIDTH-1:0][XLEN-1:0]          prf_wdata_o;

    // To ROB
    logic [WB_WIDTH-1:0]                    wb_valid_o;
    logic [WB_WIDTH-1:0][$clog2(ROB_DEPTH)-1:0] wb_rob_idx_o;
    logic [WB_WIDTH-1:0]                    wb_exception_o;
    logic [WB_WIDTH-1:0]                    wb_mispred_o;

    // To CDB
    cdb_entry_t [CDB_WIDTH-1:0]             cdb_o;

    // ----------------------------------------------
    // DUT instantiation
    // ----------------------------------------------
    complete_stage #(
        .XLEN(XLEN),
        .PHYS_REGS(PHYS_REGS),
        .ROB_DEPTH(ROB_DEPTH),
        .WB_WIDTH(WB_WIDTH),
        .CDB_WIDTH(CDB_WIDTH)
    ) dut (
        .clk(clk),
        .reset(reset),

        .fu_valid_i(fu_valid_i),
        .fu_value_i(fu_value_i),
        .fu_dest_prf_i(fu_dest_prf_i),
        .fu_rob_idx_i(fu_rob_idx_i),
        .fu_exception_i(fu_exception_i),
        .fu_mispred_i(fu_mispred_i),

        .prf_wr_en_o(prf_wr_en_o),
        .prf_waddr_o(prf_waddr_o),
        .prf_wdata_o(prf_wdata_o),

        .wb_valid_o(wb_valid_o),
        .wb_rob_idx_o(wb_rob_idx_o),
        .wb_exception_o(wb_exception_o),
        .wb_mispred_o(wb_mispred_o),

        .cdb_o(cdb_o)
    );

    // ----------------------------------------------
    // Clock generation
    // ----------------------------------------------
    initial clk = 0;
    always #5 clk = ~clk;

    // ----------------------------------------------
    // Test sequence
    // ----------------------------------------------
    initial begin
        $display("==============================================");
        $display("     Complete Stage Basic Functional Test     ");
        $display("==============================================");

        reset = 1;
        fu_valid_i = '0;
        fu_value_i = '0;
        fu_dest_prf_i = '0;
        fu_rob_idx_i = '0;
        fu_exception_i = '0;
        fu_mispred_i = '0;

        @(negedge clk);
        reset = 0;

        // -----------------------
        // Case 1: Basic writeback
        // -----------------------
        @(negedge clk);
        fu_valid_i[0] = 1;
        fu_value_i[0] = 64'hDEADBEEF12345678;
        fu_dest_prf_i[0] = 5;
        fu_rob_idx_i[0]  = 10;
        fu_exception_i[0] = 0;
        fu_mispred_i[0] = 0;

        @(posedge clk);
        #1;
        $display("[T=%0t] PRF write_en=%b addr=%0d data=%h", $time,
                 prf_wr_en_o[0], prf_waddr_o[0], prf_wdata_o[0]);
        $display("[T=%0t] ROB valid=%b idx=%0d exception=%b mispred=%b",
                 $time, wb_valid_o[0], wb_rob_idx_o[0],
                 wb_exception_o[0], wb_mispred_o[0]);
        if (prf_wr_en_o[0] && wb_valid_o[0])
            $display("@@@ Passed basic writeback test");
        else
            $display("@@@ Failed basic writeback test");

        // -----------------------
        // Case 2: Multi-FU write
        // -----------------------
        @(negedge clk);
        fu_valid_i = 4'b1111;
        for (int i = 0; i < WB_WIDTH; i++) begin
            fu_value_i[i] = i + 64'h1000;
            fu_dest_prf_i[i] = i + 1;
            fu_rob_idx_i[i]  = i + 20;
        end

        @(posedge clk);
        #1;
        for (int i = 0; i < WB_WIDTH; i++) begin
            $display("[T=%0t] FU%0d → PRF[%0d]=%h ROB[%0d]",
                $time, i, prf_waddr_o[i], prf_wdata_o[i], wb_rob_idx_o[i]);
        end
        if (&prf_wr_en_o && &wb_valid_o)
            $display("@@@ Passed multi-FU writeback test");
        else
            $display("@@@ Failed multi-FU writeback test");

        // -----------------------
        // Case 3: Exception/Mispred
        // -----------------------
        @(negedge clk);
        fu_valid_i = '0;
        fu_valid_i[1] = 1;
        fu_exception_i[1] = 1;
        fu_mispred_i[1] = 1;
        fu_value_i[1] = 64'hFACEFACEFACEFACE;
        fu_dest_prf_i[1] = 7;
        fu_rob_idx_i[1]  = 33;

        @(posedge clk);
        #1;
        $display("[T=%0t] FU1 Exception=%b Mispred=%b",
                 $time, wb_exception_o[1], wb_mispred_o[1]);
        if (wb_exception_o[1] && wb_mispred_o[1])
            $display("@@@ Passed exception/mispred test");
        else
            $display("@@@ Failed exception/mispred test");

        $display("==============================================");
        $display("        Complete Stage Testbench Done         ");
        $display("==============================================");
        $finish;
    end

endmodule
