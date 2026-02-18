# Future Extensions

## Multi-Level Superpage Blocking

The FAST paper (Kim et al., SIGMOD 2010) treats page blocking as a single
level in the hierarchy: one page size determines d_P, and the tree layout
has exactly three blocking levels (SIMD, cache line, page).  This is a
reasonable simplification for the x86-64 platforms the paper targets, where
the practical page sizes are 4 KB and 2 MB (with 1 GB pages rarely used for
application data).

However, a more faithful model of the TLB hierarchy would recognize that
modern architectures support multiple superpage (hugepage) sizes, and that
the TLB itself is typically multi-level with different capacities at each
level.  A proper generalization of the FAST blocking scheme would introduce
additional blocking levels — one for each supported page size — forming a
deeper nesting:

    SIMD block ⊂ cache line block ⊂ 4 KB page block ⊂ 2 MB page block ⊂ 1 GB page block

Each level would have its own depth parameter (d_P1, d_P2, d_P3, ...) and
the layout algorithm would recursively decompose the tree with one more
level of nesting per supported page size.

### Architectural motivation

The key TLB parameters that drive this are:

| Architecture | Typical page sizes | Notes |
|---|---|---|
| x86-64 | 4 KB, 2 MB, 1 GB | Sparse spectrum; 2 MB via `madvise(MADV_HUGEPAGE)` or `MAP_HUGETLB` |
| AArch64 | 4 KB, 16 KB, 64 KB, 2 MB, 32 MB, 1 GB | Contiguous bit gives 4× multiplier; much denser spectrum |
| RISC-V Sv39 | 4 KB, 2 MB, 1 GB | Three-level page table maps directly to three page sizes |
| RISC-V Sv48 | 4 KB, 2 MB, 1 GB, 512 GB | Four page table levels |
| POWER | 4 KB, 64 KB, 2 MB, 16 MB, 1 GB, 16 GB | Very dense superpage spectrum |

Architectures like AArch64 and POWER, which have a denser spectrum of
superpage sizes, would benefit more from multi-level page blocking than
x86-64 does.  On x86-64 the jump from 4 KB to 2 MB is so large that a
single additional blocking level captures most of the benefit; on AArch64
you might want three or four page-blocking levels.

### What this would require

1. **Runtime detection of available page sizes.**  On Linux this is
   available via `/sys/kernel/mm/hugepages/` and the `mmap`/`madvise`
   interface.  The tree construction routine would query the available
   superpage sizes and compute a d_P for each.

2. **Generalized layout algorithm.**  The current `lay_out_subtree`
   recursion already supports an arbitrary number of blocking levels via
   the `blocking_level` parameter and `depths[]` array.  Extending this
   to more than three levels is structurally straightforward — the
   `depths[]` array simply gets more entries.

3. **Superpage-aligned allocation.**  Each page-blocking level's subtrees
   should be aligned to the corresponding page size boundary so that the
   TLB benefits actually materialize.  This requires `mmap` with
   `MAP_HUGETLB` (and the appropriate size flag) or the `memfd_create` /
   `fallocate` approach for explicit hugepage allocation.

4. **Kernel and hardware support.**  Hugepage allocation can fail if the
   system has insufficient contiguous physical memory.  A robust
   implementation would attempt superpage allocation and fall back
   gracefully to smaller page sizes, adjusting d_P values accordingly.

### Testability

Empirically demonstrating multi-level page blocking requires:

- A kernel configured with hugepage support (`CONFIG_HUGETLB_PAGE`,
  `CONFIG_TRANSPARENT_HUGEPAGE`).
- Sufficient hugepage reservations (`/proc/sys/vm/nr_hugepages`).
- `perf stat` with `dTLB-load-misses` and `dTLB-store-misses` counters
  to measure TLB miss rates at each tree size.
- Tree sizes chosen to cross each page-size boundary (e.g., trees that
  fit in 4 KB × TLB_entries but not in 2 MB × L2_TLB_entries).

The ideal test platform would be an architecture with a dense superpage
spectrum (AArch64 or POWER) where the benefit of each additional blocking
level can be isolated by varying tree size across multiple boundaries.

## Other Future Directions

### Software pipelining for concurrent queries

The paper describes issuing prefetches for the next cache line block while
processing the current one, interleaving S simultaneous queries per
core/thread to hide memory latency (Section 5.1.3).  This is a natural
next step for throughput-oriented workloads.

### Key compression

Section 6 of the paper describes two compression schemes:

- **Variable-length key compression** via order-preserving partial keys
  with SIMD-accelerated extraction (Section 6.1).
- **Integer key delta compression** within each page block (Section 6.2).

Both reduce bandwidth consumption for the lower levels of large trees
where search becomes memory-bandwidth-bound.

### AVX2 / AVX-512 SIMD widths

The current implementation uses 128-bit SSE (d_K = 2, N_K = 3).  With
256-bit AVX2 (N_K = 7, d_K = 3) or 512-bit AVX-512 (N_K = 15, d_K = 4),
the SIMD blocking level resolves more tree levels per comparison,
reducing the number of memory accesses and increasing IPC.  The lookup
table grows (2^7 = 128 or 2^15 = 32768 entries) but remains cache-resident.

### Wider key types

Extending from 32-bit to 64-bit keys halves the number of keys per SIMD
register and per cache line, changing all the blocking parameters.  With
128-bit SSE and 64-bit keys: N_K = 1 (d_K = 1), degrading to
non-SIMD scalar comparison; AVX2 would give N_K = 3 (d_K = 2), recovering
the current SSE behavior at the wider key size.
