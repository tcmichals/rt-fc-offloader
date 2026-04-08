/**
 * wb_timer - Simple Wishbone Timer Peripheral
 *
 * Free-running counter for firmware timing.
 * Counter increments every clock cycle at 72MHz.
 *
 * Register Map:
 *   0x00: COUNT_LO  [31:0] - Lower 32 bits of counter (read-only)
 *   0x04: COUNT_HI  [31:0] - Upper 32 bits of counter (read-only)
 *   0x08: CONTROL   [0]    - bit0: reset counter (write 1 to reset)
 *
 * Usage:
 *   - Read COUNT_LO for sub-second timing (wraps every ~60 seconds at 72MHz)
 *   - For longer timing, read COUNT_HI:COUNT_LO as 64-bit value
 *   - 72MHz clock: 1 tick = 13.9ns, 72000 ticks = 1ms, 9000 ticks = 125µs (8kHz)
 */

`default_nettype none

module wb_timer #(
    parameter CLK_FREQ_HZ = 54_000_000
) (
    input  wire        clk,
    input  wire        rst,

    // Wishbone Slave Interface
    input  wire [31:0] wb_adr_i,
    input  wire [31:0] wb_dat_i,
    output reg  [31:0] wb_dat_o,
    input  wire [3:0]  wb_sel_i,
    input  wire        wb_we_i,
    input  wire        wb_stb_i,
    input  wire        wb_cyc_i,
    output reg         wb_ack_o
);

    // 64-bit free-running counter
    reg [63:0] counter;

    // Counter logic
    always @(posedge clk) begin
        if (rst) begin
            counter <= 64'b0;
        end else if (wb_cyc_i && wb_stb_i && wb_we_i && (wb_adr_i[3:2] == 2'h2) && wb_dat_i[0]) begin
            // Reset counter when writing 1 to CONTROL[0]
            counter <= 64'b0;
        end else begin
            counter <= counter + 1'b1;
        end
    end

    // Address decode
    wire [1:0] addr = wb_adr_i[3:2];

    // Read data mux
    always @(*) begin
        case (addr)
            2'h0:    wb_dat_o = counter[31:0];   // COUNT_LO
            2'h1:    wb_dat_o = counter[63:32];  // COUNT_HI
            2'h2:    wb_dat_o = 32'b0;           // CONTROL (write-only)
            default: wb_dat_o = 32'b0;
        endcase
    end

    // ACK generation (single cycle)
    always @(posedge clk) begin
        if (rst) begin
            wb_ack_o <= 1'b0;
        end else begin
            wb_ack_o <= wb_cyc_i && wb_stb_i && !wb_ack_o;
        end
    end

endmodule

`default_nettype wire
