# Pattern Snippets — Small Reusable Examples

This file is intentionally short and copy-friendly.

Use it when you want a tiny example of a pattern from this repo without reading
through a full module.

---

## 1) AXIS-style byte seam

Use when bytes flow through a simple pipeline.

```systemverilog
input  logic       s_tvalid,
input  logic [7:0] s_tdata,
output logic       s_tready,

output logic       m_tvalid,
output logic [7:0] m_tdata,
input  logic       m_tready
```

Good for:

- transport adapters
- simple byte forwarding blocks
- small buffered stream stages

---

## 2) AXIS-style frame seam

Use when payload bytes travel with metadata.

```systemverilog
input  logic        s_frame_tvalid,
input  logic [7:0]  s_frame_tdata,
input  logic        s_frame_tlast,
output logic        s_frame_tready,
input  logic [7:0]  s_frame_channel,
input  logic [7:0]  s_frame_flags,
input  logic [15:0] s_frame_seq,
input  logic [15:0] s_frame_payload_len
```

Good for:

- parser to CRC gate
- CRC gate to router
- router to FIFO

---

## 3) Wrapper-first reuse pattern

Use when you have a proven older block and want to adapt it instead of rewriting it.

```systemverilog
legacy_crc_core u_core (
    .data_in (i_data_byte),
    .crc_in  (crc_reg),
    .crc_out (crc_next)
);
```

Then wrap it with local control logic:

```systemverilog
if (i_frame_start) crc_reg <= 16'h0000;
if (i_data_valid)  crc_reg <= crc_next;
if (i_frame_end)   o_crc_ok <= (crc_next == i_recv_crc);
```

Good for:

- CRC engines
- SPI shifters/frontends
- DSHOT timing cores

---

## 4) Wishbone device rule of thumb

Use Wishbone when the block behaves like a peripheral, not a packet pipeline.

```text
bytes flowing through a pipeline  -> AXIS-style seam
register reads/writes to a device -> Wishbone
```

Good for:

- counters/status blocks
- DSHOT mailbox registers
- PWM capture windows
- LED/NeoPixel control windows

### Copy/paste mental model: pure register writes

```text
1) write register address + data
2) wait for ACK
3) optional readback/verify
```

The software/control side does not manage waveform timing.
Timing/clocking behavior is implemented inside RTL state machines/counters.

---

## 5) Device test questions

For a Wishbone-style peripheral, test:

```text
- reset values
- valid read/write behavior
- invalid offset handling
- ready/busy flags
- side effects after writes
```

This keeps device behavior understandable in isolation.

Runnable reference in this repo:

- `rtl/fcsp/examples/wb_status_regs.sv`
- `sim/cocotb/test_wb_status_regs_cocotb.py`

Runnable AXIS reference in this repo:

- `rtl/fcsp/examples/axis_frame_stage.sv`
- `sim/cocotb/test_axis_frame_stage_cocotb.py`

---

## 6) Simple cocotb test shape

```python
await _reset(dut)
await _drive_usb_bytes(dut, frame)
observed = await _collect_serv_cmd_payload(dut, expected_len)
assert observed == expected_payload
```

Why this is useful:

- easy to read
- easy to debug
- easy to adapt for another block

---

## 7) Retargeting order

When adapting a nearby design, change things in this order:

```text
1. transport frontend
2. CPU/control seam
3. IO device wrappers
4. keep parser/CRC/router/FIFO stable if possible
```

That preserves the most valuable reusable datapath logic.
