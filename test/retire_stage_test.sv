`timescale 1ns/1ps

module retire_stage_tb;

    // -------------------------------------------------------
    // Parameters
    // -------------------------------------------------------
    localparam int ARCH_REGS    = 8;
    localparam int PHYS_REGS    = 16;
    localparam int COMMIT_WIDTH = 2;

    // -------------------------------------------------------
    // Clock / Reset
    // -------------------------------------------------------
    logic clk;
    logic reset;

    always #5 clk = ~clk;  // 10ns period

    // -------------------------------------------------------
    // DUT I/O signals
    // -------------------------------------------------------
    logic [COMMIT_WIDTH-1:0]                         commit_valid_i;
    logic [COMMIT_WIDTH-1:0]                         commit_rd_wen_i;
    logic [COMMIT_WIDTH-1:0][$clog2(ARCH_REGS)-1:0]  commit_rd_arch_i;
    logic [COMMIT_WIDTH-1:0][$clog2(PHYS_REGS)-1:0]  commit_new_prf_i;
    logic [COMMIT_WIDTH-1:0][$clog2(PHYS_REGS)-1:0]  commit_old_prf_i;
    logic                                            flush_i;

    logic [COMMIT_WIDTH-1:0]                         amt_commit_valid_o;
    logic [COMMIT_WIDTH-1:0][$clog2(ARCH_REGS)-1:0]  amt_commit_arch_o;
    logic [COMMIT_WIDTH-1:0][$clog2(PHYS_REGS)-1:0]  amt_commit_phys_o;

    logic [COMMIT_WIDTH-1:0]                         free_valid_o;
    logic [COMMIT_WIDTH-1:0][$clog2(PHYS_REGS)-1:0]  free_reg_o;

    logic [$clog2(COMMIT_WIDTH+1)-1:0]               retire_cnt_o;

    // -------------------------------------------------------
    // Instantiate DUT
    // -------------------------------------------------------
    retire_stage #(
        .ARCH_REGS(ARCH_REGS),
        .PHYS_REGS(PHYS_REGS),
        .COMMIT_WIDTH(COMMIT_WIDTH)
    ) dut (
        .clk(clk),
        .reset(reset),

        .commit_valid_i(commit_valid_i),
        .commit_rd_wen_i(commit_rd_wen_i),
        .commit_rd_arch_i(commit_rd_arch_i),
        .commit_new_prf_i(commit_new_prf_i),
        .commit_old_prf_i(commit_old_prf_i),
        .flush_i(flush_i),

        .amt_commit_valid_o(amt_commit_valid_o),
        .amt_commit_arch_o(amt_commit_arch_o),
        .amt_commit_phys_o(amt_commit_phys_o),

        .free_valid_o(free_valid_o),
        .free_reg_o(free_reg_o),

        .retire_cnt_o(retire_cnt_o)
    );

    // -------------------------------------------------------
    // Task: Print status
    // -------------------------------------------------------
    task print_outputs(string tag);
        $display("[%0t] %s", $time, tag);
        for (int i = 0; i < COMMIT_WIDTH; i++) begin
            $display("  COMMIT[%0d]: valid=%0b rd_wen=%0b arch=%0d new=%0d old=%0d",
                     i, commit_valid_i[i], commit_rd_wen_i[i], commit_rd_arch_i[i],
                     commit_new_prf_i[i], commit_old_prf_i[i]);
        end
        for (int i = 0; i < COMMIT_WIDTH; i++) begin
            $display("  -> AMT[%0d]: valid=%0b arch=%0d phys=%0d | Free[%0d]: valid=%0b reg=%0d",
                     i, amt_commit_valid_o[i], amt_commit_arch_o[i], amt_commit_phys_o[i],
                     i, free_valid_o[i], free_reg_o[i]);
        end
        $display("  retire_cnt=%0d\n", retire_cnt_o);
    endtask

    // -------------------------------------------------------
    // Test sequence
    // -------------------------------------------------------
    initial begin
        $dumpfile("retire_stage_tb.vcd");
        $dumpvars(0, retire_stage_tb);

        clk = 0;
        reset = 1;
        commit_valid_i = '0;
        commit_rd_wen_i = '0;
        commit_rd_arch_i = '0;
        commit_new_prf_i = '0;
        commit_old_prf_i = '0;
        flush_i = 0;

        #20;
        reset = 0;
        #10;

        // -------------------------------
        // Case 1: Normal commit 2 instr
        // -------------------------------
        commit_valid_i = 2'b11;
        commit_rd_wen_i = 2'b11;
        commit_rd_arch_i[0] = 3'd2; commit_new_prf_i[0] = 4'd8; commit_old_prf_i[0] = 4'd3;
        commit_rd_arch_i[1] = 3'd5; commit_new_prf_i[1] = 4'd9; commit_old_prf_i[1] = 4'd6;
        #10;
        print_outputs("Normal commit (2 instructions)");

        // -------------------------------
        // Case 2: One store (rd_wen=0)
        // -------------------------------
        commit_valid_i = 2'b11;
        commit_rd_wen_i = 2'b01; // only slot 0 writes a reg
        commit_rd_arch_i[0] = 3'd1; commit_new_prf_i[0] = 4'd10; commit_old_prf_i[0] = 4'd4;
        commit_rd_arch_i[1] = 3'd7; commit_new_prf_i[1] = 4'd11; commit_old_prf_i[1] = 4'd5;
        #10;
        print_outputs("One rd_wen=0 (store)");

        // -------------------------------
        // Case 3: Flush active
        // -------------------------------
        flush_i = 1;
        commit_valid_i = 2'b11;
        commit_rd_wen_i = 2'b11;
        commit_rd_arch_i[0] = 3'd2; commit_new_prf_i[0] = 4'd12; commit_old_prf_i[0] = 4'd7;
        commit_rd_arch_i[1] = 3'd4; commit_new_prf_i[1] = 4'd13; commit_old_prf_i[1] = 4'd8;
        #10;
        print_outputs("Flush active");

        // -------------------------------
        // Case 4: Back to normal
        // -------------------------------
        flush_i = 0;
        commit_valid_i = 2'b01;
        commit_rd_wen_i = 2'b01;
        commit_rd_arch_i[0] = 3'd0; commit_new_prf_i[0] = 4'd14; commit_old_prf_i[0] = 4'd1;
        #10;
        print_outputs("After flush recovery");

        #10;
        $finish;
    end

endmodule
