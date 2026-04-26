// Wishbone IO Bus Address Decoder/Mux
//
// Connects a single Wishbone master to multiple IO slave peripherals
// based on the upper address bits.
//
// Address Map (absolute → slave):
//   0x40000000  → WHO_AM_I (identity, read-only)
//   0x40000100  → PWM decoder (pwmdecoder_wb)
//   0x40000300  → DShot controller (wb_dshot_controller)
//   0x40000400  → Serial/DShot mux (wb_serial_dshot_mux)
//   0x40000600  → NeoPixel (wb_neoPx)
//   0x40000900  → ESC UART (wb_esc_uart)
//   0x40000C00  → LED controller (wb_led_controller)
//
// Unmatched addresses respond with ack + data=0 (no hang).

`default_nettype wire

module wb_io_bus #(
    parameter logic [31:0] WHO_AM_I_VALUE = 32'hFC50_0002
) (
    input  wire        clk,
    input  wire        rst,

    // Wishbone master interface (from fcsp_wishbone_master)
    input  wire [31:0] wbm_adr_i,
    input  wire [31:0] wbm_dat_i,
    output logic [31:0] wbm_dat_o,
    input  wire [3:0]  wbm_sel_i,
    input  wire        wbm_we_i,
    input  wire        wbm_cyc_i,
    input  wire        wbm_stb_i,
    output logic        wbm_ack_o,

    // Slave 0: DShot controller
    output logic [31:0] dshot_adr_o,
    output logic [31:0] dshot_dat_o,
    input  wire [31:0] dshot_dat_i,
    output logic [3:0]  dshot_sel_o,
    output logic        dshot_we_o,
    output logic        dshot_cyc_o,
    output logic        dshot_stb_o,
    input  wire        dshot_ack_i,

    // Slave 1: Serial/DShot mux
    output logic [31:0] mux_adr_o,
    output logic [31:0] mux_dat_o,
    input  wire [31:0] mux_dat_i,
    output logic [3:0]  mux_sel_o,
    output logic        mux_we_o,
    output logic        mux_cyc_o,
    output logic        mux_stb_o,
    input  wire        mux_ack_i,

    // Slave 2: NeoPixel
    output logic [31:0] neo_adr_o,
    output logic [31:0] neo_dat_o,
    input  wire [31:0] neo_dat_i,
    output logic [3:0]  neo_sel_o,
    output logic        neo_we_o,
    output logic        neo_cyc_o,
    output logic        neo_stb_o,
    input  wire        neo_ack_i,

    // Slave 3: ESC UART
    output logic [3:0]  esc_adr_o,
    output logic [31:0] esc_dat_o,
    input  wire [31:0] esc_dat_i,
    output logic        esc_we_o,
    output logic        esc_cyc_o,
    output logic        esc_stb_o,
    input  wire        esc_ack_i,

    // Slave 4: PWM decoder
    output logic [31:0] pwm_adr_o,
    output logic [31:0] pwm_dat_o,
    input  wire [31:0] pwm_dat_i,
    output logic [3:0]  pwm_sel_o,
    output logic        pwm_we_o,
    output logic        pwm_cyc_o,
    output logic        pwm_stb_o,
    input  wire        pwm_ack_i,

    // Slave 5: LED controller
    output logic [31:0] led_adr_o,
    output logic [31:0] led_dat_o,
    input  wire [31:0] led_dat_i,
    output logic [3:0]  led_sel_o,
    output logic        led_we_o,
    output logic        led_cyc_o,
    output logic        led_stb_o,
    input  wire        led_ack_i
);

    // Address decode using bits [15:8] of the 32-bit address
    // (upper bits are 0x4000xxxx, lower bits are register offsets)
    wire [7:0] page = wbm_adr_i[15:8];

    localparam logic [7:0] PAGE_WHO_AM_I = 8'h00;  // 0x40000000
    localparam logic [7:0] PAGE_PWM      = 8'h01;  // 0x40000100
    localparam logic [7:0] PAGE_DSHOT    = 8'h03;  // 0x40000300
    localparam logic [7:0] PAGE_MUX      = 8'h04;  // 0x40000400
    localparam logic [7:0] PAGE_NEO      = 8'h06;  // 0x40000600
    localparam logic [7:0] PAGE_ESC      = 8'h09;  // 0x40000900
    localparam logic [7:0] PAGE_LED      = 8'h0C;  // 0x40000C00

    typedef enum logic [2:0] {
        SEL_NONE   = 3'd0,
        SEL_DSHOT  = 3'd1,
        SEL_MUX    = 3'd2,
        SEL_NEO    = 3'd3,
        SEL_ESC    = 3'd4,
        SEL_PWM    = 3'd5,
        SEL_LED    = 3'd6,
        SEL_WHOAMI = 3'd7
    } slave_sel_t;

    slave_sel_t active_slave;

    always_comb begin
        if (wbm_adr_i[31:16] == 16'h4000) begin
            case (page)
                PAGE_WHO_AM_I: active_slave = SEL_WHOAMI;
                PAGE_PWM:      active_slave = SEL_PWM;
                PAGE_DSHOT:    active_slave = SEL_DSHOT;
                PAGE_MUX:      active_slave = SEL_MUX;
                PAGE_NEO:      active_slave = SEL_NEO;
                PAGE_ESC:      active_slave = SEL_ESC;
                PAGE_LED:      active_slave = SEL_LED;
                default:       active_slave = SEL_NONE;
            endcase
        end else begin
            active_slave = SEL_NONE;
        end
    end

    // Forward address, data, control to all slaves (active gated by stb)
    // Common signals
    always_comb begin
        // DShot
        dshot_adr_o = wbm_adr_i;
        dshot_dat_o = wbm_dat_i;
        dshot_sel_o = wbm_sel_i;
        dshot_we_o  = wbm_we_i;
        dshot_cyc_o = wbm_cyc_i && (active_slave == SEL_DSHOT);
        dshot_stb_o = wbm_stb_i && (active_slave == SEL_DSHOT);

        // Mux
        mux_adr_o = wbm_adr_i;
        mux_dat_o = wbm_dat_i;
        mux_sel_o = wbm_sel_i;
        mux_we_o  = wbm_we_i;
        mux_cyc_o = wbm_cyc_i && (active_slave == SEL_MUX);
        mux_stb_o = wbm_stb_i && (active_slave == SEL_MUX);

        // NeoPixel
        neo_adr_o = wbm_adr_i;
        neo_dat_o = wbm_dat_i;
        neo_sel_o = wbm_sel_i;
        neo_we_o  = wbm_we_i;
        neo_cyc_o = wbm_cyc_i && (active_slave == SEL_NEO);
        neo_stb_o = wbm_stb_i && (active_slave == SEL_NEO);

        // ESC UART
        esc_adr_o = wbm_adr_i[3:0];
        esc_dat_o = wbm_dat_i;
        esc_we_o  = wbm_we_i;
        esc_cyc_o = wbm_cyc_i && (active_slave == SEL_ESC);
        esc_stb_o = wbm_stb_i && (active_slave == SEL_ESC);

        // PWM decoder
        pwm_adr_o = wbm_adr_i;
        pwm_dat_o = wbm_dat_i;
        pwm_sel_o = wbm_sel_i;
        pwm_we_o  = wbm_we_i;
        pwm_cyc_o = wbm_cyc_i && (active_slave == SEL_PWM);
        pwm_stb_o = wbm_stb_i && (active_slave == SEL_PWM);

        // LED controller
        led_adr_o = wbm_adr_i;
        led_dat_o = wbm_dat_i;
        led_sel_o = wbm_sel_i;
        led_we_o  = wbm_we_i;
        led_cyc_o = wbm_cyc_i && (active_slave == SEL_LED);
        led_stb_o = wbm_stb_i && (active_slave == SEL_LED);
    end

    // WHO_AM_I: simple single-cycle ack for read
    logic whoami_ack;
    always_ff @(posedge clk) begin
        if (rst)
            whoami_ack <= 1'b0;
        else
            whoami_ack <= wbm_cyc_i && wbm_stb_i && (active_slave == SEL_WHOAMI) && !whoami_ack;
    end

    // Default ack for unmapped addresses
    logic none_ack;
    always_ff @(posedge clk) begin
        if (rst)
            none_ack <= 1'b0;
        else
            none_ack <= wbm_cyc_i && wbm_stb_i && (active_slave == SEL_NONE) && !none_ack;
    end

    // Return data and ack mux
    always_comb begin
        case (active_slave)
            SEL_DSHOT: begin
                wbm_dat_o = dshot_dat_i;
                wbm_ack_o = dshot_ack_i;
            end
            SEL_MUX: begin
                wbm_dat_o = mux_dat_i;
                wbm_ack_o = mux_ack_i;
            end
            SEL_NEO: begin
                wbm_dat_o = neo_dat_i;
                wbm_ack_o = neo_ack_i;
            end
            SEL_ESC: begin
                wbm_dat_o = esc_dat_i;
                wbm_ack_o = esc_ack_i;
            end
            SEL_PWM: begin
                wbm_dat_o = pwm_dat_i;
                wbm_ack_o = pwm_ack_i;
            end
            SEL_LED: begin
                wbm_dat_o = led_dat_i;
                wbm_ack_o = led_ack_i;
            end
            SEL_WHOAMI: begin
                wbm_dat_o = WHO_AM_I_VALUE;
                wbm_ack_o = whoami_ack;
            end
            default: begin
                wbm_dat_o = 32'h0;
                wbm_ack_o = none_ack;
            end
        endcase
    end

endmodule

`default_nettype wire
