/**
 * wb_dshot_mailbox - Dual-Port DSHOT Controller with Mailbox Arbitration
 *
 * This module provides DSHOT motor control accessible from two independent
 * Wishbone masters (CPU and SPI) without conflicts.
 *
 * Features:
 *   - Zero-latency reads from both ports
 *   - FIFO-based write arbitration (Port B/SPI has priority)
 *   - Automatic dispatch to per-motor DSHOT encoders
 *   - **Auto-CRC Hardware Helper**: Calculate DSHOT CRC in RTL to simplify host software.
 * 
 * Register Map:
 *   0x00: MOTOR1_RAW [31:0] - 16-bit Full DSHOT word (throttle[15:5], telem[4], CRC[3:0])
 *   0x04: MOTOR2_RAW [31:0]
 *   0x08: MOTOR3_RAW [31:0]
 *   0x0C: MOTOR4_RAW [31:0]
 *   0x10: STATUS     [3:0]  - Ready bits
 *   0x14: CONFIG     [15:0] - DSHOT mode (150, 300, 600)
 * 
 *   **SMART REGISTERS (New)**:
 *   0x40: MOTOR1_THR [15:0] - 11-bit Throttle + 1-bit Telem. Hardware calculates CRC[3:0].
 *   0x44: MOTOR2_THR [15:0]
 *   0x48: MOTOR3_THR [15:0]
 *   0x4C: MOTOR4_THR [15:0]
 */

module wb_dshot_mailbox #(
    parameter CLK_FREQ_HZ = 54_000_000,
    parameter DEFAULT_MODE = 150
) (
    input  logic        clk,
    input  logic        rst,

    // Port A: Wishbone Slave (for CPU/SERV)
    input  logic [31:0] wba_adr_i,
    input  logic [31:0] wba_dat_i,
    output logic [31:0] wba_dat_o,
    input  logic [3:0]  wba_sel_i,
    input  logic        wba_we_i,
    input  logic        wba_stb_i,
    input  logic        wba_cyc_i,
    output logic        wba_ack_o,

    // Port B: Wishbone Slave (for SPI bridge)
    input  logic [31:0] wbb_adr_i,
    input  logic [31:0] wbb_dat_i,
    output logic [31:0] wbb_dat_o,
    input  logic [3:0]  wbb_sel_i,
    input  logic        wbb_we_i,
    input  logic        wbb_stb_i,
    input  logic        wbb_cyc_i,
    output logic        wbb_ack_o,

    // DSHOT Motor Outputs
    output logic        motor1_o,
    output logic        motor2_o,
    output logic        motor3_o,
    output logic        motor4_o,

    // Ready signals
    output logic        motor1_ready,
    output logic        motor2_ready,
    output logic        motor3_ready,
    output logic        motor4_ready
);

    // DSHOT Mode selection
    logic [15:0] dshot_mode_reg;
    always_ff @(posedge clk) begin
        if (rst) dshot_mode_reg <= DEFAULT_MODE[15:0];
        else if ((wba_stb_i && wba_cyc_i && wba_we_i && !wba_ack_o && (wba_adr_i[7:2] == 6'h05)) ||
                 (wbb_stb_i && wbb_cyc_i && wbb_we_i && !wbb_ack_o && (wbb_adr_i[7:2] == 6'h05)))
            dshot_mode_reg <= wba_dat_i[15:0]; // Use whichever port writes
    end

    // --- CRC Helper Function ---
    function logic [3:0] dshot_crc(logic [11:0] val);
        dshot_crc = (val[3:0] ^ val[7:4] ^ val[11:8]) & 4'hF;
    endfunction

    // --- Write Arbitration & Data Mux ---
    logic [31:0] mailbox_in_data;
    logic [2:0]  mailbox_in_id;
    logic        mailbox_in_vld;
    
    // Priority: Port B (SPI) > Port A (CPU)
    wire arb_port_b = wbb_stb_i && wbb_cyc_i && wbb_we_i && !wbb_ack_o;
    wire arb_port_a = wba_stb_i && wba_cyc_i && wba_we_i && !wba_ack_o && !arb_port_b;

    logic [31:0] raw_dat;
    logic [7:0]  addr_full;

    always_comb begin
        mailbox_in_vld  = arb_port_b | arb_port_a;
        mailbox_in_id   = arb_port_b ? wbb_adr_i[4:2] : wba_adr_i[4:2];
        
        raw_dat   = arb_port_b ? wbb_dat_i : wba_dat_i;
        addr_full = arb_port_b ? wbb_adr_i[7:0] : wba_adr_i[7:0];
        
        if (addr_full[6] == 1'b1) begin // Smart/THR Registers (0x40-0x4C)
            // Auto-calculate CRC: data[15:4]=THR+TELEM
            mailbox_in_data = {16'h0, raw_dat[15:4], dshot_crc(raw_dat[15:4])};
        end else begin
            // Raw Registers (0x00-0x0C)
            mailbox_in_data = raw_dat;
        end
    end

    // --- Mailbox FIFO & Encoders ---
    logic [31:0] dispatch_data;
    logic [2:0]  dispatch_id;
    logic        dispatch_vld;

    motor_mailbox_sv #( .NUM_MOTORS(4) ) u_mailbox (
        .clk(clk), .rst(rst),
        .wb_adr_i(wba_adr_i[4:2]), .wb_dat_i(wba_dat_i), .wb_we_i(1'b0), .wb_stb_i(1'b0), .wb_cyc_i(1'b0), .wb_ack_o(wba_ack_o), .wb_dat_o(wba_dat_o),
        .gen_addr(mailbox_in_id), .gen_wdata(mailbox_in_data), .gen_wen(mailbox_in_vld), .gen_rdata(),
        .dshot_out_data(dispatch_data), .dshot_out_id(dispatch_id), .dshot_out_vld(dispatch_vld)
    );
    
    // Manual Port B Ack (Mailbox doesn't do it)
    always_ff @(posedge clk) begin
        if (rst) wbb_ack_o <= 0;
        else wbb_ack_o <= arb_port_b;
    end

    // Encoders (1-4)
    dshot_output #( .clockFrequency(CLK_FREQ_HZ) ) u_motor1 (
        .i_clk(clk), .i_reset(rst), .i_dshot_value(dispatch_data[15:0]), .i_dshot_mode(dshot_mode_reg),
        .i_write(dispatch_vld && dispatch_id==0), .o_pwm(motor1_o), .o_ready(motor1_ready)
    );
    dshot_output #( .clockFrequency(CLK_FREQ_HZ) ) u_motor2 (
        .i_clk(clk), .i_reset(rst), .i_dshot_value(dispatch_data[15:0]), .i_dshot_mode(dshot_mode_reg),
        .i_write(dispatch_vld && dispatch_id==1), .o_pwm(motor2_o), .o_ready(motor2_ready)
    );
    dshot_output #( .clockFrequency(CLK_FREQ_HZ) ) u_motor3 (
        .i_clk(clk), .i_reset(rst), .i_dshot_value(dispatch_data[15:0]), .i_dshot_mode(dshot_mode_reg),
        .i_write(dispatch_vld && dispatch_id==2), .o_pwm(motor3_o), .o_ready(motor3_ready)
    );
    dshot_output #( .clockFrequency(CLK_FREQ_HZ) ) u_motor4 (
        .i_clk(clk), .i_reset(rst), .i_dshot_value(dispatch_data[15:0]), .i_dshot_mode(dshot_mode_reg),
        .i_write(dispatch_vld && dispatch_id==3), .o_pwm(motor4_o), .o_ready(motor4_ready)
    );

endmodule
