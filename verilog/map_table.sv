// ============================================================================
//  Module: map_table
//  Description:
//    Register Alias Table (RAT) for out-of-order CPU pipeline.
//    Performs architectural-to-physical register mapping, rename tracking,
//    and status management (valid bits, snapshot/rollback, etc.).
//
//  Typical connections:
//    - Connected to the Reorder Buffer (ROB) for commit updates and rollbacks.
//    - Connected to the Reservation Station (RS) for operand lookup.
//    - Connected to the Free List for allocating new physical registers.
//    - Connected to the Execution Units for writeback readiness tracking.
// ============================================================================

module map_table#(
    parameter int ARCH_REGS = 64,           // Number of architectural registers
    parameter int PHYS_REGS = 128,          // Number of physical registers
    parameter int DISPATCH_WIDTH = 1,       // Number of instructions dispatched per cycle
    parameter int WB_WIDTH     = 4,         // Number of writeback ports
    parameter int COMMIT_WIDTH = 1          // Number of commit ports
)(
    input logic clock,                        // Clock signal
    input logic reset,                      // Asynchronous reset

    // =======================================================
    // ======== Lookup (for rs1, rs2) ==========================
    // =======================================================
    // Query the current mapping of source registers (rs1, rs2)
    // for each instruction being dispatched.
    //
    // Input:
    //   rs1_arch_i / rs2_arch_i : architectural source register indices
    // Output:
    //   rs1_phys_o / rs2_phys_o : mapped physical registers (tags)
    //   rs1_valid_o / rs2_valid_o : indicate if the physical register value is ready
    //
    input  logic [DISPATCH_WIDTH-1:0][$clog2(ARCH_REGS)-1:0] rs1_arch_i,
    input  logic [DISPATCH_WIDTH-1:0][$clog2(ARCH_REGS)-1:0] rs2_arch_i,
    output logic [DISPATCH_WIDTH-1:0][$clog2(PHYS_REGS)-1:0] rs1_phys_o,
    output logic [DISPATCH_WIDTH-1:0][$clog2(PHYS_REGS)-1:0] rs2_phys_o,
    output logic                        [DISPATCH_WIDTH-1:0] rs1_valid_o,
    output logic                        [DISPATCH_WIDTH-1:0] rs2_valid_o,

    // =======================================================
    // ======== Dispatch: rename new destination reg =========
    // =======================================================
    // When new instructions are dispatched, they are assigned new
    // physical registers for their destination registers.
    //
    // Input:
    //   disp_valid_i     : per-instruction dispatch enable
    //   disp_arch_i      : architectural destination register
    //   disp_new_phys_i  : newly allocated physical register
    //
    input  logic [DISPATCH_WIDTH-1:0]                        disp_valid_i,
    input  logic [DISPATCH_WIDTH-1:0][$clog2(ARCH_REGS)-1:0] disp_arch_i,
    input  logic [DISPATCH_WIDTH-1:0][$clog2(PHYS_REGS)-1:0] disp_new_phys_i,
    output logic [DISPATCH_WIDTH-1:0][$clog2(PHYS_REGS)-1:0] disp_old_phys_o,

    // =======================================================
    // ======== Writeback: mark phys reg ready ===============
    // =======================================================
    // When instructions finish execution, their destination physical
    // registers are marked as ready (value valid).
    //
    // Input:
    //   wb_valid_i : one bit per writeback slot (asserted when result is valid)
    //   wb_phys_i  : physical register written back by the corresponding instruction
    //
    input  logic [WB_WIDTH-1:0]                                          wb_valid_i,
    input  logic [WB_WIDTH-1:0][$clog2(PHYS_REGS)-1:0]                   wb_phys_i,

    // =======================================================
    // ======== Commit: restore mapping (rollback) ===========
    // =======================================================
    // At commit, the architectural map is updated with the committed
    // physical registers (synchronized with the architectural state).
    //
    // Input:
    //   commit_valid_i : indicates valid commit slot
    //   commit_arch_i  : architectural register being committed
    //   commit_phys_i  : physical register representing committed value
    //
    // input  logic [COMMIT_WIDTH-1:0]                         commit_valid_i,
    // input  logic [COMMIT_WIDTH-1:0][$clog2(ARCH_REGS)-1:0]  commit_arch_i,
    // input  logic [COMMIT_WIDTH-1:0][$clog2(PHYS_REGS)-1:0]  commit_phys_i,

    // =======================================================
    // ======== Snapshot / Flush control =====================
    // =======================================================
    // Snapshot: Save current mapping for branch dispatch.
    // Restore: Reload previous mapping on branch misprediction or exception.
    // Flush:   Reset mappings on full pipeline flush.
    //
    // Input:
    //   flush_i             : flush the pipeline and reset table
    //   snapshot_restore_i  : restore table from saved snapshot
    //   snapshot_data_i     : snapshot data (arch_reg → phys_reg mapping)
    //
    // Output:
    //   snapshot_data_o     : current table snapshot for saving
    //
    input logic branch_stall_i,
    input logic [DISPATCH_WIDTH-1:0] is_branch_i,  //### 11/10 sychenn ###//

    input  logic                                              snapshot_restore_valid_i, //valid bit
    input  map_entry_t      snapshot_data_i [ARCH_REGS-1:0],
    
    output map_entry_t       snapshot_data_o [ARCH_REGS-1:0],
    output logic snapshot_valid_o, //### 11/10 sychenn ###//

    // input logic is_jtpe
    
    //stall
    input logic stall_i
);

    // =======================================================
    // ======== Internal State ===============================
    // =======================================================
    // Each architectural register maps to a physical register entry,
    // along with a valid bit indicating whether the physical value is ready.
    //

    // Full mapping table (Architectural Register → Physical Register)
    map_entry_t table_reg [ARCH_REGS-1:0];
    map_entry_t table_reg_next[ARCH_REGS-1:0]; // 

    //### 11/10 sychenn ###//
    always_comb begin 
        snapshot_valid_o = 1'b0;
        if (!branch_stall_i)begin
            for(int i =0 ; i < DISPATCH_WIDTH ; i++)begin
                if(is_branch_i[i] && !stall_i)begin
                    snapshot_valid_o = 1'b1;
                    break;
                end 
            end        
        end
    end

    //### 11/15  sychenn ####################################################################//
    //### The problem is that dispatch instruction read reg at the same cycle with writeback 
    //### (need to get the valid tag at the same cycle, orignally has 1 cycle latency)
    //#######################################################################################//
    logic [ARCH_REGS-1:0] wb_forward_valid;
    logic j_type_wb;
    always_comb begin 
        wb_forward_valid = '0;
        j_type_wb = '0;
        for (int i = 0 ; i < WB_WIDTH; i ++)begin
            if(wb_valid_i[i])begin
                for(int j = 0 ; j < ARCH_REGS ; j++)begin
                    if(table_reg[j].phys == wb_phys_i[i])begin
                        wb_forward_valid[j] = 1'b1;
                        // j_type_wb = 1'b1;
                    end
                end
            end
        end       
    end
    // =======================================================
    // Reset / Init: on reset, create identity mapping:
    // arch reg i -> phys i, and mark valid = 1
    // (this assumes PHYS_REGS >= ARCH_REGS)
    // =======================================================
    always_ff @(posedge clock)begin
        if(reset)begin
            for(int i =0; i< ARCH_REGS; i++)begin
                table_reg[i].phys <= i;
                table_reg[i].valid <= 1'b1;

            end

        end else begin
            table_reg <= table_reg_next;
            // // ===================================================
            // //    Dispatch rename (speculative): for each dispatch slot,
            // //    install new mapping and mark value as NOT ready (valid=0).
            // // ===================================================
            // if (snapshot_restore_valid_i) begin
            //     for(int i =0 ; i < ARCH_REGS ; i++)begin
            //         table_reg[i].phys <= snapshot_data_i[i].phys;
            //         table_reg[i].valid <= (snapshot_data_i[i].valid || ((snapshot_data_i[i].phys == table_reg[i].phys) && table_reg[i].valid));
            //     end
                
            //     // if(j_type_wb)begin
            //     //     for (int i = 0 ; i < WB_WIDTH; i ++)begin
            //     //         if(wb_valid_i[i])begin
            //     //             // table_reg[wb_phys_i[i]].valid <= 1'b1;
            //     //             for(int j = 0 ; j < ARCH_REGS ; j++)begin
            //     //                 //###11/15 sychenn prevent wb and dispatch write to the same reg at the same cycle###//
            //     //                 for(int k =0 ; k < DISPATCH_WIDTH ; k++)begin
            //     //                     if ((table_reg[j].phys == wb_phys_i[i]) && (disp_arch_i[k] != j))begin 
            //     //                         table_reg[j].valid <= 1'b1;
            //     //                     end
            //     //                 end
            //     //             end
            //     //         end
            //     //     end
            //     // end
            // end 
            // for(int i =0 ; i < DISPATCH_WIDTH ; i++)begin
            //     if(disp_valid_i[i])begin
            //         //### 11/21 r0 should always be zero ###//
            //         if (disp_arch_i[i] == `ZERO_REG) begin
            //             $display("disp_arch_i = %d is zero reg", disp_arch_i[i]);
            //         end else begin
            //             $display("disp_arch_i = %d | old_phys = %d | disp_old_phys_o = %d ", disp_arch_i[i],table_reg[disp_arch_i[i]].phys,disp_old_phys_o[i] );
            //             table_reg[disp_arch_i[i]].phys <= disp_new_phys_i[i];
            //             table_reg[disp_arch_i[i]].valid <= 1'b0; 
            //         end
            //     end
            // end
            

//             // ===================================================
//             //    Dispatch rename (speculative): for each dispatch slot,
//             //    install new mapping and mark value as NOT ready (valid=0).
//             // ===================================================
//             if (snapshot_restore_valid_i) begin
//                 for(int i =0 ; i < ARCH_REGS ; i++)begin
//                     table_reg[i].phys <= snapshot_data_i[i].phys;
//                     table_reg[i].valid <= (snapshot_data_i[i].valid || ((snapshot_data_i[i].phys == table_reg[i].phys) && table_reg[i].valid));
//                 end
//             end else begin
//                 for(int i =0 ; i < DISPATCH_WIDTH ; i++)begin
//                     if(disp_valid_i[i])begin
//                         //### 11/21 r0 should always be zero ###//
//                         if (disp_arch_i[i] == `ZERO_REG) begin
//                             `ifndef SYNTHESIS
//                             $display("disp_arch_i = %d is zero reg", disp_arch_i[i]);
//                             `endif
//                         end else begin
//                             `ifndef SYNTHESIS
//                             $display("disp_arch_i = %d | old_phys = %d | disp_old_phys_o = %d ", disp_arch_i[i],table_reg[disp_arch_i[i]].phys,disp_old_phys_o[i] );
//                             `endif
//                             table_reg[disp_arch_i[i]].phys <= disp_new_phys_i[i];
//                             table_reg[disp_arch_i[i]].valid <= 1'b0; 
//                         end
//                     end
//                 end
//             end
// >>>>>>> origin/fix_wfi_afterworld
        end

        // ===================================================
        //  Writeback(aka complete stage): any WB that writes a physical tag should mark 
        //  every architectural mapping that references that physical tag as valid.
        // ===================================================
        // for (int i = 0 ; i < WB_WIDTH; i ++)begin
        //     if(wb_valid_i[i])begin
        //         // table_reg[wb_phys_i[i]].valid <= 1'b1;
        //         for(int j = 0 ; j < ARCH_REGS ; j++)begin
        //             //###11/15 sychenn prevent wb and dispatch write to the same reg at the same cycle###//
        //             for(int k =0 ; k < DISPATCH_WIDTH ; k++)begin
        //                 if ((table_reg[j].phys == wb_phys_i[i]) && (disp_arch_i[k] != j))begin 
        //                     table_reg[j].valid <= 1'b1;
        //                 end
        //             end
        //         end
        //     end
        // end

        // ===================================================
        // Snapshot restore takes highest priority:
        // If restore asserted, overwrite the table with the provided snapshot.
        // We also mark valid = 1 for restored (AMT state is committed).
        // ===================================================

        // if(snapshot_restore_valid_i) begin
        //     for(int i =0; i < ARCH_REGS ; i++)begin
        //         table_reg[i].phys <= snapshot_data_i[i];
        //         table_reg[i].valid <= 1'b1;
        //     end
        // end

        // // ===================================================
        // // 4) Optional flush: if flush asserted, reset to identity mapping.
        // //    Depending on your microarchitecture you might instead restore from AMT.
        // // ===================================================
        // if(flush_i)begin
        //     for(int i =0 ; i<ARCH_REGS ; i++)begin
        //         table_reg[i].phys <= i;
        //         table_reg[i].valid <= 1'b1;
        //     end
        // end
    end


    // =======================================================
    // Combinational read outputs: lookup for each dispatch slot
    // =======================================================
    // Forwarding logic to handle same-cycle writeback and dispatch


    // Provide mapped phys tag and ready bit for each rs1/rs2 of every dispatch slot
    generate 
        for(genvar i =0 ; i < DISPATCH_WIDTH ; i++)begin
            always_comb begin
                //rs1 outputs
                rs1_phys_o[i] = table_reg[rs1_arch_i[i]].phys;                    
                rs1_valid_o[i] = table_reg[rs1_arch_i[i]].valid | wb_forward_valid[rs1_arch_i[i]]; //###11/15    sychenn ###//                     
                //rs2 outputs
                rs2_phys_o[i] = table_reg[rs2_arch_i[i]].phys;                    
                rs2_valid_o[i] = table_reg[rs2_arch_i[i]].valid | wb_forward_valid[rs2_arch_i[i]]; //###11/15    sychenn ###//      
                // old prf
                if (snapshot_restore_valid_i)begin
                    disp_old_phys_o[i] = snapshot_data_i[disp_arch_i[i]].phys; //### 11/15 ###//   
                end else begin
                    disp_old_phys_o[i] = table_reg[disp_arch_i[i]].phys;
                end 
                // ###TODO only for two ways  
            end                    
        end
    endgenerate
// `ifndef SYNTHESIS
//     always_ff @(posedge clock) begin
//         if (!reset) begin
//             $display("MAP_TABLE: snapshot_restore_i=%b | is_branch_i=%b ",snapshot_restore_valid_i,is_branch_i);
//             for (int i = 0 ; i < ARCH_REGS ; i++)begin
//                 $display("table_reg[%0d] value = %d (%d)| snapshot_data_o[%0d] value = %d (%d)| snapshot_data_i[%0d] value = %d (%d)", i, table_reg[i].phys,table_reg[i].valid, i, snapshot_data_o[i].phys,snapshot_data_o[i].valid, i, snapshot_data_i[i].phys,snapshot_data_i[i].valid);
//             end
//         end
//     end
// `endif
    // =======================================================
    // Snapshot output: provide current mapping (for ROB/CPU to save)
    // Drive it continuously from table_reg; CPU will latch on checkpoint_valid_o
    // =======================================================


    always_comb begin
        for(int i =0 ; i< ARCH_REGS ; i++)begin
            snapshot_data_o[i].phys  = table_reg[i].phys;
            snapshot_data_o[i].valid = table_reg[i].valid;
        end

        if(disp_valid_i[0])begin
            snapshot_data_o[disp_arch_i[0]].phys = disp_new_phys_i[0];
            snapshot_data_o[disp_arch_i[0]].valid = 1'b0;
        end

        for (int i = 0 ; i < WB_WIDTH; i ++)begin
            if(wb_valid_i[i])begin
                for(int j = 0 ; j < ARCH_REGS ; j++)begin
                    for(int k =0 ; k < DISPATCH_WIDTH ; k++)begin
                        if ((table_reg[j].phys == wb_phys_i[i]) && (disp_arch_i[k] != j))begin 
                            snapshot_data_o[j].valid = 1'b1;
                        end
                    end
                end
            end
        end


        table_reg_next = table_reg;
        if (snapshot_restore_valid_i) begin
            for(int i =0 ; i < ARCH_REGS ; i++)begin
                logic wb_match;
                wb_match = 1'b0;
                // Check if any writeback this cycle matches the snapshot's physical register
                for(int w = 0; w < WB_WIDTH; w++)begin
                    if(wb_valid_i[w] && (wb_phys_i[w] == snapshot_data_i[i].phys))begin
                        wb_match = 1'b1;
                    end
                end
                table_reg_next[i].phys = snapshot_data_i[i].phys;
                table_reg_next[i].valid = (snapshot_data_i[i].valid || 
                                          ((snapshot_data_i[i].phys == table_reg[i].phys) && table_reg[i].valid) ||
                                          wb_match);
            end

        end else begin
            for(int i =0 ; i < DISPATCH_WIDTH ; i++)begin
                if(disp_valid_i[i])begin
                    //### 11/21 r0 should always be zero ###//
                    if (disp_arch_i[i] == `ZERO_REG) begin
                        // `ifndef SYNTHESIS
                        // $display("disp_arch_i = %d is zero reg", disp_arch_i[i]);
                        // `endif
                    end else begin
                        // `ifndef SYNTHESIS
                        // $display("disp_arch_i = %d | old_phys = %d | disp_old_phys_o = %d ", disp_arch_i[i],table_reg[disp_arch_i[i]].phys,disp_old_phys_o[i] );
                        // `endif
                        table_reg_next[disp_arch_i[i]].phys = disp_new_phys_i[i];
                        table_reg_next[disp_arch_i[i]].valid = 1'b0; 
                    end
                end
            end    
        end
    

        // ===================================================
        //  Writeback(aka complete stage): any WB that writes a physical tag should mark 
        //  every architectural mapping that references that physical tag as valid.
        // ===================================================
        
        for (int i = 0 ; i < WB_WIDTH; i ++)begin
            if(wb_valid_i[i])begin
                for(int j = 0 ; j < ARCH_REGS ; j++)begin
                    for(int k = 0 ; k < DISPATCH_WIDTH ; k++)begin
                        if ((table_reg_next[j].phys == wb_phys_i[i]) && (disp_arch_i[k] != j))begin 
                            table_reg_next[j].valid = 1'b1;
                        end
                    end
                end
            end
        end
    end

    // generate
    //     for(genvar i = 0; i < ARCH_REGS; i++) begin
    //         assign snapshot_data_o[i].phys  = table_reg[i].phys;
    //         assign snapshot_data_o[i].valid = table_reg[i].valid;
    //     end
    // endgenerate


    // always_ff @(negedge clock) begin
    //     // for(int i = 0 ; )
    //     $display("table_reg[1],valid = %0b, table_reg[1].value  = %d \n", table_reg[1].valid, table_reg[1].phys);
    // end

endmodule