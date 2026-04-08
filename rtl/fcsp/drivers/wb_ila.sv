/**
 * WILA: Wishbone Integrated Logic Analyzer (Streaming RLE Edition)
 *
 * Continuously monitors a 32-bit probe bus and emits RLE-compressed
 * change events as AXI-Stream payloads. These are wrapped into FCSP
 * Channel 0x07 frames by the TX path and auto-delivered to the host.
 *
 * RLE Encoding:
 *   Each "entry" is 6 bytes:
 *     [repeat_hi][repeat_lo][data_3][data_2][data_1][data_0]
 *   - repeat_count = number of consecutive cycles the PREVIOUS value held
 *   - data = the NEW 32-bit probe snapshot
 *
 * Control Registers (Wishbone):
 *   0x00: CTRL     [0]   = ENABLE (start/stop streaming)
 *                  [1]   = FLUSH  (force emit current buffer, auto-clears)
 *   0x04: PROBE_SEL[3:0] = Select which probe group to monitor
 *                          0 = Wishbone Bus (addr, ack, stb, we)
 *                          1 = Motor Pins + DShot state
 *                          2 = ESC UART (tx, rx, baud)
 *                          3 = Raw (external probe_data input)
 *   0x08: PRESCALE [15:0] = Sample clock divider (0 = every cycle)
 *   0x0C: STATUS   [15:0] = Frames emitted (read-only counter)
 */

`default_nettype none

module wb_ila #(
    parameter MAX_ENTRIES = 40   // Entries per FCSP frame (40*6 = 240 bytes)
) (
    input  logic        clk,
    input  logic        rst,

    // Wishbone Slave (Configuration)
    input  logic [31:0] wb_adr_i,
    input  logic [31:0] wb_dat_i,
    output logic [31:0] wb_dat_o,
    input  logic        wb_we_i,
    input  logic        wb_stb_i,
    input  logic        wb_cyc_i,
    output logic        wb_ack_o,

    // Probe inputs (active group selected by PROBE_SEL)
    input  logic [31:0] probe_data,

    // AXI-Stream output (to TX framer, Channel 0x07)
    output logic [7:0]  m_tdata,
    output logic        m_tvalid,
    output logic        m_tlast,
    input  logic        m_tready
);

    // --- Control Registers ---
    logic        enabled;
    logic        flush_req;
    logic [3:0]  probe_sel;
    logic [15:0] prescale;
    logic [15:0] frame_count;

    wire sel = wb_stb_i & wb_cyc_i;

    always_ff @(posedge clk) begin
        if (rst) begin
            wb_ack_o    <= 1'b0;
            wb_dat_o    <= 32'h0;
            enabled     <= 1'b0;
            flush_req   <= 1'b0;
            probe_sel   <= 4'h0;
            prescale    <= 16'h0;
        end else begin
            wb_ack_o  <= 1'b0;
            flush_req <= 1'b0; // Auto-clear

            if (sel && !wb_ack_o) begin
                wb_ack_o <= 1'b1;
                if (wb_we_i) begin
                    case (wb_adr_i[3:2])
                        2'h0: begin
                            enabled   <= wb_dat_i[0];
                            flush_req <= wb_dat_i[1];
                        end
                        2'h1: probe_sel <= wb_dat_i[3:0];
                        2'h2: prescale  <= wb_dat_i[15:0];
                    endcase
                end else begin
                    case (wb_adr_i[3:2])
                        2'h0: wb_dat_o <= {30'b0, 1'b0, enabled};
                        2'h1: wb_dat_o <= {28'b0, probe_sel};
                        2'h2: wb_dat_o <= {16'b0, prescale};
                        2'h3: wb_dat_o <= {16'b0, frame_count};
                    endcase
                end
            end
        end
    end

    // --- Prescaler ---
    logic [15:0] prescale_cnt;
    logic        sample_tick;

    always_ff @(posedge clk) begin
        if (rst || !enabled) begin
            prescale_cnt <= 16'h0;
            sample_tick  <= 1'b0;
        end else begin
            if (prescale_cnt >= prescale) begin
                prescale_cnt <= 16'h0;
                sample_tick  <= 1'b1;
            end else begin
                prescale_cnt <= prescale_cnt + 16'h1;
                sample_tick  <= 1'b0;
            end
        end
    end

    // --- Change Detect & RLE Counter ---
    logic [31:0] prev_probe;
    logic [15:0] rle_count;
    logic        change_detected;
    logic        rle_overflow;

    assign change_detected = (probe_data != prev_probe) && sample_tick;
    assign rle_overflow    = (rle_count == 16'hFFFF) && sample_tick;

    // --- Entry FIFO (6 bytes per entry, stored as 48-bit words) ---
    localparam FIFO_DEPTH = MAX_ENTRIES;
    localparam FIFO_W     = $clog2(FIFO_DEPTH);

    logic [47:0] entry_fifo [0:FIFO_DEPTH-1];
    logic [FIFO_W-1:0] fifo_wr_ptr;
    logic [FIFO_W-1:0] fifo_rd_ptr;
    logic [FIFO_W:0]   fifo_count;
    logic               fifo_push;
    logic [47:0]        fifo_din;

    // Push an RLE entry when a change or overflow is detected
    always_ff @(posedge clk) begin
        if (rst) begin
            prev_probe  <= 32'h0;
            rle_count   <= 16'h0;
            fifo_push   <= 1'b0;
            fifo_din    <= 48'h0;
        end else begin
            fifo_push <= 1'b0;

            if (enabled && sample_tick) begin
                if (change_detected || rle_overflow) begin
                    // Emit: {repeat_count, new_value}
                    fifo_din  <= {rle_count, probe_data};
                    fifo_push <= 1'b1;
                    prev_probe <= probe_data;
                    rle_count  <= 16'h0;
                end else begin
                    rle_count <= rle_count + 16'h1;
                end
            end
        end
    end

    // FIFO storage
    always_ff @(posedge clk) begin
        if (rst) begin
            fifo_wr_ptr <= '0;
            fifo_count  <= '0;
        end else begin
            if (fifo_push && fifo_count < FIFO_DEPTH) begin
                entry_fifo[fifo_wr_ptr] <= fifo_din;
                fifo_wr_ptr <= fifo_wr_ptr + 1'b1;
                fifo_count  <= fifo_count + 1'b1;
            end
        end
    end

    // --- Frame Emitter State Machine ---
    // When FIFO is full OR flush_req, serialize entries as AXI-Stream bytes (6 per entry)
    typedef enum logic [2:0] {
        ST_IDLE     = 3'd0,
        ST_BYTE0    = 3'd1,  // repeat_hi
        ST_BYTE1    = 3'd2,  // repeat_lo
        ST_BYTE2    = 3'd3,  // data[31:24]
        ST_BYTE3    = 3'd4,  // data[23:16]
        ST_BYTE4    = 3'd5,  // data[15:8]
        ST_BYTE5    = 3'd6   // data[7:0]
    } emit_state_t;

    emit_state_t emit_state;
    logic [47:0] emit_word;
    logic [FIFO_W:0] entries_to_emit;
    logic [FIFO_W:0] entries_emitted;
    logic             is_last_byte;

    assign is_last_byte = (emit_state == ST_BYTE5) && (entries_emitted + 1'b1 >= entries_to_emit);

    always_ff @(posedge clk) begin
        if (rst) begin
            emit_state     <= ST_IDLE;
            fifo_rd_ptr    <= '0;
            entries_to_emit <= '0;
            entries_emitted <= '0;
            m_tvalid       <= 1'b0;
            m_tlast        <= 1'b0;
            m_tdata        <= 8'h0;
            frame_count    <= 16'h0;
        end else begin
            case (emit_state)
                ST_IDLE: begin
                    m_tvalid <= 1'b0;
                    m_tlast  <= 1'b0;
                    if ((fifo_count >= FIFO_DEPTH) || (flush_req && fifo_count > 0)) begin
                        entries_to_emit <= fifo_count;
                        entries_emitted <= '0;
                        emit_word       <= entry_fifo[fifo_rd_ptr];
                        fifo_rd_ptr     <= fifo_rd_ptr + 1'b1;
                        emit_state      <= ST_BYTE0;
                    end
                end

                ST_BYTE0: begin
                    m_tdata  <= emit_word[47:40]; // repeat_hi
                    m_tvalid <= 1'b1;
                    m_tlast  <= 1'b0;
                    if (m_tready) emit_state <= ST_BYTE1;
                end
                ST_BYTE1: begin
                    m_tdata <= emit_word[39:32]; // repeat_lo
                    if (m_tready) emit_state <= ST_BYTE2;
                end
                ST_BYTE2: begin
                    m_tdata <= emit_word[31:24]; // data[31:24]
                    if (m_tready) emit_state <= ST_BYTE3;
                end
                ST_BYTE3: begin
                    m_tdata <= emit_word[23:16]; // data[23:16]
                    if (m_tready) emit_state <= ST_BYTE4;
                end
                ST_BYTE4: begin
                    m_tdata <= emit_word[15:8]; // data[15:8]
                    if (m_tready) emit_state <= ST_BYTE5;
                end
                ST_BYTE5: begin
                    m_tdata <= emit_word[7:0]; // data[7:0]
                    m_tlast <= is_last_byte;
                    if (m_tready) begin
                        entries_emitted <= entries_emitted + 1'b1;
                        if (is_last_byte) begin
                            // Frame complete
                            m_tvalid    <= 1'b0;
                            m_tlast     <= 1'b0;
                            emit_state  <= ST_IDLE;
                            fifo_count  <= '0;
                            fifo_wr_ptr <= '0;
                            fifo_rd_ptr <= '0;
                            frame_count <= frame_count + 16'h1;
                        end else begin
                            // Next entry
                            emit_word   <= entry_fifo[fifo_rd_ptr];
                            fifo_rd_ptr <= fifo_rd_ptr + 1'b1;
                            emit_state  <= ST_BYTE0;
                        end
                    end
                end
            endcase
        end
    end

endmodule

`default_nettype wire
