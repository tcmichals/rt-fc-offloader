/**
 * @file main.cpp
 * @brief Primary firmware entry point for the SERV bit-serial RISC-V core.
 * 
 * This application manages the FCSP (Flight Controller Serial Protocol) 
 * control-plane logic. It responds to capability requests, handles PING 
 * handshakes, and dictates IO operations (like ESC passthrough modes).
 * 
 * Target Architecture: RV32I (SERV)
 * Memory Constraints:  4KB to 8KB Block RAM (Tang Nano 9K BRAM)
 */

#include <stdint.h>

// Define the simulated mailbox base address that the Verilog hardware (fcsp_serv_bridge.sv) 
// exposes over the Wishbone bus for the SERV CPU to interact with.
#define MAILBOX_BASE 0x40000000

volatile uint8_t* const rx_ready = (uint8_t*)(MAILBOX_BASE + 0x00);
volatile uint8_t* const rx_data  = (uint8_t*)(MAILBOX_BASE + 0x04);
volatile uint8_t* const tx_ready = (uint8_t*)(MAILBOX_BASE + 0x08);
volatile uint8_t* const tx_data  = (uint8_t*)(MAILBOX_BASE + 0x0C);

// Standard subset of FCSP operations
const uint8_t OP_PING = 0x06;
const uint8_t RES_OK  = 0x00;

/**
 * @brief Sends a byte to the hardware TX mailbox, blocking until ready.
 */
void out_byte(uint8_t b) {
    while (!(*tx_ready)) {}
    *tx_data = b;
}

/**
 * @brief Core execution loop
 */
int main() {
    uint8_t current_op = 0;
    uint8_t bytes_collected = 0;
    uint8_t buffer[16];

    while (1) {
        // Wait for incoming packet byte from the hardware parser mailbox
        if (*rx_ready) {
            uint8_t byte_in = *rx_data;
            
            if (bytes_collected == 0) {
                current_op = byte_in;
                bytes_collected++;
            } else {
                if (bytes_collected < sizeof(buffer)) {
                    buffer[bytes_collected - 1] = byte_in;
                }
                bytes_collected++;
                
                // Example: We know PING payload has exactly 4 bytes of nonce
                if (current_op == OP_PING && bytes_collected == 5) {
                    // Send RES_OK
                    out_byte(RES_OK);
                    // Echo the 4-byte nonce exactly as received
                    for (int i = 0; i < 4; i++) {
                        out_byte(buffer[i]);
                    }
                    bytes_collected = 0;
                }
            }
        }
    }

    return 0;
}
