// Wishbone ESC UART Controller — half-duplex serial for BLHeli ESC config
// Ported from legacy wb_esc_uart.sv
//
// Register Map (offset from base):
//   0x00: TX_DATA  [W]  — write byte to transmit
//   0x04: STATUS   [R]  — bit0=TX ready, bit1=RX valid, bit2=TX active
//   0x08: RX_DATA  [R]  — read received byte (clears RX valid)
//   0x0C: BAUD_DIV [RW] — programmable clocks-per-bit divider
//
// Half-duplex: TX drives line, RX listens when idle.
// Default baud: 19200 (configurable via BAUD_DIV register).
//
// Source: /media/tcmichals/projects/Tang9K/HacksterIO/SPIQuadCopter/src/wb_esc_uart.sv

`default_nettype none

module wb_esc_uart #(
    parameter int CLK_FREQ_HZ = 54_000_000
) (
    input  logic        clk,
    input  logic        rst,

    // Wishbone slave
    input  logic [3:0]  wb_adr_i,
    input  logic [31:0] wb_dat_i,
    output logic [31:0] wb_dat_o,
    input  logic        wb_we_i,
    input  logic        wb_stb_i,
    input  logic        wb_cyc_i,
    output logic        wb_ack_o,

    // Half-duplex serial
    output logic        tx_out,
    input  logic        rx_in,
    output logic        tx_active,

    // Hardware Stream Interface (FCSP CH 0x05 bypass)
    input  logic [7:0]  s_esc_tdata,
    input  logic        s_esc_tvalid,
    output logic        s_esc_tready,
    output logic [7:0]  m_esc_tdata,
    output logic        m_esc_tvalid,
    input  logic        m_esc_tready
);

    // Default baud rate
    localparam int DEFAULT_BAUD   = 19_200;
    localparam int DEFAULT_CLKDIV = CLK_FREQ_HZ / DEFAULT_BAUD;

    // Programmable divider register
    logic [15:0] baud_div;
    wire  [15:0] clks_per_bit = baud_div;
    wire  [15:0] half_bit     = {1'b0, baud_div[15:1]};
    wire  [15:0] guard_clks   = baud_div;

    // =========================================================================
    // TX State Machine
    // =========================================================================
    typedef enum logic [2:0] {
        TX_IDLE,
        TX_START,
        TX_DATA,
        TX_STOP,
        TX_GUARD
    } tx_state_t;

    tx_state_t   tx_state;
    logic [7:0]  tx_shift;
    logic [2:0]  tx_bit_idx;
    logic [15:0] tx_counter;
    logic        tx_ready;
    logic [7:0]  tx_data_reg;
    logic        tx_data_valid;
    logic        tx_data_consumed;

    // Stream TX ready — accept when TX idle and no WB byte pending
    assign s_esc_tready = (tx_state == TX_IDLE) && !tx_data_valid;

    always_ff @(posedge clk) begin
        if (rst) begin
            tx_state         <= TX_IDLE;
            tx_out           <= 1'b1;
            tx_shift         <= 8'h00;
            tx_bit_idx       <= 3'd0;
            tx_counter       <= 16'd0;
            tx_ready         <= 1'b1;
            tx_active        <= 1'b0;
            tx_data_consumed <= 1'b0;
        end else begin
            tx_data_consumed <= 1'b0;

            case (tx_state)
                TX_IDLE: begin
                    tx_out    <= 1'b1;
                    tx_active <= 1'b0;
                    tx_ready  <= 1'b1;
                    if (tx_data_valid) begin
                        tx_shift         <= tx_data_reg;
                        tx_state         <= TX_START;
                        tx_counter       <= clks_per_bit - 16'd1;
                        tx_out           <= 1'b0;
                        tx_ready         <= 1'b0;
                        tx_active        <= 1'b1;
                        tx_data_consumed <= 1'b1;
                    end else if (s_esc_tvalid) begin
                        tx_shift         <= s_esc_tdata;
                        tx_state         <= TX_START;
                        tx_counter       <= clks_per_bit - 16'd1;
                        tx_out           <= 1'b0;
                        tx_ready         <= 1'b0;
                        tx_active        <= 1'b1;
                    end
                end

                TX_START: begin
                    if (tx_counter == 16'd0) begin
                        tx_state   <= TX_DATA;
                        tx_counter <= clks_per_bit - 16'd1;
                        tx_out     <= tx_shift[0];
                        tx_bit_idx <= 3'd0;
                    end else begin
                        tx_counter <= tx_counter - 16'd1;
                    end
                end

                TX_DATA: begin
                    if (tx_counter == 16'd0) begin
                        tx_shift <= {1'b0, tx_shift[7:1]};
                        if (tx_bit_idx == 3'd7) begin
                            tx_state   <= TX_STOP;
                            tx_counter <= clks_per_bit - 16'd1;
                            tx_out     <= 1'b1;
                        end else begin
                            tx_bit_idx <= tx_bit_idx + 3'd1;
                            tx_counter <= clks_per_bit - 16'd1;
                            tx_out     <= tx_shift[1];
                        end
                    end else begin
                        tx_counter <= tx_counter - 16'd1;
                    end
                end

                TX_STOP: begin
                    if (tx_counter == 16'd0) begin
                        tx_state   <= TX_GUARD;
                        tx_counter <= guard_clks - 16'd1;
                    end else begin
                        tx_counter <= tx_counter - 16'd1;
                    end
                end

                TX_GUARD: begin
                    if (tx_counter == 16'd0) begin
                        tx_state  <= TX_IDLE;
                        tx_active <= 1'b0;
                    end else begin
                        tx_counter <= tx_counter - 16'd1;
                    end
                end

                default: tx_state <= TX_IDLE;
            endcase
        end
    end

    // =========================================================================
    // RX State Machine
    // =========================================================================
    typedef enum logic [2:0] {
        RX_IDLE,
        RX_START,
        RX_DATA,
        RX_STOP
    } rx_state_t;

    rx_state_t   rx_state;
    logic [7:0]  rx_shift;
    logic [2:0]  rx_bit_idx;
    logic [15:0] rx_counter;
    logic [7:0]  rx_data_reg;
    logic        rx_valid;
    logic        rx_read_ack;

    // 2-stage synchronizer
    logic rx_meta, rx_sync;
    always_ff @(posedge clk) begin
        if (rst) begin
            rx_meta <= 1'b1;
            rx_sync <= 1'b1;
        end else begin
            rx_meta <= rx_in;
            rx_sync <= rx_meta;
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            rx_state     <= RX_IDLE;
            rx_shift     <= 8'h00;
            rx_bit_idx   <= 3'd0;
            rx_counter   <= 16'd0;
            rx_data_reg  <= 8'h00;
            rx_valid     <= 1'b0;
            m_esc_tdata  <= 8'h00;
            m_esc_tvalid <= 1'b0;
        end else begin
            if (rx_read_ack)
                rx_valid <= 1'b0;

            // Stream RX handshake clear
            if (m_esc_tvalid && m_esc_tready)
                m_esc_tvalid <= 1'b0;

            if (tx_active) begin
                rx_state <= RX_IDLE;
            end else begin
                case (rx_state)
                    RX_IDLE: begin
                        if (rx_sync == 1'b0) begin
                            rx_state   <= RX_START;
                            rx_counter <= half_bit - 16'd1;
                        end
                    end

                    RX_START: begin
                        if (rx_counter == 16'd0) begin
                            if (rx_sync == 1'b0) begin
                                rx_state   <= RX_DATA;
                                rx_counter <= clks_per_bit - 16'd1;
                                rx_bit_idx <= 3'd0;
                            end else begin
                                rx_state <= RX_IDLE;
                            end
                        end else begin
                            rx_counter <= rx_counter - 16'd1;
                        end
                    end

                    RX_DATA: begin
                        if (rx_counter == 16'd0) begin
                            rx_shift <= {rx_sync, rx_shift[7:1]};
                            if (rx_bit_idx == 3'd7) begin
                                rx_state   <= RX_STOP;
                                rx_counter <= clks_per_bit - 16'd1;
                            end else begin
                                rx_bit_idx <= rx_bit_idx + 3'd1;
                                rx_counter <= clks_per_bit - 16'd1;
                            end
                        end else begin
                            rx_counter <= rx_counter - 16'd1;
                        end
                    end

                    RX_STOP: begin
                        if (rx_counter == 16'd0) begin
                            if (rx_sync == 1'b1) begin
                                rx_data_reg  <= rx_shift;
                                rx_valid     <= 1'b1;
                                m_esc_tdata  <= rx_shift;
                                m_esc_tvalid <= 1'b1;
                            end
                            rx_state <= RX_IDLE;
                        end else begin
                            rx_counter <= rx_counter - 16'd1;
                        end
                    end

                    default: rx_state <= RX_IDLE;
                endcase
            end
        end
    end

    // =========================================================================
    // Wishbone Interface
    // =========================================================================
    logic wb_access;
    assign wb_access = wb_stb_i && wb_cyc_i;

    // Single-cycle ack
    always_ff @(posedge clk) begin
        if (rst)
            wb_ack_o <= 1'b0;
        else
            wb_ack_o <= wb_access && !wb_ack_o;
    end

    // Write handling
    always_ff @(posedge clk) begin
        if (rst) begin
            tx_data_reg   <= 8'h00;
            tx_data_valid <= 1'b0;
            baud_div      <= DEFAULT_CLKDIV[15:0];
        end else begin
            if (tx_data_consumed)
                tx_data_valid <= 1'b0;

            if (wb_access && wb_we_i && !wb_ack_o) begin
                case (wb_adr_i[3:2])
                    2'b00: begin // TX_DATA (0x00)
                        if (tx_ready) begin
                            tx_data_reg   <= wb_dat_i[7:0];
                            tx_data_valid <= 1'b1;
                        end
                    end
                    2'b11: begin // BAUD_DIV (0x0C)
                        baud_div <= wb_dat_i[15:0];
                    end
                    default: ;
                endcase
            end
        end
    end

    // Read handling
    always_comb begin
        wb_dat_o = 32'h0;
        case (wb_adr_i[3:2])
            2'b00: wb_dat_o = {24'h0, tx_data_reg};
            2'b01: wb_dat_o = {29'h0, tx_active, rx_valid, tx_ready};
            2'b10: wb_dat_o = {24'h0, rx_data_reg};
            2'b11: wb_dat_o = {16'h0, baud_div};
            default: ;
        endcase
    end

    // RX read ack
    always_ff @(posedge clk) begin
        if (rst)
            rx_read_ack <= 1'b0;
        else
            rx_read_ack <= wb_access && !wb_we_i && wb_ack_o && (wb_adr_i[3:2] == 2'b10);
    end

    // Suppress unused-signal lint
    logic _unused;
    always_comb _unused = &{wb_adr_i[1:0], wb_dat_i[31:16]};

endmodule

`default_nettype wire
