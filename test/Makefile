# ============================================================
# Cocotb Makefile (CogniChip/local)
# Assumes RTL files are in repo root (../) and this Makefile is in test/
# Simulator: Icarus Verilog
# ============================================================

TOPLEVEL_LANG = verilog
SIM           = icarus

# Your DUT top module (must match your Verilog module name)
TOPLEVEL      = tt_um_nanotrade

# Cocotb python test module name (test.py -> MODULE=test)
MODULE        = test

# ------------------------------------------------------------
# RTL sources (adjust if your filenames differ)
# ------------------------------------------------------------
VERILOG_SOURCES = \
  $(PWD)/../tt_um_nanotrade.v \
  $(PWD)/../order_book.v \
  $(PWD)/../anomaly_detector.v \
  $(PWD)/../feature_extractor.v \
  $(PWD)/../ml_inference_engine.v \
  $(PWD)/../cascade_detector.v \
  $(PWD)/../circuit_breaker.v

# If you DO NOT have circuit_breaker.v, comment that line out:
#   $(PWD)/../circuit_breaker.v

# Optional: add include dirs if you use `include "file.vh"`
# EXTRA_ARGS += -I$(PWD)/../

# ------------------------------------------------------------
# Cocotb make rules
# ------------------------------------------------------------
include $(shell cocotb-config --makefiles)/Makefile.sim