// dma_top: single-channel AXI4 DMA with an APB4 register interface.
module dma_top (
    input  logic        clk,
    input  logic        rst_n,

    // APB4 slave
    input  logic        psel,
    input  logic        penable,
    input  logic        pwrite,
    input  logic [2:0]  pprot,
    input  logic [11:0] paddr,
    input  logic [31:0] pwdata,
    input  logic [3:0]  pstrb,
    output logic        pready,
    output logic [31:0] prdata,
    output logic        pslverr,

    // AXI4 master: write address
    output logic        awvalid,
    input  logic        awready,
    output logic        awid,
    output logic [31:0] awaddr,
    output logic [7:0]  awlen,
    output logic [2:0]  awsize,
    output logic [1:0]  awburst,
    output logic        awlock,
    output logic [3:0]  awcache,
    output logic [2:0]  awprot,
    output logic [3:0]  awqos,
    // write data
    output logic        wvalid,
    input  logic        wready,
    output logic [31:0] wdata,
    output logic [3:0]  wstrb,
    output logic        wlast,
    // write response
    input  logic        bvalid,
    output logic        bready,
    input  logic        bid,
    input  logic [1:0]  bresp,
    // read address
    output logic        arvalid,
    input  logic        arready,
    output logic        arid,
    output logic [31:0] araddr,
    output logic [7:0]  arlen,
    output logic [2:0]  arsize,
    output logic [1:0]  arburst,
    output logic        arlock,
    output logic [3:0]  arcache,
    output logic [2:0]  arprot,
    output logic [3:0]  arqos,
    // read data
    input  logic        rvalid,
    output logic        rready,
    input  logic        rid,
    input  logic [31:0] rdata,
    input  logic [1:0]  rresp,
    input  logic        rlast,

    // Interrupt
    output logic        irq
);
    // ---------------- Fixed AXI fields ----------------
    assign awid    = 1'b0;      assign arid    = 1'b0;
    assign awsize  = 3'b010;    assign arsize  = 3'b010;    // 4 bytes per beat
    assign awburst = 2'b01;     assign arburst = 2'b01;     // INCR
    assign awlock  = 1'b0;      assign arlock  = 1'b0;
    assign awcache = 4'b0000;   assign arcache = 4'b0000;
    assign awprot  = 3'b000;    assign arprot  = 3'b000;
    assign awqos   = 4'b0000;   assign arqos   = 4'b0000;
    assign wstrb   = 4'b1111;

    // ---------------- Register block (generated) ----------------
    dma_regs_pkg::dma_regs__in_t  hwif_in;
    dma_regs_pkg::dma_regs__out_t hwif_out;

    dma_regs u_regs (
        .clk, .rst_n,
        .s_apb_psel(psel), .s_apb_penable(penable), .s_apb_pwrite(pwrite),
        .s_apb_pprot(pprot), .s_apb_paddr(paddr), .s_apb_pwdata(pwdata),
        .s_apb_pstrb(pstrb), .s_apb_pready(pready), .s_apb_prdata(prdata),
        .s_apb_pslverr(pslverr),
        .hwif_in, .hwif_out
    );

    // ---------------- Internal wires ----------------
    logic        cfg_err, zero_len, ctx_load, ctx_advance;
    logic [31:0] cur_src, cur_dst, words_rem;
    logic [7:0]  cur_max_burst;
    logic [8:0]  n_beats;

    logic        rd_start, rd_done, rd_err;
    logic        wr_start, wr_done, wr_err;
    logic        fifo_clear, fifo_push, fifo_pop, fifo_full, fifo_empty;
    logic [31:0] fifo_wdata, fifo_rdata;

    logic        busy, ev_start, ev_done, ev_err;
    logic [1:0]  ev_err_code;

    // ---------------- Blocks ----------------
    dma_ctx u_ctx (
        .clk, .rst_n,
        .reg_src       (hwif_out.SRC.ADDR.value),
        .reg_dst       (hwif_out.DST.ADDR.value),
        .reg_len       (hwif_out.LEN.BYTES.value),
        .reg_max_burst (hwif_out.CTRL.MAX_BURST.value),
        .cfg_err, .zero_len,
        .load      (ctx_load),
        .advance   (ctx_advance),
        .adv_beats (n_beats),
        .src       (cur_src),
        .dst       (cur_dst),
        .words_rem,
        .max_burst (cur_max_burst)
    );

    dma_burst_calc u_burst_calc (
        .src       (cur_src),
        .dst       (cur_dst),
        .words_rem,
        .max_burst (cur_max_burst),
        .n_beats
    );

    dma_ctrl u_ctrl (
        .clk, .rst_n,
        .start (hwif_out.CTRL.START.value),
        .cfg_err, .zero_len, .n_beats, .words_rem,
        .ctx_load, .ctx_advance,
        .rd_start, .rd_done, .rd_err,
        .wr_start, .wr_done, .wr_err,
        .fifo_clear,
        .busy, .ev_start, .ev_done, .ev_err, .ev_err_code
    );

    dma_rd_engine u_rd (
        .clk, .rst_n,
        .start (rd_start), .addr (cur_src), .n_beats,
        .done (rd_done), .err (rd_err),
        .arvalid, .arready, .araddr, .arlen,
        .rvalid, .rready, .rdata, .rresp, .rlast,
        .fifo_push, .fifo_wdata
    );

    dma_fifo #(.DEPTH(256), .WIDTH(32)) u_fifo (
        .clk, .rst_n,
        .clear (fifo_clear),
        .push  (fifo_push), .wdata (fifo_wdata),
        .pop   (fifo_pop),  .rdata (fifo_rdata),
        .full  (fifo_full), .empty (fifo_empty)
    );

    dma_wr_engine u_wr (
        .clk, .rst_n,
        .start (wr_start), .addr (cur_dst), .n_beats,
        .done (wr_done), .err (wr_err),
        .awvalid, .awready, .awaddr, .awlen,
        .wvalid, .wready, .wdata, .wlast,
        .bvalid, .bready, .bresp,
        .fifo_pop, .fifo_rdata
    );

    dma_status_irq u_status (
        .clk, .rst_n,
        .busy, .ev_start, .ev_done, .ev_err, .ev_err_code,
        .st_busy      (hwif_in.STATUS.BUSY.next),
        .st_done      (hwif_in.STATUS.DONE.next),
        .st_err       (hwif_in.STATUS.ERR.next),
        .st_err_code  (hwif_in.STATUS.ERR_CODE.next),
        .int_set_done (hwif_in.INT_STATUS.DONE.hwset),
        .int_set_err  (hwif_in.INT_STATUS.ERR.hwset),
        .int_status   ({hwif_out.INT_STATUS.ERR.value,  hwif_out.INT_STATUS.DONE.value}),
        .int_enable   ({hwif_out.INT_ENABLE.ERR.value,  hwif_out.INT_ENABLE.DONE.value}),
        .irq
    );

    // Unused inputs (IDs are always 0; FIFO flags only feed assertions)
    logic unused;
    assign unused = ^{bid, rid, fifo_full, fifo_empty};

endmodule
