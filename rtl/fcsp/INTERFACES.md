# FCSP RTL Stream Interfaces

This note defines the preferred internal stream contracts for `rtl/fcsp/`.

Use AXIS-style naming internally without requiring full AXI infrastructure.

## Byte stream (AXIS-like)

Recommended signals:

- `tvalid`
- `tready`
- `tdata[7:0]`
- optional `tlast` when packet boundaries are already known

Use for:

- transport frontend seams
- simple payload byte forwarding paths

## Frame/payload stream (AXIS-like)

Recommended payload signals:

- `tvalid`
- `tready`
- `tdata[7:0]`
- `tlast`

Recommended sideband metadata (carried separately or `tuser`-like):

- `channel[7:0]`
- `flags[7:0]`
- `seq[15:0]`
- `payload_len[15:0]`
- optional error/status bits

Use for:

- parser to router/FIFO boundaries
- CONTROL payload seams into SERV
- SERV response seams back into TX path

## Naming convention

- `s_*` prefix = slave/input side of a stream
- `m_*` prefix = master/output side of a stream

Examples:

- `s_ctrl_rx_tvalid`, `s_ctrl_rx_tready`, `s_ctrl_rx_tdata`, `s_ctrl_rx_tlast`
- `m_serv_cmd_tvalid`, `m_serv_cmd_tready`, `m_serv_cmd_tdata`, `m_serv_cmd_tlast`

## Scope rule

These conventions are intended for **internal RTL composition**.

External boundaries may remain transport-specific and lightweight:

- SPI pins/frontends
- USB serial shim
- simple firmware bridge seams

## Reuse and retargeting rules

These interface choices are not just style preferences; they are the main
mechanism for making this design reusable on nearby targets.

### 1) Keep protocol semantics out of physical frontends

- `spi_frontend` should only solve pin/clock/shift/byte transport problems.
- USB/UART shims should only solve byte transport / CDC / buffering problems.
- FCSP-specific parsing starts at the parser seam, not in the transport block.

Why:

- lets us retarget the same FCSP core pipeline to SPI, USB-serial, UART, or a
	future DMA-fed host interface
- lets us reuse proven frontend logic from older projects without importing
	older protocol assumptions

### 2) Keep block internals behind stable stream seams

Preferred reusable seams are:

- byte stream: `tvalid/tready/tdata`
- frame payload stream: `tvalid/tready/tdata/tlast`
- frame metadata sideband:
	- `version`
	- `channel`
	- `flags`
	- `seq`
	- `payload_len`
	- optional `recv_crc`, error/status bits

Why:

- a parser, CRC gate, router, FIFO, or scheduler can be replaced independently
- a different target can keep the same mid-pipeline contracts even if the outer
	transport or CPU changes

### 3) Prefer wrapper-first reuse over direct copy/rewrite

When reusing an older block:

- keep the proven algorithm or timing core if possible
- add a thin wrapper that converts it to the local FCSP stream contract
- do not rewrite the logic just to make names or ports look newer

Examples in this repo:

- CRC reuse through `fcsp_crc16` and `fcsp_crc_gate`
- future SPI reuse should follow the same model
- future DSHOT/IO reuse should stay behind IO-window adapters

### 4) Separate reusable core from target policy

Reusable core logic should avoid baking in:

- board-specific pin choices
- SoC-specific bus coupling
- SERV-specific policy decisions
- MSP-specific framing/schema assumptions

Those belong in wrappers, adapters, or control-plane layers.

### 5) Make metadata sufficient for downstream replacement

If a downstream block might be swapped later, the seam should carry enough
information that the replacement does not need hidden context.

That means the frame seam should explicitly carry the fields needed for:

- CRC validation
- routing
- result framing
- tracing/debug visibility

### 6) Retarget by changing the edges first, not the middle

For a design that is "close to this one", the preferred retargeting order is:

1. adapt transport frontend
2. adapt CPU/control endpoint seam if needed
3. adapt IO engine wrappers
4. keep parser/CRC/router/FIFO contracts unchanged whenever possible

This preserves the highest-value deterministic datapath while allowing board or
system integration changes at the edges.

## Practical litmus test

Before adding or changing a block, ask:

- can this block be reused if SPI becomes UART/USB/DMA?
- can this block be reused if SERV becomes another small control CPU?
- can this block be reused if the IO engines are swapped for close variants?
- does the seam expose enough information that another implementation could
	replace this block without modifying the rest of the pipeline?

If the answer is "no", the interface is probably too coupled.

## Bus strategy: AXIS for streams, Wishbone for devices

To keep the design both reusable and teachable, we should be explicit about bus
roles instead of letting every block invent its own local convention.

### AXIS-style internal streams

Use AXIS-style valid/ready streams for:

- parser output
- CRC gate output
- router inputs/outputs
- RX/TX FIFOs
- SERV payload seams
- TX scheduler/framer payload movement

Why:

- matches FCSP's packet/stream behavior naturally
- teaches a common streaming design pattern used across FPGA projects
- makes block-level replacement and retargeting straightforward

### Wishbone for register/device attachment

Use Wishbone where the problem is **register access or device control**, not raw
packet streaming.

Good Wishbone use cases here:

- IO window/register bank attachment
- DSHOT mailbox/control registers
- PWM capture/status windows
- NeoPixel/LED control windows
- counters, status registers, and debug snapshots
- optional CPU-facing peripheral map around SERV or another small control CPU

Avoid using Wishbone as the main FCSP hot-path transport.

Why:

- the FCSP hot path is a packet/stream pipeline, so AXIS-style seams fit better
- device/register blocks benefit from a standard, well-known bus with lots of
	reusable examples and existing IP
- separating stream fabric from register fabric makes the design easier to
	explain in a classroom and easier to retarget in practice

### Educational rule of thumb

- If bytes are **flowing through a pipeline**, prefer AXIS-style seams.
- If software/firmware is **reading or writing registers in a device**, prefer
	Wishbone.

That split is simple enough for new engineers to learn quickly and realistic
enough to scale to nearby real-world designs.

## Per-device test expectation

If a block sits behind a Wishbone-style device seam, it should have a
device-focused unit testbench of its own.

Examples:

- DSHOT mailbox/register block tests
- PWM capture/status block tests
- LED/NeoPixel register-window tests
- status/counter register block tests

These tests should verify:

- register map behavior
- read/write semantics
- reset values
- side effects and ready/busy flags
- error handling for invalid offsets or unsupported operations

Why this matters for classroom use:

- students/engineers can understand each device in isolation
- interface contracts become concrete instead of hand-wavy
- the project demonstrates both stream-oriented design and standard bus-based
	peripheral design in one coherent example

## Readability requirement

These interfaces should also be easy to read and easy to copy from.

Design preference:

- small modules with obvious responsibilities
- signal names that are boring in a good way
- seams that can be shown in a short snippet
- examples that engineers can lift into a nearby design with minimal edits

If an interface is so clever that it takes a full lecture to decode, it is
probably hurting the educational value of the repo.
