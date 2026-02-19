/*
 * Cross-language benchmark: C++ — std::map (red-black tree) vs FAST.
 *
 * Compile:
 *   g++ -O3 -std=c++17 -msse2 -I../../include -I../../bindings/cpp \
 *       bench_cpp.cpp -L../../build -lfast -o bench_cpp_gcc
 */

#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <vector>
#include <algorithm>
#include <chrono>
#include <map>
#include "fast.hpp"

static void emit_json(const char *compiler, const char *method,
                      size_t tree_size, size_t num_queries, double sec)
{
    double mqs = (double)num_queries / sec / 1e6;
    double nsq = sec * 1e9 / (double)num_queries;
    printf("{\"language\":\"cpp\",\"compiler\":\"%s\",\"method\":\"%s\","
           "\"tree_size\":%zu,\"num_queries\":%zu,"
           "\"total_sec\":%.4f,\"mqs\":%.2f,\"ns_per_query\":%.1f}\n",
           compiler, method, tree_size, num_queries, sec, mqs, nsq);
    fflush(stdout);
}

int main(int argc, char **argv)
{
    size_t tree_size   = argc > 1 ? (size_t)std::atol(argv[1]) : 1000000;
    size_t num_queries = argc > 2 ? (size_t)std::atol(argv[2]) : 5000000;

#if defined(__clang__)
    const char *compiler = "clang++-" __clang_version__;
#elif defined(__GNUC__)
    char compiler_buf[64];
    std::snprintf(compiler_buf, sizeof(compiler_buf), "g++-%d.%d.%d",
                  __GNUC__, __GNUC_MINOR__, __GNUC_PATCHLEVEL__);
    const char *compiler = compiler_buf;
#else
    const char *compiler = "unknown";
#endif

    /* Generate sorted keys */
    std::vector<int32_t> keys(tree_size);
    for (size_t i = 0; i < tree_size; i++)
        keys[i] = (int32_t)(i * 3 + 1);

    /* Generate random queries */
    std::vector<int32_t> queries(num_queries);
    std::srand(42);
    int32_t max_key = keys.back();
    for (size_t i = 0; i < num_queries; i++)
        queries[i] = (int32_t)(std::rand() % (max_key + 1));

    using Clock = std::chrono::high_resolution_clock;
    volatile int64_t sink = 0;
    size_t warmup = std::min(num_queries, (size_t)100000);

    /* --- FAST FFI --- */
    {
        fast::Tree tree(keys);
        for (size_t i = 0; i < warmup; i++)
            sink += tree.search(queries[i]);

        auto t0 = Clock::now();
        for (size_t i = 0; i < num_queries; i++)
            sink += tree.search(queries[i]);
        auto t1 = Clock::now();

        double sec = std::chrono::duration<double>(t1 - t0).count();
        emit_json(compiler, "fast_ffi", tree_size, num_queries, sec);
    }

    /* --- std::map (red-black tree) --- */
    {
        std::map<int32_t, size_t> rbtree;
        for (size_t i = 0; i < tree_size; i++)
            rbtree[keys[i]] = i;

        for (size_t i = 0; i < warmup; i++) {
            auto it = rbtree.upper_bound(queries[i]);
            sink += (it != rbtree.begin()) ? (int64_t)(std::prev(it)->second) : -1;
        }

        auto t0 = Clock::now();
        for (size_t i = 0; i < num_queries; i++) {
            auto it = rbtree.upper_bound(queries[i]);
            sink += (it != rbtree.begin()) ? (int64_t)(std::prev(it)->second) : -1;
        }
        auto t1 = Clock::now();

        double sec = std::chrono::duration<double>(t1 - t0).count();
        emit_json(compiler, "std::map", tree_size, num_queries, sec);
    }

    (void)sink;
    return 0;
}
