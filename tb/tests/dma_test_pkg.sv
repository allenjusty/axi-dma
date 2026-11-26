// DMA tests (test plan: docs/testplan.md). Select one with +UVM_TESTNAME=<name>.
package dma_test_pkg;
    import uvm_pkg::*;
    `include "uvm_macros.svh"
    import apb_pkg::*;
    import axi_pkg::*;
    import dma_regs_ral_pkg::*;
    import dma_env_pkg::*;
    import dma_seq_pkg::*;

    // ------------------------------------------------------------------ base test
    class dma_base_test extends uvm_test;
        `uvm_component_utils(dma_base_test)
        dma_env            env;
        dma_env_cfg        cfg;
        virtual dma_irq_if irq_vif;
        int                timeout_us = 20_000;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            cfg = dma_env_cfg::type_id::create("cfg");
            uvm_config_db#(dma_env_cfg)::set(this, "env", "cfg", cfg);
            env = dma_env::type_id::create("env", this);
            if (!uvm_config_db#(virtual dma_irq_if)::get(this, "", "irq_vif", irq_vif)) `uvm_fatal("NOVIF", "irq_vif not set")
            void'($value$plusargs("TIMEOUT_US=%d", timeout_us));
        endfunction

        task run_phase(uvm_phase phase);
            phase.raise_objection(this);
            @(posedge irq_vif.rst_n);
            repeat (2) @(posedge irq_vif.clk);
            fork
                body();
                begin
                    #(timeout_us * 1us);
                    `uvm_fatal("WATCHDOG", $sformatf("test did not finish within %0d us", timeout_us))
                end
            join_any
            #200ns;   // drain
            phase.drop_objection(this);
        endtask

        virtual task body();
        endtask

        // One complete, checked transfer. wait_mode: 0 poll, 1 irq, -1 random.
        task xfer(bit [31:0] src, bit [31:0] dst, bit [31:0] len, bit [7:0] max_burst = 8'h0F, int wait_mode = -1);
            dma_xfer_seq x = dma_xfer_seq::type_id::create("x");
            x.model = env.regmodel; x.irq_vif = irq_vif;
            x.src = src; x.dst = dst; x.len = len; x.max_burst = max_burst;
            x.wait_irq   = (wait_mode < 0) ? $urandom_range(0, 1) : wait_mode[0];
            x.int_enable = $urandom_range(0, 3);
            x.start(env.apb.sqr);
        endtask

        // Raw APB access (for unmapped addresses)
        task apb_raw(bit write, bit [11:0] addr, bit [31:0] data = 0);
            apb_raw_seq s = apb_raw_seq::type_id::create("raw");
            s.write = write; s.addr = addr; s.data = data;
            s.start(env.apb.sqr);
        endtask

        // Single register write / read through the register model
        task reg_wr(uvm_reg r, bit [31:0] v);
            uvm_status_e st;
            r.write(st, v);
        endtask

        task reg_rd(uvm_reg r, output bit [31:0] v);
            uvm_status_e   st;
            uvm_reg_data_t d;
            r.read(st, d);
            v = d[31:0];
        endtask

        task wait_idle();
            bit [31:0] st;
            do reg_rd(env.regmodel.STATUS, st); while (st[0]);
        endtask

        function void report_phase(uvm_phase phase);
            uvm_report_server rs = uvm_report_server::get_server();
            int n_err = rs.get_severity_count(UVM_ERROR) + rs.get_severity_count(UVM_FATAL);
            `uvm_info("RESULT", $sformatf("%s %s", get_type_name(), n_err == 0 ? "TEST PASSED" : "TEST FAILED"), UVM_NONE)
        endfunction
    endclass

    // ------------------------------------------------------------------ registers
    class reg_reset_test extends dma_base_test;
        `uvm_component_utils(reg_reset_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        task body();
            uvm_reg_hw_reset_seq s = uvm_reg_hw_reset_seq::type_id::create("s");
            s.model = env.regmodel;
            s.start(null);
            apb_raw(0, 12'h020);          // unmapped read  -> PSLVERR (checked by the reference model)
            apb_raw(1, 12'hFFC, 32'h1);   // unmapped write -> PSLVERR
            apb_raw(1, 12'h01C, 32'h3F);  // write to read-only STATUS: ignored, no error
            apb_raw(1, 12'h000, 32'h0);   // write to read-only VERSION: ignored, no error
            apb_raw(0, 12'h01C);          // still 0
            apb_raw(0, 12'h000);          // still 0x0001_0000
        endtask
    endclass

    class reg_bitbash_test extends dma_base_test;
        `uvm_component_utils(reg_bitbash_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        task body();
            uvm_reg_bit_bash_seq s = uvm_reg_bit_bash_seq::type_id::create("s");
            // CTRL starts transfers; STATUS and INT_STATUS are changed by hardware
            uvm_resource_db#(bit)::set({"REG::", env.regmodel.CTRL.get_full_name()},       "NO_REG_BIT_BASH_TEST", 1, this);
            uvm_resource_db#(bit)::set({"REG::", env.regmodel.STATUS.get_full_name()},     "NO_REG_BIT_BASH_TEST", 1, this);
            uvm_resource_db#(bit)::set({"REG::", env.regmodel.INT_STATUS.get_full_name()}, "NO_REG_BIT_BASH_TEST", 1, this);
            s.model = env.regmodel;
            s.start(null);
        endtask
    endclass

    // ------------------------------------------------------------------ transfers
    class single_xfer_test extends dma_base_test;
        `uvm_component_utils(single_xfer_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        task body();
            xfer(32'h0000_1000, 32'h0000_8000, 64, 15, 0);
            xfer(32'h0000_0FE0, 32'h0000_2000, 80, 15, 1);      // worked example from the spec
        endtask
    endclass

    class burst_size_test extends dma_base_test;
        `uvm_component_utils(burst_size_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        task body();
            for (int mb = 0; mb <= 255; mb++) begin
                int words = 2 * (mb + 1) + $urandom_range(1, mb + 1);   // two full bursts + a short last one
                if (words > 1024) words = 1024;                          // stay inside one 4 KB page
                xfer(32'h0010_0000, 32'h0020_0000, words * 4, mb[7:0], 0);
            end
        endtask
    endclass

    class boundary_4k_test extends dma_base_test;
        `uvm_component_utils(boundary_4k_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        task body();
            xfer(32'h0001_0000, 32'h0002_0000, 256, 255);             // source exactly on a boundary
            xfer(32'h0001_0FFC, 32'h0002_0000, 64, 255);              // source 1 word before a boundary
            xfer(32'h0001_0000, 32'h0002_0FFC, 64, 255);              // destination 1 word before
            xfer(32'h0001_0FF0, 32'h0002_0FE0, 256, 255);             // both near, different offsets
            xfer(32'h0001_0FE0, 32'h0002_0FF0, 256, 255);
            xfer(32'h0001_0800, 32'h0003_0C00, 3 * 4096 + 512, 255);  // crosses several boundaries
            for (int i = 0; i < 10; i++)
                xfer(32'h0004_0000 + 4 * $urandom_range(1000, 1023), 32'h0008_0000 + 4 * $urandom_range(1000, 1023),
                     4 * $urandom_range(1, 600), $urandom_range(0, 255));
        endtask
    endclass

    class length_edge_test extends dma_base_test;
        `uvm_component_utils(length_edge_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        task body();
            int mbs[4] = '{0, 3, 15, 255};
            xfer(32'h0000_1000, 32'h0000_9000, 0, 15);                // zero length
            xfer(32'h0000_1000, 32'h0000_9000, 4, 15);                // one word
            foreach (mbs[i]) begin
                int full = (mbs[i] + 1) * 4;
                xfer(32'h0001_0000, 32'h0005_0000, full,     mbs[i]); // exactly one full burst
                xfer(32'h0001_0000, 32'h0005_0000, full + 4, mbs[i]); // one word more
                if (full > 4) xfer(32'h0001_0000, 32'h0005_0000, full - 4, mbs[i]);   // one word less
                xfer(32'h0001_0000, 32'h0005_0000, 3 * full, mbs[i]); // exact multiple
            end
            xfer(32'h0010_0000, 32'h0020_0000, 65536, 255);           // very long transfer
        endtask
    endclass

    class config_error_test extends dma_base_test;
        `uvm_component_utils(config_error_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        task body();
            xfer(32'h0000_1002, 32'h0000_9000, 64, 15);   // unaligned source
            xfer(32'h0000_1000, 32'h0000_9001, 64, 15);   // unaligned destination
            xfer(32'h0000_1000, 32'h0000_9000, 66, 15);   // length not a multiple of 4
            xfer(32'h0000_1003, 32'h0000_9000, 0, 15);    // unaligned with zero length
            xfer(32'hFFFF_FFC0, 32'h0000_9000, 68, 15);   // source range past 0xFFFF_FFFF
            xfer(32'h0000_1000, 32'hFFFF_FF00, 512, 15);  // destination range past the top
            xfer(32'hFFFF_FFC0, 32'h0000_9000, 64, 15);   // ends exactly at 0xFFFF_FFFF: allowed
            xfer(32'h0000_9000, 32'hFFFF_FFF0, 16, 15);   // destination ends exactly at the top: allowed
            xfer(32'h0000_0000, 32'h0000_9000, 32, 15);   // address 0
        endtask
    endclass

    class start_while_busy_test extends dma_base_test;
        `uvm_component_utils(start_while_busy_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        task body();
            dma_cfg_seq   c = dma_cfg_seq::type_id::create("c");
            dma_start_seq s = dma_start_seq::type_id::create("s");
            cfg.axi_cfg.randomize_delays(2);                          // slow memory: the transfer runs long
            c.model = env.regmodel; c.irq_vif = irq_vif;
            c.src = 32'h0003_0000; c.dst = 32'h0007_0000; c.len = 4096; c.int_enable = 0;
            c.start(env.apb.sqr);
            s.model = env.regmodel; s.irq_vif = irq_vif; s.max_burst = 7; s.no_wait = 1;
            s.start(env.apb.sqr);
            // Rule 3: register writes while busy; rule 2: START while busy is ignored
            reg_wr(env.regmodel.SRC, 32'h0009_0000);
            reg_wr(env.regmodel.DST, 32'h000A_0000);
            reg_wr(env.regmodel.LEN, 64);
            reg_wr(env.regmodel.CTRL, 32'h0000_0001);                // START with MAX_BURST = 0
            reg_wr(env.regmodel.CTRL, 32'h0000_FF01);
            wait_idle();
            // START right after DONE, back to back
            cfg.axi_cfg.set_no_delays();
            xfer(32'h0009_0000, 32'h000A_0000, 64, 0, 0);
            xfer(32'h000A_1000, 32'h000B_0000, 128, 3, 0);
        endtask
    endclass

    class backpressure_test extends dma_base_test;
        `uvm_component_utils(backpressure_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        task body();
            for (int i = 0; i < 12; i++) begin
                cfg.axi_cfg.randomize_delays(2);
                cfg.axi_cfg.order_mode = i % 4;                       // 0 free, 1 AW waits W, 2 W waits AW, 3 random
                xfer(32'h0001_0000 + 32'h1000 * i + 4 * $urandom_range(0, 1023),
                     32'h0100_0000 + 32'h1000 * i + 4 * $urandom_range(0, 1023),
                     4 * $urandom_range(1, 300), $urandom_range(0, 255));
            end
            cfg.axi_cfg.set_no_delays();
        endtask
    endclass

    class read_error_test extends dma_base_test;
        `uvm_component_utils(read_error_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        // Error on one source word; 8-beat bursts, 64 words -> 8 bursts
        task err_at(int word, bit [1:0] resp);
            cfg.axi_cfg.clear_errors();
            cfg.axi_cfg.add_error(1, 32'h0003_0000 + 4 * word, 32'h0003_0000 + 4 * word, resp);
            xfer(32'h0003_0000, 32'h0006_0000, 256, 7);
            cfg.axi_cfg.clear_errors();
        endtask
        task body();
            err_at(0,  RESP_SLVERR);    // first burst, first beat
            err_at(7,  RESP_DECERR);    // first burst, last beat
            err_at(27, RESP_SLVERR);    // middle burst, middle beat
            err_at(32, RESP_DECERR);    // middle burst, first beat
            err_at(63, RESP_SLVERR);    // last burst, last beat
            err_at(60, RESP_DECERR);    // last burst, middle beat
            cfg.axi_cfg.randomize_delays(1);
            err_at(41, RESP_SLVERR);    // with delays
            cfg.axi_cfg.set_no_delays();
            xfer(32'h0003_0000, 32'h0006_0000, 256, 7);   // a clean transfer still works afterwards
        endtask
    endclass

    class write_error_test extends dma_base_test;
        `uvm_component_utils(write_error_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        task err_at(int word, bit [1:0] resp);
            cfg.axi_cfg.clear_errors();
            cfg.axi_cfg.add_error(0, 32'h0006_0000 + 4 * word, 32'h0006_0000 + 4 * word, resp);
            xfer(32'h0003_0000, 32'h0006_0000, 256, 7);
            cfg.axi_cfg.clear_errors();
        endtask
        task body();
            err_at(3,  RESP_SLVERR);    // first burst
            err_at(30, RESP_DECERR);    // middle burst
            err_at(63, RESP_SLVERR);    // last burst
            cfg.axi_cfg.randomize_delays(1);
            err_at(17, RESP_DECERR);
            cfg.axi_cfg.set_no_delays();
            xfer(32'h0003_0000, 32'h0006_0000, 256, 7);
        endtask
    endclass

    class irq_test extends dma_base_test;
        `uvm_component_utils(irq_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        task run(bit [31:0] len, bit [1:0] en);
            dma_cfg_seq   c = dma_cfg_seq::type_id::create("c");
            dma_start_seq s = dma_start_seq::type_id::create("s");
            c.model = env.regmodel; c.irq_vif = irq_vif;
            c.src = 32'h0000_1000; c.dst = 32'h0000_8000; c.len = len; c.int_enable = en;
            c.start(env.apb.sqr);
            s.model = env.regmodel; s.irq_vif = irq_vif; s.wait_irq = 0;
            s.start(env.apb.sqr);
            repeat (5) @(posedge irq_vif.clk);    // irq is checked every settled cycle by dma_irq_monitor
        endtask
        task body();
            bit [31:0] v;
            reg_wr(env.regmodel.INT_STATUS, 3);
            run(64, 2'b00);                                        // DONE, masked
            run(64, 2'b01);                                        // DONE, enabled (DONE bit still set: irq stays)
            reg_wr(env.regmodel.INT_STATUS, 32'h2);                // clear only ERR (not set): irq stays high
            reg_wr(env.regmodel.INT_STATUS, 32'h1);                // clear DONE while irq is high
            run(66, 2'b00);                                        // config error, masked
            reg_wr(env.regmodel.INT_ENABLE, 32'h2);                // enable after the event: irq rises
            reg_rd(env.regmodel.INT_STATUS, v);
            reg_wr(env.regmodel.INT_STATUS, 32'h2);
            cfg.axi_cfg.add_error(1, 32'h0000_1010, 32'h0000_1010);
            run(64, 2'b10);                                        // read error, enabled
            cfg.axi_cfg.clear_errors();
            run(64, 2'b11);                                        // DONE with both enabled; ERR bit still set
            reg_wr(env.regmodel.INT_STATUS, 32'h3);
            run(0, 2'b01);                                         // zero length -> DONE
            reg_wr(env.regmodel.INT_ENABLE, 32'h0);                // mask while pending: irq falls
            reg_wr(env.regmodel.INT_STATUS, 32'h3);
            xfer(32'h0000_2000, 32'h0000_9000, 32, 15, 1);         // wait-for-irq completion
        endtask
    endclass

    class random_test extends dma_base_test;
        `uvm_component_utils(random_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        task body();
            int n = 25;
            void'($value$plusargs("NUM_XFERS=%d", n));
            for (int i = 0; i < n; i++) begin
                dma_xfer_seq x = dma_xfer_seq::type_id::create($sformatf("x%0d", i));
                if (!x.randomize()) `uvm_fatal("RAND", "dma_xfer_seq randomize failed")
                cfg.axi_cfg.randomize_delays($urandom_range(0, 2));
                cfg.axi_cfg.clear_errors();
                if (x.len >= 8) begin                         // sometimes put one bad word inside the transfer
                    int        pick = $urandom_range(0, 9);
                    bit [31:0] off  = 4 * $urandom_range(0, x.len / 4 - 1);
                    bit [1:0]  resp = $urandom_range(0, 1) ? RESP_SLVERR : RESP_DECERR;
                    if (pick == 0) cfg.axi_cfg.add_error(1, x.src + off, x.src + off, resp);
                    if (pick == 1) cfg.axi_cfg.add_error(0, x.dst + off, x.dst + off, resp);
                end
                x.model = env.regmodel; x.irq_vif = irq_vif;
                x.start(env.apb.sqr);
            end
            cfg.axi_cfg.clear_errors();
        endtask
    endclass

endpackage
