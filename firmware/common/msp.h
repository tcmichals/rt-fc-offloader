#pragma once
#include <stdint.h>
#include <stdbool.h>

namespace msp {

enum class Preamble : uint8_t {
    Start = '$',
    V1    = 'M',
    V2    = 'X'
};

enum class Direction : uint8_t {
    ToFC   = '<',
    FromFC = '>',
    Error  = '!'
};

enum class Command : uint8_t {
    ApiVersion     = 1,
    FcVariant      = 2,
    FcVersion      = 3,
    BoardInfo      = 4,
    BuildInfo      = 5,
    FeatureConfig  = 36,
    Ident          = 100,
    Name           = 10,
    Status         = 101,
    Motor          = 104,
    Rc             = 105,
    Analog         = 110,
    BatteryState   = 130,
    Uid            = 160,
    MotorTelemetry = 139,
    SetRawRc      = 200,
    SetMotor       = 214,
    SetPassthrough = 245,
    EepromWrite    = 250
};

static constexpr const char* FcId = "BTFL";
static constexpr const char* BoardId = "P2FC";
static constexpr uint8_t ApiVersionMajor = 1;
static constexpr uint8_t ApiVersionMinor = 48;

enum class PassthroughMode : uint8_t {
    SerialEsc = 0,
    Vtx       = 1
};

enum class DebugLevel : uint8_t {
    Off     = 0,
    Basic   = 1,
    Verbose = 2,
};

} // namespace msp

#include "../hal/pt.h"

extern "C" {
    void msp_init(void);
    PT_THREAD(msp_task(struct pt *pt));
    uint32_t msp_get_last_activity_us32(void);
    bool msp_passthrough_is_active(void);
    uint8_t msp_passthrough_motor(void);
    bool msp_is_dshot_forced_off(void);
    bool msp_dshot_output_allowed(void);
    bool msp_motor_override_pop_latest(unsigned short *out_values, unsigned char motor_count, unsigned int *out_update_us32);

    void msp_set_debug_level(uint8_t level);
    uint8_t msp_get_debug_level(void);

    uint32_t msp_get_crc_error_count(void);
    uint32_t msp_get_v2_crc_error_count(void);
    uint32_t msp_get_passthrough_begin_ok_count(void);
    uint32_t msp_get_passthrough_begin_fail_count(void);
    uint32_t msp_get_passthrough_auto_exit_count(void);
    uint32_t msp_get_unhandled_cmd_count(void);
}
