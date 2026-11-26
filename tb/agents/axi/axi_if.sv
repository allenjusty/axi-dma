// AXI4 interface (all five channels). Testbench components drive and sample on the
// falling clock edge, so every DUT output is stable when read.
interface axi_if (input logic clk, input logic rst_n);
    // write address
    logic        awvalid, awready, awid, awlock;
    logic [31:0] awaddr;
    logic [7:0]  awlen;
    logic [2:0]  awsize, awprot;
    logic [1:0]  awburst;
    logic [3:0]  awcache, awqos;
    // write data
    logic        wvalid, wready, wlast;
    logic [31:0] wdata;
    logic [3:0]  wstrb;
    // write response
    logic        bvalid, bready, bid;
    logic [1:0]  bresp;
    // read address
    logic        arvalid, arready, arid, arlock;
    logic [31:0] araddr;
    logic [7:0]  arlen;
    logic [2:0]  arsize, arprot;
    logic [1:0]  arburst;
    logic [3:0]  arcache, arqos;
    // read data
    logic        rvalid, rready, rid, rlast;
    logic [31:0] rdata;
    logic [1:0]  rresp;
endinterface
