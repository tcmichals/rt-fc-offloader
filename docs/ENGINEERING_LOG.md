# Engineering Log

This file is a lightweight running history of what we ran into, what we decided, and what was verified.

Use it for:

- design decisions that should not get lost in chat history
- bring-up discoveries
- protocol/RTL gotchas
- validation milestones
- known pain points and why choices were made

Newest entries should be added near the top.

---

## 2026-04-03 — FCSP stream semantics clarified

- FCSP is a **streaming / multiplexed** protocol, not strict send-and-wait.
- Multiple FCSP frames may appear back-to-back on the wire.
- `CONTROL`, `TELEMETRY`, `FC_LOG`, and `DEBUG_TRACE` traffic may be intermixed.
- This reinforced the architectural direction toward parser → router → FIFO → scheduler style hardware.

Why it matters:

- supports background logs/telemetry without stalling control traffic
- maps well to FPGA stream pipelines and AXIS-style internal handshakes

---

## 2026-04-03 — Parser cocotb failure root cause was testbench sampling phase

- `fcsp_parser` cocotb tests initially reported missing `frame_done` / `len_error` pulses.
- The parser logic itself was close; the testbench was sampling one-cycle pulses at the wrong simulator phase.
- Fix direction: sample outputs in `ReadOnly`, then advance out of read-only phase before driving next inputs.

Why it matters:

- avoids chasing false RTL bugs caused by cocotb scheduling
- establishes a more reliable pattern for future block-level cocotb tests

Validation status:

- parser cocotb tests pass after timing fix
- Python sim tests pass (`15 passed`)

---

## 2026-04-03 — FCSP payload cap fixed at 512 bytes for this profile

- FCSP wire field remains `u16` for `payload_len`.
- Project implementation profile currently caps payloads at `512` bytes.
- Maximum FCSP frame size at this cap is `522` bytes.

Why it matters:

- deterministic buffer sizing
- simpler parser/FIFO sizing in early FPGA implementation

---

## 2026-04-03 — Hot path ownership split settled

- Raw transport byte handling stays in RTL.
- SERV is **not** in the raw SPI byte hot path.
- SERV handles validated CONTROL-plane frames and policy/state transitions.

Why it matters:

- avoids firmware byte-rate bottlenecks
- keeps frame parsing, CRC, and routing deterministic
- allows mixed traffic to continue flowing while control logic runs separately

---

## 2026-04-03 — FPGA architecture differs intentionally from Pico MSP/PIO bring-up path

- Pico/MSP is the quick bring-up and ESC-config validation path.
- That path has already been proven with a **single ESC + motor**.
- FPGA/FCSP target architecture is different by design:
  - stream-oriented and multiplexed
  - parser/router/FIFO based
  - better suited for mixed traffic and deterministic IO timing

Why it matters:

- prevents accidental pressure to make FPGA internals mirror the Pico design
- keeps bring-up path and runtime architecture conceptually separate

See also:

- `docs/FPGA_VS_PICO_PIO_NOTES.md`

---

## 2026-04-03 — Internal interface direction: AXIS-style, not full AXI everywhere

- Decision direction: use AXIS-like valid/ready streams internally.
- Keep external boundaries lightweight (SPI frontend, USB serial shim, SERV seam).
- Do not pull in full AXI infrastructure unless needed for specific IP interop.

Why it matters:

- fits FCSP stream model
- simplifies router/FIFO/TX mux composition
- avoids unnecessary protocol overhead at boundaries
