#include "esc_passthrough.h"
#include "../hal/hal.h"
#include "timing_config.h"

namespace {

struct SharedState {
    bool active = false;
    uint8_t motor = 0;
    uint32_t dshot_block_until_us32 = 0;
    bool dshot_forced_off = false;
};

static SharedState state;

// After passthrough ends, allow DSHOT to resume after DshotResumeDelayUs.
static constexpr bool DebugLatchDshotOffAfterPassthrough = false;
static bool dshot_hold_latched = false;

static constexpr uint32_t EscPrechargeHighMs = 5;
static constexpr uint32_t EscBreakLowMs = 100;
static constexpr uint32_t EscReleaseHighMs = 5;

static inline bool time_before_us32(uint32_t a, uint32_t b) {
    return static_cast<int32_t>(a - b) < 0;
}

static void refresh_dshot_forced_off() {
    const uint32_t now = hal_uptime_us();
    hal_critical_section_enter();
    if (state.active) {
        state.dshot_forced_off = true;
    } else if (DebugLatchDshotOffAfterPassthrough && dshot_hold_latched) {
        state.dshot_forced_off = true;
    } else {
        state.dshot_forced_off = time_before_us32(now, state.dshot_block_until_us32);
    }
    hal_critical_section_exit();
}

static void line_bootloader_transition(uint8_t motor_index) {
    hal_dshot_set_passthrough(motor_index, true);
    
    // Simple bit-bang transition for BLHeli bootloader entry
    hal_delay_us(EscPrechargeHighMs * 1000);
    // Note: Bootloader entry usually requires a specific toggle sequence
    // we'll leave the detailed implementation to the HAL if needed.
}

} // namespace

extern "C" {

void esc_passthrough_init(void) {
    hal_critical_section_enter();
    state = {};
    state.dshot_forced_off = false;
    dshot_hold_latched = false;
    hal_critical_section_exit();
}

bool esc_passthrough_begin(uint8_t motor_index) {
    if (motor_index >= HAL_MAX_MOTORS) return false;

    if (esc_passthrough_active()) {
        esc_passthrough_end();
    }

    hal_critical_section_enter();
    state.active = true;
    state.dshot_forced_off = true;
    state.motor = motor_index;
    dshot_hold_latched = true;
    hal_critical_section_exit();

    line_bootloader_transition(motor_index);
    return true; 
}

void esc_passthrough_end(void) {
    uint8_t local_motor = 0;
    bool was_active = false;
    
    hal_critical_section_enter();
    was_active = state.active;
    local_motor = state.motor;
    hal_critical_section_exit();

    if (!was_active) {
        refresh_dshot_forced_off();
        return;
    }

    hal_dshot_set_passthrough(local_motor, false);

    hal_critical_section_enter();
    if (DebugLatchDshotOffAfterPassthrough && dshot_hold_latched) {
        state.dshot_block_until_us32 = 0;
        state.dshot_forced_off = true;
    } else {
        state.dshot_block_until_us32 = hal_uptime_us() + timing_config::DshotResumeDelayUs;
        state.dshot_forced_off = true;
    }
    state.active = false;
    hal_critical_section_exit();
}

bool esc_passthrough_active(void) {
    hal_critical_section_enter();
    const bool value = state.active;
    hal_critical_section_exit();
    return value;
}

uint8_t esc_passthrough_motor(void) {
    hal_critical_section_enter();
    const uint8_t value = state.motor;
    hal_critical_section_exit();
    return value;
}

bool esc_passthrough_dshot_forced_off(void) {
    refresh_dshot_forced_off();
    hal_critical_section_enter();
    const bool value = state.dshot_forced_off;
    hal_critical_section_exit();
    return value;
}

bool esc_passthrough_dshot_allowed(void) {
    return !esc_passthrough_dshot_forced_off();
}

void esc_passthrough_write_byte(uint8_t value) {
    hal_esc_serial_putc(state.motor, value);
}

bool esc_passthrough_read_byte(uint8_t *out_value) {
    int16_t c = hal_esc_serial_getc(state.motor);
    if (c >= 0) {
        if (out_value) *out_value = static_cast<uint8_t>(c);
        return true;
    }
    return false;
}

}