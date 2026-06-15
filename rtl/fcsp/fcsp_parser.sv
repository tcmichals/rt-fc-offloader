`default_nettype wire

module fcsp_parser #(
    parameter int MAX_PAYLOAD_LEN = 512,
    parameter int TIMEOUT_USEC    = 10000,
    parameter int CLK_HZ          = 54_000_000
) (
    input  wire clk,
    input  wire rst_n,
    input  wire clr,
    input  wire in_valid,
    input  wire [7:0] in_byte,
    output logic in_ready,

    // Status pulses (1 cycle)
    output logic o_sync_seen,
    output logic o_header_valid,
    output logic o_len_error,
    output logic o_frame_done,
    output logic o_parser_idle,

    // Statistics
    output logic [31:0] o_frame_count,
    output logic [31:0] o_timeout_count,
    output logic [31:0] o_error_count,

    // Header observability
    output logic [15:0] o_payload_len,

    // AXI-Stream frame out (version, channel, flags, seq, payload_len + payload)
    output logic        m_frame_tvalid,
    output logic [7:0]  m_frame_tdata,
    output logic        m_frame_tlast,
    input  wire         m_frame_tready,

    // Frame attributes for the router
    output logic [7:0]  m_frame_version,
    output logic [7:0]  m_frame_channel,
    output logic [7:0]  m_frame_flags,
    output logic [15:0] m_frame_seq,
    output logic [15:0] m_frame_payload_len,
    output logic [15:0] o_frame_recv_crc
);
    localparam logic [7:0] FCSP_SYNC = 8'hA5;

    typedef enum logic [2:0] {
        S_SEARCH_SYNC,
        S_READ_HEADER,
        S_PAYLOAD,
        S_READ_CRC,
        S_DONE
    } state_t;

    state_t state;
    logic [2:0]  hdr_idx;
    logic [15:0] payload_cnt;
    logic [15:0] payload_len_work;
    logic        crc_idx;

    logic        frame_out_valid;
    logic [7:0]  frame_out_data;
    logic        frame_out_last;

    assign m_frame_tvalid = frame_out_valid;
    assign m_frame_tdata  = frame_out_data;
    assign m_frame_tlast  = frame_out_last;
    assign o_parser_idle  = (state == S_SEARCH_SYNC);
    assign in_ready       = (state == S_SEARCH_SYNC) || (state == S_READ_HEADER) || 
                            ((state == S_PAYLOAD) && (!frame_out_valid || m_frame_tready)) || 
                            (state == S_READ_CRC);

    logic [31:0] timeout_cnt;
    // Use 64-bit intermediate to prevent overflow at high clock rates
    localparam int TIMEOUT_CYCLES = int'((TIMEOUT_USEC * 64'(CLK_HZ)) / 1_000_000);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state          <= S_SEARCH_SYNC;
            hdr_idx        <= 3'd0;
            payload_cnt    <= 16'd0;
            payload_len_work <= 16'd0;
            crc_idx        <= 1'b0;
            frame_out_valid <= 1'b0;
            frame_out_data <= 8'd0;
            frame_out_last <= 1'b0;
            o_payload_len  <= 16'd0;
            timeout_cnt    <= 32'd0;
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
            o_frame_count  <= 32'd0;
            o_timeout_count <= 32'd0;
            o_error_count  <= 32'd0;
        end else begin
            // Pulse deassertion
            o_sync_seen    <= 1'b0;
            o_header_valid <= 1'b0;
            o_len_error    <= 1'b0;
            o_frame_done   <= 1'b0;
            
            if (clr) begin
                state <= S_SEARCH_SYNC;
                timeout_cnt <= 0;
                frame_out_valid <= 1'b0;
                frame_out_last <= 1'b0;
                // Optional: we could increment o_error_count if state != S_SEARCH_SYNC
                if (state != S_SEARCH_SYNC) begin
                    o_error_count <= o_error_count + 32'd1;
                end
            end else begin
                // Timeout logic
                if (in_valid) begin
                    timeout_cnt <= 0;
                end else if (state != S_SEARCH_SYNC) begin
                    if (timeout_cnt >= TIMEOUT_CYCLES) begin
                        state <= S_SEARCH_SYNC;
                        timeout_cnt <= 0;
                        o_timeout_count <= o_timeout_count + 32'd1;
                        o_error_count <= o_error_count + 32'd1;
                        frame_out_valid <= 1'b0;
                        frame_out_last <= 1'b0;
                    end else begin
                        timeout_cnt <= timeout_cnt + 1;
                    end
                end

                if (frame_out_valid && m_frame_tready) begin
                    frame_out_valid <= 1'b0;
                    frame_out_last  <= 1'b0;
                end

                case (state)
                    S_SEARCH_SYNC: begin
                        if (in_valid && in_byte == FCSP_SYNC) begin
                            o_sync_seen <= 1'b1;
                            hdr_idx     <= 3'd0;
                            state       <= S_READ_HEADER;
                        end
                    end

                    S_READ_HEADER: begin
                        if (in_valid) begin
                            case (hdr_idx)
                                0: m_frame_version <= in_byte;
                                1: m_frame_flags   <= in_byte;
                                2: m_frame_channel <= in_byte;
                                3: m_frame_seq[15:8] <= in_byte;
                                4: m_frame_seq[7:0]  <= in_byte;
                                5: payload_len_work[15:8] <= in_byte;
                                6: begin
                                    payload_len_work[7:0] <= in_byte;
                                    m_frame_payload_len   <= {payload_len_work[15:8], in_byte};
                                    o_payload_len         <= {payload_len_work[15:8], in_byte};
                                    if ({payload_len_work[15:8], in_byte} > MAX_PAYLOAD_LEN) begin
                                        o_len_error <= 1'b1;
                                        o_error_count <= o_error_count + 32'd1;
                                        state       <= S_SEARCH_SYNC;
                                    end else begin
                                        o_header_valid <= 1'b1;
                                        payload_cnt    <= 16'd0;
                                        if ({payload_len_work[15:8], in_byte} == 0)
                                            state <= S_READ_CRC;
                                        else
                                            state <= S_PAYLOAD;
                                    end
                                end
                            endcase
                            hdr_idx <= hdr_idx + 3'd1;
                        end
                    end

                    S_PAYLOAD: begin
                        if (in_valid && in_ready) begin
                            frame_out_valid <= 1'b1;
                            frame_out_data  <= in_byte;
                            payload_cnt     <= payload_cnt + 16'd1;
                            // Fixed off-by-one: use >= instead of == to handle edge cases
                            if (payload_cnt + 16'd1 >= m_frame_payload_len) begin
                                frame_out_last <= 1'b1;
                                state          <= S_READ_CRC;
                                crc_idx        <= 1'b0;
                            end
                        end
                    end

                    S_READ_CRC: begin
                        if (in_valid) begin
                            if (crc_idx == 0) begin
                                o_frame_recv_crc[15:8] <= in_byte;
                                crc_idx <= 1'b1;
                            end else begin
                                o_frame_recv_crc[7:0] <= in_byte;
                                o_frame_done <= 1'b1;
                                o_frame_count <= o_frame_count + 32'd1;
                                state        <= S_SEARCH_SYNC;
                            end
                        end
                    end

                    default: state <= S_SEARCH_SYNC;
                endcase
            end
        end
    end
endmodule
