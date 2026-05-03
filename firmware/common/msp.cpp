#include <string.h>
#include "msp.h"
#include "../hal/hal.h"
#include "timing_config.h"
#include <stddef.h>
#include <stdint.h>

namespace {

enum class ParseState {
    WaitDollar,
    WaitMOrX,
    WaitDirection,

    // MSP v1
    WaitSizeV1,
    WaitCmdV1,
    WaitPayloadV1,
    WaitCrcV1,

    // MSP v2
    WaitFlagV2,
    WaitCmdL_V2,
    WaitCmdH_V2,
    WaitSizeL_V2,
    WaitSizeH_V2,
    WaitPayloadV2,
    WaitCrcV2,
};

static ParseState parse_state = ParseState::WaitDollar;
static uint16_t rx_cmd;
static uint16_t rx_size;
static uint8_t  rx_v2_flags;
static bool     rx_is_v2 = false;
static uint8_t  rx_buf[192];
static uint16_t rx_idx;
static uint8_t  rx_crc;
static uint8_t  rx_v2_crc;
static volatile uint32_t last_activity_us32 = 0;
static constexpr uint16_t MspV2InV1Cmd = 0x00FFu;
static constexpr uint16_t MspSetDebugLevelCmd = 253u;
static uint32_t passthrough_last_4way_activity_us32 = 0;

struct MotorOverrideMessage {
    uint16_t values[HAL_MAX_MOTORS];
    uint32_t update_us32;
};

static MotorOverrideMessage motor_override_mailbox{};
static bool motor_override_mailbox_valid = false;

static constexpr bool DebugTraceEnabled = true;
static constexpr bool DebugVerboseFrames = false;
static constexpr bool DebugStartupBanner = true;
static constexpr bool DebugCommandLog = true;
static volatile uint8_t g_debug_level = static_cast<uint8_t>(msp::DebugLevel::Basic);

static volatile uint32_t g_crc_error_count = 0;
static volatile uint32_t g_v2_crc_error_count = 0;
static volatile uint8_t g_passthrough_motor_idx = 0;
static volatile bool    g_passthrough_active = false;
static volatile uint32_t g_passthrough_begin_ok_count = 0;
static volatile uint32_t g_passthrough_begin_fail_count = 0;
static volatile uint32_t g_passthrough_auto_exit_count = 0;
static volatile uint32_t g_unhandled_cmd_count = 0;

static bool esc_passthrough_active() { return g_passthrough_active; }
static bool esc_passthrough_begin(uint8_t motor) { 
    g_passthrough_active = true; 
    g_passthrough_motor_idx = motor; 
    return true; 
}
static void esc_passthrough_end() { g_passthrough_active = false; }
static uint8_t esc_passthrough_motor() { return g_passthrough_motor_idx; }
static void esc_passthrough_init() {}
static bool esc_4way_task() { return false; }
static void esc_4way_reset() {}
static uint8_t esc_4way_esc_count() { return 0; }
static bool esc_passthrough_dshot_forced_off() { return false; }
static bool esc_passthrough_dshot_allowed() { return !g_passthrough_active; }

static bool debug_basic_enabled() {
    return DebugTraceEnabled && g_debug_level >= static_cast<uint8_t>(msp::DebugLevel::Basic);
}

static bool debug_verbose_enabled() {
    return DebugTraceEnabled && g_debug_level >= static_cast<uint8_t>(msp::DebugLevel::Verbose);
}

constexpr uint8_t build_id_byte() {
    // Compact compile-time build ID from __TIME__ (HH:MM:SS), folded to one byte.
    const uint8_t h = static_cast<uint8_t>((__TIME__[0] - '0') * 10 + (__TIME__[1] - '0'));
    const uint8_t m = static_cast<uint8_t>((__TIME__[3] - '0') * 10 + (__TIME__[4] - '0'));
    const uint8_t s = static_cast<uint8_t>((__TIME__[6] - '0') * 10 + (__TIME__[7] - '0'));
    return static_cast<uint8_t>((h * 7u) ^ (m * 13u) ^ (s * 17u));
}

constexpr char hex_digit(uint8_t v) {
    v &= 0x0Fu;
    return static_cast<char>((v < 10u) ? ('0' + v) : ('A' + (v - 10u)));
}

static void debug_puts(const char *s) {
    if (!debug_basic_enabled() || !s) return;
    hal_debug_puts(s);
}

static void debug_msp_frame(const char *prefix, char direction, uint8_t cmd, const uint8_t *payload, uint8_t len) {
    if (!debug_verbose_enabled() || !DebugVerboseFrames) return;
    
    hal_debug_puts(prefix);
    hal_debug_puts(" cmd=");
    hal_debug_hex(cmd);
    hal_debug_puts(" len=");
    hal_debug_hex(len);
    hal_debug_puts(" payload=");

    for (uint8_t i = 0; i < len; ++i) {
        hal_debug_hex(payload ? payload[i] : 0);
        if (i + 1 < len) hal_debug_puts(" ");
    }

    uint8_t crc = len ^ cmd;
    for (uint8_t i = 0; i < len; ++i) {
        crc ^= payload ? payload[i] : 0;
    }

    hal_debug_puts(" crc=");
    hal_debug_hex(crc);
    hal_debug_puts("\r\n");
    
    hal_debug_puts(prefix);
    hal_debug_puts(" frame: 24 4D ");
    hal_debug_hex(static_cast<uint8_t>(direction));
    hal_debug_puts(" ");
    hal_debug_hex(len);
    hal_debug_puts(" ");
    hal_debug_hex(cmd);

    for (uint8_t i = 0; i < len; ++i) {
        hal_debug_puts(" ");
        hal_debug_hex(payload ? payload[i] : 0);
    }
    hal_debug_puts(" ");
    hal_debug_hex(crc);
    hal_debug_puts("\r\n");
}

static void debug_log_int(const char *prefix, int val) {
    if (!debug_basic_enabled()) return;
    hal_debug_puts(prefix);
    hal_debug_hex((uint32_t)val);
    hal_debug_puts("\r\n");
}

static void debug_logf(const char *fmt, int a, int b = 0) {
    // Stubbed or replaced by specialized debug_log_int to save space.
    // Full snprintf is too large for 16KB SERV RAM.
    debug_log_int(fmt, a);
}

static bool should_trace_msp_cmd(uint16_t cmd) {
    if (!debug_verbose_enabled() || !DebugVerboseFrames) {
        return false;
    }
    switch (cmd) {
        case static_cast<uint16_t>(msp::Command::SetPassthrough):
        case static_cast<uint16_t>(msp::Command::ApiVersion):
        case static_cast<uint16_t>(msp::Command::FcVariant):
        case static_cast<uint16_t>(msp::Command::FcVersion):
        case static_cast<uint16_t>(msp::Command::BoardInfo):
            return true;
        default:
            return false;
    }
}

static uint8_t crc8_dvb_s2_update(uint8_t crc, uint8_t data) {
    crc ^= data;
    for (int i = 0; i < 8; ++i) {
        if (crc & 0x80u) {
            crc = static_cast<uint8_t>((crc << 1) ^ 0xD5u);
        } else {
            crc = static_cast<uint8_t>(crc << 1);
        }
    }
    return crc;
}

static bool normalize_motor_index(uint8_t in_value, uint8_t *out_index) {
    if (!out_index) return false;
    if (in_value < HAL_MAX_MOTORS) {
        *out_index = in_value;
        return true;
    }
    if (in_value >= 1 && in_value <= HAL_MAX_MOTORS) {
        *out_index = static_cast<uint8_t>(in_value - 1);
        return true;
    }
    return false;
}

void msp_send_reply_v1(uint8_t cmd, const uint8_t *data, uint8_t len) {
    uint8_t crc = 0;
    if (should_trace_msp_cmd(cmd)) {
        debug_msp_frame("MSP <--", '>', cmd, data, len);
    }
    hal_debug_putc(static_cast<uint8_t>(msp::Preamble::Start));
    hal_debug_putc(static_cast<uint8_t>(msp::Preamble::V1));
    hal_debug_putc(static_cast<uint8_t>(msp::Direction::FromFC));
    
    hal_debug_putc(len); crc ^= len;
    hal_debug_putc(cmd); crc ^= cmd;
    
    for (int i = 0; i < len; i++) {
        hal_debug_putc(data[i]);
        crc ^= data[i];
    }
    hal_debug_putc(crc);
}

void msp_send_reply_v2(uint16_t cmd, const uint8_t *data, uint16_t len, uint8_t flags) {
    if (len > sizeof(rx_buf)) {
        len = sizeof(rx_buf);
    }

    if (should_trace_msp_cmd(cmd)) {
        debug_logf("MSP <-- v2 cmd=%d len=%d\r\n", cmd, len);
    }

    hal_debug_putc(static_cast<uint8_t>(msp::Preamble::Start));
    hal_debug_putc(static_cast<uint8_t>(msp::Preamble::V2));
    hal_debug_putc(static_cast<uint8_t>(msp::Direction::FromFC));

    uint8_t crc = 0;

    hal_debug_putc(flags);
    crc = crc8_dvb_s2_update(crc, flags);

    const uint8_t cmd_l = static_cast<uint8_t>(cmd & 0xFFu);
    const uint8_t cmd_h = static_cast<uint8_t>((cmd >> 8) & 0xFFu);
    hal_debug_putc(cmd_l);
    crc = crc8_dvb_s2_update(crc, cmd_l);
    hal_debug_putc(cmd_h);
    crc = crc8_dvb_s2_update(crc, cmd_h);

    const uint8_t len_l = static_cast<uint8_t>(len & 0xFFu);
    const uint8_t len_h = static_cast<uint8_t>((len >> 8) & 0xFFu);
    hal_debug_putc(len_l);
    crc = crc8_dvb_s2_update(crc, len_l);
    hal_debug_putc(len_h);
    crc = crc8_dvb_s2_update(crc, len_h);

    for (uint16_t i = 0; i < len; ++i) {
        const uint8_t b = data ? data[i] : 0;
        hal_debug_putc(b);
        crc = crc8_dvb_s2_update(crc, b);
    }

    hal_debug_putc(crc);
}

void msp_send_reply_v2_in_v1(uint16_t cmd, const uint8_t *data, uint16_t len, uint8_t flags) {
    if (len > sizeof(rx_buf)) {
        len = sizeof(rx_buf);
    }

    // Encapsulated MSPv2 payload layout (inside MSPv1 cmd=255):
    // [flags][cmd_l][cmd_h][len_l][len_h][payload...][v2_crc]
    const uint16_t inner_size = static_cast<uint16_t>(6u + len);
    uint8_t v1_crc = 0;

    hal_debug_putc(static_cast<uint8_t>(msp::Preamble::Start));
    hal_debug_putc(static_cast<uint8_t>(msp::Preamble::V1));
    hal_debug_putc(static_cast<uint8_t>(msp::Direction::FromFC));

    hal_debug_putc(static_cast<uint8_t>(inner_size));
    v1_crc ^= static_cast<uint8_t>(inner_size);

    hal_debug_putc(static_cast<uint8_t>(MspV2InV1Cmd & 0xFFu));
    v1_crc ^= static_cast<uint8_t>(MspV2InV1Cmd & 0xFFu);

    uint8_t v2_crc = 0;

    hal_debug_putc(flags);
    v1_crc ^= flags;
    v2_crc = crc8_dvb_s2_update(v2_crc, flags);

    const uint8_t cmd_l = static_cast<uint8_t>(cmd & 0xFFu);
    const uint8_t cmd_h = static_cast<uint8_t>((cmd >> 8) & 0xFFu);
    hal_debug_putc(cmd_l);
    v1_crc ^= cmd_l;
    v2_crc = crc8_dvb_s2_update(v2_crc, cmd_l);
    hal_debug_putc(cmd_h);
    v1_crc ^= cmd_h;
    v2_crc = crc8_dvb_s2_update(v2_crc, cmd_h);

    const uint8_t len_l = static_cast<uint8_t>(len & 0xFFu);
    const uint8_t len_h = static_cast<uint8_t>((len >> 8) & 0xFFu);
    hal_debug_putc(len_l);
    v1_crc ^= len_l;
    v2_crc = crc8_dvb_s2_update(v2_crc, len_l);
    hal_debug_putc(len_h);
    v1_crc ^= len_h;
    v2_crc = crc8_dvb_s2_update(v2_crc, len_h);

    for (uint16_t i = 0; i < len; ++i) {
        const uint8_t b = data ? data[i] : 0;
        hal_debug_putc(b);
        v1_crc ^= b;
        v2_crc = crc8_dvb_s2_update(v2_crc, b);
    }

    hal_debug_putc(v2_crc);
    v1_crc ^= v2_crc;

    hal_debug_putc(v1_crc);
}

void msp_send_ack(uint16_t cmd, bool is_v2, uint8_t v2_flags) {
    if (is_v2) {
        msp_send_reply_v2(cmd, nullptr, 0, v2_flags);
    } else {
        msp_send_reply_v1(static_cast<uint8_t>(cmd & 0xFFu), nullptr, 0);
    }
}

void msp_send_reply_auto(uint16_t cmd,
                         const uint8_t *data,
                         uint16_t len,
                         bool is_v2,
                         uint8_t v2_flags,
                         bool v2_in_v1) {
    if (is_v2) {
        if (v2_in_v1) {
            msp_send_reply_v2_in_v1(cmd, data, len, v2_flags);
        } else {
            msp_send_reply_v2(cmd, data, len, v2_flags);
        }
    } else {
        msp_send_reply_v1(static_cast<uint8_t>(cmd & 0xFFu), data, static_cast<uint8_t>(len & 0xFFu));
    }
}

static bool handle_query_command(uint16_t cmd_raw,
                                 const uint8_t *payload,
                                 uint16_t len,
                                 bool is_v2,
                                 uint8_t v2_flags,
                                 bool v2_in_v1,
                                 uint8_t *reply,
                                 uint16_t *rlen) {
    const uint16_t cmd = static_cast<uint16_t>(cmd_raw);
    if (!reply || !rlen) {
        return false;
    }

    switch (cmd) {
        case MspSetDebugLevelCmd:
            if (len > 0 && payload) {
                const uint8_t requested = payload[0];
                if (requested <= static_cast<uint8_t>(msp::DebugLevel::Verbose)) {
                    g_debug_level = requested;
                }
            }
            reply[0] = g_debug_level;
            msp_send_reply_auto(cmd_raw, reply, 1, is_v2, v2_flags, v2_in_v1);
            return true;

        case static_cast<uint16_t>(msp::Command::ApiVersion):
            *rlen = 0;
            reply[(*rlen)++] = 0;
            reply[(*rlen)++] = msp::ApiVersionMajor;
            reply[(*rlen)++] = msp::ApiVersionMinor;
            msp_send_reply_auto(cmd_raw, reply, *rlen, is_v2, v2_flags, v2_in_v1);
            return true;

        case static_cast<uint16_t>(msp::Command::FcVariant):
            memcpy(reply, msp::FcId, 4);
            msp_send_reply_auto(cmd_raw, reply, 4, is_v2, v2_flags, v2_in_v1);
            return true;

        case static_cast<uint16_t>(msp::Command::FcVersion):
            *rlen = 0;
            reply[(*rlen)++] = 4;
            reply[(*rlen)++] = 5;
            reply[(*rlen)++] = 0;
            msp_send_reply_auto(cmd_raw, reply, *rlen, is_v2, v2_flags, v2_in_v1);
            return true;

        case static_cast<uint16_t>(msp::Command::BoardInfo):
            memcpy(reply, msp::BoardId, 4);
            reply[4] = 0;
            reply[5] = 0;
            msp_send_reply_auto(cmd_raw, reply, 6, is_v2, v2_flags, v2_in_v1);
            return true;

        case static_cast<uint16_t>(msp::Command::BuildInfo):
            memcpy(reply, "Mar 21 202612:00:00", 19);
            msp_send_reply_auto(cmd_raw, reply, 19, is_v2, v2_flags, v2_in_v1);
            return true;

        case static_cast<uint16_t>(msp::Command::FeatureConfig):
            memset(reply, 0, 4);
            msp_send_reply_auto(cmd_raw, reply, 4, is_v2, v2_flags, v2_in_v1);
            return true;

        case static_cast<uint16_t>(msp::Command::Ident):
            memset(reply, 0, 7);
            msp_send_reply_auto(cmd_raw, reply, 7, is_v2, v2_flags, v2_in_v1);
            return true;

        case static_cast<uint16_t>(msp::Command::Name):
            memcpy(reply, "PicoFC", 6);
            msp_send_reply_auto(cmd_raw, reply, 6, is_v2, v2_flags, v2_in_v1);
            return true;

        case static_cast<uint16_t>(msp::Command::Status):
            memset(reply, 0, 22);
            reply[0] = 125;
            reply[1] = 0;
            reply[4] = 0x01;
            reply[15] = 0;
            reply[16] = 0;
            reply[17] = 0x04;
            reply[18] = 0;
            reply[19] = 0;
            reply[20] = 0;
            reply[21] = 0;
            msp_send_reply_auto(cmd_raw, reply, 22, is_v2, v2_flags, v2_in_v1);
            return true;

        case static_cast<uint16_t>(msp::Command::Motor):
        {
            // ESC Configurator discovers connected motor channels by reading
            // MSP_MOTOR and filtering values > 0. If all channels are 0 at
            // startup, only a subset may appear. Report 4 present channels
            // consistently when idle by using a neutral placeholder.
            uint16_t raw[4]{};
            bool any_nonzero = false;
            for (uint8_t i = 0; i < 4; ++i) {
                raw[i] = static_cast<uint16_t>(hal_spi_get_motor_command(i));
                if (raw[i] != 0u) {
                    any_nonzero = true;
                }
            }

            for (uint8_t i = 0; i < 4; ++i) {
                const uint16_t m = any_nonzero ? raw[i] : static_cast<uint16_t>(1000u);
                reply[i * 2u] = static_cast<uint8_t>(m & 0xFFu);
                reply[i * 2u + 1u] = static_cast<uint8_t>((m >> 8) & 0xFFu);
            }
            msp_send_reply_auto(cmd_raw, reply, 8, is_v2, v2_flags, v2_in_v1);
            return true;
        }

        case static_cast<uint16_t>(msp::Command::Rc):
            for (int i = 0; i < 18; i++) {
                uint16_t us = (i < 6) ? hal_pwm_get_us(i) : 1500;
                reply[i * 2] = us & 0xFF;
                reply[i * 2 + 1] = us >> 8;
            }
            msp_send_reply_auto(cmd_raw, reply, 36, is_v2, v2_flags, v2_in_v1);
            return true;

        case static_cast<uint16_t>(msp::Command::Analog):
            reply[0] = 168;
            memset(reply + 1, 0, 6);
            msp_send_reply_auto(cmd_raw, reply, 7, is_v2, v2_flags, v2_in_v1);
            return true;

        case static_cast<uint16_t>(msp::Command::BatteryState):
            memset(reply, 0, 9);
            msp_send_reply_auto(cmd_raw, reply, 9, is_v2, v2_flags, v2_in_v1);
            return true;

        case static_cast<uint16_t>(msp::Command::Uid):
            reply[0] = 'P';
            reply[1] = 'I';
            reply[2] = 'C';
            reply[3] = 'O';
            memset(reply + 4, 0, 8);
            msp_send_reply_auto(cmd_raw, reply, 12, is_v2, v2_flags, v2_in_v1);
            return true;

        default:
            return false;
    }
}

static void handle_set_passthrough_command(uint16_t cmd_raw,
                                           const uint8_t *payload,
                                           uint16_t len,
                                           bool is_v2,
                                           uint8_t v2_flags,
                                           bool v2_in_v1,
                                           uint8_t *reply) {
    if (debug_basic_enabled() && DebugCommandLog) {
        debug_logf("MSP SET_PASSTHROUGH len=%d p0=%d\r\n",
                   len,
                   (len > 0 && payload) ? payload[0] : -1);
    }

    bool enable_passthrough = false;
    uint8_t motor_idx = 0;

    if (len == 0) {
        enable_passthrough = true;
    } else if (len == 1) {
        if (payload[0] == 0xFFu) {
            enable_passthrough = true;
            motor_idx = 0;
        }

        if (!enable_passthrough) {
            const uint8_t v = payload[0];
            const bool mux_sel = (v & 0x01u) != 0;
            const uint8_t mux_ch = static_cast<uint8_t>((v >> 1) & 0x03u);
            const bool msp_mode = (v & 0x08u) != 0;
            if (!msp_mode && !mux_sel) {
                enable_passthrough = true;
                if (!normalize_motor_index(mux_ch, &motor_idx)) {
                    enable_passthrough = false;
                }
            }
        }

        if (!enable_passthrough) {
            uint8_t compat_idx = 0;
            if (normalize_motor_index(payload[0], &compat_idx)) {
                enable_passthrough = true;
                motor_idx = compat_idx;
            }
        }
    } else {
        if (len >= 2 &&
            static_cast<msp::PassthroughMode>(payload[0]) == msp::PassthroughMode::SerialEsc) {
            enable_passthrough = normalize_motor_index(payload[1], &motor_idx);
        }
    }

    if (enable_passthrough) {
        if (esc_passthrough_active()) {
            esc_passthrough_end();
        }
        if (esc_passthrough_begin(motor_idx)) {
            ++g_passthrough_begin_ok_count;
            debug_logf("ESC --> passthrough begin motor=%d ok=1\r\n", motor_idx);
            esc_4way_reset();
            reply[0] = esc_4way_esc_count();
        } else {
            ++g_passthrough_begin_fail_count;
            debug_logf("ESC --> passthrough begin motor=%d ok=0\r\n", motor_idx);
            esc_4way_reset();
            reply[0] = 0;
        }
    } else {
        if (esc_passthrough_active()) {
            esc_passthrough_end();
            debug_puts("ESC --> passthrough end\r\n");
        }
        esc_4way_reset();
        reply[0] = 0;
    }

    if (debug_basic_enabled() && DebugCommandLog) {
        debug_logf("MSP SET_PASSTHROUGH active=%d\r\n", esc_passthrough_active() ? 1 : 0);
    }
    msp_send_reply_auto(cmd_raw, reply, 1, is_v2, v2_flags, v2_in_v1);
}

static void handle_set_motor_command(uint16_t cmd_raw,
                                     const uint8_t *payload,
                                     uint16_t len,
                                     bool is_v2,
                                     uint8_t v2_flags) {
    const uint8_t motor_count = static_cast<uint8_t>(len / 2u);
    const uint8_t count = (motor_count < HAL_MAX_MOTORS) ? motor_count : HAL_MAX_MOTORS;

    MotorOverrideMessage msg{};
    for (uint8_t i = 0; i < count; ++i) {
        const uint16_t value = static_cast<uint16_t>(payload[i * 2u]) |
                               (static_cast<uint16_t>(payload[i * 2u + 1u]) << 8);
        msg.values[i] = value;
    }

    for (uint8_t i = count; i < HAL_MAX_MOTORS; ++i) {
        msg.values[i] = 0;
    }

    if (count > 0) {
        msg.update_us32 = hal_uptime_us();
        motor_override_mailbox = msg;
        motor_override_mailbox_valid = true;
        if (debug_basic_enabled() && DebugCommandLog) {
            debug_logf("MSP SET_MOTOR m0=%d m1=%d\r\n",
                       static_cast<int>(msg.values[0]),
                       static_cast<int>(msg.values[1]));
        }
    }

    msp_send_ack(cmd_raw, is_v2, v2_flags);
}

void msp_process_command(uint16_t cmd_raw,
                         const uint8_t *payload,
                         uint16_t len,
                         bool is_v2,
                         uint8_t v2_flags,
                         bool v2_in_v1 = false) {
    uint8_t reply[64];
    uint16_t rlen = 0;
    auto cmd = static_cast<uint16_t>(cmd_raw);

    if (debug_basic_enabled() && DebugCommandLog) {
        if (is_v2) {
            debug_logf(v2_in_v1 ? "MSP RX v2/v1 cmd=%d len=%d\r\n" : "MSP RX v2 cmd=%d len=%d\r\n",
                       cmd_raw,
                       len);
        } else {
            debug_logf("MSP RX v1 cmd=%d len=%d\r\n", cmd_raw, len);
        }
    }

    if (is_v2) {
        if (should_trace_msp_cmd(cmd_raw)) {
            debug_logf("MSP --> v2 cmd=%d len=%d\r\n", cmd_raw, len);
        }
    } else {
        if (should_trace_msp_cmd(cmd_raw)) {
            debug_msp_frame("MSP -->", '<', static_cast<uint8_t>(cmd_raw & 0xFFu), payload, static_cast<uint8_t>(len & 0xFFu));
        }
    }

    if (handle_query_command(cmd_raw, payload, len, is_v2, v2_flags, v2_in_v1, reply, &rlen)) {
        return;
    }

    switch (cmd) {
        case static_cast<uint16_t>(msp::Command::SetPassthrough):
            handle_set_passthrough_command(cmd_raw, payload, len, is_v2, v2_flags, v2_in_v1, reply);
            break;

        case static_cast<uint16_t>(msp::Command::SetMotor):
            handle_set_motor_command(cmd_raw, payload, len, is_v2, v2_flags);
            break;

        case static_cast<uint16_t>(msp::Command::EepromWrite):
            msp_send_ack(cmd_raw, is_v2, v2_flags);
            break;

        default:
            ++g_unhandled_cmd_count;
            if (debug_verbose_enabled() && DebugVerboseFrames) {
                debug_logf("MSP !! unhandled cmd=%d len=%d\r\n", cmd_raw, len);
            }
            msp_send_ack(cmd_raw, is_v2, v2_flags);
            break;
    }
}

} // namespace

extern "C" {

void msp_init() {
    // hal_init() should already be called by the platform entry point
    parse_state = ParseState::WaitDollar;
    rx_cmd = 0;
    rx_size = 0;
    rx_v2_flags = 0;
    rx_is_v2 = false;
    rx_idx = 0;
    rx_crc = 0;
    rx_v2_crc = 0;
    last_activity_us32 = hal_uptime_us();
    passthrough_last_4way_activity_us32 = last_activity_us32;
    motor_override_mailbox_valid = false;
    esc_passthrough_init();
    esc_4way_reset();
    if (DebugStartupBanner) {
        const uint8_t id = build_id_byte();
        char line[8];
        line[0] = 'b';
        line[1] = 'l';
        line[2] = 'd';
        line[3] = ':';
        line[4] = hex_digit(static_cast<uint8_t>(id >> 4));
        line[5] = hex_digit(id);
        line[6] = '\n';
        line[7] = '\0';
        hal_debug_puts(line);
    }
}

PT_THREAD(msp_task(struct pt *pt)) {
    static uint32_t now_us;
    static uint8_t byte;
    static int c;

    PT_BEGIN(pt);
    while (1) {
        if (esc_passthrough_active()) {
            now_us = hal_uptime_us();
            if (esc_4way_task()) {
                last_activity_us32 = now_us;
                passthrough_last_4way_activity_us32 = now_us;
            } else if (static_cast<uint32_t>(now_us - passthrough_last_4way_activity_us32) >= timing_config::PassthroughIdleExitUs) {
                esc_passthrough_end();
                esc_4way_reset();
                parse_state = ParseState::WaitDollar;
                ++g_passthrough_auto_exit_count;
                if (debug_basic_enabled() && DebugCommandLog) {
                    hal_debug_puts("MSP 4WAY idle timeout -> exit passthrough\r\n");
                }
            }
            PT_YIELD(pt);
            continue;
        }

        PT_WAIT_UNTIL(pt, (c = hal_getc()) != -1);
        
        last_activity_us32 = hal_uptime_us();
        byte = static_cast<uint8_t>(c);

    switch (parse_state) {
        case ParseState::WaitDollar:
            if (byte == static_cast<uint8_t>(msp::Preamble::Start)) {
                rx_is_v2 = false;
                parse_state = ParseState::WaitMOrX;
            }
            break;
        case ParseState::WaitMOrX:
            if (byte == static_cast<uint8_t>(msp::Preamble::V1)) {
                rx_is_v2 = false;
                parse_state = ParseState::WaitDirection;
            } else if (byte == static_cast<uint8_t>(msp::Preamble::V2)) {
                rx_is_v2 = true;
                parse_state = ParseState::WaitDirection;
            } else {
                parse_state = ParseState::WaitDollar;
            }
            break;
        case ParseState::WaitDirection:
            if (byte == static_cast<uint8_t>(msp::Direction::ToFC)) {
                if (rx_is_v2) {
                    parse_state = ParseState::WaitFlagV2;
                } else {
                    parse_state = ParseState::WaitSizeV1;
                }
            } else {
                parse_state = ParseState::WaitDollar;
            }
            break;

        // ---- MSP v1 ----
        case ParseState::WaitSizeV1:
            rx_size = byte; rx_crc = byte; rx_idx = 0;
            parse_state = ParseState::WaitCmdV1;
            break;
        case ParseState::WaitCmdV1:
            rx_cmd = byte; rx_crc ^= byte;
            parse_state = (rx_size > 0) ? ParseState::WaitPayloadV1 : ParseState::WaitCrcV1;
            break;
        case ParseState::WaitPayloadV1:
            rx_buf[rx_idx++] = byte; rx_crc ^= byte;
            if (rx_idx >= rx_size) parse_state = ParseState::WaitCrcV1;
            break;
        case ParseState::WaitCrcV1:
            if (byte == rx_crc) {
                // MSPv2 encapsulated in MSPv1 frame ($M<, cmd=255)
                if (rx_cmd == MspV2InV1Cmd && rx_size >= 6) {
                    const uint8_t v2_flags = rx_buf[0];
                    const uint16_t v2_cmd = static_cast<uint16_t>(rx_buf[1]) |
                                            (static_cast<uint16_t>(rx_buf[2]) << 8);
                    const uint16_t v2_len = static_cast<uint16_t>(rx_buf[3]) |
                                            (static_cast<uint16_t>(rx_buf[4]) << 8);
                    const uint16_t expected = static_cast<uint16_t>(6u + v2_len);
                    if (expected == rx_size && (5u + v2_len) < sizeof(rx_buf)) {
                        const uint8_t *v2_payload = &rx_buf[5];
                        const uint8_t rx_v2_crc_local = rx_buf[5u + v2_len];
                        uint8_t calc_v2_crc = 0;
                        calc_v2_crc = crc8_dvb_s2_update(calc_v2_crc, v2_flags);
                        calc_v2_crc = crc8_dvb_s2_update(calc_v2_crc, static_cast<uint8_t>(v2_cmd & 0xFFu));
                        calc_v2_crc = crc8_dvb_s2_update(calc_v2_crc, static_cast<uint8_t>((v2_cmd >> 8) & 0xFFu));
                        calc_v2_crc = crc8_dvb_s2_update(calc_v2_crc, static_cast<uint8_t>(v2_len & 0xFFu));
                        calc_v2_crc = crc8_dvb_s2_update(calc_v2_crc, static_cast<uint8_t>((v2_len >> 8) & 0xFFu));
                        for (uint16_t i = 0; i < v2_len; ++i) {
                            calc_v2_crc = crc8_dvb_s2_update(calc_v2_crc, v2_payload[i]);
                        }

                        if (calc_v2_crc == rx_v2_crc_local) {
                            msp_process_command(v2_cmd, v2_payload, v2_len, true, v2_flags, true);
                        } else {
                            msp_send_ack(v2_cmd, true, v2_flags);
                        }
                    } else {
                        msp_send_ack(rx_cmd, false, 0);
                    }
                } else {
                    msp_process_command(rx_cmd, rx_buf, rx_size, false, 0);
                }
            } else {
                if (debug_verbose_enabled() && DebugVerboseFrames) {
                    debug_logf("MSP !! crc mismatch cmd=%d rx=0x%02X\r\n", rx_cmd, byte);
                }
                ++g_crc_error_count;
            }
            parse_state = ParseState::WaitDollar;
            break;

        // ---- MSP v2 ----
        case ParseState::WaitFlagV2:
            rx_v2_flags = byte;
            rx_v2_crc = crc8_dvb_s2_update(0, byte);
            parse_state = ParseState::WaitCmdL_V2;
            break;
        case ParseState::WaitCmdL_V2:
            rx_cmd = byte;
            rx_v2_crc = crc8_dvb_s2_update(rx_v2_crc, byte);
            parse_state = ParseState::WaitCmdH_V2;
            break;
        case ParseState::WaitCmdH_V2:
            rx_cmd |= static_cast<uint16_t>(byte) << 8;
            rx_v2_crc = crc8_dvb_s2_update(rx_v2_crc, byte);
            parse_state = ParseState::WaitSizeL_V2;
            break;
        case ParseState::WaitSizeL_V2:
            rx_size = byte;
            rx_v2_crc = crc8_dvb_s2_update(rx_v2_crc, byte);
            parse_state = ParseState::WaitSizeH_V2;
            break;
        case ParseState::WaitSizeH_V2:
            rx_size |= static_cast<uint16_t>(byte) << 8;
            rx_v2_crc = crc8_dvb_s2_update(rx_v2_crc, byte);
            rx_idx = 0;
            if (rx_size > sizeof(rx_buf)) {
                if (debug_verbose_enabled() && DebugVerboseFrames) {
                    debug_logf("MSP !! v2 payload too large cmd=%d len=%d\r\n", rx_cmd, rx_size);
                }
                parse_state = ParseState::WaitDollar;
            } else {
                parse_state = (rx_size > 0) ? ParseState::WaitPayloadV2 : ParseState::WaitCrcV2;
            }
            break;
        case ParseState::WaitPayloadV2:
            rx_buf[rx_idx++] = byte;
            rx_v2_crc = crc8_dvb_s2_update(rx_v2_crc, byte);
            if (rx_idx >= rx_size) parse_state = ParseState::WaitCrcV2;
            break;
        case ParseState::WaitCrcV2:
            if (byte == rx_v2_crc) {
                msp_process_command(rx_cmd, rx_buf, rx_size, true, rx_v2_flags);
            } else {
                if (debug_verbose_enabled() && DebugVerboseFrames) {
                    debug_logf("MSP !! v2 crc mismatch cmd=%d rx=0x%02X\r\n", rx_cmd, byte);
                }
                ++g_v2_crc_error_count;
            }
            parse_state = ParseState::WaitDollar;
        }
        PT_YIELD(pt);
    }
    PT_END(pt);
}

uint32_t msp_get_last_activity_us32() {
    return last_activity_us32;
}

bool msp_passthrough_is_active() {
    return esc_passthrough_active();
}

uint8_t msp_passthrough_motor() {
    return esc_passthrough_motor();
}

bool msp_is_dshot_forced_off() {
    return esc_passthrough_dshot_forced_off();
}

bool msp_dshot_output_allowed() {
    return esc_passthrough_dshot_allowed();
}

bool msp_motor_override_pop_latest(unsigned short *out_values,
                                   unsigned char motor_count,
                                   unsigned int *out_update_us32) {
    if (!out_values || motor_count < HAL_MAX_MOTORS || !motor_override_mailbox_valid) {
        return false;
    }

    for (uint8_t i = 0; i < HAL_MAX_MOTORS; ++i) {
        out_values[i] = motor_override_mailbox.values[i];
    }

    if (out_update_us32) {
        *out_update_us32 = motor_override_mailbox.update_us32;
    }

    if (debug_basic_enabled() && DebugCommandLog) {
        debug_logf("MSP OVR POP m0=%d m1=%d\r\n",
                   static_cast<int>(motor_override_mailbox.values[0]),
                   static_cast<int>(motor_override_mailbox.values[1]));
    }

    motor_override_mailbox_valid = false;

    return true;
}

void msp_set_debug_level(uint8_t level) {
    if (level > static_cast<uint8_t>(msp::DebugLevel::Verbose)) {
        level = static_cast<uint8_t>(msp::DebugLevel::Verbose);
    }
    g_debug_level = level;
}

uint8_t msp_get_debug_level(void) {
    return g_debug_level;
}

uint32_t msp_get_crc_error_count(void) {
    return g_crc_error_count;
}

uint32_t msp_get_v2_crc_error_count(void) {
    return g_v2_crc_error_count;
}

uint32_t msp_get_passthrough_begin_ok_count(void) {
    return g_passthrough_begin_ok_count;
}

uint32_t msp_get_passthrough_begin_fail_count(void) {
    return g_passthrough_begin_fail_count;
}

uint32_t msp_get_passthrough_auto_exit_count(void) {
    return g_passthrough_auto_exit_count;
}

uint32_t msp_get_unhandled_cmd_count(void) {
    return g_unhandled_cmd_count;
}

} // extern "C"
