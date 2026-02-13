#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include "fast.h"

static int tests_run = 0;
static int tests_passed = 0;

#define TEST(name) do { \
    tests_run++; \
    printf("  %-50s", name); \
    fflush(stdout); \
} while(0)

#define PASS() do { tests_passed++; printf("PASS\n"); } while(0)
#define FAIL(msg) do { printf("FAIL: %s\n", msg); } while(0)

static void test_single_element(void)
{
    TEST("single element: search for exact key");
    int32_t keys[] = {42};
    fast_tree_t *t = fast_create(keys, 1);
    assert(t != NULL);
    assert(fast_size(t) == 1);
    assert(fast_key_at(t, 0) == 42);

    int64_t r = fast_search(t, 42);
    if (r == 0) PASS(); else FAIL("expected 0");

    TEST("single element: search below");
    r = fast_search(t, 10);
    if (r == -1) PASS(); else FAIL("expected -1");

    TEST("single element: search above");
    r = fast_search(t, 100);
    if (r == 0) PASS(); else FAIL("expected 0");

    fast_destroy(t);
}

static void test_small_trees(void)
{
    /* 3 elements: fits in one SIMD block */
    TEST("3 elements: exact match first");
    int32_t keys3[] = {10, 20, 30};
    fast_tree_t *t = fast_create(keys3, 3);
    assert(t != NULL);

    if (fast_search(t, 10) == 0) PASS(); else FAIL("expected 0");

    TEST("3 elements: exact match middle");
    if (fast_search(t, 20) == 1) PASS(); else FAIL("expected 1");

    TEST("3 elements: exact match last");
    if (fast_search(t, 30) == 2) PASS(); else FAIL("expected 2");

    TEST("3 elements: between keys");
    if (fast_search(t, 15) == 0) PASS(); else FAIL("expected 0");

    TEST("3 elements: below all");
    if (fast_search(t, 5) == -1) PASS(); else FAIL("expected -1");

    TEST("3 elements: above all");
    if (fast_search(t, 50) == 2) PASS(); else FAIL("expected 2");

    fast_destroy(t);

    /* 7 elements: 3-level tree */
    TEST("7 elements: all exact matches");
    int32_t keys7[] = {2, 4, 6, 8, 10, 12, 14};
    t = fast_create(keys7, 7);
    assert(t != NULL);
    int ok = 1;
    for (int i = 0; i < 7; i++) {
        if (fast_search(t, keys7[i]) != i) { ok = 0; break; }
    }
    if (ok) PASS(); else FAIL("mismatch");

    TEST("7 elements: between keys");
    if (fast_search(t, 7) == 2) PASS(); else FAIL("expected 2");

    fast_destroy(t);
}

static void test_power_of_two(void)
{
    TEST("15 elements (2^4-1): all exact matches");
    int32_t keys[15];
    for (int i = 0; i < 15; i++) keys[i] = (i + 1) * 10;
    fast_tree_t *t = fast_create(keys, 15);
    assert(t != NULL);
    int ok = 1;
    for (int i = 0; i < 15; i++) {
        int64_t r = fast_search(t, keys[i]);
        if (r != i) { ok = 0; printf("\n    keys[%d]=%d -> got %ld, expected %d", i, keys[i], (long)r, i); }
    }
    if (ok) PASS(); else { printf("\n"); FAIL("mismatch"); }
    fast_destroy(t);

    TEST("31 elements (2^5-1): all exact matches");
    int32_t keys31[31];
    for (int i = 0; i < 31; i++) keys31[i] = (i + 1) * 5;
    t = fast_create(keys31, 31);
    assert(t != NULL);
    ok = 1;
    for (int i = 0; i < 31; i++) {
        int64_t r = fast_search(t, keys31[i]);
        if (r != i) { ok = 0; printf("\n    keys[%d]=%d -> got %ld, expected %d", i, keys31[i], (long)r, i); }
    }
    if (ok) PASS(); else { printf("\n"); FAIL("mismatch"); }
    fast_destroy(t);
}

static void test_non_power_of_two(void)
{
    TEST("10 elements: all exact matches");
    int32_t keys[10];
    for (int i = 0; i < 10; i++) keys[i] = i * 3 + 1;
    fast_tree_t *t = fast_create(keys, 10);
    assert(t != NULL);
    int ok = 1;
    for (int i = 0; i < 10; i++) {
        int64_t r = fast_search(t, keys[i]);
        if (r != i) { ok = 0; printf("\n    keys[%d]=%d -> got %ld, expected %d", i, keys[i], (long)r, i); }
    }
    if (ok) PASS(); else { printf("\n"); FAIL("mismatch"); }

    TEST("10 elements: between keys");
    /* key=5 is between keys[1]=4 and keys[2]=7, so result should be 1 */
    int64_t r = fast_search(t, 5);
    if (r == 1) PASS(); else { printf(" (got %ld) ", (long)r); FAIL("expected 1"); }

    fast_destroy(t);

    TEST("100 elements: exhaustive");
    int32_t keys100[100];
    for (int i = 0; i < 100; i++) keys100[i] = i * 2;  /* 0, 2, 4, ..., 198 */
    t = fast_create(keys100, 100);
    assert(t != NULL);
    ok = 1;
    for (int i = 0; i < 100; i++) {
        int64_t res = fast_search(t, keys100[i]);
        if (res != i) {
            ok = 0;
            printf("\n    keys[%d]=%d -> got %ld, expected %d", i, keys100[i], (long)res, i);
            break;
        }
    }
    if (ok) PASS(); else { printf("\n"); FAIL("mismatch"); }
    fast_destroy(t);
}

static void test_duplicates(void)
{
    TEST("duplicate keys: all same value");
    int32_t keys[] = {5, 5, 5, 5, 5};
    fast_tree_t *t = fast_create(keys, 5);
    assert(t != NULL);
    int64_t r = fast_search(t, 5);
    /* Should find *some* index where key is 5 */
    if (r >= 0 && r < 5 && fast_key_at(t, (size_t)r) == 5) PASS();
    else FAIL("expected valid index with key 5");
    fast_destroy(t);
}

static void test_lower_bound(void)
{
    TEST("lower_bound: exact match");
    int32_t keys[] = {10, 20, 30, 40, 50};
    fast_tree_t *t = fast_create(keys, 5);
    assert(t != NULL);
    if (fast_search_lower_bound(t, 30) == 2) PASS(); else FAIL("expected 2");

    TEST("lower_bound: between keys");
    if (fast_search_lower_bound(t, 25) == 2) PASS(); else FAIL("expected 2");

    TEST("lower_bound: below all");
    if (fast_search_lower_bound(t, 1) == 0) PASS(); else FAIL("expected 0");

    TEST("lower_bound: above all");
    if (fast_search_lower_bound(t, 100) == 5) PASS(); else FAIL("expected 5");

    fast_destroy(t);
}

static int cmp_int32(const void *a, const void *b)
{
    int32_t x = *(const int32_t *)a, y = *(const int32_t *)b;
    return (x > y) - (x < y);
}

static void test_large_random(void)
{
    const size_t N = 100000;
    TEST("100K random keys: build + verify all");
    int32_t *keys = (int32_t *)malloc(N * sizeof(int32_t));
    assert(keys);

    /* Generate random keys */
    srand(12345);
    for (size_t i = 0; i < N; i++)
        keys[i] = (int32_t)(rand() % 10000000);
    qsort(keys, N, sizeof(int32_t), cmp_int32);

    /* Remove duplicates */
    size_t unique = 1;
    for (size_t i = 1; i < N; i++) {
        if (keys[i] != keys[unique - 1])
            keys[unique++] = keys[i];
    }

    fast_tree_t *t = fast_create(keys, unique);
    assert(t != NULL);

    int ok = 1;
    for (size_t i = 0; i < unique; i++) {
        int64_t r = fast_search(t, keys[i]);
        if (r != (int64_t)i) {
            printf("\n    keys[%zu]=%d -> got %ld, expected %zu", i, keys[i], (long)r, i);
            ok = 0;
            if (i > 5) break;  /* Limit error output */
        }
    }
    if (ok) PASS(); else { printf("\n"); FAIL("mismatch"); }

    TEST("100K random keys: search for missing keys");
    ok = 1;
    for (int trial = 0; trial < 1000; trial++) {
        int32_t query = (int32_t)(rand() % 10000000);
        int64_t r = fast_search(t, query);

        /* Verify: r should be the largest index where keys[r] <= query,
           or -1 if query < keys[0]. */
        if (query < keys[0]) {
            if (r != -1) { ok = 0; break; }
        } else {
            if (r < 0 || r >= (int64_t)unique) { ok = 0; break; }
            if (keys[r] > query) { ok = 0; break; }
            if (r + 1 < (int64_t)unique && keys[r + 1] <= query) { ok = 0; break; }
        }
    }
    if (ok) PASS(); else FAIL("incorrect search result for missing key");

    fast_destroy(t);
    free(keys);
}

int main(void)
{
    printf("FAST Tree Tests\n");
    printf("===============\n\n");

    test_single_element();
    test_small_trees();
    test_power_of_two();
    test_non_power_of_two();
    test_duplicates();
    test_lower_bound();
    test_large_random();

    printf("\n%d / %d tests passed\n", tests_passed, tests_run);
    return tests_passed == tests_run ? 0 : 1;
}
