#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "fast.h"

static double time_diff_sec(struct timespec *start, struct timespec *end)
{
    return (double)(end->tv_sec - start->tv_sec) +
           (double)(end->tv_nsec - start->tv_nsec) / 1e9;
}

static void bench_size(size_t n, size_t num_queries)
{
    int32_t *keys = (int32_t *)malloc(n * sizeof(int32_t));
    int32_t *queries = (int32_t *)malloc(num_queries * sizeof(int32_t));
    if (!keys || !queries) {
        fprintf(stderr, "allocation failed for n=%zu\n", n);
        free(keys);
        free(queries);
        return;
    }

    /* Generate sorted unique keys */
    for (size_t i = 0; i < n; i++)
        keys[i] = (int32_t)(i * 3 + 1);

    /* Generate random queries within key range */
    int32_t max_key = keys[n - 1];
    for (size_t i = 0; i < num_queries; i++)
        queries[i] = (int32_t)(rand() % (max_key + 1));

    /* Build tree */
    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    fast_tree_t *tree = fast_create(keys, n);
    clock_gettime(CLOCK_MONOTONIC, &t1);

    if (!tree) {
        fprintf(stderr, "fast_create failed for n=%zu\n", n);
        free(keys);
        free(queries);
        return;
    }

    double build_sec = time_diff_sec(&t0, &t1);

    /* Warm up */
    volatile int64_t sink = 0;
    for (size_t i = 0; i < 1000 && i < num_queries; i++)
        sink += fast_search(tree, queries[i]);

    /* Benchmark search */
    clock_gettime(CLOCK_MONOTONIC, &t0);
    for (size_t i = 0; i < num_queries; i++)
        sink += fast_search(tree, queries[i]);
    clock_gettime(CLOCK_MONOTONIC, &t1);

    double search_sec = time_diff_sec(&t0, &t1);
    double queries_per_sec = (double)num_queries / search_sec;
    double ns_per_query = search_sec * 1e9 / (double)num_queries;

    printf("  N=%-12zu  build: %8.3f ms  search: %8.1f Mqueries/s  (%5.1f ns/query)\n",
           n, build_sec * 1000.0, queries_per_sec / 1e6, ns_per_query);

    (void)sink;
    fast_destroy(tree);
    free(keys);
    free(queries);
}

int main(void)
{
    printf("FAST Tree Benchmark\n");
    printf("====================\n\n");

    srand((unsigned)time(NULL));

    size_t sizes[] = {1000, 10000, 100000, 1000000, 10000000};
    size_t num_sizes = sizeof(sizes) / sizeof(sizes[0]);
    size_t num_queries = 10000000;

    for (size_t i = 0; i < num_sizes; i++) {
        if (sizes[i] > 1000000)
            num_queries = 5000000;
        bench_size(sizes[i], num_queries);
    }

    printf("\n");
    return 0;
}
