`timescale 1ns/1ps
`include "def.svh"

module issue_logic_tb;
    // Parameters
    localparam int RS_DEPTH       = 8;
    localparam int DISPATCH_WIDTH = 2;
    localparam int ISSUE_WIDTH    = 4;
    localparam int CDB_WIDTH      = 2;
    localparam int PHYS_REGS      = 128;
    localparam int OPCODE_N       = 8;
    localparam int FU_NUM         = 6;
    localparam int MAX_FIFO_DEPTH = 4;
    localparam int XLEN           = 64;

    // -----------------------------------------------------------
    // RS  
    // -----------------------------------------------------------
    // --- Inputs/Outputs ---
    logic clk, reset, flush;
    logic [DISPATCH_WIDTH-1:0] disp_valid_i;
    rs_entry_t [DISPATCH_WIDTH-1:0] rs_packets_i;
    logic [DISPATCH_WIDTH-1:0] disp_rs_rd_wen_i;
    logic [$clog2(DISPATCH_WIDTH+1)-1:0] free_slots_o;
    logic rs_full_o;
    logic [CDB_WIDTH-1:0] cdb_valid_i;
    logic [CDB_WIDTH-1:0][$clog2(PHYS_REGS)-1:0] cdb_tag_i;
    logic [RS_DEPTH-1:0] issue_enable_i;
    rs_entry_t [RS_DEPTH-1:0] rs_entries_o;
    logic [RS_DEPTH-1:0] rs_ready_o;
    fu_type_e fu_types_o [RS_DEPTH];

    logic [RS_DEPTH-1:0] issue_enable_o;

    // --- DUT ---
    RS #(
        .RS_DEPTH(RS_DEPTH),
        .DISPATCH_WIDTH(DISPATCH_WIDTH),
        .ISSUE_WIDTH(ISSUE_WIDTH),
        .CDB_WIDTH(CDB_WIDTH),
        .PHYS_REGS(PHYS_REGS),
        .FU_NUM(FU_NUM),
        .OPCODE_N(OPCODE_N),
        .XLEN(XLEN)
    ) dut_rs (
        .clk(clk),
        .reset(reset),
        .flush(flush),
        .disp_valid_i(disp_valid_i),
        .rs_packets_i(rs_packets_i),
        .disp_rs_rd_wen_i(disp_rs_rd_wen_i),
        .free_slots_o(free_slots_o),
        .rs_full_o(rs_full_o),
        .cdb_valid_i(cdb_valid_i),
        .cdb_tag_i(cdb_tag_i),
        .issue_enable_i(issue_enable_o), // get from issue logic
        .rs_entries_o(rs_entries_o),
        .rs_ready_o(rs_ready_o),
        .fu_type_o(fu_types_o)
    );

    // Helpfer task to dispatch instruction into RS
    task automatic dispatch_instr(
        input int idx, //which slots (n-way)
        input int fu_type,
        input int src1_tag,
        input bit src1_ready,
        input int src2_tag,
        input bit src2_ready,
        input int dest_tag,
        input int rob_idx
    );
        rs_packets_i[idx].valid      = 1'b1;
        rs_packets_i[idx].rob_idx    = rob_idx;
        rs_packets_i[idx].fu_type    = fu_type;
        rs_packets_i[idx].opcode     = 0;
        rs_packets_i[idx].dest_tag   = dest_tag;
        rs_packets_i[idx].src1_tag   = src1_tag;
        rs_packets_i[idx].src2_tag   = src2_tag;
        rs_packets_i[idx].src1_ready = src1_ready;
        rs_packets_i[idx].src2_ready = src2_ready;
        disp_valid_i[idx] = 1'b1;

    endtask

    task automatic show_status_rs();
        $display("RS Entries:");
        for (int i = 0; i < RS_DEPTH; i++) begin
        $display("Entry %0d: valid=%b, rob_idx=%0d, fu_type=%0d, dest_tag=%0d, src1_tag=%0d(%b), src2_tag=%0d(%b)", 
            i, rs_entries_o[i].valid, rs_entries_o[i].rob_idx, rs_entries_o[i].fu_type, 
            rs_entries_o[i].dest_tag, rs_entries_o[i].src1_tag, rs_entries_o[i].src1_ready,
            rs_entries_o[i].src2_tag, rs_entries_o[i].src2_ready);
        end
    endtask


    // -----------------------------------------------------------
    // Issue Logic  
    // -----------------------------------------------------------

    // -----------------------------------------------------------
    // DUT I/O
    // -----------------------------------------------------------
    //logic clk, reset;

    rs_entry_t         rs_entries_i [RS_DEPTH];
    logic              rs_ready_i   [RS_DEPTH];
    fu_type_e          fu_types_i   [RS_DEPTH];

    logic [$clog2(MAX_FIFO_DEPTH)-1:0] fu_free_slots [FU_NUM];
    logic [FU_NUM-1:0] fu_fifo_full;
    logic [FU_NUM-1:0] fu_fifo_wr_en;
    issue_packet_t                 fu_fifo_wr_pkt [FU_NUM] ;
    logic          [XLEN-1:0]                   src_val;

    // -----------------------------------------------------------
    // DUT instantiation (issue_logic)
    // -----------------------------------------------------------
    issue_logic #(
        .RS_DEPTH(RS_DEPTH),
        .ISSUE_WIDTH(ISSUE_WIDTH),
        .FU_NUM(FU_NUM),
        .MAX_FIFO_DEPTH(MAX_FIFO_DEPTH),
        .XLEN(XLEN)
    ) dut (
        .clk(clk),
        .reset(reset),

        // Get input directly from RS module
        .rs_entries_i(rs_entries_o),
        .rs_ready_i(rs_ready_o),
        .fu_types_i(fu_types_o),

        .issue_enable_o(issue_enable_o),

        .fu_fifo_full(fu_fifo_full),

        .fu_fifo_wr_en(fu_fifo_wr_en),
        .fu_fifo_wr_pkt(fu_fifo_wr_pkt)
    );

    // -----------------------------------------------------------
    // Clock generation
    // -----------------------------------------------------------
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // -----------------------------------------------------------
    // Tasks
    // -----------------------------------------------------------
    task automatic show_state();
        $display("\n======");
        $display("fu_fifo_full = %b", fu_fifo_full);
        for (int i = 0; i < RS_DEPTH; i++) begin
        $display("RS[%0d]: ready=%0b fu_type=%s issue=%0b",
                i, rs_ready_i[i], fu_types_i[i].name(), issue_enable_o[i]);
        end
        for (int f = 0; f < FU_NUM; f++) begin
        $display("FU[%0d]: wr_en=%0b valid=%0b fu_type=%s rob=%0d",
                f, fu_fifo_wr_en[f],
                fu_fifo_wr_pkt[f].valid,
                fu_fifo_wr_pkt[f].fu_type,
                fu_fifo_wr_pkt[f].rob_idx);
        end
    endtask

    task automatic reset_dut();
        // reset RS 
        reset = 1; flush = 0;
        disp_valid_i = '0; issue_enable_i = '0;
        cdb_valid_i = '0; cdb_tag_i = '0;
        disp_rs_rd_wen_i = '0;
        rs_packets_i = {default: '0};

        // reset issue logic
        fu_fifo_full = '{default: 0};
        src_val      = '0;
        #100; reset = 0;

    endtask

    task automatic show_issue_pkt(int i ); // this is the comb output
        $display("valid=%b rob_idx=%b imm=%0d fu_type=%0d opcode=%0d dest_tag=%0d src1_val=%b src2_val=%b",
                dut.fu_fifo_wr_pkt_next[i].valid,
                dut.fu_fifo_wr_pkt_next[i].rob_idx,
                dut.fu_fifo_wr_pkt_next[i].imm,
                dut.fu_fifo_wr_pkt_next[i].fu_type,
                dut.fu_fifo_wr_pkt_next[i].opcode,
                dut.fu_fifo_wr_pkt_next[i].dest_tag,
                dut.fu_fifo_wr_pkt_next[i].src1_val,
                dut.fu_fifo_wr_pkt_next[i].src2_val
        );
    endtask

    task automatic show_issue_pkt_reg(int i ); // this is the comb output
        $display("valid=%b rob_idx=%b imm=%0d fu_type=%0d opcode=%0d dest_tag=%0d src1_val=%b src2_val=%b",
                fu_fifo_wr_pkt[i].valid,
                fu_fifo_wr_pkt[i].rob_idx,
                fu_fifo_wr_pkt[i].imm,
                fu_fifo_wr_pkt[i].fu_type,
                fu_fifo_wr_pkt[i].opcode,
                fu_fifo_wr_pkt[i].dest_tag,
                fu_fifo_wr_pkt[i].src1_val,
                fu_fifo_wr_pkt[i].src2_val
        );
    endtask

    initial begin
        clk = 0;
        reset_dut();

        // Set FU FIFO full status
        fu_fifo_full[0] = 0; // ALU0
        fu_fifo_full[1] = 0; // ALU1
        fu_fifo_full[2] = 0; // ALU2
        fu_fifo_full[3] = 0; // MUL
        fu_fifo_full[4] = 0; // LOAD
        fu_fifo_full[5] = 0; // BRANCH

        // Dispatch some instructions into RS
        // [dispatch ID, fu_type, src1_tag, src1_ready, src2_tag, src2_ready, dest_tag, rob_idx]
        @(negedge clk);
        dispatch_instr(0, 0, 2, 1, 3, 0, 6, 0);
        dispatch_instr(1, 0, 4, 1, 3, 0, 7, 1);
        @(posedge clk);
        @(negedge clk);
        dispatch_instr(0, 0, 8, 1, 3, 0, 10, 2);
        dispatch_instr(1, 0, 10, 1, 3, 0, 12, 3);
        @(posedge clk);
        @(negedge clk);
        dispatch_instr(0, 0, 8, 1, 3, 0, 13, 4);
        dispatch_instr(1, 0, 10, 1, 3, 0, 14, 5);
        @(posedge clk);
        @(negedge clk);
        dispatch_instr(0, 0, 8, 1, 3, 0, 15, 6);
        dispatch_instr(1, 0, 10, 1, 3, 0, 16, 7);

        // Wake up all instructions
        @(negedge clk);
        cdb_valid_i[0] = 1;
        cdb_tag_i[0]   = 3; 
        @(posedge clk);
        cdb_valid_i = '0;
        $display("fu_fifo_wr_en = %b", dut.fu_fifo_wr_en_next);
        $display("issue_enable_o = %b", dut.issue_enable_o_next);
        $display("Issue Packet (comb)");
        for (int i = 0; i < ISSUE_WIDTH; i++) begin
            show_issue_pkt(i);
        end
        #1;
        @(posedge clk);
        $display("\nIssue Packet (reg)");
        for (int i = 0; i < ISSUE_WIDTH; i++) begin
            show_issue_pkt_reg(i);
        end
        show_status_rs();
        @(posedge clk);    


        #1000;
        $finish;
    end 

endmodule


