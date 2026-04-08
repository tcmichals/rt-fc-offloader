/**
 * DSHOT Protocol Output Module
 * 
 * Implements DSHOT digital ESC protocol for motor control.
 * 
 * DSHOT Frame Format (16 bits total):
 * ┌────────────────┬──────────┬─────────┐
 * │  Throttle      │ Telemetry│   CRC   │
 * │  (11 bits)     │ (1 bit)  │ (4 bits)│
 * └────────────────┴──────────┴─────────┘
 *  MSB                                LSB
 * 
 * Bits [15:5]  - Throttle value (0-2047)
 *                0      = Disarmed/Motor Stop
 *                1-47   = Reserved for special commands
 *                48-2047 = Throttle range (48 = min, 2047 = max)
 * 
 * Bit  [4]     - Telemetry request (1 = request telemetry data)
 * 
 * Bits [3:0]   - CRC checksum (calculated over throttle + telemetry bits)
 *                CRC = (throttle ^ (throttle >> 4) ^ (throttle >> 8)) & 0x0F
 * 
 * Special Commands (throttle values 1-47):
 *   0  = Disarmed/Motor Stop
 *   1-5    = Reserved
 *   6      = ESC Info Request
 *   7      = Spin Direction 1
 *   8      = Spin Direction 2  
 *   9      = 3D Mode Off
 *   10     = 3D Mode On
 *   11     = ESC Settings Request
 *   12     = Save Settings
 *   20     = Spin Direction Normal
 *   21     = Spin Direction Reversed
 *   22-47  = Reserved
 * 
 * DSHOT Protocol Timing (for DSHOT150):
 * - Bit period: 6.67µs
 * - Bit "0": 2.5µs HIGH, 4.17µs LOW
 * - Bit "1": 5.0µs HIGH, 1.67µs LOW
 * - Guard time: min 250µs between frames
 * 
 * NOTE: The master/host is responsible for:
 * 1. Encoding the 11-bit throttle value + telemetry bit into bits [15:4]
 * 2. Calculating and inserting the 4-bit CRC into bits [3:0]
 * 3. Respecting the guard time between successive writes
 * 
 * This module handles:
 * 1. Converting each bit into proper DSHOT timing (HIGH/LOW durations)
 * 2. Enforcing guard time (rejecting writes that come too soon)
 * 3. Generating the PWM output signal
 * 
 * This module does NOT:
 * - Parse or validate the frame structure
 * - Calculate or check CRC
 * - Decode throttle values or special commands
 * - Support telemetry feedback (future enhancement)
 * 
 * It is a pure bit-level transmitter - the host/software handles all protocol encoding.
 */

`default_nettype none
`timescale 1 ns / 1 ns

module dshot_output #(
		parameter clockFrequency = 54000000  // 54 MHz clock (Tang Nano 9K PLL)
	) (
		input  wire        i_clk,          //       clock.clk
		input  wire        i_reset,        //       reset.reset
		input  wire [15:0] i_dshot_value,  // Full 16-bit DSHOT frame (throttle[15:5] + telem[4] + crc[3:0])
		input  wire [15:0] i_dshot_mode,   // DSHOT protocol speed: 150, 300, or 600
		input  wire        i_write,        //       write strobe
		output wire	       o_pwm,          // DSHOT PWM output signal
		output wire        o_ready         // Ready for new command (guard time elapsed)
	);
	
	// Frequency validation - minimum 10 MHz required for accurate DSHOT timing
	generate
		if (clockFrequency < 10_000_000) begin
			initial $error("clockFrequency must be >= 10 MHz for DSHOT timing. Current: %0d Hz", clockFrequency);
		end
	endgenerate


/* state machine state of single bit */
localparam [3:0] INIT_TIME  = 4'h0,
		 		HIGH_TIME   = 4'h1,
	     	 	LOW_TIME    = 4'h2,
            IDLE_	    = 4'h3;
		
/* DSHOT Bit time:              (1 - TH1)   (0-T0H)
DSHOT 150 Bit time is 6.67us    5.00us      2.50us
DSHOT 300 Bit time is 3.33us    2.50us      1.25us
DSHOT 600 Bit time is 1.67us    1.25us      0.625us
DSHOT1200 Bit time is 0.83us    0.625us     0.313us
*/

/* Timing calculations based on i_dshot_mode input
   DSHOT150: Bit "0" HIGH=2.50µs, LOW=4.17µs  |  Bit "1" HIGH=5.00µs, LOW=1.67µs
   DSHOT300: Bit "0" HIGH=1.25µs, LOW=2.08µs  |  Bit "1" HIGH=2.50µs, LOW=0.83µs
   DSHOT600: Bit "0" HIGH=0.625µs, LOW=1.04µs |  Bit "1" HIGH=1.25µs, LOW=0.42µs
   
   Convert to clock cycles based on clockFrequency parameter.
   Note: Timing is calculated at runtime based on i_dshot_mode input.
*/

// Timing constants for each mode (calculated from clockFrequency parameter)
localparam [15:0] GUARD_BAND_SIGNAL = 16'd7;  // Timing adjustment for signal edges

// DSHOT150 timing (based on clockFrequency)
localparam [15:0] T0H_150 = (clockFrequency * 25) / 10000000;   // 2.50µs
localparam [15:0] T0L_150 = (clockFrequency * 417) / 100000000; // 4.17µs
localparam [15:0] T1H_150 = (clockFrequency * 50) / 10000000;   // 5.00µs
localparam [15:0] T1L_150 = (clockFrequency * 167) / 100000000; // 1.67µs
localparam [15:0] GUARD_150 = (clockFrequency * 250) / 1000000; // 250µs

// DSHOT300 timing (based on clockFrequency)
localparam [15:0] T0H_300 = (clockFrequency * 125) / 100000000;  // 1.25µs
localparam [15:0] T0L_300 = (clockFrequency * 208) / 100000000;  // 2.08µs
localparam [15:0] T1H_300 = (clockFrequency * 25) / 10000000;    // 2.50µs
localparam [15:0] T1L_300 = (clockFrequency * 83) / 100000000;   // 0.83µs
localparam [15:0] GUARD_300 = (clockFrequency * 125) / 1000000;  // 125µs

// DSHOT600 timing (based on clockFrequency)
localparam [15:0] T0H_600 = (clockFrequency * 625) / 1000000000;  // 0.625µs
localparam [15:0] T0L_600 = (clockFrequency * 104) / 100000000;   // 1.04µs
localparam [15:0] T1H_600 = (clockFrequency * 125) / 100000000;   // 1.25µs
localparam [15:0] T1L_600 = (clockFrequency * 42) / 100000000;    // 0.42µs
localparam [15:0] GUARD_600 = (clockFrequency * 625) / 10000000;  // 62.5µs

/* number of bits to shift */
localparam [3:0] NUM_BIT_TO_SHIFT = 15;

// Runtime-selectable timing values (REGISTERED for timing closure)
reg [15:0] t0h_clocks;
reg [15:0] t0l_clocks;
reg [15:0] t1h_clocks;
reg [15:0] t1l_clocks;
reg [15:0] guard_time_val;
reg [15:0] dshot_mode_latched;  // Latched mode for stable timing

reg [3:0] state;
reg [4:0] bits_to_shift;
reg [15:0] counter_high;
reg [15:0] counter_low;

reg [15:0] dshot_command;
reg [15:0] guard_count;


reg pwm;
reg ready_reg;  // Registered ready signal for timing closure

// Register the timing parameters on clock edge (only when idle)
// This breaks the critical combinational path
always @(posedge i_clk or posedge i_reset) begin
	if (i_reset) begin
		t0h_clocks <= T0H_150;
		t0l_clocks <= T0L_150;
		t1h_clocks <= T1H_150;
		t1l_clocks <= T1L_150;
		guard_time_val <= GUARD_150;
		dshot_mode_latched <= 16'd150;
	end else if (state == IDLE_ && guard_count == 0) begin
		// Only update timing when idle - safe to change mode
		if (i_dshot_mode != dshot_mode_latched) begin
			dshot_mode_latched <= i_dshot_mode;
			case (i_dshot_mode)
				16'd300: begin
					t0h_clocks <= T0H_300;
					t0l_clocks <= T0L_300;
					t1h_clocks <= T1H_300;
					t1l_clocks <= T1L_300;
					guard_time_val <= GUARD_300;
				end
				16'd600: begin
					t0h_clocks <= T0H_600;
					t0l_clocks <= T0L_600;
					t1h_clocks <= T1H_600;
					t1l_clocks <= T1L_600;
					guard_time_val <= GUARD_600;
				end
				default: begin  // DSHOT150
					t0h_clocks <= T0H_150;
					t0l_clocks <= T0L_150;
					t1h_clocks <= T1H_150;
					t1l_clocks <= T1L_150;
					guard_time_val <= GUARD_150;
				end
			endcase
		end
	end
end


always @(posedge i_clk or posedge i_reset) begin	

	if (i_reset) begin
		state <= IDLE_;
		bits_to_shift <= 0;
		dshot_command <= 0;
		pwm <= 0;
		guard_count <= 0;  // Start with 0 so first write is accepted
		ready_reg <= 1'b1; // Ready after reset
	end
	else begin
		/* update pwm value - accept write when IDLE and guard time expired */
		if (i_write && (state == IDLE_) && (guard_count == 0)) begin
			dshot_command <= i_dshot_value;
			bits_to_shift <= NUM_BIT_TO_SHIFT;
			state <= INIT_TIME;
			ready_reg <= 1'b0;  // Not ready while transmitting
			`ifdef SIMULATION
			$display ("[%0t] Accepted write: 0x%04X (mode=%0d)", $time, i_dshot_value, i_dshot_mode);
			`endif
			guard_count <= guard_time_val;  // Use selected guard time
		end
		else begin
			`ifdef SIMULATION
			if (i_write) begin
				// Debug: why wasn't write accepted?
				$display ("[%0t] Write REJECTED: state=%0d, guard_count=%0d", 
					$time, state, guard_count);
			end
			`endif
			
			case (state)
				INIT_TIME: begin
					`ifdef SIMULATION
					$display ("[%0t] INIT_TIME: bit %0d, value=0x%04X, MSB=%b", 
						$time, (NUM_BIT_TO_SHIFT - bits_to_shift), dshot_command, dshot_command[15]);
					`endif
					if (dshot_command[15]) begin
						counter_high <= t1h_clocks - GUARD_BAND_SIGNAL;
						counter_low <= t1l_clocks + GUARD_BAND_SIGNAL;
					end
					else begin
						counter_high <= t0h_clocks - GUARD_BAND_SIGNAL;
						counter_low <= t0l_clocks + GUARD_BAND_SIGNAL;
					end
					state <= HIGH_TIME;
				end

				HIGH_TIME: begin
					pwm <= 1;
					if (counter_high == 0)	begin
						state <= LOW_TIME;
					end
					else			
						counter_high <= counter_high -1'b1;

				end
				LOW_TIME: begin
					pwm <= 0;
					if (counter_low == 0) begin
						if (bits_to_shift == 0) begin
							// All bits transmitted, go to IDLE
							state <= IDLE_;
							`ifdef SIMULATION
							$display("[%0t] Transmission complete", $time);
							`endif
						end
						else begin
							// More bits to send, move to next bit
							bits_to_shift <= bits_to_shift - 1'b1;
						  	dshot_command <= {dshot_command[14:0], 1'b0};
						  	state <= INIT_TIME;
						end
					end
					else
						counter_low <= counter_low - 1'b1;
					
				end
				IDLE_: begin
					`ifdef SIMULATION
					if (guard_count != 0 && guard_count % 1000 == 0)
						$display("[%0t] IDLE_ case executing: guard_count=%0d", $time, guard_count);
					`endif
					if (guard_count != 0) begin
				 		guard_count <= guard_count -1'b1;
				 		ready_reg <= 1'b0;
				 	end else begin
				 		ready_reg <= 1'b1;  // Ready when guard time elapsed
				 	end
				end
		
				default: begin
					state <= IDLE_;
					pwm <= 0;
				end
			endcase
		
		end
	end
	
end
assign o_pwm = pwm;
assign o_ready = ready_reg;  // Registered ready signal for timing closure

endmodule

`default_nettype wire

