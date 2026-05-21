`timescale 1ns/1ps

  // =====================================================
  // 兩個問題
  // (1) Mispredict那條指令可以Commit or not => 暫時先讓SIM Module跟dut一樣
  // (2) TestBench Dispatch覆蓋掉原先的ROB(未COMMIT) 會拿到原先的指令
  // =====================================================

module tb_rob_only;

  logic start_sim;

  // Parameters match ROB
  localparam int DEPTH          = 64;
  localparam int INST_W         = 16;
  localparam int DISPATCH_WIDTH = 2;
  localparam int COMMIT_WIDTH   = 2;
  localparam int WB_WIDTH       = 4;
  localparam int ARCH_REGS      = 64;
  localparam int PHYS_REGS      = 128;
  localparam int XLEN           = 64;

  // Clock/reset
  logic clk, reset;

  // DUT I/O
  logic [DISPATCH_WIDTH-1:0] disp_valid_i, disp_rd_wen_i;
  logic [DISPATCH_WIDTH-1:0][$clog2(ARCH_REGS)-1:0] disp_rd_arch_i;
  logic [DISPATCH_WIDTH-1:0][$clog2(PHYS_REGS)-1:0] disp_rd_new_prf_i;
  logic [DISPATCH_WIDTH-1:0][$clog2(PHYS_REGS)-1:0] disp_rd_old_prf_i;
  logic [DISPATCH_WIDTH-1:0] disp_ready_o, disp_alloc_o;
  logic [DISPATCH_WIDTH-1:0][$clog2(DEPTH)-1:0] disp_rob_idx_o;

  logic [WB_WIDTH-1:0] wb_valid_i, wb_exception_i, wb_mispred_i;
  logic [WB_WIDTH-1:0][$clog2(DEPTH)-1:0] wb_rob_idx_i;

  logic [COMMIT_WIDTH-1:0] commit_valid_o, commit_rd_wen_o;
  logic [COMMIT_WIDTH-1:0][$clog2(ARCH_REGS)-1:0] commit_rd_arch_o;
  logic [COMMIT_WIDTH-1:0][$clog2(PHYS_REGS)-1:0] commit_new_prf_o;
  logic [COMMIT_WIDTH-1:0][$clog2(PHYS_REGS)-1:0] commit_old_prf_o;

  logic flush_o;
  logic [$clog2(DEPTH)-1:0] flush_upto_rob_idx_o;

  // Instantiate ROB
  rob #(
    .DEPTH(DEPTH), .INST_W(INST_W),
    .DISPATCH_WIDTH(DISPATCH_WIDTH), .COMMIT_WIDTH(COMMIT_WIDTH),
    .WB_WIDTH(WB_WIDTH), .ARCH_REGS(ARCH_REGS),
    .PHYS_REGS(PHYS_REGS), .XLEN(XLEN)
  ) dut (
    .clock(clk), .reset(reset),
    .disp_valid_i(disp_valid_i), .disp_rd_wen_i(disp_rd_wen_i),
    .disp_rd_arch_i(disp_rd_arch_i),
    .disp_rd_new_prf_i(disp_rd_new_prf_i),
    .disp_rd_old_prf_i(disp_rd_old_prf_i),
    .disp_ready_o(disp_ready_o), .disp_alloc_o(disp_alloc_o),
    .disp_rob_idx_o(disp_rob_idx_o),
    .wb_valid_i(wb_valid_i), .wb_rob_idx_i(wb_rob_idx_i),
    .wb_exception_i(wb_exception_i), .wb_mispred_i(wb_mispred_i),
    .commit_valid_o(commit_valid_o), .commit_rd_wen_o(commit_rd_wen_o),
    .commit_rd_arch_o(commit_rd_arch_o),
    .commit_new_prf_o(commit_new_prf_o),
    .commit_old_prf_o(commit_old_prf_o),
    .flush_o(flush_o), .flush_upto_rob_idx_o(flush_upto_rob_idx_o)
  );

  // =====================================================
  // Commit trace buffers
  // =====================================================
  typedef struct packed {
    int arch;
    int newp;
    int oldp;
  } commit_info_t;

  
  commit_info_t ref_group[COMMIT_WIDTH];
  commit_info_t dut_group[COMMIT_WIDTH];
  commit_info_t dut_commit_q[$][COMMIT_WIDTH];  
  commit_info_t ref_commit_q[$][COMMIT_WIDTH];
  

  // =====================================================
  // ROB SIM
  // =====================================================
  typedef struct packed {
        int valid;
        int ready;
        int rd_wen;
        int rd_arch;
        int new_prf;
        int old_prf;
        int exception;
        int mispred;
    } rob_entry_t;

  rob_entry_t ref_rob[DEPTH];
  int head, tail; 
  int num_entries;

  task ref_reset();
    for (int i=0; i<DEPTH; i++) begin
      ref_rob[i].valid = 0;
      ref_rob[i].ready = 0;
    end
    head = 0; 
    tail = 0; 
    num_entries = 0;
  endtask

  task ref_dispatch(input int rd_wen, rd_arch, new_prf, old_prf);
    ref_rob[tail] = '{valid:1, ready:0, rd_wen:rd_wen, rd_arch:rd_arch, new_prf:new_prf, old_prf:old_prf,
                      exception:0, mispred:0};
    $display("dispatch: %p, rob = %d, head = %p, tail = %p", ref_rob[tail], tail, head, (tail + 1) % DEPTH);
    tail = (tail + 1) % DEPTH;
    num_entries++;
  endtask

  task ref_wb(input int rob_idx, exception, mispred);
    if (ref_rob[rob_idx].valid) begin
      ref_rob[rob_idx].ready = 1;
      ref_rob[rob_idx].exception = exception;
      ref_rob[rob_idx].mispred = mispred;
    end
    $display("write back: %p, rob =%d, head = %p, tail = %p", ref_rob[rob_idx],rob_idx, head, tail);
  endtask

  task ref_flush(input int upto_idx);
    $display("[%0t] REF_FLUSH: tail→head (%0d→%0d)", $time, tail, upto_idx);
    while (tail != upto_idx) begin
      tail = (tail - 1 + DEPTH) % DEPTH;
      ref_rob[tail].valid = 0;
      ref_rob[tail].ready = 0;
      ref_rob[tail].exception = 0;
      ref_rob[tail].mispred = 0;
      num_entries--;
    end
    head = tail;
    $display("head = %p, tail = %p", head, tail); 
  endtask

  task automatic ref_try_commit(output int num_committed,
                      output int archs [COMMIT_WIDTH], new_prfs [COMMIT_WIDTH], old_prfs [COMMIT_WIDTH]);
    int commit_group_n = 0; //to store in the commit group (index)
    int flush = 0;
    num_committed = 0;
    // RESET ref group
    for (int c = 0; c < COMMIT_WIDTH; c++) begin
      ref_group[c].arch = 0;
      ref_group[c].newp = 0;
      ref_group[c].oldp = 0;
    end

    // Start commit process
    for (int i = 0; i < COMMIT_WIDTH; i++) begin //automatic prevents i error
      int idx = (head + i) % DEPTH;

      if (num_entries == 0 || !ref_rob[idx].valid || !ref_rob[idx].ready) break;
      
      archs[num_committed]    = ref_rob[idx].rd_arch;
      new_prfs[num_committed] = ref_rob[idx].new_prf;
      old_prfs[num_committed] = ref_rob[idx].old_prf;
      ref_rob[idx].valid = 0;
      num_committed++;

      // STORE commit data in the same cycle as group
      ref_group[commit_group_n].arch = ref_rob[idx].rd_arch;
      ref_group[commit_group_n].newp = ref_rob[idx].new_prf;
      ref_group[commit_group_n].oldp = ref_rob[idx].old_prf;
      commit_group_n++;
      // If mispredict -> flush
      if (ref_rob[idx].mispred) begin
        ref_flush(idx);
        flush = 1;
        //break;
      end
      //DISPLAY
      if (num_committed != 0) begin
        $display("Commit ROB= %p, archs= %p, new_prf = %p, old_prf = %p", idx, archs, new_prfs, old_prfs);
      end
    end

    // STORE commit group to queue
    if (commit_group_n > 0) begin
        ref_commit_q.push_back(ref_group);
        $display("head = %p, tail = %p", head + num_committed, tail);
    end
    head = (flush) ? tail:(head + num_committed) % DEPTH;
    num_entries -= num_committed;
     
    
  endtask

  always @(posedge clk) begin
    if (!reset && start_sim) begin
      int ref_n;
      int ref_arch [COMMIT_WIDTH];
      int ref_new  [COMMIT_WIDTH];
      int ref_old  [COMMIT_WIDTH];

      ref_try_commit(ref_n, ref_arch, ref_new, ref_old);
    end
  end

  // Clock
  always #5 clk = ~clk;

  // Reset
  initial begin
    clk = 0; reset = 1;
    repeat (3) @(negedge clk);
    reset = 0;
    // ROB_SIM
    ref_reset();
  end
  
  // Stimulus: multiple dispatch/writeback/flush tests
  int total_dispatched, prf_counter, ridx;
  initial begin
    // === init ===
    int correct = 1;
    start_sim = 0;
    disp_valid_i = '0; disp_rd_wen_i = '0;
    wb_valid_i   = '0; wb_exception_i = '0; wb_mispred_i = '0;
    // ROB_SIM
    ref_reset();

    @(negedge reset);
    @(negedge clk); // wait reset end

    
    // =====================================================
    // [Phase 1] Dispatch a ins -> commit
    // =====================================================
    $display("\n=== Phase 1: Single Dispatch/Commit ===");
    start_sim = 1;
    @(negedge clk);
    disp_valid_i[0]      = 1;
    disp_rd_wen_i[0]     = 1;
    disp_rd_arch_i[0]    = 5'd1;
    disp_rd_new_prf_i[0] = 7'd10;
    disp_rd_old_prf_i[0] = 7'd2;
    // ROB_SIM 
    ref_dispatch(1, 1, 10, 2); //rd_wen, rd_arch, new_prf, old_prf
    

    @(negedge clk);
    disp_valid_i = '0;

    // Writeback (ROB idx 0)
    @(negedge clk);
    wb_valid_i[0]   = 1;
    wb_rob_idx_i[0] = 0;
    // ROB_SIM
    ref_wb(0, 0, 0); //rob_idx
    
    @(negedge clk);
    wb_valid_i = '0;

    repeat (5) @(negedge clk);

    // =====================================================
    // [Phase 2] dispatch two ways, writeback one way
    // =====================================================
    $display("\n=== Phase 2: Dual Dispatch, Staggered WB ===");
    @(negedge clk);
    disp_valid_i      = 2'b11;
    disp_rd_wen_i     = 2'b11;
    disp_rd_arch_i[0] = 5'd3;  disp_rd_new_prf_i[0] = 7'd11;  disp_rd_old_prf_i[0] = 7'd5;
    disp_rd_arch_i[1] = 5'd4;  disp_rd_new_prf_i[1] = 7'd12;  disp_rd_old_prf_i[1] = 7'd6;
    ref_dispatch(1, 3, 11, 5);
    ref_dispatch(1, 4, 12, 6);

    @(negedge clk);
    disp_valid_i = '0;

    // Writeback second（ROB idx 1）
    @(negedge clk);
    wb_valid_i[0]   = 1;
    wb_rob_idx_i[0] = 2;
    ref_wb(2, 0, 0);

    @(negedge clk);
    wb_valid_i = '0;

    // writeback first（ROB idx 2）
    repeat (3) @(negedge clk);
    wb_valid_i[1]   = 1;
    wb_rob_idx_i[1] = 1;
    ref_wb(1,0,0);

    @(negedge clk);
    wb_valid_i = '0;

    repeat (6) @(negedge clk);

    // =====================================================
    // [Phase 3] test mispredict -> flush
    // =====================================================
    $display("\n=== Phase 3: Mispredict Flush Test ===");
    @(negedge clk);
    disp_valid_i[0]      = 1;
    disp_rd_wen_i[0]     = 1;
    disp_rd_arch_i[0]    = 5'd7;
    disp_rd_new_prf_i[0] = 7'd13;
    disp_rd_old_prf_i[0] = 7'd8;
    ref_dispatch(1, 7, 13, 8);

    @(negedge clk);
    disp_valid_i = '0;

    // Writeback, mispred (ROB idx 3)
    @(negedge clk);
    wb_valid_i[0]   = 1;
    wb_rob_idx_i[0] = 3;
    wb_mispred_i[0] = 1;  // flush
    ref_wb(3, 0, 1);

    @(negedge clk);
    wb_valid_i = '0; wb_mispred_i = '0;

    repeat (5) @(negedge clk);

    // =====================================================
    // [Phase 4] dispatch after flush
    // =====================================================
    $display("\n=== Phase 4: Post-Flush Dispatch ===");
    @(negedge clk);
    disp_valid_i[0]      = 1;
    disp_rd_wen_i[0]     = 1;
    disp_rd_arch_i[0]    = 5'd9;
    disp_rd_new_prf_i[0] = 7'd14;
    disp_rd_old_prf_i[0] = 7'd4;
    ref_dispatch(1, 9, 14, 4);

    @(negedge clk);
    disp_valid_i = '0;

    // Writeback + Commit (ROB idx 4)
    @(negedge clk);
    wb_valid_i[0]   = 1;
    wb_rob_idx_i[0] = 4; //應該要是rob 3?
    ref_wb(3, 0, 0);

    @(negedge clk);
    wb_valid_i = '0;

    repeat (5) @(negedge clk);

    // =====================================================
    // [Phase 5] Commit two ins at the same time
    // =====================================================

    //應該要有兩個commit?? (跑到phase6)
    $display("\n=== Phase 5: test Commit two ins at the same time ===");

    @(negedge clk);
    // Dispatch
    disp_valid_i      = 2'b11;
    disp_rd_wen_i     = 2'b11;
    disp_rd_arch_i[0] = 5'd10; disp_rd_new_prf_i[0] = 7'd15; disp_rd_old_prf_i[0] = 7'd3;
    disp_rd_arch_i[1] = 5'd11; disp_rd_new_prf_i[1] = 7'd16; disp_rd_old_prf_i[1] = 7'd4;
    ref_dispatch(1,10,15,3);
    ref_dispatch(1,11,16,4);
    
    @(negedge clk);
    disp_valid_i = '0;

    // writeback two ins
    @(negedge clk);
    wb_valid_i = 4'b0011;
    wb_rob_idx_i[0] = 5; //4?
    wb_rob_idx_i[1] = 6; //5?
    ref_wb(4,0,0);
    ref_wb(5,0,0);
    @(negedge clk);
    
    wb_valid_i = '0;
    @(negedge clk);
    // =====================================================
    // [Phase 6] Dispatch until ROB is full
    // =====================================================
    // 這裡dispatch超過rob數量 

    $display("\n=== Phase 6: Dispatch until ROB is full ===");
    total_dispatched = 0;
    prf_counter = 20;
    while(total_dispatched < 100) begin

      //full就停止diaptch 但還是多dispatch兩個
      if (disp_ready_o[0] === 0 && disp_ready_o[1] === 0) begin
        $display("[%0t] ROB full (DUT and REF) — stop dispatching", $time);
        disp_valid_i = '0;
        break;
      end

      @(negedge clk);
      for (int i = 0; i < DISPATCH_WIDTH; i++) begin
        disp_valid_i[i]      = 1;
        disp_rd_wen_i[i]     = 1;
        disp_rd_arch_i[i]    = (total_dispatched + 12) % ARCH_REGS;
        disp_rd_new_prf_i[i] = prf_counter + 10;
        disp_rd_old_prf_i[i] = prf_counter;
        total_dispatched++;
        prf_counter++;
        ref_dispatch(1,disp_rd_arch_i[i],disp_rd_new_prf_i[i],disp_rd_old_prf_i[i]);
      end
    end
    disp_valid_i = 0;
    @(negedge clk);

    // =====================================================
    // [Phase 7] WB from back
    // =====================================================
    $display("\n=== Phase 7: WB from back ===");
    for (ridx = DEPTH-1; ridx >= 0; ridx--) begin
      @(negedge clk);
      $display("ridx = %0d, DEPTH = %0d ", ridx, DEPTH);
      wb_valid_i      = 4'b0011;
      wb_rob_idx_i[0] = ridx;
      if(ridx == DEPTH - 11) begin
        wb_mispred_i[0] = 1;
        ref_wb(wb_rob_idx_i[0],0, 1);
        $display("%0d is mispred", ridx);
      end else begin
        wb_mispred_i[0] = 0;
        ref_wb(wb_rob_idx_i[0],0, 0);
      end
      wb_rob_idx_i[1] = (ridx > 0) ? ridx-1 : ridx;
      ref_wb(wb_rob_idx_i[1],0, 0);
      $display("   ");
      //$display("[%0t] WB two entries: ROB[%0d] and ROB[%0d]", 
      //        $time, wb_rob_idx_i[0], wb_rob_idx_i[1]);
      ridx--;
    end

    @(negedge clk);
    wb_valid_i = '0;
    $display("\n=== Phase 7 Complete: Reverse writeback finished ===");

    // =====================================================
    // [Phase 8] Alternating mispredict/exception flush
    // =====================================================
    /*
    $display("\n=== Phase 8: Alternating mispredict/exception flush ===");
    for (int i = 0; i < 12; i++) begin
      @(negedge clk);
      disp_valid_i = 2'b11;
      for (int k = 0; k < DISPATCH_WIDTH; k++) begin
        disp_rd_arch_i[k] = (i+k) % ARCH_REGS;
        disp_rd_new_prf_i[k] = (50 + i + k) % PHYS_REGS;
        disp_rd_old_prf_i[k] = (70 + i + k) % PHYS_REGS;
      end

      if (i % 3 == 1) begin
        wb_valid_i[0]   = 1;
        wb_rob_idx_i[0] = i % DEPTH;
        wb_mispred_i[0] = 1;
      end else if (i % 3 == 2) begin
        wb_valid_i[1]   = 1;
        wb_rob_idx_i[1] = (i-1) % DEPTH;
        wb_exception_i[1] = 1;
      end else begin
        wb_valid_i = '0; wb_mispred_i = '0; wb_exception_i = '0;
      end
    end
    wb_valid_i = '0; wb_mispred_i = '0; wb_exception_i = '0;
      */
        repeat (40) @(negedge clk);
        repeat (8) @(negedge clk);

      // =====================================================
      // Comparing Ground Truth and DUT result
      // =====================================================
      $display("START COMAPRE");
      for (int g = 0; g < ref_commit_q.size(); g++) begin
        int ref_group_size = $size(ref_commit_q[g]);
        int dut_group_size = $size(dut_commit_q[g]);
        
        for (int e = 0; e < ref_group_size; e++) begin
          if (ref_commit_q[g][e].arch !== dut_commit_q[g][e].arch ||
              ref_commit_q[g][e].newp !== dut_commit_q[g][e].newp ||
              ref_commit_q[g][e].oldp !== dut_commit_q[g][e].oldp) begin
            correct = 0;
            $display("❌ [Group %0d, Entry %0d] mismatch:", g, e);
            $display("    REF = arch=%0d newp=%0d oldp=%0d",
                    ref_commit_q[g][e].arch, ref_commit_q[g][e].newp, ref_commit_q[g][e].oldp);
            $display("    DUT = arch=%0d newp=%0d oldp=%0d",
                    dut_commit_q[g][e].arch, dut_commit_q[g][e].newp, dut_commit_q[g][e].oldp);
          end else begin
            $display("✅ [Group %0d, Entry %0d] mismatch:", g, e);
            $display("    REF = arch=%0d newp=%0d oldp=%0d",
                ref_commit_q[g][e].arch, ref_commit_q[g][e].newp, ref_commit_q[g][e].oldp);
            $display("    DUT = arch=%0d newp=%0d oldp=%0d",
                dut_commit_q[g][e].arch, dut_commit_q[g][e].newp, dut_commit_q[g][e].oldp);
          end
        end
      end
      if (correct) $display("✅@@@PASS");


        $display("commit: %p", ref_commit_q);
        $display("   ");
        $display("commit: %p", dut_commit_q);
        $display("\n=== 8 Simulation Finished ===");
        $finish;

      end

    always @(negedge clk) begin
      if(start_sim) begin
        bit has_commit = 0;
        // reset dut_group
        for (int c = 0; c < COMMIT_WIDTH; c++) begin
          dut_group[c].arch = 0;
          dut_group[c].newp = 0;
          dut_group[c].oldp = 0;
        end

        for(int i = 0; i < COMMIT_WIDTH; i++) begin
          if (commit_valid_o[i]) begin
            has_commit = 1;
            $display("[%0t] Commit %0d: arch=%0d new=%0d old=%0d",
                    $time, i,commit_rd_arch_o[i] ,
                    commit_new_prf_o[i], commit_old_prf_o[i]);
                    
            // save to dut_group 
            dut_group[i].arch = commit_rd_arch_o[i];
            dut_group[i].newp = commit_new_prf_o[i];
            dut_group[i].oldp = commit_old_prf_o[i];
          end
        end
        if(has_commit) begin    // push to dut queue
          //$display("dut group: %p", dut_group);
          dut_commit_q.push_back(dut_group);
          has_commit = 0;
        end

        if (|commit_valid_o)
          $display("commit num: %0d", $countones(commit_valid_o));

        if (flush_o)
          $display("[%0t] Flush up to ROB idx %0d", $time, flush_upto_rob_idx_o);
      end

    end
  



endmodule
