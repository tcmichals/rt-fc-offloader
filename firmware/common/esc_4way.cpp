#include "esc_4way.h"

#include "dshot.h"
#include "debug_uart.h"
#include "esc_passthrough.h"
#include "pico/stdlib.h"

#include <cstring>

namespace {

constexpr uint16_t effective_frame_length(uint8_t len_field) {
    return len_field == 0 ? 256u : static_cast<uint16_t>(len_field);
}

constexpr uint8_t kCmdRemoteEscape = 0x2E;
constexpr uint8_t kCmdLocalEscape = 0x2F;

constexpr uint8_t kCmdInterfaceTestAlive = 0x30;
constexpr uint8_t kCmdProtocolGetVersion = 0x31;
constexpr uint8_t kCmdInterfaceGetName = 0x32;
constexpr uint8_t kCmdInterfaceGetVersion = 0x33;
constexpr uint8_t kCmdInterfaceExit = 0x34;
constexpr uint8_t kCmdDeviceReset = 0x35;
constexpr uint8_t kCmdDeviceInitFlash = 0x37;
constexpr uint8_t kCmdDeviceEraseAll = 0x38;
constexpr uint8_t kCmdDevicePageErase = 0x39;
constexpr uint8_t kCmdDeviceRead = 0x3A;
constexpr uint8_t kCmdDeviceWrite = 0x3B;
constexpr uint8_t kCmdDeviceReadEEprom = 0x3D;
constexpr uint8_t kCmdDeviceWriteEEprom = 0x3E;
constexpr uint8_t kCmdInterfaceSetMode = 0x3F;
constexpr uint8_t kCmdDeviceVerify = 0x40;

constexpr uint8_t kAckOk = 0x00;
constexpr uint8_t kAckInvalidCmd = 0x02;
constexpr uint8_t kAckInvalidCrc = 0x03;
constexpr uint8_t kAckVerifyError = 0x04;
constexpr uint8_t kAckInvalidChannel = 0x08;
constexpr uint8_t kAckInvalidParam = 0x09;
constexpr uint8_t kAckGeneralError = 0x0F;

constexpr uint8_t kInterfaceModeSilabs = 1;
constexpr uint8_t kInterfaceModeAtmel = 2;
constexpr uint8_t kInterfaceModeSK = 3;
constexpr uint8_t kInterfaceModeArm = 4;

constexpr uint8_t kProtocolVersion = 108;
constexpr uint8_t kInterfaceVersionHi = 200;
constexpr uint8_t kInterfaceVersionLo = 6;
constexpr char kInterfaceName[] = "Pico4way";

constexpr uint8_t kBootResultSuccess = 0x30;
constexpr uint8_t kBootResultVerifyError = 0xC0;
constexpr uint8_t kBootResultCommandError = 0xC1;
constexpr uint8_t kBootResultCrcError = 0xC2;
constexpr uint8_t kBootResultNone = 0xFF;

constexpr uint8_t kBootCmdRun = 0x00;
constexpr uint8_t kBootCmdProgFlash = 0x01;
constexpr uint8_t kBootCmdEraseFlash = 0x02;
constexpr uint8_t kBootCmdReadFlashSil = 0x03;
constexpr uint8_t kBootCmdVerifyFlashArm = 0x04;
constexpr uint8_t kBootCmdReadEeprom = 0x04;
constexpr uint8_t kBootCmdProgEeprom = 0x05;
constexpr uint8_t kBootCmdReadFlashAtmel = 0x07;
constexpr uint8_t kBootCmdKeepAlive = 0xFD;
constexpr uint8_t kBootCmdSetBuffer = 0xFE;
constexpr uint8_t kBootCmdSetAddress = 0xFF;

constexpr uint32_t kHostArgTimeoutUs = 25000u;
constexpr uint32_t kHostDataTimeoutUs = 10000u;
constexpr uint32_t kHostCrcTimeoutUs = 10000u;

constexpr uint32_t kEscShortTimeoutUs = 5000u;
constexpr uint32_t kEscMediumTimeoutUs = 50000u;
constexpr uint32_t kEscLongTimeoutUs = 300000u;

union DeviceInfo {
    uint8_t bytes[4];
    uint16_t words[2];
    uint32_t dword;
};

struct IoMem {
    uint8_t num_bytes = 0;
    uint8_t flash_addr_h = 0xFF;
    uint8_t flash_addr_l = 0xFF;
    uint8_t *data = nullptr;
};

enum class RxState {
    WaitEscape,
    WaitCmd,
    WaitAddrH,
    WaitAddrL,
    WaitLen,
    WaitPayload,
    WaitCrcHi,
    WaitCrcLo,
};

struct FrameRx {
    RxState state = RxState::WaitEscape;
    uint8_t cmd = 0;
    uint8_t addr_h = 0;
    uint8_t addr_l = 0;
    uint8_t len = 0;
    uint8_t payload[256]{};
    uint16_t crc = 0;
    uint16_t crc_in = 0;
    uint16_t payload_index = 0;
};

static FrameRx g_rx;
static DeviceInfo g_device_info{};
static uint8_t g_current_interface_mode = kInterfaceModeAtmel;
static uint8_t g_requested_interface_mode = kInterfaceModeAtmel;
static constexpr bool Debug4wayTrace = true;

static inline bool time_before_us32(uint32_t a, uint32_t b) {
    return static_cast<int32_t>(a - b) < 0;
}

static uint16_t crc_xmodem_update(uint16_t crc, uint8_t value) {
    crc ^= static_cast<uint16_t>(value) << 8;
    for (int i = 0; i < 8; ++i) {
        if ((crc & 0x8000u) != 0) {
            crc = static_cast<uint16_t>((crc << 1) ^ 0x1021u);
        } else {
            crc = static_cast<uint16_t>(crc << 1);
        }
    }
    return crc;
}

static uint16_t crc_blheli_update(uint16_t crc, uint8_t value) {
    crc ^= value;
    for (int i = 0; i < 8; ++i) {
        if ((crc & 0x0001u) != 0) {
            crc = static_cast<uint16_t>((crc >> 1) ^ 0xA001u);
        } else {
            crc = static_cast<uint16_t>(crc >> 1);
        }
    }
    return crc;
}

static void host_write_byte(uint8_t value) {
    putchar_raw(value);
}

static void host_write_response(uint8_t cmd,
                                uint8_t addr_h,
                                uint8_t addr_l,
                                const uint8_t *payload,
                                uint8_t payload_len_field,
                                uint16_t payload_count,
                                uint8_t ack) {
    uint16_t crc = 0;
    auto emit = [&crc](uint8_t value) {
        host_write_byte(value);
        crc = crc_xmodem_update(crc, value);
    };

    emit(kCmdRemoteEscape);
    emit(cmd);
    emit(addr_h);
    emit(addr_l);
    emit(payload_len_field);
    for (uint16_t i = 0; i < payload_count; ++i) {
        emit(payload[i]);
    }
    emit(ack);
    host_write_byte(static_cast<uint8_t>((crc >> 8) & 0xFFu));
    host_write_byte(static_cast<uint8_t>(crc & 0xFFu));
}

static void reset_frame_rx() {
    g_rx = {};
}

static void esc_drain_rx() {
    uint8_t dummy = 0;
    while (esc_passthrough_read_byte(&dummy)) {
    }
}

static bool esc_read_byte_timeout(uint8_t *out_value, uint32_t timeout_us) {
    const uint32_t deadline = time_us_32() + timeout_us;
    do {
        if (esc_passthrough_read_byte(out_value)) {
            return true;
        }
        tight_loop_contents();
    } while (timeout_us == 0 || time_before_us32(time_us_32(), deadline));
    return false;
}

static void esc_write_buffer(const uint8_t *data, size_t len, bool append_crc) {
    uint16_t crc = 0;
    for (size_t i = 0; i < len; ++i) {
        esc_passthrough_write_byte(data[i]);
        crc = crc_blheli_update(crc, data[i]);
    }

    if (append_crc) {
        esc_passthrough_write_byte(static_cast<uint8_t>(crc & 0xFFu));
        esc_passthrough_write_byte(static_cast<uint8_t>((crc >> 8) & 0xFFu));
    }
}

static bool esc_read_payload(uint8_t *data,
                             uint16_t len,
                             bool expect_crc_and_ack,
                             uint8_t *ack_out,
                             uint32_t timeout_us) {
    uint16_t crc = 0;
    for (uint16_t i = 0; i < len; ++i) {
        if (!esc_read_byte_timeout(&data[i], timeout_us)) {
            if (ack_out) {
                *ack_out = kBootResultNone;
            }
            return false;
        }
        crc = crc_blheli_update(crc, data[i]);
    }

    if (!expect_crc_and_ack) {
        if (ack_out) {
            *ack_out = kBootResultSuccess;
        }
        return true;
    }

    uint8_t crc_lo = 0;
    uint8_t crc_hi = 0;
    uint8_t ack = kBootResultNone;
    if (!esc_read_byte_timeout(&crc_lo, timeout_us) ||
        !esc_read_byte_timeout(&crc_hi, timeout_us) ||
        !esc_read_byte_timeout(&ack, timeout_us)) {
        if (ack_out) {
            *ack_out = kBootResultNone;
        }
        return false;
    }

    const uint16_t received_crc = static_cast<uint16_t>(crc_lo) |
                                  (static_cast<uint16_t>(crc_hi) << 8);
    if (received_crc != crc) {
        ack = kBootResultCrcError;
    }
    if (ack_out) {
        *ack_out = ack;
    }
    return ack == kBootResultSuccess;
}

static uint8_t esc_get_ack(uint32_t timeout_us) {
    uint8_t ack = kBootResultNone;
    if (!esc_read_byte_timeout(&ack, timeout_us)) {
        return kBootResultNone;
    }
    return ack;
}

static bool bl_send_cmd_set_address(const IoMem &mem) {
    if (mem.flash_addr_h == 0xFFu && mem.flash_addr_l == 0xFFu) {
        return true;
    }

    const uint8_t cmd[] = {kBootCmdSetAddress, 0x00, mem.flash_addr_h, mem.flash_addr_l};
    esc_write_buffer(cmd, sizeof(cmd), true);
    return esc_get_ack(kEscShortTimeoutUs) == kBootResultSuccess;
}

static bool bl_send_cmd_set_buffer(const IoMem &mem) {
    uint8_t cmd[] = {kBootCmdSetBuffer, 0x00, 0x00, mem.num_bytes};
    if (mem.num_bytes == 0) {
        cmd[2] = 0x01;
    }

    esc_write_buffer(cmd, sizeof(cmd), true);

    uint8_t unexpected = 0;
    if (esc_read_byte_timeout(&unexpected, 2000u)) {
        return false;
    }

    esc_write_buffer(mem.data, mem.num_bytes == 0 ? 256u : mem.num_bytes, true);
    return esc_get_ack(40000u) == kBootResultSuccess;
}

static bool bl_read_command(uint8_t cmd, IoMem &mem) {
    if (!bl_send_cmd_set_address(mem)) {
        return false;
    }
    const uint8_t read_cmd[] = {cmd, mem.num_bytes};
    esc_write_buffer(read_cmd, sizeof(read_cmd), true);

    uint8_t ack = kBootResultNone;
    return esc_read_payload(mem.data,
                            mem.num_bytes == 0 ? 256u : mem.num_bytes,
                            true,
                            &ack,
                            kEscMediumTimeoutUs);
}

static bool bl_write_command(uint8_t cmd, IoMem &mem, uint32_t timeout_us) {
    if (!bl_send_cmd_set_address(mem) || !bl_send_cmd_set_buffer(mem)) {
        return false;
    }
    const uint8_t write_cmd[] = {cmd, 0x01};
    esc_write_buffer(write_cmd, sizeof(write_cmd), true);
    return esc_get_ack(timeout_us) == kBootResultSuccess;
}

static bool bl_page_erase(IoMem &mem) {
    if (!bl_send_cmd_set_address(mem)) {
        return false;
    }
    const uint8_t cmd[] = {kBootCmdEraseFlash, 0x01};
    esc_write_buffer(cmd, sizeof(cmd), true);
    return esc_get_ack(kEscLongTimeoutUs) == kBootResultSuccess;
}

static uint8_t bl_verify_flash(IoMem &mem) {
    if (!bl_send_cmd_set_address(mem) || !bl_send_cmd_set_buffer(mem)) {
        return kBootResultNone;
    }
    const uint8_t cmd[] = {kBootCmdVerifyFlashArm, 0x01};
    esc_write_buffer(cmd, sizeof(cmd), true);
    return esc_get_ack(40000u);
}

static bool is_atmel_device(const DeviceInfo &info) {
    const uint16_t signature = info.words[0];
    return signature == 0x9307u || signature == 0x930Au || signature == 0x930Fu || signature == 0x940Bu;
}

static bool is_silabs_device(const DeviceInfo &info) {
    return info.words[0] > 0xE800u && info.words[0] < 0xF900u;
}

static bool is_arm_device(const DeviceInfo &info) {
    return info.bytes[1] > 0x00u && info.bytes[1] < 0x90u && info.bytes[0] == 0x06u;
}

static uint8_t detect_interface_mode(const DeviceInfo &info) {
    if (is_silabs_device(info)) {
        return kInterfaceModeSilabs;
    }
    if (is_atmel_device(info)) {
        return kInterfaceModeAtmel;
    }
    if (is_arm_device(info)) {
        return kInterfaceModeArm;
    }
    return 0;
}

static bool bl_connect(DeviceInfo *out_info) {
    static constexpr uint8_t kBootInit[] = {
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x0D, 'B', 'L', 'H', 'e', 'l', 'i', 0xF4, 0x7D,
    };

    for (uint8_t attempt = 0; attempt < 3; ++attempt) {
        esc_drain_rx();

        DeviceInfo candidate{};
        esc_write_buffer(kBootInit, sizeof(kBootInit), false);

        uint8_t raw[8]{};
        uint8_t ack = kBootResultNone;
        if (!esc_read_payload(raw, sizeof(raw), false, &ack, kEscMediumTimeoutUs)) {
            sleep_ms(20);
            continue;
        }

        if (raw[0] != '4' || raw[1] != '7' || raw[2] != '1') {
            sleep_ms(20);
            continue;
        }

        candidate.bytes[2] = raw[3];
        candidate.bytes[1] = raw[4];
        candidate.bytes[0] = raw[5];

        const uint8_t detected_mode = detect_interface_mode(candidate);
        if (detected_mode == 0) {
            sleep_ms(20);
            continue;
        }

        candidate.bytes[3] = detected_mode;
        *out_info = candidate;
        g_current_interface_mode = detected_mode;
        return true;
    }

    return false;
}

static bool normalize_motor_index(uint8_t in_value, uint8_t *out_index) {
    if (!out_index) {
        return false;
    }
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

static bool ensure_selected_motor(uint8_t motor_index) {
    uint8_t normalized = 0;
    if (!normalize_motor_index(motor_index, &normalized)) {
        return false;
    }

    if (!esc_passthrough_active() || esc_passthrough_motor() != normalized) {
        if (esc_passthrough_active()) {
            esc_passthrough_end();
        }
        if (!esc_passthrough_begin(normalized)) {
            return false;
        }
        sleep_ms(20);
    }

    return true;
}

static void handle_frame(uint8_t cmd,
                         uint8_t addr_h,
                         uint8_t addr_l,
                         const uint8_t *payload,
                         uint8_t payload_len_field,
                         bool valid_crc) {
    if (Debug4wayTrace) {
        debug_uart::writef_ts("4WAY RX cmd=%u ah=%u al=%u len=%u crcok=%u\r\n",
                              cmd,
                              addr_h,
                              addr_l,
                              payload_len_field,
                              valid_crc ? 1u : 0u);
    }

    uint8_t ack = valid_crc ? kAckOk : kAckInvalidCrc;
    uint8_t dummy[256]{};
    uint8_t *out_payload = dummy;
    uint8_t out_len_field = 1;
    uint16_t out_count = 1;
    dummy[0] = 0;
    const uint16_t payload_count = effective_frame_length(payload_len_field);

    IoMem io_mem{};
    io_mem.flash_addr_h = addr_h;
    io_mem.flash_addr_l = addr_l;
    io_mem.data = dummy;

    if (valid_crc) {
        switch (cmd) {
            case kCmdInterfaceTestAlive:
                if (g_device_info.bytes[0] != 0) {
                    const uint8_t keep_alive[] = {kBootCmdKeepAlive, 0x00};
                    esc_write_buffer(keep_alive, sizeof(keep_alive), true);
                    if (esc_get_ack(kEscShortTimeoutUs) != kBootResultCommandError) {
                        g_device_info = {};
                        ack = kAckGeneralError;
                    }
                }
                break;

            case kCmdProtocolGetVersion:
                dummy[0] = kProtocolVersion;
                break;

            case kCmdInterfaceGetName:
                out_payload = reinterpret_cast<uint8_t *>(const_cast<char *>(kInterfaceName));
                out_len_field = static_cast<uint8_t>(std::strlen(kInterfaceName));
                out_count = out_len_field;
                break;

            case kCmdInterfaceGetVersion:
                dummy[0] = kInterfaceVersionHi;
                dummy[1] = kInterfaceVersionLo;
                out_len_field = 2;
                out_count = 2;
                break;

            case kCmdInterfaceExit:
                g_device_info = {};
                host_write_response(cmd, addr_h, addr_l, out_payload, out_len_field, out_count, ack);
                if (Debug4wayTrace) {
                    debug_uart::write_ts("4WAY TX cmd=52 ack=0 (exit)\r\n");
                }
                esc_passthrough_end();
                esc_4way_reset();
                return;

            case kCmdInterfaceSetMode:
                if (payload_len_field < 1) {
                    ack = kAckInvalidParam;
                    break;
                }
                if (payload[0] == kInterfaceModeSilabs ||
                    payload[0] == kInterfaceModeAtmel ||
                    payload[0] == kInterfaceModeSK ||
                    payload[0] == kInterfaceModeArm) {
                    g_requested_interface_mode = payload[0];
                    g_current_interface_mode = payload[0];
                } else {
                    ack = kAckInvalidParam;
                }
                break;

            case kCmdDeviceInitFlash:
                g_device_info = {};
                out_payload = g_device_info.bytes;
                out_len_field = 4;
                out_count = 4;
                if (payload_len_field < 1) {
                    ack = kAckInvalidChannel;
                    break;
                }
                if (!ensure_selected_motor(payload[0])) {
                    ack = kAckInvalidChannel;
                    break;
                }
                if (!bl_connect(&g_device_info)) {
                    g_device_info = {};
                    out_payload = g_device_info.bytes;
                    ack = kAckGeneralError;
                    break;
                }
                if (g_requested_interface_mode != 0 &&
                    g_requested_interface_mode != kInterfaceModeSK &&
                    g_requested_interface_mode != g_current_interface_mode) {
                    g_current_interface_mode = g_device_info.bytes[3];
                }
                g_device_info.bytes[3] = g_current_interface_mode;
                out_payload = g_device_info.bytes;
                break;

            case kCmdDeviceReset:
            {
                const uint8_t target_motor = payload_len_field > 0 ? payload[0] : 0;
                if (!ensure_selected_motor(target_motor)) {
                    ack = kAckInvalidChannel;
                    break;
                }
                const uint8_t run_cmd[] = {kBootCmdRun, 0x00};
                esc_write_buffer(run_cmd, sizeof(run_cmd), g_device_info.bytes[0] != 0);
                g_device_info = {};
                if (addr_l == 1u) {
                    esc_passthrough_end();
                    sleep_ms(300);
                    esc_passthrough_begin(target_motor);
                }
                break;
            }

            case kCmdDevicePageErase:
                if (payload_len_field < 1 || g_device_info.bytes[0] == 0) {
                    ack = kAckGeneralError;
                    break;
                }
                if (g_current_interface_mode == kInterfaceModeArm) {
                    io_mem.flash_addr_h = static_cast<uint8_t>(payload[0] << 2);
                    io_mem.flash_addr_l = 0;
                } else if (g_current_interface_mode == kInterfaceModeSilabs ||
                           g_current_interface_mode == kInterfaceModeAtmel) {
                    io_mem.flash_addr_h = static_cast<uint8_t>(payload[0] << 1);
                    io_mem.flash_addr_l = 0;
                } else {
                    ack = kAckInvalidCmd;
                    break;
                }
                if (!bl_page_erase(io_mem)) {
                    ack = kAckGeneralError;
                }
                break;

            case kCmdDeviceRead:
                if (payload_len_field < 1 || g_device_info.bytes[0] == 0) {
                    ack = kAckGeneralError;
                    break;
                }
                io_mem.num_bytes = payload[0];
                io_mem.data = dummy;
                if (!bl_read_command(g_current_interface_mode == kInterfaceModeAtmel ? kBootCmdReadFlashAtmel : kBootCmdReadFlashSil,
                                     io_mem)) {
                    ack = kAckGeneralError;
                    break;
                }
                out_len_field = io_mem.num_bytes;
                out_count = effective_frame_length(io_mem.num_bytes);
                if (payload[0] == 0) {
                    host_write_response(cmd, addr_h, addr_l, dummy, 0, 256, ack);
                    return;
                }
                break;

            case kCmdDeviceReadEEprom:
                if (payload_len_field < 1 || g_device_info.bytes[0] == 0) {
                    ack = kAckGeneralError;
                    break;
                }
                if (g_current_interface_mode != kInterfaceModeAtmel) {
                    ack = kAckInvalidCmd;
                    break;
                }
                io_mem.num_bytes = payload[0];
                io_mem.data = dummy;
                if (!bl_read_command(kBootCmdReadEeprom, io_mem)) {
                    ack = kAckGeneralError;
                    break;
                }
                out_len_field = io_mem.num_bytes;
                out_count = effective_frame_length(io_mem.num_bytes);
                if (payload[0] == 0) {
                    host_write_response(cmd, addr_h, addr_l, dummy, 0, 256, ack);
                    return;
                }
                break;

            case kCmdDeviceWrite:
                if (g_device_info.bytes[0] == 0) {
                    ack = kAckGeneralError;
                    break;
                }
                io_mem.num_bytes = payload_len_field;
                io_mem.data = const_cast<uint8_t *>(payload);
                if (!bl_write_command(kBootCmdProgFlash, io_mem, kEscMediumTimeoutUs)) {
                    ack = kAckGeneralError;
                }
                break;

            case kCmdDeviceWriteEEprom:
                if (g_device_info.bytes[0] == 0) {
                    ack = kAckGeneralError;
                    break;
                }
                if (g_current_interface_mode != kInterfaceModeAtmel) {
                    ack = kAckInvalidCmd;
                    break;
                }
                io_mem.num_bytes = payload_len_field;
                io_mem.data = const_cast<uint8_t *>(payload);
                if (!bl_write_command(kBootCmdProgEeprom, io_mem, kEscLongTimeoutUs)) {
                    ack = kAckGeneralError;
                }
                break;

            case kCmdDeviceVerify:
                if (g_device_info.bytes[0] == 0) {
                    ack = kAckGeneralError;
                    break;
                }
                if (g_current_interface_mode != kInterfaceModeArm) {
                    ack = kAckInvalidCmd;
                    break;
                }
                io_mem.num_bytes = payload_len_field;
                io_mem.data = const_cast<uint8_t *>(payload);
                switch (bl_verify_flash(io_mem)) {
                    case kBootResultSuccess:
                        ack = kAckOk;
                        break;
                    case kBootResultVerifyError:
                        ack = kAckVerifyError;
                        break;
                    default:
                        ack = kAckGeneralError;
                        break;
                }
                break;

            case kCmdDeviceEraseAll:
                ack = kAckInvalidCmd;
                break;

            default:
                ack = kAckInvalidCmd;
                break;
        }
    }

    host_write_response(cmd, addr_h, addr_l, out_payload, out_len_field, out_count, ack);
    if (Debug4wayTrace) {
        debug_uart::writef_ts("4WAY TX cmd=%u ack=%u outLen=%u\r\n",
                              cmd,
                              ack,
                              out_len_field);
    }
}

static void process_host_byte(uint8_t byte) {
    switch (g_rx.state) {
        case RxState::WaitEscape:
            if (byte == kCmdLocalEscape) {
                g_rx.state = RxState::WaitCmd;
                g_rx.crc = crc_xmodem_update(0, byte);
                g_rx.payload_index = 0;
            }
            break;

        case RxState::WaitCmd:
            g_rx.cmd = byte;
            g_rx.crc = crc_xmodem_update(g_rx.crc, byte);
            g_rx.state = RxState::WaitAddrH;
            break;

        case RxState::WaitAddrH:
            g_rx.addr_h = byte;
            g_rx.crc = crc_xmodem_update(g_rx.crc, byte);
            g_rx.state = RxState::WaitAddrL;
            break;

        case RxState::WaitAddrL:
            g_rx.addr_l = byte;
            g_rx.crc = crc_xmodem_update(g_rx.crc, byte);
            g_rx.state = RxState::WaitLen;
            break;

        case RxState::WaitLen:
            g_rx.len = byte;
            g_rx.crc = crc_xmodem_update(g_rx.crc, byte);
            g_rx.payload_index = 0;
            g_rx.state = RxState::WaitPayload;
            break;

        case RxState::WaitPayload:
            g_rx.payload[g_rx.payload_index++] = byte;
            g_rx.crc = crc_xmodem_update(g_rx.crc, byte);
            if (g_rx.payload_index >= effective_frame_length(g_rx.len)) {
                g_rx.state = RxState::WaitCrcHi;
            }
            break;

        case RxState::WaitCrcHi:
            g_rx.crc_in = static_cast<uint16_t>(byte) << 8;
            g_rx.state = RxState::WaitCrcLo;
            break;

        case RxState::WaitCrcLo:
            g_rx.crc_in |= byte;
            handle_frame(g_rx.cmd,
                         g_rx.addr_h,
                         g_rx.addr_l,
                         g_rx.payload,
                         g_rx.len,
                         g_rx.crc == g_rx.crc_in);
            reset_frame_rx();
            break;
    }
}

} // namespace

extern "C" {

void esc_4way_reset(void) {
    reset_frame_rx();
    g_device_info = {};
    g_requested_interface_mode = kInterfaceModeAtmel;
    g_current_interface_mode = kInterfaceModeAtmel;
}

uint8_t esc_4way_esc_count(void) {
    return dshot::MaxMotors;
}

bool esc_4way_task(void) {
    bool had_activity = false;
    int c = getchar_timeout_us(0);
    while (c != PICO_ERROR_TIMEOUT) {
        const uint8_t byte = static_cast<uint8_t>(c);
        const bool in_frame_before = (g_rx.state != RxState::WaitEscape);
        process_host_byte(byte);

        // Count activity only for actual 4-way framing. This avoids keeping
        // passthrough alive forever when normal MSP polling bytes arrive.
        if (in_frame_before || byte == kCmdLocalEscape) {
            had_activity = true;
        }

        c = getchar_timeout_us(0);
    }
    return had_activity;
}

} // extern "C"