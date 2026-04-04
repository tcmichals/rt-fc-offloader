/**
 * FCSP NeoPixel (WS2812) Engine
 * 
 * Simple single-LED status controller for WS2812 serial LEDs.
 * Provides a Wishbone register to update the 24-bit RGB value.
 */
`default_nettype none

module fcsp_neo_engine #(
    parameter CLK_FREQ_HZ = 54_000_000
) (
    input  logic        clk,
    input  logic        rst,

    // Wishbone Slave
    input  logic [31:0] wb_adr_i,
    input  logic [31:0] wb_dat_i,
    input  logic        wb_we_i,
    input  logic        wb_cyc_i,
    input  logic        wb_stb_i,
    output logic        wb_ack_o,
    output logic [31:0] wb_dat_o,

    // Physical LED Output
    output logic        o_neo_data,
    output logic        o_neo_busy
);

    // Timing constants for 54MHz (18.5ns period)
    // WS2812 @ 800kHz (1.25us total)
    // 0: 0.35us H, 0.8us L -> 19 H, 43 L
    // 1: 0.7us H, 0.6us L  -> 38 H, 32 L
    localparam [15:0] T0H = 16'd19;
    localparam [15:0] T0L = 16'd43;
    localparam [15:0] T1H = 16'd38;
    localparam [15:0] T1L = 16'd32;
    localparam [15:0] RESET_CLKS = (CLK_FREQ_HZ / 10_000); // 100us reset

    logic [23:0] rgb_reg;
    logic [23:0] shift_reg;
    logic [4:0]  bits_left;
    logic [15:0] cnt;
    logic        active;

    assign o_neo_busy = active;

    typedef enum logic [2:0] {
        IDLE,
        INIT,
        HIGH,
        LOW,
        RESET
    } state_t;

    state_t state;

    always_ff @(posedge clk) begin
        if (rst) begin
            wb_ack_o <= 1'b0;
            wb_dat_o <= 32'h0;
            rgb_reg  <= 24'h0;
            state    <= IDLE;
            o_neo_data <= 1'b0;
            active   <= 1'b0;
        end else begin
            wb_ack_o <= 1'b0;

            // Wishbone Access
            if (wb_cyc_i && wb_stb_i && !wb_ack_o) begin
                wb_ack_o <= 1'b1;
                if (wb_we_i) begin
                    rgb_reg <= wb_dat_i[23:0];
                    if (state == IDLE) state <= INIT;
                end else begin
                    wb_dat_o <= {8'h0, rgb_reg};
                end
            end

            // NeoPixel State Machine
            case (state)
                IDLE: begin
                    o_neo_data <= 1'b0;
                    active <= 1'b0;
                end

                INIT: begin
                    shift_reg <= rgb_reg; // Note: WS2812 is G-R-B order
                    bits_left <= 5'd23;
                    state <= HIGH;
                    active <= 1'b1;
                    cnt <= shift_reg[23] ? T1H : T0H;
                end

                HIGH: begin
                    o_neo_data <= 1'b1;
                    if (cnt == 0) begin
                        state <= LOW;
                        cnt   <= shift_reg[23] ? T1L : T0L;
                    end else cnt <= cnt - 1'b1;
                end

                LOW: begin
                    o_neo_data <= 1'b0;
                    if (cnt == 0) begin
                        if (bits_left == 0) begin
                            state <= RESET;
                            cnt   <= RESET_CLKS;
                        end else begin
                            shift_reg <= {shift_reg[22:0], 1'b0};
                            bits_left <= bits_left - 1'b1;
                            cnt <= shift_reg[22] ? T1H : T0H;
                            state <= HIGH;
                        end
                    end else cnt <= cnt - 1'b1;
                end

                RESET: begin
                    o_neo_data <= 1'b0;
                    if (cnt == 0) state <= IDLE;
                    else cnt <= cnt - 1'b1;
                end
            endcase
        end
    end

endmodule
