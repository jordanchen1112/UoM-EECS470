`include "sys_defs.svh"

module predictor_selector (
    input logic clock, reset,
    input ADDR [`FETCH_WIDTH-1:0] if_pc_i, ex_branch_pc_i,
    input logic [`FETCH_WIDTH-1:0] enable,
    // correctness signals
    input logic [`FETCH_WIDTH-1:0] p1_correct, p2_correct,

    output logic [`FETCH_WIDTH-1:0] use_p1 // which predictor to use (1 = P1, 0 = P2)
);

    typedef enum logic [1:0] {
        BIMODAL_STRONG  = 2'b00,
        BIMODAL_WEAK    = 2'b01,
        GSHARE_WEAK     = 2'b10,
        GSHARE_STRONG   = 2'b11
    } SEL_PRED;

    SEL_PRED [`GSHARE_SIZE-1:0] select_table;
    SEL_PRED [`FETCH_WIDTH-1:0] next_select_state;
    logic [`FETCH_WIDTH-1:0] [`HISTORY_BITS-1:0] index, ex_index;

    //Read logic
    always_comb begin
        for (int i = 0; i < `FETCH_WIDTH; i++) begin
            index[i] = if_pc_i[i][`HISTORY_BITS-1:0];
            use_p1[i] = select_table[index[i]][1];
        end
    end

    //update logic
    always_comb begin
        for (int i = 0; i < `FETCH_WIDTH; i++) begin
            ex_index[i] = ex_branch_pc_i[i][`HISTORY_BITS-1:0];
            next_select_state = select_table[ex_index[i]];

            if (p1_correct[i] && !p2_correct[i]) begin
                if (select_table[ex_index[i]] != GSHARE_STRONG)
                    next_select_state = SEL_PRED'(select_table[ex_index[i]] + 1);
            end else if (!p1_correct[i] && p2_correct[i]) begin
                if (select_table[ex_index[i]] != BIMODAL_STRONG)
                    next_select_state = SEL_PRED'(select_table[ex_index[i]] - 1);
            end
        end

    end

    // Update the counter each cycle
    always @(posedge clock or posedge reset) begin
        if (reset) begin
            for (int i = 0; i < `GSHARE_SIZE; i++) begin
                select_table[i] <= BIMODAL_WEAK;
            end
        end else begin

            for (int i = 0; i < `FETCH_WIDTH; i++) begin
                if (enable[i]) begin
                    select_table[ex_index[i]] <= next_select_state[i];
                end
            end
        end
    end

endmodule