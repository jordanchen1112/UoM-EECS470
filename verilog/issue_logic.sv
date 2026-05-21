`include "def.svh"
`include "ISA.svh"

module issue_logic #(
    parameter int unsigned RS_DEPTH        = 64, //RS entry numbers
    parameter int unsigned DISPATCH_WIDTH  = 1,
    parameter int unsigned ISSUE_WIDTH     = 1,
    parameter int unsigned CDB_WIDTH       = 1,
    parameter int unsigned PHYS_REGS       = 128,
    parameter int unsigned OPCODE_N        = 8,  //number of opcodes
    parameter int unsigned FU_NUM          = 6,  // how many different FU
    parameter int unsigned XLEN            = 32,
    parameter int ALU_COUNT   = 1,
    parameter int MUL_COUNT   = 1,
    parameter int LOAD_COUNT  = 1,
    parameter int BR_COUNT    = 1
)(
    input  logic                                                  clock,
    input  logic                                                  reset,

    // =========================================================
    // RS -> Issue Logic
    // =========================================================
    input  rs_entry_t    [RS_DEPTH-1:0]             rs_entries_i,
    input  logic         [RS_DEPTH-1:0]             rs_ready_i,
    input  fu_type_e                                fu_types_i [RS_DEPTH],

    output logic         [RS_DEPTH-1:0]             issue_enable_o, // which rs slot is going to be issued

    // =========================================================
    // FU <-> Issue logic
    // =========================================================
    //input   logic          [$clog2(MAX_FIFO_DEPTH)-1:0] fu_free_slots [FU_NUM], // Remaining FIFO space for each FU
    input logic   alu_ready_i  [ALU_COUNT],
    input logic   mul_ready_i  [MUL_COUNT],
    input logic   load_ready_i [LOAD_COUNT],
    input logic   br_ready_i   [BR_COUNT],

    output  issue_packet_t alu_req_o  [ALU_COUNT], // pkts to ALU 
    output  issue_packet_t mul_req_o  [MUL_COUNT],
    output  issue_packet_t load_req_o [LOAD_COUNT],
    output  issue_packet_t br_req_o   [BR_COUNT]
);

    // =========================================================
    // Grant Issue permission to RS entry (by issue selector)
    // =========================================================
    // Select who can issue ('issue_enable')
    logic [RS_DEPTH-1:0] issue_sel_out;
    logic [RS_DEPTH-1:0] issue_enable_o_next; // internal signal
    assign issue_enable_o = issue_sel_out;
    

    issue_selector #(
        .RS_DEPTH(RS_DEPTH),
        .ISSUE_WIDTH(ISSUE_WIDTH),
        .ALU_COUNT(ALU_COUNT),
        .MUL_COUNT(MUL_COUNT),
        .LOAD_COUNT(LOAD_COUNT),
        .BR_COUNT(BR_COUNT)
    )issue_sel(
        .alu_ready_i(alu_ready_i),
        .mul_ready_i(mul_ready_i),
        .load_ready_i(load_ready_i),
        .br_ready_i(br_ready_i),

        .rs_ready_vec(rs_ready_i),
        .fu_types(fu_types_i),
        .issue_rs_entry(issue_sel_out) //第幾個Rs entry可以issue
    );

    // Prevent issue_enable_o -> affect RS (input of issue selector) at the same cycle
    /*
    always_ff @( posedge clock) begin 
        //$display("issue_enable_o_ = %b | issue_enable_o_next = %b", issue_enable_o, issue_enable_o_next);
        if (reset) begin
            issue_enable_o <= '0;
        end else begin
            issue_enable_o <= issue_enable_o_next;
        end
    end
    */
    
    // =========================================================
    // Issue logic -> FU
    // =========================================================
    issue_packet_t [ISSUE_WIDTH-1:0]   issue_pkts    ;    // packets to FIFOs
    int issue_slot;
    logic [XLEN-1:0] src1_mux, src2_mux;
    logic src2_valid, src1_valid;

    // Generate Issue Packets
    //TODO issue pkts reg exist latch
    always_comb begin : issue_output
        issue_slot = 0;
        for(int i = 0; i < `SINGLE_FU_NUM; i++) begin
            alu_req_o[i]  = '0;
            mul_req_o[i]  = '0;
            load_req_o[i] = '0;
            br_req_o[i]   = '0;
        end
        src1_mux ='0;
        src2_mux ='0;
        src2_valid = 0;
        src1_valid = 0;

        for (int j = 0; j < ISSUE_WIDTH; j++) begin
            issue_pkts[j] = '0;
        end

        for (int i = 0; i < RS_DEPTH; i++) begin
            if (issue_sel_out[i]) begin
                
                // src1 value
                case (rs_entries_i[i].disp_packet.opa_select)
                    OPA_IS_RS1:  src1_mux =  rs_entries_i[i].src1_tag;
                    OPA_IS_NPC:  src1_mux = rs_entries_i[i].disp_packet.NPC;
                    OPA_IS_PC:   src1_mux = rs_entries_i[i].disp_packet.PC;
                    OPA_IS_ZERO: src1_mux = 0;
                    default:     src1_mux = 32'hdeadface; // dead face
                endcase

                // src2 value
                case (rs_entries_i[i].disp_packet.opb_select)
                    OPB_IS_RS2:   src2_mux = rs_entries_i[i].src2_tag;
                    OPB_IS_I_IMM: src2_mux = `RV32_signext_Iimm(rs_entries_i[i].disp_packet.inst);
                    OPB_IS_S_IMM: src2_mux = `RV32_signext_Simm(rs_entries_i[i].disp_packet.inst);
                    OPB_IS_B_IMM: src2_mux = `RV32_signext_Bimm(rs_entries_i[i].disp_packet.inst);
                    OPB_IS_U_IMM: src2_mux = `RV32_signext_Uimm(rs_entries_i[i].disp_packet.inst);
                    OPB_IS_J_IMM: src2_mux = `RV32_signext_Jimm(rs_entries_i[i].disp_packet.inst);
                    default:      src2_mux = 32'hfacefeed; // face feed
                endcase
                case (rs_entries_i[i].disp_packet.opa_select)
                    OPA_IS_RS1:  src1_valid =  1;
                    OPA_IS_NPC:  src1_valid =  0;
                    OPA_IS_PC:   src1_valid =  0;
                    OPA_IS_ZERO: src1_valid =  0;
                    default:     src1_valid =  1; // dead face
                endcase
                // src2 valid
                case (rs_entries_i[i].disp_packet.opb_select)
                    OPB_IS_RS2:   src2_valid =  1;
                    OPB_IS_I_IMM: src2_valid = 0;
                    OPB_IS_S_IMM: src2_valid = 0;
                    OPB_IS_B_IMM: src2_valid = 0;//1
                    OPB_IS_U_IMM: src2_valid = 0;
                    OPB_IS_J_IMM: src2_valid = 0;
                    default:      src2_valid = 1; // face feed
                endcase
                if(rs_entries_i[i].disp_packet.wr_mem) begin
                    src2_valid = 1;
                end
                 //$display("imm = %d", src2_mux);
                issue_pkts[issue_slot].opcode =  rs_entries_i[i].disp_packet.alu_func; // 4 bit opcode for ALU(add/ sub...)
                issue_pkts[issue_slot].src1_val  = src1_mux;
                issue_pkts[issue_slot].src2_val  = src2_mux;
                issue_pkts[issue_slot].src1_mux  = rs_entries_i[i].src1_tag;
                issue_pkts[issue_slot].src2_mux  = rs_entries_i[i].src2_tag;

                issue_pkts[issue_slot].imm       = src2_mux;
                issue_pkts[issue_slot].src1_valid  = src1_valid;
                issue_pkts[issue_slot].src2_valid  = src2_valid;


                issue_pkts[issue_slot].valid     = 1;
                issue_pkts[issue_slot].rob_idx   = rs_entries_i[i].rob_idx;
                issue_pkts[issue_slot].fu_type   = rs_entries_i[i].disp_packet.fu_type;
                issue_pkts[issue_slot].dest_tag  = rs_entries_i[i].dest_tag;
                issue_pkts[issue_slot].disp_packet  = rs_entries_i[i].disp_packet;

                case (issue_pkts[issue_slot].fu_type)
                    FU_ALU:  if (alu_ready_i[0])  alu_req_o[0]  = issue_pkts[issue_slot];
                    FU_MUL:  if (mul_ready_i[0])  mul_req_o[0]  = issue_pkts[issue_slot];
                    FU_LOAD: if (load_ready_i[0]) load_req_o[0] = issue_pkts[issue_slot];
                    FU_BRANCH: if (br_ready_i[0]) br_req_o[0]   = issue_pkts[issue_slot];
                    default: ;
                endcase

                issue_slot++;
                if (issue_slot >= ISSUE_WIDTH) break;
            end 
        end

end

  // =========================================================
  // DEBUG
  // =========================================================
  
//     task automatic show_rs_input();
//         //$display("[cycle]:", cyc);
//         for (int i = 0; i < RS_DEPTH; i++) begin
//           //$display(  "opcode: %d", rs_entries_i[i].disp_packet.alu_func);
//         $display("Entry %0d: opb_select=%0d, i_imm = %0d, u_imm =%0d, ready=%b, valid=%b, alu_func=%0d, rob_idx=%0d, fu_type=%0d, dest_reg_idx=%0d, dest_tag=%0d, src1_tag=%0d(%b), src2_tag=%0d(%b)", 
//             i, rs_entries_i[i].disp_packet.opb_select, rs_entries_i[i].disp_packet.inst.i.imm, rs_entries_i[i].disp_packet.inst.u.imm, rs_ready_i[i], rs_entries_i[i].valid, rs_entries_i[i].disp_packet.alu_func, rs_entries_i[i].rob_idx, rs_entries_i[i].disp_packet.fu_type, 
//             rs_entries_i[i].disp_packet.dest_reg_idx , rs_entries_i[i].dest_tag, rs_entries_i[i].src1_tag, rs_entries_i[i].src1_ready,
//             rs_entries_i[i].src2_tag, rs_entries_i[i].src2_ready);
//         end
//     endtask

//     task automatic test_grant_vector(int cyc);
//             //$display("[cycle]:", cyc);
//             for (int j = 0; j < RS_DEPTH; j++) begin
//                 $write("%b", issue_sel_out[j]);
//             end
//             $write("\n");
        
//     endtask

//     task automatic test_reqs();
//         //$display("cycle= %d",cyc);
//         // ---------------- ALU ----------------
//         $display("ALU_REQ[0]: valid=%b | rob=%0d | fu=%p | opcode=%0d | dest_tag=%0d", 
//                 alu_req_o[0].valid, alu_req_o[0].rob_idx, alu_req_o[0].fu_type, alu_req_o[0].opcode, alu_req_o[0].dest_tag);
//         $display("            imm=%h | src1_val=%h | src2_val=%h", 
//                 alu_req_o[0].imm, alu_req_o[0].src1_val, alu_req_o[0].src2_val);
//         /*
//         // ---------------- MUL ----------------
//         $display("MUL_REQ[0]: valid=%b | rob=%0d | fu=%p | opcode=%0d | dest_tag=%0d", 
//                 mul_req_o[0].valid, mul_req_o[0].rob_idx, mul_req_o[0].fu_type, mul_req_o[0].opcode, mul_req_o[0].dest_tag);
//         $display("            imm=%h | src1_val=%h | src2_val=%h", 
//                 mul_req_o[0].imm, mul_req_o[0].src1_val, mul_req_o[0].src2_val);

//         // ---------------- LOAD ----------------
//         $display("LOAD_REQ[0]: valid=%b | rob=%0d | fu=%p | opcode=%0d | dest_tag=%0d", 
//                 load_req_o[0].valid, load_req_o[0].rob_idx, load_req_o[0].fu_type, load_req_o[0].opcode, load_req_o[0].dest_tag);
//         $display("             imm=%h | src1_val=%h | src2_val=%h", 
//                 load_req_o[0].imm, load_req_o[0].src1_val, load_req_o[0].src2_val);

//         // ---------------- BR ----------------
//         $display("BR_REQ[0]: valid=%b | rob=%0d | fu=%p | opcode=%0d | dest_tag=%0d", 
//                 br_req_o[0].valid, br_req_o[0].rob_idx, br_req_o[0].fu_type, br_req_o[0].opcode, br_req_o[0].dest_tag);
//         $display("           imm=%h | src1_val=%h | src2_val=%h", 
//                 br_req_o[0].imm, br_req_o[0].src1_val, br_req_o[0].src2_val);
//         */
//     endtask
// `ifndef SYNTHESIS
// task automatic show_issue_output;
//     // ---- ALU requests ----
// $write("ALU_REQ:\n");
// for (int i = 0; i < ALU_COUNT; i++) begin
//     $write("  [%0d] valid=%b | rob=%0d | dest=%0d | src1=%h | src2=%h | imm=%h | src2_valid=%b | fu=%p\n",
//            i,
//            alu_req_o[i].valid,
//            alu_req_o[i].rob_idx,
//            alu_req_o[i].dest_tag,
//            alu_req_o[i].src1_val,
//            alu_req_o[i].src2_val,
//            alu_req_o[i].imm,
//            alu_req_o[i].src2_valid,
//            alu_req_o[i].fu_type);
// end


//     // ---- MUL requests ----
//     $write("MUL_REQ:\n");
//     for (int i = 0; i < MUL_COUNT; i++) begin
//         $write("  [%0d] valid=%b | rob=%0d | dest=%0d | src1=%h | src2=%h | imm=%h | src2_valid=%b | fu=%p\n",
//             i,
//             mul_req_o[i].valid,
//             mul_req_o[i].rob_idx,
//             mul_req_o[i].dest_tag,
//             mul_req_o[i].src1_val,
//             mul_req_o[i].src2_val,
//             mul_req_o[i].imm,
//             mul_req_o[i].src2_valid,
//             mul_req_o[i].fu_type);
//     end

//     // ---- LOAD requests ----
//     $write("LOAD_REQ:\n");
//     for (int i = 0; i < LOAD_COUNT; i++) begin
//         $write("  [%0d] valid=%0b | rob=%0d | dest=%0d | src1=%0d | src2=%0d\n",
//                i,
//                load_req_o[i].valid,
//                load_req_o[i].rob_idx,
//                load_req_o[i].dest_tag,
//                load_req_o[i].src1_val,
//                load_req_o[i].src2_val);
//     end

//     // ---- BRANCH requests ----
//     $write("BR_REQ:\n");
//     for (int i = 0; i < BR_COUNT; i++) begin
//         $write("  [%0d] valid=%0b | rob=%0d | dest=%0d | src1=%0d | src2=%0d | src1_mux=%0d | src2_mux=%0d\n",
//                i,
//                br_req_o[i].valid,
//                br_req_o[i].rob_idx,
//                br_req_o[i].dest_tag,
//                br_req_o[i].src1_val,
//                br_req_o[i].src2_val,
//                br_req_o[i].src1_mux,
//                br_req_o[i].src2_mux);
//     end

//     $write("=============================================================\n\n");
// endtask

//   int cycle_count;
//   always_ff @(posedge clock) begin
//     if (reset)  
//         cycle_count <= 0;
//     else
//       cycle_count <= cycle_count + 1;
//       // $display("// ---------------- CYCLE = %d ---------------- //",cycle_count);
//       //test_reqs();
//       //test_grant_vector(cycle_count);
//     //   show_rs_input();
      
//       //show_issue_packets(cycle_count);
//       //test_issue_selector(cycle_count);
//       show_issue_output();
      
    
//   end
// `endif

endmodule


