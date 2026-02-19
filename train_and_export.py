"""
NanoTrade ML Weight Generator
================================
Trains a 16→8→6 MLP on synthetic market-anomaly data.
Quantizes weights to INT16, activations to UINT8.
Exports Verilog $readmemh-compatible .hex files for ROM.

Anomaly classes (6 outputs):
  0 = NORMAL
  1 = PRICE_SPIKE
  2 = VOLUME_SURGE
  3 = FLASH_CRASH    (critical)
  4 = ORDER_IMBALANCE
  5 = QUOTE_STUFF    (spoofing)

Feature vector (16 features, each 0..255 after normalization):
  [0]  price_change_1s       signed delta, clipped ±127, shifted +128
  [1]  price_change_10s
  [2]  price_change_60s
  [3]  volume_ratio          current/avg * 64, clipped 0..255
  [4]  spread_pct            bid-ask / mid * 128, clipped 0..255
  [5]  buy_sell_imbalance    (buys-sells)/(buys+sells) * 128 + 128
  [6]  volatility            MAD * 4, clipped 0..255
  [7]  order_arrival_rate    orders/window, clipped 0..255
  [8]  cancel_rate           cancels/window, clipped 0..255
  [9]  buy_depth             shares at top-5 bid / 16, clipped 0..255
  [10] sell_depth
  [11] time_since_trade_ms   clipped 0..255
  [12] avg_order_lifespan_ms clipped 0..255
  [13] trade_frequency       trades/window, clipped 0..255
  [14] price_momentum        2nd-order diff, clipped ±127, shifted +128
  [15] reserved (always 128 = 0 in signed)
"""

import numpy as np
import struct, os, sys
from sklearn.neural_network import MLPClassifier
from sklearn.preprocessing import StandardScaler
from sklearn.model_selection import train_test_split
from sklearn.metrics import classification_report

SEED = 42
rng  = np.random.default_rng(SEED)

N_FEATURES = 16
N_HIDDEN   = 8  # INCREASED from 4 for better capacity
N_CLASSES  = 6
N_SAMPLES  = 12000   # INCREASED for better training

# IMPROVED: More normal samples to reduce false positives
N_NORMAL_SAMPLES = 6000  # 50% of dataset
N_ANOMALY_SAMPLES_EACH = (N_SAMPLES - N_NORMAL_SAMPLES) // (N_CLASSES - 1)  # 1200 each

OUT_DIR = "/home/claude/src/rom"
os.makedirs(OUT_DIR, exist_ok=True)

# ---------------------------------------------------------------
# 1. Generate synthetic market data
# ---------------------------------------------------------------

def gen_normal(n):
    """Quiet market: small deltas, balanced order flow"""
    X = np.zeros((n, N_FEATURES))
    X[:, 0]  = rng.normal(0,   3,  n)   # price_change_1s
    X[:, 1]  = rng.normal(0,   5,  n)   # price_change_10s
    X[:, 2]  = rng.normal(0,   8,  n)   # price_change_60s
    X[:, 3]  = rng.normal(64,  8,  n)   # volume_ratio (≈1x avg)
    X[:, 4]  = rng.normal(10,  3,  n)   # spread_pct (tight)
    X[:, 5]  = rng.normal(128, 15, n)   # buy_sell_imbalance (neutral)
    X[:, 6]  = rng.normal(8,   3,  n)   # volatility (low)
    X[:, 7]  = rng.normal(80,  20, n)   # order_arrival_rate
    X[:, 8]  = rng.normal(10,  5,  n)   # cancel_rate
    X[:, 9]  = rng.normal(120, 30, n)   # buy_depth
    X[:, 10] = rng.normal(120, 30, n)   # sell_depth
    X[:, 11] = rng.normal(20,  10, n)   # time_since_trade
    X[:, 12] = rng.normal(200, 50, n)   # avg_order_lifespan (healthy)
    X[:, 13] = rng.normal(40,  10, n)   # trade_frequency
    X[:, 14] = rng.normal(128, 5,  n)   # price_momentum (flat)
    X[:, 15] = np.full(n, 128.0)
    return X

def gen_price_spike(n):
    """Sudden sharp price movement"""
    X = gen_normal(n)
    X[:, 0]  = rng.choice([-1, 1], n) * rng.uniform(60, 127, n)
    X[:, 1]  = rng.choice([-1, 1], n) * rng.uniform(40, 100, n)
    X[:, 6]  += rng.uniform(30, 80, n)   # volatility spikes
    X[:, 14] = 128 + rng.choice([-1,1], n) * rng.uniform(40, 100, n)
    return X

def gen_volume_surge(n):
    """Panic buying/selling: volume 3-10x normal"""
    X = gen_normal(n)
    X[:, 3]  = rng.uniform(190, 255, n)   # volume_ratio >> 3x
    X[:, 7]  = rng.uniform(200, 255, n)   # order_arrival_rate spikes
    X[:, 5]  = rng.normal(128, 40, n)     # imbalance varies
    X[:, 11] = rng.uniform(0, 5, n)       # trades rapid
    return X

def gen_flash_crash(n):
    """Price drops >20% in seconds, volume explodes"""
    X = gen_normal(n)
    X[:, 0]  = -rng.uniform(90, 127, n)   # large negative 1s delta
    X[:, 1]  = -rng.uniform(80, 127, n)
    X[:, 2]  = -rng.uniform(70, 127, n)
    X[:, 3]  = rng.uniform(200, 255, n)   # panic volume
    X[:, 5]  = rng.uniform(0,   40,  n)   # extreme sell imbalance
    X[:, 6]  = rng.uniform(150, 255, n)   # extreme volatility
    X[:, 14] = rng.uniform(0,   30,  n)   # strong negative momentum
    X[:, 10] = rng.uniform(0,   20,  n)   # sell depth drained
    return X

def gen_order_imbalance(n):
    """Lopsided order book: one side dominates"""
    X = gen_normal(n)
    direction = rng.choice([0, 1], n)
    X[:, 5]  = np.where(direction, rng.uniform(200,255,n),
                                    rng.uniform(0,  55, n))
    X[:, 9]  = np.where(direction, rng.uniform(200,255,n), rng.uniform(0, 30, n))
    X[:, 10] = np.where(direction, rng.uniform(0, 30, n),  rng.uniform(200,255,n))
    X[:, 4]  = rng.uniform(60, 120, n)    # spread widens
    return X

def gen_quote_stuffing(n):
    """Spoofing: many orders placed & cancelled rapidly"""
    X = gen_normal(n)
    X[:, 7]  = rng.uniform(220, 255, n)   # order rate extreme
    X[:, 8]  = rng.uniform(180, 255, n)   # cancel rate extreme
    X[:, 12] = rng.uniform(0,   15,  n)   # avg lifespan very short
    X[:, 13] = rng.uniform(150, 255, n)   # trade freq (fake activity)
    X[:, 0]  = rng.normal(0, 5, n)        # price barely moves
    return X

# Generate IMBALANCED dataset: 50% normal, 10% each anomaly
generators  = [gen_normal, gen_price_spike, gen_volume_surge,
               gen_flash_crash, gen_order_imbalance, gen_quote_stuffing]

X_list, y_list = [], []
# Generate more normal samples
X_list.append(gen_normal(N_NORMAL_SAMPLES))
y_list.append(np.full(N_NORMAL_SAMPLES, 0))

# Generate fewer anomaly samples
for cls in range(1, N_CLASSES):
    X_list.append(generators[cls](N_ANOMALY_SAMPLES_EACH))
    y_list.append(np.full(N_ANOMALY_SAMPLES_EACH, cls))

X = np.clip(np.vstack(X_list), 0, 255).astype(np.float32)
y = np.concatenate(y_list).astype(np.int32)

# Shuffle
idx = rng.permutation(len(y))
X, y = X[idx], y[idx]

print(f"Dataset: {X.shape[0]} samples, {N_CLASSES} classes")
print(f"Class distribution: {np.bincount(y)}")

# ---------------------------------------------------------------
# 2. Scale & Train
# ---------------------------------------------------------------

X_train, X_test, y_train, y_test = train_test_split(
    X, y, test_size=0.2, random_state=SEED, stratify=y)

# Normalize to zero-mean unit-variance for training
scaler  = StandardScaler()
Xs_train = scaler.fit_transform(X_train)
Xs_test  = scaler.transform(X_test)

clf = MLPClassifier(
    hidden_layer_sizes=(N_HIDDEN,),
    activation='relu',
    max_iter=1000,  # INCREASED from 500 for better convergence
    random_state=SEED,
    verbose=False,
    learning_rate_init=0.001,
    alpha=1e-4,
)
clf.fit(Xs_train, y_train)

print("\n=== Training Complete ===")
preds = clf.predict(Xs_test)
print(classification_report(y_test, preds,
      target_names=["NORMAL","SPIKE","VOL_SURGE",
                    "FLASH_CRASH","IMBALANCE","QUOTE_STUFF"]))

acc = (preds == y_test).mean()
print(f"Test accuracy: {acc*100:.1f}%")

# ---------------------------------------------------------------
# 3. Bake scaler into the weights
#    Hardware will receive raw uint8 features.
#    We fold scaler.mean_ / scaler.scale_ into layer-1 weights
#    so the hardware never needs to do normalization.
#
#    y = ReLU(W1 @ ((x - mean)/scale) + b1)
#      = ReLU((W1/scale) @ x + (b1 - W1 @ (mean/scale)))
# ---------------------------------------------------------------

W1_raw = clf.coefs_[0]      # (16, 8)
b1_raw = clf.intercepts_[0] # (8,)
W2_raw = clf.coefs_[1]      # (8, 6)
b2_raw = clf.intercepts_[1] # (6,)

mean_  = scaler.mean_       # (16,)
scale_ = scaler.scale_      # (16,)

# Fold scaler into W1, b1
W1_folded = W1_raw / scale_[:, None]  # broadcast over hidden dim
b1_folded = b1_raw - (W1_raw / scale_[:, None]).T @ mean_

print(f"\nW1 range: [{W1_folded.min():.4f}, {W1_folded.max():.4f}]")
print(f"b1 range: [{b1_folded.min():.4f}, {b1_folded.max():.4f}]")
print(f"W2 range: [{W2_raw.min():.4f}, {W2_raw.max():.4f}]")
print(f"b2 range: [{b2_raw.min():.4f}, {b2_raw.max():.4f}]")

# ---------------------------------------------------------------
# 4. Quantize to INT16
#    Scale so max |value| maps to ~0x4000 (leaving headroom)
#    Q_SCALE = quantization scale factor stored alongside weights
# ---------------------------------------------------------------

Q_SCALE_W1 = 16384.0 / max(abs(W1_folded).max(), 1e-6)
Q_SCALE_B1 = 16384.0 / max(abs(b1_folded).max(), 1e-6)
Q_SCALE_W2 = 16384.0 / max(abs(W2_raw).max(), 1e-6)
Q_SCALE_B2 = 16384.0 / max(abs(b2_raw).max(), 1e-6)

W1_q = np.clip(np.round(W1_folded * Q_SCALE_W1), -32768, 32767).astype(np.int16)
b1_q = np.clip(np.round(b1_folded * Q_SCALE_B1), -32768, 32767).astype(np.int16)
W2_q = np.clip(np.round(W2_raw   * Q_SCALE_W2), -32768, 32767).astype(np.int16)
b2_q = np.clip(np.round(b2_raw   * Q_SCALE_B2), -32768, 32767).astype(np.int16)

# Verify quantized accuracy with folded weights
def relu(x): return np.maximum(0, x)

def infer_quantized(x_raw):
    """Run inference using integer arithmetic (simulates hardware)"""
    x32 = x_raw.astype(np.int64)
    # Layer 1: 64-bit accumulator
    acc1 = (x32 @ W1_q.astype(np.int64)) // int(Q_SCALE_W1 / Q_SCALE_B1)
    acc1 = acc1 + b1_q.astype(np.int64)
    # ReLU + right-shift to get 8-bit activations
    h1 = np.clip(acc1 >> 8, 0, 255).astype(np.int64)
    # Layer 2
    acc2 = (h1 @ W2_q.astype(np.int64))
    acc2 = acc2 + b2_q.astype(np.int64)
    return np.argmax(acc2, axis=-1)

q_preds = infer_quantized(X_test.astype(np.int32))
q_acc   = (q_preds == y_test).mean()
print(f"Quantized int accuracy: {q_acc*100:.1f}%  (float was {acc*100:.1f}%)")

# ---------------------------------------------------------------
# 5. Export hex files
#    Format: one value per line, 4 hex digits (16-bit two's complement)
#    Verilog: $readmemh("w1.hex", rom_array);
# ---------------------------------------------------------------

def to_hex16(arr):
    """Convert int16 array to hex string lines (unsigned 16-bit repr)"""
    lines = []
    for v in arr.flatten():
        u = int(v) & 0xFFFF
        lines.append(f"{u:04x}")
    return "\n".join(lines)

# W1: (16, 8) → 128 values, column-major (hidden neuron fastest)
# Verilog reads: w1[input_idx][hidden_idx]
w1_hex = to_hex16(W1_q)   # row-major: W1_q[in, hidden]
b1_hex = to_hex16(b1_q)   # (8,)
w2_hex = to_hex16(W2_q)   # (8, 6)
b2_hex = to_hex16(b2_q)   # (6,)

with open(f"{OUT_DIR}/w1.hex", "w") as f: f.write(w1_hex + "\n")
with open(f"{OUT_DIR}/b1.hex", "w") as f: f.write(b1_hex + "\n")
with open(f"{OUT_DIR}/w2.hex", "w") as f: f.write(w2_hex + "\n")
with open(f"{OUT_DIR}/b2.hex", "w") as f: f.write(b2_hex + "\n")

print(f"\nExported to {OUT_DIR}:")
print(f"  w1.hex  {W1_q.size} values  ({W1_q.size*2} bytes)")
print(f"  b1.hex  {b1_q.size} values  ({b1_q.size*2} bytes)")
print(f"  w2.hex  {W2_q.size} values  ({W2_q.size*2} bytes)")
print(f"  b2.hex  {b2_q.size} values  ({b2_q.size*2} bytes)")
total = (W1_q.size + b1_q.size + W2_q.size + b2_q.size) * 2
print(f"  TOTAL ROM: {total} bytes  ({total*8} bits)")

# Also dump a Verilog parameter file with Q scales for reference
params_v = f"""// Auto-generated by train_and_export.py — DO NOT EDIT
// Quantization scale factors (for documentation only, not used in HW)
// W1_Q_SCALE = {Q_SCALE_W1:.2f}
// B1_Q_SCALE = {Q_SCALE_B1:.2f}
// W2_Q_SCALE = {Q_SCALE_W2:.2f}
// B2_Q_SCALE = {Q_SCALE_B2:.2f}
// Float test accuracy : {acc*100:.1f}%
// Quantized accuracy  : {q_acc*100:.1f}%
// Training samples    : {len(y_train)}
// Test samples        : {len(y_test)}
"""
with open(f"{OUT_DIR}/ml_params.vh", "w") as f:
    f.write(params_v)

print("\nDone. ROM hex files ready for $readmemh.")