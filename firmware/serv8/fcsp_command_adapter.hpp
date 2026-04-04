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
    ReadBlock = 0x10,
    WriteBlock = 0x11,
    GetCaps = 0x12,
    Hello = 0x13,
};

enum class LegacyIntent {
    PassthroughEnter,
    PassthroughExit,
    EscScan,
    SetMotorSpeed,
    GetLinkStatus,
    Ping,
    ReadBlock,
    WriteBlock,
    GetCaps,
    Hello,
};

struct FcspCommand {
    uint8_t channel;
    uint8_t op;
    std::vector<uint8_t> payload;
};

inline FcspCommand build_command(
    LegacyIntent intent,
    uint8_t motor_index = 0,
    uint16_t speed = 0,
    uint32_t nonce = 0,
    uint8_t space = 0,
    uint32_t address = 0,
    uint16_t length = 0,
    const std::vector<uint8_t>& data = {},
    uint8_t page = 0,
    uint16_t max_len = 0,
    const std::vector<uint8_t>& hello_tlv = {}
) {
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
        case LegacyIntent::ReadBlock:
            return {
                static_cast<uint8_t>(Channel::Control),
                static_cast<uint8_t>(ControlOp::ReadBlock),
                {
                    space,
                    static_cast<uint8_t>((address >> 24) & 0xFF),
                    static_cast<uint8_t>((address >> 16) & 0xFF),
                    static_cast<uint8_t>((address >> 8) & 0xFF),
                    static_cast<uint8_t>(address & 0xFF),
                    static_cast<uint8_t>((length >> 8) & 0xFF),
                    static_cast<uint8_t>(length & 0xFF)
                }
            };
        case LegacyIntent::WriteBlock: {
            if (data.size() > 0xFFFF) {
                throw std::runtime_error("write data too long");
            }
            std::vector<uint8_t> payload{
                space,
                static_cast<uint8_t>((address >> 24) & 0xFF),
                static_cast<uint8_t>((address >> 16) & 0xFF),
                static_cast<uint8_t>((address >> 8) & 0xFF),
                static_cast<uint8_t>(address & 0xFF),
                static_cast<uint8_t>((data.size() >> 8) & 0xFF),
                static_cast<uint8_t>(data.size() & 0xFF)
            };
            payload.insert(payload.end(), data.begin(), data.end());
            return {
                static_cast<uint8_t>(Channel::Control),
                static_cast<uint8_t>(ControlOp::WriteBlock),
                payload
            };
        }
        case LegacyIntent::GetCaps:
            return {
                static_cast<uint8_t>(Channel::Control),
                static_cast<uint8_t>(ControlOp::GetCaps),
                {page, static_cast<uint8_t>((max_len >> 8) & 0xFF), static_cast<uint8_t>(max_len & 0xFF)}
            };
        case LegacyIntent::Hello: {
            if (hello_tlv.size() > 0xFFFF) {
                throw std::runtime_error("hello tlv too long");
            }
            std::vector<uint8_t> payload{
                static_cast<uint8_t>((hello_tlv.size() >> 8) & 0xFF),
                static_cast<uint8_t>(hello_tlv.size() & 0xFF)
            };
            payload.insert(payload.end(), hello_tlv.begin(), hello_tlv.end());
            return {
                static_cast<uint8_t>(Channel::Control),
                static_cast<uint8_t>(ControlOp::Hello),
                payload
            };
        }
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
