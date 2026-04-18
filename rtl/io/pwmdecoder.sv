// PWM Decoder — single-channel RC pulse width measurement
// Ported from legacy pwmdecoder.v
//
// Measures high-pulse width in microseconds with guard-time error detection.
//
// Source: /media/tcmichals/projects/Tang9K/HacksterIO/SPIQuadCopter/pwmDecoder/pwmdecoder.v

`default_nettype wire

module pwmdecoder #(
    parameter int CLK_FREQ_HZ = 54_000_000
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        i_pwm,
    output wire        o_pwm_ready,
    output logic [15:0] o_pwm_value
);

    localparam int CLK_DIVIDER = (CLK_FREQ_HZ / 1_000_000) - 1;

    localparam logic [15:0] GUARD_ERROR_LOW   = 16'hC000;  // No signal (timeout)
    localparam logic [15:0] GUARD_ERROR_HIGH  = 16'h8000;  // Pulse too long
    localparam logic [15:0] GUARD_ERROR_SHORT = 16'h4000;  // Pulse too short

    typedef enum logic [1:0] {
        MEASURING_OFF  = 2'd0,
        MEASURING_ON   = 2'd1,
        MEASURE_DONE   = 2'd2
    } state_t;

    localparam int GUARD_TIME_ON_MAX  = 2600;
    localparam int GUARD_TIME_ON_MIN  = 750;
    localparam int GUARD_TIME_OFF_MAX = 20000;

    state_t      state;
    logic [15:0] pwm_on_count;
    logic [15:0] pwm_off_count;
    logic [15:0] clk_counter;
    logic [1:0]  pwm_sync;
    logic        pwm_ready_reg;

    assign o_pwm_ready = pwm_ready_reg;

    always_ff @(posedge clk) begin
        if (rst) begin
            state         <= MEASURING_OFF;
            pwm_on_count  <= 16'd0;
            pwm_off_count <= 16'd0;
            clk_counter   <= 16'd0;
            pwm_sync      <= 2'b00;
            pwm_ready_reg <= 1'b0;
            o_pwm_value   <= GUARD_ERROR_LOW;
        end else begin
            // 2-FF synchronizer
            pwm_sync <= {pwm_sync[0], i_pwm};

            // Microsecond tick divider
            if (clk_counter < CLK_DIVIDER[15:0])
                clk_counter <= clk_counter + 16'd1;
            else
                clk_counter <= 16'd0;

            case (state)
                MEASURING_OFF: begin
                    if (pwm_sync[1] == 1'b0) begin
                        if (clk_counter == CLK_DIVIDER[15:0]) begin
                            if (pwm_off_count < GUARD_TIME_OFF_MAX[15:0])
                                pwm_off_count <= pwm_off_count + 16'd1;
                            else begin
                                o_pwm_value   <= pwm_off_count | GUARD_ERROR_LOW;
                                pwm_ready_reg <= 1'b1;
                                state         <= MEASURE_DONE;
                            end
                        end
                    end else begin
                        pwm_on_count  <= 16'd0;
                        pwm_ready_reg <= 1'b0;
                        state         <= MEASURING_ON;
                        clk_counter   <= 16'd0;
                    end
                end

                MEASURING_ON: begin
                    if (pwm_sync[1]) begin
                        if (clk_counter == CLK_DIVIDER[15:0]) begin
                            if (pwm_on_count < GUARD_TIME_ON_MAX[15:0])
                                pwm_on_count <= pwm_on_count + 16'd1;
                            else begin
                                state         <= MEASURE_DONE;
                                o_pwm_value   <= pwm_on_count | GUARD_ERROR_HIGH;
                                pwm_ready_reg <= 1'b1;
                            end
                        end
                    end else begin
                        pwm_ready_reg <= 1'b1;
                        state         <= MEASURE_DONE;
                        if (pwm_on_count < GUARD_TIME_ON_MIN[15:0])
                            o_pwm_value <= pwm_on_count | GUARD_ERROR_SHORT;
                        else
                            o_pwm_value <= pwm_on_count;
                    end
                end

                MEASURE_DONE: begin
                    clk_counter   <= 16'd0;
                    pwm_ready_reg <= 1'b0;
                    state         <= MEASURING_OFF;
                    pwm_on_count  <= 16'd0;
                    pwm_off_count <= 16'd0;
                end

                default: state <= MEASURING_OFF;
            endcase
        end
    end

endmodule

`default_nettype wire
