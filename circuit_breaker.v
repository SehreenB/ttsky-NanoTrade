`default_nettype none

module circuit_breaker #(
    parameter integer CONF_BITS = 8
)(
    input  wire                  clk,
    input  wire                  rst_n,

    // Trigger source (ML or cascade or rule->ML)
    input  wire                  trig_valid,      // may be multi-cycle level
    input  wire [2:0]            trig_class,      // 0=NORMAL, 3=FLASH, 4=IMB, 5=STUFF
    input  wire [CONF_BITS-1:0]  trig_conf,       // e.g. 60 => freeze 120 cycles

    // Outputs: what the book is allowed to do
    output reg  [1:0]            cb_state,        // 00 NORMAL, 01 THROTTLE, 10 WIDEN, 11 PAUSE
    output reg                   cb_active,
    output reg  [15:0]           cb_countdown,

    // Policy knobs
    output reg                   allow_order,     // whether we accept new orders this cycle
    output reg                   allow_match,     // whether matching is allowed this cycle
    output reg  [3:0]            spread_guard,    // ask must be <= bid - guard to match (guard in ticks)

    // Throttle policy: 1 order per (throttle_div) cycles
    input  wire [2:0]            throttle_div     // e.g. 4 => 1 per 4 cycles
);

    // Encodings match your logs:
    localparam [1:0] S_NORMAL   = 2'b00;
    localparam [1:0] S_THROTTLE = 2'b01;
    localparam [1:0] S_WIDEN    = 2'b10;
    localparam [1:0] S_PAUSE    = 2'b11;

    // Trigger classes (match your project)
    localparam [2:0] C_NORMAL   = 3'd0;
    localparam [2:0] C_SPIKE    = 3'd1; // not used here, but reserved
    localparam [2:0] C_VOL      = 3'd2; // reserved
    localparam [2:0] C_FLASH    = 3'd3; // FLASH_CRASH -> PAUSE
    localparam [2:0] C_IMB      = 3'd4; // ORDER_IMBALANCE -> WIDEN
    localparam [2:0] C_STUFF    = 3'd5; // QUOTE_STUFFING -> THROTTLE

    // Throttle credit system: lets exactly 1 order through every N cycles
    reg [2:0] throttle_ctr;
    reg       throttle_credit;

    // Latch-once gating:
    // Only accept a trigger when we are in NORMAL state
    wire accept_trig = trig_valid && (cb_state == S_NORMAL);

    // Convert confidence to pause length (your spec: 60 => 120 cycles)
    wire [15:0] freeze_cycles = {8'd0, trig_conf} << 1; // conf * 2

    // Helper: set outputs based on state every cycle (combinational-ish but in sequential block)
    task automatic update_policy;
        begin
            allow_match  = (cb_state != S_PAUSE);
            spread_guard = (cb_state == S_WIDEN) ? 4'd2 : 4'd0;

            if (cb_state == S_PAUSE) begin
                allow_order = 1'b0;
            end else if (cb_state == S_THROTTLE) begin
                allow_order = throttle_credit;  // only allow if we have credit
            end else begin
                allow_order = 1'b1;
            end
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cb_state       <= S_NORMAL;
            cb_active      <= 1'b0;
            cb_countdown   <= 16'd0;

            throttle_ctr   <= 3'd0;
            throttle_credit<= 1'b1;

            allow_order    <= 1'b1;
            allow_match    <= 1'b1;
            spread_guard   <= 4'd0;
        end else begin
            // --- Throttle credit generator ---
            // Credit becomes 1 once every throttle_div cycles, then consumed by allow_order path.
            if (cb_state != S_THROTTLE) begin
                throttle_ctr    <= 3'd0;
                throttle_credit <= 1'b1;
            end else begin
                if (throttle_credit) begin
                    // credit stays high until used (your wrapper should consume it when an order is actually accepted)
                    // we'll clear it here when allow_order is asserted (meaning we "spent" it)
                    if (allow_order) begin
                        throttle_credit <= 1'b0;
                        throttle_ctr    <= 3'd0;
                    end
                end else begin
                    // count cycles until refill
                    if (throttle_ctr == (throttle_div - 1'b1)) begin
                        throttle_ctr    <= 3'd0;
                        throttle_credit <= 1'b1;
                    end else begin
                        throttle_ctr    <= throttle_ctr + 3'd1;
                    end
                end
            end

            // --- State machine ---
            if (accept_trig) begin
                // Latch-once: only NORMAL can accept
                case (trig_class)
                    C_FLASH: begin
                        cb_state     <= S_PAUSE;
                        cb_active    <= 1'b1;
                        cb_countdown <= freeze_cycles;     // e.g. 120 cycles
                    end
                    C_STUFF: begin
                        cb_state     <= S_THROTTLE;
                        cb_active    <= 1'b1;
                        cb_countdown <= freeze_cycles;     // reuse same scaling
                    end
                    C_IMB: begin
                        cb_state     <= S_WIDEN;
                        cb_active    <= 1'b1;
                        cb_countdown <= freeze_cycles;
                    end
                    default: begin
                        cb_state     <= S_NORMAL;
                        cb_active    <= 1'b0;
                        cb_countdown <= 16'd0;
                    end
                endcase
            end else if (cb_active) begin
                // Count down exactly once per cycle while active
                if (cb_countdown != 16'd0) begin
                    cb_countdown <= cb_countdown - 16'd1;
                end else begin
                    // Self-heal
                    cb_state     <= S_NORMAL;
                    cb_active    <= 1'b0;
                    cb_countdown <= 16'd0;
                end
            end

            // Update policy outputs based on current state
            update_policy();
        end
    end

endmodule

`default_nettype wire