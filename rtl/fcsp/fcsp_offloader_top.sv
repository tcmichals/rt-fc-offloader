`default_nettype wire

// FCSP offloader top — production integration
//
// This module integrates:
// - transport ingress (SPI primary, USB serial optional)
// - FCSP parser fast path
// - fcsp_wishbone_master (hardware CONTROL frame processor)
// - IO engines (DSHOT / PWM decode / NeoPixel / ESC UART / mux)
module fcsp_offloader_top #(
    parameter int MAX_PAYLOAD_LEN = 512,
    parameter int CLK_FREQ_HZ    = 54_000_000
) (
    input  wire                    clk,
    input  wire                    rst,

    // SPI pins
    input  wire                    i_spi_sclk,
    input  wire                    i_spi_cs_n,
    input  wire                    i_spi_mosi,
    output wire                    o_spi_miso,

    // Optional USB-serial byte stream ingress/egress (already CDC-adapted)
    input  wire                    i_usb_rx_valid,
    input  wire [7:0]              i_usb_rx_byte,
    output logic                   o_usb_rx_ready,
    output wire                    o_usb_tx_valid,
    output wire [7:0]              o_usb_tx_byte,
    input  wire                    i_usb_tx_ready,

    // Optional debug egress producer stream
    input  wire                    s_dbg_tx_tvalid,
    input  wire [7:0]              s_dbg_tx_tdata,
    input  wire                    s_dbg_tx_tlast,
    output wire                    s_dbg_tx_tready,
    input  wire [7:0]              s_dbg_tx_channel,
    input  wire [7:0]              s_dbg_tx_flags,
    input  wire [15:0]             s_dbg_tx_seq,

    // Motor pads (bidirectional, directly to board pins)
    inout  wire  [3:0]              pad_motor,

    // NeoPixel serial output
    output wire                    o_neo_data,

    // PWM input pins (directly from board)
    input  wire                    i_pwm_0,
    input  wire                    i_pwm_1,
    input  wire                    i_pwm_2,
    input  wire                    i_pwm_3,
    input  wire                    i_pwm_4,
    input  wire                    i_pwm_5,

    // PC sniffer feed (from USB-UART RX path)
    input  wire [7:0]              pc_rx_data,
    input  wire                    pc_rx_valid,

    // ESC UART half-duplex status
    output wire                    o_esc_tx_active,

    // LED controller slave WB pass-through
    output wire [31:0]             led_adr_o,
    output wire [31:0]             led_dat_o,
    input  wire [31:0]             led_dat_i,
    output wire [3:0]              led_sel_o,
    output wire                    led_we_o,
    output wire                    led_cyc_o,
    output wire                    led_stb_o,
    input  wire                    led_ack_i,

    // Status visibility
    output wire                    o_parser_sync_seen,
    output wire                    o_parser_header_valid,
    output wire                    o_parser_len_error,
    output wire                    o_parser_frame_done,
    output wire                    o_ctrl_tx_overflow,
    output wire                    o_ctrl_tx_frame_seen,
    output wire                    o_dbg_tx_overflow,
    output wire                    o_dbg_tx_frame_seen
);
    localparam int STREAM_FIFO_DEPTH = MAX_PAYLOAD_LEN;
    localparam logic [7:0] CH_CONTROL = 8'h01;

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
        // High-water mark: if USB UART has data, treat it as the active transport.
        // Once a frame starts, the frame_from_spi logic (below) locks the routing.
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

    logic        frame_from_spi;
    logic        ingress_tid;
    logic        spi_ingress_drop;
    logic        router_s_tready;

    always_ff @(posedge clk) begin
        if (rst) begin
            frame_from_spi <= 1'b0;
            ingress_tid    <= 1'b0;
        end else if (o_parser_sync_seen) begin
            frame_from_spi <= ~sel_usb_rx;
            ingress_tid    <= ~sel_usb_rx;
        end
    end

    assign spi_ingress_drop = frame_from_spi & (crc_frame_channel != CH_CONTROL && crc_frame_channel != 8'h05);
    assign crc_frame_tready = spi_ingress_drop ? 1'b1 : router_s_tready;

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
        .s_frame_tvalid (crc_frame_tvalid & ~spi_ingress_drop),
        .s_frame_tdata  (crc_frame_tdata),
        .s_frame_tlast  (crc_frame_tlast),
        .s_frame_tready (router_s_tready),
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
        .m_esc_tready   (router_esc_tready),
        .o_route_valid  (router_route_valid),
        .o_route_drop   (router_route_drop),
        .o_route_channel(router_route_channel)
    );

    // ------------------------------------------------------------
    // Control bridge (control-plane stream seam, both ends)
    // ------------------------------------------------------------
    logic        ctrl_rx_tvalid, ctrl_rx_tlast, ctrl_rx_tready;
    logic [7:0]  ctrl_rx_tdata;
    logic [7:0]  ctrl_rx_channel, ctrl_rx_flags;
    logic [15:0] ctrl_rx_seq, ctrl_rx_payload_len;
    logic ctrl_rx_tid;
    logic ctrl_rx_overflow, ctrl_rx_frame_seen;

    logic ctrl_tx_tvalid, ctrl_tx_tlast;
    logic [7:0] ctrl_tx_tdata;
    logic ctrl_tx_tready;
    logic [7:0] ctrl_tx_meta_channel, ctrl_tx_meta_flags;
    logic [15:0] ctrl_tx_meta_seq;
    logic        ctrl_tx_meta_tdest;
    logic        ctrl_tx_fifo_tvalid, ctrl_tx_fifo_tlast;
    logic [7:0]  ctrl_tx_fifo_tdata;
    logic        ctrl_tx_fifo_tready;
    logic [7:0]  ctrl_tx_channel, ctrl_tx_flags;
    logic [15:0] ctrl_tx_seq, ctrl_tx_payload_len;
    logic        ctrl_tx_fifo_tdest;
    logic        ctrl_tx_overflow, ctrl_tx_frame_seen;
    logic        tx_wire_tvalid, tx_wire_tready;
    logic [7:0]  tx_wire_tdata;
    logic        tx_framer_busy, tx_framer_overflow, tx_framer_frame_done;
    logic        tx_frame_tdest_latched;
    logic [7:0]  tx_frame_channel_latched;
    logic        tx_route_spi;

    logic        tx_arb_tvalid, tx_arb_tlast, tx_arb_tready;
    logic [7:0]  tx_arb_tdata, tx_arb_channel, tx_arb_flags;
    logic [15:0] tx_arb_seq;
    logic        tx_arb_tdest;

    logic        dbg_tx_fifo_tvalid, dbg_tx_fifo_tlast;
    logic [7:0]  dbg_tx_fifo_tdata;
    logic        dbg_tx_fifo_tready;
    logic [7:0]  dbg_tx_channel, dbg_tx_flags;
    logic [15:0] dbg_tx_seq, dbg_tx_payload_len;
    logic        dbg_tx_fifo_tdest;
    logic        dbg_tx_overflow, dbg_tx_frame_seen;

    // ─── ESC CH 0x05 stream path ────────────────────────────────────
    // Router ESC output → io_engines TX stream → ESC UART → pad
    // ESC UART RX stream → packetizer → arbiter ESC input → framer → host
    logic        router_esc_tready;

    logic [7:0]  esc_rx_tdata;
    logic        esc_rx_tvalid;
    logic        esc_rx_tready;

    logic [7:0]  esc_pkt_tdata;
    logic        esc_pkt_tvalid;
    logic        esc_pkt_tlast;
    logic        esc_pkt_tready;
    logic        esc_pkt_tdest;
    logic        esc_active_tdest;

    always_ff @(posedge clk) begin
        if (rst)
            esc_active_tdest <= 1'b0;
        else if (router_esc_tvalid && router_esc_tready)
            esc_active_tdest <= ingress_tid;
    end
    assign esc_pkt_tdest = esc_active_tdest;

    fcsp_rx_fifo #(
        .DEPTH(STREAM_FIFO_DEPTH)
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
        .s_tid        (ingress_tid),
        .m_tvalid     (ctrl_rx_tvalid),
        .m_tdata      (ctrl_rx_tdata),
        .m_tlast      (ctrl_rx_tlast),
        .m_tready     (ctrl_rx_tready),
        .m_channel    (ctrl_rx_channel),
        .m_flags      (ctrl_rx_flags),
        .m_seq        (ctrl_rx_seq),
        .m_payload_len(ctrl_rx_payload_len),
        .m_tid        (ctrl_rx_tid),
        .o_overflow   (ctrl_rx_overflow),
        .o_frame_seen (ctrl_rx_frame_seen)
    );

    // Internal Wishbone bus connecting WB master to IO engines
    logic [31:0] int_wb_adr;
    logic [31:0] int_wb_dat_m2s;   // master → slave data
    logic [31:0] int_wb_dat_s2m;   // slave → master data
    logic [3:0]  int_wb_sel;
    logic        int_wb_we;
    logic        int_wb_cyc;
    logic        int_wb_stb;
    logic        int_wb_ack;

    // WB master debug stream — tie off for now (connect to dbg TX later)
    logic        wb_dbg_tvalid_unused;
    logic [7:0]  wb_dbg_tdata_unused;
    logic        wb_dbg_tlast_unused;

    // Capture FCSP sequence number from ctrl RX FIFO for response framing.
    // The fcsp_wishbone_master does not propagate FCSP metadata; we latch
    // it here so the TX FIFO tags the response frame correctly.
    logic [15:0] ctrl_pending_seq;
    always_ff @(posedge clk) begin
        if (rst)
            ctrl_pending_seq <= 16'h0000;
        else if (ctrl_rx_tvalid && ctrl_rx_tready)
            ctrl_pending_seq <= ctrl_rx_seq;
    end

    assign ctrl_tx_meta_channel = 8'h01; // CH_CONTROL
    assign ctrl_tx_meta_flags   = 8'h02; // ACK_RESPONSE
    assign ctrl_tx_meta_seq     = ctrl_pending_seq;

    fcsp_wishbone_master u_wb_master (
        .clk           (clk),
        .rst           (rst),
        .s_cmd_tvalid  (ctrl_rx_tvalid),
        .s_cmd_tdata   (ctrl_rx_tdata),
        .s_cmd_tlast   (ctrl_rx_tlast),
        .s_cmd_tready  (ctrl_rx_tready),
        .s_tid         (ctrl_rx_tid),
        .m_rsp_tvalid  (ctrl_tx_tvalid),
        .m_rsp_tdata   (ctrl_tx_tdata),
        .m_rsp_tlast   (ctrl_tx_tlast),
        .m_rsp_tready  (ctrl_tx_tready),
        .m_rsp_tdest   (ctrl_tx_meta_tdest),
        .m_dbg_tvalid  (wb_dbg_tvalid_unused),
        .m_dbg_tdata   (wb_dbg_tdata_unused),
        .m_dbg_tlast   (wb_dbg_tlast_unused),
        .m_dbg_tready  (1'b1),
        .wb_adr_o      (int_wb_adr),
        .wb_dat_o      (int_wb_dat_m2s),
        .wb_sel_o      (int_wb_sel),
        .wb_we_o       (int_wb_we),
        .wb_cyc_o      (int_wb_cyc),
        .wb_stb_o      (int_wb_stb),
        .wb_ack_i      (int_wb_ack),
        .wb_dat_i      (int_wb_dat_s2m)
    );

    fcsp_tx_fifo #(
        .DEPTH(STREAM_FIFO_DEPTH)
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
        .s_tdest      (ctrl_tx_meta_tdest),
        .m_tvalid     (ctrl_tx_fifo_tvalid),
        .m_tdata      (ctrl_tx_fifo_tdata),
        .m_tlast      (ctrl_tx_fifo_tlast),
        .m_tready     (ctrl_tx_fifo_tready),
        .m_channel    (ctrl_tx_channel),
        .m_flags      (ctrl_tx_flags),
        .m_seq        (ctrl_tx_seq),
        .m_payload_len(ctrl_tx_payload_len),
        .m_tdest      (ctrl_tx_fifo_tdest),
        .o_overflow   (ctrl_tx_overflow),
        .o_frame_seen (ctrl_tx_frame_seen)
    );

    fcsp_tx_fifo #(
        .DEPTH(STREAM_FIFO_DEPTH)
    ) u_dbg_tx_fifo (
        .clk          (clk),
        .rst          (rst),
        .s_tvalid     (s_dbg_tx_tvalid),
        .s_tdata      (s_dbg_tx_tdata),
        .s_tlast      (s_dbg_tx_tlast),
        .s_tready     (s_dbg_tx_tready),
        .s_channel    (s_dbg_tx_channel),
        .s_flags      (s_dbg_tx_flags),
        .s_seq        (s_dbg_tx_seq),
        .s_payload_len(16'h0000),
        .s_tdest      (1'b0), // Debug/Trace always USB
        .m_tvalid     (dbg_tx_fifo_tvalid),
        .m_tdata      (dbg_tx_fifo_tdata),
        .m_tlast      (dbg_tx_fifo_tlast),
        .m_tready     (dbg_tx_fifo_tready),
        .m_channel    (dbg_tx_channel),
        .m_flags      (dbg_tx_flags),
        .m_seq        (dbg_tx_seq),
        .m_payload_len(dbg_tx_payload_len),
        .m_tdest      (dbg_tx_fifo_tdest),
        .o_overflow   (dbg_tx_overflow),
        .o_frame_seen (dbg_tx_frame_seen)
    );

    fcsp_tx_arbiter u_tx_arbiter (
        .clk           (clk),
        .rst           (rst),
        .s_ctrl_tvalid (ctrl_tx_fifo_tvalid),
        .s_ctrl_tdata  (ctrl_tx_fifo_tdata),
        .s_ctrl_tlast  (ctrl_tx_fifo_tlast),
        .s_ctrl_tready (ctrl_tx_fifo_tready),
        .s_ctrl_channel(ctrl_tx_channel),
        .s_ctrl_flags  (ctrl_tx_flags),
        .s_ctrl_seq    (ctrl_tx_seq),
        .s_ctrl_tdest  (ctrl_tx_fifo_tdest),
        .s_esc_tvalid  (esc_pkt_tvalid),
        .s_esc_tdata   (esc_pkt_tdata),
        .s_esc_tlast   (esc_pkt_tlast),
        .s_esc_tready  (esc_pkt_tready),
        .s_esc_channel (8'h05),
        .s_esc_flags   (8'h00),
        .s_esc_seq     (16'h0000),
        .s_esc_tdest   (esc_pkt_tdest),
        .s_dbg_tvalid  (dbg_tx_fifo_tvalid),
        .s_dbg_tdata   (dbg_tx_fifo_tdata),
        .s_dbg_tlast   (dbg_tx_fifo_tlast),
        .s_dbg_tready  (dbg_tx_fifo_tready),
        .s_dbg_channel (dbg_tx_channel),
        .s_dbg_flags   (dbg_tx_flags),
        .s_dbg_seq     (dbg_tx_seq),
        .s_dbg_tdest   (dbg_tx_fifo_tdest),
        .m_tvalid      (tx_arb_tvalid),
        .m_tdata       (tx_arb_tdata),
        .m_tlast       (tx_arb_tlast),
        .m_tready      (tx_arb_tready),
        .m_channel     (tx_arb_channel),
        .m_flags       (tx_arb_flags),
        .m_seq         (tx_arb_seq),
        .m_tdest       (tx_arb_tdest)
    );

    fcsp_tx_framer #(
        .MAX_PAYLOAD_LEN(MAX_PAYLOAD_LEN)
    ) u_ctrl_tx_framer (
        .clk        (clk),
        .rst        (rst),
        .s_tvalid   (tx_arb_tvalid),
        .s_tdata    (tx_arb_tdata),
        .s_tlast    (tx_arb_tlast),
        .s_tready   (tx_arb_tready),
        .s_channel  (tx_arb_channel),
        .s_flags    (tx_arb_flags),
        .s_seq      (tx_arb_seq),
        .s_tdest    (tx_arb_tdest),
        .m_tvalid   (tx_wire_tvalid),
        .m_tdata    (tx_wire_tdata),
        .m_tready   (tx_wire_tready),
        .o_busy     (tx_framer_busy),
        .o_overflow (tx_framer_overflow),
        .o_frame_done(tx_framer_frame_done),
        .o_frame_tdest_latched(tx_frame_tdest_latched)
    );

    assign tx_route_spi = (tx_frame_tdest_latched == 1'b1);

    // -----------------------------
    // IO engines (Wishbone-based)
    // -----------------------------
    assign o_ctrl_tx_overflow = ctrl_tx_overflow;
    assign o_ctrl_tx_frame_seen = ctrl_tx_frame_seen;
    assign o_dbg_tx_overflow = dbg_tx_overflow;
    assign o_dbg_tx_frame_seen = dbg_tx_frame_seen;

    fcsp_io_engines #(
        .CLK_FREQ_HZ (CLK_FREQ_HZ)
    ) u_io_engines (
        .clk             (clk),
        .rst             (rst),
        .wb_adr_i        (int_wb_adr),
        .wb_dat_i        (int_wb_dat_m2s),
        .wb_dat_o        (int_wb_dat_s2m),
        .wb_sel_i        (int_wb_sel),
        .wb_we_i         (int_wb_we),
        .wb_cyc_i        (int_wb_cyc),
        .wb_stb_i        (int_wb_stb),
        .wb_ack_o        (int_wb_ack),
        .pad_motor       (pad_motor),
        .o_neo_data      (o_neo_data),
        .i_pwm_0         (i_pwm_0),
        .i_pwm_1         (i_pwm_1),
        .i_pwm_2         (i_pwm_2),
        .i_pwm_3         (i_pwm_3),
        .i_pwm_4         (i_pwm_4),
        .i_pwm_5         (i_pwm_5),
        .pc_rx_data      (pc_rx_data),
        .pc_rx_valid     (pc_rx_valid),
        .o_esc_tx_active (o_esc_tx_active),
        .s_esc_tdata     (router_esc_tdata),
        .s_esc_tvalid    (router_esc_tvalid),
        .s_esc_tready    (router_esc_tready),
        .m_esc_tdata     (esc_rx_tdata),
        .m_esc_tvalid    (esc_rx_tvalid),
        .m_esc_tready    (esc_rx_tready),
        .led_adr_o       (led_adr_o),
        .led_dat_o       (led_dat_o),
        .led_dat_i       (led_dat_i),
        .led_sel_o       (led_sel_o),
        .led_we_o        (led_we_o),
        .led_cyc_o       (led_cyc_o),
        .led_stb_o       (led_stb_o),
        .led_ack_i       (led_ack_i)
    );

    // ─── ESC stream packetizer ──────────────────────────────────────
    // Collects raw ESC UART RX bytes into framed payloads for the TX arbiter.
    fcsp_stream_packetizer #(
        .MAX_LEN (16),
        .TIMEOUT (1000)
    ) u_esc_packetizer (
        .clk      (clk),
        .rst      (rst),
        .s_tdata  (esc_rx_tdata),
        .s_tvalid (esc_rx_tvalid),
        .s_tready (esc_rx_tready),
        .m_tdata  (esc_pkt_tdata),
        .m_tvalid (esc_pkt_tvalid),
        .m_tlast  (esc_pkt_tlast),
        .m_tready (esc_pkt_tready)
    );

    // -----------------------------
    // TX transport seam (both ends)
    // -----------------------------
    // Transport routing policy:
    // - All TX responses egress via async USB serial.
    // - CONTROL-channel responses are additionally mirrored to SPI TX when
    //   SPI CS is asserted (dual-egress).  Non-CONTROL responses (e.g. ESC
    //   UART) are suppressed on SPI so only USB sees them.

    // SPI CS synchronizer for TX routing policy (independent of SPI frontend
    // internal CDC — this is just for the mux/ready gating logic).
    logic spi_cs_n_meta, spi_cs_n_sync;
    always_ff @(posedge clk) begin
        if (rst) begin
            spi_cs_n_meta <= 1'b1;
            spi_cs_n_sync <= 1'b1;
        end else begin
            spi_cs_n_meta <= i_spi_cs_n;
            spi_cs_n_sync <= spi_cs_n_meta;
        end
    end

    assign o_usb_tx_valid = tx_wire_tvalid;
    assign o_usb_tx_byte  = tx_wire_tdata;

    // SPI egress: valid only when SPI CS is active AND frame TDEST is SPI (1).
    assign spi_tx_valid = tx_wire_tvalid && (!spi_cs_n_sync) && tx_route_spi;
    assign spi_tx_byte  = tx_wire_tdata;

    // Back-pressure logic (tx_wire_tready):
    // - USB Serial egress is ALWAYS mandatory and must be ready.
    // - SPI egress is only mandatory if SPI CS is asserted AND tdest is SPI. 
    assign tx_wire_tready = i_usb_tx_ready && (spi_tx_ready || spi_cs_n_sync || !tx_route_spi);

    // Prevent unused warnings for observability-only wires in scaffold phase.
    logic _unused_ok;
    always_comb begin
        _unused_ok = ctrl_rx_tready ^ parser_payload_len[0]
                   ^ ctrl_tx_tlast
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
                   ^ router_route_valid ^ router_route_drop ^ router_route_channel[0]
                   ^ ctrl_rx_channel[0] ^ ctrl_rx_flags[0] ^ ctrl_rx_seq[0]
                   ^ ctrl_rx_payload_len[0] ^ ctrl_rx_overflow ^ ctrl_rx_frame_seen
                   ^ ctrl_tx_fifo_tlast ^ ctrl_tx_channel[0] ^ ctrl_tx_flags[0]
                   ^ ctrl_tx_seq[0] ^ ctrl_tx_payload_len[0]
                   ^ ctrl_tx_overflow ^ ctrl_tx_frame_seen
                   ^ dbg_tx_fifo_tvalid ^ dbg_tx_fifo_tdata[0]
                   ^ dbg_tx_fifo_tlast ^ dbg_tx_fifo_tready
                   ^ dbg_tx_channel[0] ^ dbg_tx_flags[0] ^ dbg_tx_seq[0]
                   ^ dbg_tx_payload_len[0] ^ dbg_tx_overflow ^ dbg_tx_frame_seen
                   ^ ctrl_tx_meta_channel[0] ^ ctrl_tx_meta_flags[0]
                   ^ ctrl_tx_meta_seq[0] ^ tx_wire_tvalid ^ tx_wire_tready
                   ^ tx_wire_tdata[0] ^ tx_framer_busy ^ tx_framer_overflow
                   ^ tx_framer_frame_done
                   ^ ctrl_rx_tvalid ^ ctrl_rx_tdata[0] ^ ctrl_rx_tlast
                   ^ s_dbg_tx_tvalid ^ s_dbg_tx_tdata[0] ^ s_dbg_tx_tlast
                   ^ s_dbg_tx_tready ^ s_dbg_tx_channel[0] ^ s_dbg_tx_flags[0]
                   ^ s_dbg_tx_seq[0] ^ tx_arb_tvalid ^ tx_arb_tlast
                   ^ tx_arb_tready ^ tx_arb_tdata[0] ^ tx_arb_channel[0]
                   ^ tx_arb_flags[0] ^ tx_arb_seq[0]
                   ^ tx_frame_channel_latched[0]
                   ^ frame_from_spi ^ spi_ingress_drop
                   ^ wb_dbg_tvalid_unused ^ wb_dbg_tdata_unused[0]
                   ^ wb_dbg_tlast_unused;
    end
endmodule

`default_nettype wire
