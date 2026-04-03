`default_nettype none

module fcsp_parser (
    input  logic clk,
    input  logic rst_n,
    input  logic in_valid,
    input  logic [7:0] in_byte,
    output logic in_ready
);
    // FCSP parser scaffold
    // Next iteration will implement:
    // - sync search (0xA5)
    // - header parse and payload_len bounds
    // - CRC feed/verify and frame emit interface

    logic [7:0] last_byte;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            last_byte <= 8'h00;
        end else if (in_valid && in_ready) begin
            last_byte <= in_byte;
        end
    end

    assign in_ready = 1'b1;
endmodule

`default_nettype wire
