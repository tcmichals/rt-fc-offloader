// NeoPixel WS2812/SK6812 AXIS-fed bit-serial waveform generator
// Ported from legacy sendPx_axis_flexible.sv
//
// Drives o_serial with correct T0H/T1H/BIT_PERIOD/LATCH timing.
// Parameterized for CLK_FREQ_HZ and LED_TYPE (0=WS2812, 1=SK6812).
//
// Source: /media/tcmichals/projects/Tang9K/HacksterIO/SPIQuadCopter/neoPXStrip/sendPx_axis_flexible.sv

`default_nettype none

module sendPx_axis_flexible #(
    parameter int CLK_FREQ_HZ = 54_000_000,
    parameter int LED_TYPE    = 0   // 0 = WS2812 (24-bit RGB), 1 = SK6812 (32-bit RGBW)
) (
    input  logic        clk,
    input  logic        rst,
    input  logic [31:0] s_axis_tdata,
    input  logic        s_axis_tvalid,
    input  logic        s_axis_tlast,
    output logic        s_axis_tready,
    output logic        o_serial
);

    // Frequency validation
    generate
        if (CLK_FREQ_HZ < 10_000_000 || CLK_FREQ_HZ > 200_000_000) begin : gen_freq_check
            initial $error("CLK_FREQ_HZ out of range [10 MHz, 200 MHz]. Current: %0d Hz", CLK_FREQ_HZ);
        end
    endgenerate

    // WS2812 timing (ns)
    localparam int WS2812_T0H_NS    = 400;
    localparam int WS2812_T1H_NS    = 800;
    localparam int WS2812_PERIOD_NS = 1250;
    localparam int WS2812_LATCH_NS  = 300_000;

    // SK6812 timing (ns)
    localparam int SK6812_T0H_NS    = 300;
    localparam int SK6812_T1H_NS    = 600;
    localparam int SK6812_PERIOD_NS = 1250;
    localparam int SK6812_LATCH_NS  = 300_000;

    localparam bit IS_SK6812 = (LED_TYPE == 1);

    localparam int T0H_NS    = IS_SK6812 ? SK6812_T0H_NS    : WS2812_T0H_NS;
    localparam int T1H_NS    = IS_SK6812 ? SK6812_T1H_NS    : WS2812_T1H_NS;
    localparam int PERIOD_NS = IS_SK6812 ? SK6812_PERIOD_NS  : WS2812_PERIOD_NS;
    localparam int LATCH_NS  = IS_SK6812 ? SK6812_LATCH_NS   : WS2812_LATCH_NS;

    // 64-bit intermediates to avoid overflow
    localparam logic [63:0] CLK64       = 64'(CLK_FREQ_HZ);
    localparam logic [63:0] HALF_B      = 500_000_000;
    localparam logic [63:0] ONE_B       = 1_000_000_000;

    localparam logic [23:0] T0H_CYC        = 24'(((T0H_NS    * CLK64 + HALF_B) / ONE_B));
    localparam logic [23:0] T1H_CYC        = 24'(((T1H_NS    * CLK64 + HALF_B) / ONE_B));
    localparam logic [23:0] BIT_PERIOD_CYC = 24'(((PERIOD_NS * CLK64 + HALF_B) / ONE_B));
    localparam logic [23:0] LATCH_CYC      = 24'(((LATCH_NS  * CLK64 + HALF_B) / ONE_B));
    localparam logic [23:0] GAP_CYC        = 24'(((200       * CLK64 + HALF_B) / ONE_B));

    // Bit count: 24 for WS2812, 32 for SK6812
    localparam logic [5:0] BIT_COUNT_MAX = IS_SK6812 ? 6'd31 : 6'd23;

    typedef enum logic [1:0] { IDLE, SEND, GAP, LATCH } state_t;
    state_t state;

    logic [31:0] shift_reg;
    logic [5:0]  bit_cnt;
    logic [23:0] timer;
    logic        is_last_px;

    wire [23:0] active_threshold = shift_reg[31] ? T1H_CYC : T0H_CYC;

    assign s_axis_tready = (state == IDLE);

    always_ff @(posedge clk) begin
        if (rst) begin
            state      <= IDLE;
            o_serial   <= 1'b0;
            timer      <= 24'd0;
            bit_cnt    <= 6'd0;
            shift_reg  <= 32'd0;
            is_last_px <= 1'b0;
        end else begin
            case (state)
                IDLE: begin
                    o_serial <= 1'b0;
                    timer    <= 24'd0;
                    bit_cnt  <= 6'd0;
                    if (s_axis_tvalid && s_axis_tready) begin
                        shift_reg  <= s_axis_tdata;
                        is_last_px <= s_axis_tlast;
                        state      <= SEND;
                    end
                end

                SEND: begin
                    o_serial <= (timer < active_threshold);
                    if (timer >= BIT_PERIOD_CYC - 24'd1) begin
                        timer <= 24'd0;
                        if (bit_cnt >= BIT_COUNT_MAX) begin
                            o_serial <= 1'b0;
                            state    <= is_last_px ? LATCH : GAP;
                        end else begin
                            bit_cnt   <= bit_cnt + 6'd1;
                            shift_reg <= {shift_reg[30:0], 1'b0};
                        end
                    end else begin
                        timer <= timer + 24'd1;
                    end
                end

                GAP: begin
                    o_serial <= 1'b0;
                    if (timer >= GAP_CYC - 24'd1) begin
                        timer <= 24'd0;
                        state <= IDLE;
                    end else begin
                        timer <= timer + 24'd1;
                    end
                end

                LATCH: begin
                    o_serial <= 1'b0;
                    if (timer >= LATCH_CYC - 24'd1) begin
                        timer <= 24'd0;
                        state <= IDLE;
                    end else begin
                        timer <= timer + 24'd1;
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
