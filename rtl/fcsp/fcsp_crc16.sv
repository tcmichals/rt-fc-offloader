`default_nettype none

module fcsp_crc16 (
    input  logic        clk,
    input  logic        rst,

    // Stream control
    input  logic        i_frame_start,
    input  logic        i_data_valid,
    input  logic [7:0]  i_data_byte,
    input  logic        i_frame_end,

    // Received CRC from wire for compare when frame ends
    input  logic [15:0] i_recv_crc,

    // Status
    output logic [15:0] o_crc_value,
    output logic        o_crc_valid,
    output logic        o_crc_ok
);
    logic [15:0] crc_reg;
    wire  [15:0] crc_next;

    fcsp_crc16_core_xmodem u_crc_core (
        .data_in(i_data_byte),
        .crc_in(crc_reg),
        .crc_out(crc_next)
    );

    always_ff @(posedge clk) begin
        if (rst) begin
            crc_reg     <= 16'h0000;
            o_crc_value <= 16'h0000;
            o_crc_valid <= 1'b0;
            o_crc_ok    <= 1'b0;
        end else begin
            o_crc_valid <= 1'b0;

            if (i_frame_start) begin
                crc_reg <= 16'h0000;
            end

            if (i_data_valid) begin
                crc_reg <= crc_next;
            end

            if (i_frame_end) begin
                o_crc_value <= i_data_valid ? crc_next : crc_reg;
                o_crc_ok    <= ((i_data_valid ? crc_next : crc_reg) == i_recv_crc);
                o_crc_valid <= 1'b1;
            end
        end
    end
endmodule

`default_nettype wire
