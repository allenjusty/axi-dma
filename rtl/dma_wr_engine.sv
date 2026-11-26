// dma_wr_engine: one AXI4 write burst. Raises AWVALID and WVALID together and
// independently (spec rule 8), sends N beats from the FIFO with WLAST on beat N,
// then waits for the B response.
module dma_wr_engine (
    input  logic        clk,
    input  logic        rst_n,

    // Command from dma_ctrl
    input  logic        start,      // one-cycle pulse
    input  logic [31:0] addr,
    input  logic [8:0]  n_beats,    // 1..256
    output logic        done,       // one-cycle pulse: B response accepted
    output logic        err,        // valid with done: B was SLVERR/DECERR

    // AXI4 write address channel
    output logic        awvalid,
    input  logic        awready,
    output logic [31:0] awaddr,
    output logic [7:0]  awlen,

    // AXI4 write data channel
    output logic        wvalid,
    input  logic        wready,
    output logic [31:0] wdata,
    output logic        wlast,

    // AXI4 write response channel
    input  logic        bvalid,
    output logic        bready,
    input  logic [1:0]  bresp,

    // FIFO read side (show-ahead)
    output logic        fifo_pop,
    input  logic [31:0] fifo_rdata
);
    typedef enum logic [1:0] {IDLE, XFER, RESP} state_t;
    state_t     state;
    logic       aw_pending;   // AW not yet accepted
    logic [8:0] n_q;          // beats in this burst
    logic [8:0] w_cnt;        // W beats already accepted

    logic aw_fire, w_fire, aw_finished, w_finished;

    assign awvalid = (state == XFER) && aw_pending;
    assign wvalid  = (state == XFER) && (w_cnt != n_q);
    assign wdata   = fifo_rdata;
    assign wlast   = (w_cnt == n_q - 9'd1);
    assign bready  = (state == RESP);

    assign aw_fire  = awvalid && awready;
    assign w_fire   = wvalid  && wready;
    assign fifo_pop = w_fire;

    // Both finished by the end of this cycle?
    assign aw_finished = !aw_pending || aw_fire;
    assign w_finished  = (w_cnt == n_q) || (w_fire && wlast);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state      <= IDLE;
            aw_pending <= 1'b0;
            awaddr     <= '0;
            awlen      <= '0;
            n_q        <= '0;
            w_cnt      <= '0;
        end else begin
            case (state)
                IDLE: if (start) begin
                    awaddr     <= addr;
                    awlen      <= 8'(n_beats - 9'd1);
                    n_q        <= n_beats;
                    w_cnt      <= '0;
                    aw_pending <= 1'b1;
                    state      <= XFER;
                end
                XFER: begin
                    if (aw_fire) aw_pending <= 1'b0;
                    if (w_fire)  w_cnt      <= w_cnt + 9'd1;
                    if (aw_finished && w_finished) state <= RESP;
                end
                RESP: if (bvalid) state <= IDLE;              // B handshake
                default: state <= IDLE;
            endcase
        end
    end

    assign done = (state == RESP) && bvalid;
    assign err  = bresp[1];                                   // SLVERR or DECERR

endmodule
