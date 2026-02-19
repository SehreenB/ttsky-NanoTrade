/*
 * NanoTrade Anomaly Detector - ALL DETECTORS ENABLED (SKY130 / TinyTapeout)
 *
 * All 6 detectors active with calibrated thresholds for zero false positives
 * on quiet market data while correctly detecting real anomalies.
 *
 * Root-cause fixes vs v1:
 *   A. price_data > 0 guard: idle() sends ui_in=0 (price type, data=0);
 *      ignoring zero-data prevents rolling average corruption.
 *   B. price_sum initialized to 546*8=4368 matching price_hist reset values.
 *   C. price_warmup / vol_warmup: detectors inactive until window is full.
 *   D. Quote-stuff: requires match_rate > 0 and window_timer[7] set (>=128
 *      cycles elapsed) so it can't fire in the first trading window before
 *      any real trade data exists.
 *   E. Velocity: requires BOTH consecutive deltas > spike_thresh (not half),
 *      preventing normal small-move streaks from triggering it.
 *   F. Order imbalance: minimum 8 orders on dominant side (was 4).
 *
 * No dividers, no multipliers wider than 8-bit. SKY130-synthesizable.
 */

`default_nettype none

module anomaly_detector (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [1:0]  input_type,
    input  wire [11:0] price_data,
    input  wire [11:0] volume_data,
    input  wire        match_valid,
    input  wire [7:0]  match_price,
    input  wire [11:0] spike_thresh,
    input  wire [11:0] flash_thresh,
    output wire        alert_any,
    output wire [2:0]  alert_priority,
    output wire [2:0]  alert_type,
    output wire [7:0]  alert_bitmap
);

    wire is_price  = (input_type == 2'b00);
    wire is_volume = (input_type == 2'b01);
    wire is_buy    = (input_type == 2'b10);
    wire is_sell   = (input_type == 2'b11);

    // Price rolling window (8 samples)
    reg [11:0] price_hist [0:7];
    reg [2:0]  price_ptr;
    reg [14:0] price_sum;
    reg [11:0] price_avg;
    reg [11:0] price_mad;
    reg [11:0] current_price;
    reg [11:0] prev_price;
    reg [3:0]  price_warmup;

    // Volume rolling window (8 samples)
    reg [11:0] vol_hist [0:7];
    reg [2:0]  vol_ptr;
    reg [14:0] vol_sum;
    reg [11:0] vol_avg;
    reg [11:0] current_volume;
    reg [3:0]  vol_warmup;

    // Order flow counters
    reg [5:0]  buy_order_count;
    reg [5:0]  sell_order_count;
    reg [5:0]  match_counter;
    reg [5:0]  match_rate;

    // Window timer (256-cycle windows)
    reg [7:0]  window_timer;

    // Velocity: track last two price move directions
    reg        last_move_up;
    reg        prev_move_up;
    reg        last_move_valid;
    reg        prev_move_valid;
    reg [11:0] last_delta;   // magnitude of last move
    reg [11:0] prev_delta;   // magnitude of move before that

    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            price_ptr        <= 3'd0;
            vol_ptr          <= 3'd0;
            price_sum        <= 15'd4368;  // 546*8
            vol_sum          <= 15'd1440;  // 180*8
            price_avg        <= 12'd546;
            vol_avg          <= 12'd180;
            price_mad        <= 12'd5;
            current_price    <= 12'd546;
            prev_price       <= 12'd546;
            current_volume   <= 12'd0;
            price_warmup     <= 4'd0;
            vol_warmup       <= 4'd0;
            buy_order_count  <= 6'd0;
            sell_order_count <= 6'd0;
            match_counter    <= 6'd0;
            match_rate       <= 6'd0;
            window_timer     <= 8'd0;
            last_move_up     <= 1'b0;
            prev_move_up     <= 1'b0;
            last_move_valid  <= 1'b0;
            prev_move_valid  <= 1'b0;
            last_delta       <= 12'd0;
            prev_delta       <= 12'd0;
            for (i = 0; i < 8; i = i + 1) begin
                price_hist[i] <= 12'd546;
                vol_hist[i]   <= 12'd180;
            end
        end else begin

            // Price: guard on > 0 to ignore idle() sending ui_in=0
            if (is_price && (price_data > 12'd0)) begin
                // Velocity tracking: record direction and magnitude
                prev_move_up    <= last_move_up;
                prev_move_valid <= last_move_valid;
                prev_delta      <= last_delta;
                if (price_data >= current_price) begin
                    last_move_up <= 1'b1;
                    last_delta   <= price_data - current_price;
                end else begin
                    last_move_up <= 1'b0;
                    last_delta   <= current_price - price_data;
                end
                last_move_valid <= 1'b1;

                prev_price    <= current_price;
                current_price <= price_data;

                price_sum             <= price_sum - price_hist[price_ptr] + price_data;
                price_hist[price_ptr] <= price_data;
                price_ptr             <= price_ptr + 3'd1;
                price_avg             <= price_sum[14:3];

                if (price_warmup < 4'd8) price_warmup <= price_warmup + 4'd1;

                if (price_data > price_avg)
                    price_mad <= (price_mad * 7 + (price_data - price_avg)) >> 3;
                else
                    price_mad <= (price_mad * 7 + (price_avg - price_data)) >> 3;
            end

            // Volume: guard on > 0
            if (is_volume && (volume_data > 12'd0)) begin
                current_volume        <= volume_data;
                vol_sum               <= vol_sum - vol_hist[vol_ptr] + volume_data;
                vol_hist[vol_ptr]     <= volume_data;
                vol_ptr               <= vol_ptr + 3'd1;
                vol_avg               <= vol_sum[14:3];
                if (vol_warmup < 4'd8) vol_warmup <= vol_warmup + 4'd1;
            end

            if (is_buy)
                buy_order_count  <= (buy_order_count  < 6'h3F) ? buy_order_count  + 6'd1 : 6'h3F;
            if (is_sell)
                sell_order_count <= (sell_order_count < 6'h3F) ? sell_order_count + 6'd1 : 6'h3F;
            if (match_valid)
                match_counter <= (match_counter < 6'h3F) ? match_counter + 6'd1 : 6'h3F;

            window_timer <= window_timer + 8'd1;
            if (window_timer == 8'hFF) begin
                match_rate       <= match_counter;
                match_counter    <= 6'd0;
                buy_order_count  <= buy_order_count  >> 1;
                sell_order_count <= sell_order_count >> 1;
            end
        end
    end

    // ---------------------------------------------------------------
    // Combinational detectors — all SKY130-synthesizable
    // ---------------------------------------------------------------

    wire warmed     = (price_warmup >= 4'd8);
    wire vol_warmed = (vol_warmup   >= 4'd8);

    // FLASH CRASH: price drop > flash_thresh below rolling avg
    wire [11:0] price_drop   = (price_avg > current_price) ? (price_avg - current_price) : 12'd0;
    wire det_flash = warmed && (price_drop > flash_thresh);

    // PRICE SPIKE: |cur - avg| > spike_thresh AND move > 4*MAD
    // (4*MAD filters out spikes during already-volatile periods)
    wire [11:0] price_up_delta  = (current_price > price_avg) ? (current_price - price_avg) : 12'd0;
    wire [11:0] price_any_delta = (price_drop > price_up_delta) ? price_drop : price_up_delta;
    wire [11:0] mad_x4          = {price_mad[9:0], 2'b00};  // MAD*4, capped at 12-bit
    wire det_spike = warmed && (price_any_delta > spike_thresh) && (price_any_delta > mad_x4);

    // VOLUME SURGE: current vol > 3× rolling avg  (3x = x + 2x = avg + avg<<1)
    wire [13:0] vol_3x     = {2'b00, vol_avg} + {1'b0, vol_avg, 1'b0};
    wire det_vol_surge = vol_warmed && ({2'b00, current_volume} > vol_3x) && (vol_avg > 12'd20);

    // ORDER IMBALANCE: one side > 3× other, minimum 8 orders on dominant side
    // FIX: raised min from 4 to 8 to avoid triggering on thin early-session books
    wire [7:0] buy_x3  = {2'b00, buy_order_count}  + {1'b0, buy_order_count,  1'b0};
    wire [7:0] sell_x3 = {2'b00, sell_order_count} + {1'b0, sell_order_count, 1'b0};
    wire det_imbalance = ({2'b00, buy_order_count}  > sell_x3 && buy_order_count  > 6'd8) ||
                         ({2'b00, sell_order_count} > buy_x3  && sell_order_count > 6'd8);

    // QUOTE STUFFING: high order volume with few real trades
    // FIX A: require match_rate > 0 (at least one 256-cycle window of real trade data)
    // FIX B: require window_timer[7]=1 (>=128 cycles since last window reset),
    //        so this can't fire in the first half of the very first window
    // FIX C: raised thresholds: buy>20 AND sell>20 (was 10), total>50 (was 40)
    wire [6:0] total_orders   = {1'b0, buy_order_count} + {1'b0, sell_order_count};
    // Quote stuffing: orders far outpace actual trades (ratio check).
    // Use *8 multiplier (3 bit-shifts) instead of *4 to avoid false triggers
    // during high-activity but legitimate periods (post-fat-finger rebalancing).
    // Also require match_rate > 6 to ensure we have meaningful baseline data.
    wire [8:0] match_rate_x8  = {match_rate, 3'b000};   // match_rate * 8
    wire det_quote_stuff = (match_rate > 6'd6) &&          // meaningful trade baseline
                           window_timer[7] &&               // >=128 cycles of data this window
                           (total_orders > 7'd50) &&        // very high order volume
                           ({2'b00, total_orders} > match_rate_x8) && // orders >> 8x trades
                           (buy_order_count  > 6'd20) &&    // both sides active
                           (sell_order_count > 6'd20);

    // VELOCITY: two consecutive large moves in same direction
    // FIX: require BOTH deltas > spike_thresh (not half-thresh as before)
    // Prevents normal intraday drift from triggering
    wire det_velocity = warmed && last_move_valid && prev_move_valid &&
                        (last_move_up == prev_move_up) &&
                        (last_delta  > spike_thresh) &&
                        (prev_delta  > spike_thresh);

    wire det_vol_dry = 1'b0;  // requires external cancel data, not available on TT pins
    wire det_spread  = 1'b0;  // requires bid/ask separate feeds

    // ---------------------------------------------------------------
    // Priority encoder
    // 7=flash, 6=spike, 5=vol_surge, 4=imbalance, 3=quote_stuff, 2=velocity
    // ---------------------------------------------------------------
    assign alert_any =
        det_flash | det_spike | det_vol_surge | det_imbalance |
        det_quote_stuff | det_velocity;

    assign alert_priority =
        det_flash       ? 3'd7 :
        det_spike       ? 3'd6 :
        det_vol_surge   ? 3'd5 :
        det_imbalance   ? 3'd4 :
        det_quote_stuff ? 3'd3 :
        det_velocity    ? 3'd2 :
                          3'd0;

    assign alert_type =
        det_flash       ? 3'd7 :
        det_spike       ? 3'd0 :
        det_vol_surge   ? 3'd2 :
        det_imbalance   ? 3'd6 :
        det_quote_stuff ? 3'd5 :
        det_velocity    ? 3'd1 :
                          3'd0;

    assign alert_bitmap = {det_flash, det_imbalance, det_spread,
                           det_vol_dry, det_velocity, det_vol_surge,
                           det_quote_stuff, det_spike};

endmodule