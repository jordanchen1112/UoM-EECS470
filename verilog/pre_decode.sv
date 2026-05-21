`include "def.svh"
`include "ISA.svh"

module pre_decoder (
    input INST  inst,
    input logic valid, 
    output logic cond_branch, uncond_branch,
    output logic jump, jump_back
);
    always_comb begin
        cond_branch   = `FALSE;
        uncond_branch = `FALSE;
        jump          = `FALSE;
        jump_back     = `FALSE;

        if (valid) begin
            casez (inst)
                `RV32_JAL: begin
                    uncond_branch = `TRUE;
                    jump = `TRUE;
                end
                `RV32_JALR: begin
                    uncond_branch = `TRUE;
                    jump_back = `TRUE;
                end
                `RV32_BEQ, `RV32_BNE, `RV32_BLT, `RV32_BGE,
                `RV32_BLTU, `RV32_BGEU: begin
                    cond_branch = `TRUE;
                end
        endcase
        end
    end

endmodule