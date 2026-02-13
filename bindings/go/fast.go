// Package fast provides Go bindings for the FAST search tree library.
//
// Usage:
//
//	keys := []int32{1, 3, 5, 7, 9}
//	tree, err := fast.New(keys)
//	if err != nil { log.Fatal(err) }
//	defer tree.Close()
//	idx := tree.Search(5)  // returns 2
package fast

/*
#cgo LDFLAGS: -lfast
#cgo CFLAGS: -I${SRCDIR}/../../include
#include <fast.h>
#include <stdlib.h>
*/
import "C"
import (
	"fmt"
	"runtime"
	"unsafe"
)

// Tree is a FAST search tree.
type Tree struct {
	ptr *C.fast_tree_t
}

// New builds a FAST tree from a sorted slice of int32 keys.
func New(keys []int32) (*Tree, error) {
	if len(keys) == 0 {
		return nil, fmt.Errorf("fast: keys must not be empty")
	}
	ptr := C.fast_create((*C.int32_t)(unsafe.Pointer(&keys[0])), C.size_t(len(keys)))
	if ptr == nil {
		return nil, fmt.Errorf("fast: fast_create failed")
	}
	t := &Tree{ptr: ptr}
	runtime.SetFinalizer(t, (*Tree).Close)
	return t, nil
}

// Close releases the tree's resources.
func (t *Tree) Close() {
	if t.ptr != nil {
		C.fast_destroy(t.ptr)
		t.ptr = nil
	}
}

// Search returns the index of the largest key <= query, or -1.
func (t *Tree) Search(key int32) int64 {
	return int64(C.fast_search(t.ptr, C.int32_t(key)))
}

// LowerBound returns the index of the first key >= query.
func (t *Tree) LowerBound(key int32) int64 {
	return int64(C.fast_search_lower_bound(t.ptr, C.int32_t(key)))
}

// Size returns the number of keys in the tree.
func (t *Tree) Size() int {
	return int(C.fast_size(t.ptr))
}

// KeyAt returns the key at the given sorted index.
func (t *Tree) KeyAt(index int) int32 {
	return int32(C.fast_key_at(t.ptr, C.size_t(index)))
}
