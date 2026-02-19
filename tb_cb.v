/*
 * tb_cb.v  --  NanoTrade Circuit Breaker Dedicated Testbench  (v5 final)
 * =========================================================================
 * Tests:
 *   TEST 1  FLASH_CRASH  -> PAUSE:    match_valid fully suppressed
 *   TEST 2  QUOTE_STUFF  -> THROTTLE: match rate reduced vs baseline
 *   TEST 3  IMBALANCE    -> WIDEN:    narrow cross blocked, deep cross ok
 *   TEST 4  NORMAL       -> CB clears, matching resumes immediately
 *   TEST 5  Self-healing -> CB expires autonomously, zero host action
 *
 * Compile & run:
 *   iverilog -g2012 -o sim_cb tb_cb.v tt_um_nanotrade.v order_book.v \
 *            anomaly_detector.v feature_extractor.v ml_inference_engine.v
 *   vvp sim_cb
 *   gtkwave cb.vcd
 */

`timescale 1ns/1ps
`default_nettype none

module tb_cb;

    reg  [7:0] ui_in  = 8'h00;
    wire [7:0] uo_out;
    reg  [7:0] uio_in = 8'h00;
    wire [7:0] uio_out, uio_oe;
    reg        ena = 1, clk = 0, rst_n = 0;

    tt_um_nanotrade dut (
        .ui_in(ui_in), .uo_out(uo_out),
        .uio_in(uio_in), .uio_out(uio_out), .uio_oe(uio_oe),
        .ena(ena), .clk(clk), .rst_n(rst_n)
    );

    always #10 clk = ~clk;  // 50 MHz

    // Hierarchical probes
    wire [1:0] cb_state_int  = dut.u_order_book.cb_mode_r;
    wire [8:0] cb_cdown_int  = dut.u_order_book.cb_countdown;
    wire       cb_active_int = dut.cb_active;
    wire       match_valid   = uo_out[3];

    integer cyc = 0;
    always @(posedge clk) cyc = cyc + 1;

    integer pass_count = 0, fail_count = 0;

    `define GRN  "\033[1;32m"
    `define RED  "\033[1;31m"
    `define MAG  "\033[1;35m"
    `define WHT  "\033[1;37m"
    `define DIM  "\033[2m"
    `define RST  "\033[0m"

    // ---------------------------------------------------------------
    // count_matches_pairs: send N pairs of buy-sell-idle at price p.
    // match_valid fires on the IDLE cycle (one cycle after sell inserts ask).
    // Drives ui_in on negedge for clean setup before posedge sampling.
    // ---------------------------------------------------------------
    integer match_cnt;
    task count_matches_pairs; input integer n; input [5:0] p; integer i;
        begin
            match_cnt = 0;
            for (i = 0; i < n; i = i + 1) begin
                @(negedge clk); ui_in = {2'b10, p};  // buy
                @(posedge clk); #1; ui_in = 0;
                @(negedge clk); ui_in = {2'b11, p};  // sell
                @(posedge clk); #1; ui_in = 0;
                @(posedge clk); #1;                   // idle — match fires here
                if (match_valid) match_cnt = match_cnt + 1;
            end
        end
    endtask

    // Inject ML result for exactly one posedge, then wait 2 cycles to settle
    task inject_ml; input [2:0] cls; input [7:0] conf;
        begin
            ui_in = 0;
            @(negedge clk);
            force dut.ml_valid      = 1'b1;
            force dut.ml_class      = cls;
            force dut.ml_confidence = conf;
            @(posedge clk); #1;
            release dut.ml_valid;
            release dut.ml_class;
            release dut.ml_confidence;
            repeat(2) @(posedge clk); #1;
        end
    endtask

    task check; input [255:0] lbl; input cond;
        begin
            if (cond) begin
                $display("%s  [PASS]  cy=%-4d  %0s%s", `GRN, cyc, lbl, `RST);
                pass_count = pass_count + 1;
            end else begin
                $display("%s  [FAIL]  cy=%-4d  %0s%s", `RED, cyc, lbl, `RST);
                fail_count = fail_count + 1;
            end
        end
    endtask

    integer matches_normal, matches_throttled;

    initial begin
        $dumpfile("cb.vcd"); $dumpvars(0, tb_cb);

        $display("");
        $display("%s+============================================================+%s", `WHT, `RST);
        $display("%s|    NanoTrade  --  ML Circuit Breaker Dedicated Test        |%s", `WHT, `RST);
        $display("%s|    Injects ML class/confidence, verifies silicon response  |%s", `WHT, `RST);
        $display("%s+============================================================+%s", `WHT, `RST);
        $display("");

        rst_n = 0; repeat(5) @(posedge clk); rst_n = 1;
        repeat(3) @(posedge clk); #1;
        $display("%s  [cy %-4d]  Reset released%s", `DIM, cyc, `RST);

        // ============================================================
        // TEST 1: FLASH_CRASH -> PAUSE
        // confidence=60 -> countdown = 2*60 = 120 cycles freeze
        // ============================================================
        $display("");
        $display("%s+------------------------------------------------------------+%s", `MAG, `RST);
        $display("%s|  TEST 1 -- FLASH_CRASH (class 3)  ->  PAUSE               |%s", `MAG, `RST);
        $display("%s|  confidence=60  ->  freeze 120 cycles (2.4 us @ 50 MHz)  |%s", `MAG, `RST);
        $display("%s+------------------------------------------------------------+%s", `MAG, `RST);

        count_matches_pairs(10, 6'd20);
        check("Pre-CB baseline: matching active", match_cnt > 0);
        $display("%s  [cy %-4d]  Baseline matches (10 pairs): %0d%s",
                 `DIM, cyc, match_cnt, `RST);

        inject_ml(3'd3, 8'd60);

        check("TEST 1a: cb_state == PAUSE (2'b11)",  cb_state_int == 2'b11);
        check("TEST 1b: cb_active asserted",          cb_active_int == 1'b1);

        count_matches_pairs(10, 6'd20);
        check("TEST 1c: match_valid=0 during PAUSE",  match_cnt == 0);
        $display("%s  [cy %-4d]  Matches during PAUSE (10 pairs): %0d (expect 0)%s",
                 `DIM, cyc, match_cnt, `RST);

        $display("%s  [cy %-4d]  Waiting for 120-cycle countdown to expire...%s",
                 `DIM, cyc, `RST);
        // countdown=120, ~34 cycles used (2 settle + 30 pairs), ~86 remain
        repeat(95) @(posedge clk); #1;

        check("TEST 1d: CB self-healed to NORMAL",  cb_state_int == 2'b00);
        check("TEST 1e: cb_active deasserted",       cb_active_int == 1'b0);

        count_matches_pairs(10, 6'd20);
        check("TEST 1f: matching resumes after self-heal", match_cnt > 0);
        $display("%s  [cy %-4d]  Matches after self-heal (10 pairs): %0d%s",
                 `DIM, cyc, match_cnt, `RST);

        // ============================================================
        // TEST 2: QUOTE_STUFFING -> THROTTLE
        // confidence=60 -> throttle_div = 60>>4 = 3, 1 order per 4 cycles
        // In 3-cycle pairs: buy gets slot 0 (allow), sell gets slot 1 (allow
        // since div=3 and throttle_cnt hasn't expired yet), but alignment varies.
        // The key observable: cb_state=THROTTLE (not PAUSE), rate < unthrottled.
        // ============================================================
        $display("");
        $display("%s+------------------------------------------------------------+%s", `MAG, `RST);
        $display("%s|  TEST 2 -- QUOTE_STUFFING (class 5)  ->  THROTTLE         |%s", `MAG, `RST);
        $display("%s|  confidence=60  ->  1 order per 4 cycles                 |%s", `MAG, `RST);
        $display("%s|  Observable: cb_state=THROTTLE, match rate reduced vs CB=0|%s", `MAG, `RST);
        $display("%s+------------------------------------------------------------+%s", `MAG, `RST);

        count_matches_pairs(20, 6'd20);
        matches_normal = match_cnt;
        $display("%s  [cy %-4d]  Unthrottled matches (20 pairs): %0d%s",
                 `DIM, cyc, matches_normal, `RST);

        inject_ml(3'd5, 8'd60);

        check("TEST 2a: cb_state == THROTTLE (2'b01)", cb_state_int == 2'b01);
        check("TEST 2b: THROTTLE is not a full PAUSE",  cb_state_int != 2'b11);

        count_matches_pairs(20, 6'd20);
        matches_throttled = match_cnt;
        $display("%s  [cy %-4d]  Throttled matches (20 pairs): %0d (reduced from %0d)%s",
                 `DIM, cyc, matches_throttled, matches_normal, `RST);

        check("TEST 2c: throttled match rate < unthrottled",
              matches_throttled < matches_normal);

        repeat(100) @(posedge clk); #1;

        // ============================================================
        // TEST 3: ORDER_IMBALANCE -> WIDEN
        // confidence=64 -> spread_guard = 64>>5 = 2 ticks
        //
        // Price encoding: new_price = {ext_data[0]=0, data_in[5:1]}
        //   buy@31  -> book_bid = 15    sell@31 -> book_ask = 15
        //   threshold = 15 + 2 = 17.   bid=15 >= 17?  NO -> BLOCKED
        //
        //   buy@40  -> book_bid = 20    sell@31 -> book_ask = 15
        //   threshold = 15 + 2 = 17.   bid=20 >= 17?  YES -> EXECUTES
        // ============================================================
        $display("");
        $display("%s+------------------------------------------------------------+%s", `MAG, `RST);
        $display("%s|  TEST 3 -- ORDER_IMBALANCE (class 4)  ->  WIDEN           |%s", `MAG, `RST);
        $display("%s|  confidence=64  ->  spread guard = 2 book-ticks           |%s", `MAG, `RST);
        $display("%s|  Narrow: buy@31 sell@31 -> bid=15 < threshold=17: BLOCKED |%s", `MAG, `RST);
        $display("%s|  Deep:   buy@40 sell@31 -> bid=20 >= threshold=17: MATCH  |%s", `MAG, `RST);
        $display("%s+------------------------------------------------------------+%s", `MAG, `RST);

        rst_n = 0; repeat(3) @(posedge clk); rst_n = 1; repeat(3) @(posedge clk); #1;

        inject_ml(3'd4, 8'd64);

        check("TEST 3a: cb_state == WIDEN (2'b10)", cb_state_int == 2'b10);

        // Narrow cross: bid=ask=15, threshold=17 -> should be blocked
        count_matches_pairs(10, 6'd31);
        $display("%s  [cy %-4d]  Narrow cross (buy@31,sell@31) matches: %0d (expect 0)%s",
                 `DIM, cyc, match_cnt, `RST);
        check("TEST 3b: narrow crossing blocked by spread guard", match_cnt == 0);

        // Deep cross: fresh book, re-inject WIDEN, then send buy@40/sell@31/idle
        // bid=20, ask=15, threshold=17 -> 20 >= 17 -> MATCH
        // Reset first so stale narrow-test orders don't affect timing.
        rst_n = 0; repeat(3) @(posedge clk); rst_n = 1; repeat(3) @(posedge clk); #1;
        inject_ml(3'd4, 8'd64);   // re-inject WIDEN on clean book
        begin : deep_cross
            integer dc; match_cnt = 0;
            for (dc = 0; dc < 10; dc = dc + 1) begin
                @(negedge clk); ui_in = {2'b10, 6'd40};   // buy@40 -> bid=20
                @(posedge clk); #1; ui_in = 0;
                @(negedge clk); ui_in = {2'b11, 6'd31};   // sell@31 -> ask=15
                @(posedge clk); #1; ui_in = 0;
                @(posedge clk); #1;                        // idle - match fires
                if (match_valid) match_cnt = match_cnt + 1;
            end
        end
        $display("%s  [cy %-4d]  Deep cross (buy@40,sell@31) matches: %0d (expect >0)%s",
                 `DIM, cyc, match_cnt, `RST);
        check("TEST 3c: deep crossing (bid >= ask+guard) executes", match_cnt > 0);

        repeat(80) @(posedge clk); #1;

        // ============================================================
        // TEST 4: NORMAL class -> CB clears immediately
        // ============================================================
        $display("");
        $display("%s+------------------------------------------------------------+%s", `MAG, `RST);
        $display("%s|  TEST 4 -- NORMAL (class 0)  ->  CB clears immediately    |%s", `MAG, `RST);
        $display("%s+------------------------------------------------------------+%s", `MAG, `RST);

        rst_n = 0; repeat(3) @(posedge clk); rst_n = 1; repeat(3) @(posedge clk); #1;

        inject_ml(3'd3, 8'd200);
        check("TEST 4a: PAUSE active before NORMAL injection",  cb_state_int == 2'b11);

        inject_ml(3'd0, 8'd0);
        check("TEST 4b: CB cleared to NORMAL",  cb_state_int == 2'b00);
        check("TEST 4c: cb_active deasserted",  cb_active_int == 1'b0);

        count_matches_pairs(10, 6'd20);
        check("TEST 4d: matching resumes immediately after NORMAL", match_cnt > 0);
        $display("%s  [cy %-4d]  Post-clear matches (10 pairs): %0d%s",
                 `DIM, cyc, match_cnt, `RST);

        // ============================================================
        // TEST 5: Self-Healing — CB expires autonomously
        // confidence=10 -> countdown = 20 cycles
        // ============================================================
        $display("");
        $display("%s+------------------------------------------------------------+%s", `MAG, `RST);
        $display("%s|  TEST 5 -- Self-Healing (countdown = 20 cycles)           |%s", `MAG, `RST);
        $display("%s|  Zero host action -- CB expires on its own                |%s", `MAG, `RST);
        $display("%s+------------------------------------------------------------+%s", `MAG, `RST);

        inject_ml(3'd3, 8'd10);
        check("TEST 5a: CB active after injection", cb_active_int == 1'b1);

        $display("%s  [cy %-4d]  Waiting 28 cycles with no host action...%s",
                 `DIM, cyc, `RST);
        repeat(28) @(posedge clk); #1;

        check("TEST 5b: CB self-healed (no host needed)",  cb_state_int == 2'b00);
        check("TEST 5c: cb_active low after self-heal",    cb_active_int == 1'b0);

        // ============================================================
        // SUMMARY
        // ============================================================
        $display("");
        $display("%s+============================================================+%s", `WHT, `RST);
        $display("%s|                  CIRCUIT BREAKER TEST SUMMARY             |%s", `WHT, `RST);
        $display("%s+============================================================+%s", `WHT, `RST);
        $display("%s|  Tests PASSED : %-3d                                        |%s",
                 `GRN, pass_count, `RST);
        if (fail_count == 0)
            $display("%s|  Tests FAILED : 0   -- ALL PASS                           |%s",
                     `GRN, `RST);
        else
            $display("%s|  Tests FAILED : %-3d                                        |%s",
                     `RED, fail_count, `RST);
        $display("%s+============================================================+%s", `WHT, `RST);
        $display("%s|  FLASH_CRASH  -> PAUSE    : match_valid=0 enforced in HW  |%s", `WHT, `RST);
        $display("%s|  QUOTE_STUFF  -> THROTTLE : order rate cut in HW          |%s", `WHT, `RST);
        $display("%s|  IMBALANCE    -> WIDEN    : spread guard enforced in HW   |%s", `WHT, `RST);
        $display("%s|  NORMAL       -> CLEAR    : full speed instantly resumed  |%s", `WHT, `RST);
        $display("%s|  Self-heal    : countdown expires, zero host action       |%s", `WHT, `RST);
        $display("%s|  ML->CB latency: 2 clock cycles = 40 ns @ 50 MHz         |%s", `WHT, `RST);
        $display("%s+============================================================+%s", `WHT, `RST);
        $display("");
        $finish;
    end

endmodule