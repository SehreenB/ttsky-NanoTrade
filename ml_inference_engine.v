/*
 * NanoTrade ML Inference Engine
 * ================================
 * Pipelined 16-input → 8-hidden → 6-output MLP
 * INT16 weights, INT32 accumulators, UINT8 activations
 *
 * Architecture (pipeline stages):
 *   Stage 0 : Latch feature vector, start Layer-1 MACs
 *   Stage 1 : Finish Layer-1 MACs + bias + ReLU → 8x UINT8 hidden
 *   Stage 2 : Layer-2 MACs + bias
 *   Stage 3 : Argmax → 3-bit class, confidence byte
 *   Total latency: 4 clock cycles from feature_valid to result_valid
 *
 * ROM files (loaded via $readmemh):
 *   rom/w1.hex  128 × INT16  W1[in][hidden]  row-major
 *   rom/b1.hex    8 × INT16  b1[hidden]
 *   rom/w2.hex   48 × INT16  W2[hidden][out] row-major
 *   rom/b2.hex    6 × INT16  b2[out]
 *
 * Anomaly classes:
 *   0 = NORMAL
 *   1 = PRICE_SPIKE
 *   2 = VOLUME_SURGE
 *   3 = FLASH_CRASH   (critical)
 *   4 = ORDER_IMBALANCE
 *   5 = QUOTE_STUFFING
 *
 * Fixed-point note:
 *   Layer-1 accumulator is 32-bit.
 *   After bias add, right-shift 8 to get UINT8 hidden activation.
 *   Layer-2 accumulator is 32-bit. Argmax over raw logits.
 */

`default_nettype none

module ml_inference_engine #(
    parameter W1_HEX = "rom/w1.hex",
    parameter B1_HEX = "rom/b1.hex",
    parameter W2_HEX = "rom/w2.hex",
    parameter B2_HEX = "rom/b2.hex"
)(
    input  wire        clk,
    input  wire        rst_n,

    // Feature vector input: 16 × 8-bit unsigned features
    input  wire [127:0] features,      // {feat[15], feat[14], ... feat[0]}
    input  wire         feature_valid, // pulse high for 1 cycle to start inference

    // Result output (valid 4 cycles after feature_valid)
    output reg  [2:0]  ml_class,       // 0..5 predicted class
    output reg  [7:0]  ml_confidence,  // 0..255 confidence proxy (max logit scaled)
    output reg         ml_valid        // 1 cycle pulse when result ready
);

    // ---------------------------------------------------------------
    // ROM declarations
    // ---------------------------------------------------------------
    reg signed [15:0] W1 [0:127];   // W1[in*8 + hidden]
    reg signed [15:0] b1 [0:7];
    reg signed [15:0] W2 [0:47];    // W2[hidden*6 + out]
    reg signed [15:0] b2 [0:5];

    initial begin
        $readmemh(W1_HEX, W1);
        $readmemh(B1_HEX, b1);
        $readmemh(W2_HEX, W2);
        $readmemh(B2_HEX, b2);
    end

    // ---------------------------------------------------------------
    // Feature unpacking — 16 × 8-bit unsigned
    // ---------------------------------------------------------------
    wire [7:0] feat [0:15];
    genvar gi;
    generate
        for (gi = 0; gi < 16; gi = gi + 1) begin : unpack
            assign feat[gi] = features[gi*8 +: 8];
        end
    endgenerate

    // ---------------------------------------------------------------
    // Pipeline registers
    // ---------------------------------------------------------------

    // Stage 0 → 1: latched feature vector
    reg [7:0]  s0_feat [0:15];
    reg        s0_valid;

    // Stage 1 → 2: hidden activations (UINT8 after ReLU)
    reg [7:0]  s1_hidden [0:7];
    reg        s1_valid;

    // Stage 2 → 3: output logits (INT32)
    reg signed [31:0] s2_logit [0:5];
    reg               s2_valid;

    // ---------------------------------------------------------------
    // Stage 0: Latch inputs
    // ---------------------------------------------------------------
    integer k;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s0_valid <= 1'b0;
            for (k = 0; k < 16; k = k + 1)
                s0_feat[k] <= 8'd0;
        end else begin
            s0_valid <= feature_valid;
            if (feature_valid) begin
                for (k = 0; k < 16; k = k + 1)
                    s0_feat[k] <= feat[k];
            end
        end
    end

    // ---------------------------------------------------------------
    // Stage 1: Layer-1 MAC — 16 inputs × 8 hidden neurons
    //   acc1[h] = Σ_{i=0}^{15} feat[i] * W1[i*8+h]  +  b1[h]
    //   hidden[h] = ReLU(acc1[h] >> 8)  clipped to UINT8
    // ---------------------------------------------------------------
    reg signed [31:0] acc1 [0:7];
    integer i1, h1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_valid <= 1'b0;
            for (k = 0; k < 8; k = k + 1) begin
                s1_hidden[k] <= 8'd0;
                acc1[k]      <= 32'sd0;
            end
        end else begin
            s1_valid <= s0_valid;
            if (s0_valid) begin
                // Accumulate MACs
                for (h1 = 0; h1 < 8; h1 = h1 + 1) begin
                    acc1[h1] = 32'sd0;  // blocking for in-loop accumulation
                    for (i1 = 0; i1 < 16; i1 = i1 + 1) begin
                        // Feature is unsigned 8-bit, weight is signed 16-bit
                        acc1[h1] = acc1[h1] +
                            ($signed({1'b0, s0_feat[i1]}) * $signed(W1[i1*8 + h1]));
                    end
                    // Add bias
                    acc1[h1] = acc1[h1] + $signed({b1[h1], 8'h00}); // bias scaled to match

                    // ReLU + right-shift 8 → UINT8
                    if (acc1[h1] <= 32'sd0)
                        s1_hidden[h1] <= 8'd0;
                    else if (acc1[h1] >= 32'sd65535)
                        s1_hidden[h1] <= 8'd255;
                    else
                        s1_hidden[h1] <= acc1[h1][15:8];  // bits [15:8] = >> 8
                end
            end
        end
    end

    // ---------------------------------------------------------------
    // Stage 2: Layer-2 MAC — 8 hidden × 6 output neurons
    //   logit[o] = Σ_{h=0}^{7} hidden[h] * W2[h*6+o]  +  b2[o]
    // ---------------------------------------------------------------
    integer h2, o2;
    reg signed [31:0] acc2_tmp;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s2_valid <= 1'b0;
            for (k = 0; k < 6; k = k + 1)
                s2_logit[k] <= 32'sd0;
        end else begin
            s2_valid <= s1_valid;
            if (s1_valid) begin
                for (o2 = 0; o2 < 6; o2 = o2 + 1) begin
                    acc2_tmp = 32'sd0;
                    for (h2 = 0; h2 < 8; h2 = h2 + 1) begin
                        acc2_tmp = acc2_tmp +
                            ($signed({1'b0, s1_hidden[h2]}) * $signed(W2[h2*6 + o2]));
                    end
                    s2_logit[o2] <= acc2_tmp + $signed({b2[o2], 8'h00});
                end
            end
        end
    end

    // ---------------------------------------------------------------
    // Stage 3: Argmax over 6 logits → class + confidence
    //   Confidence proxy: max_logit scaled to 0..255
    // ---------------------------------------------------------------
    reg signed [31:0] max_logit;
    reg signed [31:0] min_logit;
    reg [2:0]         best_class;
    reg signed [31:0] gap;   // hoisted for Verilog-2001 compatibility
    integer j3;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ml_valid      <= 1'b0;
            ml_class      <= 3'd0;
            ml_confidence <= 8'd0;
        end else begin
            ml_valid <= s2_valid;
            if (s2_valid) begin
                // Find argmax and range for confidence scaling
                max_logit  = s2_logit[0];
                min_logit  = s2_logit[0];
                best_class = 3'd0;

                for (j3 = 1; j3 < 6; j3 = j3 + 1) begin
                    if (s2_logit[j3] > max_logit) begin
                        max_logit  = s2_logit[j3];
                        best_class = j3[2:0];
                    end
                    if (s2_logit[j3] < min_logit)
                        min_logit = s2_logit[j3];
                end

                ml_class <= best_class;

                // Confidence: (max - min) clipped to 8 bits
                // Larger gap = more confident prediction
                gap = max_logit - min_logit;
                if (gap >= 32'sd65280)       // 255 << 8
                    ml_confidence <= 8'd255;
                else if (gap <= 32'sd0)
                    ml_confidence <= 8'd0;
                else
                    ml_confidence <= gap[15:8];
            end
        end
    end

endmodule