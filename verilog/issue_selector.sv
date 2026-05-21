
`include "def.svh"
module issue_selector #(
    parameter int unsigned RS_DEPTH    = 64,
    parameter int unsigned ISSUE_WIDTH = 4,
    parameter int ALU_COUNT   = 1,
    parameter int MUL_COUNT   = 1,
    parameter int LOAD_COUNT  = 1,
    parameter int BR_COUNT    = 1
)(
    input logic   alu_ready_i  [ALU_COUNT],
    input logic   mul_ready_i  [MUL_COUNT],
    input logic   load_ready_i [LOAD_COUNT],
    input logic   br_ready_i   [BR_COUNT],

    input  logic [RS_DEPTH-1:0]   rs_ready_vec,
    input  fu_type_e              fu_types [RS_DEPTH],

    output logic [RS_DEPTH-1:0]   issue_rs_entry
);
        int issue_cnt;
        int alu_cnt;
        int mul_cnt;
        int load_cnt;
        int br_cnt;


        always_comb begin
            issue_cnt = 0;
            alu_cnt  = 0;
            mul_cnt  = 0;
            load_cnt = 0;
            br_cnt   = 0;
            issue_rs_entry = '0;
            /*
            $write("rs_ready_vec = ");
            for (int i = 0; i < RS_DEPTH; i++) begin
                $write("%b",rs_ready_vec[i]);
            end
            $display("");
            $write("fu_types = ");
            
            for (int i = 0; i < RS_DEPTH; i++) begin
                $write("%p/ ",fu_types[i]);
            end
            $display("");
            */
            //$display("issue_cnt=%d | alu_cnt = %d |  alu_ready=%b",issue_cnt,alu_cnt,alu_ready_i[0]);
            for (int i = 0; i < RS_DEPTH; i++) begin
                if (issue_cnt >= ISSUE_WIDTH) break;
                if (rs_ready_vec[i]) begin
                    case (fu_types[i])
                        FU_ALU: begin
                            if ((alu_cnt==0) && alu_ready_i[0]) begin
                                issue_rs_entry[i] = 1;
                                alu_cnt++;
                                issue_cnt++;
                                /*
                                $display("RS_entry = %d", i);
                                for (int j = 0; j < RS_DEPTH; j++) begin
                                    $write("%b", issue_rs_entry[j]);
                                end
                                $write("\n");
                                */
                            end
                        end
                        FU_MUL: begin
                            if ((load_cnt==0) && mul_ready_i[0]) begin
                                issue_rs_entry[i] = 1;
                                mul_cnt++;
                                issue_cnt++;
                            end
                        end
                        FU_LOAD: begin
                            if ((mul_cnt==0) && load_ready_i[0]) begin
                                issue_rs_entry[i] = 1;
                                load_cnt++;
                                issue_cnt++;
                            end
                        end
                        FU_BRANCH: begin
                            if ((br_cnt ==0) && br_ready_i[0]) begin
                                issue_rs_entry[i] = 1;
                                br_cnt++;
                                issue_cnt++;
                            end
                        end
                        default: ;
                    endcase
                end
            end
        end
endmodule
