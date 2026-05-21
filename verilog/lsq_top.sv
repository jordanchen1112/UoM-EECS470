`include "sys_defs.svh"

//TODO: Need to have address valid bit (from FU)

module lsq_top #(
    parameter int DISPATCH_WIDTH = 1,
    parameter int SQ_SIZE = 128,
    parameter int LQ_SIZE = 128,
    // 用於 snapshot 介面的計算
    parameter int SQ_IDX_WIDTH = $clog2(SQ_SIZE),
    parameter int LQ_IDX_WIDTH = $clog2(LQ_SIZE)
)(
    input logic clock, reset,

    // =====================================================
    // 1. Dispatch Stage (來自 Decode/Dispatch)
    // =====================================================
    input  logic       dispatch_valid,
    input  logic       dispatch_is_store, // 1=Store, 0=Load
    input  MEM_SIZE    dispatch_size,
    input  ROB_IDX     dispatch_rob_idx,
    output logic       lsq_full,          // Stall signal to frontend

    // =====================================================
    // 2. Execution Stage (Store Data 來自 ALU/RegFile)
    // =====================================================
    input  logic       sq_data_valid,  // resp_o.valid
    input  DATA        sq_data, //resp_o.sw_data
    input  ROB_IDX     sq_data_rob_idx, // resp_o.rob_idx
    input  ADDR        sq_data_addr,  //resp_o.value 
    input  logic [2:0]        sq_data_funct3, 

    // =====================================================
    // 3. Commit Stage (來自 ROB)
    // =====================================================
    input  ROB_IDX     rob_head,
    input  logic       commit_valid,
    input  ROB_IDX     commit_rob_idx, 

    // =====================================================
    // 4. Writeback Stage (Load 完成 -> CDB/ROB)
    // =====================================================
    output logic       wb_valid,
    output ROB_IDX     wb_rob_idx,
    output DATA   wb_data, //TODO: only WORD level now
    output logic [2:0] funct3_o,
    output logic       wb_is_lw,
    output MEM_SIZE    wb_size,
    // =====================================================
    // 5. Dual Port D-Cache Interface
    // =====================================================
    
    // --- Port 0: 用於 Load ---
    output ADDR        Dcache_addr_0,
    output MEM_COMMAND Dcache_command_0,   // MEM_LOAD / MEM_NONE
    output MEM_SIZE    Dcache_size_0,
    output MEM_BLOCK   Dcache_store_data_0, // 對 Load 來說無用，補 0
    output ROB_IDX     Dcache_req_rob_idx_0,
    input  logic       Dcache_req_0_accept, // Bank Conflict 處理
    
    input  MEM_BLOCK   Dcache_data_out_0,   // Load Data Return
    input  logic       Dcache_valid_out_0,  // Load Data Valid
    input   ROB_IDX    Dcache_data_rob_idx_0,

    // --- Port 1: 用於 Store ---
    output ADDR        Dcache_addr_1,
    output MEM_COMMAND Dcache_command_1,   // MEM_STORE / MEM_NONE
    output MEM_SIZE    Dcache_size_1,
    output MEM_BLOCK   Dcache_store_data_1, // Store Data
    output ROB_IDX     Dcache_req_rob_idx_1,
    input  logic       Dcache_req_1_accept, // Bank Conflict 處理
    
    // Port 1 的回傳通常 Store 不用 (除非 atomic)，暫時忽略
    input  MEM_BLOCK   Dcache_data_out_1,   
    input  logic       Dcache_valid_out_1,
    input  ROB_IDX    Dcache_data_rob_idx_1,
    input  logic       Dcache_store_valid_1,

    // =====================================================
    // 6. Snapshot / Recovery Interface
    // =====================================================
    input logic [DISPATCH_WIDTH-1:0] is_branch_i,
    input logic                      snapshot_restore_valid_i,
    
    // SQ Snapshot
    output logic                     sq_checkpoint_valid_o,
    output sq_entry_t                sq_snapshot_data_o[SQ_SIZE-1:0],
    output logic [SQ_IDX_WIDTH-1:0]  sq_snapshot_head_o, sq_snapshot_tail_o,
    output logic [$clog2(SQ_SIZE+1)-1:0] sq_snapshot_count_o,
    input  sq_entry_t                sq_snapshot_data_i[SQ_SIZE-1:0],
    input  logic [SQ_IDX_WIDTH-1:0]  sq_snapshot_head_i, sq_snapshot_tail_i,
    input  logic [$clog2(SQ_SIZE+1)-1:0] sq_snapshot_count_i,

    // LQ Snapshot
    output logic                     lq_checkpoint_valid_o,
    output lq_entry_t                lq_snapshot_data_o[LQ_SIZE-1:0],
    output logic [LQ_IDX_WIDTH-1:0]  lq_snapshot_head_o, lq_snapshot_tail_o,
    output logic [$clog2(LQ_SIZE+1)-1:0] lq_snapshot_count_o,
    input  lq_entry_t                lq_snapshot_data_i[LQ_SIZE-1:0],
    input  logic [LQ_IDX_WIDTH-1:0]  lq_snapshot_head_i, lq_snapshot_tail_i,
    input  logic [$clog2(LQ_SIZE+1)-1:0] lq_snapshot_count_i,

    // =======================================================
    // ======== free slot count in sq/sq  =====================
    // =======================================================
    output logic [$clog2(LQ_SIZE+1)-1:0] lq_free_num_slot,
    output logic [$clog2(SQ_SIZE+1)-1:0] sq_free_num_slot,

    // =======================================================
    // ======== disp_rd_new_prf          =====================
    // =======================================================
    // Dispatch ->lsq
    input logic [DISPATCH_WIDTH-1:0][$clog2(`PHYS_REGS)-1:0]disp_rd_new_prf_i,
    // lsq -> complete stage
    output logic [$clog2(`PHYS_REGS)-1:0] wb_disp_rd_new_prf_o,

    ///////
    output ROB_IDX rob_store_ready_idx,
    output logic   rob_store_ready_valid
);

    // =====================================================
    // 內部訊號連接
    // =====================================================
    
    // Queue Full Status
    logic sq_full, lq_full;
    
    // Dispatch Steering
    logic sq_enq_valid;
    logic lq_enq_valid;

    // Forwarding Interface (LQ -> SQ -> LQ)
    ADDR        fwd_query_addr;   // LQ 問 SQ
    MEM_SIZE    fwd_query_size;   // LQ 問 SQ
    logic       fwd_valid;        // SQ 回覆 LQ
    MEM_BLOCK   fwd_data;         // SQ 回覆 LQ
    ADDR        fwd_res_addr;     // SQ 回覆 LQ (Addr match)
    logic       fwd_pending;      // SQ 回覆 LQ (Addr match but data not ready)

    // LQ Request Signals
    logic       lq_req_valid;
    ADDR        lq_req_addr;
    MEM_SIZE    lq_req_size;
    logic       lq_req_accept;
    ROB_IDX     lq_req_rob_idx;

    /////////////////
    sq_entry_t sq_internal_state [SQ_SIZE-1:0]; //TODO
    logic [SQ_IDX_WIDTH-1 : 0] sq_view_head, sq_view_tail;//TODO
    logic [$clog2(SQ_SIZE+1)-1:0] sq_view_count;//TODO

    sq_entry_t sq_view_o [SQ_SIZE-1:0];
    logic [SQ_IDX_WIDTH-1 : 0] sq_view_head_o, sq_view_tail_o;
    logic [$clog2(SQ_SIZE+1)-1:0] sq_view_count_o;

    ////////////////
    // SQ Request Signals
    logic       sq_req_valid;
    ADDR        sq_req_addr;
    MEM_SIZE    sq_req_size;
    MEM_COMMAND sq_req_cmd;       // SQ 內部產生的 Command
    MEM_BLOCK   sq_req_data;
    logic       sq_req_accept;
    ROB_IDX     sq_req_rob_idx;


    // =====================================================
    // Fix bug 
    // =====================================================
    // todo: (debug) dont know why dispatch valid would be 1 for multyple cycles -> same instr disaptch multy times
    ROB_IDX  pre_dispatch_rob;
    logic   new_dispatch;
    assign  new_dispatch = (dispatch_valid && (dispatch_rob_idx!= pre_dispatch_rob));

    //### sychen 
    always_ff @(posedge clock) begin 
        if (reset) begin
            pre_dispatch_rob <= '0;
        end else if(snapshot_restore_valid_i)begin
            pre_dispatch_rob <= '0;
        end else if (dispatch_valid) begin
            pre_dispatch_rob <= dispatch_rob_idx;
        end
        // `ifndef SYNTHESIS
        // // $display("dispatch_is_store=%b, dispatch_valid=%b, new_dispatch=%b, dispatch_rob_idx=%d, pre_dispatch_rob=%d", dispatch_is_store, dispatch_valid, new_dispatch, dispatch_rob_idx, pre_dispatch_rob);
        // $display("sq_data_valid=%b | sq_data_rob_idx=%d | sq_data_addr=%h",sq_data_valid, sq_data_rob_idx, sq_data_addr);
        // `endif
    end

    // =====================================================
    // Dispatch Steering Logic (分流)
    // =====================================================
    // todo: (bug) if two port both sent load data back, will discard port 1 data 
    ROB_IDX lq_data_rob_idx; // data rob idx from dcache to lq
    assign lq_data_rob_idx =(Dcache_valid_out_0) ? Dcache_data_rob_idx_0 : Dcache_data_rob_idx_1;
    logic  [LQ_IDX_WIDTH-1:0]Dcache_data_tag_0;
    assign sq_enq_valid = (dispatch_valid &&  dispatch_is_store);
    assign lq_enq_valid = (dispatch_valid && !dispatch_is_store);

    // 如果 dispatch Store 但 SQ 滿，或 dispatch Load 但 LQ 滿 -> Stall
    assign lsq_full = (dispatch_is_store && sq_full) || (!dispatch_is_store && lq_full);

    // =====================================================
    // Module Instances
    // =====================================================

    // 1. Store Queue Instance
    sq #(
        .DISPATCH_WIDTH(DISPATCH_WIDTH),
        .SQ_SIZE(SQ_SIZE)
    ) sq_inst (
        .clock(clock),
        .reset(reset),

        // Enqueue
        .enq_valid(sq_enq_valid),
        .enq_size(dispatch_size),
        .enq_rob_idx(dispatch_rob_idx),
        .full(sq_full),

        .rob_head(rob_head),
        
        // Data Update
        .data_valid(sq_data_valid),
        .data(sq_data),
        .data_rob_idx(sq_data_rob_idx),
        .enq_addr(sq_data_addr), 
        

        // Forwarding Logic (Service LQ query)
        // .load_addr(fwd_query_addr),
        // .load_size(fwd_query_size),
        // .fwd_valid(fwd_valid),
        // .fwd_data(fwd_data),
        // .fwd_addr(fwd_res_addr),
        // .fwd_pending(fwd_pending),

        // Commit
        .commit_valid(commit_valid),
        .commit_rob_idx(commit_rob_idx),

        // Output to D-Cache (Internal wires)
        .dc_req_valid(sq_req_valid),
        .dc_req_addr(sq_req_addr),
        .dc_req_size(sq_req_size),
        .dc_req_cmd(sq_req_cmd),
        .dc_store_data(sq_req_data), // 修正名稱對應
        .dc_req_accept(sq_req_accept),
        .dc_rob_idx(sq_req_rob_idx),

        // Store Valid
        .dc_store_valid(Dcache_store_valid_1),
        .dc_store_rob_idx(Dcache_data_rob_idx_1),

        // Snapshot
        .is_branch_i(is_branch_i),
        .snapshot_restore_valid_i(snapshot_restore_valid_i),
        .checkpoint_valid_o(sq_checkpoint_valid_o),
        .snapshot_data_o(sq_internal_state),
        .snapshot_head_o(sq_view_head),
        .snapshot_tail_o(sq_view_tail), // this is tail for snapshot
        .snapshot_count_o(sq_view_count),
        .snapshot_data_i(sq_snapshot_data_i),
        .snapshot_head_i(sq_snapshot_head_i),
        .snapshot_tail_i(sq_snapshot_tail_i),
        .snapshot_count_i(sq_snapshot_count_i),

        .free_num_slot(sq_free_num_slot),

        .rob_store_ready_idx(rob_store_ready_idx),
        .rob_store_ready_valid(rob_store_ready_valid),

        .sq_view_o(sq_view_o),
        .sq_view_head_o(sq_view_head_o),
        .sq_view_tail_o(sq_view_tail_o),
        .sq_view_count_o(sq_view_count_o)
    );

    // 2. Load Queue Instance
    lq #(
        .DISPATCH_WIDTH(DISPATCH_WIDTH),
        .LQ_SIZE(LQ_SIZE),
        .SQ_SIZE(SQ_SIZE)
    ) lq_inst (
        .clock(clock),
        .reset(reset),

        // Enqueue
        .enq_valid(lq_enq_valid),
        .enq_size(dispatch_size),
        .enq_rob_idx(dispatch_rob_idx),
        .full(lq_full),

        // Data Update (*from FU)
        .addr_valid(sq_data_valid),
        .data(sq_data), //not use for load
        .addr_rob_idx(sq_data_rob_idx), 
        .enq_addr(sq_data_addr), 
        .funct3(sq_data_funct3),

        // Forwarding Logic (Ask SQ)
        // .sq_forward_valid(fwd_valid),
        // .sq_forward_data(fwd_data),
        // .sq_forward_addr(fwd_res_addr),
        // .sq_fwd_pending(fwd_pending),
        // .sq_query_addr(fwd_query_addr),
        // .sq_query_size(fwd_query_size),

        // Output to D-Cache (Internal wires)
        .dc_req_valid(lq_req_valid),
        .dc_req_addr(lq_req_addr),
        .dc_req_size(lq_req_size),
        .dc_req_accept(lq_req_accept),
        .dc_rob_idx(lq_req_rob_idx), // TODO

        // Input from D-Cache
        .dc_load_data(Dcache_data_out_0),   // 連接 Port 0 回傳
        .dc_load_valid(Dcache_valid_out_0), // 連接 Port 0 Valid
        .dc_load_tag(Dcache_data_tag_0), //todo: not used
        .dc_rob_idx_i(lq_data_rob_idx), 

        // Writeback / Commit
        .rob_head(rob_head),
        ////////////////////////////////////////
        .sq_view_i(sq_view_o),
        .sq_view_head(sq_view_head_o),
        .sq_view_tail(sq_view_tail_o),
        .sq_view_count(sq_view_count_o),
        .rob_commit_valid(commit_valid),
        .rob_commit_valid_idx(commit_rob_idx),
        .wb_valid(wb_valid),
        .wb_rob_idx(wb_rob_idx),
        .wb_data(wb_data),
        .wb_is_lw(wb_is_lw),
        .wb_size(wb_size),
        .funct3_o(funct3_o),
        .empty(), 

        // Snapshot
        .is_branch_i(is_branch_i),
        .snapshot_restore_valid_i(snapshot_restore_valid_i),
        .checkpoint_valid_o(lq_checkpoint_valid_o),
        .snapshot_data_o(lq_snapshot_data_o),
        .snapshot_head_o(lq_snapshot_head_o),
        .snapshot_tail_o(lq_snapshot_tail_o),
        .snapshot_count_o(lq_snapshot_count_o),
        .snapshot_data_i(lq_snapshot_data_i),
        .snapshot_head_i(lq_snapshot_head_i),
        .snapshot_tail_i(lq_snapshot_tail_i),
        .snapshot_count_i(lq_snapshot_count_i),

        .free_num_slot(lq_free_num_slot),
        .disp_rd_new_prf_i(disp_rd_new_prf_i),
        .wb_disp_rd_new_prf_o(wb_disp_rd_new_prf_o)
    );


   
    // =====================================================
    // Cache Interface Connections (Dual Port Mappings)
    // =====================================================

    // -----------------------------------------------------
    // Port 0: LOAD Port (Connected to LQ)
    // -----------------------------------------------------
    // 當 LQ valid 時發送 MEM_LOAD，否則發送 MEM_NONE
    assign Dcache_command_0    = lq_req_valid ? MEM_LOAD : MEM_NONE;
    
    assign Dcache_addr_0       = lq_req_addr;
    assign Dcache_size_0       = lq_req_size;
    assign Dcache_store_data_0 = '0; // Load 不寫入資料
    assign Dcache_req_rob_idx_0      = lq_req_rob_idx; //TODO
    // 將 Cache 的 Accept 回傳給 LQ
    assign lq_req_accept       = Dcache_req_0_accept;

    // -----------------------------------------------------
    // Port 1: STORE Port (Connected to SQ)
    // -----------------------------------------------------
    // 當 SQ valid 時發送 MEM_STORE (或其他 cmd)，否則發送 MEM_NONE
    assign Dcache_command_1    = sq_req_valid ? sq_req_cmd : MEM_NONE;
    
    assign Dcache_addr_1       = sq_req_addr;
    assign Dcache_size_1       = sq_req_size;
    // assign Dcache_size_1       = WORD;
    assign Dcache_store_data_1 = sq_req_data;
    assign Dcache_req_rob_idx_1      = sq_req_rob_idx; //TODO    
    // 將 Cache 的 Accept 回傳給 SQ
    assign sq_req_accept       = Dcache_req_1_accept;

    assign sq_snapshot_data_o = sq_internal_state;
    assign sq_snapshot_head_o = sq_view_head;
    assign sq_snapshot_tail_o = sq_view_tail;
    assign sq_snapshot_count_o = sq_view_count;

//     // =====================================================
//     // Debug Display Task
//     // =====================================================
// `ifndef SYNTHESIS
//     task automatic show_lsq_status();
//         $display("=== LSQ Status (Cycle %0d) ===", $time);
        
//         // LSQ Status
//         $display("LSQ Dispatch");
//         $display("LQ Status: lq_enq_valid=%b, dispatch_size=%p, dispatch_rob_idx=%d , sq_data_funct3 = %b", lq_enq_valid, dispatch_size, dispatch_rob_idx,sq_data_funct3);
//         $display("SQ Status: sq_enq_valid=%b,  dispatch_size=%p, dispatch_rob_idx=%d", sq_enq_valid,dispatch_size, dispatch_rob_idx); 

//         $display("LSQ Get DATA/ADDR");
//         $display("LSQ: addr=%h | data=%h(%b) | rob_idx=%d", sq_data_addr, sq_data, sq_data_valid, sq_data_rob_idx);

//         // D-Cache Interface Status
//         $display("\n=== D-Cache Interface ===");
//         $display("Load Port (0): cmd=%s, addr=%h, size=%0d, accept=%b, valid_out=%b, data_out=%h, lq_req_valid=%s",
//                 Dcache_command_0.name(), Dcache_addr_0, Dcache_size_0, 
//                 Dcache_req_0_accept, Dcache_valid_out_0, Dcache_data_out_0,lq_req_valid);
        
//         $display("Store Port (1): cmd=%s, addr=%h, size=%0d, accept=%b, valid_out=%b, data_out=%h, sq_req_valid=%s",
//                 Dcache_command_1.name(), Dcache_addr_1, Dcache_size_1,
//                 Dcache_req_1_accept, Dcache_valid_out_1, Dcache_data_out_1,sq_req_valid);
        
//         // Writeback Status
//         $display("\n=== Writeback ===");
//         $display("WB Valid: %b, ROB IDX: %0d, Data: %h", 
//                 wb_valid, wb_rob_idx, wb_data);
        
//         $display("==================================\n");
//     endtask


//     // Call the debug display on every clock edge (can be modified to trigger on specific conditions)
//     always_ff @(posedge clock) begin
//         if (!reset) begin
//             // Uncomment the line below to enable continuous debugging
//             show_lsq_status();
            
//             // Or add specific conditions to trigger the display, for example:
//             // if (dispatch_valid || commit_valid || wb_valid || Dcache_valid_out_0 || Dcache_valid_out_1) begin
//             //     show_lsq_status();
//             // end
//         end
//     end
// `endif

endmodule