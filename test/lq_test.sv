`include "sys_defs.svh"

module lq_polling_tb;

    // Parameters
    parameter int DISPATCH_WIDTH = 1;
    parameter int LQ_SIZE = 8;
    parameter int SQ_SIZE = 8;
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
    logic [IDX_WIDTH-1:0] dc_req_tag;

    MEM_BLOCK   dc_load_data;
    logic       dc_load_valid;
    logic [IDX_WIDTH-1:0] dc_load_tag;

    ROB_IDX     rob_head;
    logic       wb_valid;
    ROB_IDX     wb_rob_idx;
    MEM_BLOCK   wb_data;

    logic       rob_commit_valid;
    ROB_IDX     rob_commit_valid_idx;
    logic       empty;

    // Dummy Signals
    sq_entry_t sq_view_i[SQ_SIZE-1:0];
    lq_entry_t snapshot_data_o[LQ_SIZE-1:0];
    // ... other dummies tied to 0

    // ===============================================================
    // DUT Instantiation
    // ===============================================================
    lq #(
        .DISPATCH_WIDTH(DISPATCH_WIDTH),
        .LQ_SIZE(LQ_SIZE),
        .SQ_SIZE(SQ_SIZE)
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
        .dc_req_accept(dc_req_accept),
        .dc_req_tag(dc_req_tag),

        .dc_load_data(dc_load_data),
        .dc_load_valid(dc_load_valid),
        .dc_load_tag(dc_load_tag),

        .rob_head(rob_head),
        .wb_valid(wb_valid),
        .wb_rob_idx(wb_rob_idx),
        .wb_data(wb_data),

        .rob_commit_valid(rob_commit_valid),
        .rob_commit_valid_idx(rob_commit_valid_idx),
        .empty(empty),

        .sq_view_i(sq_view_i),
        
        // Dummies
        .is_branch_i('0), .snapshot_restore_valid_i('0),
        .checkpoint_valid_o(), .snapshot_data_o(snapshot_data_o),
        .snapshot_head_o(), .snapshot_tail_o(), .snapshot_count_o(),
        .snapshot_data_i(), .snapshot_head_i('0), .snapshot_tail_i('0), .snapshot_count_i('0)
    );

    // ===============================================================
    // Clock
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
        rob_head = 0;
        // Init SQ view
        for(int i=0; i<SQ_SIZE; i++) begin
            sq_view_i[i]='0;
        end
        @(posedge clock);
        @(posedge clock);
        reset = 0;
        @(posedge clock);
    endtask

    task dispatch_load(input ROB_IDX rob);
        @(posedge clock);
        enq_valid = 1;
        // enq_addr = addr;
        enq_size = WORD;
        enq_rob_idx = rob;
        enq_addr = 32'h1000; // 固定地址方便測試
        wait(!full);
        @(posedge clock);
        enq_valid = 0;
    endtask

    // ===============================================================
    // Main Test Sequence
    // ===============================================================
    initial begin
        clock = 0;
        sys_reset();

        $display("\n=== TEST START: is_older & Stall Logic ===\n");

        // -----------------------------------------------------
        // Case 1: Baseline - No Stores
        // -----------------------------------------------------
        $display("--- Case 1: Baseline (Empty SQ) ---");
        rob_head = 10; // ROB Window Start
        dispatch_load(20); // Load ROB #20 (Distance 10 from head)
        
        #1; // Wait for comb
        if (dc_req_valid) $display("[PASS] Load Issued (No obstacles).");
        else              $display("[FAIL] Load Stalled unexpectedly!");


        // -----------------------------------------------------
        // Case 2: Younger Store with Unknown Address
        // -----------------------------------------------------
        $display("\n--- Case 2: Younger Store Unknown (Should NOT Stall) ---");
        // Load is ROB 20.
        // Inject Store ROB 25 (Younger). Address Unknown.
        sq_view_i[0].valid = 1;
        sq_view_i[0].rob_idx = 25;
        sq_view_i[0].addr_valid = 0; // Unknown!

        #1;
        if (dc_req_valid) $display("[PASS] Load Issued. Ignored younger store #25.");
        else              $display("[FAIL] Load Stalled by younger store! is_older logic wrong?");


        // -----------------------------------------------------
        // Case 3: Older Store with Unknown Address
        // -----------------------------------------------------
        $display("\n--- Case 3: Older Store Unknown (Should STALL) ---");
        // Load is ROB 20.
        // Change SQ[0] to ROB 15 (Older than 20). Address Unknown.
        sq_view_i[0].rob_idx = 15;
        
        #1;
        if (!dc_req_valid) $display("[PASS] Load Stalled correctly by older store #15.");
        else               $display("[FAIL] Load Issued! Failed to detect older unknown store.");

        // Verify Resume: If address becomes valid
        $display("    -> Resolving Address...");
        sq_view_i[0].addr_valid = 1;
        #1;
        if (dc_req_valid)  $display("[PASS] Load Issued after address resolved.");
        else               $display("[FAIL] Load still stalled?");


        // -----------------------------------------------------
        // Case 4: Wrap-around Logic (The Ultimate Test)
        // -----------------------------------------------------
        $display("\n--- Case 4: ROB Wrap-around (Circular Buffer) ---");
        // 情境：ROB Size 假設是 64
        // Head = 60
        // Store = 62 (Very Old, near head)
        // Load = 2   (Very Young, wrapped around)
        
        // Reset and setup
        sys_reset();
        rob_head = 60;
        
        // Dispatch Load #2
        dispatch_load(2); 
        
        // Inject Store #62 into SQ, Address Unknown
        sq_view_i[0].valid = 1;
        sq_view_i[0].rob_idx = 62;
        sq_view_i[0].addr_valid = 0;

        #1;
        // 數學上：(62-60)=2, (2-60)=-58 -> Store(2) < Load(-58) ? 
        // 如果用 SystemVerilog 自動 Overflow 機制:
        // Store Dist = 2
        // Load Dist  = (2 - 60) mod 64 = 6
        // 2 < 6 -> True (Store is Older) -> Should Stall
        
        if (!dc_req_valid) $display("[PASS] Wrap-around detected: Store #62 is older than Load #2. Stalled.");
        else               $display("[FAIL] Wrap-around failed! Load #2 thought it was older than #62.");


        // -----------------------------------------------------
        // Case 5: Wrap-around False Positive Check
        // -----------------------------------------------------
        $display("\n--- Case 5: Wrap-around False Positive ---");
        // 情境：
        // Head = 60
        // Load = 62 (Old)
        // Store = 2 (Young)
        
        sys_reset();
        rob_head = 60;
        dispatch_load(62); // Load is Old

        // Inject Store #2 (Young), Unknown
        sq_view_i[0].valid = 1;
        sq_view_i[0].rob_idx = 2;
        sq_view_i[0].addr_valid = 0;

        #1;
        // Load Dist = 2
        // Store Dist = 6
        // Store is NOT older. Should NOT Stall.
        if (dc_req_valid) $display("[PASS] Correctly ignored younger wrapped store #2.");
        else              $display("[FAIL] False Stall! Load #62 stalled for younger store #2.");

        $display("\n=== All Tests Finished ===");
        $finish;
    end

endmodule