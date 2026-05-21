`include "def.svh"

// ---------------- ALU FU ----------------
module alu_fu #(
  parameter int XLEN = 32,
  parameter int PHYS_REGS = 128,
  parameter int ROB_DEPTH = 64
)(
  input  issue_packet_t req_i,
  output fu_resp_t      resp_o,
  output logic          ready_o,
  output logic   [XLEN-1:0]          resulta //debug

);
  logic [XLEN-1:0] result;
    always_comb begin
        case (req_i.opcode)
            ALU_ADD:  result = req_i.src1_val + req_i.src2_val;
            ALU_SUB:  result = req_i.src1_val - req_i.src2_val;
            ALU_AND:  result = req_i.src1_val & req_i.src2_val;
            ALU_SLT:  result = signed'(req_i.src1_val) < signed'(req_i.src2_val);
            ALU_SLTU: result = req_i.src1_val < req_i.src2_val;
            ALU_OR:   result = req_i.src1_val | req_i.src2_val;
            ALU_XOR:  result = req_i.src1_val ^ req_i.src2_val;
            ALU_SRL:  result = req_i.src1_val >> req_i.src2_val[4:0];
            ALU_SLL:  result = req_i.src1_val << req_i.src2_val[4:0];
            ALU_SRA:  result = signed'(req_i.src1_val) >>> req_i.src2_val[4:0]; // arithmetic from logical shift
            // here to prevent latches:
            default:  result = 32'hfacebeec;
        endcase
    // `ifndef SYNTHESIS
    // $display("ALU op=%0d src1=%h src2=%h result=%h time=%0t",
    //          req_i.opcode, req_i.src1_val, req_i.src2_val, result, $time);
    // `endif
    end

/*
  always_comb begin
    unique case (req_i.opcode)
      4'd0: result = req_i.src1_val + req_i.src2_val;
      4'd1: result = req_i.src1_val - req_i.src2_val;
      4'd2: result = req_i.src1_val & req_i.src2_val;
      4'd3: result = req_i.src1_val | req_i.src2_val;
      4'd4: result = req_i.src1_val ^ req_i.src2_val;
      4'd5: result = req_i.src1_val << req_i.src2_val[5:0];
      4'd6: result = req_i.src1_val >> req_i.src2_val[5:0];
      4'd7: result = $signed(req_i.src1_val) <<< req_i.src2_val[5:0];
      4'd8: result = ($signed(req_i.src1_val) <  $signed(req_i.src2_val));
      4'd9: result = (req_i.src1_val < req_i.src2_val);
      default: result = '0;
    endcase
  end*/

  assign ready_o = 1'b1;
  always_comb begin
    resp_o.valid     = req_i.valid;
    resp_o.value     = result;
    resp_o.dest_prf  = req_i.dest_tag;
    resp_o.rob_idx   = req_i.rob_idx;
    resp_o.exception = 1'b0;
    resp_o.mispred   = 1'b0;
    resp_o.is_lw     = 1'b0;
    resp_o.is_sw     = 1'b0;
    resp_o.sw_data   = '0;
    resp_o.j_type_value = '0;
    resp_o.is_jtype = '0;
    resp_o.funct3 = '0;
  end
endmodule


// ---------------- MUL FU ----------------
/* initial one
module mul_fu #(
  parameter int XLEN = 32,
  parameter int PHYS_REGS = 128,
  parameter int ROB_DEPTH = 64
)(
  input  issue_packet_t req_i,
  output fu_resp_t      resp_o,
  output logic          ready_o
);
  logic [2*XLEN-1:0] product;
  assign product = $signed(req_i.src1_val) * $signed(req_i.src2_val);

  assign ready_o = 1'b1;
  always_comb begin
    resp_o.valid     = req_i.valid;
    resp_o.value     = product[XLEN-1:0];
    resp_o.dest_prf  = req_i.dest_tag;
    resp_o.rob_idx   = req_i.rob_idx;
    resp_o.exception = 1'b0;
    resp_o.mispred   = 1'b0;
  end
endmodule
*/

module mul_fu #(
  parameter int XLEN = 32,
  parameter int PHYS_REGS = 128,
  parameter int ROB_DEPTH = 64
)(
    input logic clock,
    input logic reset,
    input  issue_packet_t req_i,

    output fu_resp_t      resp_o,
    output logic  ready_o
);

    issue_packet_t [`MULT_STAGES-1:0] req_i_list;
    always_ff @(posedge clock) begin
      if(reset) begin
        for (int i = 0; i < `MULT_STAGES; i++) begin
          req_i_list[i] <= '0;
        end
      end else begin
        req_i_list[0] <= req_i;
        for(int i = 1; i < `MULT_STAGES; i++) begin
          req_i_list[i] <= req_i_list[i - 1];
        end
      end
    end

    assign ready_o = 1'b1;
    MULT_FUNC fu_func;
    always_comb  begin
      fu_func = MULT_FUNC'(req_i.disp_packet.inst.r.funct3);
    end
    logic [XLEN-1:0] product;
    logic done;

    mult mult_0(
        .clock(clock), .reset(reset), .start(req_i.valid),
        .rs1(req_i.src1_val), .rs2(req_i.src2_val),
        .func(fu_func),
        // input logic [TODO] dest_tag_in,

        // output logic [TODO] dest_tag_out,
        .result(product),
        .done(done)
    );
    // assign product = mcand * mplier;

    always_comb begin
      resp_o = '0;
      if(done) begin
        resp_o.valid     = done;
        resp_o.value     = product;
        resp_o.dest_prf  = req_i_list[`MULT_STAGES-1].dest_tag;
        resp_o.rob_idx   = req_i_list[`MULT_STAGES-1].rob_idx;
        resp_o.exception = 1'b0;
        resp_o.mispred   = 1'b0;
        resp_o.is_lw     = 1'b0;
        resp_o.is_sw     = 1'b0;
        resp_o.sw_data   = '0;
        resp_o.j_type_value = '0;
        resp_o.is_jtype = '0;
        resp_o.funct3 = '0;
      end
    end

endmodule  

// ---------------- LOAD FU ----------------
module ls_fu #(
  parameter int XLEN = 32,
  parameter int PHYS_REGS = 128,
  parameter int ROB_DEPTH = 64
)(
  input  issue_packet_t req_i,
  output fu_resp_t      resp_o,
  output logic          ready_o
);
  logic [XLEN-1:0] addr;
  assign addr = req_i.src1_val + {{(XLEN-12){req_i.imm[11]}}, req_i.imm[11:0]};
  assign ready_o = 1'b1;

  always_comb begin
    resp_o = '0;

    resp_o.valid     = req_i.valid;
    resp_o.value     = addr;
    resp_o.rob_idx   = req_i.rob_idx;
    resp_o.exception = 1'b0;
    resp_o.mispred   = 1'b0;
    resp_o.j_type_value = '0;
    resp_o.is_jtype = '0;
    resp_o.funct3 = '0; // unsigned or signed

    if (req_i.disp_packet.rd_mem) begin
      resp_o.is_lw     = 1'b1;
      resp_o.is_sw     = 1'b0;
      resp_o.dest_prf  = req_i.dest_tag;
      resp_o.sw_data   = '0;
      resp_o.funct3 = req_i.disp_packet.inst.i.funct3;
      // `ifndef SYNTHESIS
      // $display("resp_o.funct3=%b", resp_o.funct3);
      // `endif

    end else if (req_i.disp_packet.wr_mem) begin
      resp_o.is_lw     = 1'b0;
      resp_o.is_sw     = 1'b1;
      resp_o.dest_prf  = '0;
      resp_o.sw_data   = req_i.src2_val;
      resp_o.funct3 = '0;
      // `ifndef SYNTHESIS
      // // $display("ROB %0d:sw | src2_val=%h", req_i.rob_idx, req_i.src2_val);
      // `endif

    end else begin
      resp_o.is_lw     = 1'b0;
      resp_o.is_sw     = 1'b0;
      resp_o.dest_prf  = '0;
      resp_o.sw_data   = '0;
      resp_o.funct3 = '0;
    end
  end
endmodule


// ---------------- BRANCH FU ----------------
module branch_fu #(
  parameter int XLEN = 32,
  parameter int PHYS_REGS = 128,
  parameter int ROB_DEPTH = 64
)(
  input  issue_packet_t req_i,
  output fu_resp_t      resp_o,
  output logic          ready_o
);

  fu_resp_t resp_local_o;
  logic is_jtype;

  alu_fu #(.XLEN(XLEN), .PHYS_REGS(PHYS_REGS), .ROB_DEPTH(ROB_DEPTH)) u_alu_br (
        .req_i  (req_i),
        .resp_o (resp_local_o),
        .ready_o(ready_o)
      );

  logic take;
  
  always_comb begin
    is_jtype = '0;
    take = `FALSE;
    if(req_i.disp_packet.uncond_branch == 1'b1) begin
          is_jtype = 1'b1;
          take = `TRUE;
    end else begin
          case (req_i.disp_packet.inst.b.funct3)
              3'b000:  take = signed'(req_i.src1_mux) == signed'(req_i.src2_mux); // BEQ
              3'b001:  take = signed'(req_i.src1_mux) != signed'(req_i.src2_mux); // BNE
              3'b100:  take = signed'(req_i.src1_mux) <  signed'(req_i.src2_mux); // BLT
              3'b101:  take = signed'(req_i.src1_mux) >= signed'(req_i.src2_mux); // BGE
              3'b110:  take = req_i.src1_mux < req_i.src2_mux;                    // BLTU
              3'b111:  take = req_i.src1_mux >= req_i.src2_mux;                   // BGEU
              default: take = `FALSE;
          endcase
    end
    `ifndef SYNTHESIS
    // $display(" un_br=%b | fun3=%b |src1/2=%d,%d |take =%b", req_i.disp_packet.uncond_branch, req_i.disp_packet.inst.b.funct3, signed'(req_i.src1_mux),signed'(req_i.src2_mux), take);
    `endif
  end

  // assign ready_o = 1'b1;

  always_comb begin
    resp_o.valid     = req_i.valid;
    resp_o.value     = resp_local_o.value; // alu value // addr
    resp_o.dest_prf  = req_i.dest_tag;
    resp_o.rob_idx   = req_i.rob_idx;
    resp_o.exception = 1'b1; // TODO: is branch
    resp_o.mispred   = take;
    resp_o.is_lw     = 1'b0;
    resp_o.is_sw     = 1'b0;
    resp_o.sw_data   = '0;
    resp_o.j_type_value = req_i.disp_packet.NPC;
    resp_o.is_jtype = is_jtype;
    resp_o.funct3 = '0;
  end
endmodule


module fu #(
  parameter int XLEN        = 32,
  parameter int PHYS_REGS   = 128,
  parameter int ROB_DEPTH   = 64,
  parameter int ALU_COUNT   = 1,
  parameter int MUL_COUNT   = 1,
  parameter int LOAD_COUNT  = 1,
  parameter int BR_COUNT    = 1
)(

    input  logic clock,     
    input  logic reset,

    // Issue → FU
    input  issue_packet_t alu_req  [ALU_COUNT],
    input  issue_packet_t mul_req  [MUL_COUNT],
    input  issue_packet_t load_req [LOAD_COUNT],
    input  issue_packet_t br_req   [BR_COUNT],

    // FU → Issue
    output logic   alu_ready_o  [ALU_COUNT],
    output logic   mul_ready_o  [MUL_COUNT],
    output logic   load_ready_o [LOAD_COUNT],
    output logic   br_ready_o   [BR_COUNT],

    // FU responses (for debug / tracing)
    output fu_resp_t fu_resp_bus [ALU_COUNT+MUL_COUNT+LOAD_COUNT+BR_COUNT],

    // FU → Complete Stage (flattened)
    output logic [ALU_COUNT+MUL_COUNT+LOAD_COUNT+BR_COUNT-1:0]                    fu_valid_o,
    output logic [ALU_COUNT+MUL_COUNT+LOAD_COUNT+BR_COUNT-1:0][XLEN-1:0]          fu_value_o,
    output logic [ALU_COUNT+MUL_COUNT+LOAD_COUNT+BR_COUNT-1:0][$clog2(PHYS_REGS)-1:0] fu_dest_prf_o,
    output logic [ALU_COUNT+MUL_COUNT+LOAD_COUNT+BR_COUNT-1:0][$clog2(ROB_DEPTH)-1:0] fu_rob_idx_o,
    output logic [ALU_COUNT+MUL_COUNT+LOAD_COUNT+BR_COUNT-1:0]                    fu_exception_o,
    output logic [ALU_COUNT+MUL_COUNT+LOAD_COUNT+BR_COUNT-1:0]                    fu_mispred_o,
    output ADDR  [ALU_COUNT+MUL_COUNT+LOAD_COUNT+BR_COUNT-1:0]                    fu_jtype_value_o,               
    output logic [ALU_COUNT+MUL_COUNT+LOAD_COUNT+BR_COUNT-1:0]                    fu_is_jtype_o,
    output logic [ALU_COUNT+MUL_COUNT+LOAD_COUNT+BR_COUNT-1:0][2:0]               fu_funct3_o, //signed or unsigned
    output logic [ALU_COUNT+MUL_COUNT+LOAD_COUNT+BR_COUNT-1:0]                    fu_is_lw_o,
    //FU -> LSQ
    output logic [LOAD_COUNT-1:0]                                               fu_ls_valid_o,
    output logic [LOAD_COUNT-1:0]             [$clog2(ROB_DEPTH)-1:0]           fu_ls_rob_idx_o,
    output ADDR [LOAD_COUNT-1:0]                                               fu_ls_addr_o,
    output logic [LOAD_COUNT-1:0]       [XLEN-1:0]                                 fu_sw_data_o,  //only for store instr.
    output logic [LOAD_COUNT-1:0][2:0]                                            fu_sw_funct3_o

);

  // For Store instruction (store data generation)
  int idx;
  always_comb begin 
    idx = 0;
    // clear zero
    for (int j = 0 ; j < LOAD_COUNT; j++) begin

        fu_ls_valid_o[j] = '0;
        fu_ls_rob_idx_o[j] = '0;
        fu_ls_addr_o[j] = '0;
        fu_sw_data_o[j] = '0;
        fu_sw_funct3_o[j] = '0;
    end

    // route fu_resp_bus to output to lsq 
    for (int i =0; i < (ALU_COUNT+MUL_COUNT+LOAD_COUNT+BR_COUNT); i++) begin
      if (fu_resp_bus[i].is_sw || fu_resp_bus[i].is_lw) begin
        fu_ls_valid_o[idx] = fu_resp_bus[i].valid;
        fu_ls_rob_idx_o[idx] = fu_resp_bus[i].rob_idx;
        `ifndef SYNTHESIS
        // $display("idx =%d | fu_resp_bus[i].rob_idx=%d", idx, fu_resp_bus[i].rob_idx);
        // $display("idx =%d | fu_ls_rob_idx_o[i].rob_idx=%d", idx, fu_ls_rob_idx_o[idx]);
        `endif
        fu_ls_addr_o[idx] = fu_resp_bus[i].value;
        fu_sw_data_o[idx] = fu_resp_bus[i].sw_data;
        fu_sw_funct3_o[idx] = fu_resp_bus[i].funct3;
        `ifndef SYNTHESIS
        // $display("fu_sw_funct3_o[%0d]=%b", idx, fu_sw_funct3_o[idx]);
        `endif
        idx ++;
      end
    end
  end

  localparam int TOTAL_FU = ALU_COUNT + MUL_COUNT + LOAD_COUNT + BR_COUNT;
  // always_ff @(negedge clock)
  logic [XLEN-1:0] results [ALU_COUNT+MUL_COUNT+LOAD_COUNT+BR_COUNT];
  genvar i;
  generate
    // ---------------- ALU ----------------
    for (i = 0; i < ALU_COUNT; i++) begin : GEN_ALU
      alu_fu #(.XLEN(XLEN), .PHYS_REGS(PHYS_REGS), .ROB_DEPTH(ROB_DEPTH)) u_alu (
        .req_i  (alu_req[i]),
        .resp_o (fu_resp_bus[i]),
        .ready_o(alu_ready_o[i])
      );
    end

    // ---------------- MUL ----------------
    for (i = 0; i < MUL_COUNT; i++) begin : GEN_MUL
      localparam int IDX = ALU_COUNT + i;
      mul_fu #(.XLEN(XLEN), .PHYS_REGS(PHYS_REGS), .ROB_DEPTH(ROB_DEPTH)) u_mul (
        .clock(clock),
        .reset(reset),
        .req_i  (mul_req[i]),
        .resp_o (fu_resp_bus[IDX]),
        .ready_o(mul_ready_o[i])
      );
    end



    // ---------------- LOAD ----------------
    for (i = 0; i < LOAD_COUNT; i++) begin : GEN_LOAD
      localparam int IDX = ALU_COUNT + MUL_COUNT + i;
      ls_fu #(.XLEN(XLEN), .PHYS_REGS(PHYS_REGS), .ROB_DEPTH(ROB_DEPTH)) u_load (
        .req_i  (load_req[i]),
        .resp_o (fu_resp_bus[IDX]),
        .ready_o(load_ready_o[i])
      );
    end

    // ---------------- BRANCH ----------------
    for (i = 0; i < BR_COUNT; i++) begin : GEN_BR
      localparam int IDX = ALU_COUNT + MUL_COUNT + LOAD_COUNT + i;
      
      branch_fu #(.XLEN(XLEN), .PHYS_REGS(PHYS_REGS), .ROB_DEPTH(ROB_DEPTH)) u_br (
        .req_i  (br_req[i]),
        .resp_o (fu_resp_bus[IDX]),
        .ready_o(br_ready_o[i])
      );
    end
  endgenerate

  // ==========================================================
  // ===             Flatten response for WB bus             ===
  // ==========================================================
  integer k;
  always_comb begin
    for (k = 0; k < TOTAL_FU; k++) begin
      if (fu_resp_bus[k].is_sw || fu_resp_bus[k].is_lw) begin
        fu_valid_o[k] = 0; // close load fu 
      end else begin 
        fu_valid_o[k] = fu_resp_bus[k].valid;
      end

      fu_value_o    [k] = fu_resp_bus[k].value;
      fu_dest_prf_o [k] = fu_resp_bus[k].dest_prf;
      fu_rob_idx_o  [k] = fu_resp_bus[k].rob_idx;
      fu_exception_o[k] = fu_resp_bus[k].exception;
      fu_mispred_o  [k] = fu_resp_bus[k].mispred;
      fu_jtype_value_o[k] = fu_resp_bus[k].j_type_value; //addr
      fu_is_jtype_o[k]    = fu_resp_bus[k].is_jtype;
      fu_funct3_o[k]    = fu_resp_bus[k].funct3;
      fu_is_lw_o[k]    = fu_resp_bus[k].is_lw;
      `ifndef SYNTHESIS
      // $display("fu_funct3_o[k]=%b", fu_funct3_o[k]);
      `endif
    end

  end

// `ifndef SYNTHESIS
//         // =========================================================
//     // For GUI Debugger (FU Trace)
//     // =========================================================
//     integer fu_trace_fd;

//     initial begin
//         fu_trace_fd = $fopen("dump_files/fu_trace.json", "w");
//         if (fu_trace_fd == 0)
//             $fatal("Failed to open dump_files/fu_trace.json!");
//     end

//     task automatic dump_fu_state(int cycle);

//         $fdisplay(fu_trace_fd, "FU TRACE DUMP TRIGGERED AT CYCLE %0d", cycle);
//         $fwrite(fu_trace_fd, "{ \"cycle\": %0d, \"FU\": [", cycle);
//         for (int i = 0; i < TOTAL_FU; i++) begin
//             automatic issue_packet_t req;

//             // Identify FU input source by index
//             if (i < ALU_COUNT)
//                 req = alu_req[i];
//             else if (i < ALU_COUNT + MUL_COUNT)
//                 req = mul_req[i - ALU_COUNT];
//             else if (i < ALU_COUNT + MUL_COUNT + LOAD_COUNT)
//                 req = load_req[i - ALU_COUNT - MUL_COUNT];
//             else
//                 req = br_req[i - ALU_COUNT - MUL_COUNT - LOAD_COUNT];

//             if (req.valid) begin
//                 $fwrite(fu_trace_fd,
//                     "{\"idx\":%0d, \"valid\":1, \"dest_tag\":%0d, \"rob_idx\":%0d, \"src1_val\":%0d, \"src2_val\":%0d}",
//                     i, req.dest_tag, req.rob_idx, req.src1_val, req.src2_val
//                 );
//             end else begin
//                 $fwrite(fu_trace_fd, "{\"idx\":%0d, \"valid\":0}", i);
//             end

//             if (i != TOTAL_FU - 1)
//                 $fwrite(fu_trace_fd, ",");
//         end
//         $fwrite(fu_trace_fd, "]}\n");
//         $fflush(fu_trace_fd);
//     endtask

//     // =========================================================
//     // Auto Dump per Cycle
//     // =========================================================
//     int fu_cycle_count;
//     always_ff @(posedge clock) begin
//         if (reset) begin
//             fu_cycle_count <= 0;
//         end else begin
//             fu_cycle_count <= fu_cycle_count + 1;
//             dump_fu_state(fu_cycle_count);
//             $display("fu_ls_valid_o=%b | fu_ls_rob_idx_o=%d|fu_sw_data_o=%h", fu_ls_valid_o,fu_ls_rob_idx_o[0],fu_sw_data_o);

                        

//         end
//     end

// `endif


endmodule