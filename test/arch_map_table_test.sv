`timescale 1ns/1ps

module arch_map_table_tb;
    // -------------------------------------------------------
    // Parameters
    // -------------------------------------------------------
    localparam int ARCH_REGS     = 64;
    localparam int PHYS_REGS     = 128;
    localparam int COMMIT_WIDTH  = 2;

    // -------------------------------------------------------
    // DUT I/O signals
    // -------------------------------------------------------

    logic clk, reset;

    logic [COMMIT_WIDTH-1:0]                         commit_valid_i;
    logic [COMMIT_WIDTH-1:0][$clog2(ARCH_REGS)-1:0]  commit_arch_i;
    logic [COMMIT_WIDTH-1:0][$clog2(PHYS_REGS)-1:0]  commit_phys_i;

    logic [ARCH_REGS-1:0][$clog2(PHYS_REGS)-1:0]     snapshot_o;
    logic                                             restore_valid_i;
    logic [ARCH_REGS-1:0][$clog2(PHYS_REGS)-1:0]     restore_snapshot_i;

    // -------------------------------------------------------
    // DUT instance
    // -------------------------------------------------------

    arch_map_table #(
        .ARCH_REGS(ARCH_REGS),
        .PHYS_REGS(PHYS_REGS),
        .COMMIT_WIDTH(COMMIT_WIDTH)
    ) dut (
        .clk                (clk),
        .reset              (reset),
        .commit_valid_i     (commit_valid_i),
        .commit_arch_i      (commit_arch_i),
        .commit_phys_i      (commit_phys_i),
        .snapshot_o         (snapshot_o),
        .restore_valid_i    (restore_valid_i),
        .restore_snapshot_i (restore_snapshot_i)
    );


    initial clk = 0;
    always #5 clk = ~clk;  // 100 MHz

    // =====================================================
    // Task definitions
    // =====================================================
    task print_table(string msg);
        $display("---- %s ----", msg);
        for (int i = 0; i < ARCH_REGS; i++) begin
            $display("table[%0d] = %0d", i, snapshot_o[i]);
        end
    endtask

    // =====================================================
    // Test sequence
    // =====================================================
    initial begin
        logic [ARCH_REGS-1:0][$clog2(PHYS_REGS)-1:0] saved_snapshot;
        clk = 0;
        reset = 0;
        commit_valid_i = '0;
        commit_arch_i  = '0;
        commit_phys_i  = '0;
        restore_valid_i = 0;
        restore_snapshot_i = '0;

        // --------------------------
        // Reset phase
        // --------------------------
        $display("\n=== Reset Test ===");
        reset = 1;
        @(posedge clk);
        @(posedge clk);
        reset = 0;

        // 檢查reset之後的table內容
        @(posedge clk);
        print_table("After reset");
        for (int i = 0; i < ARCH_REGS; i++) begin
            if (snapshot_o[i] !== i)
                $error("Reset mismatch: table[%0d] = %0d (expected %0d)", i, snapshot_o[i], i);
        end

        // --------------------------
        // Commit phase
        // --------------------------
        $display("\n=== Commit Test ===");
        commit_valid_i = 2'b11;
        commit_arch_i[0] = 2;
        commit_arch_i[1] = 5;
        commit_phys_i[0] = 10;
        commit_phys_i[1] = 12;

        @(posedge clk);
        commit_valid_i = '0;

        @(posedge clk);
        print_table("After commit");
        if (snapshot_o[2] != 10 || snapshot_o[5] != 12)
            $error("Commit update failed");

        // --------------------------
        // Snapshot / Restore phase
        // --------------------------
        $display("\n=== Snapshot/Restore Test ===");
        // logic [ARCH_REGS-1:0][$clog2(PHYS_REGS)-1:0] saved_snapshot;
        saved_snapshot = snapshot_o;  // save current state

        // 模擬新的commit覆蓋內容
        commit_valid_i[0] = 1;
        commit_arch_i[0]  = 2;
        commit_phys_i[0]  = 8;
        @(posedge clk);
        commit_valid_i = '0;
        @(posedge clk);
        print_table("After overwrite commit");

        // 還原舊的snapshot
        restore_valid_i = 1;
        restore_snapshot_i = saved_snapshot;
        @(posedge clk);
        restore_valid_i = 0;
        @(posedge clk);

        print_table("After restore");
        if (snapshot_o[2] != 10 || snapshot_o[5] != 12)
            $error("Restore failed!");

        $display("\n✅ All tests completed successfully!");
        $finish;
    end



endmodule