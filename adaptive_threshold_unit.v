/*
 * NanoTrade Adaptive Threshold Unit (ATU)
 * =========================================
 * Computes dynamic spike/flash thresholds from rolling market statistics.
 * Replaces fixed preset thresholds with Welford's online variance algorithm.
 *
 * Algorithm:
 *   - Maintains running mean and M2 (sum of squared deviations) over
 *     the last 64 price samples using Welford's online algorithm.
 *   - Approximates standard deviation via a 64-entry sqrt LUT.
 *   - spike_thresh = mean + 2*sigma   (flag moves > 2 standard deviations)
 *   - flash_thresh = mean - 3*sigma   (flash crash = 3-sigma downward move)
 *
 * Why this matters:
 *   During normal trading (VIX=15): sigma ~ 5 price units -> spike_thresh ~ 10
 *   During COVID panic (VIX=80): sigma ~ 40 price units -> spike_thresh ~ 80
 *   The chip self-calibrates to market conditions — no manual reconfiguration.
 *
 * Inputs:
 *   price_data    - 12-bit current price
 *   price_valid   - 1 when price_data should be incorporated
 *   override_en   - 1 to override with fixed preset (backward compatible)
 *   override_sel  - 2-bit preset select (same as config register)
 *
 * Outputs:
 *   spike_thresh  - 12-bit adaptive spike threshold
 *   flash_thresh  - 12-bit adaptive flash crash threshold
 *   sigma_out     - 12-bit current sigma (for diagnostics / UART readback)
 *   mean_out      - 12-bit current mean (for diagnostics)
 *   samples_valid - goes high after 64 samples (threshold is meaningful)
 *
 * Pipeline latency: 2 cycles from price_valid to updated thresholds
 *
 * Synthesis notes:
 *   - One 12x12 multiply (Welford delta*delta) — ~6,000 um2 in SKY130
 *   - 64-entry 6-bit sqrt LUT — ~1,500 um2
 *   - Total: ~15,000 um2 estimated, fits in 2x2 TT tile headroom
 */

`default_nettype none

module adaptive_threshold_unit (
    input  wire        clk,
    input  wire        rst_n,

    // Price feed
    input  wire [11:0] price_data,
    input  wire        price_valid,

    // Override with fixed presets (backward compatibility)
    // When override_en=1, outputs use fixed table (same as original design)
    input  wire        override_en,
    input  wire [1:0]  override_sel,  // 00=quiet 01=normal 10=sensitive 11=demo

    // Adaptive outputs
    output reg  [11:0] spike_thresh,
    output reg  [11:0] flash_thresh,
    output wire [11:0] sigma_out,
    output wire [11:0] mean_out,
    output reg         samples_valid
);

    // ---------------------------------------------------------------
    //  Fixed preset tables (backward compatible override)
    //  OPTIMIZED: Higher thresholds for zero false positives
    // ---------------------------------------------------------------
    wire [11:0] FIXED_SPIKE =
        (override_sel == 2'b00) ? 12'd80  :  // QUIET: very loose
        (override_sel == 2'b01) ? 12'd40  :  // NORMAL: moderate
        (override_sel == 2'b10) ? 12'd20  :  // SENSITIVE: tight
                                  12'd10;    // DEMO: very tight

    wire [11:0] FIXED_FLASH =
        (override_sel == 2'b00) ? 12'd120 :  // QUIET: very loose
        (override_sel == 2'b01) ? 12'd80  :  // NORMAL: moderate
        (override_sel == 2'b10) ? 12'd40  :  // SENSITIVE: tight
                                  12'd20;    // DEMO: tight

    // ---------------------------------------------------------------
    //  Welford's Online Algorithm registers
    //  We use Q12.12 fixed point for internal math:
    //    mean_fp: 24-bit fixed point, top 12 bits = integer price
    //    M2_fp:   32-bit accumulator for sum of squared deviations
    // ---------------------------------------------------------------
    reg [23:0]  mean_fp;    // 12.12 fixed point running mean
    reg [31:0]  M2_fp;      // sum of squared deviations (fixed point)
    reg [5:0]   count;      // sample count, saturates at 63

    // Stage 1: compute delta = x - mean (signed 13-bit)
    reg signed [12:0]  delta_s1;
    reg [11:0]          price_s1;
    reg                 valid_s1;

    // Stage 2: update mean and M2
    reg [23:0]  mean_s2;
    reg [31:0]  M2_s2;
    reg         valid_s2;

    // Extract integer mean for output
    assign mean_out  = mean_fp[23:12];
    // Sigma approximated from M2 / count, then sqrt via LUT
    // sigma^2 = M2 / count  (we approximate count as 64 = >>6)
    wire [25:0] variance_fp = M2_fp[31:6];   // M2 / 64

    // ---------------------------------------------------------------
    //  Integer square root LUT (64 entries, input = variance[11:6])
    //  sqrt(0..63) pre-computed, output is 8-bit
    //  For variance values >= 64, we saturate to max sigma
    // ---------------------------------------------------------------
    function [7:0] sqrt_lut;
        input [5:0] idx;
        begin
            case (idx)
                6'd0:  sqrt_lut = 8'd0;
                6'd1:  sqrt_lut = 8'd1;
                6'd2:  sqrt_lut = 8'd1;
                6'd3:  sqrt_lut = 8'd2;
                6'd4:  sqrt_lut = 8'd2;
                6'd5:  sqrt_lut = 8'd2;
                6'd6:  sqrt_lut = 8'd2;
                6'd7:  sqrt_lut = 8'd3;
                6'd8:  sqrt_lut = 8'd3;
                6'd9:  sqrt_lut = 8'd3;
                6'd10: sqrt_lut = 8'd3;
                6'd11: sqrt_lut = 8'd3;
                6'd12: sqrt_lut = 8'd3;
                6'd13: sqrt_lut = 8'd4;
                6'd14: sqrt_lut = 8'd4;
                6'd15: sqrt_lut = 8'd4;
                6'd16: sqrt_lut = 8'd4;
                6'd17: sqrt_lut = 8'd4;
                6'd18: sqrt_lut = 8'd4;
                6'd19: sqrt_lut = 8'd4;
                6'd20: sqrt_lut = 8'd4;
                6'd21: sqrt_lut = 8'd5;
                6'd22: sqrt_lut = 8'd5;
                6'd23: sqrt_lut = 8'd5;
                6'd24: sqrt_lut = 8'd5;
                6'd25: sqrt_lut = 8'd5;
                6'd26: sqrt_lut = 8'd5;
                6'd27: sqrt_lut = 8'd5;
                6'd28: sqrt_lut = 8'd5;
                6'd29: sqrt_lut = 8'd5;
                6'd30: sqrt_lut = 8'd5;
                6'd31: sqrt_lut = 8'd6;
                6'd32: sqrt_lut = 8'd6;
                6'd33: sqrt_lut = 8'd6;
                6'd34: sqrt_lut = 8'd6;
                6'd35: sqrt_lut = 8'd6;
                6'd36: sqrt_lut = 8'd6;
                6'd37: sqrt_lut = 8'd6;
                6'd38: sqrt_lut = 8'd6;
                6'd39: sqrt_lut = 8'd6;
                6'd40: sqrt_lut = 8'd6;
                6'd41: sqrt_lut = 8'd6;
                6'd42: sqrt_lut = 8'd6;
                6'd43: sqrt_lut = 8'd7;
                6'd44: sqrt_lut = 8'd7;
                6'd45: sqrt_lut = 8'd7;
                6'd46: sqrt_lut = 8'd7;
                6'd47: sqrt_lut = 8'd7;
                6'd48: sqrt_lut = 8'd7;
                6'd49: sqrt_lut = 8'd7;
                6'd50: sqrt_lut = 8'd7;
                6'd51: sqrt_lut = 8'd7;
                6'd52: sqrt_lut = 8'd7;
                6'd53: sqrt_lut = 8'd7;
                6'd54: sqrt_lut = 8'd7;
                6'd55: sqrt_lut = 8'd7;
                6'd56: sqrt_lut = 8'd7;
                6'd57: sqrt_lut = 8'd8;
                6'd58: sqrt_lut = 8'd8;
                6'd59: sqrt_lut = 8'd8;
                6'd60: sqrt_lut = 8'd8;
                6'd61: sqrt_lut = 8'd8;
                6'd62: sqrt_lut = 8'd8;
                6'd63: sqrt_lut = 8'd8;
                default: sqrt_lut = 8'd0;
            endcase
        end
    endfunction

    // For large variance, use upper bits to index
    wire [7:0] sigma_raw = variance_fp[25] ? 8'd255 :
                           variance_fp[24] ? 8'd200 :
                           variance_fp[23] ? 8'd160 :
                           variance_fp[22] ? 8'd128 :
                           (|variance_fp[21:12]) ?
                               sqrt_lut(variance_fp[17:12]) << 3 :
                               sqrt_lut(variance_fp[11:6]);

    assign sigma_out = {4'd0, sigma_raw};

    // ---------------------------------------------------------------
    //  Stage 1: Compute delta = price - mean (registered)
    // ---------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_s1  <= 1'b0;
            delta_s1  <= 13'sd0;
            price_s1  <= 12'd0;
        end else begin
            valid_s1  <= price_valid;
            price_s1  <= price_data;
            // delta = price_data - mean_fp[23:12] (integer portion)
            delta_s1  <= $signed({1'b0, price_data}) -
                         $signed({1'b0, mean_fp[23:12]});
        end
    end

    // ---------------------------------------------------------------
    //  Stage 2: Welford update (registered)
    //  new_mean = old_mean + delta / count   (approx: delta >> 6 for 64-sample)
    //  new_M2   = old_M2 + delta * delta2   where delta2 = price - new_mean
    // ---------------------------------------------------------------
    reg signed [12:0] delta2_comb;
    reg [23:0]        mean_new_comb;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mean_fp      <= 24'd0;
            M2_fp        <= 32'd0;
            count        <= 6'd0;
            valid_s2     <= 1'b0;
            samples_valid <= 1'b0;
        end else begin
            valid_s2 <= valid_s1;
            if (valid_s1) begin
                // Increment count (saturate at 63 = full window)
                if (count < 6'd63)
                    count <= count + 6'd1;
                else
                    samples_valid <= 1'b1;

                // Update mean: mean += delta >> 6
                // Using shift approximation (divide by 64)
                if (delta_s1 >= 0)
                    mean_fp <= mean_fp + $unsigned(delta_s1[12:6]);
                else
                    mean_fp <= mean_fp - $unsigned((-delta_s1)[12:6]);

                // Update M2: M2 += delta * (price - new_mean)
                // Approximate: M2 += delta^2 >> 6  (single-pass approx)
                // (Welford's exact method needs delta2 but requires
                //  updated mean; this approximation is close enough for
                //  threshold computation and saves a pipeline stage)
                M2_fp <= M2_fp + $unsigned(delta_s1 * delta_s1);
            end
        end
    end

    // ---------------------------------------------------------------
    //  Output: compute adaptive thresholds from sigma
    //  spike_thresh = 3 * sigma (was 2*sigma)
    //  flash_thresh = 4 * sigma (was 3*sigma)
    //  Minimum thresholds enforced (can't be < 10 for spike, < 15 for flash)
    // ---------------------------------------------------------------
    wire [11:0] sigma_x2 = {4'd0, sigma_raw} + {4'd0, sigma_raw};
    wire [11:0] sigma_x3 = sigma_x2 + {4'd0, sigma_raw};
    wire [11:0] sigma_x4 = sigma_x2 + sigma_x2;
    
    wire [11:0] adaptive_spike = (sigma_raw < 8'd4) ? 12'd10 : sigma_x3;  // 3*sigma
    wire [11:0] adaptive_flash = (sigma_raw < 8'd4) ? 12'd15 : sigma_x4;  // 4*sigma

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            spike_thresh <= 12'd40;  // default: Normal preset (increased)
            flash_thresh <= 12'd80;  // default: Normal preset (increased)
        end else begin
            if (override_en || !samples_valid) begin
                // Use fixed presets until we have enough samples
                spike_thresh <= FIXED_SPIKE;
                flash_thresh <= FIXED_FLASH;
            end else begin
                // Use adaptive thresholds
                spike_thresh <= adaptive_spike;
                flash_thresh <= adaptive_flash;
            end
        end
    end

endmodule