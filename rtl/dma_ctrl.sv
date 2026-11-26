// dma_ctrl: top-level state machine. Moves one burst at a time (spec rule 7):
//   IDLE -> RD_REQ -> RD_WAIT -> WR_REQ -> WR_WAIT -> UPDATE -> (RD_REQ | IDLE)
// A read error stops after RD_WAIT (no write); a write error stops after WR_WAIT.
module dma_ctrl (
    input  logic       clk,
    input  logic       rst_n,

    // From the register block / context
    input  logic       start,        // one-cycle START pulse
    input  logic       cfg_err,
    input  logic       zero_len,
    input  logic [8:0] n_beats,      // size of the current burst
    input  logic [31:0] words_rem,

    // To the context
    output logic       ctx_load,
    output logic       ctx_advance,

    // Engines
    output logic       rd_start,
    input  logic       rd_done,
    input  logic       rd_err,
    output logic       wr_start,
    input  logic       wr_done,
    input  logic       wr_err,
    output logic       fifo_clear,

    // Status events (to dma_status_irq)
    output logic       busy,
    output logic       ev_start,     // accepted START: clear DONE/ERR/ERR_CODE
    output logic       ev_done,
    output logic       ev_err,
    output logic [1:0] ev_err_code
);
    typedef enum logic [2:0] {IDLE, RD_REQ, RD_WAIT, WR_REQ, WR_WAIT, UPDATE} state_t;
    state_t state, state_next;

    localparam logic [1:0] ERR_CFG = 2'd1, ERR_RD = 2'd2, ERR_WR = 2'd3;

    always_comb begin
        state_next  = state;
        ctx_load    = 1'b0;
        ctx_advance = 1'b0;
        rd_start    = 1'b0;
        wr_start    = 1'b0;
        fifo_clear  = 1'b0;
        ev_start    = 1'b0;
        ev_done     = 1'b0;
        ev_err      = 1'b0;
        ev_err_code = 2'd0;

        case (state)
            IDLE: if (start) begin                // START while busy is ignored (rule 2)
                ev_start = 1'b1;
                if (cfg_err) begin                // rule 4
                    ev_err      = 1'b1;
                    ev_err_code = ERR_CFG;
                end else if (zero_len) begin      // rule 5
                    ev_done = 1'b1;
                end else begin
                    ctx_load   = 1'b1;
                    state_next = RD_REQ;
                end
            end

            RD_REQ: begin
                rd_start   = 1'b1;
                state_next = RD_WAIT;
            end

            RD_WAIT: if (rd_done) begin
                if (rd_err) begin                 // rule 9
                    fifo_clear  = 1'b1;
                    ev_err      = 1'b1;
                    ev_err_code = ERR_RD;
                    state_next  = IDLE;
                end else begin
                    state_next = WR_REQ;
                end
            end

            WR_REQ: begin
                wr_start   = 1'b1;
                state_next = WR_WAIT;
            end

            WR_WAIT: if (wr_done) begin
                if (wr_err) begin                 // rule 10
                    ev_err      = 1'b1;
                    ev_err_code = ERR_WR;
                    state_next  = IDLE;
                end else begin
                    state_next = UPDATE;
                end
            end

            UPDATE: begin
                ctx_advance = 1'b1;
                if (words_rem == {23'd0, n_beats}) begin   // last burst done (rule 11)
                    ev_done    = 1'b1;
                    state_next = IDLE;
                end else begin
                    state_next = RD_REQ;
                end
            end

            default: state_next = IDLE;
        endcase
    end

    always_ff @(posedge clk) begin
        if (!rst_n) state <= IDLE;
        else        state <= state_next;
    end

    assign busy = (state != IDLE);

`ifndef SYNTHESIS
    a_burst_nonzero: assert property (@(posedge clk) disable iff (!rst_n)
                                      (rd_start || wr_start) |-> (n_beats != 9'd0 && n_beats <= 9'd256));
`endif

endmodule
