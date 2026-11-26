# DMA test plan

Every spec rule (spec/dma_spec.md) is mapped to the tests that exercise it, the check
that catches a failure, and the coverage item that proves it was hit. A corner case is
done only when coverage shows it was hit **and** a check would catch a failure.

## Checkers

| Checker | What it checks |
|---|---|
| `dma_ref_model` | Every APB read value and every PSLVERR, against registers predicted from the spec |
| `dma_scoreboard` | Every AR and AW against the predicted burst list, in order; write data; memory after each transfer; source untouched; fixed AXI fields; 4 KB rule; xLAST position |
| `dma_irq_monitor` | `irq == \|(INT_STATUS & INT_ENABLE)` on every settled cycle |
| `axi_monitor` | R only after AR; B only after AW and WLAST |
| `axi_slave_driver` | WLAST on beat AWLEN+1 |
| SVA (`tb/sva/dma_sva.sv`) | AXI VALID/payload stability, 4 KB, fixed fields, WLAST position, APB protocol and PSLVERR, INT_STATUS hardware-set wins |
| RTL assertions | FIFO never pushed when full or popped when empty; burst size 1..256 |

## Rules → tests → checks → coverage

| Rule | Tests | Check | Coverage |
|---|---|---|---|
| Register map | reg_reset_test, reg_bitbash_test | ref model register reads, RAL | cg_regs (each register × read/write) |
| Unmapped access | reg_reset_test | ref model, a_apb_slverr | c_slverr cover |
| 1 Start | single_xfer_test, all | scoreboard, ref model STATUS | cg_xfer |
| 2 Start while busy | start_while_busy_test | scoreboard (no extra traffic) | cg_config.start_busy |
| 3 Writes while busy | start_while_busy_test | scoreboard (bursts use old values) | — |
| 4 Config error | config_error_test, random_test | scoreboard (no traffic), ref model STATUS | cg_config causes |
| 5 Zero length | length_edge_test, irq_test | scoreboard, ref model | cg_config.zero_length, cg_xfer.zero |
| 6 Burst size / 4 KB | burst_size_test, boundary_4k_test, length_edge_test, random_test | scoreboard burst plan, a_aw_4k/a_ar_4k | cg_burst (beats, cut reason), cg_boundary |
| 7 One burst at a time | all | scoreboard ordering (read k after write k−1) | — |
| 8 Handshakes | backpressure_test, random_test | SVA stability; AW/W ordering modes in the slave | cg_read_timing, cg_write_timing (incl. AW/W order) |
| 9 Read error | read_error_test, random_test | scoreboard (no write after error), ref model ERR_CODE=2 | cg_error, cg_read_err_beat |
| 10 Write error | write_error_test, random_test | scoreboard, ref model ERR_CODE=3, memory check | cg_error |
| 11 Completion | all | ref model STATUS/INT_STATUS | cg_irq |
| 12 Interrupt | irq_test, all (random wait mode) | dma_irq_monitor, a_int_*_set | cg_irq, cg_irq_clear |
| 14 Reset | every test starts from reset | reg_reset_test | — |

## Corner cases

| Area | Corner cases | Covered by |
|---|---|---|
| Length | 0; 4; exactly one burst; ±1 word; very long (64 KB); not a multiple of 4 | length_edge_test, config_error_test, random_test |
| Burst size | MAX_BURST 0 and 255; every value 0..255; short last burst | burst_size_test |
| 4 KB rule | source on a boundary; 1 word before; both near with different offsets; several boundaries | boundary_4k_test, random_test |
| Addresses | unaligned source/destination; range ending exactly at 0xFFFF_FFFF; range past it; address 0 | config_error_test |
| Bus timing | no delays; long delays; AW before W, W before AW, same cycle; R gaps; late B | backpressure_test, random_test |
| Errors | read error on first/middle/last burst and first/middle/last beat; write error; SLVERR and DECERR | read_error_test, write_error_test |
| Control | START while busy; writes while busy; back-to-back transfers | start_while_busy_test |
| Interrupts | enabled vs masked; clear one bit; clear while high; enable after event; done and error | irq_test |

## Not covered (documented limits)

- Same-cycle hardware set and software clear of INT_STATUS is checked by the `a_int_*_set`
  assertions on every cycle, but no test is timed to make the two coincide.
- Reset during a transfer (spec rule 14 excludes it).
