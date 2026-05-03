#pragma once
#include <stdint.h>
#include <stdbool.h>

namespace pwm {

static constexpr uint8_t NumChannels = 6;
static constexpr uint16_t MinUs = 900;
static constexpr uint16_t MaxUs = 2100;
static constexpr uint32_t FailsafeMs = 50;

enum class Pin : uint8_t {
    Ch1 = 0,
    Ch2 = 1,
    Ch3 = 2,
    Ch4 = 3,
    Ch5 = 4,
    Ch6 = 5
};

struct Channel {
    uint16_t pulse_us;
    uint32_t last_update_ms;
    bool     failsafe;
};

} // namespace pwm

extern "C" {
    void     pwm_decode_init(void);
    void     pwm_decode_update(void);
    uint16_t pwm_get_us(uint8_t channel);
    bool     pwm_is_failsafe(uint8_t channel);
    bool     pwm_any_failsafe(void);
}
