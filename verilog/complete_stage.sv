`include "def.svh"
module complete_stage #(
    parameter int unsigned XLEN       = 32,
    parameter int unsigned PHYS_REGS  = 128,
    parameter int unsigned ROB_DEPTH  = 64,
    parameter int unsigned WB_WIDTH   = 4,
    parameter int unsigned CDB_WIDTH  = 4
)(
    input  logic clock,
    input  logic reset,

    // LSQ (only load instruction)
    input logic       wb_valid,
    input ROB_IDX     wb_rob_idx,
    input logic [31:0]   wb_data, 
    input logic         wb_is_lw,
    input MEM_SIZE      wb_size,
    input logic [2:0]   funct3,
    input logic [$clog2(PHYS_REGS)-1:0] wb_disp_rd_new_prf_i,

    // FU
    input  logic [WB_WIDTH-1:0]                    fu_valid_i,
    input  logic [WB_WIDTH-1:0][XLEN-1:0]          fu_value_i,
    input  logic [WB_WIDTH-1:0][$clog2(PHYS_REGS)-1:0] fu_dest_prf_i,
    input  logic [WB_WIDTH-1:0][$clog2(ROB_DEPTH)-1:0] fu_rob_idx_i,
    input  logic [WB_WIDTH-1:0]                    fu_exception_i,
    input  logic [WB_WIDTH-1:0]                    fu_mispred_i,
    input  ADDR  [WB_WIDTH-1:0]                 fu_jtype_value_i,
    input  logic [WB_WIDTH-1:0]                    fu_is_jtype,
    input logic  [WB_WIDTH-1:0][2:0]                fu_funct3_i,
    input logic [WB_WIDTH-1:0]                      fu_is_lw_i,
    // input MEM_SIZE                                   
    // PR
    output logic [WB_WIDTH-1:0]                    prf_wr_en_o,
    output logic [WB_WIDTH-1:0][$clog2(PHYS_REGS)-1:0] prf_waddr_o,
    output logic [WB_WIDTH-1:0][XLEN-1:0]          prf_wdata_o,

    // rob
    output logic [WB_WIDTH-1:0]                    wb_valid_o,
    output logic [WB_WIDTH-1:0][$clog2(ROB_DEPTH)-1:0] wb_rob_idx_o,
    output logic [WB_WIDTH-1:0]                    wb_exception_o,
    output logic [WB_WIDTH-1:0]                    wb_mispred_o,
    output logic [WB_WIDTH-1:0][XLEN-1:0]          wb_value_o,

    // cdb
    output cdb_entry_t [CDB_WIDTH-1:0]             cdb_o
);

    logic is_unsigned;
    logic [63:0] wb_ext;
    logic [7:0] b;
    logic [15:0] h;
    logic [31:0] w;
    // int idx;
    always_comb begin
        // idx = 0;
        prf_wr_en_o   = '0;
        prf_waddr_o   = '0;
        prf_wdata_o   = '0;
        wb_valid_o    = '0;
        wb_rob_idx_o  = '0;
        wb_exception_o = '0;
        wb_mispred_o   = '0;
        wb_value_o    = '0;
        cdb_o          = '0;
        is_unsigned = '0;
        wb_ext = '0;
        b = '0;
        h = '0;
        w = '0;
        for (int i = 0; i < WB_WIDTH; i++) begin
            if (fu_valid_i[i]) begin
                prf_wr_en_o[i]   = 1'b1;
                prf_waddr_o[i]   = fu_dest_prf_i[i];
               

                wb_valid_o[i]     = 1'b1;
                wb_rob_idx_o[i]   = fu_rob_idx_i[i];
                wb_exception_o[i] = fu_exception_i[i];
                wb_mispred_o[i]   = fu_mispred_i[i];
                if(fu_is_jtype[i])begin
                    prf_wdata_o[i]   = fu_jtype_value_i[i];
                    wb_value_o[i] = fu_jtype_value_i[i];
                end else begin
                    prf_wdata_o[i]   = fu_value_i[i];
                    wb_value_o[i]   = fu_value_i[i]; // 11/21 sychenn
                end

                cdb_o[i].valid     = 1'b1;
                cdb_o[i].dest_arch = '0; //todo: why is zero?
                cdb_o[i].phys_tag  = fu_dest_prf_i[i];
                cdb_o[i].value     = fu_value_i[i];          
            end else if (wb_valid && (i==2)) begin 
                // todo: lsq wb is valid
                // `ifndef SYNTHESIS
                // $display("complete stage: wb_valid=%b | wb_rob_idx=%d | wb_data=%h | wb_disp_rd_new_prf_i=%d ",wb_valid, wb_rob_idx, wb_data, wb_disp_rd_new_prf_i);
                // `endif
                // from lsq
                
            
                case (funct3)
                    3'b000:  is_unsigned = 0;  // LB size = BYTE;
                    3'b001:  is_unsigned = 0; // LH begin size = HALF; 
                    3'b010:  is_unsigned = 0;  // LW begin size = WORD;
                    3'b100:  is_unsigned = 1; // LBU begin size = BYTE;
                    3'b101:  is_unsigned = 1;  // LHU begin size = HALF;
                    default : is_unsigned = 0; 
                endcase
                // `ifndef SYNTHESIS
                // $display("complete stage: funct3: %b , is_unsigned = %b, wb_size = %d" , funct3, is_unsigned , wb_size);
                // `endif
                unique case (wb_size)
                    BYTE: begin
                        b = wb_data[7:0];
                        wb_ext = is_unsigned ? {24'b0, b} : {{24{b[7]}}, b};
                    end
                    HALF: begin
                        h = wb_data[15:0];
                        wb_ext = is_unsigned ? {16'b0, h} : {{16{h[15]}}, h};
                    end
                    WORD: begin
                        w = wb_data[31:0];
                        wb_ext = is_unsigned ? w :  w;
                    end
                    DOUBLE: begin
                        wb_ext = wb_data; // 不需要 extend
                    end
                endcase
                
                prf_wr_en_o[i]   = wb_valid;
                prf_waddr_o[i]   = wb_disp_rd_new_prf_i;
                prf_wdata_o[i]   = wb_ext;

                wb_valid_o[i]     = wb_valid;
                wb_rob_idx_o[i]   = wb_rob_idx;
                wb_exception_o[i] = '0;
                wb_mispred_o[i]   = '0;
                wb_value_o[i]   = wb_ext;

                cdb_o[i].valid     = wb_valid;
                cdb_o[i].dest_arch = '0;
                cdb_o[i].phys_tag  = wb_disp_rd_new_prf_i;
                cdb_o[i].value     = wb_ext; 
            end
            // $display("complete stage i, out, in = %0d, %0d, %0d", i, cdb_o[i].value, fu_value_i[i]);
        end
    end
    

endmodule

