`default_nettype none

// FCSP CRC validation gate
//
// Reuses the existing fcsp_crc16 frame-level CRC engine while buffering one
// parsed payload so only CRC-clean frames are released downstream.
module fcsp_crc_gate #(
    parameter int MAX_PAYLOAD_LEN = 512
) (
    input  logic        clk,
    input  logic        rst,

    // Parsed frame payload + metadata from parser
    input  logic        s_frame_tvalid,
    input  logic [7:0]  s_frame_tdata,
    input  logic        s_frame_tlast,
    output logic        s_frame_tready,
    input  logic [7:0]  s_frame_version,
    input  logic [7:0]  s_frame_channel,
    input  logic [7:0]  s_frame_flags,
    input  logic [15:0] s_frame_seq,
    input  logic [15:0] s_frame_payload_len,
    input  logic [15:0] s_frame_recv_crc,
    input  logic        s_frame_done,

    // CRC-clean frame payload + metadata toward router
    output logic        m_frame_tvalid,
    output logic [7:0]  m_frame_tdata,
    output logic        m_frame_tlast,
    input  logic        m_frame_tready,
    output logic [7:0]  m_frame_version,
    output logic [7:0]  m_frame_channel,
    output logic [7:0]  m_frame_flags,
    output logic [15:0] m_frame_seq,
    output logic [15:0] m_frame_payload_len,

    // Status pulses
    output logic        o_crc_valid,
    output logic        o_crc_ok,
    output logic        o_crc_drop
);
    typedef enum logic [1:0] {
        S_CAPTURE  = 2'd0,
        S_FEED_CRC = 2'd1,
        S_WAIT_CRC = 2'd2,
        S_STREAM   = 2'd3
    } state_t;

    localparam logic [7:0] DEFAULT_VERSION = 8'h01;
    localparam int PAYLOAD_IDX_W = (MAX_PAYLOAD_LEN <= 1) ? 1 : $clog2(MAX_PAYLOAD_LEN);
    localparam logic [15:0] MAX_PAYLOAD_LEN_U16 = MAX_PAYLOAD_LEN[15:0];

    state_t state;
    logic [7:0] payload_mem [0:MAX_PAYLOAD_LEN-1];
    logic [15:0] capture_count;
    logic [15:0] stream_idx;
    logic [3:0] crc_feed_idx;
    logic [15:0] crc_payload_idx;
    logic [PAYLOAD_IDX_W-1:0] capture_addr;
    logic [PAYLOAD_IDX_W-1:0] stream_addr;
    logic [PAYLOAD_IDX_W-1:0] crc_payload_addr;

    logic [7:0] frame_version_reg;
    logic [7:0] frame_channel_reg;
    logic [7:0] frame_flags_reg;
    logic [15:0] frame_seq_reg;
    logic [15:0] frame_payload_len_reg;
    logic [15:0] frame_recv_crc_reg;
    logic        meta_latched;

    logic        crc_frame_start;
    logic        crc_data_valid;
    logic [7:0]  crc_data_byte;
    logic        crc_frame_end;
    logic [15:0] crc_value;
    logic        crc_valid;
    logic        crc_ok;

    assign capture_addr = capture_count[PAYLOAD_IDX_W-1:0];
    assign stream_addr = stream_idx[PAYLOAD_IDX_W-1:0];
    assign crc_payload_addr = crc_payload_idx[PAYLOAD_IDX_W-1:0];

    function automatic logic [7:0] crc_feed_byte(
        input logic [3:0] idx,
        input logic [7:0] version,
        input logic [7:0] flags,
        input logic [7:0] channel,
        input logic [15:0] seq,
        input logic [15:0] payload_len,
        input logic [15:0] payload_idx,
        input logic [7:0] payload_value
    );
        begin
            unique case (idx)
                4'd0: crc_feed_byte = version;
                4'd1: crc_feed_byte = flags;
                4'd2: crc_feed_byte = channel;
                4'd3: crc_feed_byte = seq[15:8];
                4'd4: crc_feed_byte = seq[7:0];
                4'd5: crc_feed_byte = payload_len[15:8];
                4'd6: crc_feed_byte = payload_len[7:0];
                default: crc_feed_byte = payload_value;
            endcase
        end
    endfunction

    assign s_frame_tready = (state == S_CAPTURE);

    assign m_frame_tvalid = (state == S_STREAM) && (stream_idx < frame_payload_len_reg);
    assign m_frame_tdata  = payload_mem[stream_addr];
    assign m_frame_tlast  = (stream_idx == (frame_payload_len_reg - 16'd1));
    assign m_frame_version = frame_version_reg;
    assign m_frame_channel = frame_channel_reg;
    assign m_frame_flags = frame_flags_reg;
    assign m_frame_seq = frame_seq_reg;
    assign m_frame_payload_len = frame_payload_len_reg;

    always_comb begin
        crc_data_valid = 1'b0;
        crc_frame_start = 1'b0;
        crc_frame_end = 1'b0;
        crc_data_byte = 8'h00;

        if (state == S_FEED_CRC) begin
            crc_data_valid = 1'b1;
            crc_frame_start = (crc_feed_idx == 4'd0);
            crc_data_byte = crc_feed_byte(
                crc_feed_idx,
                frame_version_reg,
                frame_flags_reg,
                frame_channel_reg,
                frame_seq_reg,
                frame_payload_len_reg,
                crc_payload_idx,
                payload_mem[crc_payload_addr]
            );
            crc_frame_end = ((crc_feed_idx == 4'd6) && (frame_payload_len_reg == 16'd0))
                         || ((crc_feed_idx == 4'd7) && (crc_payload_idx == (frame_payload_len_reg - 16'd1)));
        end
    end

    fcsp_crc16 u_crc16 (
        .clk         (clk),
        .rst         (rst),
        .i_frame_start(crc_frame_start),
        .i_data_valid(crc_data_valid),
        .i_data_byte (crc_data_byte),
        .i_frame_end (crc_frame_end),
        .i_recv_crc  (frame_recv_crc_reg),
        .o_crc_value (crc_value),
        .o_crc_valid (crc_valid),
        .o_crc_ok    (crc_ok)
    );

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= S_CAPTURE;
            capture_count <= 16'd0;
            stream_idx <= 16'd0;
            crc_feed_idx <= 4'd0;
            crc_payload_idx <= 16'd0;
            frame_version_reg <= DEFAULT_VERSION;
            frame_channel_reg <= 8'd0;
            frame_flags_reg <= 8'd0;
            frame_seq_reg <= 16'd0;
            frame_payload_len_reg <= 16'd0;
            frame_recv_crc_reg <= 16'd0;
            meta_latched <= 1'b0;
            o_crc_valid <= 1'b0;
            o_crc_ok <= 1'b0;
            o_crc_drop <= 1'b0;
        end else begin
            o_crc_valid <= 1'b0;
            o_crc_ok <= 1'b0;
            o_crc_drop <= 1'b0;

            case (state)
                S_CAPTURE: begin
                    if (!meta_latched && (s_frame_tvalid || s_frame_done)) begin
                        frame_version_reg <= s_frame_version;
                        frame_channel_reg <= s_frame_channel;
                        frame_flags_reg <= s_frame_flags;
                        frame_seq_reg <= s_frame_seq;
                        frame_payload_len_reg <= s_frame_payload_len;
                        meta_latched <= 1'b1;
                    end

                    if (s_frame_tvalid && s_frame_tready && (capture_count < MAX_PAYLOAD_LEN_U16)) begin
                        payload_mem[capture_addr] <= s_frame_tdata;
                        capture_count <= capture_count + 16'd1;
                    end

                    if (s_frame_done) begin
                        frame_recv_crc_reg <= s_frame_recv_crc;
                        crc_feed_idx <= 4'd0;
                        crc_payload_idx <= 16'd0;
                        stream_idx <= 16'd0;
                        state <= S_FEED_CRC;
                    end
                end

                S_FEED_CRC: begin
                    if (crc_feed_idx < 4'd6) begin
                        crc_feed_idx <= crc_feed_idx + 4'd1;
                    end else if (crc_feed_idx == 4'd6) begin
                        if (frame_payload_len_reg == 16'd0) begin
                            state <= S_WAIT_CRC;
                        end else begin
                            crc_feed_idx <= 4'd7;
                            crc_payload_idx <= 16'd0;
                        end
                    end else begin
                        if (crc_payload_idx == (frame_payload_len_reg - 16'd1)) begin
                            state <= S_WAIT_CRC;
                        end else begin
                            crc_payload_idx <= crc_payload_idx + 16'd1;
                        end
                    end
                end

                S_WAIT_CRC: begin
                    if (crc_valid) begin
                        o_crc_valid <= 1'b1;
                        o_crc_ok <= crc_ok;
                        o_crc_drop <= ~crc_ok;
                        if (crc_ok && (frame_payload_len_reg != 16'd0)) begin
                            stream_idx <= 16'd0;
                            state <= S_STREAM;
                        end else begin
                            capture_count <= 16'd0;
                            meta_latched <= 1'b0;
                            state <= S_CAPTURE;
                        end
                    end
                end

                S_STREAM: begin
                    if (m_frame_tvalid && m_frame_tready) begin
                        if (m_frame_tlast) begin
                            capture_count <= 16'd0;
                            meta_latched <= 1'b0;
                            state <= S_CAPTURE;
                        end else begin
                            stream_idx <= stream_idx + 16'd1;
                        end
                    end
                end

                default: begin
                    state <= S_CAPTURE;
                end
            endcase
        end
    end

    logic _unused_ok;
    always_comb begin
        _unused_ok = ^crc_value ^ s_frame_tlast;
    end
endmodule

`default_nettype wire
