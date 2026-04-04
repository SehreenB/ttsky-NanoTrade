#!/bin/bash
# NanoTrade — Run all 16 stock scenarios
# Run from the project root directory

set -e
PASS=0; FAIL=0

# Compile once
echo 'Compiling NanoTrade...'
iverilog -o sim_nanotrade \
    tb_nanotrade_stock.v tt_um_nanotrade.v order_book.v \
    anomaly_detector.v feature_extractor.v ml_inference_engine.v

# Run each scenario

echo ''
echo '=================================================='
echo 'SCENARIO: GME_20210128'
echo 'Expected: FLASH_CRASH VOLUME_SURGE PRICE_SPIKE ORDER_IMBALANCE'
echo '=================================================='
STIMULUS=stimuli/GME_20210128_stimulus.memh \
GOLDEN=stimuli/GME_20210128_golden.txt \
TICKER=GME \
vvp sim_nanotrade | tee stimuli/GME_20210128_result.txt
python3 check_results.py stimuli/GME_20210128_result.txt stimuli/GME_20210128_golden.txt && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

echo ''
echo '=================================================='
echo 'SCENARIO: AMC_20210128'
echo 'Expected: VOLUME_SURGE PRICE_SPIKE ORDER_IMBALANCE'
echo '=================================================='
STIMULUS=stimuli/AMC_20210128_stimulus.memh \
GOLDEN=stimuli/AMC_20210128_golden.txt \
TICKER=AMC \
vvp sim_nanotrade | tee stimuli/AMC_20210128_result.txt
python3 check_results.py stimuli/AMC_20210128_result.txt stimuli/AMC_20210128_golden.txt && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

echo ''
echo '=================================================='
echo 'SCENARIO: BB_20210128'
echo 'Expected: PRICE_SPIKE VOLUME_SURGE'
echo '=================================================='
STIMULUS=stimuli/BB_20210128_stimulus.memh \
GOLDEN=stimuli/BB_20210128_golden.txt \
TICKER=BB \
vvp sim_nanotrade | tee stimuli/BB_20210128_result.txt
python3 check_results.py stimuli/BB_20210128_result.txt stimuli/BB_20210128_golden.txt && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

echo ''
echo '=================================================='
echo 'SCENARIO: NOK_20210128'
echo 'Expected: VOLUME_SURGE'
echo '=================================================='
STIMULUS=stimuli/NOK_20210128_stimulus.memh \
GOLDEN=stimuli/NOK_20210128_golden.txt \
TICKER=NOK \
vvp sim_nanotrade | tee stimuli/NOK_20210128_result.txt
python3 check_results.py stimuli/NOK_20210128_result.txt stimuli/NOK_20210128_golden.txt && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

echo ''
echo '=================================================='
echo 'SCENARIO: SPY_20100506'
echo 'Expected: FLASH_CRASH VOLATILITY VOLUME_SURGE'
echo '=================================================='
STIMULUS=stimuli/SPY_20100506_stimulus.memh \
GOLDEN=stimuli/SPY_20100506_golden.txt \
TICKER=SPY \
vvp sim_nanotrade | tee stimuli/SPY_20100506_result.txt
python3 check_results.py stimuli/SPY_20100506_result.txt stimuli/SPY_20100506_golden.txt && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

echo ''
echo '=================================================='
echo 'SCENARIO: PG_20100506'
echo 'Expected: FLASH_CRASH PRICE_SPIKE'
echo '=================================================='
STIMULUS=stimuli/PG_20100506_stimulus.memh \
GOLDEN=stimuli/PG_20100506_golden.txt \
TICKER=PG \
vvp sim_nanotrade | tee stimuli/PG_20100506_result.txt
python3 check_results.py stimuli/PG_20100506_result.txt stimuli/PG_20100506_golden.txt && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

echo ''
echo '=================================================='
echo 'SCENARIO: AAPL_20100506'
echo 'Expected: FLASH_CRASH VOLUME_SURGE'
echo '=================================================='
STIMULUS=stimuli/AAPL_20100506_stimulus.memh \
GOLDEN=stimuli/AAPL_20100506_golden.txt \
TICKER=AAPL \
vvp sim_nanotrade | tee stimuli/AAPL_20100506_result.txt
python3 check_results.py stimuli/AAPL_20100506_result.txt stimuli/AAPL_20100506_golden.txt && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

echo ''
echo '=================================================='
echo 'SCENARIO: ACN_20100506'
echo 'Expected: FLASH_CRASH PRICE_SPIKE'
echo '=================================================='
STIMULUS=stimuli/ACN_20100506_stimulus.memh \
GOLDEN=stimuli/ACN_20100506_golden.txt \
TICKER=ACN \
vvp sim_nanotrade | tee stimuli/ACN_20100506_result.txt
python3 check_results.py stimuli/ACN_20100506_result.txt stimuli/ACN_20100506_golden.txt && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

echo ''
echo '=================================================='
echo 'SCENARIO: SPY_20200316'
echo 'Expected: FLASH_CRASH VOLATILITY VOLUME_SURGE'
echo '=================================================='
STIMULUS=stimuli/SPY_20200316_stimulus.memh \
GOLDEN=stimuli/SPY_20200316_golden.txt \
TICKER=SPY \
vvp sim_nanotrade | tee stimuli/SPY_20200316_result.txt
python3 check_results.py stimuli/SPY_20200316_result.txt stimuli/SPY_20200316_golden.txt && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

echo ''
echo '=================================================='
echo 'SCENARIO: JETS_20200316'
echo 'Expected: FLASH_CRASH VOLUME_SURGE ORDER_IMBALANCE'
echo '=================================================='
STIMULUS=stimuli/JETS_20200316_stimulus.memh \
GOLDEN=stimuli/JETS_20200316_golden.txt \
TICKER=JETS \
vvp sim_nanotrade | tee stimuli/JETS_20200316_result.txt
python3 check_results.py stimuli/JETS_20200316_result.txt stimuli/JETS_20200316_golden.txt && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

echo ''
echo '=================================================='
echo 'SCENARIO: TSLA_20200316'
echo 'Expected: FLASH_CRASH VOLATILITY'
echo '=================================================='
STIMULUS=stimuli/TSLA_20200316_stimulus.memh \
GOLDEN=stimuli/TSLA_20200316_golden.txt \
TICKER=TSLA \
vvp sim_nanotrade | tee stimuli/TSLA_20200316_result.txt
python3 check_results.py stimuli/TSLA_20200316_result.txt stimuli/TSLA_20200316_golden.txt && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

echo ''
echo '=================================================='
echo 'SCENARIO: ZM_20200316'
echo 'Expected: VOLUME_SURGE PRICE_SPIKE'
echo '=================================================='
STIMULUS=stimuli/ZM_20200316_stimulus.memh \
GOLDEN=stimuli/ZM_20200316_golden.txt \
TICKER=ZM \
vvp sim_nanotrade | tee stimuli/ZM_20200316_result.txt
python3 check_results.py stimuli/ZM_20200316_result.txt stimuli/ZM_20200316_golden.txt && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

echo ''
echo '=================================================='
echo 'SCENARIO: SPY_20190604'
echo 'Expected: NONE'
echo '=================================================='
STIMULUS=stimuli/SPY_20190604_stimulus.memh \
GOLDEN=stimuli/SPY_20190604_golden.txt \
TICKER=SPY \
vvp sim_nanotrade | tee stimuli/SPY_20190604_result.txt
python3 check_results.py stimuli/SPY_20190604_result.txt stimuli/SPY_20190604_golden.txt && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

echo ''
echo '=================================================='
echo 'SCENARIO: MSFT_20190604'
echo 'Expected: NONE'
echo '=================================================='
STIMULUS=stimuli/MSFT_20190604_stimulus.memh \
GOLDEN=stimuli/MSFT_20190604_golden.txt \
TICKER=MSFT \
vvp sim_nanotrade | tee stimuli/MSFT_20190604_result.txt
python3 check_results.py stimuli/MSFT_20190604_result.txt stimuli/MSFT_20190604_golden.txt && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

echo ''
echo '=================================================='
echo 'SCENARIO: KO_20190604'
echo 'Expected: NONE'
echo '=================================================='
STIMULUS=stimuli/KO_20190604_stimulus.memh \
GOLDEN=stimuli/KO_20190604_golden.txt \
TICKER=KO \
vvp sim_nanotrade | tee stimuli/KO_20190604_result.txt
python3 check_results.py stimuli/KO_20190604_result.txt stimuli/KO_20190604_golden.txt && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

echo ''
echo '=================================================='
echo 'SCENARIO: GLD_20190604'
echo 'Expected: NONE'
echo '=================================================='
STIMULUS=stimuli/GLD_20190604_stimulus.memh \
GOLDEN=stimuli/GLD_20190604_golden.txt \
TICKER=GLD \
vvp sim_nanotrade | tee stimuli/GLD_20190604_result.txt
python3 check_results.py stimuli/GLD_20190604_result.txt stimuli/GLD_20190604_golden.txt && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

echo ''
echo '========================================'
echo "FINAL SCORE: $PASS passed, $FAIL failed"
echo '========================================'
