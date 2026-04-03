#pragma once

#include <cstdint>
#include <stdexcept>
#include <vector>

namespace fcsp {

enum class Channel : uint8_t {
    Control = 0x01,
};

enum class ControlOp : uint8_t {
    PtEnter = 0x01,
    PtExit = 0x02,
    EscScan = 0x03,
    SetMotorSpeed = 0x04,
    GetLinkStatus = 0x05,
    Ping = 0x06,
};

enum class LegacyIntent {
    PassthroughEnter,
    PassthroughExit,
    EscScan,
    SetMotorSpeed,
    GetLinkStatus,
    Ping,
};

struct FcspCommand {
    uint8_t channel;
    uint8_t op;
    std::vector<uint8_t> payload;
};

inline FcspCommand build_command(LegacyIntent intent, uint8_t motor_index = 0, uint16_t speed = 0, uint32_t nonce = 0) {
    switch (intent) {
        case LegacyIntent::PassthroughEnter:
            return {static_cast<uint8_t>(Channel::Control), static_cast<uint8_t>(ControlOp::PtEnter), {motor_index}};
        case LegacyIntent::PassthroughExit:
            return {static_cast<uint8_t>(Channel::Control), static_cast<uint8_t>(ControlOp::PtExit), {}};
        case LegacyIntent::EscScan:
            return {static_cast<uint8_t>(Channel::Control), static_cast<uint8_t>(ControlOp::EscScan), {motor_index}};
        case LegacyIntent::SetMotorSpeed:
            return {
                static_cast<uint8_t>(Channel::Control),
                static_cast<uint8_t>(ControlOp::SetMotorSpeed),
                {motor_index, static_cast<uint8_t>((speed >> 8) & 0xFF), static_cast<uint8_t>(speed & 0xFF)}
            };
        case LegacyIntent::GetLinkStatus:
            return {static_cast<uint8_t>(Channel::Control), static_cast<uint8_t>(ControlOp::GetLinkStatus), {}};
        case LegacyIntent::Ping:
            return {
                static_cast<uint8_t>(Channel::Control),
                static_cast<uint8_t>(ControlOp::Ping),
                {
                    static_cast<uint8_t>((nonce >> 24) & 0xFF),
                    static_cast<uint8_t>((nonce >> 16) & 0xFF),
                    static_cast<uint8_t>((nonce >> 8) & 0xFF),
                    static_cast<uint8_t>(nonce & 0xFF)
                }
            };
        default:
            throw std::runtime_error("unsupported legacy intent");
    }
}

inline std::vector<uint8_t> build_control_payload(uint8_t op, const std::vector<uint8_t>& body) {
    std::vector<uint8_t> out;
    out.reserve(body.size() + 1);
    out.push_back(op);
    out.insert(out.end(), body.begin(), body.end());
    return out;
}

}  // namespace fcsp
