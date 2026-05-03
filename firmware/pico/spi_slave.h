#pragma once
#include <stdint.h>
#include <stdbool.h>

/**
 * @brief SPI Slave implementing the WishboneSPI protocol.
 * Using C++ constexpr and enum class for better type safety.
 */

namespace spi {

enum class Command : uint8_t {
    Sync   = 0xDA,
    Read   = 0xA1,
    Write  = 0xA2,
    Pad    = 0x55,
    Ack    = 0xEE
};

enum class Response : uint8_t {
    Read   = 0x21,
    Write  = 0x22
};

namespace reg {
    static constexpr uint32_t Version     = 0x00000100;
    static constexpr uint32_t Motor1      = 0x40000300;
    static constexpr uint32_t Motor2      = 0x40000304;
    static constexpr uint32_t Motor3      = 0x40000308;
    static constexpr uint32_t Motor4      = 0x4000030C;
    static constexpr uint32_t LedCount    = 0x40000400;
    static constexpr uint32_t LedData     = 0x40000500;
    static constexpr uint32_t PwmCh1      = 0x40000600;
    static constexpr uint32_t PwmCh2      = 0x40000604;
    static constexpr uint32_t PwmCh3      = 0x40000608;
    static constexpr uint32_t PwmCh4      = 0x4000060C;
    static constexpr uint32_t PwmCh5      = 0x40000610;
    static constexpr uint32_t PwmCh6      = 0x40000614;
    static constexpr uint32_t Failsafe    = 0x40000620;

    // ESC Passthrough registers
    static constexpr uint32_t EscCtrl     = 0x40000700;
    static constexpr uint32_t EscTx       = 0x40000710;
    static constexpr uint32_t EscRx       = 0x40000720;
    static constexpr uint32_t EscStatus   = 0x40000730;
    static constexpr uint32_t EscExit     = 0x40000740;
}

namespace esc_status {
    // Packed EscStatus layout (little-endian word):
    // byte0: rx_avail (0..255)
    // byte1: flags
    //   bit0 = MSP recently active
    //   bit1 = passthrough active
    //   bit2 = DSHOT forced off
    //   bit3 = DSHOT output allowed
    // byte2: selected passthrough motor index
    // byte3: MSP activity age in ms (saturates at 255)
    static constexpr uint8_t FlagMspActiveRecent   = (1u << 0);
    static constexpr uint8_t FlagPassthroughActive = (1u << 1);
    static constexpr uint8_t FlagDshotForcedOff    = (1u << 2);
    static constexpr uint8_t FlagDshotAllowed      = (1u << 3);
}

} // namespace spi

extern "C" {
    void spi_slave_init(void);
    bool spi_slave_task(void);
    uint32_t spi_get_last_motor_update_us32(void);
    uint16_t spi_get_motor_command(uint8_t motor_index);
}
