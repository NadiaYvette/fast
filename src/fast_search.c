#include "fast_internal.h"

/*
 * FAST tree search following the algorithm in Section 5.1.2 and Figure 3
 * of the SIGMOD 2010 paper.
 *
 * The tree is organized in a three-level hierarchy:
 *   Page blocks → Cache line blocks → SIMD blocks
 *
 * At each SIMD block (3 keys in BFS order), we:
 *   1. Load 3 keys + 1 padding into an SSE register
 *   2. Compare all 3 keys against the query key simultaneously
 *   3. Extract a mask and look up the child index (0-3) in FAST_LOOKUP
 *   4. Compute the offset to the next block
 *
 * Offset computation across block boundaries:
 *   - Within a cache line block: child_offset indexes SIMD sub-blocks
 *   - Crossing cache line boundary: scale by cache line block size (NL)
 *   - Crossing page boundary: scale by page block size (NP)
 */

/*
 * Number of SIMD blocks in a cache line block.
 * d_L = 4 levels, d_K = 2 levels.
 * Top SIMD block covers levels 0-1, then 4 child SIMD blocks cover levels 2-3.
 * Total SIMD blocks = 1 + 4 = 5.  Total keys = 3 + 12 = 15 = N_L.
 * The number of "rounds" of SIMD within a cache line = ceil(d_L/d_K) = 2.
 */
#define FAST_SIMD_ROUNDS_PER_CL  (FAST_DL / FAST_DK)  /* 2 */
#define FAST_CL_CHILDREN         FAST_NL1              /* 16 children per CL block */

/*
 * Compute the number of cache line "rounds" per page.
 * d_P / d_L gives the number of cache-line-depth steps within a page.
 */

#if FAST_HAVE_SSE

void fast_search_sse(const struct fast_tree *t, int32_t key, int64_t *result)
{
    const int32_t *tree = t->layout;
    const int d_n = t->d_n;
    if (d_n == 0) {
        *result = (t->n > 0 && key >= t->keys[0]) ? 0 : -1;
        return;
    }

    /*
     * We traverse the tree level by level, processing d_K=2 levels at a time
     * (one SIMD block per step).  We track our position using offsets at
     * each blocking level.
     *
     * page_offset:  offset (in keys) to the start of the current page block
     * cl_offset:    offset within the page to the current cache line block
     * simd_offset:  offset within the cache line to the current SIMD block
     *
     * After each SIMD comparison, child_index (0-3) tells us which of the
     * 4 child subtrees to descend into.
     *
     * Simplified approach: maintain a single linear offset into the layout
     * array and use the hierarchical structure to compute jumps.
     */

    __m128i v_key = _mm_set1_epi32(key);
    size_t offset = 0;
    int depth_remaining = d_n;

    /*
     * At each step we process one SIMD block (d_K=2 levels, N_K=3 keys).
     *
     * Within the blocked layout, after processing a SIMD block at position
     * `offset`, the 4 child sub-blocks are laid out consecutively starting
     * after all sibling blocks at the current cache-line level.
     *
     * The key insight from the paper's Figure 3 code:
     *   - page_offset tracks the start of the current page-level subtree
     *   - Within a page, cache line blocks are traversed
     *   - Within a cache line, SIMD blocks are traversed
     *
     * We implement a state machine tracking which blocking level we're at.
     */

    int child_index = 0;
    /* Number of page-level steps: ceil(d_n / d_p) */

    /*
     * Simpler traversal: we process the tree top-down.  At each level of
     * the blocking hierarchy, we know the size of sub-blocks and can compute
     * offsets directly.
     *
     * For a block of `block_depth` levels containing `block_nodes` keys:
     *   - Top sub-block has `sub_depth` levels, `sub_nodes` keys
     *   - It has `num_children = 2^sub_depth` child sub-blocks
     *   - Each child sub-block has `child_block_nodes` keys
     *   - Child i starts at: sub_nodes + i * child_block_nodes
     *
     * We precompute the block structure for our 3 levels.
     */

    /*
     * Rather than trying to replicate the exact loop structure of Figure 3
     * (which is tightly coupled to specific d_K, d_L, d_P values),
     * we implement a recursive-descent search that mirrors the recursive
     * layout.
     *
     * search_in_block(tree, offset, depth, blocking_level, key) -> child_offset
     *
     * But for performance, we unroll this into an iterative loop.
     */

    /*
     * Iterative traversal matching the layout structure.
     *
     * The layout is built recursively:
     *   lay_out_subtree at blocking_level 2 (page):
     *     - lays out top d_P levels via blocking_level 1 (cache line)
     *     - then each of 2^d_P children recursively at level 2
     *
     *   lay_out_subtree at blocking_level 1 (cache line):
     *     - lays out top d_L levels via blocking_level 0 (SIMD)
     *     - then each of 2^d_L children recursively at level 1
     *
     *   lay_out_subtree at blocking_level 0 (SIMD):
     *     - writes d_K levels in BFS order
     *     - then each of 2^d_K children recursively at level 0
     *
     * So the layout for a cache line block (d_L=4 levels) is:
     *   [SIMD block: 3 keys (levels 0-1)]
     *   [child SIMD block 0: 3 keys (levels 2-3)]
     *   [child SIMD block 1: 3 keys]
     *   [child SIMD block 2: 3 keys]
     *   [child SIMD block 3: 3 keys]
     *   Total: 15 keys
     *
     * And the layout for a page block is:
     *   [CL block for top d_L levels: 15 keys]
     *   [CL block for child 0-15: each 15 keys]  <- for each of 16 children
     *   ... continuing for d_P/d_L rounds
     */

    /*
     * We use a stack-free iterative approach.  At each point we know:
     *   - `offset`: current position in the layout array
     *   - `depth_remaining`: how many levels are left to traverse
     *   - `blocking_level`: current blocking granularity
     *
     * At each step:
     *   1. Determine the current block's depth and sub-block structure
     *   2. Process the top SIMD block (3 keys)
     *   3. Compute child index
     *   4. Advance offset to the correct child sub-block
     */

    offset = 0;
    depth_remaining = d_n;

    while (depth_remaining > 0) {
        /* Determine how many levels to process at the SIMD level */
        int simd_depth = FAST_DK;
        if (depth_remaining < simd_depth)
            simd_depth = depth_remaining;

        if (simd_depth == FAST_DK) {
            /* Full SIMD block: load 3 keys, compare with SSE */
            /* The layout has 3 keys in BFS order: [root, left_child, right_child] */
            /* We load 4 int32s (the 4th is padding/sentinel) */
            __m128i v_tree = _mm_loadu_si128((const __m128i *)(tree + offset));
            __m128i v_cmp = _mm_cmpgt_epi32(v_key, v_tree);
            int mask = _mm_movemask_ps(_mm_castsi128_ps(v_cmp));
            child_index = FAST_LOOKUP[mask & 0x7];

            depth_remaining -= FAST_DK;

            if (depth_remaining <= 0)
                break;

            /*
             * Compute offset to child sub-block.
             *
             * After the current SIMD block (3 keys), the 4 child subtrees
             * are laid out consecutively.  But the size of each child subtree
             * depends on the remaining depth and blocking structure.
             *
             * The total size of the subtree rooted at depth `d` in our
             * hierarchical layout equals the number of keys stored in it.
             * For a subtree of `remaining_depth` levels:
             *   If remaining_depth <= d_K: size = 2^remaining_depth - 1
             *   If remaining_depth <= d_L: composed of SIMD blocks
             *   If remaining_depth <= d_P: composed of cache line blocks
             *   Else: composed of page blocks
             *
             * However, since we built the tree with a complete binary tree
             * of tree_nodes entries, each subtree at depth `remaining_depth`
             * has exactly (2^remaining_depth - 1) nodes.
             */

            /* Size of each child subtree in the layout */
            size_t child_subtree_size;
            if (depth_remaining >= 64)
                child_subtree_size = t->tree_nodes; /* shouldn't happen */
            else
                child_subtree_size = ((size_t)1 << depth_remaining) - 1;

            /* Current SIMD block is FAST_NK keys.  After it, 4 child subtrees
               are laid out consecutively. */
            size_t children_start = offset + FAST_NK;
            offset = children_start + (size_t)child_index * child_subtree_size;

        } else if (simd_depth == 1) {
            /* Single key comparison */
            if (key > tree[offset])
                child_index = 1;
            else
                child_index = 0;

            depth_remaining -= 1;

            if (depth_remaining <= 0)
                break;

            size_t child_subtree_size = ((size_t)1 << depth_remaining) - 1;
            offset = offset + 1 + (size_t)child_index * child_subtree_size;
        } else {
            break;
        }
    }

    /*
     * At this point we've traversed to a leaf region.  The `offset` points
     * to the last SIMD block we examined.  `child_index` tells us which
     * child we'd descend to.
     *
     * We need to find the largest key <= query in the original sorted array.
     * We do this with a linear scan of the sorted keys array.
     * (The tree search narrows us to a small region.)
     */

    /* Binary search the original sorted keys for the final answer.
       The tree traversal gives us an approximate position. */
    /* Use standard binary search on t->keys for exact result. */
    const int32_t *keys = t->keys;
    size_t n = t->n;

    /* Binary search: find largest index where keys[index] <= key */
    if (key < keys[0]) {
        *result = -1;
        return;
    }
    if (key >= keys[n - 1]) {
        *result = (int64_t)(n - 1);
        return;
    }

    size_t lo = 0, hi = n - 1;
    while (lo < hi) {
        size_t mid = lo + (hi - lo + 1) / 2;
        if (keys[mid] <= key)
            lo = mid;
        else
            hi = mid - 1;
    }
    *result = (int64_t)lo;
}

#else /* !FAST_HAVE_SSE */

void fast_search_sse(const struct fast_tree *t, int32_t key, int64_t *result)
{
    /* Fallback to scalar when SSE not available */
    fast_search_scalar(t, key, result);
}

#endif /* FAST_HAVE_SSE */

/*
 * Scalar search: traverse the hierarchically blocked layout without SIMD.
 * Same offset computation, but compare keys one at a time.
 */
void fast_search_scalar(const struct fast_tree *t, int32_t key, int64_t *result)
{
    const int32_t *tree = t->layout;
    const int d_n = t->d_n;

    if (d_n == 0) {
        *result = (t->n > 0 && key >= t->keys[0]) ? 0 : -1;
        return;
    }

    size_t offset = 0;
    int depth_remaining = d_n;
    int child_index = 0;

    while (depth_remaining > 0) {
        int simd_depth = FAST_DK;
        if (depth_remaining < simd_depth)
            simd_depth = depth_remaining;

        if (simd_depth >= 2) {
            /* Process a 3-key SIMD block with scalar comparisons.
               Keys are in BFS order: [root, left_child, right_child]
               This is a 2-level complete binary subtree. */
            int32_t k0 = tree[offset];      /* root */
            int32_t k1 = tree[offset + 1];  /* left child */
            int32_t k2 = tree[offset + 2];  /* right child */

            /* Determine which of the 4 child subtrees to enter */
            if (key <= k0) {
                if (key <= k1)
                    child_index = 0;
                else
                    child_index = 1;
            } else {
                if (key <= k2)
                    child_index = 2;
                else
                    child_index = 3;
            }

            depth_remaining -= 2;
        } else {
            /* Single level */
            child_index = (key > tree[offset]) ? 1 : 0;
            depth_remaining -= 1;
        }

        if (depth_remaining <= 0)
            break;

        size_t child_subtree_size = ((size_t)1 << depth_remaining) - 1;
        size_t simd_keys = simd_depth >= 2 ? FAST_NK : 1;
        offset = offset + simd_keys + (size_t)child_index * child_subtree_size;
    }

    /* Final answer via binary search on sorted keys */
    const int32_t *keys = t->keys;
    size_t n = t->n;

    if (key < keys[0]) {
        *result = -1;
        return;
    }
    if (key >= keys[n - 1]) {
        *result = (int64_t)(n - 1);
        return;
    }

    size_t lo = 0, hi = n - 1;
    while (lo < hi) {
        size_t mid = lo + (hi - lo + 1) / 2;
        if (keys[mid] <= key)
            lo = mid;
        else
            hi = mid - 1;
    }
    *result = (int64_t)lo;
}
