"""Reusable helpers for FCSP hardware validation scripts."""

from .fcsp_client import FcspControlClient
from .registers import (
    EXPECTED_WHO_AM_I,
    WHO_AM_I,
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
    NEO_PIXEL_0, NEO_UPDATE,
    rgbw,
    # On-board LEDs
    LED_BASE,
    LED_OUT, LED_TOGGLE, LED_CLEAR, LED_SET,
    LED_0, LED_1, LED_2, LED_3, LED_ALL,
)

__all__ = [
    "FcspControlClient",
    # Identity
    "WHO_AM_I", "EXPECTED_WHO_AM_I",
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
    "NEO_PIXEL_0", "NEO_UPDATE", "rgbw",
    # On-board LEDs
    "LED_BASE",
    "LED_OUT", "LED_TOGGLE", "LED_CLEAR", "LED_SET",
    "LED_0", "LED_1", "LED_2", "LED_3", "LED_ALL",
]
