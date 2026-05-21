/////////////////////////////////////////////////////////////////////////
//                                                                     //
//   Modulename :  free_list.sv                                        //
//                                                                     //
//  Description : 
//  - Free List for R10K-like OoO Processor
//  - Keeps track of available physical registers
//  - Supports simultaneous allocation (dispatch) and release (commit)
//  - Release-first policy (commit reg becomes available same cycle)
//                                                                     //
/////////////////////////////////////////////////////////////////////////

module free_list #(
    parameter int unsigned DISPATCH_WIDTH  = 1,
    parameter int unsigned COMMIT_WIDTH    = 1,
    parameter int unsigned ARCH_REGS       = 64,
    parameter int unsigned PHYS_REGS       = 128
)(
    input  logic clock,
    input  logic reset,

    // =========================================================
    // Dispatch <-> free list: allocate new physical registers
    // =========================================================
    input  logic [DISPATCH_WIDTH-1:0]                        alloc_req_i,  // requests new PRF
    output logic [DISPATCH_WIDTH-1:0][$clog2(PHYS_REGS)-1:0] alloc_phys_o, // allocated PRF numbers
    output logic [DISPATCH_WIDTH-1:0]                        alloc_valid_o, // whether each alloc succeed
    output logic                                             full_o,       // true if no free regs left
output logic [$clog2(PHYS_REGS+1)-1:0]                       free_count_o, // number of free regs
    // output logic [DISPATCH_WIDTH-1:0]                       new_reg_o,
    // output logic [$clog2(DISPATCH_WIDTH)-1:0]               free_regs_o,   // how many regsiters are free? (saturate at DISPATCH_WIDTH)
    // output logic                                            empty_o,

    // =========================================================
    // Commit -> free list: release old physical registers
    // =========================================================
    input  logic [COMMIT_WIDTH-1:0]                         free_valid_i,  //not all instructions will release reg (ex:store)
    input  logic [COMMIT_WIDTH-1:0][$clog2(PHYS_REGS)-1:0]  free_phys_i,
    // output logic [$clog2(PHYS_REGS)-1:0] free_fifo_debug [PHYS_REGS-1:0];   


    //### TODO: for debug only (sychenn 11/6) ###//
    input  logic flush_i,
    input logic [`ROB_DEPTH-1:0] flush_free_regs_valid, /// unused
    input logic [(PHYS_REGS)-1:0]  flush_free_regs,

    //rob
    input logic [DISPATCH_WIDTH-1:0][$clog2(PHYS_REGS)-1:0] flush2free_list_new_prf_i,
    input logic [DISPATCH_WIDTH-1:0] flush2free_list_valid_i

);

    // =========================================================
    // Internal storage for free registers
    // =========================================================
    // free free list 
    logic [(COMMIT_WIDTH + DISPATCH_WIDTH + PHYS_REGS -1):0] total_free_valid;
    logic [(COMMIT_WIDTH + DISPATCH_WIDTH + PHYS_REGS -1):0][$clog2(PHYS_REGS)-1:0] total_free_reg_idx;

    logic [$clog2(PHYS_REGS)-1:0] free_fifo [PHYS_REGS-ARCH_REGS-1:0];
    logic [$clog2(PHYS_REGS)-1:0] head, tail;
    logic [$clog2(PHYS_REGS):0]   count;

    logic [$clog2(PHYS_REGS)-1:0] next_head, next_tail;
    logic [$clog2(PHYS_REGS):0]    next_count;
    logic [$clog2(PHYS_REGS):0]    next_count_debug;

    // Used to track simultaneous transactions
    int N_alloc; // Actual number of successful allocations (0 to DISPATCH_WIDTH)
    int N_free;  // Actual number of successful releases (0 to COMMIT_WIDTH)
    int total_available;

    assign free_count_o = count;
    // ###
    // assign free_count_o = (tail > head ? (tail - head) - 1 : (ARCH_REGS - (head - tail)) - 1);
    // assign full_o = (count < DISPATCH_WIDTH);
    assign full_o = (count == 0);
    // assign full_o = ((tail > head ? (tail - head) - 1 : (ARCH_REGS - (head - tail)) - 1) < DISPATCH_WIDTH);

    /////////////////////////////////////////////////////////////////////////
    // always_comb begin
    //     next_head = head;
    //     next_tail = tail;
    //     N_alloc = 0;
    //     for(int i = 0 ; i< DISPATCH_WIDTH ; i++)begin
    //         if(alloc_req_i[i] && (count - N_alloc) > 0 )begin
    //             // Read from the FIFO: use the current head offset by N_alloc
    //             alloc_phys_o[i] = free_fifo[(head + N_alloc) % (PHYS_REGS - ARCH_REGS)];
    //             alloc_valid_o[i] = 1'b1;
    //             N_alloc++;
    //         end else begin
    //             alloc_phys_o[i] = '0;
    //             alloc_valid_o[i] = 1'b0;
    //         end
    //     end

    //     // Update next_head based on total successful allocations
    //     if (N_alloc > 0) begin
    //         next_head = (head + N_alloc) % (PHYS_REGS - ARCH_REGS);
    //     end

    //     //calculate N_free
    //     N_free = 0;
    //     for (int j = 0; j < COMMIT_WIDTH; j++) begin
    //         if (free_valid_i[j]) begin
    //             N_free++;
    //         end
    //     end
    //     int total_available = count + N_free;
    //     // Update next_tail based on total releases
    //     if(N_free > 0 )begin
    //         next_tail = (tail + N_free) % (PHYS_REGS - ARCH_REGS);
    //     end

    //     //Calculate Final next_count
    //     next_count = count + N_free - N_alloc;
    // end

    /////////////////////////////////////////////////////////////////////////
    always_comb begin
        
        // --- 1. 計算 N_free (釋放的數量) ---
        // retire
        N_free = 0;
        for (int j = 0; j < COMMIT_WIDTH; j++) begin
            if (free_valid_i[j]) begin
                N_free++;
            end
        end
        // dispatch (free the instruction that stole the free reg)
        for (int j2 = 0; j2 < DISPATCH_WIDTH; j2++) begin
            if (flush2free_list_valid_i[j2] && (flush2free_list_new_prf_i[j2] != 0)) begin
                N_free++;
            end
        end
        // chcekpoint (when flush)
        if (flush_i) begin
            for (int k = 0; k <(PHYS_REGS); k++) begin
                if (flush_free_regs[k]) begin
                    N_free++;
                    `ifndef SYNTHESIS
                    // $display("flush N_free= %d ", N_free);
                    `endif
                end
            end
        end  

        // 總可用資源：舊 count + N_free (體現 Release-first policy)
        total_available = count + N_free; 

        // --- 2. 計算 N_alloc 和分配輸出 ---
        next_head = head; // 預設值
        N_alloc = 0;
        
        for(int i = 0 ; i< DISPATCH_WIDTH ; i++)begin
            // 檢查：請求是否有效 AND 總可用資源是否大於 N_alloc (已分配的數量)
            if(alloc_req_i[i] && (total_available - N_alloc) > 0 )begin
                
                // 讀取位址：head 偏移 N_alloc (讀取隊列中第 N_alloc 個)
                alloc_phys_o[i] = free_fifo[(head + N_alloc) % (PHYS_REGS - ARCH_REGS)];
                alloc_valid_o[i] = 1'b1;
                
                N_alloc++;
            end else begin
                alloc_phys_o[i] = '0;
                alloc_valid_o[i] = 1'b0;
            end
        end

        // --- 3. 更新 next_head / next_tail / next_count ---
        
        // next_head：舊 head + 成功分配的數量
        if (N_alloc > 0) begin
            next_head = (head + N_alloc) % (PHYS_REGS - ARCH_REGS);
        end else begin
            next_head = head; // 沒有分配則不移動
        end

        // next_tail：舊 tail + 成功釋放的數量
        if(N_free > 0 )begin
            next_tail = (tail + N_free) % (PHYS_REGS - ARCH_REGS);
        end else begin
            next_tail = tail; // 沒有釋放則不移動
        end

        // Final next_count = 舊 count + N_free - N_alloc
        next_count = '0;
        if(next_tail == next_head) begin
            next_count = '0;
        end else if(next_tail > next_head) begin
            next_count = next_tail - next_head;
        end else begin
            next_count = ARCH_REGS - (next_head - next_tail);
        end
        // next_count = 2;
    end

    int id;
    // commmit :1 ; flush:2  
    // 1110000.. -> 111x000000
    // 36 ? ? -> x 1 2
    always_comb begin
        id = 0;
        total_free_valid = '0;
        total_free_reg_idx = '0;
        // retire
        if (id < (COMMIT_WIDTH + DISPATCH_WIDTH + `ROB_DEPTH)) begin
            for (int j = 0; j < COMMIT_WIDTH; j++) begin
                if (free_valid_i[j] && (free_phys_i[j] != 0)) begin
                    total_free_valid[id]   = 1;
                    total_free_reg_idx[id] = free_phys_i[j];
                    id ++;
                end
            end
            // flush
            for (int j2 = 0; j2 < DISPATCH_WIDTH; j2++) begin
                if (flush2free_list_valid_i[j2] && (flush2free_list_new_prf_i[j2] != 0)) begin
                    total_free_valid[id]   = 1;
                    total_free_reg_idx[id] = flush2free_list_new_prf_i[j2];
                    id ++;
                end
            end

            // chcekpoint
            if (flush_i) begin
                for (int j3 = 0;  j3 <(PHYS_REGS);  j3++) begin
                    if (flush_free_regs[j3]) begin
                        total_free_valid[id]   = 1;
                        total_free_reg_idx[id] = j3;
                        id ++;
                    end
                end
            end  
        end
    end

    ///////////////////////////////////////////////////////////////////////////////////////////

    // =========================================================
    // Initialize free list
    // =========================================================
    always_ff @(posedge clock) begin
        if (reset) begin
            head  <= '0;
            tail  <= PHYS_REGS - ARCH_REGS - 1;
            count <= PHYS_REGS - ARCH_REGS;
            for (int i = 0 ; i < (PHYS_REGS-ARCH_REGS) ; i++)begin
                free_fifo[i] <= i + ARCH_REGS; 
                // $display("free_fifo[%0d] = %0d" , i , free_fifo[i]);
            end
        end else begin
            // `ifndef SYNTHESIS
            // $display("flush_free_regs =%b" , flush_free_regs);
            // `endif
  
            head <= next_head;
            tail <= next_tail;
            count <= next_count;

            // =========================================================
            //  Release (Commit) — push freed physical regs back
            // ==============================================================
            for (int k = 0; k < (COMMIT_WIDTH + DISPATCH_WIDTH + PHYS_REGS); k++) begin
                if (total_free_valid[k]) begin
                    free_fifo[(tail + k) % (PHYS_REGS-ARCH_REGS)] <= total_free_reg_idx[k];
                    `ifndef SYNTHESIS
                    // $display("free reg[%0d] = %0d" , (tail + k) % (PHYS_REGS-ARCH_REGS) , total_free_reg_idx[k]);
                    `endif
                end
            end

            // =====================================================
            // Allocation (Dispatch)
            // =====================================================
            // for(int i = 0; i < DISPATCH_WIDTH ; i++)begin
            //     if(alloc_req_i[i] && (count > 0))begin
            //         alloc_phys_o[i] <= free_fifo[head];
            //         alloc_valid_o[i] <= 1'b1;
            //         head = (head+1) % (PHYS_REGS - ARCH_REGS);
            //         count = count -1 ; 
            //     end
            //     else begin
            //         alloc_phys_o[i] <= '0;
            //         alloc_valid_o[i] <= 1'b0;
            //     end
            // end
        end
    end 
    
// `ifndef SYNTHESIS
//     always_ff @(negedge clock)begin 
//         $display("free_phys = %0d , free_valid = %d\n", free_phys_i , free_valid_i);
//         $display("N_alloc=%d, N_free=%d", N_alloc, N_free);
//         $display("next: head: %d , tail: %d, count: %d, next_count_debug: %d" , next_head, next_tail, next_count, next_count_debug);
//         $display("head: %d , tail: %d, count: %d, full: %b" , head, tail, count, full_o);
//         for(int i =0 ; i< (PHYS_REGS-ARCH_REGS); i++)begin
//             $display("free_fifo[%d] = %0d ", i, free_fifo[i]);
//         end
//     end
    
//     always_ff @(posedge clock) begin 
//         $display("total_available = %0d", total_available);
//     end
// `endif

endmodule