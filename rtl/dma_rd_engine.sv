// dma_rd_engine: one AXI4 read burst. Sends AR, then accepts every R beat into the FIFO.
// Records an error if any beat is SLVERR/DECERR, but still accepts all beats (spec rule 9).
module dma_rd_engine (
    input  logic        clk,
    input  logic        rst_n,

    // Command from dma_ctrl
    input  logic        start,      // one-cycle pulse
    input  logic [31:0] addr,
    input  logic [8:0]  n_beats,    // 1..256
    output logic        done,       // one-cycle pulse: last beat accepted
    output logic        err,        // valid with done: some beat had an error response

    // AXI4 read address channel
    output logic        arvalid,
    input  logic        arready,
    output logic [31:0] araddr,
    output logic [7:0]  arlen,

    // AXI4 read data channel
    input  logic        rvalid,
    output logic        rready,
    input  logic [31:0] rdata,
    input  logic [1:0]  rresp,
    input  logic        rlast,

    // FIFO write side
    output logic        fifo_push,
    output logic [31:0] fifo_wdata
);
    typedef enum logic [1:0] {IDLE, ADDR, DATA} state_t;
    state_t state;
    logic   err_q;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state  <= IDLE;
            araddr <= '0;
            arlen  <= '0;
            err_q  <= 1'b0;
        end else begin
            case (state)
                IDLE: if (start) begin
                    araddr <= addr;
                    arlen  <= 8'(n_beats - 9'd1);
                    err_q  <= 1'b0;
                    state  <= ADDR;
                end
                ADDR: if (arready) state <= DATA;            // AR handshake
                DATA: if (rvalid) begin                       // rready is 1 in DATA
                    if (rresp[1]) err_q <= 1'b1;              // SLVERR (2'b10) or DECERR (2'b11)
                    if (rlast)    state <= IDLE;
                end
                default: state <= IDLE;
            endcase
        end
    end

    assign arvalid    = (state == ADDR);
    assign rready     = (state == DATA);
    assign fifo_push  = (state == DATA) && rvalid;
    assign fifo_wdata = rdata;
    assign done       = (state == DATA) && rvalid && rlast;
    assign err        = err_q || rresp[1];

endmodule
