#!/usr/bin/env bash
# NanoTrade -- Run all 16 stock scenarios

set -e

iverilog -g2005 -o sim_stock \
  tb_nanotrade_stock.v tt_um_nanotrade.v order_book.v \
  anomaly_detector.v feature_extractor.v ml_inference_engine.v

echo '--- GME 2021-01-28 ---'
vvp sim_stock +STIMULUS+stimuli/GME_20210128_stimulus.memh +TICKER+GME \
  | tee stimuli/GME_20210128_result.txt
python3 check_results.py stimuli/GME_20210128_golden.txt stimuli/GME_20210128_result.txt

echo '--- AMC 2021-01-28 ---'
vvp sim_stock +STIMULUS+stimuli/AMC_20210128_stimulus.memh +TICKER+AMC \
  | tee stimuli/AMC_20210128_result.txt
python3 check_results.py stimuli/AMC_20210128_golden.txt stimuli/AMC_20210128_result.txt

echo '--- BB 2021-01-28 ---'
vvp sim_stock +STIMULUS+stimuli/BB_20210128_stimulus.memh +TICKER+BB \
  | tee stimuli/BB_20210128_result.txt
python3 check_results.py stimuli/BB_20210128_golden.txt stimuli/BB_20210128_result.txt

echo '--- NOK 2021-01-28 ---'
vvp sim_stock +STIMULUS+stimuli/NOK_20210128_stimulus.memh +TICKER+NOK \
  | tee stimuli/NOK_20210128_result.txt
python3 check_results.py stimuli/NOK_20210128_golden.txt stimuli/NOK_20210128_result.txt

echo '--- SPY 2010-05-06 ---'
vvp sim_stock +STIMULUS+stimuli/SPY_20100506_stimulus.memh +TICKER+SPY \
  | tee stimuli/SPY_20100506_result.txt
python3 check_results.py stimuli/SPY_20100506_golden.txt stimuli/SPY_20100506_result.txt

echo '--- PG 2010-05-06 ---'
vvp sim_stock +STIMULUS+stimuli/PG_20100506_stimulus.memh +TICKER+PG \
  | tee stimuli/PG_20100506_result.txt
python3 check_results.py stimuli/PG_20100506_golden.txt stimuli/PG_20100506_result.txt

echo '--- AAPL 2010-05-06 ---'
vvp sim_stock +STIMULUS+stimuli/AAPL_20100506_stimulus.memh +TICKER+AAPL \
  | tee stimuli/AAPL_20100506_result.txt
python3 check_results.py stimuli/AAPL_20100506_golden.txt stimuli/AAPL_20100506_result.txt

echo '--- ACN 2010-05-06 ---'
vvp sim_stock +STIMULUS+stimuli/ACN_20100506_stimulus.memh +TICKER+ACN \
  | tee stimuli/ACN_20100506_result.txt
python3 check_results.py stimuli/ACN_20100506_golden.txt stimuli/ACN_20100506_result.txt

echo '--- SPY 2020-03-16 ---'
vvp sim_stock +STIMULUS+stimuli/SPY_20200316_stimulus.memh +TICKER+SPY \
  | tee stimuli/SPY_20200316_result.txt
python3 check_results.py stimuli/SPY_20200316_golden.txt stimuli/SPY_20200316_result.txt

echo '--- JETS 2020-03-16 ---'
vvp sim_stock +STIMULUS+stimuli/JETS_20200316_stimulus.memh +TICKER+JETS \
  | tee stimuli/JETS_20200316_result.txt
python3 check_results.py stimuli/JETS_20200316_golden.txt stimuli/JETS_20200316_result.txt

echo '--- TSLA 2020-03-16 ---'
vvp sim_stock +STIMULUS+stimuli/TSLA_20200316_stimulus.memh +TICKER+TSLA \
  | tee stimuli/TSLA_20200316_result.txt
python3 check_results.py stimuli/TSLA_20200316_golden.txt stimuli/TSLA_20200316_result.txt

echo '--- ZM 2020-03-16 ---'
vvp sim_stock +STIMULUS+stimuli/ZM_20200316_stimulus.memh +TICKER+ZM \
  | tee stimuli/ZM_20200316_result.txt
python3 check_results.py stimuli/ZM_20200316_golden.txt stimuli/ZM_20200316_result.txt

echo '--- SPY 2019-06-04 ---'
vvp sim_stock +STIMULUS+stimuli/SPY_20190604_stimulus.memh +TICKER+SPY \
  | tee stimuli/SPY_20190604_result.txt
python3 check_results.py stimuli/SPY_20190604_golden.txt stimuli/SPY_20190604_result.txt

echo '--- MSFT 2019-06-04 ---'
vvp sim_stock +STIMULUS+stimuli/MSFT_20190604_stimulus.memh +TICKER+MSFT \
  | tee stimuli/MSFT_20190604_result.txt
python3 check_results.py stimuli/MSFT_20190604_golden.txt stimuli/MSFT_20190604_result.txt

echo '--- KO 2019-06-04 ---'
vvp sim_stock +STIMULUS+stimuli/KO_20190604_stimulus.memh +TICKER+KO \
  | tee stimuli/KO_20190604_result.txt
python3 check_results.py stimuli/KO_20190604_golden.txt stimuli/KO_20190604_result.txt

echo '--- GLD 2019-06-04 ---'
vvp sim_stock +STIMULUS+stimuli/GLD_20190604_stimulus.memh +TICKER+GLD \
  | tee stimuli/GLD_20190604_result.txt
python3 check_results.py stimuli/GLD_20190604_golden.txt stimuli/GLD_20190604_result.txt

