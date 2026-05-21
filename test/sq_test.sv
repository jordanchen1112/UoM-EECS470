`include "sys_defs.svh"

module sq_tb;

  // Parameters
  parameter int DISPATCH_WIDTH = 1;
  parameter int SQ_SIZE = 8; // 縮小一點方便觀察 Full 狀態
  parameter int IDX_WIDTH = $clog2(SQ_SIZE);

  // Clock & Reset
  logic clock;
  logic reset;

  // Enqueue Interface
  logic       enq_valid;
  ADDR        enq_addr;
  MEM_SIZE    enq_size;
  ROB_IDX     enq_rob_idx;
  logic       full;

  // Data Update Interface
  logic       data_valid;
  MEM_BLOCK   data;
  ROB_IDX     data_rob_idx;

  // Forwarding Query Interface
  ADDR        load_addr;
  MEM_SIZE    load_size;
  logic       fwd_valid;
  MEM_BLOCK   fwd_data;
  ADDR        fwd_addr;
  logic       fwd_pending;

  // Commit Interface
  logic       commit_valid;
  ROB_IDX     commit_rob_idx;

  // D-Cache Interface
  logic       dc_req_valid;
  ADDR        dc_req_addr;
  MEM_SIZE    dc_req_size;
  MEM_COMMAND dc_req_cmd;
  MEM_BLOCK   dc_store_data;
  logic       dc_req_accept;

  // Snapshot Interface (Tied to 0 for basic testing)
  logic [DISPATCH_WIDTH-1:0] is_branch_i;
  logic                      snapshot_restore_valid_i;
  logic                      checkpoint_valid_o;
  
  // Snapshot Dummy Connections
  sq_entry_t                 snapshot_data_o[SQ_SIZE-1:0];
  logic [IDX_WIDTH-1 : 0]    snapshot_head_o, snapshot_tail_o;
  logic [$clog2(SQ_SIZE+1)-1:0] snapshot_count_o;
  sq_entry_t                 snapshot_data_i[SQ_SIZE-1:0];
  logic [IDX_WIDTH-1 : 0]    snapshot_head_i, snapshot_tail_i;
  logic [$clog2(SQ_SIZE+1)-1:0] snapshot_count_i;

  // ===============================================================
  // DUT Instantiation
  // ===============================================================
  sq #(
    .DISPATCH_WIDTH(DISPATCH_WIDTH),
    .SQ_SIZE(SQ_SIZE)
  ) dut (
    .clock(clock),
    .reset(reset),
    
    .enq_valid(enq_valid),
    .enq_addr(enq_addr),
    .enq_size(enq_size),
    .enq_rob_idx(enq_rob_idx),
    .full(full),

    .data_valid(data_valid),
    .data(data),
    .data_rob_idx(data_rob_idx),

    .load_addr(load_addr),
    .load_size(load_size),
    .fwd_valid(fwd_valid),
    .fwd_data(fwd_data),
    .fwd_addr(fwd_addr),
    .fwd_pending(fwd_pending),

    .commit_valid(commit_valid),
    .commit_rob_idx(commit_rob_idx),

    .dc_req_valid(dc_req_valid),
    .dc_req_addr(dc_req_addr),
    .dc_req_size(dc_req_size),
    .dc_req_cmd(dc_req_cmd),
    .dc_store_data(dc_store_data),
    .dc_req_accept(dc_req_accept),

    // Snapshot connections (Zeros)
    .is_branch_i('0),
    .snapshot_restore_valid_i('0),
    .checkpoint_valid_o(checkpoint_valid_o),
    .snapshot_data_o(snapshot_data_o),
    .snapshot_head_o(snapshot_head_o),
    .snapshot_tail_o(snapshot_tail_o),
    .snapshot_count_o(snapshot_count_o),
    .snapshot_data_i(snapshot_data_i), // Inputs tied to struct zero
    .snapshot_head_i('0),
    .snapshot_tail_i('0),
    .snapshot_count_i('0)
  );

  // ===============================================================
  // Clock Generation
  // ===============================================================
  always #5 clock = ~clock;

  // ===============================================================
  // Test Tasks
  // ===============================================================
  
  // Task: Reset System
  task sys_reset();
    $display("[TB] Resetting System...");
    reset = 1;
    enq_valid = 0;
    data_valid = 0;
    commit_valid = 0;
    dc_req_accept = 0;
    load_addr = 0;
    load_size = WORD;
    // Init snapshot inputs to 0
    for(int i=0; i<SQ_SIZE; i++) begin
        snapshot_data_i[i].valid = 0;
        // ... fill other fields if needed
    end
    @(posedge clock);
    @(posedge clock);
    reset = 0;
    @(posedge clock);
    $display("[TB] Reset Complete.");
  endtask

  // Task: Dispatch a Store
  task dispatch_store(input ADDR addr, input ROB_IDX rob_idx);
    @(posedge clock);
    enq_valid = 1;
    enq_addr = addr;
    enq_size = WORD;
    enq_rob_idx = rob_idx;
    wait(!full); // Wait if full
    @(posedge clock);
    enq_valid = 0;
    $display("[TB] Dispatched Store: Addr=%h, ROB#=%0d", addr, rob_idx);
  endtask

  // Task: Provide Data for a Store
  task update_store_data(input ROB_IDX rob_idx, input MEM_BLOCK wr_data);
    @(posedge clock);
    data_valid = 1;
    data_rob_idx = rob_idx;
    data = wr_data;
    @(posedge clock);
    data_valid = 0;
    $display("[TB] Data Update: ROB#=%0d, Data=%h", rob_idx, wr_data);
  endtask

  // Task: Commit a Store
  task commit_store(input ROB_IDX rob_idx);
    @(posedge clock);
    commit_valid = 1;
    commit_rob_idx = rob_idx;
    @(posedge clock);
    commit_valid = 0;
    $display("[TB] Committed ROB#=%0d", rob_idx);
  endtask

  // ===============================================================
  // Main Test Sequence
  // ===============================================================
  initial begin
    clock = 0;
    sys_reset();

    // -----------------------------------------------------------
    // TEST 1: Basic Enqueue -> Data -> Commit -> Retire to D-Cache
    // -----------------------------------------------------------
    $display("\n=== TEST 1: Basic Flow ===");
    dispatch_store(32'h1000, 1); // ROB #1
    update_store_data(1, 32'hDEAD_BEEF);
    
    // Check Forwarding Hit
    #1; // Wait for comb logic
    load_addr = 32'h1000; load_size = WORD;
    #1;
    if (fwd_valid && fwd_data == 32'hDEAD_BEEF) 
        $display("[PASS] Forwarding Hit detected correctly.");
    else 
        $display("[FAIL] Forwarding Hit Failed. Valid=%b, Data=%h", fwd_valid, fwd_data);

    // Commit
    commit_store(1);

    // Verify D-Cache Request
    wait(dc_req_valid); 
    if (dc_req_addr == 32'h1000 && dc_store_data == 32'hDEAD_BEEF)
        $display("[PASS] D-Cache Request Correct.");
    else
        $display("[FAIL] D-Cache Req: Addr=%h, Data=%h", dc_req_addr, dc_store_data);

    // Accept request
    @(posedge clock);
    dc_req_accept = 1;
    @(posedge clock);
    dc_req_accept = 0;
    
    // -----------------------------------------------------------
    // TEST 2: Forwarding Priority (Youngest Older Store)
    // -----------------------------------------------------------
    $display("\n=== TEST 2: Forwarding Priority ===");
    // Store A: Addr 0x2000, Data 0xA (Older)
    dispatch_store(32'h2000, 2); 
    update_store_data(2, 32'hAAAA_AAAA);
    
    // Store B: Addr 0x2000, Data 0xB (Younger) -> Should overlap Store A
    dispatch_store(32'h2000, 3);
    update_store_data(3, 32'hBBBB_BBBB);

    #1;
    load_addr = 32'h2000;
    #1;
    if (fwd_valid && fwd_data == 32'hBBBB_BBBB)
        $display("[PASS] Forwarding picked Youngest Store (0xB).");
    else
        $display("[FAIL] Forwarding Priority Wrong. Got %h", fwd_data);

    // -----------------------------------------------------------
    // TEST 3: Forwarding Pending (Address match, Data not ready)
    // -----------------------------------------------------------
    $display("\n=== TEST 3: Forwarding Pending ===");
    dispatch_store(32'h3000, 4); // No data update yet
    
    #1;
    load_addr = 32'h3000;
    #1;
    if (!fwd_valid && fwd_pending)
        $display("[PASS] Forwarding Pending detected.");
    else
        $display("[FAIL] Pending check failed. Valid=%b, Pending=%b", fwd_valid, fwd_pending);

    // Now update data
    update_store_data(4, 32'hCAFE_BABE);
    #1;
    if (fwd_valid && !fwd_pending && fwd_data == 32'hCAFE_BABE)
        $display("[PASS] Data arrived, Forwarding valid now.");
    else
        $display("[FAIL] Forwarding update failed.");

    // -----------------------------------------------------------
    // TEST 4: Full Signal & Wraparound
    // -----------------------------------------------------------
    $display("\n=== TEST 4: Full Signal ===");
    sys_reset();
    
    // Fill the queue (Size is 8)
    for(int i=0; i<8; i++) begin
        dispatch_store(32'h4000 + i*4, i+10);
    end
    
    @(posedge clock);
    if (full) $display("[PASS] Queue is Full.");
    else $display("[FAIL] Queue should be full. Count=%0d", snapshot_count_o);

    // Try to enqueue one more (Should not move tail pointer if logic protects it, 
    // but your RTL relies on !full check outside or inside. 
    // Your RTL: if (enq_valid && !full) -> Good protection)
    enq_valid = 1;
    enq_rob_idx = 99;
    @(posedge clock);
    enq_valid = 0;

    // Drain one item
    update_store_data(10, 32'h0); // Data for head
    commit_store(10); // Commit head
    
    // Enable accept to pop head
    dc_req_accept = 1;
    wait(dc_req_valid);
    @(posedge clock);
    dc_req_accept = 0; // Pop happens here

    #1;
    if (!full) $display("[PASS] Queue not full after pop.");
    else $display("[FAIL] Queue still full.");

    $display("\n=== All Tests Completed ===");
    $finish;
  end

endmodule