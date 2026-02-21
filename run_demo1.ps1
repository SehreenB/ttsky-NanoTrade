# NanoTrade — Demo 1: Kill the Flash Crash
# Run this from inside the project folder (where all .v files are)
# Windows PowerShell

Write-Host ""
Write-Host "NanoTrade — Demo 1 setup" -ForegroundColor White
Write-Host "========================" -ForegroundColor White

# Check iverilog
if (-not (Get-Command iverilog -ErrorAction SilentlyContinue)) {
    Write-Host ""
    Write-Host "ERROR: iverilog not found." -ForegroundColor Red
    Write-Host ""
    Write-Host "Install it: https://bleyer.org/icarus/"
    Write-Host "During install, check 'Add to PATH'"
    Write-Host ""
    exit 1
}

Write-Host "iverilog found." -ForegroundColor Green
Write-Host ""
Write-Host "Compiling..." -ForegroundColor Cyan

iverilog -g2012 -o sim_flash2010 `
    tb_flash_crash_2010.v `
    tt_um_nanotrade.v `
    order_book.v `
    anomaly_detector.v `
    feature_extractor.v `
    ml_inference_engine.v `
    cascade_detector.v

Write-Host "Compiled OK" -ForegroundColor Green
Write-Host ""
Write-Host "Running demo..." -ForegroundColor Cyan
Write-Host ""

vvp sim_flash2010
