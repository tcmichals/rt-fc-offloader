#pragma once

#include <stdbool.h>
#include <stdint.h>

extern "C" {
    void esc_passthrough_init(void);
    bool esc_passthrough_begin(uint8_t motor_index);
    void esc_passthrough_end(void);
    bool esc_passthrough_active(void);
    uint8_t esc_passthrough_motor(void);

    bool esc_passthrough_dshot_forced_off(void);
    bool esc_passthrough_dshot_allowed(void);

    void esc_passthrough_write_byte(uint8_t value);
    bool esc_passthrough_read_byte(uint8_t *out_value);
}