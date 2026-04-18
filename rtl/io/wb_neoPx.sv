// Wishbone NeoPixel Controller (WS2812/SK6812)
// Ported from legacy wb_neoPx.v
//
// 8-pixel buffer with Wishbone write; drives sendPx_axis_flexible.
//
// Address map (byte offsets):
//   0x00–0x1C: Pixel 0–7 (32-bit RGBW each)
//   0x20+:     Trigger update (any write)
//
// Source: /media/tcmichals/projects/Tang9K/HacksterIO/SPIQuadCopter/neoPXStrip/wb_neoPx.v

`default_nettype wire

module wb_neoPx #(
    parameter int CLK_FREQ_HZ = 54_000_000,
    parameter int LED_TYPE    = 0           // 0=WS2812, 1=SK6812
) (
    input  wire        clk,
    input  wire        rst,

    // Wishbone slave
    input  wire [31:0] wb_adr_i,
    input  wire [31:0] wb_dat_i,
    output wire [31:0] wb_dat_o,
    input  wire        wb_we_i,
    input  wire [3:0]  wb_sel_i,
    input  wire        wb_stb_i,
    input  wire        wb_cyc_i,
    output wire        wb_ack_o,

    // NeoPixel serial output
    output wire        o_serial
);

    // Pixel buffer (8 × 32-bit)
    logic [31:0] ledData [0:7];

    logic        ack;
    logic        update_req;
    logic        tvalid;
    logic [3:0]  state;
    logic [3:0]  count;
    logic        sendState;
    logic        isReady;

    wire [31:0]  m_axis_data = ledData[count[2:0]];
    wire         tlast       = (count == 4'd7);

    assign wb_ack_o = ack;
    assign wb_dat_o = (wb_adr_i[5:0] <= 6'h1C) ? ledData[wb_adr_i[4:2]] : 32'h0;

    // Wishbone write logic
    always_ff @(posedge clk) begin
        if (rst) begin
            ack        <= 1'b0;
            update_req <= 1'b0;
            for (int i = 0; i < 8; i++) ledData[i] <= 32'h0;
        end else begin
            if (wb_cyc_i && wb_stb_i && !ack) begin
                ack <= 1'b1;
                if (wb_we_i) begin
                    if (wb_adr_i[5:0] <= 6'h1C)
                        ledData[wb_adr_i[4:2]] <= wb_dat_i;
                    else
                        update_req <= 1'b1;
                end
            end else begin
                ack <= 1'b0;
                if (state != 4'd0) update_req <= 1'b0;
            end
        end
    end

    // FSM: walk through pixels and push to AXIS sender
    always_ff @(posedge clk) begin
        if (rst) begin
            state     <= 4'd0;
            tvalid    <= 1'b0;
            count     <= 4'd0;
            sendState <= 1'b0;
        end else begin
            case (state)
                4'd0: begin // IDLE
                    count  <= 4'd0;
                    tvalid <= 1'b0;
                    if (update_req) state <= 4'd1;
                end
                4'd9: state <= 4'd0; // DONE
                default: begin
                    if (!sendState) begin
                        if (isReady) begin
                            tvalid    <= 1'b1;
                            sendState <= 1'b1;
                        end
                    end else if (isReady && tvalid) begin
                        tvalid    <= 1'b0;
                        sendState <= 1'b0;
                        if (count == 4'd7)
                            state <= 4'd9;
                        else begin
                            count <= count + 4'd1;
                            state <= state + 4'd1;
                        end
                    end
                end
            endcase
        end
    end

    // Instantiate AXIS NeoPixel sender
    sendPx_axis_flexible #(
        .CLK_FREQ_HZ(CLK_FREQ_HZ),
        .LED_TYPE(LED_TYPE)
    ) u_sender (
        .clk           (clk),
        .rst           (rst),
        .s_axis_tdata  (m_axis_data),
        .s_axis_tvalid (tvalid),
        .s_axis_tlast  (tlast),
        .s_axis_tready (isReady),
        .o_serial      (o_serial)
    );

    // Suppress unused-signal lint
    logic _unused;
    always_comb _unused = &{wb_sel_i, wb_adr_i[31:6]};

endmodule

`default_nettype wire
