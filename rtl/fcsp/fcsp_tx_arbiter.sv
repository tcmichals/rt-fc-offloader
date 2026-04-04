`default_nettype none

// FCSP TX stream arbiter (frame-aware)
//
// Selects one complete payload frame at a time from multiple AXIS-like inputs.
// Current policy:
//   - CONTROL stream has strict priority when arbiter is idle
//   - ESC_SERIAL stream is selected when CONTROL is idle
//   - DEBUG stream is selected when CONTROL and ESC_SERIAL are idle
// Grant is held until the selected frame's tlast handshake to preserve frame
// atomicity for downstream metadata/framing.
module fcsp_tx_arbiter #(
    parameter int ARB_POLICY = 0 // 0: Strict Priority, 1: Round-Robin
) (
    input  logic        clk,
    input  logic        rst,

    // CONTROL input stream + metadata
    input  logic        s_ctrl_tvalid,
    input  logic [7:0]  s_ctrl_tdata,
    input  logic        s_ctrl_tlast,
    output logic        s_ctrl_tready,
    input  logic [7:0]  s_ctrl_channel,
    input  logic [7:0]  s_ctrl_flags,
    input  logic [15:0] s_ctrl_seq,

    // ESC_SERIAL input stream + metadata
    input  logic        s_esc_tvalid,
    input  logic [7:0]  s_esc_tdata,
    input  logic        s_esc_tlast,
    output logic        s_esc_tready,
    input  logic [7:0]  s_esc_channel,
    input  logic [7:0]  s_esc_flags,
    input  logic [15:0] s_esc_seq,

    // DEBUG input stream + metadata
    input  logic        s_dbg_tvalid,
    input  logic [7:0]  s_dbg_tdata,
    input  logic        s_dbg_tlast,
    output logic        s_dbg_tready,
    input  logic [7:0]  s_dbg_channel,
    input  logic [7:0]  s_dbg_flags,
    input  logic [15:0] s_dbg_seq,

    // Selected output stream + metadata
    output logic        m_tvalid,
    output logic [7:0]  m_tdata,
    output logic        m_tlast,
    input  logic        m_tready,
    output logic [7:0]  m_channel,
    output logic [7:0]  m_flags,
    output logic [15:0] m_seq
);
    typedef enum logic [1:0] {
        SEL_NONE = 2'd0,
        SEL_CTRL = 2'd1,
        SEL_ESC  = 2'd2,
        SEL_DBG  = 2'd3
    } sel_t;

    sel_t sel;
    sel_t last_sel;

    always_comb begin
        s_ctrl_tready = 1'b0;
        s_esc_tready  = 1'b0;
        s_dbg_tready  = 1'b0;
        m_tvalid      = 1'b0;
        m_tdata       = 8'h00;
        m_tlast       = 1'b0;
        m_channel     = 8'h00;
        m_flags       = 8'h00;
        m_seq         = 16'h0000;

        unique case (sel)
            SEL_CTRL: begin
                m_tvalid      = s_ctrl_tvalid;
                m_tdata       = s_ctrl_tdata;
                m_tlast       = s_ctrl_tlast;
                m_channel     = s_ctrl_channel;
                m_flags       = s_ctrl_flags;
                m_seq         = s_ctrl_seq;
                s_ctrl_tready = m_tready;
            end

            SEL_DBG: begin
                m_tvalid     = s_dbg_tvalid;
                m_tdata      = s_dbg_tdata;
                m_tlast      = s_dbg_tlast;
                m_channel    = s_dbg_channel;
                m_flags      = s_dbg_flags;
                m_seq        = s_dbg_seq;
                s_dbg_tready = m_tready;
            end

            SEL_ESC: begin
                m_tvalid      = s_esc_tvalid;
                m_tdata       = s_esc_tdata;
                m_tlast       = s_esc_tlast;
                m_channel     = s_esc_channel;
                m_flags       = s_esc_flags;
                m_seq         = s_esc_seq;
                s_esc_tready  = m_tready;
            end

            default: begin
                // idle
            end
        endcase
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            sel <= SEL_NONE;
            last_sel <= SEL_NONE;
        end else begin
            unique case (sel)
                SEL_NONE: begin
                    if (ARB_POLICY == 0) begin
                        // Strict priority while idle.
                        if (s_ctrl_tvalid) begin
                            sel <= SEL_CTRL;
                        end else if (s_esc_tvalid) begin
                            sel <= SEL_ESC;
                        end else if (s_dbg_tvalid) begin
                            sel <= SEL_DBG;
                        end
                    end else begin
                        // Round-robin fairness
                        if (last_sel == SEL_CTRL) begin
                            if (s_esc_tvalid) sel <= SEL_ESC;
                            else if (s_dbg_tvalid) sel <= SEL_DBG;
                            else if (s_ctrl_tvalid) sel <= SEL_CTRL;
                        end else if (last_sel == SEL_ESC) begin
                            if (s_dbg_tvalid) sel <= SEL_DBG;
                            else if (s_ctrl_tvalid) sel <= SEL_CTRL;
                            else if (s_esc_tvalid) sel <= SEL_ESC;
                        end else begin // last_sel == SEL_DBG or SEL_NONE
                            if (s_ctrl_tvalid) sel <= SEL_CTRL;
                            else if (s_esc_tvalid) sel <= SEL_ESC;
                            else if (s_dbg_tvalid) sel <= SEL_DBG;
                        end
                    end
                end

                SEL_CTRL: begin
                    if (s_ctrl_tvalid && m_tready && s_ctrl_tlast) begin
                        sel <= SEL_NONE;
                        last_sel <= SEL_CTRL;
                    end
                end

                SEL_DBG: begin
                    if (s_dbg_tvalid && m_tready && s_dbg_tlast) begin
                        sel <= SEL_NONE;
                        last_sel <= SEL_DBG;
                    end
                end

                SEL_ESC: begin
                    if (s_esc_tvalid && m_tready && s_esc_tlast) begin
                        sel <= SEL_NONE;
                        last_sel <= SEL_ESC;
                    end
                end

                default: begin
                    sel <= SEL_NONE;
                end
            endcase
        end
    end
endmodule

`default_nettype wire
