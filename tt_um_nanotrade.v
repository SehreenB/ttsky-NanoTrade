/*
 * NanoTrade — Top-Level TinyTapeout Wrapper
 * ============================================
 * Integrates four subsystems:
 *   1. Order Book Engine       (order_book.v)
 *   2. Rule-Based Detectors    (anomaly_detector.v)   — fast path, 1 cycle
 *   3. Feature Extractor       (feature_extractor.v)  — feeds ML every 256 cy
 *   4. ML Inference Engine     (ml_inference_engine.v) — 4-cycle pipeline
 *
 * Alert priority:
 *   ML result overrides rule-based when ml_valid fires.
 *   Rule-based fires immediately for obvious cases (1-cycle latency).
 *   Combined output uses highest priority from either system.
 *
 * Pin mapping:
 *   ui_in[7:6]   Input type: 00=price, 01=vol, 10=buy, 11=sell
 *   ui_in[5:0]   Data low 6 bits
 *   uio_in[5:0]  Data high 6 bits (12-bit price/volume)
 *
 *   uo_out[7]    Global alert (rule OR ML)
 *   uo_out[6:4]  Alert priority (7=critical flash crash)
 *   uo_out[3]    Order match valid
 *   uo_out[2:0]  Alert type code
 *
 *   uio_out[7]   ML valid
 *   uio_out[6:4] ML class (0=normal..5=quote_stuff)
 *   uio_out[3:0] ML confidence nibble
 *   (uio_out = match_price when match_valid)
 */

`default_nettype none

module tt_um_nanotrade (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);

    wire [1:0]  input_type = ui_in[7:6];
    wire [11:0] price_data = {uio_in[5:0], ui_in[5:0]};
    wire [11:0] vol_data   = {uio_in[5:0], ui_in[5:0]};

    // --- Order Book ---
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

    // --- Rule-Based Detector ---
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
        .alert_any     (rule_alert_any),
        .alert_priority(rule_alert_priority),
        .alert_type    (rule_alert_type),
        .alert_bitmap  (rule_alert_bitmap)
    );

    // --- Feature Extractor ---
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

    // --- ML Inference Engine ---
    wire [2:0]  ml_class;
    wire [7:0]  ml_confidence;
    wire        ml_valid;

    ml_inference_engine #(
        .W1_HEX("rom/w1.hex"),
        .B1_HEX("rom/b1.hex"),
        .W2_HEX("rom/w2.hex"),
        .B2_HEX("rom/b2.hex")
    ) u_ml_engine (
        .clk           (clk),
        .rst_n         (rst_n),
        .features      (features),
        .feature_valid (feature_valid),
        .ml_class      (ml_class),
        .ml_confidence (ml_confidence),
        .ml_valid      (ml_valid)
    );

    // --- Alert Fusion ---
    reg [2:0] ml_class_held;
    reg [7:0] ml_conf_held;
    reg       ml_anomaly_held;

    // ML class → priority mapping
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
                3'd1: ml_prio_held <= 3'd3;  // SPIKE
                3'd2: ml_prio_held <= 3'd2;  // VOL_SURGE
                3'd3: ml_prio_held <= 3'd7;  // FLASH_CRASH
                3'd4: ml_prio_held <= 3'd4;  // IMBALANCE
                3'd5: ml_prio_held <= 3'd5;  // QUOTE_STUFF
                default: ml_prio_held <= 3'd0;
            endcase
        end
    end

    wire        comb_alert    = rule_alert_any | ml_anomaly_held;
    wire [2:0]  comb_priority = (rule_alert_priority > ml_prio_held) ?
                                  rule_alert_priority : ml_prio_held;
    wire [2:0]  comb_type     = (rule_alert_priority >= ml_prio_held) ?
                                  rule_alert_type : ml_class_held;

    // --- Outputs ---
    assign uo_out[7]   = comb_alert;
    assign uo_out[6:4] = comb_priority;
    assign uo_out[3]   = match_valid;
    assign uo_out[2:0] = comb_type;

    assign uio_out = match_valid ? match_price :
                     {ml_valid, ml_class_held, ml_conf_held[7:4]};
    assign uio_oe  = 8'hFF;

    wire _unused = &{ena, uio_in[7:6], 1'b0};

endmodule
