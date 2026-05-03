# Blogger Entry Drafts

Use these as copy/paste starting points for Blogger posts.
Tone is intentionally practical and build-log focused.

---

## Entry 1 — Neo + Onboard LEDs are alive on Tang Nano 9K

**Title:** Neo + Onboard LEDs Bring-Up Complete on FCSP Offloader

Today’s hardware milestone was all about visual confidence checks: NeoPixel output and onboard LEDs.

### What we validated

- NeoPixel path is working end-to-end from FCSP register writes to physical LED output.
- SK6812/RGBW configuration is stable at 54 MHz timing.
- Software color packing was corrected to GRBW ordering where needed.
- Onboard LEDs are now useful as immediate bring-up indicators (clock/reset/activity/debug states).

### Why this matters

Visual outputs are low-friction sanity checks during hardware bring-up.
Before we push deeper into motor-control paths, having deterministic LED behavior makes board-state debugging dramatically faster.

### What’s next

Next integration target is motor-control pipeline completion and passthrough path hardening.

---

## Entry 2 — Serial + Wishbone reliability hardening

**Title:** FCSP Link Reliability Upgrades: Cleaner Startup, Better Bus Fault Behavior

We spent this iteration improving robustness where real hardware usually bites first: serial startup behavior and bus transaction failure handling.

### Improvements in this pass

- Serial client defaults aligned for stable bring-up behavior at common baud settings.
- Startup/link-initialization flow hardened (buffer flush + deterministic initialization sequence).
- Wishbone master path now includes timeout-based error response instead of waiting forever on missing ACK.
- Parser/transport behavior is more resilient to startup garbage/noise conditions.

### Why this matters

Reliability work is less flashy than new features, but it prevents the worst failure mode: “sometimes it works.”
Deterministic failure behavior (timeouts and explicit error responses) also makes test automation much easier.

### Validation focus

- Cocotb coverage expanded for timeout and recovery cases.
- Hardware-side observability improved with clearer debug signal strategy.

---

## Entry 3 — Next sprint: DShot + MSP integration

**Title:** Next Up: DShot Execution Path + MSP Workflow Integration

With FCSP transport and IO plumbing in better shape, next sprint is centered on control-plane usability and ESC workflow compatibility.

### Planned focus areas

- DShot path bring-up and verification under realistic update cadence.
- MSP-facing workflow alignment for ecosystem tooling expectations.
- Safety and ownership rules across shared resources (DShot vs passthrough modes).
- Additional simulation and hardware test loops to catch edge cases early.

### Success criteria

- Repeatable DShot output behavior in bench tests.
- Documented MSP interaction path that is clear for future tooling and operators.
- Updated validation matrix + engineering notes with objective pass/fail evidence.

### Closing note

This phase is where protocol work turns into pilot-usable behavior.
We’re intentionally prioritizing predictable control paths and debuggability over “fast but mysterious.”

---

## Entry 4 — Why FCSP instead of MSP-only

**Title:** Why We Built FCSP (and Still Respect MSP)

One common question: why introduce FCSP when MSP already exists?

Short answer: FCSP gives us deterministic, low-overhead transport for FPGA-offloaded control paths, while MSP remains valuable for ecosystem compatibility.

### The practical split

- **FCSP:** deterministic framing, explicit channels, clean hardware/software boundaries, and easier protocol-level validation.
- **MSP:** great interoperability with existing tools, configurators, and workflow expectations.

### Design intent

We are not treating these as enemies.
The goal is an architecture where FCSP handles the performance-critical internal path, while MSP-facing workflows stay possible where they provide user value.

### What this enables

- faster and more reliable bring-up/debug loops
- clearer ownership of IO engines and register windows
- cleaner scaling toward mixed-control workloads

---

## Entry 5 — Simulation-first workflow wins

**Title:** Simulation Is Saving Us Time: Cocotb Coverage Before Hardware Surprises

Before every hardware-heavy push, we keep tightening simulation coverage around protocol and bus behaviors.

### What we focused on

- parser timeout/recovery behavior
- Wishbone timeout handling for missing ACK paths
- IO path regressions around packed signal and register mapping changes

### Why this matters

Hardware debugging is expensive in time and attention.
By turning edge cases into repeatable tests first, we avoid “works on my bench” confidence traps.

### Outcome

Simulation is not replacing hardware validation; it is making hardware runs intentional and faster.

---

## Entry 6 — Build/timing reality check on Tang Nano 9K

**Title:** Timing Margin Checkpoint: Tang Nano 9K Snapshot and What We Learned

We captured a fresh post-route snapshot to make sure feature growth is still aligned with timing closure reality.

### Snapshot highlights

- target clock remains 54 MHz
- post-route FMAX continues to clear target margin
- utilization trends are monitored as IO engines evolve

### Engineering takeaway

Timing closure is not a one-time event.
Every meaningful RTL change should be treated as a new hypothesis to verify, not an assumption to inherit.

### Next checkpoint

As DShot/MSP integration advances, timing + routing pressure will be tracked each milestone to avoid late surprises.

---

## Blogger copy/paste metadata template

Use this block above each post in your drafting flow.

- **SEO Title:**
- **URL Slug:**
- **Excerpt (140-160 chars):**
- **Labels:** fpga, flight-controller, fcsp, tangnano9k, embedded, verification
- **Cover image note:**
- **Call to action:** Follow progress, star the repo, or share feedback.

---

## 4-week posting cadence (suggested)

- **Week 1:** Neo + onboard LED bring-up
- **Week 2:** Serial/Wishbone reliability hardening
- **Week 3:** Simulation-first workflow and timeout tests
- **Week 4:** DShot + MSP roadmap checkpoint

This cadence keeps posts technical, honest, and easy to sustain while development is still moving quickly.

---

## Google Blogger publish runbook (for `allthingsembedded.blogspot.com`)

### One-time setup (5 minutes)

1. Open Blogger dashboard and select **All things embedded**.
2. In **Settings → Formatting**, confirm timezone/date format are correct.
3. In **Settings → Meta tags**, enable search description (optional but recommended).
4. In **Posts**, decide whether comments are enabled for these project updates.

### Per-post publish checklist

1. Click **New Post**.
2. Paste the chosen entry title into the title field.
3. Paste body content from this file.
4. Use heading styles (`Heading`, `Subheading`) for section titles.
5. On right panel:
	 - **Labels**: `fpga, flight-controller, fcsp, tangnano9k, verification`
	 - **Permalink**: custom slug (short, lowercase, hyphenated)
	 - **Search description**: 140–160 char excerpt
6. Add at least one image (scope screenshot, timing plot, board photo, or block diagram).
7. Click **Preview** and check:
	 - list indentation
	 - section spacing
	 - mobile readability
8. Click **Publish**.

### Suggested first 3 posts to publish now

1. **Neo + Onboard LEDs Bring-Up Complete on FCSP Offloader**
2. **FCSP Link Reliability Upgrades: Cleaner Startup, Better Bus Fault Behavior**
3. **Next Up: DShot Execution Path + MSP Workflow Integration**

### Copy/paste search descriptions (ready)

- **Neo + LEDs:**
	`NeoPixel and onboard LED bring-up is now stable on Tang Nano 9K, with verified SK6812 timing and corrected GRBW software packing over FCSP.`

- **Reliability pass:**
	`FCSP reliability update: cleaner serial startup behavior, Wishbone timeout handling, and stronger simulation coverage for recovery and fault paths.`

- **DShot + MSP next:**
	`Next project milestone focuses on DShot execution and MSP workflow alignment, with safety ownership rules and validation-first integration.`

### Optional sign-off line

`More soon as DShot/MSP bench validation progresses. If you’re building similar FPGA flight-control offload paths, I’d love to compare notes.`
