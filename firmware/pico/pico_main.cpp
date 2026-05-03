#include <stdint.h>
#include <cstdint>
#include "pico/stdlib.h"
#include "pico/stdio_usb.h"
#include "pico/multicore.h"
#include "hardware/irq.h"
#include "dshot.h"
#include "debug_uart.h"
#include "neopixel.h"
#include "pwm_decode.h"
#include "spi_slave.h"
#include "timing_config.h"
#include "../hal/hal.h"

extern "C" {
    void app_setup(void);
    void app_run_iteration(void);
}

/**
 * @brief Core 1: Background Tasks
 * Handles all non-time-critical logic like:
 * - RC Signal decoding (PWM pulses)
 *
 * Motor-line ownership (DSHOT vs half-duplex serial passthrough)
 * stays on Core 0.
 */
extern "C" void core1_main() {
    while (true) {
        // Continuous decoding of RC inputs from PWM pins
        pwm_decode_update();

        // Optional logic for LED heartbeats or telemetry status updates
        // could be added here to avoid Core 0 latency spikes.

        tight_loop_contents();
    }
}

namespace {

static constexpr bool UsbIsolationMode = false;
static constexpr bool DebugMainTrace = false;

unsigned short msp_slider_to_dshot(unsigned short us_like_value);

enum class MotorLineMode : unsigned char {
    PassthroughBlocked,
    MspOverride,
    SpiLive,
    FailsafeStale,
};

MotorLineMode determine_motor_line_mode(bool dshot_forced_off,
                                        bool msp_override_active,
                                        bool motor_cmd_stale) {
    if (dshot_forced_off) {
        return MotorLineMode::PassthroughBlocked;
    }
    if (msp_override_active) {
        return MotorLineMode::MspOverride;
    }
    if (motor_cmd_stale) {
        return MotorLineMode::FailsafeStale;
    }
    return MotorLineMode::SpiLive;
}

const char *motor_line_mode_name(MotorLineMode mode) {
    switch (mode) {
        case MotorLineMode::PassthroughBlocked:
            return "PT";
        case MotorLineMode::MspOverride:
            return "MSP";
        case MotorLineMode::SpiLive:
            return "SPI";
        case MotorLineMode::FailsafeStale:
            return "SAFE";
        default:
            return "?";
    }
}

unsigned short resolve_motor_output(MotorLineMode mode,
                                    unsigned char motor_index,
                                    const unsigned short *msp_override_values) {
    switch (mode) {
        case MotorLineMode::MspOverride:
            return msp_slider_to_dshot(msp_override_values[motor_index]);
        case MotorLineMode::SpiLive:
            return static_cast<unsigned short>(spi_get_motor_command(motor_index));
        case MotorLineMode::FailsafeStale:
        case MotorLineMode::PassthroughBlocked:
        default:
            return 0u;
    }
}

unsigned short msp_slider_to_dshot(unsigned short us_like_value) {
    // Betaflight-style motor slider semantics are typically 1000..2000.
    // DSHOT throttle range is 48..2047 (0 = stop).
    // Treat explicit zero as stop; slider minimum (1000) maps to first
    // valid DSHOT throttle value.
    if (us_like_value == 0u) {
        return 0u;
    }
    if (us_like_value < 1000u) {
        us_like_value = 1000u;
    }
    if (us_like_value >= 2000u) {
        return 2047u;
    }

    const uint32_t in_span = 1000u;
    const uint32_t out_min = 48u;
    const uint32_t out_span = 2047u - out_min;
    const uint32_t in = static_cast<uint32_t>(us_like_value - 1000u);
    const uint32_t mapped = out_min + ((in * out_span + (in_span / 2u)) / in_span);
    return static_cast<unsigned short>(mapped);
}

bool init_usb_stdio_only() {
    if (!stdio_usb_init()) {
        return false;
    }

    stdio_filter_driver(&stdio_usb);
    return true;
}

void usb_startup_grace_period() {
    const absolute_time_t deadline = delayed_by_ms(get_absolute_time(), timing_config::UsbEnumerateWaitMs);
    while (!time_reached(deadline)) {
        if (stdio_usb_connected()) {
            sleep_ms(timing_config::UsbSettleDelayMs);
            return;
        }
        sleep_ms(timing_config::UsbPollStepMs);
        tight_loop_contents();
    }
}

[[noreturn]] void usb_isolation_loop() {
#ifdef PICO_DEFAULT_LED_PIN
    gpio_init(PICO_DEFAULT_LED_PIN);
    gpio_set_dir(PICO_DEFAULT_LED_PIN, GPIO_OUT);
    bool led_on = false;
    uint64_t last_toggle_us = time_us_64();
#endif

    while (true) {
#ifdef PICO_DEFAULT_LED_PIN
        const uint64_t now_us = time_us_64();
        if ((now_us - last_toggle_us) >= 500000u) {
            last_toggle_us = now_us;
            led_on = !led_on;
            gpio_put(PICO_DEFAULT_LED_PIN, led_on);
        }
#endif
        tight_loop_contents();
    }
}

} // namespace

/**
 * @brief Core 0: Real-time Flight Controller
 * Primary responsibility is the high-jitter-sensitive SPI bus 
 * and synchronized DSHOT motor packet dispatch.
 */
int main() {
    // Initial console setup: initialize only USB CDC stdio explicitly.
    init_usb_stdio_only();
    usb_startup_grace_period();

    if (UsbIsolationMode) {
        usb_isolation_loop();
    }

    // Initialize all firmware subsystems
    pwm_decode_init();
    multicore_launch_core1(core1_main);

    dshot_init();
    neopixel_init();
    spi_slave_init();

    // Unified App Setup
    app_setup();

    while (true) {
        // High-priority SPI bus service
        spi_slave_task();

        // Run the unified app logic (MSP, state machines, etc.)
        app_run_iteration();

        tight_loop_contents();
    }

    return 0;
}
