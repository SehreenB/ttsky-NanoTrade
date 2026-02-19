# NanoTrade -- Run all 16 stock scenarios
# Usage: .\stimuli\run_all_scenarios.ps1

$env:Path += ";C:\iverilog\bin"

# Compile once
iverilog -g2005 -o sim_stock `
  tb_nanotrade_stock.v tt_um_nanotrade.v order_book.v `
  anomaly_detector.v feature_extractor.v ml_inference_engine.v

if ($LASTEXITCODE -ne 0) { Write-Error 'Compile failed'; exit 1 }

$results = @()

Write-Host "--- GME 2021-01-28 ---" -ForegroundColor Cyan
$out = vvp sim_stock +STIMULUS+stimuli/GME_20210128_stimulus.memh +TICKER+GME 2>&1
$out | Out-File -FilePath stimuli/GME_20210128_result.txt -Encoding ascii
$out | Select-String 'FIRED_RULE_MASK|FIRED_ML_MASK|SUMMARY'
$results += python check_results.py stimuli/GME_20210128_golden.txt stimuli/GME_20210128_result.txt

Write-Host "--- AMC 2021-01-28 ---" -ForegroundColor Cyan
$out = vvp sim_stock +STIMULUS+stimuli/AMC_20210128_stimulus.memh +TICKER+AMC 2>&1
$out | Out-File -FilePath stimuli/AMC_20210128_result.txt -Encoding ascii
$out | Select-String 'FIRED_RULE_MASK|FIRED_ML_MASK|SUMMARY'
$results += python check_results.py stimuli/AMC_20210128_golden.txt stimuli/AMC_20210128_result.txt

Write-Host "--- BB 2021-01-28 ---" -ForegroundColor Cyan
$out = vvp sim_stock +STIMULUS+stimuli/BB_20210128_stimulus.memh +TICKER+BB 2>&1
$out | Out-File -FilePath stimuli/BB_20210128_result.txt -Encoding ascii
$out | Select-String 'FIRED_RULE_MASK|FIRED_ML_MASK|SUMMARY'
$results += python check_results.py stimuli/BB_20210128_golden.txt stimuli/BB_20210128_result.txt

Write-Host "--- NOK 2021-01-28 ---" -ForegroundColor Cyan
$out = vvp sim_stock +STIMULUS+stimuli/NOK_20210128_stimulus.memh +TICKER+NOK 2>&1
$out | Out-File -FilePath stimuli/NOK_20210128_result.txt -Encoding ascii
$out | Select-String 'FIRED_RULE_MASK|FIRED_ML_MASK|SUMMARY'
$results += python check_results.py stimuli/NOK_20210128_golden.txt stimuli/NOK_20210128_result.txt

Write-Host "--- SPY 2010-05-06 ---" -ForegroundColor Cyan
$out = vvp sim_stock +STIMULUS+stimuli/SPY_20100506_stimulus.memh +TICKER+SPY 2>&1
$out | Out-File -FilePath stimuli/SPY_20100506_result.txt -Encoding ascii
$out | Select-String 'FIRED_RULE_MASK|FIRED_ML_MASK|SUMMARY'
$results += python check_results.py stimuli/SPY_20100506_golden.txt stimuli/SPY_20100506_result.txt

Write-Host "--- PG 2010-05-06 ---" -ForegroundColor Cyan
$out = vvp sim_stock +STIMULUS+stimuli/PG_20100506_stimulus.memh +TICKER+PG 2>&1
$out | Out-File -FilePath stimuli/PG_20100506_result.txt -Encoding ascii
$out | Select-String 'FIRED_RULE_MASK|FIRED_ML_MASK|SUMMARY'
$results += python check_results.py stimuli/PG_20100506_golden.txt stimuli/PG_20100506_result.txt

Write-Host "--- AAPL 2010-05-06 ---" -ForegroundColor Cyan
$out = vvp sim_stock +STIMULUS+stimuli/AAPL_20100506_stimulus.memh +TICKER+AAPL 2>&1
$out | Out-File -FilePath stimuli/AAPL_20100506_result.txt -Encoding ascii
$out | Select-String 'FIRED_RULE_MASK|FIRED_ML_MASK|SUMMARY'
$results += python check_results.py stimuli/AAPL_20100506_golden.txt stimuli/AAPL_20100506_result.txt

Write-Host "--- ACN 2010-05-06 ---" -ForegroundColor Cyan
$out = vvp sim_stock +STIMULUS+stimuli/ACN_20100506_stimulus.memh +TICKER+ACN 2>&1
$out | Out-File -FilePath stimuli/ACN_20100506_result.txt -Encoding ascii
$out | Select-String 'FIRED_RULE_MASK|FIRED_ML_MASK|SUMMARY'
$results += python check_results.py stimuli/ACN_20100506_golden.txt stimuli/ACN_20100506_result.txt

Write-Host "--- SPY 2020-03-16 ---" -ForegroundColor Cyan
$out = vvp sim_stock +STIMULUS+stimuli/SPY_20200316_stimulus.memh +TICKER+SPY 2>&1
$out | Out-File -FilePath stimuli/SPY_20200316_result.txt -Encoding ascii
$out | Select-String 'FIRED_RULE_MASK|FIRED_ML_MASK|SUMMARY'
$results += python check_results.py stimuli/SPY_20200316_golden.txt stimuli/SPY_20200316_result.txt

Write-Host "--- JETS 2020-03-16 ---" -ForegroundColor Cyan
$out = vvp sim_stock +STIMULUS+stimuli/JETS_20200316_stimulus.memh +TICKER+JETS 2>&1
$out | Out-File -FilePath stimuli/JETS_20200316_result.txt -Encoding ascii
$out | Select-String 'FIRED_RULE_MASK|FIRED_ML_MASK|SUMMARY'
$results += python check_results.py stimuli/JETS_20200316_golden.txt stimuli/JETS_20200316_result.txt

Write-Host "--- TSLA 2020-03-16 ---" -ForegroundColor Cyan
$out = vvp sim_stock +STIMULUS+stimuli/TSLA_20200316_stimulus.memh +TICKER+TSLA 2>&1
$out | Out-File -FilePath stimuli/TSLA_20200316_result.txt -Encoding ascii
$out | Select-String 'FIRED_RULE_MASK|FIRED_ML_MASK|SUMMARY'
$results += python check_results.py stimuli/TSLA_20200316_golden.txt stimuli/TSLA_20200316_result.txt

Write-Host "--- ZM 2020-03-16 ---" -ForegroundColor Cyan
$out = vvp sim_stock +STIMULUS+stimuli/ZM_20200316_stimulus.memh +TICKER+ZM 2>&1
$out | Out-File -FilePath stimuli/ZM_20200316_result.txt -Encoding ascii
$out | Select-String 'FIRED_RULE_MASK|FIRED_ML_MASK|SUMMARY'
$results += python check_results.py stimuli/ZM_20200316_golden.txt stimuli/ZM_20200316_result.txt

Write-Host "--- SPY 2019-06-04 ---" -ForegroundColor Cyan
$out = vvp sim_stock +STIMULUS+stimuli/SPY_20190604_stimulus.memh +TICKER+SPY 2>&1
$out | Out-File -FilePath stimuli/SPY_20190604_result.txt -Encoding ascii
$out | Select-String 'FIRED_RULE_MASK|FIRED_ML_MASK|SUMMARY'
$results += python check_results.py stimuli/SPY_20190604_golden.txt stimuli/SPY_20190604_result.txt

Write-Host "--- MSFT 2019-06-04 ---" -ForegroundColor Cyan
$out = vvp sim_stock +STIMULUS+stimuli/MSFT_20190604_stimulus.memh +TICKER+MSFT 2>&1
$out | Out-File -FilePath stimuli/MSFT_20190604_result.txt -Encoding ascii
$out | Select-String 'FIRED_RULE_MASK|FIRED_ML_MASK|SUMMARY'
$results += python check_results.py stimuli/MSFT_20190604_golden.txt stimuli/MSFT_20190604_result.txt

Write-Host "--- KO 2019-06-04 ---" -ForegroundColor Cyan
$out = vvp sim_stock +STIMULUS+stimuli/KO_20190604_stimulus.memh +TICKER+KO 2>&1
$out | Out-File -FilePath stimuli/KO_20190604_result.txt -Encoding ascii
$out | Select-String 'FIRED_RULE_MASK|FIRED_ML_MASK|SUMMARY'
$results += python check_results.py stimuli/KO_20190604_golden.txt stimuli/KO_20190604_result.txt

Write-Host "--- GLD 2019-06-04 ---" -ForegroundColor Cyan
$out = vvp sim_stock +STIMULUS+stimuli/GLD_20190604_stimulus.memh +TICKER+GLD 2>&1
$out | Out-File -FilePath stimuli/GLD_20190604_result.txt -Encoding ascii
$out | Select-String 'FIRED_RULE_MASK|FIRED_ML_MASK|SUMMARY'
$results += python check_results.py stimuli/GLD_20190604_golden.txt stimuli/GLD_20190604_result.txt

Write-Host ''
Write-Host '=== FINAL RESULTS ===' -ForegroundColor White
$results | ForEach-Object { Write-Host $_ }
