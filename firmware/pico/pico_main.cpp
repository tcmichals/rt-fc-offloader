#include <stdint.h>
#include <cstdint>
#include "pico/stdlib.h"
#include "pico/stdio_usb.h"
#include "pico/multicore.h"
#include "hardware/irq.h"
#include "hardware/structs/sio.h"
#include "dshot.h"
#include "debug_uart.h"
#include "neopixel.h"
#include "pwm_decode.h"
#include "spi_slave.h"
#include "timing_config.h"
#include "../hal/hal.h"
#include "../common/msp.h"

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
            // Since we're just testing MSP, ignore SPI and keep ESCs armed at 0% throttle
            return 48u;
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
    // Initialize all stdio backends enabled for this target.
    // With pico_enable_stdio_uart(..., 0) and pico_enable_stdio_usb(..., 1),
    // this effectively initializes USB CDC stdio.
    stdio_init_all();

    // Keep console I/O pinned to USB CDC for MSP bring-up.
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

extern "C" void isr_irq16() {
    // Clear the first early SIO_PROC1 interrupt and disable it if we do not
    // plan to use inter-core SIO signaling on core 0.
    if (sio_hw->fifo_st & 1u) {
        // Read the mailbox FIFO to clear any pending message.
        (void)sio_hw->fifo_rd;
    }
    irq_set_enabled(SIO_IRQ_PROC1, false);
}

/**
 * @brief Core 0: Real-time Flight Controller
 * Primary responsibility is the high-jitter-sensitive SPI bus 
 * and synchronized DSHOT motor packet dispatch.
 */
int main() {
    // Initial console setup: initialize only USB CDC stdio explicitly.
    init_usb_stdio_only();
    debug_uart::init();
    hal_debug_puts("rt_fc_pico: USB stdio init\r\n");

    // Turn on the default board LED to indicate startup.
    hal_led_init();
    hal_led_on();

    usb_startup_grace_period();
    hal_debug_puts("rt_fc_pico: entering main loop\r\n");

    if (UsbIsolationMode) {
        usb_isolation_loop();
    }

    // Initialize all firmware subsystems
    pwm_decode_init();
    multicore_launch_core1(core1_main);

    dshot_init();
    neopixel_init();
    spi_slave_init();

    // Send startup test pulses (0% throttle on all motors for 2 seconds to arm ESCs)
    hal_debug_puts("Sending startup DShot test pulses...\r\n");
    for (int test_cycles = 0; test_cycles < 200; test_cycles++) {  // 200 * 10ms = 2 seconds
        for (int i = 0; i < 4; i++) {
            dshot_write(i, 48, false);  // 48 = 0% throttle (arming)
        }
        dshot_update_all();
        sleep_ms(10);
    }
    hal_debug_puts("Startup test complete. Ready for MSP commands.\r\n");

    // Unified App Setup
    app_setup();

    uint32_t last_dshot_us = hal_uptime_us();
    uint32_t last_debug_heartbeat_us = last_dshot_us;
    unsigned short msp_override_values[4] = {0, 0, 0, 0};
    unsigned int msp_override_update_us = 0;

    while (true) {
        // High-priority SPI bus service
        spi_slave_task();

        // Run the unified app logic (MSP, state machines, etc.)
        app_run_iteration();

        // High-priority DSHOT cyclic transmission (~1kHz)
        uint32_t now_us = hal_uptime_us();
        if (now_us - last_dshot_us >= 1000) {
            last_dshot_us = now_us;

            if ((now_us - last_debug_heartbeat_us) >= 1000000u) {
                last_debug_heartbeat_us = now_us;
                hal_debug_puts("DBG UART heartbeat\r\n");
            }

            unsigned short new_overrides[4];
            unsigned int new_update_us;
            if (msp_motor_override_pop_latest(new_overrides, 4, &new_update_us)) {
                for (int i = 0; i < 4; i++) {
                    msp_override_values[i] = new_overrides[i];
                }
                msp_override_update_us = new_update_us;
            }

            // 1 second timeout for MSP overrides
            bool msp_override_active = (msp_override_update_us > 0) && ((now_us - msp_override_update_us) < 1000000); 
            bool dshot_forced_off = msp_is_dshot_forced_off();
            bool motor_cmd_stale = false; // TODO: implement SPI staleness check if needed

            MotorLineMode mode = determine_motor_line_mode(dshot_forced_off, msp_override_active, motor_cmd_stale);

            for (uint8_t i = 0; i < 4; i++) {
                if (!hal_dshot_is_passthrough_active(i)) {
                    unsigned short val = resolve_motor_output(mode, i, msp_override_values);
                    dshot_write(i, val, false);
                }
            }
            dshot_update_all();

            // Heartbeat: Toggle LED every 500ms to prove this loop is alive
            static int loop_counter = 0;
            if (++loop_counter >= 500) {
                loop_counter = 0;
#ifdef PICO_DEFAULT_LED_PIN
                static bool led_state = false;
                if (!led_state) {
                    gpio_init(PICO_DEFAULT_LED_PIN);
                    gpio_set_dir(PICO_DEFAULT_LED_PIN, GPIO_OUT);
                }
                led_state = !led_state;
                gpio_put(PICO_DEFAULT_LED_PIN, led_state);
#endif
            }
        }

        tight_loop_contents();
    }

    return 0;
}
