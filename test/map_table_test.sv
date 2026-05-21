`timescale 1ns/1ps
// `include "map_table.sv"

module map_table_tb;
    // --------------------------------------------------------
    // Parameters
    // --------------------------------------------------------
    localparam int ARCH_REGS      = 64;
    localparam int PHYS_REGS      = 128;
    localparam int DISPATCH_WIDTH = 2;
    localparam int WB_WIDTH       = 4;
    localparam int COMMIT_WIDTH   = 2;


    // --------------------------------------------------------
    // DUT signals
    // --------------------------------------------------------
    logic clk, reset;
    logic flush_i;
    logic snapshot_restore_i;

    logic [ARCH_REGS-1:0][$clog2(PHYS_REGS)-1:0] snapshot_data_i;
    logic [ARCH_REGS-1:0][$clog2(PHYS_REGS)-1:0] snapshot_data_o;

    logic [DISPATCH_WIDTH-1:0][$clog2(ARCH_REGS)-1:0] rs1_arch_i;
    logic [DISPATCH_WIDTH-1:0][$clog2(ARCH_REGS)-1:0] rs2_arch_i;
    logic [DISPATCH_WIDTH-1:0][$clog2(PHYS_REGS)-1:0] rs1_phys_o;
    logic [DISPATCH_WIDTH-1:0][$clog2(PHYS_REGS)-1:0] rs2_phys_o;
    logic [DISPATCH_WIDTH-1:0] rs1_valid_o, rs2_valid_o;

    logic [DISPATCH_WIDTH-1:0]                        disp_valid_i;
    logic [DISPATCH_WIDTH-1:0][$clog2(ARCH_REGS)-1:0] disp_arch_i;
    logic [DISPATCH_WIDTH-1:0][$clog2(PHYS_REGS)-1:0] disp_new_phys_i;

    logic [WB_WIDTH-1:0] wb_valid_i;
    logic [WB_WIDTH-1:0][$clog2(PHYS_REGS)-1:0] wb_phys_i;

    // --------------------------------------------------------
    // DUT Instance
    // --------------------------------------------------------
    map_table #(
        .ARCH_REGS(ARCH_REGS),
        .PHYS_REGS(PHYS_REGS),
        .DISPATCH_WIDTH(DISPATCH_WIDTH),
        .WB_WIDTH(WB_WIDTH),
        .COMMIT_WIDTH(COMMIT_WIDTH)
    ) dut (
        .clk(clk),
        .reset(reset),
        .flush_i(flush_i),
        .snapshot_restore_i(snapshot_restore_i),
        .snapshot_data_i(snapshot_data_i),
        .snapshot_data_o(snapshot_data_o),
        .rs1_arch_i(rs1_arch_i),
        .rs2_arch_i(rs2_arch_i),
        .rs1_phys_o(rs1_phys_o),
        .rs2_phys_o(rs2_phys_o),
        .rs1_valid_o(rs1_valid_o),
        .rs2_valid_o(rs2_valid_o),
        .disp_valid_i(disp_valid_i),
        .disp_arch_i(disp_arch_i),
        .disp_new_phys_i(disp_new_phys_i),
        .wb_valid_i(wb_valid_i),
        .wb_phys_i(wb_phys_i)
    );

    // --------------------------------------------------------
    // Clock Generation
    // --------------------------------------------------------
    initial clk = 0;
    always #5 clk = ~clk;  // 100 MHz

    // --------------------------------------------------------
    // Test Sequence
    // --------------------------------------------------------
    initial begin
        $display("\n===== MAP TABLE TEST START =====\n");
        reset = 1; flush_i = 0; snapshot_restore_i = 0;
        disp_valid_i = 0; wb_valid_i = 0;
        #10;
        reset = 0;

        // ---- Step 1: After reset ----
        $display("[1] Checking reset state...");
        #10;
        for (int i = 0; i < ARCH_REGS; i++) begin
            if (dut.table[i].phys !== i)
                $display("❌ Error: table[%0d].phys != %0d", i, i);
        end

        // ---- Step 2: Dispatch rename ----
        $display("[2] Dispatch rename test...");
        disp_valid_i = 2'b11;
        disp_arch_i  = '{2, 3};
        disp_new_phys_i = '{10, 11};
        #10;
        disp_valid_i = 0;
        #10;

        $display(" table[2].phys=%0d valid=%b", dut.table[2].phys, dut.table[2].valid);
        $display(" table[3].phys=%0d valid=%b", dut.table[3].phys, dut.table[3].valid);

        // ---- Step 3: Writeback ----
        $display("[3] Writeback test...");
        wb_valid_i = 2'b10;
        wb_phys_i[1] = 11;  // mark physical reg 11 ready
        #10;
        wb_valid_i = 0;
        #10;
        $display(" After WB: table[3].valid=%b (expect 1)", dut.table[3].valid);

        // ---- Step 4: Snapshot Save ----
        $display("[4] Snapshot test...");
        for (int i = 0; i < ARCH_REGS; i++)
            snapshot_data_i[i] = '0; // clear input first

        // save snapshot
        #5;
        $display(" Snapshot saved for arch reg 3 -> phys %0d", snapshot_data_o[3]);

        // ---- Step 5: Flush ----
        $display("[5] Flush test...");
        flush_i = 1; #10; flush_i = 0;
        for (int i = 0; i < ARCH_REGS; i++) begin
            if (dut.table[i].phys != i)
                $display("❌ Error after flush at reg %0d", i);
        end

        // ---- Step 6: Snapshot Restore ----
        $display("[6] Snapshot restore test...");
        snapshot_data_i = snapshot_data_o; // restore from saved snapshot
        snapshot_restore_i = 1; #10; snapshot_restore_i = 0;

        #10;
        $display(" Restored: table[3].phys=%0d (expect 11)", dut.table[3].phys);

        $display("\n===== MAP TABLE TEST FINISHED =====\n");
        $finish;
    end

endmodule

