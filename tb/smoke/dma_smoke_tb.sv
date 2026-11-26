// dma_smoke_tb: quick directed bring-up test for the DMA RTL (plain SystemVerilog, no UVM).
// The full UVM testbench lives in tb/; this one only proves the RTL works end to end.
//   - APB master tasks (drive and sample on the falling edge)
//   - AXI4 memory slave with random READY / beat gaps and error address ranges
//   - Expected burst plan computed from spec rule 6, compared with every AR and AW
`timescale 1ns/1ps
module dma_smoke_tb;

    // ------------------------------------------------------------------ clock/reset
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    // ------------------------------------------------------------------ DUT ports
    logic        psel, penable, pwrite, pready, pslverr;
    logic [2:0]  pprot;
    logic [11:0] paddr;
    logic [31:0] pwdata, prdata;
    logic [3:0]  pstrb;

    logic        awvalid, awready, awid, awlock, wvalid, wready, wlast, bvalid, bready, bid;
    logic [31:0] awaddr, wdata;
    logic [7:0]  awlen;
    logic [2:0]  awsize, awprot;
    logic [1:0]  awburst, bresp;
    logic [3:0]  awcache, awqos, wstrb;
    logic        arvalid, arready, arid, arlock, rvalid, rready, rid, rlast;
    logic [31:0] araddr, rdata;
    logic [7:0]  arlen;
    logic [2:0]  arsize, arprot;
    logic [1:0]  arburst, rresp;
    logic [3:0]  arcache, arqos;
    logic        irq;

    dma_top dut (.*);

    // ------------------------------------------------------------------ bookkeeping
    int errors = 0;
    `define CHECK(cond, msg) if (!(cond)) begin errors++; $display("[%0t] ERROR: %s", $time, msg); end

    typedef struct { bit [31:0] addr; int beats; } burst_t;
    burst_t ar_log[$], aw_log[$];
    bit [31:0] wr_addr_log[$];

    // Memory: unwritten words read as a hash of their address, so sources need no preload.
    bit [31:0] mem [bit [31:0]];
    function automatic bit [31:0] pattern(bit [31:0] a); return {a[15:0], ~a[15:0]} ^ 32'h5A5A_1234; endfunction
    function automatic bit [31:0] mem_rd(bit [31:0] a); return mem.exists(a) ? mem[a] : pattern(a); endfunction

    // Slave knobs
    int ready_pct = 100;   // chance (%) that a READY is high in a given cycle
    int gap_pct   = 0;     // chance (%) of a gap before an R beat / B response
    bit [31:0] rd_err_lo = 32'hFFFF_FFFF, rd_err_hi = 0;   // empty range = no errors
    bit [31:0] wr_err_lo = 32'hFFFF_FFFF, wr_err_hi = 0;
    bit [1:0]  err_resp  = 2'b10;                          // SLVERR (2'b11 = DECERR)
    bit aw_waits_for_w = 0;   // slave holds AWREADY low until it has seen a W beat
    bit w_waits_for_aw = 0;   // slave holds WREADY low until it has seen AW

    function automatic bit rnd(int pct); return ($urandom_range(99) < pct); endfunction
    function automatic bit in_rng(bit [31:0] a, bit [31:0] lo, bit [31:0] hi); return (a >= lo) && (a <= hi); endfunction

    // ------------------------------------------------------------------ AXI read slave
    logic [31:0] r_addr; logic [7:0] r_len, r_beat; bit r_active;
    always @(posedge clk) begin
        if (!rst_n) begin
            arready <= 0; rvalid <= 0; rlast <= 0; rdata <= 0; rresp <= 0; r_active <= 0;
        end else if (!r_active) begin
            if (arvalid && arready) begin
                `CHECK(arsize == 3'b010 && arburst == 2'b01 && arid == 0 && arlock == 0 && arcache == 0 && arprot == 0 && arqos == 0, "AR fixed fields")
                `CHECK(araddr[11:0] + (arlen + 1) * 4 <= 4096, $sformatf("AR crosses 4KB: addr=%h len=%0d", araddr, arlen))
                ar_log.push_back('{araddr, arlen + 1});
                r_addr <= araddr; r_len <= arlen; r_beat <= 0; r_active <= 1; arready <= 0;
            end else arready <= rnd(ready_pct);
        end else begin
            if (rvalid && rready) begin                       // beat accepted
                if (rlast) begin rvalid <= 0; rlast <= 0; r_active <= 0; end
                else begin r_beat <= r_beat + 1; rvalid <= 0; end
            end else if (!rvalid && !rnd(gap_pct)) begin      // present the current beat
                rvalid <= 1;
                rdata  <= mem_rd(r_addr + 4 * r_beat);
                rresp  <= in_rng(r_addr + 4 * r_beat, rd_err_lo, rd_err_hi) ? err_resp : 2'b00;
                rlast  <= (r_beat == r_len);
            end
        end
    end

    // ------------------------------------------------------------------ AXI write slave
    logic [31:0] w_addr; logic [7:0] w_len; bit aw_got, w_got; int w_cnt;
    bit [31:0] w_buf [256];
    always @(posedge clk) begin
        if (!rst_n) begin
            awready <= 0; wready <= 0; bvalid <= 0; bresp <= 0; aw_got <= 0; w_got <= 0; w_cnt <= 0;
        end else begin
            // AW
            if (!aw_got) begin
                if (awvalid && awready) begin
                    `CHECK(awsize == 3'b010 && awburst == 2'b01 && awid == 0 && awlock == 0 && awcache == 0 && awprot == 0 && awqos == 0, "AW fixed fields")
                    `CHECK(awaddr[11:0] + (awlen + 1) * 4 <= 4096, $sformatf("AW crosses 4KB: addr=%h len=%0d", awaddr, awlen))
                    aw_log.push_back('{awaddr, awlen + 1});
                    w_addr <= awaddr; w_len <= awlen; aw_got <= 1; awready <= 0;
                end else awready <= rnd(ready_pct) && (!aw_waits_for_w || w_cnt > 0 || w_got);
            end
            // W (may arrive before AW; data is buffered)
            if (!w_got) begin
                if (wvalid && wready) begin
                    `CHECK(wstrb == 4'hF, "WSTRB not all ones")
                    w_buf[w_cnt] <= wdata;
                    w_cnt <= w_cnt + 1;
                    if (wlast) begin w_got <= 1; wready <= 0; end
                    else wready <= rnd(ready_pct) && (!w_waits_for_aw || aw_got);
                end else wready <= rnd(ready_pct) && (!w_waits_for_aw || aw_got);
            end
            // B: only after AW and the last W beat
            if (aw_got && w_got && !bvalid && !rnd(gap_pct)) begin
                bit err;
                err = 0;   // not "bit err = 0;": a static initializer runs only once
                `CHECK(w_cnt == w_len + 1, $sformatf("WLAST on beat %0d, AWLEN+1=%0d", w_cnt, w_len + 1))
                for (int i = 0; i < w_cnt; i++) if (in_rng(w_addr + 4 * i, wr_err_lo, wr_err_hi)) err = 1;
                if (!err) for (int i = 0; i < w_cnt; i++) begin
                    mem[w_addr + 4 * i] = w_buf[i];
                    wr_addr_log.push_back(w_addr + 4 * i);
                end
                bvalid <= 1; bresp <= err ? err_resp : 2'b00;
            end
            if (bvalid && bready) begin
                bvalid <= 0; aw_got <= 0; w_got <= 0; w_cnt <= 0;
            end
        end
    end

    // AXI master-side rule: VALID stays high with a stable payload until READY (checked here too)
    logic        p_arv, p_awv, p_wv; logic [31:0] p_ara, p_awa, p_wd; logic [7:0] p_arl, p_awl; logic p_wl;
    always @(posedge clk) begin
        if (rst_n) begin
            if (p_arv) `CHECK(arvalid && araddr == p_ara && arlen == p_arl, "ARVALID/payload dropped before ARREADY")
            if (p_awv) `CHECK(awvalid && awaddr == p_awa && awlen == p_awl, "AWVALID/payload dropped before AWREADY")
            if (p_wv)  `CHECK(wvalid && wdata == p_wd && wlast == p_wl, "WVALID/payload dropped before WREADY")
        end
        p_arv <= arvalid && !arready; p_ara <= araddr; p_arl <= arlen;
        p_awv <= awvalid && !awready; p_awa <= awaddr; p_awl <= awlen;
        p_wv  <= wvalid  && !wready;  p_wd  <= wdata;  p_wl  <= wlast;
    end

    // ------------------------------------------------------------------ APB master
    task automatic apb(input bit wr, input bit [11:0] a, input bit [31:0] d, output bit [31:0] rd, output bit err);
        @(negedge clk);
        psel = 1; penable = 0; pwrite = wr; paddr = a; pwdata = d; pstrb = 4'hF; pprot = 0;
        @(negedge clk);
        penable = 1;
        #1;
        while (!pready) begin @(negedge clk); #1; end
        rd = prdata; err = pslverr;
        @(posedge clk);                       // transfer completes on this edge
        #1 psel = 0; penable = 0;
    endtask
    task automatic wr32(bit [11:0] a, bit [31:0] d);
        bit [31:0] r; bit e; apb(1, a, d, r, e);
        `CHECK(!e, $sformatf("unexpected PSLVERR on write to %h", a))
    endtask
    task automatic rd32(bit [11:0] a, output bit [31:0] d);
        bit e; apb(0, a, 0, d, e);
        `CHECK(!e, $sformatf("unexpected PSLVERR on read of %h", a))
    endtask

    localparam bit [11:0] VERSION = 12'h00, INT_STATUS = 12'h04, INT_ENABLE = 12'h08, SRC = 12'h0C,
                          DST = 12'h10, LEN = 12'h14, CTRL = 12'h18, STATUS = 12'h1C;

    // ------------------------------------------------------------------ expected plan (spec rule 6)
    function automatic void plan(bit [31:0] s, bit [31:0] d, bit [31:0] len, int mb, ref burst_t rd_q[$], ref burst_t wr_q[$],
                                 output int code);
        longint words = len / 4;
        rd_q.delete(); wr_q.delete(); code = 0;
        while (words > 0) begin
            longint n = words;
            bit re = 0, we = 0;
            if (mb + 1 < n) n = mb + 1;
            if (1024 - s[11:2] < n) n = 1024 - s[11:2];
            if (1024 - d[11:2] < n) n = 1024 - d[11:2];
            rd_q.push_back('{s, int'(n)});
            for (int i = 0; i < n; i++) if (in_rng(s + 4 * i, rd_err_lo, rd_err_hi)) re = 1;
            if (re) begin code = 2; return; end          // no write after a read error
            wr_q.push_back('{d, int'(n)});
            for (int i = 0; i < n; i++) if (in_rng(d + 4 * i, wr_err_lo, wr_err_hi)) we = 1;
            if (we) begin code = 3; return; end
            s += 4 * n; d += 4 * n; words -= n;
        end
    endfunction

    // ------------------------------------------------------------------ one transfer, fully checked
    task automatic run_xfer(string name, bit [31:0] s, bit [31:0] d, bit [31:0] len, int mb,
                            bit expect_cfg_err = 0);
        burst_t exp_rd[$], exp_wr[$];
        int code, n_written;
        bit [31:0] st, is;
        int t0 = errors;

        ar_log.delete(); aw_log.delete(); wr_addr_log.delete();
        plan(s, d, len, mb, exp_rd, exp_wr, code);
        if (expect_cfg_err) begin code = 1; exp_rd.delete(); exp_wr.delete(); end

        wr32(INT_STATUS, 32'h3);                          // clear old interrupt bits
        wr32(SRC, s); wr32(DST, d); wr32(LEN, len);
        wr32(CTRL, (mb << 8) | 1);                        // MAX_BURST and START in one write (rule 1)
        do rd32(STATUS, st); while (st[0]);               // wait while BUSY

        // Status (rules 4, 5, 9, 10, 11)
        `CHECK(st[1] == (code == 0), $sformatf("%s: STATUS.DONE=%0b", name, st[1]))
        `CHECK(st[2] == (code != 0), $sformatf("%s: STATUS.ERR=%0b", name, st[2]))
        `CHECK(st[5:4] == code[1:0], $sformatf("%s: ERR_CODE=%0d expected %0d", name, st[5:4], code))
        rd32(INT_STATUS, is);
        `CHECK(is[1:0] == ((code == 0) ? 2'b01 : 2'b10), $sformatf("%s: INT_STATUS=%b", name, is[1:0]))

        // Burst plan (rules 6, 7, 9)
        `CHECK(ar_log.size() == exp_rd.size(), $sformatf("%s: %0d AR bursts, expected %0d", name, ar_log.size(), exp_rd.size()))
        `CHECK(aw_log.size() == exp_wr.size(), $sformatf("%s: %0d AW bursts, expected %0d", name, aw_log.size(), exp_wr.size()))
        foreach (exp_rd[i]) if (i < ar_log.size())
            `CHECK(ar_log[i] == exp_rd[i], $sformatf("%s: AR[%0d] = %h/%0d expected %h/%0d", name, i, ar_log[i].addr, ar_log[i].beats, exp_rd[i].addr, exp_rd[i].beats))
        foreach (exp_wr[i]) if (i < aw_log.size())
            `CHECK(aw_log[i] == exp_wr[i], $sformatf("%s: AW[%0d] = %h/%0d expected %h/%0d", name, i, aw_log[i].addr, aw_log[i].beats, exp_wr[i].addr, exp_wr[i].beats))

        // Data: every successfully written burst copied the source; nothing outside [DST, DST+LEN)
        n_written = 0;
        foreach (exp_wr[i]) if (!(code == 3 && i == exp_wr.size() - 1)) n_written += exp_wr[i].beats;
        for (int i = 0; i < n_written; i++)
            `CHECK(mem_rd(d + 4 * i) == pattern(s + 4 * i), $sformatf("%s: data mismatch at %h", name, d + 4 * i))
        foreach (wr_addr_log[i])
            `CHECK(wr_addr_log[i] >= d && {1'b0, wr_addr_log[i]} < {1'b0, d} + len, $sformatf("%s: stray write at %h", name, wr_addr_log[i]))

        $display("[%0t] %-28s %s  (%0d bursts, code %0d)", $time, name, (errors == t0) ? "PASS" : "FAIL", ar_log.size(), code);
        mem.delete();
    endtask

    // ------------------------------------------------------------------ tests
    initial begin
        bit [31:0] r, st; bit e;
        psel = 0; penable = 0; pwrite = 0; paddr = 0; pwdata = 0; pstrb = 0; pprot = 0;
        repeat (3) @(posedge clk);
        rst_n <= 1;

        // Registers: reset values, unmapped address
        rd32(VERSION, r);  `CHECK(r == 32'h0001_0000, $sformatf("VERSION=%h", r))
        rd32(CTRL, r);     `CHECK(r == 32'h0000_0F00, $sformatf("CTRL reset=%h", r))
        rd32(STATUS, r);   `CHECK(r == 0, $sformatf("STATUS reset=%h", r))
        apb(0, 12'h020, 0, r, e);  `CHECK(e, "no PSLVERR on unmapped read")
        apb(1, 12'h800, 0, r, e);  `CHECK(e, "no PSLVERR on unmapped write")
        $display("[%0t] %-28s %s", $time, "register_basics", errors == 0 ? "PASS" : "FAIL");

        // Directed transfers, no delays
        run_xfer("worked_example",      32'h0000_0FE0, 32'h0000_2000, 80, 15);
        run_xfer("single_word",         32'h0000_0100, 32'h0000_0800, 4, 15);
        run_xfer("max_burst_0",         32'h0000_0100, 32'h0000_0800, 40, 0);
        run_xfer("max_burst_255",       32'h0001_0000, 32'h0002_0000, 4096, 255);
        run_xfer("short_last_burst",    32'h0001_0000, 32'h0002_0000, 4 * 37, 15);
        run_xfer("dst_4k_limit",        32'h0001_0000, 32'h0002_0FF8, 64, 31);
        run_xfer("both_4k_different",   32'h0001_0FF0, 32'h0002_0FE8, 256, 63);
        run_xfer("crosses_many_4k",     32'h0001_0800, 32'h0003_0400, 20000, 255);
        run_xfer("ends_at_ffffffff",    32'hFFFF_FFC0, 32'h0001_0000, 64, 15);
        run_xfer("zero_length",         32'h0000_0100, 32'h0000_0800, 0, 15);
        run_xfer("cfg_unaligned_src",   32'h0000_0102, 32'h0000_0800, 16, 15, 1);
        run_xfer("cfg_unaligned_dst",   32'h0000_0100, 32'h0000_0801, 16, 15, 1);
        run_xfer("cfg_unaligned_len",   32'h0000_0100, 32'h0000_0800, 18, 15, 1);
        run_xfer("cfg_unaligned_len0",  32'h0000_0102, 32'h0000_0800, 0, 15, 1);
        run_xfer("cfg_past_top",        32'hFFFF_FFC0, 32'h0001_0000, 68, 15, 1);

        // Errors
        rd_err_lo = 32'h0003_0040; rd_err_hi = 32'h0003_0040;          // one bad word in burst 3
        run_xfer("read_err_middle_burst", 32'h0003_0000, 32'h0004_0000, 256, 7);
        err_resp = 2'b11;
        rd_err_lo = 32'h0003_0000; rd_err_hi = 32'h0003_0000;          // first beat, DECERR
        run_xfer("read_err_first_beat",   32'h0003_0000, 32'h0004_0000, 64, 15);
        rd_err_lo = 32'hFFFF_FFFF; rd_err_hi = 0; err_resp = 2'b10;
        wr_err_lo = 32'h0004_0020; wr_err_hi = 32'h0004_0020;
        run_xfer("write_err",             32'h0003_0000, 32'h0004_0000, 256, 7);
        wr_err_lo = 32'hFFFF_FFFF; wr_err_hi = 0;

        // Random delays on every channel
        ready_pct = 40; gap_pct = 50;
        run_xfer("backpressure_example",  32'h0000_0FE0, 32'h0000_2000, 80, 15);
        for (int i = 0; i < 30; i++) begin
            int ord = $urandom_range(0, 2);   // 0: no ordering, 1: AW waits for W, 2: W waits for AW
            aw_waits_for_w = (ord == 1); w_waits_for_aw = (ord == 2);
            begin
            bit [31:0] s = {$urandom_range(0, 255), 12'h000} | ($urandom_range(0, 1023) << 2);
            bit [31:0] d = 32'h0100_0000 + ({$urandom_range(0, 255), 12'h000} | ($urandom_range(0, 1023) << 2));
            run_xfer($sformatf("random_%0d", i), s, d, $urandom_range(1, 700) * 4, $urandom_range(0, 255));
            end
        end
        aw_waits_for_w = 1;                                                 // directed: slave wants W first
        run_xfer("aw_waits_for_w",        32'h0000_0FE0, 32'h0000_2000, 80, 15);
        aw_waits_for_w = 0; w_waits_for_aw = 1;                             // directed: slave wants AW first
        run_xfer("w_waits_for_aw",        32'h0000_0FE0, 32'h0000_2000, 80, 15);
        w_waits_for_aw = 0;
        ready_pct = 100; gap_pct = 0;

        // START while busy (rule 2) and register writes while busy (rule 3)
        begin
            int n_ar;
            ar_log.delete(); aw_log.delete();
            wr32(SRC, 32'h0005_0000); wr32(DST, 32'h0006_0000); wr32(LEN, 1024);
            wr32(CTRL, (3 << 8) | 1);
            wr32(SRC, 32'h0007_0000); wr32(LEN, 4); wr32(CTRL, (0 << 8) | 1);   // ignored by the running transfer
            do rd32(STATUS, st); while (st[0]);
            n_ar = ar_log.size();
            `CHECK(n_ar == 64 && ar_log[63].addr == 32'h0005_03F0 && aw_log.size() == 64, $sformatf("start_while_busy: %0d bursts", n_ar))
            for (int i = 0; i < 256; i++) `CHECK(mem_rd(32'h0006_0000 + 4 * i) == pattern(32'h0005_0000 + 4 * i), "start_while_busy data")
            $display("[%0t] %-28s %s", $time, "start_while_busy", errors == 0 ? "PASS" : "FAIL");
            mem.delete();
        end

        // Interrupts (rule 12)
        begin
            wr32(INT_STATUS, 3); wr32(INT_ENABLE, 0);
            wr32(SRC, 32'h100); wr32(DST, 32'h900); wr32(LEN, 16); wr32(CTRL, 32'h0F01);
            do rd32(STATUS, st); while (st[0]);
            `CHECK(!irq, "irq high while masked")
            wr32(INT_ENABLE, 1);  #1 `CHECK(irq, "irq low after enabling DONE")
            wr32(INT_STATUS, 2);  #1 `CHECK(irq, "clearing ERR bit dropped irq")
            wr32(INT_STATUS, 1);  #1 `CHECK(!irq, "irq still high after W1C")
            wr32(INT_ENABLE, 2); wr32(LEN, 6); wr32(CTRL, 32'h0F01);      // config error -> ERR
            do rd32(STATUS, st); while (st[0]);
            #1 `CHECK(irq, "no irq on error")
            wr32(INT_STATUS, 2); #1 `CHECK(!irq, "error irq not cleared")
            $display("[%0t] %-28s %s", $time, "irq", errors == 0 ? "PASS" : "FAIL");
        end

        $display("\n==== SMOKE TEST %s (%0d errors) ====", errors == 0 ? "PASSED" : "FAILED", errors);
        if (errors != 0) $fatal(1, "smoke test failed");   // non-zero exit code for CI
        $finish;
    end

    initial begin
        #50ms $display("TIMEOUT"); $fatal(1, "watchdog timeout");
    end

endmodule
