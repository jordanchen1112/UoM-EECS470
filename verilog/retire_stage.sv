module retire_stage #(
    parameter int unsigned ARCH_REGS    = 64,
    parameter int unsigned PHYS_REGS    = 128,
    parameter int unsigned COMMIT_WIDTH = 1
)(
    input  logic clock,
    input  logic reset,

    // rob
    input  logic [COMMIT_WIDTH-1:0]                         commit_valid_i,
    input  logic [COMMIT_WIDTH-1:0]                         commit_rd_wen_i,
    input  logic [COMMIT_WIDTH-1:0][$clog2(ARCH_REGS)-1:0]  commit_rd_arch_i,
    input  logic [COMMIT_WIDTH-1:0][$clog2(PHYS_REGS)-1:0]  commit_new_prf_i,
    input  logic [COMMIT_WIDTH-1:0][$clog2(PHYS_REGS)-1:0]  commit_old_prf_i,

    // flush in rob
    input  logic                                            flush_i,

    // arch. map
    output logic [COMMIT_WIDTH-1:0]                         amt_commit_valid_o,
    output logic [COMMIT_WIDTH-1:0][$clog2(ARCH_REGS)-1:0]  amt_commit_arch_o,
    output logic [COMMIT_WIDTH-1:0][$clog2(PHYS_REGS)-1:0]  amt_commit_phys_o,

    // free list
    output logic [COMMIT_WIDTH-1:0]                         free_valid_o,
    output logic [COMMIT_WIDTH-1:0][$clog2(PHYS_REGS)-1:0]  free_reg_o,

    // debug in cpu
    output logic [$clog2(COMMIT_WIDTH+1)-1:0]               retire_cnt_o
);
    logic fire;
    always_comb begin
        amt_commit_valid_o = '0;
        amt_commit_arch_o  = '0;
        amt_commit_phys_o  = '0;

        free_valid_o       = '0;
        free_reg_o         = '0;

        for (int i = 0; i < COMMIT_WIDTH; i++) begin
            fire = commit_valid_i[i] & commit_rd_wen_i[i];

           // fire = commit_valid_i[i] & commit_rd_wen_i[i] & ~flush_i;

            if (fire) begin
                amt_commit_valid_o[i] = 1'b1;
                amt_commit_arch_o[i]  = commit_rd_arch_i[i];
                amt_commit_phys_o[i]  = commit_new_prf_i[i];
            end

            if (fire) begin
                if (commit_old_prf_i != 0) begin
                free_valid_o[i] = 1'b1;
                free_reg_o[i]   = commit_old_prf_i[i];
                end
            end
        end
    end

    always_comb begin
        retire_cnt_o = '0;
        for (int i = 0; i < COMMIT_WIDTH; i++) begin
            retire_cnt_o += (commit_valid_i[i] & commit_rd_wen_i[i] & ~flush_i);
        end
    end

    // always_ff @(posedge clock) begin
    //     for (int i=0; i < COMMIT_WIDTH; i++) begin
    //         $display("free_valid_o=%d, commit_old_prf_i:%d | free_reg_o:%d",free_valid_o[i] ,commit_old_prf_i[i], free_reg_o[i]);
    //     end
    // end
   // =========================================================
    // For GUI Debugger (Retire Trace)
    // =========================================================
    // integer retire_trace_fd;

    // initial begin
    //     retire_trace_fd = $fopen("dump_files/retire_trace.json", "w");
    //     if (retire_trace_fd == 0)
    //         $fatal("Failed to open dump_files/retire_trace.json!");
    // end

    // function automatic string safe_str(input logic [31:0] sig);
    //     if ($isunknown(sig))
    //         return "\"x\"";
    //     else
    //         return $sformatf("%0d", sig);
    // endfunction



    // task automatic dump_retire_state(int cycle);
    //     $fwrite(retire_trace_fd, "{ \"cycle\": %0d, \"RETIRE\": [", cycle);
    //     for (int i = 0; i < COMMIT_WIDTH; i++) begin
    //         $fwrite(retire_trace_fd,
    //             "{\"idx\":%0d, \"commit_valid\":%s, \"rd_wen\":%s, \"rd_arch\":%s, \"new_prf\":%s, \"old_prf\":%s, \"amt_commit_valid\":%s, \"amt_arch\":%s, \"amt_phys\":%s, \"free_valid\":%s, \"free_reg\":%s}",
    //             i,
    //             safe_str(commit_valid_i[i]),
    //             safe_str(commit_rd_wen_i[i]),
    //             safe_str(commit_rd_arch_i[i]),
    //             safe_str(commit_new_prf_i[i]),
    //             safe_str(commit_old_prf_i[i]),
    //             safe_str(amt_commit_valid_o[i]),
    //             safe_str(amt_commit_arch_o[i]),
    //             safe_str(amt_commit_phys_o[i]),
    //             safe_str(free_valid_o[i]),
    //             safe_str(free_reg_o[i])
    //         );


    //         if (i != COMMIT_WIDTH - 1)
    //             $fwrite(retire_trace_fd, ",");
    //     end
    //     $fwrite(retire_trace_fd, "]}\n");
    //     $fflush(retire_trace_fd);
    // endtask


    // // =========================================================
    // // Auto Dump per Cycle
    // // =========================================================
    // int cycle_count;
    // always_ff @(posedge clock) begin
    //     if (reset) begin
    //         cycle_count <= 0;
    //     end else begin
    //         cycle_count <= cycle_count + 1;
    //         dump_retire_state(cycle_count);
    //     end
    // end
endmodule