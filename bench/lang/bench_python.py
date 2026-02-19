#!/usr/bin/env python3
"""Cross-language benchmark: Python — bisect / SortedList vs FAST FFI (ctypes)."""

import sys
import os
import time
import json
import random
import bisect
import ctypes
import platform

try:
    from sortedcontainers import SortedList
    HAS_SORTED_CONTAINERS = True
except ImportError:
    HAS_SORTED_CONTAINERS = False


def load_libfast():
    here = os.path.dirname(os.path.abspath(__file__))
    candidates = [
        os.path.join(here, "..", "..", "build", "libfast.so"),
        os.path.join(here, "..", "..", "build", "libfast.dylib"),
        "libfast.so",
    ]
    for path in candidates:
        if os.path.exists(path):
            lib = ctypes.CDLL(path)
            lib.fast_create.argtypes = [ctypes.POINTER(ctypes.c_int32), ctypes.c_size_t]
            lib.fast_create.restype = ctypes.c_void_p
            lib.fast_destroy.argtypes = [ctypes.c_void_p]
            lib.fast_destroy.restype = None
            lib.fast_search.argtypes = [ctypes.c_void_p, ctypes.c_int32]
            lib.fast_search.restype = ctypes.c_int64
            return lib
    raise OSError("Cannot find libfast.so")


def emit(language, compiler, method, tree_size, num_queries, elapsed):
    mqs = num_queries / elapsed / 1e6
    nsq = elapsed * 1e9 / num_queries
    print(json.dumps({
        "language": language, "compiler": compiler, "method": method,
        "tree_size": tree_size, "num_queries": num_queries,
        "total_sec": round(elapsed, 4),
        "mqs": round(mqs, 2), "ns_per_query": round(nsq, 1),
    }), flush=True)


def main():
    tree_size = int(sys.argv[1]) if len(sys.argv) > 1 else 1_000_000
    num_queries = int(sys.argv[2]) if len(sys.argv) > 2 else 5_000_000

    impl = platform.python_implementation().lower()
    ver = platform.python_version()
    compiler = f"{impl}-{ver}"

    keys_list = [i * 3 + 1 for i in range(tree_size)]
    max_key = keys_list[-1]

    rng = random.Random(42)
    queries = [rng.randint(0, max_key) for _ in range(num_queries)]

    lib = load_libfast()
    warmup = min(10000, num_queries)

    # --- FAST FFI ---
    arr = (ctypes.c_int32 * tree_size)(*keys_list)
    tree_ptr = lib.fast_create(arr, tree_size)
    if not tree_ptr:
        print("fast_create failed", file=sys.stderr)
        sys.exit(1)

    for i in range(warmup):
        lib.fast_search(tree_ptr, queries[i])

    start = time.perf_counter()
    sink = 0
    for q in queries:
        sink += lib.fast_search(tree_ptr, q)
    elapsed = time.perf_counter() - start
    emit("python", compiler, "fast_ffi", tree_size, num_queries, elapsed)

    lib.fast_destroy(tree_ptr)

    # --- bisect (binary search on sorted list) ---
    for i in range(warmup):
        bisect.bisect_right(keys_list, queries[i])

    start = time.perf_counter()
    sink = 0
    for q in queries:
        idx = bisect.bisect_right(keys_list, q) - 1
        sink += idx
    elapsed = time.perf_counter() - start
    emit("python", compiler, "bisect", tree_size, num_queries, elapsed)

    # --- SortedList (B-tree-like, if sortedcontainers installed) ---
    if HAS_SORTED_CONTAINERS:
        sl = SortedList(keys_list)

        for i in range(warmup):
            idx = sl.bisect_right(queries[i]) - 1

        start = time.perf_counter()
        sink = 0
        for q in queries:
            idx = sl.bisect_right(q) - 1
            sink += idx
        elapsed = time.perf_counter() - start
        emit("python", compiler, "SortedList", tree_size, num_queries, elapsed)

    _ = sink


if __name__ == "__main__":
    main()
