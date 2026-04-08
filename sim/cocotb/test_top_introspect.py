import cocotb
from cocotb.triggers import Timer

@cocotb.test()
async def introspect_top(dut):
    names = sorted([obj._name for obj in dut])
    cocotb.log.info("TOP SIGNALS: %s", ",".join(names))
    await Timer(1, unit="ns")
