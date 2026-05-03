#include "dshot.h"
#include "dshot.pio.h"
#include "hardware/clocks.h"
#include "hardware/gpio.h"
#include <vector>

namespace {

struct MotorState {
    uint pin;
    uint sm;
    uint offset;
    bool configured;
};

static MotorState motors[dshot::MaxMotors];
static int32_t outgoing_packet[dshot::MaxMotors];

static constexpr uint motor_pins[dshot::MaxMotors] = {
    static_cast<uint>(dshot::Pin::Motor1),
    static_cast<uint>(dshot::Pin::Motor2),
    static_cast<uint>(dshot::Pin::Motor3),
    static_cast<uint>(dshot::Pin::Motor4)
};

} // namespace

extern "C" {

uint16_t dshot_prepare_packet(uint16_t value, bool request_telemetry) {
    value &= 0x7FF;
    uint16_t packet = (value << 1) | (request_telemetry ? 1 : 0);
    uint16_t crc = (packet ^ (packet >> 4) ^ (packet >> 8)) & 0x0F;
    return (packet << 4) | crc;
}

void dshot_init() {
    // Use a conservative/default DSHOT rate for compatibility.
    // The PIO program bit timing is 40 cycles/bit in dshot.pio.
    // DSHOT300 => 3.333us/bit => clock divider doubles vs DSHOT600.
    static constexpr float DshotBitUs = 3.333333f;
    static constexpr float PioCyclesPerBit = 40.0f;

    uint offset = pio_add_program(dshot::Inst, &dshot_600_program);
    for (int i = 0; i < dshot::MaxMotors; i++) {
        uint pin = motor_pins[i];
        int sm = pio_claim_unused_sm(dshot::Inst, true);
        pio_sm_config config = dshot_600_program_get_default_config(offset);
        sm_config_set_set_pins(&config, pin, 1);
        pio_gpio_init(dshot::Inst, pin);
        pio_sm_set_consecutive_pindirs(dshot::Inst, sm, pin, 1, true);
        // ESC one-wire signal should idle high when line is released.
        gpio_set_pulls(pin, true, false);
        sm_config_set_out_shift(&config, false, false, 32);
        sm_config_set_fifo_join(&config, PIO_FIFO_JOIN_TX);
        float clocks_per_us = static_cast<float>(clock_get_hz(clk_sys)) / 1e6f;
        sm_config_set_clkdiv(&config, DshotBitUs / PioCyclesPerBit * clocks_per_us);
        pio_sm_init(dshot::Inst, sm, offset, &config);
        pio_sm_set_enabled(dshot::Inst, sm, true);
        motors[i] = {pin, static_cast<uint>(sm), offset, true};
        outgoing_packet[i] = -1;
    }
}

void dshot_write(uint8_t motor_index, uint16_t throttle, bool request_telemetry) {
    if (motor_index >= dshot::MaxMotors || !motors[motor_index].configured) return;
    outgoing_packet[motor_index] = dshot_prepare_packet(throttle, request_telemetry);
}

void dshot_update_all() {
    for (int i = 0; i < dshot::MaxMotors; i++) {
        if (outgoing_packet[i] >= 0) {
            // Keep SMs running and feed packets into the TX FIFO.
            // If a SM was previously stopped (e.g. forced-off), re-enable it.
            pio_sm_set_enabled(dshot::Inst, motors[i].sm, true);
            // dshot.pio starts with `out y, 16` to discard the upper half.
            // Keep the 16-bit packet in the lower half of OSR.
            pio_sm_put_blocking(dshot::Inst, motors[i].sm, static_cast<uint32_t>(outgoing_packet[i]));
            outgoing_packet[i] = -1;
        }
    }
}

void dshot_force_stop_all() {
    for (int i = 0; i < dshot::MaxMotors; ++i) {
        if (!motors[i].configured) {
            continue;
        }
        outgoing_packet[i] = -1;
        pio_sm_set_enabled(dshot::Inst, motors[i].sm, false);
    }
}

uint motors_get_sm(uint8_t motor_index) {
    return (motor_index < dshot::MaxMotors) ? motors[motor_index].sm : 0;
}

uint motors_get_pin(uint8_t motor_index) {
    return (motor_index < dshot::MaxMotors) ? motors[motor_index].pin : 0;
}

} // extern "C"
