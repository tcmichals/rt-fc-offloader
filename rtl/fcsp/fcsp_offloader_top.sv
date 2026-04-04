`default_nettype none

// FCSP offloader top integration (Pure Hardware High-Speed Switch)
//
// This module implements the finalized hardware-only architecture:
// - SPI (Linux) and USB (Configurator) ingress paths.
// - FCSP Header Parser & Routing Switch.
// - Hardware Wishbone Master (replacing SERV/CPU).
// - IO Engines with integrated Passthrough-Mode Switch.
// - Hardware Debug Trace Generator (Channel 0x04).
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

    // Optional USB-serial byte stream ingress/egress
    input  logic                    i_usb_rx_valid,
    input  logic [7:0]              i_usb_rx_byte,
    output logic                    o_usb_rx_ready,
    output logic                    o_usb_tx_valid,
    output logic [7:0]              o_usb_tx_byte,
    input  logic                    i_usb_tx_ready,

    // External IO pins (engine-facing)
    input  logic [MOTOR_COUNT-1:0]  i_pwm_in,
    output logic [MOTOR_COUNT-1:0]  o_motor_pins,

    output logic                    o_neo_data,

    // Status visibility
    output logic                    o_parser_sync_seen,
    output logic                    o_parser_header_valid,
    output logic                    o_parser_len_error,
    output logic                    o_parser_frame_done,
    output logic                    o_ctrl_tx_overflow,
    output logic                    o_ctrl_tx_frame_seen,
    output logic                    o_dbg_tx_overflow,
    output logic                    o_dbg_tx_frame_seen
);
    localparam int STREAM_FIFO_DEPTH = MAX_PAYLOAD_LEN;

    // -----------------------------
    // Transport Frontend (SPI + USB)
    // -----------------------------
    logic [7:0] spi_rx_byte, spi_tx_byte;
    logic       spi_rx_valid, spi_rx_ready, spi_tx_valid, spi_tx_ready;

    fcsp_spi_frontend u_spi_frontend (
        .clk       (clk), .rst(rst),
        .i_sclk    (i_spi_sclk), .i_cs_n(i_spi_cs_n), .i_mosi(i_spi_mosi), .o_miso(o_spi_miso),
        .o_rx_byte (spi_rx_byte), .o_rx_valid(spi_rx_valid), .i_rx_ready(spi_rx_ready),
        .i_tx_byte (spi_tx_byte), .i_tx_valid(spi_tx_valid), .o_tx_ready(spi_tx_ready),
        .o_busy    ()
    );

    logic [7:0] ingress_byte;
    logic       ingress_valid, ingress_ready, sel_usb_rx;
    assign sel_usb_rx    = i_usb_rx_valid;
    assign ingress_byte  = sel_usb_rx ? i_usb_rx_byte : spi_rx_byte;
    assign ingress_valid = sel_usb_rx ? i_usb_rx_valid : spi_rx_valid;
    assign o_usb_rx_ready = sel_usb_rx ? ingress_ready : 1'b0;
    assign spi_rx_ready   = sel_usb_rx ? 1'b0 : ingress_ready;

    // -----------------------------
    // Core Parser & Router
    // -----------------------------
    logic [7:0]  router_ctrl_tdata, router_esc_tdata;
    logic        router_ctrl_tvalid, router_ctrl_tlast, router_ctrl_tready;
    logic        router_esc_tvalid, router_esc_tlast, router_esc_tready;
    logic [7:0]  crc_frame_channel, crc_frame_flags;
    logic [15:0] crc_frame_seq, crc_frame_payload_len;
    logic        crc_frame_tvalid, crc_frame_tlast, crc_frame_tready;
    logic [7:0]  crc_frame_tdata;

    fcsp_parser #( .MAX_PAYLOAD_LEN(MAX_PAYLOAD_LEN) ) u_parser (
        .clk(clk), .rst_n(~rst), .in_valid(ingress_valid), .in_byte(ingress_byte), .in_ready(ingress_ready),
        .o_sync_seen(o_parser_sync_seen), .o_header_valid(o_parser_header_valid), .o_len_error(o_parser_len_error), .o_frame_done(o_parser_frame_done),
        .m_frame_tvalid(crc_frame_tvalid), .m_frame_tdata(crc_frame_tdata), .m_frame_tlast(crc_frame_tlast), .m_frame_tready(crc_frame_tready),
        .m_frame_channel(crc_frame_channel), .m_frame_flags(crc_frame_flags), .m_frame_seq(crc_frame_seq), .m_frame_payload_len(crc_frame_payload_len)
    );

    fcsp_router u_router (
        .clk(clk), .rst(rst),
        .s_frame_tvalid(crc_frame_tvalid), .s_frame_tdata(crc_frame_tdata), .s_frame_tlast(crc_frame_tlast), .s_frame_tready(crc_frame_tready),
        .s_frame_channel(crc_frame_channel), .s_frame_flags(crc_frame_flags), .s_frame_seq(crc_frame_seq), .s_frame_payload_len(crc_frame_payload_len),
        .m_ctrl_tvalid(router_ctrl_tvalid), .m_ctrl_tdata(router_ctrl_tdata), .m_ctrl_tlast(router_ctrl_tlast), .m_ctrl_tready(router_ctrl_tready),
        .m_esc_tvalid(router_esc_tvalid), .m_esc_tdata(router_esc_tdata), .m_esc_tlast(router_esc_tlast), .m_esc_tready(router_esc_tready)
    );

    // -------------------------------------------------
    // Wishbone Master & Control Plane
    // -------------------------------------------------
    logic [31:0] wb_adr, wb_dat_m2s, wb_dat_s2m;
    logic [3:0]  wb_sel;
    logic        wb_we, wb_cyc, wb_stb, wb_ack;
    logic [7:0]  ctrl_rx_tdata, ctrl_tx_tdata, ctrl_rx_channel, ctrl_rx_flags;
    logic        ctrl_rx_tvalid, ctrl_rx_tlast, ctrl_rx_tready, ctrl_tx_tvalid, ctrl_tx_tlast, ctrl_tx_tready;
    logic [15:0] ctrl_rx_seq, ctrl_rx_payload_len;

    fcsp_rx_fifo #( .DEPTH(STREAM_FIFO_DEPTH) ) u_ctrl_rx_fifo (
        .clk(clk), .rst(rst), .s_tvalid(router_ctrl_tvalid), .s_tdata(router_ctrl_tdata), .s_tlast(router_ctrl_tlast), .s_tready(router_ctrl_tready),
        .s_channel(crc_frame_channel), .s_flags(crc_frame_flags), .s_seq(crc_frame_seq), .s_payload_len(crc_frame_payload_len),
        .m_tvalid(ctrl_rx_tvalid), .m_tdata(ctrl_rx_tdata), .m_tlast(ctrl_rx_tlast), .m_tready(ctrl_rx_tready),
        .m_channel(ctrl_rx_channel), .m_flags(ctrl_rx_flags), .m_seq(ctrl_rx_seq), .m_payload_len(ctrl_rx_payload_len)
    );

    fcsp_wishbone_master u_wb_master (
        .clk(clk), .rst(rst),
        .s_cmd_tvalid(ctrl_rx_tvalid), .s_cmd_tdata(ctrl_rx_tdata), .s_cmd_tlast(ctrl_rx_tlast), .s_cmd_tready(ctrl_rx_tready),
        .m_rsp_tvalid(ctrl_tx_tvalid), .m_rsp_tdata(ctrl_tx_tdata), .m_rsp_tlast(ctrl_tx_tlast), .m_rsp_tready(ctrl_tx_tready),
        .wb_adr_o(wb_adr), .wb_dat_o(wb_dat_m2s), .wb_sel_o(wb_sel), .wb_we_o(wb_we), .wb_cyc_o(wb_cyc), .wb_stb_o(wb_stb), .wb_ack_i(wb_ack), .wb_dat_i(wb_dat_s2m)
    );

    // -----------------------------
    // IO Engines & Hardware Switch
    // -----------------------------
    logic esc_tx_tvalid, esc_tx_tlast, esc_tx_tready;
    logic [7:0] esc_tx_tdata;
    logic       passthrough_active, break_signal_active;

    fcsp_io_engines #( .MOTOR_COUNT(MOTOR_COUNT) ) u_io_engines (
        .clk(clk), .rst(rst),
        .wb_adr_i(wb_adr), .wb_dat_i(wb_dat_m2s), .wb_sel_i(wb_sel), .wb_we_i(wb_we), .wb_cyc_i(wb_cyc), .wb_stb_i(wb_stb), .wb_ack_o(wb_ack), .wb_dat_o(wb_dat_s2m),
        .o_motor_pins(o_motor_pins), .o_neo_data(o_neo_data), .o_neo_busy(),
        .s_esc_rx_tvalid(router_esc_tvalid), .s_esc_rx_tdata(router_esc_tdata), .s_esc_rx_tlast(router_esc_tlast), .s_esc_rx_tready(router_esc_tready),
        .m_esc_tx_tvalid(esc_tx_tvalid), .m_esc_tx_tdata(esc_tx_tdata), .m_esc_tx_tlast(esc_tx_tlast), .m_esc_tx_tready(esc_tx_tready),
        .o_passthrough_active(passthrough_active), .o_break_signal_active(break_signal_active)
    );

    // -----------------------------
    // Hardware Debug Trace Generator
    // -----------------------------
    logic       debug_tx_tvalid, debug_tx_tlast, debug_tx_tready;
    logic [7:0] debug_tx_tdata;

    fcsp_debug_generator u_debug_gen (
        .clk(clk), .rst(rst),
        .i_passthrough_enabled(passthrough_active),
        .i_break_active(break_signal_active),
        .i_sync_loss(o_parser_sync_seen && o_parser_len_error), // Event trigger
        .m_dbg_tvalid(debug_tx_tvalid), .m_dbg_tdata(debug_tx_tdata), .m_dbg_tlast(debug_tx_tlast), .m_dbg_tready(debug_tx_tready)
    );

    // -----------------------------
    // TX Path Aggregator (Arbiter)
    // -----------------------------
    logic ctrl_tx_fifo_tvalid, ctrl_tx_fifo_tlast, ctrl_tx_fifo_tready;
    logic [7:0] ctrl_tx_fifo_tdata, ctrl_tx_channel, ctrl_tx_flags;
    logic [15:0] ctrl_tx_seq;

    fcsp_tx_fifo #( .DEPTH(STREAM_FIFO_DEPTH) ) u_ctrl_tx_fifo (
        .clk(clk), .rst(rst), .s_tvalid(ctrl_tx_tvalid), .s_tdata(ctrl_tx_tdata), .s_tlast(ctrl_tx_tlast), .s_tready(ctrl_tx_tready),
        .s_channel(8'h01), .s_flags(8'h02), .s_seq(ctrl_rx_seq), .s_payload_len(16'h0000),
        .m_tvalid(ctrl_tx_fifo_tvalid), .m_tdata(ctrl_tx_fifo_tdata), .m_tlast(ctrl_tx_fifo_tlast), .m_tready(ctrl_tx_fifo_tready),
        .m_channel(ctrl_tx_channel), .m_flags(ctrl_tx_flags), .m_seq(ctrl_tx_seq)
    );

    logic tx_arb_tvalid, tx_arb_tlast, tx_arb_tready;
    logic [7:0] tx_arb_tdata, tx_arb_channel, tx_arb_flags;
    logic [15:0] tx_arb_seq;

    fcsp_tx_arbiter u_tx_arbiter (
        .clk(clk), .rst(rst),
        .s_ctrl_tvalid(ctrl_tx_fifo_tvalid), .s_ctrl_tdata(ctrl_tx_fifo_tdata), .s_ctrl_tlast(ctrl_tx_fifo_tlast), .s_ctrl_tready(ctrl_tx_fifo_tready),
        .s_ctrl_channel(8'h01), .s_ctrl_flags(8'h02), .s_ctrl_seq(ctrl_tx_seq),
        .s_dbg_tvalid(debug_tx_tvalid), .s_dbg_tdata(debug_tx_tdata), .s_dbg_tlast(debug_tx_tlast), .s_dbg_tready(debug_tx_tready),
        .s_dbg_channel(8'h04), .s_dbg_flags(8'h00), .s_dbg_seq(16'h0000),
        .s_esc_tvalid(esc_tx_tvalid), .s_esc_tdata(esc_tx_tdata), .s_esc_tlast(esc_tx_tlast), .s_esc_tready(esc_tx_tready),
        .s_esc_channel(8'h05), .s_esc_flags(8'h00), .s_esc_seq(16'h0000),
        .m_tvalid(tx_arb_tvalid), .m_tdata(tx_arb_tdata), .m_tlast(tx_arb_tlast), .m_tready(tx_arb_tready),
        .m_channel(tx_arb_channel), .m_flags(tx_arb_flags), .m_seq(tx_arb_seq)
    );

    fcsp_tx_framer #( .MAX_PAYLOAD_LEN(MAX_PAYLOAD_LEN) ) u_tx_framer (
        .clk(clk), .rst(rst), .s_tvalid(tx_arb_tvalid), .s_tdata(tx_arb_tdata), .s_tlast(tx_arb_tlast), .s_tready(tx_arb_tready),
        .s_channel(tx_arb_channel), .s_flags(tx_arb_flags), .s_seq(tx_arb_seq),
        .m_tvalid(o_usb_tx_valid), .m_tdata(o_usb_tx_byte), .m_tready(i_usb_tx_ready)
    );

    // SPI logic for control responses
    assign spi_tx_byte  = o_usb_tx_byte;
    assign spi_tx_valid = o_usb_tx_valid && (tx_arb_channel == 8'h01);

endmodule

`default_nettype wire
