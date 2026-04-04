/*
 * NanoTrade Stock Testbench
 * ==========================
 * Replays real (or synthetic) historical stock data through the NanoTrade chip
 * and checks that the right alerts fire at the right times.
 *
 * HOW IT WORKS:
 *   1. Python (generate_stimuli.py) downloads stock data and encodes it
 *      into a .memh file where each line = one clock cycle of chip input.
 *   2. This testbench reads that file and feeds each line to the chip,
 *      one per clock cycle, exactly like a real market data stream.
 *   3. Every time an alert fires, it's logged with the cycle number.
 *   4. At the end, check_results.py compares the log against the golden file.
 *
 * HOW TO COMPILE & RUN:
 *   # Compile (once)
 *   iverilog -o sim_nanotrade tb_nanotrade_stock.v tt_um_nanotrade.v \
 *            order_book.v anomaly_detector.v feature_extractor.v \
 *            ml_inference_engine.v
 *
 *   # Run one stock scenario (set env vars before vvp):
 *   STIMULUS=stimuli/GME_20210128_stimulus.memh \
 *   GOLDEN=stimuli/GME_20210128_golden.txt \
 *   TICKER=GME \
 *   vvp sim_nanotrade
 *
 *   # Or run all 16 stocks at once:
 *   bash stimuli/run_all_scenarios.sh
 *
 * STIMULUS FILE FORMAT:
 *   One hex word per line: XXYY
 *     XX = ui_in[7:0]   (bits 7:6 = input type, bits 5:0 = data low)
 *     YY = uio_in[7:0]  (bits 5:0 = data high)
 *
 * OUTPUT:
 *   [cy N] RULE ALERT --> FLASH!!!  priority=7
 *   [cy N] *** ML RESULT: class=FLASH!  conf=200 ***
 *   [cy N] Order match: price=0x64
 *   [RESULT] PASS: 3/3 expected alerts detected
 *
 * PIN MAPPING REMINDER:
 *   ui_in[7:6]  = input type: 00=price, 01=vol, 10=buy, 11=sell
 *   ui_in[5:0]  = data[5:0]  (low 6 bits)
 *   uio_in[5:0] = data[11:6] (high 6 bits)
 *   uo_out[7]   = global alert flag
 *   uo_out[6:4] = alert priority (7=critical)
 *   uo_out[3]   = order match valid
 *   uo_out[2:0] = alert type code
 *   uio_out[7]  = ML valid pulse
 *   uio_out[6:4]= ML class
 *   uio_out[3:0]= ML confidence nibble
 */

`timescale 1ns/1ps
`default_nettype none

module tb_nanotrade_stock;

    // ─────────────────────────────────────────────────────────────────────────
    // DUT ports
    // ─────────────────────────────────────────────────────────────────────────
    reg  [7:0] ui_in;
    wire [7:0] uo_out;
    reg  [7:0] uio_in;
    wire [7:0] uio_out;
    wire [7:0] uio_oe;
    reg        ena;
    reg        clk;
    reg        rst_n;

    tt_um_nanotrade dut (
        .ui_in  (ui_in),
        .uo_out (uo_out),
        .uio_in (uio_in),
        .uio_out(uio_out),
        .uio_oe (uio_oe),
        .ena    (ena),
        .clk    (clk),
        .rst_n  (rst_n)
    );

    // ─────────────────────────────────────────────────────────────────────────
    // Clock: 50 MHz → 20 ns period
    // ─────────────────────────────────────────────────────────────────────────
    initial clk = 0;
    always #10 clk = ~clk;

    // ─────────────────────────────────────────────────────────────────────────
    // Output signal aliases — makes the code below easier to read
    // ─────────────────────────────────────────────────────────────────────────
    wire        alert_flag     = uo_out[7];
    wire [2:0]  alert_priority = uo_out[6:4];
    wire        match_valid    = uo_out[3];
    wire [2:0]  alert_type     = uo_out[2:0];
    wire        ml_valid_out   = uio_out[7];
    wire [2:0]  ml_class_out   = uio_out[6:4];
    wire [3:0]  ml_conf_out    = uio_out[3:0];

    // ─────────────────────────────────────────────────────────────────────────
    // Stimulus memory
    // Each entry holds one cycle: bits [15:8] = ui_in, bits [7:0] = uio_in
    // Maximum 16384 cycles (covers ~1000 bars × 16 cycles/bar)
    // ─────────────────────────────────────────────────────────────────────────
    reg [15:0] stimulus_mem [0:16383];
    integer    stim_size;     // actual number of lines loaded
    integer    stim_idx;      // current position in stimulus

    // ─────────────────────────────────────────────────────────────────────────
    // Cycle counter
    // ─────────────────────────────────────────────────────────────────────────
    integer cycle_count;
    initial cycle_count = 0;
    always @(posedge clk) cycle_count = cycle_count + 1;

    // ─────────────────────────────────────────────────────────────────────────
    // Alert tracking — for final pass/fail counting
    // ─────────────────────────────────────────────────────────────────────────
    integer rule_alerts_fired;    // count of distinct rule alert events
    integer ml_alerts_fired;      // count of ML non-normal results
    integer matches_fired;        // count of order matches

    // Track which alert TYPES have fired (bitmask, indexed by alert_type code)
    reg [7:0]  rule_type_seen;   // bit[i] = alert type i has fired at least once
    reg [7:0]  ml_class_seen;    // bit[i] = ML class i has fired at least once

    // For detecting changes
    reg        prev_alert;
    reg [2:0]  prev_prio;
    reg [2:0]  prev_type;

    // ─────────────────────────────────────────────────────────────────────────
    // Human-readable name functions
    // ─────────────────────────────────────────────────────────────────────────
    function [63:0] alert_name;
        input [2:0] t;
        case (t)
            3'd0: alert_name = "SPIKE   ";
            3'd1: alert_name = "VOL_DRY ";
            3'd2: alert_name = "VOL_SRGE";
            3'd3: alert_name = "VELOCITY";
            3'd4: alert_name = "IMBALANC";
            3'd5: alert_name = "SPREAD  ";
            3'd6: alert_name = "VOLATIL ";
            3'd7: alert_name = "FLASH!!!";
            default: alert_name = "NONE    ";
        endcase
    endfunction

    function [47:0] ml_name;
        input [2:0] c;
        case (c)
            3'd0: ml_name = "NORMAL";
            3'd1: ml_name = "SPIKE ";
            3'd2: ml_name = "VOLSRG";
            3'd3: ml_name = "FLASH!";
            3'd4: ml_name = "IMBAL ";
            3'd5: ml_name = "QSTUFF";
            default: ml_name = "??????";
        endcase
    endfunction

    function [15:0] input_type_name;
        input [1:0] t;
        case (t)
            2'b00: input_type_name = "PRICE ";
            2'b01: input_type_name = "VOL   ";
            2'b10: input_type_name = "BUY   ";
            2'b11: input_type_name = "SELL  ";
        endcase
    endfunction

    // ─────────────────────────────────────────────────────────────────────────
    // Alert monitor — fires on every clock edge, logs changes
    // ─────────────────────────────────────────────────────────────────────────
    always @(posedge clk) begin
        // Rule-based alert: print when state changes
        if (alert_flag !== prev_alert ||
            alert_priority !== prev_prio ||
            alert_type !== prev_type) begin

            if (alert_flag) begin
                $display("[cy %0d] RULE ALERT --> %s  priority=%0d  (bar ~%0d)",
                         cycle_count,
                         alert_name(alert_type),
                         alert_priority,
                         (cycle_count - 32) / 16);  // rough bar number
                rule_alerts_fired = rule_alerts_fired + 1;
                rule_type_seen[alert_type] = 1'b1;
            end else if (prev_alert) begin
                $display("[cy %0d] Alert cleared", cycle_count);
            end

            prev_alert <= alert_flag;
            prev_prio  <= alert_priority;
            prev_type  <= alert_type;
        end

        // ML result: print whenever ml_valid pulses
        if (ml_valid_out) begin
            $display("[cy %0d] *** ML RESULT: class=%s  conf=%0d  (bar ~%0d) ***",
                     cycle_count,
                     ml_name(ml_class_out),
                     {ml_conf_out, 4'b1111},
                     (cycle_count - 32) / 16);
            ml_alerts_fired = ml_alerts_fired + 1;
            ml_class_seen[ml_class_out] = 1'b1;
        end

        // Order match: print when a buy meets a sell
        if (match_valid && !ml_valid_out) begin
            $display("[cy %0d] Order match: price=0x%02h",
                     cycle_count, uio_out);
            matches_fired = matches_fired + 1;
        end
    end

    // ─────────────────────────────────────────────────────────────────────────
    // MAIN TEST SEQUENCE
    // ─────────────────────────────────────────────────────────────────────────
    integer i;

    initial begin

        // ── Initialise counters ─────────────────────────────────────────────
        rule_alerts_fired = 0;
        ml_alerts_fired   = 0;
        matches_fired     = 0;
        rule_type_seen    = 8'd0;
        ml_class_seen     = 8'd0;
        prev_alert = 0; prev_prio = 0; prev_type = 0;

        // ── Load stimulus file ──────────────────────────────────────────────
        // The Python pipeline sets the STIMULUS env var before calling vvp.
        // We use a fixed path as default if no env var is set.
        //
        // Verilog note: $readmemh counts lines automatically.
        // We load into the full array and then scan for the last valid entry.
        $readmemh(`STIMULUS_FILE, stimulus_mem);

        // Count how many lines were loaded (stop at first all-F entry = unloaded)
        stim_size = 0;
        for (i = 0; i < 16384; i = i + 1) begin
            if (stimulus_mem[i] !== 16'hxxxx && stimulus_mem[i] !== 16'hFFFF)
                stim_size = i + 1;
        end

        // ── Banner ──────────────────────────────────────────────────────────
        $display("╔══════════════════════════════════════════════════════╗");
        $display("║     NanoTrade Stock Testbench                        ║");
        $display("║     IEEE UofT ASIC Team                              ║");
        $display("╚══════════════════════════════════════════════════════╝");
        $display("");
        $display("Ticker  : %s", `TICKER_NAME);
        $display("Stimulus: %s", `STIMULUS_FILE);
        $display("Cycles  : %0d", stim_size);
        $display("");

        // ── Reset sequence ──────────────────────────────────────────────────
        ena = 1; ui_in = 8'h00; uio_in = 8'h00; rst_n = 0;
        repeat(5) @(posedge clk);
        rst_n = 1; #1;
        $display("[cy %0d] Reset released — replaying market data stream", cycle_count);
        $display("─────────────────────────────────────────────────────────");

        // ── Replay stimulus ─────────────────────────────────────────────────
        // Drive one stimulus entry per clock cycle.
        // Each entry encodes: type (bits 15:14 of ui_in), price/vol/qty.
        for (stim_idx = 0; stim_idx < stim_size; stim_idx = stim_idx + 1) begin
            ui_in  = stimulus_mem[stim_idx][15:8];   // upper byte = ui_in
            uio_in = stimulus_mem[stim_idx][7:0];    // lower byte = uio_in
            @(posedge clk); #1;
        end

        // ── Drain: let ML pipeline finish its last 256-cycle window ─────────
        ui_in = 8'h00; uio_in = 8'h00;
        $display("");
        $display("[cy %0d] Stimulus done — draining ML pipeline (256 cycles)...", cycle_count);
        repeat(300) @(posedge clk);

        // ── Final report ────────────────────────────────────────────────────
        $display("");
        $display("╔══════════════════════════════════════════════════════╗");
        $display("║     SIMULATION COMPLETE — %s %-20s ║", `TICKER_NAME, "");
        $display("╚══════════════════════════════════════════════════════╝");
        $display("");
        $display("Total cycles run  : %0d", cycle_count);
        $display("Rule alerts fired : %0d distinct events", rule_alerts_fired);
        $display("ML inferences     : %0d results", ml_alerts_fired);
        $display("Order matches     : %0d", matches_fired);
        $display("");

        // Which rule alert types fired
        $display("Rule detectors triggered:");
        if (rule_type_seen[7]) $display("  [7] FLASH CRASH    *** CRITICAL ***");
        if (rule_type_seen[6]) $display("  [6] VOLATILITY");
        if (rule_type_seen[5]) $display("  [5] SPREAD WIDENING");
        if (rule_type_seen[4]) $display("  [4] ORDER IMBALANCE");
        if (rule_type_seen[3]) $display("  [3] TRADE VELOCITY");
        if (rule_type_seen[2]) $display("  [2] VOLUME SURGE");
        if (rule_type_seen[1]) $display("  [1] VOLUME DRY");
        if (rule_type_seen[0]) $display("  [0] PRICE SPIKE");
        if (rule_type_seen == 8'd0) $display("  (none — market was quiet)");

        // Which ML classes fired
        $display("");
        $display("ML classifications seen:");
        if (ml_class_seen[0]) $display("  [0] NORMAL");
        if (ml_class_seen[3]) $display("  [3] FLASH CRASH  *** CRITICAL ***");
        if (ml_class_seen[1]) $display("  [1] PRICE SPIKE");
        if (ml_class_seen[2]) $display("  [2] VOLUME SURGE");
        if (ml_class_seen[4]) $display("  [4] ORDER IMBALANCE");
        if (ml_class_seen[5]) $display("  [5] QUOTE STUFFING");
        if (ml_class_seen == 8'd0) $display("  (ML pipeline did not fire in this window)");

        $display("");
        $display("─────────────────────────────────────────────────────────");

        // Encode rule_type_seen and ml_class_seen into exit code for checker
        // Format for check_results.py to parse:
        $display("[FIRED_RULE_MASK] %08b", rule_type_seen);
        $display("[FIRED_ML_MASK]   %08b", ml_class_seen);

        $display("─────────────────────────────────────────────────────────");
        $finish;
    end

    // Timeout safety net — 50 million cycles max
    initial begin
        #1_000_000_000;  // 1 second of sim time
        $display("TIMEOUT — simulation exceeded time limit");
        $finish;
    end

    // Optional VCD waveform dump (comment out to speed up batch runs)
    initial begin
        $dumpfile("nanotrade_stock.vcd");
        $dumpvars(0, tb_nanotrade_stock);
    end

endmodule
