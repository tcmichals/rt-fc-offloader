`default_nettype wire

module spi_slave #(
    parameter DATA_WIDTH = 8
)(
    input  wire                   i_clk,
    input  wire                   i_rst,
    
    // SPI Physical Interface
    input  wire                   i_sclk,
    input  wire                   i_cs_n,
    input  wire                   i_mosi,
    output wire                   o_miso,
    
    // User / System Interface
    input  wire [DATA_WIDTH-1:0]  i_tx_data,  // Data to send
    input  wire                   i_tx_valid, // Pulse high to load data
    output wire                   o_tx_ready, // High = Safe to load new data
    output wire                   o_busy,     // High = SPI transaction in progress
    
    output wire [DATA_WIDTH-1:0]  o_rx_data,  // Received data
    output wire                   o_data_valid, // High = New rx_data available
    output wire                   o_cs_n_sync   // Synchronized CS_n output
);

    // --- 1. Synchronization & Edge Detection ---
    // 4 stages for metastability + glitch filtering at any speed
    logic [3:0] sclk_sync;   // 4 stages for SCLK
    logic [3:0] cs_n_sync;   // 4 stages for CS_n
    logic [2:0] mosi_sync;   // 3 stages for MOSI

    always_ff @(posedge i_clk or posedge i_rst) begin
        if (i_rst) begin
            sclk_sync <= 4'b0000;
            cs_n_sync <= 4'b1111;
            mosi_sync <= 3'b000;
        end else begin
            sclk_sync <= {sclk_sync[2:0], i_sclk};
            cs_n_sync <= {cs_n_sync[2:0], i_cs_n};
            mosi_sync <= {mosi_sync[1:0], i_mosi};
        end
    end

    // Glitch-filtered edge detection: require 2 consecutive 0s before, 2 consecutive 1s after (or vice versa)
    // This filters out noise spikes shorter than 2 clock cycles
    wire sclk_rising  = (sclk_sync[3:0] == 4'b0011);  // Was low for 2 clks, now high for 2 clks
    wire sclk_falling = (sclk_sync[3:0] == 4'b1100);  // Was high for 2 clks, now low for 2 clks
    wire cs_active    = ~cs_n_sync[3]; // Use deepest stage for CS
    
    // Output the Busy status immediately based on synchronized CS
    assign o_busy = cs_active;
    assign o_cs_n_sync = cs_n_sync[3];

    // --- 2. Data Path & Logic ---
    logic [$clog2(DATA_WIDTH)-1:0] bit_cnt;
    logic [DATA_WIDTH-1:0] rx_shift_reg;
    logic [DATA_WIDTH-1:0] tx_shift_reg;
    logic [DATA_WIDTH-1:0] tx_holding_reg; 

    always_ff @(posedge i_clk or posedge i_rst) begin
        if (i_rst) begin
            bit_cnt        <= 3'd7;
            o_rx_data      <= '0;
            o_data_valid   <= 1'b0;
            rx_shift_reg   <= '0;
            tx_shift_reg   <= '0;
            tx_holding_reg <= '0;
            o_tx_ready     <= 1'b1;
        end else begin
            o_data_valid <= 1'b0;

            // --- A. User Interface Logic (Safe Loading) ---
            if (i_tx_valid && o_tx_ready) begin
                tx_holding_reg <= i_tx_data;
                o_tx_ready     <= 1'b0; // Lock buffer until SPI takes it
            end

            // --- B. SPI Transaction Logic ---
            if (!cs_active) begin
                // IDLE STATE
                bit_cnt <= 3'd7; 
                
                // If the user loaded data, move it to the shifter immediately
                if (o_tx_ready == 1'b0) begin
                    tx_shift_reg <= tx_holding_reg;
                    o_tx_ready   <= 1'b1; // Unlock buffer
                end
            end 
            else begin
                // ACTIVE STATE (Busy)
                
                // Sample MOSI (Rising Edge) - use deepest sync stage
                if (sclk_rising) begin
                    rx_shift_reg <= {rx_shift_reg[DATA_WIDTH-2:0], mosi_sync[2]};
                    if (bit_cnt == 0) begin
                        o_rx_data    <= {rx_shift_reg[DATA_WIDTH-2:0], mosi_sync[2]};
                        o_data_valid <= 1'b1;
`ifdef VERBOSE
                        $display("[spi_slave %0t] RX byte complete: 0x%02x cs=%0d", $time, 
                            {rx_shift_reg[DATA_WIDTH-2:0], mosi_sync[2]}, cs_active);
`endif
                    end
                end

                // Shift MISO (Falling Edge)
                if (sclk_falling) begin
                    if (bit_cnt > 0) begin
                        bit_cnt      <= bit_cnt - 1;
                        tx_shift_reg <= {tx_shift_reg[DATA_WIDTH-2:0], 1'b0};
                    end else begin
                        // Byte complete. Prepare for next byte in stream (if any).
                        bit_cnt <= 3'd7;
                        
                        // Check if user provided new data in holding register
                        if (o_tx_ready == 1'b0) begin
                            tx_shift_reg <= tx_holding_reg;
                            o_tx_ready   <= 1'b1; // Unlock buffer - ready for next TX
`ifdef VERBOSE
                            $display("[spi_slave %0t] Loaded tx_shift_reg from holding: 0x%02x", $time, tx_holding_reg);
`endif
                        end else begin
                            tx_shift_reg <= '0; // Underflow: Send Zeros
`ifdef VERBOSE
                            $display("[spi_slave %0t] tx_shift_reg underflow -> sending 0x00", $time);
`endif
                        end
                    end
                end
            end
        end
    end

    // Tri-state MISO (direct from shift register)
    assign o_miso = (cs_active) ? tx_shift_reg[DATA_WIDTH-1] : 1'bZ;

endmodule // SPI_Slave