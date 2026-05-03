#include "esc_pio_serial.h"

#include "pico/stdlib.h"
#include "hardware/clocks.h"
#include "hardware/pio.h"
#include "esc_pio_uart.pio.h"

namespace {

static PIO const EscPio = pio1;

struct EscPioSerialState {
    bool started = false;
    uint pin = 0;
    uint32_t baud = 0;
    uint sm_tx = 0;
    uint sm_rx = 1;
    uint offset_tx = 0;
    uint offset_rx = 0;
};

static EscPioSerialState s;

static inline float pio_div_for_uart_8clocks(uint32_t baud) {
    return static_cast<float>(clock_get_hz(clk_sys)) / (8.0f * static_cast<float>(baud));
}

static void configure_tx_sm() {
    pio_sm_config c = esc_uart_tx_program_get_default_config(s.offset_tx);
    sm_config_set_out_pins(&c, s.pin, 1);
    sm_config_set_sideset_pins(&c, s.pin);
    sm_config_set_out_shift(&c, true, false, 32);
    sm_config_set_fifo_join(&c, PIO_FIFO_JOIN_TX);
    sm_config_set_clkdiv(&c, pio_div_for_uart_8clocks(s.baud));

    pio_sm_init(EscPio, s.sm_tx, s.offset_tx, &c);
    pio_sm_set_enabled(EscPio, s.sm_tx, false);
    pio_sm_set_consecutive_pindirs(EscPio, s.sm_tx, s.pin, 1, false);
}

static void configure_rx_sm() {
    pio_sm_config c = esc_uart_rx_program_get_default_config(s.offset_rx);
    sm_config_set_in_pins(&c, s.pin);
    sm_config_set_jmp_pin(&c, s.pin);
    sm_config_set_in_shift(&c, true, false, 32);
    sm_config_set_fifo_join(&c, PIO_FIFO_JOIN_RX);
    sm_config_set_clkdiv(&c, pio_div_for_uart_8clocks(s.baud));

    pio_sm_init(EscPio, s.sm_rx, s.offset_rx, &c);
    pio_sm_set_consecutive_pindirs(EscPio, s.sm_rx, s.pin, 1, false);
    pio_sm_set_enabled(EscPio, s.sm_rx, true);
}

static void tx_enable_drive() {
    // Disable RX SM first to prevent the half-duplex TX from echoing into the
    // RX FIFO and corrupting subsequent ESC responses.
    pio_sm_set_enabled(EscPio, s.sm_rx, false);
    pio_sm_set_enabled(EscPio, s.sm_tx, false);
    pio_sm_clear_fifos(EscPio, s.sm_tx);
    pio_sm_restart(EscPio, s.sm_tx);
    pio_sm_set_consecutive_pindirs(EscPio, s.sm_tx, s.pin, 1, true);
    pio_sm_set_enabled(EscPio, s.sm_tx, true);
}

static void tx_release_line() {
    pio_sm_set_enabled(EscPio, s.sm_tx, false);
    pio_sm_set_consecutive_pindirs(EscPio, s.sm_tx, s.pin, 1, false);
    // Re-enable RX SM to listen for the ESC response. Restart it cleanly so
    // any partial ISR state from before TX is discarded.
    pio_sm_restart(EscPio, s.sm_rx);
    pio_sm_set_enabled(EscPio, s.sm_rx, true);
}

} // namespace

extern "C" {

bool esc_pio_serial_start(uint pin, uint32_t baud) {
    if (s.started) {
        esc_pio_serial_stop();
    }

    s.pin = pin;
    s.baud = baud;

    pio_gpio_init(EscPio, s.pin);
    // One-wire UART idles high; keep a pull-up when line is released.
    gpio_set_pulls(s.pin, true, false);

    s.offset_tx = pio_add_program(EscPio, &esc_uart_tx_program);
    s.offset_rx = pio_add_program(EscPio, &esc_uart_rx_program);

    configure_tx_sm();
    configure_rx_sm();
    tx_release_line();

    s.started = true;
    return true;
}

void esc_pio_serial_stop(void) {
    if (!s.started) return;

    tx_release_line();
    pio_sm_set_enabled(EscPio, s.sm_tx, false);
    pio_sm_set_enabled(EscPio, s.sm_rx, false);

    pio_remove_program(EscPio, &esc_uart_tx_program, s.offset_tx);
    pio_remove_program(EscPio, &esc_uart_rx_program, s.offset_rx);

    s.started = false;
}

void esc_pio_serial_write_byte(uint8_t value) {
    if (!s.started) return;

    tx_enable_drive();
    pio_sm_put_blocking(EscPio, s.sm_tx, value);

    // 10 bits at current baud (+ small guard)
    const uint32_t frame_us = (1000000u * 10u) / (s.baud ? s.baud : 1u);
    sleep_us(frame_us + 20u);

    tx_release_line();
}

bool esc_pio_serial_read_byte(uint8_t *out_value) {
    if (!s.started || !out_value) return false;
    if (pio_sm_is_rx_fifo_empty(EscPio, s.sm_rx)) return false;

    const uint32_t raw = pio_sm_get(EscPio, s.sm_rx);
    *out_value = static_cast<uint8_t>(raw >> 24);
    return true;
}

} // extern "C"
