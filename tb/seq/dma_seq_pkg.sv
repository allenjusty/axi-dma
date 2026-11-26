// DMA sequences. All register accesses go through the UVM register model (frontdoor, APB).
package dma_seq_pkg;
    import uvm_pkg::*;
    `include "uvm_macros.svh"
    import apb_pkg::*;
    import dma_regs_ral_pkg::*;

    // ------------------------------------------------------------------ base
    class dma_base_seq extends uvm_reg_sequence #(uvm_sequence #(apb_item));
        `uvm_object_utils(dma_base_seq)
        dma_regs           regs;
        virtual dma_irq_if irq_vif;

        function new(string name = "dma_base_seq");
            super.new(name);
        endfunction

        task pre_body();
            if (!$cast(regs, model)) `uvm_fatal("SEQ", "model is not a dma_regs block")
        endtask

        task wr(uvm_reg r, bit [31:0] v);
            uvm_status_e st;
            r.write(st, v, .parent(this));
            if (st != UVM_IS_OK) `uvm_error("SEQ", $sformatf("write to %s failed", r.get_name()))
        endtask

        task rd(uvm_reg r, output bit [31:0] v);
            uvm_status_e   st;
            uvm_reg_data_t d;
            r.read(st, d, .parent(this));
            if (st != UVM_IS_OK) `uvm_error("SEQ", $sformatf("read of %s failed", r.get_name()))
            v = d[31:0];
        endtask

        // Start a child sequence that shares this sequence's model and irq handle
        task run_child(dma_base_seq s);
            s.model   = model;
            s.irq_vif = irq_vif;
            s.start(m_sequencer, this);
        endtask
    endclass

    // ------------------------------------------------------------------ program the transfer
    class dma_cfg_seq extends dma_base_seq;
        `uvm_object_utils(dma_cfg_seq)
        bit [31:0] src, dst, len;
        bit [1:0]  int_enable;

        function new(string name = "dma_cfg_seq");
            super.new(name);
        endfunction

        task body();
            wr(regs.SRC, src);
            wr(regs.DST, dst);
            wr(regs.LEN, len);
            wr(regs.INT_ENABLE, {30'd0, int_enable});
        endtask
    endclass

    // ------------------------------------------------------------------ START, then wait
    // MAX_BURST goes in the same CTRL write as START (spec rule 1).
    class dma_start_seq extends dma_base_seq;
        `uvm_object_utils(dma_start_seq)
        bit [7:0]  max_burst = 8'h0F;
        bit        wait_irq;          // 1: wait for irq, 0: poll STATUS
        bit        no_wait;           // just write START
        int        timeout_cycles = 500_000;
        bit [31:0] status;

        function new(string name = "dma_start_seq");
            super.new(name);
        endfunction

        task body();
            int n = 0;
            wr(regs.CTRL, {16'd0, max_burst, 8'h01});
            if (no_wait) return;
            if (wait_irq) begin
                while (irq_vif.irq !== 1'b1 && n < timeout_cycles) begin @(posedge irq_vif.clk); n++; end
                if (n >= timeout_cycles) `uvm_error("SEQ", "timeout waiting for irq")
            end
            n = 0;
            do begin
                rd(regs.STATUS, status);
                n++;
            end while (status[0] && n < timeout_cycles / 4);
            if (status[0]) `uvm_error("SEQ", "timeout waiting for STATUS.BUSY = 0")
        endtask
    endclass

    // ------------------------------------------------------------------ clear interrupt status
    class dma_irq_clear_seq extends dma_base_seq;
        `uvm_object_utils(dma_irq_clear_seq)
        bit [31:0] int_status;

        function new(string name = "dma_irq_clear_seq");
            super.new(name);
        endfunction

        task body();
            rd(regs.INT_STATUS, int_status);
            if (int_status[1:0] != 0) wr(regs.INT_STATUS, int_status);
        endtask
    endclass

    // ------------------------------------------------------------------ one complete transfer
    // Fields may be set directly (directed tests) or randomized (random test).
    class dma_xfer_seq extends dma_base_seq;
        `uvm_object_utils(dma_xfer_seq)
        rand bit [31:0] src, dst, len;
        rand bit [7:0]  max_burst;
        rand bit        wait_irq;
        rand bit [1:0]  int_enable;    // used when polling (irq mode enables both)
        bit [31:0]      status;

        constraint c_align   { src[1:0] == 0; dst[1:0] == 0; len[1:0] == 0; }
        constraint c_len     { len dist { 0 := 1, 4 := 3, [8:256] :/ 30, [260:4096] :/ 50, [4100:16384] :/ 16 }; }
        constraint c_inside  { {1'b0, src} + {1'b0, len} <= 33'h1_0000_0000;
                               {1'b0, dst} + {1'b0, len} <= 33'h1_0000_0000; }
        constraint c_overlap { ({1'b0, src} + {1'b0, len} <= {1'b0, dst}) || ({1'b0, dst} + {1'b0, len} <= {1'b0, src}); }
        constraint c_near_4k { src[11:0] dist { [0:4095] :/ 70, [4032:4092] :/ 30 };
                               dst[11:0] dist { [0:4095] :/ 70, [4032:4092] :/ 30 }; }
        constraint c_burst   { max_burst dist { 0 := 5, [1:14] :/ 20, 15 := 10, [16:254] :/ 50, 255 := 15 }; }

        function new(string name = "dma_xfer_seq");
            super.new(name);
        endfunction

        task body();
            dma_cfg_seq       c = dma_cfg_seq::type_id::create("cfg");
            dma_start_seq     s = dma_start_seq::type_id::create("start");
            dma_irq_clear_seq k = dma_irq_clear_seq::type_id::create("clear");
            c.src = src; c.dst = dst; c.len = len;
            c.int_enable = wait_irq ? 2'b11 : int_enable;
            run_child(c);
            s.max_burst = max_burst; s.wait_irq = wait_irq;
            run_child(s);
            status = s.status;
            run_child(k);
            `uvm_info("SEQ", $sformatf("transfer src=0x%08h dst=0x%08h len=%0d max_burst=%0d -> STATUS=0x%02h",
                                       src, dst, len, max_burst, status), UVM_MEDIUM)
        endtask
    endclass

endpackage
