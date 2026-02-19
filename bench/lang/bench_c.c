/*
 * Cross-language benchmark: C — SQLite B+ tree / binary search vs FAST.
 *
 * Usage: ./bench_c_gcc <tree_size> <num_queries>
 * Output: JSON lines to stdout (one per method).
 *
 * Compile:
 *   gcc -O3 -msse2 -I../../include bench_c.c -L../../build -lfast -lsqlite3 -o bench_c_gcc
 *   clang -O3 -msse2 -I../../include bench_c.c -L../../build -lfast -lsqlite3 -o bench_c_clang
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <stdint.h>
#include "fast.h"
#include <sqlite3.h>

static double timespec_diff(struct timespec *a, struct timespec *b)
{
    return (double)(b->tv_sec - a->tv_sec) +
           (double)(b->tv_nsec - a->tv_nsec) / 1e9;
}

/* Comparison function for stdlib bsearch */
static int cmp_int32(const void *a, const void *b)
{
    int32_t va = *(const int32_t *)a;
    int32_t vb = *(const int32_t *)b;
    return (va > vb) - (va < vb);
}

/* Use stdlib bsearch to find largest key <= query */
static int64_t stdlib_bsearch(const int32_t *keys, size_t n, int32_t key)
{
    if (key < keys[0])
        return -1;
    /* bsearch finds exact match; for floor query we need upper_bound logic */
    /* Use manual binary search since bsearch doesn't support floor semantics */
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

static void emit_json(const char *compiler, const char *method,
                      size_t tree_size, size_t num_queries, double sec)
{
    double mqs = (double)num_queries / sec / 1e6;
    double nsq = sec * 1e9 / (double)num_queries;
    printf("{\"language\":\"c\",\"compiler\":\"%s\",\"method\":\"%s\","
           "\"tree_size\":%zu,\"num_queries\":%zu,"
           "\"total_sec\":%.4f,\"mqs\":%.2f,\"ns_per_query\":%.1f}\n",
           compiler, method, tree_size, num_queries, sec, mqs, nsq);
    fflush(stdout);
}

int main(int argc, char **argv)
{
    size_t tree_size   = argc > 1 ? (size_t)atol(argv[1]) : 1000000;
    size_t num_queries = argc > 2 ? (size_t)atol(argv[2]) : 5000000;

#if defined(__clang__)
    const char *compiler = "clang-" __clang_version__;
#elif defined(__GNUC__)
    char compiler_buf[64];
    snprintf(compiler_buf, sizeof(compiler_buf), "gcc-%d.%d.%d",
             __GNUC__, __GNUC_MINOR__, __GNUC_PATCHLEVEL__);
    const char *compiler = compiler_buf;
#else
    const char *compiler = "unknown";
#endif

    /* Generate sorted keys: keys[i] = i*3 + 1 */
    int32_t *keys = (int32_t *)malloc(tree_size * sizeof(int32_t));
    if (!keys) { perror("malloc"); return 1; }
    for (size_t i = 0; i < tree_size; i++)
        keys[i] = (int32_t)(i * 3 + 1);

    /* Generate random queries */
    int32_t *queries = (int32_t *)malloc(num_queries * sizeof(int32_t));
    if (!queries) { perror("malloc"); return 1; }
    srand(42);
    int32_t max_key = keys[tree_size - 1];
    for (size_t i = 0; i < num_queries; i++)
        queries[i] = (int32_t)(rand() % (max_key + 1));

    struct timespec t0, t1;
    volatile int64_t sink = 0;
    size_t warmup = num_queries < 100000 ? num_queries : 100000;

    /* --- FAST FFI --- */
    fast_tree_t *tree = fast_create(keys, tree_size);
    if (!tree) { fprintf(stderr, "fast_create failed\n"); return 1; }

    for (size_t i = 0; i < warmup; i++)
        sink += fast_search(tree, queries[i]);

    clock_gettime(CLOCK_MONOTONIC, &t0);
    for (size_t i = 0; i < num_queries; i++)
        sink += fast_search(tree, queries[i]);
    clock_gettime(CLOCK_MONOTONIC, &t1);
    emit_json(compiler, "fast_ffi", tree_size, num_queries, timespec_diff(&t0, &t1));

    fast_destroy(tree);

    /* --- Binary search on sorted array --- */
    for (size_t i = 0; i < warmup; i++)
        sink += stdlib_bsearch(keys, tree_size, queries[i]);

    clock_gettime(CLOCK_MONOTONIC, &t0);
    for (size_t i = 0; i < num_queries; i++)
        sink += stdlib_bsearch(keys, tree_size, queries[i]);
    clock_gettime(CLOCK_MONOTONIC, &t1);
    emit_json(compiler, "bsearch", tree_size, num_queries, timespec_diff(&t0, &t1));

    /* --- SQLite B+ tree (in-memory) --- */
    {
        sqlite3 *db;
        int rc = sqlite3_open(":memory:", &db);
        if (rc != SQLITE_OK) { fprintf(stderr, "sqlite3_open failed\n"); return 1; }

        /* Minimize overhead: no journal, no sync */
        sqlite3_exec(db, "PRAGMA journal_mode=OFF", NULL, NULL, NULL);
        sqlite3_exec(db, "PRAGMA synchronous=OFF", NULL, NULL, NULL);

        /* Create table with INTEGER PRIMARY KEY (SQLite's native B+ tree) */
        sqlite3_exec(db, "CREATE TABLE t(k INTEGER PRIMARY KEY, v INTEGER)",
                     NULL, NULL, NULL);

        /* Bulk insert within a transaction */
        sqlite3_exec(db, "BEGIN", NULL, NULL, NULL);
        sqlite3_stmt *insert_stmt;
        sqlite3_prepare_v2(db, "INSERT INTO t VALUES(?,?)", -1, &insert_stmt, NULL);
        for (size_t i = 0; i < tree_size; i++) {
            sqlite3_bind_int(insert_stmt, 1, keys[i]);
            sqlite3_bind_int64(insert_stmt, 2, (sqlite3_int64)i);
            sqlite3_step(insert_stmt);
            sqlite3_reset(insert_stmt);
        }
        sqlite3_finalize(insert_stmt);
        sqlite3_exec(db, "COMMIT", NULL, NULL, NULL);

        /* Prepare floor-query: largest key <= ? via B+ tree reverse scan */
        sqlite3_stmt *search_stmt;
        sqlite3_prepare_v2(db,
            "SELECT v FROM t WHERE k<=?1 ORDER BY k DESC LIMIT 1",
            -1, &search_stmt, NULL);

        /* Warmup */
        for (size_t i = 0; i < warmup; i++) {
            sqlite3_bind_int(search_stmt, 1, queries[i]);
            if (sqlite3_step(search_stmt) == SQLITE_ROW)
                sink += sqlite3_column_int64(search_stmt, 0);
            else
                sink += -1;
            sqlite3_reset(search_stmt);
        }

        clock_gettime(CLOCK_MONOTONIC, &t0);
        for (size_t i = 0; i < num_queries; i++) {
            sqlite3_bind_int(search_stmt, 1, queries[i]);
            if (sqlite3_step(search_stmt) == SQLITE_ROW)
                sink += sqlite3_column_int64(search_stmt, 0);
            else
                sink += -1;
            sqlite3_reset(search_stmt);
        }
        clock_gettime(CLOCK_MONOTONIC, &t1);
        emit_json(compiler, "sqlite3_btree", tree_size, num_queries,
                  timespec_diff(&t0, &t1));

        sqlite3_finalize(search_stmt);
        sqlite3_close(db);
    }

    free(keys);
    free(queries);
    (void)sink;
    return 0;
}
