// APB4 interface. Testbench components drive and sample on the falling clock edge,
// so every DUT output is stable when read (race-free on any simulator).
interface apb_if (input logic clk, input logic rst_n);
    logic        psel;
    logic        penable;
    logic        pwrite;
    logic [2:0]  pprot;
    logic [11:0] paddr;
    logic [31:0] pwdata;
    logic [3:0]  pstrb;
    logic        pready;
    logic [31:0] prdata;
    logic        pslverr;
endinterface
