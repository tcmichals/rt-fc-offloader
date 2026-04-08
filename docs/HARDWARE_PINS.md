# Tang Nano 9K Hardware Pin Reference

## Physical Pin Mapping

| Pin | Signal Name    | Direction | Function                              |
|-----|----------------|-----------|---------------------------------------|
| 3   | i_rst_n        | Input     | Master Reset (active low)             |
| 52  | i_clk          | Input     | 27 MHz reference clock (PLL input)    |
| 25  | i_spi_clk      | Input     | SPI SCLK (Host Link)                  |
| 26  | i_spi_cs_n     | Input     | SPI CS (Host Link)                    |
| 27  | i_spi_mosi     | Input     | SPI MOSI (Host Link)                  |
| 28  | o_spi_miso     | Output    | SPI MISO (Host Link)                  |
| 10  | o_led_1        | Output    | On-board LED 1 (status/debug)         |
| 11  | o_led_2        | Output    | On-board LED 2 (status/debug)         |
| 13  | o_led_3        | Output    | On-board LED 3 (status/debug)         |
| 14  | o_led_4        | Output    | On-board LED 4 (status/debug)         |
| 15  | o_led_5        | Output    | On-board LED 5 (status/debug)         |
| 16  | o_led_6        | Output    | On-board LED 6 (status/debug)         |
| 19  | i_usb_uart_rx  | Input     | USB-UART RX (Configurator Link)       |
| 20  | o_usb_uart_tx  | Output    | USB-UART TX (Configurator Link)       |
| 51  | o_motor1       | Output    | Motor 1 / ESC Passthrough             |
| 42  | o_motor2       | Output    | Motor 2 / ESC Passthrough             |
| 41  | o_motor3       | Output    | Motor 3 / ESC Passthrough             |
| 35  | o_motor4       | Output    | Motor 4 / ESC Passthrough             |
| 40  | o_neopixel     | Output    | WS2812 RGB LED Data                   |

NeoPixel payload width is parameterized in the top-level seam via `NEO_RGB_WIDTH` (default `24`, e.g., RGB888). Physical NeoPixel pin mapping is unchanged.

## NeoPixel Timing Generation (RTL)

There are currently two relevant paths in this repo:

1. **FCSP seam path (`fcsp_io_engines`)**
        - Current scaffold behavior does **not** synthesize full WS2812/SK6812 waveforms yet.
        - It forwards `i_neo_rgb[0]` to `o_neo_data` and pulses `o_neo_busy` for one cycle on `i_neo_update`.

2. **Legacy Wishbone NeoPixel path (`wb_spisystem` → `wb_neoPx` → `sendPx_axis_flexible`)**
        - This is where full bit-level NeoPixel timing is generated.
        - Timing is derived from `CLK_FREQ_HZ` and LED timing constants using rounded cycle conversion:
               - $\text{cycles} = \left\lfloor\dfrac{t_{ns} \cdot f_{clk} + 5\times10^8}{10^9}\right\rfloor$
        - For WS2812 (`LED_TYPE=0`):
               - $T0H=400\,ns$, $T1H=800\,ns$, $T_{bit}=1250\,ns$, $T_{latch}=300\,\mu s$
        - For SK6812 (`LED_TYPE=1`):
               - $T0H=300\,ns$, $T1H=600\,ns$, $T_{bit}=1250\,ns$, $T_{latch}=300\,\mu s$
        - Valid clock range in RTL checks: **10 MHz to 200 MHz**.
        - The sender state machine drives `o_serial` in `SEND/GAP/LATCH` phases using computed cycle thresholds.

## Clocking Path

The external board clock pin drives the PLL in `fcsp_tangnano9k_top`:

- `Pin 52` → `i_clk` (27 MHz reference)
- `i_clk` feeds `u_pll` (`rPLL`)
- `u_pll.CLKOUT` drives internal `sys_clk`
- `sys_clk` is used as the main clock for `fcsp_offloader_top` and board-side shims

Current wrapper PLL settings target approximately **54 MHz** `sys_clk` from the 27 MHz input reference.

## ESC Configuration Wiring

The Tang Nano 9k provides a bidirectional hardware bridge for ESC configuration. This bridge is enabled by software via FCSP register `0x0020`.

```
                    ┌─────────────────┐
  PC (Configurator) │  USB-to-TTL     │
  (esc-configurator)│  Adapter        │
  ──────── USB ────►│  (CP2102/FT232) │
                    └─────────────────┘
                           │  │  │
            ┌──────────────┘  │  └──────────────┐
            │ TX (Yellow)     │ RX (White)      │ GND (Black)
            ▼                 ▼                 ▼
     ┌──────────────────────────────────────────────┐
     │           Tang Nano 9K FPGA Board           │
     │                                              │
     │  Pin 19 (i_usb_uart_rx) ◄── TX               │
     │  Pin 20 (o_usb_uart_tx) ──► RX               │
     │  GND ◄────────────────────── GND             │
     │                                              │
     │  Motor Pins (51, 42, 41, 35) ◄──► ESC Signal │
     │  (Select channel via Mode Register 0x20)     │
     │  GND ◄──────────────────────────► ESC GND    │
     └──────────────────────────────────────────────┘
```

## Motor Configuration Logic (Register 0x0020)

To configure an ESC, the host script must:
1.  **Select the Channel**: Set bits [2:1] to the motor number (0-3).
2.  **Toggle Passthrough**: Set bit [0] to 1 to enable the bridge.
3.  **Execute Break**: Toggle bit [4] to 1 then 0 to trigger the ESC bootloader.

| Motor    | Channel Select | Pin |
|----------|----------------|-----|
| Motor 1  | `2'b00`        | 51  |
| Motor 2  | `2'b01`        | 42  |
| Motor 3  | `2'b10`        | 41  |
| Motor 4  | `2'b11`        | 35  |

## On-board LED Status Mapping

In the current `fcsp_tangnano9k_top` wrapper:

- `o_led_1` and `o_led_2` are reserved for link traffic indication.
- The remaining LEDs (`o_led_3..o_led_6`) are the status/Wishbone-visible LED bank.
- Status LED width is a compile-time parameter: `LED_WIDTH` (default `4`).
- Traffic indicator timing is parameterized with:
       - `SYS_CLK_HZ` (default `54_000_000`)
       - `TRAFFIC_LED_HOLD_MS` (default `100` ms)

| LED Signal | Pin | Source Bit | Meaning |
|------------|-----|------------|---------|
| `o_led_1`  | 10  | Heartbeat generator | FPGA alive blink (`HEARTBEAT_HZ`, default 2 Hz) |
| `o_led_2`  | 11  | SPI traffic detector | SPI link activity pulse (SCLK edge while CS is low, ~100 ms hold) |
| `o_led_3`  | 13  | `LED[0]` / `debug_leds_internal[2]` | Parser frame done pulse (`o_parser_frame_done`) |
| `o_led_4`  | 14  | `LED[1]` / `debug_leds_internal[3]` | Control TX overflow (`o_ctrl_tx_overflow`) |
| `o_led_5`  | 15  | `LED[2]` / `debug_leds_internal[4]` | Control TX frame seen (`o_ctrl_tx_frame_seen`) |
| `o_led_6`  | 16  | `LED[3]` / `debug_leds_internal[5]` | Debug TX overflow (`o_dbg_tx_overflow`) |

With default `LED_WIDTH=4`, all four status LEDs are active. If `LED_WIDTH` is reduced, higher-index status LEDs are forced low while physical pin assignments remain unchanged.

By default (`SYS_CLK_HZ=54_000_000`, `HEARTBEAT_HZ=2`, `TRAFFIC_LED_HOLD_MS=100`), LED1 blinks at ~2 Hz and SPI traffic pulses are stretched to roughly 100 ms for visibility.
