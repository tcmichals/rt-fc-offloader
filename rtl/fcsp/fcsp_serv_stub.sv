`default_nettype none

// Lightweight SERV stub for Tang9k bring-up.
//
// Purpose:
// - Consume control command payload frames from fcsp_serv_bridge
// - Emit deterministic tiny response payload frames
// - Emit a short debug message per command
// - Drive DSHOT/Neo control seams so integration is exercised end-to-end
//
// NOTE: This is a bring-up placeholder, not final SERV firmware behavior.
module fcsp_serv_stub #(
    parameter int MOTOR_COUNT = 4
) (
    input  logic                    clk,
    input  logic                    rst,

    // Command input from bridge
    input  logic                    s_cmd_tvalid,
    input  logic [7:0]              s_cmd_tdata,
    input  logic                    s_cmd_tlast,
    output logic                    s_cmd_tready,

    // Response payload output to bridge
    output logic                    m_rsp_tvalid,
    output logic [7:0]              m_rsp_tdata,
    output logic                    m_rsp_tlast,
    input  logic                    m_rsp_tready,

    // Debug payload output (to DEBUG_TRACE TX seam)
    output logic                    m_dbg_tvalid,
    output logic [7:0]              m_dbg_tdata,
    output logic                    m_dbg_tlast,
    input  logic                    m_dbg_tready,

    // IO control seams
    output logic                    o_dshot_update,
    output logic [1:0]              o_dshot_mode_sel,
    output logic [MOTOR_COUNT*16-1:0] o_dshot_words,
    output logic                    o_neo_update,
    output logic [23:0]             o_neo_rgb
);
    localparam logic [7:0] OP_PT_ENTER        = 8'h01;
    localparam logic [7:0] OP_PT_EXIT         = 8'h02;
    localparam logic [7:0] OP_ESC_SCAN        = 8'h03;
    localparam logic [7:0] OP_SET_MOTOR_SPEED = 8'h04;
    localparam logic [7:0] OP_GET_LINK_STATUS = 8'h05;
    localparam logic [7:0] OP_PING            = 8'h06;
    localparam logic [7:0] OP_READ_BLOCK      = 8'h10;
    localparam logic [7:0] OP_WRITE_BLOCK     = 8'h11;
    localparam logic [7:0] OP_GET_CAPS        = 8'h12;
    localparam logic [7:0] OP_HELLO           = 8'h13;

    localparam logic [7:0] RES_OK             = 8'h00;
    localparam logic [7:0] RES_INVALID_ARG    = 8'h01;
    localparam logic [7:0] RES_NOT_SUPPORTED  = 8'h04;

    localparam int CMD_MAX = 256;
    localparam int READ_BLOCK_MAX = 64;
    localparam int RSP_MAX = 3 + READ_BLOCK_MAX;

    typedef enum logic [3:0] {
        ST_IDLE             = 4'd0,
        ST_BUILD            = 4'd1,
        ST_RSP_SEND         = 4'd2,
        ST_DBG_SEND         = 4'd3,
        ST_DO_READ_BLOCK    = 4'd4,
        ST_DO_WRITE_BLOCK   = 4'd5,
        ST_DO_CAPS          = 4'd6,
        ST_DO_HELLO         = 4'd7
    } st_t;

    st_t st;

    logic [7:0] cmd_buf [0:CMD_MAX-1];
    logic [15:0] cmd_len;
    logic        cmd_overflow;

    logic [7:0] rsp_buf [0:RSP_MAX-1];
    logic [15:0] rsp_len;
    logic [15:0] rsp_idx;

    logic [2:0] dbg_idx;
    logic [7:0] blk_mem [0:255];

    logic [15:0] copy_idx;
    logic [15:0] copy_target_len;
    logic [7:0]  work_addr;

    integer i;

    logic [7:0] op;
    logic [15:0] speed_u16;

    initial begin
        for (integer k = 0; k < 256; k = k + 1) begin
            blk_mem[k] = k[7:0];
        end
    end

    logic [7:0] caps_blob [0:22];
    initial begin
        caps_blob[0]  = 8'h05; caps_blob[1]  = 8'd9;
        caps_blob[2]  = "S"; caps_blob[3]  = "E"; caps_blob[4]  = "R"; caps_blob[5]  = "V";
        caps_blob[6]  = "-"; caps_blob[7]  = "S"; caps_blob[8]  = "T"; caps_blob[9]  = "U"; caps_blob[10] = "B";
        caps_blob[11] = 8'h03; caps_blob[12] = 8'd2; caps_blob[13] = 8'h00; caps_blob[14] = READ_BLOCK_MAX[7:0];
        caps_blob[15] = 8'h04; caps_blob[16] = 8'd2; caps_blob[17] = 8'h00; caps_blob[18] = READ_BLOCK_MAX[7:0];
        caps_blob[19] = 8'h11; caps_blob[20] = 8'd2; caps_blob[21] = 8'h00; caps_blob[22] = MOTOR_COUNT[7:0];
    end

    logic [7:0] hello_blob [0:13];
    initial begin
        hello_blob[0]  = 8'h01; hello_blob[1]  = 8'd1; hello_blob[2]  = 8'h02;
        hello_blob[3]  = 8'h02; hello_blob[4]  = 8'd9;
        hello_blob[5]  = "s"; hello_blob[6]  = "e"; hello_blob[7]  = "r"; hello_blob[8]  = "v";
        hello_blob[9]  = "-"; hello_blob[10] = "s"; hello_blob[11] = "t"; hello_blob[12] = "u"; hello_blob[13] = "b";
    end

    always_comb begin
        s_cmd_tready = (st == ST_IDLE);

        m_rsp_tvalid = (st == ST_RSP_SEND) && (rsp_idx < rsp_len);
        m_rsp_tlast  = (st == ST_RSP_SEND) && (rsp_idx + 16'd1 == rsp_len);
        m_rsp_tdata  = (rsp_idx < RSP_MAX) ? rsp_buf[rsp_idx] : 8'h00;

        m_dbg_tvalid = (st == ST_DBG_SEND);
        m_dbg_tlast  = (st == ST_DBG_SEND) && (dbg_idx == 3'd5);
        unique case (dbg_idx)
            3'd0: m_dbg_tdata = "S";
            3'd1: m_dbg_tdata = "E";
            3'd2: m_dbg_tdata = "R";
            3'd3: m_dbg_tdata = "V";
            3'd4: m_dbg_tdata = op;
            3'd5: m_dbg_tdata = 8'h0A;
            default: m_dbg_tdata = 8'h00;
        endcase
    end

    logic [15:0] req_len_u16;

    always_ff @(posedge clk) begin
        if (rst) begin
            st              <= ST_IDLE;
            cmd_len         <= 16'd0;
            cmd_overflow    <= 1'b0;
            rsp_len         <= 16'd0;
            rsp_idx         <= 16'd0;
            dbg_idx         <= 3'd0;
            o_dshot_update  <= 1'b0;
            o_dshot_mode_sel<= 2'b00;
            o_dshot_words   <= '0;
            o_neo_update    <= 1'b0;
            o_neo_rgb       <= 24'h000000;
            op              <= 8'h00;
            copy_idx        <= 16'd0;
            copy_target_len <= 16'd0;
            work_addr       <= 8'd0;
        end else begin
            o_dshot_update <= 1'b0;
            o_neo_update   <= 1'b0;

            unique case (st)
                ST_IDLE: begin
                    if (s_cmd_tvalid && s_cmd_tready) begin
                        if (cmd_len < CMD_MAX[15:0]) begin
                            cmd_buf[cmd_len] <= s_cmd_tdata;
                            cmd_len <= cmd_len + 16'd1;
                        end else begin
                            cmd_overflow <= 1'b1;
                        end

                        if (s_cmd_tlast) begin
                            st <= ST_BUILD;
                        end
                    end
                end

                ST_BUILD: begin
                    op <= (cmd_len != 16'd0) ? cmd_buf[0] : 8'h00;
                    rsp_buf[0] <= RES_NOT_SUPPORTED;
                    rsp_len <= 16'd1;

                    if (cmd_overflow || (cmd_len == 16'd0)) begin
                        rsp_buf[0] <= RES_INVALID_ARG;
                        rsp_len <= 16'd1;
                        st <= ST_RSP_SEND;
                    end else begin
                        st <= ST_RSP_SEND; // Default next state unless overridden below
                        rsp_idx <= 16'd0;
                        dbg_idx <= 3'd0;

                        unique case (cmd_buf[0])
                            OP_PT_ENTER: begin
                                if (cmd_len == 16'd2) begin
                                    rsp_buf[0] <= RES_OK;
                                    rsp_buf[1] <= MOTOR_COUNT[7:0];
                                    rsp_len <= 16'd2;
                                end else begin
                                    rsp_buf[0] <= RES_INVALID_ARG;
                                    rsp_len <= 16'd1;
                                end
                            end

                            OP_PT_EXIT: begin
                                rsp_buf[0] <= RES_OK;
                                rsp_len <= 16'd1;
                            end

                            OP_ESC_SCAN: begin
                                if (cmd_len == 16'd2) begin
                                    rsp_buf[0] <= RES_OK;
                                    rsp_buf[1] <= MOTOR_COUNT[7:0];
                                    rsp_len <= 16'd2;
                                end else begin
                                    rsp_buf[0] <= RES_INVALID_ARG;
                                    rsp_len <= 16'd1;
                                end
                            end

                            OP_SET_MOTOR_SPEED: begin
                                if (cmd_len >= 16'd4) begin
                                    speed_u16 = {cmd_buf[2], cmd_buf[3]};
                                    o_dshot_mode_sel <= 2'b01;
                                    for (i = 0; i < MOTOR_COUNT; i = i + 1) begin
                                        o_dshot_words[i*16 +: 16] <= speed_u16;
                                    end
                                    o_dshot_update <= 1'b1;
                                    o_neo_rgb <= {cmd_buf[1], cmd_buf[2], cmd_buf[3]};
                                    o_neo_update <= 1'b1;
                                    rsp_buf[0] <= RES_OK;
                                    rsp_len <= 16'd1;
                                end else begin
                                    rsp_buf[0] <= RES_INVALID_ARG;
                                    rsp_len <= 16'd1;
                                end
                            end

                            OP_GET_LINK_STATUS: begin
                                rsp_buf[0] <= RES_OK;
                                rsp_buf[1] <= 8'h00; // flags hi
                                rsp_buf[2] <= 8'h01; // flags lo: link up
                                rsp_buf[3] <= 8'h00; // rx_drops hi
                                rsp_buf[4] <= 8'h00; // rx_drops lo
                                rsp_buf[5] <= 8'h00; // crc_err hi
                                rsp_buf[6] <= 8'h00; // crc_err lo
                                rsp_len <= 16'd7;
                            end

                            OP_PING: begin
                                if (cmd_len == 16'd5) begin
                                    rsp_buf[0] <= RES_OK;
                                    rsp_buf[1] <= cmd_buf[1];
                                    rsp_buf[2] <= cmd_buf[2];
                                    rsp_buf[3] <= cmd_buf[3];
                                    rsp_buf[4] <= cmd_buf[4];
                                    rsp_len <= 16'd5;
                                end else begin
                                    rsp_buf[0] <= RES_INVALID_ARG;
                                    rsp_len <= 16'd1;
                                end
                            end

                            OP_READ_BLOCK: begin
                                if (cmd_len >= 16'd8) begin
                                    work_addr = cmd_buf[5];
                                    req_len_u16 = {cmd_buf[6], cmd_buf[7]};
                                    copy_target_len = req_len_u16;
                                    if (copy_target_len > READ_BLOCK_MAX) begin
                                        copy_target_len = READ_BLOCK_MAX;
                                    end
                                    if ((work_addr + copy_target_len) > 256) begin
                                        copy_target_len = 256 - work_addr;
                                    end

                                    rsp_buf[0] <= RES_OK;
                                    rsp_buf[1] <= copy_target_len[15:8];
                                    rsp_buf[2] <= copy_target_len[7:0];
                                    rsp_len <= (16'd3 + copy_target_len);
                                    copy_idx <= 16'd0;
                                    st <= ST_DO_READ_BLOCK;
                                end else begin
                                    rsp_buf[0] <= RES_INVALID_ARG;
                                    rsp_len <= 16'd1;
                                end
                            end

                            OP_WRITE_BLOCK: begin
                                if (cmd_len >= 16'd8) begin
                                    work_addr = cmd_buf[5];
                                    req_len_u16 = {cmd_buf[6], cmd_buf[7]};
                                    copy_target_len = req_len_u16;
                                    if ((copy_target_len + 8) != cmd_len) begin
                                        rsp_buf[0] <= RES_INVALID_ARG;
                                        rsp_len <= 16'd1;
                                    end else begin
                                        if (copy_target_len > (256 - work_addr)) begin
                                            copy_target_len = 256 - work_addr;
                                        end
                                        if (copy_target_len > READ_BLOCK_MAX) begin
                                            copy_target_len = READ_BLOCK_MAX;
                                        end
                                        
                                        rsp_buf[0] <= RES_OK;
                                        rsp_buf[1] <= copy_target_len[15:8];
                                        rsp_buf[2] <= copy_target_len[7:0];
                                        rsp_len <= 16'd3;
                                        copy_idx <= 16'd0;
                                        st <= ST_DO_WRITE_BLOCK;
                                    end
                                end else begin
                                    rsp_buf[0] <= RES_INVALID_ARG;
                                    rsp_len <= 16'd1;
                                end
                            end

                            OP_GET_CAPS: begin
                                rsp_buf[0] <= RES_OK;
                                rsp_buf[1] <= (cmd_len >= 16'd4) ? cmd_buf[1] : 8'h00; // page echo
                                rsp_buf[2] <= 8'h00; // has_more=0
                                rsp_buf[3] <= 16'd0; // len hi
                                rsp_buf[4] <= 16'd23; // len lo
                                rsp_len <= 16'd28; // 5 + 23
                                copy_target_len <= 16'd23;
                                copy_idx <= 16'd0;
                                st <= ST_DO_CAPS;
                            end

                            OP_HELLO: begin
                                if (cmd_len >= 16'd3) begin
                                    req_len_u16 = {cmd_buf[1], cmd_buf[2]};
                                    if ((req_len_u16 + 3) != cmd_len) begin
                                        rsp_buf[0] <= RES_INVALID_ARG;
                                        rsp_len <= 16'd1;
                                    end else begin
                                        rsp_buf[0] <= RES_OK;
                                        rsp_buf[1] <= 8'h00;
                                        rsp_buf[2] <= 8'd14;
                                        rsp_len <= 16'd17;
                                        copy_target_len <= 16'd14;
                                        copy_idx <= 16'd0;
                                        st <= ST_DO_HELLO;
                                    end
                                end else begin
                                    rsp_buf[0] <= RES_INVALID_ARG;
                                    rsp_len <= 16'd1;
                                end
                            end

                            default: begin
                                rsp_buf[0] <= RES_NOT_SUPPORTED;
                                rsp_len <= 16'd1;
                            end
                        endcase
                    end
                    cmd_len <= 16'd0;
                    cmd_overflow <= 1'b0;
                    rsp_idx <= 16'd0;
                    dbg_idx <= 3'd0;
                end

                ST_DO_READ_BLOCK: begin
                    if (copy_idx < copy_target_len) begin
                        rsp_buf[3 + copy_idx] <= blk_mem[work_addr + copy_idx[7:0]];
                        copy_idx <= copy_idx + 16'd1;
                    end else begin
                        st <= ST_RSP_SEND;
                    end
                end

                ST_DO_WRITE_BLOCK: begin
                    if (copy_idx < copy_target_len) begin
                        blk_mem[work_addr + copy_idx[7:0]] <= cmd_buf[8 + copy_idx];
                        copy_idx <= copy_idx + 16'd1;
                    end else begin
                        st <= ST_RSP_SEND;
                    end
                end

                ST_DO_CAPS: begin
                    if (copy_idx < copy_target_len) begin
                        rsp_buf[5 + copy_idx] <= caps_blob[copy_idx[7:0]];
                        copy_idx <= copy_idx + 16'd1;
                    end else begin
                        st <= ST_RSP_SEND;
                    end
                end

                ST_DO_HELLO: begin
                    if (copy_idx < copy_target_len) begin
                        rsp_buf[3 + copy_idx] <= hello_blob[copy_idx[7:0]];
                        copy_idx <= copy_idx + 16'd1;
                    end else begin
                        st <= ST_RSP_SEND;
                    end
                end

                ST_RSP_SEND: begin
                    if (m_rsp_tvalid && m_rsp_tready) begin
                        if (m_rsp_tlast) begin
                            dbg_idx <= 3'd0;
                            st      <= ST_DBG_SEND;
                        end else begin
                            rsp_idx <= rsp_idx + 16'd1;
                        end
                    end
                end

                ST_DBG_SEND: begin
                    if (m_dbg_tvalid && m_dbg_tready) begin
                        if (dbg_idx == 3'd5) begin
                            st <= ST_IDLE;
                        end else begin
                            dbg_idx <= dbg_idx + 3'd1;
                        end
                    end
                end

                default: begin
                    st <= ST_IDLE;
                end
            endcase
        end
    end
endmodule

`default_nettype wire
