// Functional coverage (coverage plan in docs/testplan.md). Plain coverpoints with explicit
// bins and plain full crosses only, so Verilator keeps them all.
class dma_coverage extends uvm_component;
    `uvm_component_utils(dma_coverage)

    // ---- sampled values
    bit [31:0] c_len;
    int        c_len_vs_burst;   // 0 exact multiple of a full burst, 1 one word more, 2 one word less, 3 other
    int        c_beats;
    int        c_cut;
    bit        c_src_near, c_dst_near;
    int        c_ar_wait, c_aw_wait, c_w_wait, c_r_wait, c_b_wait, c_order;
    int        c_err_kind;       // 0 read, 1 write
    int        c_err_pos;        // 0 first burst, 1 middle, 2 last
    int        c_err_beat;       // read errors: 0 first beat, 1 middle, 2 last
    int        c_err_resp;       // 0 SLVERR, 1 DECERR
    int        c_cfg;            // 0..4 dma_cfg_cause_e, 5 zero length, 6 START while busy
    int        c_outcome;        // 0 done, 1 error
    bit        c_irq_en;
    int        c_reg;
    bit        c_reg_wr;

    covergroup cg_xfer;
        cp_len: coverpoint c_len {
            bins zero     = {0};
            bins one_word = {4};
            bins words_2_16   = {[8:64]};
            bins words_17_256 = {[68:1024]};
            bins words_257_up = {[1028:32'hFFFF_FFFF]};
        }
        cp_len_vs_burst: coverpoint c_len_vs_burst {
            bins exact_multiple = {0};
            bins one_word_more  = {1};
            bins one_word_less  = {2};
            bins other          = {3};
        }
    endgroup

    covergroup cg_burst;
        cp_beats: coverpoint c_beats {
            bins one      = {1};
            bins b2_15    = {[2:15]};
            bins b16      = {16};
            bins b17_255  = {[17:255]};
            bins b256     = {256};
        }
        cp_cut: coverpoint c_cut {
            bins remaining = {CUT_REMAIN};
            bins max_burst = {CUT_MAXB};
            bins src_4k    = {CUT_SRC4K};
            bins dst_4k    = {CUT_DST4K};
        }
    endgroup

    covergroup cg_boundary;
        cp_src_near: coverpoint c_src_near { bins no = {0}; bins yes = {1}; }
        cp_dst_near: coverpoint c_dst_near { bins no = {0}; bins yes = {1}; }
        x_near: cross cp_src_near, cp_dst_near;
    endgroup

    covergroup cg_read_timing;
        cp_ar_wait: coverpoint c_ar_wait { bins none = {0}; bins short_ = {[1:3]}; bins long_ = {[4:$]}; }
        cp_r_wait:  coverpoint c_r_wait  { bins none = {0}; bins short_ = {[1:3]}; bins long_ = {[4:$]}; }
    endgroup

    covergroup cg_write_timing;
        cp_aw_wait: coverpoint c_aw_wait { bins none = {0}; bins short_ = {[1:3]}; bins long_ = {[4:$]}; }
        cp_w_wait:  coverpoint c_w_wait  { bins none = {0}; bins short_ = {[1:3]}; bins long_ = {[4:$]}; }
        cp_b_wait:  coverpoint c_b_wait  { bins none = {0}; bins short_ = {[1:3]}; bins long_ = {[4:$]}; }
        cp_order:   coverpoint c_order   { bins aw_first = {-1}; bins same_cycle = {0}; bins w_first = {1}; }
    endgroup

    covergroup cg_error;
        cp_kind: coverpoint c_err_kind { bins read = {0}; bins write = {1}; }
        cp_pos:  coverpoint c_err_pos  { bins first = {0}; bins middle = {1}; bins last = {2}; }
        cp_resp: coverpoint c_err_resp { bins slverr = {0}; bins decerr = {1}; }
        x_kind_pos: cross cp_kind, cp_pos;
    endgroup

    covergroup cg_read_err_beat;
        cp_beat: coverpoint c_err_beat { bins first = {0}; bins middle = {1}; bins last = {2}; }
    endgroup

    covergroup cg_config;
        cp_cause: coverpoint c_cfg {
            bins unaligned_src = {0};
            bins unaligned_dst = {1};
            bins unaligned_len = {2};
            bins src_past_top  = {3};
            bins dst_past_top  = {4};
            bins zero_length   = {5};
            bins start_busy    = {6};
        }
    endgroup

    covergroup cg_irq;
        cp_outcome: coverpoint c_outcome { bins done = {0}; bins error = {1}; }
        cp_enabled: coverpoint c_irq_en  { bins masked = {0}; bins enabled = {1}; }
        x_irq: cross cp_outcome, cp_enabled;
    endgroup

    covergroup cg_irq_clear;   // software clears a status bit while irq is high
        cp_hit: coverpoint c_irq_en { bins clear_while_high = {1}; }
    endgroup

    covergroup cg_regs;
        cp_reg: coverpoint c_reg {
            bins version = {0}; bins int_status = {1}; bins int_enable = {2}; bins src = {3};
            bins dst = {4}; bins len = {5}; bins ctrl = {6}; bins status = {7};
        }
        cp_rw: coverpoint c_reg_wr { bins read = {0}; bins write = {1}; }
        x_reg_rw: cross cp_reg, cp_rw;
    endgroup

    function new(string name, uvm_component parent);
        super.new(name, parent);
        cg_xfer = new(); cg_burst = new(); cg_boundary = new();
        cg_read_timing = new(); cg_write_timing = new();
        cg_error = new(); cg_read_err_beat = new(); cg_config = new();
        cg_irq = new(); cg_irq_clear = new(); cg_regs = new();
    endfunction

    // ---- sample functions (called by the reference model and scoreboard)
    function void sample_xfer(dma_xfer x);
        if (x.cfg_err) begin
            for (int c = 0; c < 5; c++) if (x.cfg_causes[c]) begin c_cfg = c; cg_config.sample(); end
            return;
        end
        if (x.zero_len) begin c_cfg = 5; cg_config.sample(); end
        c_len = x.len;
        begin
            int words = x.len / 4, full = x.max_burst + 1;
            c_len_vs_burst = (words % full == 0) ? 0 : (words % full == 1) ? 1 : (words % full == full - 1) ? 2 : 3;
        end
        cg_xfer.sample();
        c_src_near = (x.src[11:2] >= 10'd1008);   // within 16 words of a 4 KB boundary
        c_dst_near = (x.dst[11:2] >= 10'd1008);
        cg_boundary.sample();
    endfunction

    function void sample_start_busy();
        c_cfg = 6; cg_config.sample();
    endfunction

    function void sample_burst(dma_burst_t b);
        c_beats = b.beats; c_cut = b.cut;
        cg_burst.sample();
    endfunction

    function void sample_axi(axi_item t);
        if (t.kind == AXI_READ) begin
            c_ar_wait = t.addr_wait; c_r_wait = t.data_wait;
            cg_read_timing.sample();
        end else begin
            c_aw_wait = t.addr_wait; c_w_wait = t.data_wait; c_b_wait = t.resp_wait; c_order = t.aw_vs_w;
            cg_write_timing.sample();
        end
    endfunction

    function void sample_error(bit is_write, int burst_idx, int n_planned, bit [1:0] resp, int beat, int n_beats);
        c_err_kind = is_write;
        c_err_pos  = (burst_idx == 0) ? 0 : (burst_idx == n_planned - 1) ? 2 : 1;
        c_err_resp = (resp == 2'b11);
        cg_error.sample();
        if (!is_write) begin
            c_err_beat = (beat == 0) ? 0 : (beat == n_beats - 1) ? 2 : 1;
            cg_read_err_beat.sample();
        end
    endfunction

    function void sample_irq(int outcome, bit enabled);
        c_outcome = (outcome != CODE_NONE); c_irq_en = enabled;
        cg_irq.sample();
    endfunction

    function void sample_irq_clear();
        c_irq_en = 1; cg_irq_clear.sample();
    endfunction

    function void sample_reg(bit [11:0] addr, bit write);
        c_reg = addr[4:2]; c_reg_wr = write;
        cg_regs.sample();
    endfunction

    function void report_phase(uvm_phase phase);
        string s;
        s = $sformatf("\n  %-18s %6.1f%%", "transfer",      cg_xfer.get_coverage());
        s = {s, $sformatf("\n  %-18s %6.1f%%", "burst",         cg_burst.get_coverage())};
        s = {s, $sformatf("\n  %-18s %6.1f%%", "4KB boundary",  cg_boundary.get_coverage())};
        s = {s, $sformatf("\n  %-18s %6.1f%%", "read timing",   cg_read_timing.get_coverage())};
        s = {s, $sformatf("\n  %-18s %6.1f%%", "write timing",  cg_write_timing.get_coverage())};
        s = {s, $sformatf("\n  %-18s %6.1f%%", "errors",        cg_error.get_coverage())};
        s = {s, $sformatf("\n  %-18s %6.1f%%", "read err beat", cg_read_err_beat.get_coverage())};
        s = {s, $sformatf("\n  %-18s %6.1f%%", "config",        cg_config.get_coverage())};
        s = {s, $sformatf("\n  %-18s %6.1f%%", "interrupts",    cg_irq.get_coverage())};
        s = {s, $sformatf("\n  %-18s %6.1f%%", "irq clear",     cg_irq_clear.get_coverage())};
        s = {s, $sformatf("\n  %-18s %6.1f%%", "registers",     cg_regs.get_coverage())};
        `uvm_info("COVERAGE", {"Functional coverage (this run):", s}, UVM_LOW)
    endfunction
endclass
