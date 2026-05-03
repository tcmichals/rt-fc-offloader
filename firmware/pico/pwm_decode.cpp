#include "pwm_decode.h"
#include "hardware/pwm.h"
#include "hardware/gpio.h"
#include "hardware/clocks.h"
#include "pico/time.h"
#include <cstring>
#include <algorithm>

namespace {

static constexpr uint channel_pins[pwm::NumChannels] = {
    static_cast<uint>(pwm::Pin::Ch1), static_cast<uint>(pwm::Pin::Ch2),
    static_cast<uint>(pwm::Pin::Ch3), static_cast<uint>(pwm::Pin::Ch4),
    static_cast<uint>(pwm::Pin::Ch5), static_cast<uint>(pwm::Pin::Ch6)
};

static pwm::Channel channels[pwm::NumChannels];

void pwm_irq_handler() {
    uint32_t status = pwm_get_irq_status_mask();
    uint32_t now = to_ms_since_boot(get_absolute_time());

    for (int i = 0; i < pwm::NumChannels; i++) {
        uint slice = pwm_gpio_to_slice_num(channel_pins[i]);
        if (status & (1u << slice)) {
            pwm_clear_irq(slice);
            uint16_t count = pwm_get_counter(slice);
            pwm_set_counter(slice, 0);

            if (count >= pwm::MinUs && count <= pwm::MaxUs) {
                channels[i].pulse_us = count;
                channels[i].last_update_ms = now;
                channels[i].failsafe = false;
            }
        }
    }
}

} // namespace

extern "C" {

void pwm_decode_init() {
    float clk = static_cast<float>(clock_get_hz(clk_sys)) / 1e6f;
    uint16_t div_int = static_cast<uint16_t>(clk);

    for (auto& ch : channels) ch.failsafe = true;

    for (int i = 0; i < pwm::NumChannels; i++) {
        uint pin = channel_pins[i];
        uint slice = pwm_gpio_to_slice_num(pin);
        gpio_set_function(pin, GPIO_FUNC_PWM);

        pwm_config cfg = pwm_get_default_config();
        pwm_config_set_clkdiv_int_frac(&cfg, div_int, 0);
        pwm_config_set_clkdiv_mode(&cfg, PWM_DIV_B_HIGH);
        pwm_config_set_wrap(&cfg, pwm::MaxUs + 100);

        pwm_init(slice, &cfg, true);
        pwm_set_counter(slice, 0);
        pwm_set_irq_enabled(slice, true);
    }

    irq_set_exclusive_handler(PWM_IRQ_WRAP, pwm_irq_handler);
    irq_set_enabled(PWM_IRQ_WRAP, true);
}

void pwm_decode_update() {
    uint32_t now = to_ms_since_boot(get_absolute_time());
    for (int i = 0; i < pwm::NumChannels; i++) {
        if ((now - channels[i].last_update_ms) > pwm::FailsafeMs) {
            channels[i].failsafe = true;
        }
    }
}

uint16_t pwm_get_us(uint8_t channel) {
    if (channel >= pwm::NumChannels) return 1000;
    return channels[channel].failsafe ? 1000 : channels[channel].pulse_us;
}

bool pwm_is_failsafe(uint8_t channel) {
    return (channel < pwm::NumChannels) ? channels[channel].failsafe : true;
}

bool pwm_any_failsafe() {
    for (const auto& ch : channels) if (ch.failsafe) return true;
    return false;
}

} // extern "C"
