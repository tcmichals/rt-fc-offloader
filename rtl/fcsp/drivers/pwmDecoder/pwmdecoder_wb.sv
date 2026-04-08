/**
 * PWM Decoder with Wishbone B3 Interface
 * 
 * Decodes 6 RC-style PWM input signals and provides register-based access via Wishbone bus.
 * 
 * Address Map:
 *   0x00: PWM Channel 0 value (R) - 16-bit pulse width in microseconds
 *   0x04: PWM Channel 1 value (R)
 *   0x08: PWM Channel 2 value (R)
 *   0x0C: PWM Channel 3 value (R)
 *   0x10: PWM Channel 4 value (R)
 *   0x14: PWM Channel 5 value (R)
 *   0x18: Status register (R) - bits [5:0] = channel ready flags
 * 
 * PWM Value Format:
 *   Bits [15:0] = Pulse width in microseconds
 *   Special values:
 *     - Value | 0x8000: Guard time error (pulse too long)
 *     - Value | 0xC000: Guard time error (no signal)
 * 
 * Parameters:
 *   clockFreq: System clock frequency in Hz (default: 100 MHz)
 *   DATA_WIDTH: Wishbone data width (default: 32)
 *   ADDR_WIDTH: Wishbone address width (default: 32)
 */

`default_nettype none
`timescale 1 ns / 1 ns

module pwmdecoder_wb #(
    parameter clockFreq = 100_000_000,
    parameter DATA_WIDTH = 32,
    parameter ADDR_WIDTH = 32,
    parameter SELECT_WIDTH = (DATA_WIDTH/8)
)
(
    input wire i_clk,
    input wire i_rst,
    
    // Wishbone slave interface
    input  wire [ADDR_WIDTH-1:0]   wb_adr_i,
    input  wire [DATA_WIDTH-1:0]   wb_dat_i,
    output reg  [DATA_WIDTH-1:0]   wb_dat_o,
    input  wire                    wb_we_i,
    input  wire [SELECT_WIDTH-1:0] wb_sel_i,
    input  wire                    wb_stb_i,
    output reg                     wb_ack_o,
    output wire                    wb_err_o,
    output wire                    wb_rty_o,
    input  wire                    wb_cyc_i,

    // PWM input signals
    input wire i_pwm_0,
    input wire i_pwm_1,
    input wire i_pwm_2,
    input wire i_pwm_3,
    input wire i_pwm_4,
    input wire i_pwm_5
);

    // Internal signals
    wire       pwm_ready_0, pwm_ready_1, pwm_ready_2;
    wire       pwm_ready_3, pwm_ready_4, pwm_ready_5;
    wire [15:0] pwm_value_0, pwm_value_1, pwm_value_2;
    wire [15:0] pwm_value_3, pwm_value_4, pwm_value_5;
    
    // Address decode
    wire [4:0] addr_bits = wb_adr_i[6:2];  // Word-aligned addresses
    
    // Wishbone protocol: no errors or retries
    assign wb_err_o = 1'b0;
    assign wb_rty_o = 1'b0;
    
    // Wishbone read logic
    // Internal active-low reset for legacy pwmdecoder instances
    wire i_rstn = ~i_rst;

    always @(posedge i_clk or posedge i_rst) begin
        if (i_rst) begin
            wb_dat_o <= 32'h0;
            wb_ack_o <= 1'b0;
        end else begin
            // Acknowledge any valid cycle
            wb_ack_o <= wb_stb_i && wb_cyc_i && !wb_ack_o;
            
            if (wb_stb_i && wb_cyc_i && !wb_we_i) begin
                // Read operation
                case (addr_bits)
                    5'h00: wb_dat_o <= {16'h0, pwm_value_0};
                    5'h01: wb_dat_o <= {16'h0, pwm_value_1};
                    5'h02: wb_dat_o <= {16'h0, pwm_value_2};
                    5'h03: wb_dat_o <= {16'h0, pwm_value_3};
                    5'h04: wb_dat_o <= {16'h0, pwm_value_4};
                    5'h05: wb_dat_o <= {16'h0, pwm_value_5};
                    5'h06: wb_dat_o <= {26'h0, pwm_ready_5, pwm_ready_4, pwm_ready_3, 
                                              pwm_ready_2, pwm_ready_1, pwm_ready_0};
                    default: wb_dat_o <= 32'hDEADBEEF;
                endcase
            end
        end
    end
    
    // PWM Decoder Instances
    pwmdecoder #(
        .clockFreq(clockFreq)
    ) pwmDecoder_0 (
        .i_clk(i_clk),
        .i_pwm(i_pwm_0),
        .i_resetn(i_rstn),
        .o_pwm_ready(pwm_ready_0),
        .o_pwm_value(pwm_value_0)
    );

    pwmdecoder #(
        .clockFreq(clockFreq)
    ) pwmDecoder_1 (
        .i_clk(i_clk),
        .i_pwm(i_pwm_1),
        .i_resetn(i_rstn),
        .o_pwm_ready(pwm_ready_1),
        .o_pwm_value(pwm_value_1)
    );

    pwmdecoder #(
        .clockFreq(clockFreq)
    ) pwmDecoder_2 (
        .i_clk(i_clk),
        .i_pwm(i_pwm_2),
        .i_resetn(i_rstn),
        .o_pwm_ready(pwm_ready_2),
        .o_pwm_value(pwm_value_2)
    );

    pwmdecoder #(
        .clockFreq(clockFreq)
    ) pwmDecoder_3 (
        .i_clk(i_clk),
        .i_pwm(i_pwm_3),
        .i_resetn(i_rstn),
        .o_pwm_ready(pwm_ready_3),
        .o_pwm_value(pwm_value_3)
    );

    pwmdecoder #(
        .clockFreq(clockFreq)
    ) pwmDecoder_4 (
        .i_clk(i_clk),
        .i_pwm(i_pwm_4),
        .i_resetn(i_rstn),
        .o_pwm_ready(pwm_ready_4),
        .o_pwm_value(pwm_value_4)
    );

    pwmdecoder #(
        .clockFreq(clockFreq)
    ) pwmDecoder_5 (
        .i_clk(i_clk),
        .i_pwm(i_pwm_5),
        .i_resetn(i_rstn),
        .o_pwm_ready(pwm_ready_5),
        .o_pwm_value(pwm_value_5)
    );

endmodule