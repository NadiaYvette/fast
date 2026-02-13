#include "fast_internal.h"

/*
 * Build a mapping from sorted index -> BFS index for a complete binary
 * tree with `n` nodes.  sorted_to_bfs[i] = BFS index (0-based) for the
 * i-th smallest key.
 *
 * We do an in-order traversal of the implicit complete binary tree
 * (0-indexed BFS layout) to assign sorted positions.
 */
static void build_inorder_map(size_t *bfs_to_sorted, size_t n)
{
    /* In-order traversal of implicit complete binary tree.
     * BFS index i (0-based): left child = 2i+1, right child = 2i+2.
     * We traverse in-order and assign consecutive sorted indices. */
    size_t sorted_idx = 0;

    /* Iterative in-order traversal using a stack. */
    size_t *stack = (size_t *)malloc(64 * sizeof(size_t));
    size_t stack_cap = 64;
    size_t stack_top = 0;
    size_t cur = 0;

    while (cur < n || stack_top > 0) {
        while (cur < n) {
            if (stack_top >= stack_cap) {
                stack_cap *= 2;
                stack = (size_t *)realloc(stack, stack_cap * sizeof(size_t));
            }
            stack[stack_top++] = cur;
            cur = 2 * cur + 1;  /* left child */
        }
        if (stack_top > 0) {
            cur = stack[--stack_top];
            bfs_to_sorted[cur] = sorted_idx++;
            cur = 2 * cur + 2;  /* right child */
        }
    }

    free(stack);
}

/*
 * Recursively lay out the hierarchically blocked tree.
 *
 * This is the core of the FAST layout algorithm. We recursively decompose
 * the BFS-ordered binary tree into blocks at three granularities:
 *
 * 1. SIMD blocks: d_K=2 levels, N_K=3 nodes
 *    A complete binary subtree of depth 2 (root + 2 children).
 *    Fits in one SSE register load (3 × 4 bytes = 12 bytes).
 *
 * 2. Cache line blocks: d_L=4 levels, N_L=15 nodes
 *    Contains ceil(d_L/d_K) = 2 "rounds" of SIMD blocks.
 *    First SIMD block (3 nodes) at the top, then 4 child SIMD blocks
 *    (12 nodes) = 15 total. Fits in one 64-byte cache line (60 bytes).
 *
 * 3. Page blocks: d_P levels, N_P nodes
 *    Contains ceil(d_P/d_L) rounds of cache line blocks.
 *
 * The layout procedure:
 *   layout_block(bfs_tree, out, bfs_root, out_pos, remaining_depth, block_type)
 *
 * For a subtree of `depth` levels rooted at BFS index `bfs_root`:
 *   - Extract the top `block_depth` levels (the current block)
 *   - Write those nodes contiguously at `out_pos`
 *   - Recursively lay out each child subtree
 */

/*
 * Write a complete binary subtree of `depth` levels rooted at `bfs_root`
 * in BFS order into `out` starting at `out_pos`.
 * Returns the number of nodes written (2^depth - 1).
 */
static size_t write_bfs_block(const int32_t *bfs_tree, int32_t *out,
                              size_t bfs_root, size_t out_pos,
                              int depth, size_t total_bfs_nodes)
{
    size_t count = 0;
    size_t block_size = ((size_t)1 << depth) - 1;

    /* BFS traversal of the subtree: level by level */
    /* Queue: we process nodes level by level */
    size_t *queue = (size_t *)malloc(block_size * sizeof(size_t));
    size_t head = 0, tail = 0;

    if (bfs_root < total_bfs_nodes) {
        queue[tail++] = bfs_root;
    }

    int levels_done = 0;
    size_t level_remaining = 1;
    size_t next_level_count = 0;

    while (head < tail && levels_done < depth) {
        size_t node = queue[head++];
        level_remaining--;

        out[out_pos + count] = bfs_tree[node];
        count++;

        size_t left = 2 * node + 1;
        size_t right = 2 * node + 2;
        if (left < total_bfs_nodes && levels_done + 1 < depth) {
            queue[tail++] = left;
            next_level_count++;
        }
        if (right < total_bfs_nodes && levels_done + 1 < depth) {
            queue[tail++] = right;
            next_level_count++;
        }

        if (level_remaining == 0) {
            levels_done++;
            level_remaining = next_level_count;
            next_level_count = 0;
        }
    }

    free(queue);
    return count;
}

/*
 * Collect the leaf-level BFS indices of a subtree of `depth` levels
 * rooted at `bfs_root`.  These are the roots of the child subtrees
 * that will be laid out next.
 *
 * The "leaves" here are the children of the bottom level of the block,
 * i.e., the nodes at depth `depth` (0-indexed from the block root).
 * There are 2^depth such children.
 */
static size_t collect_children(size_t bfs_root, int depth,
                               size_t *children, size_t total_bfs_nodes)
{
    /* The children of a d-level block rooted at `bfs_root` are
       the BFS nodes at level d below bfs_root. */
    /* Level 0: bfs_root
       Level 1: 2*bfs_root+1, 2*bfs_root+2
       Level d: 2^d nodes starting at 2^d * bfs_root + (2^d - 1) */
    size_t num_children = (size_t)1 << depth;
    size_t base = num_children * (bfs_root + 1) - 1; /* first child BFS index (0-based) */

    size_t count = 0;
    for (size_t i = 0; i < num_children; i++) {
        size_t child = base + i;
        if (child < total_bfs_nodes) {
            children[count++] = child;
        }
    }
    return count;
}

/*
 * Recursively lay out a subtree in the hierarchical blocked fashion.
 *
 * blocking_level:
 *   0 = we're laying out SIMD blocks (innermost, d_K levels)
 *   1 = cache line blocks (d_L levels, decomposed into SIMD blocks)
 *   2 = page blocks (d_P levels, decomposed into cache line blocks)
 *   3 = top level (whole tree, decomposed into page blocks)
 *
 * For each level, we:
 *   1. Write the top `sub_depth` levels of the current subtree
 *   2. Collect the child subtree roots
 *   3. Recursively lay out each child
 *
 * The sub_depth at each blocking level:
 *   - Level 0 (SIMD):       sub_depth = d_K = 2
 *   - Level 1 (cache line): sub_depth = d_L = 4 (contains SIMD blocks internally)
 *   - Level 2 (page):       sub_depth = d_P (contains cache line blocks)
 *
 * But we want the *within-block* layout to also be hierarchical. So a cache
 * line block's 15 nodes are arranged as: [3 SIMD-block nodes] followed by
 * [4 child SIMD blocks of 3 nodes each].  Similarly for page blocks.
 *
 * We implement this with a two-phase approach:
 * Phase 1: Build BFS tree from sorted keys
 * Phase 2: Permute into blocked layout via recursive decomposition
 */

/*
 * lay_out_subtree: Recursively arrange a subtree rooted at BFS index
 * `bfs_root` (with `remaining_depth` levels below it) into the output
 * array at position `*out_pos`.
 *
 * `block_depth` is the depth of the current blocking level we should
 * decompose into (d_K for SIMD, d_L for cache-line, d_P for page).
 *
 * `blocking_level`: 0=SIMD, 1=cacheline, 2=page
 * `depths`: array [d_K, d_L, d_P]
 */
static void lay_out_subtree(const int32_t *bfs_tree, int32_t *out,
                            size_t bfs_root, size_t *out_pos,
                            int remaining_depth, int blocking_level,
                            const int *depths, size_t total_bfs_nodes)
{
    if (remaining_depth <= 0 || bfs_root >= total_bfs_nodes)
        return;

    int block_depth = depths[blocking_level];

    if (remaining_depth <= block_depth || blocking_level == 0) {
        /*
         * Base case: remaining tree fits in one block at this level,
         * or we're at the SIMD (innermost) level.
         * Write the subtree in plain BFS order.
         */
        int actual_depth = remaining_depth < block_depth ? remaining_depth : block_depth;
        size_t written = write_bfs_block(bfs_tree, out, bfs_root, *out_pos,
                                         actual_depth, total_bfs_nodes);
        *out_pos += written;

        /* Now lay out children (subtrees below this block) */
        if (remaining_depth > block_depth) {
            size_t children[1 << FAST_DK]; /* max children at SIMD level */
            size_t nchildren = collect_children(bfs_root, actual_depth,
                                                children, total_bfs_nodes);
            for (size_t i = 0; i < nchildren; i++) {
                lay_out_subtree(bfs_tree, out, children[i], out_pos,
                                remaining_depth - actual_depth, blocking_level,
                                depths, total_bfs_nodes);
            }
        }
    } else {
        /*
         * Recursive case: decompose this block into sub-blocks at the
         * next finer blocking level.
         *
         * Write the top `block_depth` levels of the subtree, but with
         * the internal structure recursively blocked at the next level down.
         */
        /* First, lay out the top portion (block_depth levels) using the
           next finer blocking level */
        /* Actually: we write the top block_depth levels as a unit, then
           recurse into children.  The internal structure of this block
           is handled by the next-level-down decomposition. */

        /* Lay out the top `block_depth` levels using finer blocking */
        lay_out_subtree(bfs_tree, out, bfs_root, out_pos,
                        block_depth, blocking_level - 1,
                        depths, total_bfs_nodes);

        /* Collect children at block_depth levels below bfs_root */
        size_t max_children = (size_t)1 << block_depth;
        size_t *children = (size_t *)malloc(max_children * sizeof(size_t));
        size_t nchildren = collect_children(bfs_root, block_depth,
                                            children, total_bfs_nodes);

        /* Recursively lay out each child subtree at this blocking level */
        for (size_t i = 0; i < nchildren; i++) {
            lay_out_subtree(bfs_tree, out, children[i], out_pos,
                            remaining_depth - block_depth, blocking_level,
                            depths, total_bfs_nodes);
        }
        free(children);
    }
}

int fast_build_layout(struct fast_tree *t, const int32_t *sorted_keys, size_t n)
{
    /* Compute tree depth: d_N = ceil(log2(n+1)) so that 2^d_N - 1 >= n */
    int d_n = 0;
    {
        size_t tmp = 1;
        while (tmp - 1 < n) { d_n++; tmp <<= 1; }
    }
    size_t tree_nodes = ((size_t)1 << d_n) - 1;

    t->d_n = d_n;
    t->tree_nodes = tree_nodes;
    t->n = n;

    /* Detect page size */
    long ps = sysconf(_SC_PAGESIZE);
    t->page_size = (ps > 0) ? (size_t)ps : 4096;
    /* Compute d_p: largest d such that (2^d - 1) * 4 <= page_size */
    t->d_p = FAST_DP_4K;
    if (t->page_size >= 2 * 1024 * 1024) {
        t->d_p = FAST_DP_2M;
    } else {
        int dp = 1;
        while (((size_t)1 << (dp + 1)) - 1 <= t->page_size / sizeof(int32_t)) {
            dp++;
        }
        t->d_p = dp;
    }
    t->n_p = ((size_t)1 << t->d_p) - 1;

    /* Copy sorted keys */
    t->keys = (int32_t *)malloc(n * sizeof(int32_t));
    if (!t->keys)
        return -1;
    memcpy(t->keys, sorted_keys, n * sizeof(int32_t));

    /* Build BFS tree: bfs_tree[i] holds the key at BFS position i */
    int32_t *bfs_tree = (int32_t *)malloc(tree_nodes * sizeof(int32_t));
    if (!bfs_tree) {
        free(t->keys);
        t->keys = NULL;
        return -1;
    }

    /* Fill with sentinel, then populate via in-order mapping */
    for (size_t i = 0; i < tree_nodes; i++)
        bfs_tree[i] = FAST_KEY_MAX;

    /* Build mapping: bfs_to_sorted[bfs_index] = sorted_index */
    size_t *bfs_to_sorted = (size_t *)malloc(tree_nodes * sizeof(size_t));
    if (!bfs_to_sorted) {
        free(bfs_tree);
        free(t->keys);
        t->keys = NULL;
        return -1;
    }
    for (size_t i = 0; i < tree_nodes; i++)
        bfs_to_sorted[i] = SIZE_MAX;

    build_inorder_map(bfs_to_sorted, tree_nodes);

    /* Populate BFS tree: for each BFS node, assign the key at its
       in-order rank (or sentinel if rank >= n) */
    for (size_t i = 0; i < tree_nodes; i++) {
        size_t sorted_idx = bfs_to_sorted[i];
        if (sorted_idx < n)
            bfs_tree[i] = sorted_keys[sorted_idx];
        else
            bfs_tree[i] = FAST_KEY_MAX;
    }
    free(bfs_to_sorted);

    /* Allocate output layout array (aligned to page boundary for TLB perf) */
    size_t layout_bytes = tree_nodes * sizeof(int32_t);
    /* Round up to multiple of 64 (cache line) and add padding for SSE loads */
    layout_bytes = ((layout_bytes + 63) / 64) * 64 + 16;

    t->layout = NULL;
    if (posix_memalign((void **)&t->layout, t->page_size > 64 ? 4096 : 64,
                       layout_bytes) != 0) {
        free(bfs_tree);
        free(t->keys);
        t->keys = NULL;
        return -1;
    }

    /* Fill layout with sentinel */
    for (size_t i = 0; i < layout_bytes / sizeof(int32_t); i++)
        t->layout[i] = FAST_KEY_MAX;

    /* Perform hierarchical blocked layout */
    int depths[3] = { FAST_DK, FAST_DL, t->d_p };
    int blocking_level;
    if (d_n <= FAST_DK)
        blocking_level = 0;
    else if (d_n <= FAST_DL)
        blocking_level = 1;
    else
        blocking_level = 2;

    size_t out_pos = 0;
    lay_out_subtree(bfs_tree, t->layout, 0, &out_pos, d_n, blocking_level,
                    depths, tree_nodes);

    free(bfs_tree);
    return 0;
}
