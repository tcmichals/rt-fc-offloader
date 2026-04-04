`default_nettype none

// FCSP offloader top integration scaffold
//
// This module establishes integration seams for:
// - transport ingress (SPI primary, USB serial optional)
// - FCSP parser fast path
// - SERV control-plane bridge (RX to SERV, SERV to TX)
// - IO engines (DSHOT / PWM decode / NeoPixel)
module fcsp_offloader_top #(
    parameter int MAX_PAYLOAD_LEN = 512,
    parameter int MOTOR_COUNT = 4
) (
    input  logic                    clk,
    input  logic                    rst,

    // SPI pins
    input  logic                    i_spi_sclk,
    input  logic                    i_spi_cs_n,
    input  logic                    i_spi_mosi,
    output logic                    o_spi_miso,

    // Optional USB-serial byte stream ingress/egress (already CDC-adapted)
    input  logic                    i_usb_rx_valid,
    input  logic [7:0]              i_usb_rx_byte,
    output logic                    o_usb_rx_ready,
    output logic                    o_usb_tx_valid,
    output logic [7:0]              o_usb_tx_byte,
    input  logic                    i_usb_tx_ready,

    // SERV endpoint AXIS-like command/response streams
    output logic                    m_serv_cmd_tvalid,
    output logic [7:0]              m_serv_cmd_tdata,
    output logic                    m_serv_cmd_tlast,
    input  logic                    m_serv_cmd_tready,

    input  logic                    s_serv_rsp_tvalid,
    input  logic [7:0]              s_serv_rsp_tdata,
    input  logic                    s_serv_rsp_tlast,
    output logic                    s_serv_rsp_tready,

    // External IO pins (engine-facing)
    input  logic [MOTOR_COUNT-1:0]  i_pwm_in,
    output logic                    o_neo_data,

    // Status visibility
    output logic                    o_parser_sync_seen,
    output logic                    o_parser_header_valid,
    output logic                    o_parser_len_error,
    output logic                    o_parser_frame_done
);
    // -----------------------------
    // SPI frontend -> selected RX
    // -----------------------------
    logic [7:0] spi_rx_byte;
    logic       spi_rx_valid;
    logic       spi_rx_ready;

    logic [7:0] spi_tx_byte;
    logic       spi_tx_valid;
    logic       spi_tx_ready;

    fcsp_spi_frontend u_spi_frontend (
        .clk       (clk),
        .rst       (rst),
        .i_sclk    (i_spi_sclk),
        .i_cs_n    (i_spi_cs_n),
        .i_mosi    (i_spi_mosi),
        .o_miso    (o_spi_miso),
        .o_rx_byte (spi_rx_byte),
        .o_rx_valid(spi_rx_valid),
        .i_rx_ready(spi_rx_ready),
        .i_tx_byte (spi_tx_byte),
        .i_tx_valid(spi_tx_valid),
        .o_tx_ready(spi_tx_ready),
        .o_busy    ()
    );

    // Current scaffold transport selection policy:
    // - USB ingress has priority if valid, else SPI ingress.
    logic       sel_usb_rx;
    logic [7:0] ingress_byte;
    logic       ingress_valid;
    logic       ingress_ready;

    always_comb begin
        sel_usb_rx   = i_usb_rx_valid;
        ingress_byte = sel_usb_rx ? i_usb_rx_byte : spi_rx_byte;
        ingress_valid= sel_usb_rx ? i_usb_rx_valid : spi_rx_valid;

        o_usb_rx_ready = sel_usb_rx ? ingress_ready : 1'b0;
        spi_rx_ready   = sel_usb_rx ? 1'b0 : ingress_ready;
    end

    // -----------------------------
    // Parser fast-path observability
    // -----------------------------
    logic [15:0] parser_payload_len;
    logic        parser_frame_tvalid;
    logic [7:0]  parser_frame_tdata;
    logic        parser_frame_tlast;
    logic        parser_frame_tready;
    logic [7:0]  parser_frame_version;
    logic [7:0]  parser_frame_channel;
    logic [7:0]  parser_frame_flags;
    logic [15:0] parser_frame_seq;
    logic [15:0] parser_frame_payload_len;
    logic [15:0] parser_frame_recv_crc;

    logic        crc_frame_tvalid, crc_frame_tlast, crc_frame_tready;
    logic [7:0]  crc_frame_tdata;
    logic [7:0]  crc_frame_version;
    logic [7:0]  crc_frame_channel;
    logic [7:0]  crc_frame_flags;
    logic [15:0] crc_frame_seq;
    logic [15:0] crc_frame_payload_len;
    logic        crc_gate_valid, crc_gate_ok, crc_gate_drop;

    logic        router_ctrl_tvalid, router_ctrl_tlast, router_ctrl_tready;
    logic [7:0]  router_ctrl_tdata;
    logic        router_tel_tvalid, router_tel_tlast;
    logic [7:0]  router_tel_tdata;
    logic        router_log_tvalid, router_log_tlast;
    logic [7:0]  router_log_tdata;
    logic        router_dbg_tvalid, router_dbg_tlast;
    logic [7:0]  router_dbg_tdata;
    logic        router_esc_tvalid, router_esc_tlast;
    logic [7:0]  router_esc_tdata;
    logic        router_route_valid, router_route_drop;
    logic [7:0]  router_route_channel;

    fcsp_parser #(
        .MAX_PAYLOAD_LEN(MAX_PAYLOAD_LEN)
    ) u_parser (
        .clk           (clk),
        .rst_n         (~rst),
        .in_valid      (ingress_valid),
        .in_byte       (ingress_byte),
        .in_ready      (ingress_ready),
        .o_sync_seen   (o_parser_sync_seen),
        .o_header_valid(o_parser_header_valid),
        .o_len_error   (o_parser_len_error),
        .o_frame_done  (o_parser_frame_done),
        .o_payload_len (parser_payload_len),
        .m_frame_tvalid(parser_frame_tvalid),
        .m_frame_tdata (parser_frame_tdata),
        .m_frame_tlast (parser_frame_tlast),
        .m_frame_tready(parser_frame_tready),
        .m_frame_version(parser_frame_version),
        .m_frame_channel(parser_frame_channel),
        .m_frame_flags (parser_frame_flags),
        .m_frame_seq   (parser_frame_seq),
        .m_frame_payload_len(parser_frame_payload_len),
        .o_frame_recv_crc(parser_frame_recv_crc)
    );

    // Reuse the existing CRC16/XMODEM block through a small buffered gate so
    // only CRC-clean frames move on to the router.
    fcsp_crc_gate #(
        .MAX_PAYLOAD_LEN(MAX_PAYLOAD_LEN)
    ) u_crc_gate (
        .clk            (clk),
        .rst            (rst),
        .s_frame_tvalid (parser_frame_tvalid),
        .s_frame_tdata  (parser_frame_tdata),
        .s_frame_tlast  (parser_frame_tlast),
        .s_frame_tready (parser_frame_tready),
        .s_frame_version(parser_frame_version),
        .s_frame_channel(parser_frame_channel),
        .s_frame_flags  (parser_frame_flags),
        .s_frame_seq    (parser_frame_seq),
        .s_frame_payload_len(parser_frame_payload_len),
        .s_frame_recv_crc(parser_frame_recv_crc),
        .s_frame_done   (o_parser_frame_done),
        .m_frame_tvalid (crc_frame_tvalid),
        .m_frame_tdata  (crc_frame_tdata),
        .m_frame_tlast  (crc_frame_tlast),
        .m_frame_tready (crc_frame_tready),
        .m_frame_version(crc_frame_version),
        .m_frame_channel(crc_frame_channel),
        .m_frame_flags  (crc_frame_flags),
        .m_frame_seq    (crc_frame_seq),
        .m_frame_payload_len(crc_frame_payload_len),
        .o_crc_valid    (crc_gate_valid),
        .o_crc_ok       (crc_gate_ok),
        .o_crc_drop     (crc_gate_drop)
    );

    fcsp_router u_router (
        .clk            (clk),
        .rst            (rst),
        .s_frame_tvalid (crc_frame_tvalid),
        .s_frame_tdata  (crc_frame_tdata),
        .s_frame_tlast  (crc_frame_tlast),
        .s_frame_tready (crc_frame_tready),
        .s_frame_channel(crc_frame_channel),
        .s_frame_flags  (crc_frame_flags),
        .s_frame_seq    (crc_frame_seq),
        .s_frame_payload_len(crc_frame_payload_len),
        .m_ctrl_tvalid  (router_ctrl_tvalid),
        .m_ctrl_tdata   (router_ctrl_tdata),
        .m_ctrl_tlast   (router_ctrl_tlast),
        .m_ctrl_tready  (router_ctrl_tready),
        .m_tel_tvalid   (router_tel_tvalid),
        .m_tel_tdata    (router_tel_tdata),
        .m_tel_tlast    (router_tel_tlast),
        .m_tel_tready   (1'b1),
        .m_log_tvalid   (router_log_tvalid),
        .m_log_tdata    (router_log_tdata),
        .m_log_tlast    (router_log_tlast),
        .m_log_tready   (1'b1),
        .m_dbg_tvalid   (router_dbg_tvalid),
        .m_dbg_tdata    (router_dbg_tdata),
        .m_dbg_tlast    (router_dbg_tlast),
        .m_dbg_tready   (1'b1),
        .m_esc_tvalid   (router_esc_tvalid),
        .m_esc_tdata    (router_esc_tdata),
        .m_esc_tlast    (router_esc_tlast),
        .m_esc_tready   (1'b1),
        .o_route_valid  (router_route_valid),
        .o_route_drop   (router_route_drop),
        .o_route_channel(router_route_channel)
    );

    // -------------------------------------------------
    // SERV bridge (control-plane stream seam, both ends)
    // -------------------------------------------------
    logic ctrl_rx_tvalid, ctrl_rx_tlast;
    logic [7:0] ctrl_rx_tdata;
    logic ctrl_rx_tready;
    logic [7:0] ctrl_rx_channel, ctrl_rx_flags;
    logic [15:0] ctrl_rx_seq, ctrl_rx_payload_len;
    logic ctrl_rx_overflow, ctrl_rx_frame_seen;

    logic ctrl_tx_tvalid, ctrl_tx_tlast;
    logic [7:0] ctrl_tx_tdata;
    logic ctrl_tx_tready;
    logic [7:0] ctrl_tx_meta_channel, ctrl_tx_meta_flags;
    logic [15:0] ctrl_tx_meta_seq;
    logic        ctrl_tx_fifo_tvalid, ctrl_tx_fifo_tlast;
    logic [7:0]  ctrl_tx_fifo_tdata;
    logic        ctrl_tx_fifo_tready;
    logic [7:0]  ctrl_tx_channel, ctrl_tx_flags;
    logic [15:0] ctrl_tx_seq, ctrl_tx_payload_len;
    logic        ctrl_tx_overflow, ctrl_tx_frame_seen;
    logic        tx_wire_tvalid, tx_wire_tready;
    logic [7:0]  tx_wire_tdata;
    logic        tx_framer_busy, tx_framer_overflow, tx_framer_frame_done;

    fcsp_rx_fifo #(
        .DEPTH(MAX_PAYLOAD_LEN)
    ) u_ctrl_rx_fifo (
        .clk          (clk),
        .rst          (rst),
        .s_tvalid     (router_ctrl_tvalid),
        .s_tdata      (router_ctrl_tdata),
        .s_tlast      (router_ctrl_tlast),
        .s_tready     (router_ctrl_tready),
        .s_channel    (crc_frame_channel),
        .s_flags      (crc_frame_flags),
        .s_seq        (crc_frame_seq),
        .s_payload_len(crc_frame_payload_len),
        .m_tvalid     (ctrl_rx_tvalid),
        .m_tdata      (ctrl_rx_tdata),
        .m_tlast      (ctrl_rx_tlast),
        .m_tready     (ctrl_rx_tready),
        .m_channel    (ctrl_rx_channel),
        .m_flags      (ctrl_rx_flags),
        .m_seq        (ctrl_rx_seq),
        .m_payload_len(ctrl_rx_payload_len),
        .o_overflow   (ctrl_rx_overflow),
        .o_frame_seen (ctrl_rx_frame_seen)
    );

    fcsp_serv_bridge u_serv_bridge (
        .clk            (clk),
        .rst            (rst),
        .s_ctrl_rx_tvalid(ctrl_rx_tvalid),
        .s_ctrl_rx_tdata (ctrl_rx_tdata),
        .s_ctrl_rx_tlast (ctrl_rx_tlast),
        .s_ctrl_rx_tready(ctrl_rx_tready),
        .s_ctrl_rx_seq   (ctrl_rx_seq),
        .m_serv_cmd_tvalid(m_serv_cmd_tvalid),
        .m_serv_cmd_tdata (m_serv_cmd_tdata),
        .m_serv_cmd_tlast (m_serv_cmd_tlast),
        .m_serv_cmd_tready(m_serv_cmd_tready),
        .s_serv_rsp_tvalid(s_serv_rsp_tvalid),
        .s_serv_rsp_tdata (s_serv_rsp_tdata),
        .s_serv_rsp_tlast (s_serv_rsp_tlast),
        .s_serv_rsp_tready(s_serv_rsp_tready),
        .m_ctrl_tx_tvalid (ctrl_tx_tvalid),
        .m_ctrl_tx_tdata  (ctrl_tx_tdata),
        .m_ctrl_tx_tlast  (ctrl_tx_tlast),
        .m_ctrl_tx_tready (ctrl_tx_tready),
        .m_ctrl_tx_channel(ctrl_tx_meta_channel),
        .m_ctrl_tx_flags  (ctrl_tx_meta_flags),
        .m_ctrl_tx_seq    (ctrl_tx_meta_seq)
    );

    fcsp_tx_fifo #(
        .DEPTH(MAX_PAYLOAD_LEN)
    ) u_ctrl_tx_fifo (
        .clk          (clk),
        .rst          (rst),
        .s_tvalid     (ctrl_tx_tvalid),
        .s_tdata      (ctrl_tx_tdata),
        .s_tlast      (ctrl_tx_tlast),
        .s_tready     (ctrl_tx_tready),
        .s_channel    (ctrl_tx_meta_channel),
        .s_flags      (ctrl_tx_meta_flags),
        .s_seq        (ctrl_tx_meta_seq),
        .s_payload_len(16'h0000),
        .m_tvalid     (ctrl_tx_fifo_tvalid),
        .m_tdata      (ctrl_tx_fifo_tdata),
        .m_tlast      (ctrl_tx_fifo_tlast),
        .m_tready     (ctrl_tx_fifo_tready),
        .m_channel    (ctrl_tx_channel),
        .m_flags      (ctrl_tx_flags),
        .m_seq        (ctrl_tx_seq),
        .m_payload_len(ctrl_tx_payload_len),
        .o_overflow   (ctrl_tx_overflow),
        .o_frame_seen (ctrl_tx_frame_seen)
    );

    fcsp_tx_framer #(
        .MAX_PAYLOAD_LEN(MAX_PAYLOAD_LEN)
    ) u_ctrl_tx_framer (
        .clk        (clk),
        .rst        (rst),
        .s_tvalid   (ctrl_tx_fifo_tvalid),
        .s_tdata    (ctrl_tx_fifo_tdata),
        .s_tlast    (ctrl_tx_fifo_tlast),
        .s_tready   (ctrl_tx_fifo_tready),
        .s_channel  (ctrl_tx_channel),
        .s_flags    (ctrl_tx_flags),
        .s_seq      (ctrl_tx_seq),
        .m_tvalid   (tx_wire_tvalid),
        .m_tdata    (tx_wire_tdata),
        .m_tready   (tx_wire_tready),
        .o_busy     (tx_framer_busy),
        .o_overflow (tx_framer_overflow),
        .o_frame_done(tx_framer_frame_done)
    );

    // -----------------------------
    // IO engines seam (DSHOT/PWM/Neo)
    // -----------------------------
    logic dshot_update;
    logic [1:0] dshot_mode_sel;
    logic [MOTOR_COUNT*16-1:0] dshot_words;
    logic dshot_ready;
    logic [MOTOR_COUNT*16-1:0] pwm_width_ticks;
    logic [MOTOR_COUNT-1:0] pwm_new_sample;
    logic neo_update;
    logic [23:0] neo_rgb;
    logic neo_busy;

    assign dshot_update = 1'b0;
    assign dshot_mode_sel = 2'b00;
    assign dshot_words = '0;
    assign neo_update = 1'b0;
    assign neo_rgb = 24'h000000;

    fcsp_io_engines #(
        .MOTOR_COUNT(MOTOR_COUNT)
    ) u_io_engines (
        .clk              (clk),
        .rst              (rst),
        .i_dshot_update   (dshot_update),
        .i_dshot_mode_sel (dshot_mode_sel),
        .i_dshot_words    (dshot_words),
        .o_dshot_ready    (dshot_ready),
        .i_pwm_in         (i_pwm_in),
        .o_pwm_width_ticks(pwm_width_ticks),
        .o_pwm_new_sample (pwm_new_sample),
        .i_neo_update     (neo_update),
        .i_neo_rgb        (neo_rgb),
        .o_neo_busy       (neo_busy),
        .o_neo_data       (o_neo_data)
    );

    // -----------------------------
    // TX transport seam (both ends)
    // -----------------------------
    // Current scaffold drives only the CONTROL response source through a real
    // FCSP TX framer. A later revision inserts multi-channel TX scheduling.
    assign tx_wire_tready = i_usb_tx_ready | spi_tx_ready;

    assign o_usb_tx_valid = tx_wire_tvalid;
    assign o_usb_tx_byte  = tx_wire_tdata;

    assign spi_tx_valid = tx_wire_tvalid;
    assign spi_tx_byte  = tx_wire_tdata;

    // Prevent unused warnings for observability-only wires in scaffold phase.
    logic _unused_ok;
    always_comb begin
        _unused_ok = ctrl_rx_tready ^ dshot_ready ^ neo_busy ^ parser_payload_len[0]
                   ^ pwm_width_ticks[0] ^ pwm_new_sample[0] ^ ctrl_tx_tlast
                   ^ parser_frame_tvalid ^ parser_frame_tdata[0] ^ parser_frame_tlast
                   ^ parser_frame_version[0]
                   ^ parser_frame_channel[0] ^ parser_frame_flags[0]
                   ^ parser_frame_seq[0] ^ parser_frame_payload_len[0]
                   ^ parser_frame_recv_crc[0]
                   ^ crc_frame_tvalid ^ crc_frame_tdata[0] ^ crc_frame_tlast
                   ^ crc_frame_tready ^ crc_frame_version[0] ^ crc_frame_channel[0]
                   ^ crc_frame_flags[0] ^ crc_frame_seq[0] ^ crc_frame_payload_len[0]
                   ^ crc_gate_valid ^ crc_gate_ok ^ crc_gate_drop
                   ^ router_tel_tvalid ^ router_tel_tdata[0] ^ router_tel_tlast
                   ^ router_log_tvalid ^ router_log_tdata[0] ^ router_log_tlast
                   ^ router_dbg_tvalid ^ router_dbg_tdata[0] ^ router_dbg_tlast
                   ^ router_esc_tvalid ^ router_esc_tdata[0] ^ router_esc_tlast
                   ^ router_route_valid ^ router_route_drop ^ router_route_channel[0]
                   ^ ctrl_rx_channel[0] ^ ctrl_rx_flags[0] ^ ctrl_rx_seq[0]
                   ^ ctrl_rx_payload_len[0] ^ ctrl_rx_overflow ^ ctrl_rx_frame_seen
                   ^ ctrl_tx_fifo_tlast ^ ctrl_tx_channel[0] ^ ctrl_tx_flags[0]
                   ^ ctrl_tx_seq[0] ^ ctrl_tx_payload_len[0]
                   ^ ctrl_tx_overflow ^ ctrl_tx_frame_seen
                   ^ ctrl_tx_meta_channel[0] ^ ctrl_tx_meta_flags[0]
                   ^ ctrl_tx_meta_seq[0] ^ tx_wire_tvalid ^ tx_wire_tready
                   ^ tx_wire_tdata[0] ^ tx_framer_busy ^ tx_framer_overflow
                   ^ tx_framer_frame_done;
    end
endmodule

`default_nettype wire
