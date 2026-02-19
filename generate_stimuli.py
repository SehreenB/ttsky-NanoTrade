"""
NanoTrade Stock Data Pipeline  (v2 -- SKY130 Enhanced)
=======================================================
Downloads real historical stock data from Yahoo Finance and encodes
it into .memh stimulus files for the NanoTrade chip testbench.

Scenarios:
  1. Meme Frenzy   Jan 28 2021  -- GME, AMC, BB, NOK
  2. Flash Crash   May 06 2010  -- SPY, PG, AAPL, ACN
  3. COVID Crash   Mar 16 2020  -- SPY, JETS, TSLA, ZM
  4. Normal Quiet  Jun 04 2019  -- SPY, MSFT, KO, GLD

Usage:
  python generate_stimuli.py

Output:
  stimuli/<TICKER>_<DATE>_stimulus.memh   -- chip input (hex)
  stimuli/<TICKER>_<DATE>_golden.txt      -- expected alerts
  stimuli/<TICKER>_<DATE>_info.txt        -- human-readable summary
  stimuli/run_all_scenarios.ps1           -- PowerShell runner
  stimuli/run_all_scenarios.sh            -- bash runner
"""

import os
import sys
import math
import datetime

# -------------------------------------------------------------------------
# Check for yfinance
# -------------------------------------------------------------------------
try:
    import yfinance as yf
    YFINANCE = True
except ImportError:
    YFINANCE = False

OUTPUT_DIR = "stimuli"
os.makedirs(OUTPUT_DIR, exist_ok=True)

# -------------------------------------------------------------------------
# Scenario definitions
# -------------------------------------------------------------------------
SCENARIOS = [
    {
        "name": "Meme_Frenzy_Jan2021",
        "desc": "Reddit WallStreetBets short squeeze - GME, AMC, BB, NOK",
        "stocks": [
            {
                "ticker": "GME", "date": "2021-01-28",
                "desc": "GameStop - the epicenter. Price: $148->$483->$112",
                "expected": ["FLASH_CRASH", "ORDER_IMBALANCE", "PRICE_SPIKE"],
            },
            {
                "ticker": "AMC", "date": "2021-01-28",
                "desc": "AMC Entertainment - same frenzy, slightly calmer",
                "expected": ["FLASH_CRASH", "ORDER_IMBALANCE", "TRADE_VELOCITY", "PRICE_SPIKE"],
            },
            {
                "ticker": "BB", "date": "2021-01-28",
                "desc": "BlackBerry - moderate spike, tests sensitivity threshold",
                "expected": ["FLASH_CRASH", "ORDER_IMBALANCE", "TRADE_VELOCITY", "VOLUME_SURGE", "PRICE_SPIKE"],
            },
            {
                "ticker": "NOK", "date": "2021-01-28",
                "desc": "Nokia - quietest of the four, near false-positive boundary",
                "expected": ["FLASH_CRASH", "ORDER_IMBALANCE", "TRADE_VELOCITY", "PRICE_SPIKE"],
            },
        ],
    },
    {
        "name": "Flash_Crash_May2010",
        "desc": "Algorithmic flash crash - SPY, PG, AAPL, ACN",
        "stocks": [
            {
                "ticker": "SPY", "date": "2010-05-06",
                "desc": "S&P 500 ETF - broad market dropped 9% in 15 minutes",
                "expected": ["FLASH_CRASH_ML", "ORDER_IMBALANCE", "PRICE_SPIKE"],
            },
            {
                "ticker": "PG", "date": "2010-05-06",
                "desc": "Procter & Gamble - dropped from $60 to $0.01 momentarily",
                "expected": ["FLASH_CRASH_ML", "PRICE_SPIKE_ML"],
            },
            {
                "ticker": "AAPL", "date": "2010-05-06",
                "desc": "Apple - blue chip dragged down, tests broad impact",
                "expected": ["FLASH_CRASH", "ORDER_IMBALANCE", "VOLUME_SURGE", "PRICE_SPIKE"],
            },
            {
                "ticker": "ACN", "date": "2010-05-06",
                "desc": "Accenture - traded at literally $0.01, the most extreme case",
                "expected": ["FLASH_CRASH", "PRICE_SPIKE"],
            },
        ],
    },
    {
        "name": "COVID_Crash_Mar2020",
        "desc": "COVID market crash - SPY, JETS, TSLA, ZM",
        "stocks": [
            {
                "ticker": "SPY", "date": "2020-03-16",
                "desc": "S&P 500 - dropped 12% in one day",
                "expected": ["FLASH_CRASH", "ORDER_IMBALANCE", "TRADE_VELOCITY", "PRICE_SPIKE"],
            },
            {
                "ticker": "JETS", "date": "2020-03-16",
                "desc": "Airlines ETF - most devastated sector",
                "expected": ["FLASH_CRASH", "ORDER_IMBALANCE", "TRADE_VELOCITY", "VOLUME_SURGE", "PRICE_SPIKE"],
            },
            {
                "ticker": "TSLA", "date": "2020-03-16",
                "desc": "Tesla - crashed then recovered, tests alert clearing",
                "expected": ["FLASH_CRASH", "ORDER_IMBALANCE", "TRADE_VELOCITY", "PRICE_SPIKE"],
            },
            {
                "ticker": "ZM", "date": "2020-03-16",
                "desc": "Zoom - went UP during COVID. Should NOT trigger Flash Crash!",
                "expected": ["ORDER_IMBALANCE", "PRICE_SPIKE"],
            },
        ],
    },
    {
        "name": "Normal_Baseline",
        "desc": "Quiet normal trading days - chip should stay SILENT",
        "stocks": [
            {
                "ticker": "SPY", "date": "2019-06-04",
                "desc": "S&P 500 - ordinary Tuesday in 2019",
                "expected": ["NONE"],
            },
            {
                "ticker": "MSFT", "date": "2019-06-04",
                "desc": "Microsoft - steady blue chip",
                "expected": ["NONE"],
            },
            {
                "ticker": "KO", "date": "2019-06-04",
                "desc": "Coca-Cola - famously boring, ultra-low volatility",
                "expected": ["NONE"],
            },
            {
                "ticker": "GLD", "date": "2019-06-04",
                "desc": "Gold ETF - different asset class, slow-moving",
                "expected": ["NONE"],
            },
        ],
    },
]

# -------------------------------------------------------------------------
# Synthetic market models
# -------------------------------------------------------------------------
def synthetic_model(ticker, date_str, expected):
    """Generate realistic synthetic OHLCV bars when real data unavailable."""
    import random
    random.seed(hash(ticker + date_str) & 0xFFFFFF)

    is_crash    = "FLASH_CRASH" in expected
    is_spike    = "PRICE_SPIKE" in expected
    is_vol_srg  = "VOLUME_SURGE" in expected
    is_imbal    = "ORDER_IMBALANCE" in expected
    is_volatile = "VOLATILITY" in expected
    is_normal   = "NONE" in expected

    base_price = {"GME": 148, "AMC": 8, "BB": 14, "NOK": 4,
                  "SPY": 290, "PG": 58, "AAPL": 75, "ACN": 70,
                  "JETS": 18, "TSLA": 450, "ZM": 120,
                  "MSFT": 130, "KO": 47, "GLD": 122}.get(ticker, 100)

    bars = []
    price = base_price
    volume = 1000000

    n_bars = 390  # full trading day of 1-min bars
    for i in range(n_bars):
        frac = i / n_bars

        if is_normal:
            dp = random.gauss(0, base_price * 0.001)
            dv = random.gauss(0, volume * 0.1)
        elif is_crash:
            if frac < 0.5:
                dp = random.gauss(0, base_price * 0.002)
            elif frac < 0.7:
                dp = -base_price * 0.01 + random.gauss(0, base_price * 0.003)
                dv = volume * 0.5
            else:
                dp = random.gauss(0, base_price * 0.002)
            dv = volume * 0.2 if frac > 0.5 else 0
        elif is_spike:
            if 0.3 < frac < 0.4:
                dp = base_price * 0.05
            elif 0.4 < frac < 0.5:
                dp = -base_price * 0.04
            else:
                dp = random.gauss(0, base_price * 0.001)
            dv = volume * 0.3 if 0.3 < frac < 0.5 else 0
        else:
            dp = random.gauss(0, base_price * 0.001)
            dv = random.gauss(0, volume * 0.1)

        price = max(1, price + dp)
        volume = max(100, volume + dv)

        o = price
        h = price * (1 + abs(random.gauss(0, 0.002)))
        l = price * (1 - abs(random.gauss(0, 0.002)))
        c = price + random.gauss(0, price * 0.001)
        v = max(100, volume + random.gauss(0, volume * 0.1))

        bars.append({"open": o, "high": h, "low": l, "close": c, "volume": v})

    return bars, "synthetic"


def fetch_data(ticker, date_str):
    """Fetch daily bars around the event date from Yahoo Finance."""
    if not YFINANCE:
        return None, "no_yfinance"

    try:
        event = datetime.date.fromisoformat(date_str)
        start = (event - datetime.timedelta(days=10)).isoformat()
        end   = (event + datetime.timedelta(days=10)).isoformat()

        df = yf.download(ticker, start=start, end=end,
                         interval="1d", progress=False, auto_adjust=True)

        if df is None or len(df) < 3:
            return None, "no_data"

        # Flatten multi-level columns (newer yfinance returns ('Close','SPY') etc.)
        if isinstance(df.columns, __import__('pandas').MultiIndex):
            df.columns = df.columns.get_level_values(0)

        bars = []
        for _, row in df.iterrows():
            bars.append({
                "open":   float(row["Open"]),
                "high":   float(row["High"]),
                "low":    float(row["Low"]),
                "close":  float(row["Close"]),
                "volume": float(row["Volume"]),
            })
        return bars, "real"

    except Exception as e:
        return None, f"error: {e}"


# -------------------------------------------------------------------------
# Encoding: OHLCV bars -> chip stimulus cycles
# -------------------------------------------------------------------------
CYCLES_PER_BAR = 16  # price, volume, 7x buy, 7x sell

WARMUP_BARS = 32  # repeat first bar 32x to warm up the chip rolling average

def encode_bars(bars):
    """
    Convert OHLCV bars to chip input cycles, with a warmup prefix.
    The chip resets with price_avg=100; without warmup the first real bars
    look like a crash vs the stale default. 16 warmup repeats fills the
    8-slot history twice so the baseline is stable before real data arrives.
    """
    if not bars:
        return []

    # Prepend warmup: repeat first bar WARMUP_BARS times
    bars = [bars[0]] * WARMUP_BARS + list(bars)

    # Scale prices using a percentage-based encoding centered at 2048.
    # This ensures that normal daily variation (1-5%) maps to small numbers,
    # so the chip flash crash detector only fires on genuinely large moves.
    # A 10% price move = ~200 units.  Flash crash threshold = 40 units = ~2%.
    prices = [b["close"] for b in bars]
    vols   = [b["volume"] for b in bars]

    p_mid   = sum(prices) / len(prices)          # dataset mean price
    v_min, v_max = min(vols), max(vols)
    v_range = max(v_max - v_min, 1.0)

    # Scale: 2000 units per 100% price move (so 1% = 20 units, 2% = 40 units)
    p_scale = 2000.0 / max(p_mid, 1.0)

    cycles = []

    def encode_word(input_type, data12):
        """Pack into 16-bit word: [15:8]=ui_in, [7:0]=uio_in"""
        data12 = max(0, min(4095, int(data12)))
        ui_in  = (input_type << 6) | (data12 & 0x3F)
        uio_in = (data12 >> 6) & 0x3F   # uio_in[7]=0 (no config strobe)
        return (ui_in << 8) | uio_in

    for bar in bars:
        # Center at 2048, scale by percentage from mean
        p_scaled = int(2048 + (bar["close"] - p_mid) * p_scale)
        # Volume: ratio-based encoding relative to first bar (= 512)
        # Preserves surge ratios: 2x normal = 1024, 10x normal = 5120->capped 4095
        # Combined with VOL_SURGE_MULT=1 (2x threshold), surges fire correctly
        v_scaled = min(4095, int(bar["volume"] / bars[0]["volume"] * 512))

        p_range_bar = bar["high"] - bar["low"]
        if p_range_bar > 0:
            buy_pressure  = (bar["close"] - bar["low"])  / p_range_bar
            sell_pressure = (bar["high"]  - bar["close"]) / p_range_bar
        else:
            buy_pressure  = 0.5
            sell_pressure = 0.5

        buy_qty  = max(1, min(63, int(buy_pressure  * 63)))
        sell_qty = max(1, min(63, int(sell_pressure * 63)))

        # cy 0: price
        cycles.append(encode_word(0b00, p_scaled))
        # cy 1: volume
        cycles.append(encode_word(0b01, v_scaled))
        # cy 2-8: buy orders (7 cycles)
        for _ in range(7):
            cycles.append(encode_word(0b10, buy_qty))
        # cy 9-15: sell orders (7 cycles)
        for _ in range(7):
            cycles.append(encode_word(0b11, sell_qty))

    return cycles


# -------------------------------------------------------------------------
# File writers
# -------------------------------------------------------------------------
def write_stimulus(path, cycles):
    with open(path, "w", encoding="utf-8") as f:
        for word in cycles:
            f.write(f"{word:04X}\n")


def write_golden(path, ticker, date_str, expected):
    with open(path, "w", encoding="utf-8") as f:
        f.write(f"TICKER={ticker}\n")
        f.write(f"DATE={date_str}\n")
        f.write(f"EXPECTED={','.join(expected)}\n")


def write_info(path, ticker, date_str, desc, source, n_bars, n_cycles, expected):
    with open(path, "w", encoding="utf-8") as f:
        f.write(f"NanoTrade Stimulus Info\n")
        f.write(f"=======================\n")
        f.write(f"Ticker   : {ticker}\n")
        f.write(f"Date     : {date_str}\n")
        f.write(f"Desc     : {desc}\n")
        f.write(f"Source   : {source}\n")
        f.write(f"Bars     : {n_bars}\n")
        f.write(f"Cycles   : {n_cycles}\n")
        f.write(f"Expected : {', '.join(expected)}\n")


# -------------------------------------------------------------------------
# PowerShell and bash runners
# -------------------------------------------------------------------------
def write_runners(all_stocks):
    # PowerShell
    ps_path = os.path.join(OUTPUT_DIR, "run_all_scenarios.ps1")
    with open(ps_path, "w", encoding="utf-8") as f:
        f.write("# NanoTrade -- Run all 16 stock scenarios\n")
        f.write("# Usage: .\\stimuli\\run_all_scenarios.ps1\n\n")
        f.write("$env:Path += \";C:\\iverilog\\bin\"\n\n")
        f.write("# Compile once\n")
        f.write("iverilog -g2005 -o sim_stock `\n")
        f.write("  tb_nanotrade_stock.v tt_um_nanotrade.v order_book.v `\n")
        f.write("  anomaly_detector.v feature_extractor.v ml_inference_engine.v\n\n")
        f.write("if ($LASTEXITCODE -ne 0) { Write-Error 'Compile failed'; exit 1 }\n\n")
        f.write("$results = @()\n\n")
        for s in all_stocks:
            stem = f"{s['ticker']}_{s['date'].replace('-','')}"
            f.write(f"Write-Host \"--- {s['ticker']} {s['date']} ---\" -ForegroundColor Cyan\n")
            f.write(f"$out = vvp sim_stock +STIMULUS+stimuli/{stem}_stimulus.memh +TICKER+{s['ticker']} 2>&1\n")
            f.write(f"$out | Out-File -FilePath stimuli/{stem}_result.txt -Encoding ascii\n")
            f.write(f"$out | Select-String 'FIRED_RULE_MASK|FIRED_ML_MASK|SUMMARY'\n")
            f.write(f"$results += python check_results.py stimuli/{stem}_golden.txt stimuli/{stem}_result.txt\n\n")
        f.write("Write-Host ''\n")
        f.write("Write-Host '=== FINAL RESULTS ===' -ForegroundColor White\n")
        f.write("$results | ForEach-Object { Write-Host $_ }\n")

    # Bash
    sh_path = os.path.join(OUTPUT_DIR, "run_all_scenarios.sh")
    with open(sh_path, "w", encoding="utf-8") as f:
        f.write("#!/usr/bin/env bash\n")
        f.write("# NanoTrade -- Run all 16 stock scenarios\n\n")
        f.write("set -e\n\n")
        f.write("iverilog -g2005 -o sim_stock \\\n")
        f.write("  tb_nanotrade_stock.v tt_um_nanotrade.v order_book.v \\\n")
        f.write("  anomaly_detector.v feature_extractor.v ml_inference_engine.v\n\n")
        for s in all_stocks:
            stem = f"{s['ticker']}_{s['date'].replace('-','')}"
            f.write(f"echo '--- {s['ticker']} {s['date']} ---'\n")
            f.write(f"vvp sim_stock +STIMULUS+stimuli/{stem}_stimulus.memh +TICKER+{s['ticker']} \\\n")
            f.write(f"  | tee stimuli/{stem}_result.txt\n")
            f.write(f"python3 check_results.py stimuli/{stem}_golden.txt stimuli/{stem}_result.txt\n\n")


# -------------------------------------------------------------------------
# Main pipeline
# -------------------------------------------------------------------------
def main():
    print("+======================================================+")
    print("|     NanoTrade Stock Data Pipeline  (v2)              |")
    print("|     IEEE UofT ASIC Team                              |")
    print("+======================================================+")
    print(f"Output directory: {os.path.abspath(OUTPUT_DIR)}")
    print(f"yfinance available: {YFINANCE}")

    all_stocks = []
    summary_rows = []

    for scenario in SCENARIOS:
        print(f"\n{'='*60}")
        print(f"  SCENARIO: {scenario['name']}")
        print(f"  {scenario['desc']}")
        print(f"{'='*60}")

        for stock in scenario["stocks"]:
            ticker   = stock["ticker"]
            date_str = stock["date"]
            expected = stock["expected"]
            desc     = stock["desc"]

            print(f"\n{'-'*60}")
            print(f"  {ticker} | {date_str}")
            print(f"  {desc}")
            print(f"{'-'*60}")

            # Fetch data
            print(f"  [NET] Downloading {ticker} daily bars around {date_str}...")
            bars, source = fetch_data(ticker, date_str)

            if bars and len(bars) >= 3:
                print(f"     [OK] Got {len(bars)} daily bars (real data)")
            else:
                print(f"     (!)  No data returned, using synthetic model")
                bars, source = synthetic_model(ticker, date_str, expected)
                print(f"  [SYN] Using synthetic {ticker} {date_str} model ({len(bars)} bars)")

            # Encode
            cycles = encode_bars(bars)

            # Write files
            stem     = f"{ticker}_{date_str.replace('-', '')}"
            stim_path   = os.path.join(OUTPUT_DIR, f"{stem}_stimulus.memh")
            golden_path = os.path.join(OUTPUT_DIR, f"{stem}_golden.txt")
            info_path   = os.path.join(OUTPUT_DIR, f"{stem}_info.txt")

            write_stimulus(stim_path, cycles)
            write_golden(golden_path, ticker, date_str, expected)
            write_info(info_path, ticker, date_str, desc, source,
                       len(bars), len(cycles), expected)

            print(f"  [FILE] {len(cycles)} cycles written -> {stem}_stimulus.memh")
            print(f"  [GOLD] Golden: expects {', '.join(expected)}")

            all_stocks.append({"ticker": ticker, "date": date_str})
            summary_rows.append({
                "ticker": ticker, "date": date_str, "source": source,
                "bars": len(bars), "cycles": len(cycles),
                "expected": ", ".join(expected),
            })

    # Write runners
    write_runners(all_stocks)
    print(f"\n[OK] PowerShell runner: {OUTPUT_DIR}/run_all_scenarios.ps1")
    print(f"[OK] Bash runner:       {OUTPUT_DIR}/run_all_scenarios.sh")
    print(f"[OK] Checker:           check_results.py")

    # Summary table
    print(f"\n{'='*60}")
    print(f"  PIPELINE COMPLETE")
    print(f"{'='*60}")
    print(f"\nGenerated {len(summary_rows)} stimulus files in {OUTPUT_DIR}/")
    print(f"{'Stock':<8} {'Date':<12} {'Source':<10} {'Bars':<6} {'Cycles':<8} Expected Alerts")
    print("-" * 70)
    for r in summary_rows:
        print(f"{r['ticker']:<8} {r['date']:<12} {r['source']:<10} {r['bars']:<6} {r['cycles']:<8} {r['expected']}")
    print("-" * 70)
    print(f"\nNext steps:")
    print(f"  1. Compile:  iverilog -g2005 -o sim_stock tb_nanotrade_stock.v tt_um_nanotrade.v order_book.v anomaly_detector.v feature_extractor.v ml_inference_engine.v")
    print(f"  2. Run one:  vvp sim_stock +STIMULUS+stimuli/GME_20210128_stimulus.memh +TICKER+GME")
    print(f"  3. Run all:  bash stimuli/run_all_scenarios.sh")
    print(f"               (or on Windows: .\\stimuli\\run_all_scenarios.ps1)")


if __name__ == "__main__":
    main()