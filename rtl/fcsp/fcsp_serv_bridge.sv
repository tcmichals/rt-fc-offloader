`default_nettype none

// FCSP <-> SERV control-plane bridge (skeleton)
//
// Purpose:
// - accept validated CONTROL payload bytes from FCSP channel FIFO side
// - emit command stream toward SERV firmware endpoint
// - accept response stream from SERV endpoint
// - emit response payload bytes toward FCSP TX side
module fcsp_serv_bridge (
    input  logic        clk,
    input  logic        rst,

    // Slave AXIS-like CONTROL RX payload stream (from FCSP router/FIFO)
    input  logic        s_ctrl_rx_tvalid,
    input  logic [7:0]  s_ctrl_rx_tdata,
    input  logic        s_ctrl_rx_tlast,
    output logic        s_ctrl_rx_tready,
    input  logic [15:0] s_ctrl_rx_seq,

    // Master AXIS-like SERV command stream (toward firmware endpoint)
    output logic        m_serv_cmd_tvalid,
    output logic [7:0]  m_serv_cmd_tdata,
    output logic        m_serv_cmd_tlast,
    input  logic        m_serv_cmd_tready,

    // Slave AXIS-like SERV response stream (from firmware endpoint)
    input  logic        s_serv_rsp_tvalid,
    input  logic [7:0]  s_serv_rsp_tdata,
    input  logic        s_serv_rsp_tlast,
    output logic        s_serv_rsp_tready,

    // Master AXIS-like CONTROL TX payload stream (toward TX mux/framer)
    output logic        m_ctrl_tx_tvalid,
    output logic [7:0]  m_ctrl_tx_tdata,
    output logic        m_ctrl_tx_tlast,
    input  logic        m_ctrl_tx_tready,
    output logic [7:0]  m_ctrl_tx_channel,
    output logic [7:0]  m_ctrl_tx_flags,
    output logic [15:0] m_ctrl_tx_seq
);
    localparam logic [1:0] ST_IDLE      = 2'd0;
    localparam logic [1:0] ST_REQ       = 2'd1;
    localparam logic [1:0] ST_WAIT_RSP  = 2'd2;
    localparam logic [1:0] ST_RSP       = 2'd3;

    localparam logic [7:0] CONTROL_CHANNEL = 8'h01;
    localparam logic [7:0] ACK_RESPONSE    = 8'h02;

    logic [1:0]  state;
    logic [15:0] pending_seq;

    assign s_ctrl_rx_tready = ((state == ST_IDLE) || (state == ST_REQ)) ? m_serv_cmd_tready : 1'b0;
    assign m_serv_cmd_tvalid = ((state == ST_IDLE) || (state == ST_REQ)) ? s_ctrl_rx_tvalid : 1'b0;
    assign m_serv_cmd_tdata  = s_ctrl_rx_tdata;
    assign m_serv_cmd_tlast  = s_ctrl_rx_tlast;

    assign s_serv_rsp_tready = ((state == ST_WAIT_RSP) || (state == ST_RSP)) ? m_ctrl_tx_tready : 1'b0;
    assign m_ctrl_tx_tvalid  = ((state == ST_WAIT_RSP) || (state == ST_RSP)) ? s_serv_rsp_tvalid : 1'b0;
    assign m_ctrl_tx_tdata   = s_serv_rsp_tdata;
    assign m_ctrl_tx_tlast   = s_serv_rsp_tlast;
    assign m_ctrl_tx_channel = CONTROL_CHANNEL;
    assign m_ctrl_tx_flags   = ACK_RESPONSE;
    assign m_ctrl_tx_seq     = pending_seq;

    always_ff @(posedge clk) begin
        if (rst) begin
            state       <= ST_IDLE;
            pending_seq <= 16'h0000;
        end else begin
            unique case (state)
                ST_IDLE: begin
                    if (s_ctrl_rx_tvalid && m_serv_cmd_tready) begin
                        pending_seq <= s_ctrl_rx_seq;
                        if (s_ctrl_rx_tlast) begin
                            state <= ST_WAIT_RSP;
                        end else begin
                            state <= ST_REQ;
                        end
                    end
                end
                ST_REQ: begin
                    if (s_ctrl_rx_tvalid && m_serv_cmd_tready && s_ctrl_rx_tlast) begin
                        pending_seq <= s_ctrl_rx_seq;
                        state <= ST_WAIT_RSP;
                    end
                end
                ST_WAIT_RSP: begin
                    if (s_serv_rsp_tvalid && m_ctrl_tx_tready) begin
                        if (s_serv_rsp_tlast) begin
                            state <= ST_IDLE;
                        end else begin
                            state <= ST_RSP;
                        end
                    end
                end
                ST_RSP: begin
                    if (s_serv_rsp_tvalid && m_ctrl_tx_tready && s_serv_rsp_tlast) begin
                        state <= ST_IDLE;
                    end
                end
                default: begin
                    state <= ST_IDLE;
                end
            endcase
        end
    end
endmodule

`default_nettype wire
