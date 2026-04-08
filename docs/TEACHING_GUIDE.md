# Teaching Guide — Reusable Patterns in `rt-fc-offloader`

This guide exists for two reasons:

1. help engineers review the repo quickly
2. make it easy to lift ideas and small code patterns into nearby designs

The project goal is not only to build one working FCSP offloader. It is also to
show a clean way to combine:

- streaming datapaths
- validated packet pipelines
- device/register buses
- small control-plane CPUs
- block-level verification

If another engineer or another AI reviews this repo, the ideal outcome is:

- they can understand the design without reading every file
- they can find small patterns worth copying
- they can tell where to retarget the edges without rewriting the middle

---

## Fast mental model

Think of the design as two fabrics that meet cleanly:

### 1) Stream fabric

Use AXIS-style valid/ready seams for moving FCSP bytes or payloads through:

- parser
- CRC gate
- router
- FIFOs
- SERV payload bridge
- TX framing path

This is the high-value deterministic datapath.

### 2) Device/register fabric

Use Wishbone-style attachment when the problem is device control or register
access:

- IO windows
- counters/status
- DSHOT mailbox/control
- PWM capture/status
- LED/NeoPixel control

This keeps device logic standard and reusable without forcing a register bus
through the FCSP hot path.

---

## Pattern 1 — AXIS-style byte seam

Use this when bytes move through a pipeline.

```systemverilog
input  logic       s_tvalid,
input  logic [7:0] s_tdata,
output logic       s_tready,

output logic       m_tvalid,
output logic [7:0] m_tdata,
input  logic       m_tready
```

Why it is useful:

- easy to understand
- easy to simulate
- easy to retarget
- easy to connect with FIFOs or wrappers

When to use it:

- parser output
- transport adapters
- simple forwarding blocks

---

## Pattern 2 — AXIS-style frame seam with sideband metadata

Use this when payload bytes travel as one packet/frame and downstream logic
needs header context.

```systemverilog
input  logic        s_frame_tvalid,
input  logic [7:0]  s_frame_tdata,
input  logic        s_frame_tlast,
output logic        s_frame_tready,
input  logic [7:0]  s_frame_version,
input  logic [7:0]  s_frame_channel,
input  logic [7:0]  s_frame_flags,
input  logic [15:0] s_frame_seq,
input  logic [15:0] s_frame_payload_len
```

Why it is useful:

- downstream blocks do not need hidden state
- router can route by channel
- CRC gate can validate without reparsing
- TX logic can rebuild results with enough context

Design rule:

- if a downstream replacement would need to "know something from elsewhere",
  the seam is probably missing metadata.

---

## Pattern 3 — Wrapper-first reuse

When reusing a proven block from an older design:

- keep the proven algorithm or timing core
- add a thin wrapper to match the local interface contract
- avoid rewriting just to make the code look new

Example from this repo:

- `fcsp_crc16_core_xmodem.sv` is the proven CRC logic
- `fcsp_crc16.sv` wraps it as a frame-level CRC block
- `fcsp_crc_gate.sv` reuses that block in the parser → router path

That is usually better than cloning CRC behavior in multiple places.

---

## Pattern 4 — Wishbone for devices, not streams

Wishbone is a good fit when a block behaves like a peripheral.

Use it for:

- register banks
- counters/status blocks
- DSHOT mailbox/control windows
- PWM capture/control windows
- LED/NeoPixel windows

Do **not** use it as the main FCSP byte-stream transport.

Simple mental rule:

- bytes flowing through a pipeline → AXIS-style seam
- software/firmware reading or writing registers → Wishbone

### Teaching note: "pure register writes" hides clocking complexity

For classroom use, emphasize that Wishbone control code should be written as
simple register transactions:

- write address + data
- wait for ACK
- optional readback/verify

No software side should bit-bang protocol timing or count waveform cycles.
Those concerns belong inside dedicated RTL timing engines.

In this repo:

- `wb_led_controller.sv` demonstrates the control-plane side (parameterized
    register semantics via `LED_WIDTH`).
- NeoPixel waveform timing belongs in the dedicated timing path (e.g.
    `wb_neoPx` / `sendPx_axis_flexible`), not in bus/control code.

### How to teach with `docs/TIMING_REPORT.md`

Use the timing report as the bridge between architecture and measured hardware behavior:

- **Control-plane view**: software performs register reads/writes and waits for ACK.
- **Timing-engine view**: RTL blocks produce deterministic sub-microsecond behavior.
- **Evidence view**: post-route FMAX, margin, and worst-path data confirm whether the design still meets timing goals.

A simple classroom flow:

1. Show register-level intent (Wishbone transaction model).
2. Show which RTL block owns timing-critical behavior.
3. Show timing evidence in `TIMING_REPORT.md` (FMAX/margin/worst path).
4. Discuss optimization priorities from worst-path decomposition (logic vs routing).

This keeps students from mixing software control semantics with waveform-generation responsibilities.

---

## Pattern 5 — Small device testbenches

If a block is effectively a device on a register bus, it should get a
device-focused testbench.

Good device-test questions:

- what are the reset values?
- what happens on valid read/write?
- what happens on invalid offset?
- what flags or side effects change?
- what busy/ready behavior must remain deterministic?

This matters because per-device tests make the repo easier to teach and easier
to review.

---

## Pattern 6 — Block-level cocotb tests

Keep tests small and focused.

Good examples already present in this repo:

- parser sync / resync tests
- parser payload length reject test
- top-level CONTROL-path smoke test
- bad CRC drop test before SERV

Useful cocotb structure:

```python
await _reset(dut)
await _drive_usb_bytes(dut, frame)
observed = await _collect_serv_cmd_payload(dut, expected_len)
assert observed == expected_payload
```

Why this works well:

- clear setup
- clear stimulus
- clear observation point
- clear expectation

---

## Pattern 7 — Retarget by changing the edges first

If a future design is "close to this one", change things in this order:

1. transport frontend
2. CPU/control seam
3. IO device wrappers
4. keep parser/CRC/router/FIFO seams stable if possible

This keeps the most valuable deterministic logic reusable.

---

## Reviewer checklist

If you are reviewing a block or proposing a new one, ask:

- Is the block small enough to understand in one sitting?
- Are the interface names obvious?
- Could another engineer lift this pattern into a related design?
- Is the block tested in isolation?
- Does the block hide target-specific assumptions that should live in a wrapper instead?
- If transport or CPU changed, would the middle of the pipeline still hold up?

If the answer to several of those is "no", the design probably needs a cleaner
seam.

---

## Suggested future teaching snippets

As the repo grows, it would be useful to keep adding tiny examples for:

- Wishbone peripheral wrapper
- DSHOT mailbox register block
- TX framer skeleton
- FCSP result/response builder
- FIFO boundary test pattern

The goal is simple: an engineer should be able to copy a small idea without
copying the entire project.

For very short copy-paste examples, see also:

- `docs/PATTERN_SNIPPETS.md`

## Runnable micro-reference now included

The repo now includes a tiny Wishbone peripheral example and cocotb tests:

- RTL: `rtl/fcsp/examples/wb_status_regs.sv`
- Test: `sim/cocotb/test_wb_status_regs_cocotb.py`

Run it with:

```text
cd sim && make test-wb-example-cocotb
```

AXIS micro-reference run command:

- `make -C sim test-axis-example-cocotb`

This is intentionally small so a reviewer can inspect both the peripheral and
its tests quickly.
