`default_nettype none

// FCSP SPI frontend (skeleton)
//
// Responsibility: convert SPI physical pins to a core-clock byte stream.
// This module intentionally avoids FCSP parsing semantics.
module fcsp_spi_frontend #(
    parameter int DATA_WIDTH = 8
) (
    input  logic                  clk,
    input  logic                  rst,

    // SPI pins
    input  logic                  i_sclk,
    input  logic                  i_cs_n,
    input  logic                  i_mosi,
    output logic                  o_miso,

    // Core-facing RX stream
    output logic [DATA_WIDTH-1:0] o_rx_byte,
    output logic                  o_rx_valid,
    input  logic                  i_rx_ready,

    // Core-facing TX stream
    input  logic [DATA_WIDTH-1:0] i_tx_byte,
    input  logic                  i_tx_valid,
    output logic                  o_tx_ready,

    output logic                  o_busy
);
    // NOTE: This is a compile-safe skeleton. Port timing/behavior will be
    // upgraded in the next step with full SPI slave shift/edge logic.
    logic [2:0] cs_sync;

    always_ff @(posedge clk) begin
        if (rst) begin
            cs_sync   <= 3'b111;
            o_busy    <= 1'b0;
            o_rx_byte <= '0;
            o_rx_valid <= 1'b0;
            o_tx_ready <= 1'b1;
            o_miso <= 1'b0;
        end else begin
            cs_sync <= {cs_sync[1:0], i_cs_n};
            o_busy <= ~cs_sync[2];

            // Keep handshake deterministic while logic is scaffolded.
            o_rx_valid <= 1'b0;
            o_tx_ready <= 1'b1;

            // Hold MISO low while idle/skeleton mode.
            o_miso <= 1'b0;

            // Prevent unused warnings for yet-to-be-wired interfaces.
            if (i_rx_ready && i_tx_valid) begin
                o_rx_byte <= i_tx_byte;
            end
        end
    end
endmodule

`default_nettype wire
