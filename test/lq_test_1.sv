`include "sys_defs.svh"

module lq_tb;

    // Parameters
    parameter int DISPATCH_WIDTH = 1;
    parameter int LQ_SIZE = 8; // 設小一點方便觀察
    parameter int IDX_WIDTH = $clog2(LQ_SIZE);

    // Clock & Reset
    logic clock, reset;

    // Interfaces
    logic       enq_valid;
    ADDR        enq_addr;
    MEM_SIZE    enq_size;
    ROB_IDX     enq_rob_idx;
    logic       full;

    logic       sq_forward_valid;
    MEM_BLOCK   sq_forward_data;
    ADDR        sq_forward_addr;
    logic       sq_fwd_pending;
    ADDR        sq_query_addr;
    MEM_SIZE    sq_query_size;

    logic       dc_req_valid;
    ADDR        dc_req_addr;
    MEM_SIZE    dc_req_size;
    logic       dc_req_accept;
    logic [IDX_WIDTH-1:0] dc_req_tag; // 來自 LQ 的 Tag

    MEM_BLOCK   dc_load_data;
    logic       dc_load_valid;
    logic [IDX_WIDTH-1:0] dc_load_tag; // 回傳給 LQ 的 Tag

    logic       wb_valid;
    ROB_IDX     wb_rob_idx;
    MEM_BLOCK   wb_data;
    logic       rob_commit_valid;
    ROB_IDX     rob_commit_valid_idx;
    logic       empty;

    // Snapshot Dummy
    lq_entry_t  snapshot_data_o[LQ_SIZE-1:0];
    logic [IDX_WIDTH-1:0] snap_head, snap_tail;
    logic [$clog2(LQ_SIZE+1)-1:0] snap_count;
    lq_entry_t  snapshot_data_i[LQ_SIZE-1:0]; // Tied to 0

    // ===============================================================
    // DUT Instantiation
    // ===============================================================
    lq #(
        .DISPATCH_WIDTH(DISPATCH_WIDTH),
        .LQ_SIZE(LQ_SIZE)
    ) dut (
        .clock(clock),
        .reset(reset),

        .enq_valid(enq_valid),
        .enq_addr(enq_addr),
        .enq_size(enq_size),
        .enq_rob_idx(enq_rob_idx),
        .full(full),

        .sq_forward_valid(sq_forward_valid),
        .sq_forward_data(sq_forward_data),
        .sq_forward_addr(sq_forward_addr),
        .sq_fwd_pending(sq_fwd_pending),
        .sq_query_addr(sq_query_addr),
        .sq_query_size(sq_query_size),

        .dc_req_valid(dc_req_valid),
        .dc_req_addr(dc_req_addr),
        .dc_req_size(dc_req_size),
        .dc_req_tag(dc_req_tag),       // Check this!
        .dc_req_accept(dc_req_accept),

        .dc_load_data(dc_load_data),
        .dc_load_valid(dc_load_valid),
        .dc_load_tag(dc_load_tag),     // Check this!

        .wb_valid(wb_valid),
        .wb_rob_idx(wb_rob_idx),
        .wb_data(wb_data),
        .rob_commit_valid(rob_commit_valid),
        .rob_commit_valid_idx(rob_commit_valid_idx),
        .empty(empty),

        // Dummy connections
        .is_branch_i('0),
        .snapshot_restore_valid_i('0),
        .checkpoint_valid_o(),
        .snapshot_data_o(snapshot_data_o),
        .snapshot_head_o(snap_head),
        .snapshot_tail_o(snap_tail),
        .snapshot_count_o(snap_count),
        .snapshot_data_i(snapshot_data_i),
        .snapshot_head_i('0),
        .snapshot_tail_i('0),
        .snapshot_count_i('0)
    );

    // ===============================================================
    // Clock Gen
    // ===============================================================
    always #5 clock = ~clock;

    // ===============================================================
    // Tasks
    // ===============================================================
    task sys_reset();
        reset = 1;
        enq_valid = 0;
        sq_forward_valid = 0;
        sq_fwd_pending = 0;
        dc_req_accept = 0;
        dc_load_valid = 0;
        rob_commit_valid = 0;
        for(int i=0; i<LQ_SIZE; i++) snapshot_data_i[i] = '0;
        @(posedge clock);
        @(posedge clock);
        reset = 0;
        @(posedge clock);
    endtask

    task dispatch_load(input ADDR addr, input ROB_IDX rob_idx);
        enq_valid = 1;
        enq_addr = addr;
        enq_size = WORD;
        enq_rob_idx = rob_idx;
        wait(!full);
        @(posedge clock);
        enq_valid = 0;
        $display("dispatch load : ADDR: %0h , rob_idx: %0d" , addr, rob_idx);
    endtask

    logic [IDX_WIDTH-1:0] captured_tag_1;
    logic [IDX_WIDTH-1:0] tag_A;
    logic [IDX_WIDTH-1:0] tag_B;
    // ===============================================================
    // Main Test
    // ===============================================================
    initial begin
        clock = 0;
        sys_reset();

        $display("\n=== TEST 1: Basic Tagged Request/Response ===");
        // 1. Dispatch
        dispatch_load(32'h1000, 10);
        
        // 2. Wait for Request and Capture Tag
        wait(dc_req_valid);
        captured_tag_1 = dc_req_tag;
        $display("[TB] Req 1: Addr=%h, Tag=%0d", dc_req_addr, captured_tag_1);
        
        // 3. Accept
        @(posedge clock);
        dc_req_accept = 1;
        @(posedge clock);
        dc_req_accept = 0;

        // 4. Return Data using captured Tag
        #10;
        @(posedge clock);
        dc_load_valid = 1;
        dc_load_data  = 32'hAAAA_BBBB;
        dc_load_tag   = captured_tag_1; // Use the tag!
        @(posedge clock);
        dc_load_valid = 0;

        // 5. Commit Check
        rob_commit_valid = 1;
        rob_commit_valid_idx = 10;
        @(posedge clock);
        if(wb_valid && wb_data == 32'hAAAA_BBBB) $display("[PASS] Basic Tag Test.");
        else $display("[FAIL] Basic Tag Test. WB_Data=%h", wb_data);
        rob_commit_valid = 0;


        // ===========================================================
        // TEST 2: Out-of-Order Cache Return (Crucial Test)
        // ===========================================================
        $display("\n=== TEST 2: Out-of-Order Return (The Tag Test) ===");
        
        // 1. Dispatch two loads
        // Load A: Addr 0x2000 (Will be slow) -> ROB #20
        dispatch_load(32'h2000, 20);
        // Load B: Addr 0x3000 (Will be fast) -> ROB #21
        dispatch_load(32'h3000, 21);

        // 2. Issue Load A
        // logic [IDX_WIDTH-1:0] tag_A;
        wait(dc_req_valid && dc_req_addr == 32'h2000);
        tag_A = dc_req_tag;
        $display("[TB] Issued Load A (0x2000) with Tag %0d", tag_A);
        @(posedge clock);
        dc_req_accept = 1;
        @(posedge clock);
        dc_req_accept = 0;

        // 3. Issue Load B
        
        wait(dc_req_valid && dc_req_addr == 32'h3000);
        tag_B = dc_req_tag;
        $display("[TB] Issued Load B (0x3000) with Tag %0d", tag_B);
        @(posedge clock);
        dc_req_accept = 1;
        @(posedge clock);
        dc_req_accept = 0;

        // 4. Return Data for Load B FIRST! (Using Tag B)
        $display("[TB] Returning Data for Load B first...");
        @(posedge clock);
        dc_load_valid = 1;
        dc_load_data  = 32'hBBBB_BBBB;
        dc_load_tag   = tag_B; // Using Tag B
        @(posedge clock);
        dc_load_valid = 0;

        // 5. Return Data for Load A LATER (Using Tag A)
        $display("[TB] Returning Data for Load A second...");
        @(posedge clock);
        dc_load_valid = 1;
        dc_load_data  = 32'hAAAA_AAAA;
        dc_load_tag   = tag_A; // Using Tag A
        @(posedge clock);
        dc_load_valid = 0;

        // 6. Verify Commit Order & Data
        // Commit A first (ROB #20) -> Should have 0xA...A
        @(posedge clock);
        rob_commit_valid = 1;
        rob_commit_valid_idx = 20;
        @(posedge clock);
        if(wb_valid && wb_data == 32'hAAAA_AAAA) 
            $display("[PASS] Load A (ROB 20) Data Correct: %h", wb_data);
        else 
            $display("[FAIL] Load A Data Wrong! Got %h", wb_data);
        
        // Commit B next (ROB #21) -> Should have 0xB...B
        rob_commit_valid_idx = 21;
        @(posedge clock);
        if(wb_valid && wb_data == 32'hBBBB_BBBB) 
            $display("[PASS] Load B (ROB 21) Data Correct: %h", wb_data);
        else 
            $display("[FAIL] Load B Data Wrong! Got %h", wb_data);
            
        rob_commit_valid = 0;


        // ===========================================================
        // TEST 3: Forwarding and Pending
        // ===========================================================
        $display("\n=== TEST 3: Forwarding Pending Logic ===");
        dispatch_load(32'h4000, 30);

        // Simulate SQ Pending response
        wait(sq_query_addr == 32'h4000);
        @(posedge clock);
        sq_fwd_pending = 1;
        sq_forward_addr = 32'h4000;
        
        // Check Stall
        repeat(3) @(posedge clock);
        if(dc_req_valid) $display("[FAIL] LQ sent request despite pending!");
        else $display("[PASS] LQ Stalled on Pending.");

        // Resolve Pending
        sq_fwd_pending = 0;
        sq_forward_valid = 1;
        sq_forward_data = 32'hCAFE_BABE;
        @(posedge clock);
        sq_forward_valid = 0;

        // Commit
        rob_commit_valid = 1;
        rob_commit_valid_idx = 30;
        @(posedge clock);
        if(wb_data == 32'hCAFE_BABE) $display("[PASS] Forwarding Data Correct.");
        rob_commit_valid = 0;

        $display("\n=== All Tests Finished ===");
        $finish;
    end

endmodule