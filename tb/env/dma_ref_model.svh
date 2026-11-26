// dma_ref_model: predicts the DMA's behavior from spec/dma_spec.md (never from the RTL).
//   - Watches every APB transfer; keeps a shadow of the programmed registers.
//   - On an accepted START, applies rules 4-6 and predicts the exact burst list (with the
//     AXI agent's error ranges), then sends the prediction to the scoreboard.
//   - Predicts STATUS and INT_STATUS, and checks every APB read and every PSLVERR.
// Hardware updates STATUS/INT_STATUS a few cycles after the event the testbench observes,
// so those two registers (and irq) are only compared once the prediction is "settled".
`uvm_analysis_imp_decl(_apb)

class dma_ref_model extends uvm_component;
    `uvm_component_utils(dma_ref_model)

    uvm_analysis_imp_apb #(apb_item, dma_ref_model) apb_imp;
    uvm_analysis_port #(dma_xfer) xfer_ap;     // to the scoreboard

    dma_env_cfg  cfg;
    dma_coverage cov;

    // Shadow of software-written registers
    bit [31:0] r_src, r_dst, r_len;
    bit [7:0]  r_max_burst = 8'h0F;
    bit [1:0]  r_int_enable;

    // Predicted hardware state
    bit        busy;
    bit        st_done, st_err;
    bit [1:0]  st_code;
    bit [1:0]  int_status;     // {ERR, DONE}
    time       t_change;       // last time a predicted STATUS/INT_STATUS/irq value changed
    int        n_xfers, n_reg_checks;

    localparam int SETTLE_CYCLES = 3;

    function new(string name, uvm_component parent);
        super.new(name, parent);
        apb_imp = new("apb_imp", this);
        xfer_ap = new("xfer_ap", this);
    endfunction

    function void changed();
        t_change = $time;
    endfunction

    // True when hardware has had time to reflect every predicted change
    function bit settled();
        return ($time - t_change) >= SETTLE_CYCLES * cfg.clk_period_ns;
    endfunction

    function bit exp_irq();
        return |(int_status & r_int_enable);
    endfunction

    // ------------------------------------------------------------------ APB input
    function void write_apb(apb_item t);
        bit mapped = (t.addr[11:2] < 10'd8);
        if (t.slverr != !mapped)
            `uvm_error("REF_REG", $sformatf("%s: PSLVERR=%0b, expected %0b", t.convert2string(), t.slverr, !mapped))
        if (!mapped) return;
        cov.sample_reg(t.addr, t.write);
        if (t.write) apb_write(t.addr, t.data);
        else         apb_read(t.addr, t.data);
    endfunction

    function void apb_write(bit [11:0] addr, bit [31:0] d);
        case ({addr[11:2], 2'b00})
            REG_INT_STATUS: begin                       // write 1 to clear
                if (exp_irq() && |(d[1:0] & int_status)) cov.sample_irq_clear();
                int_status &= ~d[1:0];
                changed();
            end
            REG_INT_ENABLE: begin r_int_enable = d[1:0]; changed(); end
            REG_SRC:        r_src = d;
            REG_DST:        r_dst = d;
            REG_LEN:        r_len = d;
            REG_CTRL: begin
                r_max_burst = d[15:8];                  // rule 1: same write's MAX_BURST is used
                if (d[0]) start();
            end
            default: ;                                  // VERSION, STATUS: read-only, writes ignored
        endcase
    endfunction

    function void apb_read(bit [11:0] addr, bit [31:0] d);
        bit [31:0] exp;
        bit        check = 1;
        case ({addr[11:2], 2'b00})
            REG_VERSION:    exp = VERSION_VALUE;
            REG_INT_STATUS: begin exp = {30'd0, int_status}; check = settled(); end
            REG_INT_ENABLE: exp = {30'd0, r_int_enable};
            REG_SRC:        exp = r_src;
            REG_DST:        exp = r_dst;
            REG_LEN:        exp = r_len;
            REG_CTRL:       exp = {16'd0, r_max_burst, 8'd0};      // START always reads 0
            REG_STATUS:     begin exp = {26'd0, st_code, 1'b0, st_err, st_done, busy}; check = settled(); end
            default:        exp = 0;
        endcase
        if (check) begin
            n_reg_checks++;
            if (d !== exp)
                `uvm_error("REF_REG", $sformatf("read 0x%03h = 0x%08h, expected 0x%08h", addr, d, exp))
        end
    endfunction

    // ------------------------------------------------------------------ START (rules 1-6)
    function void start();
        dma_xfer x;
        if (busy) begin                                  // rule 2: ignored
            `uvm_info("REF", "START while busy: ignored", UVM_MEDIUM)
            cov.sample_start_busy();
            return;
        end
        x = dma_xfer::type_id::create("x");
        x.id = n_xfers++;
        x.src = r_src; x.dst = r_dst; x.len = r_len; x.max_burst = r_max_burst;

        // Rule 1: START clears the previous result
        st_done = 0; st_err = 0; st_code = CODE_NONE;

        // Rule 4: config error
        x.cfg_causes[CFG_UNALIGNED_SRC] = (x.src[1:0] != 0);
        x.cfg_causes[CFG_UNALIGNED_DST] = (x.dst[1:0] != 0);
        x.cfg_causes[CFG_UNALIGNED_LEN] = (x.len[1:0] != 0);
        x.cfg_causes[CFG_SRC_PAST_TOP]  = (x.len != 0) && ((33'(x.src) + 33'(x.len) - 33'd1) > 33'hFFFF_FFFF);
        x.cfg_causes[CFG_DST_PAST_TOP]  = (x.len != 0) && ((33'(x.dst) + 33'(x.len) - 33'd1) > 33'hFFFF_FFFF);
        x.cfg_err  = (x.cfg_causes != 0);
        x.zero_len = !x.cfg_err && (x.len == 0);         // rule 5

        if (x.cfg_err) begin
            x.outcome = CODE_CFG;
            finish(x.outcome);
        end else if (x.zero_len) begin
            x.outcome = CODE_NONE;
            finish(x.outcome);
        end else begin
            x.src_data = new[x.len / 4];
            foreach (x.src_data[i]) x.src_data[i] = cfg.mem.read_word(x.src + 4 * i);
            plan_bursts(x);
            busy = 1;
            changed();
        end
        `uvm_info("REF", {"START: ", x.convert2string()}, UVM_MEDIUM)
        cov.sample_xfer(x);
        xfer_ap.write(x);
    endfunction

    // Rule 6 repeated until no words remain; stops at the first burst that will fail (rules 9, 10)
    function void plan_bursts(dma_xfer x);
        bit [31:0] s = x.src, d = x.dst;
        longint    words = x.len / 4;
        bit        stopped = 0;
        x.outcome = CODE_NONE;
        x.n_planned = 0;
        while (words > 0) begin
            dma_burst_t b;
            longint n = words;
            b.cut = CUT_REMAIN;
            if (x.max_burst + 1 < n)   begin n = x.max_burst + 1;   b.cut = CUT_MAXB;  end
            if (1024 - s[11:2] < n)    begin n = 1024 - s[11:2];    b.cut = CUT_SRC4K; end
            if (1024 - d[11:2] < n)    begin n = 1024 - d[11:2];    b.cut = CUT_DST4K; end
            b.src = s; b.dst = d; b.beats = int'(n);
            b.rd_err = 0;
            for (int i = 0; i < n; i++) if (cfg.axi_cfg.rd_resp(s + 4 * i) != RESP_OKAY) b.rd_err = 1;
            b.wr_err = !b.rd_err && (cfg.axi_cfg.wr_resp(d, int'(n)) != RESP_OKAY);
            x.n_planned++;
            if (!stopped) begin
                x.bursts.push_back(b);
                if (b.rd_err)      begin x.outcome = CODE_RD; stopped = 1; end
                else if (b.wr_err) begin x.outcome = CODE_WR; stopped = 1; end
            end
            s += 4 * n; d += 4 * n; words -= n;
        end
    endfunction

    // ------------------------------------------------------------------ end of a transfer
    // Called directly for config errors / zero length, and by the scoreboard when the last
    // predicted burst has been observed on AXI.
    function void finish(int code);
        busy = 0;
        if (code == CODE_NONE) begin st_done = 1; int_status[0] = 1; end
        else begin st_err = 1; st_code = code[1:0]; int_status[1] = 1; end
        cov.sample_irq(code, (code == CODE_NONE) ? r_int_enable[0] : r_int_enable[1]);
        changed();
    endfunction

    function void report_phase(uvm_phase phase);
        `uvm_info("REF", $sformatf("%0d transfers predicted, %0d register reads checked", n_xfers, n_reg_checks), UVM_LOW)
    endfunction
endclass
