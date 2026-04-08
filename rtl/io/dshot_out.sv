// DSHOT Protocol Output Module (ported from legacy dshot_out.v)
//
// Pure bit-level DSHOT pulse transmitter.
// Supports runtime-selectable DSHOT150 / DSHOT300 / DSHOT600.
//
// DSHOT Frame Format (16 bits total):
//   [15:5]  Throttle (0–2047)
//   [4]     Telemetry request
//   [3:0]   CRC (host-calculated)
//
// This module handles:
//   - Converting each bit into proper DSHOT timing
//   - Enforcing inter-frame guard time
//   - Generating PWM output signal
//
// Source: /media/tcmichals/projects/Tang9K/HacksterIO/SPIQuadCopter/dshot/dshot_out.v

`default_nettype none

module dshot_out #(
    parameter int CLK_FREQ_HZ = 54_000_000
) (
    input  logic        clk,
    input  logic        rst,
    input  logic [15:0] i_dshot_value,
    input  logic [15:0] i_dshot_mode,   // 150, 300, or 600
    input  logic        i_write,
    output logic        o_pwm,
    output logic        o_ready
);

    // Frequency validation
    generate
        if (CLK_FREQ_HZ < 10_000_000) begin : gen_freq_check
            initial $error("CLK_FREQ_HZ must be >= 10 MHz for DSHOT timing. Current: %0d Hz", CLK_FREQ_HZ);
        end
    endgenerate

    // State machine states
    typedef enum logic [1:0] {
        ST_IDLE     = 2'd0,
        ST_INIT     = 2'd1,
        ST_HIGH     = 2'd2,
        ST_LOW      = 2'd3
    } state_t;

    localparam logic [15:0] GUARD_BAND = 16'd7;

    // DSHOT150 timing (use 64-bit intermediates to avoid signed overflow)
    localparam logic [15:0] T0H_150   = 16'((64'(CLK_FREQ_HZ) * 25) / 10_000_000);
    localparam logic [15:0] T0L_150   = 16'((64'(CLK_FREQ_HZ) * 417) / 100_000_000);
    localparam logic [15:0] T1H_150   = 16'((64'(CLK_FREQ_HZ) * 50) / 10_000_000);
    localparam logic [15:0] T1L_150   = 16'((64'(CLK_FREQ_HZ) * 167) / 100_000_000);
    localparam logic [15:0] GUARD_150 = 16'((64'(CLK_FREQ_HZ) * 250) / 1_000_000);

    // DSHOT300 timing
    localparam logic [15:0] T0H_300   = 16'((64'(CLK_FREQ_HZ) * 125) / 100_000_000);
    localparam logic [15:0] T0L_300   = 16'((64'(CLK_FREQ_HZ) * 208) / 100_000_000);
    localparam logic [15:0] T1H_300   = 16'((64'(CLK_FREQ_HZ) * 25) / 10_000_000);
    localparam logic [15:0] T1L_300   = 16'((64'(CLK_FREQ_HZ) * 83) / 100_000_000);
    localparam logic [15:0] GUARD_300 = 16'((64'(CLK_FREQ_HZ) * 125) / 1_000_000);

    // DSHOT600 timing
    localparam logic [15:0] T0H_600   = 16'((64'(CLK_FREQ_HZ) * 625) / 1_000_000_000);
    localparam logic [15:0] T0L_600   = 16'((64'(CLK_FREQ_HZ) * 104) / 100_000_000);
    localparam logic [15:0] T1H_600   = 16'((64'(CLK_FREQ_HZ) * 125) / 100_000_000);
    localparam logic [15:0] T1L_600   = 16'((64'(CLK_FREQ_HZ) * 42) / 100_000_000);
    localparam logic [15:0] GUARD_600 = 16'((64'(CLK_FREQ_HZ) * 625) / 10_000_000);

    localparam logic [4:0] NUM_BIT_TO_SHIFT = 5'd15;

    // Registered timing values
    logic [15:0] t0h_clocks, t0l_clocks, t1h_clocks, t1l_clocks, guard_time_val;
    logic [15:0] dshot_mode_latched;

    state_t      state;
    logic [4:0]  bits_to_shift;
    logic [15:0] counter_high, counter_low;
    logic [15:0] dshot_command;
    logic [15:0] guard_count;
    logic        pwm_reg;
    logic        ready_reg;

    // Update timing params only when idle and guard expired
    always_ff @(posedge clk) begin
        if (rst) begin
            t0h_clocks       <= T0H_150;
            t0l_clocks       <= T0L_150;
            t1h_clocks       <= T1H_150;
            t1l_clocks       <= T1L_150;
            guard_time_val   <= GUARD_150;
            dshot_mode_latched <= 16'd150;
        end else if (state == ST_IDLE && guard_count == 16'd0) begin
            if (i_dshot_mode != dshot_mode_latched) begin
                dshot_mode_latched <= i_dshot_mode;
                case (i_dshot_mode)
                    16'd300: begin
                        t0h_clocks <= T0H_300; t0l_clocks <= T0L_300;
                        t1h_clocks <= T1H_300; t1l_clocks <= T1L_300;
                        guard_time_val <= GUARD_300;
                    end
                    16'd600: begin
                        t0h_clocks <= T0H_600; t0l_clocks <= T0L_600;
                        t1h_clocks <= T1H_600; t1l_clocks <= T1L_600;
                        guard_time_val <= GUARD_600;
                    end
                    default: begin
                        t0h_clocks <= T0H_150; t0l_clocks <= T0L_150;
                        t1h_clocks <= T1H_150; t1l_clocks <= T1L_150;
                        guard_time_val <= GUARD_150;
                    end
                endcase
            end
        end
    end

    // Main state machine
    always_ff @(posedge clk) begin
        if (rst) begin
            state         <= ST_IDLE;
            bits_to_shift <= 5'd0;
            dshot_command <= 16'd0;
            pwm_reg       <= 1'b0;
            guard_count   <= 16'd0;
            ready_reg     <= 1'b1;
            counter_high  <= 16'd0;
            counter_low   <= 16'd0;
        end else begin
            if (i_write && state == ST_IDLE && guard_count == 16'd0) begin
                dshot_command <= i_dshot_value;
                bits_to_shift <= NUM_BIT_TO_SHIFT;
                state         <= ST_INIT;
                ready_reg     <= 1'b0;
                guard_count   <= guard_time_val;
            end else begin
                case (state)
                    ST_INIT: begin
                        if (dshot_command[15]) begin
                            counter_high <= t1h_clocks - GUARD_BAND;
                            counter_low  <= t1l_clocks + GUARD_BAND;
                        end else begin
                            counter_high <= t0h_clocks - GUARD_BAND;
                            counter_low  <= t0l_clocks + GUARD_BAND;
                        end
                        state <= ST_HIGH;
                    end

                    ST_HIGH: begin
                        pwm_reg <= 1'b1;
                        if (counter_high == 16'd0) begin
                            state <= ST_LOW;
                        end else begin
                            counter_high <= counter_high - 16'd1;
                        end
                    end

                    ST_LOW: begin
                        pwm_reg <= 1'b0;
                        if (counter_low == 16'd0) begin
                            if (bits_to_shift == 5'd0) begin
                                state <= ST_IDLE;
                            end else begin
                                bits_to_shift <= bits_to_shift - 5'd1;
                                dshot_command <= {dshot_command[14:0], 1'b0};
                                state         <= ST_INIT;
                            end
                        end else begin
                            counter_low <= counter_low - 16'd1;
                        end
                    end

                    ST_IDLE: begin
                        if (guard_count != 16'd0) begin
                            guard_count <= guard_count - 16'd1;
                            ready_reg   <= 1'b0;
                        end else begin
                            ready_reg <= 1'b1;
                        end
                    end

                    default: begin
                        state   <= ST_IDLE;
                        pwm_reg <= 1'b0;
                    end
                endcase
            end
        end
    end

    assign o_pwm   = pwm_reg;
    assign o_ready = ready_reg;

endmodule

`default_nettype wire
