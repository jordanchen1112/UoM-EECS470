`include "sys_defs.svh"

module dcache_tb;

  // ---------------------------
  // clock / reset
  // ---------------------------
  logic clock, reset;

  initial begin
    clock = 0;
    forever #5 clock = ~clock;  // 10ns period
  end

  initial begin
    reset = 1;
    repeat (5) @(posedge clock);
    reset = 0;
  end

  ADDR      test_addr, test_add2;
  ADDR      addr0, addr1;
  MEM_BLOCK expect_block;

  // ---------------------------
  // dcache <-> cpu 端信號
  // ---------------------------
  ADDR        Dcache_addr_0;
  MEM_COMMAND Dcache_command_0;
  MEM_SIZE    Dcache_size_0;
  MEM_BLOCK   Dcache_store_data_0;
  logic       Dcache_req_0_accept;
  MEM_BLOCK   Dcache_data_out_0;
  logic       Dcache_valid_out_0;

  ADDR        Dcache_addr_1;
  MEM_COMMAND Dcache_command_1;
  MEM_SIZE    Dcache_size_1;
  MEM_BLOCK   Dcache_store_data_1;
  logic       Dcache_req_1_accept;
  MEM_BLOCK   Dcache_data_out_1;
  logic       Dcache_valid_out_1;

  // ---------------------------
  // dcache <-> mem 端信號
  // ---------------------------
  MEM_COMMAND Dcache2mem_command;
  ADDR        Dcache2mem_addr;
  MEM_SIZE    Dcache2mem_size;
  MEM_BLOCK   Dcache2mem_data;
  logic       Dcache2mem_valid;

  MEM_TAG     mem2proc_transaction_tag;
  MEM_BLOCK   mem2proc_data;
  MEM_TAG     mem2proc_data_tag;

  // ---------------------------
  // 真正 memory module 的介面
  // ---------------------------
  MEM_COMMAND debug_proc2mem_command;  // 你貼的 memory 用的是這個名字
  ADDR        proc2mem_addr;
  MEM_BLOCK   proc2mem_data;
// `ifndef CACHE_MODE
  MEM_SIZE    proc2mem_size;
// `endif

  // dcache outputs 接到 mem inputs
  assign debug_proc2mem_command = Dcache2mem_command;
  assign proc2mem_addr          = Dcache2mem_addr;
  assign proc2mem_data          = Dcache2mem_data;
// `ifndef CACHE_MODE
  assign proc2mem_size          = Dcache2mem_size;
// `endif

  // ---------------------------
  // instantiate dcache (DUT)
  // ---------------------------
  dcache dut (
    .clock(clock),
    .reset(reset),

    .Dcache_addr_0(Dcache_addr_0),
    .Dcache_command_0(Dcache_command_0),
    .Dcache_size_0(Dcache_size_0),
    .Dcache_store_data_0(Dcache_store_data_0),
    .Dcache_req_0_accept(Dcache_req_0_accept),
    .Dcache_data_out_0(Dcache_data_out_0),
    .Dcache_valid_out_0(Dcache_valid_out_0),

    .Dcache_addr_1(Dcache_addr_1),
    .Dcache_command_1(Dcache_command_1),
    .Dcache_size_1(Dcache_size_1),
    .Dcache_store_data_1(Dcache_store_data_1),
    .Dcache_req_1_accept(Dcache_req_1_accept),
    .Dcache_data_out_1(Dcache_data_out_1),
    .Dcache_valid_out_1(Dcache_valid_out_1),

    .Dcache2mem_command(Dcache2mem_command),
    .Dcache2mem_addr(Dcache2mem_addr),
    .Dcache2mem_size(Dcache2mem_size),
    .Dcache2mem_data(Dcache2mem_data),
    .Dcache2mem_valid(Dcache2mem_valid),

    .mem2proc_transaction_tag(mem2proc_transaction_tag),
    .mem2proc_data(mem2proc_data),
    .mem2proc_data_tag(mem2proc_data_tag)
  );

  // ---------------------------
  // instantiate mem module
  // 你貼的那段
  // ---------------------------
  mem memory (
    .clock            (clock),
    .proc2mem_command (debug_proc2mem_command),
    .proc2mem_addr    (proc2mem_addr),
    .proc2mem_data    (proc2mem_data),
// `ifndef CACHE_MODE
    .proc2mem_size    (proc2mem_size),
// `endif
    .mem2proc_transaction_tag (mem2proc_transaction_tag),
    .mem2proc_data            (mem2proc_data),
    .mem2proc_data_tag        (mem2proc_data_tag)
  );

 task automatic show_status(); 
 $display("-------------------------------------------------------------------");
  $display("req_to_bank=[%b%b%b%b]", dut.req_0_to_bank_0,dut.req_0_to_bank_1,dut.req_1_to_bank_0,dut.req_1_to_bank_1 );
  
  $write("way_hit_0= ");
  for (int w = 0; w < dut.CACHE_WAYS; w++) begin
    $write("%b", dut.way_hit_0[w]);
  end
  $display(" ");
  $write("way_hit_1= ");
  for (int w = 0; w < dut.CACHE_WAYS; w++) begin
    $write("%b", dut.way_hit_1[w]);
  end
  $display(" ");
  $display("send_new_mem_req=%b |free_mshr_idx=%0d |pending_mshr_id=%d | pending_req_to_mem=%b", dut.send_new_mem_req,dut.free_mshr_idx,dut.pending_mshr_id,dut.pending_req_to_mem);

  for (int i = 0; i < dut.MSHR_SIZE; i++) begin
    if (dut.mshr[i].valid) begin
      $display("mashr[%0d] mem tag = %d", i, dut.mshr[i].mem_tag);
    end
  end

  $display("memory response: tag=%d | data=%d | data_tag =%d",mem2proc_transaction_tag,mem2proc_data,mem2proc_data_tag );
   $display("Dcache_command_0 = %p Accept0=[%0b%0b%0b] valid0=%0d dat0=%h | Dcache_command_1 = %p accept1=%0d valid1=%0d dat1=%h",
             dut.Dcache_command_0, Dcache_req_0_accept,dut.req_0_accept, dut.mshr_hit_0, Dcache_valid_out_0, Dcache_data_out_0.dbbl_level, dut.Dcache_command_1, Dcache_req_1_accept, Dcache_valid_out_1, Dcache_data_out_1.dbbl_level);
 $display("-------------------------------------------------------------------");
 endtask 

  // ---------------------------
  // 測試流程
  // ---------------------------
  initial begin
    // init
    Dcache_addr_0        = '0;
    Dcache_command_0     = MEM_NONE;
    Dcache_size_0        = DOUBLE;
    Dcache_store_data_0  = '0;

    Dcache_addr_1        = '0;
    Dcache_command_1     = MEM_NONE;
    Dcache_size_1        = DOUBLE;
    Dcache_store_data_1  = '0;

    @(negedge reset);
    @(posedge clock);

    // ============================
    // Test 1: 同一個 addr，第一次 MISS，第二次 HIT
    // ============================
    
    test_addr = 32'h0000_1000;
    test_add2 = 32'h0000_1010;

    $display("[TB] Test1: first access (expect miss: valid_out_0=0)");
    // 第一次 load（會 miss）
    @(negedge clock);
    Dcache_addr_0    = test_addr;
    Dcache_command_0 = MEM_LOAD;
    Dcache_size_0    = DOUBLE;

    Dcache_addr_1    = test_add2;
    Dcache_command_1 = MEM_LOAD;
    Dcache_size_1    = DOUBLE;
    #1
    show_status() ;
    @(posedge clock);
    @(negedge clock);
    Dcache_command_0 <= MEM_NONE;
    Dcache_command_1 <= MEM_NONE;
    #1
    show_status() ;
    @(posedge clock);
    #1
     show_status() ;
    @(posedge clock);
        show_status() ;
    @(posedge clock);
       

    // 等 memory / MSHR / refill 流一段時間
    repeat (5) @(posedge clock);

    $display("[TB] Test1: second access (expect hit: valid_out_0=1)");

    // 第二次 load（應該 hit）
    @(negedge clock);
    Dcache_addr_0    <= test_addr;
    Dcache_command_0 <= MEM_LOAD;
    Dcache_size_0    <= DOUBLE;

    @(posedge clock);
      #1
    show_status() ;
    @(negedge clock);
    Dcache_command_0 <= MEM_NONE;
    #1
    show_status() ;
    @(posedge clock);
     show_status() ;

    

    // // ============================
    // // Test 2: 兩個 port 同時 load
    // // ============================
    // $display("[TB] Test2: two-port same-cycle access (just checking accept/valid)");

    // addr0 = 32'h0000_2000;
    // addr1 = 32'h0000_2008;  // 你可以挑可能去不同 bank 的 addr

    // @(posedge clock);
    // Dcache_addr_0    <= addr0;
    // Dcache_command_0 <= MEM_LOAD;
    // Dcache_size_0    <= DOUBLE;

    // Dcache_addr_1    <= addr1;
    // Dcache_command_1 <= MEM_LOAD;
    // Dcache_size_1    <= DOUBLE;

    // @(posedge clock);
    // $display("[TB]  two-port first access: acc0=%0d acc1=%0d v0=%0d v1=%0d",
    //          Dcache_req_0_accept, Dcache_req_1_accept,
    //          Dcache_valid_out_0, Dcache_valid_out_1);

    // Dcache_command_0 <= MEM_NONE;
    // Dcache_command_1 <= MEM_NONE;

    // 再等幾個 cycle 讓它 refill 完
    repeat (30) @(posedge clock);

    $display("[TB] DONE. Check above messages for ERROR/WARNING.");
    $finish;
  end

endmodule