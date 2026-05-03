#pragma once

#include <stdbool.h>
#include <stdint.h>

extern "C" {
    void esc_4way_reset(void);
    uint8_t esc_4way_esc_count(void);
    bool esc_4way_task(void);
}