// Wishbone PWM Decoder — 6-channel RC pulse width measurement
// Ported from legacy pwmdecoder_wb.v
//
// Register Map (read-only, 32-bit word-aligned):
//   0x00–0x14: PWM channel 0–5 value [15:0] (microseconds)
//   0x18:      Status [5:0] = per-channel ready flags
//
// Source: /media/tcmichals/projects/Tang9K/HacksterIO/SPIQuadCopter/pwmDecoder/pwmdecoder_wb.v

`default_nettype wire

module pwmdecoder_wb #(
    parameter int CLK_FREQ_HZ = 54_000_000
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

    // PWM input signals
    input  wire        i_pwm_0,
    input  wire        i_pwm_1,
    input  wire        i_pwm_2,
    input  wire        i_pwm_3,
    input  wire        i_pwm_4,
    input  wire        i_pwm_5
);

    // Internal signals
    logic        pwm_ready_0, pwm_ready_1, pwm_ready_2;
    logic        pwm_ready_3, pwm_ready_4, pwm_ready_5;
    logic [15:0] pwm_value_0, pwm_value_1, pwm_value_2;
    logic [15:0] pwm_value_3, pwm_value_4, pwm_value_5;

    wire [4:0] addr_bits = wb_adr_i[6:2];

    // Single-cycle ack
    always_ff @(posedge clk) begin
        if (rst) begin
            wb_dat_o <= 32'h0;
            wb_ack_o <= 1'b0;
        end else begin
            wb_ack_o <= wb_stb_i && wb_cyc_i && !wb_ack_o;

            if (wb_stb_i && wb_cyc_i && !wb_we_i) begin
                case (addr_bits)
                    5'h00: wb_dat_o <= {16'h0, pwm_value_0};
                    5'h01: wb_dat_o <= {16'h0, pwm_value_1};
                    5'h02: wb_dat_o <= {16'h0, pwm_value_2};
                    5'h03: wb_dat_o <= {16'h0, pwm_value_3};
                    5'h04: wb_dat_o <= {16'h0, pwm_value_4};
                    5'h05: wb_dat_o <= {16'h0, pwm_value_5};
                    5'h06: wb_dat_o <= {26'h0, pwm_ready_5, pwm_ready_4, pwm_ready_3,
                                               pwm_ready_2, pwm_ready_1, pwm_ready_0};
                    default: wb_dat_o <= 32'h0;
                endcase
            end
        end
    end

    // PWM decoder instances
    pwmdecoder #(.CLK_FREQ_HZ(CLK_FREQ_HZ)) u_ch0 (
        .clk(clk), .rst(rst), .i_pwm(i_pwm_0),
        .o_pwm_ready(pwm_ready_0), .o_pwm_value(pwm_value_0)
    );
    pwmdecoder #(.CLK_FREQ_HZ(CLK_FREQ_HZ)) u_ch1 (
        .clk(clk), .rst(rst), .i_pwm(i_pwm_1),
        .o_pwm_ready(pwm_ready_1), .o_pwm_value(pwm_value_1)
    );
    pwmdecoder #(.CLK_FREQ_HZ(CLK_FREQ_HZ)) u_ch2 (
        .clk(clk), .rst(rst), .i_pwm(i_pwm_2),
        .o_pwm_ready(pwm_ready_2), .o_pwm_value(pwm_value_2)
    );
    pwmdecoder #(.CLK_FREQ_HZ(CLK_FREQ_HZ)) u_ch3 (
        .clk(clk), .rst(rst), .i_pwm(i_pwm_3),
        .o_pwm_ready(pwm_ready_3), .o_pwm_value(pwm_value_3)
    );
    pwmdecoder #(.CLK_FREQ_HZ(CLK_FREQ_HZ)) u_ch4 (
        .clk(clk), .rst(rst), .i_pwm(i_pwm_4),
        .o_pwm_ready(pwm_ready_4), .o_pwm_value(pwm_value_4)
    );
    pwmdecoder #(.CLK_FREQ_HZ(CLK_FREQ_HZ)) u_ch5 (
        .clk(clk), .rst(rst), .i_pwm(i_pwm_5),
        .o_pwm_ready(pwm_ready_5), .o_pwm_value(pwm_value_5)
    );

    // Suppress unused-signal lint
    logic _unused;
    always_comb _unused = &{wb_dat_i, wb_sel_i, wb_we_i, wb_adr_i[31:7], wb_adr_i[1:0]};

endmodule

`default_nettype wire
