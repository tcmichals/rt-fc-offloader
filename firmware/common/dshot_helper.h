#ifndef DSHOT_HELPER_H
#define DSHOT_HELPER_H

#include <stdint.h>

inline uint16_t dshot_prepare_packet(uint16_t throttle, bool telemetry) {
    // DShot throttle range: 0 (stop), 48..2047 (throttle).
    // Clip to 11 bits.
    throttle &= 0x07FF;
    
    // Packet: [Throttle (11 bits)] [Telemetry (1 bit)]
    uint16_t packet = (throttle << 1) | (telemetry ? 1 : 0);
    
    // Checksum: XOR groups of 4 bits
    uint16_t checksum = (packet ^ (packet >> 4) ^ (packet >> 8)) & 0x0F;
    
    // Final 16-bit packet: [Packet (12 bits)] [Checksum (4 bits)]
    return (packet << 4) | checksum;
}

#endif // DSHOT_HELPER_H
