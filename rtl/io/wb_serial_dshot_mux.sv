// Wishbone Serial/DSHOT Pin Mux with MSP Sniffer
// Ported from legacy wb_serial_dshot_mux.sv
//
// Controls which driver (DShot or serial) drives each motor pin.
// Includes MSP header sniffer for auto-passthrough and 5-second watchdog.
//
// Register at word address 0x0400:
//   bit[0]   = mode: 0=serial/passthrough, 1=DShot (default=1)
//   bit[2:1] = channel: motor 0–3
//   bit[3]   = msp_mode: 0=passthrough, 1=MSP FC protocol
//   bit[4]   = force_low: drive selected pin LOW (break for ESC bootloader)
//
// Source: /media/tcmichals/projects/Tang9K/HacksterIO/SPIQuadCopter/src/wb_serial_dshot_mux.sv

`default_nettype wire

module wb_serial_dshot_mux #(
    parameter int CLK_FREQ_HZ = 54_000_000
) (
    input  wire        clk,
    input  wire        rst,

    // Wishbone slave
    input  wire [31:0] wb_dat_i,
    input  wire [31:0] wb_adr_i,
    input  wire        wb_we_i,
    input  wire [3:0]  wb_sel_i,
    input  wire        wb_stb_i,
    input  wire        wb_cyc_i,
    output logic [31:0] wb_dat_o,
    output logic        wb_ack_o,

    // Status outputs
    output wire        mux_sel,        // 0=serial, 1=DShot (effective)
    output logic [1:0]  mux_ch,         // selected motor channel
    output logic        msp_mode,       // 0=passthrough, 1=MSP

    // PC sniffer interface
    input  wire [7:0]  pc_rx_data,
    input  wire        pc_rx_valid,

    // Motor pad bidirectional
    inout  wire  [3:0]  pad_motor,

    // Internal inputs
    input  wire [3:0]  dshot_in,       // from DSHOT controller
    input  wire        serial_tx_i,    // from serial bridge
    input  wire        serial_oe_i,    // from serial bridge (active high)
    output wire        serial_rx_o     // to serial bridge

`ifdef SIM_CONTROL
    , input  wire        tb_mux_force_en
    , input  wire        tb_mux_force_sel
    , input  wire [1:0]  tb_mux_force_ch
`endif
);

    // Address decode: only respond to 0x0400
    wire sel = wb_cyc_i & wb_stb_i & (wb_adr_i[11:2] == 10'h100);

    // Register input signals for timing closure
    logic [3:0] dshot_in_reg;
    logic       serial_tx_reg;
    logic       serial_oe_reg;

    always_ff @(posedge clk) begin
        if (rst) begin
            dshot_in_reg  <= 4'b0;
            serial_tx_reg <= 1'b1;
            serial_oe_reg <= 1'b0;
        end else begin
            dshot_in_reg  <= dshot_in;
            serial_tx_reg <= serial_tx_i;
            serial_oe_reg <= serial_oe_i;
        end
    end

    logic reg_mux_sel;
    logic reg_force_low;

    always_ff @(posedge clk) begin
        if (rst) begin
            reg_mux_sel  <= 1'b1;  // Default: DSHOT (safety)
            mux_ch       <= 2'b0;
            msp_mode     <= 1'b0;
            reg_force_low <= 1'b0;
            wb_ack_o     <= 1'b0;
            wb_dat_o     <= 32'b0;
        end else begin
            wb_ack_o <= 1'b0;

            if (sel && !wb_ack_o) begin
                wb_ack_o <= 1'b1;
                if (wb_we_i) begin
                    reg_mux_sel   <= wb_dat_i[0];
                    mux_ch        <= wb_dat_i[2:1];
                    msp_mode      <= wb_dat_i[3];
                    reg_force_low <= wb_dat_i[4];
                end
                wb_dat_o <= {27'b0, reg_force_low, msp_mode, mux_ch, reg_mux_sel};
            end
        end
    end

    // ==========================================
    // MSP Sniffer (auto-passthrough)
    // ==========================================
    typedef enum logic [2:0] {
        S_IDLE   = 3'd0,
        S_DOLLAR = 3'd1,
        S_M      = 3'd2,
        S_ARROW  = 3'd3,
        S_SIZE   = 3'd4
    } sniff_state_t;

    sniff_state_t sniff_state;
    logic         auto_passthrough_active;
    logic [31:0]  watchdog_timer;

    localparam int WATCHDOG_LIMIT = CLK_FREQ_HZ * 5;

    always_ff @(posedge clk) begin
        if (rst) begin
            sniff_state             <= S_IDLE;
            auto_passthrough_active <= 1'b0;
            watchdog_timer          <= 32'd0;
        end else begin
            logic watchdog_reset;
            watchdog_reset = 1'b0;

            if (pc_rx_valid) begin
                case (sniff_state)
                    S_IDLE:   if (pc_rx_data == 8'h24) sniff_state <= S_DOLLAR;  // '$'
                    S_DOLLAR: sniff_state <= (pc_rx_data == 8'h4D) ? S_M      : S_IDLE; // 'M'
                    S_M:      sniff_state <= (pc_rx_data == 8'h3C) ? S_ARROW  : S_IDLE; // '<'
                    S_ARROW:  sniff_state <= S_SIZE;
                    S_SIZE: begin
                        if (pc_rx_data == 8'hF5 || pc_rx_data == 8'h64) begin
                            auto_passthrough_active <= 1'b1;
                            watchdog_reset = 1'b1;
                        end
                        sniff_state <= S_IDLE;
                    end
                    default: sniff_state <= S_IDLE;
                endcase

                if (auto_passthrough_active) watchdog_reset = 1'b1;
            end

            // Watchdog timer
            if (auto_passthrough_active) begin
                if (watchdog_reset)
                    watchdog_timer <= 32'd0;
                else if (watchdog_timer < WATCHDOG_LIMIT[31:0])
                    watchdog_timer <= watchdog_timer + 32'd1;
                else
                    auto_passthrough_active <= 1'b0;
            end
        end
    end

    // ==========================================
    // Effective mux selection
    // ==========================================
    logic        effective_mux_sel;
    logic [1:0]  effective_mux_ch;

`ifdef SIM_CONTROL
    assign effective_mux_sel = tb_mux_force_en ? tb_mux_force_sel : (auto_passthrough_active ? 1'b0 : reg_mux_sel);
    assign effective_mux_ch  = tb_mux_force_en ? tb_mux_force_ch  : mux_ch;
`else
    assign effective_mux_sel = auto_passthrough_active ? 1'b0 : reg_mux_sel;
    assign effective_mux_ch  = mux_ch;
`endif

    assign mux_sel = effective_mux_sel;

    // One-cycle global tristate on mode/channel change
    logic        prev_mux_sel;
    logic [1:0]  prev_mux_ch;
    logic        global_tristate;

    always_ff @(posedge clk) begin
        if (rst) begin
            prev_mux_sel    <= 1'b1;
            prev_mux_ch     <= 2'b0;
            global_tristate <= 1'b0;
        end else begin
            if ((effective_mux_sel != prev_mux_sel) || (effective_mux_ch != prev_mux_ch)) begin
                global_tristate <= 1'b1;
                prev_mux_sel   <= effective_mux_sel;
                prev_mux_ch    <= effective_mux_ch;
            end else begin
                global_tristate <= 1'b0;
            end
        end
    end

    // ==========================================
    // IO buffer and muxing
    // ==========================================
    genvar gi;
    generate
        for (gi = 0; gi < 4; gi++) begin : gen_pads
            wire is_target = (effective_mux_ch == gi[1:0]);
            wire dshot_val = dshot_in_reg[gi];

            logic pad_out_data;
            logic pad_oe_active_high;

            always_ff @(posedge clk) begin
                if (rst) begin
                    pad_out_data       <= 1'b0;
                    pad_oe_active_high <= 1'b0;
                end else begin
                    if (effective_mux_sel == 1'b1) begin
                        // DSHOT mode: all motor pins driven by DShot
                        pad_out_data       <= dshot_val;
                        pad_oe_active_high <= 1'b1;
                    end else begin
                        if (is_target) begin
                            if (reg_force_low) begin
                                pad_out_data       <= 1'b0;
                                pad_oe_active_high <= 1'b1;
                            end else begin
                                pad_out_data       <= serial_tx_reg;
                                pad_oe_active_high <= serial_oe_reg;
                            end
                        end else begin
                            pad_out_data       <= 1'b0;
                            pad_oe_active_high <= 1'b0;
                        end
                    end
                end
            end

            wire pad_input_val;
            wire final_drive_enable = ~global_tristate & pad_oe_active_high;

`ifdef GOWIN_FPGA
            wire gowin_oen = ~final_drive_enable;
            IOBUF io_inst (
                .O   (pad_input_val),
                .I   (pad_out_data),
                .OEN (gowin_oen),
                .IO  (pad_motor[gi])
            );
`else
            assign pad_motor[gi]  = final_drive_enable ? pad_out_data : 1'bz;
            assign pad_input_val  = pad_motor[gi];
`endif
        end
    endgenerate

    // Collect RX taps
    logic [3:0] rx_tap_array;
    generate
        for (gi = 0; gi < 4; gi++) begin : tap_conn
            assign rx_tap_array[gi] = gen_pads[gi].pad_input_val;
        end
    endgenerate

    // 2-FF synchronizer on selected channel RX
    logic serial_rx_meta, serial_rx_sync;

    always_ff @(posedge clk) begin
        if (rst) begin
            serial_rx_meta <= 1'b1;
            serial_rx_sync <= 1'b1;
        end else begin
            serial_rx_meta <= rx_tap_array[effective_mux_ch];
            serial_rx_sync <= serial_rx_meta;
        end
    end

    // Gate serial RX: HIGH idle in DSHOT mode
    assign serial_rx_o = (effective_mux_sel == 1'b0) ? serial_rx_sync : 1'b1;

    // Suppress unused-signal lint
    logic _unused;
    always_comb _unused = &{wb_sel_i, wb_dat_i[31:5], wb_adr_i[31:12], wb_adr_i[1:0]};

endmodule

`default_nettype wire
