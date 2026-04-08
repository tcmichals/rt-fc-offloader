`default_nettype none


module pwmdecoder #(
        parameter clockFreq = 50000000)
        (input wire i_clk,
        input wire i_pwm,
        input wire i_resetn,
        output wire  o_pwm_ready,
        output reg [15:0] o_pwm_value);

reg [15:0] pwm_on_count;
reg [15:0] pwm_off_count;
reg pwm_ready;
reg [1:0] state;
reg [15:0] clk_counter;
reg [1:0] pwm_sig;

localparam CLK_DIVIDER = (clockFreq / 1_000_000) -1;
localparam GUARD_ERROR_LOW 	= 16'hC000;  // No signal (timeout)
localparam GUARD_ERROR_HIGH = 16'h8000;  // Pulse too long (>max)
localparam GUARD_ERROR_SHORT = 16'h4000; // Pulse too short (<min)

localparam MEASURING_ON = 2'b1;
localparam MEASURING_OFF = 2'b0;
localparam MEASURE_COMPLETE = 2'b10;

localparam NO_ERROR = 16'h0;
localparam GUARD_TIME_ON_MAX = 16'd2600; 
localparam GUARD_TIME_ON_MIN = 16'd750;  // 750us min with 50us margin for clock alignment
localparam GUARD_TIME_OFF_MAX = 16'd20000;

initial begin
    pwm_ready = 0;
    state = MEASURING_OFF;
    clk_counter =0; 
    pwm_on_count = 0;
    pwm_off_count = 0;
    pwm_sig = 0;
    o_pwm_value = GUARD_ERROR_LOW;
end


assign o_pwm_ready = pwm_ready;

always @(posedge i_clk or negedge i_resetn) begin

    if (!i_resetn) begin
        pwm_ready <= 0;
        state <= MEASURING_OFF;
        clk_counter <= 0; 
        pwm_on_count <= 0;
        pwm_off_count <= 0;
        pwm_sig <= 0;
	    o_pwm_value <= GUARD_ERROR_LOW;
    end
    else begin
        //synchronize FF
        pwm_sig = {pwm_sig[0], i_pwm};

        // Default counter increment (overridden in state machine if needed)
        // But logic below relies on specific counter values. 
        // Let's manage it strictly within the state machine or a single block.
        
        // Counter Logic merged here
        if (clk_counter < CLK_DIVIDER)
             clk_counter <= clk_counter + 1'b1;
        else
             clk_counter <= 0;

        case (state)

            MEASURING_OFF: begin 
                if (pwm_sig[1] == 0) 
                begin
                    if (clk_counter == CLK_DIVIDER ) 
                    begin
                        if (pwm_off_count < GUARD_TIME_OFF_MAX)
                            pwm_off_count <= pwm_off_count + 1'b1;
                        else 
                        begin
			                /* use pwm_off_count greater then 26ms, notify pwm*/
                            o_pwm_value <= pwm_off_count | GUARD_ERROR_LOW; 
		                    pwm_ready <= 1;
                    	   state <= MEASURE_COMPLETE;
                        end
                    end
                end
                else begin
                    pwm_on_count <= 0;
                    pwm_ready <= 0;
                    state <= MEASURING_ON;
                    clk_counter <= 0;
                end
            end

            MEASURING_ON: begin /* measure on */
                if (pwm_sig[1]) begin
                    if (clk_counter == CLK_DIVIDER )
                    begin
                        if (pwm_on_count < GUARD_TIME_ON_MAX)                           
                            pwm_on_count <= pwm_on_count + 1'b1;
                        else begin
						    state <= MEASURE_COMPLETE;
							o_pwm_value <= pwm_on_count  | GUARD_ERROR_HIGH;
							pwm_ready <= 1;
						end
                    end
                end
                else 
                begin
                    pwm_ready <= 1;
                    state <= MEASURE_COMPLETE;
                    // Check for too-short pulse (below minimum guard time)
                    if (pwm_on_count < GUARD_TIME_ON_MIN)
                        o_pwm_value <= pwm_on_count | GUARD_ERROR_SHORT;
                    else
		                o_pwm_value <= pwm_on_count;
                end
            end

            MEASURE_COMPLETE: begin /* restart measurement */
                clk_counter <= 0;
                pwm_ready <= 0;
                state <= MEASURING_OFF;
                pwm_on_count <=0;
                pwm_off_count <= 0;
            end

        endcase 
    end
end

endmodule