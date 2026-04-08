/**
 * SPI Slave to Wishbone Bridge
 * 
 * Protocol (all multi-byte values little-endian):
 *   Frame:    [cmd] [len 2B] [addr 4B] [data/pad N] [DA]
 *   Response: [DA]  [resp]   [len echo] [addr echo] [data/ack]
 * 
 * Commands:
 *   0xA1 = Read request  → 0x81 response
 *   0xA2 = Write request → 0x82 response
 *   0xDA = Sync/Ready/Terminate
 *   0x55 = Pad byte (read requests)
 *   0xEE = Write acknowledge
 *   0xF5 = Invalid command error
 * 
 * Response is shifted by 1 byte (SPI full-duplex).
 * Length must be multiple of 4 (32-bit aligned).
 */

`default_nettype none

module spi_slave_wb_bridge #(
    parameter WB_ADDR_WIDTH = 32,
    parameter WB_DATA_WIDTH = 32,
    parameter WB_SEL_WIDTH = WB_DATA_WIDTH / 8
) (
    input  wire                      clk,
    input  wire                      rst,
    
    // SPI Slave Interface (directly from SPI slave module)
    input  wire                      spi_rx_valid,
    input  wire [7:0]                spi_rx_data,
    output wire                      spi_tx_valid,
    output wire [7:0]                spi_tx_data,
    input  wire                      spi_tx_ready,
    input  wire                      spi_cs_n,       // Active low chip select
    
    // Wishbone Master Interface
    output reg  [WB_ADDR_WIDTH-1:0]  wb_adr_o,
    output reg  [WB_DATA_WIDTH-1:0]  wb_dat_o,
    input  wire [WB_DATA_WIDTH-1:0]  wb_dat_i,
    output reg                       wb_we_o,
    output reg  [WB_SEL_WIDTH-1:0]   wb_sel_o,
    output reg                       wb_stb_o,
    input  wire                      wb_ack_i,
    input  wire                      wb_err_i,
    output reg                       wb_cyc_o,
    
    // Status
    output wire                      busy
);

    // Protocol bytes
    localparam SYNC_BYTE    = 8'hDA;  // Frame sync/ready/terminate
    localparam CMD_READ     = 8'hA1;  // Read request
    localparam CMD_WRITE    = 8'hA2;  // Write request
    localparam RESP_READ    = 8'h21;  // Read response (CMD_READ ^ 0x80)
    localparam RESP_WRITE   = 8'h22;  // Write response (CMD_WRITE ^ 0x80)
    localparam PAD_BYTE     = 8'h55;  // Pad byte
    localparam WRITE_ACK    = 8'hEE;  // Write acknowledge
    
    // State machine
    localparam ST_IDLE      = 4'd0;   // Wait for cmd, TX=DA
    localparam ST_LEN0      = 4'd1;   // Receive len[0], TX=resp
    localparam ST_LEN1      = 4'd2;   // Receive len[1], TX=len[0]
    localparam ST_ADDR0     = 4'd3;   // Receive addr[0], TX=len[1]
    localparam ST_ADDR1     = 4'd4;   // Receive addr[1], TX=addr[0]
    localparam ST_ADDR2     = 4'd5;   // Receive addr[2], TX=addr[1]
    localparam ST_ADDR3     = 4'd6;   // Receive addr[3], TX=addr[2]
    localparam ST_DATA      = 4'd7;   // Receive/send data, TX=addr[3] then data/ack
    localparam ST_WB_READ   = 4'd8;   // Wishbone read in progress
    localparam ST_WB_WRITE  = 4'd9;   // Wishbone write in progress
    localparam ST_TERM      = 4'd10;  // Receive DA terminator
    
    reg [3:0]  state;
    reg [7:0]  cmd;
    reg [31:0] addr;
    reg [15:0] len;
    reg [15:0] remaining;
    reg [31:0] data_word;      // Current word being assembled or sent
    reg [1:0]  word_byte_cnt;  // Byte position within 32-bit word (0-3)
    reg [31:0] read_data;      // Data read from Wishbone
    reg [31:0] timeout_cnt;
    reg        wb_error;       // Wishbone error flag
    reg        first_data_byte; // Flag for first data byte (TX=addr[3])
    
    // TX holding register for reliable handshake
    reg [7:0]  tx_hold_data;   // Data waiting to be sent
    reg        tx_hold_valid;  // Data is waiting in hold register
    
    assign busy = (state != ST_IDLE);
    
    // SPI CS rising edge detection (end of transaction)
    reg spi_cs_n_d;
    wire spi_cs_rise = spi_cs_n && !spi_cs_n_d;
    
    always @(posedge clk) begin
        spi_cs_n_d <= spi_cs_n;
    end
    
    // TX handshake: hold valid until slave accepts (ready && valid)
    wire tx_accepted = spi_tx_valid && spi_tx_ready;
    
    // Drive SPI TX from holding register
    assign spi_tx_data = tx_hold_data;
    assign spi_tx_valid = tx_hold_valid;
    
    // Helper task-like logic: load TX hold register
    // Called from state machine when new data should be sent
    
    // Main state machine
    always @(posedge clk) begin
        if (rst || spi_cs_rise) begin
            state <= ST_IDLE;
            cmd <= 8'h00;
            addr <= 32'h0;
            len <= 16'h0;
            remaining <= 16'h0;
            data_word <= 32'h0;
            word_byte_cnt <= 2'd0;
            read_data <= 32'h0;
            timeout_cnt <= 32'h0;
            wb_error <= 1'b0;
            first_data_byte <= 1'b0;
            // Pre-load DA for next transaction
            tx_hold_data <= SYNC_BYTE;
            tx_hold_valid <= 1'b1;
            // Deassert Wishbone
            wb_stb_o <= 1'b0;
            wb_cyc_o <= 1'b0;
            wb_we_o <= 1'b0;
            wb_sel_o <= {WB_SEL_WIDTH{1'b1}};
            wb_adr_o <= {WB_ADDR_WIDTH{1'b0}};
            wb_dat_o <= {WB_DATA_WIDTH{1'b0}};
        end else begin
            // Clear hold valid when slave accepts data
            if (tx_accepted) begin
                tx_hold_valid <= 1'b0;
            end
            
            case (state)
                // ============================================================
                // IDLE: Pre-loaded DA. Wait for command byte.
                // ============================================================
                ST_IDLE: begin
                    if (spi_rx_valid) begin
                        cmd <= spi_rx_data;
                        if (spi_rx_data == CMD_READ) begin
                            // Valid read command - pre-load response 0x21
                            tx_hold_data <= RESP_READ;
                            tx_hold_valid <= 1'b1;
                            state <= ST_LEN0;
                        end else if (spi_rx_data == CMD_WRITE) begin
                            // Valid write command - pre-load response 0x22
                            tx_hold_data <= RESP_WRITE;
                            tx_hold_valid <= 1'b1;
                            state <= ST_LEN0;
                        end else begin
                            // Invalid command - stay in IDLE, keep DA loaded
                            tx_hold_data <= SYNC_BYTE;
                            tx_hold_valid <= 1'b1;
                            // Stay in ST_IDLE
                        end
                    end
                end
                
                // ============================================================
                // LEN0: Receive len[0], pre-load for echo
                // ============================================================
                ST_LEN0: begin
                    if (spi_rx_valid) begin
                        len[7:0] <= spi_rx_data;
                        // Pre-load len[0] for echo
                        tx_hold_valid <= 1'b1;
                        tx_hold_data <= spi_rx_data;
                        state <= ST_LEN1;
                    end
                end
                
                // ============================================================
                // LEN1: Receive len[1], pre-load for echo
                // ============================================================
                ST_LEN1: begin
                    if (spi_rx_valid) begin
                        len[15:8] <= spi_rx_data;
                        remaining <= {spi_rx_data, len[7:0]};
                        // Pre-load len[1] for echo
                        tx_hold_valid <= 1'b1;
                        tx_hold_data <= spi_rx_data;
                        state <= ST_ADDR0;
                    end
                end
                
                // ============================================================
                // ADDR0-3: Receive address bytes, pre-load for echo
                // ============================================================
                ST_ADDR0: begin
                    if (spi_rx_valid) begin
                        addr[7:0] <= spi_rx_data;
                        tx_hold_valid <= 1'b1;
                        tx_hold_data <= spi_rx_data;
                        state <= ST_ADDR1;
                    end
                end
                
                ST_ADDR1: begin
                    if (spi_rx_valid) begin
                        addr[15:8] <= spi_rx_data;
                        tx_hold_valid <= 1'b1;
                        tx_hold_data <= spi_rx_data;
                        state <= ST_ADDR2;
                    end
                end
                
                ST_ADDR2: begin
                    if (spi_rx_valid) begin
                        addr[23:16] <= spi_rx_data;
                        tx_hold_valid <= 1'b1;
                        tx_hold_data <= spi_rx_data;
                        state <= ST_ADDR3;
                    end
                end
                
                ST_ADDR3: begin
                    if (spi_rx_valid) begin
                        addr[31:24] <= spi_rx_data;
                        // Pre-load addr[3] for echo (will be sent during first data byte)
                        tx_hold_valid <= 1'b1;
                        tx_hold_data <= spi_rx_data;
                        
                        // For reads: start WB read now
                        if (cmd == CMD_READ) begin
                            wb_adr_o <= {spi_rx_data, addr[23:0]};
                            wb_stb_o <= 1'b1;
                            wb_cyc_o <= 1'b1;
                            wb_we_o <= 1'b0;
                            wb_sel_o <= 4'b1111;
                            timeout_cnt <= 32'd1000;
                            state <= ST_WB_READ;
                        end else begin
                            // Write: go to receive data
                            word_byte_cnt <= 2'd0;
                            data_word <= 32'h0;
                            first_data_byte <= 1'b1;
                            state <= ST_DATA;
                        end
                    end
                end
                
                // ============================================================
                // WB_READ: Wait for Wishbone read to complete
                // ============================================================
                ST_WB_READ: begin
                    timeout_cnt <= timeout_cnt - 1;
                    
                    if (wb_ack_i) begin
                        wb_stb_o <= 1'b0;
                        wb_cyc_o <= 1'b0;
                        read_data <= wb_dat_i;
                        word_byte_cnt <= 2'd0;
                        first_data_byte <= 1'b1;
                        state <= ST_DATA;
                    end else if (wb_err_i || timeout_cnt == 0) begin
                        wb_stb_o <= 1'b0;
                        wb_cyc_o <= 1'b0;
                        wb_error <= 1'b1;
                        read_data <= 32'hDEADDEAD;  // Error pattern
                        word_byte_cnt <= 2'd0;
                        first_data_byte <= 1'b1;
                        state <= ST_DATA;
                    end
                end
                
                // ============================================================
                // ST_DATA: Send/receive data bytes
                // For reads: send read_data, receive pad (0x55)
                // For writes: receive data, send 0xEE ack
                // ============================================================
                ST_DATA: begin
                    if (spi_rx_valid) begin
                        // Check for terminator
                        if (spi_rx_data == SYNC_BYTE && remaining == 0) begin
                            // Transaction complete - pre-load DA for next
                            tx_hold_valid <= 1'b1;
                            tx_hold_data <= SYNC_BYTE;
                            state <= ST_IDLE;
                        end else if (remaining > 0) begin
                            remaining <= remaining - 1;
                            
                            if (cmd == CMD_READ) begin
                                // READ: send data byte, receive pad
                                if (first_data_byte) begin
                                    // First byte: TX already has addr[3], now pre-load data[0]
                                    tx_hold_valid <= 1'b1;
                                    tx_hold_data <= read_data[7:0];
                                    first_data_byte <= 1'b0;
                                    word_byte_cnt <= 2'd1;
                                end else begin
                                    // Subsequent bytes
                                    case (word_byte_cnt)
                                        2'd1: begin
                                            tx_hold_valid <= 1'b1;
                                            tx_hold_data <= read_data[15:8];
                                            word_byte_cnt <= 2'd2;
                                        end
                                        2'd2: begin
                                            tx_hold_valid <= 1'b1;
                                            tx_hold_data <= read_data[23:16];
                                            word_byte_cnt <= 2'd3;
                                        end
                                        2'd3: begin
                                            // Last byte of word - preload data[3]
                                            tx_hold_valid <= 1'b1;
                                            tx_hold_data <= read_data[31:24];
                                            // Check if more complete words remain
                                            // remaining is current value, will be decremented to remaining-1
                                            // We need 4+ more bytes after this one for another word
                                            if (remaining > 4) begin
                                                // More words to read - start next WB read
                                                addr <= addr + 4;
                                                wb_adr_o <= addr + 4;
                                                wb_stb_o <= 1'b1;
                                                wb_cyc_o <= 1'b1;
                                                timeout_cnt <= 32'd1000;
                                                state <= ST_WB_READ;
                                            end else begin
                                                // Last byte of last word
                                                word_byte_cnt <= 2'd0;
                                            end
                                        end
                                        default: begin
                                            tx_hold_valid <= 1'b1;
                                            tx_hold_data <= read_data[7:0];
                                            word_byte_cnt <= 2'd1;
                                        end
                                    endcase
                                end
                            end else begin
                                // WRITE: receive data byte, send 0xEE ack
                                case (word_byte_cnt)
                                    2'd0: data_word[7:0]   <= spi_rx_data;
                                    2'd1: data_word[15:8]  <= spi_rx_data;
                                    2'd2: data_word[23:16] <= spi_rx_data;
                                    2'd3: data_word[31:24] <= spi_rx_data;
                                endcase
                                
                                // Pre-load 0xEE ack (or addr[3] echo for first byte)
                                if (first_data_byte) begin
                                    // TX already has addr[3], now pre-load EE
                                    tx_hold_valid <= 1'b1;
                                    tx_hold_data <= WRITE_ACK;
                                    first_data_byte <= 1'b0;
                                end else begin
                                    tx_hold_valid <= 1'b1;
                                    tx_hold_data <= WRITE_ACK;
                                end
                                
                                if (word_byte_cnt == 2'd3) begin
                                    // Word complete - do WB write
                                    wb_dat_o <= {spi_rx_data, data_word[23:0]};
                                    wb_adr_o <= addr;
                                    wb_stb_o <= 1'b1;
                                    wb_cyc_o <= 1'b1;
                                    wb_we_o <= 1'b1;
                                    wb_sel_o <= 4'b1111;
                                    timeout_cnt <= 32'd1000;
                                    state <= ST_WB_WRITE;
                                    word_byte_cnt <= 2'd0;
                                end else begin
                                    word_byte_cnt <= word_byte_cnt + 1;
                                end
                            end
                        end
                    end
                end
                
                // ============================================================
                // WB_WRITE: Wait for Wishbone write to complete
                // ============================================================
                ST_WB_WRITE: begin
                    timeout_cnt <= timeout_cnt - 1;
                    
                    if (wb_ack_i) begin
                        wb_stb_o <= 1'b0;
                        wb_cyc_o <= 1'b0;
                        wb_we_o <= 1'b0;
                        addr <= addr + 4;
                        
                        if (remaining > 0) begin
                            // More data to receive
                            state <= ST_DATA;
                        end else begin
                            // Done - wait for terminator
                            state <= ST_DATA;
                        end
                    end else if (wb_err_i || timeout_cnt == 0) begin
                        wb_stb_o <= 1'b0;
                        wb_cyc_o <= 1'b0;
                        wb_we_o <= 1'b0;
                        wb_error <= 1'b1;
                        state <= ST_DATA;
                    end
                end
                
                default: begin
                    state <= ST_IDLE;
                    tx_hold_valid <= 1'b1;
                    tx_hold_data <= SYNC_BYTE;
                end
            endcase
        end
    end

endmodule

`default_nettype wire
