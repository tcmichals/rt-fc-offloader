// Wishbone USB UART with RX and TX (for MSP communication)
`default_nettype none

module wb_usb_uart #(
    parameter CLK_FREQ = 54_000_000,
    parameter BAUD     = 115200
)(
    input  wire        clk,
    input  wire        rst,
    
    // Wishbone slave interface
    input  wire [31:0] wb_adr_i,
    input  wire [31:0] wb_dat_i,
    output reg  [31:0] wb_dat_o,
    input  wire        wb_we_i,
    input  wire        wb_stb_i,
    output reg         wb_ack_o,
    
    // UART pins
    input  wire        uart_rx,
    output wire        uart_tx
);

    // Register offsets (relative addressing)
    localparam REG_TX_DATA   = 4'h0;   // Write: TX byte, Read: RX byte
    localparam REG_STATUS    = 4'h4;   // Read: bit0 = TX ready, bit1 = RX valid
    localparam REG_RX_DATA   = 4'h8;   // Read: RX byte (same as offset 0 read)

    // Prescale value for verilog-uart: CLK_FREQ / (BAUD * 8)
    localparam [15:0] PRESCALE = CLK_FREQ / (BAUD * 8);

    // TX interface
    reg  [7:0] tx_data;
    reg        tx_valid;
    wire       tx_ready;
    wire       tx_busy;

    // RX interface
    wire [7:0] rx_data;
    wire       rx_valid;

    // 2-stage synchronizer for RX input (async input from external pin)
    reg [1:0] uart_rx_sync;
    wire      uart_rx_synced;
    
    always @(posedge clk) begin
        if (rst)
            uart_rx_sync <= 2'b11;  // Idle high
        else
            uart_rx_sync <= {uart_rx_sync[0], uart_rx};
    end
    assign uart_rx_synced = uart_rx_sync[1];

    // 4-byte RX FIFO
    localparam FIFO_DEPTH = 4;
    localparam FIFO_ADDR_BITS = 2;
    
    reg [7:0]  fifo_mem [0:FIFO_DEPTH-1];
    reg [FIFO_ADDR_BITS:0] fifo_wr_ptr;  // Extra bit for full/empty detection
    reg [FIFO_ADDR_BITS:0] fifo_rd_ptr;
    
    wire fifo_empty = (fifo_wr_ptr == fifo_rd_ptr);
    wire fifo_full  = (fifo_wr_ptr[FIFO_ADDR_BITS] != fifo_rd_ptr[FIFO_ADDR_BITS]) &&
                      (fifo_wr_ptr[FIFO_ADDR_BITS-1:0] == fifo_rd_ptr[FIFO_ADDR_BITS-1:0]);
    wire [7:0] fifo_rd_data = fifo_mem[fifo_rd_ptr[FIFO_ADDR_BITS-1:0]];
    
    reg rx_read;  // Pulse to pop from FIFO
    
    // Frame/overrun errors for debugging
    wire rx_frame_error;
    wire rx_overrun_error;

    // Instantiate uart_tx from verilog-uart library
    uart_tx #(
        .DATA_WIDTH(8)
    ) u_uart_tx (
        .clk(clk),
        .rst(rst),
        .s_axis_tdata(tx_data),
        .s_axis_tvalid(tx_valid),
        .s_axis_tready(tx_ready),
        .txd(uart_tx),
        .busy(tx_busy),
        .prescale(PRESCALE)
    );

    // Instantiate uart_rx from verilog-uart library
    uart_rx #(
        .DATA_WIDTH(8)
    ) u_uart_rx (
        .clk(clk),
        .rst(rst),
        .m_axis_tdata(rx_data),
        .m_axis_tvalid(rx_valid),
        .m_axis_tready(1'b1),  // Always ready - we buffer in FIFO
        .rxd(uart_rx_synced),  // Use synchronized input
        .busy(),
        .overrun_error(rx_overrun_error),
        .frame_error(rx_frame_error),
        .prescale(PRESCALE)
    );

    // FIFO write logic
    always @(posedge clk) begin
        if (rst) begin
            fifo_wr_ptr <= 0;
        end else begin
            // Push to FIFO when RX valid and not full
            if (rx_valid && !fifo_full) begin
                fifo_mem[fifo_wr_ptr[FIFO_ADDR_BITS-1:0]] <= rx_data;
                fifo_wr_ptr <= fifo_wr_ptr + 1;
            end
        end
    end

    // FIFO read logic
    always @(posedge clk) begin
        if (rst) begin
            fifo_rd_ptr <= 0;
        end else begin
            // Pop from FIFO on read
            if (rx_read && !fifo_empty) begin
                fifo_rd_ptr <= fifo_rd_ptr + 1;
            end
        end
    end

    // TX ready for software: uart_tx ready and not busy
    wire tx_can_write = tx_ready && !tx_busy;

    // ACK pipeline to match mux's registered data path
    reg wb_ack_pending;

    // Wishbone logic
    always @(posedge clk) begin
        if (rst) begin
            wb_ack_o <= 1'b0;
            wb_ack_pending <= 1'b0;
            wb_dat_o <= 32'b0;
            tx_data  <= 8'b0;
            tx_valid <= 1'b0;
            rx_read  <= 1'b0;
        end else begin
            // Always clear tx_valid after one cycle - uart_tx will have sampled it
            tx_valid <= 1'b0;
            
            // Clear rx_read pulse
            rx_read <= 1'b0;
            
            // 2-cycle ACK: pending -> ack (matches mux data registration)
            wb_ack_o <= wb_ack_pending;
            wb_ack_pending <= 1'b0;

            // Wishbone transaction
            if (wb_stb_i && !wb_ack_pending && !wb_ack_o) begin
                wb_ack_pending <= 1'b1;  // Will become wb_ack_o next cycle
                
                if (wb_we_i) begin
                    // Write
                    case (wb_adr_i[3:0])
                        REG_TX_DATA: begin
                            if (tx_can_write) begin
                                tx_data  <= wb_dat_i[7:0];
                                tx_valid <= 1'b1;
                            end
                        end
                        default: ;
                    endcase
                end else begin
                    // Read - data is registered, will be valid when ACK arrives
                    case (wb_adr_i[3:0])
                        REG_TX_DATA, REG_RX_DATA: begin
                            wb_dat_o <= {24'b0, fifo_rd_data};
                            rx_read  <= !fifo_empty;  // Pop from FIFO
                        end
                        REG_STATUS: begin
                            // bit0=TX_READY, bit1=RX_VALID (FIFO not empty), bit2=frame_err, bit3=overrun_err
                            wb_dat_o <= {28'b0, rx_overrun_error, rx_frame_error, !fifo_empty, tx_can_write};
                        end
                        default: wb_dat_o <= 32'b0;
                    endcase
                end
            end
        end
    end

endmodule

`default_nettype wire
