`default_nettype none

// Minimal AXIS-style frame byte stage (1-deep elastic buffer).
//
// Purpose:
// - teaching/reference block for valid/ready behavior with tlast
// - tiny reusable stage for decoupling producer/consumer timing
module axis_frame_stage (
    input  logic       clk,
    input  logic       rst,

    // Input stream
    input  logic       s_tvalid,
    input  logic [7:0] s_tdata,
    input  logic       s_tlast,
    output logic       s_tready,

    // Output stream
    output logic       m_tvalid,
    output logic [7:0] m_tdata,
    output logic       m_tlast,
    input  logic       m_tready
);
    logic       hold_valid;
    logic [7:0] hold_data;
    logic       hold_last;

    wire pop  = hold_valid && m_tready;
    wire push = s_tvalid && s_tready;

    assign s_tready = !hold_valid || m_tready;
    assign m_tvalid = hold_valid;
    assign m_tdata  = hold_data;
    assign m_tlast  = hold_last;

    always_ff @(posedge clk) begin
        if (rst) begin
            hold_valid <= 1'b0;
            hold_data  <= 8'h00;
            hold_last  <= 1'b0;
        end else begin
            // Occupancy update from handshake events
            unique case ({push, pop})
                2'b10: hold_valid <= 1'b1; // fill
                2'b01: hold_valid <= 1'b0; // drain
                default: begin
                    // 2'b00 keep state; 2'b11 remains full (replace data)
                    hold_valid <= hold_valid || push;
                end
            endcase

            // Capture new sample on push, including simultaneous push+pop
            if (push) begin
                hold_data <= s_tdata;
                hold_last <= s_tlast;
            end
        end
    end
endmodule

`default_nettype wire
