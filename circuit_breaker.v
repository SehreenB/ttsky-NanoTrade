module circuit_breaker (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [2:0] ml_class,
    input  wire [7:0] ml_confidence,
    input  wire       ml_valid,
    input  wire       rule_alert,
    input  wire [2:0] rule_priority,
    output reg        cb_halt,
    output reg        cb_throttle,
    output reg        cb_throttle_phase,
    output reg [2:0]  cb_state
);

// States
localparam NORMAL   = 3'd0;
localparam THROTTLE = 3'd1;
localparam HALT     = 3'd2;
localparam COOLDOWN = 3'd3;

// ML class codes matching train_and_export.py
localparam ML_NORMAL      = 3'd0;
localparam ML_PRICE_SPIKE = 3'd1;
localparam ML_VOL_SURGE   = 3'd2;
localparam ML_FLASH_CRASH = 3'd3;
localparam ML_IMBALANCE   = 3'd4;
localparam ML_QUOTE_STUFF = 3'd5;

reg [6:0] countdown;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        cb_state          <= NORMAL;
        cb_halt           <= 0;
        cb_throttle       <= 0;
        cb_throttle_phase <= 0;
        countdown         <= 0;
    end else begin

        // Toggle throttle phase every cycle
        cb_throttle_phase <= ~cb_throttle_phase;

        case (cb_state)

            NORMAL: begin
                cb_halt     <= 0;
                cb_throttle <= 0;
                if (ml_valid) begin
                    if (ml_class == ML_FLASH_CRASH) begin
                        if (ml_confidence > 8) begin
                            cb_state  <= HALT;
                            countdown <= 63;
                        end else begin
                            cb_state  <= THROTTLE;
                            countdown <= 31;
                        end
                    end else if (ml_class == ML_QUOTE_STUFF) begin
                        cb_state  <= THROTTLE;
                        countdown <= 15;
                    end else if (ml_class == ML_IMBALANCE &&
                                 ml_confidence > 8) begin
                        cb_state  <= THROTTLE;
                        countdown <= 15;
                    end else if (ml_class == ML_PRICE_SPIKE &&
                                 ml_confidence > 12) begin
                        cb_state  <= THROTTLE;
                        countdown <= 7;
                    end
                end
                // Rule-based override: critical priority halts immediately
                if (rule_alert && rule_priority == 3'd7) begin
                    cb_state  <= HALT;
                    countdown <= 63;
                end
            end

            THROTTLE: begin
                cb_throttle <= 1;
                cb_halt     <= 0;
                if (countdown == 0) begin
                    cb_state    <= COOLDOWN;
                    countdown   <= 15;
                end else begin
                    countdown <= countdown - 1;
                end
                // Escalate to HALT if new flash crash arrives
                if (ml_valid && ml_class == ML_FLASH_CRASH &&
                    ml_confidence > 8) begin
                    cb_state  <= HALT;
                    countdown <= 63;
                end
            end

            HALT: begin
                cb_halt     <= 1;
                cb_throttle <= 0;
                if (countdown == 0) begin
                    cb_state  <= COOLDOWN;
                    countdown <= 31;
                end else begin
                    countdown <= countdown - 1;
                end
            end

            COOLDOWN: begin
                cb_halt     <= 0;
                cb_throttle <= 1;
                if (countdown == 0) begin
                    cb_state    <= NORMAL;
                    cb_throttle <= 0;
                end else begin
                    countdown <= countdown - 1;
                end
            end

        endcase
    end
end

endmodule