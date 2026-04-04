/**
 * FCSP DSHOT Engine — 4-Channel Wishbone Controller
 * 
 * Provides memory-mapped access to 4 DShot motor outputs.
 * Compatible with the FCSP/1 hardware-native offloader.
 */
`default_nettype none

module fcsp_dshot_engine #(
    parameter CLK_FREQ_HZ = 54_000_000
) (
    input  logic        clk,
    input  logic        rst,

    // Wishbone Slave
    input  logic [31:0] wb_adr_i,
    input  logic [31:0] wb_dat_i,
    input  logic        wb_we_i,
    input  logic        wb_cyc_i,
    input  logic        wb_stb_i,
    output logic        wb_ack_o,
    output logic [31:0] wb_dat_o,

    // Motor Outputs
    output logic [3:0]  o_motor_pins,
    output logic [3:0]  o_ready
);

    logic [15:0] motor_vals[4];
    logic [15:0] dshot_mode;
    logic        motor_write[4];

    // Wishbone Logic
    always_ff @(posedge clk) begin
        if (rst) begin
            wb_ack_o <= 1'b0;
            wb_dat_o <= 32'h0;
            dshot_mode <= 16'd150;
            for (int i=0; i<4; i++) motor_vals[i] <= 16'h0;
            for (int i=0; i<4; i++) motor_write[i] <= 1'b0;
        end else begin
            wb_ack_o <= 1'b0;
            for (int i=0; i<4; i++) motor_write[i] <= 1'b0;

            if (wb_cyc_i && wb_stb_i && !wb_ack_o) begin
                wb_ack_o <= 1'b1;
                if (wb_we_i) begin
                    case (wb_adr_i[5:2])
                        4'h0: begin motor_vals[0] <= wb_dat_i[15:0]; motor_write[0] <= 1'b1; end
                        4'h1: begin motor_vals[1] <= wb_dat_i[15:0]; motor_write[1] <= 1'b1; end
                        4'h2: begin motor_vals[2] <= wb_dat_i[15:0]; motor_write[2] <= 1'b1; end
                        4'h3: begin motor_vals[3] <= wb_dat_i[15:0]; motor_write[3] <= 1'b1; end
                        4'h5: dshot_mode <= wb_dat_i[15:0];
                        default: ;
                    endcase
                end else begin
                    case (wb_adr_i[5:2])
                        4'h0: wb_dat_o <= {16'h0, motor_vals[0]};
                        4'h1: wb_dat_o <= {16'h0, motor_vals[1]};
                        4'h2: wb_dat_o <= {16'h0, motor_vals[2]};
                        4'h3: wb_dat_o <= {16'h0, motor_vals[3]};
                        4'h4: wb_dat_o <= {28'h0, o_ready};
                        4'h5: wb_dat_o <= {16'h0, dshot_mode};
                        default: wb_dat_o <= 32'hdeadbeef;
                    endcase
                end
            end
        end
    end

    // Instinctiate 4 Output Drivers
    genvar i;
    generate
        for (i=0; i<4; i++) begin : gen_motors
            fcsp_dshot_output #( .CLK_FREQ_HZ(CLK_FREQ_HZ) ) u_motor (
                .clk(clk), .rst(rst),
                .i_dshot_value(motor_vals[i]),
                .i_dshot_mode(dshot_mode),
                .i_write(motor_write[i]),
                .o_pwm(o_motor_pins[i]),
                .o_ready(o_ready[i])
            );
        end
    endgenerate

endmodule
