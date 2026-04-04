`default_nettype none

module fcsp_parser #(
    parameter int MAX_PAYLOAD_LEN = 512
) (
    input  logic clk,
    input  logic rst_n,
    input  logic in_valid,
    input  logic [7:0] in_byte,
    output logic in_ready,

    // Status pulses (1 cycle)
    output logic o_sync_seen,
    output logic o_header_valid,
    output logic o_len_error,
    output logic o_frame_done,

    // Header observability
    output logic [15:0] o_payload_len,

    // Parsed payload stream + frame metadata
    output logic        m_frame_tvalid,
    output logic [7:0]  m_frame_tdata,
    output logic        m_frame_tlast,
    input  logic        m_frame_tready,
    output logic [7:0]  m_frame_version,
    output logic [7:0]  m_frame_channel,
    output logic [7:0]  m_frame_flags,
    output logic [15:0] m_frame_seq,
    output logic [15:0] m_frame_payload_len,
    output logic [15:0] o_frame_recv_crc
);
    localparam logic [7:0] FCSP_SYNC = 8'hA5;
    localparam logic [15:0] MAX_PAYLOAD_LEN_U16 = MAX_PAYLOAD_LEN[15:0];

    typedef enum logic [1:0] {
        S_SEARCH_SYNC = 2'd0,
        S_READ_HEADER = 2'd1,
        S_STREAM_PAYLOAD = 2'd2,
        S_SKIP_CRC       = 2'd3
    } state_t;

    state_t state;
    logic [2:0] hdr_idx;
    logic [15:0] body_remaining;
    logic [15:0] payload_remaining;
    logic [15:0] payload_len_work;
    logic        frame_out_valid;
    logic [7:0]  frame_out_data;
    logic        frame_out_last;

    assign m_frame_tvalid = frame_out_valid;
    assign m_frame_tdata  = frame_out_data;
    assign m_frame_tlast  = frame_out_last;

    always_comb begin
        if (state == S_STREAM_PAYLOAD) begin
            in_ready = ~frame_out_valid || m_frame_tready;
        end else begin
            in_ready = 1'b1;
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state          <= S_SEARCH_SYNC;
            hdr_idx        <= 3'd0;
            body_remaining <= 16'd0;
            payload_remaining <= 16'd0;
            payload_len_work <= 16'd0;
            frame_out_valid <= 1'b0;
            frame_out_data <= 8'd0;
            frame_out_last <= 1'b0;
            o_payload_len  <= 16'd0;
            o_frame_recv_crc <= 16'd0;
            o_sync_seen    <= 1'b0;
            o_header_valid <= 1'b0;
            o_len_error    <= 1'b0;
            o_frame_done   <= 1'b0;
            m_frame_version <= 8'd0;
            m_frame_channel <= 8'd0;
            m_frame_flags <= 8'd0;
            m_frame_seq <= 16'd0;
            m_frame_payload_len <= 16'd0;
        end else if (in_valid && in_ready) begin
            // default pulses low (set high only on event)
            o_sync_seen    <= 1'b0;
            o_header_valid <= 1'b0;
            o_len_error    <= 1'b0;
            o_frame_done   <= 1'b0;

            if (frame_out_valid && m_frame_tready) begin
                frame_out_valid <= 1'b0;
                frame_out_last <= 1'b0;
            end

            case (state)
                S_SEARCH_SYNC: begin
                    if (in_byte == FCSP_SYNC) begin
                        o_sync_seen <= 1'b1;
                        hdr_idx <= 3'd0;
                        payload_len_work <= 16'd0;
                        body_remaining <= 16'd0;
                        payload_remaining <= 16'd0;
                        state <= S_READ_HEADER;
                    end
                end

                S_READ_HEADER: begin
                    // Header after sync:
                    // [0]=version [1]=flags [2]=channel [3]=seq_hi [4]=seq_lo [5]=len_hi [6]=len_lo
                    unique case (hdr_idx)
                        3'd0: begin
                            m_frame_version <= in_byte;
                            hdr_idx <= 3'd1;
                        end
                        3'd1: begin
                            m_frame_flags <= in_byte;
                            hdr_idx <= 3'd2;
                        end
                        3'd2: begin
                            m_frame_channel <= in_byte;
                            hdr_idx <= 3'd3;
                        end
                        3'd3: begin
                            m_frame_seq[15:8] <= in_byte;
                            hdr_idx <= 3'd4;
                        end
                        3'd4: begin
                            m_frame_seq[7:0] <= in_byte;
                            hdr_idx <= 3'd5;
                        end
                        3'd5: begin
                            payload_len_work[15:8] <= in_byte;
                            hdr_idx <= 3'd6;
                        end
                        3'd6: begin
                            payload_len_work[7:0] <= in_byte;
                            o_payload_len <= {payload_len_work[15:8], in_byte};
                            m_frame_payload_len <= {payload_len_work[15:8], in_byte};
                            hdr_idx <= 3'd0;

                            if ({payload_len_work[15:8], in_byte} > MAX_PAYLOAD_LEN_U16) begin
                                o_len_error <= 1'b1;
                                state <= S_SEARCH_SYNC;
                            end else begin
                                // Remaining bytes after header are payload + CRC16.
                                body_remaining <= {payload_len_work[15:8], in_byte} + 16'd2;
                                payload_remaining <= {payload_len_work[15:8], in_byte};
                                o_header_valid <= 1'b1;
                                if ({payload_len_work[15:8], in_byte} == 16'd0) begin
                                    state <= S_SKIP_CRC;
                                end else begin
                                    state <= S_STREAM_PAYLOAD;
                                end
                            end
                        end
                        default: begin
                            hdr_idx <= 3'd0;
                            state <= S_SEARCH_SYNC;
                        end
                    endcase
                end

                S_STREAM_PAYLOAD: begin
                    if (payload_remaining != 16'd0) begin
                        frame_out_valid <= 1'b1;
                        frame_out_data <= in_byte;
                        frame_out_last <= (payload_remaining == 16'd1);
                        payload_remaining <= payload_remaining - 16'd1;
                        body_remaining <= body_remaining - 16'd1;

                        if (payload_remaining == 16'd1) begin
                            state <= S_SKIP_CRC;
                        end
                    end else begin
                        state <= S_SKIP_CRC;
                    end
                end

                S_SKIP_CRC: begin
                    if (body_remaining != 16'd0) begin
                        if (body_remaining == 16'd2) begin
                            o_frame_recv_crc[15:8] <= in_byte;
                        end else if (body_remaining == 16'd1) begin
                            o_frame_recv_crc[7:0] <= in_byte;
                        end

                        body_remaining <= body_remaining - 16'd1;

                        // Pulse done when this accepted byte consumes the final
                        // remaining body byte (payload + CRC16). Payload bytes,
                        // if any, have already been emitted on m_frame_*.
                        if (body_remaining == 16'd1) begin
                            o_frame_done <= 1'b1;
                            state <= S_SEARCH_SYNC;
                        end
                    end else begin
                        state <= S_SEARCH_SYNC;
                    end
                end

                default: begin
                    state <= S_SEARCH_SYNC;
                end
            endcase
        end else begin
            // no accepted byte this cycle: clear pulse outputs
            o_sync_seen    <= 1'b0;
            o_header_valid <= 1'b0;
            o_len_error    <= 1'b0;
            o_frame_done   <= 1'b0;

            if (frame_out_valid && m_frame_tready) begin
                frame_out_valid <= 1'b0;
                frame_out_last <= 1'b0;
            end
        end
    end
endmodule

`default_nettype wire
