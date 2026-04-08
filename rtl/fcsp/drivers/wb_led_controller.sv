/**
 * Wishbone LED Controller
 * 
 * Simple LED register interface via Wishbone bus
 * Address map:
 *   0x00: LED output register (RW) - bits [3:0] control LEDs 0-3
 *   0x04: LED mode register (RW)   - bits [3:0] select mode (0=manual, 1=blink, etc.)
 */

module wb_led_controller #(
    parameter DATA_WIDTH = 32,
    parameter ADDR_WIDTH = 32,
    parameter SELECT_WIDTH = (DATA_WIDTH/8),
    parameter LED_WIDTH = 4,
    parameter LED_POLARITY = 0 // 0: Active Low, 1: Active High
) (
    input  wire                    clk,
    input  wire                    rst,
    
    // Wishbone slave interface
    input  wire [ADDR_WIDTH-1:0]   wbs_adr_i,
    input  wire [DATA_WIDTH-1:0]   wbs_dat_i,
    output reg  [DATA_WIDTH-1:0]   wbs_dat_o,
    input  wire                    wbs_we_i,
    input  wire [SELECT_WIDTH-1:0] wbs_sel_i,
    input  wire                    wbs_stb_i,
    output reg                     wbs_ack_o,
    output wire                    wbs_err_o,
    output wire                    wbs_rty_o,
    input  wire                    wbs_cyc_i,
    
    // LED outputs
    output wire [LED_WIDTH-1:0]    led_out

);

    localparam ADDR_LED_OUT     = 2'h0;
    localparam ADDR_LED_TOGGLE  = 2'h1;
    localparam ADDR_LED_CLEAR   = 2'h2;
    localparam ADDR_LED_SET     = 2'h3;
    
    // Wishbone protocol
    assign wbs_err_o = 1'b0;
    assign wbs_rty_o = 1'b0;
    
    reg [LED_WIDTH-1:0] led_out_reg;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            wbs_ack_o <= 1'b0;
            wbs_dat_o <= 32'h0;
            led_out_reg <= {LED_WIDTH{1'b0}};
        end else begin
            // Simple ACK: pulse for one cycle (matches wb_version pattern)
            wbs_ack_o <= wbs_stb_i && wbs_cyc_i && !wbs_ack_o;

            if (wbs_stb_i && wbs_cyc_i && !wbs_ack_o) begin
                if (wbs_we_i) begin
                    // Write operation
                    case (wbs_adr_i[3:2])
                        ADDR_LED_OUT: begin
                            led_out_reg <= wbs_dat_i[LED_WIDTH-1:0];
                        end
                        ADDR_LED_TOGGLE: begin
                            led_out_reg <= led_out_reg ^ wbs_dat_i[LED_WIDTH-1:0];
                        end
                        ADDR_LED_CLEAR: begin
                            led_out_reg <= led_out_reg & ~wbs_dat_i[LED_WIDTH-1:0];
                        end
                        ADDR_LED_SET: begin
                            led_out_reg <= led_out_reg | wbs_dat_i[LED_WIDTH-1:0];
                        end
                        default: ;
                    endcase
                end else begin
                    // Read operation
                    wbs_dat_o <= {{(32-LED_WIDTH){1'b0}}, led_out_reg};
                end
            end
        end
    end

// Polarity handling at IP boundary:
// - LED_POLARITY=0 (active-low): physical LED ON when logical bit is 1.
// - LED_POLARITY=1 (active-high): physical LED ON when logical bit is 1.
assign led_out = (LED_POLARITY == 0) ? ~led_out_reg : led_out_reg;
endmodule
