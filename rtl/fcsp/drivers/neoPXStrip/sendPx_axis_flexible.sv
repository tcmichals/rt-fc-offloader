`timescale 1ns / 1ps

module sendPx_axis_flexible #(
    parameter integer CLK_FREQ_HZ = 54_000_000,
    parameter integer LED_TYPE    = 0   // 0 = WS2812 (24-bit), 1 = SK6812 (32-bit)
)(
    input  wire        axis_aclk,
    input  wire        axis_reset,
    input  wire [31:0] s_axis_tdata,
    input  wire        s_axis_tvalid,
    input  wire        s_axis_tlast,
    output wire         s_axis_tready,
    output reg         o_serial
);
/* From Data sheet WS2812

T0H .35us to .4us
T1H .7us to .8us
T0L .8us to .85us
T1L .6us to .65us

*/

/* From SK6812 
T0H .3us
T1H .6us
T0L .9us 
T1L .6us
*/

    // --- Frequency Validation ---
    // CLK_FREQ_HZ must be between 10 MHz and 200 MHz for accurate sub-microsecond timing
    generate
        if (CLK_FREQ_HZ < 10_000_000 || CLK_FREQ_HZ > 200_000_000) begin
            $error("CLK_FREQ_HZ out of valid range. Must be between 10 MHz and 200 MHz. Current: %0d Hz", CLK_FREQ_HZ);
        end
    endgenerate

    // --- Dynamic Timing Calculation ---
    // Timing values are calculated from integer-nanosecond specs and CLK_FREQ_HZ

    // WS2812: T0H=400ns, T1H=800ns, BIT_PERIOD=1250ns, LATCH=300000ns
    localparam integer WS2812_T0H_NS     = 400;
    localparam integer WS2812_T1H_NS     = 800;
    localparam integer WS2812_PERIOD_NS  = 1250;
    localparam integer WS2812_LATCH_NS   = 300_000;

    // SK6812: T0H=300ns, T1H=600ns, BIT_PERIOD=1250ns, LATCH=300000ns
    localparam integer SK6812_T0H_NS     = 300;
    localparam integer SK6812_T1H_NS     = 600;
    localparam integer SK6812_PERIOD_NS  = 1250;
    localparam integer SK6812_LATCH_NS   = 300_000;

    // LED type selector (0 = WS2812, 1 = SK6812)
    localparam bit IS_SK6812 = (LED_TYPE == 1);

    // Conditional timing based on LED_TYPE
    localparam integer T0H_NS    = IS_SK6812 ? SK6812_T0H_NS : WS2812_T0H_NS;
    localparam integer T1H_NS    = IS_SK6812 ? SK6812_T1H_NS : WS2812_T1H_NS;
    localparam integer PERIOD_NS = IS_SK6812 ? SK6812_PERIOD_NS : WS2812_PERIOD_NS;
    localparam integer LATCH_NS  = IS_SK6812 ? SK6812_LATCH_NS : WS2812_LATCH_NS;

    // Convert to cycle counts using widened 64-bit intermediate localparams to avoid overflow
    localparam [63:0] CLK64       = CLK_FREQ_HZ;
    localparam [63:0] T0H_NS64    = T0H_NS;
    localparam [63:0] T1H_NS64    = T1H_NS;
    localparam [63:0] PERIOD_NS64 = PERIOD_NS;
    localparam [63:0] LATCH_NS64  = LATCH_NS;
    localparam [63:0] CONST_HALF_BILLION = 500_000_000;
    localparam [63:0] CONST_BILLION = 1_000_000_000;

    localparam [63:0] T0H_CYC64        = (T0H_NS64 * CLK64 + CONST_HALF_BILLION) / CONST_BILLION;
    localparam [63:0] T1H_CYC64        = (T1H_NS64 * CLK64 + CONST_HALF_BILLION) / CONST_BILLION;
    localparam [63:0] BIT_PERIOD_CYC64 = (PERIOD_NS64 * CLK64 + CONST_HALF_BILLION) / CONST_BILLION;
    localparam [63:0] LATCH_CYC64      = (LATCH_NS64 * CLK64 + CONST_HALF_BILLION) / CONST_BILLION;
    localparam [63:0] GAP_CYC64        = (((64'd200) * CLK64 + CONST_HALF_BILLION) / CONST_BILLION); // 200ns inter-pixel gap

    localparam [23:0] T0H_CYC        = T0H_CYC64[23:0];
    localparam [23:0] T1H_CYC        = T1H_CYC64[23:0];
    localparam [23:0] BIT_PERIOD_CYC = BIT_PERIOD_CYC64[23:0];
    localparam [23:0] LATCH_CYC      = LATCH_CYC64[23:0];
    localparam [23:0] GAP_CYC        = GAP_CYC64[23:0];

    // Bit count limit: 24 bits for WS2812, 32 bits for SK6812
    localparam [5:0] BIT_COUNT_MAX = IS_SK6812 ? 6'd31 : 6'd23;

    typedef enum reg [1:0] { IDLE, SEND, GAP, LATCH } state_t;
    state_t state;

    reg [31:0] shift_reg;
    reg [5:0]  bit_cnt;
    reg [23:0] timer;
    reg        is_last_px;

    // Pulse width is determined by current MSB
    wire [23:0] active_threshold;
    assign active_threshold = (shift_reg[31]) ? T1H_CYC : T0H_CYC;

    // AXIS ready is high when in IDLE state and not sending
    assign s_axis_tready = (state == IDLE);

    // Print timing constants at simulation start for debugging
    initial begin
        $display("[INFO] T0H_CYC=%0d T1H_CYC=%0d BIT_PERIOD_CYC=%0d LATCH_CYC=%0d GAP_CYC=%0d BIT_COUNT_MAX=%0d", T0H_CYC, T1H_CYC, BIT_PERIOD_CYC, LATCH_CYC, GAP_CYC, BIT_COUNT_MAX);
    end

    always @(posedge axis_aclk) begin
        if (axis_reset) begin
            state <= IDLE;
            o_serial <= 0;
            timer <= 0;
            bit_cnt <= 0;
            shift_reg <= 0;
            is_last_px <= 0;
        end else begin
            case (state)
                IDLE: begin
                    o_serial <= 0;
                    timer    <= 0;
                    bit_cnt  <= 0;
                    if (s_axis_tvalid && s_axis_tready) begin
                        shift_reg  <= s_axis_tdata;
                        is_last_px <= s_axis_tlast;
                        state      <= SEND;
                    end
                end

                SEND: begin
                    o_serial <= (timer < active_threshold);
                    if (timer >= BIT_PERIOD_CYC - 24'd1) begin
                        timer <= 0;
                            if (bit_cnt >= BIT_COUNT_MAX) begin
                                    o_serial <= 0;
                                    if (is_last_px) begin
                                        state <= LATCH;
                                    end else begin
                                        state <= GAP;
                                    end
                            end else begin
                            bit_cnt   <= bit_cnt + 1;
                            shift_reg <= {shift_reg[30:0], 1'b0};
                        end
                    end else begin
                        timer <= timer + 1;
                    end
                end

                GAP: begin
                    o_serial <= 0;
                    if (timer >= GAP_CYC - 24'd1) begin
                        timer <= 0;
                        state <= IDLE;
                    end else begin
                        timer <= timer + 1;
                    end
                end

                LATCH: begin
                    o_serial <= 0;
                    if (timer >= LATCH_CYC - 24'd1) begin
                        timer <= 0;
                        state <= IDLE;
                    end else begin
                        timer <= timer + 1;
                    end
                end
                
                default: state <= IDLE;
            endcase
        end
    end
endmodule