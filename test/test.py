import os
import json
import threading
import queue
import time

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from websockets.sync.client import connect


print("### RUNNING TEST.PY VERSION: COINBASE_EXCHANGE_PUBLIC_V1 ###")


def clamp(v, lo, hi):
    return lo if v < lo else hi if v > hi else v


def pack_12_to_pins(x12: int):
    x12 &= 0xFFF
    ui_low6 = x12 & 0x3F
    uio_low6 = (x12 >> 6) & 0x3F
    return ui_low6, uio_low6


def drive_inputs(dut, input_type: int, payload12: int, config_strobe: int = 0):
    ui_low6, uio_low6 = pack_12_to_pins(payload12)
    dut.ui_in.value = ((input_type & 0x3) << 6) | ui_low6
    dut.uio_in.value = ((config_strobe & 0x1) << 7) | uio_low6


def encode_spread_to_12bit(spread: float, scale: float):
    return clamp(int(round(spread * scale)), 0, 4095)


def decode_outputs(uo: int):
    alert = (uo >> 7) & 1
    prio = (uo >> 4) & 0x7
    typ = uo & 0x7
    return alert, prio, typ


# ----------------------------
# Coinbase Exchange PUBLIC WS thread (NO AUTH)
# ----------------------------
def ws_thread_coinbase_exchange(product_id: str, out_q: "queue.Queue", stop_evt: threading.Event):
    """
    Public Coinbase Exchange WebSocket (no auth):
      wss://ws-feed.exchange.coinbase.com
    Subscribe to 'ticker' (lightweight, reliable).
    We'll use best_bid / best_ask from ticker messages.
    """
    url = "wss://ws-feed.exchange.coinbase.com"

    try:
        # raise max_size just in case, though ticker messages are small
        with connect(url, open_timeout=10, max_size=4 * 1024 * 1024) as ws:
            out_q.put(("__STATUS__", "CONNECTED"))

            sub = {
                "type": "subscribe",
                "product_ids": [product_id],
                "channels": ["ticker"]
            }
            ws.send(json.dumps(sub))
            out_q.put(("__STATUS__", f"SUBSCRIBED ticker {product_id}"))

            last_emit = 0.0

            while not stop_evt.is_set():
                msg = ws.recv()
                data = json.loads(msg)

                if data.get("type") == "error":
                    out_q.put(("__ERROR__", f"Coinbase error: {data}"))
                    return

                if data.get("type") != "ticker":
                    continue

                # ticker includes best_bid / best_ask strings
                bb = data.get("best_bid")
                ba = data.get("best_ask")
                if bb is None or ba is None:
                    continue

                best_bid = float(bb)
                best_ask = float(ba)

                # emit at most 20 Hz
                now = time.time()
                if now - last_emit < 0.05:
                    continue

                out_q.put((best_bid, 0.0, best_ask, 0.0))
                last_emit = now

    except Exception as e:
        out_q.put(("__ERROR__", str(e)))


@cocotb.test()
async def realtime_ws_demo(dut):
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())

    # Reset
    dut.ena.value = 1
    dut.rst_n.value = 0
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    await Timer(200, unit="ns")
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)

    # Tunables
    product_id = os.getenv("PRODUCT", "BTC-USD")  # Coinbase Exchange uses BTC-USD format
    n_msgs = int(os.getenv("N_MSGS", "100"))
    spread_scale = float(os.getenv("SPREAD_SCALE", "200"))  # spreads are small in USD
    event_cycles = int(os.getenv("EVENT_CYCLES", "1"))
    idle_cycles = int(os.getenv("IDLE_CYCLES", "0"))
    startup_timeout_s = float(os.getenv("STARTUP_TIMEOUT_S", "12"))

    dut._log.info(
        f"Coinbase EXCHANGE WS demo: product={product_id} n_msgs={n_msgs} spread_scale={spread_scale}"
    )

    q = queue.Queue(maxsize=5000)
    stop_evt = threading.Event()
    t = threading.Thread(target=ws_thread_coinbase_exchange, args=(product_id, q, stop_evt), daemon=True)
    t.start()

    # Prime idle
    drive_inputs(dut, 0b00, 2048)
    for _ in range(10):
        await RisingEdge(dut.clk)

    start_wall = time.time()
    first_data = False

    got = 0
    try:
        while got < n_msgs:
            if q.empty():
                if not first_data and (time.time() - start_wall) > startup_timeout_s:
                    raise RuntimeError("No WS data received (Coinbase Exchange). Network may block WS.")
                await Timer(1, unit="us")
                continue

            item = q.get()

            if isinstance(item, tuple) and len(item) == 2 and item[0] == "__ERROR__":
                raise RuntimeError(f"WS thread error: {item[1]}")
            if isinstance(item, tuple) and len(item) == 2 and item[0] == "__STATUS__":
                dut._log.info(f"WS status: {item[1]}")
                continue

            best_bid, _, best_ask, _ = item

            if not first_data:
                dut._log.info("Received first ticker message ✅")
                first_data = True

            spread = max(0.0, best_ask - best_bid)
            payload12 = encode_spread_to_12bit(spread, spread_scale)

            # Alternate BUY/SELL just to toggle both paths
            input_type = 0b10 if (got & 1) == 0 else 0b11

            drive_inputs(dut, input_type, payload12)
            for _ in range(event_cycles):
                await RisingEdge(dut.clk)

            uo = int(dut.uo_out.value)
            uioo = int(dut.uio_out.value)
            alert, prio, typ = decode_outputs(uo)

            if alert:
                dut._log.warning(
                    f"[ALERT] bid={best_bid:.2f} ask={best_ask:.2f} spread={spread:.2f} "
                    f"type={typ} prio={prio} uo=0x{uo:02X} uio=0x{uioo:02X}"
                )

            if idle_cycles > 0:
                drive_inputs(dut, 0b00, 2048)
                for _ in range(idle_cycles):
                    await RisingEdge(dut.clk)

            got += 1

    finally:
        stop_evt.set()

    dut._log.info("Coinbase Exchange WS demo finished ✅")