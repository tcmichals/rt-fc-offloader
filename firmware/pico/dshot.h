#pragma once
#include <stdint.h>
#include <stdbool.h>
#include "hardware/pio.h"

namespace dshot {

static constexpr uint8_t MaxMotors = 4;
static PIO const Inst = pio0;

// Motor Pin Assignment
enum class Pin : uint {
    Motor1 = 6,
    Motor2 = 7,
    Motor3 = 8,
    Motor4 = 9
};

struct Motor {
    uint pin;
    uint sm;
    uint offset;
    bool configured;
};

} // namespace dshot

extern "C" {
    void dshot_init(void);
    void dshot_show();
    void dshot_write(uint8_t motor_index, uint16_t throttle, bool request_telemetry);
    void dshot_update_all(void);
    void dshot_force_stop_all(void);
    uint16_t dshot_prepare_packet(uint16_t value, bool request_telemetry);
    
    // Accessors for ESC passthrough
    uint motors_get_sm(uint8_t motor_index);
    uint motors_get_pin(uint8_t motor_index);
}
