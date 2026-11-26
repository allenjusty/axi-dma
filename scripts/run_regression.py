#!/usr/bin/env python3
"""Run the DMA UVM regression in parallel.

Usage:
    scripts/run_regression.py                 # full list, seeds from tests below
    scripts/run_regression.py --quick         # one seed per test (CI on push)
    scripts/run_regression.py --seeds 20      # override seeds for every test
    scripts/run_regression.py --test random_test --seeds 50

Needs the testbench built first (make tb). Writes build/regression/summary.txt and a
merged coverage report in build/regression/coverage/.
"""
import argparse
import os
import random
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SIM = ROOT / "build" / "uvm" / "sim"
OUT = ROOT / "build" / "regression"

# test name -> number of seeds in a full regression
TESTS = {
    "reg_reset_test": 1,
    "reg_bitbash_test": 1,
    "single_xfer_test": 2,
    "burst_size_test": 2,
    "boundary_4k_test": 5,
    "length_edge_test": 3,
    "config_error_test": 2,
    "start_while_busy_test": 5,
    "backpressure_test": 5,
    "read_error_test": 3,
    "write_error_test": 3,
    "irq_test": 3,
    "random_test": 20,
}


def run_one(test, seed, extra):
    d = OUT / "runs" / f"{test}_{seed}"
    d.mkdir(parents=True, exist_ok=True)
    cmd = [str(SIM), f"+UVM_TESTNAME={test}", f"+verilator+seed+{seed}", "+UVM_VERBOSITY=UVM_LOW"] + extra
    with open(d / "sim.log", "w") as log:
        rc = subprocess.run(cmd, cwd=d, stdout=log, stderr=subprocess.STDOUT).returncode
    text = (d / "sim.log").read_text(errors="replace")
    passed = rc == 0 and "TEST PASSED" in text
    first_err = ""
    if not passed:
        for line in text.splitlines():
            if "UVM_ERROR" in line and "@" in line or "UVM_FATAL" in line and "@" in line or "Assertion failed" in line:
                first_err = line.strip()[:160]
                break
        if not first_err:
            first_err = f"exit code {rc}, no PASS line"
    rerun = f"cd {d} && {' '.join(cmd)}"
    return test, seed, passed, first_err, rerun, d / "coverage.dat"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--quick", action="store_true", help="one seed per test")
    ap.add_argument("--seeds", type=int, help="seeds per test (overrides the table)")
    ap.add_argument("--test", help="run only this test")
    ap.add_argument("-j", type=int, default=os.cpu_count(), help="parallel jobs")
    ap.add_argument("--fixed-seeds", action="store_true", help="use seeds 1..N instead of random seeds")
    args, extra = ap.parse_known_args()

    if not SIM.exists():
        sys.exit("build/uvm/sim not found: run 'make tb' first")

    tests = {args.test: TESTS.get(args.test, 1)} if args.test else dict(TESTS)
    jobs = []
    for t, n in tests.items():
        n = 1 if args.quick else (args.seeds or n)
        seeds = range(1, n + 1) if (args.fixed_seeds or args.quick) else random.sample(range(1, 1_000_000), n)
        jobs += [(t, s) for s in seeds]

    print(f"Running {len(jobs)} simulations with {args.j} jobs...")
    with ThreadPoolExecutor(max_workers=args.j) as ex:
        results = list(ex.map(lambda j: run_one(j[0], j[1], extra), jobs))

    OUT.mkdir(parents=True, exist_ok=True)
    lines = [f"{'test':24} {'seed':>8}  result"]
    fails = [r for r in results if not r[2]]
    for t, s, ok, err, rerun, _ in sorted(results):
        lines.append(f"{t:24} {s:>8}  {'PASS' if ok else 'FAIL  ' + err}")
    lines.append("")
    lines.append(f"{len(results) - len(fails)}/{len(results)} passed")
    if fails:
        lines.append("\nRerun failures with:")
        lines += [f"  {r[4]}" for r in fails]
    summary = "\n".join(lines)
    (OUT / "summary.txt").write_text(summary + "\n")
    print(summary)

    # Merge coverage (functional covergroups + cover properties)
    dats = [str(r[5]) for r in results if r[5].exists()]
    if dats:
        merged = OUT / "coverage.dat"
        subprocess.run(["verilator_coverage", "--write", str(merged)] + dats, check=False)
        subprocess.run(["verilator_coverage", "--annotate", str(OUT / "coverage"), str(merged)],
                       check=False, stdout=subprocess.DEVNULL)
        rep = subprocess.run([sys.executable, str(ROOT / "scripts" / "cov_report.py"), str(merged)],
                             capture_output=True, text=True)
        print(rep.stdout)
        (OUT / "coverage_summary.txt").write_text(rep.stdout)

    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
