// dma_burst_calc: size of the next burst (spec rule 6). Purely combinational.
//   N = min(words remaining, MAX_BURST + 1,
//           words left before the next 4 KB boundary from SRC,
//           words left before the next 4 KB boundary from DST)
module dma_burst_calc (
    input  logic [31:0] src,        // current source byte address (word aligned)
    input  logic [31:0] dst,        // current destination byte address (word aligned)
    input  logic [31:0] words_rem,  // words still to move (> 0 when used)
    input  logic [7:0]  max_burst,  // beats per burst minus 1
    output logic [8:0]  n_beats     // 1..256
);
    // Words left before the 4 KB boundary: (4096 - addr[11:0]) / 4 = 1024 - addr[11:2]
    logic [31:0] src_room, dst_room, burst_cap, n;

    assign src_room  = 32'd1024 - {22'd0, src[11:2]};   // 1..1024
    assign dst_room  = 32'd1024 - {22'd0, dst[11:2]};   // 1..1024
    assign burst_cap = {24'd0, max_burst} + 32'd1;      // 1..256

    always_comb begin
        n = words_rem;
        if (burst_cap < n) n = burst_cap;
        if (src_room  < n) n = src_room;
        if (dst_room  < n) n = dst_room;
    end

    assign n_beats = n[8:0];  // n <= burst_cap <= 256, so 9 bits are enough

endmodule
