/**
 * FCSP DSHOT Protocol Output Module
 * 
 * Implements DSHOT digital ESC protocol for motor control.
 * Adapted from prior SPIQuadCopter design for Pure Hardware Offloader.
 */
`default_nettype none
`timescale 1 ns / 1 ns

module fcsp_dshot_output #(
    parameter CLK_FREQ_HZ = 54_000_000
) (
    input  logic        clk,
    input  logic        rst,
    input  logic [15:0] i_dshot_value, // Full 16-bit frame [Throttle(11) | Telem(1) | CRC(15)]
    input  logic [15:0] i_dshot_mode,  // 150, 300, 600
    input  logic        i_write,       // Triggers transmission
    output logic        o_pwm,
    output logic        o_ready        // True when NOT transmitting and GUARD TIME elapsed
);

    // State definitions
    typedef enum logic [1:0] {
        IDLE,
        INIT,
        HIGH,
        LOW
    } state_t;

    state_t state;

    // Timing constants (calculated for the given clock frequency)
    // DSHOT150: 6.67us period. 0: 2.5us HIGH. 1: 5.0us HIGH.
    localparam [15:0] T0H_150 = (CLK_FREQ_HZ * 25) / 10_000_000;
    localparam [15:0] T0L_150 = (CLK_FREQ_HZ * 417) / 100_000_000;
    localparam [15:0] T1H_150 = (CLK_FREQ_HZ * 50) / 10_000_000;
    localparam [15:0] T1L_150 = (CLK_FREQ_HZ * 167) / 100_000_000;
    localparam [15:0] GUARD_150 = (CLK_FREQ_HZ * 250) / 1_000_000; // 250us

    // Latched registers for timing stability
    logic [15:0] t0h_clks, t0l_clks, t1h_clks, t1l_clks, guard_clks;
    logic [15:0] dshot_shift_reg;
    logic [3:0]  bits_left;
    logic [15:0] high_cnt, low_cnt, guard_cnt;

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= IDLE;
            o_pwm <= 1'b0;
            o_ready <= 1'b1;
            guard_cnt <= '0;
            // Default DSHOT150
            t0h_clks <= T0H_150; t0l_clks <= T0L_150;
            t1h_clks <= T1H_150; t1l_clks <= T1L_150;
            guard_clks <= GUARD_150;
        end else begin
            case (state)
                IDLE: begin
                    o_pwm <= 1'b0;
                    if (guard_cnt != 0) begin
                        guard_cnt <= guard_cnt - 1'b1;
                        o_ready <= 1'b0;
                    end else begin
                        o_ready <= 1'b1;
                        if (i_write) begin
                            dshot_shift_reg <= i_dshot_value;
                            bits_left <= 4'd15;
                            guard_cnt <= guard_clks;
                            state <= INIT;
                        end
                    end
                end

                INIT: begin
                    if (dshot_shift_reg[15]) begin
                        high_cnt <= t1h_clks;
                        low_cnt  <= t1l_clks;
                    end else begin
                        high_cnt <= t0h_clks;
                        low_cnt  <= t0l_clks;
                    end
                    state <= HIGH;
                end

                HIGH: begin
                    o_pwm <= 1'b1;
                    if (high_cnt == 0) state <= LOW;
                    else high_cnt <= high_cnt - 1'b1;
                end

                LOW: begin
                    o_pwm <= 1'b0;
                    if (low_cnt == 0) begin
                        if (bits_left == 0) begin
                            state <= IDLE;
                        end else begin
                            dshot_shift_reg <= {dshot_shift_reg[14:0], 1'b0};
                            bits_left <= bits_left - 1'b1;
                            state <= INIT;
                        end
                    end else begin
                        low_cnt <= low_cnt - 1'b1;
                    end
                end
            endcase
        end
    end

endmodule
