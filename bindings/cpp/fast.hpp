#ifndef FAST_HPP
#define FAST_HPP

/*
 * C++ RAII wrapper for the FAST search tree library.
 *
 * Usage:
 *   #include "fast.hpp"
 *   std::vector<int32_t> keys = {1, 3, 5, 7, 9};
 *   fast::Tree tree(keys.data(), keys.size());
 *   int64_t idx = tree.search(5);  // returns 2
 */

#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include <vector>

extern "C" {
#include "fast.h"
}

namespace fast {

class Tree {
public:
    Tree(const int32_t *keys, size_t n)
        : tree_(fast_create(keys, n))
    {
        if (!tree_)
            throw std::runtime_error("fast_create failed");
    }

    Tree(const std::vector<int32_t> &keys)
        : Tree(keys.data(), keys.size()) {}

    ~Tree() { fast_destroy(tree_); }

    Tree(const Tree &) = delete;
    Tree &operator=(const Tree &) = delete;

    Tree(Tree &&other) noexcept : tree_(other.tree_) { other.tree_ = nullptr; }
    Tree &operator=(Tree &&other) noexcept {
        if (this != &other) {
            fast_destroy(tree_);
            tree_ = other.tree_;
            other.tree_ = nullptr;
        }
        return *this;
    }

    int64_t search(int32_t key) const { return fast_search(tree_, key); }
    int64_t lower_bound(int32_t key) const { return fast_search_lower_bound(tree_, key); }
    size_t size() const { return fast_size(tree_); }
    int32_t key_at(size_t index) const { return fast_key_at(tree_, index); }

private:
    fast_tree_t *tree_;
};

} // namespace fast

#endif // FAST_HPP
