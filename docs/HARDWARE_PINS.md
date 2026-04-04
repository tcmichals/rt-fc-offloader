# Tang Nano 9K Hardware Pin Reference

## Physical Pin Mapping

| Pin | Signal Name    | Direction | Function                              |
|-----|----------------|-----------|---------------------------------------|
| 3   | i_rst_n        | Input     | Master Reset (active low)             |
| 52  | i_clk          | Input     | 27 MHz System Clock                   |
| 25  | i_spi_clk      | Input     | SPI SCLK (Host Link)                  |
| 26  | i_spi_cs_n     | Input     | SPI CS (Host Link)                    |
| 27  | i_spi_mosi     | Input     | SPI MOSI (Host Link)                  |
| 28  | o_spi_miso     | Output    | SPI MISO (Host Link)                  |
| 19  | i_usb_uart_rx  | Input     | USB-UART RX (Configurator Link)       |
| 20  | o_usb_uart_tx  | Output    | USB-UART TX (Configurator Link)       |
| 51  | o_motor1       | Output    | Motor 1 / ESC Passthrough             |
| 42  | o_motor2       | Output    | Motor 2 / ESC Passthrough             |
| 41  | o_motor3       | Output    | Motor 3 / ESC Passthrough             |
| 35  | o_motor4       | Output    | Motor 4 / ESC Passthrough             |
| 40  | o_neopixel     | Output    | WS2812 RGB LED Data                   |

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
