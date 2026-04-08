`default_nettype none

// FCSP IO engines — production integration.
//
// Instantiates wb_io_bus and all real IO peripheral slaves:
//   - wb_dshot_controller  (4-channel DShot motor output)
//   - wb_serial_dshot_mux  (pin mux with MSP sniffer)
//   - wb_neoPx             (8-pixel NeoPixel controller)
//   - wb_esc_uart          (half-duplex ESC serial)
//   - pwmdecoder_wb        (6-channel PWM decoder)
//
// Wishbone master port connects to fcsp_wishbone_master via the top level.
module fcsp_io_engines #(
    parameter int CLK_FREQ_HZ   = 54_000_000,
    parameter int NEO_LED_TYPE  = 0   // 0=WS2812, 1=SK6812
) (
    input  logic        clk,
    input  logic        rst,

    // Wishbone master interface (from fcsp_wishbone_master)
    input  logic [31:0] wb_adr_i,
    input  logic [31:0] wb_dat_i,
    output logic [31:0] wb_dat_o,
    input  logic [3:0]  wb_sel_i,
    input  logic        wb_we_i,
    input  logic        wb_cyc_i,
    input  logic        wb_stb_i,
    output logic        wb_ack_o,

    // Motor pads (bidirectional)
    inout  wire  [3:0]  pad_motor,

    // NeoPixel serial output
    output logic        o_neo_data,

    // PWM input pins (directly from board)
    input  logic        i_pwm_0,
    input  logic        i_pwm_1,
    input  logic        i_pwm_2,
    input  logic        i_pwm_3,
    input  logic        i_pwm_4,
    input  logic        i_pwm_5,

    // PC sniffer feed (from USB-UART RX path)
    input  logic [7:0]  pc_rx_data,
    input  logic        pc_rx_valid,

    // ESC UART half-duplex (directly to/from mux)
    // (internal wiring; exposed here only for optional external debug taps)
    output logic        o_esc_tx_active,

    // ESC UART stream interface (FCSP CH 0x05 passthrough)
    input  logic [7:0]  s_esc_tdata,
    input  logic        s_esc_tvalid,
    output logic        s_esc_tready,
    output logic [7:0]  m_esc_tdata,
    output logic        m_esc_tvalid,
    input  logic        m_esc_tready,

    // LED controller slave (directly wired to wb_io_bus)
    // LED slave WB signals exposed for external LED controller hookup
    output logic [31:0] led_adr_o,
    output logic [31:0] led_dat_o,
    input  logic [31:0] led_dat_i,
    output logic [3:0]  led_sel_o,
    output logic        led_we_o,
    output logic        led_cyc_o,
    output logic        led_stb_o,
    input  logic        led_ack_i
);

    // ─── Internal WB wires: DShot ───────────────────────────────────
    logic [31:0] dshot_adr, dshot_wdat, dshot_rdat;
    logic [3:0]  dshot_sel;
    logic        dshot_we, dshot_cyc, dshot_stb, dshot_ack;

    // ─── Internal WB wires: Mux ─────────────────────────────────────
    logic [31:0] mux_adr, mux_wdat, mux_rdat;
    logic [3:0]  mux_sel;
    logic        mux_we, mux_cyc, mux_stb, mux_ack;

    // ─── Internal WB wires: NeoPixel ────────────────────────────────
    logic [31:0] neo_adr, neo_wdat, neo_rdat;
    logic [3:0]  neo_sel;
    logic        neo_we, neo_cyc, neo_stb, neo_ack;

    // ─── Internal WB wires: ESC UART ────────────────────────────────
    logic [3:0]  esc_adr;
    logic [31:0] esc_wdat, esc_rdat;
    logic        esc_we, esc_cyc, esc_stb, esc_ack;

    // ─── Internal WB wires: PWM decoder ─────────────────────────────
    logic [31:0] pwm_adr, pwm_wdat, pwm_rdat;
    logic [3:0]  pwm_sel;
    logic        pwm_we, pwm_cyc, pwm_stb, pwm_ack;

    // ─── Address decoder / bus mux ──────────────────────────────────
    wb_io_bus u_bus (
        .clk        (clk),
        .rst        (rst),
        .wbm_adr_i  (wb_adr_i),
        .wbm_dat_i  (wb_dat_i),
        .wbm_dat_o  (wb_dat_o),
        .wbm_sel_i  (wb_sel_i),
        .wbm_we_i   (wb_we_i),
        .wbm_cyc_i  (wb_cyc_i),
        .wbm_stb_i  (wb_stb_i),
        .wbm_ack_o  (wb_ack_o),
        // DShot
        .dshot_adr_o (dshot_adr),  .dshot_dat_o (dshot_wdat), .dshot_dat_i (dshot_rdat),
        .dshot_sel_o (dshot_sel),  .dshot_we_o  (dshot_we),   .dshot_cyc_o (dshot_cyc),
        .dshot_stb_o (dshot_stb),  .dshot_ack_i (dshot_ack),
        // Mux
        .mux_adr_o   (mux_adr),   .mux_dat_o   (mux_wdat),  .mux_dat_i   (mux_rdat),
        .mux_sel_o   (mux_sel),   .mux_we_o    (mux_we),    .mux_cyc_o   (mux_cyc),
        .mux_stb_o   (mux_stb),   .mux_ack_i   (mux_ack),
        // NeoPixel
        .neo_adr_o   (neo_adr),   .neo_dat_o   (neo_wdat),  .neo_dat_i   (neo_rdat),
        .neo_sel_o   (neo_sel),   .neo_we_o    (neo_we),    .neo_cyc_o   (neo_cyc),
        .neo_stb_o   (neo_stb),   .neo_ack_i   (neo_ack),
        // ESC UART
        .esc_adr_o   (esc_adr),   .esc_dat_o   (esc_wdat),  .esc_dat_i   (esc_rdat),
        .esc_we_o    (esc_we),    .esc_cyc_o   (esc_cyc),
        .esc_stb_o   (esc_stb),   .esc_ack_i   (esc_ack),
        // PWM decoder
        .pwm_adr_o   (pwm_adr),   .pwm_dat_o   (pwm_wdat),  .pwm_dat_i   (pwm_rdat),
        .pwm_sel_o   (pwm_sel),   .pwm_we_o    (pwm_we),    .pwm_cyc_o   (pwm_cyc),
        .pwm_stb_o   (pwm_stb),   .pwm_ack_i   (pwm_ack),
        // LED controller (exposed externally)
        .led_adr_o   (led_adr_o), .led_dat_o   (led_dat_o), .led_dat_i   (led_dat_i),
        .led_sel_o   (led_sel_o), .led_we_o    (led_we_o),  .led_cyc_o   (led_cyc_o),
        .led_stb_o   (led_stb_o), .led_ack_i   (led_ack_i)
    );

    // ─── DShot controller ───────────────────────────────────────────
    logic [3:0] motor_out;
    logic [3:0] motor_ready;

    wb_dshot_controller #(
        .CLK_FREQ_HZ  (CLK_FREQ_HZ),
        .DEFAULT_MODE  (150)
    ) u_dshot (
        .clk          (clk),
        .rst          (rst),
        .wb_adr_i     (dshot_adr),
        .wb_dat_i     (dshot_wdat),
        .wb_dat_o     (dshot_rdat),
        .wb_we_i      (dshot_we),
        .wb_sel_i     (dshot_sel),
        .wb_stb_i     (dshot_stb),
        .wb_cyc_i     (dshot_cyc),
        .wb_ack_o     (dshot_ack),
        .motor1_o     (motor_out[0]),
        .motor2_o     (motor_out[1]),
        .motor3_o     (motor_out[2]),
        .motor4_o     (motor_out[3]),
        .motor1_ready (motor_ready[0]),
        .motor2_ready (motor_ready[1]),
        .motor3_ready (motor_ready[2]),
        .motor4_ready (motor_ready[3])
    );

    // ─── ESC UART ───────────────────────────────────────────────────
    logic esc_tx_out, esc_rx_in, esc_tx_act;

    wb_esc_uart #(
        .CLK_FREQ_HZ (CLK_FREQ_HZ)
    ) u_esc_uart (
        .clk          (clk),
        .rst          (rst),
        .wb_adr_i     (esc_adr),
        .wb_dat_i     (esc_wdat),
        .wb_dat_o     (esc_rdat),
        .wb_we_i      (esc_we),
        .wb_stb_i     (esc_stb),
        .wb_cyc_i     (esc_cyc),
        .wb_ack_o     (esc_ack),
        .tx_out       (esc_tx_out),
        .rx_in        (esc_rx_in),
        .tx_active    (esc_tx_act),
        .s_esc_tdata  (s_esc_tdata),
        .s_esc_tvalid (s_esc_tvalid),
        .s_esc_tready (s_esc_tready),
        .m_esc_tdata  (m_esc_tdata),
        .m_esc_tvalid (m_esc_tvalid),
        .m_esc_tready (m_esc_tready)
    );

    assign o_esc_tx_active = esc_tx_act;

    // ─── Serial/DShot Pin Mux ───────────────────────────────────────
    logic        mux_sel_out;
    logic [1:0]  mux_ch_out;
    logic        mux_msp_mode;
    logic        mux_serial_rx;

    wb_serial_dshot_mux #(
        .CLK_FREQ_HZ (CLK_FREQ_HZ)
    ) u_mux (
        .clk          (clk),
        .rst          (rst),
        .wb_dat_i     (mux_wdat),
        .wb_adr_i     (mux_adr),
        .wb_we_i      (mux_we),
        .wb_sel_i     (mux_sel),
        .wb_stb_i     (mux_stb),
        .wb_cyc_i     (mux_cyc),
        .wb_dat_o     (mux_rdat),
        .wb_ack_o     (mux_ack),
        .mux_sel      (mux_sel_out),
        .mux_ch       (mux_ch_out),
        .msp_mode     (mux_msp_mode),
        .pc_rx_data   (pc_rx_data),
        .pc_rx_valid  (pc_rx_valid),
        .pad_motor    (pad_motor),
        .dshot_in     (motor_out),
        .serial_tx_i  (esc_tx_out),
        .serial_oe_i  (esc_tx_act),
        .serial_rx_o  (mux_serial_rx)
    );

    // Feed mux RX back into ESC UART
    assign esc_rx_in = mux_serial_rx;

    // ─── Suppress Verilator warnings for status outputs not yet consumed ─
    logic _unused_ok = &{1'b0, motor_ready, mux_sel_out, mux_ch_out, mux_msp_mode, 1'b0};

    // ─── NeoPixel ───────────────────────────────────────────────────
    wb_neoPx #(
        .CLK_FREQ_HZ (CLK_FREQ_HZ),
        .LED_TYPE     (NEO_LED_TYPE)
    ) u_neopx (
        .clk       (clk),
        .rst       (rst),
        .wb_adr_i  (neo_adr),
        .wb_dat_i  (neo_wdat),
        .wb_dat_o  (neo_rdat),
        .wb_we_i   (neo_we),
        .wb_sel_i  (neo_sel),
        .wb_stb_i  (neo_stb),
        .wb_cyc_i  (neo_cyc),
        .wb_ack_o  (neo_ack),
        .o_serial  (o_neo_data)
    );

    // ─── PWM Decoder ────────────────────────────────────────────────
    pwmdecoder_wb #(
        .CLK_FREQ_HZ (CLK_FREQ_HZ)
    ) u_pwm (
        .clk       (clk),
        .rst       (rst),
        .wb_adr_i  (pwm_adr),
        .wb_dat_i  (pwm_wdat),
        .wb_dat_o  (pwm_rdat),
        .wb_we_i   (pwm_we),
        .wb_sel_i  (pwm_sel),
        .wb_stb_i  (pwm_stb),
        .wb_cyc_i  (pwm_cyc),
        .wb_ack_o  (pwm_ack),
        .i_pwm_0   (i_pwm_0),
        .i_pwm_1   (i_pwm_1),
        .i_pwm_2   (i_pwm_2),
        .i_pwm_3   (i_pwm_3),
        .i_pwm_4   (i_pwm_4),
        .i_pwm_5   (i_pwm_5)
    );

endmodule

`default_nettype wire
