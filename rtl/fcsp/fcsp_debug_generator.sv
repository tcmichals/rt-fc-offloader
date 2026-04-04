`default_nettype none

// FCSP Hardware Debug Generator ("Soft-ILA")
//
// Captures internal hardware probes and sends them as FCSP Channel 0x04 frames.
// This allows the host to see a "trace" of hardware events over USB/SPI.
module fcsp_debug_generator (
    input  logic        clk,
    input  logic        rst,

    // Probe Inputs (The "Signals" we want to watch)
    input  logic        i_passthrough_enabled,
    input  logic        i_break_active,
    input  logic        i_sync_loss,
    input  logic        i_wb_cyc,
    input  logic        i_wb_ack,
    input  logic [7:0]  i_router_chan,

    // FCSP Stream Output (Channel 0x04)
    output logic        m_dbg_tvalid,
    output logic [7:0]  m_dbg_tdata,
    output logic        m_dbg_tlast,
    input  logic        m_dbg_tready
);

    // Snapshot Register
    logic [31:0] probe_snapshot;
    assign probe_snapshot = {
        20'h0,                  // Padding
        i_router_chan,          // [11:4] Active Channel
        i_wb_ack,               // [3] Wishbone ACK
        i_wb_cyc,               // [2] Wishbone Cycle
        i_break_active,         // [1] Break Signal State
        i_passthrough_enabled   // [0] Passthrough Mode
    };

    logic [31:0] last_snapshot;
    logic        trigger;
    
    // Trigger on any change or sync loss event
    assign trigger = (probe_snapshot != last_snapshot) || i_sync_loss;

    typedef enum logic [2:0] {
        IDLE,
        HEADER,
        SEND_B0,
        SEND_B1,
        SEND_B2,
        SEND_B3,
        DONE
    } state_t;

    state_t state;
    logic [7:0] bytes[4];
    assign bytes[0] = probe_snapshot[7:0];
    assign bytes[1] = probe_snapshot[15:8];
    assign bytes[2] = probe_snapshot[23:16];
    assign bytes[3] = probe_snapshot[31:24];

    always_ff @(posedge clk) begin
        if (rst) begin
            state         <= IDLE;
            last_snapshot <= '0;
            m_dbg_tvalid  <= 1'b0;
            m_dbg_tdata   <= 8'h0;
            m_dbg_tlast   <= 1'b0;
        end else begin
            case (state)
                IDLE: begin
                    m_dbg_tvalid <= 1'b0;
                    m_dbg_tlast  <= 1'b0;
                    if (trigger) begin
                        last_snapshot <= probe_snapshot;
                        state         <= HEADER;
                    end
                end

                HEADER: begin
                    // Send an Event Type byte (0x01 = Snapshot)
                    m_dbg_tvalid <= 1'b1;
                    m_dbg_tdata  <= 8'h01; 
                    if (m_dbg_tready) state <= SEND_B0;
                end

                SEND_B0: begin
                    m_dbg_tdata  <= bytes[0];
                    if (m_dbg_tready) state <= SEND_B1;
                end

                SEND_B1: begin
                    m_dbg_tdata  <= bytes[1];
                    if (m_dbg_tready) state <= SEND_B2;
                end

                SEND_B2: begin
                    m_dbg_tdata  <= bytes[2];
                    if (m_dbg_tready) state <= SEND_B3;
                end

                SEND_B3: begin
                    m_dbg_tdata  <= bytes[3];
                    m_dbg_tlast  <= 1'b1;
                    if (m_dbg_tready) state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
