#include "spi_slave.h"
#include "dshot.h"
#include "msp.h"
#include "esc_passthrough.h"
#include "neopixel.h"
#include "pwm_decode.h"
#include "pico/stdlib.h"
#include "pico/types.h"
#include "hardware/spi.h"
#include "hardware/gpio.h"
#include <stdint.h>
#include <cstdint>
#include <cstring>

namespace {

// Hardware SPI0 wired as Slave to Pi Zero 2W
static spi_inst_t* const SpiPort = spi0;
static constexpr uint PinMiso = 19;
static constexpr uint PinCs   = 17;
static constexpr uint PinSck  = 18;
static constexpr uint PinMosi = 16;

enum class State {
    Sync,
    LenL,
    LenH,
    Addr0,
    Addr1,
    Addr2,
    Addr3,
    Data,
};

static State    state    = State::Sync;
static uint8_t  cmd;
static uint16_t length;
static uint32_t addr;
static uint16_t data_idx;
static uint8_t  data_buf[256];
static volatile uint32_t last_motor_update_us32 = 0;
static volatile uint16_t motor_command[dshot::MaxMotors] = {0, 0, 0, 0};

static constexpr uint32_t MspActiveRecentWindowUs = 500000u;
static constexpr uint8_t EscRxFifoSize = 64;
static uint8_t esc_rx_fifo[EscRxFifoSize] = {};
static uint8_t esc_rx_head = 0;
static uint8_t esc_rx_tail = 0;

static inline uint8_t esc_rx_count() {
    return static_cast<uint8_t>(esc_rx_head - esc_rx_tail);
}

static inline bool esc_rx_push(uint8_t value) {
    if (esc_rx_count() >= EscRxFifoSize) {
        return false;
    }
    esc_rx_fifo[esc_rx_head % EscRxFifoSize] = value;
    ++esc_rx_head;
    return true;
}

static inline bool esc_rx_pop(uint8_t *out_value) {
    if (!out_value || esc_rx_count() == 0) {
        return false;
    }
    *out_value = esc_rx_fifo[esc_rx_tail % EscRxFifoSize];
    ++esc_rx_tail;
    return true;
}

static void esc_rx_pump() {
    if (!esc_passthrough_active()) {
        return;
    }
    uint8_t b = 0;
    while (esc_rx_count() < EscRxFifoSize && esc_passthrough_read_byte(&b)) {
        if (!esc_rx_push(b)) {
            break;
        }
    }
}

static bool normalize_motor_index(uint8_t in_value, uint8_t *out_index) {
    if (!out_index) return false;
    if (in_value < dshot::MaxMotors) {
        *out_index = in_value;
        return true;
    }
    if (in_value >= 1 && in_value <= dshot::MaxMotors) {
        *out_index = static_cast<uint8_t>(in_value - 1);
        return true;
    }
    return false;
}

uint32_t reg_read(uint32_t address) {
    esc_rx_pump();

    switch (address) {
        case spi::reg::Version:  return 0xDEADBEEF;
        case spi::reg::PwmCh1:   return pwm_get_us(0);
        case spi::reg::PwmCh2:   return pwm_get_us(1);
        case spi::reg::PwmCh3:   return pwm_get_us(2);
        case spi::reg::PwmCh4:   return pwm_get_us(3);
        case spi::reg::PwmCh5:   return pwm_get_us(4);
        case spi::reg::PwmCh6:   return pwm_get_us(5);
        case spi::reg::Failsafe: {
            uint32_t mask = 0;
            for (int i = 0; i < 6; i++) {
                if (pwm_is_failsafe(i)) mask |= (1u << i);
            }
            return mask;
        }
        case spi::reg::EscStatus: {
            const bool passthrough_active = esc_passthrough_active();
            const bool dshot_forced_off = msp_is_dshot_forced_off();
            const bool dshot_allowed = msp_dshot_output_allowed();
            const uint8_t motor = msp_passthrough_motor();
            const uint8_t rx_avail = esc_rx_count();

            const uint32_t age_us = static_cast<uint32_t>(time_us_32() - msp_get_last_activity_us32());
            const uint8_t age_ms = static_cast<uint8_t>((age_us >= 255000u) ? 0xFFu : (age_us / 1000u));
            const bool msp_active_recent = age_us <= MspActiveRecentWindowUs;

            uint8_t flags = 0;
            if (msp_active_recent) flags |= spi::esc_status::FlagMspActiveRecent;
            if (passthrough_active) flags |= spi::esc_status::FlagPassthroughActive;
            if (dshot_forced_off) flags |= spi::esc_status::FlagDshotForcedOff;
            if (dshot_allowed) flags |= spi::esc_status::FlagDshotAllowed;

            return static_cast<uint32_t>(rx_avail) |
                   (static_cast<uint32_t>(flags) << 8) |
                   (static_cast<uint32_t>(motor) << 16) |
                   (static_cast<uint32_t>(age_ms) << 24);
        }
        case spi::reg::EscRx: {
            uint8_t b0 = 0, b1 = 0, b2 = 0, b3 = 0;
            esc_rx_pop(&b0);
            esc_rx_pop(&b1);
            esc_rx_pop(&b2);
            esc_rx_pop(&b3);
            return static_cast<uint32_t>(b0) |
                   (static_cast<uint32_t>(b1) << 8) |
                   (static_cast<uint32_t>(b2) << 16) |
                   (static_cast<uint32_t>(b3) << 24);
        }
        default: return 0xCAFEBABE;
    }
}

void reg_write(uint32_t address, const uint8_t *data, uint16_t len) {
    if (len < 4) return;
    uint32_t value = data[0] | (static_cast<uint32_t>(data[1]) << 8) |
                    (static_cast<uint32_t>(data[2]) << 16) |
                    (static_cast<uint32_t>(data[3]) << 24);
    bool motor_write = false;

    switch (address) {
        case spi::reg::Motor1: motor_command[0] = static_cast<uint16_t>(value); motor_write = true; break;
        case spi::reg::Motor2: motor_command[1] = static_cast<uint16_t>(value); motor_write = true; break;
        case spi::reg::Motor3: motor_command[2] = static_cast<uint16_t>(value); motor_write = true; break;
        case spi::reg::Motor4: motor_command[3] = static_cast<uint16_t>(value); motor_write = true; break;
        case spi::reg::EscCtrl: {
            const uint8_t requested_motor = data[0];
            uint8_t motor_index = 0;
            if (esc_passthrough_active()) {
                esc_passthrough_end();
            }
            esc_rx_head = 0;
            esc_rx_tail = 0;
            if (normalize_motor_index(requested_motor, &motor_index)) {
                dshot_force_stop_all();
                esc_passthrough_begin(motor_index);
            }
            break;
        }
        case spi::reg::EscTx:
            if (esc_passthrough_active()) {
                for (uint16_t i = 0; i < len; ++i) {
                    esc_passthrough_write_byte(data[i]);
                }
            }
            break;
        case spi::reg::EscExit:
            if (data[0] == 0x01u && esc_passthrough_active()) {
                esc_passthrough_end();
            }
            break;
        case spi::reg::LedData: {
            uint num = len / 4;
            for (uint i = 0; i < num && i < NEOPIXEL_COUNT; i++) {
                neopixel_set(i, data[i*4], data[i*4+1], data[i*4+2], data[i*4+3]);
            }
            neopixel_show();
            break;
        }
        default: break;
    }

    if (motor_write) {
        last_motor_update_us32 = time_us_32();
        // DSHOT transmission is centralized in main.cpp so passthrough gating
        // and MSP motor override priority are enforced in one place.
    }
}

uint8_t spi_process_byte(uint8_t rx) {
    switch (state) {
        case State::Sync:
            if (rx == static_cast<uint8_t>(spi::Command::Read) || rx == static_cast<uint8_t>(spi::Command::Write)) {
                cmd = rx;
                state = State::LenL;
            }
            return static_cast<uint8_t>(spi::Command::Sync);

        case State::LenL:
            length = rx;
            state = State::LenH;
            return (cmd == static_cast<uint8_t>(spi::Command::Read)) ? static_cast<uint8_t>(spi::Response::Read) : static_cast<uint8_t>(spi::Response::Write);

        case State::LenH:
            length |= (static_cast<uint16_t>(rx) << 8);
            state = State::Addr0;
            return static_cast<uint8_t>(length & 0xFF);

        case State::Addr0:
            addr = rx;
            state = State::Addr1;
            return static_cast<uint8_t>((length >> 8) & 0xFF);

        case State::Addr1:
            addr |= (static_cast<uint32_t>(rx) << 8);
            state = State::Addr2;
            return static_cast<uint8_t>(addr & 0xFF);

        case State::Addr2:
            addr |= (static_cast<uint32_t>(rx) << 16);
            state = State::Addr3;
            return static_cast<uint8_t>((addr >> 8) & 0xFF);

        case State::Addr3:
            addr |= (static_cast<uint32_t>(rx) << 24);
            state = State::Data;
            data_idx = 0;
            std::memset(data_buf, 0, sizeof(data_buf));
            return static_cast<uint8_t>((addr >> 16) & 0xFF);

        case State::Data: {
            uint8_t tx;
            if (cmd == static_cast<uint8_t>(spi::Command::Read)) {
                uint32_t val = reg_read(addr + (data_idx & ~3u));
                tx = (val >> ((data_idx & 3) * 8)) & 0xFF;
                if (data_idx == 0) tx = static_cast<uint8_t>((addr >> 24) & 0xFF);
            } else {
                if (data_idx < sizeof(data_buf)) data_buf[data_idx] = rx;
                tx = (data_idx == 0) ? static_cast<uint8_t>((addr >> 24) & 0xFF) : static_cast<uint8_t>(spi::Command::Ack);
            }
            data_idx++;
            if (rx == static_cast<uint8_t>(spi::Command::Sync) || data_idx >= length + 1) {
                if (cmd == static_cast<uint8_t>(spi::Command::Write) && data_idx >= length + 1) reg_write(addr, data_buf, length);
                state = State::Sync;
            }
            return tx;
        }
        default: state = State::Sync; return static_cast<uint8_t>(spi::Command::Sync);
    }
}

} // namespace

extern "C" {

void spi_slave_init() {
    spi_init(SpiPort, 10 * 1000 * 1000);
    spi_set_slave(SpiPort, true);
    spi_set_format(SpiPort, 8, SPI_CPOL_0, SPI_CPHA_0, SPI_MSB_FIRST);
    gpio_set_function(PinMiso, GPIO_FUNC_SPI);
    gpio_set_function(PinCs,   GPIO_FUNC_SPI);
    gpio_set_function(PinSck,  GPIO_FUNC_SPI);
    gpio_set_function(PinMosi, GPIO_FUNC_SPI);
    state = State::Sync;
    last_motor_update_us32 = time_us_32();
}

bool spi_slave_task() {
    if (!spi_is_readable(SpiPort)) return false;
    uint8_t rx;
    spi_read_blocking(SpiPort, 0, &rx, 1);
    uint8_t tx = spi_process_byte(rx);
    spi_write_blocking(SpiPort, &tx, 1);
    return true;
}

uint32_t spi_get_last_motor_update_us32() {
    return last_motor_update_us32;
}

uint16_t spi_get_motor_command(uint8_t motor_index) {
    return (motor_index < dshot::MaxMotors) ? motor_command[motor_index] : 0;
}

} // extern "C"
