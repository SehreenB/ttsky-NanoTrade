/*
 * NanoTrade — Top-Level TinyTapeout Wrapper  (v2 — SKY130 Enhanced)
 * ====================================================================
 * Enhancements over v1:
 *
 *  1. SYNTHESIZABLE ML ENGINE
 *     Uses 16→4→6 MLP with case-ROM weights (no $readmemh)
 *
 *  2. CONFIG REGISTER  (medium-term)
 *     Write ui_in[7:6]=2'b00 + uio_in[7]=1 to load a threshold config byte.
 *     Config bits select which of 4 preset threshold levels to use:
 *       uio_in[1:0] = 2'b00 → "Quiet"    (loose thresholds, few alerts)
 *       uio_in[1:0] = 2'b01 → "Normal"   (default — matches testbench)
 *       uio_in[1:0] = 2'b10 → "Sensitive"(tight thresholds, more alerts)
 *       uio_in[1:0] = 2'b11 → "Demo"     (very tight, good for live demo)
 *
 *  3. UART READBACK  (medium-term)
 *     uo_out[3] repurposed as UART TX when no order match is pending.
 *     Fires a 115200-baud byte every time an alert or ML result occurs.
 *     Frame: START | alert_type[2:0] | alert_prio[2:0] | ml_class[1:0] | STOP
 *     Connect to a USB-UART adapter for live terminal readout during demos.
 *     Baud divisor auto-calculated from CLK_HZ parameter.
 *
 *  4. HEARTBEAT LED  (medium-term)
 *     uo_out[3] pulses at ~1 Hz (toggling every 25M cycles at 50 MHz)
 *     when no order match AND no UART transmission is active.
 *     Proves chip is alive at a glance on the demo board.
 *
 * Pin mapping (unchanged from v1 for TT compatibility):
 *   ui_in[7:6]   Input type: 00=price/config, 01=vol, 10=buy, 11=sell
 *   ui_in[5:0]   Data low 6 bits
 *   uio_in[7]    Config write strobe (1=config mode, only when type=00)
 *   uio_in[5:0]  Data high 6 bits  OR  config byte[5:0]
 *
 *   uo_out[7]    Global alert (rule OR ML)
 *   uo_out[6:4]  Alert priority (7=critical flash crash)
 *   uo_out[3]    Order match valid / UART TX / heartbeat (priority order)
 *   uo_out[2:0]  Alert type code
 *
 *   uio_out[7]   ML valid pulse
 *   uio_out[6:4] ML class
 *   uio_out[3:0] ML confidence nibble / match price bits [3:0]
 */

`default_nettype none

module tt_um_nanotrade #(
    parameter CLK_HZ = 50_000_000   // 50 MHz for SKY130 @ TinyTapeout
) (
    input  wire [7:0] ui_in,
    output reg  [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);

    // ---------------------------------------------------------------
    // Input decode
    // ---------------------------------------------------------------
    wire [1:0]  input_type   = ui_in[7:6];
    wire        config_strobe = uio_in[7] && (input_type == 2'b00);
    wire [11:0] price_data   = {uio_in[5:0], ui_in[5:0]};
    wire [11:0] vol_data     = {uio_in[5:0], ui_in[5:0]};

    // ---------------------------------------------------------------
    // CONFIG REGISTER — threshold preset select
    // ---------------------------------------------------------------
    reg [1:0] thresh_sel;   // 00=quiet 01=normal 10=sensitive 11=demo

    // Threshold tables: [preset][value]
    // SPIKE_THRESH: how many price units = a spike
    wire [11:0] SPIKE_THRESH =
        (thresh_sel == 2'b00) ? 12'd40 :
        (thresh_sel == 2'b01) ? 12'd20 :
        (thresh_sel == 2'b10) ? 12'd10 :
                                12'd5;   // demo

    // FLASH_THRESH: price drop from baseline to trigger flash crash
    wire [11:0] FLASH_THRESH =
        (thresh_sel == 2'b00) ? 12'd60 :
        (thresh_sel == 2'b01) ? 12'd40 :
        (thresh_sel == 2'b10) ? 12'd20 :
                                12'd10;  // demo

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            thresh_sel <= 2'b01;   // default = Normal
        else if (config_strobe)
            thresh_sel <= uio_in[1:0];
    end

    // ---------------------------------------------------------------
    // Order Book
    // ---------------------------------------------------------------
    wire        match_valid;
    wire [7:0]  match_price;

    order_book u_order_book (
        .clk        (clk),
        .rst_n      (rst_n),
        .input_type (input_type),
        .data_in    (ui_in[5:0]),
        .ext_data   (uio_in[5:0]),
        .match_valid(match_valid),
        .match_price(match_price)
    );

    // ---------------------------------------------------------------
    // Rule-Based Anomaly Detector (with live threshold params)
    // ---------------------------------------------------------------
    wire        rule_alert_any;
    wire [2:0]  rule_alert_priority;
    wire [2:0]  rule_alert_type;
    wire [7:0]  rule_alert_bitmap;

    anomaly_detector u_rule_detector (
        .clk           (clk),
        .rst_n         (rst_n),
        .input_type    (input_type),
        .price_data    (price_data),
        .volume_data   (vol_data),
        .match_valid   (match_valid),
        .match_price   (match_price),
        .spike_thresh  (SPIKE_THRESH),
        .flash_thresh  (FLASH_THRESH),
        .alert_any     (rule_alert_any),
        .alert_priority(rule_alert_priority),
        .alert_type    (rule_alert_type),
        .alert_bitmap  (rule_alert_bitmap)
    );

    // ---------------------------------------------------------------
    // Feature Extractor
    // ---------------------------------------------------------------
    wire [127:0] features;
    wire         feature_valid;

    feature_extractor u_feat_extractor (
        .clk          (clk),
        .rst_n        (rst_n),
        .input_type   (input_type),
        .price_data   (price_data),
        .volume_data  (vol_data),
        .match_valid  (match_valid),
        .match_price  (match_price),
        .features     (features),
        .feature_valid(feature_valid)
    );

    // ---------------------------------------------------------------
    // ML Inference Engine (synthesizable ROM, 16→4→6 MLP)
    // ---------------------------------------------------------------
    wire [2:0]  ml_class;
    wire [7:0]  ml_confidence;
    wire        ml_valid;

    ml_inference_engine u_ml_engine (
        .clk           (clk),
        .rst_n         (rst_n),
        .features      (features),
        .feature_valid (feature_valid),
        .ml_class      (ml_class),
        .ml_confidence (ml_confidence),
        .ml_valid      (ml_valid)
    );

    // ---------------------------------------------------------------
    // Alert Fusion
    // ---------------------------------------------------------------
    reg [2:0] ml_class_held;
    reg [7:0] ml_conf_held;
    reg       ml_anomaly_held;
    reg [2:0] ml_prio_held;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ml_class_held   <= 3'd0;
            ml_conf_held    <= 8'd0;
            ml_anomaly_held <= 1'b0;
            ml_prio_held    <= 3'd0;
        end else if (ml_valid) begin
            ml_class_held   <= ml_class;
            ml_conf_held    <= ml_confidence;
            ml_anomaly_held <= (ml_class != 3'd0);
            case (ml_class)
                3'd0: ml_prio_held <= 3'd0;
                3'd1: ml_prio_held <= 3'd3;
                3'd2: ml_prio_held <= 3'd2;
                3'd3: ml_prio_held <= 3'd7;
                3'd4: ml_prio_held <= 3'd4;
                3'd5: ml_prio_held <= 3'd5;
                default: ml_prio_held <= 3'd0;
            endcase
        end
    end

    wire        comb_alert    = rule_alert_any | ml_anomaly_held;
    wire [2:0]  comb_priority = (rule_alert_priority > ml_prio_held) ?
                                  rule_alert_priority : ml_prio_held;
    wire [2:0]  comb_type     = (rule_alert_priority >= ml_prio_held) ?
                                  rule_alert_type : ml_class_held;

    // ---------------------------------------------------------------
    // UART READBACK — 115200 baud, 8N1
    // ---------------------------------------------------------------
    localparam BAUD_DIV = CLK_HZ / 115200;   // ~434 at 50 MHz

    // Payload to send: {alert_type[2:0], alert_priority[2:0], ml_class[1:0]}
    // = 1 byte: packed status word
    wire [7:0] uart_payload = {comb_type, comb_priority, ml_class_held[1:0]};

    // Trigger: send on every alert rising edge or ML valid pulse
    reg        prev_alert_r;
    wire       uart_trigger = (comb_alert && !prev_alert_r) || ml_valid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) prev_alert_r <= 1'b0;
        else        prev_alert_r <= comb_alert;
    end

    // UART state machine
    reg [9:0]  uart_shift;   // {stop, data[7:0], start}
    reg [9:0]  uart_bit_cnt; // baud divisor counter
    reg [3:0]  uart_bits;    // bit position 0..9
    reg        uart_busy;
    reg        uart_tx;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            uart_busy    <= 1'b0;
            uart_tx      <= 1'b1;   // idle high
            uart_shift   <= 10'h3FF;
            uart_bit_cnt <= 10'd0;
            uart_bits    <= 4'd0;
        end else begin
            if (!uart_busy && uart_trigger) begin
                // Load frame: START(0) + DATA + STOP(1)
                uart_shift   <= {1'b1, uart_payload, 1'b0};
                uart_bit_cnt <= 10'd0;
                uart_bits    <= 4'd0;
                uart_busy    <= 1'b1;
                uart_tx      <= 1'b0;   // start bit immediately
            end else if (uart_busy) begin
                if (uart_bit_cnt >= BAUD_DIV - 1) begin
                    uart_bit_cnt <= 10'd0;
                    uart_bits    <= uart_bits + 4'd1;
                    uart_tx      <= uart_shift[uart_bits];
                    if (uart_bits == 4'd9) begin
                        uart_busy <= 1'b0;
                        uart_tx   <= 1'b1;  // idle
                    end
                end else begin
                    uart_bit_cnt <= uart_bit_cnt + 10'd1;
                end
            end
        end
    end

    // ---------------------------------------------------------------
    // HEARTBEAT — ~1 Hz pulse on uo_out[3] when idle
    // ---------------------------------------------------------------
    localparam HB_DIV = CLK_HZ / 2;   // toggle at 1 Hz = period/2

    reg [24:0] hb_cnt;
    reg        hb_led;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hb_cnt <= 25'd0;
            hb_led <= 1'b0;
        end else begin
            if (hb_cnt >= HB_DIV - 1) begin
                hb_cnt <= 25'd0;
                hb_led <= ~hb_led;
            end else begin
                hb_cnt <= hb_cnt + 25'd1;
            end
        end
    end

    // ---------------------------------------------------------------
    // Output mux:
    //   uo_out[3] priority: match_valid > uart_busy > heartbeat
    // ---------------------------------------------------------------
    always @(*) begin
        uo_out[7]   = comb_alert;
        uo_out[6:4] = comb_priority;
        uo_out[2:0] = comb_type;

        if (match_valid)
            uo_out[3] = 1'b1;          // order match pulse
        else if (uart_busy)
            uo_out[3] = uart_tx;       // UART byte streaming
        else
            uo_out[3] = hb_led;        // heartbeat when idle
    end

    // ---------------------------------------------------------------
    // Bidirectional outputs
    // ---------------------------------------------------------------
    assign uio_out = match_valid ? match_price :
                     {ml_valid, ml_class_held, ml_conf_held[7:4]};
    assign uio_oe  = 8'hFF;

    wire _unused = &{ena, uio_in[6:2], 1'b0};

endmodule