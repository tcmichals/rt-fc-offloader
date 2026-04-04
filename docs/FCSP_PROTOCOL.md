# FCSP Protocol Specification (FCSP/1)

**FCSP** = **Flight Controller Switch Protocol**

This is the shared offloader↔flight-controller protocol for both repositories:

- FPGA/offloader implementation: `rt-fc-offloader`
- Python GUI/worker implementation: `python-imgui-esc-configurator`

## Purpose

FCSP is the canonical runtime protocol for this repository.

- FCSP path: deterministic runtime transport with lower control-plane CPU overhead
- MSP/Pico path: optional migration/compatibility context only (not required for implementation progress)

## Layering model (protocol vs physical layer)

FCSP is the **protocol layer** and must remain stable across physical/link transports.

- Same FCSP frame format, channels, op IDs, flags, and result codes
- Different physical layers are allowed underneath

Think of FCSP as `L2.5/L3-like protocol semantics` over interchangeable link layers.

### FCSP/1 approved physical layers

- **Primary**: SPI (offloader ↔ flight-controller)
- **Optional**: UART/USB-CDC/TCP tunnel for simulation, debug, and tooling paths

Rule: changing physical layer must not change FCSP behavior semantics.

## FCSP/1 profile target

- CPU: **SERV 8-bit parallel**
- Clock target: **50 MHz FMAX**
- Transport profile: SPI byte stream on the **offloader↔flight-controller** link (no packet boundary assumptions)
- Parse model: RTL fast-path + lightweight control-plane firmware
- FPGA target philosophy: **small-FPGA-first** (Tang9K-class viability, no large-device assumption)

## Streaming model (not send-and-wait)

FCSP/1 is a **stream protocol**, not a strict lockstep request/reply protocol.

Implications:

- multiple FCSP frames may appear back-to-back on the same wire stream
- command, telemetry, and logging frames may be intermixed in either direction
- receivers must parse continuously and route by channel, not assume one outstanding request only

Design intent:

- enable high-rate runtime traffic without artificial stop-and-wait stalls
- keep CONTROL latency deterministic while allowing background telemetry/log flow
- map naturally to FPGA parser/router/FIFO pipelines and priority TX scheduling

## Link-layer scope (important)

- FCSP/1 over SPI is the primary production profile for the **offloader ↔ flight-controller** path.
- The Python GUI/worker layer should remain feature-intent oriented and transport-agnostic.
- Any GUI-side transport to the offloader process/service is an implementation detail and is not the FCSP/SPI wire contract.

### Cross-transport compatibility requirements

When FCSP runs over non-SPI links (simulation/debug paths), the following must remain identical:

1. byte-accurate FCSP frame format
2. channel IDs and op IDs
3. result/error code meanings
4. passthrough safety/state semantics
5. resynchronization and CRC validation behavior

## Frame format

All multi-byte integers are big-endian.

| Field | Size | Description |
|---|---:|---|
| `sync` | 1 | `0xA5` |
| `version` | 1 | Protocol version, currently `1` |
| `flags` | 1 | Bitfield |
| `channel` | 1 | Logical channel |
| `seq` | 2 | Sequence number (wraps) |
| `payload_len` | 2 | Payload byte length |
| `payload` | N | Channel payload |
| `crc16` | 2 | CRC16/XMODEM over `version..payload` |

Total length = `1 + 1 + 1 + 1 + 2 + 2 + payload_len + 2`.

### FCSP/1 implementation profile limit (current project)

For deterministic buffer sizing in the current offloader profile, implementations in this project use:

- `max_payload_len = 512` bytes

Wire format still uses `u16` `payload_len`, but frames above 512 bytes are rejected by parser/profile policy.

## Flags (FCSP/1)

- `0x01` ACK requested
- `0x02` ACK response
- `0x04` Error indication
- others reserved

## Channel map (FCSP/1)

- `0x01` CONTROL — command/reply control-plane
- `0x02` TELEMETRY — high-rate status stream
- `0x03` FC_LOG — runtime logs/events
- `0x04` DEBUG_TRACE — verbose protocol diagnostics
- `0x05` ESC_SERIAL — passthrough tunnel (MSP/4-way bridge payload)

## SPI transport mapping (FCSP over SPI)

Detailed transport profile:

- `docs/FCSP_SPI_TRANSPORT.md`

FCSP is transport-agnostic at framing level, but FCSP/1 is profiled for SPI.

- Each SPI burst may contain partial frame bytes, one full frame, or multiple concatenated frames.
- The receiver must treat SPI as a byte stream and run the FCSP resynchronization parser.
- Padding is allowed only at burst boundaries, not inside a frame.
- FCSP traffic classes can be intermixed on the wire stream (for example CONTROL requests/replies with `FC_LOG`/`TELEMETRY` frames).
- Recommended host burst behavior at 50 MHz profile:
	- prefer batched transfers with one or more complete frames per burst,
	- avoid tiny single-byte bursts except for debug,
	- keep control latency deterministic via channel priority.

### SPI/FCSP ownership split

- RTL fast-path (`rtl/fcsp/`): sync detect, payload length bound checks, CRC16, channel route, FIFO push/pop.
- SERV control-plane (`firmware/serv8/`): control op handling, policy/state transitions, result code generation.
- Offloader boundary: maps GUI feature-intent commands to FCSP channel+op frames over SPI to the flight controller.

## CONTROL channel operation mapping (FCSP/1)

`channel=0x01` payload begins with `op_id` (1 byte), followed by operation-specific fields.

| op_id | Name | Request payload | Response payload |
|---:|---|---|---|
| `0x01` | `PT_ENTER` | `motor_index:u8` | `result:u8, esc_count:u8` |
| `0x02` | `PT_EXIT` | none | `result:u8` |
| `0x03` | `ESC_SCAN` | `motor_index:u8` | `result:u8, esc_count:u8` |
| `0x04` | `SET_MOTOR_SPEED` | `motor_index:u8, speed:u16` | `result:u8` |
| `0x05` | `GET_LINK_STATUS` | none | `result:u8, flags:u16, rx_drops:u16, crc_err:u16` |
| `0x06` | `PING` | `nonce:u32` | `result:u8, nonce:u32` |
| `0x10` | `READ_BLOCK` | `space:u8, address:u32, len:u16` | `result:u8, len:u16, data:bytes[len]` |
| `0x11` | `WRITE_BLOCK` | `space:u8, address:u32, len:u16, data:bytes[len]` | `result:u8, bytes_written:u16` |
| `0x12` | `GET_CAPS` | none | `result:u8, caps_len:u16, caps_tlv:caps_len bytes` |
| `0x13` | `HELLO` | `client_hello_len:u16, client_hello_tlv:bytes` | `result:u8, hello_len:u16, hello_tlv:bytes` |

`result` codes (`u8`):

- `0x00` OK
- `0x01` INVALID_ARGUMENT
- `0x02` BUSY
- `0x03` NOT_READY
- `0x04` NOT_SUPPORTED
- `0x05` CRC_OR_FRAME_ERROR
- `0x06` INTERNAL_ERROR

### Address space mapping for dynamic read/write

`space` (`u8`) in `READ_BLOCK` / `WRITE_BLOCK`:

- `0x01` FC_REG    — flight-controller control/status register window
- `0x02` ESC_EEPROM — ESC settings/data region
- `0x03` FLASH     — ESC/target flash region
- `0x04` TELEMETRY_SNAPSHOT — sampled telemetry/status blocks
- `0x05..0x7F` reserved for standard future FCSP spaces
- `0x80..0xFF` vendor/project extension spaces

This model enables adding new features without adding a dedicated op for each one.

### Unified IO domains (PWM / DSHOT / LED / NeoPixel)

Use FCSP block operations for all IO domains so clients follow one access pattern:

- discover capabilities/counts via `HELLO` + `GET_CAPS`
- read state via `READ_BLOCK(space, address, len)`
- write commands/config via `WRITE_BLOCK(space, address, len, data)`

Recommended standard `space` assignments:

- `0x10` PWM_IO      — PWM capture/config/state window
- `0x11` DSHOT_IO    — DSHOT command/config/state window
- `0x12` LED_IO      — generic discrete/status LED control
- `0x13` NEO_IO      — NeoPixel/WS2812 strip control and framebuffer windows

These values are part of FCSP/1 profile guidance and should be treated as stable once implemented.

### Dynamic capability discovery (GET_CAPS)

`GET_CAPS` returns TLV records so clients can enable features dynamically.

TLV format in `caps_tlv`:

- `type:u8`
- `len:u8`
- `value:len bytes`

Initial TLV types:

- `0x01` supported `op_id` bitmap/chunk
- `0x02` supported `space` bitmap/chunk
- `0x03` max read block length (`u16`)
- `0x04` max write block length (`u16`)
- `0x05` protocol profile string (UTF-8, e.g. `SERV8-50-SPIPROD`)
- `0x06` feature flags (`u32` bitfield)

Recommended IO discovery TLVs:

- `0x10` pwm_channel_count (`u16`)
- `0x11` dshot_motor_count (`u16`)
- `0x12` led_count (`u16`)
- `0x13` neopixel_count (`u16`)
- `0x14` supported_io_spaces bitmap/chunk

This allows both sides to adapt dynamically (for example, different LED/NeoPixel counts) without GUI protocol redesign.

## Discovery model

FCSP discovery has two layers:

1. **Protocol discovery (required)** via `HELLO` + `GET_CAPS`
2. **Network service discovery (optional)** via mDNS when FCSP is exposed on IP transports

## Shared schema size strategy (keep one schema, keep it small)

Yes — FCSP should use one shared schema across transports, but with a compact profile.

Use this pattern:

1. **Fixed tiny core**: frame header + `op_id` + compact primitive fields
2. **TLV extensions**: optional data only when needed
3. **Capability paging**: do not send giant capability blobs in one response

### Compact profile rules

- Keep common request/response bodies <= 32 bytes when possible.
- Prefer integer enums/bitfields over long strings on wire.
- Return counts/limits first; fetch details on demand.
- Use `GET_CAPS` pagination for large capability sets.

### GET_CAPS pagination

`GET_CAPS` request payload (optional):

- `page:u8` (default `0`)
- `max_len:u16` (default implementation max)

`GET_CAPS` response additional fields:

- `page:u8`
- `has_more:u8` (`0`/`1`)
- `caps_len:u16`
- `caps_tlv:caps_len bytes`

This keeps discovery bounded for low-memory endpoints.

### Schema/version identity

Add a short schema identity TLV in `HELLO`/`GET_CAPS`:

- `schema_id:u16` (e.g. `0x0001` for FCSP/1 core)
- `schema_hash:u32` (optional quick compatibility hash)

Clients should gate optional features by `schema_id` + capability TLVs, not by hardcoded board names.

### 1) Protocol discovery (required)

All FCSP endpoints should support:

- `HELLO` (`op_id=0x13`) for identity/session metadata
- `GET_CAPS` (`op_id=0x12`) for machine-readable feature negotiation

`HELLO` TLV format (`hello_tlv`):

- `type:u8`
- `len:u8`
- `value:len bytes`

Recommended `HELLO` TLVs:

- `0x01` endpoint role (`u8`): `1=offloader`, `2=flight-controller`, `3=sim`
- `0x02` endpoint name (UTF-8), e.g. `fcsp-offloader-01`
- `0x03` protocol family/version string (UTF-8), e.g. `FCSP/1`
- `0x04` profile string (UTF-8), e.g. `SERV8-50-SPIPROD`
- `0x05` instance id (`u32`) boot/session identifier
- `0x06` uptime ms (`u32`)

Notes:

- `HELLO` is link-agnostic and works for SPI and non-SPI transports.
- Unknown TLV types must be ignored (forward compatibility).

### 2) Network service discovery (optional mDNS)

When FCSP is bridged/exposed over IP (TCP/UDP) for tooling/simulation, mDNS may be used.

- Suggested service type: `_fcsp._tcp.local`
- Suggested instance name: `<endpoint-name>._fcsp._tcp.local`
- Suggested TXT records:
	- `proto=FCSP/1`
	- `role=offloader|sim|controller`
	- `profile=SERV8-50-SPIPROD`
	- `caps_hash=<hex>`
	- `build=<short-id>`

Important scope rule:

- mDNS is only for IP-discovery convenience.
- It does **not** replace protocol-level discovery and is not applicable to raw SPI links.

## Functional mapping matrix (MSP/4-way → FCSP)

This matrix is the migration contract for keeping GUI behavior unchanged while transport evolves.

| Feature intent (GUI/worker) | Legacy path | FCSP/1 phase 1 mapping | FCSP/1 phase 2 mapping |
|---|---|---|---|
| Enter passthrough | `MSP_SET_PASSTHROUGH` | `CONTROL/PT_ENTER` | same |
| Exit passthrough | `MSP_SET_PASSTHROUGH` | `CONTROL/PT_EXIT` | same |
| Scan ESCs | `MSP_SET_PASSTHROUGH` scan semantics | `CONTROL/ESC_SCAN` | same |
| Set motor speed | `MSP_SET_MOTOR` | `CONTROL/SET_MOTOR_SPEED` | same |
| Read 4-way identity | 4-way `get_name/get_version` | `ESC_SERIAL` tunnel raw bytes | native `CONTROL` identity ops (optional) |
| Read settings | 4-way `read_eeprom` | `ESC_SERIAL` tunnel raw bytes | native settings read op (optional) |
| Write settings | 4-way `write_eeprom` | `ESC_SERIAL` tunnel raw bytes | native settings write op (optional) |
| Flash firmware | 4-way page erase/write/read/verify | `ESC_SERIAL` tunnel raw bytes | native flash ops (future) |
| Runtime telemetry/logs | MSP/status polling + ad hoc logs | `TELEMETRY` + `FC_LOG` channels | same |

Native phase-2 replacements can use generic block ops:

- settings read/write via `READ_BLOCK/WRITE_BLOCK` with `space=ESC_EEPROM`
- flash page/program/verify flows via block ops with `space=FLASH`
- register-style control/diagnostics via block ops with `space=FC_REG`

### Phase policy

- **Phase 1 (stabilize)**: retain MSP/4-way semantics via `ESC_SERIAL` tunneling where needed.
- **Phase 2 (optimize)**: replace high-frequency or expensive tunneled paths with native CONTROL ops.
- GUI workflows stay stable; only worker transport/protocol adapter changes.

## State mapping requirements

Passthrough ownership and safety behavior must match legacy behavior:

1. DSHOT writes are blocked while passthrough is active.
2. Passthrough activation records active motor index and ESC count.
3. Exit passthrough returns control to motor path cleanly before speed updates resume.
4. Transport errors must map to deterministic result/status events for UI recovery.

## 50 MHz implementation requirements

To hit 50 MHz reliably on SERV-8:

1. RTL handles sync detect, length tracking, CRC16, channel routing
2. SERV interrupts only on complete validated frame or FIFO watermark
3. Deep RX/TX FIFOs (target >= 4 KB aggregate)
4. Avoid per-byte ISR handling
5. Host batches small control messages when possible

## Resynchronization rules

Receiver behavior:

1. Search for `0xA5`
2. Parse header and validate `payload_len` cap
3. Wait for full frame bytes
4. Verify CRC16
5. On failure: advance by one byte and continue scan

## Migration policy

- Keep MSP functional during GUI parity validation
- Add FCSP adapter in Python worker without changing GUI workflow
- Move runtime traffic channel-by-channel from MSP to FCSP
- Keep passthrough safety/ownership constraints unchanged

## Versioning

- Family name: `FCSP`
- Version tag: `FCSP/1`
- Future incompatible change: bump version field
