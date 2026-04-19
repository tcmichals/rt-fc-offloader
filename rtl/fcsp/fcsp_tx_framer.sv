`default_nettype wire

// FCSP TX framer
//
// Captures one payload frame plus metadata, then emits a complete FCSP wire
// frame: sync, header, payload, crc16/xmodem(version..payload).
module fcsp_tx_framer #(
    parameter int MAX_PAYLOAD_LEN = 512
) (
    input  wire        clk,
    input  wire        rst,

    // Slave payload stream + metadata (one complete payload frame)
    input  wire        s_tvalid,
    input  wire [7:0]  s_tdata,
    input  wire        s_tlast,
    output logic        s_tready,
    input  wire [7:0]  s_channel,
    input  wire [7:0]  s_flags,
    input  wire [15:0] s_seq,
    input  wire        s_tdest,

    // Master byte stream (wire-format FCSP frame)
    output logic        m_tvalid,
    output logic [7:0]  m_tdata,
    input  wire        m_tready,

    // Status
    output logic        o_busy,
    output logic        o_overflow,
    output logic        o_frame_done,
    output wire        o_frame_tdest_latched
);
    localparam logic [7:0] FCSP_SYNC    = 8'hA5;
    localparam logic [7:0] FCSP_VERSION = 8'h01;
    localparam int PAYLOAD_INDEX_W = (MAX_PAYLOAD_LEN <= 1) ? 1 : $clog2(MAX_PAYLOAD_LEN);
    localparam logic [15:0] MAX_PAYLOAD_LEN_16 = MAX_PAYLOAD_LEN[15:0];

    typedef enum logic [3:0] {
        S_CAPTURE    = 4'd0,
        S_EMIT_SYNC  = 4'd1,
        S_EMIT_VER   = 4'd2,
        S_EMIT_FLAGS = 4'd3,
        S_EMIT_CHAN  = 4'd4,
        S_EMIT_SEQ_H = 4'd5,
        S_EMIT_SEQ_L = 4'd6,
        S_EMIT_LEN_H = 4'd7,
        S_EMIT_LEN_L = 4'd8,
        S_EMIT_PAYLD = 4'd9,
        S_EMIT_CRC_H = 4'd10,
        S_EMIT_CRC_L = 4'd11
    } state_t;

    state_t state;

    logic [7:0] payload_mem [0:MAX_PAYLOAD_LEN-1];
    logic [15:0] payload_count;
    logic [PAYLOAD_INDEX_W-1:0] emit_index;
    logic [7:0]  frame_channel;
    logic [7:0]  frame_flags;
    logic [15:0] frame_seq;
    logic        frame_tdest;
    logic        capture_active;
    logic        drop_frame;

    logic [15:0] crc_reg;
    logic [15:0] crc_next;
    logic [7:0]  crc_data_in;
    logic [15:0] emit_index_plus_one;

    // -----------------------------------------------------------------
    // Synchronous read port — enables BSRAM inference
    // -----------------------------------------------------------------
    logic [PAYLOAD_INDEX_W-1:0] mem_rd_addr;
    logic [7:0]                 mem_rd_data;

    always_comb begin
        mem_rd_addr = '0;
        case (state)
            S_EMIT_LEN_L:
                mem_rd_addr = '0;              // prime first payload byte
            S_EMIT_PAYLD: begin
                if (m_tvalid && m_tready)
                    mem_rd_addr = emit_index + 1'b1; // next byte
                else
                    mem_rd_addr = emit_index;        // hold
            end
            S_CAPTURE:
                mem_rd_addr = '0;              // prime for next frame
            default:
                mem_rd_addr = '0;
        endcase
    end

    always_ff @(posedge clk) begin
        mem_rd_data <= payload_mem[mem_rd_addr];
    end

    fcsp_crc16_core_xmodem u_crc_core (
        .data_in (crc_data_in),
        .crc_in  (crc_reg),
        .crc_out (crc_next)
    );

    always_comb begin
        s_tready = (state == S_CAPTURE);
        m_tvalid = (state != S_CAPTURE);
        o_busy   = (state != S_CAPTURE) || capture_active;

        unique case (state)
            S_EMIT_SYNC:  m_tdata = FCSP_SYNC;
            S_EMIT_VER:   m_tdata = FCSP_VERSION;
            S_EMIT_FLAGS: m_tdata = frame_flags;
            S_EMIT_CHAN:  m_tdata = frame_channel;
            S_EMIT_SEQ_H: m_tdata = frame_seq[15:8];
            S_EMIT_SEQ_L: m_tdata = frame_seq[7:0];
            S_EMIT_LEN_H: m_tdata = payload_count[15:8];
            S_EMIT_LEN_L: m_tdata = payload_count[7:0];
            S_EMIT_PAYLD: m_tdata = mem_rd_data;
            S_EMIT_CRC_H: m_tdata = crc_reg[15:8];
            S_EMIT_CRC_L: m_tdata = crc_reg[7:0];
            default:      m_tdata = 8'h00;
        endcase

        unique case (state)
            S_EMIT_VER:   crc_data_in = FCSP_VERSION;
            S_EMIT_FLAGS: crc_data_in = frame_flags;
            S_EMIT_CHAN:  crc_data_in = frame_channel;
            S_EMIT_SEQ_H: crc_data_in = frame_seq[15:8];
            S_EMIT_SEQ_L: crc_data_in = frame_seq[7:0];
            S_EMIT_LEN_H: crc_data_in = payload_count[15:8];
            S_EMIT_LEN_L: crc_data_in = payload_count[7:0];
            S_EMIT_PAYLD: crc_data_in = mem_rd_data;
            default:      crc_data_in = 8'h00;
        endcase

        emit_index_plus_one = {{(16-PAYLOAD_INDEX_W){1'b0}}, emit_index} + 16'd1;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state          <= S_CAPTURE;
            payload_count  <= 16'h0000;
            emit_index     <= '0;
            frame_channel  <= 8'h00;
            frame_flags    <= 8'h00;
            frame_seq      <= 16'h0000;
            frame_tdest    <= 1'b0;
            capture_active <= 1'b0;
            drop_frame     <= 1'b0;
            crc_reg        <= 16'h0000;
            o_overflow     <= 1'b0;
            o_frame_done   <= 1'b0;
        end else begin
            o_overflow   <= 1'b0;
            o_frame_done <= 1'b0;

            if ((state == S_CAPTURE) && s_tvalid && s_tready) begin
                if (!capture_active) begin
                    frame_channel  <= s_channel;
                    frame_flags    <= s_flags;
                    frame_seq      <= s_seq;
                    frame_tdest    <= s_tdest;
                    payload_count  <= 16'h0000;
                    capture_active <= 1'b1;
                    drop_frame     <= 1'b0;
                end

                if (!drop_frame) begin
                    if (payload_count < MAX_PAYLOAD_LEN_16) begin
                        payload_mem[payload_count[PAYLOAD_INDEX_W-1:0]] <= s_tdata;
                        payload_count <= payload_count + 16'd1;
                    end else begin
                        drop_frame <= 1'b1;
                        o_overflow <= 1'b1;
                    end
                end

                if (s_tlast) begin
                    capture_active <= 1'b0;
                    emit_index     <= '0;
                    crc_reg        <= 16'h0000;

                    if (drop_frame || (payload_count >= MAX_PAYLOAD_LEN_16)) begin
                        state        <= S_CAPTURE;
                        payload_count <= 16'h0000;
                    end else begin
                        state <= S_EMIT_SYNC;
                    end
                end
            end

            if ((state != S_CAPTURE) && m_tvalid && m_tready) begin
                unique case (state)
                    S_EMIT_SYNC: begin
                        crc_reg <= 16'h0000;
                        state   <= S_EMIT_VER;
                    end
                    S_EMIT_VER: begin
                        crc_reg <= crc_next;
                        state   <= S_EMIT_FLAGS;
                    end
                    S_EMIT_FLAGS: begin
                        crc_reg <= crc_next;
                        state   <= S_EMIT_CHAN;
                    end
                    S_EMIT_CHAN: begin
                        crc_reg <= crc_next;
                        state   <= S_EMIT_SEQ_H;
                    end
                    S_EMIT_SEQ_H: begin
                        crc_reg <= crc_next;
                        state   <= S_EMIT_SEQ_L;
                    end
                    S_EMIT_SEQ_L: begin
                        crc_reg <= crc_next;
                        state   <= S_EMIT_LEN_H;
                    end
                    S_EMIT_LEN_H: begin
                        crc_reg <= crc_next;
                        state   <= S_EMIT_LEN_L;
                    end
                    S_EMIT_LEN_L: begin
                        crc_reg <= crc_next;
                        if (payload_count == 16'h0000) begin
                            state <= S_EMIT_CRC_H;
                        end else begin
                            state <= S_EMIT_PAYLD;
                        end
                    end
                    S_EMIT_PAYLD: begin
                        crc_reg <= crc_next;
                        if (emit_index_plus_one >= payload_count) begin
                            emit_index <= '0;
                            state      <= S_EMIT_CRC_H;
                        end else begin
                            emit_index <= emit_index + {{(PAYLOAD_INDEX_W-1){1'b0}}, 1'b1};
                        end
                    end
                    S_EMIT_CRC_H: begin
                        state <= S_EMIT_CRC_L;
                    end
                    S_EMIT_CRC_L: begin
                        state        <= S_CAPTURE;
                        payload_count <= 16'h0000;
                        o_frame_done <= 1'b1;
                    end
                    default: begin
                        state <= S_CAPTURE;
                    end
                endcase
            end
        end
    end
    assign o_frame_tdest_latched = frame_tdest;
endmodule

`default_nettype wire