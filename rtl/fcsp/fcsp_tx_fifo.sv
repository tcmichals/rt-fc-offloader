`default_nettype wire

// FCSP TX FIFO wrapper (skeleton)
//
// Mirrors the RX FIFO contract for egress scheduling paths.
// Current scaffold is pass-through while preserving the future buffering seam.
module fcsp_tx_fifo #(
    parameter int DEPTH = 512
) (
    input  wire        clk,
    input  wire        rst,

    // Slave payload stream + metadata
    input  wire        s_tvalid,
    input  wire [7:0]  s_tdata,
    input  wire        s_tlast,
    output wire        s_tready,
    input  wire [7:0]  s_channel,
    input  wire [7:0]  s_flags,
    input  wire [15:0] s_seq,
    input  wire [15:0] s_payload_len,
    input  wire        s_tdest,

    // Master payload stream + metadata
    output wire        m_tvalid,
    output wire [7:0]  m_tdata,
    output wire        m_tlast,
    input  wire        m_tready,
    output wire [7:0]  m_channel,
    output wire [7:0]  m_flags,
    output wire [15:0] m_seq,
    output wire [15:0] m_payload_len,
    output wire        m_tdest,

    // Status
    output logic        o_overflow,
    output logic        o_frame_seen
);
    localparam int ADDR_W = (DEPTH <= 2) ? 1 : $clog2(DEPTH);

    logic [7:0]  mem_data      [0:DEPTH-1];
    logic        mem_last      [0:DEPTH-1];
    logic [7:0]  mem_channel   [0:DEPTH-1];
    logic [7:0]  mem_flags     [0:DEPTH-1];
    logic [15:0] mem_seq       [0:DEPTH-1];
    logic [15:0] mem_payload_len [0:DEPTH-1];
    logic        mem_tdest     [0:DEPTH-1];

    logic [ADDR_W-1:0] wr_ptr;
    logic [ADDR_W-1:0] rd_ptr;
    logic [ADDR_W:0]   count;

    logic push;
    logic pop;
    logic full;
    logic empty;

    assign full  = (count == DEPTH[ADDR_W:0]);
    assign empty = (count == '0);

    assign s_tready = ~full;
    assign m_tvalid = ~empty;

    assign m_tdata       = mem_data[rd_ptr];
    assign m_tlast       = mem_last[rd_ptr];
    assign m_channel     = mem_channel[rd_ptr];
    assign m_flags       = mem_flags[rd_ptr];
    assign m_seq         = mem_seq[rd_ptr];
    assign m_payload_len = mem_payload_len[rd_ptr];
    assign m_tdest       = mem_tdest[rd_ptr];

    assign push = s_tvalid && s_tready;
    assign pop  = m_tvalid && m_tready;

    always_ff @(posedge clk) begin
        if (rst) begin
            wr_ptr       <= '0;
            rd_ptr       <= '0;
            count        <= '0;
            o_overflow   <= 1'b0;
            o_frame_seen <= 1'b0;
        end else begin
            o_overflow   <= 1'b0;
            o_frame_seen <= 1'b0;

            if (s_tvalid && ~s_tready) begin
                o_overflow <= 1'b1;
            end

            if (push) begin
                mem_data[wr_ptr]        <= s_tdata;
                mem_last[wr_ptr]        <= s_tlast;
                mem_channel[wr_ptr]     <= s_channel;
                mem_flags[wr_ptr]       <= s_flags;
                mem_seq[wr_ptr]         <= s_seq;
                mem_payload_len[wr_ptr] <= s_payload_len;
                mem_tdest[wr_ptr]       <= s_tdest;
                wr_ptr                  <= wr_ptr + 1'b1;
            end

            if (pop) begin
                rd_ptr <= rd_ptr + 1'b1;
            end

            unique case ({push, pop})
                2'b10: count <= count + 1'b1;
                2'b01: count <= count - 1'b1;
                default: count <= count;
            endcase

            if (pop && m_tlast) begin
                o_frame_seen <= 1'b1;
            end
        end
    end
endmodule

`default_nettype wire
