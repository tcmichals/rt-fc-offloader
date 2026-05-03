#include "../hal/hal.h"
#include "pico/stdlib.h"
#include "hardware/timer.h"
#include "dshot.h"
#include "debug_uart.h"
#include "spi_slave.h"
#include "pwm_decode.h"
#include "msp.h"
#include "../common/esc_passthrough.h"
#include <stdio.h>

extern "C" {

void hal_init(void) {
    // Basic Pico SDK init is usually handled in the boilerplate
    // but we can ensure standard I/O is ready if needed.
}

uint32_t hal_uptime_us(void) {
    return time_us_32();
}

uint32_t hal_uptime_ms(void) {
    return to_ms_since_boot(get_absolute_time());
}

void     hal_delay_us(uint32_t us) {
    sleep_us(us);
}

int16_t  hal_getc(void) {
    int c = getchar_timeout_us(0);
    if (c == PICO_ERROR_TIMEOUT) return -1;
    return (int16_t)static_cast<uint8_t>(c);
}

void hal_critical_section_enter(void) {
    // On Pico, use hardware spinlock or disable interrupts
    // For simplicity, we can use the interrupt masking approach
    irq_set_mask_enabled(0xFFFFFFFF, false);
}

void hal_critical_section_exit(void) {
    // Re-enable all interrupts
    irq_set_mask_enabled(0xFFFFFFFF, true);
}

void hal_debug_putc(char c) {
    putchar(c);
}

void hal_debug_puts(const char* s) {
    debug_uart::write(s);
}

void hal_debug_hex(uint32_t val) {
    debug_uart::writef("%08X", val);
}

void hal_dshot_write(uint8_t channel, uint16_t value) {
    if (channel < dshot::MaxMotors) {
        dshot_write(channel, value, false);
        // On Pico, we usually call dshot_update_all() after a batch of writes.
        // The common app logic should handle the batching.
    }
}

bool hal_dshot_is_passthrough_active(uint8_t channel) {
    // On Pico, this is derived from the MSP/4-way state
    return msp_passthrough_is_active();
}

void hal_dshot_set_passthrough(uint8_t channel, bool active) {
    // On Pico, toggle the passthrough mode for the specified channel
    if (active) {
        // Entering passthrough: disable DSHOT on this line
        dshot_force_stop_all();
        esc_passthrough_begin(channel);
    } else {
        // Exiting passthrough: re-enable normal DSHOT mode
        esc_passthrough_end();
    }
}

uint16_t hal_spi_get_motor_command(uint8_t channel) {
    return spi_get_motor_command(channel);
}

bool hal_spi_is_selected(void) {
    // The Pico SPI slave driver handles CS via hardware/interrupts.
    // This is a placeholder for the polled check if needed.
    return true; 
}

void hal_spi_exchange(const uint8_t* tx_buf, uint8_t* rx_buf, size_t len) {
    // Pico SPI slave uses a background buffer/DMA.
    // This would trigger a sync if we were doing polled exchange.
}

bool hal_spi_is_busy(void) {
    return false;
}

uint16_t hal_pwm_get_us(uint8_t channel) {
    return pwm_get_us(channel);
}

void hal_esc_serial_putc(uint8_t channel, uint8_t c) {
    // Placeholder for 4-way serial write
}

int16_t hal_esc_serial_getc(uint8_t channel) {
    // Placeholder for 4-way serial read
    return -1;
}

} // extern "C"
