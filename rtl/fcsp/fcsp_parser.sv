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
    output logic [15:0] o_payload_len
);
    localparam logic [7:0] FCSP_SYNC = 8'hA5;
    localparam logic [15:0] MAX_PAYLOAD_LEN_U16 = logic'(MAX_PAYLOAD_LEN[15:0]);

    typedef enum logic [1:0] {
        S_SEARCH_SYNC = 2'd0,
        S_READ_HEADER = 2'd1,
        S_SKIP_BODY   = 2'd2
    } state_t;

    state_t state;
    logic [2:0] hdr_idx;
    logic [15:0] body_remaining;
    logic [15:0] payload_len_work;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state          <= S_SEARCH_SYNC;
            hdr_idx        <= 3'd0;
            body_remaining <= 16'd0;
            payload_len_work <= 16'd0;
            o_payload_len  <= 16'd0;
            o_sync_seen    <= 1'b0;
            o_header_valid <= 1'b0;
            o_len_error    <= 1'b0;
            o_frame_done   <= 1'b0;
        end else if (in_valid && in_ready) begin
            // default pulses low (set high only on event)
            o_sync_seen    <= 1'b0;
            o_header_valid <= 1'b0;
            o_len_error    <= 1'b0;
            o_frame_done   <= 1'b0;

            case (state)
                S_SEARCH_SYNC: begin
                    if (in_byte == FCSP_SYNC) begin
                        o_sync_seen <= 1'b1;
                        hdr_idx <= 3'd0;
                        payload_len_work <= 16'd0;
                        state <= S_READ_HEADER;
                    end
                end

                S_READ_HEADER: begin
                    // Header after sync:
                    // [0]=version [1]=flags [2]=channel [3]=seq_hi [4]=seq_lo [5]=len_hi [6]=len_lo
                    if (hdr_idx == 3'd5) begin
                        payload_len_work[15:8] <= in_byte;
                        hdr_idx <= 3'd6;
                    end else if (hdr_idx == 3'd6) begin
                        payload_len_work[7:0] <= in_byte;
                        o_payload_len <= {payload_len_work[15:8], in_byte};
                        hdr_idx <= 3'd0;

                        if ({payload_len_work[15:8], in_byte} > MAX_PAYLOAD_LEN_U16) begin
                            o_len_error <= 1'b1;
                            state <= S_SEARCH_SYNC;
                        end else begin
                            // body bytes after header are payload + CRC16 (2 bytes)
                            body_remaining <= {payload_len_work[15:8], in_byte} + 16'd2;
                            o_header_valid <= 1'b1;
                            state <= S_SKIP_BODY;
                        end
                    end else begin
                        hdr_idx <= hdr_idx + 3'd1;
                    end
                end

                S_SKIP_BODY: begin
                    if (body_remaining != 16'd0) begin
                        body_remaining <= body_remaining - 16'd1;

                        // Pulse done when this accepted byte consumes the final
                        // remaining body byte (payload + CRC16).
                        if ((body_remaining - 16'd1) == 16'd0) begin
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
        end
    end

    assign in_ready = 1'b1;
endmodule

`default_nettype wire
