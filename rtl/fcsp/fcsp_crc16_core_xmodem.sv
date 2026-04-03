`default_nettype none

// Combinational CRC16-XMODEM (poly 0x1021), byte step function.
// Ported from proven legacy implementation and wrapped for FCSP use.
module fcsp_crc16_core_xmodem (
    input  wire [7:0]  data_in,
    input  wire [15:0] crc_in,
    output wire [15:0] crc_out
);
    wire [7:0] d;
    wire [15:0] c;

    assign d = data_in;
    assign c = crc_in;

    assign crc_out[0]  = c[8] ^ c[12] ^ d[0] ^ d[4];
    assign crc_out[1]  = c[9] ^ c[13] ^ d[1] ^ d[5];
    assign crc_out[2]  = c[10] ^ c[14] ^ d[2] ^ d[6];
    assign crc_out[3]  = c[11] ^ c[15] ^ d[3] ^ d[7];
    assign crc_out[4]  = c[12] ^ d[4];
    assign crc_out[5]  = c[8] ^ c[12] ^ c[13] ^ d[0] ^ d[4] ^ d[5];
    assign crc_out[6]  = c[9] ^ c[13] ^ c[14] ^ d[1] ^ d[5] ^ d[6];
    assign crc_out[7]  = c[10] ^ c[14] ^ c[15] ^ d[2] ^ d[6] ^ d[7];
    assign crc_out[8]  = c[0] ^ c[11] ^ c[15] ^ d[3] ^ d[7];
    assign crc_out[9]  = c[1] ^ c[12] ^ d[4];
    assign crc_out[10] = c[2] ^ c[13] ^ d[5];
    assign crc_out[11] = c[3] ^ c[14] ^ d[6];
    assign crc_out[12] = c[4] ^ c[8] ^ c[12] ^ c[15] ^ d[0] ^ d[4] ^ d[7];
    assign crc_out[13] = c[5] ^ c[9] ^ c[13] ^ d[1] ^ d[5];
    assign crc_out[14] = c[6] ^ c[10] ^ c[14] ^ d[2] ^ d[6];
    assign crc_out[15] = c[7] ^ c[11] ^ c[15] ^ d[3] ^ d[7];
endmodule

`default_nettype wire
