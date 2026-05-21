/*
module rob #(
    parameter int unsigned ROB_DEPTH           = 64,
    parameter int unsigned INST_W          = 16,
    parameter int unsigned DISPATCH_WIDTH  = 1,
    parameter int unsigned COMMIT_WIDTH    = 1,
    parameter int unsigned WB_WIDTH        = 4,
    parameter int unsigned ARCH_REGS       = 64,
    parameter int unsigned PHYS_REGS       = 128,
    parameter int unsigned XLEN            = 32
)(
    input  logic clock,
    input  logic reset,

    // Dispatch
    input  logic [DISPATCH_WIDTH-1:0] disp_valid_i,
    input  logic [DISPATCH_WIDTH-1:0] disp_rd_wen_i,
    input  logic [DISPATCH_WIDTH-1:0][$clog2(ARCH_REGS)-1:0] disp_rd_arch_i,
    input  logic [DISPATCH_WIDTH-1:0][$clog2(PHYS_REGS)-1:0] disp_rd_new_prf_i,
    input  logic [DISPATCH_WIDTH-1:0][$clog2(PHYS_REGS)-1:0] disp_rd_old_prf_i,

    output logic [DISPATCH_WIDTH-1:0] disp_ready_o,
    output logic [DISPATCH_WIDTH-1:0] disp_alloc_o,
    output logic [DISPATCH_WIDTH-1:0][$clog2(ROB_DEPTH)-1:0]  disp_rob_idx_o,
    output logic [$clog2(ROB_DEPTH+1)-1:0] disp_enable_space_o, 

    // Writeback
    input  logic [WB_WIDTH-1:0] wb_valid_i,
    input  logic [WB_WIDTH-1:0][$clog2(ROB_DEPTH)-1:0] wb_rob_idx_i,
    input  logic [WB_WIDTH-1:0] wb_exception_i,
    input  logic [WB_WIDTH-1:0] wb_mispred_i,

    // Commit
    output logic [COMMIT_WIDTH-1:0] commit_valid_o,
    output logic [COMMIT_WIDTH-1:0] commit_rd_wen_o,
    output logic [COMMIT_WIDTH-1:0][$clog2(ARCH_REGS)-1:0] commit_rd_arch_o,
    output logic [COMMIT_WIDTH-1:0][$clog2(PHYS_REGS)-1:0] commit_new_prf_o,
    output logic [COMMIT_WIDTH-1:0][$clog2(PHYS_REGS)-1:0] commit_old_prf_o,

    // Branch flush
    output logic flush_o,
    output logic [$clog2(ROB_DEPTH)-1:0] flush_upto_rob_idx_o
);

        // ===== ROB Entry Struct =====
    typedef struct packed {
        logic valid;
        logic ready;
        logic rd_wen;
        logic [$clog2(ARCH_REGS)-1:0] rd_arch;
        logic [$clog2(PHYS_REGS)-1:0] new_prf;
        logic [$clog2(PHYS_REGS)-1:0] old_prf;
        logic exception;
        logic mispred;
    } rob_entry_t;

    rob_entry_t rob_table [ROB_DEPTH];

    logic [$clog2(ROB_DEPTH)-1:0] head, tail;
    logic [$clog2(ROB_DEPTH):0] count;

    // ===== Internal Signals =====
    logic full, empty;
    logic [$clog2(ROB_DEPTH)-1:0] next_tail, next_head;
    logic [COMMIT_WIDTH-1:0] retire_en;

    assign full  = (count == ROB_DEPTH);
    assign empty = (count == 0);
    assign disp_ready_o = {!full, !full};   //fixed to 2 bits

    // ===== Dispatch Logic =====
    assign disp_enable_space_o = ROB_DEPTH - count;
    always_comb begin
        next_tail = tail;
        for (int i = 0; i < DISPATCH_WIDTH; i++) begin
            disp_alloc_o[i]   = 1'b0;
            disp_rob_idx_o[i] = '0;
        end

        if (!full) begin
            for (int i = 0; i < DISPATCH_WIDTH; i++) begin
                if (disp_valid_i[i] && (count + i < ROB_DEPTH)) begin
                    disp_alloc_o[i]   = 1'b1;
                    disp_rob_idx_o[i] = next_tail;
                    next_tail         = (next_tail == ROB_DEPTH-1) ? '0 : next_tail + 1;
                end
            end
        end
    end

    // ===== Commit Ready Check =====
    always_comb begin
        retire_en = '0;
        for (int i = 0; i < COMMIT_WIDTH; i++) begin
            // if (!empty && rob_table[(head + i) % ROB_DEPTH].valid && rob_table[(head + i) % ROB_DEPTH].ready && ((i == 0) || retire_en[i-1])) begin ### ?not sure the valid part
            if (!empty && rob_table[(head + i) % ROB_DEPTH].ready && ((i == 0) || retire_en[i-1])) begin
                retire_en[i] = 1'b1;
            end
        end
    end

    // ===== Sequential Block =====
    always_ff @(posedge clock) begin
        if (reset) begin
            head   <= '0;
            tail   <= '0;
            count  <= '0;
            flush_o <= 1'b0;
            flush_upto_rob_idx_o <= '0;

            for(int i = 0 ; i< COMMIT_WIDTH; i++)begin
                commit_old_prf_o[i] <= '0;
            end

            for (int i = 0; i < ROB_DEPTH; i++) begin
            //     rob_table[i].valid     <= 1'b0;
            //     rob_table[i].ready     <= 1'b0;
            //     rob_table[i].exception <= 1'b0;
            //     rob_table[i].mispred   <= 1'b0;
                rob_table[i] <= '0;
            end

        end else begin
            flush_o <= 1'b0; // default

            // ==== Writeback ====
            for (int i = 0; i < WB_WIDTH; i++) begin
                if (wb_valid_i[i]) begin
                    rob_table[wb_rob_idx_i[i]].ready     <= 1'b1;
                    rob_table[wb_rob_idx_i[i]].exception <= wb_exception_i[i];
                    rob_table[wb_rob_idx_i[i]].mispred   <= wb_mispred_i[i];
                end
            end

            // ==== Dispatch (allocate new entries) ====
            for (int i = 0; i < DISPATCH_WIDTH; i++) begin
                if (disp_alloc_o[i]) begin
                    rob_table[disp_rob_idx_o[i]].valid     <= 1'b1;
                    rob_table[disp_rob_idx_o[i]].ready     <= 1'b0;
                    rob_table[disp_rob_idx_o[i]].rd_wen    <= disp_rd_wen_i[i];
                    rob_table[disp_rob_idx_o[i]].rd_arch   <= disp_rd_arch_i[i];
                    rob_table[disp_rob_idx_o[i]].new_prf   <= disp_rd_new_prf_i[i];
                    rob_table[disp_rob_idx_o[i]].old_prf   <= disp_rd_old_prf_i[i];
                    rob_table[disp_rob_idx_o[i]].exception <= 1'b0;
                    rob_table[disp_rob_idx_o[i]].mispred   <= 1'b0;
                end
            end

            // ==== Commit (retire ready entries) ====
            for (int i = 0; i < COMMIT_WIDTH; i++) begin
                if (retire_en[i]) begin
                    commit_valid_o[i]   <= 1'b1;
                    commit_rd_wen_o[i]  <= rob_table[head + i].rd_wen;
                    commit_rd_arch_o[i] <= rob_table[head + i].rd_arch;
                    commit_new_prf_o[i] <= rob_table[head + i].new_prf;
                    commit_old_prf_o[i] <= rob_table[head + i].old_prf;

                    // Flush if mispred or exception
                    if (rob_table[head].mispred || rob_table[head].exception) begin
                        flush_o              <= 1'b1;
                        flush_upto_rob_idx_o <= head;
                        head   <= '0;//###
                        tail   <= '0;//###
                        count  <= '0;
                        for (int j = 0; j < ROB_DEPTH; j++) begin
                            rob_table[j].valid <= 1'b0;
                        end
                    end else begin
                        rob_table[head].valid <= 1'b0;
                    end
                end else begin
                    commit_valid_o[i] <= 1'b0;
                end
            end

            head <= head + $countones(retire_en);

            // ==== Update count and tail ====
            count <= count + $countones(disp_alloc_o) - $countones(retire_en);
            tail  <= next_tail;
        end

    end
    // always_ff @(negedge clock)begin
    //    // $display("head = %0d  , tail = %0d\n" , head, tail);
    //    $display("disp_rob_idx_o=%d | commit_old_prf_o: %d", disp_rob_idx_o[0], commit_old_prf_o[0]);
    // end

/*
task automatic show_rob_output();
    // $display("============================================");
    // $display("                 ROB STATUS                 ");
    // $display("============================================");
    // $display("Head = %0d | Tail = %0d | Count = %0d | Full = %b | Empty = %b", 
    //          head, tail, count, full, empty);
    for (int i = 0; i < ROB_DEPTH; i++) begin
        if (rob_table[i].valid) begin
            // $display("Entry %0d: valid=%b, ready=%b, rd_wen=%b, rd_arch=%0d, new_prf=%0d, old_prf=%0d, exception=%b, mispred=%b",
            //          i, 
            //          rob_table[i].valid,
            //          rob_table[i].ready,
            //          rob_table[i].rd_wen,
            //          rob_table[i].rd_arch,
            //          rob_table[i].new_prf,
            //          rob_table[i].old_prf,
            //          rob_table[i].exception,
            //          rob_table[i].mispred);
        end else begin
            // $display("Entry %0d: --- empty ---", i);
        end
    end
    // $display("============================================");
endtask
*/

//     int cycle_count;
//     always_ff @(posedge clock) begin
//         if (reset) begin
//             cycle_count <= 0;
//         end else begin
//             cycle_count <= cycle_count + 1;
//             show_rob_output();
//         end
//     end


// endmodule
// */

//### TODO: Modified Version 11/6 sychenn ###//
module rob #(
    parameter int unsigned ROB_DEPTH       = 64,
    parameter int unsigned INST_W          = 16,
    parameter int unsigned DISPATCH_WIDTH  = 1,
    parameter int unsigned COMMIT_WIDTH    = 1,
    parameter int unsigned WB_WIDTH        = 4,
    parameter int unsigned ARCH_REGS       = 64,
    parameter int unsigned PHYS_REGS       = 128,
    parameter int unsigned XLEN            = 32
)(
    input  logic clock,
    input  logic reset,

    // Dispatch
    input  logic [DISPATCH_WIDTH-1:0] disp_valid_i,
    input  logic [DISPATCH_WIDTH-1:0] disp_rd_wen_i,
    input  logic [DISPATCH_WIDTH-1:0][$clog2(ARCH_REGS)-1:0] disp_rd_arch_i,
    input  logic [DISPATCH_WIDTH-1:0][$clog2(PHYS_REGS)-1:0] disp_rd_new_prf_i,
    input  logic [DISPATCH_WIDTH-1:0][$clog2(PHYS_REGS)-1:0] disp_rd_old_prf_i,
    input  DISP_PACKET [DISPATCH_WIDTH-1:0] disp_packet_i,

    output logic [DISPATCH_WIDTH-1:0] disp_ready_o,
    output logic [DISPATCH_WIDTH-1:0] disp_alloc_o,
    output ROB_IDX [DISPATCH_WIDTH-1:0]  disp_rob_idx_o,
    output logic [$clog2(ROB_DEPTH+1)-1:0] disp_enable_space_o, 

    // Writeback
    input  logic [WB_WIDTH-1:0] wb_valid_i,
    input  logic [WB_WIDTH-1:0][$clog2(ROB_DEPTH)-1:0] wb_rob_idx_i,
    input  logic [WB_WIDTH-1:0] wb_exception_i,
    input  logic [WB_WIDTH-1:0] wb_mispred_i,
    //### 11/7 add sychenn ###//
    input  logic [WB_WIDTH-1:0][XLEN-1:0]          fu_value_wb_i,

    // Commit
    output logic [COMMIT_WIDTH-1:0] commit_valid_o,
    output logic [COMMIT_WIDTH-1:0] commit_rd_wen_o,
    output logic [COMMIT_WIDTH-1:0][$clog2(ARCH_REGS)-1:0] commit_rd_arch_o,
    output logic [COMMIT_WIDTH-1:0][$clog2(PHYS_REGS)-1:0] commit_new_prf_o,
    output logic [COMMIT_WIDTH-1:0][$clog2(PHYS_REGS)-1:0] commit_old_prf_o,

    // Branch flush ##TODO: What is this for?
    output logic flush_o,
    output ROB_IDX flush_upto_rob_idx_o,

    // Branch flush ### (sychenn 11/6) ###
    input logic mispredict_i,
    input ROB_IDX  mispredict_rob_idx_i,

    //### TODO: for debug only (sychenn 11/6) ###
    //  to free list
    output logic [DISPATCH_WIDTH-1:0][$clog2(PHYS_REGS)-1:0] flush2free_list_new_prf_o,
    output logic [DISPATCH_WIDTH-1:0] flush2free_list_valid_o,
    output logic flush_i,
    output logic [ROB_DEPTH-1:0] flush_free_regs_valid,
    output logic [(PHYS_REGS)-1:0] flush_free_regs,

    output COMMIT_PACKET [`N-1:0] wb_packet_o,

    // ROB -> LSQ
    output ROB_IDX      [COMMIT_WIDTH-1:0]   retire_rob_idx_o, 
    output ROB_IDX       rob_head_o,

    input ROB_IDX rob_store_ready_idx,
    input logic   rob_store_ready_valid,

    //halt
    input logic system_stop
);

    
    // ===== ROB Entry Struct =====
    typedef struct packed {
        logic valid;
        logic ready;
        logic rd_wen;
        logic [$clog2(ARCH_REGS)-1:0] rd_arch;
        logic [$clog2(PHYS_REGS)-1:0] new_prf;
        logic [$clog2(PHYS_REGS)-1:0] old_prf;
        logic halt;
        logic exception;
        logic mispred;
        ADDR NPC;
        ADDR PC;
        INST inst;
        logic [XLEN-1:0] value;
    } rob_entry_t;

    rob_entry_t rob_table [ROB_DEPTH];

    ROB_IDX head, tail;
    logic [$clog2(ROB_DEPTH):0] count;

    assign rob_head_o = head; // sent to lsq

    // ===== Internal Signals =====
    logic full, empty, empty_org;
    logic [$clog2(ROB_DEPTH)-1:0] next_tail, next_head;
    logic [COMMIT_WIDTH-1:0] retire_en;
    always_ff @(posedge clock) begin
        empty_org <= empty;
    end

    assign full  = (count == ROB_DEPTH);
    assign empty = (count == 0);
    assign disp_ready_o = {!full, !full};   //fixed to 2 bits

    //=============================================================//
    //### TODO: for debug only (sychenn 11/6) ###//
    //=============================================================//

    //### added to update head/tail/count at the same cycle ###//
    //his is for the scenario that flush the ROB when retired mispredicrt instruction 

    // logic [$clog2(COMMIT_WIDTH)-1:0] flush_condition; // represent which commit slot needs to be flushed 
    // always_comb begin
    //     flush_condition = '0;
    //     for (int i = 0; i < COMMIT_WIDTH; i++) begin
    //         if (retire_en[i]) begin
    //             if (rob_table[head+i].mispred || rob_table[head+i].exception) begin
    //                 flush_condition = flush_condition | (1 << i);
    //             end
    //         end
    //     end
    // end
    
    //=============================================================//
    //### for debug only (sychenn 11/6) ###//
    //=============================================================//
    logic [COMMIT_WIDTH-1:0] wb_valid;
    COMMIT_PACKET [`N-1:0] wb_packet;

    always_ff @(posedge clock) begin
        if(reset) begin    
            wb_valid <= '0;
        end else begin
            wb_valid <= retire_en;
        end
    end

    always_comb begin 
        wb_packet_o = '0;
        for(int i = 0; i < COMMIT_WIDTH; i++) begin
            if  (wb_valid[i]) begin
                wb_packet_o[i].data = wb_packet[i].data;
                wb_packet_o[i].reg_idx =wb_packet[i].reg_idx;
                wb_packet_o[i].halt = wb_packet[i].halt;
                wb_packet_o[i].illegal=wb_packet[i].illegal;
                wb_packet_o[i].valid =wb_packet[i].valid;
                wb_packet_o[i].NPC = wb_packet[i].NPC;
            end else begin
                wb_packet_o[i] = '0;
            end
        end
    end

    // ===== Dispatch Logic =====
    assign disp_enable_space_o = ROB_DEPTH - count;
    always_comb begin
        next_tail = tail;
        for (int i = 0; i < DISPATCH_WIDTH; i++) begin
            disp_alloc_o[i]   = 1'b0;
            disp_rob_idx_o[i] = '0;
        end

        if (!full) begin
            for (int i = 0; i < DISPATCH_WIDTH; i++) begin
                if (disp_valid_i[i] && (count + i < ROB_DEPTH)) begin
                    disp_alloc_o[i]   = 1'b1;
                    disp_rob_idx_o[i] = next_tail;
                    next_tail         = (next_tail == ROB_DEPTH-1) ? '0 : next_tail + 1;
                end
            end
        end
    end

    // ===== Commit Ready Check =====
    always_comb begin
        retire_en = '0;
        if(!mispredict_i && !system_stop)begin
             for (int i = 0; i < COMMIT_WIDTH; i++) begin
                // if (!empty && rob_table[(head + i) % ROB_DEPTH].valid && rob_table[(head + i) % ROB_DEPTH].ready && ((i == 0) || retire_en[i-1])) begin ### ?not sure the valid part
                if (rob_table[(head + i) % ROB_DEPTH].valid && rob_table[(head + i) % ROB_DEPTH].ready) begin
                    retire_en[i] = 1'b1;
                end else begin
                    break;
                end
            end
        end
    end

    // ===== Flush Miispredict logic ====//
    // for free regs
    // logic [ROB_DEPTH-1:0] flush_free_regs_valid;
    // logic [ROB_DEPTH-1:0][$clog2(PHYS_REGS)-1:0] flush_free_regs;

    // for flush mispredict instructions
    logic [$clog2(ROB_DEPTH):0]   flush_count;
    logic [ROB_DEPTH-1:0]   flushed_mask;  // flushed if flushed_mask[i] = 1
    always_comb begin
        // free regs
        flush_free_regs_valid = '0;
        flush_free_regs       = '0;
        // flush mispredict instructions
        flush_count = '0;
        flushed_mask = '0;
        if (mispredict_i) begin
            for (int j = 1; j < ROB_DEPTH; j++) begin
                `ifndef SYNTHESIS
            // $display("m=%d,j=%d | valid=%b | rob_table[j].old_prf=%0d",mispredict_rob_idx_i, (mispredict_rob_idx_i + j) % ROB_DEPTH,rob_table[(mispredict_rob_idx_i + j) % ROB_DEPTH].valid,rob_table[(mispredict_rob_idx_i + j) % ROB_DEPTH].old_prf);
                `endif
                // (mispredict_rob_idx_i + 1 + j) % ROB_DEPTH = idx (but cannot 2 int in one block?)
                if ((mispredict_rob_idx_i + j) % ROB_DEPTH == tail) begin
                    break;
                end else if ((rob_table[(mispredict_rob_idx_i + j) % ROB_DEPTH].valid)) begin
                    // this is to update ROB
                    flush_count++; 
                    flushed_mask |= (1 << (mispredict_rob_idx_i + j) % ROB_DEPTH);
                    // this is to update free list
                    if ((rob_table[(mispredict_rob_idx_i + j) % ROB_DEPTH].old_prf != 0)) begin
                        // flush mispredict instructions                        
                        //free regs
                        flush_free_regs_valid[j] = 1'b1;
                        flush_free_regs       |= (1 << rob_table[(mispredict_rob_idx_i + j) % ROB_DEPTH].new_prf);
                    end
                end
            end
            
           
        end
        flush_i = |flush_free_regs_valid;
        `ifndef SYNTHESIS
        // $display("flush_count=%d",flush_count);
        `endif
    end

    // ===== Sequential Block =====
    // TODO:  When flush mispredict: ### only writeback still need to work ###,  STOP commit and dispatch
    always_ff @(posedge clock) begin
        if (reset) begin
            head   <= '0;
            tail   <= '0;
            count  <= '0;
            flush_o <= 1'b0;
            flush_upto_rob_idx_o <= '0;
            retire_rob_idx_o <= '0;
            commit_valid_o <= '0;

            for (int i = 0; i < DISPATCH_WIDTH; i++) begin
                flush2free_list_valid_o[i] <= '0;
                flush2free_list_new_prf_o[i] <= '0;
            end
            
            for(int i = 0 ; i< `N; i++)begin
                wb_packet[i] <= '0;
            end

            for(int i = 0 ; i< COMMIT_WIDTH; i++)begin
                commit_old_prf_o[i] <= '0;
            end

            for(int i = 0 ; i< COMMIT_WIDTH; i++)begin
                commit_new_prf_o[i] <= '0;
            end

            for (int i = 0; i < ROB_DEPTH; i++) begin
                rob_table[i] <= '0;
            end

            for (int i = 0; i < COMMIT_WIDTH; i++) begin
                commit_rd_wen_o <= '0;
                commit_rd_arch_o <= '0;
            end
        
        //################## (sychenn 11/6) ######################
        end else begin  
            if (mispredict_i) begin
                // Flush to tail
                if (mispredict_i) begin
                    for (int j = 0; j < ROB_DEPTH; j++) begin
                        if (flushed_mask[j]) begin
                            rob_table[j].valid <= 1'b0;
                            rob_table[j].ready <= 1'b0;
                        end
                    end
                end
                // update tail and count
                tail  <= (mispredict_rob_idx_i+1) % ROB_DEPTH;
                count <= count - flush_count;
                

                // stop commit
                for (int i = 0; i < COMMIT_WIDTH; i++) begin
                    commit_valid_o[i]   <= 1'b0;
                    commit_old_prf_o[i] <= '0;
                end
                for (int i = 0; i < DISPATCH_WIDTH; i++) begin
                    flush2free_list_valid_o[i] <= disp_rd_wen_i[i];
                    flush2free_list_new_prf_o[i] <= disp_rd_new_prf_i[i];
                end

                for (int i = 0; i < COMMIT_WIDTH; i++) begin
                    commit_rd_wen_o <= '0;
                    commit_rd_arch_o <= '0;
                end

            //################## (sychenn 11/6) ######################
            end else begin
                flush_o <= 1'b0; // default
                for (int i = 0; i < DISPATCH_WIDTH; i++) begin
                    flush2free_list_valid_o[i] <= '0;
                    flush2free_list_new_prf_o[i] <= '0;
                end

                // ==== Dispatch (allocate new entries) ====
                for (int i = 0; i < DISPATCH_WIDTH; i++) begin
                    if (disp_alloc_o[i]) begin
                        rob_table[disp_rob_idx_o[i]].valid     <= 1'b1;
                        rob_table[disp_rob_idx_o[i]].ready     <= '0; 
                        rob_table[disp_rob_idx_o[i]].rd_wen    <= disp_rd_wen_i[i];
                        rob_table[disp_rob_idx_o[i]].rd_arch   <= disp_rd_arch_i[i];
                        rob_table[disp_rob_idx_o[i]].new_prf   <= disp_rd_new_prf_i[i];
                        rob_table[disp_rob_idx_o[i]].old_prf   <= disp_rd_old_prf_i[i];
                        rob_table[disp_rob_idx_o[i]].exception <= 1'b0;
                        rob_table[disp_rob_idx_o[i]].mispred   <= 1'b0;

                        //###11/7 SYCHENN ###//
                        rob_table[disp_rob_idx_o[i]].NPC   <= disp_packet_i[i].NPC;
                        rob_table[disp_rob_idx_o[i]].PC    <= disp_packet_i[i].PC;
                        rob_table[disp_rob_idx_o[i]].inst  <= disp_packet_i[i].inst;

                        rob_table[disp_rob_idx_o[i]].halt  <= disp_packet_i[i].halt;
                    end
                end

                // ==== Commit (retire ready entries) ====
                // TODO: Also FLush out the midpredicted instructions (previous code let it commit as well)
                for (int i = 0; i < COMMIT_WIDTH; i++) begin
                    // TODO: add (!flush_condition) to let insturctions after mispred/exception in the same cycle: 
                    // goes to else block and let valid <=0
                    if (retire_en[i]) begin 
                        // Flush if mispred or exception
                        //TODO: Here's why it clear all rob at cycle 118
                        // if (flush_condition[i]) begin
                        //     //flush_condition would be 1 at the same cycle
                        //     flush_o              <= 1'b1;
                        //     flush_upto_rob_idx_o <= head;
                        //     head   <= '0;//###
                        //     tail   <= '0;//###
                        //     count  <= '0;
                        //     commit_valid_o[i] <= 1'b0; //TODO: I guess this also needed??
                        //     for (int j = 0; j < ROB_DEPTH; j++) begin
                        //         rob_table[j].valid <= 1'b0;
                        //     end

                        // end else begin
                        // cleaar the rob entry

                        // retire rob idx
                        retire_rob_idx_o <= head + i;

                        rob_table[head + i].valid <= 1'b0;
                        // Output commit data
                        commit_valid_o[i]   <= 1'b1;
                        commit_rd_wen_o[i]  <= rob_table[head + i].rd_wen;
                        commit_rd_arch_o[i] <= rob_table[head + i].rd_arch;
                        commit_new_prf_o[i] <= rob_table[head + i].new_prf;
                        commit_old_prf_o[i] <= rob_table[head + i].old_prf;
                        // wb file
                        if(rob_table[head].valid) begin
                            wb_packet[i].data <= rob_table[head + i].value;
                            wb_packet[i].reg_idx <= rob_table[head + i].rd_arch;
                            wb_packet[i].halt <= rob_table[head + i].halt;
                            wb_packet[i].illegal <=0;
                            wb_packet[i].valid <=1;
                            wb_packet[i].NPC <= rob_table[head + i].NPC;
                        end else begin
                            wb_packet[i].valid <=0;
                        end
                        // $display("npc1=%h | npc2=%h",rob_table[head + i].NPC, disp_packet_i[0].NPC);

                    end else begin
                        commit_valid_o[i] <= 1'b0;
                    end

                    //TODO: This part overwrite the head <= '0 when flush all ROB entry (when retired mispredict instruction)
                    // ==== Update count and head/tail ====
                    head <= head + $countones(retire_en);
                    count <= count + $countones(disp_alloc_o) - $countones(retire_en);
                    tail  <= next_tail;
                end
            end    
                // ==== Writeback ====


            if (!reset) begin
                for (int i = 0; i < WB_WIDTH; i++) begin
                    if (wb_valid_i[i] && rob_table[wb_rob_idx_i[i]].valid) begin  
                        `ifndef SYNTHESIS
                        // $display("bug value= %d | rob=%d",fu_value_wb_i[i],wb_rob_idx_i[i] );
                        `endif
                        rob_table[wb_rob_idx_i[i]].ready     <= 1'b1;
                        rob_table[wb_rob_idx_i[i]].exception <= wb_exception_i[i];
                        rob_table[wb_rob_idx_i[i]].mispred   <= wb_mispred_i[i];
                        rob_table[wb_rob_idx_i[i]].value   <= fu_value_wb_i[i]; //### sychenn 11/7 ###/
                    end
                end
                if(rob_store_ready_valid) begin
                    rob_table[rob_store_ready_idx].ready <= 1'b1;
                end
            end
        end
    end


    // always_ff @(negedge clock)begin
    //    // $display("head = %0d  , tail = %0d\n" , head, tail);
    //    $display("disp_rob_idx_o=%d | commit_old_prf_o: %d", disp_rob_idx_o[0], commit_old_prf_o[0]);
    // end
// `ifndef SYNTHESIS
// task automatic show_rob_output();
//     // $display("============================================");
//     // $display("                 ROB STATUS                 ");
//     // $display("============================================");
//     // $display("Head = %0d | Tail = %0d | Count = %0d | Full = %b | Empty = %b", 
//     //          head, tail, count, full, empty);
//     for (int i = 0; i < ROB_DEPTH; i++) begin
//         if (rob_table[i].valid) begin
//             // $display("Entry %0d: Value=%h, PC=%h , valid=%b, ready=%b, rd_wen=%b, rd_arch=%0d, new_prf=%0d, old_prf=%0d, exception=%b, mispred=%b",
//             //          i, 
//             //          rob_table[i].value,
//             //          rob_table[i].PC,
//             //          rob_table[i].valid,
//             //          rob_table[i].ready,
//             //          rob_table[i].rd_wen,
//             //          rob_table[i].rd_arch,
//             //          rob_table[i].new_prf,
//             //          rob_table[i].old_prf,
//             //          rob_table[i].exception,
//             //          rob_table[i].mispred);
//         end else begin
//             // $display("Entry %0d: --- empty ---", i);
//         end
//     end
//     // $display("============================================");
// endtask

//    // =========================================================
//     // For GUI Debugger
//     // =========================================================
//     integer rob_trace_fd;

//     initial begin
//         rob_trace_fd = $fopen("dump_files/rob_trace.json", "w");
//         if (rob_trace_fd == 0)
//             $fatal("Failed to open dump_files/rob_trace.json!");
//     end

//     task automatic dump_rob_state(int cycle);
//         $fwrite(rob_trace_fd, "{ \"cycle\": %0d, \"ROB\": [", cycle);
//         for (int i = 0; i < ROB_DEPTH; i++) begin
//             if (rob_table[i].valid) begin
//                 automatic rob_entry_t e = rob_table[i];
//                 $fwrite(rob_trace_fd,
//                     "{\"idx\":%0d, \"valid\":%0d, \"ready\":%0d, \"rd_wen\":%0d,\"rd_arch\":%0d, \"new_prf\":%0d, \"old_prf\":%0d,\"exception\":%0d, \"mispred\":%0d}",
//                     i, e.valid, e.ready, e.rd_wen, e.rd_arch,
//                     e.new_prf, e.old_prf, e.exception, e.mispred);
//             end else begin
//                 $fwrite(rob_trace_fd, "{\"idx\":%0d, \"valid\":0}", i);
//             end

//             if (i != ROB_DEPTH - 1)
//                 $fwrite(rob_trace_fd, ",");
//         end
//         $fwrite(rob_trace_fd, "]}\n");
//         $fflush(rob_trace_fd); 
//     endtask


//     int cycle_count;
//     always_ff @(posedge clock) begin
//         if (reset) begin
//             cycle_count <= 0;
//         end else begin
//             cycle_count <= cycle_count + 1;
//             dump_rob_state(cycle_count);
//             show_rob_output();
//         end
//     end
// `endif

endmodule


