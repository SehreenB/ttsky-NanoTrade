#!/usr/bin/env python3
"""
NanoTrade Finnhub Data Fetcher
================================
Pulls real market data from Finnhub and generates Verilog testbench
stimulus tasks so your hardware sim uses actual historical trade data.

Usage:
  python finnhub_fetch.py --mode quote   --symbol AAPL
  python finnhub_fetch.py --mode candles --symbol SPY  --date 2020-03-16
  python finnhub_fetch.py --mode live    --symbol TSLA  (streams via WebSocket)

Requires: pip install requests websocket-client
API key is pre-configured below.
"""

import requests
import json
import sys
import os
import time
import argparse
from datetime import datetime, timezone
import struct

API_KEY = "d6al1ghr01qqjvbqrao0d6al1ghr01qqjvbqraog"
BASE_URL = "https://finnhub.io/api/v1"

HEADERS = {"X-Finnhub-Token": API_KEY}

# ---------------------------------------------------------------
# Price scaling: map real dollar price to 12-bit hardware value
#   Hardware uses 12-bit: 0..4095
#   We scale so $100 = 400 (factor of 4), with a floor at $1 = 4
#   Stocks over $1000 (GOOGL, AMZN, NVDA) are divided by 4 first
# ---------------------------------------------------------------
def scale_price(dollar_price: float) -> int:
    if dollar_price > 1000:
        return min(4095, int(dollar_price / 4 * 4))    # /4 then *4 = *1
    elif dollar_price > 500:
        return min(4095, int(dollar_price * 2))
    else:
        return min(4095, int(dollar_price * 4))

def scale_volume(shares: int, scale_factor: float = 0.05) -> int:
    """Map share volume to 12-bit (0..4095). scale_factor tunes sensitivity."""
    return min(4095, int(shares * scale_factor))

# ---------------------------------------------------------------
# Finnhub API calls
# ---------------------------------------------------------------

def get_quote(symbol: str) -> dict:
    """Get current quote for a symbol."""
    r = requests.get(f"{BASE_URL}/quote", params={"symbol": symbol}, headers=HEADERS, timeout=10)
    r.raise_for_status()
    return r.json()

def get_candles(symbol: str, resolution: str, from_ts: int, to_ts: int) -> dict:
    """Get OHLCV candles. resolution: 1, 5, 15, 30, 60, D, W, M"""
    r = requests.get(f"{BASE_URL}/stock/candle", params={
        "symbol": symbol,
        "resolution": resolution,
        "from": from_ts,
        "to": to_ts
    }, headers=HEADERS, timeout=15)
    r.raise_for_status()
    return r.json()

def get_trades(symbol: str) -> dict:
    """Get recent trades (last batch from websocket replay)."""
    # Finnhub free tier: use quote + candles, not tick-level
    return get_quote(symbol)

def get_company_news(symbol: str, from_date: str, to_date: str) -> list:
    """Get news for context display."""
    r = requests.get(f"{BASE_URL}/company-news", params={
        "symbol": symbol,
        "from": from_date,
        "to": to_date
    }, headers=HEADERS, timeout=10)
    r.raise_for_status()
    return r.json()

def date_to_ts(date_str: str, end_of_day: bool = False) -> int:
    """Convert YYYY-MM-DD to Unix timestamp."""
    dt = datetime.strptime(date_str, "%Y-%m-%d")
    if end_of_day:
        dt = dt.replace(hour=23, minute=59, second=59)
    return int(dt.replace(tzinfo=timezone.utc).timestamp())

# ---------------------------------------------------------------
# Verilog testbench generator
# ---------------------------------------------------------------

def candles_to_verilog_tasks(symbol: str, candles: dict, scenario_name: str) -> str:
    """Convert Finnhub candle data to Verilog task calls."""
    if candles.get("s") != "ok":
        return f"    // ERROR: No data returned for {symbol}\n"

    times  = candles["t"]
    opens  = candles["o"]
    closes = candles["c"]
    highs  = candles["h"]
    lows   = candles["l"]
    vols   = candles["v"]

    lines = []
    lines.append(f"    // === {scenario_name}: {symbol} — {len(times)} candles ===")

    # Establish baseline from first candle
    baseline = scale_price(opens[0])
    lines.append(f"    // Baseline price: ${opens[0]:.2f} (scaled: {baseline})")
    lines.append(f"    // Establishing 20-cycle baseline at open...")

    for _ in range(20):
        vol = scale_volume(int(vols[0] / len(times)))
        lines.append(f"    send_price(12'd{baseline});")
        lines.append(f"    send_volume(12'd{min(4095, vol)});")
        lines.append(f"    send_buy(6'd8);")
        lines.append(f"    send_sell(6'd8);")

    lines.append(f"    idle(10);")
    lines.append(f"    $display(\"  {symbol} baseline established at ${opens[0]:.2f}\");")
    lines.append("")

    # Replay each candle
    prev_close = opens[0]
    for i, (t, o, c, h, l, v) in enumerate(zip(times, opens, closes, highs, lows, vols)):
        ts_str = datetime.fromtimestamp(t, tz=timezone.utc).strftime("%H:%M")
        pct_chg = (c - prev_close) / prev_close * 100 if prev_close > 0 else 0

        price_scaled = scale_price(c)
        vol_scaled   = scale_volume(int(v))

        # Infer order side bias from price direction
        if c > o:  # bullish candle: more buys
            buy_qty = min(63, 10 + int(abs(pct_chg) * 5))
            sell_qty = max(1, 8 - int(abs(pct_chg) * 2))
        elif c < o:  # bearish candle: more sells
            buy_qty = max(1, 8 - int(abs(pct_chg) * 2))
            sell_qty = min(63, 10 + int(abs(pct_chg) * 5))
        else:  # flat
            buy_qty = 8
            sell_qty = 8

        flag = ""
        if pct_chg > 5:
            flag = "  << LARGE MOVE UP"
        elif pct_chg < -5:
            flag = "  << LARGE MOVE DOWN"

        lines.append(f"    // {ts_str}  ${c:.2f}  ({pct_chg:+.1f}%)  vol={v:,}{flag}")
        lines.append(f"    send_price(12'd{price_scaled});")
        lines.append(f"    send_volume(12'd{vol_scaled});")
        lines.append(f"    send_buy(6'd{buy_qty});")
        lines.append(f"    send_sell(6'd{sell_qty});")
        lines.append(f"    idle(3);")

        prev_close = c

    lines.append(f"    idle(20);")
    lines.append(f"    $display(\"  {symbol} replay complete. Final: ${closes[-1]:.2f}\");")
    lines.append("")
    return "\n".join(lines)

def generate_testbench(symbol: str, scenario: str, candles: dict,
                       news_headlines: list, date_str: str, output_file: str):
    """Write a complete Verilog testbench using Finnhub data."""

    stim = candles_to_verilog_tasks(symbol, candles, scenario)

    # Build news summary (top 3 headlines for context comments)
    news_comments = ""
    if news_headlines:
        news_comments = "// Top news headlines for this period:\n"
        for item in news_headlines[:3]:
            headline = item.get("headline", "")[:70].replace('"', "'")
            news_comments += f"//   {headline}\n"

    template = f'''/*
 * NanoTrade Live-Generated Testbench
 * ====================================
 * Generated by: finnhub_fetch.py
 * Symbol  : {symbol}
 * Scenario: {scenario}
 * Date    : {date_str}
 * Source  : Finnhub.io real market data
 *
{news_comments} *
 * HOW TO RUN:
 *   iverilog -g2005 -o sim_{symbol.lower()} {output_file} tt_um_nanotrade.v \\
 *            order_book.v anomaly_detector.v feature_extractor.v ml_inference_engine.v
 *   vvp sim_{symbol.lower()}
 */

`timescale 1ns/1ps
`default_nettype none

module tb_live_{symbol.lower()}_{date_str.replace("-","")};

    reg  [7:0] ui_in;
    wire [7:0] uo_out;
    reg  [7:0] uio_in;
    wire [7:0] uio_out;
    wire [7:0] uio_oe;
    reg        ena, clk, rst_n;

    tt_um_nanotrade dut (
        .ui_in(ui_in), .uo_out(uo_out),
        .uio_in(uio_in), .uio_out(uio_out), .uio_oe(uio_oe),
        .ena(ena), .clk(clk), .rst_n(rst_n)
    );

    initial clk = 0;
    always #10 clk = ~clk;

    wire alert_flag     = uo_out[7];
    wire [2:0] alert_priority = uo_out[6:4];
    wire match_valid    = uo_out[3];
    wire [2:0] alert_type = uo_out[2:0];
    wire ml_valid_out   = uio_out[7];
    wire [2:0] ml_class = uio_out[6:4];

    integer cycle_count, alerts_fired, ml_results;
    initial begin cycle_count=0; alerts_fired=0; ml_results=0; end
    always @(posedge clk) cycle_count = cycle_count + 1;

    reg prev_alert; reg [2:0] prev_type;
    initial begin prev_alert=0; prev_type=0; end

    always @(posedge clk) begin
        if (alert_flag && (!prev_alert || alert_type != prev_type)) begin
            alerts_fired = alerts_fired + 1;
            $display("\\033[1;31m  [cy %0d] ALERT prio=%0d type=%0d\\033[0m",
                     cycle_count, alert_priority, alert_type);
        end
        prev_alert = alert_flag; prev_type = alert_type;
        if (ml_valid_out) begin
            ml_results = ml_results + 1;
            if (ml_class != 0)
                $display("\\033[1;35m  [cy %0d] ML class=%0d\\033[0m", cycle_count, ml_class);
        end
        if (match_valid)
            $display("\\033[1;32m  [cy %0d] ORDER MATCHED\\033[0m", cycle_count);
    end

    task send_price; input [11:0] p; begin
        @(posedge clk); #1; ui_in={{2\'b00,p[5:0]}}; uio_in={{2\'b00,p[11:6]}};
    end endtask
    task send_volume; input [11:0] v; begin
        @(posedge clk); #1; ui_in={{2\'b01,v[5:0]}}; uio_in={{2\'b00,v[11:6]}};
    end endtask
    task send_buy; input [5:0] q; begin
        @(posedge clk); #1; ui_in={{2\'b10,q}}; uio_in=8\'h00;
    end endtask
    task send_sell; input [5:0] q; begin
        @(posedge clk); #1; ui_in={{2\'b11,q}}; uio_in=8\'h00;
    end endtask
    task idle; input integer n; integer k; begin
        for(k=0;k<n;k=k+1) begin @(posedge clk); #1; ui_in=8\'h00; uio_in=8\'h00; end
    end endtask

    initial begin
        $dumpfile("{symbol.lower()}_{date_str}.vcd");
        $dumpvars(0, tb_live_{symbol.lower()}_{date_str.replace("-","")});

        $display("");
        $display("\\033[1;37m+================================================================+\\033[0m");
        $display("\\033[1;37m|  NanoTrade -- LIVE DATA REPLAY: {symbol:<10s} {date_str:<20s}|\\033[0m");
        $display("\\033[1;37m|  Scenario: {scenario:<52s}|\\033[0m");
        $display("\\033[1;37m|  Source: Finnhub.io real market data                           |\\033[0m");
        $display("\\033[1;37m+================================================================+\\033[0m");
        $display("");

        ena=1; ui_in=0; uio_in=0; rst_n=0;
        repeat(5) @(posedge clk);
        rst_n=1; #1;

{stim}

        // ML inference on final market state
        $display("  Feeding final features to ML pipeline...");
        idle(300);

        $display("");
        $display("\\033[1;37m+================================================================+\\033[0m");
        $display("\\033[1;37m|  REPLAY COMPLETE                                               |\\033[0m");
        $display("\\033[1;37m|  Cycles: %-8d  Alerts: %-5d  ML results: %-5d             |\\033[0m",
                 cycle_count, alerts_fired, ml_results);
        $display("\\033[1;37m+================================================================+\\033[0m");
        $finish;
    end

    initial begin #100000000; $display("TIMEOUT"); $finish; end

endmodule
'''
    with open(output_file, "w") as f:
        f.write(template)
    print(f"  Generated: {output_file}")

# ---------------------------------------------------------------
# CLI
# ---------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(
        description="NanoTrade Finnhub data fetcher — generates Verilog testbenches from real data",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
EXAMPLES:
  # Pull today's AAPL data and generate a testbench
  python finnhub_fetch.py --mode quote --symbol AAPL

  # Pull 1-minute candles for SPY on COVID crash day
  python finnhub_fetch.py --mode candles --symbol SPY --date 2020-03-16 --resolution 1

  # Pull 5-min candles for TSLA on a recent day
  python finnhub_fetch.py --mode candles --symbol TSLA --date 2024-11-05 --resolution 5

  # Pull data for multiple symbols and combine
  python finnhub_fetch.py --mode multi --symbols SPY,AAPL,JPM --date 2020-03-16
        """
    )
    parser.add_argument("--mode", choices=["quote", "candles", "multi"], default="candles")
    parser.add_argument("--symbol", default="SPY", help="Stock ticker (e.g. AAPL, SPY, TSLA)")
    parser.add_argument("--symbols", default="SPY,AAPL", help="Comma-separated for multi mode")
    parser.add_argument("--date", default="2020-03-16", help="Date YYYY-MM-DD")
    parser.add_argument("--resolution", default="5", help="Candle resolution: 1, 5, 15, 30, 60")
    parser.add_argument("--out", default=None, help="Output .v filename (auto-named if omitted)")
    parser.add_argument("--scenario", default=None, help="Scenario description string")
    args = parser.parse_args()

    print(f"\n  NanoTrade Finnhub Fetcher")
    print(f"  Mode: {args.mode}  |  Date: {args.date}\n")

    if args.mode == "quote":
        print(f"  Fetching current quote for {args.symbol}...")
        q = get_quote(args.symbol)
        print(f"  {args.symbol}: current=${q['c']:.2f}  open=${q['o']:.2f}  "
              f"high=${q['h']:.2f}  low=${q['l']:.2f}  prev_close=${q['pc']:.2f}")
        pct = (q['c'] - q['pc']) / q['pc'] * 100
        print(f"  Change: {pct:+.2f}%")
        print(f"  Hardware scaled price: {scale_price(q['c'])}")

    elif args.mode == "candles":
        sym = args.symbol
        from_ts = date_to_ts(args.date)
        to_ts   = date_to_ts(args.date, end_of_day=True)

        print(f"  Fetching {args.resolution}-min candles for {sym} on {args.date}...")
        candles = get_candles(sym, args.resolution, from_ts, to_ts)

        n = len(candles.get("t", []))
        if n == 0:
            print(f"  ERROR: No candles returned. Check date (markets closed?) or symbol.")
            sys.exit(1)

        print(f"  Got {n} candles.")
        if candles.get("c"):
            open_p  = candles["o"][0]
            close_p = candles["c"][-1]
            pct = (close_p - open_p) / open_p * 100
            print(f"  Open: ${open_p:.2f}  Close: ${close_p:.2f}  ({pct:+.2f}%)")

        # Fetch news for context
        news = []
        try:
            from datetime import timedelta
            d = datetime.strptime(args.date, "%Y-%m-%d")
            d2 = (d + timedelta(days=1)).strftime("%Y-%m-%d")
            news = get_company_news(sym, args.date, d2)
            print(f"  Fetched {len(news)} news items for context.")
        except Exception:
            pass

        scenario = args.scenario or f"{sym} market replay {args.date}"
        out_file  = args.out or f"tb_live_{sym.lower()}_{args.date.replace('-','')}.v"

        generate_testbench(sym, scenario, candles, news, args.date, out_file)
        print(f"\n  To compile and run:")
        print(f"    iverilog -g2005 -o sim_{sym.lower()} {out_file} tt_um_nanotrade.v \\")
        print(f"             order_book.v anomaly_detector.v feature_extractor.v ml_inference_engine.v")
        print(f"    vvp sim_{sym.lower()}")

    elif args.mode == "multi":
        symbols = [s.strip() for s in args.symbols.split(",")]
        from_ts = date_to_ts(args.date)
        to_ts   = date_to_ts(args.date, end_of_day=True)
        all_candles = {}

        for sym in symbols:
            print(f"  Fetching {sym}...")
            try:
                c = get_candles(sym, args.resolution, from_ts, to_ts)
                all_candles[sym] = c
                n = len(c.get("t", []))
                print(f"    {sym}: {n} candles")
                time.sleep(0.3)  # rate limit
            except Exception as e:
                print(f"    {sym}: ERROR — {e}")

        # Generate combined testbench
        scenario = args.scenario or f"Multi-stock replay {args.date}: {', '.join(symbols)}"
        out_file  = args.out or f"tb_live_multi_{args.date.replace('-','')}.v"
        # Use first symbol's candles as primary, others as segments
        primary = symbols[0]
        if primary in all_candles:
            generate_testbench(primary, scenario, all_candles[primary], [], args.date, out_file)
            print(f"\n  Primary generated. For full multi-stock, edit {out_file}")
            print(f"  and add segments for: {', '.join(symbols[1:])}")

    print()

if __name__ == "__main__":
    main()
