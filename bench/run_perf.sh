#!/bin/bash
#
# run_perf.sh — Run the FAST perf comparison benchmark under perf stat.
#
# Compares sorted-array binary search, BFS-layout binary tree, and FAST
# tree across a range of tree sizes, collecting hardware performance
# counters that reveal the architectural effects of FAST's hierarchical
# blocking:
#
#   dTLB-load-misses        → page blocking (d_P) effectiveness
#   LLC-load-misses         → cache line blocking (d_L) effectiveness
#   L1-dcache-load-misses   → overall cache behavior
#   instructions, cycles    → IPC / SIMD blocking (d_K) effectiveness
#   branch-misses           → branch prediction (SIMD reduces branches)
#
# Usage:
#   ./bench/run_perf.sh [build_dir]
#
# Prerequisites:
#   - perf installed (linux-tools-common / perf on most distros)
#   - Sufficient permissions for perf counters:
#       sudo sysctl -w kernel.perf_event_paranoid=-1
#     or run as root
#   - The project must be built: cmake --build build
#
# Output: tab-separated tables suitable for further processing.

set -euo pipefail

BUILD_DIR="${1:-build}"
BENCH="$BUILD_DIR/fast_bench_perf"

if [ ! -x "$BENCH" ]; then
    echo "Error: $BENCH not found. Build the project first:" >&2
    echo "  cmake -B $BUILD_DIR && cmake --build $BUILD_DIR" >&2
    exit 1
fi

# Check perf availability
if ! command -v perf &>/dev/null; then
    echo "Error: 'perf' not found. Install linux-tools or perf." >&2
    exit 1
fi

# Test if perf counters are accessible
if ! perf stat -e cycles true 2>/dev/null; then
    echo "Warning: perf counters not accessible." >&2
    echo "Try: sudo sysctl -w kernel.perf_event_paranoid=-1" >&2
    echo "Falling back to wall-clock-only mode." >&2
    PERF_AVAILABLE=0
else
    PERF_AVAILABLE=1
fi

# Hardware counter groups.
# We split into groups to avoid multiplexing on hardware with limited PMU
# counters (typically 4-8 programmable counters).
EVENTS_CACHE="L1-dcache-loads,L1-dcache-load-misses,LLC-loads,LLC-load-misses"
EVENTS_TLB="dTLB-loads,dTLB-load-misses"
EVENTS_COMPUTE="cycles,instructions,branches,branch-misses"

# Tree sizes chosen to cross architectural boundaries:
#   8K keys   =  32 KB  (fits in L1 data cache, ~32-48KB on most CPUs)
#   64K keys  = 256 KB  (exceeds L1, fits in L2)
#   512K keys =   2 MB  (exceeds L2, fits in L3 on most CPUs)
#   4M keys   =  16 MB  (exceeds L3 on many CPUs)
#   16M keys  =  64 MB  (well beyond LLC, memory-bandwidth-bound)
SIZES="8192 65536 524288 4194304 16777216"
NUM_QUERIES=5000000

METHODS="array bfs fast"

echo "========================================================================"
echo "  FAST Perf Comparison Benchmark"
echo "========================================================================"
echo ""
echo "Timestamp: $(date -Iseconds)"
echo "Kernel:    $(uname -r)"
echo "CPU:       $(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs || echo 'unknown')"
echo "L1d:       $(getconf LEVEL1_DCACHE_SIZE 2>/dev/null || echo 'unknown') bytes"
echo "L2:        $(getconf LEVEL2_CACHE_SIZE 2>/dev/null || echo 'unknown') bytes"
echo "L3:        $(getconf LEVEL3_CACHE_SIZE 2>/dev/null || echo 'unknown') bytes"
echo "Page size: $(getconf PAGESIZE 2>/dev/null || echo 'unknown') bytes"
echo ""

run_one() {
    local method="$1" size="$2" nq="$3" label="$4"

    if [ "$PERF_AVAILABLE" -eq 1 ]; then
        echo "--- $label: perf counters (cache) ---"
        perf stat -e "$EVENTS_CACHE" -- "$BENCH" "$method" "$size" "$nq" 2>&1 | \
            grep -E '(L1-dcache|LLC-|Mq/s|ns/query)'
        echo ""

        echo "--- $label: perf counters (TLB) ---"
        perf stat -e "$EVENTS_TLB" -- "$BENCH" "$method" "$size" "$nq" 2>&1 | \
            grep -E '(dTLB|Mq/s|ns/query)'
        echo ""

        echo "--- $label: perf counters (compute) ---"
        perf stat -e "$EVENTS_COMPUTE" -- "$BENCH" "$method" "$size" "$nq" 2>&1 | \
            grep -E '(cycles|instructions|branch|insn per cycle|Mq/s|ns/query)'
        echo ""
    else
        "$BENCH" "$method" "$size" "$nq"
    fi
}

for SIZE in $SIZES; do
    KB=$((SIZE * 4 / 1024))
    echo "========================================================================"
    echo "  Tree size: $SIZE keys (${KB} KB)"
    echo "========================================================================"
    echo ""

    for METHOD in $METHODS; do
        LABEL="$METHOD / N=$SIZE"
        run_one "$METHOD" "$SIZE" "$NUM_QUERIES" "$LABEL"
    done
done

echo "========================================================================"
echo "  Done."
echo "========================================================================"
