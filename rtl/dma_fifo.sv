// dma_fifo: holds one burst of read data (256 x 32 bits = one maximum burst).
// Show-ahead: rdata is the oldest entry whenever the FIFO is not empty.
module dma_fifo #(
    parameter int DEPTH = 256,
    parameter int WIDTH = 32
) (
    input  logic             clk,
    input  logic             rst_n,
    input  logic             clear,   // drop all contents (after a read error)
    input  logic             push,
    input  logic [WIDTH-1:0] wdata,
    input  logic             pop,
    output logic [WIDTH-1:0] rdata,
    output logic             full,
    output logic             empty
);
    localparam int AW = $clog2(DEPTH);

    logic [WIDTH-1:0] mem [DEPTH];
    logic [AW-1:0]    wr_ptr, rd_ptr;
    logic [AW:0]      count;

    always_ff @(posedge clk) begin
        if (push) mem[wr_ptr] <= wdata;
    end

    always_ff @(posedge clk) begin
        if (!rst_n || clear) begin
            wr_ptr <= '0;
            rd_ptr <= '0;
            count  <= '0;
        end else begin
            if (push) wr_ptr <= wr_ptr + 1'b1;
            if (pop)  rd_ptr <= rd_ptr + 1'b1;
            case ({push, pop})
                2'b10:   count <= count + 1'b1;
                2'b01:   count <= count - 1'b1;
                default: count <= count;
            endcase
        end
    end

    assign rdata = mem[rd_ptr];
    assign full  = (count == (AW+1)'(DEPTH));
    assign empty = (count == '0);

`ifndef SYNTHESIS
    // Design-intent checks: the DMA never overfills or over-reads its FIFO.
    a_no_push_when_full: assert property (@(posedge clk) disable iff (!rst_n) !(push && full && !clear));
    a_no_pop_when_empty: assert property (@(posedge clk) disable iff (!rst_n) !(pop && empty && !clear));
`endif

endmodule
