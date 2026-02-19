#include "fast_internal.h"

/*
 * FAST tree search following the algorithm in Section 5.1.2 of the
 * SIGMOD 2010 paper.
 *
 * The tree layout is a recursive SIMD-blocked structure: each 3-key
 * block (d_K=2 levels in BFS order) is followed contiguously by its
 * 4 child subtrees.  This lets us compute child offsets with simple
 * arithmetic: child i starts at (offset + 3 + i * child_subtree_size).
 *
 * After reaching a leaf block, sorted_rank[] maps the layout position
 * back to the original sorted-array index.  A short forward scan (at
 * most 2 steps) resolves exact-match vs. strict-inequality edges.
 */

#define FAST_SIMD_ROUNDS_PER_CL  (FAST_DL / FAST_DK)
#define FAST_CL_CHILDREN         FAST_NL1

/*
 * Resolve the predecessor from a leaf SIMD block (3 keys).
 *
 * child_index partitions the key space into 4 intervals relative to the
 * block's 3 keys [root, left, right] (BFS order, left < root < right):
 *
 *   0: key <= left       → start searching from rank[left] - 1
 *   1: left < key <= root → start from rank[left]
 *   2: root < key <= right → start from rank[root]
 *   3: key > right        → start from rank[right]
 *
 * Then scan forward (at most 2 positions) checking keys[pos+1] <= key.
 */
static inline int64_t resolve_simd_leaf(const struct fast_tree *t,
                                        int32_t key, size_t offset,
                                        int child_index)
{
    const int32_t *keys = t->keys;
    const int32_t *rank = t->sorted_rank;
    const size_t n = t->n;
    int64_t lo;

    switch (child_index) {
    case 0:  lo = (int64_t)rank[offset + 1] - 1; break;
    case 1:  lo = (int64_t)rank[offset + 1];      break;
    case 2:  lo = (int64_t)rank[offset];           break;
    default: lo = (int64_t)rank[offset + 2];       break;
    }

    /* Clamp and scan forward to find exact predecessor */
    if (lo < -1) lo = -1;
    if (lo >= (int64_t)n) lo = (int64_t)n - 1;
    for (int i = 0; i < 3 && lo + 1 < (int64_t)n; i++) {
        if (keys[lo + 1] <= key)
            lo++;
        else
            break;
    }
    return lo;
}

/* Resolve from a single-key leaf node. */
static inline int64_t resolve_single_leaf(const struct fast_tree *t,
                                          int32_t key, size_t offset,
                                          int child_index)
{
    const int32_t *keys = t->keys;
    const int32_t *rank = t->sorted_rank;
    const size_t n = t->n;
    int64_t lo;

    if (child_index == 0)
        lo = (int64_t)rank[offset] - 1;
    else
        lo = (int64_t)rank[offset];

    if (lo < -1) lo = -1;
    if (lo >= (int64_t)n) lo = (int64_t)n - 1;
    for (int i = 0; i < 2 && lo + 1 < (int64_t)n; i++) {
        if (keys[lo + 1] <= key)
            lo++;
        else
            break;
    }
    return lo;
}

#if FAST_HAVE_SSE

void fast_search_sse(const struct fast_tree *t, int32_t key, int64_t *result)
{
    const int32_t *tree = t->layout;
    const int d_n = t->d_n;

    if (d_n == 0) {
        *result = (t->n > 0 && key >= t->keys[0]) ? 0 : -1;
        return;
    }

    /* Boundary checks */
    if (key < t->keys[0]) {
        *result = -1;
        return;
    }
    if (key >= t->keys[t->n - 1]) {
        *result = (int64_t)(t->n - 1);
        return;
    }

    __m128i v_key = _mm_set1_epi32(key);
    size_t offset = 0;
    int depth_remaining = d_n;
    int child_index = 0;
    int last_block_type = 0; /* 0 = simd (3 keys), 1 = single key */

    while (depth_remaining > 0) {
        int simd_depth = (depth_remaining >= FAST_DK) ? FAST_DK : depth_remaining;

        if (simd_depth == FAST_DK) {
            __m128i v_tree = _mm_loadu_si128((const __m128i *)(tree + offset));
            __m128i v_cmp = _mm_cmpgt_epi32(v_key, v_tree);
            int mask = _mm_movemask_ps(_mm_castsi128_ps(v_cmp));
            child_index = FAST_LOOKUP[mask & 0x7];

            depth_remaining -= FAST_DK;
            last_block_type = 0;

            if (depth_remaining <= 0)
                break;

            size_t child_subtree_size = ((size_t)1 << depth_remaining) - 1;
            offset = offset + FAST_NK + (size_t)child_index * child_subtree_size;

        } else {
            /* Single key (depth_remaining was 1) */
            child_index = (key > tree[offset]) ? 1 : 0;
            depth_remaining -= 1;
            last_block_type = 1;
            break;
        }
    }

    if (last_block_type == 0)
        *result = resolve_simd_leaf(t, key, offset, child_index);
    else
        *result = resolve_single_leaf(t, key, offset, child_index);
}

#else /* !FAST_HAVE_SSE */

void fast_search_sse(const struct fast_tree *t, int32_t key, int64_t *result)
{
    fast_search_scalar(t, key, result);
}

#endif /* FAST_HAVE_SSE */

/*
 * Scalar search: same traversal logic, scalar comparisons.
 */
void fast_search_scalar(const struct fast_tree *t, int32_t key, int64_t *result)
{
    const int32_t *tree = t->layout;
    const int d_n = t->d_n;

    if (d_n == 0) {
        *result = (t->n > 0 && key >= t->keys[0]) ? 0 : -1;
        return;
    }

    if (key < t->keys[0]) {
        *result = -1;
        return;
    }
    if (key >= t->keys[t->n - 1]) {
        *result = (int64_t)(t->n - 1);
        return;
    }

    size_t offset = 0;
    int depth_remaining = d_n;
    int child_index = 0;
    int last_block_type = 0;

    while (depth_remaining > 0) {
        int simd_depth = (depth_remaining >= FAST_DK) ? FAST_DK : depth_remaining;

        if (simd_depth >= 2) {
            int32_t k0 = tree[offset];      /* root */
            int32_t k1 = tree[offset + 1];  /* left child */
            int32_t k2 = tree[offset + 2];  /* right child */

            if (key <= k0) {
                child_index = (key <= k1) ? 0 : 1;
            } else {
                child_index = (key <= k2) ? 2 : 3;
            }

            depth_remaining -= 2;
            last_block_type = 0;

            if (depth_remaining <= 0)
                break;

            size_t child_subtree_size = ((size_t)1 << depth_remaining) - 1;
            offset = offset + FAST_NK + (size_t)child_index * child_subtree_size;

        } else {
            child_index = (key > tree[offset]) ? 1 : 0;
            depth_remaining -= 1;
            last_block_type = 1;
            break;
        }
    }

    if (last_block_type == 0)
        *result = resolve_simd_leaf(t, key, offset, child_index);
    else
        *result = resolve_single_leaf(t, key, offset, child_index);
}
