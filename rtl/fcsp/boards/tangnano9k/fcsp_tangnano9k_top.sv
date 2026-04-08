`default_nettype none

// Tang Nano 9K board wrapper for FCSP offloader top.
//
// Notes:
// - This wrapper is for board bring-up/programming flow.
// - USB-UART pins are adapted through a simple UART byte-stream shim and
//   connected to fcsp_offloader_top USB seams.
module fcsp_tangnano9k_top (
    input  logic i_clk,
    input  logic i_rst_n,

    // SPI host link
    input  logic i_spi_clk,
    input  logic i_spi_cs_n,
    input  logic i_spi_mosi,
    output logic o_spi_miso,

    // On-board LEDs
    output logic o_led_1,
    output logic o_led_2,
    output logic o_led_3,
    output logic o_led_4,
    output logic o_led_5,
    output logic o_led_6,

    // USB UART pins
    input  logic i_usb_uart_rx,
    output logic o_usb_uart_tx,

    // PWM inputs
    input  logic i_pwm_ch0,
    input  logic i_pwm_ch1,
    input  logic i_pwm_ch2,
    input  logic i_pwm_ch3,
    input  logic i_pwm_ch4,
    input  logic i_pwm_ch5,

    // Motor pins (bidirectional for 1-wire serial)
    inout  wire o_motor1,
    inout  wire o_motor2,
    inout  wire o_motor3,
    inout  wire o_motor4,

    // NeoPixel output
    output logic o_neopixel,

    // Debug pins
    output logic o_debug_0,
    output logic o_debug_1,
    output logic o_debug_2
);
    localparam int BOARD_LED_COUNT = 6;
    localparam int TRAFFIC_LED_COUNT = 2;
    parameter int LED_WIDTH = 4;
    parameter int SYS_CLK_HZ = 54_000_000;
    parameter int HEARTBEAT_HZ = 2;
    parameter int TRAFFIC_LED_HOLD_MS = 100;

    initial begin
        if (LED_WIDTH < 0 || LED_WIDTH > (BOARD_LED_COUNT - TRAFFIC_LED_COUNT)) begin
            $error("LED_WIDTH must be in range [0,%0d], got %0d",
                   BOARD_LED_COUNT - TRAFFIC_LED_COUNT, LED_WIDTH);
        end
        if (SYS_CLK_HZ <= 0) begin
            $error("SYS_CLK_HZ must be > 0, got %0d", SYS_CLK_HZ);
        end
        if (HEARTBEAT_HZ <= 0) begin
            $error("HEARTBEAT_HZ must be > 0, got %0d", HEARTBEAT_HZ);
        end
        if (TRAFFIC_LED_HOLD_MS < 0) begin
            $error("TRAFFIC_LED_HOLD_MS must be >= 0, got %0d", TRAFFIC_LED_HOLD_MS);
        end
    end

    logic rst;
    assign rst = ~i_rst_n;

    logic usb_rx_valid;
    logic [7:0] usb_rx_byte;
    logic usb_rx_ready;
    logic usb_tx_valid;
    logic [7:0] usb_tx_byte;
    logic usb_tx_ready;

    logic [7:0] debug_leds_internal;
    logic ctrl_tx_overflow;
    logic ctrl_tx_frame_seen;

    logic dbg_tx_tvalid;
    logic [7:0] dbg_tx_tdata;
    logic dbg_tx_tlast;
    logic dbg_tx_tready;
    logic [7:0] dbg_tx_channel;
    logic [7:0] dbg_tx_flags;
    logic [15:0] dbg_tx_seq;

    logic parser_sync_seen;
    logic parser_header_valid;
    logic parser_len_error;
    logic parser_frame_done;
    logic dbg_tx_overflow;
    logic dbg_tx_frame_seen;

    logic sys_clk;

    // Visible activity indicators: hold LEDs on briefly after each event.
    localparam int TRAFFIC_LED_HOLD_CYCLES_RAW = (SYS_CLK_HZ / 1000) * TRAFFIC_LED_HOLD_MS;
    localparam int TRAFFIC_LED_HOLD_CYCLES =
        (TRAFFIC_LED_HOLD_CYCLES_RAW < 1) ? 1 : TRAFFIC_LED_HOLD_CYCLES_RAW;
    localparam int TRAFFIC_LED_CNT_W = (TRAFFIC_LED_HOLD_CYCLES <= 1)
                                     ? 1 : $clog2(TRAFFIC_LED_HOLD_CYCLES);

    logic [TRAFFIC_LED_CNT_W-1:0] spi_led_hold_cnt;
    logic [TRAFFIC_LED_CNT_W-1:0] serial_led_hold_cnt;
    logic spi_led_on;
    logic serial_led_on;

    logic spi_clk_meta;
    logic spi_clk_sync;
    logic spi_clk_prev;
    logic spi_cs_meta;
    logic spi_cs_sync;
    logic spi_traffic_event;
    logic serial_traffic_event;
    logic [BOARD_LED_COUNT-TRAFFIC_LED_COUNT-1:0] wb_status_leds;

    localparam int HEARTBEAT_HALF_PERIOD_CYCLES_RAW = SYS_CLK_HZ / (2 * HEARTBEAT_HZ);
    localparam int HEARTBEAT_HALF_PERIOD_CYCLES =
        (HEARTBEAT_HALF_PERIOD_CYCLES_RAW < 1) ? 1 : HEARTBEAT_HALF_PERIOD_CYCLES_RAW;
    localparam int HEARTBEAT_CNT_W = (HEARTBEAT_HALF_PERIOD_CYCLES <= 1)
                                   ? 1 : $clog2(HEARTBEAT_HALF_PERIOD_CYCLES);
    logic [HEARTBEAT_CNT_W-1:0] heartbeat_cnt;
    logic heartbeat_led_on;
    
    // rPLL for ~54 MHz (27MHz * 2 / 1 = 54 MHz)
    rPLL #(
        .FCLKIN("27"),
        .IDIV_SEL(0),
        .FBDIV_SEL(1),
        .ODIV_SEL(8),
        .DYN_IDIV_SEL("false"),
        .DYN_FBDIV_SEL("false"),
        .DYN_ODIV_SEL("false"),
        .DYN_SDIV_SEL(2),
        .DEVICE("GW1NR-9C")
    ) u_pll (
        .CLKIN(i_clk),
        .CLKFB(1'b0),
        .RESET(~i_rst_n),
        .RESET_P(1'b0),
        .FBDSEL(6'b000000),
        .IDSEL(6'b000000),
        .ODSEL(6'b000000),
        .PSDA(4'b0000),
        .DUTYDA(4'b0000),
        .FDLY(4'b0000),
        .CLKOUT(sys_clk),
        .LOCK(),
        .CLKOUTP(),
        .CLKOUTD(),
        .CLKOUTD3()
    );

    // UART shim connects physical USB-UART pins to offloader USB byte seam.
    fcsp_uart_byte_stream #(
        .CLK_HZ(SYS_CLK_HZ),
        .BAUD(1_000_000)
    ) u_usb_uart (
        .clk       (sys_clk),
        .rst       (rst),
        .i_uart_rx (i_usb_uart_rx),
        .o_uart_tx (o_usb_uart_tx),
        .i_tx_valid(usb_tx_valid),
        .i_tx_byte (usb_tx_byte),
        .o_tx_ready(usb_tx_ready),
        .o_rx_valid(usb_rx_valid),
        .o_rx_byte (usb_rx_byte),
        .i_rx_ready(usb_rx_ready)
    );

    // -------------------------------------------------------------------
    // Hardware FCSP control path:
    //   fcsp_wishbone_master now lives inside fcsp_offloader_top and
    //   drives wb_io_bus → IO engines directly.
    //   LED controller is the only peripheral outside the offloader.
    // -------------------------------------------------------------------

    // LED controller pass-through from IO engines
    logic [31:0] led_adr;
    logic [31:0] led_dat_o;
    logic [31:0] led_dat_i;
    logic [3:0]  led_sel;
    logic        led_we;
    logic        led_cyc;
    logic        led_stb;
    logic        led_ack;
    logic [3:0]  led_reg_out;

    wb_led_controller #(
        .LED_WIDTH   (4),
        .LED_POLARITY(0)
    ) u_led_ctrl (
        .clk       (sys_clk),
        .rst       (rst),
        .wbs_adr_i (led_adr),
        .wbs_dat_i (led_dat_o),
        .wbs_dat_o (led_dat_i),
        .wbs_we_i  (led_we),
        .wbs_sel_i (led_sel),
        .wbs_stb_i (led_stb),
        .wbs_ack_o (led_ack),
        .wbs_err_o (),
        .wbs_rty_o (),
        .wbs_cyc_i (led_cyc),
        .led_out   (led_reg_out)
    );

    // ESC TX active status
    logic esc_tx_active;

    assign dbg_tx_tvalid = 1'b0;
    assign dbg_tx_tdata = 8'h00;
    assign dbg_tx_tlast = 1'b0;
    assign dbg_tx_channel = 8'h00;
    assign dbg_tx_flags = 8'h00;
    assign dbg_tx_seq = 16'h0000;

    fcsp_offloader_top #(
        .MAX_PAYLOAD_LEN(256),
        .CLK_FREQ_HZ(SYS_CLK_HZ)
    ) u_top (
        .clk(sys_clk),
        .rst(rst),
        .i_spi_sclk(i_spi_clk),
        .i_spi_cs_n(i_spi_cs_n),
        .i_spi_mosi(i_spi_mosi),
        .o_spi_miso(o_spi_miso),
        .i_usb_rx_valid(usb_rx_valid),
        .i_usb_rx_byte(usb_rx_byte),
        .o_usb_rx_ready(usb_rx_ready),
        .o_usb_tx_valid(usb_tx_valid),
        .o_usb_tx_byte(usb_tx_byte),
        .i_usb_tx_ready(usb_tx_ready),
        .s_dbg_tx_tvalid(dbg_tx_tvalid),
        .s_dbg_tx_tdata(dbg_tx_tdata),
        .s_dbg_tx_tlast(dbg_tx_tlast),
        .s_dbg_tx_tready(dbg_tx_tready),
        .s_dbg_tx_channel(dbg_tx_channel),
        .s_dbg_tx_flags(dbg_tx_flags),
        .s_dbg_tx_seq(dbg_tx_seq),
        // Motor pads (bidirectional)
        .pad_motor({o_motor4, o_motor3, o_motor2, o_motor1}),
        // NeoPixel
        .o_neo_data(o_neopixel),
        // PWM inputs
        .i_pwm_0(i_pwm_ch0),
        .i_pwm_1(i_pwm_ch1),
        .i_pwm_2(i_pwm_ch2),
        .i_pwm_3(i_pwm_ch3),
        .i_pwm_4(i_pwm_ch4),
        .i_pwm_5(i_pwm_ch5),
        // PC sniffer (tap the USB UART RX stream)
        .pc_rx_data(usb_rx_byte),
        .pc_rx_valid(usb_rx_valid),
        // ESC status
        .o_esc_tx_active(esc_tx_active),
        // LED controller pass-through
        .led_adr_o(led_adr),
        .led_dat_o(led_dat_o),
        .led_dat_i(led_dat_i),
        .led_sel_o(led_sel),
        .led_we_o(led_we),
        .led_cyc_o(led_cyc),
        .led_stb_o(led_stb),
        .led_ack_i(led_ack),
        // Status
        .o_parser_sync_seen(parser_sync_seen),
        .o_parser_header_valid(parser_header_valid),
        .o_parser_len_error(parser_len_error),
        .o_parser_frame_done(parser_frame_done),
        .o_ctrl_tx_overflow(ctrl_tx_overflow),
        .o_ctrl_tx_frame_seen(ctrl_tx_frame_seen),
        .o_dbg_tx_overflow(dbg_tx_overflow),
        .o_dbg_tx_frame_seen(dbg_tx_frame_seen)
    );

    assign debug_leds_internal = {
        dbg_tx_frame_seen,
        dbg_tx_overflow,
        ctrl_tx_frame_seen,
        ctrl_tx_overflow,
        parser_frame_done,
        parser_len_error,
        parser_header_valid,
        parser_sync_seen
    };

    // SPI traffic event detector (edge on SCLK while CS is asserted low).
    always_ff @(posedge sys_clk) begin
        if (rst) begin
            spi_clk_meta <= 1'b0;
            spi_clk_sync <= 1'b0;
            spi_clk_prev <= 1'b0;
            spi_cs_meta  <= 1'b1;
            spi_cs_sync  <= 1'b1;
        end else begin
            spi_clk_meta <= i_spi_clk;
            spi_clk_sync <= spi_clk_meta;
            spi_clk_prev <= spi_clk_sync;
            spi_cs_meta  <= i_spi_cs_n;
            spi_cs_sync  <= spi_cs_meta;
        end
    end

    assign spi_traffic_event = (~spi_cs_sync) && (spi_clk_sync ^ spi_clk_prev);
    assign serial_traffic_event = (usb_rx_valid && usb_rx_ready)
                               || (usb_tx_valid && usb_tx_ready);

    // Pulse-stretch logic for human-visible LED activity.
    always_ff @(posedge sys_clk) begin
        if (rst) begin
            spi_led_hold_cnt <= '0;
            serial_led_hold_cnt <= '0;
            heartbeat_cnt <= '0;
            heartbeat_led_on <= 1'b0;
        end else begin
            if (spi_traffic_event) begin
                spi_led_hold_cnt <= TRAFFIC_LED_HOLD_CYCLES - 1;
            end else if (spi_led_hold_cnt != '0) begin
                spi_led_hold_cnt <= spi_led_hold_cnt - 1'b1;
            end

            if (serial_traffic_event) begin
                serial_led_hold_cnt <= TRAFFIC_LED_HOLD_CYCLES - 1;
            end else if (serial_led_hold_cnt != '0) begin
                serial_led_hold_cnt <= serial_led_hold_cnt - 1'b1;
            end

            if (heartbeat_cnt == HEARTBEAT_HALF_PERIOD_CYCLES - 1) begin
                heartbeat_cnt <= '0;
                heartbeat_led_on <= ~heartbeat_led_on;
            end else begin
                heartbeat_cnt <= heartbeat_cnt + 1'b1;
            end
        end
    end

    assign spi_led_on = (spi_led_hold_cnt != '0);
    assign serial_led_on = (serial_led_hold_cnt != '0);
    assign wb_status_leds = debug_leds_internal[5:2];

    // LED/debug mapping for board bring-up visibility.
    // Tang Nano 9K onboard LEDs are active-low: drive 0 to turn LED on.
    assign o_led_1 = ~heartbeat_led_on;
    assign o_led_2 = ~spi_led_on;
    // LEDs 3-6: register-controlled via wb_led_controller (active-low)
    assign o_led_3 = ~led_reg_out[0];
    assign o_led_4 = ~led_reg_out[1];
    assign o_led_5 = ~led_reg_out[2];
    assign o_led_6 = ~led_reg_out[3];

    assign o_debug_0 = debug_leds_internal[0];
    assign o_debug_1 = debug_leds_internal[1];
    assign o_debug_2 = debug_leds_internal[2];

    // Reserved outputs in this wrapper revision - now driven by u_top.

    logic _unused_ok;
    always_comb begin
        _unused_ok = usb_rx_ready ^ usb_tx_byte[0]
                   ^ parser_len_error
                   ^ parser_frame_done ^ dbg_tx_tready
                   ^ wb_status_leds[0]
                   ^ esc_tx_active;
    end
endmodule

`default_nettype wire
