#!/usr/bin/env bash
# Mutation check: does the testbench catch real bugs?
# Each mutant is a copy of the RTL with one deliberate bug. A mutant is "killed" when the
# named tests fail. Results: build/mutants/results.txt
#
# Usage: scripts/mutation_test.sh [mutant]   (all mutants one after another, or just one)
set -u
cd "$(dirname "$0")/.."
ROOT=$PWD
OUT=$ROOT/build/mutants
mkdir -p "$OUT"
: > "$OUT/results.txt"

# name # file # sed expression # tests   (fields separated by #)
MUTANTS=(
  "no_dst_4k#dma_burst_calc.sv#s/if (dst_room  < n) n = dst_room;//#boundary_4k_test random_test"
  "wrong_errcode#dma_status_irq.sv#s/st_err_code <= ev_err_code;/st_err_code <= 2'd1;/#read_error_test write_error_test"
  "w_waits_aw#dma_wr_engine.sv#s/assign wvalid  = (state == XFER) \&\& (w_cnt != n_q);/assign wvalid  = (state == XFER) \&\& !aw_pending \&\& (w_cnt != n_q);/#backpressure_test"
  "range_dst_only#dma_ctx.sv#s/(src_last\[32\] || dst_last\[32\])/dst_last[32]/#config_error_test"
)

run_mutant() {
  IFS='#' read -r name file expr tests <<< "$1"
  D="$OUT/$name"
  mkdir -p "$D"
  cp -r Makefile rtl tb spec "$D/"
  sed -i "$expr" "$D/rtl/$file"
  if diff -q "rtl/$file" "$D/rtl/$file" > /dev/null; then
    echo "$name: mutation did not apply" >> "$OUT/results.txt"; return
  fi
  if ! (cd "$D" && make tb > build.log 2>&1); then
    echo "$name: build failed" >> "$OUT/results.txt"; return
  fi
  for t in $tests; do
    mkdir -p "$D/run_$t"
    (cd "$D/run_$t" && timeout 900 ../build/uvm/sim +UVM_TESTNAME=$t +verilator+seed+1 > sim.log 2>&1)
    res=$(grep -ho 'TEST PASSED\|TEST FAILED' "$D/run_$t/sim.log" | head -1)
    [ -z "$res" ] && res="TEST FAILED (no result line)"
    first=$(grep -m1 -hE 'UVM_(ERROR|FATAL) [^:]|Assertion failed' "$D/run_$t/sim.log" | cut -c1-220)
    verdict=$([ "$res" = "TEST PASSED" ] && echo "SURVIVED" || echo "KILLED")
    printf "%-15s %-20s %-9s %s\n" "$name" "$t" "$verdict" "$first" >> "$OUT/results.txt"
  done
}

ONLY=${1:-}
for m in "${MUTANTS[@]}"; do
  [ -n "$ONLY" ] && [ "${m%%#*}" != "$ONLY" ] && continue
  run_mutant "$m"          # one at a time: each UVM build needs several GB of memory
done
wait
echo "DONE" >> "$OUT/results.txt"
cat "$OUT/results.txt"
