/////////////////////////////////////////////////////////////////////////
//                                                                     //
//   Modulename :  dispatch_stage.sv                                   //
//                                                                     //
//  Description :  Decode -> Rename -> Dispatch (RS & ROB)             //
//                                                                     //
//                                                                     //
//                                                                     //
/////////////////////////////////////////////////////////////////////////


// =========================================================
// ????????? 
// [Fetch -> ROB -> RS] OR [Fetch -> ROB && RS]
// It seems like there was no datapath between ROB and RS in R10K? 
// =========================================================  


`include "def.svh"

module dispatch_stage #(
    parameter int unsigned FETCH_WIDTH = 1,
    parameter int unsigned DISPATCH_WIDTH = 1,
    parameter int unsigned PHYS_REGS = 128,
    parameter int unsigned ARCH_REGS = 64,
    parameter int unsigned DEPTH = 64,
    parameter int unsigned ADDR_WIDTH = 32

)(
    input   logic clock,          
    input   logic reset,         
    //input   logic disp_valid,       
    //input   logic disp_flush,      
    //input   logic disp_stall,   
    
    // =========================================================
    // Decode Instructions 
    // =========================================================  
    input  IF_ID_PACKET [FETCH_WIDTH-1:0] if_packet_i,     // get packet from Fetch Stage, FETCH_WIDTH > DISPATCH_WIDTH

    // =========================================================
    // (RENAME) Dispatch <-> Free List
    // =========================================================
    input  logic       [$clog2(DISPATCH_WIDTH+1)-1:0]   free_regs_i,   // how many regsiters in Free list? (saturate at DISPATCH_WIDTH)
    input  logic                                      free_full_i,       // Whether Free list is empty
    input  logic       [DISPATCH_WIDTH-1:0][$clog2(PHYS_REGS)-1:0] new_reg_i,

    output logic       [DISPATCH_WIDTH-1:0]           alloc_req_o,   // request sent to Free List (return new_reg_o)

    // =========================================================
    // (RENAME) Dispatch <-> Map Table
    // =========================================================
    input   logic      [DISPATCH_WIDTH-1:0]                           src1_ready_i,  // <-> rs1_valid_o in 'map_table.sv' 
    input   logic      [DISPATCH_WIDTH-1:0]                           src2_ready_i,
    input   logic      [DISPATCH_WIDTH-1:0][$clog2(PHYS_REGS)-1:0]    src1_phys_i,   //tag of reg 1
    input   logic      [DISPATCH_WIDTH-1:0][$clog2(PHYS_REGS)-1:0]    src2_phys_i,   //tag of reg 2
    input   logic      [DISPATCH_WIDTH-1:0][$clog2(PHYS_REGS)-1:0]    dest_reg_old_i,  //Told

    output  logic      [DISPATCH_WIDTH-1:0]                           rename_valid_o,
    output  logic      [DISPATCH_WIDTH-1:0][$clog2(ARCH_REGS)-1:0]    dest_arch_o,     //write reg   request
    output  logic      [DISPATCH_WIDTH-1:0][$clog2(ARCH_REGS)-1:0]    src1_arch_o,   //read  reg 1 request
    output  logic      [DISPATCH_WIDTH-1:0][$clog2(ARCH_REGS)-1:0]    src2_arch_o,   //read  reg 2 request
    output  logic      [DISPATCH_WIDTH-1:0][$clog2(PHYS_REGS)-1:0]   dest_new_prf, //

    output logic [DISPATCH_WIDTH-1:0] is_branch_o,  //### 11/10 sychenn ###//

    // =========================================================
    // Dispatch <-> RS
    // =========================================================
    input  logic       [$clog2(DISPATCH_WIDTH+1)-1:0]                   free_rs_slots_i,      // how many free slots in rs
    input  logic                                                      rs_full_i,   
    
    output logic       [DISPATCH_WIDTH-1:0]                           disp_rs_valid_o,
    output logic       [DISPATCH_WIDTH-1:0]                           disp_rs_rd_wen_o,       // read (I think it is whether write PRF?) //has_dest_reg?
    output rs_entry_t  [DISPATCH_WIDTH-1:0]                           rs_packets_o,           // packets sent to rs

    // =========================================================
    // Dispatch <-> ROB
    // =========================================================
    input  logic       [$clog2(DISPATCH_WIDTH+1)-1:0]                   free_rob_slots_i,   // how many free slots in rob 
    input  logic       [DISPATCH_WIDTH-1:0]                           disp_rob_ready_i,   //rob is ready // unused for now
    input  logic       [DISPATCH_WIDTH-1:0][$clog2(DEPTH)-1:0]        disp_rob_idx_i,     // rob id (sent to rs)

    output logic       [DISPATCH_WIDTH-1:0]                           disp_rob_valid_o,
    output logic       [DISPATCH_WIDTH-1:0]                           disp_rob_rd_wen_o, // read
    //output rob_entry_t [DISPATCH_WIDTH-1:0]                           rob_packets_o,     // packets sent to rob
    output  logic [DISPATCH_WIDTH-1:0][$clog2(ARCH_REGS)-1:0] disp_rd_arch_o,
    output  logic [DISPATCH_WIDTH-1:0][$clog2(PHYS_REGS)-1:0] disp_rd_new_prf_o,
    output  logic [DISPATCH_WIDTH-1:0][$clog2(PHYS_REGS)-1:0] disp_rd_old_prf_o,

    // =========================================================
    // (branch update) Dispatch → BTB 
    // =========================================================
    //Unknown
    //output  logic                          btb_update_valid_o,
    //output  logic      [ADDR_WIDTH-1:0]    btb_update_pc_o,
    //output  logic      [ADDR_WIDTH-1:0]    btb_update_target_o,
    input branch_stall, // from cpu 
    //packet
    output DISP_PACKET [DISPATCH_WIDTH-1:0] disp_packet_o,
    output logic stall,

    output logic [$clog2(DISPATCH_WIDTH+1)-1:0] disp_n,

    // Dispatch <-> LSQ
    output  logic     [DISPATCH_WIDTH-1:0]  dispatch_valid,
    output  logic      [DISPATCH_WIDTH-1:0] dispatch_is_store, // 1=Store, 0=Load
    output  MEM_SIZE   [DISPATCH_WIDTH-1:0] dispatch_size,
    output  ROB_IDX    [DISPATCH_WIDTH-1:0] disp_rob_idx_o,
    output  logic     [DISPATCH_WIDTH-1:0][2:0] disp_ld_funct3_o,
    input   logic   [$clog2(`LQ_SIZE+1)-1:0]    lq_count,         
    input   logic    [$clog2(`LQ_SIZE+1)-1:0]   st_count          

);

logic [DISPATCH_WIDTH-1:0] disp_has_dest;
logic [DISPATCH_WIDTH-1:0] disp_rd_wen_o;
logic [$clog2(DISPATCH_WIDTH+1)-1:0] total_valid_instr;
logic clear_valid_by_stall;

    //### 11/10 sychenn ###// (for map table restore)
    always_comb begin
        for (int i = 0; i < DISPATCH_WIDTH; i++) begin
          //### TODO: Fetch width need to be smaller then dispatch width ###//
            is_branch_o[i] = disp_packet_o[i].valid && (disp_packet_o[i].cond_branch || disp_packet_o[i].uncond_branch);
        end
    end

    always_ff @(posedge clock) begin
      if (!reset) begin
        clear_valid_by_stall <= 1;
        if (!stall) begin
          clear_valid_by_stall <= 0;
        end else if (stall) begin
          clear_valid_by_stall <= 1;
        end
      end
    end

    assign stall = (disp_n < `N);

    always_comb begin
      total_valid_instr = '0;
      for (int i = 0; i < DISPATCH_WIDTH; i++) begin
        if (if_packet_i[i].valid)
          total_valid_instr = total_valid_instr + 1;
      end
    end

    always_comb begin
        disp_n = DISPATCH_WIDTH;
        if (free_rs_slots_i < disp_n)  disp_n = free_rs_slots_i;
        if (free_rob_slots_i < disp_n) disp_n = free_rob_slots_i;
        if (free_regs_i < disp_n)      disp_n = free_regs_i;
        if (lq_count < disp_n)         disp_n = lq_count;
        if (st_count < disp_n)         disp_n = st_count;
        // $display("lq_count=%d st_count=%d", lq_count, st_count);
    end
// `ifndef SYNTHESIS
//     always_ff @(posedge clock) begin
//       if (!reset) begin
//         for (int i = 0; i < DISPATCH_WIDTH; i++) begin
//             $display("[%0t] DISPATCH: if_packet_i[%b] valid=%0d", $time, i, if_packet_i[i].valid);
//         end
//         $display("[%0t] DISPATCH: RS=%0d ROB=%0d REG=%0d  W=%0d  -> disp_n=%0d",
//                 $time,free_rs_slots_i, free_rob_slots_i, free_regs_i, DISPATCH_WIDTH, disp_n);
//       end
//     end
// `endif

    //pass packet
    always_comb begin
        for (int i=0; i< DISPATCH_WIDTH; i++)begin
            disp_packet_o[i].inst = if_packet_i[i].inst;
            disp_packet_o[i].PC = if_packet_i[i].PC;
            disp_packet_o[i].NPC = if_packet_i[i].NPC;
            disp_packet_o[i].valid = if_packet_i[i].valid;
            // disp_packet_o[i].valid = (clear_valid_by_stall ) ? '0 : if_packet_i[i].valid;
            disp_packet_o[i].dest_reg_idx = (disp_has_dest[i]) ? if_packet_i[i].inst.r.rd : `ZERO_REG;
            // `ifndef SYNTHESIS
            // $display("are your still work2?");
            // `endif
        end
    end

    // Instantiate the instruction decoder
    for (genvar i = 0; i < DISPATCH_WIDTH; i++) begin : gen_decoders
        decoder decoder (
            .inst  (if_packet_i[i].inst),
            .valid (if_packet_i[i].valid),

            .opa_select    (disp_packet_o[i].opa_select),
            .opb_select    (disp_packet_o[i].opb_select),
            .has_dest      (disp_has_dest[i]),
            .alu_func      (disp_packet_o[i].alu_func),
            .mult          (disp_packet_o[i].mult),
            .rd_mem        (disp_packet_o[i].rd_mem),
            .wr_mem        (disp_packet_o[i].wr_mem),
            .cond_branch   (disp_packet_o[i].cond_branch),
            .uncond_branch (disp_packet_o[i].uncond_branch),
            .csr_op        (disp_packet_o[i].csr_op),
            .halt          (disp_packet_o[i].halt),
            .illegal       (disp_packet_o[i].illegal),
            .fu_type       (disp_packet_o[i].fu_type)
        );
    end

    always_comb begin
      for (int i=0; i < DISPATCH_WIDTH; i++) begin
        disp_rd_wen_o[i] = (disp_has_dest[i]) && (if_packet_i[i].inst.r.rd != '0);
      end
    end

    assign disp_rob_rd_wen_o = disp_rd_wen_o;
    assign disp_rs_rd_wen_o = disp_rd_wen_o;


    //TODO exist latch
    always_comb begin
        disp_rs_valid_o = '0;
        rs_packets_o = '0;
        disp_rob_valid_o = '0;
        rename_valid_o = '0;
        alloc_req_o = '0;
        dest_new_prf = '0;
        disp_rd_arch_o = '0;
        disp_rd_new_prf_o = '0;
        disp_rd_old_prf_o = '0;
        src1_arch_o = '0;
        src2_arch_o = '0;
        dest_arch_o = '0;

        dispatch_valid = '0;
        dispatch_is_store = '0;
        dispatch_size = '0;
        disp_rob_idx_o = '0;
        disp_ld_funct3_o = '0;
        if (!branch_stall && !stall) begin
          for (int i = 0; i < DISPATCH_WIDTH; i++) begin
              if (if_packet_i[i].valid) begin //### Account for icache miss (valid = 0)
                // Dispatch -> Map Table
                src1_arch_o[i] = if_packet_i[i].inst.r.rs1;
                src2_arch_o[i]= if_packet_i[i].inst.r.rs2;
                dest_arch_o[i] = disp_packet_o[i].dest_reg_idx;  // from decoder
                rename_valid_o[i] = if_packet_i[i].valid & disp_rd_wen_o[i] & (i < disp_n); // only if instruction is valid
                alloc_req_o[i] = if_packet_i[i].valid & disp_rd_wen_o[i] & (i < disp_n);

                // To RS
                if(i < disp_n) begin
                    disp_rs_valid_o[i] = 1; //### 11/21

                    //rs_entry
                    rs_packets_o[i].valid = 1;
                    //###11/10
                    rs_packets_o[i].fu_type = (disp_packet_o[i].mult) ? 2'b01 : (disp_packet_o[i].rd_mem | disp_packet_o[i].wr_mem) ? 2'b10 : (disp_packet_o[i].cond_branch|disp_packet_o[i].uncond_branch) ? 2'b11 : 2'b00;
                    rs_packets_o[i].rob_idx = disp_rob_idx_i[i];

                    rs_packets_o[i].dest_arch_reg = disp_packet_o[i].dest_reg_idx;

                    rs_packets_o[i].dest_tag = new_reg_i[i];//from free list

                    rs_packets_o[i].src1_tag = src1_phys_i[i];  // physical tag for rs1
                    rs_packets_o[i].src2_tag = src2_phys_i[i];  // physical tag for rs2
                    rs_packets_o[i].src1_ready = src1_ready_i[i]; // whether rs1 is ready (+)
                    rs_packets_o[i].src2_ready = src2_ready_i[i]; // If is IMM ALWAYS READY

                    // rs_packets_o[i].src2_ready = (disp_packet_o[i].opb_select == 3'h0 && !disp_packet_o[i].wr_mem) ? src2_ready_i[i] : 1; // If is IMM ALWAYS READY
                    rs_packets_o[i].disp_packet = disp_packet_o[i];

                    // To ROB
                    disp_rob_valid_o[i] = 1;
                    disp_rd_arch_o[i] = disp_packet_o[i].dest_reg_idx;
                    disp_rd_old_prf_o[i] = dest_reg_old_i[i]; // Told
                    disp_rd_new_prf_o[i] = new_reg_i[i];  //from free list

                    // To map table
                    dest_new_prf[i] = new_reg_i[i];

                    // To LSQ
                    if (disp_packet_o[i].valid && (disp_packet_o[i].rd_mem || disp_packet_o[i].wr_mem)) begin
                      dispatch_valid[i] = 1;
                      dispatch_is_store[i] = disp_packet_o[i].wr_mem; // store = 1
                      dispatch_size[i] = MEM_SIZE'(if_packet_i[i].inst.r.funct3[1:0]);
                      disp_rob_idx_o[i] = disp_rob_idx_i[i];
                      disp_ld_funct3_o[i] = if_packet_i[i].inst.i.funct3;
                    end else begin
                      dispatch_valid[i] = 0;
                      dispatch_is_store[i] = disp_packet_o[i].wr_mem; // store = 1
                      dispatch_size[i] =  MEM_SIZE'(if_packet_i[i].inst.r.funct3[1:0]);
                      disp_rob_idx_o[i] = disp_rob_idx_i[i];
                    end
                    
                end 
              end
          end
        end 
      end

/*
  // =========================================================
  // DEBUG
  // =========================================================
  integer cycle_count;
  always_ff @(posedge clock) begin
    if (reset)
      cycle_count <= 0;
    else
      cycle_count <= cycle_count + 1;

    for (int i = 0; i < DISPATCH_WIDTH; i++) begin
      if (disp_rs_valid_o[i]) begin
        $display("[Cycle=%0d] Dispatch %0d | ROB_idx=%0d | Dest=%0d | Src1=%0d (%b) | Src2=%0d (%b)",
                 cycle_count, i,
                 rs_packets_o[i].rob_idx,
                 rs_packets_o[i].dest_tag,
                 rs_packets_o[i].src1_tag, rs_packets_o[i].src1_ready,
                 rs_packets_o[i].src2_tag, rs_packets_o[i].src2_ready);
      end
    end
  end
*/

//   // =========================================================
//   // DEBUG
//   // =========================================================
//   `ifndef SYNTHESIS
//   integer cycle_count;
//   always_ff @(posedge clock) begin
//     if (reset)
//       cycle_count <= 0;
//     else
//       cycle_count <= cycle_count + 1;

//     for (int i = 0; i < DISPATCH_WIDTH; i++) begin
//       $display("disp_rs_valid_o=%b | rs_packets_o valid=%b", disp_rs_valid_o[0], rs_packets_o[0].valid);
//       if (disp_rs_valid_o[i]) begin
//         $display("Dispatch %0d | ROB_idx=%0d | Dest=%0d | Src1=%0d (%b) | Src2=%0d (%b)",
//                  i,
//                  rs_packets_o[i].rob_idx,
//                  rs_packets_o[i].dest_tag,
//                  rs_packets_o[i].src1_tag, rs_packets_o[i].src1_ready,
//                  rs_packets_o[i].src2_tag, rs_packets_o[i].src2_ready);
//       end
//     end
//   end
// `endif

endmodule


