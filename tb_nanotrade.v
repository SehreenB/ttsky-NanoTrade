/*
 * NanoTrade Stock Replay Testbench  (v2 -- SKY130 Enhanced)
 * ===========================================================
 * Replays real historical stock data through the NanoTrade chip.
 * Compatible with the v2 architecture:
 *   - 16->4->6 synthesizable MLP (no rom/ folder needed)
 *   - Live threshold config register
 *   - UART readback + heartbeat on uo_out[3]
 *
 * HOW TO COMPILE (once):
 *   Windows PowerShell:
 *     iverilog -g2005 -o sim_stock tb_nanotrade_stock.v tt_um_nanotrade.v ^
 *              order_book.v anomaly_detector.v feature_extractor.v ^
 *              ml_inference_engine.v
 *
 *   Mac / Linux / WSL:
 *     iverilog -g2005 -o sim_stock tb_nanotrade_stock.v tt_um_nanotrade.v \
 *              order_book.v anomaly_detector.v feature_extractor.v \
 *              ml_inference_engine.v
 *
 * HOW TO RUN (no recompile needed between stocks):
 *   vvp sim_stock +STIMULUS+stimuli/GME_20210128_stimulus.memh +TICKER+GME
 *   vvp sim_stock +STIMULUS+stimuli/SPY_20190604_stimulus.memh +TICKER+SPY
 *
 * THRESHOLD PRESETS (set at start of each run via config register):
 *   NORMAL (default) -- spike>20, flash>40
 *   Use +PRESET+0 (Quiet), +PRESET+1 (Normal), +PRESET+2 (Sensitive), +PRESET+3 (Demo)
 *
 * STIMULUS FILE FORMAT:
 *   One hex word per line: XXYY
 *     XX = ui_in[7:0]  (bits 7:6 = input type, bits 5:0 = data low)
 *     YY = uio_in[7:0] (bits 5:0 = data high)
 */

`timescale 1ns/1ps
`default_nettype none

module tb_nanotrade_stock;

    // -------------------------------------------------------------------
    // DUT
    // -------------------------------------------------------------------
    reg  [7:0] ui_in;
    wire [7:0] uo_out;
    reg  [7:0] uio_in;
    wire [7:0] uio_out;
    wire [7:0] uio_oe;
    reg        ena;
    reg        clk;
    reg        rst_n;

    tt_um_nanotrade dut (
        .ui_in(ui_in),   .uo_out(uo_out),
        .uio_in(uio_in), .uio_out(uio_out), .uio_oe(uio_oe),
        .ena(ena),        .clk(clk),          .rst_n(rst_n)
    );

    // -------------------------------------------------------------------
    // Clock: 50 MHz
    // -------------------------------------------------------------------
    initial clk = 0;
    always #10 clk = ~clk;

    // -------------------------------------------------------------------
    // Output decoding
    // -------------------------------------------------------------------
    wire        alert_flag     = uo_out[7];
    wire [2:0]  alert_priority = uo_out[6:4];
    wire [2:0]  alert_type     = uo_out[2:0];
    wire        ml_valid_out   = uio_out[7];
    wire [2:0]  ml_class_out   = uio_out[6:4];
    wire [3:0]  ml_conf_nibble = uio_out[3:0];

    // uo_out[3] is match_valid / UART TX / heartbeat -- check only when no UART
    // For stock replay we just track alert_flag and ML results

    // -------------------------------------------------------------------
    // Stimulus memory
    // -------------------------------------------------------------------
    reg [15:0] stimulus_mem [0:16383];
    integer    stim_size;
    integer    stim_idx;
    integer    i;

    // Plusarg strings
    reg [512*8-1:0] stimulus_file;
    reg [127:0]     ticker_name;
    integer         preset;

    // -------------------------------------------------------------------
    // Cycle counter
    // -------------------------------------------------------------------
    integer cycle_count;
    initial cycle_count = 0;
    always @(posedge clk) cycle_count = cycle_count + 1;

    // -------------------------------------------------------------------
    // ANSI colors
    // -------------------------------------------------------------------
    `define RESET   "\033[0m"
    `define BOLD    "\033[1m"
    `define RED     "\033[1;31m"
    `define YELLOW  "\033[1;33m"
    `define CYAN    "\033[1;36m"
    `define GREEN   "\033[1;32m"
    `define MAGENTA "\033[1;35m"
    `define WHITE   "\033[1;37m"

    // -------------------------------------------------------------------
    // Name functions
    // -------------------------------------------------------------------
    function [119:0] alert_name_full;
        input [2:0] t;
        case (t)
            3'd0: alert_name_full = "Price Spike    ";
            3'd1: alert_name_full = "Volume Dry     ";
            3'd2: alert_name_full = "Volume Surge   ";
            3'd3: alert_name_full = "Trade Velocity ";
            3'd4: alert_name_full = "Order Imbalance";
            3'd5: alert_name_full = "Spread Widening";
            3'd6: alert_name_full = "High Volatility";
            3'd7: alert_name_full = "FLASH CRASH !!!";
            default: alert_name_full = "None           ";
        endcase
    endfunction

    function [63:0] ml_class_name;
        input [2:0] c;
        case (c)
            3'd0: ml_class_name = "NORMAL  ";
            3'd1: ml_class_name = "SPIKE   ";
            3'd2: ml_class_name = "VOL_SRG ";
            3'd3: ml_class_name = "FLASH!! ";
            3'd4: ml_class_name = "IMBALANC";
            3'd5: ml_class_name = "QSTUFF  ";
            default: ml_class_name = "UNKNOWN ";
        endcase
    endfunction

    function [79:0] prio_bar;
        input [2:0] p;
        case (p)
            3'd0: prio_bar = "[.       ]";
            3'd1: prio_bar = "[=       ]";
            3'd2: prio_bar = "[==      ]";
            3'd3: prio_bar = "[===     ]";
            3'd4: prio_bar = "[====    ]";
            3'd5: prio_bar = "[=====   ]";
            3'd6: prio_bar = "[======  ]";
            3'd7: prio_bar = "[========]";
            default: prio_bar = "[        ]";
        endcase
    endfunction

    function [119:0] conf_bar;
        input [3:0] c;
        case (c)
            4'd0:  conf_bar = "[.            ]";
            4'd1:  conf_bar = "[==           ]";
            4'd2:  conf_bar = "[====         ]";
            4'd3:  conf_bar = "[======       ]";
            4'd4:  conf_bar = "[========     ]";
            4'd5:  conf_bar = "[==========   ]";
            4'd6:  conf_bar = "[============ ]";
            default: conf_bar = "[=============]";
        endcase
    endfunction

    // -------------------------------------------------------------------
    // Warmup gate -- suppress alerts during first 16 warmup bars
    // (16 bars x 16 cycles/bar = 256 stimulus cycles after replay starts)
    // -------------------------------------------------------------------
    integer warmup_end_cycle;
    reg     warmup_active;
    initial begin warmup_end_cycle = 0; warmup_active = 1; end

    // -------------------------------------------------------------------
    // Statistics
    // -------------------------------------------------------------------
    integer total_alerts;
    integer flash_crashes;
    integer ml_inferences;
    reg [7:0] rule_type_seen;
    reg [7:0] ml_class_seen;

    // -------------------------------------------------------------------
    // Alert monitor
    // -------------------------------------------------------------------
    reg       prev_alert;
    reg [2:0] prev_prio;
    reg [2:0] prev_type;
    initial begin prev_alert = 0; prev_prio = 0; prev_type = 0; end

    always @(posedge clk) begin

        // Update warmup gate each cycle
        if (warmup_end_cycle > 0 && cycle_count >= warmup_end_cycle)
            warmup_active = 0;

        if (alert_flag !== prev_alert ||
            alert_priority !== prev_prio ||
            alert_type !== prev_type) begin

            // Accumulate full bitmap (not just priority-encoded type)
        // This captures Volume Surge even when Flash Crash dominates output
        if (!warmup_active)
            rule_type_seen = rule_type_seen | dut.rule_alert_bitmap;

        if (alert_flag && !warmup_active) begin
                total_alerts = total_alerts + 1;
                if (alert_type == 3'd7) flash_crashes = flash_crashes + 1;

                if (alert_priority == 3'd7) begin
                    $display("%s+-----------------------------------------------------+%s", `RED, `RESET);
                    $display("%s|  !! CRITICAL  cy=%-5d  %-15s            |%s",
                             `RED, cycle_count, alert_name_full(alert_type), `RESET);
                    $display("%s|  Priority: %s  SEVERITY: CRITICAL              |%s",
                             `RED, prio_bar(alert_priority), `RESET);
                    $display("%s+-----------------------------------------------------+%s", `RED, `RESET);
                end else if (alert_priority >= 3'd4) begin
                    $display("%s+-----------------------------------------------------+%s", `YELLOW, `RESET);
                    $display("%s|  ALERT  cy=%-5d  %-15s                      |%s",
                             `YELLOW, cycle_count, alert_name_full(alert_type), `RESET);
                    $display("%s|  Priority: %s  priority=%0d  SEVERITY: HIGH     |%s",
                             `YELLOW, prio_bar(alert_priority), alert_priority, `RESET);
                    $display("%s+-----------------------------------------------------+%s", `YELLOW, `RESET);
                end else begin
                    $display("%s  [cy %-5d]  ALERT: %-15s  priority=%0d  %s%s",
                             `CYAN, cycle_count, alert_name_full(alert_type),
                             alert_priority, prio_bar(alert_priority), `RESET);
                end

            end else if (!warmup_active) begin
                $display("%s  [cy %-5d]  Alert cleared%s", `GREEN, cycle_count, `RESET);
            end

            prev_alert <= alert_flag;
            prev_prio  <= alert_priority;
            prev_type  <= alert_type;
        end

        if (ml_valid_out) begin
            ml_inferences = ml_inferences + 1;
            ml_class_seen[ml_class_out] = 1'b1;
            $display("");
            $display("%s  +----------------------------------------------------+%s", `MAGENTA, `RESET);
            $display("%s  |          ML INFERENCE ENGINE RESULT                |%s", `MAGENTA, `RESET);
            $display("%s  |----------------------------------------------------|%s", `MAGENTA, `RESET);
            $display("%s  |  Cycle      : %-5d                                 |%s",
                     `MAGENTA, cycle_count, `RESET);
            $display("%s  |  Class      : %-8s  (code %0d)                   |%s",
                     `MAGENTA, ml_class_name(ml_class_out), ml_class_out, `RESET);
            $display("%s  |  Confidence : %s  (%0d/15)              |%s",
                     `MAGENTA, conf_bar(ml_conf_nibble), ml_conf_nibble, `RESET);
            $display("%s  |  Latency    : 4-cycle pipeline + 256-cy feature win|%s", `MAGENTA, `RESET);
            $display("%s  +----------------------------------------------------+%s", `MAGENTA, `RESET);
            $display("");
        end
    end

    // -------------------------------------------------------------------
    // MAIN
    // -------------------------------------------------------------------
    initial begin
        total_alerts   = 0;
        flash_crashes  = 0;
        ml_inferences  = 0;
        rule_type_seen = 8'd0;
        ml_class_seen  = 8'd0;

        // Read plusargs
        if (!$value$plusargs("STIMULUS+%s", stimulus_file)) begin
            $display("ERROR: No stimulus file.");
            $display("Usage: vvp sim_stock +STIMULUS+stimuli/GME_20210128_stimulus.memh +TICKER+GME");
            $finish;
        end
        if (!$value$plusargs("TICKER+%s", ticker_name))
            ticker_name = "UNKNOWN ";
        if (!$value$plusargs("PRESET+%d", preset))
            preset = 1;  // default = Normal

        // Load stimulus
        $readmemh(stimulus_file, stimulus_mem);
        stim_size = 0;
        for (i = 0; i < 16384; i = i + 1)
            if (stimulus_mem[i] !== 16'hxxxx && stimulus_mem[i] !== 16'hFFFF)
                stim_size = i + 1;

        // Banner
        $display("");
        $display("%s+============================================================+%s", `BOLD, `RESET);
        $display("%s|     NanoTrade Stock Replay  --  IEEE UofT ASIC             |%s", `BOLD, `RESET);
        $display("%s|     SKY130  50 MHz  |  2x2 TinyTapeout tiles               |%s", `BOLD, `RESET);
        $display("%s+============================================================+%s", `BOLD, `RESET);
        $display("");
        $display("  Ticker   : %s", ticker_name);
        $display("  Stimulus : %s", stimulus_file);
        $display("  Cycles   : %0d", stim_size);
        $display("  Preset   : %0d  (0=Quiet 1=Normal 2=Sensitive 3=Demo)", preset);
        $display("");

        // Reset
        ena = 1; ui_in = 8'h00; uio_in = 8'h00; rst_n = 0;
        repeat(5) @(posedge clk);
        rst_n = 1; #1;
        $display("%s  [cy %-5d]  Reset released -- system online%s",
                 `GREEN, cycle_count, `RESET);

        // Set threshold preset via config register
        // ui_in[7:6]=00 (price/config type) + uio_in[7]=1 (config strobe)
        ui_in  = 8'b00_000000;
        uio_in = {1'b1, 5'b00000, preset[1:0]};
        @(posedge clk); #1;
        ui_in  = 8'h00;
        uio_in = 8'h00;
        @(posedge clk); #1;
        $display("%s  [cy %-5d]  Threshold preset %0d applied%s",
                 `CYAN, cycle_count, preset, `RESET);

        // Replay stimulus
        warmup_end_cycle = cycle_count + 512 + 5;  // suppress alerts during 32 warmup bars (32x16=512)
        $display("%s  [cy %-5d]  Replaying market data stream ...%s",
                 `GREEN, cycle_count, `RESET);
        $display("  ---------------------------------------------------");

        for (stim_idx = 0; stim_idx < stim_size; stim_idx = stim_idx + 1) begin
            ui_in  = stimulus_mem[stim_idx][15:8];
            uio_in = stimulus_mem[stim_idx][7:0];
            @(posedge clk); #1;
        end

        // Drain ML pipeline -- hold last stimulus value to avoid price=0 false crash
        ui_in = stimulus_mem[stim_size-1][15:8];
        uio_in = stimulus_mem[stim_size-1][7:0];
        $display("");
        $display("%s  [cy %-5d]  Stimulus done -- draining ML pipeline ...%s",
                 `GREEN, cycle_count, `RESET);
        repeat(300) @(posedge clk);

        // Summary
        $display("");
        $display("%s+============================================================+%s", `BOLD, `RESET);
        $display("%s|                    SIMULATION SUMMARY                      |%s", `BOLD, `RESET);
        $display("%s+============================================================+%s", `BOLD, `RESET);
        $display("%s|  Ticker             : %-8s                              |%s",
                 `BOLD, ticker_name, `RESET);
        $display("%s|  Total Cycles       : %-5d                                 |%s",
                 `BOLD, cycle_count, `RESET);
        $display("%s|  Rule Alerts Fired  : %-5d                                 |%s",
                 `BOLD, total_alerts, `RESET);
        $display("%s|  Flash Crashes Det. : %-5d  (critical severity)            |%s",
                 `BOLD, flash_crashes, `RESET);
        $display("%s|  ML Inferences      : %-5d  (256-cy window + 4-cy pipe)    |%s",
                 `BOLD, ml_inferences, `RESET);
        $display("%s+============================================================+%s", `BOLD, `RESET);

        $display("");
        $display("  Rule detectors triggered:");
        if (rule_type_seen[7]) $display("    [7] FLASH CRASH       *** CRITICAL ***");
        if (rule_type_seen[6]) $display("    [6] High Volatility");
        if (rule_type_seen[5]) $display("    [5] Spread Widening");
        if (rule_type_seen[4]) $display("    [4] Order Imbalance");
        if (rule_type_seen[3]) $display("    [3] Trade Velocity");
        if (rule_type_seen[2]) $display("    [2] Volume Surge");
        if (rule_type_seen[1]) $display("    [1] Volume Dry");
        if (rule_type_seen[0]) $display("    [0] Price Spike");
        if (rule_type_seen == 8'd0) $display("    (none -- market was quiet)");

        $display("");
        $display("  ML classifications:");
        if (ml_class_seen[3]) $display("    [3] FLASH CRASH       *** CRITICAL ***");
        if (ml_class_seen[1]) $display("    [1] PRICE SPIKE");
        if (ml_class_seen[2]) $display("    [2] VOLUME SURGE");
        if (ml_class_seen[4]) $display("    [4] ORDER IMBALANCE");
        if (ml_class_seen[5]) $display("    [5] QUOTE STUFFING");
        if (ml_class_seen[0]) $display("    [0] NORMAL");
        if (ml_class_seen == 8'd0) $display("    (ML pipeline did not fire)");

        $display("");
        $display("  [FIRED_RULE_MASK] %08b", rule_type_seen);
        $display("  [FIRED_ML_MASK]   %08b", ml_class_seen);
        $display("");

        $finish;
    end

    initial begin
        $dumpfile("nanotrade_stock.vcd");
        $dumpvars(0, tb_nanotrade_stock);
    end

    initial begin
        #100_000_000;
        $display("TIMEOUT");
        $finish;
    end

endmodule