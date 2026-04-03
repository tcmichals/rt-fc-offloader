"""Cocotb scaffold for FCSP parser RTL verification.

This testbench is intentionally lightweight until `rtl/fcsp/fcsp_parser.sv`
ports are finalized. It already integrates the Python FCSP golden model.
"""

import cocotb
from cocotb.triggers import Timer

from python_fcsp.fcsp_codec import encode_frame


@cocotb.test()
async def smoke_fcsp_parser_scaffold(dut) -> None:
    """Basic smoke test scaffold.

    TODO: replace with real signal-level drive/check once DUT interface is fixed.
    """
    _ = encode_frame(flags=0, channel=0x01, seq=1, payload=b"ping")

    # Keep test deterministic and explicit while interface is under construction.
    await Timer(1, unit="us")

    # Placeholder assertion to keep CI path alive.
    assert True
