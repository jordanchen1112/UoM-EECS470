/////////////////////////////////////////////////////////////////////////
//                                                                     //
//   Modulename :  fetch_stage.sv                                      //
//                                                                     //
//  Description :  instruction fetch (IF) stage of the pipeline;       //
//                 fetch instruction, compute next PC location, and    //
//                 send them down the pipeline.                        //
//                                                                     //
/////////////////////////////////////////////////////////////////////////

`include "sys_defs.svh"

module stage_if #(
    parameter int unsigned           FETCH_WIDTH  = 1,
    parameter int unsigned           ADDR_WIDTH   = 32

)(
    input logic                            clock,          // system clock
    input logic                            reset,          // system reset
    input logic                            if_valid,       // only go to next PC when true (stall)
    input logic                            if_flush,   
    input logic take_branch, //###    


    input logic [$clog2(`DISPATCH_WIDTH+1)-1:0] disp_n,
    // =========================================================
    // Branch Predictor ->  Fetch (only first branch was computed!!)
    // =========================================================
    input  logic                           pred_valid_i,     
    input  logic [$clog2(FETCH_WIDTH)-1:0] pred_lane_i,      // which instruction is branch
    input  logic                           pred_taken_i,     
    input  logic [ADDR_WIDTH-1:0]          pred_target_i,    // predicted target PC Addr

    // =========================================================
    // Fetch <-> ICache / Mem (get instructions)
    // Problem : fetch one line (from ICache) per cycle (might not enough for N-way)
    // Possible Solution: dual-line fetch (two fetch requests per cycle)?
    // =========================================================
    input                 Icache_valid,
    input  MEM_BLOCK      Icache_data,      // data coming back from Instruction memory

    output ADDR                            Imem_addr, // address sent to Instruction memory

    // =========================================================
    // EXE -> Fetch (real branch result)
    // =========================================================
    input logic [ADDR_WIDTH-1:0]           correct_pc_target_o, //exe stage will compute the correct target for branch instruction

    // =========================================================
    // Fetch -> Dispatch 
    // =========================================================
    output IF_ID_PACKET [FETCH_WIDTH-1:0]  if_packet_o
);

    // --------------------------
    // Base PC register
    // --------------------------
    logic [ADDR_WIDTH-1:0] PC_reg, PC_next;

    //### stall fetch due to icache miss
    logic stall_fetch;
    assign stall_fetch = if_valid && !(&Icache_valid);

    // always_ff @(posedge clock) begin
    //     $display("flush : %b, PC : %h, NPC : %h", if_flush, PC_reg, PC_next);
    //     $display("if_valid : %b, pred_valid, taken, target : %b %b %h", if_valid, pred_valid_i, pred_taken_i, pred_target_i);
    // end

    // Next PC priority:
    //  1) if_flush (from EXE correction)
    //  2) predicted taken
    //  3) sequential advance by FETCH_WIDTH
    always_comb begin
        // default: hold
        PC_next = PC_reg;
        if(take_branch) begin
            PC_next = 32'h68;
        end else if (if_flush) begin
            PC_next = correct_pc_target_o;
            // PC_next = 32'h68;
        end else if (if_valid && !stall_fetch) begin
            if (pred_valid_i && pred_taken_i) begin
                PC_next = pred_target_i;
                `ifndef SYNTHESIS
                // $display("PC_next=%h", PC_next);
                `endif
            // end else if(PC_reg == 32'hA4) begin //### close flush
            //     PC_next = 32'h68; //###
            // end else if(PC_reg == 32'hA8) begin //###
            //     PC_next = 32'hA8; //###
            end else begin
                PC_next = PC_reg + (`N << 2); // + 4 * FETCH_WIDTH
            end
        end
        
    end

    always_ff @(posedge clock) begin
        if (reset) begin
            PC_reg <= '0;
        end else begin
            PC_reg <= PC_next;
            
        end
    end

    // --------------------------
    // Memory / I$ interface
    // --------------------------
    // Align base fetch address to 8 bytes (64b line)
    assign Imem_addr    = {PC_reg[ADDR_WIDTH-1:3], 3'b0};

    // --------------------------
    // Lane packing helpers
    // --------------------------
    // Compute each lane’s instruction address as base PC + 4 × i.
    function automatic logic [31:0] pick_inst_from_block
    (
        input                             k,
        input MEM_BLOCK                   blk,
        input logic [ADDR_WIDTH-1:0]      inst_addr
    );
        case (inst_addr[2])
            1'b0: pick_inst_from_block = (k == 1) ? `NOP : blk.word_level[0];
            1'b1: pick_inst_from_block = blk.word_level[1];
            default: pick_inst_from_block = `NOP; 
        endcase
    endfunction

    // --------------------------
    // N-way bundle output
    // --------------------------
    genvar k;
    generate
        for (k = 0; k < FETCH_WIDTH; k++) begin : GEN_FETCH_LANES
            logic [ADDR_WIDTH-1:0] this_pc;
            logic [31:0]           this_inst;
            logic                  this_valid;

            // Lane valid rules:
            // During flush: all lanes are invalid (0) — or alternatively, output NOP with valid=0 in the same cycle.
            // When stalled (if_valid=0): all lanes are invalid (0).
            // When a predicted branch is taken: only lanes with index ≤ pred_lane_i are valid.
            // Otherwise: all lanes are valid.
            always_comb begin
                this_pc = '0;
                this_inst = `NOP;
                this_valid = 1'b0;

                if (Icache_valid) begin
                    this_pc   = PC_reg + (k << 2);
                    this_inst = pick_inst_from_block(k, Icache_data, this_pc);
                end

                // TODO: for N-way, when one of the instructions miss, all instructions after it should be invalid?
                if (reset || if_flush || !if_valid || !Icache_valid) begin
                    this_valid = 1'b0;
                end else if (pred_valid_i && pred_taken_i) begin
                    this_valid = (k <= pred_lane_i);
                end else begin
                    this_valid = 1'b1;
                end
            end

            // Packet output
            assign if_packet_o[k].PC    = this_pc;
            assign if_packet_o[k].NPC   = this_pc + 32'd4;
            assign if_packet_o[k].inst  = this_valid ? this_inst : `NOP;
            assign if_packet_o[k].valid = this_valid;
        end
    endgenerate
// `ifndef SYNTHESIS
//     always_ff @(posedge clock) begin
//         if (!reset) begin
//             $display("[%t] PC_reg = %h | PC_next=%h | Icache_valid=%b Icache_data = %h| if_packet_o_valid=%b", $time, PC_reg,PC_next, Icache_valid,Icache_data, if_packet_o[0].valid );
//         end
//     end
//     initial begin
//         $dumpfile("fetch_stage.vcd");
//         $dumpvars(0, stage_if);
//     end
// `endif
endmodule