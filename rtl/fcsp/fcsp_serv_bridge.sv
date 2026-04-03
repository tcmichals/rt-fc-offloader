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

    // CONTROL RX payload byte stream (from FCSP router/FIFO)
    input  logic        i_ctrl_rx_valid,
    input  logic [7:0]  i_ctrl_rx_byte,
    input  logic        i_ctrl_rx_last,
    output logic        o_ctrl_rx_ready,

    // SERV command stream (toward firmware endpoint)
    output logic        o_serv_cmd_valid,
    output logic [7:0]  o_serv_cmd_byte,
    output logic        o_serv_cmd_last,
    input  logic        i_serv_cmd_ready,

    // SERV response stream (from firmware endpoint)
    input  logic        i_serv_rsp_valid,
    input  logic [7:0]  i_serv_rsp_byte,
    input  logic        i_serv_rsp_last,
    output logic        o_serv_rsp_ready,

    // FCSP TX payload stream (toward TX mux/framer)
    output logic        o_ctrl_tx_valid,
    output logic [7:0]  o_ctrl_tx_byte,
    output logic        o_ctrl_tx_last,
    input  logic        i_ctrl_tx_ready
);
    // Skeleton behavior: direct stream-through in both directions.
    // A future revision will add op framing, buffering, and policy/error mapping.

    // RX to SERV command path
    assign o_ctrl_rx_ready = i_serv_cmd_ready;
    assign o_serv_cmd_valid = i_ctrl_rx_valid;
    assign o_serv_cmd_byte  = i_ctrl_rx_byte;
    assign o_serv_cmd_last  = i_ctrl_rx_last;

    // SERV response to TX payload path
    assign o_serv_rsp_ready = i_ctrl_tx_ready;
    assign o_ctrl_tx_valid  = i_serv_rsp_valid;
    assign o_ctrl_tx_byte   = i_serv_rsp_byte;
    assign o_ctrl_tx_last   = i_serv_rsp_last;
endmodule

`default_nettype wire
