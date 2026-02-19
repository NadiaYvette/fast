#ifndef FAST_INTERNAL_H
#define FAST_INTERNAL_H

#include "fast.h"
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifdef __SSE2__
#include <emmintrin.h>  /* SSE2: _mm_set1_epi32, _mm_cmpgt_epi32 */
#include <xmmintrin.h>  /* SSE:  _mm_movemask_ps, _mm_castsi128_ps */
#define FAST_HAVE_SSE 1
#else
#define FAST_HAVE_SSE 0
#endif

/*
 * Architecture constants for 32-bit keys on x86-64.
 *
 * SIMD blocking (innermost):
 *   d_K = 2  =>  N_K = 2^2 - 1 = 3 keys per SIMD block
 *   With 4-byte keys, 3 keys = 12 bytes, fits in 128-bit SSE register.
 *   Each SIMD block is a 2-level complete binary subtree (root + 2 children).
 *
 * Cache line blocking (middle):
 *   d_L = 4  =>  N_L = 2^4 - 1 = 15 keys per cache line block
 *   15 keys * 4 bytes = 60 bytes, fits in a 64-byte cache line.
 *   A cache line block contains multiple SIMD blocks arranged in BFS order.
 *
 * Page blocking (outermost):
 *   d_P depends on page size:
 *     4KB page  => d_P = 10  (2^10 - 1 = 1023 keys * 4 = 4092 bytes)
 *     2MB page  => d_P = 19  (2^19 - 1 = 524287 keys * ~2MB)
 */

#define FAST_DK     2
#define FAST_NK     3    /* 2^FAST_DK - 1 */
#define FAST_NK1    4    /* FAST_NK + 1: number of child subtrees per SIMD block */

#define FAST_DL     4
#define FAST_NL    15    /* 2^FAST_DL - 1 */
#define FAST_NL1   16    /* FAST_NL + 1 */

#define FAST_DP_4K 10
#define FAST_NP_4K 1023  /* 2^10 - 1 */

#define FAST_DP_2M 19
#define FAST_NP_2M 524287 /* 2^19 - 1 */

/* Sentinel value used to pad incomplete trees. */
#define FAST_KEY_MAX INT32_MAX

/*
 * Lookup table for SSE mask → child index.
 *
 * During search, we compare the query key against 3 tree keys using SSE:
 *   V_mask = _mm_cmpgt_epi32(V_keyq, V_tree)
 * This produces a 4-bit mask (we use only the lower 3 bits, plus bit 3
 * which is always 0 since we pad the 4th element with INT32_MAX).
 *
 * The mask encodes: bit i = 1 if query > tree[i], for i in {0,1,2}.
 * In a 3-node complete binary subtree laid out in BFS order [root, left, right]:
 *   - mask=0b000 (0): query <= root                → child 0 (left subtree of left child)
 *   - mask=0b001 (1): query > root, query <= left   → child 1 (right subtree of left child)
 *   - mask=0b010 (2): impossible in sorted BFS (root < left would be wrong)
 *   - mask=0b011 (3): query > root and left, <= right → child 2 (left subtree of right child)
 *   - mask=0b100 (4): impossible
 *   - mask=0b101 (5): impossible
 *   - mask=0b110 (6): impossible
 *   - mask=0b111 (7): query > all three             → child 3 (right subtree of right child)
 *
 * But _mm_movemask_ps extracts the sign bits of 32-bit floats, giving
 * bits in order [b3,b2,b1,b0] from the 4 lanes.  With our BFS layout
 * [root, left_child, right_child] where left_child < root < right_child:
 *
 *   bit 0 = (key > root), bit 1 = (key > left_child), bit 2 = (key > right_child)
 *
 *   - mask=0b000 (0): key <= left_child (and thus <= root) → child 0
 *   - mask=0b001 (1): key > root but key <= left_child    → impossible (left < root)
 *   - mask=0b010 (2): key > left_child, key <= root       → child 1
 *   - mask=0b011 (3): key > root and left_child, <= right  → child 2
 *   - mask=0b100 (4): key > right_child but <= others      → impossible
 *   - mask=0b101 (5): impossible
 *   - mask=0b110 (6): impossible
 *   - mask=0b111 (7): key > all three                      → child 3
 */
static const int FAST_LOOKUP[16] = {
    0, -1, 1, 2, -1, -1, -1, 3,   /* indices 0-7 */
    0, -1, 1, 2, -1, -1, -1, 3    /* indices 8-15 (bit 3 = don't care) */
};

/*
 * Internal tree structure.
 */
struct fast_tree {
    int32_t *layout;       /* Hierarchically blocked tree array (aligned) */
    int32_t *sorted_rank;  /* sorted_rank[i] = index in original sorted array for layout[i] */
    int32_t *keys;         /* Copy of original sorted keys */
    size_t   n;            /* Number of actual keys */
    size_t   layout_size;  /* Number of entries allocated in layout/sorted_rank */
    size_t   tree_nodes;   /* Total nodes in padded complete binary tree (2^d_N - 1) */
    int      d_n;          /* Depth of tree (number of levels) */
    int      d_p;          /* Page blocking depth (depends on system page size) */
    int      n_p;          /* Keys per page block (2^d_p - 1) */
    size_t   page_size;    /* System page size in bytes */
};

/* Internal functions */
int  fast_build_layout(struct fast_tree *t, const int32_t *sorted_keys, size_t n);
void fast_search_sse(const struct fast_tree *t, int32_t key, int64_t *result);
void fast_search_scalar(const struct fast_tree *t, int32_t key, int64_t *result);

#endif /* FAST_INTERNAL_H */
