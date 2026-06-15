#include <stdint.h>
#include <cstdint>
#include "pico/stdlib.h"
#include "pico/stdio_usb.h"
#include "pico/multicore.h"
#include "hardware/irq.h"
#include "hardware/structs/sio.h"
#include "dshot.h"
#include "debug_uart.h"
#include "timing_config.h"
#include "../hal/hal.h"
#include "msp.h"
#include "hardware/timer.h"

extern "C" {
    void app_setup(void);
    void app_run_iteration(void);
    void logger_core1_task(void);
}

/**
 * @brief Core 1: Background Tasks
 * Handles all non-time-critical logic like:
 * - UART Debug Logging
 */
extern "C" void core1_main() {
    while (true) {
        logger_core1_task();
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
    UsbLive,
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
    return MotorLineMode::UsbLive;
}

const char *motor_line_mode_name(MotorLineMode mode) {
    switch (mode) {
        case MotorLineMode::PassthroughBlocked:
            return "PT";
        case MotorLineMode::MspOverride:
            return "MSP";
        case MotorLineMode::UsbLive:
            return "USB";
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
        case MotorLineMode::UsbLive:
            // Since we're just testing MSP, keep ESCs armed at 0% throttle
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

static volatile uint16_t g_dshot_values[4] = {48, 48, 48, 48};
static volatile bool g_dshot_passthrough_mask[4] = {false, false, false, false};

static bool dshot_timer_callback(repeating_timer_t *rt) {
    for (uint8_t i = 0; i < 4; i++) {
        if (!g_dshot_passthrough_mask[i]) {
            dshot_write(i, g_dshot_values[i], false);
        }
    }
    dshot_update_all();
    return true; // Keep repeating
}

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
    hal_init();
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
    multicore_launch_core1(core1_main);

    dshot_init();

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

    // Start 1kHz DShot Hardware Timer (Negative delay means start-to-start timing)
    repeating_timer_t dshot_timer;
    add_repeating_timer_us(-1000, dshot_timer_callback, NULL, &dshot_timer);

    uint32_t last_debug_heartbeat_us = hal_uptime_us();
    uint32_t last_led_toggle_us = hal_uptime_us();
    unsigned short msp_override_values[4] = {0, 0, 0, 0};
    unsigned int msp_override_update_us = 0;

    while (true) {
        // Run the unified app logic (MSP, state machines, etc.)
        app_run_iteration();

        uint32_t now_us = hal_uptime_us();

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
        // 3 second timeout for general MSP connection (failsafe)
        bool motor_cmd_stale = (now_us - msp_get_last_activity_us32()) > 3000000u;

        MotorLineMode mode = determine_motor_line_mode(dshot_forced_off, msp_override_active, motor_cmd_stale);

        for (uint8_t i = 0; i < 4; i++) {
            g_dshot_passthrough_mask[i] = hal_dshot_is_passthrough_active(i);
            g_dshot_values[i] = resolve_motor_output(mode, i, msp_override_values);
        }

        // Heartbeat: Toggle LED every 500ms to prove this loop is alive
        if (now_us - last_led_toggle_us >= 500000u) {
            last_led_toggle_us = now_us;
#ifdef PICO_DEFAULT_LED_PIN
            static bool led_state = false;
            static bool led_initialized = false;
            if (!led_initialized) {
                gpio_init(PICO_DEFAULT_LED_PIN);
                gpio_set_dir(PICO_DEFAULT_LED_PIN, GPIO_OUT);
                led_initialized = true;
            }
            led_state = !led_state;
            gpio_put(PICO_DEFAULT_LED_PIN, led_state);
#endif
        }

        tight_loop_contents();
    }

    return 0;
}
