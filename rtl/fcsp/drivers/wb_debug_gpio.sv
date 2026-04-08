/**
 * Wishbone Debug GPIO Controller
 * 
 * 3-bit digital output for fast debugging with logic analyzer/scope.
 * Replaces slow Debug UART - direct pin control with minimal latency.
 *
 * Address map (word-aligned):
 *   0x00: GPIO output register (RW) - bits[2:0] = o_debug[2:0]
 *   0x04: GPIO set register (WO) - write 1s to set corresponding bits
 *   0x08: GPIO clear register (WO) - write 1s to clear corresponding bits
 *   0x0C: GPIO toggle register (WO) - write 1s to toggle corresponding bits
 */
`default_nettype none

module wb_debug_gpio #(
    parameter GPIO_WIDTH = 3
)(
    input  wire        clk,
    input  wire        rst,
    
    // Wishbone slave interface
    input  wire [31:0] wb_adr_i,
    input  wire [31:0] wb_dat_i,
    output reg  [31:0] wb_dat_o,
    input  wire        wb_we_i,
    input  wire        wb_stb_i,
    input  wire        wb_cyc_i,
    output reg         wb_ack_o,
    
    // GPIO outputs
    output wire [GPIO_WIDTH-1:0] gpio_out
);

    // Register offsets (word-aligned, use bits[3:2])
    localparam ADDR_OUT    = 2'h0;  // 0x00
    localparam ADDR_SET    = 2'h1;  // 0x04
    localparam ADDR_CLR    = 2'h2;  // 0x08
    localparam ADDR_TGL    = 2'h3;  // 0x0C

    reg [GPIO_WIDTH-1:0] gpio_reg;

    always @(posedge clk) begin
        if (rst) begin
            wb_ack_o <= 1'b0;
            wb_dat_o <= 32'h0;
            gpio_reg <= {GPIO_WIDTH{1'b0}};
        end else begin
            // Single-cycle ACK
            wb_ack_o <= wb_stb_i && wb_cyc_i && !wb_ack_o;

            if (wb_stb_i && wb_cyc_i && !wb_ack_o) begin
                if (wb_we_i) begin
                    // Write operations
                    case (wb_adr_i[3:2])
                        ADDR_OUT: gpio_reg <= wb_dat_i[GPIO_WIDTH-1:0];
                        ADDR_SET: gpio_reg <= gpio_reg | wb_dat_i[GPIO_WIDTH-1:0];
                        ADDR_CLR: gpio_reg <= gpio_reg & ~wb_dat_i[GPIO_WIDTH-1:0];
                        ADDR_TGL: gpio_reg <= gpio_reg ^ wb_dat_i[GPIO_WIDTH-1:0];
                        default: ;
                    endcase
                end else begin
                    // Read - always return current GPIO value
                    wb_dat_o <= {{(32-GPIO_WIDTH){1'b0}}, gpio_reg};
                end
            end
        end
    end

    assign gpio_out = gpio_reg;

endmodule

`default_nettype wire
