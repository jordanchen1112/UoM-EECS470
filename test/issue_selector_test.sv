// =========================================================
// FU #0 = ALU0
// FU #1 = ALU1
// FU #2 = ALU2
// FU #3 = MUL
// FU #4 = LOAD
// FU #5 = BRANCH
// =========================================================

module issue_selector #(
    parameter int unsigned RS_DEPTH        = 64, // RS entry numbers
    parameter int unsigned FU_NUM          = 6,  // total physical FUs
    parameter int unsigned ISSUE_WIDTH     = 4
)(
    input  logic [FU_NUM-1:0]                 fu_fifo_full;, 
    input  logic [RS_DEPTH-1:0]               rs_ready_vec,
    input  logic [2:0]                        fu_types [RS_DEPTH], 
    output logic [RS_DEPTH-1:0]               issue_rs_entry       
)
    int issue_cnt;
    logic [FU_NUM-1:0]  tmp_fu_fifo_full;

    always_comb begin
        issue_rs_entry = '0;
        issue_cnt      = 0;
        tmp_fu_fifo_full      = fu_fifo_full;

        // Iterate through RS entries in order
        for (int i = 0; i < RS_DEPTH; i++) begin
            if (issue_cnt >= ISSUE_WIDTH)
                break;

            if (rs_ready_vec[i]) begin
                case (fu_types[i])

                    // ALU: can go to FIFO 1, 2, or 3
                    FU_ALU: begin
                        if (!tmp_fu_fifo_full[0]) begin
                            issue_rs_entry[i] = 1'b1;
                            tmp_fu_fifo_full[0] = 1;
                            issue_cnt++;
                        end
                        else if (!tmp_fu_fifo_full[1]) begin
                            issue_rs_entry[i] = 1'b1;
                            tmp_fu_fifo_full[1] =1;
                            issue_cnt++;
                        end
                        else if (!tmp_fu_fifo_full[2]) begin
                            issue_rs_entry[i] = 1'b1;
                            tmp_fu_fifo_full[2] =1;
                            issue_cnt++;
                        end
                    end

                    // MUL → FIFO[4]
                    FU_MUL: begin
                        if (!tmp_fu_fifo_full[3]) begin
                            issue_rs_entry[i] = 1'b1;
                            tmp_fu_fifo_full[3] = 1;
                            issue_cnt++;
                        end
                    end

                    // LOAD → FIFO[5]
                    FU_LOAD: begin
                        if (!tmp_fu_fifo_full[4]) begin
                            issue_rs_entry[i] = 1'b1;
                            tmp_fu_fifo_full[4] = 1;
                            issue_cnt++;
                        end
                    end

                    // BRANCH → FIFO[6]
                    FU_BRANCH: begin
                        if (!tmp_fu_fifo_full[5]) begin
                            issue_rs_entry[i] = 1'b1;
                            tmp_fu_fifo_full[5] = 1;
                            issue_cnt++;
                        end
                    end

                    default: ;
                endcase
            end
        end
    end

endmodule