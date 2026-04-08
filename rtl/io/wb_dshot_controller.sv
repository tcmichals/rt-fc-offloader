// Wishbone DSHOT Controller — 4-channel motor output
// Ported from legacy wb_dshot_controller.sv
//
// Supports runtime-selectable DSHOT150 / DSHOT300 / DSHOT600.
//
// Register Map (32-bit, word-aligned):
//   0x00: MOTOR1_VALUE [15:0] — raw 16-bit DSHOT word
//   0x04: MOTOR2_VALUE [15:0]
//   0x08: MOTOR3_VALUE [15:0]
//   0x0C: MOTOR4_VALUE [15:0]
//   0x10: STATUS [3:0] — per-motor ready bits (read-only)
//   0x14: CONFIG [15:0] — DSHOT speed (150/300/600)
//
// Source: /media/tcmichals/projects/Tang9K/HacksterIO/SPIQuadCopter/src/wb_dshot_controller.sv

`default_nettype none

module wb_dshot_controller #(
    parameter int CLK_FREQ_HZ  = 54_000_000,
    parameter int DEFAULT_MODE = 150
) (
    input  logic        clk,
    input  logic        rst,

    // Wishbone slave interface
    input  logic [31:0] wb_adr_i,
    input  logic [31:0] wb_dat_i,
    output logic [31:0] wb_dat_o,
    input  logic        wb_we_i,
    input  logic [3:0]  wb_sel_i,
    input  logic        wb_stb_i,
    input  logic        wb_cyc_i,
    output logic        wb_ack_o,

    // Motor DSHOT outputs
    output logic        motor1_o,
    output logic        motor2_o,
    output logic        motor3_o,
    output logic        motor4_o,

    // Ready signals
    output logic        motor1_ready,
    output logic        motor2_ready,
    output logic        motor3_ready,
    output logic        motor4_ready
);

    // Frequency validation
    generate
        if (CLK_FREQ_HZ < 10_000_000) begin : gen_freq_check
            initial $error("CLK_FREQ_HZ must be >= 10 MHz for DSHOT. Current: %0d Hz", CLK_FREQ_HZ);
        end
    endgenerate

    // Address decode (word-aligned)
    wire [3:0] addr = wb_adr_i[5:2];

    wire motor1_write = wb_cyc_i & wb_stb_i & wb_we_i & (addr == 4'h0);
    wire motor2_write = wb_cyc_i & wb_stb_i & wb_we_i & (addr == 4'h1);
    wire motor3_write = wb_cyc_i & wb_stb_i & wb_we_i & (addr == 4'h2);
    wire motor4_write = wb_cyc_i & wb_stb_i & wb_we_i & (addr == 4'h3);
    wire config_write = wb_cyc_i & wb_stb_i & wb_we_i & (addr == 4'h5);

    // Motor value registers and write strobes
    logic [15:0] motor1_value, motor2_value, motor3_value, motor4_value;
    logic [15:0] dshot_mode_reg;
    logic        motor1_strobe, motor2_strobe, motor3_strobe, motor4_strobe;

    // Wishbone single-cycle ack
    always_ff @(posedge clk) begin
        if (rst)
            wb_ack_o <= 1'b0;
        else
            wb_ack_o <= wb_cyc_i & wb_stb_i & ~wb_ack_o;
    end

    // Write registers
    always_ff @(posedge clk) begin
        if (rst) begin
            motor1_value  <= 16'h0;
            motor2_value  <= 16'h0;
            motor3_value  <= 16'h0;
            motor4_value  <= 16'h0;
            dshot_mode_reg <= DEFAULT_MODE[15:0];
            motor1_strobe <= 1'b0;
            motor2_strobe <= 1'b0;
            motor3_strobe <= 1'b0;
            motor4_strobe <= 1'b0;
        end else begin
            motor1_strobe <= 1'b0;
            motor2_strobe <= 1'b0;
            motor3_strobe <= 1'b0;
            motor4_strobe <= 1'b0;

            if (config_write)
                dshot_mode_reg <= wb_dat_i[15:0];

            if (motor1_write) begin
                motor1_value  <= wb_dat_i[15:0];
                motor1_strobe <= 1'b1;
            end
            if (motor2_write) begin
                motor2_value  <= wb_dat_i[15:0];
                motor2_strobe <= 1'b1;
            end
            if (motor3_write) begin
                motor3_value  <= wb_dat_i[15:0];
                motor3_strobe <= 1'b1;
            end
            if (motor4_write) begin
                motor4_value  <= wb_dat_i[15:0];
                motor4_strobe <= 1'b1;
            end
        end
    end

    // Read data mux
    always_ff @(posedge clk) begin
        if (rst) begin
            wb_dat_o <= 32'h0;
        end else begin
            case (addr)
                4'h0: wb_dat_o <= {16'h0, motor1_value};
                4'h1: wb_dat_o <= {16'h0, motor2_value};
                4'h2: wb_dat_o <= {16'h0, motor3_value};
                4'h3: wb_dat_o <= {16'h0, motor4_value};
                4'h4: wb_dat_o <= {28'h0, motor4_ready, motor3_ready, motor2_ready, motor1_ready};
                4'h5: wb_dat_o <= {16'h0, dshot_mode_reg};
                default: wb_dat_o <= 32'h0;
            endcase
        end
    end

    // Motor DSHOT output instances
    dshot_out #(.CLK_FREQ_HZ(CLK_FREQ_HZ)) u_motor1 (
        .clk(clk), .rst(rst),
        .i_dshot_value(motor1_value), .i_dshot_mode(dshot_mode_reg),
        .i_write(motor1_strobe), .o_pwm(motor1_o), .o_ready(motor1_ready)
    );

    dshot_out #(.CLK_FREQ_HZ(CLK_FREQ_HZ)) u_motor2 (
        .clk(clk), .rst(rst),
        .i_dshot_value(motor2_value), .i_dshot_mode(dshot_mode_reg),
        .i_write(motor2_strobe), .o_pwm(motor2_o), .o_ready(motor2_ready)
    );

    dshot_out #(.CLK_FREQ_HZ(CLK_FREQ_HZ)) u_motor3 (
        .clk(clk), .rst(rst),
        .i_dshot_value(motor3_value), .i_dshot_mode(dshot_mode_reg),
        .i_write(motor3_strobe), .o_pwm(motor3_o), .o_ready(motor3_ready)
    );

    dshot_out #(.CLK_FREQ_HZ(CLK_FREQ_HZ)) u_motor4 (
        .clk(clk), .rst(rst),
        .i_dshot_value(motor4_value), .i_dshot_mode(dshot_mode_reg),
        .i_write(motor4_strobe), .o_pwm(motor4_o), .o_ready(motor4_ready)
    );

    // Suppress unused-signal lint
    logic _unused;
    always_comb _unused = &{wb_sel_i, wb_adr_i[31:6], wb_adr_i[1:0], wb_dat_i[31:16]};

endmodule

`default_nettype wire
