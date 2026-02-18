#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <stdint.h>
#include "fast.h"

/*
 * Perf-oriented comparison benchmark.
 *
 * Compares three search structures on identical data and queries:
 *   1. Sorted array + binary search  (baseline, no locality optimization)
 *   2. BFS-layout binary tree        (standard implicit heap-order layout)
 *   3. FAST tree                     (hierarchically blocked layout)
 *
 * Designed to be run under `perf stat` to measure hardware counters that
 * reveal the architectural effects of FAST's blocking:
 *   - dTLB-load-misses   (page blocking effect)
 *   - LLC-load-misses     (cache line blocking effect)
 *   - L1-dcache-load-misses
 *   - instructions, cycles (IPC / SIMD effect)
 *   - branch-misses
 *
 * Usage:
 *   ./fast_bench_perf [method] [tree_size] [num_queries]
 *
 * method: "array", "bfs", "fast", or "all" (default: "all")
 * tree_size: number of keys (default: 1000000)
 * num_queries: number of search queries (default: 10000000)
 *
 * When method is "all", each structure is tested in sequence with a
 * labeled marker so `perf stat` interval output or separate runs can
 * isolate them.  For cleanest counter attribution, run one method at
 * a time:
 *   perf stat -e ... ./fast_bench_perf array 1000000
 *   perf stat -e ... ./fast_bench_perf bfs   1000000
 *   perf stat -e ... ./fast_bench_perf fast  1000000
 */

/* ------------------------------------------------------------------ */
/* 1. Sorted array binary search                                       */
/* ------------------------------------------------------------------ */

static int64_t sorted_array_search(const int32_t *keys, size_t n, int32_t key)
{
    if (key < keys[0])
        return -1;
    size_t lo = 0, hi = n - 1;
    while (lo < hi) {
        size_t mid = lo + (hi - lo + 1) / 2;
        if (keys[mid] <= key)
            lo = mid;
        else
            hi = mid - 1;
    }
    return (int64_t)lo;
}

/* ------------------------------------------------------------------ */
/* 2. BFS-layout binary tree                                           */
/*    Standard implicit complete binary tree in heap order.             */
/*    Node i (0-indexed) has children at 2i+1 and 2i+2.               */
/*    This is what FAST starts from before its blocked permutation.     */
/* ------------------------------------------------------------------ */

typedef struct {
    int32_t *tree;   /* BFS-ordered keys */
    int32_t *keys;   /* original sorted keys for final answer */
    size_t   n;      /* number of actual keys */
    size_t   nodes;  /* total tree nodes (padded to 2^d - 1) */
} bfs_tree_t;

/* In-order traversal to populate bfs_to_sorted mapping */
static void bfs_inorder_map(size_t *bfs_to_sorted, size_t n)
{
    size_t sorted_idx = 0;
    size_t *stack = (size_t *)malloc(64 * sizeof(size_t));
    size_t stack_cap = 64, stack_top = 0;
    size_t cur = 0;

    while (cur < n || stack_top > 0) {
        while (cur < n) {
            if (stack_top >= stack_cap) {
                stack_cap *= 2;
                stack = (size_t *)realloc(stack, stack_cap * sizeof(size_t));
            }
            stack[stack_top++] = cur;
            cur = 2 * cur + 1;
        }
        if (stack_top > 0) {
            cur = stack[--stack_top];
            bfs_to_sorted[cur] = sorted_idx++;
            cur = 2 * cur + 2;
        }
    }
    free(stack);
}

static bfs_tree_t *bfs_tree_create(const int32_t *sorted_keys, size_t n)
{
    bfs_tree_t *t = (bfs_tree_t *)calloc(1, sizeof(bfs_tree_t));
    if (!t) return NULL;

    /* Compute padded size */
    int d = 0;
    size_t tmp = 1;
    while (tmp - 1 < n) { d++; tmp <<= 1; }
    size_t nodes = tmp - 1;

    t->n = n;
    t->nodes = nodes;
    t->keys = (int32_t *)malloc(n * sizeof(int32_t));
    t->tree = (int32_t *)malloc(nodes * sizeof(int32_t));
    if (!t->keys || !t->tree) {
        free(t->keys);
        free(t->tree);
        free(t);
        return NULL;
    }

    memcpy(t->keys, sorted_keys, n * sizeof(int32_t));
    for (size_t i = 0; i < nodes; i++)
        t->tree[i] = INT32_MAX;

    size_t *bfs_to_sorted = (size_t *)malloc(nodes * sizeof(size_t));
    for (size_t i = 0; i < nodes; i++)
        bfs_to_sorted[i] = SIZE_MAX;
    bfs_inorder_map(bfs_to_sorted, nodes);

    for (size_t i = 0; i < nodes; i++) {
        if (bfs_to_sorted[i] < n)
            t->tree[i] = sorted_keys[bfs_to_sorted[i]];
    }
    free(bfs_to_sorted);
    return t;
}

static void bfs_tree_destroy(bfs_tree_t *t)
{
    if (t) {
        free(t->tree);
        free(t->keys);
        free(t);
    }
}

static int64_t bfs_tree_search(const bfs_tree_t *t, int32_t key)
{
    /* Traverse the BFS tree: at each node, go left (2i+1) or right (2i+2) */
    size_t idx = 0;
    while (idx < t->nodes) {
        if (key <= t->tree[idx])
            idx = 2 * idx + 1;   /* left child */
        else
            idx = 2 * idx + 2;   /* right child */
    }

    /* idx is now a "virtual leaf" past the array.  Back up to find the
       answer in the sorted keys via binary search. */
    const int32_t *keys = t->keys;
    size_t n = t->n;
    if (key < keys[0])
        return -1;
    if (key >= keys[n - 1])
        return (int64_t)(n - 1);
    size_t lo = 0, hi = n - 1;
    while (lo < hi) {
        size_t mid = lo + (hi - lo + 1) / 2;
        if (keys[mid] <= key)
            lo = mid;
        else
            hi = mid - 1;
    }
    return (int64_t)lo;
}

/* ------------------------------------------------------------------ */
/* Benchmark harness                                                   */
/* ------------------------------------------------------------------ */

static double time_diff_sec(struct timespec *start, struct timespec *end)
{
    return (double)(end->tv_sec - start->tv_sec) +
           (double)(end->tv_nsec - start->tv_nsec) / 1e9;
}

typedef int64_t (*search_fn)(const void *structure, int32_t key);

static int64_t wrap_array_search(const void *ctx, int32_t key)
{
    /* ctx points to a {keys, n} pair */
    const int32_t *const *pair = (const int32_t *const *)ctx;
    const int32_t *keys = pair[0];
    size_t n = (size_t)(uintptr_t)pair[1];
    return sorted_array_search(keys, n, key);
}

static int64_t wrap_bfs_search(const void *ctx, int32_t key)
{
    return bfs_tree_search((const bfs_tree_t *)ctx, key);
}

static int64_t wrap_fast_search(const void *ctx, int32_t key)
{
    return fast_search((const fast_tree_t *)ctx, key);
}

/*
 * Run `num_queries` searches and report wall-clock throughput.
 * The interesting numbers come from `perf stat` wrapping this process.
 */
static void run_benchmark(const char *label, search_fn fn, const void *ctx,
                          const int32_t *queries, size_t num_queries)
{
    /* Warm up: bring the structure into whatever cache level it fits in */
    volatile int64_t sink = 0;
    size_t warmup = num_queries < 100000 ? num_queries : 100000;
    for (size_t i = 0; i < warmup; i++)
        sink += fn(ctx, queries[i]);

    struct timespec t0, t1;

    /*
     * Marker: write the label to stderr so that perf stat interval
     * output (--interval-print) or scripted per-method runs can be
     * correlated with counter windows.
     */
    fprintf(stderr, ">>> BEGIN %s (%zu queries)\n", label, num_queries);

    clock_gettime(CLOCK_MONOTONIC, &t0);
    for (size_t i = 0; i < num_queries; i++)
        sink += fn(ctx, queries[i]);
    clock_gettime(CLOCK_MONOTONIC, &t1);

    fprintf(stderr, ">>> END %s\n", label);

    double sec = time_diff_sec(&t0, &t1);
    double mq_s = (double)num_queries / sec / 1e6;
    double ns_q = sec * 1e9 / (double)num_queries;

    printf("  %-24s  %8.2f Mq/s   %6.1f ns/query\n", label, mq_s, ns_q);
    (void)sink;
}

static void usage(const char *argv0)
{
    fprintf(stderr,
        "Usage: %s [method] [tree_size] [num_queries]\n"
        "\n"
        "  method:      array | bfs | fast | all  (default: all)\n"
        "  tree_size:   number of keys            (default: 1000000)\n"
        "  num_queries: number of search queries   (default: 10000000)\n"
        "\n"
        "For cleanest perf counter attribution, run one method at a time:\n"
        "  perf stat -e <events> %s array 1000000 10000000\n"
        "  perf stat -e <events> %s bfs   1000000 10000000\n"
        "  perf stat -e <events> %s fast  1000000 10000000\n",
        argv0, argv0, argv0, argv0);
}

int main(int argc, char **argv)
{
    const char *method = "all";
    size_t tree_size = 1000000;
    size_t num_queries = 10000000;

    if (argc > 1) {
        if (strcmp(argv[1], "-h") == 0 || strcmp(argv[1], "--help") == 0) {
            usage(argv[0]);
            return 0;
        }
        method = argv[1];
    }
    if (argc > 2) tree_size = (size_t)atol(argv[2]);
    if (argc > 3) num_queries = (size_t)atol(argv[3]);

    int do_array = (strcmp(method, "array") == 0 || strcmp(method, "all") == 0);
    int do_bfs   = (strcmp(method, "bfs")   == 0 || strcmp(method, "all") == 0);
    int do_fast  = (strcmp(method, "fast")  == 0 || strcmp(method, "all") == 0);

    if (!do_array && !do_bfs && !do_fast) {
        fprintf(stderr, "Unknown method: %s\n", method);
        usage(argv[0]);
        return 1;
    }

    printf("FAST Perf Comparison Benchmark\n");
    printf("==============================\n");
    printf("  Tree size:   %zu keys (%zu KB)\n", tree_size, tree_size * 4 / 1024);
    printf("  Queries:     %zu\n", num_queries);
    printf("  Method:      %s\n\n", method);

    /* Generate sorted keys */
    int32_t *keys = (int32_t *)malloc(tree_size * sizeof(int32_t));
    if (!keys) { perror("malloc keys"); return 1; }
    for (size_t i = 0; i < tree_size; i++)
        keys[i] = (int32_t)(i * 3 + 1);

    /* Generate random queries spanning the full key range */
    int32_t *queries = (int32_t *)malloc(num_queries * sizeof(int32_t));
    if (!queries) { perror("malloc queries"); return 1; }
    srand(42);  /* deterministic for reproducibility */
    int32_t max_key = keys[tree_size - 1];
    for (size_t i = 0; i < num_queries; i++)
        queries[i] = (int32_t)(rand() % (max_key + 1));

    /* ------ Sorted array binary search ------ */
    if (do_array) {
        const void *pair[2] = { keys, (const void *)(uintptr_t)tree_size };
        run_benchmark("sorted-array-bsearch", wrap_array_search, pair,
                      queries, num_queries);
    }

    /* ------ BFS-layout binary tree ------ */
    if (do_bfs) {
        bfs_tree_t *bfs = bfs_tree_create(keys, tree_size);
        if (!bfs) { fprintf(stderr, "bfs_tree_create failed\n"); return 1; }
        run_benchmark("bfs-binary-tree", wrap_bfs_search, bfs,
                      queries, num_queries);
        bfs_tree_destroy(bfs);
    }

    /* ------ FAST tree ------ */
    if (do_fast) {
        fast_tree_t *ft = fast_create(keys, tree_size);
        if (!ft) { fprintf(stderr, "fast_create failed\n"); return 1; }
        run_benchmark("fast-tree", wrap_fast_search, ft,
                      queries, num_queries);
        fast_destroy(ft);
    }

    free(keys);
    free(queries);
    return 0;
}
