`include "sys_defs.svh"

module lq #(
    parameter int DISPATCH_WIDTH = 1,
    parameter int LQ_SIZE = 128,
    parameter int SQ_SIZE = 128,
    parameter int IDX_WIDTH = $clog2(LQ_SIZE)
)
(   
    input logic clock, reset,

    // 1. Enqueue (Dispatch)
    input logic         enq_valid, 
    input MEM_SIZE      enq_size,
    input ROB_IDX       enq_rob_idx,
    output logic        full,


    //###sychenn : addr arrived from fu 
    input  logic       addr_valid,//todo: used as addr valid signal
    input  DATA        data,  //todo: unused (data should not come from FU)
    input  ROB_IDX     addr_rob_idx, //todo: this is addr rob_idx
    input ADDR          enq_addr, // this is addr from FU
    input logic [2:0]         funct3,
    // 2. SQ Forwarding (Query & Response)
    // input  logic       sq_forward_valid,
    // input  MEM_BLOCK   sq_forward_data,
    // input  ADDR        sq_forward_addr, // 其實如果是針對特定 query 回覆，addr 可以不用 check
    // input  logic       sq_fwd_pending,
    // output ADDR        sq_query_addr,
    // output MEM_SIZE    sq_query_size,

    // 3. D-Cache Request
    output logic       dc_req_valid,
    output ADDR        dc_req_addr,
    output MEM_SIZE    dc_req_size,
    output logic [IDX_WIDTH-1:0] dc_req_tag,

    // 4. D-Cache Response
    input  MEM_BLOCK   dc_load_data,
    input  logic       dc_load_valid,
    input  logic [IDX_WIDTH-1:0] dc_load_tag, //todo: not used
    input  ROB_IDX     dc_rob_idx_i,  // from dcache (data rob_idx)
    input  logic       dc_req_accept,

    output ROB_IDX     dc_rob_idx,

    // 5. Writeback (To CDB/ROB - Data Ready)
    input  ROB_IDX     rob_head,

    output logic       wb_valid,
    output ROB_IDX     wb_rob_idx,
    output DATA   wb_data, //TODO: only WORD level now
    output logic [2:0]       funct3_o,
    output logic       wb_is_lw,
    output MEM_SIZE     wb_size,
    output logic [$clog2(`PHYS_REGS)-1:0] wb_disp_rd_new_prf_o,

    // 6. Commit (From ROB - Free Entry)
    input  logic       rob_commit_valid,
    input  ROB_IDX     rob_commit_valid_idx,

    output logic       empty,

    // =======================================================
    // ======== free slot count in lq    =====================
    // =======================================================
    output logic [$clog2(LQ_SIZE+1)-1:0] free_num_slot,

    input logic [DISPATCH_WIDTH-1:0][$clog2(`PHYS_REGS)-1:0]disp_rd_new_prf_i,

    // Snapshot interface (Keep as is)
    input logic [DISPATCH_WIDTH-1:0] is_branch_i,
    input logic                      snapshot_restore_valid_i,
    output logic                     checkpoint_valid_o,
    output lq_entry_t                snapshot_data_o[LQ_SIZE-1:0],
    output logic   [IDX_WIDTH-1 : 0] snapshot_head_o , snapshot_tail_o,
    output logic   [$clog2(LQ_SIZE+1)-1:0] snapshot_count_o,
    input lq_entry_t                 snapshot_data_i[LQ_SIZE-1:0],
    input logic    [IDX_WIDTH-1 : 0] snapshot_head_i , snapshot_tail_i,
    input logic   [$clog2(LQ_SIZE+1)-1:0] snapshot_count_i,

    input sq_entry_t sq_view_i [SQ_SIZE-1:0],
    input logic [IDX_WIDTH-1 : 0] sq_view_head, sq_view_tail,
    input logic [$clog2(LQ_SIZE+1)-1:0] sq_view_count
);

    // forwarding logic
  function automatic logic addr_overlap(ADDR store_addr , MEM_SIZE store_size , ADDR load_addr , MEM_SIZE load_size);
    int byte_store , byte_load;
    begin
      case (store_size)
        BYTE:byte_store = 1;
        HALF:byte_store = 2;
        WORD:byte_store = 4;
        DOUBLE:byte_store = 8;
        default: byte_store = 4;
      endcase
      case (load_size)
        BYTE:byte_load = 1;
        HALF:byte_load = 2;
        WORD:byte_load = 4;
        DOUBLE:byte_load = 8;
        default:byte_load = 4;
      endcase
      addr_overlap = !((store_addr + byte_store - 1) < load_addr || (load_addr + byte_load - 1) < store_addr);
    end
  endfunction

    // Function for pointer increment
    function automatic [IDX_WIDTH-1:0] next_ptr(input [IDX_WIDTH-1:0] ptr);
        return (ptr == LQ_SIZE-1) ? 0 : ptr + 1;
    endfunction

    lq_entry_t lq[LQ_SIZE];
    logic [IDX_WIDTH-1 : 0] head, tail;
    logic [$clog2(LQ_SIZE+1)-1:0] count;
    
    assign full = (count == LQ_SIZE);
    assign empty = (count == 0);

    // Snapshot logic
    logic checkpoint_valid_next;
    always_comb begin 
        checkpoint_valid_next = 1'b0;
        for(int i =0 ; i < DISPATCH_WIDTH ; i++) begin
            if(is_branch_i[i]) begin
                checkpoint_valid_next = 1'b1;
                break;
            end
        end        
    end

    // =========================================================================
    // Combinational Logic: Find Candidate for Forwarding Query & Issue
    // =========================================================================
    logic found_unissued;
    logic [IDX_WIDTH-1:0] query_idx; // 記住是誰在查詢
    ROB_IDX rob_idx_to_dcache;
    ADDR sq_query_addr;
    MEM_SIZE    sq_query_size;
    logic stall_older_store_unknown;

    //---------------find what to sent to DCACHE---------------//
    always_comb begin
        int i;
        int idx;
        found_unissued = 1'b0;
        query_idx = '0;
        sq_query_addr = '0;
        sq_query_size = '0;
        rob_idx_to_dcache = '0;
        // stall_older_store_unknown = 1'b0;
        // Find the oldest valid entry that needs data (not valid, not issued)
        // This acts as the candidate for BOTH Forwarding and D-Cache Issue
        for(i = 0; i < LQ_SIZE; i++) begin
            idx = (head + i) % LQ_SIZE; // Check from oldest to youngest
            // Only consider entries that:
            //   - are valid
            //   - do not yet have data
            //   - have NOT yet been accepted by D-cache (issued == 0)
            // This allows us to keep asserting the request while dc_req_accept == 0,
            // and stop once a request is accepted (dc_req_valid && dc_req_accept).
            if(lq[idx].valid && !lq[idx].data_valid && !lq[idx].issued && lq[idx].addr_valid) begin
                // $display("[DEBUG] Found Candidate! Idx=%0d, Addr=%h", idx, lq[idx].addr);
                sq_query_addr = lq[idx].addr;
                sq_query_size = lq[idx].size;
                query_idx = idx;
                found_unissued = 1'b1;
                rob_idx_to_dcache = lq[idx].rob_idx;
                // $display("found_unissued = %0b" , found_unissued);
                break; // Found the oldest one
            end
        end


    end

    // =========================================================================
    // Combinational Logic: D-Cache Request
    // =========================================================================

    //---------------send to DCACHE---------------//

    logic fwd_found,sq_forward_valid;
    MEM_BLOCK fwd_data;
    ADDR fwd_addr;
    always_comb begin
        // fwd_found = 1'b0;
        dc_req_valid = 1'b0;
        dc_req_addr  = '0;
        dc_req_size  = '0;
        stall_older_store_unknown = 1'b0;
        fwd_found = 1'b0;
        // pending_found = 1'b0;
        fwd_data = '0;
        fwd_addr = '0;
        sq_forward_valid = '0;

        dc_req_tag = '0;
        dc_rob_idx = '0;
        //---------------check if there is older store address unknown---------------//
        if (found_unissued) begin
            for (int k=0; k<SQ_SIZE; k++) begin
                `ifndef SYNTHESIS
                // 條件：SQ有效 + 地址未知 + 比目前的 Load 老
                // $display("{%t} sq_view_i[%0d].valid = %0b", $time, k, sq_view_i[k].valid);
                // $display("{%t} sq_view_i[%0d].addr_valid = %0b", $time, k, sq_view_i[k].addr_valid);
                // $display("{%t} is old =%b", $time, is_older(sq_view_i[k].rob_idx, lq[query_idx].rob_idx, rob_head));
                // $display("{%t} sq_view_i[%0d].rob_idx = %0d, lq[query_idx].rob_idx = %0d, rob_head = %0d", $time, k, sq_view_i[k].rob_idx, lq[query_idx].rob_idx, rob_head);
                `endif
                if (sq_view_i[k].valid && 
                    !sq_view_i[k].addr_valid && 
                    is_older(sq_view_i[k].rob_idx, lq[query_idx].rob_idx, rob_head)) begin
                    
                        stall_older_store_unknown = 1'b1;
                    break; 
                end
            end
        end
        `ifndef SYNTHESIS
        // $display("{%t} stall_older_store_unknown = %0b", $time, stall_older_store_unknown);
        `endif

        if(found_unissued && !stall_older_store_unknown)begin
            int k;
            int i;
            int start;
            int checked;

            // $display("[DEBUG-ALWAYS STORE QUEUE] Count=%0d, Tail=%0d, Head=%0d", count, tail, head);
            if(sq_view_count != 0)begin
                checked = 0;
                // start at tail - 1 (most recent store) and go backwards up to count entries
                start  = (sq_view_tail == 0) ? (SQ_SIZE - 1) : (sq_view_tail - 1);
                `ifndef SYNTHESIS
                // $display("[DEBUG-FWD] @Time : %t , sq_view_count: %d" , $time, sq_view_count);
                `endif
                // idx = tail - 1;
                for(k = 0 ; k < SQ_SIZE ; k++)begin
                    // int i = (idx - k) % SQ_SIZE;
                    i = start - k;
                    if(i<0)i = i + SQ_SIZE;
                    // $display("[DEBUG-FWD] checked: %d ,Checking indx = %0d, sq[%0d] = %0d , k=%0d , start = %0d" ,checked, i , i , sq_view_i[i].valid , k , start);
                    if(sq_view_i[i].valid)begin
                        `ifndef SYNTHESIS
                        // $display("[DEBUG-FWD]@Time %t Checking idx=%0d. SQ_Addr=%h, SQ_Size=%0d | Load_Addr=%h, Load_Size=%0d", 
                        //         $time, i, sq_view_i[i].addr, sq_view_i[i].size, lq[query_idx].addr, lq[query_idx].addr);
                        `endif
                        if(addr_overlap(sq_view_i[i].addr , sq_view_i[i].size , lq[query_idx].addr , lq[query_idx].size))begin
                            `ifndef SYNTHESIS
                            // $display("[RTL-SQ-FWD] Overlap at idx=%0d. DataValid=%b. Data=%h", i, sq_view_i[i].data_valid, sq_view_i[i].data);
                            `endif
                            if(sq_view_i[i].data_valid && (is_older(sq_view_i[i].rob_idx, lq[query_idx].rob_idx, rob_head) ||sq_view_i[i].commited)) begin
                                fwd_found = 1'b1;
                                // pending_found = 1'b0;
                                fwd_data = sq_view_i[i].data;
                                fwd_addr = sq_view_i[i].addr;
                                // $display("[RTL-SQ-FWD]found = %0b ", fwd_found);
                                sq_forward_valid = 1'b1;
                                break;
                            end else begin
                            // $display("[DEBUG-ALWAYS] Loop idx=%0d has Valid=0! (This is wrong)", i);
                            // pending_found = 1'b1;break;
                            end
                        end
                    end
                    checked++;
                    if(checked >= sq_view_count)begin
                        fwd_found = 1'b0;
                        break;
                    end
                end
            end else begin
                fwd_found = 1'b0;
            end

            if(!fwd_found)begin
                dc_req_valid = 1'b1;
                dc_req_addr  = sq_query_addr; // Same as lq[query_idx].addr
                dc_req_size  = sq_query_size;
                dc_req_tag   = query_idx;
                dc_rob_idx = rob_idx_to_dcache;
                // $display("[LQ] dc_req_valid: %0b , dc_req_addr: %0h ,dc_req_size: %0d, dc_req_tag:%0d " ,dc_req_valid,dc_req_addr,dc_req_size, dc_req_tag);
            end
        end

        // if(found_unissued && !stall_older_store_unknown && !fwd_found)begin
        //     dc_req_valid = 1'b1;
        //     dc_req_addr  = sq_query_addr; // Same as lq[query_idx].addr
        //     dc_req_size  = sq_query_size;
        //     dc_req_tag   = query_idx;
        //     dc_rob_idx = rob_idx_to_dcache;
        //     $display("dc_req_valid: %0b , dc_req_addr: %0h ,dc_req_size: %0d, dc_req_tag:%0d " ,dc_req_valid,dc_req_addr,dc_req_size, dc_req_tag);
        // end
    end



    // =========================================================================
    // Sequential Logic: State Updates
    // =========================================================================
    logic wb_from_fwd, wb_from_cache;
    logic do_enq, do_commit;
    // logic sq_forward_valid;
    assign wb_from_fwd   = found_unissued && fwd_found;
    assign wb_from_cache = dc_load_valid && !wb_from_fwd;


    assign do_enq = enq_valid && !full;
    assign do_commit = !empty && lq[head].valid && rob_commit_valid && (rob_commit_valid_idx == lq[head].rob_idx);
    
    always_ff @(posedge clock) begin
        // $display("{%t} wb_from_fwd = %0b, wb_from_cache = %0b , found_unissued = %0b, sq_forward_valid = %0b, dc_load_valid = %0b", $time, wb_from_fwd, wb_from_cache, found_unissued, sq_forward_valid, dc_load_valid);
        if(reset) begin
            head <= '0;
            tail <= '0;
            count <= '0;
            checkpoint_valid_o <= 1'b0;
            wb_valid <= 1'b0;
            wb_rob_idx <= '0;
            wb_data <= '0;
            wb_is_lw <= '0;
            wb_size <= '0;
            wb_disp_rd_new_prf_o <= '0;
            for(int i = 0; i < LQ_SIZE; i++) begin
                lq[i].valid <= '0;
                lq[i].data_valid <= '0;
                lq[i].addr_valid <= '0;
                lq[i].issued <= '0;
                lq[i].addr <= '0;
                lq[i].size <= '0;
                lq[i].rob_idx <= '0;
                lq[i].data <= '0;
                lq[i].disp_rd_new_prf <= '0;
                lq[i].funct3 <= '0;
            end
            funct3_o <= '0;
        end else begin
            checkpoint_valid_o <= checkpoint_valid_next;
            wb_valid <= 1'b0; 
            wb_data <= '0;
            wb_is_lw <= '0;
            wb_size <= '0;

            if (do_enq && !do_commit)      count <= count + 1'b1;
            else if (!do_enq && do_commit) count <= count - 1'b1;

            if(snapshot_restore_valid_i) begin
                tail <= snapshot_tail_i;
                if(snapshot_tail_i >= head)begin
                    count <= snapshot_tail_i - head;
                end else begin
                    count <= snapshot_tail_i - head + LQ_SIZE;
                end

                if (head <= snapshot_tail_i) begin
                    for(int i = 0; i < LQ_SIZE; i++) begin
                        if ((i >= 0 && i < head) || (i >= snapshot_tail_i)) begin
                            lq[i].valid <= 1'b0;
                            lq[i].data_valid <= 1'b0;
                            lq[i].issued <= 1'b0;
                            lq[i].addr_valid <= 1'b0;
                        end
                    end
                end else begin
                    for(int i = 0; i < LQ_SIZE; i++) begin
                        if (i >= snapshot_tail_i && i < head) begin
                            lq[i].valid <= 1'b0;
                            lq[i].data_valid <= 1'b0;
                            lq[i].issued <= 1'b0;
                            lq[i].addr_valid <= 1'b0;
                        end
                    end
                end
                if (head == snapshot_tail_i) begin
                    lq[head].valid <= 1'b0;
                    lq[head].data_valid <= 1'b0;
                    lq[head].issued <= 1'b0;
                    lq[head].addr_valid <= 1'b0;
                end

                if(!empty) begin
                     if(lq[head].valid && rob_commit_valid && (rob_commit_valid_idx == lq[head].rob_idx)) begin
                        // 只有在 Commit 的時候才真正釋放 Entry
                        lq[head].valid <= 1'b0;
                        lq[head].data_valid <= 1'b0;
                        head <= next_ptr(head);
                        // count <= count - 1'b1;
                        
                        // 在 Commit 時送出 Writeback (配合你的 Testbench 預期)
                        // $display("[DEBUG-ALWAYS LOAD QUEUE] lq[head].valid = %0b", lq[head].valid);
                        // if (lq[head].data_valid) begin
                        //     wb_valid <= 1'b1;
                        //     //  wb_rob_idx <= lq[head].rob_idx;
                        //     //  wb_data <= lq[head].data;
                        // end
                    end
                end
            end else begin
                
                // ------------------------------------
                // 1. Enqueue
                // ------------------------------------
                if(enq_valid && !full) begin
                    lq[tail].valid <= 1'b1;
                    lq[tail].addr <= '0; //### sychen have not get addr when dispatch
                    lq[tail].addr_valid <= 1'b0; //### sychen 
                    lq[tail].size <= enq_size;
                    lq[tail].rob_idx <= enq_rob_idx;
                    lq[tail].data_valid <= 1'b0;
                    lq[tail].issued <= 1'b0;
                    lq[tail].data <= '0;
                    lq[tail].disp_rd_new_prf <= disp_rd_new_prf_i;
                    lq[tail].funct3 <= funct3;
                    tail <= next_ptr(tail);
                end        
                //### sychenn
                // store addr arrived from fu (match by rob_idx)
                if (addr_valid)begin 
                    // $display("addr_valid=%b | addr_rob_idx=%d | enq_addr=%h",addr_valid, addr_rob_idx, enq_addr);
                    for(int i = 0 ; i < LQ_SIZE ; i++)begin // simple linear search
                        if(lq[i].valid && (lq[i].rob_idx == addr_rob_idx))begin
                            // $display("aaaaa addr_rob_idx: %0d", addr_rob_idx);
                            lq[i].addr_valid <= 1'b1;
                            lq[i].addr <= enq_addr;
                            break;
                        end 
                    end
                end

                if(wb_from_cache) begin
                    for(int j = 0 ; j < LQ_SIZE ; j++)begin 
                        if(lq[j].valid && (lq[j].rob_idx == dc_rob_idx_i))begin
                            // $display("aaaaa dc_rob_idx_i: %0d", dc_rob_idx_i);
                            lq[j].data       <= dc_load_data;
                            lq[j].data_valid <= 1'b1;
                            wb_rob_idx <= lq[j].rob_idx;
                            wb_size <= lq[j].size;
                            funct3_o <= lq[j].funct3;
                            wb_data    <= dc_load_data.word_level[0];
                            wb_is_lw   <= 1'b1;
                            wb_valid   <= 1'b1;
                            wb_disp_rd_new_prf_o <= lq[j].disp_rd_new_prf;
                            // $display("wb_data=%h|%h",dc_load_data.word_level, dc_load_data.word_level[0]);
                            break;
                        end
                    end
                end

                // ------------------------------------
                // 2. Handling SQ Forwarding Response
                // ------------------------------------
                // If we queried SQ and it says "Hit!", take the data directly
                else if(wb_from_fwd) begin
                    // 直接寫入剛剛發起查詢的那個 Index (query_idx)
                    `ifndef SYNTHESIS
                    // $display("[sq_forwarding]: fwd_data: %0h|fwd_found=%b", fwd_data,fwd_found);
                    // $display("sq_view_i[i].valid=%b | sq_view_i[i].data_valid=%b | sq_view_i[i].rob_idx=%d | addr_overlap=%b", sq_view_i[0].valid, sq_view_i[0].data_valid, sq_view_i[0].rob_idx, addr_overlap(sq_view_i[0].addr , sq_view_i[0].size , lq[query_idx].addr , lq[query_idx].size));
                    `endif
                    lq[query_idx].data <= fwd_data;
                    lq[query_idx].data_valid <= 1'b1;
                    // 不需要 set issued, 因為資料已經拿到了
                    // Trigger Writeback immediately (Optional, or wait for next cycle logic)
                    // 為了簡化，我們讓它在下個 cycle 透過一般 Writeback 邏輯處理，
                    // 或者在這裡直接觸發 wb_valid 也可以。
                    wb_valid   <= 1'b1;
                    wb_rob_idx <= lq[query_idx].rob_idx;
                    wb_data    <= fwd_data.word_level[0]; //TODO: Only consider WORD Data now
                    wb_size <= lq[query_idx].size;
                    funct3_o <= lq[query_idx].funct3;
                    wb_is_lw <= 1'b1;
                    wb_disp_rd_new_prf_o <= lq[query_idx].disp_rd_new_prf;
                end
                // $display("wb_valid=%b | wb_rob_idx=%d | wb_data=%h",wb_valid, wb_rob_idx, wb_data);

                // ------------------------------------
                // 3. Handling D-Cache Request Accepted
                // ------------------------------------
                // Mark as issued so we don't request again
                //### sychen todo: Now keep sending request untill get the data back ###//
                if(dc_req_valid && dc_load_valid) begin
                    lq[query_idx].issued <= 1'b1;
                end

                // ------------------------------------
                // 4. Handling D-Cache Data Return
                // ------------------------------------

                // ------------------------------------
                // 5. Writeback Logic (Data is Ready -> Tell ROB)
                // ------------------------------------
                // 這裡做一個簡單的輪詢：如果有 Valid Data 且還沒退休，就送 Writeback
                // 注意：這裡簡化了，實際硬體可能需要一個 FIFO 緩衝區來排隊 Writeback
                // 這裡我們優先 Writeback Head (為了簡單)，或者您可以掃描
                // 這裡修正為：Writeback Head if ready.
                
                // 如果您希望盡快 Writeback，可以在資料寫入的那一刻 (Forwarding 或 Cache Return) 直接觸發
                // 但為了配合你的介面 (wb_valid 是單脈衝)，我們檢測 Head 是否 Ready
                // **注意**：你的 wb_logic 原本是綁在 commit 上。
                // 如果你想保留「Commit 時才釋放」但「隨時可以 Writeback」：
                // 目前設計：當資料備妥時，這裡簡化為 "Commit 時順便 Writeback" (因為你的 Testbench 這樣測)
                // 但正確做法應該是分開。我這邊先依照你的 Testbench 邏輯保留 Commit 觸發釋放。
                
                // ------------------------------------
                // 6. Commit Logic (Free Entry)
                // ------------------------------------
                // $display("[DEBUG-ALWAYS LOAD QUEUE] empty = %0b", empty);
                if(!empty) begin
                     if(lq[head].valid && rob_commit_valid && (rob_commit_valid_idx == lq[head].rob_idx)) begin
                        // 只有在 Commit 的時候才真正釋放 Entry
                        lq[head].valid <= 1'b0;
                        lq[head].data_valid <= 1'b0;
                        head <= next_ptr(head);
                        // count <= count - 1'b1;
                        
                        // 在 Commit 時送出 Writeback (配合你的 Testbench 預期)
                        // $display("[DEBUG-ALWAYS LOAD QUEUE] lq[head].valid = %0b", lq[head].valid);
                        // if (lq[head].data_valid) begin
                        //     wb_valid <= 1'b1;
                        //     //  wb_rob_idx <= lq[head].rob_idx;
                        //     //  wb_data <= lq[head].data;
                        // end
                    end
                end

            end // else snapshot
        end // else reset
    end

    // // forwarding logic from store queue
    // logic found, pending_found;
    // MEM_BLOCK found_data;
    // ADDR found_addr;
    // always_comb begin
    //     int k;
    //     int i;
    //     int start;
    //     found = 1'b0;
    //     pending_found = 1'b0;
    //     found_data = '0;
    //     found_addr = '0;
    //     sq_forward_valid = '0;
    //     // $display("[DEBUG-ALWAYS STORE QUEUE] Count=%0d, Tail=%0d, Head=%0d", count, tail, head);
    //     if(sq_view_count != 0)begin
    //         int checked = 0;
    //         // start at tail - 1 (most recent store) and go backwards up to count entries
    //         start  = (sq_view_tail == 0) ? (SQ_SIZE - 1) : (sq_view_tail - 1);
    //         // idx = tail - 1;
    //         for(k = 0 ; k < SQ_SIZE ; k++)begin
    //             // int i = (idx - k) % SQ_SIZE;
    //             i = start - k;
    //             if(i<0)i = i + SQ_SIZE;
    //             $display("[DEBUG-FWD] Checking indx = %0d, sq[%0d] = %0d , k=%0d , start = %0d" , i , i , sq[i].valid , k , start);
    //             if(sq_view_i[i].valid)begin
    //                 $display("[DEBUG-FWD]@Time %t Checking idx=%0d. SQ_Addr=%h, SQ_Size=%0d | Load_Addr=%h, Load_Size=%0d", 
    //                         $time, i, sq[i].addr, sq[i].size, load_addr, load_size);
    //                 if(addr_overlap(sq_view_i[i].addr , sq_view_i[i].size , load_addr , load_size))begin
    //                     $display("[RTL-SQ-FWD] Overlap at idx=%0d. DataValid=%b. Data=%h", i, sq[i].data_valid, sq[i].data);
    //                     if(sq_view_i[i].data_valid)begin
    //                         found = 1'b1;
    //                         pending_found = 1'b0;
    //                         found_data = sq[i].data;
    //                         found_addr = sq[i].addr;
    //                         $display("[RTL-SQ-FWD]found = %0b ", found);
    //                         sq_forward_valid = 1'b1;
    //                         break;
    //                     end else begin
    //                     // $display("[DEBUG-ALWAYS] Loop idx=%0d has Valid=0! (This is wrong)", i);
    //                     pending_found = 1'b1;break;
    //                     end
    //                 end
    //             end
    //             checked++;
    //             if(checked >= count)break;
    //         end
    //     end
    // end



    assign free_num_slot = LQ_SIZE - count;
    // Snapshot output connections
    generate 
        for (genvar i = 0 ; i < LQ_SIZE ; i++) begin
            // assign snapshot_data_o[i] = lq[i];
            assign snapshot_data_o[i].valid = lq[i].valid;
            assign snapshot_data_o[i].addr = lq[i].addr;
            assign snapshot_data_o[i].size = lq[i].size;
            assign snapshot_data_o[i].rob_idx = lq[i].rob_idx;
            assign snapshot_data_o[i].data_valid = lq[i].data_valid;
            assign snapshot_data_o[i].data = lq[i].data;
            assign snapshot_data_o[i].issued = lq[i].issued;
            assign snapshot_data_o[i].disp_rd_new_prf = lq[i].disp_rd_new_prf;
            assign snapshot_data_o[i].funct3 = lq[i].funct3;
        end
    endgenerate
    assign snapshot_head_o = head;
    assign snapshot_tail_o = tail;
    assign snapshot_count_o = count;


    // =================================================================
  // Debug Task: Show Load Queue Status
  // =================================================================
// `ifndef SYNTHESIS
//   task automatic show_lq_status();
//     int i;
//     $display("\n===================================================================");
//     $display("snapshot output: checkpoint_valid_o = %b | snapshot_tail_o = %d ", checkpoint_valid_o, snapshot_tail_o);
//     $display("snapshot_restore_valid_i = %b | store_tail = %d ", snapshot_restore_valid_i, snapshot_tail_i);
//     $display("[LQ DUMP] Time: %0t", $time);
    
//     // 1. 顯示佇列基本狀態 (State)
//     $display("[LQ State] Head=%0d | Tail=%0d | Count=%0d | Full=%b | Empty=%b", 
//              head, tail, count, full, empty);

//     // 2. 顯示目前的控制邏輯判斷 (Combinational Logic Status)
//     // 這些訊號解釋了為什麼 LQ 現在發送請求，或是為什麼停住了
//     $display("[LQ Logic] --------------------------------------------------------");
//     if (found_unissued)
//         $display("  -> Candidate Found at Index: %0d", query_idx);
//     else
//         $display("  -> No Candidate Found (All done or empty)");

//     $display("  -> Stall by Unknown Older Store? : %b", stall_older_store_unknown);
//     // $display("  -> SQ Forwarding Pending?        : %b", sq_fwd_pending);
//     $display("  -> Final DC Request Valid?       : %b", dc_req_valid);
//     $display("-------------------------------------------------------------------");

//     // 3. 顯示佇列內容 (Entry Content)
//     for (i = 0; i < LQ_SIZE; i++) begin
//       if (lq[i].valid) begin
//         // 使用 %s 或標記來指出誰是 Head, 誰是 Candidate
//         string tag;
//         if (i == head) tag = "(HEAD)";
//         else if (found_unissued && i == query_idx) tag = "(*CAND*)";
//         else tag = "";

//         $display("[LQ[%2d]] %-8s ROB#=%0d Addr=%h (AV=%b) | Data=%h (DV=%b) | Issued=%b | PRF=%0d",
//                  i,
//                  tag,
//                  lq[i].rob_idx,
//                  lq[i].addr,
//                  lq[i].addr_valid,      // Address Valid
//                  lq[i].data,
//                  lq[i].data_valid,      // Data Valid
//                  lq[i].issued,          // Issued to Cache
//                  lq[i].disp_rd_new_prf
//         );
//       end
//     end
//     $display("===================================================================\n");
//   endtask

//   always_ff @(posedge clock) begin
//     if (!reset) begin
//       show_lq_status();
//     end
//   end
//     // initial begin
//     //     $dumpfile("lq.vcd");
//     //     $dumpvars(0, lq);
//     // end
// `endif
endmodule