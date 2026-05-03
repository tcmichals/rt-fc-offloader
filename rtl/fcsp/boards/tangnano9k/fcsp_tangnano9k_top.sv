`default_nettype wire

// Tang Nano 9K board wrapper for FCSP offloader top.
//
// Notes:
// - This wrapper is for board bring-up/programming flow.
// - USB-UART pins are adapted through a simple UART byte-stream shim and
//   connected to fcsp_offloader_top USB seams.
module fcsp_tangnano9k_top (
    input  wire i_clk,
    input  wire i_rst_n,

    // SPI host link
    input  wire i_spi_clk,
    input  wire i_spi_cs_n,
    input  wire i_spi_mosi,
    output wire o_spi_miso,

    // On-board LEDs
    output wire o_led_1,
    output wire o_led_2,
    output wire o_led_3,
    output wire o_led_4,
    output wire o_led_5,
    output wire o_led_6,

    // USB UART pins
    input  wire i_usb_uart_rx,
    output wire o_usb_uart_tx,

    // PWM inputs
    input  wire i_pwm_ch0,
    input  wire i_pwm_ch1,
    input  wire i_pwm_ch2,
    input  wire i_pwm_ch3,
    input  wire i_pwm_ch4,
    input  wire i_pwm_ch5,

    // Motor pins (bidirectional for 1-wire serial)
    inout  wire o_motor1,
    inout  wire o_motor2,
    inout  wire o_motor3,
    inout  wire o_motor4,

    // NeoPixel output
    output wire o_neopixel,

    // Debug pins
    output wire o_debug_0,
    output wire o_debug_1,
    output wire o_debug_2,
    output wire o_debug_3,
    output wire o_debug_4,
    output wire o_debug_5,
    output wire o_debug_6
);
    parameter int LED_WIDTH = 5;
    parameter int SYS_CLK_HZ = 54_000_000;
    parameter int HEARTBEAT_HZ = 2;

    initial begin
        if (LED_WIDTH < 0 || LED_WIDTH > 5) begin
            $error("LED_WIDTH must be in range [0,5], got %0d", LED_WIDTH);
        end
        if (SYS_CLK_HZ <= 0) begin
            $error("SYS_CLK_HZ must be > 0, got %0d", SYS_CLK_HZ);
        end
        if (HEARTBEAT_HZ <= 0) begin
            $error("HEARTBEAT_HZ must be > 0, got %0d", HEARTBEAT_HZ);
        end
    end

    logic rst;
    logic wb_ack;
    logic wb_stb;
    logic crc_ok;
    logic crc_drop;
    logic pll_lock;
    assign rst = !pll_lock || !i_rst_n;

    logic usb_rx_valid;
    logic [7:0] usb_rx_byte;
    logic usb_rx_ready;
    logic usb_tx_valid;
    logic [7:0] usb_tx_byte;
    logic usb_tx_ready;

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

    localparam int HEARTBEAT_HALF_PERIOD_CYCLES_RAW = SYS_CLK_HZ / (2 * HEARTBEAT_HZ);
    localparam int HEARTBEAT_HALF_PERIOD_CYCLES =
        (HEARTBEAT_HALF_PERIOD_CYCLES_RAW < 1) ? 1 : HEARTBEAT_HALF_PERIOD_CYCLES_RAW;
    localparam int HEARTBEAT_CNT_W = (HEARTBEAT_HALF_PERIOD_CYCLES <= 1)
                                   ? 1 : $clog2(HEARTBEAT_HALF_PERIOD_CYCLES);
    logic [HEARTBEAT_CNT_W-1:0] heartbeat_cnt;
    logic heartbeat_led_on;
    
    // rPLL for 54 MHz — VCO=432MHz (27*2*8), CLKOUT=432/8=54MHz
    rPLL #(
        .FCLKIN("27"),
        .IDIV_SEL(0),
        .FBDIV_SEL(1),
        .ODIV_SEL(8),
        .DEVICE("GW1NR-9C"),
        .CLKFB_SEL("internal")
    ) u_pll (
        .CLKIN(i_clk),
        .CLKFB(1'b0),
        .RESET(1'b0),
        .RESET_P(1'b0),
        .FBDSEL(6'b000000),
        .IDSEL(6'b000000),
        .ODSEL(6'b000000),
        .PSDA(4'b0000),
        .DUTYDA(4'b0000),
        .FDLY(4'b0000),
        .CLKOUT(sys_clk),
        .LOCK(pll_lock),
        .CLKOUTP(),
        .CLKOUTD(),
        .CLKOUTD3()
    );

    // UART shim connects physical USB-UART pins to offloader USB byte seam.
    fcsp_uart_byte_stream #(
        .CLK_HZ(SYS_CLK_HZ),
        .BAUD(115_200)
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
    logic [4:0]  led_reg_out;

    wb_led_controller #(
        .LED_WIDTH   (5),
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
        .CLK_FREQ_HZ(SYS_CLK_HZ),
        .NEO_LED_TYPE(1)  // SK6812 RGBW
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
        .o_dbg_tx_frame_seen(dbg_tx_frame_seen),
        .o_wb_ack(wb_ack),
        .o_wb_stb(wb_stb),
        .o_crc_ok(crc_ok),
        .o_crc_drop(crc_drop)
    );

    // Heartbeat counter
    always_ff @(posedge sys_clk) begin
        if (rst) begin
            heartbeat_cnt <= '0;
            heartbeat_led_on <= 1'b0;
        end else begin
            if (heartbeat_cnt == HEARTBEAT_HALF_PERIOD_CYCLES - 1) begin
                heartbeat_cnt <= '0;
                heartbeat_led_on <= ~heartbeat_led_on;
            end else begin
                heartbeat_cnt <= heartbeat_cnt + 1'b1;
            end
        end
    end

    // LED mapping: Tang Nano 9K Active-Low (0 = ON, 1 = OFF)
    assign o_led_1 = ~heartbeat_led_on;    // LED1: 2Hz Heartbeat
    // Wishbone LED controller outputs (LED_POLARITY=0 already inverts for active-low):
    assign o_led_2 = led_reg_out[0];       // LED2: WB LED[0]
    assign o_led_3 = led_reg_out[1];       // LED3: WB LED[1]
    assign o_led_4 = led_reg_out[2];       // LED4: WB LED[2]
    assign o_led_5 = led_reg_out[3];       // LED5: WB LED[3]
    assign o_led_6 = led_reg_out[4];       // LED6: WB LED[4]

    // Debug pins — Full pipeline trace (7 active)
    assign o_debug_0 = i_usb_uart_rx;                           // CH0 (32): Raw RX
    assign o_debug_1 = parser_frame_done;                       // CH1 (31): Frame fully received
    assign o_debug_2 = crc_ok;                                  // CH2 (49): CRC passed
    assign o_debug_3 = crc_drop;                                // CH3: CRC failed/dropped
    assign o_debug_4 = ctrl_tx_frame_seen;                      // CH4: Response sent to TX
    assign o_debug_5 = o_usb_uart_tx;                           // CH5: Raw TX output
    assign o_debug_6 = ctrl_tx_overflow;                        // CH6: TX overflow

    logic _unused_ok;
    always_comb begin
        _unused_ok = usb_rx_ready ^ usb_tx_byte[0]
                   ^ parser_len_error ^ parser_header_valid
                   ^ parser_sync_seen
                   ^ dbg_tx_tready
                   ^ dbg_tx_overflow ^ dbg_tx_frame_seen
                   ^ esc_tx_active
                   ^ i_rst_n;
    end
endmodule

`default_nettype wire
