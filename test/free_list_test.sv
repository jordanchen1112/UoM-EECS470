`timescale 1ns/1ps

module free_list_tb;

    // ---------------------------------------
    // Parameters
    // ---------------------------------------
    localparam int DISPATCH_WIDTH = 2;
    localparam int COMMIT_WIDTH   = 2;
    localparam int ARCH_REGS      = 64;
    localparam int PHYS_REGS      = 128;

    // ---------------------------------------
    // DUT I/O signals
    // ---------------------------------------
    logic clk, reset;

    logic [DISPATCH_WIDTH-1:0] alloc_req_i;
    logic [DISPATCH_WIDTH-1:0][$clog2(PHYS_REGS)-1:0] alloc_phys_o;
    logic [DISPATCH_WIDTH-1:0] alloc_valid_o;
    logic full_o;
    logic [$clog2(PHYS_REGS):0] free_count_o;

    logic [COMMIT_WIDTH-1:0] free_valid_i;
    logic [COMMIT_WIDTH-1:0][$clog2(PHYS_REGS)-1:0] free_phys_i;

    // ---------------------------------------
    // Instantiate DUT
    // ---------------------------------------
    free_list #(
        .DISPATCH_WIDTH(DISPATCH_WIDTH),
        .COMMIT_WIDTH(COMMIT_WIDTH),
        .ARCH_REGS(ARCH_REGS),
        .PHYS_REGS(PHYS_REGS)
    ) dut (
        .clk(clk),
        .reset(reset),
        .alloc_req_i(alloc_req_i),
        .alloc_phys_o(alloc_phys_o),
        .alloc_valid_o(alloc_valid_o),
        .full_o(full_o),
        .free_count_o(free_count_o),
        .free_valid_i(free_valid_i),
        .free_phys_i(free_phys_i)
    );

    // ---------------------------------------
    // Clock generation
    // ---------------------------------------
    initial clk = 0;
    always #5 clk = ~clk;

    // task print_table(string msg);
    //     $display("---- %s ----", msg);
    //     for (int i = 0; i < (PHYS_REGS - ARCH_REGS); i++) begin
    //         $display("table[%0d] = %0d", i, free_fifo[i]);
    //     end
    // endtask

    // ---------------------------------------
    // Test sequence
    // ---------------------------------------
    initial begin
        int alloc0, alloc1;
        $display("===== Free List Test Start =====");
        clk = 0;
        reset = 1;
        alloc_req_i = '0;
        free_valid_i = '0;
        free_phys_i = '0;
        @(posedge clk);
        @(posedge clk);
        reset = 0;
        @(posedge clk);

        // -----------------------------------
        // Check reset initialization
        // -----------------------------------
        $display("[TEST] After reset, free_count_o = %0d (expect %0d)",
                 free_count_o, PHYS_REGS - ARCH_REGS);
        // print_table(After_reset);
        if (free_count_o !== (PHYS_REGS - ARCH_REGS))
            $error("Reset free_count incorrect!");

        // -----------------------------------
        // Allocate 2 registers
        // -----------------------------------
        alloc_req_i = 2'b11;
        @(posedge clk);
        alloc_req_i = 2'b00;
        // @(posedge clk);
        $display("[ALLOC] Allocated regs: %0d, %0d (valid: %b)",
                 alloc_phys_o[0], alloc_phys_o[1], alloc_valid_o);
        // print_table(After A)
        alloc0 = alloc_phys_o[0];
        alloc1 = alloc_phys_o[1];
        @(posedge clk);

        $display("[CHECK] Free count after alloc = %0d", free_count_o);

        // -----------------------------------
        // Free one register (simulate commit)
        // -----------------------------------
        free_valid_i[0] = 1'b1;
        free_phys_i[0] = alloc0;
        @(posedge clk);
        #1ns;
        free_valid_i = '0;

        $display("[FREE] Freed reg %0d, free_count now = %0d", alloc0, free_count_o);

        // -----------------------------------
        // Simultaneous alloc + free
        // -----------------------------------
        alloc_req_i = 2'b01;
        free_valid_i[0] = 1'b1;
        free_phys_i[0] = alloc1;
        @(posedge clk);
        alloc_req_i = '0;
        free_valid_i = '0;
        #1ns;
        $display("[SIMULT] Alloc + Free same cycle. Allocated: %0d, Free: %0d, free_count_o: %0d", alloc_phys_o[0], free_phys_i[0], free_count_o);
        @(posedge clk);

        // -----------------------------------
        // Drain free list completely
        // -----------------------------------
        repeat(10) begin
            alloc_req_i = 2'b11;
            @(posedge clk);
        end
        alloc_req_i = 2'b00;
        // @(posedge clk);
        #1ns;
        $display("[DRAIN] Free count after draining = %0d", free_count_o);

        // -----------------------------------
        // Try allocate when empty
        // -----------------------------------
        alloc_req_i = 2'b11;
        @(posedge clk);
        alloc_req_i = 2'b00;
        if (alloc_valid_o != 2'b00)
            $error("Should not allocate when free list is empty!");

        $display("===== Free List Test Finished =====");
        $finish;
    end

endmodule