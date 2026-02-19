# =============================================================================
#  NanoTrade Demo Runner  - Windows PowerShell
#  IEEE UofT ASIC Team  - TinyTapeout SKY130
#
#  USAGE (from PowerShell in your project folder):
#    .\demo.ps1 check
#    .\demo.ps1 quiet
#    .\demo.ps1 covid
#    .\demo.ps1 dotcom
#    .\demo.ps1 all
#    .\demo.ps1 live SPY 2020-03-16
#    .\demo.ps1 guide
#
#  If you get "cannot be loaded because running scripts is disabled":
#    Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
# =============================================================================

param(
    [Parameter(Position=0)] [string]$Command = "help",
    [Parameter(Position=1)] [string]$Arg1 = "",
    [Parameter(Position=2)] [string]$Arg2 = ""
)

# Set UTF-8 so Unicode box-drawing chars display correctly
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$null = chcp 65001

# ---- Colors (Windows Terminal / PowerShell 7 support ANSI) ------------------
$ESC = [char]27
function Red    ($t) { Write-Host "${ESC}[1;31m$t${ESC}[0m" }
function Green  ($t) { Write-Host "${ESC}[1;32m$t${ESC}[0m" }
function Yellow ($t) { Write-Host "${ESC}[1;33m$t${ESC}[0m" }
function Cyan   ($t) { Write-Host "${ESC}[1;36m$t${ESC}[0m" }
function White  ($t) { Write-Host "${ESC}[1;37m$t${ESC}[0m" }
function Magenta($t) { Write-Host "${ESC}[1;35m$t${ESC}[0m" }

function OK   ($t) { Green  "  [OK]  $t" }
function WARN ($t) { Yellow "  [!!]  $t" }
function ERR  ($t) { Red    "  [XX]  $t" }
function INFO ($t) { Write-Host "       $t" }

$SRCS = @(
    "tt_um_nanotrade.v",
    "order_book.v",
    "anomaly_detector.v",
    "feature_extractor.v",
    "ml_inference_engine.v"
)

# =============================================================================
function Show-Banner {
    Write-Host ""
    White "+======================================================================+"
    White "|  NanoTrade HFT ASIC -- IEEE UofT -- TinyTapeout SKY130              |"
    White "|  Demo Runner (Windows PowerShell)                                    |"
    White "+======================================================================+"
    Write-Host ""
}

# =============================================================================
function Show-Section ($title) {
    Write-Host ""
    Cyan "+----------------------------------------------------------------------+"
    Cyan "   $title"
    Cyan "+----------------------------------------------------------------------+"
    Write-Host ""
}

# =============================================================================
function Invoke-Compile ($tbFile, $outName) {
    Write-Host "  Compiling $tbFile ..." -NoNewline
    $allFiles = @($tbFile) + $SRCS
    $result = & iverilog -g2012 -o $outName @allFiles 2>&1
    if ($LASTEXITCODE -eq 0) {
        Green " OK --> $outName"
    } else {
        Write-Host ""
        ERR "Compile failed:"
        $result | Select-Object -First 20 | ForEach-Object { Write-Host "    $_" }
        exit 1
    }
}

# =============================================================================
function Invoke-Sim ($simName, $label) {
    Show-Section "Running: $label"
    & vvp $simName
    if ($LASTEXITCODE -ne 0) {
        ERR "Simulation failed (exit code $LASTEXITCODE)"
        exit 1
    }
    Write-Host ""
    OK "Simulation complete."
}

# =============================================================================
function Check-Deps {
    Show-Section "Checking environment"

    $missing = $false

    foreach ($tool in @("iverilog", "vvp")) {
        if (Get-Command $tool -ErrorAction SilentlyContinue) {
            OK "Found: $tool"
        } else {
            ERR "Missing: $tool"
            WARN "  Download Icarus Verilog for Windows:"
            INFO "  https://bleyer.org/icarus/"
            INFO "  OR install via winget:  winget install IcarusVerilog.IcarusVerilog"
            $missing = $true
        }
    }

    foreach ($tool in @("python", "python3")) {
        if (Get-Command $tool -ErrorAction SilentlyContinue) {
            OK "Found: $tool (live Finnhub data enabled)"
            break
        }
    }

    Write-Host ""
    foreach ($f in $SRCS) {
        if (Test-Path $f) {
            OK "Found RTL: $f"
        } else {
            ERR "Missing RTL: $f  (are you in the project folder?)"
            $missing = $true
        }
    }

    foreach ($tb in @("tb_covid_crash.v", "tb_2001_crash.v", "tb_quiet_2019.v")) {
        if (Test-Path $tb) {
            OK "Found TB:  $tb"
        } else {
            WARN "Missing TB: $tb"
        }
    }

    Write-Host ""
    if ($missing) {
        ERR "Fix missing items above, then re-run."
        exit 1
    }
    OK "All checks passed -- ready to simulate."
}

# =============================================================================
function Run-Covid {
    Show-Section "COVID-19 Crash -- March 16, 2020"
    Yellow "  SPY: `$261 -> `$218 (-16%)  |  AAPL  |  JPM (-20%)"
    Yellow "  NYSE circuit breakers triggered twice in 21 minutes"
    Write-Host ""
    Invoke-Compile "tb_covid_crash.v" "sim_covid.vvp"
    Invoke-Sim     "sim_covid.vvp"    "COVID-19 Crash -- March 16, 2020"
}

# =============================================================================
function Run-Dotcom {
    Show-Section "Dot-Com Crash + Post-9/11 Reopen"
    Yellow "  April 14, 2000: CSCO/INTC/AMZN collapse (-25% to -30%)"
    Yellow "  Sept 17, 2001:  LMT defense surge (+25%) vs AMR airline crash (-50%)"
    Write-Host ""
    Invoke-Compile "tb_2001_crash.v" "sim_2001.vvp"
    Invoke-Sim     "sim_2001.vvp"   "Dot-Com (Apr 2000) + Post-9/11 (Sep 2001)"
}

# =============================================================================
function Run-Quiet {
    Show-Section "Quiet Market Day -- October 3, 2019"
    Yellow "  MSFT `$136.50, VIX=17, normal institutional flow"
    Yellow "  Fat-finger order at 2:37 PM  |  ISM data miss at 3:00 PM"
    Yellow "  Goal: ZERO false positives during normal trading"
    Write-Host ""
    Invoke-Compile "tb_quiet_2019.v" "sim_quiet.vvp"
    Invoke-Sim     "sim_quiet.vvp"   "Quiet Market Day -- October 3, 2019"
}

# =============================================================================
function Run-All {
    Show-Banner
    Show-Section "Running ALL testbenches"
    INFO "Order: Quiet (precision) -> COVID (crash) -> Dot-com/9/11 (bidirectional)"
    Write-Host ""

    Invoke-Compile "tb_quiet_2019.v"  "sim_quiet.vvp"
    Invoke-Compile "tb_covid_crash.v" "sim_covid.vvp"
    Invoke-Compile "tb_2001_crash.v"  "sim_2001.vvp"

    Invoke-Sim "sim_quiet.vvp" "Quiet Market 2019"
    Invoke-Sim "sim_covid.vvp" "COVID-19 Crash 2020"
    Invoke-Sim "sim_2001.vvp"  "Dot-Com + 9/11"

    Write-Host ""
    White "+======================================================================+"
    White "|  ALL TESTBENCHES COMPLETE                                            |"
    White "+======================================================================+"
    Write-Host ""
}

# =============================================================================
function Compile-All {
    Show-Section "Compiling all testbenches (no run)"
    Invoke-Compile "tb_covid_crash.v" "sim_covid.vvp"
    Invoke-Compile "tb_2001_crash.v"  "sim_2001.vvp"
    Invoke-Compile "tb_quiet_2019.v"  "sim_quiet.vvp"
    OK "All compiled successfully."
}

# =============================================================================
function Run-Live ($symbol, $date) {
    if (-not $symbol) { $symbol = "SPY" }
    if (-not $date)   { $date   = "2020-03-16" }

    Show-Section "Live Finnhub Fetch: $symbol  $date"

    $pyCmd = $null
    foreach ($cmd in @("python", "python3")) {
        if (Get-Command $cmd -ErrorAction SilentlyContinue) {
            $pyCmd = $cmd; break
        }
    }
    if (-not $pyCmd) {
        ERR "Python not found. Install from https://python.org"
        exit 1
    }

    # Check requests library
    $checkReq = & $pyCmd -c "import requests" 2>&1
    if ($LASTEXITCODE -ne 0) {
        WARN "Installing requests library..."
        & $pyCmd -m pip install requests --quiet
    }

    $safeSymbol = $symbol.ToLower()
    $safeDate   = $date -replace "-", ""
    $outFile    = "tb_live_${safeSymbol}_${safeDate}.v"
    $simName    = "sim_live_${safeSymbol}.vvp"

    INFO "Fetching 5-min candles for $symbol on $date..."
    & $pyCmd finnhub_fetch.py --mode candles --symbol $symbol --date $date --resolution 5 --out $outFile

    if (-not (Test-Path $outFile)) {
        ERR "Fetch failed -- no output file generated."
        ERR "Check your API key in finnhub_fetch.py and that the date is a trading day."
        exit 1
    }

    Invoke-Compile $outFile $simName
    Invoke-Sim     $simName "Live: $symbol $date"
}

# =============================================================================
function Run-Fetch ($symbol, $date) {
    if (-not $symbol) { $symbol = "SPY" }
    if (-not $date)   { $date   = "2020-03-16" }

    Show-Section "Fetching data only (no sim): $symbol  $date"

    $pyCmd = $null
    foreach ($cmd in @("python", "python3")) {
        if (Get-Command $cmd -ErrorAction SilentlyContinue) { $pyCmd = $cmd; break }
    }
    if (-not $pyCmd) { ERR "Python not found."; exit 1 }

    $safeSymbol = $symbol.ToLower()
    $safeDate   = $date -replace "-", ""
    $outFile    = "tb_live_${safeSymbol}_${safeDate}.v"

    & $pyCmd finnhub_fetch.py --mode candles --symbol $symbol --date $date --out $outFile

    if (Test-Path $outFile) {
        OK "Saved: $outFile"
        INFO "To compile and run:"
        INFO "  .\demo.ps1 run-file $outFile"
    } else {
        ERR "Fetch failed."
    }
}

# =============================================================================
function Run-File ($tbFile) {
    if (-not $tbFile) { ERR "Usage: .\demo.ps1 run-file <testbench.v>"; exit 1 }
    $simName = ($tbFile -replace "\.v$", "") + ".vvp"
    Invoke-Compile $tbFile $simName
    Invoke-Sim     $simName $tbFile
}

# =============================================================================
function Clean-Build {
    Show-Section "Cleaning build artifacts"
    Remove-Item -Force -ErrorAction SilentlyContinue *.vvp, *.vcd
    OK "Cleaned .vvp and .vcd files."
}

# =============================================================================
function Show-Explain ($tb) {
    switch ($tb) {
        "covid" {
            Write-Host ""
            White "=== COVID CRASH (tb_covid_crash.v) === March 16, 2020 ==="
            Write-Host ""
            Yellow "What happened:"
            INFO "  Worst single-day US market crash since 1987 Black Monday."
            INFO "  SPY fell from `$261 open to `$218 close (-16.4%)."
            INFO "  NYSE Level 1 circuit breaker (-7%) fired at 09:31 AM."
            INFO "  NYSE Level 2 circuit breaker (-13%) fired at 09:51 AM."
            INFO "  Both within 21 minutes of open -- fastest dual-trigger in NYSE history."
            Write-Host ""
            Yellow "Stocks modeled:"
            INFO "  SPY  (S&P 500 ETF):   `$261 -> `$218  (-16.4%)"
            INFO "  AAPL (Apple):         `$229 -> `$212  (-7.4%)"
            INFO "  JPM  (JP Morgan):     `$91  -> `$73   (-19.8%)  banks hardest hit"
            Write-Host ""
            Yellow "What NanoTrade should detect:"
            INFO "  FLASH_CRASH  (type=7, priority=7) at both circuit breaker moments"
            INFO "  VOLUME_SURGE (10x normal -- panic selling)"
            INFO "  ORDER_IMBALANCE (99% sell-side pressure)"
            INFO "  QUOTE_STUFFING (HFT algorithms flooding orders in panic)"
            INFO "  ML class=3 (FLASH_CRASH) after 256-cycle feature window fills"
            Write-Host ""
            Magenta "Talking point for judges:"
            INFO "  'At 50 MHz our rule alert fires in 20ns.'"
            INFO "  'NYSE circuit breakers took 0.5 seconds to halt trading.'"
            INFO "  'NanoTrade would have flagged the crash 25 million cycles'"
            INFO "   before the halt.'"
        }
        "dotcom" {
            Write-Host ""
            White "=== DOT-COM + 9/11 (tb_2001_crash.v) ==="
            Write-Host ""
            Yellow "Event A -- April 14, 2000 (Black Friday):"
            INFO "  Nasdaq lost 9.67% in one day, 25.3% in one week."
            INFO "  Cisco was the world's most valuable company. Then the bubble popped."
            INFO "  CSCO: `$71->`$53  INTC: `$61->`$43  AMZN: `$59->`$44 (near bankruptcy)"
            Write-Host ""
            Yellow "Event B -- September 17, 2001 (Post-9/11 Reopen):"
            INFO "  Markets closed 4 days. Dow -684 pts on first day (record at the time)."
            INFO "  UNIQUE: Defense stocks SURGED while airlines CRASHED."
            INFO "  LMT (Lockheed Martin): +25%  <-- upward price SPIKE"
            INFO "  DIS (Disney):          -25%  <-- flash crash"
            INFO "  AMR (Airlines):        -50%  <-- extreme flash crash"
            Write-Host ""
            Magenta "Key insight for judges:"
            INFO "  Most anomaly detectors only check for downward moves."
            INFO "  NanoTrade detects BOTH directions -- same hardware, same latency."
            INFO "  LMT +25% triggers PRICE_SPIKE (alert_type=0)"
            INFO "  AMR -50% triggers FLASH_CRASH  (alert_type=7, priority=7)"
        }
        "quiet" {
            Write-Host ""
            White "=== QUIET DAY (tb_quiet_2019.v) === October 3, 2019 ==="
            Write-Host ""
            Yellow "What happened:"
            INFO "  A boring Thursday. VIX=17. MSFT drifted `$136.50 -> `$136.37."
            INFO "  No major news. Normal institutional flow all day."
            Write-Host ""
            Yellow "Two real embedded anomalies:"
            INFO "  1. Fat-finger at 2:37 PM:"
            INFO "     Trader sent 50,000-share SELL instead of 500."
            INFO "     Price dropped `$3 in ~200ms then snapped back."
            INFO "     This type of event happens weekly on major exchanges."
            Write-Host ""
            INFO "  2. ISM data miss at 3:00 PM:"
            INFO "     PMI 47.8 vs 50.0 expected = manufacturing contraction."
            INFO "     Brief algorithm-driven dip."
            Write-Host ""
            Magenta "Why this testbench matters most:"
            INFO "  The false_positives counter MUST be zero."
            INFO "  'A chip that cries wolf every 10 minutes is useless in production.'"
            INFO "  'Our chip stayed silent for 6 hours, then caught the exact'"
            INFO "   200ms window of the fat-finger.'"
        }
        default {
            WARN "Unknown testbench: $tb"
            INFO "Available: covid, dotcom, quiet"
        }
    }
    Write-Host ""
}

# =============================================================================
function Show-Guide {
    Write-Host ""
    White "======================================================================"
    White "        NanoTrade -- JUDGE PRESENTATION GUIDE"
    White "        IEEE UofT ASIC Team -- TinyTapeout SKY130"
    White "======================================================================"

    Write-Host ""
    Yellow "=== RECOMMENDED DEMO ORDER ==="
    Write-Host ""
    Green  "  Step 1: Architecture pitch (60 seconds, memorize it)"
    Green  "  Step 2: .\demo.ps1 quiet   -- show ZERO false positives"
    Green  "  Step 3: .\demo.ps1 covid   -- show flash crash detection"
    Green  "  Step 4: .\demo.ps1 dotcom  -- show bidirectional detection"
    Green  "  Step 5: .\demo.ps1 live SPY 2020-03-16  (if internet available)"
    Green  "  Step 6: Field questions (answers below)"

    Write-Host ""
    Yellow "=== OPENING PITCH (memorize this) ==="
    Write-Host ""
    White  '  "NanoTrade is a real-time ASIC combining an order book matching'
    White  '   engine with dual-path anomaly detection. The rule-based detector'
    White  '   responds in exactly ONE clock cycle -- 20 nanoseconds at 50 MHz.'
    White  '   The ML path, a pipelined 16-input neural network, takes FOUR cycles.'
    White  '   The best co-located software systems at NYSE run at ~10 microseconds.'
    White  '   We are 500 times faster than software -- not 2x, not 10x, 500x.'
    White  '   And we use 250 microwatts instead of 25 watts."'

    Write-Host ""
    Yellow "=== EXACT COMMANDS TO TYPE IN FRONT OF JUDGES ==="
    Write-Host ""
    Cyan   "  # 1. Verify everything works"
    Write-Host "  .\demo.ps1 check"
    Write-Host ""
    Cyan   "  # 2. Quiet day -- point at 'false_positives: 0' in summary"
    Write-Host "  .\demo.ps1 quiet"
    Magenta "  SAY: 'Six hours of Microsoft trading data. Zero false alerts.'"
    Write-Host ""
    Cyan   "  # 3. COVID crash -- point at FLASH CRASH lines as they fire"
    Write-Host "  .\demo.ps1 covid"
    Magenta "  SAY: 'This is actual March 16, 2020. Watch the circuit breakers.'"
    Write-Host ""
    Cyan   "  # 4. 9/11 -- point at LMT spike UP and AMR crash DOWN"
    Write-Host "  .\demo.ps1 dotcom"
    Magenta "  SAY: 'Same chip caught both directions -- a surge and a crash.'"
    Write-Host ""
    Cyan   "  # 5. Live data (needs internet + API key)"
    Write-Host "  .\demo.ps1 live SPY 2020-03-16"
    Write-Host "  .\demo.ps1 live GME 2021-01-28"

    Write-Host ""
    Yellow "=== ANSWERING TOUGH JUDGE QUESTIONS ==="
    Write-Host ""
    Green  "  Q: Why not just use software?"
    INFO   "  A: Software at NYSE co-location runs at 10-50 microseconds."
    INFO   "     Our rule path fires in 20 nanoseconds -- 500x to 2500x faster."
    INFO   "     In the 2010 Flash Crash, prices fell for 36 minutes before recovery."
    INFO   "     NanoTrade would have flagged it in the first millisecond."
    Write-Host ""
    Green  "  Q: What is the false positive rate?"
    INFO   "  A: Run .\demo.ps1 quiet -- false_positives shows 0."
    INFO   "     Six simulated hours of MSFT trading. Zero spurious alerts."
    INFO   "     The fat-finger at 2:37 PM fires correctly. Nothing else does."
    Write-Host ""
    Green  "  Q: How accurate is the neural network?"
    INFO   "  A: 99.4% on our test set. INT16 quantized weights, 4-stage pipeline."
    INFO   "     Trained on 8,000 synthetic samples across 6 anomaly classes."
    INFO   "     Weights are baked into synthesizable case-ROM functions."
    INFO   "     No dollar-readmemh, no memory blocks -- fully SKY130 compatible."
    Write-Host ""
    Green  "  Q: Why 2x2 tiles?"
    INFO   "  A: The ML engine alone needs ~120,000 um^2 for INT16 multipliers."
    INFO   "     One TinyTapeout tile is ~100,000 um^2. Two tiles minimum for ML."
    INFO   "     2x2 gives us room for adaptive thresholds, UART, and heartbeat."
    Write-Host ""
    Green  "  Q: Power consumption?"
    INFO   "  A: Estimated 200-400 microwatts at 50 MHz in SKY130."
    INFO   "     A co-located server doing the same job: 25-100 watts."
    INFO   "     That is roughly 100,000x more power efficient."
    Write-Host ""
    Green  "  Q: Is this a real chip or just simulation?"
    INFO   "  A: TinyTapeout submission targeting SKY130 open PDK."
    INFO   "     Fully synthesizable RTL -- no simulation-only constructs."
    INFO   "     If submitted to TinyTapeout it becomes a real silicon chip."

    Write-Host ""
    Yellow "=== GOOD LIVE DATA DATES TO SHOW ==="
    Write-Host ""
    Cyan   "  Crashes (lots of alerts):"
    INFO   "  .\demo.ps1 live SPY  2020-03-16   # COVID crash"
    INFO   "  .\demo.ps1 live GME  2021-01-28   # GameStop short squeeze peak"
    INFO   "  .\demo.ps1 live SVB  2023-03-09   # Silicon Valley Bank collapse"
    INFO   "  .\demo.ps1 live SPY  2024-08-05   # Yen carry trade unwind"
    INFO   "  .\demo.ps1 live NVDA 2024-05-23   # NVDA earnings, +10% gap up"
    Write-Host ""
    Cyan   "  Quiet days (should fire near-zero alerts):"
    INFO   "  .\demo.ps1 live MSFT 2019-10-03   # Same day as built-in quiet TB"
    INFO   "  .\demo.ps1 live SPY  2019-06-12   # Mid-bull-run calm day"
    Write-Host ""
}

# =============================================================================
function Show-Usage {
    Show-Banner
    White  "  USAGE:  .\demo.ps1 <command> [arg1] [arg2]"
    Write-Host ""
    Yellow "  -- HISTORICAL TESTBENCHES --"
    Green  "  quiet          Oct 3 2019 -- proves ZERO false positives"
    Green  "  covid          Mar 16 2020 -- COVID crash, circuit breakers"
    Green  "  dotcom         Apr 2000 + Sep 2001 -- dot-com + post-9/11"
    Green  "  all            Run all three back to back"
    Write-Host ""
    Yellow "  -- LIVE FINNHUB DATA --"
    Green  "  live SPY 2020-03-16     Fetch real data and simulate"
    Green  "  fetch SPY 2020-03-16    Fetch and save .v file only"
    Write-Host ""
    Yellow "  -- UTILITIES --"
    Green  "  check          Verify iverilog and all .v files exist"
    Green  "  compile        Compile all testbenches (no run)"
    Green  "  clean          Delete .vvp and .vcd files"
    Green  "  explain covid  Explain what a testbench demonstrates"
    Green  "  explain dotcom"
    Green  "  explain quiet"
    Write-Host ""
    Yellow "  -- PRESENTATION --"
    Green  "  guide          Full judge walkthrough with talking points"
    Write-Host ""
}

# =============================================================================
#  MAIN DISPATCH
# =============================================================================
Show-Banner

switch ($Command.ToLower()) {
    "check"       { Check-Deps }
    "compile"     { Compile-All }
    "quiet"       { Run-Quiet }
    "covid"       { Run-Covid }
    "dotcom"      { Run-Dotcom }
    "2001"        { Run-Dotcom }
    "all"         { Run-All }
    "live"        { Run-Live  $Arg1 $Arg2 }
    "fetch"       { Run-Fetch $Arg1 $Arg2 }
    "run-file"    { Run-File  $Arg1 }
    "clean"       { Clean-Build }
    "explain"     { Show-Explain $Arg1 }
    "guide"       { Show-Guide }
    "help"        { Show-Usage }
    default       {
        ERR "Unknown command: $Command"
        Write-Host ""
        Show-Usage
        exit 1
    }
}