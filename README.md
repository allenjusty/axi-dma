# AXI4 DMA controller with a UVM testbench

A single-channel memory-to-memory DMA (APB4 registers, AXI4 master) designed and
verified with free tools only: Verilator, UVM 1800.2-2017, PeakRDL, Z3.

| | |
|---|---|
| Design | 1 channel, APB4 slave registers, AXI4 master, bursts of up to 256 beats, 4 KB rule, read/write error handling, level interrupt |
| Testbench | SystemVerilog UVM on Verilator: APB master agent, reactive AXI4 slave agent with a memory model, register model (RAL), spec-based reference model, scoreboard, SVA, functional coverage |
| Regression | 13 tests, 55 seeded runs, **55/55 pass** |
| Functional coverage | **100 %** (102/102 bins, 11 covergroups) |

## Block diagram

```
            APB4                                                  irq
             │                                                     ▲
       ┌─────▼─────┐    ┌─────────┐    ┌────────────────┐   ┌──────┴───────┐
       │ dma_regs  │───►│ dma_ctx │───►│ dma_burst_calc │   │dma_status_irq│
       │(PeakRDL)  │    └────┬────┘    └───────┬────────┘   └──────▲───────┘
       └─────▲─────┘         │                 │                   │
             │         ┌─────▼─────────────────▼───────────────────┴──┐
             └─────────│ dma_ctrl  IDLE→RD_REQ→RD_WAIT→WR_REQ→WR_WAIT→UPDATE │
                       └─────┬──────────────────────────────┬─────────┘
                    ┌────────▼──────┐   ┌──────────┐   ┌────▼──────────┐
                    │ dma_rd_engine │──►│ dma_fifo │──►│ dma_wr_engine │
                    └────────▲──────┘   │ 256 x 32 │   └────▲──────────┘
                             │          └──────────┘        │
                          AXI4 AR, R                     AXI4 AW, W, B
```

One burst at a time: read N beats into the FIFO, write them, wait for B, advance.
N = min(words remaining, MAX_BURST+1, words to the next 4 KB boundary on the source side,
same on the destination side).

## Testbench

```
 ┌───────────── dma_env ──────────────────────────────────────────────────┐
 │  APB agent ──► uvm_reg_predictor ─► register model (PeakRDL-uvm)       │
 │      │                                                                  │
 │      └──────► dma_ref_model ──(predicted bursts)──► dma_scoreboard ◄──┐ │
 │                (from the spec)                                         │ │
 │                    │                                                   │ │
 │                    └──► dma_irq_monitor              AXI slave agent ──┘ │
 │                                                     (memory responder) │
 └────────────────────────────────────────────────────────────────────────┘
```

- **Reference model** written from [spec/dma_spec.md](spec/dma_spec.md), never from the RTL.
  On every START it predicts the exact burst list (including where an error stops the
  transfer), STATUS and INT_STATUS, and checks every APB read and PSLVERR.
- **Scoreboard** compares every AR and AW with the prediction in order, checks write
  data beat by beat, checks memory and an untouched source after each transfer.
- **AXI slave** randomizes READY on every channel, gaps between R beats, B latency, and
  the AW/W order (AW first, W first, or either); error responses come from address ranges.
- **Assertions** (bound with `bind`): AXI VALID/payload stability, 4 KB rule, fixed fields,
  WLAST position, APB protocol and PSLVERR, "hardware set wins" on INT_STATUS.
- Drivers and monitors drive and sample on the **falling** clock edge, so every DUT
  output is stable when read: no races on Verilator, no clocking blocks needed.

Test plan with rule → test → check → coverage mapping: [docs/testplan.md](docs/testplan.md).

## Results

```
covergroup           bins hit  coverage
cg_boundary           8 / 8       100.0%
cg_burst              9 / 9       100.0%
cg_config             7 / 7       100.0%
cg_error             13 / 13      100.0%
cg_irq                8 / 8       100.0%
cg_irq_clear          1 / 1       100.0%
cg_read_err_beat      3 / 3       100.0%
cg_read_timing        6 / 6       100.0%
cg_regs              26 / 26      100.0%
cg_write_timing      12 / 12      100.0%
cg_xfer               9 / 9       100.0%
TOTAL               102 / 102     100.0%
```

**Does the testbench catch real bugs?** [scripts/mutation_test.sh](scripts/mutation_test.sh)
builds copies of the RTL with one deliberate bug each and runs the matching tests.
All four are caught:

| Injected bug | Caught by | First error |
|---|---|---|
| Burst size ignores the destination 4 KB limit | boundary_4k_test, random_test | scoreboard: burst read 16 beats, expected 1 |
| ERR_CODE always reports 1 | read_error_test, write_error_test | reference model: STATUS read 0x14, expected 0x24 / 0x34 |
| WVALID waits for AW to be accepted (breaks AXI rule) | backpressure_test | deadlock with the "AW waits for W" slave → timeout |
| Range check ignores the source address | config_error_test | irq monitor: irq=0, expected 1 (ERR not set) |

## Bug log

Every bug found, how it was caught, the root cause and whether it was a design,
testbench or model bug: [docs/bug_log.md](docs/bug_log.md).

## Running it

Tools: Verilator 5.054 (built with Z3), Python 3, PeakRDL (`pip install peakrdl peakrdl-regblock peakrdl-uvm`),
UVM 1800.2-2017-1.0 (the single-file copy in Verilator's `test_regress/t/uvm`).

```sh
make lint                         # Verilator -Wall lint of the RTL
make smoke                        # quick directed test, no UVM (seconds)
make tb                           # build the UVM testbench once (~10 min)
make test TEST=random_test SEED=7 # run one test
make test TEST=irq_test ARGS=+DUMP  # with waves (waves.vcd)
python3 scripts/run_regression.py # full regression + merged coverage
python3 scripts/cov_report.py build/regression/coverage.dat --holes
make regs ral                     # regenerate register RTL and model from SystemRDL
```

## Layout

```
spec/     dma_spec.md (the spec), dma_regs.rdl (registers, SystemRDL)
rtl/      hand-written RTL, rtl/gen/ generated register block
tb/       agents/ (APB, AXI), env/ (ref model, scoreboard, irq monitor, RAL),
          seq/, tests/, sva/, coverage/, smoke/ (non-UVM bring-up test), tb_top.sv
scripts/  run_regression.py, cov_report.py
docs/     testplan.md, bug_log.md
```
