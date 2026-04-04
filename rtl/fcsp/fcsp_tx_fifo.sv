`default_nettype none

// FCSP TX FIFO wrapper (skeleton)
//
// Mirrors the RX FIFO contract for egress scheduling paths.
// Current scaffold is pass-through while preserving the future buffering seam.
module fcsp_tx_fifo #(
    parameter int DEPTH = 512
) (
    input  logic        clk,
    input  logic        rst,

    // Slave payload stream + metadata
    input  logic        s_tvalid,
    input  logic [7:0]  s_tdata,
    input  logic        s_tlast,
    output logic        s_tready,
    input  logic [7:0]  s_channel,
    input  logic [7:0]  s_flags,
    input  logic [15:0] s_seq,
    input  logic [15:0] s_payload_len,

    // Master payload stream + metadata
    output logic        m_tvalid,
    output logic [7:0]  m_tdata,
    output logic        m_tlast,
    input  logic        m_tready,
    output logic [7:0]  m_channel,
    output logic [7:0]  m_flags,
    output logic [15:0] m_seq,
    output logic [15:0] m_payload_len,

    // Status
    output logic        o_overflow,
    output logic        o_frame_seen
);
    assign s_tready      = m_tready;
    assign m_tvalid      = s_tvalid;
    assign m_tdata       = s_tdata;
    assign m_tlast       = s_tlast;
    assign m_channel     = s_channel;
    assign m_flags       = s_flags;
    assign m_seq         = s_seq;
    assign m_payload_len = s_payload_len;

    always_ff @(posedge clk) begin
        if (rst) begin
            o_overflow   <= 1'b0;
            o_frame_seen <= 1'b0;
        end else begin
            o_overflow   <= 1'b0;
            o_frame_seen <= 1'b0;
            if (s_tvalid && s_tready && s_tlast) begin
                o_frame_seen <= 1'b1;
            end
        end
    end

    logic _unused_depth;
    always_comb begin
        _unused_depth = DEPTH[0];
    end
endmodule

`default_nettype wire
