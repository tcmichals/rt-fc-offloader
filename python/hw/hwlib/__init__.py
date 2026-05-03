"""Reusable helpers for FCSP hardware validation scripts."""

from .fcsp_client import FcspControlClient, setup_file_logging
from .registers import (
    EXPECTED_WHO_AM_I,
    WHO_AM_I,
    # PWM decoder
    PWM_BASE,
    PWM_CH0, PWM_CH1, PWM_CH2, PWM_CH3, PWM_CH4, PWM_CH5,
    PWM_STATUS, PWM_CHANNELS,
    # DShot
    DSHOT_BASE,
    DSHOT_MOTOR1_RAW, DSHOT_MOTOR2_RAW, DSHOT_MOTOR3_RAW, DSHOT_MOTOR4_RAW,
    DSHOT_MOTOR1_THR, DSHOT_MOTOR2_THR, DSHOT_MOTOR3_THR, DSHOT_MOTOR4_THR,
    DSHOT_MOTOR_THR, DSHOT_MOTOR_RAW,
    DSHOT_STATUS, DSHOT_CONFIG,
    # Mux
    MUX_CTRL,
    MODE_SERIAL, MODE_DSHOT,
    make_mux_word, decode_mux_word,
    # NeoPixel
    NEO_BASE,
    NEO_PIXEL_0, NEO_PIXEL_1, NEO_PIXEL_2, NEO_PIXEL_3,
    NEO_PIXEL_4, NEO_PIXEL_5, NEO_PIXEL_6, NEO_PIXEL_7,
    NEO_PIXELS, NEO_UPDATE,
    rgbw,
    # ESC UART
    ESC_BASE,
    ESC_TX_DATA, ESC_STATUS, ESC_RX_DATA, ESC_BAUD_DIV,
    # On-board LEDs
    LED_BASE,
    LED_OUT, LED_TOGGLE, LED_CLEAR, LED_SET,
    LED_0, LED_1, LED_2, LED_3, LED_ALL,
)

__all__ = [
    "FcspControlClient",
    # Identity
    "WHO_AM_I", "EXPECTED_WHO_AM_I",
    # PWM decoder
    "PWM_BASE",
    "PWM_CH0", "PWM_CH1", "PWM_CH2", "PWM_CH3", "PWM_CH4", "PWM_CH5",
    "PWM_STATUS", "PWM_CHANNELS",
    # DShot
    "DSHOT_BASE",
    "DSHOT_MOTOR1_RAW", "DSHOT_MOTOR2_RAW", "DSHOT_MOTOR3_RAW", "DSHOT_MOTOR4_RAW",
    "DSHOT_MOTOR1_THR", "DSHOT_MOTOR2_THR", "DSHOT_MOTOR3_THR", "DSHOT_MOTOR4_THR",
    "DSHOT_MOTOR_THR", "DSHOT_MOTOR_RAW",
    "DSHOT_STATUS", "DSHOT_CONFIG",
    # Mux
    "MUX_CTRL", "MODE_SERIAL", "MODE_DSHOT",
    "make_mux_word", "decode_mux_word",
    # NeoPixel
    "NEO_BASE",
    "NEO_PIXEL_0", "NEO_PIXEL_1", "NEO_PIXEL_2", "NEO_PIXEL_3",
    "NEO_PIXEL_4", "NEO_PIXEL_5", "NEO_PIXEL_6", "NEO_PIXEL_7",
    "NEO_PIXELS", "NEO_UPDATE", "rgbw",
    # ESC UART
    "ESC_BASE",
    "ESC_TX_DATA", "ESC_STATUS", "ESC_RX_DATA", "ESC_BAUD_DIV",
    # On-board LEDs
    "LED_BASE",
    "LED_OUT", "LED_TOGGLE", "LED_CLEAR", "LED_SET",
    "LED_0", "LED_1", "LED_2", "LED_3", "LED_ALL",
]
