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

    // SERV endpoint command/response streams
    output logic                    o_serv_cmd_valid,
    output logic [7:0]              o_serv_cmd_byte,
    output logic                    o_serv_cmd_last,
    input  logic                    i_serv_cmd_ready,

    input  logic                    i_serv_rsp_valid,
    input  logic [7:0]              i_serv_rsp_byte,
    input  logic                    i_serv_rsp_last,
    output logic                    o_serv_rsp_ready,

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
        .o_payload_len (parser_payload_len)
    );

    // -------------------------------------------------
    // SERV bridge (control-plane stream seam, both ends)
    // -------------------------------------------------
    // NOTE: Router/FIFO handoff is not wired yet. We feed an idle stream now,
    // but keep SERV and TX seams available for integration bring-up.
    logic ctrl_rx_valid, ctrl_rx_last;
    logic [7:0] ctrl_rx_byte;
    logic ctrl_rx_ready;

    logic ctrl_tx_valid, ctrl_tx_last;
    logic [7:0] ctrl_tx_byte;
    logic ctrl_tx_ready;

    assign ctrl_rx_valid = 1'b0;
    assign ctrl_rx_byte  = 8'h00;
    assign ctrl_rx_last  = 1'b0;

    fcsp_serv_bridge u_serv_bridge (
        .clk            (clk),
        .rst            (rst),
        .i_ctrl_rx_valid(ctrl_rx_valid),
        .i_ctrl_rx_byte (ctrl_rx_byte),
        .i_ctrl_rx_last (ctrl_rx_last),
        .o_ctrl_rx_ready(ctrl_rx_ready),
        .o_serv_cmd_valid(o_serv_cmd_valid),
        .o_serv_cmd_byte (o_serv_cmd_byte),
        .o_serv_cmd_last (o_serv_cmd_last),
        .i_serv_cmd_ready(i_serv_cmd_ready),
        .i_serv_rsp_valid(i_serv_rsp_valid),
        .i_serv_rsp_byte (i_serv_rsp_byte),
        .i_serv_rsp_last (i_serv_rsp_last),
        .o_serv_rsp_ready(o_serv_rsp_ready),
        .o_ctrl_tx_valid (ctrl_tx_valid),
        .o_ctrl_tx_byte  (ctrl_tx_byte),
        .o_ctrl_tx_last  (ctrl_tx_last),
        .i_ctrl_tx_ready (ctrl_tx_ready)
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
    // Current scaffold forwards SERV response bytes directly.
    // A later revision inserts channel TX FIFOs + FCSP tx framer.
    assign ctrl_tx_ready = i_usb_tx_ready | spi_tx_ready;

    assign o_usb_tx_valid = ctrl_tx_valid;
    assign o_usb_tx_byte  = ctrl_tx_byte;

    assign spi_tx_valid = ctrl_tx_valid;
    assign spi_tx_byte  = ctrl_tx_byte;

    // Prevent unused warnings for observability-only wires in scaffold phase.
    logic _unused_ok;
    always_comb begin
        _unused_ok = ctrl_rx_ready ^ dshot_ready ^ neo_busy ^ parser_payload_len[0]
                   ^ pwm_width_ticks[0] ^ pwm_new_sample[0] ^ ctrl_tx_last;
    end
endmodule

`default_nettype wire
