# NanoTrade — HFT Matching Engine + ML Anomaly Detection

**IEEE UofT ASIC Team** | TinyTapeout Submission | 2×2 Tiles | 50 MHz

NanoTrade is a real-time ASIC that combines a high-frequency trading order book with dual-path anomaly detection — a rule-based fast path (1-cycle latency) and a pipelined neural network (4-cycle latency) — all on a single TinyTapeout chip. It detects flash crashes, volume surges, quote stuffing, and order imbalances at hardware speed, demonstrating parallelism that is impossible in software.

---

## Table of Contents

1. [What It Does](#what-it-does)
2. [Architecture Overview](#architecture-overview)
3. [File Structure](#file-structure)
4. [Pin Mapping](#pin-mapping)
5. [Alert Types](#alert-types)
6. [Running the Original Testbench](#running-the-original-testbench)
7. [Stock Data Validation Suite](#stock-data-validation-suite)
   - [Quick Start](#quick-start)
   - [Test Scenarios](#test-scenarios)
   - [How It Works](#how-the-validation-pipeline-works)
   - [Using Real Data](#using-real-stock-data-yfinance)
   - [Running One Stock](#running-a-single-stock)
   - [Understanding the Output](#understanding-the-output)
8. [ML Neural Network](#ml-neural-network)
9. [Reproducing the ML Weights](#reproducing-the-ml-weights)

---

## What It Does

NanoTrade watches a stream of market data — prices, volumes, buy orders, sell orders — and simultaneously:

- **Matches orders** using a 4-entry bid/ask order book with price-time priority
- **Fires rule-based alerts** within 1 clock cycle for obvious anomalies (e.g. price drops 40+ units from baseline)
- **Runs ML inference** every 256 cycles, classifying the market into one of 6 states using a 16→8→6 MLP neural network

Both paths feed into a priority fusion system. The ML result overrides the rule-based path when it fires. The highest-priority alert from either system appears on the output pins.

---

## Architecture Overview

```
                          ┌─────────────────────────────────────────────┐
   ui_in[7:6] = type      │              tt_um_nanotrade                 │
   ui_in[5:0] = data lo   │                                              │
   uio_in[5:0]= data hi   │  ┌─────────────┐    ┌──────────────────┐   │
         ──────────────►  │  │ order_book  │    │anomaly_detector  │   │
                          │  │             │    │  (8 detectors,   │   │
                          │  │ 4-entry bid │    │  1-cycle latency)│   │
                          │  │ 4-entry ask │    └────────┬─────────┘   │
                          │  │ price-time  │             │ rule alerts  │
                          │  │ priority    │    ┌────────▼─────────┐   │
                          │  └──────┬──────┘    │ feature_extractor│   │
                          │  match  │           │  16×8-bit vector │   │  uo_out[7]   = alert flag
                          │  valid  │           │  every 256 cy    │   │  uo_out[6:4] = priority
                          │         │           └────────┬─────────┘   │  uo_out[3]   = match valid
                          │         │                    │              │  uo_out[2:0] = alert type
                          │         │           ┌────────▼─────────┐   │  uio_out[7]  = ML valid
                          │         │           │ml_inference_engine│   │  uio_out[6:4]= ML class
                          │         │           │  16→8→6 MLP      │   │  uio_out[3:0]= ML confidence
                          │         │           │  4-cycle pipeline │   │
                          │         │           └────────┬─────────┘   │
                          │         │      ML result     │             │
                          │         └──────────► Alert Fusion ◄────────┘
                          └─────────────────────────────────────────────┘
```

---

## File Structure

```
ttsky-NanoTrade/
│
│  ── Core Hardware (Verilog) ──────────────────────────────────────────
├── tt_um_nanotrade.v         Top-level TinyTapeout wrapper + alert fusion
├── order_book.v              4-entry bid/ask order book, price-time matching
├── anomaly_detector.v        8 parallel combinational detectors, 1-cycle latency
├── feature_extractor.v       Converts raw stream → 16×8-bit feature vector
├── ml_inference_engine.v     Pipelined 16→8→6 MLP, 4-cycle latency
│
│  ── Testbenches ──────────────────────────────────────────────────────
├── tb_nanotrade.v            Original testbench (hardcoded scenarios)
├── tb_nanotrade_stock.v      Stock data testbench (reads .memh stimulus files)
│
│  ── ML Training ──────────────────────────────────────────────────────
├── train_and_export.py       Trains MLP, quantizes to INT16, exports ROM hex
├── rom/
│   ├── w1.hex                Layer-1 weights  (128 × INT16)
│   ├── b1.hex                Layer-1 biases   (8   × INT16)
│   ├── w2.hex                Layer-2 weights  (48  × INT16)
│   └── b2.hex                Layer-2 biases   (6   × INT16)
│
│  ── Stock Validation Suite ────────────────────────────────────────────
├── generate_stimuli.py       Downloads stock data → encodes → writes .memh files
├── check_results.py          Compares simulation output against golden reference
├── stimuli/
│   ├── run_all_scenarios.sh  One command to run all 16 stocks
│   ├── GME_20210128_stimulus.memh    ← chip input stream (one line per cycle)
│   ├── GME_20210128_golden.txt       ← expected alert types
│   ├── GME_20210128_info.txt         ← human-readable summary
│   └── ... (3 files × 16 stocks = 48 files total)
│
│  ── Config ────────────────────────────────────────────────────────────
├── info.yaml                 TinyTapeout project metadata + pinout
└── nanotrade.vcd             Simulation waveform dump
```

---

## Pin Mapping

### Inputs

| Pin | Name | Description |
|-----|------|-------------|
| `ui_in[7:6]` | `input_type` | `00`=price, `01`=volume, `10`=buy order, `11`=sell order |
| `ui_in[5:0]` | `data[5:0]` | Low 6 bits of price/volume/quantity |
| `uio_in[5:0]` | `data[11:6]` | High 6 bits of price/volume |

The chip reconstructs a 12-bit value as `{uio_in[5:0], ui_in[5:0]}`.

### Outputs

| Pin | Name | Description |
|-----|------|-------------|
| `uo_out[7]` | `alert_flag` | High when any alert is active (rule OR ML) |
| `uo_out[6:4]` | `alert_priority` | 0–7, where 7 = critical flash crash |
| `uo_out[3]` | `match_valid` | High for 1 cycle when a buy/sell pair matches |
| `uo_out[2:0]` | `alert_type` | Which alert is highest priority (see table below) |
| `uio_out[7]` | `ml_valid` | 1-cycle pulse when ML result is ready |
| `uio_out[6:4]` | `ml_class` | ML predicted class (0=normal … 5=quote stuffing) |
| `uio_out[3:0]` | `ml_confidence` | Confidence nibble (higher = more certain) |

When `match_valid` is high, `uio_out[7:0]` carries the match price instead of the ML result.

---

## Alert Types

### Rule-Based (anomaly_detector.v)

| Code | Name | Condition | Priority |
|------|------|-----------|----------|
| 0 | PRICE_SPIKE | `\|Δprice\|` > 20 units | 0 |
| 1 | VOL_DRY | Volume < 25% of average | 1 |
| 2 | VOL_SURGE | Volume > 2× average | 2 |
| 3 | VELOCITY | > 30 matches per window | 3 |
| 4 | IMBALANCE | Buy/sell ratio > 4:1 | 4 |
| 5 | SPREAD | One side of book empty | 5 |
| 6 | VOLATILITY | MAD > 4× baseline | 6 |
| 7 | FLASH_CRASH | Price drop > 40 from avg | 7 (critical) |

### ML Classes (ml_inference_engine.v)

| Class | Name | Description |
|-------|------|-------------|
| 0 | NORMAL | Quiet market |
| 1 | PRICE_SPIKE | Sharp price movement |
| 2 | VOLUME_SURGE | 3–10× volume explosion |
| 3 | FLASH_CRASH | Price drops >20% in seconds |
| 4 | ORDER_IMBALANCE | Lopsided buy/sell pressure |
| 5 | QUOTE_STUFFING | Mass orders placed and cancelled (spoofing) |

---

## Running the Original Testbench

The original testbench uses hardcoded synthetic scenarios (good for quick smoke testing):

```bash
# From the project root directory
iverilog -o sim \
    tb_nanotrade.v tt_um_nanotrade.v order_book.v \
    anomaly_detector.v feature_extractor.v ml_inference_engine.v

vvp sim
```

Expected output includes alerts for price spike, flash crash, volume surge, and ML inference results across 8 scripted scenarios.

---

## Stock Data Validation Suite

This suite validates the chip against 16 real historical market events across 4 scenarios. It proves the chip correctly detects anomalies on real-world data — not just hardcoded test patterns.

### Quick Start

```bash
# Step 1 — Install Python dependencies (only needed once)
pip install yfinance pandas numpy

# Step 2 — Generate all 16 stimulus files
#   With yfinance installed: downloads real minute-by-minute data from Yahoo Finance
#   Without yfinance: falls back to accurate synthetic models of each event
python3 generate_stimuli.py

# Step 3 — Compile the stock testbench
iverilog -o sim_nanotrade \
    tb_nanotrade_stock.v tt_um_nanotrade.v order_book.v \
    anomaly_detector.v feature_extractor.v ml_inference_engine.v

# Step 4 — Run all 16 stocks and get a final score
bash stimuli/run_all_scenarios.sh
```

Final output looks like:
```
========================================
FINAL SCORE: 16 passed, 0 failed
========================================
```

---

### Test Scenarios

#### Scenario 1 — Meme Stock Frenzy (January 28, 2021)

The Reddit WallStreetBets short squeeze. All four stocks were part of the same event but with very different intensities — this tests that the chip scales its response appropriately.

| Stock | Expected Alerts | Why |
|-------|----------------|-----|
| **GME** | FLASH_CRASH, VOL_SURGE, PRICE_SPIKE, IMBALANCE | Price went $148 → $483 → $112 in one day |
| **AMC** | VOL_SURGE, PRICE_SPIKE, IMBALANCE | Same frenzy, ~40% the intensity of GME |
| **BB** | PRICE_SPIKE, VOL_SURGE | BlackBerry — moderate spike |
| **NOK** | VOL_SURGE | Nokia — barely anomalous, tests sensitivity boundary |

#### Scenario 2 — Algorithmic Flash Crash (May 6, 2010)

The Dow dropped 9% in 15 minutes due to algorithmic spoofing. PG and ACN both briefly traded near $0.01 — extreme edge cases for the chip's detectors.

| Stock | Expected Alerts | Why |
|-------|----------------|-----|
| **SPY** | FLASH_CRASH, VOLATILITY, VOL_SURGE | S&P 500 dropped 9% in 15 minutes |
| **PG** | FLASH_CRASH, PRICE_SPIKE | Procter & Gamble dropped from $60 to $0.01 |
| **AAPL** | FLASH_CRASH, VOL_SURGE | Blue chip dragged down ~5% |
| **ACN** | FLASH_CRASH, PRICE_SPIKE | Accenture literally traded at $0.01 |

#### Scenario 3 — COVID Crash (March 16, 2020)

The largest single-day point decline ever for the Dow at the time. ZM (Zoom) is a deliberate counter-example — it went *up* during COVID, so the chip should detect Volume Surge and Price Spike but **not** Flash Crash.

| Stock | Expected Alerts | Why |
|-------|----------------|-----|
| **SPY** | FLASH_CRASH, VOLATILITY, VOL_SURGE | S&P 500 down 12% in one day |
| **JETS** | FLASH_CRASH, VOL_SURGE, IMBALANCE | Airlines ETF — most devastated sector |
| **TSLA** | FLASH_CRASH, VOLATILITY | Crashed then recovered — tests alert clearing |
| **ZM** | VOL_SURGE, PRICE_SPIKE *(not FLASH_CRASH)* | Zoom went UP — tests directional discrimination |

#### Scenario 4 — Normal Quiet Baselines (June 4, 2019)

Four completely boring trading days. **Nothing should fire.** This proves the chip has a low false-positive rate and doesn't cry wolf on normal data.

| Stock | Expected Alerts | Why |
|-------|----------------|-----|
| **SPY** | *none* | Ordinary Tuesday in a quiet market |
| **MSFT** | *none* | Steady blue chip |
| **KO** | *none* | Coca-Cola — famously low volatility |
| **GLD** | *none* | Gold ETF — different asset class entirely |

---

### How the Validation Pipeline Works

Understanding the three-step pipeline helps when something goes wrong or you want to add new test cases.

**Step 1 — Data fetching (`generate_stimuli.py`)**

For each stock the script tries to download real 1-minute OHLCV bars from Yahoo Finance. If that fails (no internet, data unavailable for old dates, etc.) it falls back to a mathematically faithful synthetic model built from what actually happened. Each model was constructed from documented facts — for example, the GME model has three explicit phases: slow rise to $148, explosive surge to $483, and collapse back to $112.

**Step 2 — Encoding**

Real prices like "$483" cannot go directly into the chip — the chip only understands 12-bit integers (0–4095). The pipeline scales each stock's price range into chip units while preserving relative movements. A 77% price collapse still maps to a 77% drop in chip units, which is far above the Flash Crash threshold. Each 1-minute bar becomes 16 chip clock cycles: 4 price ticks (open/high/low/close), 2 volume ticks, 6 buy/sell orders (split by price direction), and 4 idle cycles.

**Step 3 — Simulation and checking**

The testbench `tb_nanotrade_stock.v` reads the `.memh` file and feeds one entry to the chip per clock cycle, exactly like a real market data stream. After the full replay, `check_results.py` compares which alert types actually fired against the golden file and reports pass or fail.

---

### Using Real Stock Data (yfinance)

If `yfinance` is installed and you have internet access, `generate_stimuli.py` automatically downloads genuine historical data:

```bash
pip install yfinance
python3 generate_stimuli.py
```

The script will print `✅ Got 390 bars from Yahoo Finance` for each stock instead of `🔬 Using synthetic model`. All downstream files (`.memh`, golden, run script) are identical in format — you just re-run the simulation with the new stimulus files.

> **Note on old dates:** Yahoo Finance sometimes has gaps in 1-minute data for dates before 2020. If a download returns fewer than 10 bars the script automatically falls back to the synthetic model for that stock.

---

### Running a Single Stock

You don't have to run all 16. To test just one stock:

```bash
# Compile first (only needed once)
iverilog -o sim_nanotrade \
    tb_nanotrade_stock.v tt_um_nanotrade.v order_book.v \
    anomaly_detector.v feature_extractor.v ml_inference_engine.v

# Run GME
STIMULUS=stimuli/GME_20210128_stimulus.memh \
GOLDEN=stimuli/GME_20210128_golden.txt \
TICKER=GME \
vvp sim_nanotrade

# Then check the result
python3 check_results.py stimuli/GME_20210128_result.txt stimuli/GME_20210128_golden.txt
```

---

### Understanding the Output

A typical simulation run prints:

```
╔══════════════════════════════════════════════════════╗
║     NanoTrade Stock Testbench                        ║
╚══════════════════════════════════════════════════════╝

Ticker  : GME
Stimulus: stimuli/GME_20210128_stimulus.memh
Cycles  : 6272

[cy 0] Reset released — replaying market data stream
─────────────────────────────────────────────────────────
[cy 512]  RULE ALERT --> VOL_SRGE  priority=2  (bar ~30)
[cy 1920] RULE ALERT --> SPIKE     priority=0  (bar ~118)
[cy 2176] RULE ALERT --> FLASH!!!  priority=7  (bar ~134)
[cy 3328] *** ML RESULT: class=FLASH!  conf=207 ***
[cy 4096] Alert cleared
...

Rule detectors triggered:
  [7] FLASH CRASH    *** CRITICAL ***
  [2] VOLUME SURGE
  [0] PRICE SPIKE

ML classifications seen:
  [3] FLASH CRASH  *** CRITICAL ***
  [2] VOLUME SURGE

[FIRED_RULE_MASK] 10000101
[FIRED_ML_MASK]   00001100
─────────────────────────────────────────────────────────
```

The `bar ~N` annotation tells you which minute of the trading day triggered the alert. The `FIRED_*_MASK` lines at the bottom are parsed by `check_results.py` to determine pass/fail automatically.

---

## ML Neural Network

The chip contains a 3-layer MLP:

```
Input layer:   16 features  (8-bit unsigned each)
Hidden layer:   8 neurons   (ReLU activation)
Output layer:   6 classes   (argmax → predicted class)
Total weights:  128 + 8 + 48 + 6 = 190 INT16 values = 380 bytes ROM
```

**Pipeline latency:** 4 clock cycles from `feature_valid` pulse to `ml_valid` result.

**Feature vector** (one snapshot every 256 cycles):

| Index | Feature | Description |
|-------|---------|-------------|
| 0 | price_change_1s | Absolute price change over last 8 cycles |
| 1 | price_change_10s | Absolute price change over last 32 cycles |
| 2 | price_change_60s | Absolute price change over 64-cycle window |
| 3 | volume_ratio | Current volume / rolling average |
| 4 | spread_pct | Proxy for bid-ask spread width |
| 5 | buy_sell_imbalance | Buy fraction of total order flow |
| 6 | volatility | Mean absolute deviation × 4 |
| 7 | order_arrival_rate | Buy + sell orders per window |
| 8 | cancel_rate | Not tracked on TinyTapeout I/O → 0 |
| 9 | buy_depth | Buy order count × 16 |
| 10 | sell_depth | Sell order count × 16 |
| 11 | time_since_trade | Cycles since last match >> 4 |
| 12 | avg_order_lifespan | Not tracked → 200 (healthy default) |
| 13 | trade_frequency | Matches per window × 4 |
| 14 | price_momentum | Second derivative of price |
| 15 | reserved | Always 128 |

---

## Reproducing the ML Weights

If you want to retrain the network (e.g. to adjust thresholds or add new anomaly classes):

```bash
pip install scikit-learn numpy

# Trains on 8000 synthetic samples, exports to rom/
python3 train_and_export.py
```

This will print training accuracy, quantized accuracy, and weight statistics, then overwrite `rom/w1.hex`, `rom/b1.hex`, `rom/w2.hex`, `rom/b2.hex`. The quantized integer accuracy should be within ~2% of the float accuracy.

> **Note:** The scaler is folded into the weights during export, so the hardware never needs to normalize inputs. Raw uint8 features feed directly into the chip.

---

*NanoTrade — IEEE UofT ASIC Team*