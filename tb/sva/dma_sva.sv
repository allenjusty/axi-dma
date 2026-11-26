// dma_sva: protocol and design assertions, bound to dma_top (see tb_top.sv).
// Each property is kept simple (one implication, $stable, disable iff) for Verilator.
module dma_sva (
    input logic        clk,
    input logic        rst_n,
    // APB
    input logic        psel, penable, pwrite, pready, pslverr,
    input logic [11:0] paddr,
    input logic [31:0] pwdata,
    // AXI
    input logic        awvalid, awready, wvalid, wready, wlast, arvalid, arready,
    input logic [31:0] awaddr, araddr, wdata,
    input logic [7:0]  awlen, arlen,
    input logic [2:0]  awsize, arsize,
    input logic [1:0]  awburst, arburst,
    input logic [3:0]  wstrb,
    // INT_STATUS hardware set / stored value
    input logic        int_set_done, int_set_err, int_done, int_err
);
    // ---------------- AXI: VALID holds with a stable payload until READY
    a_aw_stable: assert property (@(posedge clk) disable iff (!rst_n)
        awvalid && !awready |=> awvalid && $stable(awaddr) && $stable(awlen));
    a_ar_stable: assert property (@(posedge clk) disable iff (!rst_n)
        arvalid && !arready |=> arvalid && $stable(araddr) && $stable(arlen));
    a_w_stable:  assert property (@(posedge clk) disable iff (!rst_n)
        wvalid && !wready |=> wvalid && $stable(wdata) && $stable(wlast));

    // ---------------- AXI: no burst crosses a 4 KB boundary
    logic [12:0] aw_end, ar_end;   // offset in the page of the byte after the burst
    assign aw_end = {1'b0, awaddr[11:0]} + ({5'd0, awlen} + 13'd1) * 13'd4;
    assign ar_end = {1'b0, araddr[11:0]} + ({5'd0, arlen} + 13'd1) * 13'd4;
    a_aw_4k: assert property (@(posedge clk) disable iff (!rst_n) awvalid |-> aw_end <= 13'h1000);
    a_ar_4k: assert property (@(posedge clk) disable iff (!rst_n) arvalid |-> ar_end <= 13'h1000);

    // ---------------- AXI: fixed fields
    a_fixed: assert property (@(posedge clk) disable iff (!rst_n)
        awsize == 3'b010 && arsize == 3'b010 && awburst == 2'b01 && arburst == 2'b01 && wstrb == 4'hF);

    // ---------------- AXI: WLAST exactly on beat AWLEN+1
    // (the DUT holds AWLEN until the next burst, so it is valid for every W beat)
    logic [8:0] w_cnt;
    always_ff @(posedge clk)
        if (!rst_n)              w_cnt <= '0;
        else if (wvalid && wready) w_cnt <= wlast ? 9'd0 : w_cnt + 9'd1;
    a_wlast: assert property (@(posedge clk) disable iff (!rst_n) wvalid |-> (wlast == (w_cnt == {1'b0, awlen})));

    // ---------------- APB
    a_apb_slverr: assert property (@(posedge clk) disable iff (!rst_n)
        psel && penable && pready |-> (pslverr == (paddr[11:2] >= 10'd8)));
    a_apb_penable: assert property (@(posedge clk) disable iff (!rst_n)
        $rose(penable) |-> $past(psel && !penable));
    a_apb_stable: assert property (@(posedge clk) disable iff (!rst_n)
        psel && penable && !pready |=> $stable(paddr) && $stable(pwrite) && $stable(pwdata));

    // ---------------- INT_STATUS: a hardware set always wins (rule 12)
    a_int_done_set: assert property (@(posedge clk) disable iff (!rst_n) int_set_done |=> int_done);
    a_int_err_set:  assert property (@(posedge clk) disable iff (!rst_n) int_set_err  |=> int_err);

    // ---------------- covers
    c_aw_wait:   cover property (@(posedge clk) awvalid && !awready);
    c_w_before_aw: cover property (@(posedge clk) wvalid && wready && awvalid && !awready);
    c_slverr:    cover property (@(posedge clk) psel && penable && pready && pslverr);
endmodule
