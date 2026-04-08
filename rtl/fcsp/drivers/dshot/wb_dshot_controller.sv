/**
 * Wishbone DSHOT Controller
 * 
 * 4-channel DSHOT motor controller with Wishbone B3 interface
 * Supports DSHOT150, DSHOT300, and DSHOT600 modes (runtime selectable)
 * 
 * Register Map (32-bit registers):
 *   0x00: MOTOR1_VALUE [15:0] - DSHOT value for motor 1
 *   0x04: MOTOR2_VALUE [15:0] - DSHOT value for motor 2
 *   0x08: MOTOR3_VALUE [15:0] - DSHOT value for motor 3
 *   0x0C: MOTOR4_VALUE [15:0] - DSHOT value for motor 4
 *   0x10: STATUS [3:0] - Ready status bits (read-only)
 *         bit[0] = motor1_ready
 *         bit[1] = motor2_ready
 *         bit[2] = motor3_ready
 *         bit[3] = motor4_ready
 *   0x14: CONFIG [15:0] - Configuration register
 *         bit[15:0] = dshot_mode (150, 300, or 600)
 *         Read returns current mode setting
 * 
 * DSHOT Protocol:
 *   16-bit frame format:
 *   [15:5]  = 11-bit throttle value (0-2047)
 *   [4]     = telemetry request bit
 *   [3:0]   = 4-bit CRC checksum
 * 
 * Notes:
 *   - Supports DSHOT150 (6.67us bit), DSHOT300 (3.33us bit), DSHOT600 (1.67us bit)
 *   - Default mode is DSHOT150
 *   - Write to CONFIG register changes mode for all motors
 *   - 72 MHz clock recommended
 *   - Write triggers immediate transmission
 *   - Guard time prevents rapid updates
 */

`default_nettype none

module wb_dshot_controller #(
    parameter CLK_FREQ_HZ = 54_000_000,  // 54 MHz system clock
    parameter GUARD_TIME = 18000,        // ~250us @ 72MHz
    parameter DEFAULT_MODE = 150         // Default DSHOT mode (150, 300, or 600)
) (
    // Wishbone slave interface
    input  wire        wb_clk_i,
    input  wire        wb_rst_i,
    input  wire [31:0] wb_dat_i,
    input  wire [31:0] wb_adr_i,
    input  wire        wb_we_i,
    input  wire [3:0]  wb_sel_i,
    input  wire        wb_stb_i,
    input  wire        wb_cyc_i,
    output reg  [31:0] wb_dat_o,
    output reg         wb_ack_o,
    output wire        wb_stall_o,

    // DSHOT motor outputs
    output wire        motor1_o,
    output wire        motor2_o,
    output wire        motor3_o,
    output wire        motor4_o,
    output wire        dshot_tx,  // Shared output for mux
    
    // Ready signals
    output wire        motor1_ready,
    output wire        motor2_ready,
    output wire        motor3_ready,
    output wire        motor4_ready
);

    // Frequency validation - minimum 10 MHz required for accurate DSHOT timing
    generate
        if (CLK_FREQ_HZ < 10_000_000) begin
            $error("CLK_FREQ_HZ must be >= 10 MHz for DSHOT timing. Current: %0d Hz", CLK_FREQ_HZ);
        end
    endgenerate

    // Address decode
    wire [3:0] addr = wb_adr_i[5:2];  // Word-aligned addresses
    
    // Register enables
    wire motor1_write = wb_cyc_i & wb_stb_i & wb_we_i & (addr == 4'h0);
    wire motor2_write = wb_cyc_i & wb_stb_i & wb_we_i & (addr == 4'h1);
    wire motor3_write = wb_cyc_i & wb_stb_i & wb_we_i & (addr == 4'h2);
    wire motor4_write = wb_cyc_i & wb_stb_i & wb_we_i & (addr == 4'h3);
    wire status_read  = wb_cyc_i & wb_stb_i & ~wb_we_i & (addr == 4'h4);
    wire config_write = wb_cyc_i & wb_stb_i & wb_we_i & (addr == 4'h5);
    wire config_read  = wb_cyc_i & wb_stb_i & ~wb_we_i & (addr == 4'h5);

    // DSHOT values and write strobes
    reg [15:0] motor1_value;
    reg [15:0] motor2_value;
    reg [15:0] motor3_value;
    reg [15:0] motor4_value;
    
    // Configuration register - DSHOT mode selection
    reg [15:0] dshot_mode_reg;
    
    reg motor1_write_strobe;
    reg motor2_write_strobe;
    reg motor3_write_strobe;
    reg motor4_write_strobe;

    // Wishbone acknowledge - single cycle
    always @(posedge wb_clk_i) begin
        if (wb_rst_i)
            wb_ack_o <= 1'b0;
        else
            wb_ack_o <= wb_cyc_i & wb_stb_i & ~wb_ack_o;
    end

    // No stall signal needed
    assign wb_stall_o = 1'b0;

    // Write registers and generate strobes
    always @(posedge wb_clk_i) begin
        if (wb_rst_i) begin
            motor1_value <= 16'h0;
            motor2_value <= 16'h0;
            motor3_value <= 16'h0;
            motor4_value <= 16'h0;
            dshot_mode_reg <= DEFAULT_MODE;  // Initialize to default mode
            motor1_write_strobe <= 1'b0;
            motor2_write_strobe <= 1'b0;
            motor3_write_strobe <= 1'b0;
            motor4_write_strobe <= 1'b0;
        end else begin
            // Clear strobes by default
            motor1_write_strobe <= 1'b0;
            motor2_write_strobe <= 1'b0;
            motor3_write_strobe <= 1'b0;
            motor4_write_strobe <= 1'b0;

            // Configuration register
            if (config_write) begin
                dshot_mode_reg <= wb_dat_i[15:0];
            end

            // Motor 1
            if (motor1_write) begin
                motor1_value <= wb_dat_i[15:0];
                motor1_write_strobe <= 1'b1;
            end

            // Motor 2
            if (motor2_write) begin
                motor2_value <= wb_dat_i[15:0];
                motor2_write_strobe <= 1'b1;
            end

            // Motor 3
            if (motor3_write) begin
                motor3_value <= wb_dat_i[15:0];
                motor3_write_strobe <= 1'b1;
            end

            // Motor 4
            if (motor4_write) begin
                motor4_value <= wb_dat_i[15:0];
                motor4_write_strobe <= 1'b1;
            end
        end
    end

    // Read data mux
    always @(posedge wb_clk_i) begin
        if (wb_rst_i) begin
            wb_dat_o <= 32'h0;
        end else begin
            case (addr)
                4'h0: wb_dat_o <= {16'h0, motor1_value};
                4'h1: wb_dat_o <= {16'h0, motor2_value};
                4'h2: wb_dat_o <= {16'h0, motor3_value};
                4'h3: wb_dat_o <= {16'h0, motor4_value};
                4'h4: wb_dat_o <= {28'h0, motor4_ready, motor3_ready, motor2_ready, motor1_ready};  // Status: ready bits
                4'h5: wb_dat_o <= {16'h0, dshot_mode_reg};  // Config register - read current mode
                default: wb_dat_o <= 32'h0;
            endcase
        end
    end

    // Instantiate DSHOT output modules - mode is runtime configurable via dshot_mode_reg
    dshot_output #(
        .clockFrequency(CLK_FREQ_HZ)
    ) dshot_motor1 (
        .i_clk(wb_clk_i),
        .i_reset(wb_rst_i),
        .i_dshot_value(motor1_value),
        .i_dshot_mode(dshot_mode_reg),  // Runtime mode selection
        .i_write(motor1_write_strobe),
        .o_pwm(motor1_o),
        .o_ready(motor1_ready)
    );

    // For shared line, use motor1's DSHOT output as dshot_tx (can be changed as needed)
    assign dshot_tx = motor1_o;

    dshot_output #(
        .clockFrequency(CLK_FREQ_HZ)
    ) dshot_motor2 (
        .i_clk(wb_clk_i),
        .i_reset(wb_rst_i),
        .i_dshot_value(motor2_value),
        .i_dshot_mode(dshot_mode_reg),  // Runtime mode selection
        .i_write(motor2_write_strobe),
        .o_pwm(motor2_o),
        .o_ready(motor2_ready)
    );

    dshot_output #(
        .clockFrequency(CLK_FREQ_HZ)
    ) dshot_motor3 (
        .i_clk(wb_clk_i),
        .i_reset(wb_rst_i),
        .i_dshot_value(motor3_value),
        .i_dshot_mode(dshot_mode_reg),  // Runtime mode selection
        .i_write(motor3_write_strobe),
        .o_pwm(motor3_o),
        .o_ready(motor3_ready)
    );

    dshot_output #(
        .clockFrequency(CLK_FREQ_HZ)
    ) dshot_motor4 (
        .i_clk(wb_clk_i),
        .i_reset(wb_rst_i),
        .i_dshot_value(motor4_value),
        .i_dshot_mode(dshot_mode_reg),  // Runtime mode selection
        .i_write(motor4_write_strobe),
        .o_pwm(motor4_o),
        .o_ready(motor4_ready)
    );

endmodule

`default_nettype wire
