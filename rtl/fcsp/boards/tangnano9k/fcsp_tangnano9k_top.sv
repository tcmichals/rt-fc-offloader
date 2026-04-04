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

    // Motor pins (reserved in this wrapper revision)
    output logic o_motor1,
    output logic o_motor2,
    output logic o_motor3,
    output logic o_motor4,

    // NeoPixel output
    output logic o_neopixel,

    // Debug pins
    output logic o_debug_0,
    output logic o_debug_1,
    output logic o_debug_2
);
    logic rst;
    assign rst = ~i_rst_n;

    logic usb_rx_valid;
    logic [7:0] usb_rx_byte;
    logic usb_rx_ready;
    logic usb_tx_valid;
    logic [7:0] usb_tx_byte;
    logic usb_tx_ready;

    logic serv_cmd_tvalid;
    logic [7:0] serv_cmd_tdata;
    logic serv_cmd_tlast;
    logic serv_cmd_tready;

    logic serv_rsp_tvalid;
    logic [7:0] serv_rsp_tdata;
    logic serv_rsp_tlast;
    logic serv_rsp_tready;

    logic dbg_tx_tvalid;
    logic [7:0] dbg_tx_tdata;
    logic dbg_tx_tlast;
    logic dbg_tx_tready;
    logic [7:0] dbg_tx_channel;
    logic [7:0] dbg_tx_flags;
    logic [15:0] dbg_tx_seq;

    logic dshot_update;
    logic [1:0] dshot_mode_sel;
    logic [4*16-1:0] dshot_words;
    logic neo_update;
    logic [23:0] neo_rgb;

    logic ctrl_tx_overflow;
    logic ctrl_tx_frame_seen;
    logic dbg_tx_overflow;
    logic dbg_tx_frame_seen;

    logic parser_sync_seen;
    logic parser_header_valid;
    logic parser_len_error;
    logic parser_frame_done;

    logic sys_clk;
    
    // rPLL for ~54 MHz (27MHz * 2 / 1 = 54 MHz)
    // VCO = 27 * 2 * 8 = 432 MHz (Within 400-1200MHz range)
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
        .CLK_HZ(54_000_000),
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

    fcsp_offloader_top #(
        .MAX_PAYLOAD_LEN(256),
        .MOTOR_COUNT(4)
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
        .i_pwm_in({i_pwm_ch3, i_pwm_ch2, i_pwm_ch1, i_pwm_ch0}),
        .o_motor_pins({o_motor4, o_motor3, o_motor2, o_motor1}),
        .o_neo_data(o_neopixel),
        .o_parser_sync_seen(parser_sync_seen),
        .o_parser_header_valid(parser_header_valid),
        .o_parser_len_error(parser_len_error),
        .o_parser_frame_done(parser_frame_done),
        .o_ctrl_tx_overflow(ctrl_tx_overflow),
        .o_ctrl_tx_frame_seen(ctrl_tx_frame_seen),
        .o_dbg_tx_overflow(dbg_tx_overflow),
        .o_dbg_tx_frame_seen(dbg_tx_frame_seen)
    );

    // LED/debug mapping for board bring-up visibility.
    assign o_led_1 = parser_sync_seen;
    assign o_led_2 = parser_header_valid;
    assign o_led_3 = parser_frame_done;
    assign o_led_4 = parser_len_error;
    assign o_led_5 = serv_cmd_tvalid;
    assign o_led_6 = ctrl_tx_overflow | dbg_tx_overflow;

    assign o_debug_0 = parser_sync_seen;
    assign o_debug_1 = ctrl_tx_frame_seen;
    assign o_debug_2 = dbg_tx_frame_seen;

    // Reserved outputs in this wrapper revision - now driven by u_top.

    logic _unused_ok;
    always_comb begin
        _unused_ok = usb_rx_ready ^ usb_tx_byte[0]
                   ^ i_pwm_ch4 ^ i_pwm_ch5 ^ parser_len_error
                   ^ parser_frame_done;
    end
endmodule

`default_nettype wire
