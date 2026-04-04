`default_nettype none

// Tang Nano 9K board wrapper for FCSP offloader top.
//
// Notes:
// - This wrapper is for board bring-up/programming flow.
// - Current fcsp_offloader_top uses byte-stream seams for USB ingress/egress,
//   so USB-UART physical pins are currently held idle in this wrapper.
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

    // USB UART pins (board-level pins available, byte-stream bridge TBD)
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

    logic parser_sync_seen;
    logic parser_header_valid;
    logic parser_len_error;
    logic parser_frame_done;

    // USB byte-stream seam is not yet wired to physical UART in this wrapper.
    assign usb_rx_valid = 1'b0;
    assign usb_rx_byte  = 8'h00;
    assign usb_tx_ready = 1'b1;

    // No SERV endpoint integrated in this board wrapper revision.
    assign serv_cmd_tready = 1'b1;
    assign serv_rsp_tvalid = 1'b0;
    assign serv_rsp_tdata  = 8'h00;
    assign serv_rsp_tlast  = 1'b0;

    fcsp_offloader_top #(
        .MAX_PAYLOAD_LEN(512),
        .MOTOR_COUNT(4)
    ) u_top (
        .clk(i_clk),
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
        .m_serv_cmd_tvalid(serv_cmd_tvalid),
        .m_serv_cmd_tdata(serv_cmd_tdata),
        .m_serv_cmd_tlast(serv_cmd_tlast),
        .m_serv_cmd_tready(serv_cmd_tready),
        .s_serv_rsp_tvalid(serv_rsp_tvalid),
        .s_serv_rsp_tdata(serv_rsp_tdata),
        .s_serv_rsp_tlast(serv_rsp_tlast),
        .s_serv_rsp_tready(serv_rsp_tready),
        .i_pwm_in({i_pwm_ch3, i_pwm_ch2, i_pwm_ch1, i_pwm_ch0}),
        .o_neo_data(o_neopixel),
        .o_parser_sync_seen(parser_sync_seen),
        .o_parser_header_valid(parser_header_valid),
        .o_parser_len_error(parser_len_error),
        .o_parser_frame_done(parser_frame_done)
    );

    // LED/debug mapping for board bring-up visibility.
    assign o_led_1 = parser_sync_seen;
    assign o_led_2 = parser_header_valid;
    assign o_led_3 = parser_frame_done;
    assign o_led_4 = parser_len_error;
    assign o_led_5 = serv_cmd_tvalid;
    assign o_led_6 = usb_tx_valid;

    assign o_debug_0 = parser_sync_seen;
    assign o_debug_1 = parser_frame_done;
    assign o_debug_2 = parser_len_error;

    // Reserved outputs in this wrapper revision.
    assign o_usb_uart_tx = 1'b1;
    assign o_motor1 = 1'b0;
    assign o_motor2 = 1'b0;
    assign o_motor3 = 1'b0;
    assign o_motor4 = 1'b0;

    logic _unused_ok;
    always_comb begin
        _unused_ok = i_usb_uart_rx ^ usb_rx_ready ^ usb_tx_byte[0]
                   ^ serv_cmd_tdata[0] ^ serv_cmd_tlast ^ serv_rsp_tready
                   ^ i_pwm_ch4 ^ i_pwm_ch5;
    end
endmodule

`default_nettype wire
