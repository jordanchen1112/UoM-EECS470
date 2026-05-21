`timescale 1ns/1ps
`include "sys_defs.svh"

module fetch_test;

    // -------------------------------
    // Parameters
    // -------------------------------
    localparam FETCH_WIDTH = 2;
    localparam ADDR_WIDTH  = 32;

    // -------------------------------
    // DUT I/O signals
    // -------------------------------
    logic clock, reset;
    logic if_valid, if_flush;
    logic pred_valid_i, pred_taken_i;
    logic [$clog2(FETCH_WIDTH)-1:0] pred_lane_i;
    logic [ADDR_WIDTH-1:0] pred_target_i, correct_pc_target_o;

    MEM_BLOCK [FETCH_WIDTH-1:0] Imem_data;
    MEM_TAG Imem2proc_transaction_tag, Imem2proc_data_tag;
    MEM_COMMAND Imem_command;
    ADDR Imem_addr;

    IF_ID_PACKET [FETCH_WIDTH-1:0] if_packet_o;

    // -------------------------------
    // DUT instantiation
    // -------------------------------
    stage_if #(.FETCH_WIDTH(FETCH_WIDTH)) dut (
        .clock(clock),
        .reset(reset),
        .if_valid(if_valid),
        .if_flush(if_flush),
        .pred_valid_i(pred_valid_i),
        .pred_lane_i(pred_lane_i),
        .pred_taken_i(pred_taken_i),
        .pred_target_i(pred_target_i),
        .Imem_data(Imem_data),
        .Imem2proc_transaction_tag(Imem2proc_transaction_tag),
        .Imem2proc_data_tag(Imem2proc_data_tag),
        .Imem_command(Imem_command),
        .Imem_addr(Imem_addr),
        .correct_pc_target_o(correct_pc_target_o),
        .if_packet_o(if_packet_o)
    );

    // -------------------------------
    // Clock generation
    // -------------------------------
    always #5 clock = ~clock;  // 100MHz

    // -------------------------------
    // Memory model (dummy)
    // -------------------------------
    // Simulate a simple ICache: each block outputs a fixed sequence of instruction numbers.
    initial begin : MEM_INIT
        int i;
        for (i = 0; i < FETCH_WIDTH; i++) begin
            Imem_data[i].word_level[0] = 32'h1111_0000 + i;
            Imem_data[i].word_level[1] = 32'h2222_0000 + i;
        end
        Imem2proc_transaction_tag = 0;
        Imem2proc_data_tag = 0;
    end

    // -------------------------------
    // Monitor
    // -------------------------------
    always @(posedge clock) begin
        if (!reset) begin
            $display("[%0t] PC=%h | CMD=%0d | FLUSH=%0b | PRED_TAKEN=%0b | VALID=%0b",
                     $time, Imem_addr, Imem_command, if_flush, pred_taken_i, if_valid);
            for (int i = 0; i < FETCH_WIDTH; i++) begin
                $display("    lane%0d: PC=%h NPC=%h INST=%h VALID=%b",
                         i, if_packet_o[i].PC, if_packet_o[i].NPC,
                         if_packet_o[i].inst, if_packet_o[i].valid);
            end
        end
    end

    // -------------------------------
    // Test sequence
    // -------------------------------
    initial begin
        $dumpfile("fetch_stage.vcd");
        $dumpvars(0, dut);

        // Default values
        clock = 0; reset = 1;
        if_valid = 0; if_flush = 0;
        pred_valid_i = 0; pred_taken_i = 0; pred_lane_i = 0;
        pred_target_i = 32'h0000_0040;
        correct_pc_target_o = 32'h0000_0080;

        #20 reset = 0;
        $display("\n=== TESTCASE 1: Basic sequential fetch ===");
        basic_fetch();

        $display("\n=== TESTCASE 2: Predicted branch taken ===");
        branch_pred_taken();

        $display("\n=== TESTCASE 3: Flush correction ===");
        flush_recovery();

        $display("\n=== TESTCASE 4: Stall behavior ===");
        stall_behavior();

        #50 $display("\nSimulation finished!");
        $finish;
    end

    // ============================================================
    // Testcase 1: Basic sequential fetch
    // ============================================================
    task basic_fetch();
        begin
            if_valid = 1;
            repeat (4) @(posedge clock);
        end
    endtask

    // ============================================================
    // Testcase 2: Predicted branch taken
    // ============================================================
    task branch_pred_taken();
        begin
            pred_valid_i = 1;
            pred_taken_i = 1;
            pred_lane_i  = 1;             // Assume the branch is in lane 1
            pred_target_i = 32'h0000_0040; // Jump to 0x40.
            @(posedge clock);
            pred_valid_i = 0;
            pred_taken_i = 0;
            repeat (3) @(posedge clock);
        end
    endtask

    // ============================================================
    // Testcase 3: Flush correction
    // ============================================================
    task flush_recovery();
        begin
            if_flush = 1;
            correct_pc_target_o = 32'h0000_0080; // Correct PC.
            @(posedge clock);
            if_flush = 0;
            repeat (3) @(posedge clock);
        end
    endtask

    // ============================================================
    // Testcase 4: Stall behavior
    // ============================================================
    task stall_behavior();
        begin
            if_valid = 0; // stall
            repeat (2) @(posedge clock);
            if_valid = 1;
            repeat (2) @(posedge clock);
        end
    endtask

endmodule
