/*
 * NanoTrade Stock Testbench
 * ==========================
 * Replays real historical stock data through the NanoTrade chip.
 *
 * HOW TO COMPILE & RUN (Windows PowerShell):
 *
 *   # Step 1 - Compile once
 *   iverilog -o sim_nanotrade tb_nanotrade_stock.v tt_um_nanotrade.v ^
 *            order_book.v anomaly_detector.v feature_extractor.v ^
 *            ml_inference_engine.v
 *
 *   # Step 2 - Run a stock (pass file via +plusargs, no recompile needed)
 *   vvp sim_nanotrade +STIMULUS+stimuli/GME_20210128_stimulus.memh +TICKER+GME
 *
 * STIMULUS FILE FORMAT:
 *   One hex word per line: XXYY
 *     XX = ui_in[7:0]   (bits 7:6 = input type, bits 5:0 = data low)
 *     YY = uio_in[7:0]  (bits 5:0 = data high)
 */

`timescale 1ns/1ps
`default_nettype none

module tb_nanotrade_stock;

    // -------------------------------------------------------------------------
    // DUT ports
    // -------------------------------------------------------------------------
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

    // -------------------------------------------------------------------------
    // Clock: 50 MHz -> 20 ns period
    // -------------------------------------------------------------------------
    initial clk = 0;
    always #10 clk = ~clk;

    // -------------------------------------------------------------------------
    // Output signal aliases
    // -------------------------------------------------------------------------
    wire        alert_flag     = uo_out[7];
    wire [2:0]  alert_priority = uo_out[6:4];
    wire        match_valid    = uo_out[3];
    wire [2:0]  alert_type     = uo_out[2:0];
    wire        ml_valid_out   = uio_out[7];
    wire [2:0]  ml_class_out   = uio_out[6:4];
    wire [3:0]  ml_conf_out    = uio_out[3:0];

    // -------------------------------------------------------------------------
    // Stimulus memory (max 16384 cycles)
    // -------------------------------------------------------------------------
    reg [15:0] stimulus_mem [0:16383];
    integer    stim_size;
    integer    stim_idx;

    // Plusargs strings
    reg [255:0] stimulus_file;
    reg [63:0]  ticker_name;

    // -------------------------------------------------------------------------
    // Cycle counter
    // -------------------------------------------------------------------------
    integer cycle_count;
    initial cycle_count = 0;
    always @(posedge clk) cycle_count = cycle_count + 1;

    // -------------------------------------------------------------------------
    // Alert tracking
    // -------------------------------------------------------------------------
    integer rule_alerts_fired;
    integer ml_alerts_fired;
    integer matches_fired;
    reg [7:0]  rule_type_seen;
    reg [7:0]  ml_class_seen;
    reg        prev_alert;
    reg [2:0]  prev_prio;
    reg [2:0]  prev_type;

    // -------------------------------------------------------------------------
    // Name functions
    // -------------------------------------------------------------------------
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

    // -------------------------------------------------------------------------
    // Alert monitor
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (alert_flag !== prev_alert ||
            alert_priority !== prev_prio ||
            alert_type !== prev_type) begin

            if (alert_flag) begin
                $display("[cy %0d] RULE ALERT --> %s  priority=%0d  (bar ~%0d)",
                         cycle_count,
                         alert_name(alert_type),
                         alert_priority,
                         (cycle_count - 32) / 16);
                rule_alerts_fired = rule_alerts_fired + 1;
                rule_type_seen[alert_type] = 1'b1;
            end else if (prev_alert) begin
                $display("[cy %0d] Alert cleared", cycle_count);
            end

            prev_alert <= alert_flag;
            prev_prio  <= alert_priority;
            prev_type  <= alert_type;
        end

        if (ml_valid_out) begin
            $display("[cy %0d] *** ML RESULT: class=%s  conf=%0d  (bar ~%0d) ***",
                     cycle_count,
                     ml_name(ml_class_out),
                     {ml_conf_out, 4'b1111},
                     (cycle_count - 32) / 16);
            ml_alerts_fired = ml_alerts_fired + 1;
            ml_class_seen[ml_class_out] = 1'b1;
        end

        if (match_valid && !ml_valid_out) begin
            $display("[cy %0d] Order match: price=0x%02h",
                     cycle_count, uio_out);
            matches_fired = matches_fired + 1;
        end
    end

    // -------------------------------------------------------------------------
    // MAIN TEST SEQUENCE
    // -------------------------------------------------------------------------
    integer i;

    initial begin

        rule_alerts_fired = 0;
        ml_alerts_fired   = 0;
        matches_fired     = 0;
        rule_type_seen    = 8'd0;
        ml_class_seen     = 8'd0;
        prev_alert = 0; prev_prio = 0; prev_type = 0;

        // Read plusargs - passed as: +STIMULUS+path/to/file.memh +TICKER+GME
        if (!$value$plusargs("STIMULUS+%s", stimulus_file)) begin
            $display("ERROR: No stimulus file specified.");
            $display("Usage: vvp sim_nanotrade +STIMULUS+stimuli/GME_20210128_stimulus.memh +TICKER+GME");
            $finish;
        end
        if (!$value$plusargs("TICKER+%s", ticker_name))
            ticker_name = "UNKNOWN";

        // Load stimulus
        $readmemh(stimulus_file, stimulus_mem);

        // Count loaded lines
        stim_size = 0;
        for (i = 0; i < 16384; i = i + 1) begin
            if (stimulus_mem[i] !== 16'hxxxx && stimulus_mem[i] !== 16'hFFFF)
                stim_size = i + 1;
        end

        // Banner
        $display("===========================================================");
        $display("  NanoTrade Stock Testbench  |  IEEE UofT ASIC Team");
        $display("===========================================================");
        $display("");
        $display("Ticker  : %s", ticker_name);
        $display("Stimulus: %s", stimulus_file);
        $display("Cycles  : %0d", stim_size);
        $display("");

        // Reset
        ena = 1; ui_in = 8'h00; uio_in = 8'h00; rst_n = 0;
        repeat(5) @(posedge clk);
        rst_n = 1; #1;
        $display("[cy %0d] Reset released - replaying market data stream", cycle_count);
        $display("---------------------------------------------------------");

        // Replay
        for (stim_idx = 0; stim_idx < stim_size; stim_idx = stim_idx + 1) begin
            ui_in  = stimulus_mem[stim_idx][15:8];
            uio_in = stimulus_mem[stim_idx][7:0];
            @(posedge clk); #1;
        end

        // Drain ML pipeline
        ui_in = 8'h00; uio_in = 8'h00;
        $display("");
        $display("[cy %0d] Stimulus done - draining ML pipeline...", cycle_count);
        repeat(300) @(posedge clk);

        // Final report
        $display("");
        $display("===========================================================");
        $display("  SIMULATION COMPLETE");
        $display("===========================================================");
        $display("");
        $display("Total cycles run  : %0d", cycle_count);
        $display("Rule alerts fired : %0d distinct events", rule_alerts_fired);
        $display("ML inferences     : %0d results", ml_alerts_fired);
        $display("Order matches     : %0d", matches_fired);
        $display("");

        $display("Rule detectors triggered:");
        if (rule_type_seen[7]) $display("  [7] FLASH CRASH    *** CRITICAL ***");
        if (rule_type_seen[6]) $display("  [6] VOLATILITY");
        if (rule_type_seen[5]) $display("  [5] SPREAD WIDENING");
        if (rule_type_seen[4]) $display("  [4] ORDER IMBALANCE");
        if (rule_type_seen[3]) $display("  [3] TRADE VELOCITY");
        if (rule_type_seen[2]) $display("  [2] VOLUME SURGE");
        if (rule_type_seen[1]) $display("  [1] VOLUME DRY");
        if (rule_type_seen[0]) $display("  [0] PRICE SPIKE");
        if (rule_type_seen == 8'd0) $display("  (none - market was quiet)");

        $display("");
        $display("ML classifications seen:");
        if (ml_class_seen[3]) $display("  [3] FLASH CRASH  *** CRITICAL ***");
        if (ml_class_seen[1]) $display("  [1] PRICE SPIKE");
        if (ml_class_seen[2]) $display("  [2] VOLUME SURGE");
        if (ml_class_seen[4]) $display("  [4] ORDER IMBALANCE");
        if (ml_class_seen[5]) $display("  [5] QUOTE STUFFING");
        if (ml_class_seen[0]) $display("  [0] NORMAL");
        if (ml_class_seen == 8'd0) $display("  (ML pipeline did not fire)");

        $display("");
        $display("---------------------------------------------------------");
        $display("[FIRED_RULE_MASK] %08b", rule_type_seen);
        $display("[FIRED_ML_MASK]   %08b", ml_class_seen);
        $display("---------------------------------------------------------");
        $finish;
    end

    initial begin
        #1_000_000_000;
        $display("TIMEOUT");
        $finish;
    end

    initial begin
        $dumpfile("nanotrade_stock.vcd");
        $dumpvars(0, tb_nanotrade_stock);
    end

endmodule
