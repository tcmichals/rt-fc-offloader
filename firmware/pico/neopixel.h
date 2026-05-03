#pragma once
#include <stdint.h>
#include <stdbool.h>
#include "pico/types.h"

namespace neopixel {

static constexpr uint Pin = 10;
static constexpr uint Count = 16;
static constexpr bool IsRgbw = true;

struct Color {
    uint8_t r, g, b, w;
};

} // namespace neopixel

// Maintain compatibility with existing code using old names (or we update them too)
#define NEOPIXEL_COUNT neopixel::Count

extern "C" {
    void neopixel_init(void);
    void neopixel_set(uint index, uint8_t r, uint8_t g, uint8_t b, uint8_t w);
    void neopixel_set_all(uint8_t r, uint8_t g, uint8_t b, uint8_t w);
    void neopixel_show(void);
    void neopixel_clear(void);
}
