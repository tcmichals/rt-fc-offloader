#ifndef HAL_H
#define HAL_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#define HAL_MAX_MOTORS 4

#ifdef __cplusplus
extern "C" {
#endif

/* --- System & Timing --- */
void     hal_init(void);
uint32_t hal_uptime_us(void);
uint32_t hal_uptime_ms(void);
void     hal_delay_us(uint32_t us);
// Reads a byte from the primary control stream (USB/UART). Returns -1 if no data.
int16_t  hal_getc(void);

// Critical section abstraction for cross-platform safety
void     hal_critical_section_enter(void);
void     hal_critical_section_exit(void);

/* --- Debug Console --- */
void     hal_debug_putc(char c);
void     hal_debug_puts(const char* s);
void     hal_debug_hex(uint32_t val);

/* --- Motor / DShot --- */
// Sets the output value for a specific DShot channel
void     hal_dshot_write(uint8_t channel, uint16_t value);
// Returns true if the DShot line is currently being used for passthrough
bool     hal_dshot_is_passthrough_active(uint8_t channel);
// Transitions a DShot pin between normal and passthrough mode
void     hal_dshot_set_passthrough(uint8_t channel, bool active);

/* --- SPI Bus (Link to Host) --- */
// Returns the latest motor command received from the host over SPI
uint16_t hal_spi_get_motor_command(uint8_t channel);
// Returns true if the host has selected this device (CS active)
bool     hal_spi_is_selected(void);
// Exchanges data over SPI. Non-blocking if hardware permits.
void     hal_spi_exchange(const uint8_t* tx_buf, uint8_t* rx_buf, size_t len);
// Returns true if an SPI transaction is complete
bool     hal_spi_is_busy(void);

/* --- UART / ESC Passthrough --- */
// Returns the pulse width (in microseconds) of a PWM input channel
uint16_t hal_pwm_get_us(uint8_t channel);
// Writes a byte to the ESC serial line during passthrough
void     hal_esc_serial_putc(uint8_t channel, uint8_t c);
// Reads a byte from the ESC serial line (returns -1 if no data)
int16_t  hal_esc_serial_getc(uint8_t channel);

#ifdef __cplusplus
}
#endif

#endif // HAL_H
