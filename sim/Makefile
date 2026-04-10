SIM_DIR := $(CURDIR)
ROOT_DIR := $(abspath $(SIM_DIR)/..)

ifneq ($(wildcard $(ROOT_DIR)/.venv/bin),)
export PATH := $(ROOT_DIR)/.venv/bin:$(PATH)
override PYTHON_BIN := $(ROOT_DIR)/.venv/bin/python
endif

TOPLEVEL_LANG ?= verilog
TOPLEVEL ?= fcsp_parser
COCOTB_TEST_MODULES ?= test_fcsp_parser_cocotb

# Default FCSP parser RTL source
VERILOG_SOURCES ?= $(ROOT_DIR)/rtl/fcsp/fcsp_parser.sv

FCSP_TOP_SOURCES := \
	$(ROOT_DIR)/rtl/fcsp/fcsp_offloader_top.sv \
	$(ROOT_DIR)/rtl/fcsp/fcsp_spi_frontend.sv \
	$(ROOT_DIR)/rtl/fcsp/fcsp_parser.sv \
	$(ROOT_DIR)/rtl/fcsp/fcsp_crc16_core_xmodem.sv \
	$(ROOT_DIR)/rtl/fcsp/fcsp_crc16.sv \
	$(ROOT_DIR)/rtl/fcsp/fcsp_crc_gate.sv \
	$(ROOT_DIR)/rtl/fcsp/fcsp_router.sv \
	$(ROOT_DIR)/rtl/fcsp/fcsp_rx_fifo.sv \
	$(ROOT_DIR)/rtl/fcsp/fcsp_wishbone_master.sv \
	$(ROOT_DIR)/rtl/fcsp/fcsp_tx_fifo.sv \
	$(ROOT_DIR)/rtl/fcsp/fcsp_tx_arbiter.sv \
	$(ROOT_DIR)/rtl/fcsp/fcsp_tx_framer.sv \
	$(ROOT_DIR)/rtl/fcsp/fcsp_io_engines.sv \
	$(ROOT_DIR)/rtl/fcsp/fcsp_stream_packetizer.sv \
	$(ROOT_DIR)/rtl/fcsp/fcsp_debug_generator.sv \
	$(ROOT_DIR)/rtl/fcsp/drivers/spiSlave/spi_slave.sv \
	$(ROOT_DIR)/rtl/fcsp/drivers/spiSlave/spi_slave_wb_bridge.sv \
	$(ROOT_DIR)/rtl/fcsp/drivers/wb_led_controller.sv \
	$(ROOT_DIR)/rtl/io/wb_io_bus.sv \
	$(ROOT_DIR)/rtl/io/wb_dshot_controller.sv \
	$(ROOT_DIR)/rtl/io/dshot_out.sv \
	$(ROOT_DIR)/rtl/io/wb_serial_dshot_mux.sv \
	$(ROOT_DIR)/rtl/io/wb_esc_uart.sv \
	$(ROOT_DIR)/rtl/io/wb_neoPx.sv \
	$(ROOT_DIR)/rtl/io/sendPx_axis_flexible.sv \
	$(ROOT_DIR)/rtl/io/pwmdecoder_wb.sv \
	$(ROOT_DIR)/rtl/io/pwmdecoder.sv

WB_EXAMPLE_SOURCES := \
	$(ROOT_DIR)/rtl/fcsp/examples/wb_status_regs.sv

AXIS_EXAMPLE_SOURCES := \
	$(ROOT_DIR)/rtl/fcsp/examples/axis_frame_stage.sv

TX_FIFO_SOURCES := \
	$(ROOT_DIR)/rtl/fcsp/fcsp_tx_fifo.sv

TX_ARBITER_SOURCES := \
	$(ROOT_DIR)/rtl/fcsp/fcsp_tx_arbiter.sv

WB_SERIAL_DSHOT_MUX_SOURCES := \
	$(ROOT_DIR)/rtl/io/wb_serial_dshot_mux.sv

WB_LED_SOURCES := \
	$(ROOT_DIR)/rtl/fcsp/drivers/wb_led_controller.sv

FCSP_WB_MASTER_SOURCES := \
	$(ROOT_DIR)/rtl/fcsp/fcsp_wishbone_master.sv

WB_IO_BUS_SOURCES := \
	$(ROOT_DIR)/rtl/io/wb_io_bus.sv

DSHOT_OUT_SOURCES := \
	$(ROOT_DIR)/rtl/io/dshot_out.sv

WB_NEOPX_SOURCES := \
	$(ROOT_DIR)/rtl/io/wb_neoPx.sv \
	$(ROOT_DIR)/rtl/io/sendPx_axis_flexible.sv

PWMDECODER_SOURCES := \
	$(ROOT_DIR)/rtl/io/pwmdecoder.sv

WB_ESC_UART_SOURCES := \
	$(ROOT_DIR)/rtl/io/wb_esc_uart.sv

STREAM_PACKETIZER_SOURCES := \
	$(ROOT_DIR)/rtl/fcsp/fcsp_stream_packetizer.sv

export PYTHONPATH := $(SIM_DIR):$(SIM_DIR)/cocotb:$(ROOT_DIR)/python/hw:$(PYTHONPATH)

SIM ?= verilator
EXTRA_ARGS += --Wno-WIDTH --Wno-CASEINCOMPLETE --Wno-PINMISSING
# --Wno-WIDTHEXPAND was split from WIDTH in Verilator ~5.026; older versions
# subsume it under --Wno-WIDTH.  Probe support so CI works with both.
_VL_WE_OK := $(shell echo 'module _t; endmodule' > /tmp/_vl_we_test.sv && \
  verilator --Wno-WIDTHEXPAND --lint-only /tmp/_vl_we_test.sv >/dev/null 2>&1 && echo yes; \
  rm -f /tmp/_vl_we_test.sv)
ifeq ($(_VL_WE_OK),yes)
EXTRA_ARGS += --Wno-WIDTHEXPAND
endif

PYTEST ?= $(if $(wildcard $(ROOT_DIR)/.venv/bin/pytest),$(ROOT_DIR)/.venv/bin/pytest,pytest)
COCOTB_CONFIG ?= $(if $(wildcard $(ROOT_DIR)/.venv/bin/cocotb-config),$(ROOT_DIR)/.venv/bin/cocotb-config,cocotb-config)

.PHONY: test-cocotb test-python test-hw-scripts-sim test-all test-all-strict test-top-cocotb test-top-cocotb-experimental test-fcsp-integration-cocotb test-wb-example-cocotb test-axis-example-cocotb test-tx-fifo-cocotb test-tx-arbiter-cocotb test-serial-mux-cocotb test-wb-led-cocotb test-fcsp-wb-master-cocotb test-e2e-all-cocotb test-fcsp-smoke-cocotb test-teaching-examples-cocotb test-stream-packetizer-cocotb test-e2e-esc-roundtrip-cocotb test-e2e-switching-cocotb test-e2e-led-cocotb test-e2e-neopixel-cocotb test-e2e-blheli-boot-cocotb test-e2e-spi-tx-cocotb test-esc-protocol-cocotb test-spi-routing-policy-cocotb fit-evidence-snapshot fit-evidence-snapshot-live

check-cocotb:
	@if [ -z "$(COCOTB_MAKEFILES)" ]; then \
		echo "ERROR: cocotb-config not found in PATH; cocotb targets are unavailable."; \
		echo "Hint: use project .venv and ensure cocotb is installed, then re-run."; \
		exit 2; \
	fi

test-cocotb: check-cocotb
	rm -rf sim_build results.xml
	$(MAKE) -C . sim

test-top-cocotb: check-cocotb
	rm -rf sim_build results.xml
	$(MAKE) -C . sim TOPLEVEL=fcsp_offloader_top COCOTB_TEST_MODULES=test_fcsp_offloader_top_cocotb VERILOG_SOURCES="$(FCSP_TOP_SOURCES)"

test-top-cocotb-experimental: check-cocotb
	rm -rf sim_build results.xml
	$(MAKE) -C . sim TOPLEVEL=fcsp_offloader_top COCOTB_TEST_MODULES=test_esc_passthrough_e2e VERILOG_SOURCES="$(FCSP_TOP_SOURCES)"

test-fcsp-integration-cocotb: test-top-cocotb-experimental

test-wb-example-cocotb: check-cocotb
	rm -rf sim_build results.xml
	$(MAKE) -C . sim TOPLEVEL=wb_status_regs COCOTB_TEST_MODULES=test_wb_status_regs_cocotb VERILOG_SOURCES="$(WB_EXAMPLE_SOURCES)"

test-axis-example-cocotb: check-cocotb
	rm -rf sim_build results.xml
	$(MAKE) -C . sim TOPLEVEL=axis_frame_stage COCOTB_TEST_MODULES=test_axis_frame_stage_cocotb VERILOG_SOURCES="$(AXIS_EXAMPLE_SOURCES)"

test-tx-fifo-cocotb: check-cocotb
	rm -rf sim_build results.xml
	$(MAKE) -C . sim TOPLEVEL=fcsp_tx_fifo COCOTB_TEST_MODULES=test_fcsp_tx_fifo_cocotb VERILOG_SOURCES="$(TX_FIFO_SOURCES)"

test-tx-arbiter-cocotb: check-cocotb
	rm -rf sim_build results.xml
	$(MAKE) -C . sim TOPLEVEL=fcsp_tx_arbiter COCOTB_TEST_MODULES=test_fcsp_tx_arbiter_cocotb VERILOG_SOURCES="$(TX_ARBITER_SOURCES)"

test-serial-mux-cocotb: check-cocotb
	rm -rf sim_build results.xml
	$(MAKE) -C . sim TOPLEVEL=wb_serial_dshot_mux COCOTB_TEST_MODULES=test_wb_serial_dshot_mux_cocotb VERILOG_SOURCES="$(WB_SERIAL_DSHOT_MUX_SOURCES)" EXTRA_ARGS="$(EXTRA_ARGS) -GCLK_FREQ_HZ=100"

test-wb-led-cocotb: check-cocotb
	rm -rf sim_build results.xml
	$(MAKE) -C . sim TOPLEVEL=wb_led_controller COCOTB_TEST_MODULES=test_wb_led_controller_cocotb VERILOG_SOURCES="$(WB_LED_SOURCES)"

test-fcsp-wb-master-cocotb: check-cocotb
	rm -rf sim_build results.xml
	$(MAKE) -C . sim TOPLEVEL=fcsp_wishbone_master COCOTB_TEST_MODULES=test_fcsp_wishbone_master_cocotb VERILOG_SOURCES="$(FCSP_WB_MASTER_SOURCES)"

test-wb-io-bus-cocotb: check-cocotb
	rm -rf sim_build results.xml
	$(MAKE) -C . sim TOPLEVEL=wb_io_bus COCOTB_TEST_MODULES=test_wb_io_bus_cocotb VERILOG_SOURCES="$(WB_IO_BUS_SOURCES)"

test-dshot-out-cocotb: check-cocotb
	rm -rf sim_build results.xml
	$(MAKE) -C . sim TOPLEVEL=dshot_out COCOTB_TEST_MODULES=test_dshot_out_cocotb VERILOG_SOURCES="$(DSHOT_OUT_SOURCES)" EXTRA_ARGS="$(EXTRA_ARGS) -GCLK_FREQ_HZ=100000000"

test-wb-neopx-cocotb: check-cocotb
	rm -rf sim_build results.xml
	$(MAKE) -C . sim TOPLEVEL=wb_neoPx COCOTB_TEST_MODULES=test_wb_neoPx_cocotb VERILOG_SOURCES="$(WB_NEOPX_SOURCES)" EXTRA_ARGS="$(EXTRA_ARGS) -GCLK_FREQ_HZ=100000000"

test-pwmdecoder-cocotb: check-cocotb
	rm -rf sim_build results.xml
	$(MAKE) -C . sim TOPLEVEL=pwmdecoder COCOTB_TEST_MODULES=test_pwmdecoder_cocotb VERILOG_SOURCES="$(PWMDECODER_SOURCES)" EXTRA_ARGS="$(EXTRA_ARGS) -GCLK_FREQ_HZ=100000000"

test-wb-esc-uart-cocotb: check-cocotb
	rm -rf sim_build results.xml
	$(MAKE) -C . sim TOPLEVEL=wb_esc_uart COCOTB_TEST_MODULES=test_wb_esc_uart_cocotb VERILOG_SOURCES="$(WB_ESC_UART_SOURCES)" EXTRA_ARGS="$(EXTRA_ARGS) -GCLK_FREQ_HZ=100000000"

test-e2e-fcsp-wb-io-cocotb: check-cocotb
	rm -rf sim_build results.xml
	$(MAKE) -C . sim TOPLEVEL=fcsp_offloader_top COCOTB_TEST_MODULES=test_e2e_fcsp_wb_io_cocotb VERILOG_SOURCES="$(FCSP_TOP_SOURCES)"

test-stream-packetizer-cocotb: check-cocotb
	rm -rf sim_build results.xml
	$(MAKE) -C . sim TOPLEVEL=fcsp_stream_packetizer COCOTB_TEST_MODULES=test_fcsp_stream_packetizer_cocotb VERILOG_SOURCES="$(STREAM_PACKETIZER_SOURCES)" EXTRA_ARGS="$(EXTRA_ARGS) -GMAX_LEN=16 -GTIMEOUT=1000"

test-e2e-esc-roundtrip-cocotb: check-cocotb
	rm -rf sim_build results.xml
	$(MAKE) -C . sim TOPLEVEL=fcsp_offloader_top COCOTB_TEST_MODULES=test_e2e_esc_roundtrip_cocotb VERILOG_SOURCES="$(FCSP_TOP_SOURCES)"

test-e2e-switching-cocotb: check-cocotb
	rm -rf sim_build results.xml
	$(MAKE) -C . sim TOPLEVEL=fcsp_offloader_top COCOTB_TEST_MODULES=test_e2e_switching_cocotb VERILOG_SOURCES="$(FCSP_TOP_SOURCES)"

test-e2e-led-cocotb: check-cocotb
	rm -rf sim_build results.xml
	$(MAKE) -C . sim TOPLEVEL=fcsp_offloader_top COCOTB_TEST_MODULES=test_e2e_led_cocotb VERILOG_SOURCES="$(FCSP_TOP_SOURCES)"

test-e2e-neopixel-cocotb: check-cocotb
	rm -rf sim_build results.xml
	$(MAKE) -C . sim TOPLEVEL=fcsp_offloader_top COCOTB_TEST_MODULES=test_e2e_neopixel_cocotb VERILOG_SOURCES="$(FCSP_TOP_SOURCES)"

test-e2e-blheli-boot-cocotb: check-cocotb
	rm -rf sim_build results.xml
	$(MAKE) -C . sim TOPLEVEL=fcsp_offloader_top COCOTB_TEST_MODULES=test_e2e_blheli_boot_cocotb VERILOG_SOURCES="$(FCSP_TOP_SOURCES)"

test-e2e-spi-tx-cocotb: check-cocotb
	rm -rf sim_build results.xml
	$(MAKE) -C . sim TOPLEVEL=fcsp_offloader_top COCOTB_TEST_MODULES=test_e2e_spi_tx_cocotb VERILOG_SOURCES="$(FCSP_TOP_SOURCES)"

test-esc-protocol-cocotb: check-cocotb
	rm -rf sim_build results.xml
	$(MAKE) -C . sim TOPLEVEL=fcsp_offloader_top COCOTB_TEST_MODULES=test_esc_protocol_cocotb VERILOG_SOURCES="$(FCSP_TOP_SOURCES)"

test-spi-routing-policy-cocotb: check-cocotb
	rm -rf sim_build results.xml
	$(MAKE) -C . sim TOPLEVEL=fcsp_offloader_top COCOTB_TEST_MODULES=test_spi_routing_policy_cocotb VERILOG_SOURCES="$(FCSP_TOP_SOURCES)"

test-e2e-all-cocotb: test-top-cocotb test-top-cocotb-experimental test-serial-mux-cocotb test-wb-led-cocotb test-fcsp-wb-master-cocotb test-wb-io-bus-cocotb test-dshot-out-cocotb test-wb-neopx-cocotb test-pwmdecoder-cocotb test-wb-esc-uart-cocotb test-e2e-fcsp-wb-io-cocotb test-e2e-switching-cocotb test-e2e-led-cocotb test-e2e-neopixel-cocotb test-e2e-blheli-boot-cocotb test-e2e-spi-tx-cocotb test-esc-protocol-cocotb test-spi-routing-policy-cocotb

# Default smoke gate stays deterministic and fast.
test-fcsp-smoke-cocotb: test-cocotb test-tx-arbiter-cocotb

test-teaching-examples-cocotb: test-wb-example-cocotb test-axis-example-cocotb

test-python:
	$(PYTEST) -q tests

test-hw-scripts-sim:
	$(PYTEST) -q tests/test_hw_scripts_sim.py

test-all: test-python test-hw-scripts-sim test-fcsp-smoke-cocotb test-teaching-examples-cocotb

# Strict gate includes top-level and integration-oriented suites.
test-all-strict: test-all test-top-cocotb test-top-cocotb-experimental test-serial-mux-cocotb test-wb-led-cocotb test-fcsp-wb-master-cocotb test-wb-io-bus-cocotb test-dshot-out-cocotb test-wb-neopx-cocotb test-pwmdecoder-cocotb test-wb-esc-uart-cocotb test-e2e-fcsp-wb-io-cocotb test-stream-packetizer-cocotb test-e2e-esc-roundtrip-cocotb test-e2e-switching-cocotb test-e2e-led-cocotb test-e2e-neopixel-cocotb test-e2e-blheli-boot-cocotb test-e2e-spi-tx-cocotb test-esc-protocol-cocotb test-spi-routing-policy-cocotb

fit-evidence-snapshot:
	bash ../scripts/generate_fit_evidence_snapshot.sh

fit-evidence-snapshot-live:
	RUN_SIM_GATE=1 bash ../scripts/generate_fit_evidence_snapshot.sh

COCOTB_MAKEFILES := $(shell $(COCOTB_CONFIG) --makefiles 2>/dev/null)
ifneq ($(COCOTB_MAKEFILES),)
include $(COCOTB_MAKEFILES)/Makefile.sim
endif
