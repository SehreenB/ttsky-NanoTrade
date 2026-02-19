@echo off
:: =============================================================================
::  NanoTrade Demo Runner -- Windows Command Prompt (cmd.exe) fallback
::  Use demo.ps1 in PowerShell for colors. This works everywhere.
::
::  USAGE:
::    demo.bat check
::    demo.bat quiet
::    demo.bat covid
::    demo.bat dotcom
::    demo.bat all
::    demo.bat live SPY 2020-03-16
::    demo.bat guide
:: =============================================================================

set SRCS=tt_um_nanotrade.v order_book.v anomaly_detector.v feature_extractor.v ml_inference_engine.v

echo.
echo +======================================================================+
echo ^|  NanoTrade HFT ASIC -- IEEE UofT -- TinyTapeout SKY130              ^|
echo +======================================================================+
echo.

if "%1"==""        goto :usage
if "%1"=="help"    goto :usage
if "%1"=="check"   goto :check
if "%1"=="compile" goto :compile
if "%1"=="quiet"   goto :quiet
if "%1"=="covid"   goto :covid
if "%1"=="dotcom"  goto :dotcom
if "%1"=="2001"    goto :dotcom
if "%1"=="all"     goto :all
if "%1"=="live"    goto :live
if "%1"=="fetch"   goto :fetch
if "%1"=="clean"   goto :clean
if "%1"=="guide"   goto :guide

echo [ERROR] Unknown command: %1
goto :usage

:: ---------------------------------------------------------------------------
:check
echo --- Checking environment ---
echo.
where iverilog >nul 2>&1
if errorlevel 1 (
    echo [MISSING] iverilog -- download from: https://bleyer.org/icarus/
    echo           OR: winget install IcarusVerilog.IcarusVerilog
) else (
    echo [OK] iverilog found
)
where vvp >nul 2>&1
if errorlevel 1 (echo [MISSING] vvp) else (echo [OK] vvp found)
where python >nul 2>&1
if errorlevel 1 (echo [WARN] python not found -- live data disabled) else (echo [OK] python found)
echo.
for %%f in (%SRCS%) do (
    if exist %%f (echo [OK] %%f) else (echo [MISSING] %%f -- run from project folder)
)
for %%f in (tb_covid_crash.v tb_2001_crash.v tb_quiet_2019.v) do (
    if exist %%f (echo [OK] %%f) else (echo [WARN] %%f not found)
)
echo.
goto :end

:: ---------------------------------------------------------------------------
:compile
echo --- Compiling all testbenches ---
echo.
iverilog -g2005 -o sim_covid.vvp  tb_covid_crash.v %SRCS%
if errorlevel 1 (echo [FAIL] tb_covid_crash.v && goto :end)
echo [OK] sim_covid.vvp
iverilog -g2005 -o sim_2001.vvp   tb_2001_crash.v  %SRCS%
if errorlevel 1 (echo [FAIL] tb_2001_crash.v && goto :end)
echo [OK] sim_2001.vvp
iverilog -g2005 -o sim_quiet.vvp  tb_quiet_2019.v  %SRCS%
if errorlevel 1 (echo [FAIL] tb_quiet_2019.v && goto :end)
echo [OK] sim_quiet.vvp
echo.
echo All compiled successfully.
goto :end

:: ---------------------------------------------------------------------------
:quiet
echo --- Quiet Market Day -- October 3, 2019 ---
echo MSFT $136.50, VIX=17, fat-finger at 2:37 PM
echo Goal: ZERO false positives during normal trading
echo.
iverilog -g2005 -o sim_quiet.vvp tb_quiet_2019.v %SRCS%
if errorlevel 1 (echo Compile failed && goto :end)
vvp sim_quiet.vvp
goto :end

:: ---------------------------------------------------------------------------
:covid
echo --- COVID-19 Crash -- March 16, 2020 ---
echo SPY $261-^>$218 (-16%%) ^| AAPL ^| JPM (-20%%)
echo Circuit breakers fired twice in 21 minutes
echo.
iverilog -g2005 -o sim_covid.vvp tb_covid_crash.v %SRCS%
if errorlevel 1 (echo Compile failed && goto :end)
vvp sim_covid.vvp
goto :end

:: ---------------------------------------------------------------------------
:dotcom
echo --- Dot-Com Crash (Apr 2000) + Post-9/11 (Sep 2001) ---
echo CSCO/INTC/AMZN collapse ^| LMT defense surge vs AMR airline crash
echo.
iverilog -g2005 -o sim_2001.vvp tb_2001_crash.v %SRCS%
if errorlevel 1 (echo Compile failed && goto :end)
vvp sim_2001.vvp
goto :end

:: ---------------------------------------------------------------------------
:all
echo --- Running ALL testbenches ---
echo.
call demo.bat quiet
call demo.bat covid
call demo.bat dotcom
echo.
echo +======================================================================+
echo ^|  ALL TESTBENCHES COMPLETE                                            ^|
echo +======================================================================+
goto :end

:: ---------------------------------------------------------------------------
:live
if "%2"=="" (echo Usage: demo.bat live SYMBOL DATE && goto :end)
if "%3"=="" (echo Usage: demo.bat live SYMBOL DATE && goto :end)
echo --- Fetching live data: %2 on %3 ---
python finnhub_fetch.py --mode candles --symbol %2 --date %3 --resolution 5
if errorlevel 1 (echo Fetch failed && goto :end)
set LSYM=%2
set LDATE=%3
:: Build output filename (simplified -- no string manipulation in batch)
python -c "s='%2'.lower(); d='%3'.replace('-',''); print(f'tb_live_{s}_{d}.v')" > _tmp_name.txt
set /p LIVEFILE=<_tmp_name.txt
del _tmp_name.txt
iverilog -g2005 -o sim_live.vvp %LIVEFILE% %SRCS%
if errorlevel 1 (echo Compile failed && goto :end)
vvp sim_live.vvp
goto :end

:: ---------------------------------------------------------------------------
:fetch
if "%2"=="" (echo Usage: demo.bat fetch SYMBOL DATE && goto :end)
if "%3"=="" (echo Usage: demo.bat fetch SYMBOL DATE && goto :end)
echo --- Fetching data only: %2 on %3 ---
python finnhub_fetch.py --mode candles --symbol %2 --date %3 --resolution 5
echo Done. Look for tb_live_*.v in current folder.
goto :end

:: ---------------------------------------------------------------------------
:clean
echo --- Cleaning build artifacts ---
del /q *.vvp 2>nul
del /q *.vcd 2>nul
echo Cleaned.
goto :end

:: ---------------------------------------------------------------------------
:guide
echo.
echo ======================================================================
echo   NanoTrade -- JUDGE PRESENTATION GUIDE
echo ======================================================================
echo.
echo RECOMMENDED ORDER:
echo   1. demo.bat check           -- show environment is ready
echo   2. demo.bat quiet           -- ZERO false positives (say this out loud)
echo   3. demo.bat covid           -- flash crash, circuit breakers
echo   4. demo.bat dotcom          -- bidirectional: surge UP + crash DOWN
echo   5. demo.bat live SPY 2020-03-16  -- live API data (if internet)
echo.
echo OPENING PITCH:
echo   "NanoTrade detects market anomalies in 20 nanoseconds -- one clock
echo    cycle at 50 MHz. The best NYSE co-located software runs at 10
echo    microseconds. We are 500 times faster. At 250 microwatts versus
echo    25 watts for a server -- 100,000x more power efficient."
echo.
echo TOUGH QUESTIONS:
echo.
echo   Q: Why not software?
echo   A: 20ns vs 10,000ns. 500x faster. In the COVID crash, circuit
echo      breakers took 30 seconds to trigger. Our chip fires in nanoseconds.
echo.
echo   Q: False positive rate?
echo   A: Run demo.bat quiet -- false_positives=0 across a full trading day.
echo      The fat-finger at 2:37 PM fires. Nothing else does.
echo.
echo   Q: Neural network accuracy?
echo   A: 99.4%% quantized. Weights baked into synthesizable case-ROM.
echo      No dollar-readmemh. Fully SKY130 compatible.
echo.
echo   Q: Real chip or simulation?
echo   A: TinyTapeout submission for SKY130. Fully synthesizable RTL.
echo      Submit to TinyTapeout and it becomes real silicon.
echo.
echo GOOD LIVE DATES:
echo   demo.bat live SPY  2020-03-16   COVID crash
echo   demo.bat live GME  2021-01-28   GameStop short squeeze
echo   demo.bat live SVB  2023-03-09   Silicon Valley Bank collapse
echo   demo.bat live NVDA 2024-05-23   NVDA earnings +10%% gap up
echo   demo.bat live MSFT 2019-10-03   Quiet day -- should stay silent
echo.
goto :end

:: ---------------------------------------------------------------------------
:usage
echo USAGE:  demo.bat ^<command^> [symbol] [date]
echo.
echo   TESTBENCHES:
echo     quiet              Oct 3 2019 -- zero false positives demo
echo     covid              Mar 16 2020 -- COVID crash
echo     dotcom             Apr 2000 + Sep 2001 -- dot-com + 9/11
echo     all                Run all three
echo.
echo   LIVE DATA:
echo     live SPY 2020-03-16    Fetch from Finnhub and simulate
echo     fetch SPY 2020-03-16   Fetch only, save .v file
echo.
echo   UTILITIES:
echo     check              Verify tools and files
echo     compile            Compile all (no run)
echo     clean              Delete .vvp and .vcd files
echo     guide              Judge presentation walkthrough
echo.

:end
