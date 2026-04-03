# FCSP Protocol Specification (FCSP/1)

**FCSP** = **Flight Controller Switch Protocol**

This is the shared offloader↔flight-controller protocol for both repositories:

- FPGA/offloader implementation: `rt-fc-offloader`
- Python GUI/worker implementation: `python-imgui-esc-configurator`

## Purpose

FCSP replaces MSP for high-rate runtime traffic while preserving MSP-compatible workflows during migration.

- MSP path: feature validation, compatibility, and bring-up
- FCSP path: deterministic runtime transport and lower CPU overhead

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

FCSP is transport-agnostic at framing level, but FCSP/1 is profiled for SPI.

- Each SPI burst may contain partial frame bytes, one full frame, or multiple concatenated frames.
- The receiver must treat SPI as a byte stream and run the FCSP resynchronization parser.
- Padding is allowed only at burst boundaries, not inside a frame.
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
