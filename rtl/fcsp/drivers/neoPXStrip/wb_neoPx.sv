/**

 * Wishbone NeoPixel Controller (WS2812/SK6812)
 *
 * Features:
 * - Wishbone-mapped pixel buffer for up to 8 NeoPixels
 * - AXI-like interface: outputs pixel data and valid strobe to NeoPixel bitstream driver
 * - Supports WS2812 (24-bit RGB) and SK6812 (32-bit RGBW) via sendPx_axis_flexible LED_TYPE parameter
 * - Dynamic timing calculation based on CLK_FREQ_HZ (10 MHz to 200 MHz)
 * - Default: WS2812 with 400/800 ns high pulse per bit spec
 * - For SK6812 support, instantiate sendPx_axis_flexible with LED_TYPE="SK6812" parameter
 * - Use with sendPx_axis_flexible.sv for correct timing
 *
 * Address map:
 *   0x00-0x1C: Write 32-bit RGBW values for each pixel
 *   Other: trigger update
 *
 * See SYSTEM_OVERVIEW.md for details.
 */

`timescale 1ns / 1ps

module wb_neoPx #( 
    parameter DATA_WIDTH = 32,
    parameter ADDR_WIDTH = 32,
    parameter SELECT_WIDTH = (DATA_WIDTH/8),
    parameter CLK_FREQ_HZ = 54_000_000
) (
    input  wire                    i_clk,
    input  wire                    i_rst,
    input  wire [ADDR_WIDTH-1:0]   wb_adr_i,
    input  wire [DATA_WIDTH-1:0]   wb_dat_i,
    output wire [DATA_WIDTH-1:0]   wb_dat_o,
    input  wire                    wb_we_i,
    input  wire [SELECT_WIDTH-1:0] wb_sel_i,
    input  wire                    wb_stb_i,
    output wire                    wb_ack_o,
    output wire                    wb_err_o,
    output wire                    wb_rty_o,
    input  wire                    wb_cyc_i,
    output wire                    o_serial
);

    // Frequency validation - minimum 10 MHz required for accurate NeoPixel timing
    generate
        if (CLK_FREQ_HZ < 10_000_000 || CLK_FREQ_HZ > 200_000_000) begin
            initial $error("CLK_FREQ_HZ out of valid range. Must be between 10 MHz and 200 MHz. Current: %0d Hz", CLK_FREQ_HZ);
        end
    endgenerate

    // --- Internal Registers ---
    logic [31:0] ledData[0:7]; 
    logic [3:0]  state;
    logic [3:0]  count;
    logic        ack;
    logic        update_req;
    logic        tvalid;
    logic        sendState;
    
    wire       isReady;
    wire [31:0] m_axis_data;
    wire        tlast;

    // --- Logic Assignments ---
    assign wb_ack_o = ack;
    assign wb_err_o = 1'b0;
    assign wb_rty_o = 1'b0;
    assign wb_dat_o = (wb_adr_i[5:0] <= 6'h1C) ? ledData[wb_adr_i[4:2]] : 32'h0;
    assign m_axis_data = ledData[count];
    assign tlast       = (count == 4'd7);

    // --- Wishbone Slave Logic ---
    always_ff @(posedge i_clk) begin
        if (i_rst) begin
            ack <= 1'b0;
            update_req <= 1'b0;
            ledData[0] <= 32'h0; ledData[1] <= 32'h0; ledData[2] <= 32'h0; ledData[3] <= 32'h0;
            ledData[4] <= 32'h0; ledData[5] <= 32'h0; ledData[6] <= 32'h0; ledData[7] <= 32'h0;
        end else begin
            if (wb_cyc_i && wb_stb_i && !ack) begin
                ack <= 1'b1;
                if (wb_we_i) begin
                    if (wb_adr_i[5:0] <= 6'h1C) 
                        ledData[wb_adr_i[4:2]] <= wb_dat_i;
                    else 
                        update_req <= 1'b1;
                end
            end else begin
                ack <= 1'b0;
                if (state != 4'd0) update_req <= 1'b0;
            end
        end
    end

    // --- FSM ---
    always_ff @(posedge i_clk) begin
        if (i_rst) begin
            state <= 4'd0; tvalid <= 0; count <= 0; sendState <= 0;
        end else begin
            case (state)
                4'd0: begin // IDLE
                    count <= 0; tvalid <= 0;
                    if (update_req) state <= 4'd1;
                end
                4'd9: state <= 4'd0; // DONE
                default: begin
                    if (!sendState) begin
                        if (isReady) begin
                            tvalid <= 1'b1; sendState <= 1'b1;
                        end
                    end else if (isReady && tvalid) begin
                        tvalid <= 1'b0; sendState <= 1'b0;
                        if (count == 4'd7) state <= 4'd9;
                        else begin
                            count <= count + 1'b1;
                            state <= state + 1'b1;
                        end
                    end
                end
            endcase
        end
    end

    sendPx_axis_flexible #(
        .CLK_FREQ_HZ(CLK_FREQ_HZ),
        .LED_TYPE(1) // Use SK6812 (32-bit RGBW) to match testbench expectations
    ) axis_inst (
        .axis_aclk(i_clk),
        .axis_reset(i_rst),
        .s_axis_tdata(m_axis_data),
        .s_axis_tvalid(tvalid),
        .s_axis_tlast(tlast),
        .s_axis_tready(isReady),
        .o_serial(o_serial)
    );

endmodule
