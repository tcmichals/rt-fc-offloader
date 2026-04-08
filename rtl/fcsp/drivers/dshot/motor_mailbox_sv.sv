// Package definition for documentation (not used in synthesis due to tool limitations)
// typedef struct packed {
//     logic [31:0] data; // 32-bit Motor Command
//     logic [2:0]  id;   // Motor ID (0-7)
//     logic        vld;  // Pulse high on update
// } motor_cmd_t;

// Main Mailbox Module
module motor_mailbox_sv #(
    parameter int NUM_MOTORS = 8
)(
    input  logic        clk,
    input  logic        rst, // Positive Synchronous Reset

    // --- Port A: Wishbone Slave ---
    input  logic [2:0]  wb_adr_i,
    input  logic [31:0] wb_dat_i,
    input  logic        wb_we_i,
    input  logic        wb_stb_i,
    input  logic        wb_cyc_i,
    output logic        wb_ack_o,
    output logic [31:0] wb_dat_o,

    // --- Port B: Generic Interface ---
    input  logic [2:0]  gen_addr,
    input  logic [31:0] gen_wdata,
    input  logic        gen_wen,
    output logic [31:0] gen_rdata,

    // --- Single-Channel DSHOT Dispatch Output ---
    output logic [31:0] dshot_out_data,
    output logic [2:0]  dshot_out_id,
    output logic        dshot_out_vld
);


    // Internal Memory for Motor Speeds
    logic [31:0] motor_regs [NUM_MOTORS];

    // --- Combinatorial Reads ---
    // Zero-latency read access for both interfaces
    assign wb_dat_o  = motor_regs[wb_adr_i];
    assign gen_rdata = motor_regs[gen_addr];

    // --- Command FIFO for Synchronization ---
    localparam int FIFO_DEPTH = 4;
    
    // FIFO entry: packed bits [34:0] = {id[2:0], data[31:0]}
    logic [34:0] fifo_mem [FIFO_DEPTH];

    logic [$clog2(FIFO_DEPTH)-1:0] rd_ptr, wr_ptr;
    logic [$clog2(FIFO_DEPTH):0]   fifo_count;

    wire fifo_full  = (fifo_count == FIFO_DEPTH);
    wire fifo_empty = (fifo_count == 0);

    // Write Interface signals
    wire wb_write_req  = wb_stb_i && wb_cyc_i && wb_we_i && !wb_ack_o;
    wire gen_write_req = gen_wen;

    // --- Port B (Generic) Priority Arbiter ---
    // If both write, Port B takes the current cycle, Port A is stalled
    wire push_gen = gen_write_req && !fifo_full;
    wire push_wb  = wb_write_req  && !fifo_full && !gen_write_req;

    // --- Wishbone ACK Logic ---
    // ACK only when the command is actually pushed into the FIFO
    always_ff @(posedge clk) begin
        if (rst) begin
            wb_ack_o <= 1'b0;
        end else begin
            wb_ack_o <= push_wb;
        end
    end

    // --- FIFO Read Signal (for dispatch) ---
    wire fifo_pop = !fifo_empty;
    wire [2:0]  pop_id   = fifo_mem[rd_ptr][34:32];
    wire [31:0] pop_data = fifo_mem[rd_ptr][31:0];

    // --- FIFO Write, Control & Motor Regs Logic (single driver) ---
    always_ff @(posedge clk) begin
        if (rst) begin
            wr_ptr     <= '0;
            fifo_count <= '0;
            for (int i = 0; i < NUM_MOTORS; i++) motor_regs[i] <= 32'h0;
        end else begin
            // FIFO Push
            if (push_gen || push_wb) begin
                // Pack as {id[2:0], data[31:0]}
                fifo_mem[wr_ptr] <= push_gen ? {gen_addr, gen_wdata} : 
                                               {wb_adr_i, wb_dat_i};
                wr_ptr           <= wr_ptr + 1'b1;
            end

            // FIFO Count Tracking (Push vs Pull)
            case ({ (push_gen || push_wb), fifo_pop })
                2'b10: fifo_count <= fifo_count + 1'b1; // Push only
                2'b01: fifo_count <= fifo_count - 1'b1; // Pull only
                default: ; // Both or None: count stays same
            endcase

            // Update motor_regs when popping from FIFO
            if (fifo_pop) begin
                motor_regs[pop_id] <= pop_data;
            end
        end
    end

    // --- FIFO Read & Motor Dispatch ---
    always_ff @(posedge clk) begin
        if (rst) begin
            rd_ptr         <= '0;
            dshot_out_data <= '0;
            dshot_out_id   <= '0;
            dshot_out_vld  <= 1'b0;
        end else begin
            dshot_out_vld <= 1'b0; // Default: pulse

            if (fifo_pop) begin
                // Dispatch to DSHOT Engine
                dshot_out_data <= pop_data;
                dshot_out_id   <= pop_id;
                dshot_out_vld  <= 1'b1;
                
                rd_ptr <= rd_ptr + 1'b1;
            end
        end
    end

endmodule
