`include "sys_defs.svh"

module btb (
    input logic clock,
    input logic reset,

    // Input from Fetch stage
    input ADDR [`FETCH_WIDTH-1:0] if_pc_i,

    // Input from Execution stage
    input ADDR [`FETCH_WIDTH-1:0] ex_pc_i,
    input ADDR [`FETCH_WIDTH-1:0] ex_target_i,
    input logic [`FETCH_WIDTH-1:0] is_branch_ex_i,

    // output
    output logic [`FETCH_WIDTH-1:0] hit_o,
    output ADDR [`FETCH_WIDTH-1:0] pred_pc_o
);

    typedef struct packed {
        logic [`BTB_TAG_BITS-1:0] tag;
        logic [`BTB_VALUE_BITS-1:0] target;
    } btb_entry_t;

    logic [`BTB_SIZE-1:0][1:0] valids;
    btb_entry_t [`BTB_SIZE-1:0] way0, way1;
    logic [`BTB_SIZE-1:0] lru_bits; 

    logic way0_hit, way1_hit;
    logic [`BTB_VALUE_BITS-1:0] target_val;

    always_ff @(posedge clock) begin
        if (reset) begin
            valids   <= '0;
            lru_bits <= '0;
        end else begin
            for (int i = 0; i < `FETCH_WIDTH; i++) begin
                if (is_branch_ex_i[i]) begin
                    automatic logic [`BTB_INDEX_BITS-1:0] idx = ex_pc_i[i][`BTB_INDEX_BITS+1:2];
                    automatic logic [`BTB_TAG_BITS-1:0] tag = ex_pc_i[i][`BTB_TAG_BITS+`BTB_INDEX_BITS+1:`BTB_INDEX_BITS+2];
                    automatic logic [`BTB_VALUE_BITS-1:0] tgt = ex_target_i[i][`BTB_VALUE_BITS+1:2];

                    // Check if branch already exists in either way (Update case)
                    automatic logic hit_way0_wr, hit_way1_wr;
                    hit_way0_wr = valids[idx][0] && (way0[idx].tag == tag);
                    hit_way1_wr = valids[idx][1] && (way1[idx].tag == tag);

                    if (hit_way0_wr) begin
                        // Found in Way 0: Update target, make Way 1 the LRU victim
                        way0[idx].target <= tgt; 
                        lru_bits[idx]    <= 1'b1; 
                    end 
                    else if (hit_way1_wr) begin
                        // Found in Way 1: Update target, make Way 0 the LRU victim
                        way1[idx].target <= tgt;
                        lru_bits[idx]    <= 1'b0;
                    end 
                    else begin
                        // MISS: We must insert new branch. Check LRU bit to pick victim.
                        if (lru_bits[idx] == 1'b0) begin
                            // Victim is Way 0
                            valids[idx][0]      <= 1'b1;
                            way0[idx].tag    <= tag;
                            way0[idx].target <= tgt;
                            lru_bits[idx]    <= 1'b1; // Way 1 is now the "oldest"
                        end else begin
                            // Victim is Way 1
                            valids[idx][1]      <= 1'b1;
                            way1[idx].tag    <= tag;
                            way1[idx].target <= tgt;
                            lru_bits[idx]    <= 1'b0; // Way 0 is now the "oldest"
                        end
                    end
                end
            end
        end
    end

    always_comb begin
        hit_o = '0;
        pred_pc_o = '0;

        for (int i = 0; i < `FETCH_WIDTH; i++) begin
            way0_hit = valids[if_pc_i[i][`BTB_INDEX_BITS+1:2]][0] ? (way0[if_pc_i[i][`BTB_INDEX_BITS+1:2]].tag == if_pc_i[i][`BTB_TAG_BITS+`BTB_INDEX_BITS+1:`BTB_INDEX_BITS+2]) : '0;
            way1_hit = valids[if_pc_i[i][`BTB_INDEX_BITS+1:2]][1] ? (way1[if_pc_i[i][`BTB_INDEX_BITS+1:2]].tag == if_pc_i[i][`BTB_TAG_BITS+`BTB_INDEX_BITS+1:`BTB_INDEX_BITS+2]) : '0;

            hit_o[i] = way0_hit || way1_hit;

            target_val = (way0_hit) ? way0[if_pc_i[i][`BTB_INDEX_BITS+1:2]].target : way1[if_pc_i[i][`BTB_INDEX_BITS+1:2]].target; 

            pred_pc_o[i] = {
                if_pc_i[i][`XLEN-1:`BTB_VALUE_BITS+2], 
                target_val,
                if_pc_i[i][1:0]
            };
            // $display("-----BTB: way0: %b, way1: %b, pred_pc, hit = %0h, %0d------", way0_hit, way1_hit, pred_pc_o[i], hit_o[i]);
            // $display("some value: tag: %h, tar: %0h, off: %b", if_pc_i[i], target_val, if_pc_i[i][1:0]);
            // $display("v1: %b, v2: %b, hi1: %b, hi2: %b", valids[if_pc_i[i][`BTB_INDEX_BITS+1:2]][0], valids[if_pc_i[i][`BTB_INDEX_BITS+1:2]][1],  way0_hit, way1_hit);
        end

        for (int i = 0; i < `BTB_SIZE; i++)begin
            way0_hit = valids[if_pc_i[0][`BTB_INDEX_BITS+1:2]][0] ? (way0[if_pc_i[0][`BTB_INDEX_BITS+1:2]].tag == if_pc_i[0][`BTB_TAG_BITS+`BTB_INDEX_BITS+1:`BTB_INDEX_BITS+2]) : '0;
            way1_hit = valids[if_pc_i[0][`BTB_INDEX_BITS+1:2]][1] ? (way1[if_pc_i[0][`BTB_INDEX_BITS+1:2]].tag == if_pc_i[0][`BTB_TAG_BITS+`BTB_INDEX_BITS+1:`BTB_INDEX_BITS+2]) : '0;
            // $display("BTB[%d]: valid1=%b | tag1=%0h | val1=%0h | valid2=%b | tag2=%0h | val2=%0h | hit1=%b | hit2=%b", i, valids[i][0], way0[i].tag, way0[i].target, valids[i][1], way1[i].tag, way1[i].target, way0_hit, way1_hit);
        end
    end

endmodule