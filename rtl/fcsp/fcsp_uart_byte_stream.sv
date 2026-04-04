`default_nettype none

// UART <-> byte-stream shim (8N1)
//
// Provides a simple AXIS-like byte seam around a UART line pair.
// - TX input: i_tx_valid/i_tx_byte with o_tx_ready backpressure
// - RX output: o_rx_valid/o_rx_byte with i_rx_ready backpressure
module fcsp_uart_byte_stream #(
    parameter int CLK_HZ = 27_000_000,
    parameter int BAUD   = 1_000_000
) (
    input  logic       clk,
    input  logic       rst,

    // UART pins
    input  logic       i_uart_rx,
    output logic       o_uart_tx,

    // TX byte stream (slave)
    input  logic       i_tx_valid,
    input  logic [7:0] i_tx_byte,
    output logic       o_tx_ready,

    // RX byte stream (master)
    output logic       o_rx_valid,
    output logic [7:0] o_rx_byte,
    input  logic       i_rx_ready
);
    localparam int BAUD_DIV = (CLK_HZ + (BAUD/2)) / BAUD;
    localparam int BAUD_DIV_W = (BAUD_DIV <= 1) ? 1 : $clog2(BAUD_DIV);
    localparam int RX_START_TICKS_INT = BAUD_DIV + (BAUD_DIV/2) - 1;
    localparam logic [BAUD_DIV_W-1:0] BAUD_DIV_M1 = BAUD_DIV[BAUD_DIV_W-1:0] - 1'b1;
    localparam logic [BAUD_DIV_W-1:0] RX_START_TICKS = RX_START_TICKS_INT[BAUD_DIV_W-1:0];

    // ----------------
    // TX state machine
    // ----------------
    logic [9:0] tx_shift;
    logic [3:0] tx_bits_left;
    logic [BAUD_DIV_W-1:0] tx_tick_cnt;
    logic tx_busy;

    assign o_tx_ready = ~tx_busy;
    assign o_uart_tx  = tx_busy ? tx_shift[0] : 1'b1;

    always_ff @(posedge clk) begin
        if (rst) begin
            tx_shift    <= 10'h3FF;
            tx_bits_left<= 4'd0;
            tx_tick_cnt <= '0;
            tx_busy     <= 1'b0;
        end else begin
            if (!tx_busy) begin
                if (i_tx_valid && o_tx_ready) begin
                    // 8N1: start(0), data[7:0] LSB-first, stop(1)
                    tx_shift     <= {1'b1, i_tx_byte, 1'b0};
                    tx_bits_left <= 4'd10;
                    tx_tick_cnt  <= BAUD_DIV_M1;
                    tx_busy      <= 1'b1;
                end
            end else begin
                if (tx_tick_cnt == '0) begin
                    tx_shift <= {1'b1, tx_shift[9:1]};
                    if (tx_bits_left == 4'd1) begin
                        tx_busy      <= 1'b0;
                        tx_bits_left <= 4'd0;
                    end else begin
                        tx_bits_left <= tx_bits_left - 1'b1;
                    end
                    tx_tick_cnt <= BAUD_DIV_M1;
                end else begin
                    tx_tick_cnt <= tx_tick_cnt - 1'b1;
                end
            end
        end
    end

    // ----------------
    // RX state machine
    // ----------------
    logic rx_sync_0, rx_sync_1;
    logic rx_busy;
    logic [3:0] rx_bit_idx;
    logic [7:0] rx_shift;
    logic [BAUD_DIV_W-1:0] rx_tick_cnt;
    logic [7:0] rx_hold_byte;
    logic rx_hold_valid;

    assign o_rx_valid = rx_hold_valid;
    assign o_rx_byte  = rx_hold_byte;

    always_ff @(posedge clk) begin
        if (rst) begin
            rx_sync_0    <= 1'b1;
            rx_sync_1    <= 1'b1;
            rx_busy      <= 1'b0;
            rx_bit_idx   <= 4'd0;
            rx_shift     <= 8'h00;
            rx_tick_cnt  <= '0;
            rx_hold_byte <= 8'h00;
            rx_hold_valid<= 1'b0;
        end else begin
            rx_sync_0 <= i_uart_rx;
            rx_sync_1 <= rx_sync_0;

            if (rx_hold_valid && i_rx_ready) begin
                rx_hold_valid <= 1'b0;
            end

            if (!rx_busy) begin
                // Detect start bit low; sample first data bit ~1.5 bit later.
                if (!rx_sync_1) begin
                    rx_busy     <= 1'b1;
                    rx_bit_idx  <= 4'd0;
                    rx_tick_cnt <= RX_START_TICKS;
                end
            end else begin
                if (rx_tick_cnt == '0) begin
                    if (rx_bit_idx < 4'd8) begin
                        rx_shift[rx_bit_idx] <= rx_sync_1;
                        rx_bit_idx <= rx_bit_idx + 1'b1;
                        rx_tick_cnt <= BAUD_DIV_M1;
                    end else begin
                        // Stop bit sample point reached; accept byte.
                        rx_busy <= 1'b0;
                        if (!rx_hold_valid) begin
                            rx_hold_byte  <= rx_shift;
                            rx_hold_valid <= 1'b1;
                        end
                    end
                end else begin
                    rx_tick_cnt <= rx_tick_cnt - 1'b1;
                end
            end
        end
    end
endmodule

`default_nettype wire
