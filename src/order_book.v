/*
 * NanoTrade Order Book Engine
 *
 * Maintains a 4-entry bid queue and 4-entry ask queue.
 * Performs price-time priority matching every clock cycle.
 *
 * Input encoding (input_type):
 *   2'b10 = Buy order  -> price = {ext_data[0], data_in[5:0]} = 7-bit price
 *   2'b11 = Sell order -> price = {ext_data[0], data_in[5:0]} = 7-bit price
 *   Quantity is fixed at data_in[2:0] * 8 for simplicity on limited I/O
 *
 * Match occurs when best_bid_price >= best_ask_price
 * Output: match_valid=1 with match_price for one cycle
 */

`default_nettype none

module order_book (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [1:0] input_type,   // 10=buy, 11=sell
    input  wire [5:0] data_in,      // low 6 bits of price/qty
    input  wire [5:0] ext_data,     // high 6 bits (ext_data[0] = MSB of price)
    output reg        match_valid,
    output reg  [7:0] match_price
);

    // Order book entries: 4 bids, 4 asks
    // Each entry: [valid, price[6:0]]
    reg [7:0] bid [0:3];  // bid[i] = {valid, price[6:0]}
    reg [7:0] ask [0:3];

    wire [6:0] new_price = {ext_data[0], data_in[5:1]};  // 7-bit price
    wire       is_buy    = (input_type == 2'b10);
    wire       is_sell   = (input_type == 2'b11);
    wire       is_order  = is_buy | is_sell;

    // Best bid = highest valid bid price
    reg [6:0] best_bid;
    reg       best_bid_valid;
    reg [1:0] best_bid_idx;

    // Best ask = lowest valid ask price
    reg [6:0] best_ask;
    reg       best_ask_valid;
    reg [1:0] best_ask_idx;

    integer i;

    // Combinational: find best bid/ask every cycle
    always @(*) begin
        best_bid       = 7'h00;
        best_bid_valid = 1'b0;
        best_bid_idx   = 2'd0;
        best_ask       = 7'h7F;
        best_ask_valid = 1'b0;
        best_ask_idx   = 2'd0;

        // Find highest bid
        for (i = 0; i < 4; i = i + 1) begin
            if (bid[i][7] && (!best_bid_valid || bid[i][6:0] > best_bid)) begin
                best_bid       = bid[i][6:0];
                best_bid_valid = 1'b1;
                best_bid_idx   = i[1:0];
            end
        end

        // Find lowest ask
        for (i = 0; i < 4; i = i + 1) begin
            if (ask[i][7] && (!best_ask_valid || ask[i][6:0] < best_ask)) begin
                best_ask       = ask[i][6:0];
                best_ask_valid = 1'b1;
                best_ask_idx   = i[1:0];
            end
        end
    end

    // Find first empty slot
    reg [1:0] empty_bid_slot;
    reg       has_empty_bid;
    reg [1:0] empty_ask_slot;
    reg       has_empty_ask;

    always @(*) begin
        empty_bid_slot = 2'd0;
        has_empty_bid  = 1'b0;
        empty_ask_slot = 2'd0;
        has_empty_ask  = 1'b0;
        for (i = 3; i >= 0; i = i - 1) begin
            if (!bid[i][7]) begin
                empty_bid_slot = i[1:0];
                has_empty_bid  = 1'b1;
            end
            if (!ask[i][7]) begin
                empty_ask_slot = i[1:0];
                has_empty_ask  = 1'b1;
            end
        end
    end

    // Sequential: insert orders + perform matching
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            match_valid <= 1'b0;
            match_price <= 8'd0;
            for (i = 0; i < 4; i = i + 1) begin
                bid[i] <= 8'h00;
                ask[i] <= 8'h00;
            end
        end else begin
            match_valid <= 1'b0;

            // Step 1: Insert new order
            if (is_buy && has_empty_bid) begin
                bid[empty_bid_slot] <= {1'b1, new_price};
            end
            if (is_sell && has_empty_ask) begin
                ask[empty_ask_slot] <= {1'b1, new_price};
            end

            // Step 2: Match (use registered best bid/ask from last cycle for timing)
            if (best_bid_valid && best_ask_valid && (best_bid >= best_ask)) begin
                // Match! Execute at ask price (maker wins)
                match_valid <= 1'b1;
                match_price <= {1'b0, best_ask};  // 8-bit output

                // Remove matched orders from book
                bid[best_bid_idx] <= 8'h00;
                ask[best_ask_idx] <= 8'h00;
            end
        end
    end

endmodule
