module disp_selector #(
    parameter int unsigned RS_DEPTH        = 64, //RS entry numbers
    parameter int unsigned DISPATCH_WIDTH  = 2
)(
    input  logic [RS_DEPTH-1:0]                     empty_vec,
    input  logic [DISPATCH_WIDTH-1:0]               disp_valid_vec, //from dispatch stage (which slot is going to dispatch)
    output logic [DISPATCH_WIDTH-1:0][RS_DEPTH-1:0] disp_grant_vec
);  
    logic [RS_DEPTH-1:0]                            internal_mask; // for multi-selection, mask the slot that has been choosen by previous one
    
    always_comb begin 
        disp_grant_vec = '0;
        internal_mask  = '0;

        // For each dispatch slot
        for (int i = 0; i<DISPATCH_WIDTH; i++) begin
            if (disp_valid_vec[i]) begin
                // Find the first empty entry not yet used
                for (int j=0; j<RS_DEPTH; j++) begin
                    if (empty_vec[j] && !internal_mask[j]) begin
                        disp_grant_vec[i][j] = 1'b1;
                        internal_mask [j] = 1'b1;
                        break;
                    end
                end
            end
        end
    end

    endmodule
