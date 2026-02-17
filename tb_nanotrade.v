/*
 * NanoTrade Testbench — Fixed Version
 * =====================================
 * Fixes:
 *   1. Price encoding: correct 12-bit split ui_in[5:0] + uio_in[5:0]
 *   2. Clean output: only prints on alert CHANGES, not every cycle
 *   3. Scenarios use proper price values that don't trigger false crashes
 *
 * HOW TO COMPILE & RUN (from NanoTrade folder containing rom/ subfolder):
 *   iverilog -o sim tb_nanotrade.v tt_um_nanotrade.v order_book.v ^
 *            anomaly_detector.v feature_extractor.v ml_inference_engine.v
 *   vvp sim
 */

`timescale 1ns/1ps
`default_nettype none

module tb_nanotrade;

    reg  [7:0] ui_in;
    wire [7:0] uo_out;
    reg  [7:0] uio_in;
    wire [7:0] uio_out;
    wire [7:0] uio_oe;
    reg        ena;
    reg        clk;
    reg        rst_n;

    tt_um_nanotrade dut (
        .ui_in(ui_in), .uo_out(uo_out),
        .uio_in(uio_in), .uio_out(uio_out), .uio_oe(uio_oe),
        .ena(ena), .clk(clk), .rst_n(rst_n)
    );

    initial clk = 0;
    always #10 clk = ~clk;

    wire        alert_flag     = uo_out[7];
    wire [2:0]  alert_priority = uo_out[6:4];
    wire        match_valid    = uo_out[3];
    wire [2:0]  alert_type     = uo_out[2:0];
    wire        ml_valid_out   = uio_out[7];
    wire [2:0]  ml_class_out   = uio_out[6:4];
    wire [3:0]  ml_conf_out    = uio_out[3:0];

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

    integer cycle_count;
    initial cycle_count = 0;
    always @(posedge clk) cycle_count = cycle_count + 1;

    // Print only on alert state changes
    reg        prev_alert;
    reg [2:0]  prev_prio;
    reg [2:0]  prev_type;
    initial begin prev_alert=0; prev_prio=0; prev_type=0; end

    always @(posedge clk) begin
        if (alert_flag !== prev_alert || alert_priority !== prev_prio || alert_type !== prev_type) begin
            if (alert_flag)
                $display("[cy %0d] RULE ALERT --> %s  priority=%0d",
                         cycle_count, alert_name(alert_type), alert_priority);
            else
                $display("[cy %0d] Alert cleared", cycle_count);
            prev_alert <= alert_flag;
            prev_prio  <= alert_priority;
            prev_type  <= alert_type;
        end
        if (ml_valid_out)
            $display("[cy %0d] *** ML RESULT: class=%s  conf=%0d ***",
                     cycle_count, ml_name(ml_class_out), {ml_conf_out,4'b1111});
        if (match_valid && !ml_valid_out)
            $display("[cy %0d] Order match: price=0x%02h", cycle_count, uio_out);
    end

    // --- Tasks ---
    // CORRECT 12-bit price encoding: high 6 bits -> uio_in[5:0], low 6 bits -> ui_in[5:0]
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
            ui_in = {2'b10, qty}; uio_in = 8'h00;
            @(posedge clk); #1;
        end
    endtask

    task send_sell;
        input [5:0] qty;
        begin
            ui_in = {2'b11, qty}; uio_in = 8'h00;
            @(posedge clk); #1;
        end
    endtask

    task idle;
        input integer n;
        begin
            ui_in = 8'h00; uio_in = 8'h00;
            repeat(n) @(posedge clk); #1;
        end
    endtask

    integer i;
    initial begin
        $dumpfile("nanotrade.vcd");
        $dumpvars(0, tb_nanotrade);

        $display("============================================");
        $display("  NanoTrade Testbench  -  IEEE UofT ASIC   ");
        $display("============================================");

        ena=1; ui_in=0; uio_in=0; rst_n=0;
        repeat(5) @(posedge clk);
        rst_n=1; #1;
        $display("[cy %0d] Reset released", cycle_count);

        // ----------------------------------------------------------
        // SCENARIO 1: Normal warm-up — establish baseline at price=100
        // ----------------------------------------------------------
        $display("\n--- SCENARIO 1: Normal Market Warm-up ---");
        repeat(30) begin
            send_price(12'd100);
            send_volume(12'd100);
            send_buy(6'd5);
            send_sell(6'd5);
        end
        idle(30);
        $display("[cy %0d] Baseline established. Should see no FLASH alert.", cycle_count);

        // ----------------------------------------------------------
        // SCENARIO 2: Price Spike (100 -> 180, delta=80 > thresh=20)
        // ----------------------------------------------------------
        $display("\n--- SCENARIO 2: Price Spike (100 -> 180) ---");
        send_price(12'd180);
        idle(5);
        send_price(12'd100); // recover
        idle(5);

        // ----------------------------------------------------------
        // SCENARIO 3: Order Imbalance (15 buys vs 1 sell)
        // ----------------------------------------------------------
        $display("\n--- SCENARIO 3: Order Imbalance ---");
        repeat(15) send_buy(6'd10);
        send_sell(6'd1);
        idle(10);

        // ----------------------------------------------------------
        // SCENARIO 4: Volume Surge (100 -> 500, 5x average)
        // ----------------------------------------------------------
        $display("\n--- SCENARIO 4: Volume Surge ---");
        send_volume(12'd500);
        idle(5);
        send_volume(12'd100); // recover
        idle(5);

        // ----------------------------------------------------------
        // SCENARIO 5: Flash Crash CRITICAL (100 -> 50, drop > thresh=40)
        // ----------------------------------------------------------
        $display("\n--- SCENARIO 5: FLASH CRASH (100 -> 50) ---");
        repeat(8) send_price(12'd100); // reinforce baseline
        send_price(12'd50);            // CRASH
        idle(5);
        repeat(8) send_price(12'd100); // recover
        idle(5);

        // ----------------------------------------------------------
        // SCENARIO 6: Order Book Match
        // ----------------------------------------------------------
        $display("\n--- SCENARIO 6: Order Book Match ---");
        send_price(12'd100);
        send_buy(6'd10);
        send_sell(6'd10);
        idle(5);

        // ----------------------------------------------------------
        // SCENARIO 7: Quote Stuffing (mass orders both sides)
        // ----------------------------------------------------------
        $display("\n--- SCENARIO 7: Quote Stuffing Pattern ---");
        repeat(40) begin
            send_buy(6'd63);
            send_sell(6'd63);
        end
        idle(10);

        // ----------------------------------------------------------
        // SCENARIO 8: ML Inference — wait for full 256-cycle window
        // ----------------------------------------------------------
        $display("\n--- SCENARIO 8: ML Inference (waiting for 256-cycle window...) ---");
        repeat(20) begin
            send_price(12'd50);
            send_volume(12'd400);
            send_buy(6'd1);
            send_sell(6'd30);
        end
        idle(300); // enough for feature window + 4-stage pipeline

        $display("\n============================================");
        $display("  Done - %0d cycles total", cycle_count);
        $display("============================================");
        $finish;
    end

    initial begin #20000000; $display("TIMEOUT"); $finish; end

endmodule