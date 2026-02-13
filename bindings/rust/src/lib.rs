//! Rust bindings for the FAST (Fast Architecture Sensitive Tree) library.
//!
//! # Example
//! ```no_run
//! use fast_tree::FastTree;
//! let keys = vec![1i32, 3, 5, 7, 9];
//! let tree = FastTree::new(&keys).unwrap();
//! assert_eq!(tree.search(5), Some(2));
//! assert_eq!(tree.search(0), None);
//! ```

use std::os::raw::c_void;

#[repr(C)]
struct FastTreeOpaque {
    _private: [u8; 0],
}

extern "C" {
    fn fast_create(keys: *const i32, n: usize) -> *mut FastTreeOpaque;
    fn fast_destroy(tree: *mut FastTreeOpaque);
    fn fast_search(tree: *const FastTreeOpaque, key: i32) -> i64;
    fn fast_search_lower_bound(tree: *const FastTreeOpaque, key: i32) -> i64;
    fn fast_size(tree: *const FastTreeOpaque) -> usize;
    fn fast_key_at(tree: *const FastTreeOpaque, index: usize) -> i32;
}

/// A FAST search tree wrapping the C library.
pub struct FastTree {
    ptr: *mut FastTreeOpaque,
}

// SAFETY: The underlying C library is thread-safe for read-only operations
// after construction.
unsafe impl Send for FastTree {}
unsafe impl Sync for FastTree {}

impl FastTree {
    /// Build a FAST tree from a sorted slice of 32-bit keys.
    pub fn new(keys: &[i32]) -> Option<Self> {
        if keys.is_empty() {
            return None;
        }
        let ptr = unsafe { fast_create(keys.as_ptr(), keys.len()) };
        if ptr.is_null() {
            None
        } else {
            Some(FastTree { ptr })
        }
    }

    /// Search for the largest key <= `key`. Returns the index or `None`.
    pub fn search(&self, key: i32) -> Option<usize> {
        let r = unsafe { fast_search(self.ptr, key) };
        if r < 0 { None } else { Some(r as usize) }
    }

    /// Find the first key >= `key`. Returns the index (may equal `size()`).
    pub fn lower_bound(&self, key: i32) -> usize {
        unsafe { fast_search_lower_bound(self.ptr, key) as usize }
    }

    /// Number of keys in the tree.
    pub fn size(&self) -> usize {
        unsafe { fast_size(self.ptr) }
    }

    /// Get the key at the given sorted index.
    pub fn key_at(&self, index: usize) -> i32 {
        unsafe { fast_key_at(self.ptr, index) }
    }
}

impl Drop for FastTree {
    fn drop(&mut self) {
        if !self.ptr.is_null() {
            unsafe { fast_destroy(self.ptr) };
        }
    }
}
