#include "../hal/hal.h"
#include "pico/stdlib.h"
#include "pico/stdio_usb.h"
#include "hardware/timer.h"
#include "hardware/gpio.h"
#include "hardware/uart.h"
#include "dshot.h"
#include "debug_uart.h"
#include "spi_slave.h"
#include "pwm_decode.h"
#include "msp.h"
#include "../common/esc_passthrough.h"
#include "esc_pio_serial.h"
#include <stdio.h>

namespace {

static constexpr uint kDebugUartTxPin = 20;
static constexpr uint32_t kDebugUartBaud = 115200;
static bool g_debug_uart_hw_inited = false;

static inline void ensure_debug_uart_hw_init() {
    if (g_debug_uart_hw_inited) {
        return;
    }
    uart_init(uart1, kDebugUartBaud);
    gpio_set_function(kDebugUartTxPin, GPIO_FUNC_UART);
    uart_set_hw_flow(uart1, false, false);
    uart_set_format(uart1, 8, 1, UART_PARITY_NONE);
    g_debug_uart_hw_inited = true;
}

}

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
    ensure_debug_uart_hw_init();
    uart_putc_raw(uart1, static_cast<uint8_t>(c));
    if (stdio_usb_connected()) {
        putchar(c);
    }
}

void hal_debug_puts(const char* s) {
    if (!s) {
        return;
    }

    ensure_debug_uart_hw_init();

    // Keep human-readable debug text on external UART only.
    // NOTE: MSP protocol bytes share stdio/USB path via hal_debug_putc();
    // mirroring debug text to USB corrupts configurator framing.
    const char *tx = s;
    while (*tx) {
        uart_putc_raw(uart1, static_cast<uint8_t>(*tx++));
    }
}

void hal_debug_hex(uint32_t val) {
    char buf[9];
    snprintf(buf, sizeof(buf), "%08X", static_cast<unsigned int>(val));
    hal_debug_puts(buf);
}

void hal_led_init(void) {
#ifdef PICO_DEFAULT_LED_PIN
    gpio_init(PICO_DEFAULT_LED_PIN);
    gpio_set_dir(PICO_DEFAULT_LED_PIN, GPIO_OUT);
#endif
}

void hal_led_on(void) {
#ifdef PICO_DEFAULT_LED_PIN
    gpio_put(PICO_DEFAULT_LED_PIN, 1);
#endif
}

void hal_led_off(void) {
#ifdef PICO_DEFAULT_LED_PIN
    gpio_put(PICO_DEFAULT_LED_PIN, 0);
#endif
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
    if (active) {
        // Entering passthrough: disable DSHOT on this line
        dshot_force_stop_all();
        // Hardware pin muxing for UART/bitbanging
        uint pin = motors_get_pin(channel);
        esc_pio_serial_start(pin, 19200); // Default BLHeli baud
    } else {
        // Exiting passthrough: restore pin to DSHOT PIO
        esc_pio_serial_stop();
        // Hardware pin muxing restoration
        uint pin = motors_get_pin(channel);
        pio_gpio_init(dshot::Inst, pin);
        // The dshot_update_all() will automatically re-enable the SM when normal operation resumes.
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
    esc_pio_serial_write_byte(c);
}

int16_t hal_esc_serial_getc(uint8_t channel) {
    uint8_t out_value;
    if (esc_pio_serial_read_byte(&out_value)) {
        return out_value;
    }
    return -1;
}

} // extern "C"
