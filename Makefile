# DMA project - common commands
PEAKRDL ?= $(HOME)/tools/pyenv/bin/peakrdl
VFLAGS  := --binary --timing --assert -j 0 -Wno-fatal -Wno-WIDTH rtl/lint.vlt -f rtl/dma.f
SEED    ?= 1

.PHONY: regs ral lint smoke tb test clean
regs:   ## regenerate the APB register block from SystemRDL
	$(PEAKRDL) regblock spec/dma_regs.rdl -o rtl/gen --cpuif apb4-flat --addr-width 12 \
	    --default-reset rst_n --err-if-bad-addr --hwif-report

ral:    ## regenerate the UVM register model from SystemRDL
	$(PEAKRDL) uvm spec/dma_regs.rdl -o tb/env/gen/dma_regs_ral_pkg.sv
	# UVM 2017 cannot map 4-byte registers with UVM_NO_ENDIAN (every register lands at 0)
	sed -i 's/UVM_NO_ENDIAN/UVM_LITTLE_ENDIAN/' tb/env/gen/dma_regs_ral_pkg.sv

lint:   ## Verilator lint, all warnings
	verilator --lint-only -Wall --assert rtl/lint.vlt -f rtl/dma.f --top-module dma_top

smoke:  ## build and run the directed smoke test (SEED=n)
	verilator $(VFLAGS) -Mdir build/smoke tb/smoke/dma_smoke_tb.sv --top-module dma_smoke_tb -o sim > build/smoke.log 2>&1 \
	    || (tail -20 build/smoke.log; exit 1)
	./build/smoke/sim +verilator+seed+$(SEED)

# ---------------- UVM testbench (build once, pick the test at run time)
UVM_HOME ?= $(HOME)/tools/uvm-2017-1.0
TEST     ?= single_xfer_test
# The UVM build is memory-hungry (~1 GB per compiler process); keep jobs modest on small machines.
BUILD_JOBS ?= 4
export OBJCACHE ?= ccache
VERB     ?= UVM_LOW
UVM_FLAGS := --binary --timing --vpi --assert --coverage-user --trace-vcd --timescale-override 1ns/1ps \
             -j $(BUILD_JOBS) -Wno-fatal -Wno-lint -Wno-style -Werror-COVERIGN \
             +incdir+$(UVM_HOME) +incdir+$(UVM_HOME)/dpi \
             $(UVM_HOME)/uvm_pkg_all_v2017_1_0_dpi.svh $(UVM_HOME)/dpi/uvm_dpi.cc \
             rtl/lint.vlt -f rtl/dma.f -f tb/tb.f --top-module tb_top -Mdir build/uvm -o sim

tb:     ## build the UVM testbench (takes a few minutes)
	@mkdir -p build
	verilator $(UVM_FLAGS) > build/uvm_build.log 2>&1 || (grep -E "%Error" build/uvm_build.log | head -30; exit 1)
	@echo "built build/uvm/sim"

test:   ## run one test: make test TEST=random_test SEED=3
	@mkdir -p build/runs/$(TEST)_$(SEED)
	cd build/runs/$(TEST)_$(SEED) && ../../uvm/sim +UVM_TESTNAME=$(TEST) +verilator+seed+$(SEED) \
	    +UVM_VERBOSITY=$(VERB) $(ARGS) | tee sim.log

clean:
	rm -rf build
