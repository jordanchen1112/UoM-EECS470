`include "sys_defs.svh"

module gshare (
    input logic clock,
    input logic reset,

    // Input from fetch stage
    input ADDR [`FETCH_WIDTH-1:0] if_pc_i,
    input logic [`FETCH_WIDTH-1:0] if_is_branch_i,

    // Input from execute stage
    input logic [`FETCH_WIDTH-1:0] ex_is_branch_i,
    input logic [`FETCH_WIDTH-1:0] ex_branch_taken_i,
    input ADDR [`FETCH_WIDTH-1:0] ex_branch_pc_i,
    input logic [`FETCH_WIDTH-1:0] [`HISTORY_BITS-1:0] ex_history_i, 
    input logic [`FETCH_WIDTH-1:0] mispredict_i,

    output logic [`FETCH_WIDTH-1:0] predict_o,
    output logic [`FETCH_WIDTH-1:0] [`HISTORY_BITS-1:0] history_o 
);
    initial assert(`FETCH_WIDTH == 1) else $error("This GShare module is optimized for FETCH_WIDTH=1 only.");

    typedef enum logic [1:0] {
        NT_STRONG  = 2'b00, 
        NT_WEAK    = 2'b01,
        T_WEAK     = 2'b10, 
        T_STRONG   = 2'b11
    } branch_state_t;

    branch_state_t [`GSHARE_SIZE-1:0] gshare_table; 
    branch_state_t [`FETCH_WIDTH-1:0] states, next_states;

    logic [`HISTORY_BITS-1:0] global_history, next_global_history;
    logic [`FETCH_WIDTH-1:0][`HISTORY_BITS-1:0] index, ex_index;
    
    // -----------------------------------------------------------------
    // PREDICTION LOGIC
    // -----------------------------------------------------------------
    always_comb begin
        history_o = '0;
        predict_o = '0;
        index = '0;
        
        // 1. Default: History stays the same
        next_global_history = global_history; 

        // 2. Fetch Stage Logic (Scalar)
        for (int i = 0; i < `FETCH_WIDTH; i++) begin
            // Calculate Index directly from current global history
            index[i] = if_pc_i[i][`HISTORY_BITS-1:0] ^ global_history;
            
            // Output the history used for this prediction
            history_o[i] = global_history;

            if (if_is_branch_i[i]) begin
                predict_o[i] = gshare_table[index[i]][1]; // MSB
                
                // Update history with prediction (Left Shift)
                next_global_history = {global_history[`HISTORY_BITS-2:0], predict_o[i]};
            end
        end

        // 3. Recovery Logic (Highest Priority)
        // If mispredict, we ignore the Fetch stage update and restore from Execute
        if (mispredict_i[0] && ex_is_branch_i[0]) begin
            // FIX: Correct shift syntax. Drop MSB, append Real Outcome.
            // Old Code: ex_history_i[i][`HISTORY_BITS-1:1] (WRONG - drops LSB)
            next_global_history = {ex_history_i[0][`HISTORY_BITS-2:0], ex_branch_taken_i[0]};
        end
    end

    // -----------------------------------------------------------------
    // UPDATE LOGIC (Execute Stage)
    // -----------------------------------------------------------------
    always_comb begin
        for (int i = 0; i < `FETCH_WIDTH; i++) begin
            // FIX: Always calculate ex_index, regardless of mispredict status
            ex_index[i] = ex_branch_pc_i[i][`HISTORY_BITS-1:0] ^ ex_history_i[i];
            
            states[i] = gshare_table[ex_index[i]];
            next_states[i] = states[i]; 

            // Standard Saturating Counter Update
            case (states[i]) 
                NT_STRONG : next_states[i] = ex_branch_taken_i[i] ? NT_WEAK  : NT_STRONG;
                NT_WEAK   : next_states[i] = ex_branch_taken_i[i] ? T_WEAK   : NT_STRONG;
                T_WEAK    : next_states[i] = ex_branch_taken_i[i] ? T_STRONG : NT_WEAK;
                T_STRONG  : next_states[i] = ex_branch_taken_i[i] ? T_STRONG : T_WEAK;
            endcase
        end
    end

    // -----------------------------------------------------------------
    // SEQUENTIAL LOGIC
    // -----------------------------------------------------------------
    always_ff @(posedge clock) begin
        if (reset) begin
            global_history <= '0;
            for (int i = 0; i < `GSHARE_SIZE; i++) begin
                gshare_table[i] <= NT_WEAK; 
            end
        end else begin          
            global_history <= next_global_history; 
            
            for (int i = 0; i < `FETCH_WIDTH; i++) begin
                if (ex_is_branch_i[i]) begin
                    gshare_table[ex_index[i]] <= next_states[i];
                end
            end

            // for (int i =0; i < `GSHARE_SIZE; i++)begin
            //     $display("gshare_table[%d]: state=%b ", i, gshare_table[i]);
            // end
        end


    end

endmodule