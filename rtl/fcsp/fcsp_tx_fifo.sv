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
    localparam int DATA_W = 8 + 1 + 8 + 8 + 16 + 16 + 1; // 58 bits

    // Single packed memory — enables BSRAM inference
    logic [DATA_W-1:0] mem [0:DEPTH-1];

    logic [ADDR_W-1:0] wr_ptr;
    logic [ADDR_W-1:0] rd_ptr;
    logic [ADDR_W:0]   count;

    logic push;
    logic read_en;
    logic [DATA_W-1:0] dout;
    logic valid_q;

    assign s_tready = (count < DEPTH[ADDR_W:0]);
    assign push = s_tvalid && s_tready;

    // Read from BRAM when it has elements and output register is free or consumed
    assign read_en = (count > 0) && (!valid_q || m_tready);

    logic [DATA_W-1:0] write_data;
    assign write_data = {s_tdata, s_tlast, s_channel, s_flags, s_seq, s_payload_len, s_tdest};

    // BSRAM-friendly: synchronous write + registered read
    always_ff @(posedge clk) begin
        if (push) begin
            mem[wr_ptr] <= write_data;
        end
        if (read_en) begin
            dout <= mem[rd_ptr];
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            wr_ptr       <= '0;
            rd_ptr       <= '0;
            count        <= '0;
            valid_q      <= 1'b0;
            o_overflow   <= 1'b0;
            o_frame_seen <= 1'b0;
        end else begin
            o_overflow   <= 1'b0;
            o_frame_seen <= 1'b0;

            if (s_tvalid && ~s_tready) begin
                o_overflow <= 1'b1;
            end

            // valid_q register management (skid logic)
            if (read_en) begin
                valid_q <= 1'b1;
            end else if (m_tready) begin
                valid_q <= 1'b0;
            end

            if (push) begin
                wr_ptr <= wr_ptr + 1'b1;
            end
            if (read_en) begin
                rd_ptr <= rd_ptr + 1'b1;
            end

            unique case ({push, read_en})
                2'b10: count <= count + 1'b1;
                2'b01: count <= count - 1'b1;
                default: count <= count;
            endcase

            if (valid_q && m_tready && m_tlast) begin
                o_frame_seen <= 1'b1;
            end
        end
    end

    assign m_tvalid = valid_q;
    assign {m_tdata, m_tlast, m_channel, m_flags, m_seq, m_payload_len, m_tdest} = dout;
endmodule

`default_nettype wire
