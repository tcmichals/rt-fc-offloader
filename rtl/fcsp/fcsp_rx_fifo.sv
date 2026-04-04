`default_nettype none

// FCSP RX FIFO wrapper (Storage seam implementation)
//
// AXIS-style single-packet stream wrapper with frame metadata sideband.
// Upgraded from a pass-through scaffold to a true buffered FIFO leveraging
// hardware-friendly FWFT BRAM for Tang9K targets.
module fcsp_rx_fifo #(
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
    localparam int ADDR_W = (DEPTH <= 2) ? 1 : $clog2(DEPTH);
    localparam int DATA_W = 8 + 1 + 8 + 8 + 16 + 16; // 57 bits

    // Synchronous Memory inference array
    logic [DATA_W-1:0] mem [0:DEPTH-1];

    logic [ADDR_W-1:0] wr_ptr;
    logic [ADDR_W-1:0] rd_ptr;
    logic [ADDR_W:0]   bram_count;

    logic push;
    logic read_en;
    logic [DATA_W-1:0] dout;
    logic valid_q;

    assign s_tready = (bram_count < DEPTH[ADDR_W:0]);
    assign push = s_tvalid && s_tready;

    // We can read from BRAM if it has elements and either:
    // - the output register is empty (!valid_q)
    // - the output register is being consumed this cycle (m_tready && valid_q)
    assign read_en = (bram_count > 0) && (!valid_q || m_tready);

    logic [DATA_W-1:0] write_data;
    assign write_data = {s_tdata, s_tlast, s_channel, s_flags, s_seq, s_payload_len};

    // BRAM instance
    always_ff @(posedge clk) begin
        if (push) begin
            mem[wr_ptr] <= write_data;
        end
        if (read_en) begin
            dout <= mem[rd_ptr];
        end
    end

    // Internal FIFO counters
    always_ff @(posedge clk) begin
        if (rst) begin
            wr_ptr <= '0;
            rd_ptr <= '0;
            bram_count <= '0;
            valid_q <= 1'b0;
            o_overflow <= 1'b0;
            o_frame_seen <= 1'b0;
        end else begin
            // Track overflow condition
            o_overflow <= s_tvalid && !s_tready;
            o_frame_seen <= 1'b0; // Pulse per pop

            // valid_q register management (skid logic)
            if (read_en) begin
                valid_q <= 1'b1;
            end else if (m_tready) begin
                valid_q <= 1'b0;
            end

            // Pointer updates
            if (push) begin
                wr_ptr <= wr_ptr + 1'b1;
            end
            if (read_en) begin
                rd_ptr <= rd_ptr + 1'b1;
            end

            // Counter update
            unique case ({push, read_en})
                2'b10: bram_count <= bram_count + 1'b1;
                2'b01: bram_count <= bram_count - 1'b1;
                default: bram_count <= bram_count;
            endcase

            if (valid_q && m_tready && m_tlast) begin
                o_frame_seen <= 1'b1;
            end
        end
    end

    // Interface extraction
    assign m_tvalid = valid_q;
    assign {m_tdata, m_tlast, m_channel, m_flags, m_seq, m_payload_len} = dout;

endmodule

`default_nettype wire
