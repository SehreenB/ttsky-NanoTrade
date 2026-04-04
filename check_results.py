"""
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

print(f"\nChecker: {result_path.split('/')[-1]}")
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
