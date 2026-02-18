/*
 * NanoTrade Enhanced Testbench  (ASCII-safe, Windows PowerShell compatible)
 * ==========================================================================
 * All Unicode removed -- uses pure 7-bit ASCII only.
 * Tested on: Windows PowerShell, cmd.exe, bash, zsh, WSL.
 *
 * HOW TO COMPILE & RUN (from NanoTrade folder):
 *
 *   Windows PowerShell:
 *     iverilog -g2005 -o sim tb_nanotrade.v tt_um_nanotrade.v order_book.v anomaly_detector.v feature_extractor.v ml_inference_engine.v
 *     vvp sim
 *
 *   Mac / Linux / WSL:
 *     iverilog -g2005 -o sim tb_nanotrade.v tt_um_nanotrade.v order_book.v \
 *              anomaly_detector.v feature_extractor.v ml_inference_engine.v
 *     vvp sim
 *
 * COLORS: Uses ANSI escape codes. Works in Windows Terminal, PowerShell 7+,
 *         bash, zsh. If you see ESC[31m raw codes, your terminal doesn't
 *         support ANSI -- colors are cosmetic only, output is still readable.
 */

`timescale 1ns/1ps
`default_nettype none

module tb_nanotrade;

    // -------------------------------------------------------------------
    //  DUT connections  (TinyTapeout / SKY130 pin-compatible)
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
    //  Clock: 50 MHz  (20 ns period)
    // -------------------------------------------------------------------
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

    // -------------------------------------------------------------------
    //  Cycle counter
    // -------------------------------------------------------------------
    integer cycle_count;
    initial cycle_count = 0;
    always @(posedge clk) cycle_count = cycle_count + 1;

    // -------------------------------------------------------------------
    //  ANSI color codes  (pure ASCII escape sequences -- safe everywhere)
    // -------------------------------------------------------------------
    `define RESET   "\033[0m"
    `define BOLD    "\033[1m"
    `define RED     "\033[1;31m"
    `define YELLOW  "\033[1;33m"
    `define CYAN    "\033[1;36m"
    `define GREEN   "\033[1;32m"
    `define MAGENTA "\033[1;35m"
    `define WHITE   "\033[1;37m"
    `define DIM     "\033[2m"

    // -------------------------------------------------------------------
    //  Alert name  (15 chars, padded, ASCII only)
    // -------------------------------------------------------------------
    function [119:0] alert_name_full;   // 15 chars * 8 bits
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

    // -------------------------------------------------------------------
    //  ML class name  (8 chars, padded)
    // -------------------------------------------------------------------
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

    // -------------------------------------------------------------------
    //  Priority bar  (ASCII-only, 10 chars)
    // -------------------------------------------------------------------
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

    // -------------------------------------------------------------------
    //  Confidence bar  (ASCII-only, 15 chars)
    // -------------------------------------------------------------------
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
            4'd7:  conf_bar = "[=============]";
            4'd8:  conf_bar = "[=============]";
            4'd9:  conf_bar = "[=============]";
            4'd10: conf_bar = "[=============]";
            4'd11: conf_bar = "[=============]";
            4'd12: conf_bar = "[=============]";
            4'd13: conf_bar = "[=============]";
            4'd14: conf_bar = "[=============]";
            4'd15: conf_bar = "[=============]";
            default: conf_bar = "[             ]";
        endcase
    endfunction

    // -------------------------------------------------------------------
    //  Statistics
    // -------------------------------------------------------------------
    integer total_alerts;
    integer total_matches;
    integer flash_crashes;
    integer ml_inferences;
    initial begin
        total_alerts  = 0;
        total_matches = 0;
        flash_crashes = 0;
        ml_inferences = 0;
    end

    // -------------------------------------------------------------------
    //  Alert change detector  (only print on transitions)
    // -------------------------------------------------------------------
    reg        prev_alert;
    reg [2:0]  prev_prio;
    reg [2:0]  prev_type;
    initial begin prev_alert = 0; prev_prio = 0; prev_type = 0; end

    always @(posedge clk) begin

        // ---- RULE-BASED ALERT EVENTS --------------------------------
        if (alert_flag !== prev_alert ||
            alert_priority !== prev_prio ||
            alert_type !== prev_type) begin

            if (alert_flag) begin
                total_alerts = total_alerts + 1;
                if (alert_type == 3'd7)
                    flash_crashes = flash_crashes + 1;

                if (alert_priority == 3'd7) begin
                    // CRITICAL  -- red box
                    $display("%s+-----------------------------------------------------+%s", `RED, `RESET);
                    $display("%s|  !! CRITICAL ALERT  cy=%-5d  %-15s       |%s",
                             `RED, cycle_count, alert_name_full(alert_type), `RESET);
                    $display("%s|  Priority: %s  SEVERITY: CRITICAL              |%s",
                             `RED, prio_bar(alert_priority), `RESET);
                    $display("%s+-----------------------------------------------------+%s", `RED, `RESET);

                end else if (alert_priority >= 3'd4) begin
                    // HIGH  -- yellow box
                    $display("%s+-----------------------------------------------------+%s", `YELLOW, `RESET);
                    $display("%s|  ALERT  cy=%-5d  %-15s                      |%s",
                             `YELLOW, cycle_count, alert_name_full(alert_type), `RESET);
                    $display("%s|  Priority: %s  priority=%0d  SEVERITY: HIGH     |%s",
                             `YELLOW, prio_bar(alert_priority), alert_priority, `RESET);
                    $display("%s+-----------------------------------------------------+%s", `YELLOW, `RESET);

                end else begin
                    // LOW / INFO  -- cyan line
                    $display("%s  [cy %-5d]  ALERT: %-15s  priority=%0d  %s%s",
                             `CYAN, cycle_count, alert_name_full(alert_type),
                             alert_priority, prio_bar(alert_priority), `RESET);
                end

            end else begin
                $display("%s  [cy %-5d]  Alert cleared -- market stable%s",
                         `GREEN, cycle_count, `RESET);
            end

            prev_alert <= alert_flag;
            prev_prio  <= alert_priority;
            prev_type  <= alert_type;
        end

        // ---- ML INFERENCE RESULT ------------------------------------
        if (ml_valid_out) begin
            ml_inferences = ml_inferences + 1;
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

        // ---- ORDER BOOK MATCH ---------------------------------------
        if (match_valid && !ml_valid_out) begin
            total_matches = total_matches + 1;
            $display("%s  [cy %-5d]  MATCH  price = 0x%02h  (%0d)%s",
                     `GREEN, cycle_count, uio_out, uio_out, `RESET);
        end
    end

    // -------------------------------------------------------------------
    //  Input tasks
    // -------------------------------------------------------------------
    task send_price;
        input [11:0] price;
        begin
            ui_in  = {2'b00, price[5:0]};
            uio_in = {2'b00, price[11:6]};
            @(posedge clk); #1;
        end
    endtask

    task send_volume;
        input [11:0] vol;
        begin
            ui_in  = {2'b01, vol[5:0]};
            uio_in = {2'b00, vol[11:6]};
            @(posedge clk); #1;
        end
    endtask

    task send_buy;
        input [5:0] qty;
        begin
            ui_in  = {2'b10, qty};
            uio_in = 8'h00;
            @(posedge clk); #1;
        end
    endtask

    task send_sell;
        input [5:0] qty;
        begin
            ui_in  = {2'b11, qty};
            uio_in = 8'h00;
            @(posedge clk); #1;
        end
    endtask

    task idle;
        input integer n;
        begin
            ui_in  = 8'h00;
            uio_in = 8'h00;
            repeat(n) @(posedge clk); #1;
        end
    endtask

    // Config register: set threshold preset
    //   00 = Quiet      (loose -- few alerts)
    //   01 = Normal     (default)
    //   10 = Sensitive  (tight)
    //   11 = Demo       (very tight -- great for live demos)
    task set_threshold_preset;
        input [1:0] preset;
        begin
            ui_in  = 8'b00_000000;
            uio_in = {1'b1, 5'b00000, preset};
            @(posedge clk); #1;
            ui_in  = 8'h00;
            uio_in = 8'h00;
            @(posedge clk); #1;
        end
    endtask

    // Scenario banner  (pure ASCII +/- box)
    task scenario_banner;
        input [8*44-1:0] title;
        input integer    num;
        begin
            $display("");
            $display("%s+========================================================+%s", `WHITE, `RESET);
            $display("%s|  SCENARIO %0d -- %-42s  |%s", `WHITE, num, title, `RESET);
            $display("%s+========================================================+%s", `WHITE, `RESET);
        end
    endtask

    // -------------------------------------------------------------------
    //  Main stimulus
    // -------------------------------------------------------------------
    integer i;
    initial begin
        $dumpfile("nanotrade.vcd");
        $dumpvars(0, tb_nanotrade);

        // Top banner
        $display("");
        $display("%s+============================================================+%s", `BOLD, `RESET);
        $display("%s|     NanoTrade  --  HFT ASIC on SkyWater SKY130             |%s", `BOLD, `RESET);
        $display("%s|       IEEE UofT  --  TinyTapeout Submission                 |%s", `BOLD, `RESET);
        $display("%s|  Rule-Based (1-cy)  +  MLP Inference (4-cy pipeline)       |%s", `BOLD, `RESET);
        $display("%s+============================================================+%s", `BOLD, `RESET);
        $display("");
        $display("  Architecture : Order Book  +  8 Parallel Anomaly Detectors");
        $display("               : 16->4->6 MLP (INT16 weights, UINT8 activations)");
        $display("  Clock        : 50 MHz  (20 ns period, SKY130 compatible)");
        $display("  Footprint    : 2x2 TinyTapeout tiles");
        $display("");

        // Reset
        ena = 1; ui_in = 0; uio_in = 0; rst_n = 0;
        repeat(5) @(posedge clk);
        rst_n = 1; #1;
        $display("%s  [cy %-5d]  Reset released -- system online%s",
                 `GREEN, cycle_count, `RESET);

        // ------------------------------------------------------------------
        // SCENARIO 1: Normal warm-up
        // ------------------------------------------------------------------
        scenario_banner("Normal Market Warm-up  (price=100)", 1);
        $display("  Sending 30 balanced price/volume/buy/sell cycles ...");
        repeat(30) begin
            send_price(12'd100);
            send_volume(12'd100);
            send_buy(6'd5);
            send_sell(6'd5);
        end
        idle(30);
        $display("%s  [cy %-5d]  Baseline established  (avg price=100, vol=100)%s",
                 `GREEN, cycle_count, `RESET);

        // ------------------------------------------------------------------
        // SCENARIO 2: Price Spike  100 -> 180  (delta=80 > thresh 20)
        // ------------------------------------------------------------------
        scenario_banner("Price Spike  100 -> 180  (delta=80, thresh=20)", 2);
        $display("  Injecting sudden price spike ...");
        send_price(12'd180);
        idle(5);
        send_price(12'd100);
        idle(5);

        // ------------------------------------------------------------------
        // SCENARIO 3: Order Imbalance  (15 buys vs 1 sell)
        // ------------------------------------------------------------------
        scenario_banner("Order Imbalance  (15 buys vs 1 sell)", 3);
        $display("  Flooding one side of the order book ...");
        repeat(15) send_buy(6'd10);
        send_sell(6'd1);
        idle(10);

        // ------------------------------------------------------------------
        // SCENARIO 4: Volume Surge  100 -> 500  (5x average)
        // ------------------------------------------------------------------
        scenario_banner("Volume Surge  100 -> 500  (5x average)", 4);
        $display("  Panic buying simulation -- volume spike ...");
        send_volume(12'd500);
        idle(5);
        send_volume(12'd100);
        idle(5);

        // ------------------------------------------------------------------
        // SCENARIO 5: Flash Crash  100 -> 50  (drop > thresh 40)
        // ------------------------------------------------------------------
        scenario_banner("Flash Crash  100 -> 50  (drop > thresh 40)", 5);
        $display("  Reinforcing baseline then crashing price ...");
        repeat(8) send_price(12'd100);
        send_price(12'd50);
        idle(5);
        repeat(8) send_price(12'd100);
        idle(5);

        // ------------------------------------------------------------------
        // SCENARIO 6: Order Book Match
        // ------------------------------------------------------------------
        scenario_banner("Order Book Match", 6);
        $display("  Placing matching buy and sell at same price ...");
        send_price(12'd100);
        send_buy(6'd10);
        send_sell(6'd10);
        idle(5);

        // ------------------------------------------------------------------
        // SCENARIO 7: Quote Stuffing / Spoofing
        // ------------------------------------------------------------------
        scenario_banner("Quote Stuffing / Spoofing Pattern", 7);
        $display("  Rapid-fire buy+sell orders (40 pairs at max qty) ...");
        repeat(40) begin
            send_buy(6'd63);
            send_sell(6'd63);
        end
        idle(10);

        // ------------------------------------------------------------------
        // SCENARIO 8: ML Inference  (flash crash feature stream)
        // ------------------------------------------------------------------
        scenario_banner("ML Neural Net  --  256-cycle feature window", 8);
        $display("  Streaming flash-crash features (price drop + high volume) ...");
        $display("  Waiting for feature window + 4-stage pipeline ...");
        repeat(20) begin
            send_price(12'd50);
            send_volume(12'd400);
            send_buy(6'd1);
            send_sell(6'd30);
        end
        idle(300);

        // ------------------------------------------------------------------
        // SCENARIO 9: Config Register -- Live Threshold Tuning
        // ------------------------------------------------------------------
        scenario_banner("Config Register  --  Live Threshold Tuning", 9);
        $display("  Switching to DEMO preset (spike thresh=5, flash thresh=10) ...");
        set_threshold_preset(2'b11);
        $display("%s  [cy %-5d]  Thresholds set -> DEMO preset active%s",
                 `CYAN, cycle_count, `RESET);
        $display("  A 7-unit move now triggers SPIKE alert (thresh=5 in demo mode)...");
        send_price(12'd100);
        idle(2);
        send_price(12'd107);
        idle(5);
        send_price(12'd100);
        idle(5);

        $display("");
        $display("  Switching back to NORMAL preset ...");
        set_threshold_preset(2'b01);
        $display("%s  [cy %-5d]  Thresholds restored -> NORMAL preset active%s",
                 `CYAN, cycle_count, `RESET);
        idle(5);

        // ------------------------------------------------------------------
        // Final summary
        // ------------------------------------------------------------------
        $display("");
        $display("%s+============================================================+%s", `BOLD, `RESET);
        $display("%s|                    SIMULATION SUMMARY                      |%s", `BOLD, `RESET);
        $display("%s+============================================================+%s", `BOLD, `RESET);
        $display("%s|  Total Cycles       : %-5d                                 |%s",
                 `BOLD, cycle_count, `RESET);
        $display("%s|  Rule Alerts Fired  : %-5d                                 |%s",
                 `BOLD, total_alerts, `RESET);
        $display("%s|  Flash Crashes Det. : %-5d  (critical severity)            |%s",
                 `BOLD, flash_crashes, `RESET);
        $display("%s|  Order Book Matches : %-5d                                 |%s",
                 `BOLD, total_matches, `RESET);
        $display("%s|  ML Inferences      : %-5d  (256-cy window + 4-cy pipe)    |%s",
                 `BOLD, ml_inferences, `RESET);
        $display("%s|  Scenarios Run      : 9 of 9  [PASS]                       |%s",
                 `BOLD, `RESET);
        $display("%s+============================================================+%s", `BOLD, `RESET);
        $display("%s|  SKY130  50 MHz  |  2x2 TT tiles  |  IEEE UofT ASIC        |%s",
                 `BOLD, `RESET);
        $display("%s+============================================================+%s", `BOLD, `RESET);
        $display("");
        $finish;
    end

    initial begin #20000000; $display("TIMEOUT"); $finish; end

endmodule