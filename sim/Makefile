TOPLEVEL_LANG ?= verilog
TOPLEVEL ?= fcsp_parser
MODULE ?= test_fcsp_parser_cocotb

# FCSP parser RTL source
VERILOG_SOURCES ?= $(PWD)/../rtl/fcsp/fcsp_parser.sv

export PYTHONPATH := $(PWD):$(PWD)/cocotb:$(PYTHONPATH)

SIM ?= verilator

.PHONY: test-cocotb test-python test-all

test-cocotb:
	$(MAKE) -C . sim

test-python:
	pytest -q tests

test-all: test-python test-cocotb

include $(shell cocotb-config --makefiles)/Makefile.sim
