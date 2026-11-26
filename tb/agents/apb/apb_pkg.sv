// APB4 master agent: item, driver, monitor, agent, and the register-model adapter.
package apb_pkg;
    import uvm_pkg::*;
    `include "uvm_macros.svh"

    // ------------------------------------------------------------------ item
    class apb_item extends uvm_sequence_item;
        `uvm_object_utils(apb_item)
        rand bit        write;
        rand bit [11:0] addr;
        rand bit [31:0] data;     // write data, or read data once the transfer is done
        bit             slverr;

        function new(string name = "apb_item");
            super.new(name);
        endfunction

        virtual function string convert2string();
            return $sformatf("%s addr=0x%03h data=0x%08h%s", write ? "WR" : "RD", addr, data, slverr ? " PSLVERR" : "");
        endfunction
    endclass

    typedef uvm_sequencer #(apb_item) apb_sequencer;

    // ------------------------------------------------------------------ driver
    // Setup phase for one cycle, then access phase until PREADY. One idle cycle between transfers.
    class apb_driver extends uvm_driver #(apb_item);
        `uvm_component_utils(apb_driver)
        virtual apb_if vif;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            if (!uvm_config_db#(virtual apb_if)::get(this, "", "apb_vif", vif))
                `uvm_fatal("NOVIF", "apb_vif not set")
        endfunction

        task run_phase(uvm_phase phase);
            vif.psel = 0; vif.penable = 0; vif.pwrite = 0; vif.pprot = 0;
            vif.paddr = 0; vif.pwdata = 0; vif.pstrb = 0;
            forever begin
                seq_item_port.get_next_item(req);
                @(negedge vif.clk);                       // setup phase
                vif.psel    = 1;
                vif.penable = 0;
                vif.pwrite  = req.write;
                vif.paddr   = req.addr;
                vif.pwdata  = req.write ? req.data : 32'h0;
                vif.pstrb   = req.write ? 4'hF : 4'h0;    // APB4: PSTRB is 0 for reads
                @(negedge vif.clk);                       // access phase
                vif.penable = 1;
                while (!vif.pready) @(negedge vif.clk);
                if (!req.write) req.data = vif.prdata;
                req.slverr = vif.pslverr;
                @(negedge vif.clk);                       // transfer completed on the rising edge
                vif.psel    = 0;
                vif.penable = 0;
                seq_item_port.item_done();
            end
        endtask
    endclass

    // ------------------------------------------------------------------ monitor
    class apb_monitor extends uvm_monitor;
        `uvm_component_utils(apb_monitor)
        virtual apb_if vif;
        uvm_analysis_port #(apb_item) ap;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            ap = new("ap", this);
        endfunction

        function void build_phase(uvm_phase phase);
            if (!uvm_config_db#(virtual apb_if)::get(this, "", "apb_vif", vif))
                `uvm_fatal("NOVIF", "apb_vif not set")
        endfunction

        task run_phase(uvm_phase phase);
            forever begin
                @(negedge vif.clk);
                #1;   // after the drivers have updated their outputs for this cycle
                if (vif.rst_n && vif.psel && vif.penable && vif.pready) begin
                    apb_item t = apb_item::type_id::create("t");
                    t.write  = vif.pwrite;
                    t.addr   = vif.paddr;
                    t.data   = vif.pwrite ? vif.pwdata : vif.prdata;
                    t.slverr = vif.pslverr;
                    `uvm_info("APB_MON", t.convert2string(), UVM_HIGH)
                    ap.write(t);
                end
            end
        endtask
    endclass

    // ------------------------------------------------------------------ agent
    class apb_agent extends uvm_agent;
        `uvm_component_utils(apb_agent)
        apb_sequencer sqr;
        apb_driver    drv;
        apb_monitor   mon;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            sqr = apb_sequencer::type_id::create("sqr", this);
            drv = apb_driver::type_id::create("drv", this);
            mon = apb_monitor::type_id::create("mon", this);
        endfunction

        function void connect_phase(uvm_phase phase);
            drv.seq_item_port.connect(sqr.seq_item_export);
        endfunction
    endclass

    // ------------------------------------------------------------------ register adapter
    class apb_reg_adapter extends uvm_reg_adapter;
        `uvm_object_utils(apb_reg_adapter)

        function new(string name = "apb_reg_adapter");
            super.new(name);
            supports_byte_enable = 0;
            provides_responses   = 0;   // the driver writes read data back into the request
        endfunction

        virtual function uvm_sequence_item reg2bus(const ref uvm_reg_bus_op rw);
            apb_item t = apb_item::type_id::create("t");
            t.write = (rw.kind == UVM_WRITE);
            t.addr  = rw.addr[11:0];
            t.data  = rw.data[31:0];
            return t;
        endfunction

        virtual function void bus2reg(uvm_sequence_item bus_item, ref uvm_reg_bus_op rw);
            apb_item t;
            if (!$cast(t, bus_item)) `uvm_fatal("ADAPTER", "not an apb_item")
            rw.kind   = t.write ? UVM_WRITE : UVM_READ;
            rw.addr   = t.addr;
            rw.data   = t.data;
            rw.status = t.slverr ? UVM_NOT_OK : UVM_IS_OK;
        endfunction
    endclass

    // ------------------------------------------------------------------ raw access (unmapped addresses)
    class apb_raw_seq extends uvm_sequence #(apb_item);
        `uvm_object_utils(apb_raw_seq)
        bit        write;
        bit [11:0] addr;
        bit [31:0] data;
        bit        slverr;

        function new(string name = "apb_raw_seq");
            super.new(name);
        endfunction

        task body();
            apb_item t = apb_item::type_id::create("t");
            start_item(t);
            t.write = write; t.addr = addr; t.data = data;
            finish_item(t);
            data   = t.data;
            slverr = t.slverr;
        endtask
    endclass

endpackage
