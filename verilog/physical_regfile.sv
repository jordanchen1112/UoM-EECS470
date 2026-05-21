module pr #(
    parameter int unsigned PHYS_REGS = 128,
    parameter int unsigned XLEN      = 32,
    parameter int unsigned READ_PORTS = 8,
    parameter int unsigned WRITE_PORTS = 4,
    parameter bit          BYPASS_EN    = 1
)(
    input logic clock,
    input logic reset,
    //---------------- read ports (from issue stage / rename) ----------------
    input  logic [READ_PORTS-1:0]rd_en, 
    input  logic [READ_PORTS-1:0][$clog2(PHYS_REGS)-1:0] raddr,
    output logic [READ_PORTS-1:0][XLEN-1:0]          rdata_o,
    //---------------- write ports ----------------
    input  logic [WRITE_PORTS-1:0] wr_en, 
    input  logic [WRITE_PORTS-1:0][$clog2(PHYS_REGS)-1:0] waddr,
    input  logic [WRITE_PORTS-1:0][XLEN-1:0]          wdata
);

    logic [PHYS_REGS-1:0][XLEN-1:0] regfile;
    
/*
    always @(negedge clock) begin
    if (!reset) begin
        $display("====================================================");
        $display("[PR DEBUG @ %0t]", $time);

        // Write ports
        for (int i = 0; i < WRITE_PORTS; i++) begin
            if (wr_en[i])
                $display("WRITE[%0d]: addr=%0d data=0x%0h", i, waddr[i], wdata[i]);
        end

        // Read ports
        for (int i = 0; i < READ_PORTS; i++) begin
            if (rd_en[i])
                $display("READ[%0d]: addr=%0d data=0x%0h", i, raddr[i], rdata_o[i]);
        end

        // Optional: key registers
        //$display("REGS[0]=0x%0h [1]=0x%0h [2]=0x%0h [3]=0x%0h [65]=0x%0h",
            //     regfile[0], regfile[1], regfile[2], regfile[3], regfile[65]);

        $display("====================================================\n");
    end
end
*/

    always_ff @(posedge clock) begin
        if (reset) begin
            regfile <= '0;
        end else begin
            for (int w = 0; w < WRITE_PORTS; w++) begin
                if (wr_en[w] && waddr[w]!=0)
                    regfile[waddr[w]] <= wdata[w];
            end
        end
    end

    always_comb begin
        for (int r = 0; r < READ_PORTS; r++) begin
            rdata_o[r] = regfile[raddr[r]];
            if (BYPASS_EN) begin
                for (int w = 0; w < WRITE_PORTS; w++) begin
                    if (wr_en[w] && waddr[w]!= 0 && (waddr[w] == raddr[r]) )
                        rdata_o[r] = wdata[w];
                end
            end
        end
    end

endmodule