`default_nettype none

// FCSP IO engines wrapper (Pure Hardware Strategy)
//
// Integrates:
// - DShot Controller (4-channel Wishbone Slave)
// - NeoPixel (WS2812) Status LED Controller
// - Passthrough Mode register (0x020) for ESC bootloader entry sequence.
module fcsp_io_engines #(
    parameter CLK_FREQ_HZ = 54_000_000,
    parameter int MOTOR_COUNT = 4
) (
    input  logic                    clk,
    input  logic                    rst,

    // Wishbone Slave interface
    input  logic [31:0]             wb_adr_i,
    input  logic [31:0]             wb_dat_i,
    input  logic [3:0]              wb_sel_i,
    input  logic                    wb_we_i,
    input  logic                    wb_cyc_i,
    input  logic                    wb_stb_i,
    output logic                    wb_ack_o,
    output logic [31:0]             wb_dat_o,

    // Physical Motor Control Outputs
    output logic [MOTOR_COUNT-1:0]    o_motor_pins,
    output logic                      o_neo_data,
    output logic                      o_neo_busy,

    // Hardware Bypassed ESC Serial Path
    input  logic                    s_esc_rx_tvalid,
    input  logic [7:0]              s_esc_rx_tdata,
    input  logic                    s_esc_rx_tlast,
    output logic                    s_esc_rx_tready,

    output logic                    m_esc_tx_tvalid,
    output logic [7:0]              m_esc_tx_tdata,
    output logic                    m_esc_tx_tlast,
    input  logic                    m_esc_tx_tready,

    // Status for Debug Trace
    output logic                    o_passthrough_active,
    output logic                    o_break_signal_active
);

    // Internal Sub-Bus Decoding
    logic        sel_dshot, sel_neo, sel_mode;
    assign sel_dshot = (wb_adr_i[11:8] == 4'h0); // 0x000-0x0FF
    assign sel_neo   = (wb_adr_i[11:8] == 4'h1); // 0x100-0x1FF
    assign sel_mode  = (wb_adr_i[11:0] == 12'h020);

    // Mode Signals
    logic        passthrough_mode;
    logic [1:0]  esc_ch_select;
    logic        force_low;
    assign o_passthrough_active  = passthrough_mode;
    assign o_break_signal_active = force_low;

    // Sub-Engine Data/ACK Paths
    logic        wb_ack_dshot, wb_ack_neo;
    logic [31:0] wb_dat_dshot, wb_dat_neo;
    logic [3:0]  dshot_out, dshot_ready;

    // 1) DShot Engine (Motors)
    fcsp_dshot_engine #( .CLK_FREQ_HZ(CLK_FREQ_HZ) ) u_dshot_eng (
        .clk(clk), .rst(rst),
        .wb_adr_i(wb_adr_i), .wb_dat_i(wb_dat_i), .wb_we_i(wb_we_i), .wb_cyc_i(wb_cyc_i && sel_dshot), .wb_stb_i(wb_stb_i && sel_dshot),
        .wb_ack_o(wb_ack_dshot), .wb_dat_o(wb_dat_dshot),
        .o_motor_pins(dshot_out), .o_ready(dshot_ready)
    );

    // 2) NeoPixel Engine (Status LED)
    fcsp_neo_engine #( .CLK_FREQ_HZ(CLK_FREQ_HZ) ) u_neo_eng (
        .clk(clk), .rst(rst),
        .wb_adr_i(wb_adr_i), .wb_dat_i(wb_dat_i), .wb_we_i(wb_we_i), .wb_cyc_i(wb_cyc_i && sel_neo), .wb_stb_i(wb_stb_i && sel_neo),
        .wb_ack_o(wb_ack_neo), .wb_dat_o(wb_dat_neo),
        .o_neo_data(o_neo_data), .o_neo_busy(o_neo_busy)
    );

    // Mode Register & Top-level ACK Steering
    always_ff @(posedge clk) begin
        if (rst) begin
            wb_ack_o         <= 1'b0;
            wb_dat_o         <= 32'h0;
            passthrough_mode <= 1'b0;
            esc_ch_select    <= 2'b0;
            force_low        <= 1'b0;
        end else begin
            wb_ack_o <= 1'b0;
            
            if (sel_dshot) begin
                wb_ack_o <= wb_ack_dshot;
                wb_dat_o <= wb_dat_dshot;
            end else if (sel_neo) begin
                wb_ack_o <= wb_ack_neo;
                wb_dat_o <= wb_dat_neo;
            end else if (sel_mode && wb_cyc_i && wb_stb_i && !wb_ack_o) begin
                wb_ack_o <= 1'b1;
                if (wb_we_i) begin
                    passthrough_mode <= wb_dat_i[0];
                    esc_ch_select    <= wb_dat_i[2:1];
                    force_low        <= wb_dat_i[4];
                end else begin
                    wb_dat_o <= {27'h0, force_low, 1'b0, esc_ch_select, passthrough_mode};
                end
            end
        end
    end

    // Physical Pin Multiplexing (Actuation Plane)
    logic esc_tunnel_out;
    assign esc_tunnel_out = s_esc_rx_tvalid ? s_esc_rx_tdata[0] : 1'b1; // Default HIGH for Serial IDLE

    always_comb begin
        o_motor_pins = '0; 
        if (force_low) begin
            o_motor_pins = '0; 
        end else if (passthrough_mode) begin
            o_motor_pins[esc_ch_select] = esc_tunnel_out;
        end else begin
            o_motor_pins = dshot_out;
        end
    end

    // ESC Path Feedback
    assign s_esc_rx_tready = m_esc_tx_tready;
    assign m_esc_tx_tvalid = s_esc_rx_tvalid;
    assign m_esc_tx_tdata  = s_esc_rx_tdata;
    assign m_esc_tx_tlast  = s_esc_rx_tlast;

endmodule

`default_nettype wire
