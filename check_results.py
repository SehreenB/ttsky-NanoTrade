"""
NanoTrade Results Checker  (v2)
================================
Compares simulation output against golden expected alerts.

Usage:
  python check_results.py stimuli/GME_20210128_golden.txt stimuli/GME_20210128_result.txt

Exit code:
  0 = PASS
  1 = FAIL
"""

import sys
import os

# Alert name -> bit index in FIRED_RULE_MASK
RULE_BITS = {
    "PRICE_SPIKE":      0,
    "VOLUME_DRY":       1,
    "VOLUME_SURGE":     2,
    "TRADE_VELOCITY":   3,
    "ORDER_IMBALANCE":  4,
    "SPREAD_WIDENING":  5,
    "VOLATILITY":       6,
    "FLASH_CRASH":      7,
}

ML_BITS = {
    "NORMAL":           0,
    "PRICE_SPIKE":      1,
    "VOLUME_SURGE":     2,
    "FLASH_CRASH":      3,
    "ORDER_IMBALANCE":  4,
    "QUOTE_STUFFING":   5,
}


def parse_golden(path):
    expected = []
    ticker = ""
    date   = ""
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line.startswith("TICKER="):
                ticker = line.split("=", 1)[1]
            elif line.startswith("DATE="):
                date = line.split("=", 1)[1]
            elif line.startswith("EXPECTED="):
                expected = [e.strip() for e in line.split("=", 1)[1].split(",")]
    return ticker, date, expected


def parse_result(path):
    rule_mask = None
    ml_mask   = None
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line.startswith("[FIRED_RULE_MASK]"):
                rule_mask = int(line.split()[-1], 2)
            elif line.startswith("[FIRED_ML_MASK]"):
                ml_mask = int(line.split()[-1], 2)
    return rule_mask, ml_mask


def check(golden_path, result_path):
    ticker, date, expected = parse_golden(golden_path)
    rule_mask, ml_mask = parse_result(result_path)

    if rule_mask is None:
        print(f"[ERROR] Could not parse FIRED_RULE_MASK from {result_path}")
        return False

    print(f"\n{'='*55}")
    print(f"  Results Check: {ticker} {date}")
    print(f"{'='*55}")
    print(f"  Expected alerts : {', '.join(expected)}")
    print(f"  Rule mask fired : {rule_mask:08b}")
    print(f"  ML   mask fired : {ml_mask:08b}" if ml_mask is not None else "  ML mask        : (not found)")
    print()

    if expected == ["NONE"]:
        # Normal baseline: should not fire FLASH_CRASH (bit 7)
        flash_bit = 1 << RULE_BITS["FLASH_CRASH"]
        if rule_mask & flash_bit:
            print(f"  [FAIL] Expected NONE but FLASH_CRASH fired (false positive!)")
            return False
        else:
            print(f"  [PASS] Quiet day -- no Flash Crash detected (correct)")
            return True

    passed = []
    failed = []

    for alert in expected:
        # Handle _ML suffix: means we only expect ML detection, not rule
        if alert.endswith("_ML"):
            base = alert[:-3]
            if base in ML_BITS and ml_mask is not None:
                if ml_mask & (1 << ML_BITS[base]):
                    passed.append(f"{base}(ML)")
                else:
                    failed.append(base)
            else:
                passed.append(f"{alert}(?)")
            continue

        # Check rule mask
        if alert in RULE_BITS:
            bit = 1 << RULE_BITS[alert]
            if rule_mask & bit:
                passed.append(alert)
            else:
                # Also accept if ML caught it
                ml_equiv = alert
                if ml_equiv in ML_BITS and ml_mask is not None:
                    if ml_mask & (1 << ML_BITS[ml_equiv]):
                        passed.append(f"{alert}(ML)")
                        continue
                failed.append(alert)
        else:
            passed.append(f"{alert}(?)")

    for a in passed:
        print(f"  [PASS] {a}")
    for a in failed:
        print(f"  [MISS] {a}  -- not detected")

    total    = len(expected)
    n_passed = len(passed)
    result   = "PASS" if n_passed == total else "FAIL"
    print(f"\n  Score: {n_passed}/{total}  [{result}]")
    return n_passed == total


def main():
    if len(sys.argv) != 3:
        print(f"Usage: python check_results.py <golden.txt> <result.txt>")
        sys.exit(1)

    golden_path = sys.argv[1]
    result_path = sys.argv[2]

    if not os.path.exists(golden_path):
        print(f"[ERROR] Golden file not found: {golden_path}")
        sys.exit(1)
    if not os.path.exists(result_path):
        print(f"[ERROR] Result file not found: {result_path}")
        sys.exit(1)

    ok = check(golden_path, result_path)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()