# NanoTrade: HFT Matching Engine + ML Anomaly Detection

## How it works

NanoTrade is a real-time market anomaly detection ASIC implemented on SKY130 in a 2×2 TinyTapeout tile. It combines two parallel detection paths:

**Rule-Based Engine (1-cycle latency)**
An 8-detector anomaly engine monitors rolling price and volume averages and fires alerts for: flash crashes, price spikes, volume surges, order imbalances, trade velocity spikes, volatility bursts, spread widening, and volume drying.

**ML Inference Engine (4-cycle latency)**
A synthesizable 16→4→6 MLP neural network with weights baked into case-ROM LUTs (no SRAM, no $readmemh). Processes a 256-cycle feature window from the feature extractor and classifies market conditions into 6 classes: Normal, Price Spike, Volume Surge, Flash Crash, Volatility, Order Imbalance.

**Order Book Engine**
A 4-entry bid/ask queue with price-time priority matching. Feeds order pressure data into the anomaly detector.

## How to use

Send 16-bit words (split across ui_in and uio_in) every clock cycle:

- `ui_in[7:6]` = input type: `00`=price, `01`=volume, `10`=buy order, `11`=sell order
- `ui_in[5:0]` = data bits [5:0]
- `uio_in[5:0]` = data bits [11:6]
- `uio_in[7]` = config write strobe (set to 1 with type=00 to load threshold preset)

Read alerts from:
- `uo_out[7]` = alert active (rule OR ML)
- `uo_out[6:4]` = alert priority (7=critical)
- `uo_out[2:0]` = alert type code
- `uio_out[7]` = ML inference valid
- `uio_out[6:4]` = ML class
- `uio_out[3:0]` = ML confidence

## Threshold Presets

Write config byte with `uio_in[7]=1, ui_in[7:6]=00`:
- `uio_in[1:0] = 00` → Quiet (few alerts)
- `uio_in[1:0] = 01` → Normal (default)
- `uio_in[1:0] = 10` → Sensitive
- `uio_in[1:0] = 11` → Demo

## External hardware

No external hardware required. UART TX output on `uo_out[3]` at 115200 baud can optionally be connected to a USB-UART adapter for live terminal readout during demonstrations.
