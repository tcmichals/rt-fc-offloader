# PIO to RTL Translation Guide

This document shows how RP2040 PIO assembly translates to SystemVerilog RTL, using actual examples from the rt-fc-offloader project.

## DShot: PIO vs RTL

### PIO Implementation (dshot.pio)

```asm
.program dshot_600
    set    pindirs, 1               ; FORCE pin direction to output
start:
    set    pins, 0                [31]      ; drive pin LOW - inter-frame gap
    nop                           [20]      ; min 2us gap before next frame
    pull   block                            ; wait for CPU to push a packet
    out    y, 16                            ; discard top 16 bits (only need 16-bit packet)
bitloop:
    out    y, 1                             ; shift next bit into y
    jmp    !y, outzero                      ; branch on bit value
    set    pins, 1                [26]      ; '1': HIGH for 27 cycles
    set    pins, 0                [9]       ;      LOW  for 13 cycles (total 40)
    jmp    !osre, bitloop                   ; loop until all bits sent
    jmp    start
outzero:
    set    pins, 1                [12]      ; '0': HIGH for 13 cycles
    set    pins, 0                [22]      ;      LOW  for 27 cycles (total 40)
    jmp    !osre, bitloop         [1]       ; loop until all bits sent (+ 1 alignment)
```

**Key PIO Features:**
- `pull block` → Blocking wait for data (AXI-Stream ready/valid)
- `out y, n` → Shift register operation
- `jmp !y, label` → Conditional branch
- `set pins, val [n]` → Output with delay
- `jmp !osre, label` → Loop until shift register empty
- Timing: 40 cycles per bit at DSHOT600 (1.667us)

### RTL Implementation (dshot_out.sv)

```systemverilog
typedef enum logic [1:0] {
    ST_IDLE     = 2'd0,
    ST_INIT     = 2'd1,
    ST_HIGH     = 2'd2,
    ST_LOW      = 2'd3
} state_t;

// DSHOT600 timing (54MHz clock)
localparam logic [15:0] T0H_600   = 16'((64'(CLK_FREQ_HZ) * 625) / 1_000_000_000);  // 34 cycles
localparam logic [15:0] T0L_600   = 16'((64'(CLK_FREQ_HZ) * 104) / 100_000_000);   // 6 cycles
localparam logic [15:0] T1H_600   = 16'((64'(CLK_FREQ_HZ) * 125) / 100_000_000);   // 7 cycles
localparam logic [15:0] T1L_600   = 16'((64'(CLK_FREQ_HZ) * 42) / 100_000_000);    // 2 cycles

always_ff @(posedge clk) begin
    case (state)
        ST_IDLE: begin
            if (i_write && guard_count == 16'd0) begin
                dshot_command <= i_dshot_value;  // pull block equivalent
                bits_to_shift <= 5'd15;
                state <= ST_INIT;
            end
        end

        ST_INIT: begin
            // out y, 1 equivalent - check bit value
            if (dshot_command[15]) begin
                counter_high <= t1h_clocks;
                counter_low  <= t1l_clocks;
            end else begin
                counter_high <= t0h_clocks;
                counter_low  <= t0l_clocks;
            end
            state <= ST_HIGH;
        end

        ST_HIGH: begin
            pwm_reg <= 1'b1;  // set pins, 1
            if (counter_high == 16'd0) begin
                state <= ST_LOW;
            end else begin
                counter_high <= counter_high - 16'd1;
            end
        end

        ST_LOW: begin
            pwm_reg <= 1'b0;  // set pins, 0
            if (counter_low == 16'd0) begin
                if (bits_to_shift == 5'd0) begin
                    state <= ST_IDLE;  // jmp start equivalent
                end else begin
                    bits_to_shift <= bits_to_shift - 5'd1;
                    dshot_command <= {dshot_command[14:0], 1'b0};  // out y, 1 equivalent
                    state <= ST_INIT;
                end
            end else begin
                counter_low <= counter_low - 16'd1;
            end
        end
    endcase
end
```

**Key RTL Features:**
- State machine replaces PIO instruction flow
- Counters replace PIO delay cycles
- Shift register (`dshot_command`) replaces PIO Y register
- `i_write` signal replaces `pull block`
- Timing calculated from clock frequency

## SPI Master: PIO vs RTL

### PIO Implementation (spi_master.pio)

```asm
.program spi_master
.side_set 1

; SPI mode 0, CPOL=0, CPHA=0
pull block
out x, 8              ; bit counter
bitloop:
    out pins, 1       ; MOSI
    set pins, 1 side 0 [1]  ; SCK rising edge
    in pins, 1        ; MISO
    set pins, 0 side 1 [1]  ; SCK falling edge
    jmp x-- bitloop
```

**Key PIO Features:**
- `side_set` for clock edge control
- `out pins, 1` for MOSI output
- `in pins, 1` for MISO input
- `set pins, 1/0` for clock generation

### RTL Implementation (spi_master.sv)

```systemverilog
typedef enum logic [1:0] {
    SPI_IDLE,
    SPI_TRANSFER
} spi_state_t;

always_ff @(posedge clk) begin
    case (state)
        SPI_IDLE: begin
            sck <= 1'b0;  // CPOL=0
            if (start_transfer) begin
                shift_reg <= tx_data;
                bit_counter <= 3'd7;
                state <= SPI_TRANSFER;
            end
        end
        SPI_TRANSFER: begin
            mosi <= shift_reg[7];  // out pins, 1
            sck <= 1'b0;  // rising edge
            rx_data <= {rx_data[6:0], miso};  // in pins, 1
            sck <= 1'b1;  // falling edge
            shift_reg <= {shift_reg[6:0], 1'b0};
            if (bit_counter == 0) begin
                state <= SPI_IDLE;
                done <= 1'b1;
            end else begin
                bit_counter <= bit_counter - 1;
            end
        end
    endcase
end
```

## PWM Generation: PIO vs RTL

### PIO Implementation (pwm.pio)

```asm
.program pwm
.side_set 1

set x, 31            ; duty cycle counter
set y, 255           ; period counter
loop:
    set pins, 1 side 1
    jmp x--, loop side 0
    set pins, 0 side 1
    jmp y--, loop side 0
```

**Key PIO Features:**
- Two counters (X for duty, Y for period)
- `jmp x--` for duty cycle
- `jmp y--` for period
- `side_set` for pin control

### RTL Implementation (pwm_generator.sv)

```systemverilog
typedef enum logic [1:0] {
    PWM_HIGH,
    PWM_LOW
} pwm_state_t;

always_ff @(posedge clk) begin
    case (state)
        PWM_HIGH: begin
            pwm_out <= 1'b1;
            if (duty_counter == 0) begin
                state <= PWM_LOW;
                duty_counter <= duty_cycle;
            end else begin
                duty_counter <= duty_counter - 1;
            end
        end
        PWM_LOW: begin
            pwm_out <= 1'b0;
            if (period_counter == 0) begin
                state <= PWM_HIGH;
                period_counter <= period;
                duty_counter <= duty_cycle;
            end else begin
                period_counter <= period_counter - 1;
            end
        end
    endcase
end
```

## UART: PIO vs RTL

### PIO Implementation (esc_pio_uart.pio)

```asm
.program esc_uart_tx
.side_set 1 opt

; 8N1 transmit, LSB first, 8 clocks per bit
pull        side 1 [7]   ; idle high / stop bit
set x, 7    side 0 [7]   ; start bit low
bitloop:
    out pins, 1
    jmp x-- bitloop [6]
    nop       side 1 [6] ; stop bit
```

**Key PIO Features:**
- `side_set` → Pin direction control + timing
- `set x, 7` → Initialize bit counter
- `out pins, 1` → Shift out bit
- `jmp x--` → Decrement and loop
- 8 cycles per bit at 19200 baud

### RTL Implementation (wb_esc_uart.sv)

```systemverilog
typedef enum logic [2:0] {
    TX_IDLE,
    TX_START,
    TX_DATA,
    TX_STOP,
    TX_GUARD
} tx_state_t;

localparam int DEFAULT_BAUD = 19_200;
localparam int DEFAULT_CLKDIV = int'(64'(CLK_FREQ_HZ) / 64'(DEFAULT_BAUD));

always_ff @(posedge clk) begin
    case (tx_state)
        TX_IDLE: begin
            tx_out <= 1'b1;  // idle high (side 1)
            if (tx_data_valid) begin
                tx_shift <= tx_data_reg;
                tx_state <= TX_START;
                tx_counter <= clks_per_bit - 16'd1;
                tx_out <= 1'b0;  // start bit low (side 0)
            end
        end

        TX_START: begin
            if (tx_counter == 16'd0) begin
                tx_state <= TX_DATA;
                tx_counter <= clks_per_bit - 16'd1;
                tx_out <= tx_shift[0];  // out pins, 1
                tx_bit_idx <= 3'd0;
            end else begin
                tx_counter <= counter - 16'd1;
            end
        end

        TX_DATA: begin
            if (tx_counter == 16'd0) begin
                tx_shift <= {1'b0, tx_shift[7:1]};  // shift
                if (tx_bit_idx == 3'd7) begin
                    tx_state <= TX_STOP;
                    tx_counter <= clks_per_bit - 16'd1;
                    tx_out <= 1'b1;  // stop bit (side 1)
                end else begin
                    tx_bit_idx <= tx_bit_idx + 3'd1;
                    tx_counter <= clks_per_bit - 16'd1;
                    tx_out <= tx_shift[1];  // out pins, 1
                end
            end else begin
                tx_counter <= tx_counter - 16'd1;
            end
        end

        TX_STOP: begin
            if (tx_counter == 16'd0) begin
                tx_state <= TX_GUARD;  // half-duplex turnaround
            end else begin
                tx_counter <= tx_counter - 16'd1;
            end
        end
    endcase
end
```

**Key RTL Features:**
- 5-state machine replaces PIO instruction sequence
- `clks_per_bit` replaces PIO clock divider
- `tx_shift` replaces PIO OSR (Output Shift Register)
- `tx_bit_idx` replaces PIO X register counter
- TX_GUARD state for half-duplex turnaround (not in PIO)

## PIO to RTL Mapping Patterns

### Instruction Mapping

| PIO Instruction | RTL Equivalent | Notes |
|----------------|----------------|-------|
| `pull block` | AXI-Stream ready/valid handshake | Blocking data input |
| `pull` | Register assignment | Non-blocking data input |
| `out x, n` | Shift register operation | `data <= {data[n-1:0], new_bit}` |
| `out pins, n` | Output register assignment | `pin <= data[0]` |
| `set pins, val` | Output register | Direct pin control |
| `set pindirs, val` | Direction register | GPIO direction control |
| `jmp label` | State transition | `state <= NEXT_STATE` |
| `jmp !x, label` | Conditional state transition | `if (!x) state <= NEXT_STATE` |
| `jmp x--, label` | Counter + loop | `if (counter-- != 0) state <= LOOP` |
| `wait pin` | Edge detection logic | `if (edge_detected) state <= NEXT` |
| `in pins, n` | Input shift register | `data <= {new_bit, data[n-1:0]}` |
| `push block` | AXI-Stream valid/ready handshake | Blocking data output |
| `mov x, y` | Register assignment | `x <= y` |
| `mov pins, x` | Output from register | `pins <= x` |

### Timing Translation

**PIO Delay Cycles to RTL Counters:**

```systemverilog
// PIO: side_set [n] or delay [n]
// At 150MHz PIO clock: 1 cycle = 6.67ns

// RTL: Calculate counter value from target clock
localparam int CLK_FREQ = 54_000_000;  // RTL clock
localparam int PIO_CLK = 150_000_000;   // PIO clock
localparam int TARGET_NS = n * 6.67;    // PIO delay in ns

// RTL counter value
localparam int COUNTER = (CLK_FREQ * TARGET_NS) / 1_000_000_000;
```

**Example: DSHOT600 T0H (PIO: [26] cycles)**

```systemverilog
// PIO: 26 cycles at 150MHz = 173.33ns
// RTL at 54MHz: (54MHz * 173.33ns) / 1ns = 9.36 cycles ≈ 9 cycles

localparam logic [15:0] T0H_600 = 16'((64'(CLK_FREQ_HZ) * 625) / 1_000_000_000);
```

### State Machine Translation

**PIO Flow:**
```asm
label1:
    instruction1
    instruction2
    jmp label2
label2:
    instruction3
    jmp label1
```

**RTL Equivalent:**
```systemverilog
typedef enum logic [1:0] {
    ST_LABEL1,
    ST_LABEL2
} state_t;

always_ff @(posedge clk) begin
    case (state)
        ST_LABEL1: begin
            // instruction1
            // instruction2
            state <= ST_LABEL2;
        end
        ST_LABEL2: begin
            // instruction3
            state <= ST_LABEL1;
        end
    endcase
end
```

### Register Translation

**PIO Registers:**
- **X/Y**: General-purpose registers → RTL logic registers
- **OSR**: Output Shift Register → RTL shift register
- **ISR**: Input Shift Register → RTL shift register
- **FIFO**: TX/RX FIFO → AXI-Stream interface

## AI Prompt Examples for PIO to RTL

### Basic Prompt Template

```
Convert this RP2040 PIO assembly program to SystemVerilog RTL:

[PASTE PIO CODE HERE]

Context:
- Target clock: [specify, e.g., 54MHz]
- PIO clock: [specify, e.g., 150MHz]
- Function: [brief description]

Requirements:
- Generate synthesizable SystemVerilog
- Map PIO instructions to RTL state machine
- Convert PIO delay cycles to RTL counters using timing formula:
  RTL_counter = (RTL_CLK * PIO_delay_cycles * PIO_period) / 1_000_000_000
- Handle pull block as AXI-Stream ready/valid handshake
- Implement shift registers for out/in instructions
- Include proper reset and initialization
- Add status outputs (busy, done, ready)
- Provide usage example in comments
- Explain any assumptions made
```

### DShot Example Prompt

```
Convert this RP2040 PIO assembly program to SystemVerilog RTL:

.program dshot_600
    set    pindirs, 1
start:
    set    pins, 0                [31]
    nop                           [20]
    pull   block
    out    y, 16
bitloop:
    out    y, 1
    jmp    !y, outzero
    set    pins, 1                [26]
    set    pins, 0                [9]
    jmp    !osre, bitloop
    jmp    start
outzero:
    set    pins, 1                [12]
    set    pins, 0                [22]
    jmp    !osre, bitloop         [1]

Context:
- Target clock: 54MHz (RTL)
- PIO clock: 150MHz (PIO)
- Function: DSHOT600 motor control protocol (16-bit packet with CRC)

Requirements:
- Generate synthesizable SystemVerilog
- Map PIO instructions to RTL state machine
- Convert PIO delay cycles to RTL counters:
  - [31] = 31 * 6.67ns = 207ns → (54MHz * 207ns) = 11 cycles
  - [26] = 26 * 6.67ns = 173ns → (54MHz * 173ns) = 9 cycles
  - [22] = 22 * 6.67ns = 147ns → (54MHz * 147ns) = 8 cycles
  - [12] = 12 * 6.67ns = 80ns → (54MHz * 80ns) = 4 cycles
  - [9] = 9 * 6.67ns = 60ns → (54MHz * 60ns) = 3 cycles
- Handle pull block as simple handshake (clk, rst, i_write, i_dshot_value, o_pwm, o_ready)
- Implement shift register for out y, 1
- Include proper reset and initialization
- Add busy/ready status outputs
- Provide usage example in comments
```

### UART Example Prompt

```
Convert this RP2040 PIO assembly program to SystemVerilog RTL:

.program esc_uart_tx
.side_set 1 opt

; 8N1 transmit, LSB first, 8 clocks per bit
pull        side 1 [7]   ; idle high / stop bit
set x, 7    side 0 [7]   ; start bit low
bitloop:
    out pins, 1
    jmp x-- bitloop [6]
    nop       side 1 [6] ; stop bit

Context:
- Target clock: 54MHz (RTL)
- PIO clock: 150MHz (PIO)
- Function: Half-duplex UART transmitter at 19200 baud 8N1
- Baud rate: 19200

Requirements:
- Generate synthesizable SystemVerilog
- Map PIO instructions to RTL state machine
- Convert side_set timing:
  - [7] = 7 * 6.67ns = 47ns → (54MHz * 47ns) = 3 cycles
  - [6] = 6 * 6.67ns = 40ns → (54MHz * 40ns) = 2 cycles
- Calculate clks_per_bit: 54MHz / 19200 = 2812 cycles
- Handle pull block as data input (tx_data_valid, tx_data_reg)
- Implement shift register for out pins, 1
- Include proper reset and initialization
- Add TX_GUARD state for half-duplex turnaround
- Provide usage example in comments
```

### SPI Master Example Prompt

```
Convert this RP2040 PIO assembly program to SystemVerilog RTL:

.program spi_master
.side_set 1

; SPI mode 0, CPOL=0, CPHA=0
pull block
out x, 8              ; bit counter
bitloop:
    out pins, 1       ; MOSI
    set pins, 1 side 0 [1]  ; SCK rising edge
    in pins, 1        ; MISO
    set pins, 0 side 1 [1]  ; SCK falling edge
    jmp x-- bitloop

Context:
- Target clock: 54MHz (RTL)
- PIO clock: 150MHz (PIO)
- Function: SPI master mode 0 (CPOL=0, CPHA=0)
- Data width: 8 bits

Requirements:
- Generate synthesizable SystemVerilog
- Map PIO instructions to RTL state machine
- Convert side_set timing:
  - [1] = 1 * 6.67ns = 6.67ns → (54MHz * 6.67ns) = 0 cycles (use 1 for margin)
- Handle pull block as transfer start signal
- Implement shift register for out pins, 1 (MOSI)
- Implement shift register for in pins, 1 (MISO)
- Generate SCK clock edges (rising on MOSI, falling on MISO)
- Include proper reset and initialization
- Add done status output
- Provide usage example in comments
```

### PWM Example Prompt

```
Convert this RP2040 PIO assembly program to SystemVerilog RTL:

.program pwm
.side_set 1

set x, 31            ; duty cycle counter
set y, 255           ; period counter
loop:
    set pins, 1 side 1
    jmp x--, loop side 0
    set pins, 0 side 1
    jmp y--, loop side 0

Context:
- Target clock: 54MHz (RTL)
- PIO clock: 150MHz (PIO)
- Function: PWM generation with configurable duty cycle and period
- Default duty: 31/255 (12%)
- Default period: 255 cycles

Requirements:
- Generate synthesizable SystemVerilog
- Map PIO instructions to RTL state machine
- Convert side_set timing:
  - [1] = 1 * 6.67ns = 6.67ns → (54MHz * 6.67ns) = 0 cycles (use 1 for margin)
- Implement two counters: duty_counter and period_counter
- Map jmp x-- to duty cycle counter
- Map jmp y-- to period counter
- Make duty cycle and period configurable parameters
- Include proper reset and initialization
- Add status output (optional)
- Provide usage example in comments
```

### Complex Protocol Prompt

```
Convert this RP2040 PIO assembly program to SystemVerilog RTL:

[PASTE COMPLEX PIO CODE]

Context:
- Target clock: [specify]
- PIO clock: [specify]
- Function: [detailed description]
- Protocol: [protocol name, link to spec if available]
- Timing requirements: [specific timing constraints]

Requirements:
- Generate synthesizable SystemVerilog
- Map PIO instructions to RTL state machine
- Convert all PIO delay cycles to RTL counters
- Handle all side_set instructions with proper timing
- Implement all shift registers (OSR, ISR)
- Handle pull/push with AXI-Stream interfaces
- Include proper reset and initialization
- Add comprehensive status outputs
- Include timing diagram in comments (mermaid format)
- Provide detailed usage example
- Explain any assumptions made about timing or protocol
- Add parameterization for configurable values
```

### Verification Prompt

```
Analyze this PIO assembly program and the corresponding RTL implementation:

[PASTE PIO CODE]

[PASTE RTL CODE]

Check for:
1. Correct instruction-to-state mapping
2. Accurate timing translation (compare PIO cycles with RTL counters)
3. Proper handling of pull/pull block
4. Correct shift register implementation
5. Complete reset logic
6. Missing edge cases

Provide:
- Line-by-line comparison
- Timing calculation verification
- Any discrepancies found
- Suggestions for improvement
```

## AI Prompt Template for PIO to RTL

### Basic Template

```
Convert this RP2040 PIO assembly program to SystemVerilog RTL:

[PASTE PIO CODE HERE]

Context:
- Target clock: [specify, e.g., 54MHz]
- PIO clock: [specify, e.g., 150MHz]
- Function: [brief description]

Requirements:
- Generate synthesizable SystemVerilog
- Map PIO instructions to RTL state machine
- Convert PIO delay cycles to RTL counters using timing formula:
  RTL_counter = (RTL_CLK * PIO_delay_cycles * PIO_period) / 1_000_000_000
- Handle pull block as AXI-Stream ready/valid handshake
- Implement shift registers for out/in instructions
- Include proper reset and initialization
- Add status outputs (busy, done, ready)
- Provide usage example in comments
- Explain any assumptions made
```

### Example with DShot PIO

```
Convert this RP2040 PIO assembly program to SystemVerilog RTL:

.program dshot_600
    set    pindirs, 1
start:
    set    pins, 0                [31]
    nop                           [20]
    pull   block
    out    y, 16
bitloop:
    out    y, 1
    jmp    !y, outzero
    set    pins, 1                [26]
    set    pins, 0                [9]
    jmp    !osre, bitloop
    jmp    start
outzero:
    set    pins, 1                [12]
    set    pins, 0                [22]
    jmp    !osre, bitloop         [1]

Context:
- Target clock: 54MHz (RTL)
- PIO clock: 150MHz (PIO)
- Function: DSHOT600 motor control protocol

Requirements:
- Generate synthesizable SystemVerilog
- Map PIO instructions to RTL state machine
- Convert PIO delay cycles to RTL counters:
  - [31] = 31 * 6.67ns = 207ns → (54MHz * 207ns) = 11 cycles
  - [26] = 26 * 6.67ns = 173ns → (54MHz * 173ns) = 9 cycles
  - [22] = 22 * 6.67ns = 147ns → (54MHz * 147ns) = 8 cycles
  - [12] = 12 * 6.67ns = 80ns → (54MHz * 80ns) = 4 cycles
  - [9] = 9 * 6.67ns = 60ns → (54MHz * 60ns) = 3 cycles
- Handle pull block as simple handshake (clk, rst, i_write, i_dshot_value, o_pwm, o_ready)
- Implement shift register for out y, 1
- Include proper reset and initialization
- Add busy/ready status outputs
- Provide usage example in comments
```

## Common Patterns

### Blocking Data Input (pull block)

**PIO:**
```asm
pull block
```

**RTL:**
```systemverilog
input wire i_write,
input wire [15:0] i_data,
output wire o_ready,

always_ff @(posedge clk) begin
    if (i_write && ready) begin
        data_reg <= i_data;
        ready <= 1'b0;
    end
end
```

### Shift Register (out y, n)

**PIO:**
```asm
out y, 1
```

**RTL:**
```systemverilog
logic [15:0] shift_reg;
always_ff @(posedge clk) begin
    shift_reg <= {shift_reg[14:0], new_bit};
end
```

### Conditional Branch (jmp !x, label)

**PIO:**
```asm
jmp !x, outzero
```

**RTL:**
```systemverilog
if (!x) begin
    state <= ST_OUTZERO;
end
```

### Counter Loop (jmp x--, label)

**PIO:**
```asm
set x, 7
bitloop:
    jmp x-- bitloop
```

**RTL:**
```systemverilog
logic [2:0] counter;
always_ff @(posedge clk) begin
    if (counter == 0) begin
        state <= ST_NEXT;
    end else begin
        counter <= counter - 1;
    end
end
```

## Tips for AI Conversion

1. **Provide clock frequencies** - Essential for timing translation
2. **Specify interface style** - AXI-Stream, Wishbone, or simple
3. **Include context** - What the module does, protocol details
4. **Request comments** - Ask AI to explain the translation
5. **Verify timing** - Check that RTL counters match PIO delays
6. **Test incrementally** - Start with simple PIO, move to complex
7. **Use existing RTL as reference** - Compare AI output with hand-written RTL

## Verification

After AI generation, verify:
1. Timing matches PIO specification
2. State machine covers all PIO paths
3. Reset logic is complete
4. Interface signals are correct
5. No inferred latches
6. Synthesizable code style

## References

- PIO Assembly Guide: https://datasheets.raspberrypi.com/rp2040/rp2040-datasheet.pdf#section3
- rt-fc-offloader PIO: `firmware/pico/*.pio`
- rt-fc-offloader RTL: `rtl/io/*.sv`
