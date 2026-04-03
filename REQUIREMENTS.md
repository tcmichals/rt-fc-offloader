# rt-fc-offloader Requirements

## Mission

Provide deterministic offloader-side protocol and hardware control paths using FCSP over SPI (primary profile), with support for equivalent FCSP semantics over alternate links when needed.

## Must-have requirements

1. Canonical FCSP ownership in this repo:
   - `docs/FCSP_PROTOCOL.md`
2. 50 MHz SERV-8 profile viability with RTL fast-path offload.
3. RTL handles sync/length/CRC/channel routing/FIFO.
4. SERV handles control policy/state transitions and result codes.
5. Unified dynamic IO model via FCSP block operations:
   - PWM, DSHOT, LED, NeoPixel handled through discoverable spaces.
6. Discovery support:
   - required `HELLO` + `GET_CAPS`
   - optional mDNS for IP-exposed transports.

## Cross-repo contract

- Python repo consumes FCSP as client/adapter.
- FCSP wire changes are made here first, then implemented in companion repo.
- No duplicated FCSP spec files in companion repos.

## Quality gates

- Protocol/frame parser tests pass in simulation.
- Capability/discovery behavior is deterministic and versioned.
- Backward-safe migration path from MSP remains documented.
