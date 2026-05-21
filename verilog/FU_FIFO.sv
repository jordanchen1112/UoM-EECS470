// =========================================================
// What should the FIFO_DEPTH be?
// =========================================================

module FIFO #(
    parameter  int unsigned     FIFO_DEPTH  = 16,
    parameter  int unsigned     ISSUE_WIDTH = 2,
    localparam int unsigned     CNT_BITS    = $clog2(FIFO_DEPTH+1) // DEPTH's bits
)(
    input  logic                clock,
    input  logic                reset,

    // =========================================================
    // Issue logic <-> FIFO
    // =========================================================
    input  logic                wr_en, // issue logic wants to push (write)
    input  issue_packet_t       issue_packet_i,
    output logic [CNT_BITS-1:0] free_slots_o, // # of free slots
    output logic                full_o,

    // =========================================================
    // FIFO <-> FU
    // =========================================================
    input  logic                rd_en, // FU wants to pull (read)
    output issue_packet_t       issue_packet_o,
    output logic                empty_o    // since output data is alwats visible, FU need to check if the FIFO is empty (zero latency for read)
);

    // =========================================================
    // FIFO internal signal
    // =========================================================
    // Contol signal
    logic                            wr_valid, rd_valid;

    // Storage (mem)
    issue_packet_t                   mem [FIFO_DEPTH];

    // Head & Tail
    logic [$clog2(FIFO_DEPTH)-1:0]   head, next_head;
    logic [$clog2(FIFO_DEPTH)-1:0]   tail, next_tail;

    // Reamaining slots
    logic [$clog2(FIFO_DEPTH+1)-1:0] entries, next_entries;  // how many current data in the FIFO
    logic [$clog2(FIFO_DEPTH+1)-1:0] real_spots; // use to saturate free_slots_o

    // Control Signals
    assign empty_o      = (entries == 0);
    assign full_o       = (entries == FIFO_DEPTH);

    assign wr_valid = wr_en && (!full_o || rd_valid); // valid when full but read & write at the same cycle
    assign rd_valid = rd_en && !empty_o;

    // Reamaining slots
    assign real_spots   = FIFO_DEPTH - entries;
    assign free_slots_o = (real_spots >= ISSUE_WIDTH) ? ISSUE_WIDTH : real_spots;

    // =========================================================
    // FIFO control part (pointers)
    // Head: Next read location
    // Tail: Next write location
    // =========================================================
    // Update FIFO pointers
    always_comb begin
        next_head = head;
        next_tail = tail;
        next_entries = entries;
        if (wr_valid) begin
            next_tail = (tail == FIFO_DEPTH - 1) ? 0 : tail + 1;
            next_entries++;
        end
        if (rd_valid) begin
            next_head = (head == FIFO_DEPTH - 1) ? 0 : head + 1;
            next_entries--;
        end
    end

    // Save update to FIFO pointers
    always_ff @(posedge clock) begin
        if (reset) begin
            tail    <= 0;
            head    <= 0;
            entries <= 0;
        end else begin
            head    <= next_head;
            tail    <= next_tail;
            entries <= next_entries;
        end
    end

    // =========================================================
    // Write (push)
    // =========================================================
    always_ff @(posedge clock) begin
        if (wr_valid)
            mem[tail] <= issue_packet_i;
    end

    // =========================================================
    // Read (pop)
    // =========================================================
    assign issue_packet_o = (rd_valid) ? mem[head] : '0;  // simple read, combinational

endmodule

module FU_FIFO #(
    parameter int unsigned ISSUE_WIDTH    = 2,
    parameter int unsigned FU_NUM         = 6,
    parameter int unsigned FIFO_DEPTH     = 4,
    parameter int unsigned XLEN           = 32,
    localparam int unsigned CNT_BITS      = $clog2(FIFO_DEPTH+1)
)(
    input  logic                              clock,
    input  logic                              reset,

    // =========================================================
    // Issue logic → FU FIFO
    // =========================================================
    input  logic          [FU_NUM-1:0]        fu_fifo_wr_en,
    input  issue_packet_t [FU_NUM-1:0]        fu_fifo_wr_pkt,

    output logic          [FU_NUM-1:0]        fu_fifo_full,
    output logic          [CNT_BITS-1:0]      fu_free_slots [FU_NUM],

    // =========================================================
    // FU FIFO -> FU
    // =========================================================
    input  logic          [FU_NUM-1:0]        fu_rd_en,        // FU read enable per FU
    output issue_packet_t [FU_NUM-1:0]        fu_issue_pkt,  // output packets per FU
    output logic          [FU_NUM-1:0]        fu_fifo_empty    // per-FU empty flag
);

    // =========================================================
    // Instantiate FIFO
    //
    // FU #0 = ALU0
    // FU #1 = ALU1
    // FU #2 = ALU2
    // FU #3 = MUL
    // FU #4 = LOAD
    // FU #5 = BRANCH
    // =========================================================
    // -------------------- ALU1 FIFO --------------------
    FIFO #(
        .FIFO_DEPTH(FIFO_DEPTH),
        .ISSUE_WIDTH(ISSUE_WIDTH)
    ) alu0_fifo (
        .clock(clock),
        .reset(reset),
        .wr_en(fu_fifo_wr_en[0]),
        .issue_packet_i(fu_fifo_wr_pkt[0]),
        .free_slots_o(fu_free_slots[0]),
        .full_o(fu_fifo_full[0]),
        .rd_en(fu_rd_en[0]),
        .issue_packet_o(fu_issue_pkt[0]),
        .empty_o(fu_fifo_empty[0])
    );

    // -------------------- ALU2 FIFO --------------------
    FIFO #(
        .FIFO_DEPTH(FIFO_DEPTH),
        .ISSUE_WIDTH(ISSUE_WIDTH)
    ) alu1_fifo (
        .clock(clock),
        .reset(reset),
        .wr_en(fu_fifo_wr_en[1]),
        .issue_packet_i(fu_fifo_wr_pkt[1]),
        .free_slots_o(fu_free_slots[1]),
        .full_o(fu_fifo_full[1]),
        .rd_en(fu_rd_en[1]),
        .issue_packet_o(fu_issue_pkt[1]),
        .empty_o(fu_fifo_empty[1])
    );

    // --------------------ALU3 FIFO --------------------
    FIFO #(
        .FIFO_DEPTH(FIFO_DEPTH),
        .ISSUE_WIDTH(ISSUE_WIDTH)
    ) alu2_fifo (
        .clock(clock),
        .reset(reset),
        .wr_en(fu_fifo_wr_en[2]),
        .issue_packet_i(fu_fifo_wr_pkt[2]),
        .free_slots_o(fu_free_slots[2]),
        .full_o(fu_fifo_full[2]),
        .rd_en(fu_rd_en[2]),
        .issue_packet_o(fu_issue_pkt[2]),
        .empty_o(fu_fifo_empty[2])
    );

    // --------------------MLU FIFO --------------------
    FIFO #(
        .FIFO_DEPTH(FIFO_DEPTH),
        .ISSUE_WIDTH(ISSUE_WIDTH)
    ) mlu0_fifo (
        .clock(clock),
        .reset(reset),
        .wr_en(fu_fifo_wr_en[3]),
        .issue_packet_i(fu_fifo_wr_pkt[3]),
        .free_slots_o(fu_free_slots[3]),
        .full_o(fu_fifo_full[3]),
        .rd_en(fu_rd_en[3]),
        .issue_packet_o(fu_issue_pkt[3]),
        .empty_o(fu_fifo_empty[3])
    );

    // --------------------LOAD FIFO --------------------
    FIFO #(
        .FIFO_DEPTH(FIFO_DEPTH),
        .ISSUE_WIDTH(ISSUE_WIDTH)
    ) load0_fifo (
        .clock(clock),
        .reset(reset),
        .wr_en(fu_fifo_wr_en[4]),
        .issue_packet_i(fu_fifo_wr_pkt[4]),
        .free_slots_o(fu_free_slots[4]),
        .full_o(fu_fifo_full[4]),
        .rd_en(fu_rd_en[4]),
        .issue_packet_o(fu_issue_pkt[4]),
        .empty_o(fu_fifo_empty[4])
    );

    // --------------------BRANCH FIFO --------------------
    FIFO #(
        .FIFO_DEPTH(FIFO_DEPTH),
        .ISSUE_WIDTH(ISSUE_WIDTH)
    ) branch0_fifo (
        .clock(clock),
        .reset(reset),
        .wr_en(fu_fifo_wr_en[5]),
        .issue_packet_i(fu_fifo_wr_pkt[5]),
        .free_slots_o(fu_free_slots[5]),
        .full_o(fu_fifo_full[5]),
        .rd_en(fu_rd_en[5]),
        .issue_packet_o(fu_issue_pkt[5]),
        .empty_o(fu_fifo_empty[5])
    );

endmodule