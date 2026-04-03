`default_nettype none

// FCSP IO engines wrapper (skeleton)
//
// Integrates lift/adapt points for:
// - DSHOT engine/mailbox path
// - PWM decode path
// - NeoPixel output path
//
// Control/status register semantics are expected to be exposed via SERV + IO windows.
module fcsp_io_engines #(
    parameter int MOTOR_COUNT = 4
) (
    input  logic                    clk,
    input  logic                    rst,

    // DSHOT controls (from SERV/IO window decode)
    input  logic                    i_dshot_update,
    input  logic [1:0]              i_dshot_mode_sel,   // 0:150, 1:300, 2:600, 3:1200
    input  logic [MOTOR_COUNT*16-1:0] i_dshot_words,
    output logic                    o_dshot_ready,

    // PWM decode inputs / outputs
    input  logic [MOTOR_COUNT-1:0]  i_pwm_in,
    output logic [MOTOR_COUNT*16-1:0] o_pwm_width_ticks,
    output logic [MOTOR_COUNT-1:0]  o_pwm_new_sample,

    // NeoPixel output controls
    input  logic                    i_neo_update,
    input  logic [23:0]             i_neo_rgb,
    output logic                    o_neo_busy,
    output logic                    o_neo_data
);
    // Placeholder tie-offs until legacy cores are imported and wired.
    // This keeps top-level integration moving while preserving IO contract.

    always_ff @(posedge clk) begin
        if (rst) begin
            o_dshot_ready     <= 1'b1;
            o_pwm_width_ticks <= '0;
            o_pwm_new_sample  <= '0;
            o_neo_busy        <= 1'b0;
            o_neo_data        <= 1'b0;
        end else begin
            // DSHOT ready is optimistic in scaffold mode.
            o_dshot_ready <= 1'b1;

            // PWM decode scaffold: no decode yet, pulses remain low.
            o_pwm_width_ticks <= '0;
            o_pwm_new_sample  <= '0;

            // NeoPixel scaffold: hold line low.
            o_neo_busy <= 1'b0;
            o_neo_data <= 1'b0;

            // Consume inputs to avoid unused warnings in strict flows.
            if (i_dshot_update || i_neo_update || (|i_pwm_in) || (|i_dshot_words) || (|i_dshot_mode_sel) || (|i_neo_rgb)) begin
                o_dshot_ready <= 1'b1;
            end
        end
    end
endmodule

`default_nettype wire
