// tb_top: clock, reset, interfaces, DUT, assertions and run_test().
module tb_top;
    import uvm_pkg::*;
    import dma_test_pkg::*;

    logic clk = 0, rst_n = 0;
    always #5ns clk = ~clk;                       // 100 MHz
    initial begin
        repeat (5) @(posedge clk);
        rst_n <= 1;
    end

    apb_if     apb (clk, rst_n);
    axi_if     axi (clk, rst_n);
    dma_irq_if irq (clk, rst_n);

    dma_top dut (
        .clk, .rst_n,
        .psel(apb.psel), .penable(apb.penable), .pwrite(apb.pwrite), .pprot(apb.pprot),
        .paddr(apb.paddr), .pwdata(apb.pwdata), .pstrb(apb.pstrb),
        .pready(apb.pready), .prdata(apb.prdata), .pslverr(apb.pslverr),
        .awvalid(axi.awvalid), .awready(axi.awready), .awid(axi.awid), .awaddr(axi.awaddr),
        .awlen(axi.awlen), .awsize(axi.awsize), .awburst(axi.awburst), .awlock(axi.awlock),
        .awcache(axi.awcache), .awprot(axi.awprot), .awqos(axi.awqos),
        .wvalid(axi.wvalid), .wready(axi.wready), .wdata(axi.wdata), .wstrb(axi.wstrb), .wlast(axi.wlast),
        .bvalid(axi.bvalid), .bready(axi.bready), .bid(axi.bid), .bresp(axi.bresp),
        .arvalid(axi.arvalid), .arready(axi.arready), .arid(axi.arid), .araddr(axi.araddr),
        .arlen(axi.arlen), .arsize(axi.arsize), .arburst(axi.arburst), .arlock(axi.arlock),
        .arcache(axi.arcache), .arprot(axi.arprot), .arqos(axi.arqos),
        .rvalid(axi.rvalid), .rready(axi.rready), .rid(axi.rid), .rdata(axi.rdata),
        .rresp(axi.rresp), .rlast(axi.rlast),
        .irq(irq.irq)
    );

    initial begin
        uvm_config_db#(virtual apb_if)::set(null, "*", "apb_vif", apb);
        uvm_config_db#(virtual axi_if)::set(null, "*", "axi_vif", axi);
        uvm_config_db#(virtual dma_irq_if)::set(null, "*", "irq_vif", irq);
        if ($test$plusargs("DUMP")) begin
            $dumpfile("waves.vcd");
            $dumpvars(0, tb_top);
        end
        run_test();
    end
endmodule

bind dma_top dma_sva u_sva (
    .clk, .rst_n,
    .psel, .penable, .pwrite, .pready, .pslverr, .paddr, .pwdata,
    .awvalid, .awready, .wvalid, .wready, .wlast, .arvalid, .arready,
    .awaddr, .araddr, .wdata, .awlen, .arlen, .awsize, .arsize, .awburst, .arburst, .wstrb,
    .int_set_done (hwif_in.INT_STATUS.DONE.hwset),
    .int_set_err  (hwif_in.INT_STATUS.ERR.hwset),
    .int_done     (hwif_out.INT_STATUS.DONE.value),
    .int_err      (hwif_out.INT_STATUS.ERR.value)
);
