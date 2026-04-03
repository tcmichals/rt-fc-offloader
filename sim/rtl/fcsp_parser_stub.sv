module fcsp_parser_stub (
    input  logic clk,
    input  logic rst_n,
    input  logic in_valid,
    input  logic [7:0] in_byte,
    output logic in_ready
);
    // Stub module for cocotb/verilator wiring bring-up.
    // Replace with rtl/fcsp/fcsp_parser.sv once parser interface is finalized.
    assign in_ready = 1'b1;
endmodule
