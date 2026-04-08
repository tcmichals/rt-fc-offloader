/**
 * Wishbone ESC UART Controller
 * 
 * Half-duplex UART for BLHeli ESC configuration.
 * Includes Hardware Stream Interface for high-speed FCSP passthrough (Channel 0x05).
 * 
 * Register Map:
 *   0x00: TX_DATA  [W]
 *   0x04: STATUS   [R] - [2]=tx_active, [1]=rx_valid, [0]=tx_ready
 *   0x08: RX_DATA  [R]
 *   0x0C: BAUD_DIV [RW] - Clocks per bit
 */

module wb_esc_uart #(
    parameter CLK_FREQ_HZ = 54_000_000
) (
    input  logic        clk,
    input  logic        rst,
    
    // Wishbone slave interface
    input  logic [3:0]  wb_adr_i,
    input  logic [31:0] wb_dat_i,
    output logic [31:0] wb_dat_o,
    input  logic        wb_we_i,
    input  logic        wb_stb_i,
    input  logic        wb_cyc_i,
    output logic        wb_ack_o,
    
    // Half-duplex serial interface
    output logic        tx_out,
    input  logic        rx_in,
    output logic        tx_active,

    // Hardware Stream Interface (Direct bypass for high-volume data)
    input  logic [7:0]  s_esc_tdata,
    input  logic        s_esc_tvalid,
    output logic        s_esc_tready,
    
    output logic [7:0]  m_esc_tdata,
    output logic        m_esc_tvalid,
    input  logic        m_esc_tready
);

    // Baud Rate configuration
    logic [31:0] clks_per_bit;
    always_ff @(posedge clk) begin
        if (rst) clks_per_bit <= CLK_FREQ_HZ / 19200;
        else if (wb_stb_i && wb_cyc_i && wb_we_i && !wb_ack_o && (wb_adr_i[3:2] == 2'b11))
            clks_per_bit <= wb_dat_i;
    end

    wire [31:0] half_bit   = clks_per_bit >> 1;
    wire [31:0] guard_clks = clks_per_bit;

    // --- TX FSM ---
    typedef enum logic [2:0] { TX_IDLE, TX_START, TX_DATA, TX_STOP, TX_GUARD } tx_state_t;
    tx_state_t tx_state;
    logic [7:0] tx_shift;
    logic [2:0] tx_bit_idx;
    logic [31:0] tx_counter;
    logic [7:0] tx_data_reg;
    logic       tx_data_valid, tx_data_consumed;

    assign s_esc_tready = (tx_state == TX_IDLE) && !tx_data_valid;

    always_ff @(posedge clk) begin
        if (rst) begin
            tx_state <= TX_IDLE; tx_out <= 1'b1; tx_active <= 1'b0; tx_data_consumed <= 1'b0;
            tx_counter <= 0; tx_shift <= 0; tx_bit_idx <= 0;
        end else begin
            tx_data_consumed <= 1'b0;
            case (tx_state)
                TX_IDLE: begin
                    tx_out <= 1'b1; tx_active <= 1'b0;
                    if (tx_data_valid || s_esc_tvalid) begin
                        tx_shift <= tx_data_valid ? tx_data_reg : s_esc_tdata;
                        tx_state <= TX_START; tx_counter <= clks_per_bit - 1;
                        tx_out <= 1'b0; tx_active <= 1'b1; tx_data_consumed <= tx_data_valid;
                    end
                end
                TX_START: begin
                    if (tx_counter == 0) begin tx_state <= TX_DATA; tx_counter <= clks_per_bit - 1; tx_out <= tx_shift[0]; tx_bit_idx <= 0; end
                    else tx_counter <= tx_counter - 1;
                end
                TX_DATA: begin
                    if (tx_counter == 0) begin
                        if (tx_bit_idx == 7) begin tx_state <= TX_STOP; tx_counter <= clks_per_bit - 1; tx_out <= 1'b1; end
                        else begin tx_bit_idx <= tx_bit_idx + 1; tx_counter <= clks_per_bit - 1; tx_out <= tx_shift[tx_bit_idx+1]; end
                    end else tx_counter <= tx_counter - 1;
                end
                TX_STOP: begin
                    if (tx_counter == 0) begin tx_state <= TX_GUARD; tx_counter <= guard_clks - 1; end
                    else tx_counter <= tx_counter - 1;
                end
                TX_GUARD: begin
                    if (tx_counter == 0) begin tx_state <= TX_IDLE; tx_active <= 1'b0; end
                    else tx_counter <= tx_counter - 1;
                end
                default: tx_state <= TX_IDLE;
            endcase
        end
    end

    // --- RX FSM ---
    typedef enum logic [2:0] { RX_IDLE, RX_START, RX_DATA, RX_STOP } rx_state_t;
    rx_state_t rx_state;
    logic [7:0] rx_shift, rx_data_reg;
    logic [2:0] rx_bit_idx;
    logic [31:0] rx_counter;
    logic rx_valid, rx_sync, rx_meta;

    always_ff @(posedge clk) begin rx_meta <= rx_in; rx_sync <= rx_meta; end

    always_ff @(posedge clk) begin
        if (rst) begin
            rx_state <= RX_IDLE; rx_valid <= 1'b0; m_esc_tvalid <= 1'b0;
            rx_counter <= 0; rx_shift <= 0; rx_bit_idx <= 0; rx_data_reg <= 0; m_esc_tdata <= 0;
        end else begin
            // Handshakes
            if (wb_ack_o && !wb_we_i && (wb_adr_i[3:2] == 2'b10)) rx_valid <= 1'b0;
            if (m_esc_tready) m_esc_tvalid <= 1'b0;
            
            if (!tx_active) begin
                case (rx_state)
                    RX_IDLE: if (!rx_sync) begin rx_state <= RX_START; rx_counter <= half_bit - 1; end
                    RX_START: begin
                        if (rx_counter == 0) begin
                            if (!rx_sync) begin rx_state <= RX_DATA; rx_counter <= clks_per_bit - 1; rx_bit_idx <= 0; end
                            else rx_state <= RX_IDLE;
                        end else rx_counter <= rx_counter - 1;
                    end
                    RX_DATA: begin
                        if (rx_counter == 0) begin
                            rx_shift[rx_bit_idx] <= rx_sync;
                            if (rx_bit_idx == 7) begin rx_state <= RX_STOP; rx_counter <= clks_per_bit - 1; end
                            else begin rx_bit_idx <= rx_bit_idx + 1; rx_counter <= clks_per_bit - 1; end
                        end else rx_counter <= rx_counter - 1;
                    end
                    RX_STOP: begin
                        if (rx_counter == 0) begin
                            if (rx_sync) begin rx_data_reg <= rx_shift; rx_valid <= 1'b1; m_esc_tdata <= rx_shift; m_esc_tvalid <= 1'b1; end
                            rx_state <= RX_IDLE;
                        end else rx_counter <= rx_counter - 1;
                    end
                    default: rx_state <= RX_IDLE;
                endcase
            end
        end
    end

    // --- Wishbone ---
    always_ff @(posedge clk) begin
        if (rst) begin
            wb_ack_o <= 1'b0;
            tx_data_reg <= 0;
            tx_data_valid <= 0;
        end else begin
            wb_ack_o <= (wb_stb_i && wb_cyc_i) && !wb_ack_o;
            
            if (tx_data_consumed) tx_data_valid <= 0;
            
            if (wb_stb_i && wb_cyc_i && wb_we_i && !wb_ack_o) begin
                if (wb_adr_i[3:2] == 2'b00) begin
                    tx_data_reg <= wb_dat_i[7:0]; tx_data_valid <= 1'b1;
                end
            end
        end
    end
    
    assign wb_dat_o = (wb_adr_i[3:2] == 2'b00) ? {24'h0, tx_data_reg} :
                      (wb_adr_i[3:2] == 2'b01) ? {29'h0, tx_active, rx_valid, (tx_state == TX_IDLE)} :
                      (wb_adr_i[3:2] == 2'b10) ? {24'h0, rx_data_reg} :
                      (wb_adr_i[3:2] == 2'b11) ? clks_per_bit : 32'h0;

endmodule
