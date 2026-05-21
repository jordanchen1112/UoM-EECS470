`include "sys_defs.svh"

module lsq_top_tb;

    // Parameters
    parameter int DISPATCH_WIDTH = 1;
    parameter int SQ_SIZE = 8;
    parameter int LQ_SIZE = 8;
    parameter int SQ_IDX_WIDTH = $clog2(SQ_SIZE);
    parameter int LQ_IDX_WIDTH = $clog2(LQ_SIZE);

    // Clock & Reset
    logic clock, reset;

    // Dispatch Interface
    logic       dispatch_valid;
    logic       dispatch_is_store;
    ADDR        dispatch_addr;
    MEM_SIZE    dispatch_size;
    ROB_IDX     dispatch_rob_idx;
    logic       lsq_full;

    // Execution Interface (Store Data)
    logic       sq_data_valid;
    MEM_BLOCK   sq_data;
    ROB_IDX     sq_data_rob_idx;

    // Commit Interface
    logic       commit_valid;
    ROB_IDX     commit_rob_idx;

    // Writeback Interface
    logic       wb_valid;
    ROB_IDX     wb_rob_idx;
    MEM_BLOCK   wb_data;

    // D-Cache Interface
    // Port 0 (Load)
    ADDR        Dcache_addr_0;
    MEM_COMMAND Dcache_command_0;
    MEM_SIZE    Dcache_size_0;
    MEM_BLOCK   Dcache_store_data_0;
    logic [LQ_IDX_WIDTH-1:0] Dcache_req_tag;
    logic       Dcache_req_0_accept;
    MEM_BLOCK   Dcache_data_out_0;
    logic       Dcache_valid_out_0;
    logic [LQ_IDX_WIDTH-1:0] Dcache_load_tag;

    // Port 1 (Store)
    ADDR        Dcache_addr_1;
    MEM_COMMAND Dcache_command_1;
    MEM_SIZE    Dcache_size_1;
    MEM_BLOCK   Dcache_store_data_1;
    logic       Dcache_req_1_accept;
    MEM_BLOCK   Dcache_data_out_1;   
    logic       Dcache_valid_out_1;

    // Snapshot Interface (Dummy)
    logic [DISPATCH_WIDTH-1:0] is_branch_i;
    logic                      snapshot_restore_valid_i;
    
    // Outputs ignored for functional test
    logic sq_checkpoint_valid_o, lq_checkpoint_valid_o;
    sq_entry_t sq_snap_o[SQ_SIZE-1:0];
    lq_entry_t lq_snap_o[LQ_SIZE-1:0];
    
    // Inputs tied to 0
    sq_entry_t sq_snap_i[SQ_SIZE-1:0];
    lq_entry_t lq_snap_i[LQ_SIZE-1:0];

    // ===============================================================
    // DUT Instantiation
    // ===============================================================
    lsq_top #(
        .DISPATCH_WIDTH(DISPATCH_WIDTH),
        .SQ_SIZE(SQ_SIZE),
        .LQ_SIZE(LQ_SIZE)
    ) dut (
        .clock(clock),
        .reset(reset),

        // Dispatch
        .dispatch_valid(dispatch_valid),
        .dispatch_is_store(dispatch_is_store),
        .dispatch_addr(dispatch_addr),
        .dispatch_size(dispatch_size),
        .dispatch_rob_idx(dispatch_rob_idx),
        .lsq_full(lsq_full),

        // Execution
        .sq_data_valid(sq_data_valid),
        .sq_data(sq_data),
        .sq_data_rob_idx(sq_data_rob_idx),

        // Commit
        .commit_valid(commit_valid),
        .commit_rob_idx(commit_rob_idx),

        // Writeback
        .wb_valid(wb_valid),
        .wb_rob_idx(wb_rob_idx),
        .wb_data(wb_data),

        // D-Cache Port 0
        .Dcache_addr_0(Dcache_addr_0),
        .Dcache_command_0(Dcache_command_0),
        .Dcache_size_0(Dcache_size_0),
        .Dcache_store_data_0(Dcache_store_data_0),
        .Dcache_req_tag(Dcache_req_tag),
        .Dcache_req_0_accept(Dcache_req_0_accept),
        .Dcache_data_out_0(Dcache_data_out_0),
        .Dcache_valid_out_0(Dcache_valid_out_0),
        .Dcache_load_tag(Dcache_load_tag),

        // D-Cache Port 1
        .Dcache_addr_1(Dcache_addr_1),
        .Dcache_command_1(Dcache_command_1),
        .Dcache_size_1(Dcache_size_1),
        .Dcache_store_data_1(Dcache_store_data_1),
        .Dcache_req_1_accept(Dcache_req_1_accept),
        .Dcache_data_out_1(Dcache_data_out_1),
        .Dcache_valid_out_1(Dcache_valid_out_1),

        // Snapshot
        .is_branch_i('0),
        .snapshot_restore_valid_i('0),
        .sq_snapshot_data_i(sq_snap_i),
        .sq_snapshot_head_i('0), .sq_snapshot_tail_i('0), .sq_snapshot_count_i('0),
        .lq_snapshot_data_i(lq_snap_i),
        .lq_snapshot_head_i('0), .lq_snapshot_tail_i('0), .lq_snapshot_count_i('0),
        .sq_checkpoint_valid_o(sq_checkpoint_valid_o),
        .lq_checkpoint_valid_o(lq_checkpoint_valid_o)
        // ... ignore other snapshot outputs
    );

    // ===============================================================
    // Clock Generation
    // ===============================================================
    always #5 clock = ~clock;

    // ===============================================================
    // Tasks
    // ===============================================================

    task sys_reset();
        $display("\n[TB] Resetting System...");
        reset = 1;
        dispatch_valid = 0;
        sq_data_valid = 0;
        commit_valid = 0;
        
        // Cache Defaults
        Dcache_req_0_accept = 0;
        Dcache_valid_out_0 = 0;
        Dcache_req_1_accept = 0;
        Dcache_valid_out_1 = 0;
        
        // Init dummy arrays
        for(int i=0; i<SQ_SIZE; i++) sq_snap_i[i] = '0;
        for(int i=0; i<LQ_SIZE; i++) lq_snap_i[i] = '0;

        repeat(2) @(posedge clock);
        reset = 0;
        @(posedge clock);
    endtask

    // Dispatch a LOAD
    task dispatch_load(input ADDR addr, input ROB_IDX rob);
        @(posedge clock);
        dispatch_valid = 1;
        dispatch_is_store = 0; // Load
        dispatch_addr = addr;
        dispatch_size = WORD;
        dispatch_rob_idx = rob;
        wait(!lsq_full);
        @(posedge clock);
        dispatch_valid = 0;
        $display("[TB] Dispatch LOAD: Addr=%h, ROB=%0d", addr, rob);
    endtask

    // Dispatch a STORE
    task dispatch_store(input ADDR addr, input ROB_IDX rob);
        @(posedge clock);
        dispatch_valid = 1;
        dispatch_is_store = 1; // Store
        dispatch_addr = addr;
        dispatch_size = WORD;
        dispatch_rob_idx = rob;
        wait(!lsq_full);
        @(posedge clock);
        dispatch_valid = 0;
        $display("[TB] Dispatch STORE: Addr=%h, ROB=%0d", addr, rob);
    endtask

    // Execute Stage: Send Data for a Store
    task exec_store_data(input ROB_IDX rob, input MEM_BLOCK data);
        @(posedge clock);
        sq_data_valid = 1;
        sq_data_rob_idx = rob;
        sq_data = data;
        @(posedge clock);
        sq_data_valid = 0;
        $display("[TB] Exec STORE Data: ROB=%0d, Data=%h", rob, data);
    endtask

    // Commit Stage: Notify LSQ that ROB entry is safe
    task rob_commit(input ROB_IDX rob);
        @(posedge clock);
        commit_valid = 1;
        commit_rob_idx = rob;
        @(posedge clock);
        commit_valid = 0;
        $display("[TB] ROB Commit: ROB=%0d", rob);
    endtask

    // ===============================================================
    // Main Test Sequence
    // ===============================================================
    logic [LQ_IDX_WIDTH-1:0] captured_tag;
    initial begin
        clock = 0;
        sys_reset();

        // -----------------------------------------------------------
        // TEST 1: Simple Load (Cache Miss then Hit)
        // -----------------------------------------------------------
        $display("\n=== TEST 1: Simple Load Flow ===");
        // 1. Dispatch Load (ROB #10) -> Address 0x1000
        dispatch_load(32'h1000, 10);

        // 2. Wait for LSQ to request Port 0
        wait(Dcache_command_0 == MEM_LOAD);
        captured_tag = Dcache_req_tag;
        $display("[TB] LSQ Requested Port 0: Addr=%h, Tag=%0d", Dcache_addr_0, captured_tag);

        // 3. Cache Accepts Request
        @(posedge clock);
        Dcache_req_0_accept = 1;
        @(posedge clock);
        Dcache_req_0_accept = 0;

        // 4. Cache Returns Data (After some delay)
        repeat(2) @(posedge clock);
        Dcache_valid_out_0 = 1;
        Dcache_data_out_0  = 32'hAAAA_1111;
        Dcache_load_tag    = captured_tag;
        $display("[TB] Cache Returning Data: %h (Tag %0d)", Dcache_data_out_0, captured_tag);
        @(posedge clock);
        Dcache_valid_out_0 = 0;

        // 5. Commit & Check Writeback
        // (Assuming LQ needs commit to retire, but Writeback might happen earlier depending on your logic)
        $display("[TB] WB_VALID: %b ", wb_valid);
        wait(wb_valid); 
        if(wb_data == 32'hAAAA_1111 && wb_rob_idx == 10) 
            $display("[PASS] Load Writeback Correct.");
        else 
            $display("[FAIL] Load Writeback Error. Data=%h", wb_data);

        // Retire from LQ (Free entry)
        rob_commit(10); 


        // -----------------------------------------------------------
        // TEST 2: Simple Store Flow
        // -----------------------------------------------------------
        $display("\n=== TEST 2: Simple Store Flow ===");
        // 1. Dispatch Store (ROB #20) -> Address 0x2000
        dispatch_store(32'h2000, 20);

        // 2. Data Calculation Finishes (Exec Stage)
        exec_store_data(20, 32'hBBBB_2222);

        // 3. ROB Commits the Store (Only now can it go to Cache)
        rob_commit(20);

        // 4. Check if LSQ requests Port 1 (Store Port)
        wait(Dcache_command_1 == MEM_STORE);
        if(Dcache_addr_1 == 32'h2000 && Dcache_store_data_1 == 32'hBBBB_2222)
            $display("[PASS] LSQ Sent Store to Port 1 Correctly.");
        else
            $display("[FAIL] Port 1 Req Error. Addr=%h, Data=%h", Dcache_addr_1, Dcache_store_data_1);

        // 5. Cache Accepts
        @(posedge clock);
        Dcache_req_1_accept = 1;
        @(posedge clock);
        Dcache_req_1_accept = 0;
        // Verify it stops requesting
        #1;
        if(Dcache_command_1 == MEM_NONE) $display("[PASS] SQ Request Cleared after Accept.");


        // -----------------------------------------------------------
        // TEST 3: Store-to-Load Forwarding (Critical)
        // -----------------------------------------------------------
        $display("\n=== TEST 3: Store-to-Load Forwarding ===");
        // 1. Dispatch Store (ROB #30) -> Addr 0x3000
        dispatch_store(32'h3000, 30);
        
        // 2. Dispatch Load (ROB #31) -> Addr 0x3000 (Same Addr!)
        dispatch_load(32'h3000, 31);

        // 3. Exec Store Data (0xCAFE_BABE)
        $display("[TB] Updating Store Data...");
        exec_store_data(30, 32'hCAFE_BABE);

        // 4. Monitor Port 0: 
        // Forwarding should happen internally, so Load should NOT go to Cache Port 0.
        // Or if it did request before data arrived, it should be ignored or overwritten.
        // Let's check WB directly.
        
        $display("[TB] Waiting for Load Writeback (from Forwarding)...");
        // We expect WB without sending a Load Request to Cache, 
        // OR if it sent one, we ignore it and Forwarding takes precedence.
        
        // Give it some cycles
        // repeat(5) @(posedge clock);

        // Since we didn't drive Dcache_req_0_accept, the LQ shouldn't have issued to cache yet.
        // It should pick up the forwarding data combinatorially.

        // Commit Load (ROB #31) to see if it has data
        
        // Check if WB happened correctly
        $display("[TB] wb_valid =%0b" , wb_valid);
        if (wb_valid && wb_data == 32'hCAFE_BABE)
            $display("[PASS] Forwarding Successful! WB Data: %h", wb_data);
        else begin
            // Depending on when wb_valid fires (immediate or at commit)
             @(posedge clock); // Check one more cycle
             if (wb_valid && wb_data == 32'hCAFE_BABE)
                $display("[PASS] Forwarding Successful (Delayed)!");
             else
                $display("[FAIL] Forwarding Failed. WB Data: %h", wb_data);
        end

        rob_commit(31);
        // Clean up Store
        rob_commit(30); // Commit store
        @(posedge clock); Dcache_req_1_accept = 1; @(posedge clock); Dcache_req_1_accept = 0; // Accept store


        // -----------------------------------------------------------
        // TEST 4: Dual Port Simultaneous Access
        // -----------------------------------------------------------
        $display("\n=== TEST 4: Dual Port Access ===");
        // Prepare: One committed store waiting, One new load dispatched
        
        // 1. Dispatch Store (ROB #40)
        dispatch_store(32'h4000, 40);
        exec_store_data(40, 32'hDDDD_4444);
        rob_commit(40); // Now SQ is ready to fire

        // 2. Dispatch Load (ROB #41) -> Addr 0x5000
        dispatch_load(32'h5000, 41);

        // 3. Wait for both ports to be active
        wait(Dcache_command_0 == MEM_LOAD && Dcache_command_1 == MEM_STORE);
        
        $display("[PASS] Simultaneous Request Detected!");
        $display("   Port 0 (Load): Addr=%h", Dcache_addr_0);
        $display("   Port 1 (Store): Addr=%h", Dcache_addr_1);

        // 4. Accept both
        @(posedge clock);
        Dcache_req_0_accept = 1;
        Dcache_req_1_accept = 1;
        @(posedge clock);
        Dcache_req_0_accept = 0;
        Dcache_req_1_accept = 0;

        $display("\n=== All Tests Completed ===");
        $finish;
    end

endmodule