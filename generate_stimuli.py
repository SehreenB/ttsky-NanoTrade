"""
NanoTrade Stock Data Pipeline
================================
Downloads real historical stock data and converts it into stimulus files
that the NanoTrade chip testbench can replay cycle by cycle.

HOW TO RUN:
    pip install yfinance pandas numpy
    python generate_stimuli.py

WHAT IT PRODUCES (in the stimuli/ folder):
    For each stock (e.g. GME_20210128):
        GME_20210128_stimulus.memh   — chip input stream (ui_in + uio_in per cycle)
        GME_20210128_golden.txt      — what alerts we EXPECT to see and when
        GME_20210128_info.txt        — human-readable summary of the data

    Plus:
        run_all_scenarios.sh         — one command to simulate all 16 stocks

UNDERSTANDING THE OUTPUT:
    Each line of a .memh file = one clock cycle
    Format: XXYY  where XX = ui_in byte, YY = uio_in byte
    The testbench reads this and feeds it to the chip one cycle at a time.

AUTHOR: IEEE UofT ASIC Team
"""

import os
import sys
import numpy as np
import pandas as pd

# ── Try to import yfinance (needs: pip install yfinance) ──────────────────────
try:
    import yfinance as yf
    HAS_YFINANCE = True
except ImportError:
    HAS_YFINANCE = False
    print("⚠  yfinance not found. Run: pip install yfinance")
    print("   Falling back to realistic synthetic data for all scenarios.\n")

# ── Output directory ──────────────────────────────────────────────────────────
OUT_DIR = os.path.join(os.path.dirname(__file__), "stimuli")
os.makedirs(OUT_DIR, exist_ok=True)


# ═══════════════════════════════════════════════════════════════════════════════
# TEST CASE DEFINITIONS
# Each scenario = a list of stocks + date + what alerts we expect to see
# ═══════════════════════════════════════════════════════════════════════════════

SCENARIOS = [

    # ── SCENARIO 1: Meme Stock Frenzy (Jan 28, 2021) ────────────────────────
    # The Reddit WallStreetBets short squeeze. GME went from $148 to $483
    # then crashed back to $112 in a single day. AMC, BB, NOK all surged too
    # but with different intensities — perfect for showing the chip scales.
    {
        "name": "Meme_Frenzy_Jan2021",
        "description": "Reddit WallStreetBets short squeeze — GME, AMC, BB, NOK",
        "date": "2021-01-28",
        "interval": "1m",   # 1-minute bars
        "stocks": [
            {
                "ticker": "GME",
                "label": "GameStop — the epicenter. Price: $148→$483→$112",
                "expected_alerts": ["FLASH_CRASH", "VOLUME_SURGE", "PRICE_SPIKE", "ORDER_IMBALANCE"]
            },
            {
                "ticker": "AMC",
                "label": "AMC Entertainment — same frenzy, slightly calmer",
                "expected_alerts": ["VOLUME_SURGE", "PRICE_SPIKE", "ORDER_IMBALANCE"]
            },
            {
                "ticker": "BB",
                "label": "BlackBerry — moderate spike, tests sensitivity threshold",
                "expected_alerts": ["PRICE_SPIKE", "VOLUME_SURGE"]
            },
            {
                "ticker": "NOK",
                "label": "Nokia — quietest of the four, near false-positive boundary",
                "expected_alerts": ["VOLUME_SURGE"]
            },
        ]
    },

    # ── SCENARIO 2: 2010 Flash Crash (May 6, 2010) ──────────────────────────
    # The Dow dropped 9% in 15 minutes due to algorithmic quote stuffing/spoofing.
    # PG and ACN literally traded at $0.01 — extreme edge cases for the chip.
    {
        "name": "Flash_Crash_May2010",
        "description": "Algorithmic flash crash — SPY, PG, AAPL, ACN",
        "date": "2010-05-06",
        "interval": "1m",
        "stocks": [
            {
                "ticker": "SPY",
                "label": "S&P 500 ETF — broad market dropped 9% in 15 minutes",
                "expected_alerts": ["FLASH_CRASH", "VOLATILITY", "VOLUME_SURGE"]
            },
            {
                "ticker": "PG",
                "label": "Procter & Gamble — dropped from $60 to $0.01 momentarily",
                "expected_alerts": ["FLASH_CRASH", "PRICE_SPIKE"]
            },
            {
                "ticker": "AAPL",
                "label": "Apple — blue chip dragged down, tests broad impact",
                "expected_alerts": ["FLASH_CRASH", "VOLUME_SURGE"]
            },
            {
                "ticker": "ACN",
                "label": "Accenture — traded at literally $0.01, the most extreme case",
                "expected_alerts": ["FLASH_CRASH", "PRICE_SPIKE"]
            },
        ]
    },

    # ── SCENARIO 3: COVID Crash (March 16, 2020) ────────────────────────────
    # Largest single-day point decline ever for the Dow at the time.
    # ZM (Zoom) went UP during COVID — clever negative test for Flash Crash.
    {
        "name": "COVID_Crash_Mar2020",
        "description": "COVID market crash — SPY, JETS, TSLA, ZM",
        "date": "2020-03-16",
        "interval": "1m",
        "stocks": [
            {
                "ticker": "SPY",
                "label": "S&P 500 — dropped 12% in one day",
                "expected_alerts": ["FLASH_CRASH", "VOLATILITY", "VOLUME_SURGE"]
            },
            {
                "ticker": "JETS",
                "label": "Airlines ETF — most devastated sector",
                "expected_alerts": ["FLASH_CRASH", "VOLUME_SURGE", "ORDER_IMBALANCE"]
            },
            {
                "ticker": "TSLA",
                "label": "Tesla — crashed then recovered, tests alert clearing",
                "expected_alerts": ["FLASH_CRASH", "VOLATILITY"]
            },
            {
                "ticker": "ZM",
                "label": "Zoom — went UP during COVID. Should NOT trigger Flash Crash!",
                "expected_alerts": ["VOLUME_SURGE", "PRICE_SPIKE"]  # but NOT flash crash
            },
        ]
    },

    # ── SCENARIO 4: Normal Quiet Days (Negative Controls) ───────────────────
    # Nothing should fire. This proves the chip isn't a false-alarm machine.
    {
        "name": "Normal_Baseline",
        "description": "Quiet normal trading days — chip should stay SILENT",
        "date": "2019-06-04",
        "interval": "1m",
        "stocks": [
            {
                "ticker": "SPY",
                "label": "S&P 500 — ordinary Tuesday in 2019",
                "expected_alerts": []  # NOTHING should fire
            },
            {
                "ticker": "MSFT",
                "label": "Microsoft — steady blue chip",
                "expected_alerts": []
            },
            {
                "ticker": "KO",
                "label": "Coca-Cola — famously boring, ultra-low volatility",
                "expected_alerts": []
            },
            {
                "ticker": "GLD",
                "label": "Gold ETF — different asset class, slow-moving",
                "expected_alerts": []
            },
        ]
    },
]


# ═══════════════════════════════════════════════════════════════════════════════
# CHIP ENCODING FUNCTIONS
# These match EXACTLY the pin mapping in tt_um_nanotrade.v
# ═══════════════════════════════════════════════════════════════════════════════

def encode_price(price_12bit):
    """
    Encode a 12-bit price into (ui_in, uio_in) bytes.

    From tt_um_nanotrade.v:
        ui_in[7:6]  = 2'b00  (type = price)
        ui_in[5:0]  = price[5:0]   (low 6 bits)
        uio_in[5:0] = price[11:6]  (high 6 bits)

    So the chip reassembles: price = {uio_in[5:0], ui_in[5:0]}
    """
    price_12bit = int(np.clip(price_12bit, 0, 4095))
    ui  = (0b00 << 6) | (price_12bit & 0x3F)        # type=00, low 6 bits
    uio = (price_12bit >> 6) & 0x3F                  # high 6 bits
    return ui, uio

def encode_volume(vol_12bit):
    """
    Encode a 12-bit volume into (ui_in, uio_in) bytes.
        ui_in[7:6]  = 2'b01  (type = volume)
        ui_in[5:0]  = vol[5:0]
        uio_in[5:0] = vol[11:6]
    """
    vol_12bit = int(np.clip(vol_12bit, 0, 4095))
    ui  = (0b01 << 6) | (vol_12bit & 0x3F)
    uio = (vol_12bit >> 6) & 0x3F
    return ui, uio

def encode_buy(qty_6bit):
    """
    Encode a buy order.
        ui_in[7:6]  = 2'b10  (type = buy)
        ui_in[5:0]  = qty
        uio_in      = 0x00
    """
    qty = int(np.clip(qty_6bit, 0, 63))
    return (0b10 << 6) | qty, 0x00

def encode_sell(qty_6bit):
    """
    Encode a sell order.
        ui_in[7:6]  = 2'b11  (type = sell)
        ui_in[5:0]  = qty
        uio_in      = 0x00
    """
    qty = int(np.clip(qty_6bit, 0, 63))
    return (0b11 << 6) | qty, 0x00

def encode_idle():
    """No input this cycle."""
    return 0x00, 0x00


# ═══════════════════════════════════════════════════════════════════════════════
# PRICE SCALING
# Real stock prices (e.g. $483) must be mapped to 12-bit integers (0–4095).
# We use min-max scaling per stock, preserving relative movements.
# ═══════════════════════════════════════════════════════════════════════════════

def scale_price(prices, target_baseline=200, target_range=800):
    """
    Scale a series of real prices into 12-bit chip values.

    Strategy:
    - Map the median price → target_baseline (chip units)
    - Map the full price range → target_range (chip units)
    - This means a 50% price drop maps to a chip drop of ~400 units,
      which is well above the FLASH_CRASH threshold of 40 units.

    Example:
        GME prices: $148 → $483 (range $335)
        Scaled to chip: ~200 → ~1125 (range ~925)
        A drop from $483 to $112 = 77% → chip drop of ~715 units → FLASH CRASH ✅
    """
    prices = np.array(prices, dtype=float)
    p_min  = prices.min()
    p_max  = prices.max()
    p_range = p_max - p_min if p_max > p_min else 1.0

    # Scale to target_range chip units around target_baseline
    scaled = target_baseline + (prices - p_min) / p_range * target_range
    return np.clip(scaled, 1, 4090).astype(int)

def scale_volume(volumes, target_normal=100, target_max=3000):
    """
    Scale real volumes into 12-bit chip values.

    We map the median volume → target_normal.
    A 10x volume surge maps to chip value ~1000, which is 10x the baseline
    of 100, well above the VOL_SURGE threshold of 2x.
    """
    volumes = np.array(volumes, dtype=float)
    v_median = np.median(volumes)
    if v_median == 0:
        v_median = 1.0
    # Normalize so median = target_normal
    scaled = (volumes / v_median) * target_normal
    return np.clip(scaled, 1, target_max).astype(int)


# ═══════════════════════════════════════════════════════════════════════════════
# STIMULUS GENERATION
# Converts one bar of OHLCV data into a sequence of chip cycles.
# ═══════════════════════════════════════════════════════════════════════════════

def bar_to_cycles(open_p, high_p, low_p, close_p, volume, buy_pressure):
    """
    Convert one OHLCV bar into a list of (ui_in, uio_in) cycle tuples.

    Each bar is expanded into ~16 cycles to give the chip's detectors
    time to react — matching roughly how the chip's 256-cycle window works.

    buy_pressure: 0.0 to 1.0 — fraction of order flow that is buying
                  (derived from price direction: going up = more buys)

    Cycle layout per bar:
        Cycles  0- 3: Send price (open, high, low, close) — 4 price ticks
        Cycles  4- 5: Send volume × 2
        Cycles  6-11: Send buy/sell orders based on pressure
        Cycles 12-15: Idle (let detectors settle)
    """
    cycles = []

    # Price ticks: open, high, low, close (captures intra-bar movement)
    for p in [open_p, high_p, low_p, close_p]:
        cycles.append(encode_price(p))

    # Volume ticks (send twice so the rolling average sees it clearly)
    for _ in range(2):
        cycles.append(encode_volume(volume))

    # Order flow: 6 orders split by buy/sell pressure
    n_buys  = int(round(buy_pressure * 6))
    n_sells = 6 - n_buys
    qty = 10  # fixed quantity per order
    for _ in range(n_buys):
        cycles.append(encode_buy(qty))
    for _ in range(n_sells):
        cycles.append(encode_sell(qty))

    # Idle cycles
    for _ in range(4):
        cycles.append(encode_idle())

    return cycles  # 16 cycles per bar


def df_to_stimulus(df, ticker):
    """
    Convert a full DataFrame of OHLCV bars into a flat list of chip cycles.

    Also produces annotation markers so the testbench knows which cycle
    corresponds to which bar (for the golden checker to use).

    Returns:
        cycles     — list of (ui_in, uio_in) tuples, one per clock cycle
        markers    — list of (cycle_index, bar_index, timestamp) for annotations
    """
    # Scale prices and volumes to chip units
    all_prices = np.concatenate([df['Open'].values, df['High'].values,
                                  df['Low'].values,  df['Close'].values])
    p_scaled = scale_price(all_prices)

    # Split back into columns
    n = len(df)
    open_s  = p_scaled[0*n : 1*n]
    high_s  = p_scaled[1*n : 2*n]
    low_s   = p_scaled[2*n : 3*n]
    close_s = p_scaled[3*n : 4*n]

    vol_s = scale_volume(df['Volume'].values)

    # Buy pressure from price direction
    price_deltas  = df['Close'].values - df['Open'].values
    buy_pressures = np.where(price_deltas > 0, 0.7,       # going up → more buys
                    np.where(price_deltas < 0, 0.3, 0.5)) # going down → more sells

    # Assemble all cycles
    all_cycles = []
    markers    = []

    # Warm-up: 32 cycles of idle to let reset settle
    for _ in range(32):
        all_cycles.append(encode_idle())

    for i in range(n):
        markers.append((len(all_cycles), i, df.index[i]))
        bar_cycles = bar_to_cycles(
            open_s[i], high_s[i], low_s[i], close_s[i],
            vol_s[i], buy_pressures[i]
        )
        all_cycles.extend(bar_cycles)

    return all_cycles, markers


# ═══════════════════════════════════════════════════════════════════════════════
# SYNTHETIC DATA GENERATOR
# Used when yfinance is unavailable OR as a guaranteed-to-work fallback.
# Models each event faithfully based on what actually happened.
# ═══════════════════════════════════════════════════════════════════════════════

def synthetic_gme_20210128(n_bars=390):
    """
    Synthetic GME Jan 28 2021 (1-minute bars, 390 = full trading day).
    Faithfully models: steady rise → spike to $483 → collapse to $112.
    Phase 1 (0-120 bars):  Normal open around $148, rising slowly
    Phase 2 (120-200 bars): Explosive surge to $483
    Phase 3 (200-390 bars): Collapse to $112 with high volatility
    """
    t = np.arange(n_bars)
    prices = np.zeros(n_bars)
    volumes = np.zeros(n_bars)
    rng = np.random.default_rng(42)

    # Phase 1: Normal rise
    mask1 = t < 120
    prices[mask1]  = 148 + t[mask1] * 0.8 + rng.normal(0, 3, mask1.sum())
    volumes[mask1] = 1e6 + rng.normal(0, 1e5, mask1.sum())

    # Phase 2: Explosive spike
    mask2 = (t >= 120) & (t < 200)
    t2 = t[mask2] - 120
    prices[mask2]  = 148 + 96 + t2 * 3.0 + rng.normal(0, 8, mask2.sum())
    volumes[mask2] = 5e6 + t2 * 1e5 + rng.normal(0, 5e5, mask2.sum())

    # Phase 3: Flash crash collapse
    mask3 = t >= 200
    t3 = t[mask3] - 200
    prices[mask3]  = 483 - t3 * 1.9 + rng.normal(0, 15, mask3.sum())
    volumes[mask3] = 8e6 - t3 * 1e4 + rng.normal(0, 8e5, mask3.sum())

    prices  = np.clip(prices,  50, 600)
    volumes = np.clip(volumes, 1e5, 2e7)

    idx = pd.date_range("2021-01-28 09:30", periods=n_bars, freq="1min")
    return pd.DataFrame({
        'Open':   prices + rng.normal(0, 1, n_bars),
        'High':   prices + np.abs(rng.normal(3, 2, n_bars)),
        'Low':    prices - np.abs(rng.normal(3, 2, n_bars)),
        'Close':  prices,
        'Volume': volumes.astype(int)
    }, index=idx)

def synthetic_amc_20210128(n_bars=390):
    """AMC — same frenzy as GME but ~40% intensity."""
    rng = np.random.default_rng(43)
    t = np.arange(n_bars)
    prices  = 5 + t * 0.015 + rng.normal(0, 0.5, n_bars)
    prices[150:220] += np.linspace(0, 8, 70)
    prices[220:]    -= np.linspace(0, 5, n_bars - 220)
    volumes = 2e6 + rng.normal(0, 3e5, n_bars)
    volumes[150:220] *= 4.0
    prices  = np.clip(prices, 2, 25)
    volumes = np.clip(volumes, 1e5, 3e7)
    idx = pd.date_range("2021-01-28 09:30", periods=n_bars, freq="1min")
    return pd.DataFrame({'Open': prices, 'High': prices*1.01,
                         'Low': prices*0.99, 'Close': prices,
                         'Volume': volumes.astype(int)}, index=idx)

def synthetic_bb_20210128(n_bars=390):
    """BlackBerry — moderate spike, ~20% intensity."""
    rng = np.random.default_rng(44)
    t = np.arange(n_bars)
    prices = 14 + rng.normal(0, 0.5, n_bars)
    prices[100:180] += np.linspace(0, 4, 80)
    prices[180:]    -= np.linspace(0, 3, n_bars - 180)
    volumes = 5e5 + rng.normal(0, 5e4, n_bars)
    volumes[100:180] *= 2.5
    prices  = np.clip(prices, 10, 25)
    volumes = np.clip(volumes, 1e4, 5e6)
    idx = pd.date_range("2021-01-28 09:30", periods=n_bars, freq="1min")
    return pd.DataFrame({'Open': prices, 'High': prices*1.005,
                         'Low': prices*0.995, 'Close': prices,
                         'Volume': volumes.astype(int)}, index=idx)

def synthetic_nok_20210128(n_bars=390):
    """Nokia — barely anomalous, tests sensitivity boundary."""
    rng = np.random.default_rng(45)
    t = np.arange(n_bars)
    prices = 4.5 + rng.normal(0, 0.1, n_bars)
    prices[120:160] += np.linspace(0, 1.2, 40)
    prices[160:]    -= np.linspace(0, 0.8, n_bars - 160)
    volumes = 3e5 + rng.normal(0, 3e4, n_bars)
    volumes[120:160] *= 2.2
    prices  = np.clip(prices, 3, 7)
    volumes = np.clip(volumes, 1e4, 5e6)
    idx = pd.date_range("2021-01-28 09:30", periods=n_bars, freq="1min")
    return pd.DataFrame({'Open': prices, 'High': prices*1.003,
                         'Low': prices*0.997, 'Close': prices,
                         'Volume': volumes.astype(int)}, index=idx)

def synthetic_spy_flash2010(n_bars=390):
    """SPY May 6 2010 — 9% drop in 15 minutes then partial recovery."""
    rng = np.random.default_rng(50)
    t = np.arange(n_bars)
    prices = 120 + rng.normal(0, 0.3, n_bars)
    # The crash: bars 170-205 (~2:40pm to 2:47pm)
    crash_start, crash_end = 170, 205
    prices[crash_start:crash_end] = np.linspace(120, 108, crash_end - crash_start)
    prices[crash_end:crash_end+30] = np.linspace(108, 116, 30)
    prices[crash_end+30:] = 116 + rng.normal(0, 0.5, n_bars - crash_end - 30)
    volumes = 3e6 + rng.normal(0, 2e5, n_bars)
    volumes[crash_start:crash_end+30] *= 5.0
    prices  = np.clip(prices, 100, 130)
    volumes = np.clip(volumes, 1e5, 5e7)
    idx = pd.date_range("2010-05-06 09:30", periods=n_bars, freq="1min")
    return pd.DataFrame({'Open': prices, 'High': prices+0.2,
                         'Low': prices-0.2, 'Close': prices,
                         'Volume': volumes.astype(int)}, index=idx)

def synthetic_pg_flash2010(n_bars=390):
    """PG May 6 2010 — dropped from $60 to near $0 in seconds."""
    rng = np.random.default_rng(51)
    prices = np.full(n_bars, 60.0) + rng.normal(0, 0.2, n_bars)
    # Extreme crash at bars 175-180
    prices[175:180] = np.linspace(60, 1, 5)
    prices[180:190] = np.linspace(1, 58, 10)
    volumes = 2e5 + rng.normal(0, 2e4, n_bars)
    volumes[170:195] *= 10.0
    prices  = np.clip(prices, 0.01, 70)
    volumes = np.clip(volumes, 1e3, 1e7)
    idx = pd.date_range("2010-05-06 09:30", periods=n_bars, freq="1min")
    return pd.DataFrame({'Open': prices, 'High': prices*1.005,
                         'Low': prices*0.995, 'Close': prices,
                         'Volume': volumes.astype(int)}, index=idx)

def synthetic_aapl_flash2010(n_bars=390):
    """AAPL May 6 2010 — blue chip dragged down ~5%."""
    rng = np.random.default_rng(52)
    prices = 262 + rng.normal(0, 1, n_bars)
    prices[170:200] -= np.linspace(0, 14, 30)
    prices[200:230] += np.linspace(0, 10, 30)
    volumes = 5e6 + rng.normal(0, 5e5, n_bars)
    volumes[165:205] *= 3.0
    prices  = np.clip(prices, 240, 280)
    volumes = np.clip(volumes, 1e5, 5e7)
    idx = pd.date_range("2010-05-06 09:30", periods=n_bars, freq="1min")
    return pd.DataFrame({'Open': prices, 'High': prices+0.5,
                         'Low': prices-0.5, 'Close': prices,
                         'Volume': volumes.astype(int)}, index=idx)

def synthetic_acn_flash2010(n_bars=390):
    """ACN May 6 2010 — traded at literally $0.01. The most extreme case."""
    rng = np.random.default_rng(53)
    prices = np.full(n_bars, 41.0) + rng.normal(0, 0.2, n_bars)
    # The famous near-zero trade
    prices[176:179] = [10, 0.01, 0.01]
    prices[179:185] = np.linspace(0.01, 38, 6)
    volumes = 1e5 + rng.normal(0, 1e4, n_bars)
    volumes[172:188] *= 8.0
    prices  = np.clip(prices, 0.01, 50)
    volumes = np.clip(volumes, 1e3, 5e6)
    idx = pd.date_range("2010-05-06 09:30", periods=n_bars, freq="1min")
    return pd.DataFrame({'Open': prices, 'High': prices*1.01,
                         'Low': prices*0.5, 'Close': prices,
                         'Volume': volumes.astype(int)}, index=idx)

def synthetic_spy_covid2020(n_bars=390):
    """SPY Mar 16 2020 — 12% single-day drop."""
    rng = np.random.default_rng(60)
    # Opens down 8%, keeps falling to -12%, slight recovery at close
    prices = np.linspace(270, 240, n_bars) + rng.normal(0, 1.5, n_bars)
    prices[:30] = np.linspace(290, 270, 30)
    volumes = 8e6 + rng.normal(0, 1e6, n_bars)
    volumes[0:100] *= 2.0   # panic at open
    prices  = np.clip(prices, 220, 300)
    volumes = np.clip(volumes, 1e5, 1e8)
    idx = pd.date_range("2020-03-16 09:30", periods=n_bars, freq="1min")
    return pd.DataFrame({'Open': prices, 'High': prices+1,
                         'Low': prices-2, 'Close': prices,
                         'Volume': volumes.astype(int)}, index=idx)

def synthetic_jets_covid2020(n_bars=390):
    """JETS (Airlines ETF) — most devastated sector, -30% that week."""
    rng = np.random.default_rng(61)
    prices = np.linspace(22, 14, n_bars) + rng.normal(0, 0.5, n_bars)
    volumes = 3e6 + rng.normal(0, 5e5, n_bars)
    volumes[0:60] *= 3.0
    prices  = np.clip(prices, 10, 28)
    volumes = np.clip(volumes, 1e4, 2e7)
    idx = pd.date_range("2020-03-16 09:30", periods=n_bars, freq="1min")
    return pd.DataFrame({'Open': prices, 'High': prices+0.3,
                         'Low': prices-0.5, 'Close': prices,
                         'Volume': volumes.astype(int)}, index=idx)

def synthetic_tsla_covid2020(n_bars=390):
    """TSLA — crashed then partially recovered, tests alert clearing."""
    rng = np.random.default_rng(62)
    prices = np.full(n_bars, 130.0) + rng.normal(0, 2, n_bars)
    prices[:130]  -= np.linspace(0, 25, 130)  # crash
    prices[130:260] += np.linspace(0, 15, 130)  # recovery
    volumes = 5e7 + rng.normal(0, 5e6, n_bars)
    prices  = np.clip(prices, 90, 165)
    volumes = np.clip(volumes, 1e6, 3e8)
    idx = pd.date_range("2020-03-16 09:30", periods=n_bars, freq="1min")
    return pd.DataFrame({'Open': prices, 'High': prices+2,
                         'Low': prices-3, 'Close': prices,
                         'Volume': volumes.astype(int)}, index=idx)

def synthetic_zm_covid2020(n_bars=390):
    """
    Zoom — went UP during COVID. Volume surge + price spike but NO flash crash.
    This is the clever negative test — chip should NOT say FLASH_CRASH.
    """
    rng = np.random.default_rng(63)
    prices = np.linspace(110, 160, n_bars) + rng.normal(0, 3, n_bars)
    volumes = 4e6 + rng.normal(0, 8e5, n_bars)
    volumes[0:100] *= 2.5
    prices  = np.clip(prices, 90, 180)
    volumes = np.clip(volumes, 1e5, 3e7)
    idx = pd.date_range("2020-03-16 09:30", periods=n_bars, freq="1min")
    return pd.DataFrame({'Open': prices, 'High': prices+2,
                         'Low': prices-1, 'Close': prices,
                         'Volume': volumes.astype(int)}, index=idx)

def synthetic_quiet(ticker, seed, n_bars=390):
    """Normal quiet day — boring, flat, low volume. Nothing should fire."""
    rng = np.random.default_rng(seed)
    base_prices = {"SPY": 285, "MSFT": 130, "KO": 55, "GLD": 135}
    base_vols   = {"SPY": 5e6, "MSFT": 2e7, "KO": 1e7, "GLD": 8e6}
    bp = base_prices.get(ticker, 100)
    bv = base_vols.get(ticker, 5e6)
    prices  = bp + rng.normal(0, 0.3, n_bars)   # tiny noise, no trend
    volumes = bv + rng.normal(0, bv*0.05, n_bars) # 5% volume noise
    prices  = np.clip(prices, bp*0.95, bp*1.05)
    volumes = np.clip(volumes, bv*0.5, bv*2)
    idx = pd.date_range("2019-06-04 09:30", periods=n_bars, freq="1min")
    return pd.DataFrame({'Open': prices, 'High': prices+0.1,
                         'Low': prices-0.1, 'Close': prices,
                         'Volume': volumes.astype(int)}, index=idx)

# Map (ticker, date) → synthetic generator function
SYNTHETIC_MAP = {
    ("GME",  "2021-01-28"): synthetic_gme_20210128,
    ("AMC",  "2021-01-28"): synthetic_amc_20210128,
    ("BB",   "2021-01-28"): synthetic_bb_20210128,
    ("NOK",  "2021-01-28"): synthetic_nok_20210128,
    ("SPY",  "2010-05-06"): synthetic_spy_flash2010,
    ("PG",   "2010-05-06"): synthetic_pg_flash2010,
    ("AAPL", "2010-05-06"): synthetic_aapl_flash2010,
    ("ACN",  "2010-05-06"): synthetic_acn_flash2010,
    ("SPY",  "2020-03-16"): synthetic_spy_covid2020,
    ("JETS", "2020-03-16"): synthetic_jets_covid2020,
    ("TSLA", "2020-03-16"): synthetic_tsla_covid2020,
    ("ZM",   "2020-03-16"): synthetic_zm_covid2020,
    ("SPY",  "2019-06-04"): lambda: synthetic_quiet("SPY",  70),
    ("MSFT", "2019-06-04"): lambda: synthetic_quiet("MSFT", 71),
    ("KO",   "2019-06-04"): lambda: synthetic_quiet("KO",   72),
    ("GLD",  "2019-06-04"): lambda: synthetic_quiet("GLD",  73),
}


# ═══════════════════════════════════════════════════════════════════════════════
# DATA FETCHER
# Tries real yfinance data first, falls back to synthetic if unavailable.
# ═══════════════════════════════════════════════════════════════════════════════

def fetch_data(ticker, date, interval="1m"):
    """
    Attempt to download real data from Yahoo Finance.
    Falls back to synthetic model if:
    - yfinance not installed
    - Network unavailable
    - Data not available for that date
    """
    key = (ticker, date)

    if HAS_YFINANCE:
        try:
            print(f"  📡 Downloading {ticker} {date} from Yahoo Finance...")
            start = pd.Timestamp(date)
            end   = start + pd.Timedelta(days=1)
            df = yf.download(ticker, start=start, end=end,
                             interval=interval, progress=False, auto_adjust=True)
            if df is not None and len(df) > 10:
                print(f"     ✅ Got {len(df)} bars from Yahoo Finance")
                return df, "real"
            else:
                print(f"     ⚠  No data returned, using synthetic model")
        except Exception as e:
            print(f"     ⚠  Download failed ({e}), using synthetic model")

    # Fallback to synthetic
    if key in SYNTHETIC_MAP:
        df = SYNTHETIC_MAP[key]()
        print(f"  🔬 Using synthetic {ticker} {date} model ({len(df)} bars)")
        return df, "synthetic"
    else:
        raise ValueError(f"No synthetic model for {ticker} {date}")


# ═══════════════════════════════════════════════════════════════════════════════
# FILE WRITERS
# ═══════════════════════════════════════════════════════════════════════════════

def write_stimulus_memh(cycles, filepath):
    """
    Write stimulus cycles to a $readmemh-compatible hex file.

    Format: one line per cycle = "XXYY"
        XX = ui_in  (hex byte, 2 chars)
        YY = uio_in (hex byte, 2 chars)

    The testbench reads this with:
        $readmemh("stimulus.memh", stimulus_mem);
    """
    with open(filepath, "w") as f:
        f.write("// NanoTrade stimulus file — format: ui_in[7:0] uio_in[7:0]\n")
        f.write(f"// Total cycles: {len(cycles)}\n")
        for ui, uio in cycles:
            f.write(f"{ui:02x}{uio:02x}\n")

def write_golden(expected_alerts, markers, filepath, ticker, date, source):
    """
    Write the golden reference file — what alerts we expect and when.
    The testbench checker compares actual chip output against this.
    """
    with open(filepath, "w") as f:
        f.write(f"// NanoTrade Golden Reference\n")
        f.write(f"// Ticker: {ticker}  Date: {date}  Source: {source}\n")
        f.write(f"// Expected alerts: {', '.join(expected_alerts) if expected_alerts else 'NONE'}\n")
        f.write(f"// Total bars: {len(markers)}\n")
        f.write("//\n")
        f.write("// Format: EXPECTED_ALERT_TYPE  (chip should fire at least once)\n")
        for alert in expected_alerts:
            f.write(f"EXPECT {alert}\n")
        if not expected_alerts:
            f.write("EXPECT NONE\n")

def write_info(ticker, date, source, df, expected_alerts, n_cycles, filepath):
    """Write a human-readable summary of the scenario."""
    with open(filepath, "w") as f:
        f.write(f"NanoTrade Stimulus Info\n")
        f.write(f"=======================\n")
        f.write(f"Ticker  : {ticker}\n")
        f.write(f"Date    : {date}\n")
        f.write(f"Source  : {source}\n")
        f.write(f"Bars    : {len(df)}\n")
        f.write(f"Cycles  : {n_cycles}\n")
        f.write(f"\nPrice range: ${df['Close'].min():.2f} — ${df['Close'].max():.2f}\n")
        f.write(f"Volume range: {df['Volume'].min():,} — {df['Volume'].max():,}\n")
        f.write(f"\nExpected alerts:\n")
        if expected_alerts:
            for a in expected_alerts:
                f.write(f"  ✅ {a}\n")
        else:
            f.write(f"  ✅ NONE (this is a quiet baseline test)\n")


# ═══════════════════════════════════════════════════════════════════════════════
# MAIN PIPELINE
# ═══════════════════════════════════════════════════════════════════════════════

def process_stock(ticker, date, interval, expected_alerts, label):
    """Full pipeline for one stock: fetch → encode → write files."""
    print(f"\n{'─'*60}")
    print(f"  {ticker} | {date}")
    print(f"  {label}")
    print(f"{'─'*60}")

    # Fetch data
    df, source = fetch_data(ticker, date, interval)

    # Convert to chip cycles
    cycles, markers = df_to_stimulus(df, ticker)

    # Build output filename base
    safe_date = date.replace("-", "")
    base = f"{ticker}_{safe_date}"
    stem = os.path.join(OUT_DIR, base)

    # Write files
    stimulus_path = f"{stem}_stimulus.memh"
    golden_path   = f"{stem}_golden.txt"
    info_path     = f"{stem}_info.txt"

    write_stimulus_memh(cycles, stimulus_path)
    write_golden(expected_alerts, markers, golden_path, ticker, date, source)
    write_info(ticker, date, source, df, expected_alerts, len(cycles), info_path)

    print(f"  📄 {len(cycles)} cycles written → {os.path.basename(stimulus_path)}")
    print(f"  📋 Golden: expects {', '.join(expected_alerts) if expected_alerts else 'NONE'}")

    return {
        "ticker":   ticker,
        "date":     date,
        "base":     base,
        "source":   source,
        "n_cycles": len(cycles),
        "n_bars":   len(df),
        "expected": expected_alerts,
    }


def write_run_script(results):
    """
    Write a shell script that runs the iverilog simulation for all 16 stocks.
    Each run uses the matching stimulus .memh file.
    """
    script_path = os.path.join(OUT_DIR, "run_all_scenarios.sh")
    with open(script_path, "w") as f:
        f.write("#!/bin/bash\n")
        f.write("# NanoTrade — Run all 16 stock scenarios\n")
        f.write("# Run from the project root directory\n\n")
        f.write("set -e\n")
        f.write("PASS=0; FAIL=0\n\n")

        f.write("# Compile once\n")
        f.write("echo 'Compiling NanoTrade...'\n")
        f.write("iverilog -o sim_nanotrade \\\n")
        f.write("    tb_nanotrade_stock.v tt_um_nanotrade.v order_book.v \\\n")
        f.write("    anomaly_detector.v feature_extractor.v ml_inference_engine.v\n\n")

        scenario_names = []
        for r in results:
            scenario_names.append(r["name"] if "name" in r else r["base"])

        f.write("# Run each scenario\n")
        for r in results:
            base = r["base"]
            expected = r["expected"]
            f.write(f"\necho ''\n")
            f.write(f"echo '{'='*50}'\n")
            f.write(f"echo 'SCENARIO: {base}'\n")
            exp_str = " ".join(expected) if expected else "NONE"
            f.write(f"echo 'Expected: {exp_str}'\n")
            f.write(f"echo '{'='*50}'\n")
            f.write(f"STIMULUS=stimuli/{base}_stimulus.memh \\\n")
            f.write(f"GOLDEN=stimuli/{base}_golden.txt \\\n")
            f.write(f"TICKER={r['ticker']} \\\n")
            f.write(f"vvp sim_nanotrade | tee stimuli/{base}_result.txt\n")
            f.write(f"python3 check_results.py stimuli/{base}_result.txt "
                    f"stimuli/{base}_golden.txt && PASS=$((PASS+1)) || FAIL=$((FAIL+1))\n")

        f.write("\necho ''\n")
        f.write("echo '========================================'\n")
        f.write("echo \"FINAL SCORE: $PASS passed, $FAIL failed\"\n")
        f.write("echo '========================================'\n")

    os.chmod(script_path, 0o755)
    print(f"\n✅ Run script: {script_path}")


def write_check_script():
    """Write the Python result checker — compares sim output to golden file."""
    path = os.path.join(os.path.dirname(__file__), "check_results.py")
    code = '''"""
NanoTrade Result Checker
========================
Compares simulation output (vvp log) against golden reference.
Usage:
    python3 check_results.py <result.txt> <golden.txt>
"""
import sys, re

def parse_golden(path):
    expected = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line.startswith("EXPECT "):
                expected.append(line.split()[1])
    return expected

def parse_result(path):
    """Extract all alert types that fired from the simulation log."""
    fired = set()
    alert_map = {
        "SPIKE":    "PRICE_SPIKE",
        "VOL_DRY":  "VOL_DRY",
        "VOL_SRGE": "VOLUME_SURGE",
        "VELOCITY": "TRADE_VELOCITY",
        "IMBALANC": "ORDER_IMBALANCE",
        "SPREAD":   "SPREAD_WIDENING",
        "VOLATIL":  "VOLATILITY",
        "FLASH":    "FLASH_CRASH",
        # ML names
        "SPIKE ":   "PRICE_SPIKE",
        "VOLSRG":   "VOLUME_SURGE",
        "FLASH!":   "FLASH_CRASH",
        "IMBAL ":   "ORDER_IMBALANCE",
        "QSTUFF":   "QUOTE_STUFFING",
    }
    with open(path) as f:
        for line in f:
            for key, val in alert_map.items():
                if key in line:
                    fired.add(val)
    return fired

if len(sys.argv) != 3:
    print("Usage: check_results.py <result.txt> <golden.txt>")
    sys.exit(1)

result_path = sys.argv[1]
golden_path = sys.argv[2]

expected = parse_golden(golden_path)
fired    = parse_result(result_path)

print(f"\\nChecker: {result_path.split(\'/\')[-1]}")
print(f"  Expected: {expected}")
print(f"  Fired:    {sorted(fired)}")

if expected == ["NONE"]:
    if not fired:
        print("  ✅ PASS — Chip correctly stayed silent on normal data")
        sys.exit(0)
    else:
        print(f"  ❌ FAIL — False alarms: {sorted(fired)}")
        sys.exit(1)
else:
    missing = [e for e in expected if e not in fired]
    if not missing:
        print(f"  ✅ PASS — All expected alerts detected")
        sys.exit(0)
    else:
        print(f"  ❌ FAIL — Missed: {missing}")
        sys.exit(1)
'''
    with open(path, "w") as f:
        f.write(code)
    print(f"✅ Checker: {os.path.basename(path)}")


def main():
    print("╔══════════════════════════════════════════════════════╗")
    print("║     NanoTrade Stock Data Pipeline                    ║")
    print("║     IEEE UofT ASIC Team                              ║")
    print("╚══════════════════════════════════════════════════════╝")
    print(f"\nOutput directory: {OUT_DIR}")
    print(f"yfinance available: {HAS_YFINANCE}")

    all_results = []

    for scenario in SCENARIOS:
        print(f"\n{'═'*60}")
        print(f"  SCENARIO: {scenario['name']}")
        print(f"  {scenario['description']}")
        print(f"{'═'*60}")

        for stock in scenario["stocks"]:
            result = process_stock(
                ticker   = stock["ticker"],
                date     = scenario["date"],
                interval = scenario["interval"],
                expected_alerts = stock["expected_alerts"],
                label    = stock["label"],
            )
            result["name"]     = scenario["name"]
            result["scenario"] = scenario["name"]
            all_results.append(result)

    # Write helper scripts
    write_run_script(all_results)
    write_check_script()

    # Summary
    print(f"\n{'═'*60}")
    print(f"  PIPELINE COMPLETE")
    print(f"{'═'*60}")
    print(f"\nGenerated {len(all_results)} stimulus files in stimuli/\n")
    print(f"{'Stock':<8} {'Date':<12} {'Source':<10} {'Bars':<6} {'Cycles':<8} Expected Alerts")
    print(f"{'─'*70}")
    for r in all_results:
        alerts = ', '.join(r['expected']) if r['expected'] else 'NONE'
        print(f"{r['ticker']:<8} {r['date']:<12} {r['source']:<10} {r['n_bars']:<6} {r['n_cycles']:<8} {alerts}")

    print(f"\n{'─'*70}")
    print(f"\nNext steps:")
    print(f"  1. Run: python3 generate_stimuli.py   (already done!)")
    print(f"  2. Run: iverilog -o sim_nanotrade tb_nanotrade_stock.v ...")
    print(f"  3. Run: bash stimuli/run_all_scenarios.sh")
    print(f"  4. Or simulate one stock: STIMULUS=stimuli/GME_20210128_stimulus.memh vvp sim_nanotrade")

if __name__ == "__main__":
    main()
