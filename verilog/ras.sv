`include "sys_defs.svh"

module ras (
    input  logic clock,
    input  logic reset,

    // Input
    input ADDR pc_in,
    input logic push,
    input logic pop,

    // output
    output ADDR return_pc_o,
    output logic empty_o

);
    logic [`RAS_SIZE-1:0][`XLEN-1:0] ras_stack;
    logic [$clog2(`RAS_SIZE)-1:0] top;  //next free entry
    logic [$clog2(`RAS_SIZE)-1:0] index;
    logic [$clog2(`RAS_SIZE):0]   count; // Note: Extra bit to store "SIZE" value

    assign index = top ? top - 1 : `RAS_SIZE - 1; // Point to the top of the stack
    assign return_pc_o = ras_stack[index];
    
    assign empty_o = (count == 0);

    always_ff @(posedge clock) begin
        if (reset) begin
            count <= '0;
            top <= '0;
        end else begin
            if (pop && !push) begin
                if (count > 0) begin
                     top <= (top == 0) ? (`RAS_SIZE - 1) : (top - 1);
                end
            end else if (push && !pop) begin
                ras_stack[top] <= pc_in+4;
                if (top == `RAS_SIZE-1) begin
                    top <= 0;
                end else begin
                    top <= top + 1;
                end
            end else if (push && pop) begin
                ras_stack[top] <= pc_in + 4; 
            end

            if (push && !pop) begin
                // Increment count, saturate at RAS_SIZE
                if (count < `RAS_SIZE) count <= count + 1;
            end 
            else if (pop && !push) begin
                // Decrement count, saturate at 0
                if (count > 0) count <= count - 1;
            end
        end
    end

endmodule