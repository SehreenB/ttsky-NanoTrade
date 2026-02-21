#!/bin/bash
# NanoTrade — Demo 1: Kill the Flash Crash
# Run this from inside the project folder (where all .v files are)
# Mac/Linux only. Windows: use run_demo1.ps1

set -e

echo ""
echo "NanoTrade — Demo 1 setup"
echo "========================"

# Check iverilog is installed
if ! command -v iverilog &> /dev/null; then
    echo ""
    echo "ERROR: iverilog not found."
    echo ""
    echo "Install it:"
    echo "  Mac:   brew install icarus-verilog"
    echo "  Linux: sudo apt-get install iverilog"
    echo ""
    exit 1
fi

echo "iverilog found: $(iverilog -V 2>&1 | head -1)"
echo ""
echo "Compiling..."

iverilog -g2012 -o sim_flash2010 \
    tb_flash_crash_2010.v \
    tt_um_nanotrade.v \
    order_book.v \
    anomaly_detector.v \
    feature_extractor.v \
    ml_inference_engine.v \
    cascade_detector.v

echo "Compiled OK — binary: sim_flash2010"
echo ""
echo "Running demo..."
echo ""

vvp sim_flash2010
