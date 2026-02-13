#ifndef FAST_H
#define FAST_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct fast_tree fast_tree_t;

/*
 * Build a FAST tree from a sorted array of 32-bit keys.
 * keys must be sorted in ascending order.  n must be >= 1.
 * Returns NULL on allocation failure.
 */
fast_tree_t *fast_create(const int32_t *keys, size_t n);

/* Free all memory associated with the tree. */
void fast_destroy(fast_tree_t *tree);

/*
 * Point search: return the index (into the original sorted key array)
 * of the largest key <= query.  Returns -1 if query < all keys.
 */
int64_t fast_search(const fast_tree_t *tree, int32_t key);

/*
 * Lower-bound search: return the index of the first key >= query.
 * Returns (int64_t)fast_size(tree) if query > all keys.
 */
int64_t fast_search_lower_bound(const fast_tree_t *tree, int32_t key);

/* Return the number of keys in the tree. */
size_t fast_size(const fast_tree_t *tree);

/* Return the key at the given index in the original sorted order. */
int32_t fast_key_at(const fast_tree_t *tree, size_t index);

#ifdef __cplusplus
}
#endif

#endif /* FAST_H */
