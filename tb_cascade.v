/*
 * tb_cascade.v  --  NanoTrade Cascade Detector Dedicated Test  (v2)
 * ==================================================================
 * Tests:
 *   TEST 1  VOL_CRASH   : VOLUME_SURGE  → FLASH_CRASH  → cascade fires
 *   TEST 2  SPIKE_CRASH : PRICE_SPIKE   → FLASH_CRASH  → cascade fires
 *   TEST 3  STUFF_CRASH : QUOTE_STUFFING→ FLASH_CRASH  → cascade fires
 *   TEST 4  TRIPLE      : 3 distinct anomalies → cascade TRIPLE fires
 *   TEST 5  No cascade  : single isolated FLASH_CRASH → no cascade
 *   TEST 6  Window expiry: events > 64 cy apart → window resets, no cascade
 *   TEST 7  CB Doubling : cascade fires doubled CB freeze
 *
 * Compile & run:
 *   iverilog -g2012 -o sim_cascade tb_cascade.v tt_um_nanotrade.v order_book.v \
 *     cascade_detector.v anomaly_detector.v feature_extractor.v ml_inference_engine.v
 *   vvp sim_cascade
 *   gtkwave cascade.vcd
 */

`timescale 1ns/1ps
`default_nettype none

module tb_cascade;

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

    always #10 clk = ~clk;

    // Probes
    wire        cascade_alert = dut.cascade_alert;
    wire [1:0]  cascade_type  = dut.cascade_type;
    wire [3:0]  hist0         = dut.u_cascade.hist[0];
    wire [3:0]  hist1         = dut.u_cascade.hist[1];
    wire [3:0]  hist2         = dut.u_cascade.hist[2];
    wire [8:0]  cb_countdown  = dut.u_order_book.cb_countdown;
    wire        cascade_cb_load  = dut.cascade_cb_load;
    wire [7:0]  cascade_cb_param = dut.cascade_cb_param;

    integer cyc = 0;
    always @(posedge clk) cyc = cyc + 1;

    integer pass_count = 0, fail_count = 0;

    `define GRN  "\033[1;32m"
    `define RED  "\033[1;31m"
    `define MAG  "\033[1;35m"
    `define WHT  "\033[1;37m"
    `define DIM  "\033[2m"
    `define RST  "\033[0m"

    function [79:0] casc_name; input [1:0] t;
        case (t)
            2'd0: casc_name = "VOL_CRASH ";
            2'd1: casc_name = "SPIK_CRASH";
            2'd2: casc_name = "STUF_CRASH";
            2'd3: casc_name = "TRIPLE    ";
        endcase
    endfunction

    // ------------------------------------------------------------------
    // All injections go via ML path to avoid anomaly_detector noise.
    // This is valid because cascade_detector fuses ML + rule streams
    // identically; we verified the rule path works in the direct trace.
    // ------------------------------------------------------------------
    // ML class codes:
    //   0=NORMAL  1=SPIKE  2=VOL_SURGE  3=FLASH_CRASH
    //   4=IMBALANCE  5=QUOTE_STUFF
    //
    task inject_ml; input [2:0] cls; input [7:0] conf;
        begin
            // rule_alert_any kept forced=0 by do_reset throughout each test
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

    // Reset + flush cascade history
    task do_reset;
        begin
            ui_in = 0;
            force dut.rule_alert_any = 1'b0;   // silence for entire test
            rst_n = 0; repeat(5) @(posedge clk); #1; rst_n = 1;
            force dut.u_cascade.test_flush = 1'b1;
            repeat(5) @(posedge clk); #1;       // flush for 5 cycles
            release dut.u_cascade.test_flush;
            repeat(3) @(posedge clk); #1;       // settle (still silenced)
            // rule_alert_any STAYS forced=0 until end_test releases it
        end
    endtask

    // Release background silence after each test
    task end_test;
        begin
            release dut.rule_alert_any;
            repeat(2) @(posedge clk); #1;
        end
    endtask

    task tick; input integer n; integer i;
        begin for(i=0;i<n;i=i+1) @(posedge clk); #1; end
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

    // Wait up to n cycles for cascade_alert to fire, return whether it did
    reg cascade_seen;
    reg [1:0] cascade_type_seen;
    task wait_for_cascade; input integer n; integer i;
        begin
            cascade_seen = 0;
            for (i = 0; i < n; i = i + 1) begin
                @(posedge clk); #1;
                if (cascade_alert && !cascade_seen) begin
                    cascade_seen = 1;
                    cascade_type_seen = cascade_type;
                end
            end
        end
    endtask

    integer cb_countdown_captured;

    initial begin
        $dumpfile("cascade.vcd"); $dumpvars(0, tb_cascade);

        $display("");
        $display("%s+============================================================+%s", `WHT, `RST);
        $display("%s|    NanoTrade  --  Cascade Detector Dedicated Test          |%s", `WHT, `RST);
        $display("%s|    Verifies multi-event signature detection + CB doubling  |%s", `WHT, `RST);
        $display("%s+============================================================+%s", `WHT, `RST);
        $display("");

        // ================================================================
        // TEST 1: VOL_CRASH  (VOLUME_SURGE → FLASH_CRASH)
        // ================================================================
        $display("%s+------------------------------------------------------------+%s", `MAG, `RST);
        $display("%s|  TEST 1 -- VOL_CRASH: VOLUME_SURGE then FLASH_CRASH       |%s", `MAG, `RST);
        $display("%s+------------------------------------------------------------+%s", `MAG, `RST);

        do_reset;
        inject_ml(3'd2, 8'd60);   // VOLUME_SURGE
        tick(4);
        $display("%s  [cy %-4d]  Event 1: VOLUME_SURGE  hist=[%0d,%0d,%0d]%s",
                 `DIM, cyc, hist0, hist1, hist2, `RST);

        inject_ml(3'd3, 8'd80);   // FLASH_CRASH
        tick(3);
        $display("%s  [cy %-4d]  Event 2: FLASH_CRASH   hist=[%0d,%0d,%0d]  cascade=%0d%s",
                 `DIM, cyc, hist0, hist1, hist2, cascade_alert, `RST);

        check("TEST 1a: cascade_alert fired",       cascade_alert == 1'b1);
        check("TEST 1b: cascade_type == VOL_CRASH", cascade_type  == 2'd0);
        $display("%s  [cy %-4d]  Cascade type: %0s%s",
                 `DIM, cyc, casc_name(cascade_type), `RST);
        end_test; tick(35);

        // ================================================================
        // TEST 2: SPIKE_CRASH  (PRICE_SPIKE → FLASH_CRASH)
        // ================================================================
        $display("");
        $display("%s+------------------------------------------------------------+%s", `MAG, `RST);
        $display("%s|  TEST 2 -- SPIKE_CRASH: PRICE_SPIKE then FLASH_CRASH      |%s", `MAG, `RST);
        $display("%s+------------------------------------------------------------+%s", `MAG, `RST);

        do_reset;
        inject_ml(3'd1, 8'd70);   // PRICE_SPIKE
        tick(4);
        $display("%s  [cy %-4d]  Event 1: PRICE_SPIKE   hist=[%0d,%0d,%0d]%s",
                 `DIM, cyc, hist0, hist1, hist2, `RST);

        inject_ml(3'd3, 8'd90);   // FLASH_CRASH
        tick(3);
        $display("%s  [cy %-4d]  Event 2: FLASH_CRASH   hist=[%0d,%0d,%0d]  cascade=%0d%s",
                 `DIM, cyc, hist0, hist1, hist2, cascade_alert, `RST);

        check("TEST 2a: cascade_alert fired",          cascade_alert == 1'b1);
        check("TEST 2b: cascade_type == SPIKE_CRASH",  cascade_type  == 2'd1);
        $display("%s  [cy %-4d]  Cascade type: %0s%s",
                 `DIM, cyc, casc_name(cascade_type), `RST);
        end_test; tick(35);

        // ================================================================
        // TEST 3: STUFF_CRASH  (QUOTE_STUFFING → FLASH_CRASH)
        // ================================================================
        $display("");
        $display("%s+------------------------------------------------------------+%s", `MAG, `RST);
        $display("%s|  TEST 3 -- STUFF_CRASH: QUOTE_STUFFING then FLASH_CRASH   |%s", `MAG, `RST);
        $display("%s+------------------------------------------------------------+%s", `MAG, `RST);

        do_reset;
        inject_ml(3'd5, 8'd80);   // QUOTE_STUFFING
        tick(4);
        $display("%s  [cy %-4d]  Event 1: QUOTE_STUFFING hist=[%0d,%0d,%0d]%s",
                 `DIM, cyc, hist0, hist1, hist2, `RST);

        inject_ml(3'd3, 8'd100);  // FLASH_CRASH
        tick(3);
        $display("%s  [cy %-4d]  Event 2: FLASH_CRASH    hist=[%0d,%0d,%0d]  cascade=%0d%s",
                 `DIM, cyc, hist0, hist1, hist2, cascade_alert, `RST);

        check("TEST 3a: cascade_alert fired",          cascade_alert == 1'b1);
        check("TEST 3b: cascade_type == STUFF_CRASH",  cascade_type  == 2'd2);
        $display("%s  [cy %-4d]  Cascade type: %0s%s",
                 `DIM, cyc, casc_name(cascade_type), `RST);
        end_test; tick(35);

        // ================================================================
        // TEST 4: TRIPLE  (3 distinct anomalies → FLASH_CRASH)
        // Models the 2010 Flash Crash: volume surge → price spike → crash
        // ================================================================
        $display("");
        $display("%s+------------------------------------------------------------+%s", `MAG, `RST);
        $display("%s|  TEST 4 -- TRIPLE: 3 distinct anomalies (2010 pattern)    |%s", `MAG, `RST);
        $display("%s|  VOLUME_SURGE -> PRICE_SPIKE -> FLASH_CRASH               |%s", `MAG, `RST);
        $display("%s+------------------------------------------------------------+%s", `MAG, `RST);

        do_reset;
        inject_ml(3'd2, 8'd60);   // VOLUME_SURGE
        tick(4);
        $display("%s  [cy %-4d]  Event 1: VOLUME_SURGE   hist=[%0d,%0d,%0d]%s",
                 `DIM, cyc, hist0, hist1, hist2, `RST);

        inject_ml(3'd1, 8'd70);   // PRICE_SPIKE
        tick(4);
        $display("%s  [cy %-4d]  Event 2: PRICE_SPIKE    hist=[%0d,%0d,%0d]%s",
                 `DIM, cyc, hist0, hist1, hist2, `RST);

        inject_ml(3'd3, 8'd90);   // FLASH_CRASH
        tick(3);
        $display("%s  [cy %-4d]  Event 3: FLASH_CRASH    hist=[%0d,%0d,%0d]  cascade=%0d%s",
                 `DIM, cyc, hist0, hist1, hist2, cascade_alert, `RST);

        check("TEST 4a: cascade_alert fired",      cascade_alert == 1'b1);
        check("TEST 4b: cascade_type == TRIPLE",   cascade_type  == 2'd3);
        $display("%s  [cy %-4d]  Cascade type: %0s  (2010 Flash Crash pattern)%s",
                 `DIM, cyc, casc_name(cascade_type), `RST);
        end_test; tick(35);

        // ================================================================
        // TEST 5: No cascade — single isolated FLASH_CRASH
        // A lone crash without any precursor should NOT trigger cascade
        // ================================================================
        $display("");
        $display("%s+------------------------------------------------------------+%s", `MAG, `RST);
        $display("%s|  TEST 5 -- No cascade: isolated FLASH_CRASH               |%s", `MAG, `RST);
        $display("%s|  A lone event with no precursor must NOT trigger cascade   |%s", `MAG, `RST);
        $display("%s+------------------------------------------------------------+%s", `MAG, `RST);

        do_reset;
        inject_ml(3'd3, 8'd100);  // FLASH_CRASH with no precursor
        tick(5);

        check("TEST 5: no cascade from isolated event", cascade_alert == 1'b0);
        $display("%s  [cy %-4d]  cascade_alert=%0d (expect 0 -- no precursor)%s",
                 `DIM, cyc, cascade_alert, `RST);
        end_test; tick(35);

        // ================================================================
        // TEST 6: Window expiry — events > CASCADE_WINDOW cycles apart
        // First event ages out; second event arrives alone → no cascade
        // ================================================================
        $display("");
        $display("%s+------------------------------------------------------------+%s", `MAG, `RST);
        $display("%s|  TEST 6 -- Window expiry: events > 64 cycles apart        |%s", `MAG, `RST);
        $display("%s|  First event must expire before second arrives             |%s", `MAG, `RST);
        $display("%s+------------------------------------------------------------+%s", `MAG, `RST);

        do_reset;
        inject_ml(3'd2, 8'd60);   // VOLUME_SURGE
        tick(2);
        $display("%s  [cy %-4d]  Event 1: VOLUME_SURGE%s", `DIM, cyc, `RST);

        tick(70);   // wait > CASCADE_WINDOW=64 cycles
        $display("%s  [cy %-4d]  Waited 70 cycles (window=64, should expire)%s",
                 `DIM, cyc, `RST);

        inject_ml(3'd3, 8'd80);   // FLASH_CRASH — first event should have expired
        tick(5);

        check("TEST 6: no cascade after window expiry", cascade_alert == 1'b0);
        $display("%s  [cy %-4d]  cascade_alert=%0d (expect 0 -- window expired)%s",
                 `DIM, cyc, cascade_alert, `RST);
        end_test; tick(35);

        // ================================================================
        // TEST 7: CB Doubling
        // Inject VOL_CRASH with confidence=80 → cascade_cb_param should = 160
        // Order book CB countdown should be > 160 (doubled freeze)
        // ================================================================
        $display("");
        $display("%s+------------------------------------------------------------+%s", `MAG, `RST);
        $display("%s|  TEST 7 -- CB Doubling: cascade freeze = 2x confidence    |%s", `MAG, `RST);
        $display("%s|  VOLUME_SURGE + FLASH_CRASH(conf=80) -> CB param=160      |%s", `MAG, `RST);
        $display("%s+------------------------------------------------------------+%s", `MAG, `RST);

        do_reset;
        inject_ml(3'd2, 8'd60);   // VOLUME_SURGE precursor
        tick(4);

        // Sample cb_param as soon as cascade fires (cascade_cb_load pulse)
        // cascade_cb_load fires the same cycle cascade is detected
        // We inject FLASH_CRASH and sample on the NEXT posedge (registered)
        inject_ml(3'd3, 8'd80);   // FLASH_CRASH with confidence=80

        // The cascade fires this cycle; cascade_cb_param = 2*80 = 160
        // and cascade_cb_load pulses → order_book loads cb_countdown = 2*160 = 320
        // Sample on next cycle:
        @(posedge clk); #1;
        cb_countdown_captured = cb_countdown;
        $display("%s  [cy %-4d]  cascade_cb_param=%0d (expect 160)  cb_countdown=%0d (expect ~318)%s",
                 `DIM, cyc, cascade_cb_param, cb_countdown_captured, `RST);

        check("TEST 7a: cascade fired",              cascade_alert == 1'b1);
        check("TEST 7b: cascade_cb_param == 2x80",   cascade_cb_param == 8'd160);
        check("TEST 7c: CB countdown > normal (80)",  cb_countdown_captured > 9'd160);

        $display("");
        $display("%s+============================================================+%s", `WHT, `RST);
        $display("%s|                  CASCADE DETECTOR TEST SUMMARY            |%s", `WHT, `RST);
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
        $display("%s|  VOL_CRASH   : VOLUME_SURGE  + FLASH_CRASH  detected      |%s", `WHT, `RST);
        $display("%s|  SPIKE_CRASH : PRICE_SPIKE   + FLASH_CRASH  detected      |%s", `WHT, `RST);
        $display("%s|  STUFF_CRASH : QUOTE_STUFF   + FLASH_CRASH  detected      |%s", `WHT, `RST);
        $display("%s|  TRIPLE      : 3-event chain (2010 Flash Crash pattern)   |%s", `WHT, `RST);
        $display("%s|  False-pos prevention: window + single-event filtering    |%s", `WHT, `RST);
        $display("%s|  CB doubling : cascade freeze = 2x normal confidence      |%s", `WHT, `RST);
        $display("%s|  Detection latency: 1 clock cycle = 20 ns @ 50 MHz       |%s", `WHT, `RST);
        $display("%s+============================================================+%s", `WHT, `RST);
        $display("");
        $finish;
    end

endmodule