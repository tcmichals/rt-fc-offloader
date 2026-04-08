from __future__ import annotations

import importlib.util
import pathlib
import sys


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
HW_DIR = REPO_ROOT / "python" / "hw"


def _load_module(module_name: str, file_path: pathlib.Path):
    spec = importlib.util.spec_from_file_location(module_name, str(file_path))
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Failed to load module spec for {file_path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


if str(HW_DIR) not in sys.path:
    sys.path.insert(0, str(HW_DIR))

registers_mod = _load_module("hw_registers", HW_DIR / "hwlib" / "registers.py")
neopixel_mod = _load_module("hw_test_neopixel", HW_DIR / "test_hw_neopixel.py")
led_walk_mod = _load_module("hw_test_led_walk", HW_DIR / "test_hw_onboard_led_walk.py")
switching_mod = _load_module("hw_test_switching", HW_DIR / "test_hw_switching.py")
version_poll_mod = _load_module("hw_test_version_poll", HW_DIR / "test_hw_version_poll.py")

LED_BASE = registers_mod.LED_BASE
run_neopixel_test = neopixel_mod.run_test
run_led_walk_test = led_walk_mod.run_test
run_switching_test = switching_mod.run_test
neopixel_main = neopixel_mod.main
led_walk_main = led_walk_mod.main
switching_main = switching_mod.main
version_poll_main = version_poll_mod.main


def test_hw_switching_runs_in_sim() -> None:
    run_switching_test(port="sim", baud=1_000_000, break_ms=0)


def test_hw_onboard_led_walk_runs_in_sim() -> None:
    run_led_walk_test(
        port="sim",
        baud=1_000_000,
        led_base=LED_BASE,
        width=4,
        step_ms=1,
        loops=1,
    )


def test_hw_neopixel_runs_in_sim() -> None:
    run_neopixel_test(
        port="sim",
        baud=1_000_000,
        num_leds=4,
        step_delay=0.0,
        cycles=1,
    )


def test_hw_version_poll_runs_in_sim(monkeypatch) -> None:
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "test_hw_version_poll.py",
            "--port",
            "sim",
            "--count",
            "5",
            "--interval-ms",
            "1",
            "--no-ansi",
        ],
    )
    version_poll_main()


def test_hw_switching_cli_main_runs_in_sim(monkeypatch) -> None:
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "test_hw_switching.py",
            "--port",
            "sim",
            "--break-ms",
            "0",
        ],
    )
    switching_main()


def test_hw_onboard_led_walk_cli_main_runs_in_sim(monkeypatch) -> None:
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "test_hw_onboard_led_walk.py",
            "--port",
            "sim",
            "--led-base",
            hex(LED_BASE),
            "--width",
            "4",
            "--step-ms",
            "1",
            "--loops",
            "1",
        ],
    )
    led_walk_main()


def test_hw_neopixel_cli_main_runs_in_sim(monkeypatch) -> None:
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "test_hw_neopixel.py",
            "sim",
            "--cycles",
            "1",
            "--num-leds",
            "4",
            "--step-delay",
            "0",
        ],
    )
    neopixel_main()
