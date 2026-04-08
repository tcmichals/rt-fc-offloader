`default_nettype none
`timescale 1 ns / 1 ns

module wb_version #(
    parameter DATA_WIDTH = 32,
    parameter ADDR_WIDTH = 32
) (
    input  wire                    i_clk,
    input  wire                    i_rst,
    
    // Wishbone slave interface
    input  wire [ADDR_WIDTH-1:0]   wb_adr_i,
    input  wire [DATA_WIDTH-1:0]   wb_dat_i,
    output reg  [DATA_WIDTH-1:0]   wb_dat_o,
    input  wire                    wb_we_i,
    input  wire                    wb_stb_i,
    output reg                     wb_ack_o,
    input  wire                    wb_cyc_i
);

    always @(posedge i_clk or posedge i_rst) begin
        if (i_rst) begin
            wb_dat_o <= 32'h0;
            wb_ack_o <= 1'b0;
        end else begin
            // Pulse ACK for one cycle when accessed
            wb_ack_o <= wb_stb_i && wb_cyc_i && !wb_ack_o;
            
            if (wb_stb_i && wb_cyc_i) begin
                // Always return DEADBEEF regardless of address or write
                wb_dat_o <= 32'hDEADBEEF;
            end
        end
    end

endmodule
