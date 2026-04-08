/**
 * wb_spisystem - Unified Wishbone Peripheral System (Pure Hardware Edition)
 * 
 * Contains all flight controller peripherals accessible via a single 
 * unified Wishbone bus. 
 *
 * Address Map (32-bit):
 *   0x40000300: DShot Controller (Motors 1-4)
 *   0x40000400: Serial/DSHOT Mux Selection
 *   0x40000600: NeoPixel Buffer
 *   0x40000800: USB UART Bridge
 *   0x40000900: ESC UART Bridge (Baud @ 0x4000090C)
 */

module wb_spisystem #(
    parameter CLK_FREQ_HZ      = 54_000_000,
    parameter USB_BAUD_RATE    = 115_200,
    parameter ENABLE_CPU_BUS   = 1
) (
    input  logic        clk,
    input  logic        rst,
    
    input  logic [31:0] cpu_wb_adr_i,
    input  logic [31:0] cpu_wb_dat_i,
    output logic [31:0] cpu_wb_dat_o,
    input  logic [3:0]  cpu_wb_sel_i,
    input  logic        cpu_wb_we_i,
    input  logic        cpu_wb_stb_i,
    input  logic        cpu_wb_cyc_i,
    output logic        cpu_wb_ack_o,

    // Dummy Ports
    input  logic        spi_clk, spi_cs_n, spi_mosi,
    output logic        spi_miso,

    // Peripheral I/Os
    inout  logic        motor1, motor2, motor3, motor4,
    output logic        neopixel,
    input  logic [5:0]  pwm_ch,
    output logic        usb_uart_tx,
    
    // ESC Serial Stream Interface (Channel 0x05)
    input  logic [7:0]  s_esc_stream_tdata,
    input  logic        s_esc_stream_tvalid,
    output logic        s_esc_stream_tready,
    output logic [7:0]  m_esc_stream_tdata,
    output logic        m_esc_stream_tvalid,
    input  logic        m_esc_stream_tready,

    // ILA Trace Stream Interface (Channel 0x07)
    output logic [7:0]  m_ila_stream_tdata,
    output logic        m_ila_stream_tvalid,
    output logic        m_ila_stream_tlast,
    input  logic        m_ila_stream_tready
);

    logic [31:0] s_dat_o [0:7];
    logic        s_ack   [0:7];

    wire sel_id     = (cpu_wb_adr_i[15:0] == 16'h0000);
    wire sel_dshot  = (cpu_wb_adr_i[15:8] == 8'h03);
    wire sel_mux    = (cpu_wb_adr_i[15:8] == 8'h04);
    wire sel_neo    = (cpu_wb_adr_i[15:8] == 8'h06);
    wire sel_ila    = (cpu_wb_adr_i[15:8] == 8'h07);
    wire sel_usb    = (cpu_wb_adr_i[15:8] == 8'h08);
    wire sel_esc    = (cpu_wb_adr_i[15:8] == 8'h09);
    wire sel_pwm    = (cpu_wb_adr_i[15:8] == 8'h0A);

    assign cpu_wb_dat_o = sel_id    ? 32'hFC500002 :
                          sel_dshot ? s_dat_o[0] :
                          sel_mux   ? s_dat_o[1] :
                          sel_neo   ? s_dat_o[2] :
                          sel_ila   ? s_dat_o[6] :
                          sel_usb   ? s_dat_o[3] :
                          sel_esc   ? s_dat_o[4] :
                          sel_pwm   ? s_dat_o[5] : 32'h0;

    assign cpu_wb_ack_o = (sel_id    & cpu_wb_stb_i) |
                          (sel_dshot & s_ack[0])     |
                          (sel_mux   & s_ack[1])     |
                          (sel_neo   & s_ack[2])     |
                          (sel_ila   & s_ack[6])     |
                          (sel_usb   & s_ack[3])     |
                          (sel_esc   & s_ack[4])     |
                          (sel_pwm   & s_ack[5]);

    logic motor1_dshot, motor2_dshot, motor3_dshot, motor4_dshot;
    logic esc_uart_tx_pin, esc_uart_rx_pin, esc_uart_tx_active;

    // 1. DShot Controller (Slave 0)
    wb_dshot_mailbox #( .CLK_FREQ_HZ(CLK_FREQ_HZ) ) u_dshot_mailbox (
        .clk(clk), .rst(rst),
        .wba_adr_i(cpu_wb_adr_i), .wba_dat_i(cpu_wb_dat_i), .wba_dat_o(s_dat_o[0]),
        .wba_sel_i(cpu_wb_sel_i), .wba_we_i(cpu_wb_we_i), .wba_stb_i(cpu_wb_stb_i & sel_dshot),
        .wba_cyc_i(cpu_wb_cyc_i & sel_dshot), .wba_ack_o(s_ack[0]),
        .wbb_stb_i(1'b0), .wbb_cyc_i(1'b0), .wbb_adr_i(32'h0), .wbb_dat_i(32'h0), .wbb_dat_o(), .wbb_sel_i(4'h0), .wbb_we_i(1'b0), .wbb_ack_o(),
        .motor1_o(motor1_dshot), .motor2_o(motor2_dshot), .motor3_o(motor3_dshot), .motor4_o(motor4_dshot),
        .motor1_ready(), .motor2_ready(), .motor3_ready(), .motor4_ready()
    );

    // 2. Serial/DSHOT Mux (Slave 1)
    wb_serial_dshot_mux #( .CLK_FREQ_HZ(CLK_FREQ_HZ) ) u_serial_mux (
        .wb_clk_i(clk), .wb_rst_i(rst),
        .wb_adr_i(cpu_wb_adr_i), .wb_dat_i(cpu_wb_dat_i), .wb_dat_o(s_dat_o[1]),
        .wb_we_i(cpu_wb_we_i), .wb_sel_i(cpu_wb_sel_i), .wb_stb_i(cpu_wb_stb_i & sel_mux),
        .wb_cyc_i(cpu_wb_cyc_i & sel_mux), .wb_ack_o(s_ack[1]), .wb_stall_o(),
        .pc_rx_data(s_esc_stream_tdata), .pc_rx_valid(s_esc_stream_tvalid),
        .pad_motor({motor4, motor3, motor2, motor1}),
        .dshot_in({motor4_dshot, motor3_dshot, motor2_dshot, motor1_dshot}),
        .serial_tx_i(esc_uart_tx_pin), .serial_oe_i(esc_uart_tx_active), .serial_rx_o(esc_uart_rx_pin)
    );

    // 3. NeoPixel (Slave 2)
    wb_neoPx #( .CLK_FREQ_HZ(CLK_FREQ_HZ) ) u_neopixel (
        .i_clk(clk), .i_rst(rst),
        .wb_adr_i(cpu_wb_adr_i), .wb_dat_i(cpu_wb_dat_i), .wb_dat_o(s_dat_o[2]),
        .wb_stb_i(cpu_wb_stb_i & sel_neo), .wb_cyc_i(cpu_wb_cyc_i & sel_neo), .wb_we_i(cpu_wb_we_i), .wb_sel_i(cpu_wb_sel_i),
        .wb_ack_o(s_ack[2]), .wb_err_o(), .wb_rty_o(), .o_serial(neopixel)
    );

    // 4. USB UART (Slave 3)
    wb_usb_uart #( .CLK_FREQ(CLK_FREQ_HZ), .BAUD(USB_BAUD_RATE) ) u_usb_uart (
        .clk(clk), .rst(rst),
        .wb_adr_i(cpu_wb_adr_i), .wb_dat_i(cpu_wb_dat_i), .wb_dat_o(s_dat_o[3]),
        .wb_we_i(cpu_wb_we_i), .wb_stb_i(cpu_wb_stb_i & sel_usb), .wb_ack_o(s_ack[3]),
        .uart_tx(usb_uart_tx), .uart_rx(1'b1)
    );

    // 5. ESC UART (Slave 4)
    wb_esc_uart #( .CLK_FREQ_HZ(CLK_FREQ_HZ) ) u_esc_uart (
        .clk(clk), .rst(rst),
        .wb_adr_i(cpu_wb_adr_i[3:0]), .wb_dat_i(cpu_wb_dat_i), .wb_dat_o(s_dat_o[4]),
        .wb_we_i(cpu_wb_we_i), .wb_stb_i(cpu_wb_stb_i & sel_esc), .wb_cyc_i(cpu_wb_cyc_i & sel_esc),
        .wb_ack_o(s_ack[4]), .tx_out(esc_uart_tx_pin), .rx_in(esc_uart_rx_pin), .tx_active(esc_uart_tx_active),
        .s_esc_tdata(s_esc_stream_tdata), .s_esc_tvalid(s_esc_stream_tvalid), .s_esc_tready(s_esc_stream_tready),
        .m_esc_tdata(m_esc_stream_tdata), .m_esc_tvalid(m_esc_stream_tvalid), .m_esc_tready(m_esc_stream_tready)
    );

    // 6. WILA: Streaming RLE Trace Engine (Slave 6 @ 0x0700)
    wb_ila #( .MAX_ENTRIES(40) ) u_ila (
        .clk(clk), .rst(rst),
        .wb_adr_i(cpu_wb_adr_i), .wb_dat_i(cpu_wb_dat_i), .wb_dat_o(s_dat_o[6]),
        .wb_we_i(cpu_wb_we_i), .wb_stb_i(cpu_wb_stb_i & sel_ila),
        .wb_cyc_i(cpu_wb_cyc_i & sel_ila), .wb_ack_o(s_ack[6]),
        .probe_data({
            cpu_wb_adr_i[15:0],     // [31:16] Bus Address
            cpu_wb_ack_o,           // [15] Ack
            cpu_wb_stb_i,           // [14] Strobe
            cpu_wb_we_i,            // [13] Write-enable
            motor4, motor3, motor2, motor1, // [12:9] Motor Pins
            esc_uart_tx_pin,        // [8] ESC TX
            esc_uart_rx_pin,        // [7] ESC RX
            neopixel,               // [6] Neo
            pwm_ch                  // [5:0] PWM Inputs
        }),
        .m_tdata(m_ila_stream_tdata), .m_tvalid(m_ila_stream_tvalid),
        .m_tlast(m_ila_stream_tlast), .m_tready(m_ila_stream_tready)
    );

    assign s_dat_o[5] = {26'b0, pwm_ch};
    assign s_ack[5]   = cpu_wb_stb_i & sel_pwm;
    assign spi_miso   = 1'b0;

endmodule
