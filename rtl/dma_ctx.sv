// dma_ctx: live transfer state (internal copies of SRC, DST, word count, MAX_BURST)
// and the START-time checks of spec rules 4 (config error) and 5 (zero length).
module dma_ctx (
    input  logic        clk,
    input  logic        rst_n,

    // Programmed register values
    input  logic [31:0] reg_src,
    input  logic [31:0] reg_dst,
    input  logic [31:0] reg_len,
    input  logic [7:0]  reg_max_burst,

    // Checks on the programmed values (combinational)
    output logic        cfg_err,    // rule 4
    output logic        zero_len,   // rule 5

    // Control from dma_ctrl
    input  logic        load,       // copy register values in (accepted START)
    input  logic        advance,    // a burst of adv_beats words finished
    input  logic [8:0]  adv_beats,

    // Live state
    output logic [31:0] src,
    output logic [31:0] dst,
    output logic [31:0] words_rem,
    output logic [7:0]  max_burst
);
    // ---------------- Rule 4 / rule 5 checks ----------------
    logic        align_err;
    logic [32:0] src_last, dst_last;   // 33-bit so the sum cannot wrap
    logic        range_err;

    assign align_err = (reg_src[1:0] != 2'b00) || (reg_dst[1:0] != 2'b00) || (reg_len[1:0] != 2'b00);
    assign src_last  = {1'b0, reg_src} + {1'b0, reg_len} - 33'd1;
    assign dst_last  = {1'b0, reg_dst} + {1'b0, reg_len} - 33'd1;
    assign range_err = (reg_len != 32'd0) && (src_last[32] || dst_last[32]);  // last byte > 0xFFFF_FFFF

    assign cfg_err  = align_err || range_err;
    assign zero_len = !align_err && (reg_len == 32'd0);

    // ---------------- Live state ----------------
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            src       <= '0;
            dst       <= '0;
            words_rem <= '0;
            max_burst <= '0;
        end else if (load) begin
            src       <= reg_src;
            dst       <= reg_dst;
            words_rem <= {2'b00, reg_len[31:2]};
            max_burst <= reg_max_burst;
        end else if (advance) begin
            src       <= src + {21'd0, adv_beats, 2'b00};
            dst       <= dst + {21'd0, adv_beats, 2'b00};
            words_rem <= words_rem - {23'd0, adv_beats};
        end
    end

endmodule
