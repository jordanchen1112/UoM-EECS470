`include "sys_defs.svh"

module bimodal (
    input clock, reset, 
    input ADDR [`FETCH_WIDTH-1:0] if_pc_i, ex_branch_pc_i,
    input logic [`FETCH_WIDTH-1:0] enable, taken,
    output logic [`FETCH_WIDTH-1:0] prediction
);
    typedef enum logic [1:0] {
        NT_STRONG  = 2'b00, // NT: Predict a branch as Not Taken
        NT_WEAK    = 2'b01,
        T_WEAK     = 2'b10, // T: Predict a branch as Taken
        T_STRONG   = 2'b11
    } STATE;

    STATE [`GSHARE_SIZE-1:0] bimodal_table;

    STATE [`FETCH_WIDTH-1:0] state, next_state;

    logic [`FETCH_WIDTH-1:0] [`HISTORY_BITS-1:0] index, ex_index;

    always_comb begin
        for (int i = 0; i < `FETCH_WIDTH; i++) begin
            index[i] = if_pc_i[i][`HISTORY_BITS-1:0];
            prediction[i] = bimodal_table[index[i]][1];
        end
    end

    always_comb begin
        for (int i = 0; i < `FETCH_WIDTH; i++) begin
            ex_index[i] = ex_branch_pc_i[i][`HISTORY_BITS-1:0];
            case (bimodal_table[ex_index[i]])
                NT_STRONG : next_state[i] = taken[i] ? NT_WEAK  : NT_STRONG;
                NT_WEAK   : next_state[i] = taken[i] ? T_WEAK   : NT_STRONG;
                T_WEAK    : next_state[i] = taken[i] ? T_STRONG : NT_WEAK;
                T_STRONG  : next_state[i] = taken[i] ? T_STRONG : T_WEAK;
            endcase
        end
    end

    always_ff @(posedge clock) begin
        if (reset) begin
            for (int i = 0; i < `GSHARE_SIZE; i++) begin
                bimodal_table[i] <= NT_WEAK;
            end
        end else begin
            for (int i = 0; i < `FETCH_WIDTH; i++) begin
                if(enable[i]) begin
                    bimodal_table[ex_index[i]] <= next_state[i];
                end
            end
        end
    end

endmodule