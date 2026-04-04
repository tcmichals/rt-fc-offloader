SIM_DIR := $(CURDIR)
ROOT_DIR := $(abspath $(SIM_DIR)/..)

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
	$(ROOT_DIR)/rtl/fcsp/fcsp_serv_bridge.sv \
	$(ROOT_DIR)/rtl/fcsp/fcsp_tx_fifo.sv \
	$(ROOT_DIR)/rtl/fcsp/fcsp_tx_framer.sv \
	$(ROOT_DIR)/rtl/fcsp/fcsp_io_engines.sv

WB_EXAMPLE_SOURCES := \
	$(ROOT_DIR)/rtl/fcsp/examples/wb_status_regs.sv

AXIS_EXAMPLE_SOURCES := \
	$(ROOT_DIR)/rtl/fcsp/examples/axis_frame_stage.sv

export PYTHONPATH := $(SIM_DIR):$(SIM_DIR)/cocotb:$(PYTHONPATH)

SIM ?= verilator

.PHONY: test-cocotb test-python test-all test-top-cocotb test-wb-example-cocotb test-axis-example-cocotb test-fcsp-smoke-cocotb test-teaching-examples-cocotb fit-evidence-snapshot fit-evidence-snapshot-live

test-cocotb:
	rm -rf sim_build results.xml
	$(MAKE) -C . sim

test-top-cocotb:
	rm -rf sim_build results.xml
	$(MAKE) -C . sim TOPLEVEL=fcsp_offloader_top COCOTB_TEST_MODULES=test_fcsp_offloader_top_cocotb VERILOG_SOURCES="$(FCSP_TOP_SOURCES)"

test-wb-example-cocotb:
	rm -rf sim_build results.xml
	$(MAKE) -C . sim TOPLEVEL=wb_status_regs COCOTB_TEST_MODULES=test_wb_status_regs_cocotb VERILOG_SOURCES="$(WB_EXAMPLE_SOURCES)"

test-axis-example-cocotb:
	rm -rf sim_build results.xml
	$(MAKE) -C . sim TOPLEVEL=axis_frame_stage COCOTB_TEST_MODULES=test_axis_frame_stage_cocotb VERILOG_SOURCES="$(AXIS_EXAMPLE_SOURCES)"

test-fcsp-smoke-cocotb: test-cocotb test-top-cocotb

test-teaching-examples-cocotb: test-wb-example-cocotb test-axis-example-cocotb

test-python:
	pytest -q tests

test-all: test-python test-fcsp-smoke-cocotb test-teaching-examples-cocotb

fit-evidence-snapshot:
	bash ../scripts/generate_fit_evidence_snapshot.sh

fit-evidence-snapshot-live:
	RUN_SIM_GATE=1 bash ../scripts/generate_fit_evidence_snapshot.sh

COCOTB_MAKEFILES := $(shell cocotb-config --makefiles 2>/dev/null)
ifneq ($(COCOTB_MAKEFILES),)
include $(COCOTB_MAKEFILES)/Makefile.sim
endif
