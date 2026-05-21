`include "sys_defs.svh"

module dcache (
    input clock, reset,
    
    // Request from LOAD unit
    input  ADDR        Dcache_addr_0,      // Request 0
    input  MEM_COMMAND Dcache_command_0, // MEM_LOAD or MEM_STORE or MEM_NONE
    input  MEM_SIZE    Dcache_size_0, // WORD/BYTE/HALF
    input  MEM_BLOCK   Dcache_store_data_0, // load = 0
    input  ROB_IDX     Dcache_req_rob_idx_0,

    output logic       Dcache_req_0_accept, // if bank conflict (two request go to the same bank), it might be 0 and need to be resent at the next cycle
    output MEM_BLOCK   Dcache_data_out_0,
    output logic       Dcache_valid_out_0,  //data valid (load)
    output ROB_IDX     Dcache_data_rob_idx_0,
    output logic       Dcache_store_valid_0, // store valid
    
    input  ADDR        Dcache_addr_1,      // Request 1
    input  MEM_COMMAND Dcache_command_1,
    input  MEM_SIZE    Dcache_size_1,
    input  MEM_BLOCK   Dcache_store_data_1,
    input  ROB_IDX     Dcache_req_rob_idx_1,

    output logic       Dcache_req_1_accept,  // if bank conflict (two request go to the same bank), it might be 0
    output MEM_BLOCK   Dcache_data_out_1,
    output logic       Dcache_valid_out_1,  //data valid (load)
    output ROB_IDX     Dcache_data_rob_idx_1,
    output logic       Dcache_store_valid_1, // store valid
    
    // Memory interface (non-blocking)
    output MEM_COMMAND Dcache2mem_command,
    output ADDR        Dcache2mem_addr,
    output MEM_SIZE    Dcache2mem_size,
    output MEM_BLOCK   Dcache2mem_data,
    output logic       send_new_mem_req,
    
    input  MEM_TAG   mem2proc_transaction_tag, //Tell you the tag for this to mem request (1 cycle after sending request)
    input  MEM_BLOCK mem2proc_data,
    input  MEM_TAG   mem2proc_data_tag,

    // Halt by WFI and write back to memory
    input logic halt_by_wfi,
    output logic finished_wb_to_mem
);

    // =========================================================
    // Cache configuration
    // =========================================================

    // Cache parameters
    parameter int CACHE_SIZE = 256;
    parameter int LINE_SIZE = (`XLEN /8) * 2; //8 Bytes
    parameter int CACHE_WAYS = 4;             // 4-way associative
    parameter int BANKS = 2;                  // 2 banks for dual-port
    parameter int CACHE_LINES = 256 / LINE_SIZE;           // Total lines (32 lines)
    parameter int BANK_SIZE = CACHE_LINES / BANKS; // Total lines per bank (16 lines / bank)
    parameter int SETS_PER_BANK = BANK_SIZE / CACHE_WAYS; //4 sets per bank

    parameter int VICTIM_SIZE = 8;            // Victim cache entries
    parameter int MSHR_SIZE = 4;             // Outstanding requests

    // Bits parameters
    parameter int BANK_BITS = $clog2(BANKS); // # bank = 2 (1 bit)
    parameter int OFFSET_BITS = $clog2(LINE_SIZE); // # offset = 8 bytes (3 bits)
    parameter int INDEX_BITS = $clog2(BANK_SIZE / CACHE_WAYS);      // # set = 4 = 16 lines / 4 ways (2 bits per bank)
    parameter int TAG_BITS = `XLEN - INDEX_BITS - OFFSET_BITS - BANK_BITS; // 3 for byte offset

    // =========================================================
    // Cache helper bits
    // =========================================================
    // ----------  Banked, associative storage ----------
    logic [TAG_BITS-1:0]       cache_tags [BANKS-1:0][SETS_PER_BANK-1:0][CACHE_WAYS-1:0];
    logic [CACHE_WAYS-1:0]     cache_valid[BANKS-1:0][SETS_PER_BANK-1:0];
    logic [CACHE_WAYS-1:0]     cache_dirty[BANKS-1:0][SETS_PER_BANK-1:0];


    // ---------- LRU tracking for replacement ---------- 
    logic [$clog2(CACHE_WAYS)-1:0] lru_bits [BANKS-1:0][SETS_PER_BANK-1:0][CACHE_WAYS-1:0];

  
    // =========================================================
    // Cache Control
    // =========================================================
    // ----------  Address breakdown ---------- 
    logic [TAG_BITS-1:0] tag_0, tag_1;
    logic [INDEX_BITS-1:0] index_0, index_1;
    logic [OFFSET_BITS-1:0] offset_0, offset_1;
    logic [BANK_BITS-1:0] bank_0, bank_1;

    assign bank_0 = Dcache_addr_0[OFFSET_BITS +: BANK_BITS];
    assign offset_0 = Dcache_addr_0[0 +: OFFSET_BITS];
    assign index_0 =  Dcache_addr_0[OFFSET_BITS + BANK_BITS +: INDEX_BITS];
    assign tag_0 =  Dcache_addr_0[31 : OFFSET_BITS + BANK_BITS + INDEX_BITS];

    assign bank_1  = Dcache_addr_1[OFFSET_BITS +: BANK_BITS];
    assign offset_1 = Dcache_addr_1[0 +: OFFSET_BITS];
    assign index_1 = Dcache_addr_1[OFFSET_BITS + BANK_BITS +: INDEX_BITS];
    assign tag_1   = Dcache_addr_1[31 : OFFSET_BITS + BANK_BITS + INDEX_BITS];

    // ----------  Bank determiniation ---------- (turn #request to #BANK)
    logic req_0_to_bank_0, req_0_to_bank_1, req_1_to_bank_0, req_1_to_bank_1;
    logic req_0_accept,req_1_accept; //whether request has assign to bank

    //### load & store both can use ###//
    assign req_0_to_bank_0 = (Dcache_command_0 != MEM_NONE) && !bank_0;
    assign req_0_to_bank_1 = (Dcache_command_0 != MEM_NONE) && bank_0;
    assign req_1_to_bank_0 = (Dcache_command_1 != MEM_NONE) && !req_0_to_bank_0 && !bank_1;
    assign req_1_to_bank_1 = (Dcache_command_1 != MEM_NONE) && !req_0_to_bank_1 && bank_1;

    assign req_0_accept = req_0_to_bank_0 || req_0_to_bank_1;
    assign req_1_accept = req_1_to_bank_0 || req_1_to_bank_1;

    // ----------  Cache Hit Detection ----------       
    //### The 1/0 here is from CPU REQUEST not bank ###//
    //### load & store both can use ###//
    logic [CACHE_WAYS-1:0] way_hit_0, way_hit_1;  // all ways hit =1 , miss = 0 (ex: 0010)
    logic [1:0] hit_way_0, hit_way_1;  //which way hit (ex: 2)
    logic cache_hit_0, cache_hit_1, load_cache_hit_0, load_cache_hit_1, store_cache_hit_0, store_cache_hit_1;

    int refill_mshr_id;
    logic refill_enable;
    logic transaction_data_tag_the_same_time;

    always_comb begin
        way_hit_0 = '0;
        way_hit_1 = '0;
        hit_way_0 = 0;
        hit_way_1 = 0;
        
        // Check all ways for hits using arrays (valid and tag match)
        for (int w = 0; w < CACHE_WAYS; w++) begin
            way_hit_0[w] = cache_valid[bank_0][index_0][w] && (cache_tags[bank_0][index_0][w] == tag_0);
            way_hit_1[w] = cache_valid[bank_1][index_1][w] && (cache_tags[bank_1][index_1][w] == tag_1);
        end
        
        // hit or miss
        cache_hit_0 = (|way_hit_0);
        cache_hit_1 = (|way_hit_1);

        load_cache_hit_0 = cache_hit_0 && Dcache_command_0 == MEM_LOAD;
        load_cache_hit_1 = cache_hit_1 && Dcache_command_1 == MEM_LOAD;

        store_cache_hit_0 = cache_hit_0 && Dcache_command_0 == MEM_STORE;
        store_cache_hit_1 = cache_hit_1 && Dcache_command_1 == MEM_STORE;

        // check which way hit
        for (int w = 0; w < CACHE_WAYS; w++) begin
            if (way_hit_0[w]) hit_way_0 = w;
            if (way_hit_1[w]) hit_way_1 = w;
        end
    end

    // =========================================================
    // Cache Signals (sent to mem_dp)
    // =========================================================
    // ---------- READ ---------- 
    // Read enable signals
    logic cache_read_en_0, cache_read_en_1;
    // Read addresses 
    logic [INDEX_BITS-1:0] cache_read_addr_0;
    logic [INDEX_BITS-1:0] cache_read_addr_1;
    // Read Data
    MEM_BLOCK [CACHE_WAYS-1:0] cache_data_read_0 ;
    MEM_BLOCK [CACHE_WAYS-1:0] cache_data_read_1;
    MEM_BLOCK line_data_0, line_data_1;  //this is the read result in the whole line format
    MEM_BLOCK updated_line_0 ,updated_line_1; // if store: modified the line and put it back to the cache line
    
    // ---------- WRITE ---------- 
    // Write enable signals
    logic  [CACHE_WAYS-1:0] write_en_0;  //comb
    logic  [CACHE_WAYS-1:0] write_en_1;  //comb 
    logic  [CACHE_WAYS-1:0] cache_write_en_0; // reg send to mem_dp
    logic  [CACHE_WAYS-1:0] cache_write_en_1; // reg send to mem_dp
    
    logic  [CACHE_WAYS-1:0] cache_write_en_hit_0;
    logic  [CACHE_WAYS-1:0] cache_write_en_hit_1;
    logic  [CACHE_WAYS-1:0] cache_write_en_refill_0;
    logic  [CACHE_WAYS-1:0] cache_write_en_refill_1;

    // Write addresses 
    logic [INDEX_BITS-1:0] cache_write_addr_0, cache_write_addr_hit_0, cache_write_addr_refill_0;
    logic [INDEX_BITS-1:0] cache_write_addr_1, cache_write_addr_hit_1, cache_write_addr_refill_1;

    // Write Data
    MEM_BLOCK cache_write_data_0, cache_write_data_hit_0, cache_write_data_refill_0;
    MEM_BLOCK cache_write_data_1, cache_write_data_hit_1, cache_write_data_refill_1;

    // here 0/1 means banks
    genvar w;
    for (w = 0; w < CACHE_WAYS; w++) begin
        assign write_en_0[w] = (!halt_by_wfi) ? cache_write_en_hit_0[w] | cache_write_en_refill_0[w] : '0;
        assign write_en_1[w] = (!halt_by_wfi) ? cache_write_en_hit_1[w] | cache_write_en_refill_1[w] : '0;
        // assign write_en_0[w] = cache_write_en_hit_0[w] | cache_write_en_refill_0[w];
        // assign write_en_1[w] = cache_write_en_hit_1[w] | cache_write_en_refill_1[w];
    end

    // assign cache_write_addr_0 =
    //     (|cache_write_en_0) ? (|cache_write_en_refill_0) ? cache_write_addr_refill_0 : cache_write_addr_hit_0 : '0;
    // assign cache_write_addr_1 =
    //     (|cache_write_en_1) ? (|cache_write_en_refill_1) ? cache_write_addr_refill_1 : cache_write_addr_hit_1 : '0;

    always_ff @( posedge clock) begin 
        if (reset) begin
            cache_write_data_0 <= '0;
            cache_write_data_1 <= '0;

            cache_write_addr_0 <= '0;
            cache_write_addr_1 <= '0;
            cache_write_en_0 <= '0;
            cache_write_en_1 <= '0;
        end else begin
            if (|write_en_0) begin
                cache_write_data_0 <= (|cache_write_en_refill_0) ? cache_write_data_refill_0 : cache_write_data_hit_0;
                cache_write_addr_0 <= (|cache_write_en_refill_0) ? cache_write_addr_refill_0 : cache_write_addr_hit_0;
                cache_write_en_0 <= write_en_0;
            end else begin
                cache_write_data_0 <= '0;
                cache_write_addr_0 <= '0;
                cache_write_en_0   <= '0;
            end

            if (|write_en_1) begin
                cache_write_data_1 <= (|cache_write_en_refill_1) ? cache_write_data_refill_1 : cache_write_data_hit_1;
                cache_write_addr_1 <= (|cache_write_en_refill_1) ? cache_write_addr_refill_1 : cache_write_addr_hit_1;
                cache_write_en_1 <= write_en_1;
            end else begin
                cache_write_data_1 <= '0;
                cache_write_en_1   <= '0;
                cache_write_addr_1 <= '0;
            end
        end
    end

    // assign cache_write_data_0 =
    //     (|cache_write_en_0) ? (|cache_write_en_refill_0) ? cache_write_data_refill_0 : cache_write_data_hit_0 : '0;
    // assign cache_write_data_1 =
    //     (|cache_write_en_1) ? (|cache_write_en_refill_1) ? cache_write_data_refill_1 : cache_write_data_hit_1 : '0;

    // =========================================================
    // Main Cache Arrays
    // =========================================================
    // even bank (bank bit = 0)
    genvar i;
    for (i = 0; i < CACHE_WAYS; i++) begin : gen_cache_data_bank_even
        memDP #(
            .WIDTH(LINE_SIZE * 8),           // MEM_BLOCK width (in bytes)
            .DEPTH(SETS_PER_BANK),  // = set size = 4 (each DP contains 1 way)
            .READ_PORTS(1),       
            .BYPASS_EN(1)         // Enable bypass for write-through
        ) cache_data_0 (
            .clock(clock),
            .reset(reset),
            .re(cache_read_en_0),
            .raddr(cache_read_addr_0),
            .rdata(cache_data_read_0[i]),
            .we(cache_write_en_0[i]),
            .waddr(cache_write_addr_0),
            .wdata(cache_write_data_0)
        );
    end 

    // odd bank (bank bit = 1)
    genvar j;
    for (j = 0; j < CACHE_WAYS; j++) begin : gen_cache_data_bank_odd
        memDP #(
            .WIDTH(LINE_SIZE * 8),           // MEM_BLOCK width (in bytes)
            .DEPTH(SETS_PER_BANK),  //= set size (each DP contains 1 way)
            .READ_PORTS(1),       
            .BYPASS_EN(1)         // Enable bypass for write-through
        ) cache_data_1 (
            .clock(clock),
            .reset(reset),
            .re(cache_read_en_1),
            .raddr(cache_read_addr_1),
            .rdata(cache_data_read_1[j]), // read 4 ways
            .we(cache_write_en_1[j]), // which way to write (write one way)
            .waddr(cache_write_addr_1), //index (set)
            .wdata(cache_write_data_1)
        );
    end

    // ---------- WFI Logic ----------  
    // cycle k founds dirty cache line (wfi_found_dirty = 1)
    // cycle k+1 (1) gets dirty line bank set way 
    //           (2) gets dirty line data (send_wfi_to_mem = 1, send signal to cache (cache_en = 1)) 
    //           (3) sends dirty line to memory
    //           (4) clear dirty bit
    
    typedef enum logic [1:0] {
        WFI_IDLE,
        WFI_WRITING_BACK,
        WFI_DONE
    } wfi_state_t;

    wfi_state_t wfi_state, wfi_state_next;

    assign finished_wb_to_mem = (wfi_state == WFI_DONE);

    // Track which cache line we're currently writing back
    logic [$clog2(BANKS)-1:0]          wfi_bank, wfi_bank_next;
    logic [$clog2(SETS_PER_BANK)-1:0]  wfi_set, wfi_set_next;
    logic [$clog2(CACHE_WAYS)-1:0]     wfi_way, wfi_way_next;
    MEM_BLOCK wfi_cache_data;

    logic wfi_found_dirty;
    logic send_wfi_to_mem;

    logic [$clog2(`MEM_LATENCY_IN_CYCLES+1)-1:0] latency;
    logic [$clog2(`MEM_LATENCY_IN_CYCLES+1)-1:0] latency_counter, latency_counter_next;
    assign latency = `MEM_LATENCY_IN_CYCLES;

    // Scan for dirty cache lines
    always_comb begin
        wfi_found_dirty = 1'b0;

        wfi_bank_next = wfi_bank;
        wfi_set_next = wfi_set;
        wfi_way_next = wfi_way;
        
        // Check if current line is dirty and valid
        if (wfi_state == WFI_WRITING_BACK) begin
            // Scan dirty cache lines
            for (int b = 0; b < BANKS; b++) begin
                for (int s = 0; s < SETS_PER_BANK; s++) begin
                    for (int w = 0; w < CACHE_WAYS; w++) begin
                        if (cache_dirty[b][s][w] && cache_valid[b][s][w]) begin
                            wfi_bank_next = b;
                            wfi_set_next = s;
                            wfi_way_next = w;
                            wfi_found_dirty = 1'b1;
                        end
                    end
                end
            end
        end
    end

    always_comb begin
        wfi_state_next = wfi_state;
        latency_counter_next = latency_counter;
        
        case (wfi_state)
            WFI_IDLE: begin
                if (halt_by_wfi) begin
                    latency_counter_next ++;
                    if (latency_counter == latency) begin
                        wfi_state_next = WFI_WRITING_BACK;
                    end
                end
            end
            
            WFI_WRITING_BACK: begin
                // If still has dirty cache line => keep writing back
                if (wfi_found_dirty) begin
                    wfi_state_next = WFI_WRITING_BACK;  // Continue scanning
                end else begin
                    wfi_state_next = WFI_DONE;
                end
            end
            
            WFI_DONE: begin
                if (!halt_by_wfi) begin
                    wfi_state_next = WFI_IDLE;
                end
            end
        endcase
    end

    // Sequential logic for WFI scanning
    always_ff @(posedge clock) begin 
        if (reset) begin
            wfi_state <= WFI_IDLE;
            wfi_bank  <= '0;
            wfi_set   <= '0;
            wfi_way   <= '0;
            latency_counter <= '0;
            send_wfi_to_mem <= '0;
        end else begin
            wfi_state <= wfi_state_next;
            wfi_bank <= wfi_bank_next;
            wfi_set <= wfi_set_next;
            wfi_way <= wfi_way_next;
            latency_counter <= latency_counter_next;
            send_wfi_to_mem <= (wfi_state == WFI_WRITING_BACK && wfi_found_dirty);
        end
    end
    
    // WFI cache get data from the same cycle
    assign wfi_cache_data = (wfi_bank == 1'b0) ? cache_data_read_0[wfi_way] : cache_data_read_1[wfi_way];

    // =========================================================
    // Load (Read) Logic 
    // if this cycle accept :
    //    if cache hit : read hit line
    //    if cache miss: read replace line (for wb to mem)
    // => always read the cache when request was accepeted (it will output 4 ways)
    //
    // ### Cannot use load_cache_hit because it still need to read the whole line while write! ###//
    // =========================================================  
    // ----------  Read enable signals ----------    
    logic wfi_read_en;
    logic wb_mem_read_en;
    // wb address ( the one that were replaced )
    logic [TAG_BITS-1:0]   victim_tag;
    logic [INDEX_BITS-1:0] victim_index;
    logic [BANK_BITS-1:0]  victim_bank;
    logic [$clog2(CACHE_WAYS)-1:0] victim_way;
    assign wfi_read_en = (wfi_state == WFI_WRITING_BACK && send_wfi_to_mem);
    
    assign cache_read_en_0 = (req_0_to_bank_0 && Dcache_req_0_accept) || (req_1_to_bank_0 && Dcache_req_1_accept) || 
                             (wfi_read_en && wfi_bank == 1'b0) || (wb_mem_read_en && victim_bank == 1'b0);
    assign cache_read_en_1 = (req_0_to_bank_1 && Dcache_req_0_accept) || (req_1_to_bank_1 && Dcache_req_1_accept) || 
                             (wfi_read_en && wfi_bank == 1'b1) || (wb_mem_read_en && victim_bank == 1'b1);

    // ----------  Assign Read address ----------    
    // Only need index to determine which set 

    assign cache_read_addr_0 = wfi_read_en && (wfi_bank == 1'b0) ? wfi_set : 
                               (req_0_to_bank_0) ? index_0 : (req_1_to_bank_0) ? index_1 : '0;
    assign cache_read_addr_1 = wfi_read_en && (wfi_bank == 1'b1) ? wfi_set : 
                               (req_0_to_bank_1) ? index_0 : (req_1_to_bank_1) ? index_1 : '0;

    // ----------  Get Read Result ---------- 
    always_comb begin
        Dcache_valid_out_0 = 0; //Actually Dcache_req_0_accept contains (Dcache_command_0 != MEM_NONE)
        Dcache_valid_out_1 = 0;
        Dcache_data_out_0 = '0; //8 byte per line = 64 bits
        Dcache_data_out_1 = '0;
        Dcache_data_rob_idx_0 = '0;
        line_data_0 = '0;
        line_data_1 = '0;

        if (cache_hit_0) begin
            if (req_0_to_bank_0) line_data_0 = cache_data_read_0[hit_way_0];
            else if (req_0_to_bank_1) line_data_1 = cache_data_read_1[hit_way_0];
        end 

        if (cache_hit_1) begin
            if (req_1_to_bank_0) line_data_0 = cache_data_read_0[hit_way_1];
            else if (req_1_to_bank_1) line_data_1 = cache_data_read_1[hit_way_1];
        end 


        // Choose the data to cpu by data size and offset
        // TODO: NEED TO HANDLE THE SAME CYCLE CACHE HIT/MSHR RESPONSE
        if ((load_cache_hit_0 && Dcache_req_0_accept) || (load_cache_hit_1 && Dcache_req_1_accept)) begin
            Dcache_valid_out_0 = load_cache_hit_0;
            Dcache_valid_out_1 = load_cache_hit_1;
            Dcache_data_rob_idx_0 = (load_cache_hit_0) ? Dcache_req_rob_idx_0 : '0;
            unique case (Dcache_size_0)
                BYTE:    Dcache_data_out_0.byte_level[0] = (req_0_to_bank_0) ? line_data_0.byte_level[offset_0] : line_data_1.byte_level[offset_0];
                HALF:    Dcache_data_out_0.half_level[0] = (req_0_to_bank_0) ? line_data_0.half_level[offset_0[OFFSET_BITS-1:1]] : line_data_1.half_level[offset_0[OFFSET_BITS-1:1]];
                WORD:    Dcache_data_out_0.word_level[0] = (req_0_to_bank_0) ? line_data_0.word_level[offset_0[OFFSET_BITS-1:2]] : line_data_1.word_level[offset_0[OFFSET_BITS-1:2]];
                DOUBLE:  Dcache_data_out_0.dbbl_level = (req_0_to_bank_0) ? line_data_0.dbbl_level : line_data_1.dbbl_level;
                default: Dcache_data_out_0.dbbl_level = (req_0_to_bank_0) ? line_data_0.dbbl_level : line_data_1.dbbl_level;
            endcase
            unique case (Dcache_size_1)
                BYTE:    Dcache_data_out_1.byte_level[0] = (req_1_to_bank_0) ? line_data_0.byte_level[offset_1] : line_data_1.byte_level[offset_1];
                HALF:    Dcache_data_out_1.half_level[0] = (req_1_to_bank_0) ? line_data_0.half_level[offset_1[OFFSET_BITS-1:1]] : line_data_1.half_level[offset_1[OFFSET_BITS-1:1]];
                WORD:    Dcache_data_out_1.word_level[0] = (req_1_to_bank_0) ? line_data_0.word_level[offset_1[OFFSET_BITS-1:2]] : line_data_1.word_level[offset_1[OFFSET_BITS-1:2]];
                DOUBLE:  Dcache_data_out_1.dbbl_level = (req_1_to_bank_0) ? line_data_0.dbbl_level : line_data_1.dbbl_level;
                default: Dcache_data_out_1.dbbl_level = (req_1_to_bank_0) ? line_data_0.dbbl_level : line_data_1.dbbl_level;
            endcase
            `ifndef SYNTHESIS
            // $display("[DCACHE] load_cache_hit_1=%h Dcache_req_rob_idx_1=%h mem2proc_data_tag=%h mshr[refill_mshr_id].mem_tag=%h mshr[refill_mshr_id].port_id=%h mshr[refill_mshr_id].rob_idx=%h", load_cache_hit_1, Dcache_req_rob_idx_1, mem2proc_data_tag, mshr[refill_mshr_id].mem_tag, mshr[refill_mshr_id].port_id, mshr[refill_mshr_id].rob_idx);
            `endif
        // Data from memory refill_mshr_id
        end else if ((mem2proc_data_tag == mshr[refill_mshr_id].mem_tag) && mshr[refill_mshr_id].valid && mshr[refill_mshr_id].command == MEM_STORE) begin
            Dcache_data_rob_idx_0 = (mshr[refill_mshr_id].port_id == 0) ? mshr[refill_mshr_id].rob_idx: '0;
            unique case (Dcache_size_0)
                BYTE:    Dcache_data_out_0.byte_level[0] = mem2proc_data.byte_level[offset_0];
                HALF:    Dcache_data_out_0.half_level[0] = mem2proc_data.half_level[offset_0[OFFSET_BITS-1:1]];
                WORD:    Dcache_data_out_0.word_level[0] = mem2proc_data.word_level[offset_0[OFFSET_BITS-1:2]];
                DOUBLE:  Dcache_data_out_0.dbbl_level = mem2proc_data.dbbl_level;
                default: Dcache_data_out_0.dbbl_level = mem2proc_data.dbbl_level;
            endcase
            unique case (Dcache_size_1)
                BYTE:    Dcache_data_out_1.byte_level[0] = mem2proc_data.byte_level[offset_1];
                HALF:    Dcache_data_out_1.half_level[0] = mem2proc_data.half_level[offset_1[OFFSET_BITS-1:1]];
                WORD:    Dcache_data_out_1.word_level[0] = mem2proc_data.word_level[offset_1[OFFSET_BITS-1:2]];
                DOUBLE:  Dcache_data_out_1.dbbl_level = mem2proc_data.dbbl_level;
                default: Dcache_data_out_1.dbbl_level = mem2proc_data.dbbl_level;
            endcase
        end
    end


    // =========================================================
    // Store (Write) Logic
    // =========================================================  
    // ----------  Write enable signals ----------    
    always_comb begin 
        for (int w = 0; w < CACHE_WAYS; w++) begin
            cache_write_en_hit_0[w] = 1'b0;
            cache_write_en_hit_1[w] = 1'b0;
        end
        // bank 0 enable
        if (store_cache_hit_0 && req_0_to_bank_0) begin
            cache_write_en_hit_0[hit_way_0] = 1'b1;
        end else if (store_cache_hit_1 && req_1_to_bank_0) begin
            cache_write_en_hit_0[hit_way_1] = 1'b1;
        end

        // bank 1 enable
        if (store_cache_hit_0 && req_0_to_bank_1) begin
            cache_write_en_hit_1[hit_way_0] = 1'b1;
        end else if (store_cache_hit_1 && req_1_to_bank_1) begin
            cache_write_en_hit_1[hit_way_1] = 1'b1;
        end
    end

    // ----------  Assign Write address ----------    
    // Only need index to determine which set 
    assign cache_write_addr_hit_0 = (req_0_to_bank_0 && store_cache_hit_0) ? index_0 : (req_1_to_bank_0 && store_cache_hit_1) ? index_1 : '0;
    assign cache_write_addr_hit_1 = (req_0_to_bank_1 && store_cache_hit_0) ? index_0 : (req_1_to_bank_1 && store_cache_hit_1) ? index_1 : '0;

    // ---------- Write Data ---------- 
    always_comb begin
        // banks 0/1
        updated_line_0 = line_data_0; // from read memDP
        updated_line_1 = line_data_1; // from read memDP

        // Get hit line and update the value we want to write 
        if (store_cache_hit_0) begin // req 0/1
            if (req_0_to_bank_0) begin
                unique case (Dcache_size_0) // req 0/1
                    BYTE:    updated_line_0.byte_level[offset_0] = Dcache_store_data_0.byte_level[0];
                    HALF:    updated_line_0.half_level[offset_0[OFFSET_BITS-1:1]] = Dcache_store_data_0.half_level[0];
                    WORD:    updated_line_0.word_level[offset_0[OFFSET_BITS-1:2]] = Dcache_store_data_0.word_level[0];
                    DOUBLE:  updated_line_0.dbbl_level = Dcache_store_data_0.dbbl_level;
                    default: updated_line_0.dbbl_level = Dcache_store_data_0.dbbl_level;
                endcase
            end else if (req_0_to_bank_1) begin
                unique case (Dcache_size_0)
                    BYTE:    updated_line_1.byte_level[offset_0] = Dcache_store_data_0.byte_level[0];
                    HALF:    updated_line_1.half_level[offset_0[OFFSET_BITS-1:1]] = Dcache_store_data_0.half_level[0];
                    WORD:    updated_line_1.word_level[offset_0[OFFSET_BITS-1:2]] = Dcache_store_data_0.word_level[0];
                    DOUBLE:  updated_line_1.dbbl_level = Dcache_store_data_0.dbbl_level;
                    default: updated_line_1.dbbl_level = Dcache_store_data_0.dbbl_level;
                endcase
            end
        end

        if (store_cache_hit_1) begin // req 0/1
            if (req_1_to_bank_0) begin
                unique case (Dcache_size_1)
                    BYTE:    updated_line_0.byte_level[offset_1] = Dcache_store_data_1.byte_level[0];
                    HALF:    updated_line_0.half_level[offset_1[OFFSET_BITS-1:1]] = Dcache_store_data_1.half_level[0];
                    WORD:    updated_line_0.word_level[offset_1[OFFSET_BITS-1:2]] = Dcache_store_data_1.word_level[0];
                    DOUBLE:  updated_line_0.dbbl_level = Dcache_store_data_1.dbbl_level;
                    default: updated_line_0.dbbl_level = Dcache_store_data_1.dbbl_level;
                endcase
            end else if (req_1_to_bank_1) begin
                unique case (Dcache_size_1)
                    BYTE:    updated_line_1.byte_level[offset_1] = Dcache_store_data_1.byte_level[0];
                    HALF:    updated_line_1.half_level[offset_1[OFFSET_BITS-1:1]] = Dcache_store_data_1.half_level[0];
                    WORD:    updated_line_1.word_level[offset_1[OFFSET_BITS-1:2]] = Dcache_store_data_1.word_level[0];
                    DOUBLE:  updated_line_1.dbbl_level = Dcache_store_data_1.dbbl_level;
                    default: updated_line_1.dbbl_level = Dcache_store_data_1.dbbl_level;
                endcase
            end
        end

        // store the updated line we write
        cache_write_data_hit_0 = updated_line_0;
        cache_write_data_hit_1 = updated_line_1;
    end

    // ----------  Cache Miss Path ----------     
    // 0/1 here is from REQUEST
    logic miss_0, miss_1;
    logic send_miss_0, send_miss_1;
    logic has_req_to_mem;
    logic [$clog2(CACHE_WAYS)-1:0] replace_way_0, replace_way_1;
    logic mshr_hit_0, mshr_hit_1;
    logic mshr_found;
    logic send_evict_to_mem;

    assign miss_0       = req_0_accept && !cache_hit_0; //req_0_accept contains !mem_none
    assign miss_1       = req_1_accept && !cache_hit_1;
    assign send_miss_0  = miss_0 && !send_evict_to_mem && !mshr_hit_0 && mshr_found; // if both miss, request 0 go first
    assign send_miss_1  = !miss_0 && miss_1 && !send_evict_to_mem && !mshr_hit_1 && mshr_found;  // request_0 go first
    assign has_req_to_mem = (send_miss_0 || send_miss_1);

    always_ff @(posedge clock) begin
        if (reset) begin
            send_evict_to_mem <= 1'b0;
        end else if (has_req_to_mem) begin
            send_evict_to_mem <= 1'b1;
        end else begin 
            send_evict_to_mem <= 1'b0;
        end
    end

    // Block normal operations during WFI flush
    assign Dcache_req_1_accept = (wfi_state == WFI_IDLE) && req_1_accept && !(miss_0 && miss_1) && !mshr_hit_1 && (cache_hit_1 || mshr_found); // if request 0 and 1 both miss, give up request 1
    assign Dcache_req_0_accept = (wfi_state == WFI_IDLE) && req_0_accept && !mshr_hit_0 && (cache_hit_0 || mshr_found); // has free bank && not already in mshr && mshr not full

    // ---------- MSHR for Non-Blocking ----------   
    typedef struct packed {
        logic valid;
        logic [TAG_BITS-1:0] tag;
        logic [INDEX_BITS-1:0] index;
        logic [BANK_BITS-1:0] bank;
        logic [$clog2(CACHE_WAYS)-1:0] way;
        logic [OFFSET_BITS-1:0] offset;
        MEM_COMMAND command;
        MEM_SIZE size;
        MEM_BLOCK store_data;
        logic port_id; // FROM WHICH PORT
        MEM_TAG     mem_tag; 
        ROB_IDX     rob_idx;
        // logic victim_hit;  // Request went to victim cache
    } mshr_entry_t;

    mshr_entry_t mshr [MSHR_SIZE-1:0];
    logic [MSHR_SIZE-1:0] mshr_valid;

    // ---------- Signals for Allocate MSHR ----------   
    logic [$clog2(MSHR_SIZE)-1:0] pending_mshr_id;
    logic pending_req_to_mem;
    
    // logic send_new_mem_req; // have req to memory & has MSHR entry
    int free_mshr_idx;
    
    int max_val_0;
    int max_val_1;

    // ----------  LRU logic ----------  
    // Find the replacement way
    always_comb begin : LRU
        max_val_0 = '0;
        max_val_1 = '0;
        replace_way_0 = '0;
        replace_way_1 = '0;
 
        // Req 0
        // First find invalid
        if (!(&cache_valid[bank_0][index_0])) begin
            for (int w1 = 0; w1 <CACHE_WAYS; w1++) begin
                if (!cache_valid[bank_0][index_0][w1]) begin
                    replace_way_0 = w1;
                    break;
                end
            end
        end else begin
            // If no invalid, find the oldest
            for (int w = 0; w <CACHE_WAYS; w++) begin
                if (lru_bits[bank_0][index_0][w] > max_val_0) begin
                    replace_way_0 = w;
                    max_val_0 = lru_bits[bank_0][index_0][w];
                end
            end
        end

        // Req 1
        // First find invalid
        if (!(&cache_valid[bank_1][index_1])) begin
            for (int w3 = 0; w3 <CACHE_WAYS; w3++) begin
                if (!cache_valid[bank_1][index_1][w3]) begin
                    replace_way_1 = w3;
                    break;
                end
            end
        end else begin
            // If no invalid, find the oldest
            for (int w2 = 0; w2 <CACHE_WAYS; w2++) begin
                if (lru_bits[bank_1][index_1][w2] > max_val_1) begin
                    replace_way_1 = w2;
                    max_val_1 = lru_bits[bank_1][index_1][w2];
                end
            end
        end
    end

    // Update LRU Bits
    always_ff @(posedge clock) begin : update_LRU
        if (reset) begin
            for (int b = 0; b < BANKS; b++) begin
                for (int s = 0; s < SETS_PER_BANK; s++) begin
                    for (int w = 0; w < CACHE_WAYS; w++) begin
                        lru_bits[b][s][w] <= '0;   
                    end
                end
            end
        end else begin
            //---------------when cache hit---------------//
            // cpu reauest 0
            if (cache_hit_0 && Dcache_req_0_accept) begin
                for (int w = 0; w < CACHE_WAYS; w++) begin
                    if (w == hit_way_0) begin
                        lru_bits[bank_0][index_0][hit_way_0] <= '0;
                    end else if (lru_bits[bank_0][index_0][w] < lru_bits[bank_0][index_0][hit_way_0] || lru_bits[bank_0][index_0][w] == lru_bits[bank_0][index_0][hit_way_0]) begin
                        lru_bits[bank_0][index_0][w] <= lru_bits[bank_0][index_0][w] + 1'b1;
                    end
                end
            end
            // cpu reauest 1
            if (cache_hit_1 && Dcache_req_1_accept) begin
                lru_bits[bank_1][index_1][hit_way_1] <= '0;
                for (int w11 = 0; w11 < CACHE_WAYS; w11++) begin
                    if (w11 != hit_way_1 && (lru_bits[bank_1][index_1][w11] < lru_bits[bank_1][index_1][hit_way_1] || lru_bits[bank_1][index_1][w11] == lru_bits[bank_1][index_1][hit_way_1])) begin
                        lru_bits[bank_1][index_1][w11] <= lru_bits[bank_1][index_1][w11] + 1'b1;
                    end
                end
            end

            //---------------when cache miss---------------//
            if (send_miss_0) begin
                lru_bits[bank_0][index_0][replace_way_0] <= '0;
                for (int w00 = 0; w00 < CACHE_WAYS; w00++) begin
                    if (w00 != replace_way_0 && (lru_bits[bank_0][index_0][w00] < lru_bits[bank_0][index_0][replace_way_0] || lru_bits[bank_0][index_0][w00] == lru_bits[bank_0][index_0][replace_way_0])) begin
                        lru_bits[bank_0][index_0][w00] <= lru_bits[bank_0][index_0][w00] + 1'b1;
                    end
                end
            end

            if (send_miss_1) begin
                lru_bits[bank_1][index_1][replace_way_1] <= '0;
                for (int w11_m = 0; w11_m < CACHE_WAYS; w11_m++) begin
                    if (w11_m != replace_way_1 && (lru_bits[bank_1][index_1][w11_m] < lru_bits[bank_1][index_1][replace_way_1] || lru_bits[bank_1][index_1][w11_m] == lru_bits[bank_1][index_1][replace_way_1])) begin
                        lru_bits[bank_1][index_1][w11_m] <= lru_bits[bank_1][index_1][w11_m] + 1'b1;
                    end
                end
            end
        end
    end

    // ----------  MSHR logic -------------------------  
    // Find empty MSHR
    always_comb begin
        mshr_found    = 0;
        free_mshr_idx = 0;
        for (int i = MSHR_SIZE -1; i >=0; i--) begin
            if (!mshr[i].valid && !mshr_found) begin
                mshr_found    = 1;
                free_mshr_idx = i;
            end
        end
    end


    // Find refill MSHR id (when data tag comes back from memory)
    //### Handle the case that transaction tag and data tag come back at the same cycle ###//

    always_comb begin : blockName
        refill_mshr_id =  0;
        refill_enable = 0;
        transaction_data_tag_the_same_time = 0;
        if (mem2proc_data_tag != 0) begin
            if ((mem2proc_transaction_tag == mem2proc_data_tag)) begin
                refill_mshr_id = pending_mshr_id;   
                refill_enable = 1;
                transaction_data_tag_the_same_time = 1;
            end else begin
                for (int i = 0; i < MSHR_SIZE; i++) begin
                    if (mshr[i].valid && (mshr[i].mem_tag == mem2proc_data_tag)) begin
                        refill_mshr_id = i;
                        refill_enable = 1;
                    end
                end
            end 
        end
    end

    // Allocate to the MSHR 
    always_ff @(posedge clock) begin
        if (reset) begin
            // Record #MSHR that was used
            pending_mshr_id <= '0;
            pending_req_to_mem <= 0;


            // Allocate to the MSHR
            for (int i = 0; i < MSHR_SIZE; i++) begin
                mshr[i].valid   <= 0;
                mshr[i].tag <= '0;
                mshr[i].index <= '0;
                mshr[i].bank <= '0;
                mshr[i].way <= '0;
                mshr[i].offset <= '0;
                mshr[i].command <= '0;
                mshr[i].size <= '0;
                mshr[i].store_data <= '0;
                mshr[i].port_id <= '0;
                mshr[i].rob_idx <= '0;
                mshr[i].mem_tag <= '0;
            end

            // initial helper tags array
            for (int b = 0; b < BANKS; b++) begin
                for (int s = 0; s < SETS_PER_BANK; s++) begin
                    cache_valid[b][s] <= '0;
                    cache_dirty[b][s] <= '0;
                    for (int w2 = 0; w2 < CACHE_WAYS; w2++) begin
                        cache_tags[b][s][w2] <= '0;
                    end
                end
            end
        end else begin
            // ---------- Record #MSHR that was used & Allocate to the MSHR ---------- 
            if (has_req_to_mem && (send_miss_1 || send_miss_0)) begin
                // Record #MSHR
                pending_mshr_id <= free_mshr_idx;
                pending_req_to_mem <= 0;
                // Allocate to the MSHR
                mshr[free_mshr_idx].valid  <= 1;
                mshr[free_mshr_idx].tag    <= (send_miss_0 ? tag_0   : tag_1);
                mshr[free_mshr_idx].index  <= (send_miss_0 ? index_0 : index_1);
                mshr[free_mshr_idx].bank   <= (send_miss_0 ? bank_0  : bank_1);
                mshr[free_mshr_idx].way    <= (send_miss_0 ? replace_way_0 : replace_way_1); //lru
                mshr[free_mshr_idx].command<= (send_miss_0 ? Dcache_command_0 : Dcache_command_1);
                mshr[free_mshr_idx].offset  <= (send_miss_0 ? offset_0         : offset_1);
                mshr[free_mshr_idx].size   <= (send_miss_0 ? Dcache_size_0    : Dcache_size_1);
                mshr[free_mshr_idx].store_data <= (send_miss_0 ? Dcache_store_data_0    : Dcache_store_data_1);
                mshr[free_mshr_idx].mem_tag <= mem2proc_transaction_tag;   
                mshr[free_mshr_idx].rob_idx <= send_miss_0 ? Dcache_req_rob_idx_0    : Dcache_req_rob_idx_1; 
                mshr[free_mshr_idx].port_id <= (send_miss_0 ? 0 : 1);
            end  

            // ---------- Get tag/result from mem ---------- 
            // Get Tag from memory (save to MSHR & clear pending bit)
            if (wfi_state == WFI_WRITING_BACK) begin
                cache_dirty[wfi_bank_next][wfi_set_next][wfi_way_next] <=1'b0;
            end else begin    
                if (mem2proc_transaction_tag != 0 && pending_req_to_mem) begin
                    // $display("tag = %d | ",mem2proc_transaction_tag);
                    pending_req_to_mem <= 0;
                    pending_mshr_id <= 0;
                end
                
                // UPDATE TAG/VALID/DIRTY => Read Miss, Write Hit, Write Miss
                //  Get Result from memory => update cache state
                if (mem2proc_data_tag != 0 && refill_enable) begin
                    mshr[refill_mshr_id].valid <= 1'b0; 
                end
                
                // ---------- Write hit logic ---------- (store cache hit 0/1 is req )
                if (store_cache_hit_0) begin
                    cache_dirty[bank_0][index_0][hit_way_0] <= 1'b1;
                    cache_valid[bank_0][index_0][hit_way_0] <= 1'b1; //useless
                    cache_tags [bank_0][index_0][hit_way_0] <= tag_0; //useless
                end else if (send_miss_0) begin 
                    cache_dirty[bank_0][index_0][replace_way_0] <= 1'b1;
                    cache_valid[bank_0][index_0][replace_way_0] <= 1'b1;
                    cache_tags [bank_0][index_0][replace_way_0] <= tag_0;
                end

                if (store_cache_hit_1) begin
                    cache_dirty[bank_1][index_1][hit_way_1] <= 1'b1;
                    cache_valid[bank_1][index_1][hit_way_1] <= 1'b1;
                    cache_tags [bank_1][index_1][hit_way_1] <= tag_1;
                end else if (send_miss_1) begin 
                    `ifndef SYNTHESIS
                    // $display("tag=%d | data = %d", tag_1, Dcache_store_data_1);
                    // $display("bank_1=%d | index_1 = %d |replace_way_1=%d ", bank_1, index_1,replace_way_1);
                    `endif
                    cache_dirty[bank_1][index_1][replace_way_1] <= 1'b1;
                    cache_valid[bank_1][index_1][replace_way_1] <= 1'b1;
                    cache_tags [bank_1][index_1][replace_way_1] <= tag_1;
                end               
            end
        end
        `ifndef SYNTHESIS
        for (int b = 0; b < BANKS; b++) begin
            for (int s = 0; s < SETS_PER_BANK; s++) begin
                // $display("dirty[%b][%d]=%b",b,s,cache_dirty[b][s]);
            end
        end
        `endif
    end

    //  Get Result from memory => update cache data with received data
    //  wb to cache line 
    MEM_BLOCK fill_data;
    always_comb begin 
        cache_write_en_refill_0 ='0;
        cache_write_en_refill_1 ='0;
        cache_write_addr_refill_0 = '0;
        cache_write_addr_refill_1 = '0;
        cache_write_data_refill_0 = '0;
        cache_write_data_refill_1 = '0;
        fill_data = '0;

        if ((mem2proc_data_tag == mshr[refill_mshr_id].mem_tag || transaction_data_tag_the_same_time) && mshr[refill_mshr_id].valid ) begin
            fill_data = mem2proc_data;

            // If store, first store data in and fill back to cache; If load, just fill back to cache
            if (mshr[refill_mshr_id].valid && mshr[refill_mshr_id].command == MEM_STORE) begin
                unique case (mshr[refill_mshr_id].size) 
                    BYTE:    fill_data.byte_level[mshr[refill_mshr_id].offset] = mshr[refill_mshr_id].store_data.byte_level[0];
                    HALF:    fill_data.half_level[mshr[refill_mshr_id].offset[OFFSET_BITS-1:1]] =  mshr[refill_mshr_id].store_data.half_level[0];
                    WORD:    fill_data.word_level[mshr[refill_mshr_id].offset[OFFSET_BITS-1:2]] = mshr[refill_mshr_id].store_data.word_level[0];
                    DOUBLE:  fill_data.dbbl_level = mshr[refill_mshr_id].store_data.dbbl_level;
                endcase
            end

            if (mshr[refill_mshr_id].valid && mshr[refill_mshr_id].bank == 1'b0) begin
                cache_write_addr_refill_0  = mshr[refill_mshr_id].index;
                cache_write_data_refill_0  = fill_data;
                cache_write_en_refill_0[mshr[refill_mshr_id].way] = 1'b1;
            end else if (mshr[refill_mshr_id].valid && mshr[refill_mshr_id].bank == 1'b1) begin
                cache_write_addr_refill_1 = mshr[refill_mshr_id].index;
                cache_write_data_refill_1 = fill_data;
                cache_write_en_refill_1[mshr[refill_mshr_id].way] = 1'b1;
            end
        end
    end


    // only port 1 support store
    always_comb begin
        if (store_cache_hit_0 && !mshr_hit_0)  begin
            Dcache_store_valid_0 = 1'b1;
        end else if ((mem2proc_data_tag == mshr[refill_mshr_id].mem_tag || transaction_data_tag_the_same_time) && mshr[refill_mshr_id].valid && mshr[refill_mshr_id].command == MEM_STORE && mshr[refill_mshr_id].port_id == 1'b0) begin
            Dcache_store_valid_0 = 1'b1;
        end else begin
            Dcache_store_valid_0 = 1'b0;
        end

        if (store_cache_hit_1 && !mshr_hit_1 && Dcache_req_1_accept)  begin
            Dcache_store_valid_1 = 1'b1;
            Dcache_data_rob_idx_1 = Dcache_req_rob_idx_1;
        end else if ((mem2proc_data_tag == mshr[refill_mshr_id].mem_tag || transaction_data_tag_the_same_time) && mshr[refill_mshr_id].valid && mshr[refill_mshr_id].command == MEM_STORE && mshr[refill_mshr_id].port_id == 1'b1) begin
            Dcache_store_valid_1 = 1'b1;
            Dcache_data_rob_idx_1 = mshr[refill_mshr_id].rob_idx;
        end else begin
            Dcache_store_valid_1 = 1'b0;
            Dcache_data_rob_idx_1 = '0;
        end
    end
    

    // ----------Write Back to the memory ------------------
    // cycle k: cache miss-> send mem_load to mem (READ Target)
    // ### it will always read 4 ways out at cycle k, so just choose the replace way and wb to mem 
    // cycle k+1: wb replace cache line to mem => send mem_store to mem
    
    logic wb_mem_valid;
    MEM_BLOCK wb_mem_data;
    ADDR wb_mem_addr;
    MEM_SIZE wb_mem_size;

    always_comb begin
        victim_tag   = '0;
        victim_index = '0;
        victim_bank  = '0;
        victim_way   = '0;
        wb_mem_read_en = '0;
        `ifndef SYNTHESIS
        // $display("test");
        `endif
        if (has_req_to_mem) begin
            wb_mem_read_en = 1'b1;
            if (send_miss_0) begin
                victim_index = index_0;
                victim_bank  = bank_0;
                victim_way   = replace_way_0;
                victim_tag   = cache_tags[bank_0][index_0][replace_way_0];
            end else if (send_miss_1) begin
                victim_index = index_1;
                victim_bank  = bank_1; 
                victim_way   = replace_way_1;
                victim_tag   = cache_tags[bank_1][index_1][replace_way_1];
            end
        end
    end
    
    always_ff @(posedge clock) begin : write_back_to_memory
        if (reset) begin
            wb_mem_valid <= 1'b0;
            wb_mem_data <= '0;
            wb_mem_addr <= '0;
            wb_mem_size <= DOUBLE;
        end else if (has_req_to_mem) begin
            wb_mem_size <= (send_miss_0) ? Dcache_size_0 : Dcache_size_1;
            wb_mem_addr <= {victim_tag, victim_index, victim_bank, {OFFSET_BITS{1'b0}}};

            if (send_miss_0 && cache_dirty[victim_bank][victim_index][victim_way] && cache_valid[victim_bank][victim_index][victim_way]) begin // cache_miss_0 and replace_way_0 here is req 0/1
                wb_mem_valid <= 1'b1;
                wb_mem_data <=  (bank_0) ? cache_data_read_1[replace_way_0] : cache_data_read_0[replace_way_0];
            end else if (send_miss_1 && cache_dirty[victim_bank][victim_index][victim_way] && cache_valid[victim_bank][victim_index][victim_way]) begin // cache_miss_1
                wb_mem_valid <= 1'b1;
                wb_mem_data <=  (bank_1) ? cache_data_read_1[replace_way_1] : cache_data_read_0[replace_way_1];
            end
            
        end else begin
            wb_mem_valid <= 1'b0;
            wb_mem_data <= '0;
            wb_mem_addr <= '0;
            wb_mem_size <= DOUBLE;
        end
        `ifndef SYNTHESIS
        // $display("wb_valid=%d | wb_addr=%d | wb_data =%d | wb_size=%d",wb_mem_valid,wb_mem_addr,wb_mem_data,wb_mem_size);
        `endif
    end

    // ---------- Send signal to the memory ------------------
    always_comb begin : signal_to_mem
        // default
        Dcache2mem_command = MEM_NONE;
        Dcache2mem_addr    = '0;
        Dcache2mem_size    = BYTE;  
        Dcache2mem_data    = '0;

        // WFI flush has highest priority - write dirty cache lines back to memory
        if (wfi_state == WFI_WRITING_BACK && send_wfi_to_mem) begin
            Dcache2mem_command = MEM_STORE;
            Dcache2mem_size    = DOUBLE; // 64 bits
            Dcache2mem_addr    = {cache_tags[wfi_bank][wfi_set][wfi_way], wfi_set, wfi_bank, {OFFSET_BITS{1'b0}}};
            Dcache2mem_data    = wfi_cache_data;
        end 
        // Normal cache miss - load from memory
        // todo: might happend at the same cycle need to fix
        else if (has_req_to_mem) begin
            Dcache2mem_command = MEM_LOAD;
            Dcache2mem_size    = DOUBLE;    
            Dcache2mem_data = '0; 
            if (send_miss_0 ) begin
                Dcache2mem_addr = {tag_0, index_0, bank_0, {OFFSET_BITS{1'b0}}};
            end else if (send_miss_1) begin // send_miss_1
                Dcache2mem_addr = {tag_1, index_1, bank_1, {OFFSET_BITS{1'b0}}};
            end
        end 
        // Victim writeback - store evicted dirty line to memory
        else if (wb_mem_valid) begin
            Dcache2mem_command = MEM_STORE;
            Dcache2mem_addr = wb_mem_addr;
            Dcache2mem_size = wb_mem_size;
            Dcache2mem_data = wb_mem_data;
        end 
    end

    // ---------- MSHR Conflict ------------------
    //### Handle the situation that cpu sent request that is waiting inside the MSHR ###//
    always_comb begin
        mshr_hit_0 = 1'b0;
        mshr_hit_1 = 1'b0;
        for (int i = 0; i < MSHR_SIZE; i++) begin
            if (Dcache_command_0 != MEM_NONE &&
                mshr[i].valid &&
                mshr[i].tag   == tag_0   &&
                mshr[i].index == index_0 &&
                mshr[i].bank  == bank_0 &&
                mshr[i].rob_idx == Dcache_req_rob_idx_0) begin
                mshr_hit_0 = 1'b1;
            end
            if (Dcache_command_1 != MEM_NONE && 
                mshr[i].valid &&    
                mshr[i].tag   == tag_1   &&
                mshr[i].index == index_1 &&
                mshr[i].bank  == bank_1 &&
                mshr[i].rob_idx == Dcache_req_rob_idx_1) begin
                mshr_hit_1 = 1'b1;
            end
        end
    end
    
// `ifndef SYNTHESIS
// task automatic show_status();
//     $display("===================================================================");
//     $display("D-Cache Status @ time %0t", $time);

//     // =================================================================
//     // Request 0 Pipeline  (Req0 -> Bank -> Hit/Miss -> MSHR -> Mem)
//     // =================================================================
//     $display("== Request 0 ======================================================");
//     $display("[REQ0] cmd=%s size=%s addr=%h store_data=%h | req_rob_idx=%0d data_rob_idx=%0d",
//              Dcache_command_0.name(), Dcache_size_0.name(),
//              Dcache_addr_0, Dcache_store_data_0.dbbl_level, Dcache_req_rob_idx_0, Dcache_data_rob_idx_0);
//     $display("[REQ0] bank=%0d index=%0d offset=%0d",
//              bank_0, index_0, offset_0);

//     // bank routing / accept
//     $display("[REQ0] to_bank0=%b to_bank1=%b  req_0_accept=%b  Dcache_req_0_accept=%b Dcache_store_valid_0=%b",
//              req_0_to_bank_0, req_0_to_bank_1,
//              req_0_accept, Dcache_req_0_accept, Dcache_store_valid_0);

//     // hit / miss / mshr
//     $display("[REQ0] way_hit=%b  hit_way=%0d  cache_hit=%b  load_hit=%b  store_hit=%b",
//              way_hit_0, hit_way_0, cache_hit_0, load_cache_hit_0, store_cache_hit_0);
//     $display("[REQ0] miss=%b  mshr_hit=%b",
//              miss_0, mshr_hit_0);

//     // data out / valid
//     $display("[REQ0] valid_out=%b  data_out=%h",
//              Dcache_valid_out_0, Dcache_data_out_0.dbbl_level);

//     // =================================================================
//     // Request 1 Pipeline  (Req1 -> Bank -> Hit/Miss -> MSHR -> Mem)
//     // =================================================================
//     $display("== Request 1 ======================================================");
//     $display("[REQ1] cmd=%s size=%s addr=%h store_data=%h | req_rob_idx=%0d data_rob_idx=%0d",
//              Dcache_command_1.name(), Dcache_size_1.name(),
//              Dcache_addr_1, Dcache_store_data_1.dbbl_level, Dcache_req_rob_idx_1, Dcache_data_rob_idx_1);
//     $display("[REQ1] bank=%0d index=%0d offset=%0d",
//              bank_1, index_1, offset_1);

//     $display("[REQ1] to_bank0=%b to_bank1=%b  req_1_accept=%b  Dcache_req_1_accept=%b Dcache_store_valid_1=%b",
//              req_1_to_bank_0, req_1_to_bank_1,
//              req_1_accept, Dcache_req_1_accept, Dcache_store_valid_1);

//     $display("[REQ1] way_hit=%b  hit_way=%0d  cache_hit=%b  load_hit=%b  store_hit=%b",
//              way_hit_1, hit_way_1, cache_hit_1, load_cache_hit_1, store_cache_hit_1);
//     $display("[REQ1] miss=%b  mshr_hit=%b",
//              miss_1, mshr_hit_1);

//     $display("[REQ1] valid_out=%b  data_out=%h",
//              Dcache_valid_out_1, Dcache_data_out_1.dbbl_level);

//     // =================================================================
//     // Bank / Cache Array Control
//     // =================================================================
//     $display("== Bank / Cache Control ===========================================");
//     $display("[BANK] req_to_bank = {req0->b0,b1, req1->b0,b1} = %b%b%b%b",
//              req_0_to_bank_0, req_0_to_bank_1, req_1_to_bank_0, req_1_to_bank_1);
//     $display("[BANK] has_req_to_mem=%b  send_miss_0=%b  send_miss_1=%b  send_evict_to_mem=%b",
//              has_req_to_mem, send_miss_0, send_miss_1, send_evict_to_mem);

//     // read path
//     $display("[READ]  en={b0,b1} = %b %b  addr={b0,b1} = %d %d",
//              cache_read_en_0, cache_read_en_1,
//              cache_read_addr_0, cache_read_addr_1);

//     // write path
//     $display("refill_mshr_id=%0d , transaction_data_tag_the_same_time=%b", refill_mshr_id, transaction_data_tag_the_same_time);
//     $display("[WRITE] hit_en_0=%b  refill_en_0=%b  final_we_0=%b  waddr_0=%0d  data_0=%h data_hit_0=%h data_refill_0=%h",
//              cache_write_en_hit_0, cache_write_en_refill_0,
//              cache_write_en_0, cache_write_addr_0, cache_write_data_0, cache_write_data_hit_0, cache_write_data_refill_0);
//     $display("[WRITE] hit_en_1=%b  refill_en_1=%b  final_we_1=%b  waddr_1=%0d  data_1=%h data_hit_1=%h data_refill_1=%h",
//              cache_write_en_hit_1, cache_write_en_refill_1,
//              cache_write_en_1, cache_write_addr_1, cache_write_data_1, cache_write_data_hit_1, cache_write_data_refill_1);

//     // =================================================================
//     // MSHR / Miss Handling
//     // =================================================================
//     $display("== MSHR / Miss Handling ===========================================");
//     $display("[MSHR] send_new_mem_req=%b  mshr_found=%b  free_mshr_idx=%0d",
//              send_new_mem_req, mshr_found, free_mshr_idx);
//     $display("[MSHR] pending_mshr_id=%0d  pending_req_to_mem=%b",
//              pending_mshr_id, pending_req_to_mem);
//     $display("[MSHR] miss_0=%b miss_1=%b  has_req_to_mem=%b",
//              miss_0, miss_1, has_req_to_mem);

//     // 列出所有有效 MSHR entry
//     for (int i = 0; i < MSHR_SIZE; i++) begin
//             $display("[MSHR[%0d]] valid=%b tag=%h idx=%0d bank=%0d way=%0d cmd=%s size=%s",
//                      i,
//                      mshr[i].valid, mshr[i].tag, mshr[i].index, mshr[i].bank,
//                      mshr[i].way,
//                      mshr[i].command.name(), mshr[i].size.name());
//             $display("           offset=%0d  mem_tag=%0d  LSQ_REQ_tag=%0d  store_data=%h",
//                      mshr[i].offset,
//                      mshr[i].mem_tag,
//                      mshr[i].rob_idx,
//                      mshr[i].store_data.dbbl_level);
//         end

//     // =================================================================
//     // Full Cache Contents (per bank / set / way)
//     // =================================================================
//     $display("== Cache Contents (tags / valid / dirty / LRU) =====================");
//     for (int b = 0; b < BANKS; b++) begin
//         for (int s = 0; s < SETS_PER_BANK; s++) begin
//             // Summary line of valid/dirty bits for this set
//             $write("[BANK%0d SET%0d] valid=", b, s);
//             for (int w = CACHE_WAYS-1; w >=0; w--) begin
//                 $write("%b", cache_valid[b][s][w]);
//             end
//             $write(" dirty=");
//             for (int w = CACHE_WAYS-1; w >=0; w--) begin
//                 $write("%b", cache_dirty[b][s][w]);
//             end
//             $display("");

//             // Per-way detail: tag and LRU
//             for (int w = CACHE_WAYS-1; w >=0; w--) begin
//                 $write("    way%0d: tag=%h  LRU=%0d", w,
//                          cache_tags[b][s][w], lru_bits[b][s][w]);
//             end
//             $display("");

//         end
//     end

//     // =================================================================
//     // Memory Interface
//     // =================================================================
//     $display("== Memory Interface ===============================================");
//     $display("wb_mem_valid=%b wb_mem_data=%h wb_mem_addr=%h tag=%h index=%h bank=%h way=%h", wb_mem_valid, wb_mem_data, wb_mem_addr, victim_tag, victim_index, victim_bank, victim_way);
//     $display("[TO  MEM] cmd=%s addr=%h size=%s data=%h",
//              Dcache2mem_command.name(), Dcache2mem_addr,
//              Dcache2mem_size.name(), Dcache2mem_data.dbbl_level);
//     $display("[FROM MEM] trans_tag=%0d  data_tag=%0d  data=%h",
//              mem2proc_transaction_tag, mem2proc_data_tag, mem2proc_data.dbbl_level);

//     $display("===================================================================");
// endtask


// always_ff @(posedge clock) begin
//     if (!reset) begin
//         show_status();
//     end
// end
// `endif

endmodule




