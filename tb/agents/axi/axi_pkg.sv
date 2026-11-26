// AXI4 slave agent: a reactive memory responder plus a monitor.
//   axi_item          one complete read or write transaction
//   axi_slave_cfg     READY probabilities, beat gaps, B latency, AW/W ordering, error ranges
//   axi_mem_model     sparse byte memory, shared with the scoreboard
//   axi_slave_driver  responds to the DUT (one process for reads, one for writes)
//   axi_monitor       rebuilds complete transactions from the five channels
package axi_pkg;
    import uvm_pkg::*;
    `include "uvm_macros.svh"

    typedef enum {AXI_READ, AXI_WRITE} axi_kind_e;
    localparam bit [1:0] RESP_OKAY = 2'b00, RESP_SLVERR = 2'b10, RESP_DECERR = 2'b11;

    // ------------------------------------------------------------------ item
    class axi_item extends uvm_sequence_item;
        `uvm_object_utils(axi_item)
        axi_kind_e  kind;
        bit         id;
        bit [31:0]  addr;
        bit [7:0]   len;
        bit [2:0]   size;
        bit [1:0]   burst;
        bit [31:0]  data[$];
        bit [3:0]   strb[$];        // writes only
        bit [1:0]   resp[$];        // read: one per beat; write: resp[0] = BRESP
        int         last_beat;      // index of the beat that carried xLAST
        // Timing, for coverage
        int         addr_wait;      // cycles AxVALID waited for AxREADY
        int         data_wait;      // write: cycles WVALID waited for WREADY; read: cycles with no R beat offered
        int         resp_wait;      // write: cycles from WLAST (and AW) to BVALID
        int         aw_vs_w;        // write: -1 AW accepted first, 0 same cycle, +1 first W beat accepted first
        int         start_cycle;    // cycle of the address handshake (for ordering checks)

        function new(string name = "axi_item");
            super.new(name);
        endfunction

        function bit has_error();
            foreach (resp[i]) if (resp[i][1]) return 1;
            return 0;
        endfunction

        virtual function string convert2string();
            return $sformatf("%s addr=0x%08h len=%0d (%0d beats) size=%0d burst=%0d id=%0d resp=%s",
                             kind == AXI_READ ? "READ " : "WRITE", addr, len, data.size(), size, burst, id,
                             has_error() ? "ERROR" : "OKAY");
        endfunction
    endclass

    // ------------------------------------------------------------------ slave configuration
    typedef struct {
        bit        is_read;     // 1: R beats in range get the error; 0: B for a burst touching the range
        bit [31:0] lo, hi;      // inclusive byte range
        bit [1:0]  resp;        // SLVERR or DECERR
    } axi_err_range_t;

    class axi_slave_cfg extends uvm_object;
        `uvm_object_utils(axi_slave_cfg)
        int ar_ready_pct = 100;     // chance (%) that xREADY is high in a cycle
        int aw_ready_pct = 100;
        int w_ready_pct  = 100;
        int r_gap_pct    = 0;       // chance (%) of not offering the next R beat in a cycle
        int b_delay_max  = 0;       // B is sent 0..b_delay_max cycles after AW and WLAST
        int order_mode   = 0;       // 0: no ordering, 1: AW waits for W, 2: W waits for AW, 3: random per burst
        axi_err_range_t err_ranges[$];

        function new(string name = "axi_slave_cfg");
            super.new(name);
        endfunction

        function void set_no_delays();
            ar_ready_pct = 100; aw_ready_pct = 100; w_ready_pct = 100;
            r_gap_pct = 0; b_delay_max = 0; order_mode = 0;
        endfunction

        // level 0: none, 1: light, 2: heavy
        function void randomize_delays(int level);
            if (level == 0) begin set_no_delays(); return; end
            ar_ready_pct = (level == 1) ? $urandom_range(50, 100) : $urandom_range(10, 50);
            aw_ready_pct = (level == 1) ? $urandom_range(50, 100) : $urandom_range(10, 50);
            w_ready_pct  = (level == 1) ? $urandom_range(50, 100) : $urandom_range(10, 50);
            r_gap_pct    = (level == 1) ? $urandom_range(0, 30)   : $urandom_range(30, 80);
            b_delay_max  = (level == 1) ? $urandom_range(0, 3)    : $urandom_range(4, 20);
            order_mode   = 3;
        endfunction

        function void add_error(bit is_read, bit [31:0] lo, bit [31:0] hi, bit [1:0] resp = RESP_SLVERR);
            axi_err_range_t r;
            r.is_read = is_read; r.lo = lo; r.hi = hi; r.resp = resp;
            err_ranges.push_back(r);
        endfunction

        function void clear_errors();
            err_ranges.delete();
        endfunction

        // Response for one read beat at byte address a
        function bit [1:0] rd_resp(bit [31:0] a);
            foreach (err_ranges[i])
                if (err_ranges[i].is_read && a >= err_ranges[i].lo && a <= err_ranges[i].hi) return err_ranges[i].resp;
            return RESP_OKAY;
        endfunction

        // Response for a write burst of n words starting at byte address a
        function bit [1:0] wr_resp(bit [31:0] a, int n);
            for (int k = 0; k < n; k++)
                foreach (err_ranges[i])
                    if (!err_ranges[i].is_read && (a + 4 * k) >= err_ranges[i].lo && (a + 4 * k) <= err_ranges[i].hi)
                        return err_ranges[i].resp;
            return RESP_OKAY;
        endfunction
    endclass

    // ------------------------------------------------------------------ memory model
    // Sparse byte memory. A byte never written reads as a seeded hash of its word address,
    // so any source range has unique, known data without preloading.
    class axi_mem_model extends uvm_object;
        `uvm_object_utils(axi_mem_model)
        bit [7:0]  mem [bit [31:0]];
        bit [31:0] seed;

        function new(string name = "axi_mem_model");
            super.new(name);
            seed = $urandom;
        endfunction

        function bit [31:0] default_word(bit [31:0] word_addr);
            bit [31:0] x = word_addr ^ seed;
            x ^= x << 13; x ^= x >> 17; x ^= x << 5;
            return x * 32'h9E37_79B1;
        endfunction

        function bit [7:0] read_byte(bit [31:0] a);
            bit [31:0] w;
            if (mem.exists(a)) return mem[a];
            w = default_word({a[31:2], 2'b00});
            return w[8 * a[1:0] +: 8];
        endfunction

        function bit [31:0] read_word(bit [31:0] a);
            bit [31:0] wa = {a[31:2], 2'b00};
            return {read_byte(wa + 3), read_byte(wa + 2), read_byte(wa + 1), read_byte(wa)};
        endfunction

        function void write_word(bit [31:0] a, bit [31:0] data, bit [3:0] strb);
            bit [31:0] wa = {a[31:2], 2'b00};
            for (int b = 0; b < 4; b++) if (strb[b]) mem[wa + b] = data[8 * b +: 8];
        endfunction

        function void clear();
            mem.delete();
        endfunction
    endclass

    // ------------------------------------------------------------------ slave driver
    // Each cycle (falling edge): first apply the handshakes that happened on the last rising
    // edge, then choose this cycle's outputs, then note which handshakes will happen on the
    // next rising edge (VALID && READY are both final at this point).
    class axi_slave_driver extends uvm_component;
        `uvm_component_utils(axi_slave_driver)
        virtual axi_if vif;
        axi_slave_cfg  cfg;
        axi_mem_model  mem;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            if (!uvm_config_db#(virtual axi_if)::get(this, "", "axi_vif", vif)) `uvm_fatal("NOVIF", "axi_vif not set")
            if (!uvm_config_db#(axi_slave_cfg)::get(this, "", "axi_cfg", cfg)) `uvm_fatal("NOCFG", "axi_cfg not set")
            if (!uvm_config_db#(axi_mem_model)::get(this, "", "axi_mem", mem)) `uvm_fatal("NOMEM", "axi_mem not set")
        endfunction

        function bit rnd(int pct);
            return ($urandom_range(99) < pct);
        endfunction

        task run_phase(uvm_phase phase);
            fork
                read_side();
                write_side();
            join
        endtask

        // AR, then exactly ARLEN+1 R beats with RLAST on the last one
        task read_side();
            bit        ar_hs, r_hs, have;
            bit [31:0] addr, cap_addr;
            bit [7:0]  len, cap_len;
            int        beat;
            vif.arready = 0; vif.rvalid = 0; vif.rlast = 0; vif.rdata = 0; vif.rresp = 0; vif.rid = 0;
            forever begin
                @(negedge vif.clk);
                if (!vif.rst_n) begin
                    vif.arready = 0; vif.rvalid = 0; vif.rlast = 0;
                    have = 0; ar_hs = 0; r_hs = 0;
                    continue;
                end
                // 1. handshakes from the last rising edge
                if (ar_hs) begin addr = cap_addr; len = cap_len; beat = 0; have = 1; end
                if (r_hs) begin
                    vif.rvalid = 0; vif.rlast = 0;
                    if (beat == len) have = 0;
                    else beat++;
                end
                // 2. outputs for this cycle (RVALID, once high, holds until RREADY)
                vif.arready = !have && rnd(cfg.ar_ready_pct);
                if (have && !vif.rvalid && !rnd(cfg.r_gap_pct)) begin
                    bit [31:0] a = addr + 4 * beat;
                    vif.rvalid = 1;
                    vif.rdata  = mem.read_word(a);
                    vif.rresp  = cfg.rd_resp(a);
                    vif.rlast  = (beat == len);
                end
                // 3. handshakes on the next rising edge
                ar_hs = vif.arvalid && vif.arready;
                if (ar_hs) begin cap_addr = vif.araddr; cap_len = vif.arlen; end
                r_hs = vif.rvalid && vif.rready;
            end
        endtask

        // AW and W accepted independently (in the configured order); B only after AW and WLAST
        task write_side();
            bit        aw_hs, w_hs, b_hs, aw_have, w_done, cap_wlast;
            bit [31:0] waddr, cap_awaddr, cap_wdata;
            bit [7:0]  wlen, cap_awlen;
            bit [3:0]  cap_wstrb;
            bit [31:0] wdata_q[$];
            bit [3:0]  wstrb_q[$];
            int        order, b_wait;
            vif.awready = 0; vif.wready = 0; vif.bvalid = 0; vif.bresp = 0; vif.bid = 0;
            order  = pick_order();
            b_wait = $urandom_range(0, cfg.b_delay_max);
            forever begin
                @(negedge vif.clk);
                if (!vif.rst_n) begin
                    vif.awready = 0; vif.wready = 0; vif.bvalid = 0;
                    aw_hs = 0; w_hs = 0; b_hs = 0; aw_have = 0; w_done = 0;
                    wdata_q.delete(); wstrb_q.delete();
                    continue;
                end
                // 1. handshakes from the last rising edge
                if (aw_hs) begin waddr = cap_awaddr; wlen = cap_awlen; aw_have = 1; end
                if (w_hs) begin
                    wdata_q.push_back(cap_wdata);
                    wstrb_q.push_back(cap_wstrb);
                    if (cap_wlast) w_done = 1;
                end
                if (b_hs) begin
                    vif.bvalid = 0;
                    aw_have = 0; w_done = 0;
                    wdata_q.delete(); wstrb_q.delete();
                    order  = pick_order();
                    b_wait = $urandom_range(0, cfg.b_delay_max);
                end
                // 2. outputs for this cycle
                vif.awready = !aw_have && rnd(cfg.aw_ready_pct) && (order != 1 || wdata_q.size() > 0 || w_done);
                vif.wready  = !w_done  && rnd(cfg.w_ready_pct)  && (order != 2 || aw_have);
                if (aw_have && w_done && !vif.bvalid) begin
                    if (b_wait > 0) b_wait--;
                    else begin
                        bit [1:0] resp = cfg.wr_resp(waddr, wdata_q.size());
                        if (wdata_q.size() != wlen + 1)
                            `uvm_error("AXI_SLV", $sformatf("write at 0x%08h: WLAST on beat %0d, AWLEN+1 = %0d",
                                                             waddr, wdata_q.size(), wlen + 1))
                        if (resp == RESP_OKAY)
                            foreach (wdata_q[i]) mem.write_word(waddr + 4 * i, wdata_q[i], wstrb_q[i]);
                        vif.bvalid = 1;
                        vif.bresp  = resp;
                    end
                end
                // 3. handshakes on the next rising edge
                aw_hs = vif.awvalid && vif.awready;
                if (aw_hs) begin cap_awaddr = vif.awaddr; cap_awlen = vif.awlen; end
                w_hs = vif.wvalid && vif.wready;
                if (w_hs) begin cap_wdata = vif.wdata; cap_wstrb = vif.wstrb; cap_wlast = vif.wlast; end
                b_hs = vif.bvalid && vif.bready;
            end
        endtask

        function int pick_order();
            return (cfg.order_mode == 3) ? $urandom_range(0, 2) : cfg.order_mode;
        endfunction
    endclass

    // ------------------------------------------------------------------ monitor
    class axi_monitor extends uvm_monitor;
        `uvm_component_utils(axi_monitor)
        virtual axi_if vif;
        uvm_analysis_port #(axi_item) ap;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            ap = new("ap", this);
        endfunction

        function void build_phase(uvm_phase phase);
            if (!uvm_config_db#(virtual axi_if)::get(this, "", "axi_vif", vif)) `uvm_fatal("NOVIF", "axi_vif not set")
        endfunction

        task run_phase(uvm_phase phase);
            axi_item rd_q[$], aw_q[$], w_q[$];
            axi_item w_cur;
            int cyc, ar_wait, aw_wait, w_wait, b_wait;
            forever begin
                @(negedge vif.clk);
                #1;   // after the drivers have updated their outputs for this cycle
                cyc++;
                if (!vif.rst_n) begin
                    rd_q.delete(); aw_q.delete(); w_q.delete(); w_cur = null;
                    ar_wait = 0; aw_wait = 0; w_wait = 0; b_wait = 0;
                    continue;
                end

                // ---- R (before AR, so a beat always belongs to an older AR)
                if (vif.rvalid && vif.rready) begin
                    if (rd_q.size() == 0) `uvm_error("AXI_MON", "R beat with no outstanding AR")
                    else begin
                        axi_item t = rd_q[0];
                        t.data.push_back(vif.rdata);
                        t.resp.push_back(vif.rresp);
                        if (vif.rlast) begin
                            t.last_beat = t.data.size() - 1;
                            void'(rd_q.pop_front());
                            ap.write(t);
                        end
                    end
                end else if (rd_q.size() > 0 && !vif.rvalid) rd_q[0].data_wait++;

                // ---- AR
                if (vif.arvalid && vif.arready) begin
                    axi_item t = axi_item::type_id::create("rd");
                    t.kind = AXI_READ; t.id = vif.arid; t.addr = vif.araddr; t.len = vif.arlen;
                    t.size = vif.arsize; t.burst = vif.arburst; t.addr_wait = ar_wait; t.start_cycle = cyc;
                    rd_q.push_back(t);
                    ar_wait = 0;
                end else if (vif.arvalid) ar_wait++;

                // ---- B (before AW/W: a B must answer an AW and WLAST accepted in an earlier
                //      cycle, and the cycle WLAST is accepted does not count as waiting for B)
                if (vif.bvalid && vif.bready) begin
                    if (aw_q.size() == 0 || w_q.size() == 0)
                        `uvm_error("AXI_MON", "B response before both AW and WLAST were accepted")
                    else begin
                        axi_item t = aw_q.pop_front();
                        axi_item w = w_q.pop_front();
                        t.data = w.data; t.strb = w.strb; t.last_beat = w.last_beat; t.data_wait = w.data_wait;
                        t.resp.push_back(vif.bresp);
                        t.resp_wait = b_wait;
                        t.aw_vs_w   = (t.start_cycle < w.start_cycle) ? -1 : (t.start_cycle == w.start_cycle) ? 0 : 1;
                        ap.write(t);
                    end
                    b_wait = 0;
                end else if (aw_q.size() > 0 && w_q.size() > 0) b_wait++;

                // ---- AW
                if (vif.awvalid && vif.awready) begin
                    axi_item t = axi_item::type_id::create("wr");
                    t.kind = AXI_WRITE; t.id = vif.awid; t.addr = vif.awaddr; t.len = vif.awlen;
                    t.size = vif.awsize; t.burst = vif.awburst; t.addr_wait = aw_wait; t.start_cycle = cyc;
                    aw_q.push_back(t);
                    aw_wait = 0;
                end else if (vif.awvalid) aw_wait++;

                // ---- W
                if (vif.wvalid && vif.wready) begin
                    if (w_cur == null) begin
                        w_cur = axi_item::type_id::create("w");
                        w_cur.start_cycle = cyc;
                    end
                    w_cur.data.push_back(vif.wdata);
                    w_cur.strb.push_back(vif.wstrb);
                    if (vif.wlast) begin
                        w_cur.last_beat = w_cur.data.size() - 1;
                        w_cur.data_wait = w_wait;
                        w_q.push_back(w_cur);
                        w_cur = null;
                        w_wait = 0;
                    end
                end else if (vif.wvalid) w_wait++;
            end
        endtask
    endclass

    // ------------------------------------------------------------------ agent
    class axi_slave_agent extends uvm_agent;
        `uvm_component_utils(axi_slave_agent)
        axi_slave_driver drv;
        axi_monitor      mon;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            drv = axi_slave_driver::type_id::create("drv", this);
            mon = axi_monitor::type_id::create("mon", this);
        endfunction
    endclass

endpackage
