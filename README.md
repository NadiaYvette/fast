# FAST: Fast Architecture Sensitive Tree

A C implementation of the FAST search tree algorithm described in:

> Changkyu Kim, Jatin Chhugani, Nadathur Satish, Eric Sedlar, Anthony D. Nguyen,
> Tim Kaldewey, Victor W. Lee, Scott A. Brandt, and Pradeep Dubey.
> **"FAST: Fast Architecture Sensitive Tree Search on Modern CPUs and GPUs."**
> *SIGMOD '10*, June 6–11, 2010, Indianapolis, Indiana, USA.

FAST is a binary search tree whose nodes are rearranged in memory using a
three-level hierarchical blocking scheme — page, cache line, and SIMD — to
minimize TLB misses, cache misses, and exploit SSE2 parallelism during
search.

## Building

```bash
cmake -B build
cmake --build build
```

Produces:
- `libfast.so` / `libfast.a` — shared and static libraries
- `build/fast_test` — correctness tests
- `build/fast_bench` — throughput benchmark
- `build/fast_bench_perf` — perf counter comparison benchmark

Requirements: C11 compiler with SSE2 support (baseline on x86-64), CMake ≥ 3.10.

## Usage (C)

```c
#include <fast.h>

int32_t keys[] = {2, 4, 6, 8, 10, 12, 14};
fast_tree_t *tree = fast_create(keys, 7);

int64_t idx = fast_search(tree, 9);      /* returns 3 (largest key <= 9 is 8) */
int64_t lb  = fast_search_lower_bound(tree, 9); /* returns 4 (first key >= 9 is 10) */

fast_destroy(tree);
```

## API

```c
fast_tree_t *fast_create(const int32_t *keys, size_t n);
void         fast_destroy(fast_tree_t *tree);
int64_t      fast_search(const fast_tree_t *tree, int32_t key);
int64_t      fast_search_lower_bound(const fast_tree_t *tree, int32_t key);
size_t       fast_size(const fast_tree_t *tree);
int32_t      fast_key_at(const fast_tree_t *tree, size_t index);
```

All functions use an opaque pointer (`fast_tree_t *`) suitable for FFI.
Keys must be sorted `int32_t` values. `fast_search` returns the index of
the largest key ≤ the query, or −1 if the query is smaller than all keys.

## How It Works

The tree is a complete binary tree whose nodes are permuted into a
hierarchically blocked memory layout with three nesting levels:

| Level | Blocking by | Depth | Nodes per block | Rationale |
|-------|-------------|-------|-----------------|-----------|
| Inner | SIMD register (128-bit SSE) | d_K = 2 | 3 | Compare 3 keys simultaneously via `_mm_cmpgt_epi32` |
| Middle | Cache line (64 bytes) | d_L = 4 | 15 | Keep one traversal step's data in a single cache line |
| Outer | Memory page (4 KB / 2 MB) | d_P = 10 or 19 | 1023 or 524287 | Minimize TLB misses during traversal |

During search, each SIMD block is processed by loading 3 keys into an SSE
register, comparing all three against the query key in parallel, extracting
a bitmask, and looking up the child index in an 8-entry table. This
replaces unpredictable branches with a mask-and-lookup, improving IPC and
reducing branch mispredictions.

A scalar fallback is provided for platforms without SSE2.

## Benchmarks

Run the throughput benchmark:

```bash
./build/fast_bench
```

Run the perf counter comparison (sorted array vs. BFS tree vs. FAST):

```bash
./build/fast_bench_perf all 1000000 5000000
```

Or with hardware performance counters:

```bash
perf stat -e cycles,instructions,L1-dcache-load-misses,LLC-load-misses,dTLB-load-misses \
    ./build/fast_bench_perf fast 4000000 5000000
```

### PDF Report

Generate a full PDF report with throughput charts, performance counter
analysis, and detailed tables:

```bash
python3 bench/report.py build fast_report.pdf
```

Requires Python 3 with matplotlib and numpy. Uses `perf stat` when
available; falls back to wall-clock timing otherwise.

### Sweep Script

Run the full comparison sweep across multiple tree sizes with grouped
hardware counters:

```bash
bench/run_perf.sh build
```

## FFI Bindings

Bindings are provided for 17 languages, all wrapping the same C shared
library:

| Language | File | Approach |
|----------|------|----------|
| C++ | `bindings/cpp/fast.hpp` | RAII `fast::Tree` class |
| Rust | `bindings/rust/` | `FastTree` with `Drop` |
| Ada | `bindings/ada/fast_binding.ads` | `pragma Import(C)` |
| Go | `bindings/go/fast.go` | cgo with finalizer |
| Fortran | `bindings/fortran/fast_binding.f90` | `ISO_C_BINDING` |
| Java | `bindings/java/` | JNI with `AutoCloseable` |
| Julia | `bindings/julia/Fast.jl` | `ccall` |
| Python | `bindings/python/fast.py` | ctypes |
| Ruby | `bindings/ruby/fast.rb` | FFI gem |
| R | `bindings/r/fast.R` | `dyn.load` + `.Call` |
| Haskell | `bindings/haskell/Fast.hs` | `foreign import ccall` |
| Mercury | `bindings/mercury/fast.m` | `pragma foreign_proc` |
| Standard ML | `bindings/sml/fast.sml` | MLton `_import` |
| OCaml | `bindings/ocaml/` | C stubs + `external` |
| Prolog | `bindings/prolog/fast.pl` | SWI-Prolog foreign |
| Common Lisp | `bindings/lisp/fast.lisp` | CFFI |
| Scheme | `bindings/scheme/fast.scm` | Chez Scheme `foreign-procedure` |

### Python example

```python
from fast import FastTree
tree = FastTree([1, 3, 5, 7, 9])
tree.search(5)   # 2
tree.search(0)   # -1
```

## Tests

```bash
./build/fast_test
```

23 tests covering single-element trees, power-of-2 and non-power-of-2
sizes, duplicate keys, lower-bound search, and exhaustive verification
with 100K random keys.

## Project Structure

```
include/fast.h            Public C API (the FFI surface)
src/fast_internal.h       Architecture constants, structs, lookup table
src/fast_build.c          Sorted array → hierarchically blocked layout
src/fast_search.c         SSE2 search with lookup table + scalar fallback
src/fast.c                Public API glue
test/test_fast.c          Correctness tests
bench/bench.c             Throughput benchmark
bench/bench_perf.c        Perf counter comparison benchmark
bench/run_perf.sh         Hardware counter sweep script
bench/report.py           PDF report generator
bindings/                 FFI bindings for 15 languages
FUTURE.md                 Future extensions (superpages, AVX, compression)
```

## Future Work

See [FUTURE.md](FUTURE.md) for planned extensions, including:

- **Multi-level superpage blocking** — additional blocking levels for each
  supported page size (4 KB → 2 MB → 1 GB), particularly beneficial on
  architectures with dense superpage spectra (AArch64, POWER)
- **AVX2 / AVX-512** — wider SIMD resolves more tree levels per comparison
- **Software pipelining** — interleave multiple concurrent queries to hide
  memory latency
- **Key compression** — order-preserving partial keys and delta encoding
  to reduce bandwidth for large trees

## License

This implementation is an independent realization of the algorithm
described in the SIGMOD 2010 paper cited above.
