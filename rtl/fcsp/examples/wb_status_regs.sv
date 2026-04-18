`default_nettype wire

// Minimal Wishbone register peripheral for teaching/reference purposes.
//
// Register map (word offsets):
//   0x0: CONTROL (RW)
//   0x4: SCRATCH (RW)
//   0x8: STATUS  (RO) bit0 = heartbeat (counter bit 8)
//   0xC: COUNTER (RO) free-running cycle counter
module wb_status_regs (
    input  wire        clk,
    input  wire        rst,

    // Wishbone classic slave
    input  wire        wb_cyc_i,
    input  wire        wb_stb_i,
    input  wire        wb_we_i,
    input  wire [3:0]  wb_sel_i,
    input  wire [7:0]  wb_adr_i,
    input  wire [31:0] wb_dat_i,
    output logic [31:0] wb_dat_o,
    output logic        wb_ack_o,
    output logic        wb_err_o
);
    logic [31:0] reg_control;
    logic [31:0] reg_scratch;
    logic [31:0] reg_counter;

    logic req;
    logic [3:0] word_addr;
    logic addr_valid;
    logic wr_en_control;
    logic wr_en_scratch;

    assign req = wb_cyc_i && wb_stb_i;
    assign word_addr = wb_adr_i[5:2];
    assign addr_valid = (word_addr <= 4'd3);
    assign wr_en_control = req && wb_we_i && (word_addr == 4'd0) && addr_valid;
    assign wr_en_scratch = req && wb_we_i && (word_addr == 4'd1) && addr_valid;

    // Byte-lane write helper
    function automatic [31:0] apply_wstrb(
        input [31:0] old_val,
        input [31:0] new_val,
        input [3:0]  sel
    );
        begin
            apply_wstrb = old_val;
            if (sel[0]) apply_wstrb[7:0]   = new_val[7:0];
            if (sel[1]) apply_wstrb[15:8]  = new_val[15:8];
            if (sel[2]) apply_wstrb[23:16] = new_val[23:16];
            if (sel[3]) apply_wstrb[31:24] = new_val[31:24];
        end
    endfunction

    always_ff @(posedge clk) begin
        if (rst) begin
            reg_control <= 32'h0000_0000;
            reg_scratch <= 32'h0000_0000;
            reg_counter <= 32'h0000_0000;
            wb_ack_o    <= 1'b0;
            wb_err_o    <= 1'b0;
        end else begin
            reg_counter <= reg_counter + 32'd1;

            wb_ack_o <= 1'b0;
            wb_err_o <= 1'b0;

            if (req) begin
                if (addr_valid) begin
                    wb_ack_o <= 1'b1;
                end else begin
                    wb_err_o <= 1'b1;
                end
            end

            if (wr_en_control) begin
                reg_control <= apply_wstrb(reg_control, wb_dat_i, wb_sel_i);
            end
            if (wr_en_scratch) begin
                reg_scratch <= apply_wstrb(reg_scratch, wb_dat_i, wb_sel_i);
            end
        end
    end

    always_comb begin
        unique case (word_addr)
            4'd0: wb_dat_o = reg_control;
            4'd1: wb_dat_o = reg_scratch;
            4'd2: wb_dat_o = {31'd0, reg_counter[8]};
            4'd3: wb_dat_o = reg_counter;
            default: wb_dat_o = 32'h0000_0000;
        endcase
    end
endmodule

`default_nettype wire
