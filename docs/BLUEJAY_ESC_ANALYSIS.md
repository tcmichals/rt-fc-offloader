# Bluejay ESC Firmware — Source Code Analysis

> **Repository:** [bird-sanctuary/bluejay](https://github.com/bird-sanctuary/bluejay) (GPL-3.0)
> **Language:** 8051 assembly (SiLabs EFM8 BB21 / BB51)
> **Base:** BLHeli_S revision 16.7 by Steffen Skaug
> **Version analyzed:** 0.21.0 (latest release, July 2024)

**Related documentation:**
- [DESIGN.md](DESIGN.md) §8 — FPGA-side DShot implementation, telemetry status, and bootloader entry via hardware.
- [BLHELI_PASSTHROUGH.md](BLHELI_PASSTHROUGH.md) — Python developer passthrough operating procedure.
- [BLHELI_QUICKSTART.md](BLHELI_QUICKSTART.md) — Wiring and quick-start usage guide.

---

## 1. Bluejay vs BLHeli — Lineage and Differences

**BLHeli** is a family of ESC firmware projects by Steffen Skaug, starting in 2011:

| Firmware | MCU Target | Language | Status |
|----------|-----------|----------|--------|
| BLHeli (original) | Atmel ATmega/ATtiny | AVR assembly | Discontinued |
| BLHeli_S | SiLabs EFM8 (BB1/BB2) | 8051 assembly | Discontinued (last release: rev 16.7, 2018) |
| BLHeli_32 | STM32 (ARM Cortex-M0) | C (closed source) | Active (commercial) |

**Bluejay** is an open-source fork of **BLHeli_S rev 16.7**. It was created by Mathias Rasmussen and is now maintained by the bird-sanctuary community. Bluejay keeps the same 8051 assembly language and SiLabs MCU targets but adds significant features that BLHeli_S never had:

| Capability | BLHeli_S 16.7 | Bluejay 0.21 |
|-----------|--------------|-------------|
| DShot protocol | DShot150/300/600 | DShot300/600 (dropped 150) |
| Bidirectional DShot | Not supported | **Supported** — eRPM telemetry via GCR on signal wire |
| Extended DShot Telemetry (EDT) | Not supported | **Supported** — temp, voltage, current, stress, status |
| PWM input (analog RC) | Supported | **Removed** — DShot-only |
| OneShot125/OneShot42 | Supported | **Removed** — DShot-only |
| PWM frequency | 24 kHz fixed | 24/48/96 kHz selectable |
| Startup tunes | Not supported | **Supported** — user-configurable melodies |
| Safety arm (EDT required) | Not supported | **Supported** — optional via `Pgm_Safety_Arm` |
| BB51 MCU support | Not supported | **Supported** |
| LED control | Not supported | **Supported** (up to 3 LEDs, layout-dependent) |
| Turtle mode | Not supported | **Supported** — DShot command 21 |
| Open source | Yes (GPL-3.0) | Yes (GPL-3.0) |

**Key architectural difference:** BLHeli_S supported multiple input signal types (PWM, OneShot, DShot) with runtime detection. Bluejay removed all analog input support and is exclusively DShot. This simplification allowed the codebase to add bidirectional DShot and EDT without the code-space overhead of analog signal handling.

**Bootloader compatibility:** Bluejay uses the **same BLHeli bootloader** (`BLHeliBootLoad.inc`) as BLHeli_S. Any tool that can flash BLHeli_S (ESC Configurator, BLHeli Suite, Betaflight passthrough) can also flash Bluejay. The bootloader protocol, handshake, and flash commands are identical.

**EEPROM layout:** Bluejay uses `EEPROM_LAYOUT_REVISION = 208`, which is different from BLHeli_S. Settings written by BLHeli_S will be reset to Bluejay defaults on first boot. The setting structure is compatible enough that configurator tools can read/write both.

---

## 2. Repository Layout

```
bluejay/
├── src/
│   ├── Bluejay.asm              ← Main entry point, startup, run loop
│   ├── BLHeliBootLoad.inc       ← BLHeli serial bootloader
│   ├── Layouts/                 ← Pin mapping files (A–Z, BB51 variants)
│   ├── Modules/
│   │   ├── Common.asm           ← MCU defs, constants, macros (PCA, clock, flash)
│   │   ├── Codespace.asm        ← Flash segment address definitions
│   │   ├── Enums.asm            ← Named constants (MCU types, PWM freq, DShot cmds)
│   │   ├── Macros.asm           ← DShot decode/encode macros, math helpers
│   │   ├── Isrs.asm             ← All interrupt handlers (Timer0/1/2/3, Int0/1, PCA)
│   │   ├── DShot.asm            ← DShot signal detection, command processing, telemetry
│   │   ├── Scheduler.asm        ← 1024ms cyclic scheduler (EDT frames, temp protection)
│   │   ├── Timing.asm           ← Commutation timing, zero-cross wait
│   │   ├── Commutation.asm      ← 6-step BLDC commutation sequences
│   │   ├── Power.asm            ← PWM limit, set_pwm_limit function
│   │   ├── Fx.asm               ← Fixed-point math utilities
│   │   ├── Eeprom.asm           ← Flash-as-EEPROM read/write
│   │   ├── Settings.asm         ← Decode EEPROM parameters to runtime flags
│   │   └── McuOffsets.asm        ← MCU-specific SFR page offsets
│   ├── Settings/
│   │   └── BluejaySettings.asm  ← Default parameter values
│   └── Silabs/
│       ├── SI_EFM8BB2_Defs.inc  ← SFR definitions for BB21
│       └── SI_EFM8BB51_Defs.inc ← SFR definitions for BB51
├── tools/                       ← Build helper scripts (Python)
├── Makefile                     ← Build system (invokes SiLabs assembler)
└── README.md
```

---

## 3. Supported Features

| Feature | Details |
|---------|---------|
| **DShot protocol** | DShot300 and DShot600 (auto-detected at startup) |
| **Bidirectional DShot** | eRPM telemetry via GCR-encoded response on signal wire |
| **Extended DShot Telemetry (EDT)** | Temperature, voltage (stub), current (stub), demag stress, status events |
| **PWM frequencies** | 24 kHz, 48 kHz, 96 kHz (selectable at build time) |
| **Motor control** | 6-step sensorless BLDC with back-EMF zero-crossing |
| **Startup** | Soft-start with configurable min/max power, stall recovery (retries up to 3) |
| **Direction** | Normal, reverse, bidirectional with braking |
| **Temperature protection** | 4-tier PWM limiting based on ADC readings |
| **Beacon/beep** | Configurable beep melody, beacon delay (1/2/5/10 min or infinite) |
| **LED control** | Up to 3 status LEDs (layout-dependent) |
| **Safety arm** | Optional EDT-enable-required-to-arm safety feature |
| **BLHeli bootloader** | Serial bootloader for firmware updates via signal wire |
| **Turtle mode** | User-request reverse for crash recovery |

---

## 4. MCU Hardware Model

The EFM8 BB21/BB51 is an enhanced 8051 with:

| Resource | Role in Bluejay |
|----------|----------------|
| **24.5 MHz internal oscillator** | Master clock (switchable to 49 MHz via divider) |
| **Timer0** (41.67 ns ticks) | DShot telemetry pulse generation |
| **Timer1** (41.67 ns ticks) | DShot frame sync detection (gated by Int1) |
| **Timer2** (500 ns ticks) | RC pulse timeout, commutation period measurement |
| **Timer3** (500 ns ticks) | Commutation timing (advance/zero-cross waits) |
| **PCA0** (41.67 ns ticks) | Hardware PWM generation (motor phase drive) |
| **Int0** (edge-triggered) | Captures DShot pulse widths into XRAM |
| **Int1** (edge-triggered) | Marks DShot frame start timestamp |
| **ADC** | Temperature reading for thermal protection |
| **Flash** | Firmware + EEPROM emulation (settings storage) |

**Clock switching:** MCU runs at 24 MHz while waiting for signal. After arming, BB21/BB51 switch to 48 MHz for higher timing resolution during motor operation. All DShot timing thresholds are doubled when switching to 48 MHz.

---

## 5. Program Flow — What Each Section Does

### 5.1 Power-on Reset (`pgm_start` in `Bluejay.asm`)

**Lines:** Entry point after reset vector.

```
pgm_start:
    Lock_Flash              ; Prevent accidental flash writes
    mov WDTCN, #0DEh       ; Disable watchdog
    mov WDTCN, #0ADh
    mov SP, #Stack          ; Initialize stack (16 bytes)
    ...
    call set_default_parameters
    call read_all_eeprom_parameters
    call decode_settings
    call play_beep_melody   ; Startup tunes
    call led_control
```

**What it does:**
1. Disables watchdog timer
2. Configures VDD monitor (BB21 only)
3. Sets clock divider to 1 (24 MHz)
4. Initializes all port pins per layout file (motor phase FETs, comparator inputs, signal pin)
5. Clears all 256 bytes of internal RAM
6. Loads default settings, then overrides with EEPROM-stored user settings
7. Plays startup beep melody
8. Falls through to `init_no_signal`

### 5.2 Signal Detection (`init_no_signal` → `setup_dshot`)

**What it does:**

1. **Bootloader check:** If the signal wire is held HIGH for ~150 ms at power-on, the ESC jumps to `CSEG_BOOT_START` (the BLHeli bootloader). This is how configurator tools enter flash mode.

2. **DShot setup:** Configures Timer0/1 for DShot pulse capture:
   - Timer0/1 in 8-bit auto-reload mode, gated by Int0/Int1
   - CKCON0 = `0x01` (Timer0/1 clock = sys_clock / 4, for DShot150 initial probe)

3. **Signal level detection** (`detect_rcp_level` in `DShot.asm`):
   - Samples the signal pin 50 times (~25 µs)
   - If consistently LOW → normal DShot
   - If consistently HIGH → inverted DShot (bidirectional capable)
   - Sets `Flag_Rcp_DShot_Inverted` accordingly

4. **Int0/Int1 routing:** Routes signal pin to both external interrupt inputs. If inverted DShot detected, Int0 is inverted; otherwise Int1 is inverted. This lets the same ISR code decode both polarities.

### 5.3 DShot Speed Auto-Detection (`setup_dshot` continued)

Bluejay does **NOT** support PWM or OneShot — it is DShot-only. Protocol detection is a sequential probe:

```
1. Try DShot300 first:
   - Set DShot_Timer_Preset = -128  (frame sync timeout for 300)
   - Set DShot_Pwm_Thr = 16        (pulse width threshold for 300)
   - Set DShot_Frame_Length_Thr = 80
   - Set telemetry bitrate = 375000 (= 5/4 × 300000)
   - Set CKCON0 = 0x0C              (Timer0/1 = sys_clk, not /4)
   - Wait 100ms, count out-of-range pulses
   - If Rcp_Outside_Range_Cnt == 0 → DShot300 detected, proceed to arming

2. If DShot300 failed, try DShot600:
   - Set DShot_Timer_Preset = -64
   - Set DShot_Pwm_Thr = 8
   - Set DShot_Frame_Length_Thr = 40
   - Set telemetry bitrate = 750000 (= 5/4 × 600000)
   - Wait 100ms, count out-of-range pulses
   - If Rcp_Outside_Range_Cnt == 0 → DShot600 detected, proceed to arming

3. If both failed → jump back to init_no_signal (retry)
```

**Key insight:** The ESC determines DShot speed by trying to decode frames at each rate and checking if pulses fall within valid ranges. There is no magic protocol negotiation — it is trial-and-error with timeouts.

### 5.4 Arming Sequence (`arming_begin` → `wait_for_start`)

```
arming_begin:
    push PSW
    mov  Temp8, CKCON0    ; Save DShot clock for telemetry
    pop  PSW
    setb Flag_Had_Signal  ; Mark signal detected
    beep_f1_short         ; Confirm detection beep

arming_wait:
    ; Wait for throttle = 0 for ~300ms (10 × 32ms Timer2 cycles)
    clr  C
    mov  A, Rcp_Stop_Cnt
    subb A, #10
    jc   arming_wait      ; Keep waiting

    beep_f2_short         ; Confirm armed beep
```

**What it does:**
1. Saves DShot timing configuration
2. Beeps to confirm signal detection
3. Waits for the flight controller to send zero throttle for ~300 ms
4. Beeps again to confirm the ESC is armed
5. Falls through to `wait_for_start` loop

**Safety arm (optional):** If `Pgm_Safety_Arm` is set, the ESC requires EDT to be enabled (DShot command 13 sent 6 times) before it will start the motor. This prevents accidental spin-up.

### 5.5 Wait for Start (`wait_for_start` → `wait_for_start_loop`)

The ESC sits in a loop:
- Creates telemetry packets (0 RPM) and sends them back to the FC
- Runs the scheduler (temperature monitoring, EDT frames)
- Processes DShot commands (beeps, direction changes, settings)
- Plays beacon beeps at configurable intervals (1/2/5/10 min)
- Watches for non-zero throttle

When throttle > 0:
- Waits 100 ms to filter glitches
- If still non-zero → proceeds to `motor_start`

### 5.6 Motor Start (`motor_start`)

```
motor_start:
    clr  IE_EA              ; Disable all interrupts
    call switch_power_off
    mov  Flags0, #0         ; Clear all run-time flags
    mov  Flags1, #0

    ; Switch to 48MHz (BB21/BB51 only)
    Set_MCU_Clk_48MHz

    ; Scale all DShot timing for 48MHz
    clr  C
    rlca DShot_Timer_Preset
    rlca DShot_Frame_Length_Thr
    rlca DShot_Pwm_Thr

    ; Initialize commutation
    call comm5_comm6
    call comm6_comm1
    call initialize_timing
    ...
    setb IE_EA               ; Re-enable interrupts
```

**What it does:**
1. Switches MCU to 48 MHz for better commutation timing resolution
2. Doubles all DShot decoding thresholds (since timer ticks are now half the duration)
3. Swaps GCR telemetry pulse timings to 48 MHz variants
4. Sets startup power limits from `Pgm_Startup_Power_Max`
5. Initializes commutation sequence (6-step BLDC starting position)
6. Sets `Flag_Startup_Phase` and `Flag_Initial_Run_Phase`
7. Enters the commutation run loop

### 5.7 Commutation Run Loop (`run1` → `run6`)

The main motor control loop cycles through 6 commutation states. Each state:

1. Waits for the comparator to detect back-EMF zero crossing
2. Waits the calculated advance timing before commutating
3. Fires the next commutation (switches motor phase FETs)
4. Calculates the next commutation period

```
run1: call wait_for_comp_out_high  ; Wait for BEMF zero cross
      call wait_for_comm           ; Wait advance timing
      call comm1_comm2             ; Switch FETs
      call calc_next_comm_period   ; Update timing
      ; → falls through to run2

run2: call wait_for_comp_out_low
      call set_pwm_limit           ; Thermal/RPM power limiting
      call wait_for_comm
      call comm2_comm3
      call calc_next_comm_period
      ; → falls through to run3

... (run3 through run6 similar)

run6: ...
      call scheduler_run           ; Run periodic tasks (EDT, temp)
      ; → checks for stop/stall/direction change
      ; → jumps back to run1
```

**After run6:** The code checks:
- Is the motor still in startup phase? (24 commutations required)
- Is the motor in initial run phase? (12 rotations required)
- Has the RC pulse returned to zero? → exit run mode
- Has the RC pulse timed out? → exit run mode
- Is the motor below minimum speed? → exit run mode (stall)
- Bidirectional direction change? → initiate braking

### 5.8 Exit Run Mode (`exit_run_mode`)

```
exit_run_mode:
    clr  IE_EA
    call switch_power_off
    Set_MCU_Clk_24MHz       ; Back to 24MHz

    ; Scale DShot thresholds back to 24MHz
    setb C
    rrca DShot_Timer_Preset
    rrca DShot_Frame_Length_Thr
    rrca DShot_Pwm_Thr
```

If the motor stalled:
- Increments `Startup_Stall_Cnt`
- If < 3 stalls → retries `motor_start` after 100 ms delay
- If ≥ 3 stalls → beeps stall warning, returns to `arming_begin`

If normal stop:
- Applies brake-on-stop if configured (turns on all complementary FETs)
- Returns to `wait_for_start`

---

## 6. Interrupt Handlers (`Isrs.asm`)

### 6.1 Int0 — DShot Pulse Capture (Highest Priority)

```
int0_int:
    push ACC
    mov  A, TL0                  ; Read Timer0 (pulse width)
    mov  TL1, DShot_Timer_Preset ; Reset frame sync timer
    push PSW
    mov  PSW, #8h                ; Register bank 1
    movx @Temp1, A               ; Store pulse width in XRAM
    inc  Temp1                   ; Advance pointer
    pop  PSW
    pop  ACC
    reti
```

**Trigger:** Rising edge of DShot signal (via Int0).
**What it does:** Reads Timer0 count (which measures the previous pulse HIGH duration since Timer0 is gated by Int0). Stores the timestamp into external RAM (XRAM), building an array of 16 pulse widths — one per DShot bit.

### 6.2 Int1 — Frame Start Timestamp

```
int1_int:
    clr  IE_EX1              ; Disable Int1
    setb TCON_TR1             ; Start Timer1 (frame sync)
    clr  TMR2CN0_TR2         ; Snapshot Timer2
    mov  DShot_Frame_Start_L, TMR2L
    mov  DShot_Frame_Start_H, TMR2H
    setb TMR2CN0_TR2
    reti
```

**Trigger:** Falling edge of DShot signal (marks beginning of frame).
**What it does:** Records a Timer2 timestamp for frame-length validation. Starts Timer1 as a timeout — if Timer1 overflows before all 16 bits arrive, the ISR fires (Timer1 ISR) to process the frame.

### 6.3 Timer1 — DShot Frame Decode (Core Protocol Engine)

This is the most complex ISR (~300 lines). It fires when Timer1 overflows, which happens at the end of each DShot frame.

**Frame validation:**
1. Checks frame time (Timer2 delta) is within `DShot_Frame_Length_Thr` to `2× DShot_Frame_Length_Thr`
2. Verifies exactly 16 pulses were captured (`Temp1 == 16`)

**Bit decoding** (via `Decode_DShot_2Bit` macro):
- Reads each pulse width from XRAM
- Subtracts the previous timestamp to get the delta
- Subtracts `DShot_Pwm_Thr` (minimum valid pulse width)
- If result is negative → invalid pulse → frame rejected
- If result < `DShot_Pwm_Thr` → bit is `1` (short pulse = high)
- If result ≥ `DShot_Pwm_Thr` → bit is `0` (long pulse = low)
- Bits are shifted MSB-first into result registers

**The decoded 16-bit frame:**
```
Temp5[3:0] = MSB nibble (bits 15–12)
Temp4[7:0] = LSB byte   (bits 11–4)
Temp3[3:0] = CRC nibble  (bits 3–0)
```

**CRC validation:**
```
A = Temp4 ^ (Temp4 >> 4) ^ Temp5 ^ Temp3
; If inverted DShot: A = ~A
; Valid if (A & 0x0F) == 0
```

**Throttle extraction:**
```
; Invert data (DShot sends inverted)
; Subtract 96 → throttle range 0–1999 (from 96–2095)
; Values 1–95 are DShot commands (with telemetry bit set)

; For bidirectional mode:
;   0 = stop
;   96–2095 → forward (after subtracting 96)
;   2096–4095 → reverse (after subtracting 2096)
```

**PWM calculation:**
- Scales throttle from 12-bit to the configured PWM resolution (8/9/10/11 bit)
- Applies startup power boost if motor is stalling
- Applies temperature and RPM power limits
- Writes result to PCA PWM registers (with dead-time compensation if configured)

**Telemetry scheduling:**
- If inverted DShot (bidirectional) and a telemetry packet is ready:
  - Switches Timer0 from gated mode to free-running
  - Configures the signal pin as push-pull output
  - Starts telemetry transmission (handled by Timer0 ISR)

### 6.4 Timer0 — DShot Telemetry Transmission

```
t0_int:
    push PSW
    mov  PSW, #10h           ; Register bank 2
    dec  Temp1               ; Decrement pulse pointer
    cjne Temp1, #(Temp_Storage - 1), t0_int_dshot_tlm_transition

    ; Last pulse done
    jb   RTX_BIT, t0_int_dshot_tlm_finish
    ; ... wait for line to return high

t0_int_dshot_tlm_transition:
    cpl  RTX_BIT              ; Toggle signal level
    mov  TL0, @Temp1          ; Load next timing
    pop  PSW
    reti
```

**What it does:** Shifts out GCR-encoded telemetry data by toggling the signal pin at pre-computed intervals stored in `Temp_Storage`. Each Timer0 overflow triggers the next toggle. When all pulses are sent, restores the pin to input mode and re-enables DShot reception.

### 6.5 Timer2 — 16 ms Heartbeat

Fires every ~16 ms (32 ms before arming). Increments `Timer2_X`, sets `Flag_16ms_Elapsed` for the scheduler, and manages RC pulse timeout (`Rcp_Timeout_Cntd`). If timeout reaches zero, sets `Flag_Rcp_Stop`.

### 6.6 Timer3 — Commutation Timing

Used by the timing module to schedule commutation advance. Clears `Flag_Timer3_Pending` when it fires, signaling the commutation wait code to proceed.

---

## 7. DShot Protocol Details

### 7.1 Frame Format (FC → ESC)

```
┌─────────────────┬───┬──────┐
│  Throttle (11)  │ T │ CRC  │
│  bits 15–5      │ 4 │ 3–0  │
└─────────────────┴───┴──────┘
MSB sent first, 16 bits total
```

| Field | Bits | Description |
|-------|------|-------------|
| Throttle | `[15:5]` | 0 = disarmed, 1–47 = DShot commands (with T=1), 48–2047 = throttle |
| Telemetry | `[4]` | 1 = request telemetry response, 0 = no request |
| CRC | `[3:0]` | `(value ^ (value >> 4) ^ (value >> 8)) & 0x0F` |

### 7.2 Bit Encoding (Timing at Wire Level)

Each bit is encoded as a fixed-period pulse with variable duty cycle:

```
              ┌──────┐             ┌───────────────┐
Bit = 1:      │ T1H  │    T1L     │               │
         ─────┘      └────────────┘               └──
              ←──────── bit period ────────────────→

              ┌──┐                 ┌───────────────┐
Bit = 0:      │T0│     T0L        │               │
         ─────┘  └────────────────┘               └──
              ←──────── bit period ────────────────→
```

| Speed | T1H (high) | T0H (high) | Bit period | Frame time (16 bits) | Frame rate |
|-------|-----------|-----------|------------|---------------------|-----------|
| DShot150 | 5.00 µs | 2.50 µs | 6.67 µs | 106.7 µs | 9.4 kHz |
| DShot300 | 2.50 µs | 1.25 µs | 3.33 µs | 53.3 µs | 18.8 kHz |
| DShot600 | 1.25 µs | 0.625 µs | 1.67 µs | 26.7 µs | 37.5 kHz |

**Decision rule (ESC receiver):** If *high time* > threshold → bit is `1`, else bit is `0`. The threshold is set at 3/4 of the bit period.

### 7.3 DShot Commands

Commands are sent as throttle values 1–47 with the telemetry bit set. Commands 7+ must be received 6 consecutive times before the ESC acts on them.

| Command | Value | Action | Repeat Required |
|---------|-------|--------|----------------|
| Beep 1–5 | 1–5 | Play beacon beep tones | No (immediate) |
| ESC Info | 6 | Request ESC information | No |
| Direction Normal | 7 | Set motor direction to normal | Yes (×6) |
| Direction Reverse | 8 | Set motor direction to reverse | Yes (×6) |
| Bidir Off | 9 | Disable bidirectional mode | Yes (×6) |
| Bidir On | 10 | Enable bidirectional mode | Yes (×6) |
| Save Settings | 12 | Write direction/bidir to EEPROM | Yes (×6) |
| EDT Enable | 13 | Enable Extended DShot Telemetry | Yes (×6) |
| EDT Disable | 14 | Disable Extended DShot Telemetry | Yes (×6) |
| User Direction Normal | 20 | Set to programmed direction | Yes (×6) |
| User Direction Reverse | 21 | Temporary reverse (turtle mode) | Yes (×6) |

### 7.4 How the ESC Decides to Send Telemetry

Telemetry is **not** enabled by a single flag or register. It requires two conditions to be true, each determined by a different mechanism:

#### Condition 1: Inverted DShot Signal (Hardware Detection)

At power-on, before any DShot frames are decoded, the ESC runs `detect_rcp_level` (`DShot.asm`):

```
detect_rcp_level:
    mov  A, #50              ; Sample 50 times (~25 µs)
    mov  C, RTX_BIT          ; Read current level

detect_rcp_level_read:
    ; If level changes during sampling → restart
    ; If stable for 50 samples → declare level
    ...
    mov  Flag_Rcp_DShot_Inverted, C   ; HIGH = inverted DShot
    ret
```

**Normal DShot:** Signal idles LOW between frames. The FC pulls the line HIGH for each bit pulse. `Flag_Rcp_DShot_Inverted = 0`.

**Inverted DShot (bidirectional):** Signal idles HIGH (pulled up). The FC pulls the line LOW for each bit pulse. `Flag_Rcp_DShot_Inverted = 1`.

The flight controller chooses which mode to use. If the FC configures its DShot output as inverted (all flight controller firmware has this option, typically called "Bidirectional DShot" or "RPM filtering" in the configurator), the ESC automatically detects it and enables telemetry responses.

**This is the primary telemetry gate.** In the Timer1 ISR (`t1_int` in `Isrs.asm`), after decoding a valid DShot frame and setting the PWM output, the code checks:

```
    jnb  Flag_Rcp_DShot_Inverted, t1_int_exit_no_tlm  ; No telemetry if normal DShot
    jnb  Flag_Telemetry_Pending, t1_int_exit_no_tlm   ; No packet ready yet
    ; → Configure Timer0 for telemetry transmission
    ; → Set signal pin to push-pull output
    ; → Start sending GCR-encoded response
```

If `Flag_Rcp_DShot_Inverted` is clear, the ESC **never** sends any telemetry, regardless of the telemetry request bit in the DShot frame.

#### Condition 2: EDT Enable Command (For Extended Telemetry Only)

Basic eRPM telemetry is sent automatically whenever inverted DShot is detected — no additional command is needed.

Extended DShot Telemetry (EDT) — temperature, voltage, current, stress, status frames — requires the FC to send **DShot command 13 six consecutive times** while the motor is not running (during `wait_for_start`):

```
dshot_cmd_extended_telemetry_enable:
    cjne Temp1, #CMD_EXTENDED_TELEMETRY_ENABLE, ...

    mov  Ext_Telemetry_L, #00h
    mov  Ext_Telemetry_H, #0Eh     ; Send version frame (111 0 0000 0000)
    setb Flag_Ext_Tele              ; Enable EDT scheduler
    sjmp dshot_cmd_exit
```

Once `Flag_Ext_Tele` is set, the scheduler (`Scheduler.asm`) begins populating `Ext_Telemetry_L/H` with temperature, status, demag, and debug data on its 1024 ms cycle. The telemetry packet builder checks `Ext_Telemetry_H` and, if non-zero, sends the EDT frame instead of eRPM.

**Summary of telemetry activation:**

| Telemetry type | Requires inverted DShot? | Requires DShot cmd 13? | When sent |
|---------------|------------------------|----------------------|-----------|
| eRPM (motor speed) | **Yes** | No | Every DShot frame (when packet ready) |
| EDT Temperature | **Yes** | **Yes** (×6) | Every ~1024 ms (scheduler step 7) |
| EDT Status | **Yes** | **Yes** (×6) | Every ~1024 ms (scheduler step 1) |
| EDT Demag metric | **Yes** | **Yes** (×6) | Every ~512 ms (even scheduler steps) |
| EDT Debug 1/2 | **Yes** | **Yes** (×6) | Every ~1024 ms (scheduler steps 3, 5) |

### 7.5 Telemetry Packet Construction (What's in the Packet)

The telemetry packet is built by `dshot_tlm_create_packet` (`DShot.asm`). This routine is called from the `wait_for_start` loop and during commutation waits. It is designed to be interruptible — divided into 6 stages that can yield to Timer3 (commutation timing) to avoid interfering with motor control.

#### Stage 0: Read commutation period or EDT data

```
    ; If Ext_Telemetry_H is non-zero → EDT frame ready, skip eRPM calc
    mov  A, Ext_Telemetry_H
    jnz  dshot_tlm_ready

    ; Otherwise calculate eRPM from commutation period
    clr  IE_EA
    mov  A, Comm_Period4x_L       ; Read commutation period (4× average)
    mov  Tlm_Data_H, Comm_Period4x_H
    setb IE_EA
```

The commutation period (`Comm_Period4x`) is measured by Timer2 in 500 ns ticks across 4 commutations. The routine converts this to an electrical period (e-period) in microseconds:

```
    ; e-period = Comm_Period4x × 3/4 (= 6 commutations × 0.5 µs/tick)
    ; Correction: subtract 4 × Comm_Period4x_H for timer tick inaccuracy
    ; (Timer2 ticks are ~489 ns, not exactly 500 ns)
```

#### Stage 1: Check for EDT or encode eRPM

If `Ext_Telemetry_H` is non-zero, the EDT data is moved directly to `Tlm_Data_L/H` and `Ext_Telemetry_H` is cleared (one-shot — next frame will revert to eRPM unless the scheduler loads new EDT data).

If eRPM, the 16-bit e-period is compressed to 12 bits using `dshot_12bit_encode`:

```
; 12-bit format: eee m mmmm mmmm
; Find the highest set bit in the high byte to determine exponent
; Shift the 16-bit value right by (exponent) to fit mantissa into 9 bits
; Store exponent in Tlm_Data_H[3:1], mantissa in Tlm_Data_L + Tlm_Data_H[0]
```

**Normalization:** The encoder sets bit 8 of the mantissa (the MSB) whenever the exponent is > 0. This ensures each eRPM value has a unique representation, freeing up patterns where bit[8]=0 and exponent>0 for EDT frames.

#### Stage 2: Compute CRC

```
    mov  A, Tlm_Data_L
    swap A                    ; Get high nibble of low byte
    xrl  A, Tlm_Data_L       ; XOR with low byte
    xrl  A, Tlm_Data_H       ; XOR with high byte
    cpl  A                    ; Invert (CRC is inverted for telemetry)
    ; Low nibble of A is now the 4-bit CRC
```

#### Stages 3–5: GCR encode (4 nibbles → 20 GCR bits → pulse timings)

The 16-bit frame (12 data + 4 CRC) is split into 4 nibbles. Each nibble is GCR-encoded via a jump table (`dshot_gcr_encode_jump_table`) into 5-bit codewords. The codewords are stored as **pulse duration values** in `Temp_Storage[0..N]`:

```
; Temp_Storage contents after encoding (example):
; [0] = DShot_GCR_Pulse_Time_1    ← final transition (always Time_1)
; [1] = timing for 1st GCR transition
; [2] = timing for 2nd GCR transition
; ...
; [N] = timing for last GCR transition
```

Each entry is a Timer0 reload value. When the Timer0 ISR fires, it toggles the signal pin and loads the next timing value. The three possible values are:

| Variable | Timer0 counts | Real time (DShot300 @ 24 MHz) | Encodes |
|----------|--------------|------------------------------|---------|
| `DShot_GCR_Pulse_Time_1` | Shortest | ~2.67 µs | Single GCR bit |
| `DShot_GCR_Pulse_Time_2` | Medium | ~5.33 µs | Two same GCR bits |
| `DShot_GCR_Pulse_Time_3` | Longest | ~8.00 µs | Three same GCR bits |

These values are precomputed by the `Set_DShot_Tlm_Bitrate` macro at setup time and adjusted when switching between 24/48 MHz.

#### What goes on the wire

After `Flag_Telemetry_Pending` is set, the next Timer1 ISR (end of the next DShot frame) initiates transmission:

```
Timeline for one DShot cycle with telemetry:

FC sends DShot frame (16 bits)
    │
    ├── 26.7 µs (DShot600) or 53.3 µs (DShot300)
    │
    ▼
FC releases line (tri-states output, line pulled HIGH)
    │
    ├── ~30 µs delay (DSHOT_TLM_START_DELAY)
    │
    ▼
ESC drives line (push-pull output)
    │
    ├── GCR-encoded telemetry: ~20 transitions over ~53 µs (DShot300)
    │   Each transition = toggle signal level at computed timing
    │
    ▼
ESC releases line (back to open-drain input)
    │
    ▼
FC resumes driving next DShot frame
```

**Complete telemetry packet on the wire (DShot300 example, eRPM = 25000):**

```
12-bit telemetry data:
  e-period → 12-bit encode → exponent=5, mantissa=0x119 → 101 1 0001 1001
  CRC = (0x119 ^ 0x11 ^ 0x01) & 0x0F inverted = ...

16-bit frame: [101 1 0001 1001] [cccc]
  → 4 nibbles → 4 GCR codewords → 20 GCR bits
  → Encoded as pulse durations (signal toggles)
  → Transmitted LSB-first as transition timings on the wire
```

### 7.6 Extended DShot Telemetry (EDT)

EDT reuses the same 12-bit telemetry frame by exploiting normalized eRPM encoding. After normalization, certain prefix patterns are impossible for eRPM values, so they are repurposed:

**Frame discrimination rule:** If the last four bits of the 12-bit value are `0` OR bit[8] is `1`, it is an eRPM frame. All other patterns are EDT frames.

| Prefix (4 bits) | Bit pattern | Frame type | Data content |
|-----------------|-------------|-----------|-------------|
| `000 0` or `000 1` | eRPM value | **eRPM** | Electrical RPM (mantissa << exponent) |
| Any with bit[8]=1 | eRPM value | **eRPM** | Electrical RPM |
| `001 0` | `001 0 tttt tttt` | **Temperature** | Degrees Celsius, unsigned (0–255) |
| `010 0` | `010 0 vvvv vvvv` | **Voltage** | Battery voltage in 0.25V steps (0–63.75V) |
| `011 0` | `011 0 iiii iiii` | **Current** | Motor current in 1A steps (0–255A) |
| `100 0` | `100 0 dddd dddd` | **Debug 1** | Firmware-defined (Bluejay: `0x88` stub) |
| `101 0` | `101 0 dddd dddd` | **Debug 2** | Firmware-defined (Bluejay: `0xAA` stub) |
| `110 0` | `110 0 ssss ssss` | **Stress level** | Demag metric value (0–255) |
| `111 0` | `111 0 AWSx mmmm` | **Status** | A=demag alert, W=desync warning, S=stall error, m=max stress (0–15) |

**How Bluejay fills each EDT frame:**

| Frame | Source in Bluejay | Scheduler step | `Ext_Telemetry_H` value |
|-------|------------------|---------------|------------------------|
| Temperature | ADC reading, normalized per MCU/power rating | Step 7 (odd) | `0x02` |
| Stress (demag metric) | `Demag_Detected_Metric` counter | Steps 0,2,4,6 (even) | `0x0C` |
| Status | `Flag_Demag_Notify`, `Flag_Desync_Notify`, `Flag_Stall_Notify`, metric/9 | Step 1 (odd) | `0x0E` |
| Debug 1 | Hardcoded `0x88` (stub) | Step 3 (odd) | `0x08` |
| Debug 2 | Hardcoded `0xAA` (stub) | Step 5 (odd) | `0x0A` |
| Version | `0x00` (sent once on EDT enable) | On command 13 | `0x0E` |
| Disabled | `0xFF` (sent once on EDT disable) | On command 14 | `0x0E` |

**Note:** Voltage and current frames are defined in the EDT specification but **Bluejay does not populate them** — the BB21/BB51 hardware lacks voltage/current sense ADC inputs. These frames would require external sense circuitry.

**Enabling:** FC sends DShot command 13 six times. ESC ACKs with a version frame (`111 0 0000 0000`).

**Disabling:** FC sends DShot command 14 six times. ESC ACKs with a disabled frame (`111 0 1111 1111`).

---

## 8. Scheduler (`Scheduler.asm`)

The scheduler runs once per electrical revolution (called from `run6`). It uses a 1024 ms cycle divided into 8 steps of 128 ms each:

| Step | ms Offset | Action |
|------|-----------|--------|
| 0 (even) | 0 | Update temperature setpoint + send demag metric EDT frame |
| 1 (odd) | 128 | Update temperature PWM limit + send status EDT frame |
| 2 (even) | 256 | Update temperature setpoint + send demag metric EDT frame |
| 3 (odd) | 384 | Update temperature PWM limit + send debug1 EDT frame |
| 4 (even) | 512 | Update temperature setpoint + send demag metric EDT frame |
| 5 (odd) | 640 | Update temperature PWM limit + send debug2 EDT frame |
| 6 (even) | 768 | Update temperature setpoint + send demag metric EDT frame |
| 7 (odd) | 896 | Update temperature PWM limit + send temperature EDT frame + restart ADC |

**Temperature protection (4 tiers):**

| ADC Reading vs Limit | PWM Setpoint | Effect |
|---------------------|-------------|--------|
| Below limit 1 | 255 (100%) | Full power |
| Between limit 1 and 2 | 200 (~80%) | Reduced power |
| Between limit 2 and 3 | 150 (~60%) | Further reduced |
| Between limit 3 and 4 | 100 (~40%) | Landing power |
| Above limit 4 | 50 (~20%) | Forced landing |

PWM limit changes are applied ±1 per scheduler step to avoid current spikes.

---

## 9. BLHeli Bootloader (`BLHeliBootLoad.inc`)

### 9.1 Entry Conditions

The bootloader is entered when the signal wire is held HIGH for ~150 ms at power-on. This is checked in `init_no_signal`:

```
; If input signal is high for about ~150ms, enter bootloader mode
mov  Temp1, #9
mov  Temp2, #0
mov  Temp3, #0
input_high_check:
    jnb  RTX_BIT, bootloader_done   ; If low detected, skip
    djnz Temp3, input_high_check
    djnz Temp2, input_high_check
    djnz Temp1, input_high_check

    call beep_enter_bootloader
    ljmp CSEG_BOOT_START             ; Jump to bootloader
```

The bootloader can also be entered via the BLHeli passthrough protocol from a flight controller.

### 9.2 Bootloader Protocol

**Physical layer:** Bit-banged UART at 19200 baud on the signal wire (RTX_PIN). Uses the same pin as DShot — this is why the ESC must be in bootloader mode (not running motor) to be flashed.

**Initialization:**
1. Disables watchdog
2. Sets RTX_PIN as open-drain digital I/O
3. Enables crossbar
4. Attempts to sync with the configurator (up to 250 retries)

**Handshake:**
1. Waits for the RTX line to go LOW
2. Scans for the identifier string "BLHeli" byte-by-byte with CRC validation
3. If found, sends boot info: `"471d"` + chip signature + bootloader version + page count
4. Enters command loop

### 9.3 Command Protocol

All commands follow: **command word → parameter word → CRC16 → response byte**

CRC uses polynomial `0xA001` (standard CRC-16/IBM, computed incrementally during UART bit reception).

| Command | Code | Parameters | Action |
|---------|------|-----------|--------|
| Run/Restart | `0x00` + `0x00` | — | Jump to `0x0000` (application restart) |
| Reset bootloader | `0x00` + `0x01` | — | Restart bootloader init |
| Program flash | `0x01` | Address pre-set, buffer pre-loaded | Write buffer contents to flash |
| Erase flash | `0x02` | Address pre-set | Erase flash page at address |
| Read flash | `0x03` | Count in Cmdl | Read N bytes from flash, send with CRC |
| Set address | `0xFF` | Address (16-bit) | Set flash pointer (DPL/DPH) |
| Set buffer | `0xFE` | Size (16-bit) | Receive N bytes into XRAM buffer |
| Keep alive | `0xFD` | — | No-op, resets timeout |

**Flash protection:**
- Bootloader segment itself cannot be erased or written (address check against `CSEG_BOOT_START`)
- Flash keys (`0xA5`, `0xF1`) must be set before write operations
- Keys are cleared on exit to prevent accidental flash corruption

### 9.4 Response Codes

| Code | Meaning |
|------|---------|
| `0x30` | SUCCESS |
| `0xC0` | ERRORVERIFY — verification failed |
| `0xC1` | ERRORCOMMAND — unknown command |
| `0xC2` | ERRORCRC — CRC mismatch |
| `0xC5` | ERRORPROG — programming error |

### 9.5 Bootloader Exit

On receiving command `0x00` with parameter `0x00`:

```
exit:
    mov  Bit_Access, #0      ; Clear flash lock detect variable
    mov  Bit_Access_Int, #0FFh ; Mark: came from bootloader
    mov  BL_Flash_Key_1, #0  ; Lock flash
    mov  BL_Flash_Key_2, #0
    ljmp 0000h               ; Jump to application entry
```

---

## 10. Pin Layout System

Bluejay supports 27+ pin layouts for BB21 and 5+ for BB51. Each layout file (e.g., `Layouts/A.inc`) defines:

- **Port assignments:** Which pins connect to motor phase FETs (Ap/Bp/Cp for PWM, Ac/Bc/Cc for complementary), comparator inputs (Am/Bm/Cm for BEMF, Vn for neutral), signal pin (RX), and optional LEDs (L0/L1/L2)
- **PWM inversion flags:** Whether PWM FETs or complementary FETs have inverted logic
- **PWM side:** High-side or low-side PWM
- **LED count:** 0–3 LEDs

Example layout A (BB21):
```
;  PORT 0                |  PORT 1
;  P0 P1 P2 P3 P4 P5 P6 P7  |  P0 P1 P2 P3 P4 P5 P6 P7
;  Vn Am Bm Cm __ RX __ __  |  Ap Ac Bp Bc Cp Cc __ __
;  PWM inv: no   COM inv: no   PWM side: high   LEDs: 0
```

The build system selects a layout via `ESCNO` and `MCU_TYPE` defines, which are typically passed from the Makefile for each ESC target variant.

---

## 11. Relationship to This Project

This analysis matters for `rt-fc-offloader` because:

1. **DShot output timing:** The `dshot_out.sv` RTL module must produce pulse widths that Bluejay's `Int0` → `Decode_DShot_2Bit` logic will correctly decode. The threshold is `DShot_Pwm_Thr` (16 for DShot300, 8 for DShot600 at 24 MHz clock/4 ticks).

2. **Bidirectional telemetry:** If the FPGA needs to receive eRPM/EDT data, it must decode GCR-encoded pulse streams sent 30 µs after each DShot frame. The `wb_dshot_controller` currently sends raw 16-bit words — receiving telemetry is a future feature.

3. **BLHeli passthrough:** The `wb_serial_dshot_mux` supports ESC passthrough by routing serial UART to the motor pin. The bootloader protocol (19200 baud, "BLHeli" handshake, command loop) is what flows through this path when a configurator tool connects.

4. **DShot command injection:** The FPGA can send DShot commands (values 1–47 with telemetry bit) to trigger beeps, direction changes, or EDT enable/disable on connected ESCs.

5. **No PWM/OneShot support needed:** Bluejay is DShot-only. The FPGA does not need to generate PWM or OneShot signals for Bluejay-flashed ESCs.

---

## 12. Key Code Cross-Reference

| Concept | File | Key Label/Function |
|---------|------|--------------------|
| Entry point | `Bluejay.asm` | `pgm_start:` |
| Bootloader check | `Bluejay.asm` | `input_high_check:` |
| DShot speed probe | `Bluejay.asm` | `setup_dshot:` |
| Signal polarity detect | `DShot.asm` | `detect_rcp_level:` |
| DShot pulse capture | `Isrs.asm` | `int0_int:` |
| Frame sync start | `Isrs.asm` | `int1_int:` |
| Frame decode + throttle | `Isrs.asm` | `t1_int:` → `t1_int_decode_checksum:` |
| Bit decode macro | `Macros.asm` | `Decode_DShot_2Bit` |
| GCR telemetry transmit | `Isrs.asm` | `t0_int:` |
| Telemetry packet build | `DShot.asm` | `dshot_tlm_create_packet:` |
| 12-bit eRPM encode | `DShot.asm` | `dshot_12bit_encode:` |
| GCR nibble encode | `DShot.asm` | `dshot_gcr_encode:` + jump table |
| DShot command handler | `DShot.asm` | `dshot_cmd_check:` |
| EDT enable/disable | `DShot.asm` | `dshot_cmd_extended_telemetry_enable:` |
| Motor commutation loop | `Bluejay.asm` | `run1:` through `run6:` |
| Scheduler main | `Scheduler.asm` | `scheduler_run:` |
| Temperature EDT frame | `Scheduler.asm` | `scheduler_steps_odd_temperature_frame:` |
| Status EDT frame | `Scheduler.asm` | `scheduler_steps_odd_status_frame:` |
| Demag metric EDT frame | `Scheduler.asm` | `scheduler_steps_even_demag_metric_frame:` |
| Bootloader init | `BLHeliBootLoad.inc` | `init:` |
| Bootloader handshake | `BLHeliBootLoad.inc` | `abd:` → `id1:` → `id5:` |
| Flash program | `BLHeliBootLoad.inc` | `pro3:` → `pro5:` |
| Flash erase | `BLHeliBootLoad.inc` | `mai4:` (program/erase branch) |
| Flash read | `BLHeliBootLoad.inc` | `mai5:` → `rd1:` |
| Bootloader UART TX | `BLHeliBootLoad.inc` | `putc:` |
| Bootloader UART RX | `BLHeliBootLoad.inc` | `getc:` → `getx:` |
| Layout pin defines | `Layouts/*.inc` | Port initialization macros |
| EEPROM defaults | `Settings/BluejaySettings.asm` | `DEFAULT_PGM_*` constants |
| Interrupt vector table | `Common.asm` | `Interrupt_Table_Definition` macro |
