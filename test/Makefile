SIM ?= icarus
WAVES ?= 1
TOPLEVEL_LANG ?= verilog
SRC_DIR = $(PWD)/../src
PROJECT_SOURCES = tt_um_nanotrade.v order_book.v anomaly_detector.v feature_extractor.v ml_inference_engine.v

include $(shell cocotb-config --makefiles)/Makefile.sim

TOPLEVEL = tb
MODULE   = test

VERILOG_SOURCES  = $(PWD)/tb.v
VERILOG_SOURCES += $(addprefix $(SRC_DIR)/,$(PROJECT_SOURCES))
