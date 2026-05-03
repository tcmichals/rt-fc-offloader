// Wishbone PWM Decoder — N-channel RC pulse width measurement
//
// Register Map (read-only, 32-bit word-aligned):
//   0x00–0x14: PWM channel 0–(N-1) value [15:0] (microseconds)
//   0x18:      Status [N-1:0] = per-channel ready flags
//
// Architecture: Shared Input Capture
// - Uses a single 1MHz global timer.
// - Each channel captures the timer on rising/falling edges.
// - Significantly reduces LUT usage compared to independent counters.

`default_nettype wire

module pwmdecoder_wb #(
    parameter int CLK_FREQ_HZ = 54_000_000,
    parameter int NUM_CHANNELS = 6
) (
    input  wire        clk,
    input  wire        rst,

    // Wishbone slave
    input  wire [31:0] wb_adr_i,
    input  wire [31:0] wb_dat_i,
    output logic [31:0] wb_dat_o,
    input  wire        wb_we_i,
    input  wire [3:0]  wb_sel_i,
    input  wire        wb_stb_i,
    input  wire        wb_cyc_i,
    output logic        wb_ack_o,

    // PWM input signals (Packed array)
    input  wire [NUM_CHANNELS-1:0] i_pwm
);

    // -----------------------------------------------------------------
    // Shared 1MHz Timebase
    // -----------------------------------------------------------------
    localparam int CLK_DIVIDER = (CLK_FREQ_HZ / 1_000_000) - 1;
    
    logic [15:0] tick_counter;
    logic        tick_1us;
    logic [15:0] global_timer;

    always_ff @(posedge clk) begin
        if (rst) begin
            tick_counter <= '0;
            tick_1us     <= 1'b0;
            global_timer <= '0;
        end else begin
            if (tick_counter >= CLK_DIVIDER[15:0]) begin
                tick_counter <= '0;
                tick_1us     <= 1'b1;
                global_timer <= global_timer + 16'd1;
            end else begin
                tick_counter <= tick_counter + 16'd1;
                tick_1us     <= 1'b0;
            end
        end
    end

    // -----------------------------------------------------------------
    // PWM Input Capture Channels
    // -----------------------------------------------------------------
    localparam logic [15:0] GUARD_TIME_ON_MAX  = 16'd2600;
    localparam logic [15:0] GUARD_TIME_ON_MIN  = 16'd750;
    localparam logic [15:0] GUARD_TIME_OFF_MAX = 16'd20000;
    localparam logic [15:0] GUARD_ERROR_LOW    = 16'hC000;
    localparam logic [15:0] GUARD_ERROR_HIGH   = 16'h8000;
    localparam logic [15:0] GUARD_ERROR_SHORT  = 16'h4000;

    logic [NUM_CHANNELS-1:0] pwm_ready_flags;
    logic [15:0]             pwm_values [0:NUM_CHANNELS-1];

    genvar i;
    generate
        for (i = 0; i < NUM_CHANNELS; i++) begin : gen_pwm_ch
            logic [1:0]  sync;
            logic [15:0] start_time;
            logic        measuring;
            logic [15:0] off_timer;

            always_ff @(posedge clk) begin
                if (rst) begin
                    sync          <= 2'b00;
                    start_time    <= '0;
                    measuring     <= 1'b0;
                    off_timer     <= '0;
                    pwm_ready_flags[i] <= 1'b0;
                    pwm_values[i]      <= GUARD_ERROR_LOW;
                end else begin
                    // 2-stage synchronizer
                    sync <= {sync[0], i_pwm[i]};
                    
                    // Default to ready=0 (pulse high for 1 cycle when new data arrives)
                    pwm_ready_flags[i] <= 1'b0;

                    // Edge detection logic
                    if (sync[1] == 1'b0 && sync[0] == 1'b1) begin
                        // Rising edge
                        start_time <= global_timer;
                        measuring  <= 1'b1;
                        off_timer  <= '0;
                    end else if (sync[1] == 1'b1 && sync[0] == 1'b0 && measuring) begin
                        // Falling edge
                        logic [15:0] delta;
                        delta = global_timer - start_time;
                        measuring <= 1'b0;
                        pwm_ready_flags[i] <= 1'b1;
                        
                        if (delta < GUARD_TIME_ON_MIN)
                            pwm_values[i] <= delta | GUARD_ERROR_SHORT;
                        else if (delta > GUARD_TIME_ON_MAX)
                            pwm_values[i] <= delta | GUARD_ERROR_HIGH;
                        else
                            pwm_values[i] <= delta;
                    end

                    // Timeout logic (Signal lost)
                    if (tick_1us) begin
                        if (sync[1] == 1'b0) begin
                            if (off_timer < GUARD_TIME_OFF_MAX) begin
                                off_timer <= off_timer + 16'd1;
                            end else if (off_timer == GUARD_TIME_OFF_MAX) begin
                                pwm_values[i] <= off_timer | GUARD_ERROR_LOW;
                                pwm_ready_flags[i] <= 1'b1;
                                off_timer <= off_timer + 16'd1; // prevent continuous strobing
                            end
                        end else begin
                            off_timer <= '0;
                        end
                    end
                end
            end
        end
    endgenerate

    // -----------------------------------------------------------------
    // Wishbone Read Multiplexer
    // -----------------------------------------------------------------
    wire [4:0] addr_bits = wb_adr_i[6:2];

    always_ff @(posedge clk) begin
        if (rst) begin
            wb_dat_o <= 32'h0;
            wb_ack_o <= 1'b0;
        end else begin
            wb_ack_o <= wb_stb_i && wb_cyc_i && !wb_ack_o;

            if (wb_stb_i && wb_cyc_i && !wb_we_i) begin
                if (addr_bits < NUM_CHANNELS) begin
                    // Read channel value
                    wb_dat_o <= {16'h0, pwm_values[addr_bits]};
                end else if (addr_bits == 5'h06) begin
                    // Read status flags (assume NUM_CHANNELS <= 32)
                    logic [31:0] padded_flags;
                    padded_flags = '0;
                    padded_flags[NUM_CHANNELS-1:0] = pwm_ready_flags;
                    wb_dat_o <= padded_flags;
                end else begin
                    wb_dat_o <= 32'h0;
                end
            end
        end
    end

    // Suppress unused-signal lint
    logic _unused;
    always_comb _unused = &{wb_dat_i, wb_sel_i, wb_we_i, wb_adr_i[31:7], wb_adr_i[1:0]};

endmodule

`default_nettype wire
