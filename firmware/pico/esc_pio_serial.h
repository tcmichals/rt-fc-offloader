#pragma once
#include <stdint.h>
#include <stdbool.h>
#include "pico/types.h"

extern "C" {
    bool esc_pio_serial_start(uint pin, uint32_t baud);
    void esc_pio_serial_stop(void);
    void esc_pio_serial_write_byte(uint8_t value);
    bool esc_pio_serial_read_byte(uint8_t *out_value);
}
