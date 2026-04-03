# FCSP SPI Transport Profile (FCSP/1)

This document defines how FCSP frames are carried over SPI for the offloader↔flight-controller link.

## Why this exists

SPI is **synchronous**: bytes are clocked in/out with no native packet boundaries.

FCSP therefore treats SPI as a byte stream and provides packet framing at the protocol layer (`sync`, header, CRC).

## Transport model

- Link type: SPI slave/device receives bursts from SPI master/host.
- Unit on wire: bytes clocked synchronously with SCLK.
- FCSP framing: independent of SPI burst boundaries.

Meaning:

- one SPI burst may contain partial FCSP frame,
- one burst may contain exactly one frame,
- one burst may contain multiple concatenated frames.

## RX behavior requirements

Receiver parser must:

1. scan byte stream for FCSP sync (`0xA5`)
2. parse fixed header (`version, flags, channel, seq, payload_len`)
3. enforce implementation payload cap (`max_payload_len = 512`)
4. wait for full `payload + crc16`
5. verify CRC16/XMODEM over `version..payload`
6. on failure, advance by one byte and resynchronize

## TX behavior requirements

- TX path emits complete FCSP frames as byte stream.
- Bursting policy should prefer complete-frame batching for efficiency.
- CONTROL channel traffic should receive highest scheduler/mux priority.

## Dummy/pad byte behavior (implementation detail)

Because SPI is full-duplex and synchronous, a master must keep clocking bytes to receive reply bytes.

Implementations MAY use dummy/pad bytes during SPI bursts to:

- prime internal bus transactions (for example, Wishbone read/write startup latency),
- continue clocking while waiting for response bytes,
- flush/align transport-shim FIFOs.

Important scope rule:

- Dummy/pad bytes are **transport-shim behavior**, not FCSP wire semantics.
- FCSP frame definition remains unchanged (`sync/header/payload/crc16`) and must not encode a required pad byte value.

Compatibility note for legacy bridges:

- Older SPI/Wishbone bridges may emit first reply bytes with a one-byte pipeline offset and consume explicit pad patterns.
- This is acceptable inside the SPI bridge layer as long as the FCSP parser interface sees a clean byte stream and standard FCSP frames.

## Framing and buffering profile limits

- FCSP wire field `payload_len`: `u16` (wire-format capability)
- Project profile cap: `512` bytes per FCSP payload
- Frame byte count:

$$
\text{frame\_len} = 1 + 1 + 1 + 1 + 2 + 2 + \text{payload\_len} + 2
$$

With profile cap (`payload_len=512`), maximum FCSP frame size is:

$$
1+1+1+1+2+2+512+2 = 522\ \text{bytes}
$$

## Mode and signal expectations

Unless board-specific constraints require otherwise, use one fixed SPI mode consistently across both endpoints (profile recommendation: Mode 0).

Regardless of chosen mode, FCSP semantics do not change.

## Error/accounting guidance

Maintain counters for:

- CRC failures
- length-limit rejects
- sync-loss/resync events
- FIFO overflow/drop events

Expose counters via CONTROL `GET_LINK_STATUS` and/or diagnostics channels.

## Ownership split reminder

- RTL fast path: SPI byte ingest, parser, CRC, router, FIFO handling
- SERV control plane: validated frame handling, op dispatch, policy/result codes

SERV should not parse raw SPI bytes in the hot path.
