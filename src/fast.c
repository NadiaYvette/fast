#include "fast_internal.h"

fast_tree_t *fast_create(const int32_t *keys, size_t n)
{
    if (!keys || n == 0)
        return NULL;

    struct fast_tree *t = (struct fast_tree *)calloc(1, sizeof(struct fast_tree));
    if (!t)
        return NULL;

    if (fast_build_layout(t, keys, n) != 0) {
        free(t);
        return NULL;
    }

    return t;
}

void fast_destroy(fast_tree_t *tree)
{
    if (!tree)
        return;

    free(tree->layout);
    free(tree->sorted_rank);
    free(tree->keys);
    free(tree);
}

int64_t fast_search(const fast_tree_t *tree, int32_t key)
{
    if (!tree || tree->n == 0)
        return -1;

    int64_t result;
#if FAST_HAVE_SSE
    fast_search_sse(tree, key, &result);
#else
    fast_search_scalar(tree, key, &result);
#endif
    return result;
}

int64_t fast_search_lower_bound(const fast_tree_t *tree, int32_t key)
{
    if (!tree || tree->n == 0)
        return 0;

    /* Lower bound: first key >= query.
       Use the sorted keys array with binary search. */
    const int32_t *keys = tree->keys;
    size_t n = tree->n;

    if (key <= keys[0])
        return 0;
    if (key > keys[n - 1])
        return (int64_t)n;

    size_t lo = 0, hi = n - 1;
    while (lo < hi) {
        size_t mid = lo + (hi - lo) / 2;
        if (keys[mid] < key)
            lo = mid + 1;
        else
            hi = mid;
    }
    return (int64_t)lo;
}

size_t fast_size(const fast_tree_t *tree)
{
    return tree ? tree->n : 0;
}

int32_t fast_key_at(const fast_tree_t *tree, size_t index)
{
    if (!tree || index >= tree->n)
        return 0;
    return tree->keys[index];
}
