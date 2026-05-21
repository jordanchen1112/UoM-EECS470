`include "sys_defs.svh"

module lq #(
    parameter int DISPATCH_WIDTH = 1,
    parameter int LQ_SIZE = 16,
    parameter int IDX_WIDTH = $clog2(LQ_SIZE)
    // #parameter int unsigned COMMIT_WIDTH = 1
)
(   
    //enqueue new load instruction
   input logic clock, reset,

//    input logic          is_load_instr,
    input logic         enq_valid, 
   input ADDR           enq_addr,
   input MEM_SIZE       enq_size,
   input ROB_IDX        enq_rob_idx,

   output logic         full,

    // check store queue forwarding 
    // check SQ for forwarding
    input  logic       sq_forward_valid,
    input  MEM_BLOCK   sq_forward_data,
    input  ADDR        sq_forward_addr,
    input  logic       sq_fwd_pending,
    output ADDR        sq_query_addr,
    output MEM_SIZE    sq_query_size,

    // to Dcache
    output logic       dc_req_valid,
    output ADDR        dc_req_addr,
    output MEM_SIZE    dc_req_size,
    input  logic       dc_req_accept,

    // from Dcache
    input  MEM_BLOCK   dc_load_data,
    input  logic       dc_load_valid,

    // writeback to ROB
    input  logic       rob_commit_valid,
    input  ROB_IDX     rob_commit_valid_idx,
    output logic       wb_valid,
    output ROB_IDX     wb_rob_idx,
    output MEM_BLOCK   wb_data,

    output logic       empty,

    // =======================================================
    // ======== Snapshot / Flush control =====================
    // =======================================================

    input logic [DISPATCH_WIDTH-1:0] is_branch_i,
    // input logic                      flush_i,
    input logic                      snapshot_restore_valid_i, //valid bit
    output logic                     checkpoint_valid_o,
    output lq_entry_t                snapshot_data_o[LQ_SIZE-1:0],
    output logic   [IDX_WIDTH-1 : 0] snapshot_head_o , snapshot_tail_o,
    output logic   [$clog2(LQ_SIZE+1)-1:0] snapshot_count_o,
    input lq_entry_t                 snapshot_data_i[LQ_SIZE-1:0],
    input logic    [IDX_WIDTH-1 : 0] snapshot_head_i , snapshot_tail_i,
    input logic   [$clog2(LQ_SIZE+1)-1:0] snapshot_count_i;

);

    // typedef struct packed {
    //     logic     valid;
    //     ADDR      addr;
    //     MEM_SIZE  size;
    //     ROB_IDX   rob_idx;
    //     logic     data_valid;
    //     MEM_BLOCK data;
    //     logic     issued;  //whether request was sent to dcache
    // } lq_entry_t;

    // -----------------------------------------
    // Circular increment function
    // -----------------------------------------
    function automatic [IDX_WIDTH-1:0] next_ptr(input [IDX_WIDTH-1:0] ptr);
        if (ptr == LQ_SIZE-1)
            return 0;
        else
            return ptr + 1;
    endfunction

    lq_entry_t lq[LQ_SIZE];
    logic [IDX_WIDTH-1 : 0] head , tail;
    logic [$clog2(LQ_SIZE+1)-1:0] count;
    assign full = (count == LQ_SIZE);
    assign empty = (count == 0);
    
    //oldest entry needing work
    logic have_uncompleted;
    logic [IDX_WIDTH-1:0] uncomplete_idx;


    //### 11/10 sychenn ###//
    logic checkpoint_valid_next;
    always_comb begin 
        checkpoint_valid_next = 1'b0;
        for(int i =0 ; i < DISPATCH_WIDTH ; i++)begin
            if(is_branch_i[i])begin
                checkpoint_valid_next = 1'b1;
                break;
            end
        end        
    end

    always_ff @(posedge clock)begin
        if(reset)begin
            head <= '0;
            tail <= '0;
            count <= '0;
            checkpoint_valid_o <= 1'b0;
            for(int i =0 ; i < LQ_SIZE ; i++)begin
                lq[i].valid <= '0;
                lq[i].addr <= '0;
                lq[i].size <= '0;
                lq[i].rob_idx <= '0; 
                lq[i].data_valid <= '0;
                lq[i].data <= '0;
                // lq[i].commited <= '0;
                lq[i].issued <= '0;
            end
        end else begin
            checkpoint_valid_o <= checkpoint_valid_next;

            // restore the value if we mispredict
            if(snapshot_restore_valid_i)begin
                head <= snapshot_head_i;
                tail <= snapshot_tail_i;
                count <= snapshot_count_i;
                for(int i = 0 ; i < LQ_SIZE ; i++)begin
                    lq[i].valid <= snapshot_data_i[i].valid;
                    lq[i].addr <= snapshot_data_i[i].addr;
                    lq[i].size <= snapshot_data_i[i].size;
                    lq[i].rob_idx <= snapshot_data_i[i].rob_idx;
                    lq[i].data_valid <= snapshot_data_i[i].data_valid;
                    lq[i].data <= snapshot_data_i[i].data;
                    lq[i].issued <= snapshot_data_i[i].issued;
                end
            end
            else begin
                //enqueue new load 
                if(enq_valid && !full)begin
                    lq[tail].valid <= 1'b1;
                    lq[tail].addr <= enq_addr;
                    lq[tail].size <= enq_size;
                    lq[tail].rob_idx <= enq_rob_idx;
                    lq[tail].data_valid <= 1'b0;
                    lq[tail].issued <= 1'b0;
                    // lq[tail].commited <= 1'b0;
                    // tail <= tail + 1'b1;
                    tail <= next_ptr(tail);
                    count <= count + 1'b1;
                end


                // //need to fix!!!!!
                // if(dc_req_valid && dc_req_accept)begin
                //     lq[uncomplete_idx].issued <= 1;
                // end


                //if head has data -> produce writeback and pop
                // if(lq[head].valid && lq[head].data_valid)begin
                //     for(int i =0 ;i < COMMIT_WIDTH ; i++)begin
                //         wb_data <= lq[head].data;
                //         lq[head].valid <= 1'b0;
                //         lq[head].data_valid <= 1'b0;
                //         head <= head + 1'b1;
                //         count <= count - 1'b1;
                //     end
                // end

                wb_valid <= 1'b0;
                if(!empty)begin
                    if(lq[head].valid && lq[head].data_valid && rob_commit_valid && (rob_commit_valid_idx == lq[head].rob_idx))begin
                        wb_valid <= 1;
                        wb_rob_idx <= lq[head].rob_idx;
                        wb_data <= lq[head].data;
                        lq[head].valid <= 1'b0;
                        // head <= head + 1;
                        head <= next_ptr(head);
                        count <= count - 1 ;
                    end
                end
            end
        end
    end



    // -------------------------------
    // Issue / request arbitration to dcache
    // Strategy:
    // - try to forward from SQ first (fast-path)
    // - else: if head exists and not issued -> send request to dcache
    // - if SQ matched but data pending -> stall (do not send to dcache)
    // -------------------------------
    // find addr in load queue that reqest forwarding from store queue
    logic found_unissued; 
    always_comb begin
        found_unissued = 1'b0;
        sq_query_addr = '0;
        sq_query_size = '0;
        //find the oldest valid entry that has not completed and not issued
        for(int i = 0 ;i < LQ_SIZE ; i++)begin
            int index = (head + i)%LQ_SIZE;
            if(lq[index].valid && !lq[index].data_valid)begin
                sq_query_addr = lq[index].addr;
                sq_query_size = lq[index].size;
                found_unissued = 1'b1;
                break;
            end
        end

    end

    //decision logic: if sq_fwd_valid -> complete the corresponding entry immediately 
    // But we must find which entry matched query; we assume query corresponds to the same oldest unissued entry
    always_ff @(posedge clock)begin
        if(reset)begin
        end 
        else begin
            if(found_unissued && sq_forward_valid)begin
                for(int i =0; i< LQ_SIZE ; i++)begin
                    int index = (i+head) % LQ_SIZE;
                    if(found_unissued && sq_forward_valid)begin
                        if((lq[index].addr == sq_forward_addr) && lq[index].valid && !lq[index].data_valid)begin
                            lq[index].data <= sq_forward_data;
                            lq[index].data_valid <= 1'b1;
                            lq[index].issued <= 1'b0; 
                            break;
                        end
                    end
                end 
                if (found_unissued && sq_fwd_pending)begin
                    // match exists but pending data: do nothing (stall) — could implement replay later
                end else begin
                    // no forwarding match <= load data from cache
                    if(found_unissued)begin
                        //find the oldest unissued index
                        int issue_idx = -1;
                        for(int i =0 ; i<LQ_SIZE;i++)begin
                            int idx = (head+i) % LQ_SIZE;
                            if(lq[idx].valid && !lq[idx].data_valid && !lq[idx].issued)begin
                                issue_idx <= idx;
                                break;
                            end
                            else if(issue_idx != -1)begin
                                // do nothing
                            end
                        end
                    end
                end
            end
        end
    end

    logic [IDX_WIDTH-1:0] issue_idx_comb;
    logic issue_candidate;

    always_comb begin
        issue_idx_comb = '0;
        issue_candidate = 1'b0;
        dc_req_valid = 1'b0;
        dc_req_addr ='0;
        dc_req_size = '0;

        // find oldest unissued entry
        for (int i=0;i<LQ_SIZE;i++) begin
            int idx = (head + i) % LQ_SIZE;
            if (lq[idx].valid && !lq[idx].data_valid && !lq[idx].issued) begin
                // if forwarding pending (sq_fwd_pending) and it matched the same addr, we should not issue
                // Here we conservatively check sq_fwd_pending signal (which was produced for the oldest unissued query)
                if (!sq_fwd_pending) begin
                    dc_req_valid = 1'b1;
                    dc_req_addr  = lq[idx].addr;
                    dc_req_size  = lq[idx].size;
                    issue_candidate = 1'b1;
                    issue_idx_comb = idx;
                end
                break;
            end
        end
    end

    //when dc_req accepted, mark that entry issued
    always_ff @(posedge clock)begin
        if(reset)begin
        end else begin
            if (dc_req_valid && dc_req_accept) begin
                lq[issue_idx_comb].issued <= 1'b1;
            end

            // dcache response
            if(dc_load_valid) begin
                for(int i =0 ; i < LQ_SIZE ; i++)begin
                    int idx = (head + i) % LQ_SIZE;
                    if(lq[idx].valid && !lq[idx].data_valid && lq[idx].issued)begin
                        lq[idx].data <= dc_load_data;
                        lq[idx].data_valid <= 1'b1;
                        break; 
                    end
                end
            end
        end
    end

    // =======================================================
    // Snapshot output: provide current mapping (for ROB/CPU to save)
    // Drive it continuously from table_reg; CPU will latch on checkpoint_valid_o
    // =======================================================
    generate 
        for (genvar i = 0 ; i < LQ_SIZE ; i++)begin
            assign snapshot_data_o[i].valid = lq[i].valid;
            assign snapshot_data_o[i].addr = lq[i].addr;
            assign snapshot_data_o[i].size = lq[i].size;
            assign snapshot_data_o[i].rob_idx = lq[i].rob_idx;
            assign snapshot_data_o[i].data_valid = lq[i].data_valid;
            assign snapshot_data_o[i].data = lq[i].data;
            assign snapshot_data_o[i].issued = lq[i].issued;
            // head, tail 怎麼處理??
        end
    endgenerate
    assign snapshot_head_o = head;
    assign snapshot_tail_o = tail;
    assign snapshot_count_o = count;
    // =======================================================
    // =======================================================
    // =======================================================
    // =======================================================


endmodule