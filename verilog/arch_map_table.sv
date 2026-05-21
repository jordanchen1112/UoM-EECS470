module arch_map_table #(
    parameter int ARCH_REGS = 64,
    parameter int PHYS_REGS = 128,
    parameter int COMMIT_WIDTH = 1
)(
    input  logic clock,
    input  logic reset,     
    // =======================================================
    // ========== Lookup Interface ===========================
    // =======================================================
    // Used to query the current architectural-to-physical register mapping
    // input  logic [$clog2(ARCH_REGS)-1:0] arch_reg_i,  // Architectural register index to lookup
    // output logic [$clog2(PHYS_REGS)-1:0] phys_reg_o,  // Mapped physical register output

    // =======================================================
    // ========== Commit Update Interface ====================
    // =======================================================
    // When instructions commit (retire), the architectural map table (AMT)
    // is updated to reflect the new committed architectural-to-physical mappings
    input  logic [COMMIT_WIDTH-1:0]                         commit_valid_i,  // One bit per commit slot; high = valid commit
    input  logic [COMMIT_WIDTH-1:0][$clog2(ARCH_REGS)-1:0]  commit_arch_i,   // Architectural register(s) being committed
    input  logic [COMMIT_WIDTH-1:0][$clog2(PHYS_REGS)-1:0]  commit_phys_i,   // Physical register(s) now representing committed state

    // =======================================================
    // ========== Snapshot / Restore Interface ===============
    // =======================================================
    // The AMT provides a snapshot of all current architectural mappings.
    // This is typically used when dispatching a branch (save current map),
    // or when a misprediction occurs (restore a previous snapshot).
    output logic [ARCH_REGS-1:0][$clog2(PHYS_REGS)-1:0] snapshot_o, // Full snapshot of current architectural-to-physical map
    input  logic restore_valid_i,  // Asserted when restoring the AMT from a saved snapshot
    input  logic [ARCH_REGS-1:0][$clog2(PHYS_REGS)-1:0] restore_snapshot_i // Snapshot data to restore from
);

   
    logic [ARCH_REGS-1:0][$clog2(PHYS_REGS)-1:0] table_reg;


    // =======================================================
    // Commit update
    // =======================================================
    always_ff @(posedge clock)begin
        if(reset)begin
            for(int i =0; i< ARCH_REGS; i++)begin
                    table_reg[i] <= i;
            end
        end else if (restore_valid_i)begin
            for(int i =0; i< ARCH_REGS; i++)begin
                table_reg[i] <= restore_snapshot_i[i];
            end
        end else begin
            for (int i =0 ; i< COMMIT_WIDTH ; i++)begin
                if(commit_valid_i[i]) table_reg[commit_arch_i[i]] <= commit_phys_i[i];
            end
        end
    end

    assign snapshot_o = table_reg;

endmodule