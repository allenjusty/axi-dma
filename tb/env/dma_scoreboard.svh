// dma_scoreboard: compares every observed AXI transaction with the predicted burst list,
// in order, and checks memory when a transfer ends.
`uvm_analysis_imp_decl(_xfer)
`uvm_analysis_imp_decl(_axi)

class dma_scoreboard extends uvm_scoreboard;
    `uvm_component_utils(dma_scoreboard)

    uvm_analysis_imp_xfer #(dma_xfer, dma_scoreboard) xfer_imp;
    uvm_analysis_imp_axi  #(axi_item, dma_scoreboard) axi_imp;

    dma_env_cfg   cfg;
    dma_ref_model ref_m;
    dma_coverage  cov;

    dma_xfer cur;           // transfer in progress (at most one)
    int      rd_idx;        // bursts whose read has been observed
    int      wr_idx;        // bursts whose write has been observed
    int      n_done, n_bursts, n_words;

    function new(string name, uvm_component parent);
        super.new(name, parent);
        xfer_imp = new("xfer_imp", this);
        axi_imp  = new("axi_imp", this);
    endfunction

    // ------------------------------------------------------------------ predictions
    function void write_xfer(dma_xfer x);
        if (cur != null)
            `uvm_error("SB", $sformatf("new transfer started while xfer#%0d still has %0d bursts outstanding",
                                       cur.id, cur.bursts.size() - wr_idx))
        if (x.bursts.size() == 0) begin   // config error / zero length: no bus traffic allowed
            n_done++;
            return;
        end
        cur = x; rd_idx = 0; wr_idx = 0;
    endfunction

    // ------------------------------------------------------------------ AXI observations
    function void write_axi(axi_item t);
        cov.sample_axi(t);
        check_fixed_fields(t);
        if (cur == null) begin
            `uvm_error("SB", {"unexpected AXI traffic (no transfer active): ", t.convert2string()})
            return;
        end
        if (t.kind == AXI_READ) check_read(t);
        else                    check_write(t);
    endfunction

    function void check_fixed_fields(axi_item t);
        if (t.size != 3'b010 || t.burst != 2'b01 || t.id != 0)
            `uvm_error("SB", {"wrong fixed AXI fields: ", t.convert2string()})
        if ({1'b0, t.addr[11:0]} + 13'(t.len + 1) * 13'd4 > 13'h1000)
            `uvm_error("SB", {"burst crosses a 4 KB boundary: ", t.convert2string()})
        if (t.last_beat != t.len)
            `uvm_error("SB", $sformatf("xLAST on beat %0d, expected %0d: %s", t.last_beat, t.len, t.convert2string()))
        if (t.kind == AXI_WRITE) foreach (t.strb[i])
            if (t.strb[i] != 4'hF) `uvm_error("SB", $sformatf("WSTRB=%h on beat %0d", t.strb[i], i))
    endfunction

    // Rule 7: read k only after write k-1 finished; the read must match burst k
    function void check_read(axi_item t);
        dma_burst_t b;
        int err_beat = -1;
        if (rd_idx != wr_idx || rd_idx >= cur.bursts.size()) begin
            `uvm_error("SB", $sformatf("unexpected read (reads seen %0d, writes seen %0d, planned %0d): %s",
                                       rd_idx, wr_idx, cur.bursts.size(), t.convert2string()))
            return;
        end
        b = cur.bursts[rd_idx];
        if (t.addr != b.src || t.len + 1 != b.beats)
            `uvm_error("SB", $sformatf("xfer#%0d burst %0d read: addr=0x%08h beats=%0d, expected addr=0x%08h beats=%0d",
                                       cur.id, rd_idx, t.addr, t.len + 1, b.src, b.beats))
        foreach (t.resp[i]) if (t.resp[i][1] && err_beat < 0) err_beat = i;
        if ((err_beat >= 0) != b.rd_err)
            `uvm_error("SB", $sformatf("burst %0d read error=%0b, predicted %0b", rd_idx, err_beat >= 0, b.rd_err))
        rd_idx++;
        n_bursts++;
        cov.sample_burst(b);
        if (b.rd_err) begin
            cov.sample_error(0, rd_idx - 1, cur.n_planned, t.resp[err_beat], err_beat, b.beats);
            end_xfer(CODE_RD);                            // rule 9: no write follows
        end
    endfunction

    // The write must match burst k and carry exactly the source words of that burst
    function void check_write(axi_item t);
        dma_burst_t b;
        int off;
        if (wr_idx != rd_idx - 1) begin
            `uvm_error("SB", $sformatf("write without its read (reads seen %0d, writes seen %0d): %s",
                                       rd_idx, wr_idx, t.convert2string()))
            return;
        end
        b   = cur.bursts[wr_idx];
        off = (b.src - cur.src) / 4;
        if (t.addr != b.dst || t.len + 1 != b.beats)
            `uvm_error("SB", $sformatf("xfer#%0d burst %0d write: addr=0x%08h beats=%0d, expected addr=0x%08h beats=%0d",
                                       cur.id, wr_idx, t.addr, t.len + 1, b.dst, b.beats))
        foreach (t.data[i])
            if (off + i < cur.src_data.size() && t.data[i] != cur.src_data[off + i])
                `uvm_error("SB", $sformatf("xfer#%0d write data beat %0d at 0x%08h = 0x%08h, expected 0x%08h",
                                           cur.id, i, t.addr + 4 * i, t.data[i], cur.src_data[off + i]))
        if (t.resp[0][1] != b.wr_err)
            `uvm_error("SB", $sformatf("burst %0d BRESP=%0d, predicted error=%0b", wr_idx, t.resp[0], b.wr_err))
        wr_idx++;
        n_words += b.beats;
        if (b.wr_err) begin
            cov.sample_error(1, wr_idx - 1, cur.n_planned, t.resp[0], 0, b.beats);
            end_xfer(CODE_WR);                            // rule 10
        end else if (wr_idx == cur.bursts.size()) end_xfer(CODE_NONE);   // rule 11
    endfunction

    // ------------------------------------------------------------------ end of transfer
    function void end_xfer(int code);
        int n_written = 0;
        if (code != cur.outcome)
            `uvm_error("SB", $sformatf("xfer#%0d ended with code %0d, predicted %0d", cur.id, code, cur.outcome))
        // Words of every burst whose write succeeded
        foreach (cur.bursts[i]) if (i < wr_idx && !cur.bursts[i].wr_err) n_written += cur.bursts[i].beats;
        for (int i = 0; i < n_written; i++)
            if (cfg.mem.read_word(cur.dst + 4 * i) != cur.src_data[i])
                `uvm_error("SB", $sformatf("xfer#%0d memory at 0x%08h = 0x%08h, expected 0x%08h",
                                           cur.id, cur.dst + 4 * i, cfg.mem.read_word(cur.dst + 4 * i), cur.src_data[i]))
        foreach (cur.src_data[i])                         // source must be untouched
            if (cfg.mem.read_word(cur.src + 4 * i) != cur.src_data[i])
                `uvm_error("SB", $sformatf("xfer#%0d source word at 0x%08h changed", cur.id, cur.src + 4 * i))
        `uvm_info("SB", $sformatf("xfer#%0d complete: %0d bursts, %0d words written, code %0d",
                                  cur.id, wr_idx + (code == CODE_RD), n_written, code), UVM_MEDIUM)
        ref_m.finish(code);
        n_done++;
        cur = null;
    endfunction

    function void check_phase(uvm_phase phase);
        if (cur != null)
            `uvm_error("SB", $sformatf("xfer#%0d never finished: %0d of %0d bursts read, %0d written",
                                       cur.id, rd_idx, cur.bursts.size(), wr_idx))
    endfunction

    function void report_phase(uvm_phase phase);
        `uvm_info("SB", $sformatf("%0d transfers checked, %0d bursts, %0d words", n_done, n_bursts, n_words), UVM_LOW)
    endfunction
endclass
