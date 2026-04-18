/**
 * fcsp_stream_packetizer
 *
 * Buffers raw bytes into FCSP-ready payload frames.
 * - Emits a frame when it reaches MAX_LEN.
 * - Emits a partial frame if TIMEOUT cycles pass without new bytes.
 */

`default_nettype wire

module fcsp_stream_packetizer #(
    parameter int MAX_LEN = 16,
    parameter int TIMEOUT = 1000  // Cycles (~18us at 54MHz)
) (
    input  wire        clk,
    input  wire        rst,

    // Ingress (raw bytes)
    input  wire [7:0]  s_tdata,
    input  wire        s_tvalid,
    output wire        s_tready,

    // Egress (Framed payload)
    output logic [7:0]  m_tdata,
    output logic        m_tvalid,
    output logic        m_tlast,
    input  wire        m_tready
);

    logic [7:0]  mem [0:MAX_LEN-1];
    logic [7:0]  count;
    logic [31:0] timer;

    typedef enum logic [1:0] {
        S_IDLE = 2'd0,
        S_FILL = 2'd1,
        S_PUSH = 2'd2
    } state_t;

    state_t state;
    logic [7:0] push_idx;

    assign s_tready = (state == S_FILL) && (count < MAX_LEN);

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= S_FILL;
            count <= 8'd0;
            timer <= 32'd0;
            push_idx <= 8'd0;
            m_tvalid <= 1'b0;
            m_tlast  <= 1'b0;
        end else begin
            case (state)
                S_FILL: begin
                    if (s_tvalid && s_tready) begin
                        mem[count] <= s_tdata;
                        count <= count + 8'd1;
                        timer <= 32'd0;
                        if (count == MAX_LEN-1) begin
                            state <= S_PUSH;
                            push_idx <= 8'd0;
                        end
                    end else if (count > 0) begin
                        if (timer >= TIMEOUT) begin
                            state <= S_PUSH;
                            push_idx <= 8'd0;
                        end else begin
                            timer <= timer + 32'd1;
                        end
                    end
                end

                S_PUSH: begin
                    if (!m_tvalid || m_tready) begin
                        if (push_idx < count) begin
                            m_tdata  <= mem[push_idx];
                            m_tvalid <= 1'b1;
                            m_tlast  <= (push_idx == count - 1);
                            push_idx <= push_idx + 8'd1;
                        end else begin
                            m_tvalid <= 1'b0;
                            m_tlast  <= 1'b0;
                            count    <= 8'd0;
                            timer    <= 32'd0;
                            state    <= S_FILL;
                        end
                    end
                end
                default: state <= S_FILL;
            endcase
        end
    end

endmodule
