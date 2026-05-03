"""Common register constants and bitfield helpers for hardware scripts."""

from __future__ import annotations

# ---------------------------------------------------------------------------
# Identity
# ---------------------------------------------------------------------------
WHO_AM_I          = 0x40000000
EXPECTED_WHO_AM_I = 0xFC500002

# ---------------------------------------------------------------------------
# DShot mailbox  (base 0x40000300)
# Raw registers:  write a full 16-bit DSHOT word (throttle[15:5] telem[4] CRC[3:0])
# Smart/THR regs: write 11-bit throttle + 1-bit telemetry, hardware fills CRC
# Status/Config:  read ready bits, write DSHOT speed (150/300/600)
# ---------------------------------------------------------------------------
DSHOT_BASE        = 0x40000300

DSHOT_MOTOR1_RAW  = DSHOT_BASE + 0x00   # raw 16-bit DSHOT word, motor 1
DSHOT_MOTOR2_RAW  = DSHOT_BASE + 0x04
DSHOT_MOTOR3_RAW  = DSHOT_BASE + 0x08
DSHOT_MOTOR4_RAW  = DSHOT_BASE + 0x0C
DSHOT_STATUS      = DSHOT_BASE + 0x10   # [3:0] ready bits
DSHOT_CONFIG      = DSHOT_BASE + 0x14   # [15:0] speed: 150/300/600

DSHOT_MOTOR1_THR  = DSHOT_BASE + 0x40   # 11-bit throttle + 1-bit telem, CRC auto
DSHOT_MOTOR2_THR  = DSHOT_BASE + 0x44
DSHOT_MOTOR3_THR  = DSHOT_BASE + 0x48
DSHOT_MOTOR4_THR  = DSHOT_BASE + 0x4C

# Convenience list indexed 0..3
DSHOT_MOTOR_THR   = (DSHOT_MOTOR1_THR, DSHOT_MOTOR2_THR, DSHOT_MOTOR3_THR, DSHOT_MOTOR4_THR)
DSHOT_MOTOR_RAW   = (DSHOT_MOTOR1_RAW, DSHOT_MOTOR2_RAW, DSHOT_MOTOR3_RAW, DSHOT_MOTOR4_RAW)

# ---------------------------------------------------------------------------
# Serial/DSHOT mux  (base 0x40000400)
# ---------------------------------------------------------------------------
MUX_CTRL   = 0x40000400
MODE_SERIAL = 0  # bit[0]=0 => serial/passthrough
MODE_DSHOT  = 1  # bit[0]=1 => dshot

# ---------------------------------------------------------------------------
# PWM decoder  (base 0x40000100)
# Read-only channel values [15:0] and status [5:0] ready bits
# ---------------------------------------------------------------------------
PWM_BASE      = 0x40000100

PWM_CH0       = PWM_BASE + 0x00   # [15:0] channel 0 pulse width
PWM_CH1       = PWM_BASE + 0x04
PWM_CH2       = PWM_BASE + 0x08
PWM_CH3       = PWM_BASE + 0x0C
PWM_CH4       = PWM_BASE + 0x10
PWM_CH5       = PWM_BASE + 0x14
PWM_STATUS    = PWM_BASE + 0x18   # [5:0] ready bits

PWM_CHANNELS  = (PWM_CH0, PWM_CH1, PWM_CH2, PWM_CH3, PWM_CH4, PWM_CH5)

# ---------------------------------------------------------------------------
# NeoPixel  (base 0x40000600)
# Pixel slots 0..7 (32-bit each), trigger at +0x20
# ---------------------------------------------------------------------------
NEO_BASE      = 0x40000600

NEO_PIXEL_0   = NEO_BASE + 0x00
NEO_PIXEL_1   = NEO_BASE + 0x04
NEO_PIXEL_2   = NEO_BASE + 0x08
NEO_PIXEL_3   = NEO_BASE + 0x0C
NEO_PIXEL_4   = NEO_BASE + 0x10
NEO_PIXEL_5   = NEO_BASE + 0x14
NEO_PIXEL_6   = NEO_BASE + 0x18
NEO_PIXEL_7   = NEO_BASE + 0x1C
NEO_UPDATE    = NEO_BASE + 0x20

NEO_PIXELS    = (NEO_PIXEL_0, NEO_PIXEL_1, NEO_PIXEL_2, NEO_PIXEL_3,
                 NEO_PIXEL_4, NEO_PIXEL_5, NEO_PIXEL_6, NEO_PIXEL_7)

# ---------------------------------------------------------------------------
# ESC UART  (base 0x40000900)
# Half-duplex ESC UART controller
# ---------------------------------------------------------------------------
ESC_BASE      = 0x40000900

ESC_TX_DATA   = ESC_BASE + 0x00   # W:  TX byte (low 8 bits)
ESC_STATUS    = ESC_BASE + 0x04   # R:  bit0=tx_ready, bit1=rx_valid, bit2=tx_active
ESC_RX_DATA   = ESC_BASE + 0x08   # R:  RX byte (reading clears rx_valid)
ESC_BAUD_DIV  = ESC_BASE + 0x0C   # RW: [15:0] baud divisor

# ---------------------------------------------------------------------------
# On-board LED controller  (base 0x40000C00)
# Registers: LED_OUT (+0x00), LED_TOGGLE (+0x04), LED_CLEAR (+0x08), LED_SET (+0x0C)
# Bits [3:0] map to board LEDs 3-6 (active-low on Tang Nano 9K)
# ---------------------------------------------------------------------------
LED_BASE    = 0x40000C00
LED_OUT     = LED_BASE + 0x00   # RW: current output value
LED_TOGGLE  = LED_BASE + 0x04   # W:  XOR bits into output
LED_CLEAR   = LED_BASE + 0x08   # W:  AND-NOT bits into output
LED_SET     = LED_BASE + 0x0C   # W:  OR bits into output

LED_0 = 0x1   # board o_led_3
LED_1 = 0x2   # board o_led_4
LED_2 = 0x4   # board o_led_5
LED_3 = 0x8   # board o_led_6
LED_ALL = 0xF


def rgbw(r: int, g: int, b: int, w: int = 0) -> int:
    """Pack into 32-bit SK6812 GRBW word (MSB-first: G[31:24] R[23:16] B[15:8] W[7:0])."""
    return (g << 24) | (r << 16) | (b << 8) | w


def make_mux_word(
    mode: int,
    channel: int,
    msp_mode: int = 0,
    force_low: int = 0,
    auto_passthrough_en: int = 0,
) -> int:
    """Build wb_serial_dshot_mux control word bits [5:0]."""
    return (
        ((auto_passthrough_en & 0x1) << 5)
        | ((force_low & 0x1) << 4)
        | ((msp_mode & 0x1) << 3)
        | ((channel & 0x3) << 1)
        | (mode & 0x1)
    )


def decode_mux_word(word: int) -> dict[str, int]:
    """Decode wb_serial_dshot_mux control word bits [5:0]."""
    return {
        "mode": word & 0x1,
        "channel": (word >> 1) & 0x3,
        "msp_mode": (word >> 3) & 0x1,
        "force_low": (word >> 4) & 0x1,
        "auto_passthrough_en": (word >> 5) & 0x1,
    }
