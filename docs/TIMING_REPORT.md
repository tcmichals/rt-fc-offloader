# Hardware Timing and Switch-Over Report

This report documents the timing-critical transitions for the **Pure Hardware Switch** architecture, specifically for the DShot-to-Serial transition required for ESC bootloader entry.

## Target: ESC Bootloader Entry Sequence

The BLHeli bootloader (SiLabs/EFM8) requires a specific physical sequence on the signal wire to enter programming mode instead of flight mode.

> **Full bootloader entry sequence and register values:** [DESIGN.md](DESIGN.md) §6
> **ESC bootloader firmware internals:** [BLUEJAY_ESC_ANALYSIS.md](BLUEJAY_ESC_ANALYSIS.md) §9

### Sequence Details (Hardware Level)

| Step | Action | Logic State | Duration |
|------|--------|-------------|----------|
| 1 | Idle / Flight | DShot Pulses | Continuous |
| 2 | **Enable Switch** | Write `0x40000400` ← `0x04` (serial mode, ch 2) | ~18 ns (1 clock) |
| 3 | **Execute Break** | Write `0x40000400` ← `0x14` (force_low=1) | **20–250 ms** |
| 4 | **Release Break** | Write `0x40000400` ← `0x04` (force_low=0) | ~18 ns |
| 5 | **Init Flash** | Send CH 0x05 stream | Immediate |

## Pure Hardware Performance vs. PICO/PIO

### 1. Pin Jitter and Latency
In the previous software-mediated control approach, the "Break" timing could depend on scheduling/load interactions. This could lead to variable length "low" times during heavy control-path activity.

In the **Pure Hardware Switch**:
- The transition from DShot to a forced LOW state happens in **exactly 1 clock cycle** (18.5ns at 54MHz).
- Software scheduling jitter is removed from the FPGA-controlled segment of the transition; low duration is controlled by host write timing to the `force_low` bit.
- This provides the highly deterministic signal required by sensitive ESC bootloaders.

### 2. Baud Rate Integrity (1,000,000 USB Link + ESC Tunnel Passthrough)
- **USB-Link (1,000,000)**: In the current Tang9K top wrapper, `fcsp_uart_byte_stream` is instantiated with `.BAUD(1_000_000)` at `54_000_000` Hz.
- **ESC-Tunnel (bit-transparent)**: Channel `0x05` forwarding is byte/stream-transparent in FCSP transport terms; ESC serial timing is set by the active passthrough/UART configuration path and is not hard-wired by this timing report section.

## Latest FPGA Compile Summary (Tang9K OSS Flow)

Source: `build/tang9k_oss/nextpnr.log` from latest successful `tang9k-build`.

### Timing Summary

- Constraint clock (`sys_clk`): **54.00 MHz**
- Post-route FMAX (`sys_clk`): **59.83 MHz** (**PASS**)
- Margin vs target: **+5.83 MHz** (~10.8% headroom)

Note: nextpnr log also includes an earlier analytical estimate (`89.14 MHz`), but
the post-route number (`59.83 MHz`) is the actionable sign-off metric.

### Resource Usage Summary

| Resource | Used / Avail | Utilization |
|---|---:|---:|
| IOB | 24 / 276 | 8% |
| LUT4 | 2101 / 8640 | 24% |
| DFF | 1274 / 6480 | 19% |
| RAM16SDP4 | 128 / 270 | 47% |
| BSRAM | 2 / 26 | 7% |
| rPLL | 1 / 2 | 50% |

## Worst Path / FMAX Limiter (Current Build)

### What currently limits FMAX

From the critical path report on `sys_clk`:

- Dominant path is in **CRC/data-capture logic**, traversing
	`u_top.u_crc_gate.payload_mem.*` and `u_top.u_crc_gate.u_crc16.*` nodes.
- Path split reported by nextpnr:
	- **Logic delay:** `7.42 ns`
	- **Routing delay:** `9.30 ns`

Interpretation: this is **routing-dominated** (routing > logic), so gains come
most from physical locality + additional staging (not only boolean simplification).

### Practical ways to improve FMAX (highest ROI first)

1. **Add/register pipeline cuts around CRC feed path**
	 - Insert a staging register between payload memory read data and CRC consume
		 logic in `fcsp_crc_gate`/`fcsp_crc16` interaction.
	 - Goal: reduce long combinational/routing span into smaller hops.

2. **Reduce routing span of `payload_mem` -> CRC chain**
	 - Keep related registers and CRC logic in tighter locality (hierarchy-preserve
		 where helpful; avoid transformations that scatter these cones).
	 - If needed, duplicate high-fanout control signals near sink clusters.

3. **Constrain/register memory outputs where practical**
	 - Prefer registered BRAM/LUTRAM read boundaries when protocol latency budget
		 permits, to break memory-to-ALU critical arcs.

4. **Retiming-friendly coding style in hot blocks**
	 - Keep arithmetic/state update paths explicit and pipelineable in
		 `fcsp_crc_gate` and adjacent framing logic.
	 - Avoid large mixed control/data always blocks on the hot path.

5. **Re-check non-essential wide mux depth near CRC path**
	 - Simplify deeply nested selects in CRC feed byte selection if equivalent
		 staged forms are possible.

### Suggested measurable goal

- Near-term objective: raise post-route `sys_clk` FMAX from **59.83 MHz** to
	**>= 65 MHz** while preserving FCSP behavior and passing all simulation suites.

## Verification Checklist

✅ **Passthrough Latency**: Sub-microsecond (Pure RTL).
✅ **Transition Time**: Consistent 18.5ns.
✅ **Break Signal Capability**: Supported via Serial/DShot Mux register (`0x40000400`) bit [4].
✅ **Channel Isolation**: Software can select exactly which motor receives the configuration stream while keeping others idle.

## Design Conclusion
The **Pure Hardware Switch** currently meets the documented timing targets for the BLHeli 4-Way transition path in this repository's validation context, and shows positive post-route margin on the Tang9K build flow.

<!-- AUTO_COMPILE_SUMMARY_START -->
## Auto-updated Compile Snapshot

Generated: 2026-04-18 14:57:22Z

Source log: `/media/tcmichals/projects/pico/flightcontroller/rt-fc-offloader/build/tangnano20k_oss/nextpnr.log`

### Timing

- Constraint (`sys_clk`): **54.00 MHz**
- Post-route FMAX (`sys_clk`): **184.23 MHz**
- Margin vs target: **130.23 MHz**
- Early analytical estimate (pre-route): **152.25 MHz**

### Utilization

| Resource | Used / Avail | Utilization |
|---|---:|---:|
| IOB | 25 / 384 | 6% |
| LUT4 | 6862 / 20736 | 33% |
| DFF | 3385 / 15552 | 21% |
| RAM16SDP4 | 162 / 648 | 25% |
| BSRAM | 4 / 46 | 8% |
| rPLL | 1 / 2 | 50% |

### Current Worst Path Snapshot (`sys_clk`)

- Source: `u_top.u_wb_master.rsp_len_DFFRE_Q_2.Q`
- Sink: `u_top.u_tx_arbiter.sel_DFF_Q_1_D_LUT4_F_I2_LUT2_F_I1_LUT4_I3_I2_ALU_COUT_CIN_ALU_COUT_CIN_ALU_COUT_CIN_ALU_COUT_CIN_ALU_COUT_CIN_ALU_COUT_CIN_ALU_COUT_CIN_ALU_COUT_CIN_ALU_COUT_CIN_ALU_COUT_CIN_ALU_COUT_CIN_ALU_COUT_CIN_ALU_COUT_CIN_ALU_COUT_CIN_ALU_COUT_CIN_ALU_COUT.I1`
- Logic delay: **2.86 ns**
- Routing delay: **2.57 ns**
<!-- AUTO_COMPILE_SUMMARY_END -->
