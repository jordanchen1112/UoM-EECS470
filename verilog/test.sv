// always_ff @(posedge clock) begin
//         if (reset) begin
//             // ... reset logic ...
//             for(int i =0; i< ARCH_REGS; i++) begin
//                 table_reg[i].phys <= i;
//                 table_reg[i].valid <= 1'b1;
//             end
//         end else begin
//             // -------------------------------------------------------
//             // 1. Snapshot Restore
//             // -------------------------------------------------------
//             // If valid, we restore the whole table. 
//             // If NOT valid, we simply skip this and move to dispatch.
//             if (snapshot_restore_valid_i) begin
//                 for(int i =0 ; i < ARCH_REGS ; i++) begin
//                     table_reg[i].phys <= snapshot_data_i[i].phys;
//                     table_reg[i].valid <= (snapshot_data_i[i].valid || 
//                                           ((snapshot_data_i[i].phys == table_reg[i].phys) && table_reg[i].valid));
//                 end
//             end 

//             // -------------------------------------------------------
//             // 2. Dispatch Rename (ALWAYS CHECKED)
//             // -------------------------------------------------------
//             // We removed the 'else'. This loop runs every cycle (if not reset).
//             // - If Restore was LOW: logic behaves normally.
//             // - If Restore was HIGH: this runs AFTER restore, allowing 'jalr' 
//             //   to overwrite the link register (dest) with the new tag.
//             for(int i =0 ; i < DISPATCH_WIDTH ; i++) begin
//                 if(disp_valid_i[i]) begin
//                     if (disp_arch_i[i] != `ZERO_REG) begin
//                         table_reg[disp_arch_i[i]].phys <= disp_new_phys_i[i];
//                         table_reg[disp_arch_i[i]].valid <= 1'b0; 
//                     end
//                 end
//             end
//         end
        
//         // -------------------------------------------------------
//         // 3. Writeback (Completes the cycle)
//         // -------------------------------------------------------
//         // ... (Existing WB logic) ...
//     end



//     unique case (Dcache_size_0)
//                 BYTE:    Dcache_data_out_0.byte_level[0] = line_data_0.byte_level[offset_0];
//                 HALF:    Dcache_data_out_0.half_level[0] = line_data_0.half_level[offset_0[OFFSET_BITS-1:1]];
//                 WORD:    Dcache_data_out_0.word_level[0] = line_data_0.word_level[offset_0[OFFSET_BITS-1:2]];
//                 DOUBLE:  Dcache_data_out_0.dbbl_level = line_data_0.dbbl_level;
//                 default: Dcache_data_out_0.dbbl_level = line_data_0.dbbl_level;
//             endcase

