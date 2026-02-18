#!/usr/bin/env python3
"""
Generate a PDF report comparing FAST tree, BFS tree, and sorted-array
binary search across multiple tree sizes, with hardware performance
counter data from perf stat.

Usage:
    python3 bench/report.py [build_dir] [output.pdf]

    build_dir:   path to CMake build directory (default: build)
    output.pdf:  output PDF file (default: fast_report.pdf)

Prerequisites:
    - The project must be built (fast_bench_perf in build_dir)
    - Python 3 with matplotlib and numpy
    - perf (optional; if unavailable, only wall-clock data is collected)
    - For full perf counters: kernel.perf_event_paranoid <= 1
"""

import subprocess
import sys
import os
import re
import platform
import datetime
from collections import defaultdict
from pathlib import Path

import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.backends.backend_pdf import PdfPages
from matplotlib.gridspec import GridSpec


# ── Configuration ──────────────────────────────────────────────────

METHODS = ["array", "bfs", "fast"]
METHOD_LABELS = {
    "array": "Sorted Array",
    "bfs":   "BFS Tree",
    "fast":  "FAST Tree",
}
METHOD_COLORS = {
    "array": "#7f8c8d",
    "bfs":   "#e74c3c",
    "fast":  "#2980b9",
}

SIZES = [8192, 65536, 524288, 4194304, 16777216]
NUM_QUERIES = 5_000_000

PERF_EVENTS = [
    "cycles", "instructions",
    "L1-dcache-loads", "L1-dcache-load-misses",
    "LLC-loads", "LLC-load-misses",
    "dTLB-loads", "dTLB-load-misses",
    "branches", "branch-misses",
]


# ── System info ────────────────────────────────────────────────────

def get_system_info():
    info = {}
    info["hostname"] = platform.node()
    info["kernel"] = platform.release()
    info["arch"] = platform.machine()
    info["date"] = datetime.datetime.now().isoformat(timespec="seconds")

    try:
        with open("/proc/cpuinfo") as f:
            for line in f:
                if line.startswith("model name"):
                    info["cpu"] = line.split(":", 1)[1].strip()
                    break
    except OSError:
        info["cpu"] = "unknown"

    for name, var in [("L1d", "LEVEL1_DCACHE_SIZE"),
                      ("L2", "LEVEL2_CACHE_SIZE"),
                      ("L3", "LEVEL3_CACHE_SIZE")]:
        try:
            val = subprocess.check_output(
                ["getconf", var], stderr=subprocess.DEVNULL, text=True
            ).strip()
            info[name] = int(val)
        except (subprocess.CalledProcessError, ValueError):
            info[name] = None

    try:
        info["page_size"] = os.sysconf("SC_PAGESIZE")
    except (ValueError, OSError):
        info["page_size"] = 4096

    return info


# ── Run benchmarks ─────────────────────────────────────────────────

def check_perf():
    """Return True if perf stat works."""
    try:
        subprocess.run(
            ["perf", "stat", "-e", "cycles", "true"],
            capture_output=True, timeout=5,
        )
        return True
    except (subprocess.CalledProcessError, FileNotFoundError,
            subprocess.TimeoutExpired):
        return False


def parse_perf_output(stderr_text):
    """Extract counter values from perf stat stderr output."""
    counters = {}
    for line in stderr_text.splitlines():
        line = line.strip()
        # Match lines like:  1,234,567  cpu_core/cycles/u  or  1.234.567  cycles
        # Handle both locale formats (comma/period as thousands separator)
        m = re.match(
            r"([\d.,]+)\s+(?:cpu_core/)?(\S+?)(?:/u)?\s", line
        )
        if m:
            raw_val = m.group(1).replace(".", "").replace(",", "")
            name = m.group(2)
            try:
                counters[name] = int(raw_val)
            except ValueError:
                pass
    return counters


def parse_throughput(stdout_text):
    """Extract Mq/s and ns/query from bench output."""
    for line in stdout_text.splitlines():
        m = re.search(r"([\d.]+)\s+Mq/s\s+([\d.]+)\s+ns/query", line)
        if m:
            return float(m.group(1)), float(m.group(2))
    return None, None


def run_benchmark(bench_path, method, size, num_queries, use_perf):
    """Run one benchmark invocation, return (throughput_mqs, ns_per_q, counters)."""
    cmd = [bench_path, method, str(size), str(num_queries)]

    if use_perf:
        perf_cmd = [
            "perf", "stat", "-e", ",".join(PERF_EVENTS), "--"
        ] + cmd
        proc = subprocess.run(
            perf_cmd, capture_output=True, text=True, timeout=300
        )
        counters = parse_perf_output(proc.stderr)
        mqs, nsq = parse_throughput(proc.stdout)
    else:
        proc = subprocess.run(
            cmd, capture_output=True, text=True, timeout=300
        )
        counters = {}
        mqs, nsq = parse_throughput(proc.stdout)

    return mqs, nsq, counters


def collect_all(bench_path, use_perf):
    """Run all benchmarks, return structured results."""
    results = {}  # results[(method, size)] = {mqs, nsq, counters}
    total = len(METHODS) * len(SIZES)
    done = 0

    for size in SIZES:
        for method in METHODS:
            done += 1
            label = f"{method} N={size}"
            print(f"  [{done}/{total}] {label}...", end="", flush=True)
            mqs, nsq, counters = run_benchmark(
                bench_path, method, size, NUM_QUERIES, use_perf
            )
            results[(method, size)] = {
                "mqs": mqs, "nsq": nsq, "counters": counters,
            }
            if mqs:
                print(f" {mqs:.2f} Mq/s")
            else:
                print(" (no data)")

    return results


# ── PDF report generation ──────────────────────────────────────────

def fmt_size(n):
    """Format key count as human-readable."""
    if n >= 1_000_000:
        return f"{n // 1_000_000}M"
    elif n >= 1_000:
        return f"{n // 1_000}K"
    return str(n)


def fmt_bytes(n):
    """Format byte count."""
    if n is None:
        return "?"
    if n >= 1_048_576:
        return f"{n // 1_048_576} MB"
    elif n >= 1024:
        return f"{n // 1024} KB"
    return f"{n} B"


def safe_get(results, method, size, counter):
    """Safely get a counter value, returning None if missing."""
    entry = results.get((method, size))
    if entry is None:
        return None
    return entry["counters"].get(counter)


def safe_ratio(num, den):
    """Compute num/den as percentage, return None if either is missing/zero."""
    if num is None or den is None or den == 0:
        return None
    return 100.0 * num / den


def generate_pdf(results, sys_info, use_perf, output_path):
    """Generate the full PDF report."""
    size_labels = [fmt_size(s) for s in SIZES]
    size_kb = [s * 4 / 1024 for s in SIZES]

    with PdfPages(output_path) as pdf:
        # ── Page 1: Title + System Info + Throughput ──────────
        fig = plt.figure(figsize=(11, 8.5))
        gs = GridSpec(2, 1, height_ratios=[1, 2.5], hspace=0.3)

        # Title block
        ax_title = fig.add_subplot(gs[0])
        ax_title.axis("off")
        title_text = "FAST Tree Performance Report"
        ax_title.text(0.5, 0.85, title_text, transform=ax_title.transAxes,
                      ha="center", va="top", fontsize=20, fontweight="bold")

        info_lines = [
            f"Date: {sys_info.get('date', '?')}",
            f"CPU: {sys_info.get('cpu', '?')}",
            f"Kernel: {sys_info.get('kernel', '?')}",
            f"Caches: L1d={fmt_bytes(sys_info.get('L1d'))}, "
            f"L2={fmt_bytes(sys_info.get('L2'))}, "
            f"L3={fmt_bytes(sys_info.get('L3'))}",
            f"Page size: {fmt_bytes(sys_info.get('page_size'))}",
            f"Queries per test: {NUM_QUERIES:,}",
            f"Perf counters: {'yes' if use_perf else 'no (wall-clock only)'}",
        ]
        ax_title.text(0.5, 0.45, "\n".join(info_lines),
                      transform=ax_title.transAxes, ha="center", va="top",
                      fontsize=9, fontfamily="monospace",
                      bbox=dict(boxstyle="round,pad=0.5", facecolor="#f0f0f0",
                                edgecolor="#cccccc"))

        # Throughput bar chart
        ax_tp = fig.add_subplot(gs[1])
        x = np.arange(len(SIZES))
        width = 0.25

        for i, method in enumerate(METHODS):
            vals = []
            for size in SIZES:
                entry = results.get((method, size))
                vals.append(entry["mqs"] if entry and entry["mqs"] else 0)
            ax_tp.bar(x + i * width, vals, width,
                      label=METHOD_LABELS[method],
                      color=METHOD_COLORS[method])

        ax_tp.set_xlabel("Tree Size (keys)", fontsize=11)
        ax_tp.set_ylabel("Throughput (Mqueries/s)", fontsize=11)
        ax_tp.set_title("Search Throughput Comparison", fontsize=14,
                        fontweight="bold")
        ax_tp.set_xticks(x + width)
        ax_tp.set_xticklabels(
            [f"{fmt_size(s)}\n({fmt_bytes(int(kb * 1024))})"
             for s, kb in zip(SIZES, size_kb)],
            fontsize=8,
        )
        ax_tp.legend(fontsize=10)
        ax_tp.grid(axis="y", alpha=0.3)
        ax_tp.set_axisbelow(True)
        pdf.savefig(fig)
        plt.close(fig)

        if not use_perf:
            # No perf data — just the throughput page
            return

        # ── Page 2: Cache & TLB metrics ──────────────────────
        fig, axes = plt.subplots(2, 2, figsize=(11, 8.5))
        fig.suptitle("Hardware Performance Counter Analysis",
                     fontsize=16, fontweight="bold", y=0.98)

        # dTLB miss rate
        ax = axes[0, 0]
        for i, method in enumerate(METHODS):
            vals = []
            for size in SIZES:
                r = safe_ratio(
                    safe_get(results, method, size, "dTLB-load-misses"),
                    safe_get(results, method, size, "dTLB-loads"),
                )
                vals.append(r if r is not None else 0)
            ax.plot(range(len(SIZES)), vals, "o-",
                    label=METHOD_LABELS[method],
                    color=METHOD_COLORS[method], linewidth=2, markersize=6)
        ax.set_xticks(range(len(SIZES)))
        ax.set_xticklabels(size_labels, fontsize=8)
        ax.set_ylabel("dTLB Miss Rate (%)")
        ax.set_title("dTLB Load Misses — Page Blocking Effect", fontsize=10,
                      fontweight="bold")
        ax.legend(fontsize=8)
        ax.grid(alpha=0.3)
        ax.set_axisbelow(True)

        # LLC miss rate
        ax = axes[0, 1]
        for i, method in enumerate(METHODS):
            vals = []
            for size in SIZES:
                r = safe_ratio(
                    safe_get(results, method, size, "LLC-load-misses"),
                    safe_get(results, method, size, "LLC-loads"),
                )
                vals.append(r if r is not None else 0)
            ax.plot(range(len(SIZES)), vals, "o-",
                    label=METHOD_LABELS[method],
                    color=METHOD_COLORS[method], linewidth=2, markersize=6)
        ax.set_xticks(range(len(SIZES)))
        ax.set_xticklabels(size_labels, fontsize=8)
        ax.set_ylabel("LLC Miss Rate (%)")
        ax.set_title("LLC Load Misses — Cache Line Blocking Effect",
                      fontsize=10, fontweight="bold")
        ax.legend(fontsize=8)
        ax.grid(alpha=0.3)
        ax.set_axisbelow(True)

        # IPC
        ax = axes[1, 0]
        for i, method in enumerate(METHODS):
            vals = []
            for size in SIZES:
                insn = safe_get(results, method, size, "instructions")
                cyc = safe_get(results, method, size, "cycles")
                if insn and cyc and cyc > 0:
                    vals.append(insn / cyc)
                else:
                    vals.append(0)
            ax.plot(range(len(SIZES)), vals, "o-",
                    label=METHOD_LABELS[method],
                    color=METHOD_COLORS[method], linewidth=2, markersize=6)
        ax.set_xticks(range(len(SIZES)))
        ax.set_xticklabels(size_labels, fontsize=8)
        ax.set_ylabel("IPC (instructions / cycle)")
        ax.set_title("Instructions Per Cycle — SIMD Blocking Effect",
                      fontsize=10, fontweight="bold")
        ax.legend(fontsize=8)
        ax.grid(alpha=0.3)
        ax.set_axisbelow(True)

        # Branch miss rate
        ax = axes[1, 1]
        for i, method in enumerate(METHODS):
            vals = []
            for size in SIZES:
                r = safe_ratio(
                    safe_get(results, method, size, "branch-misses"),
                    safe_get(results, method, size, "branches"),
                )
                vals.append(r if r is not None else 0)
            ax.plot(range(len(SIZES)), vals, "o-",
                    label=METHOD_LABELS[method],
                    color=METHOD_COLORS[method], linewidth=2, markersize=6)
        ax.set_xticks(range(len(SIZES)))
        ax.set_xticklabels(size_labels, fontsize=8)
        ax.set_ylabel("Branch Miss Rate (%)")
        ax.set_title("Branch Mispredictions — SIMD Reduces Branches",
                      fontsize=10, fontweight="bold")
        ax.legend(fontsize=8)
        ax.grid(alpha=0.3)
        ax.set_axisbelow(True)

        fig.tight_layout(rect=[0, 0, 1, 0.95])
        pdf.savefig(fig)
        plt.close(fig)

        # ── Page 3: Detailed data tables ─────────────────────
        fig = plt.figure(figsize=(11, 8.5))
        ax = fig.add_subplot(111)
        ax.axis("off")
        ax.set_title("Detailed Results Table", fontsize=16,
                      fontweight="bold", pad=20)

        # Build table data
        headers = ["Size", "Method", "Mq/s", "ns/q",
                   "L1d miss%", "LLC miss%", "dTLB miss%",
                   "IPC", "Br miss%"]
        rows = []
        for size in SIZES:
            for method in METHODS:
                entry = results.get((method, size), {})
                counters = entry.get("counters", {})

                l1_rate = safe_ratio(
                    counters.get("L1-dcache-load-misses"),
                    counters.get("L1-dcache-loads"),
                )
                llc_rate = safe_ratio(
                    counters.get("LLC-load-misses"),
                    counters.get("LLC-loads"),
                )
                tlb_rate = safe_ratio(
                    counters.get("dTLB-load-misses"),
                    counters.get("dTLB-loads"),
                )
                insn = counters.get("instructions")
                cyc = counters.get("cycles")
                ipc = insn / cyc if insn and cyc and cyc > 0 else None
                br_rate = safe_ratio(
                    counters.get("branch-misses"),
                    counters.get("branches"),
                )

                def f(v, fmt=".1f"):
                    return f"{v:{fmt}}" if v is not None else "-"

                rows.append([
                    fmt_size(size),
                    METHOD_LABELS[method],
                    f(entry.get("mqs"), ".2f"),
                    f(entry.get("nsq"), ".1f"),
                    f(l1_rate),
                    f(llc_rate),
                    f(tlb_rate),
                    f(ipc, ".2f"),
                    f(br_rate),
                ])

        table = ax.table(
            cellText=rows, colLabels=headers,
            loc="center", cellLoc="center",
        )
        table.auto_set_font_size(False)
        table.set_fontsize(7)
        table.scale(1.0, 1.3)

        # Style header
        for j in range(len(headers)):
            table[0, j].set_facecolor("#2c3e50")
            table[0, j].set_text_props(color="white", fontweight="bold")

        # Alternate row shading by tree size
        for i, row_data in enumerate(rows):
            size_idx = i // len(METHODS)
            bg = "#f8f9fa" if size_idx % 2 == 0 else "#ffffff"
            # Highlight FAST rows
            if "FAST" in row_data[1]:
                bg = "#d4e6f1" if size_idx % 2 == 0 else "#d6eaf8"
            for j in range(len(headers)):
                table[i + 1, j].set_facecolor(bg)

        pdf.savefig(fig)
        plt.close(fig)


# ── Main ───────────────────────────────────────────────────────────

def main():
    build_dir = sys.argv[1] if len(sys.argv) > 1 else "build"
    output_path = sys.argv[2] if len(sys.argv) > 2 else "fast_report.pdf"

    bench_path = os.path.join(build_dir, "fast_bench_perf")
    if not os.path.isfile(bench_path):
        print(f"Error: {bench_path} not found. Build the project first:")
        print(f"  cmake -B {build_dir} && cmake --build {build_dir}")
        sys.exit(1)

    print("FAST Tree Performance Report Generator")
    print("=" * 42)

    sys_info = get_system_info()
    print(f"CPU:    {sys_info.get('cpu', '?')}")
    print(f"Caches: L1d={fmt_bytes(sys_info.get('L1d'))}, "
          f"L2={fmt_bytes(sys_info.get('L2'))}, "
          f"L3={fmt_bytes(sys_info.get('L3'))}")

    use_perf = check_perf()
    if use_perf:
        print("Perf:   available (collecting hardware counters)")
    else:
        print("Perf:   not available (wall-clock only)")
        print("  Hint: sudo sysctl -w kernel.perf_event_paranoid=-1")

    print(f"\nRunning {len(METHODS) * len(SIZES)} benchmarks "
          f"({NUM_QUERIES:,} queries each)...\n")

    results = collect_all(bench_path, use_perf)

    print(f"\nGenerating report: {output_path}")
    generate_pdf(results, sys_info, use_perf, output_path)
    print(f"Done. Report saved to {output_path}")


if __name__ == "__main__":
    main()
