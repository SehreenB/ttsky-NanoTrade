/*
 * NanoTrade — Top-Level TinyTapeout Wrapper  (v3 — ML Circuit Breaker)
 * ======================================================================
 * NEW in v3:
 *
 *  5. ML-CONTROLLED ADAPTIVE CIRCUIT BREAKER
 *     The ML engine output now directly controls the order book.
 *     When a flash crash, quote stuffing, or severe imbalance is detected,
 *     the circuit breaker halts or throttles matching within 4 clock cycles
 *     (80ns at 50MHz) — the time it takes the ML pipeline to fire.
 *     The rule-based detector can also trigger an immediate HALT in 1 cycle.
 *
 *     Response table:
 *       FLASH_CRASH  + confidence > 8  → HALT     (64 cycles)
 *       FLASH_CRASH  + confidence ≤ 8  → THROTTLE (32 cycles)
 *       QUOTE_STUFF  + any             → THROTTLE (16 cycles)
 *       ORDER_IMBAL  + confidence > 8  → THROTTLE (16 cycles)
 *       PRICE_SPIKE  + confidence > 12 → THROTTLE  (8 cycles)
 *       Rule alert   + priority = 7    → HALT     (64 cycles, 1-cycle path)
 *
 *     cb_state is exposed on uio_out[1:0] when no match/ML output pending.
 *
 * Previous features (unchanged):
 *   1. Synthesizable 16→4→6 MLP with case-ROM weights
 *   2. Config register with 4 threshold presets
 *   3. UART readback at 115200 baud
 *   4. Heartbeat LED at ~1 Hz
 *
 * Pin mapping (unchanged for TT compatibility):
 *   ui_in[7:6]   Input type: 00=price/config, 01=vol, 10=buy, 11=sell
 *   ui_in[5:0]   Data low 6 bits
 *   uio_in[7]    Config write strobe
 *   uio_in[5:0]  Data high 6 bits / config byte
 *
 *   uo_out[7]    Global alert (rule OR ML)
 *   uo_out[6:4]  Alert priority
 *   uo_out[3]    Order match / UART TX / heartbeat
 *   uo_out[2:0]  Alert type
 *
 *   uio_out[7]   ML valid pulse
 *   uio_out[6:4] ML class
 *   uio_out[3:2] Circuit breaker state (NEW: cb_state[1:0])
 *   uio_out[1:0] ML confidence nibble [5:4] / match price [1:0]
 */

`default_nettype none

module tt_um_nanotrade #(
    parameter CLK_HZ = 50_000_000
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
    wire [1:0]  input_type    = ui_in[7:6];
    wire        config_strobe = uio_in[7] && (input_type == 2'b00);
    wire [11:0] price_data    = {uio_in[5:0], ui_in[5:0]};
    wire [11:0] vol_data      = {uio_in[5:0], ui_in[5:0]};

    // ---------------------------------------------------------------
    // CONFIG REGISTER — threshold preset select
    // ---------------------------------------------------------------
    reg [1:0] thresh_sel;

    wire [11:0] SPIKE_THRESH =
        (thresh_sel == 2'b00) ? 12'd40 :
        (thresh_sel == 2'b01) ? 12'd20 :
        (thresh_sel == 2'b10) ? 12'd10 :
                                12'd5;

    wire [11:0] FLASH_THRESH =
        (thresh_sel == 2'b00) ? 12'd60 :
        (thresh_sel == 2'b01) ? 12'd40 :
        (thresh_sel == 2'b10) ? 12'd20 :
                                12'd10;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            thresh_sel <= 2'b01;
        else if (config_strobe)
            thresh_sel <= uio_in[1:0];
    end

    // ---------------------------------------------------------------
    // Circuit Breaker wires (declared early — used in order_book)
    // ---------------------------------------------------------------
    wire        cb_halt;
    wire        cb_throttle;
    wire        cb_throttle_phase;
    wire [2:0]  cb_state;

    // ---------------------------------------------------------------
    // Order Book (now with circuit breaker ports)
    // ---------------------------------------------------------------
    wire        match_valid;
    wire [7:0]  match_price;

    order_book u_order_book (
        .clk              (clk),
        .rst_n            (rst_n),
        .input_type       (input_type),
        .data_in          (ui_in[5:0]),
        .ext_data         (uio_in[5:0]),
        .cb_halt          (cb_halt),
        .cb_throttle      (cb_throttle),
        .cb_throttle_phase(cb_throttle_phase),
        .match_valid      (match_valid),
        .match_price      (match_price)
    );

    // ---------------------------------------------------------------
    // Rule-Based Anomaly Detector
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
    // ML Inference Engine (16→4→6 MLP)
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
    // ML-CONTROLLED CIRCUIT BREAKER (NEW)
    // Sits between ML engine output and order book control
    // ---------------------------------------------------------------
    circuit_breaker u_circuit_breaker (
        .clk              (clk),
        .rst_n            (rst_n),
        .ml_class         (ml_class),
        .ml_confidence    (ml_confidence),
        .ml_valid         (ml_valid),
        .rule_alert       (rule_alert_any),
        .rule_priority    (rule_alert_priority),
        .cb_halt          (cb_halt),
        .cb_throttle      (cb_throttle),
        .cb_throttle_phase(cb_throttle_phase),
        .cb_state         (cb_state)
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
    // Now also encodes circuit breaker state in upper bits
    // Payload: {cb_state[1:0], comb_type[2:0], comb_priority[2:0]}
    // ---------------------------------------------------------------
    localparam BAUD_DIV = CLK_HZ / 115200;

    wire [7:0] uart_payload = {cb_state[1:0], comb_type, comb_priority};

    reg        prev_alert_r;
    wire       uart_trigger = (comb_alert && !prev_alert_r) || ml_valid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) prev_alert_r <= 1'b0;
        else        prev_alert_r <= comb_alert;
    end

    reg [9:0]  uart_shift;
    reg [9:0]  uart_bit_cnt;
    reg [3:0]  uart_bits;
    reg        uart_busy;
    reg        uart_tx;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            uart_busy    <= 1'b0;
            uart_tx      <= 1'b1;
            uart_shift   <= 10'h3FF;
            uart_bit_cnt <= 10'd0;
            uart_bits    <= 4'd0;
        end else begin
            if (!uart_busy && uart_trigger) begin
                uart_shift   <= {1'b1, uart_payload, 1'b0};
                uart_bit_cnt <= 10'd0;
                uart_bits    <= 4'd0;
                uart_busy    <= 1'b1;
                uart_tx      <= 1'b0;
            end else if (uart_busy) begin
                if (uart_bit_cnt >= BAUD_DIV - 1) begin
                    uart_bit_cnt <= 10'd0;
                    uart_bits    <= uart_bits + 4'd1;
                    uart_tx      <= uart_shift[uart_bits];
                    if (uart_bits == 4'd9) begin
                        uart_busy <= 1'b0;
                        uart_tx   <= 1'b1;
                    end
                end else begin
                    uart_bit_cnt <= uart_bit_cnt + 10'd1;
                end
            end
        end
    end

    // ---------------------------------------------------------------
    // HEARTBEAT
    // ---------------------------------------------------------------
    localparam HB_DIV = CLK_HZ / 2;

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
    // Output mux
    // ---------------------------------------------------------------
    always @(*) begin
        uo_out[7]   = comb_alert;
        uo_out[6:4] = comb_priority;
        uo_out[2:0] = comb_type;

        if (match_valid)
            uo_out[3] = 1'b1;
        else if (uart_busy)
            uo_out[3] = uart_tx;
        else
            uo_out[3] = hb_led;
    end

    // ---------------------------------------------------------------
    // Bidirectional outputs
    // uio_out[7]   = ml_valid
    // uio_out[6:4] = ml_class_held
    // uio_out[3:2] = cb_state[1:0]  ← NEW: circuit breaker state visible
    // uio_out[1:0] = ml_conf nibble high bits / match price low bits
    // ---------------------------------------------------------------
    assign uio_out = match_valid  ? match_price :
                     {ml_valid, ml_class_held, cb_state[1:0], ml_conf_held[5:4]};
    assign uio_oe  = 8'hFF;

    wire _unused = &{ena, uio_in[6:2], 1'b0};

endmodule