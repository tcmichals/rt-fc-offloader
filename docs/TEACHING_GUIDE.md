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

---

## Pattern 8 — Frame-Atomic TX Arbitration

### The problem

Multiple producers inside an FPGA need to send data out a single serial link.
If you naively mux byte-by-byte, you get interleaved garbage: byte 3 of a CTRL
response mixed with byte 1 of a debug trace frame. The receiver cannot parse
either one.

### The solution: frame-atomic grant

The arbiter grants the output to one producer at a time and **holds the grant
until the producer asserts `tlast`** — the end-of-frame marker. This guarantees
each frame exits the FPGA as a contiguous byte sequence.

### How the FCSP arbiter works

```
State: SEL_NONE
  │
  ├─ CTRL valid? ──► SEL_CTRL (grant locked)
  │                     └─ on tlast handshake → SEL_NONE
  ├─ ESC valid? ───► SEL_ESC  (grant locked)
  │                     └─ on tlast handshake → SEL_NONE
  └─ DBG valid? ───► SEL_DBG  (grant locked)
                        └─ on tlast handshake → SEL_NONE
```

While idle (`SEL_NONE`), the arbiter evaluates all inputs every cycle using
**fixed priority**: CTRL > ESC > DBG. The first input with `tvalid` asserted
wins.

Once a grant is issued, the arbiter ignores all other inputs. Only the granted
producer's `tvalid/tdata/tlast` signals are wired to the output. All other
producers see `tready = 0` (stalled).

The grant releases when the output hand-shakes the `tlast` byte:
`tvalid && tready && tlast` all high in the same cycle.

### Why fixed priority instead of round-robin?

In this design:

- **CTRL** responses are latency-critical — the host is waiting for a register
  read reply
- **ESC** serial data has baud-rate constraints — bytes must flow at 19200 bps
  rate
- **Debug** trace is best-effort — a missed frame is acceptable

With short frames (typically 7–17 bytes) at 54 MHz sys_clk, each frame
occupies the arbiter for < 1 µs. Starvation is unlikely in practice.

### The queuing fabric

Each producer has its own elastic buffer before reaching the arbiter:

| Producer | Buffer | Purpose |
|----------|--------|---------|
| CTRL WB master | `fcsp_tx_fifo` (512 deep) | Decouples WB response generation from TX timing |
| ESC UART RX | `fcsp_stream_packetizer` (16 bytes + timeout) | Collects raw UART bytes into frames |
| Debug generator | `fcsp_tx_fifo` (512 deep) | Absorbs bursty probe-change events |

The FIFOs ensure a producer is not stalled by downstream backpressure unless
the buffer is full. Overflow is reported via `o_overflow` status signals.

### Downstream: the framer

After the arbiter, the selected frame enters the `fcsp_tx_framer`, which:

1. Captures all payload bytes into internal memory
2. Emits a complete FCSP wire frame: `sync + header + payload + CRC16`
3. Stalls the arbiter (`s_tready = 0`) during the emit phase

This means the arbiter naturally holds its grant while the framer serializes,
because the `tlast` byte was already consumed during capture.

### Teaching exercise

1. Look at `fcsp_tx_arbiter.sv` — count the states
2. Trace what happens when CTRL and DBG both assert `tvalid` simultaneously
3. What prevents a debug frame from interrupting a CTRL frame mid-stream?
4. What happens if the ESC path never asserts `tlast`? (Answer: arbiter
   deadlocks on `SEL_ESC` — this is why the packetizer has a timeout)

---

## Pattern 9 — RLE Compression for Debug Trace

### What RLE is

Run-Length Encoding (RLE) is one of the simplest lossless compression
techniques. Instead of recording every sample, you record "this value repeated
N times, then the value changed to X."

Traditional logic analyzer capture (no compression):

```
Cycle:  0   1   2   3   4   5   6   7   8   9
Value:  05  05  05  05  05  07  07  07  07  07
Stored: 05  05  05  05  05  07  07  07  07  07   (10 entries)
```

With RLE:

```
Entry 1: repeat=0, data=05    (first appearance, no repeats before)
Entry 2: repeat=4, data=07    (05 held for 4 more cycles, then changed to 07)
Stored: 2 entries instead of 10
```

### Why RLE matters for FPGA trace

FPGA logic runs at MHz speeds. A 54 MHz clock produces 54 million samples per
second. Sending all samples over a low-bandwidth link (SPI at 10 MHz, USB-UART
at 1 Mbaud) is impossible. Most of the time, signals are stable — they change
only at events. RLE exploits this: stable periods cost zero bandwidth.

### Wire format in `wb_ila`

Each RLE entry is 6 bytes:

```
Byte 0: repeat_count[15:8]    (high byte of repeat count)
Byte 1: repeat_count[7:0]     (low byte of repeat count)
Byte 2: probe_data[31:24]     (MSB of new probe value)
Byte 3: probe_data[23:16]
Byte 4: probe_data[15:8]
Byte 5: probe_data[7:0]       (LSB of new probe value)
```

The 16-bit repeat count means one entry can represent up to 65535 consecutive
identical samples. At a 1 MHz sample rate (PRESCALE=53), that covers ~65 ms of
stable signal with a single 6-byte entry.

### Decode walkthrough

Given these raw bytes from the host:

```
00 00 00 00 00 05    → repeat=0, data=0x00000005
00 63 00 00 00 07    → repeat=99, data=0x00000007
03 E7 00 00 00 05    → repeat=999, data=0x00000005
```

Timeline reconstruction:

1. Sample 0: probe = `0x05` (initial capture)
2. Samples 1–99: probe held `0x05` (99 cycles)
3. Sample 100: probe changed to `0x07`
4. Samples 101–1099: probe held `0x07` (999 cycles)
5. Sample 1100: probe changed back to `0x05`

Total: 1100+ samples stored in just 18 bytes.

### When RLE fails

RLE is worst-case when signals toggle every cycle (e.g., a free-running
counter). Every sample generates a new entry with `repeat=0`. Use the
**prescaler** to reduce the sample rate and filter out high-frequency
noise that is not relevant to your debug goal.

### Classroom exercise

1. Set `PRESCALE = 53` (1 MHz sample rate)
2. Enable the ILA via CTRL register write
3. Toggle an LED via Wishbone writes (causes probe changes)
4. Read the RLE frame from the host
5. Decode the entries by hand and reconstruct the timeline
6. Compare: how many bytes would raw capture have required?

---

## Pattern 9 — SPI Slave Operation

### SPI basics for classroom review

SPI (Serial Peripheral Interface) is a synchronous 4-wire bus:

| Wire | Direction (this design) | Purpose |
|------|------------------------|---------|
| SCLK | Master → Slave | Clock signal — master controls timing |
| CS_N | Master → Slave | Chip select (active low) — frames a transaction |
| MOSI | Master → Slave | Data: Master Out, Slave In |
| MISO | Slave → Master | Data: Slave Out, Master In |

### SPI Mode 0 (CPOL=0, CPHA=0)

Both SPI slave implementations in this repo use Mode 0:

- **CPOL=0:** SCLK idles LOW between transfers
- **CPHA=0:** Data is sampled on the **rising** edge of SCLK, shifted on the **falling** edge

```
CS_N:  ‾‾‾\_________________________________/‾‾‾
SCLK:  ____/ ‾ \_ / ‾ \_ / ‾ \_ / ‾ \_ ...
            ↑      ↑      ↑      ↑
         sample  sample  sample  sample (MOSI → slave)
               ↑      ↑      ↑
             shift  shift  shift         (slave → MISO)
```

Bit order: **MSB-first**. The most significant bit is sent/received first.

### The CDC problem

SCLK comes from an external master and is **asynchronous** to the FPGA's
internal clock (`sys_clk = 54 MHz`). Sampling an asynchronous signal directly
risks **metastability** — the flip-flop output can oscillate or settle to an
unpredictable value.

Solution: pass every external signal through a **synchronizer chain** — a
series of flip-flops clocked by `sys_clk`.

This repo has two implementations with different trade-offs:

| Implementation | Sync depth | Glitch filter | Max SCLK |
|----------------|-----------|---------------|----------|
| `fcsp_spi_frontend` | 3-FF | None | 13.5 MHz |
| `spi_slave` | 4-FF | 2-cycle | 6.75 MHz |

### How the 3-FF synchronizer works (`fcsp_spi_frontend`)

```systemverilog
logic [2:0] sclk_sync;
always_ff @(posedge clk)
    sclk_sync <= {sclk_sync[1:0], i_sclk};

wire sclk_rise = (sclk_sync[2:1] == 2'b01);  // detected rising edge
wire sclk_fall = (sclk_sync[2:1] == 2'b10);  // detected falling edge
```

Each clock cycle, the external SCLK value shifts through the chain. After 3
cycles, the value is safely in the `sys_clk` domain. Edge detection compares
the two deepest stages.

### How the 4-FF glitch filter works (`spi_slave`)

```systemverilog
logic [3:0] sclk_sync;
always_ff @(posedge clk)
    sclk_sync <= {sclk_sync[2:0], i_sclk};

wire sclk_rising  = (sclk_sync[3:0] == 4'b0011);
wire sclk_falling = (sclk_sync[3:0] == 4'b1100);
```

This requires the signal to be stable at the old level for 2 cycles *and*
stable at the new level for 2 cycles before declaring an edge. Any brief
noise spike (< 2 sys_clk cycles) is rejected.

### Max SCLK from PLL clock rate

The FPGA PLL generates `sys_clk = 54 MHz` from a 27 MHz crystal.

**3-FF sync (fcsp_spi_frontend):**

Each SCLK half-period must span at least 2 sys_clk cycles for the edge
detector to see the transition:

```
Max SCLK = sys_clk / 4 = 54 MHz / 4 = 13.5 MHz
```

**4-FF glitch filter (spi_slave):**

Each SCLK half-period must span at least 4 sys_clk cycles:

```
Max SCLK = sys_clk / 8 = 54 MHz / 8 = 6.75 MHz
```

**Practical recommendation:** Run the Pico SPI master at 10 MHz or below.
This stays within `fcsp_spi_frontend` limits with margin.

### Full-duplex byte flow

SPI is inherently full-duplex — every SCLK cycle clocks one bit in *and* one
bit out. The slave must have a TX byte ready before CS asserts, or MISO will
shift zeros (padding).

```
Master sends:  [CMD byte] [ADDR byte] [DATA byte] ...
Slave sends:   [pad 0x00] [pad 0x00]  [RESP byte] ...
                                        ↑
                               response appears here
                          (1 byte behind, due to SPI pipeline)
```

The 1-byte TX hold register in `fcsp_spi_frontend` queues the next byte to
send. If software/RTL does not provide a byte in time, the slave sends `0x00`.
This is purely a transport-layer concern — the FCSP protocol layer handles
framing independently.

### Classroom exercise

1. Wire a logic analyzer to SCLK, CS_N, MOSI, MISO
2. Send a known FCSP frame from the Pico
3. Observe: CS_N drops, SCLK toggles, MOSI carries frame bytes MSB-first
4. On MISO: see `0x00` pad bytes (no response queued yet)
5. Send a READ_BLOCK command → observe response bytes appearing on MISO
6. Count SCLK edges per byte (8) and verify bit order

---

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
