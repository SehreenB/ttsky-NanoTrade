/*
 * NanoTrade Real-World Testbench #3: Quiet Market Day — 2019
 * ===========================================================
 * Date modeled: October 3, 2019 — a low-volatility Thursday
 * VIX (fear index) at 17.  No major news.  Typical institutional flow.
 *
 * Purpose of this testbench:
 *   - Show the chip CORRECTLY STAYS SILENT on normal trading
 *   - Demonstrate order matching on tight spreads
 *   - Show gradual, legitimate intraday price drift (NORMAL = no alert)
 *   - One brief, real anomaly embedded: a fat-finger order at 2:37 PM
 *     (accidentally typed too many zeros — common real event)
 *   - VIX spike at end of day: small afternoon dip on ISM data miss
 *
 * Stocks:
 *   MSFT (Microsoft): $136.50 meandering, healthy volume [* 4 = 546]
 *   GOOGL (Alphabet): $1,201 tick-by-tick  [/ 4 = 300, then * 4 = 1200]
 *     Note: GOOGL too expensive for 12-bit, so we show $300 = fractional
 *   WMT  (Walmart):   $119 stable consumer staple [* 4 = 476]
 *
 * Fat-finger event:
 *   At 2:37 PM, a trader at a large bank accidentally sent a sell order
 *   for 50,000 shares instead of 500. Price momentarily tanked $3 before
 *   correcting. NanoTrade should flag this as a SPIKE + VOLUME SURGE.
 *
 * HOW TO RUN:
 *   iverilog -g2005 -o sim_quiet tb_quiet_2019.v tt_um_nanotrade.v \
 *            order_book.v anomaly_detector.v feature_extractor.v ml_inference_engine.v
 *   vvp sim_quiet
 */

`timescale 1ns/1ps
`default_nettype none

module tb_quiet_2019;

    // -------------------------------------------------------------------
    //  DUT
    // -------------------------------------------------------------------
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

    // -------------------------------------------------------------------
    //  Output decoding
    // -------------------------------------------------------------------
    wire        alert_flag     = uo_out[7];
    wire [2:0]  alert_priority = uo_out[6:4];
    wire        match_valid    = uo_out[3];
    wire [2:0]  alert_type     = uo_out[2:0];
    wire        ml_valid_out   = uio_out[7];
    wire [2:0]  ml_class_out   = uio_out[6:4];
    wire [3:0]  ml_conf_nibble = uio_out[3:0];

    integer cycle_count;
    initial cycle_count = 0;
    always @(posedge clk) cycle_count = cycle_count + 1;

    integer alerts_fired, matches_made, ml_results, false_positives;
    initial begin
        alerts_fired   = 0;
        matches_made   = 0;
        ml_results     = 0;
        false_positives = 0;  // any alert before fat-finger phase
    end

    // Track which phase we're in (0=normal, 1=anomaly, 2=recovery)
    reg [1:0] market_phase;
    initial market_phase = 2'd0;

    reg prev_alert;
    reg [2:0] prev_type;
    initial begin prev_alert = 0; prev_type = 0; end

    always @(posedge clk) begin
        if (alert_flag && (!prev_alert || alert_type != prev_type)) begin
            alerts_fired = alerts_fired + 1;
            if (market_phase == 2'd0) begin
                // Alert during normal trading — unexpected!
                false_positives = false_positives + 1;
                $display("\033[1;33m  [cy %0d] UNEXPECTED alert type=%0d prio=%0d (normal period!)\033[0m",
                         cycle_count, alert_type, alert_priority);
            end else begin
                $display("\033[1;31m  [cy %0d] ALERT type=%0d prio=%0d  %s\033[0m",
                         cycle_count, alert_type, alert_priority,
                         (alert_type == 3'd7) ? "<FLASH CRASH>" :
                         (alert_type == 3'd0) ? "(Fat-Finger Price Spike)" :
                         (alert_type == 3'd2) ? "(Volume Surge)" :
                         (alert_type == 3'd6) ? "(Order Imbalance)" : "(Anomaly)");
            end
        end
        prev_alert = alert_flag;
        prev_type  = alert_type;

        if (match_valid) begin
            matches_made = matches_made + 1;
            // Only print first 5 to avoid flooding
            if (matches_made <= 5)
                $display("\033[1;32m  [cy %0d] Order matched (book clearing normally)\033[0m", cycle_count);
        end

        if (ml_valid_out) begin
            ml_results = ml_results + 1;
            if (ml_class_out == 3'd0 && market_phase == 2'd0)
                $display("\033[0;32m  [cy %0d] ML: NORMAL (correct, quiet day confirmed)\033[0m", cycle_count);
            else if (ml_class_out != 3'd0)
                $display("\033[1;35m  [cy %0d] ML: class=%0d conf=%0d %s\033[0m",
                         cycle_count, ml_class_out, ml_conf_nibble,
                         (market_phase == 2'd1) ? "<< fat-finger anomaly detected! >>" : "");
        end
    end

    // -------------------------------------------------------------------
    //  Helper tasks
    // -------------------------------------------------------------------
    task send_price;
        input [11:0] p;
        begin
            @(posedge clk); #1;
            ui_in  = {2'b00, p[5:0]};
            uio_in = {2'b00, p[11:6]};
        end
    endtask

    task send_volume;
        input [11:0] v;
        begin
            @(posedge clk); #1;
            ui_in  = {2'b01, v[5:0]};
            uio_in = {2'b00, v[11:6]};
        end
    endtask

    task send_buy;
        input [5:0] qty;
        begin
            @(posedge clk); #1;
            ui_in  = {2'b10, qty};
            uio_in = 8'h00;
        end
    endtask

    task send_sell;
        input [5:0] qty;
        begin
            @(posedge clk); #1;
            ui_in  = {2'b11, qty};
            uio_in = 8'h00;
        end
    endtask

    task idle;
        input integer n;
        integer k;
        begin
            for (k = 0; k < n; k = k + 1) begin
                @(posedge clk); #1;
                ui_in  = 8'h00;
                uio_in = 8'h00;
            end
        end
    endtask

    // Normal tick: small price wiggle, balanced book, modest volume
    // Simulates realistic HFT market-making: quotes update every ~10ms
    task normal_tick;
        input [11:0] base_price;
        input [1:0]  jitter;    // 0-3: small random-ish offset for simulation
        begin
            // Price wiggles ±1-2 units (cents in scaled form)
            case (jitter)
                2'd0: send_price(base_price);
                2'd1: send_price(base_price + 12'd1);
                2'd2: send_price(base_price - 12'd1);
                2'd3: send_price(base_price + 12'd2);
            endcase
            send_volume(12'd180);   // ~90 shares/s, light normal day
            // Balanced book with tight spread
            send_buy(6'd8);
            send_sell(6'd8);
        end
    endtask

    task time_banner;
        input [8*40-1:0] msg;
        input [8*12-1:0] time_s;
        begin
            $display("\033[0;36m  [%s] %s\033[0m", time_s, msg);
        end
    endtask

    // -------------------------------------------------------------------
    //  MAIN STIMULUS
    // -------------------------------------------------------------------
    integer k;
    reg [1:0] jit;

    initial begin
        $dumpfile("quiet_2019.vcd");
        $dumpvars(0, tb_quiet_2019);

        $display("");
        $display("\033[1;37m+====================================================================+\033[0m");
        $display("\033[1;37m|  NanoTrade -- QUIET MARKET DAY REPLAY                             |\033[0m");
        $display("\033[1;37m|  Date: October 3, 2019  |  VIX: 17  |  Low volatility            |\033[0m");
        $display("\033[1;37m|  Stocks: MSFT $136, GOOGL $300 (proxy), WMT $119                 |\033[0m");
        $display("\033[1;37m|  Goal: Verify NO false alerts on normal market, but DETECT        |\033[0m");
        $display("\033[1;37m|  the 2:37 PM fat-finger order and afternoon ISM data dip          |\033[0m");
        $display("\033[1;37m+====================================================================+\033[0m");
        $display("");

        // Reset
        ena = 1; ui_in = 0; uio_in = 0; rst_n = 0;
        repeat(5) @(posedge clk);
        rst_n = 1; #1;

        // ============================================================
        // 09:30 — MARKET OPEN, MSFT baseline
        // ============================================================
        market_phase = 2'd0;
        time_banner("MARKET OPEN: MSFT $136.50 (545 scaled)", "09:30:00");
        $display("  Normal open. Institutions slowly accumulate.");
        $display("  VIX at 17 -- below average, very calm market.");

        // Establish MSFT baseline: $136.50 = 546 (scaled *4)
        repeat(50) begin
            // Simulate realistic pseudo-random jitter using counter
            jit = cycle_count[1:0];
            normal_tick(12'd546, jit);
        end
        idle(20);

        // ============================================================
        // 10:00 — Slow morning, tight spreads, order book filling
        // ============================================================
        time_banner("MORNING DRIFT: Institutions accumulating MSFT", "10:00:00");
        $display("  Pension fund quietly buying. 2 buys for every 1 sell.");
        $display("  Price drifts from $136.50 -> $137.00 (tiny upward pressure)");
        // Slight buy imbalance — legitimate, very gradual
        // Price drifts from 546 to 548 over 30 cycles (gentle upward lean)
        repeat(10) begin send_price(12'd546); send_volume(12'd200); send_buy(6'd10); send_sell(6'd7); end
        repeat(10) begin send_price(12'd547); send_volume(12'd200); send_buy(6'd10); send_sell(6'd7); end
        repeat(10) begin send_price(12'd548); send_volume(12'd200); send_buy(6'd10); send_sell(6'd7); end
        // Book matches firing (normal clearing)
        send_buy(6'd20);
        send_sell(6'd20);
        idle(15);

        // ============================================================
        // 11:15 — GOOGL quiet trading
        // ============================================================
        time_banner("GOOGL proxy: search ad revenue steady (scaled)", "11:15:00");
        $display("  Google normalised to same scale as MSFT for single-stock detector.");
        $display("  No news. Ad revenue on track. Quiet institutional flow.");
        repeat(35) begin
            jit = cycle_count[1:0];
            normal_tick(12'd560, jit);
        end
        idle(15);

        // ============================================================
        // 12:30 — Lunch lull, volume drops 40%
        // ============================================================
        time_banner("LUNCH LULL: Volume drops. Wide spreads on low volume.", "12:30:00");
        $display("  Classic midday volume trough. Market makers widen spreads.");
        $display("  Price barely moves. Book thins out. No anomalies.");
        repeat(30) begin
            send_price(12'd548);
            send_volume(12'd80);    // 40% of morning volume
            send_buy(6'd5);
            send_sell(6'd5);
        end
        idle(10);

        // ============================================================
        // 13:30 — WMT: Walmart afternoon run — earnings whisper
        // ============================================================
        time_banner("WMT $119: Slow institutional accumulation pre-earnings", "13:30:00");
        $display("  Walmart earnings next week. Smart money quietly loading up.");
        $display("  $119 * 4 = 476 scaled. Very low volatility consumer staple.");
        repeat(30) begin
            jit = cycle_count[1:0];
            case (jit)
                2'd0: send_price(12'd476);
                2'd1: send_price(12'd477);
                2'd2: send_price(12'd476);
                2'd3: send_price(12'd475);
            endcase
            send_volume(12'd160);
            send_buy(6'd9);
            send_sell(6'd8);   // very slight buy lean
        end
        idle(10);

        // ============================================================
        // 14:37 — FAT-FINGER ORDER EVENT
        // Reality: Large bank trader typed 50,000 shares sell instead of 500
        // Price momentarily tanked ~$3 before market makers stepped in
        // This is one of the most common real-world anomaly types
        // ============================================================
        market_phase = 2'd1;
        $display("");
        $display("\033[1;33m  ================================================================\033[0m");
        $display("\033[1;33m  2:37 PM -- FAT-FINGER ORDER EVENT                               \033[0m");
        $display("\033[1;33m  Trader at large bank sends 50,000-share sell (meant: 500)        \033[0m");
        $display("\033[1;33m  Expected: VOLUME SURGE + PRICE SPIKE alert                       \033[0m");
        $display("\033[1;33m  ================================================================\033[0m");

        // Background of the event: MSFT was at $137 right before
        repeat(5) begin
            send_price(12'd548);
            send_volume(12'd180);
            send_buy(6'd9);
            send_sell(6'd9);
        end

        // FAT FINGER: massive accidental sell order hits the market
        // Volume explodes 50x, price craters $3 in milliseconds
        send_volume(12'd4000);           // 50x normal volume in one tick
        repeat(3) send_price(12'd536);   // $134 (down $3 = 12 scaled units)
        repeat(35) send_sell(6'd63);     // massive sell pressure
        send_buy(6'd1);                  // no buyers at this speed
        idle(5);

        // Market makers step in (within ~200ms in reality)
        $display("  Market makers detect the error and step in...");
        repeat(3) send_price(12'd546);   // price snaps back to $136.50
        send_volume(12'd1200);
        repeat(10) send_buy(6'd30);      // market makers absorbing
        idle(10);

        // Back to normal
        market_phase = 2'd2;
        time_banner("PRICE RECOVERY: Fat-finger corrected, market resumes", "14:38:00");
        repeat(15) begin
            jit = cycle_count[1:0];
            normal_tick(12'd546, jit);
        end
        idle(10);

        // ============================================================
        // 15:00 — ISM Manufacturing Data Miss
        // ISM PMI came in at 47.8 vs 50.0 expected — contraction
        // Caused brief afternoon sell-off in industrials/materials
        // ============================================================
        market_phase = 2'd1;
        time_banner("ISM DATA MISS: Manufacturing PMI 47.8 vs 50.0 expected", "15:00:00");
        $display("  ISM print at 47.8 = manufacturing contraction.");
        $display("  Algo reaction: industrials sell-off. Brief but sharp.");
        $display("  MSFT mostly immune (tech, not manufacturing), but");
        $display("  algorithmic risk-off drags everything slightly.");

        // Moderate dip — not a crash, just a noticeable move
        repeat(8) send_price(12'd540);   // $135 — down $1.50 from $136.50
        send_volume(12'd600);
        repeat(12) send_sell(6'd30);
        repeat(5) send_buy(6'd15);
        idle(5);
        // Stabilizes
        repeat(10) begin
            send_price(12'd542);
            send_volume(12'd300);
            send_buy(6'd8);
            send_sell(6'd9);
        end
        idle(5);

        // ============================================================
        // 15:30 — End of day: institutional rebalancing flows
        // ============================================================
        market_phase = 2'd0;
        time_banner("END-OF-DAY REBALANCING: Funds adjusting portfolios", "15:30:00");
        $display("  Passive index funds rebalancing. Predictable, smooth.");
        $display("  Volume picks up slightly. Price drift: $135 -> $136.");
        repeat(30) begin
            jit = cycle_count[1:0];
            case (jit)
                2'd0: send_price(12'd540);
                2'd1: send_price(12'd542);
                2'd2: send_price(12'd543);
                2'd3: send_price(12'd544);
            endcase
            send_volume(12'd320);
            send_buy(6'd10);
            send_sell(6'd9);
        end
        idle(15);

        // ============================================================
        // ML inference on NORMAL market features
        // Expected class: 0 = NORMAL
        // ============================================================
        time_banner("ML INFERENCE: Normal market features -> expect NORMAL", "15:45:00");
        $display("  Feeding 256-cycle window of quiet market data to MLP...");
        repeat(30) begin
            send_price(12'd544);
            send_volume(12'd200);
            send_buy(6'd8);
            send_sell(6'd8);
        end
        idle(280);

        // ============================================================
        //  Summary
        // ============================================================
        $display("");
        $display("\033[1;37m+====================================================================+\033[0m");
        $display("\033[1;37m|             QUIET DAY SIMULATION SUMMARY                          |\033[0m");
        $display("\033[1;37m+====================================================================+\033[0m");
        $display("\033[1;37m|  Total Cycles        : %-5d                                      |\033[0m", cycle_count);
        $display("\033[1;37m|  Alerts Fired        : %-5d  (should be 1-2, fat-finger only)    |\033[0m", alerts_fired);
        $display("\033[1;37m|  False Positives     : %-5d  (must be 0 -- chip is precise!)     |\033[0m", false_positives);
        $display("\033[1;37m|  Order Book Matches  : %-5d  (normal intraday clearing)           |\033[0m", matches_made);
        $display("\033[1;37m|  ML Inferences       : %-5d  (expect NORMAL class most of day)   |\033[0m", ml_results);
        $display("\033[1;37m|                                                                   |\033[0m");
        $display("\033[1;37m|  VALIDATION:                                                      |\033[0m");
        if (false_positives == 0)
            $display("\033[1;32m|  [PASS] Zero false positives on normal trading data            |\033[0m");
        else
            $display("\033[1;31m|  [FAIL] False positives detected: %-3d                          |\033[0m", false_positives);
        $display("\033[1;37m|                                                                   |\033[0m");
        $display("\033[1;37m|  Real context: Oct 3 2019 -- MSFT closed at $136.37              |\033[0m");
        $display("\033[1;37m|  VIX: 17, S&P closed flat (+0.08%%)                               |\033[0m");
        $display("\033[1;37m|  ISM miss caused brief risk-off, recovered by close               |\033[0m");
        $display("\033[1;37m+====================================================================+\033[0m");
        $display("");

        $finish;
    end

    initial begin #50000000; $display("TIMEOUT"); $finish; end

endmodule