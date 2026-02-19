// Cross-language benchmark: Go — google/btree / sort.Search vs FAST FFI (cgo).
//
// google/btree is a widely-used in-memory B-tree for Go.
// sort.Search (binary search on sorted slice) is the stdlib approach.
//
// Build:
//   CGO_CFLAGS="-I../../include" CGO_LDFLAGS="-L../../build -lfast" \
//       go build -o bench_go bench_go.go

package main

/*
#cgo CFLAGS: -I../../include
#cgo LDFLAGS: -L../../build -lfast -Wl,-rpath,../../build
#include <fast.h>
#include <stdlib.h>
*/
import "C"

import (
	"fmt"
	"math/rand"
	"os"
	"runtime"
	"sort"
	"strconv"
	"time"
	"unsafe"

	"github.com/google/btree"
)

// Int32Item implements btree.Item for int32 keys with an associated index.
type Int32Item struct {
	Key   int32
	Value int64
}

func (a Int32Item) Less(b btree.Item) bool {
	return a.Key < b.(Int32Item).Key
}

func emitJSON(method string, treeSize, numQueries int, sec float64) {
	mqs := float64(numQueries) / sec / 1e6
	nsq := sec * 1e9 / float64(numQueries)
	goVer := runtime.Version()
	fmt.Printf(`{"language":"go","compiler":"%s","method":"%s",`+
		`"tree_size":%d,"num_queries":%d,`+
		`"total_sec":%.4f,"mqs":%.2f,"ns_per_query":%.1f}`+"\n",
		goVer, method, treeSize, numQueries, sec, mqs, nsq)
}

func main() {
	treeSize := 1000000
	numQueries := 5000000
	if len(os.Args) > 1 {
		if v, err := strconv.Atoi(os.Args[1]); err == nil {
			treeSize = v
		}
	}
	if len(os.Args) > 2 {
		if v, err := strconv.Atoi(os.Args[2]); err == nil {
			numQueries = v
		}
	}

	runtime.LockOSThread()

	// Generate sorted keys
	keys := make([]int32, treeSize)
	for i := range keys {
		keys[i] = int32(i*3 + 1)
	}
	maxKey := keys[treeSize-1]

	// Generate random queries
	rng := rand.New(rand.NewSource(42))
	queries := make([]int32, numQueries)
	for i := range queries {
		queries[i] = int32(rng.Intn(int(maxKey) + 1))
	}

	warmup := numQueries
	if warmup > 100000 {
		warmup = 100000
	}

	runtime.GC()

	// --- FAST FFI ---
	{
		tree := C.fast_create((*C.int32_t)(unsafe.Pointer(&keys[0])), C.size_t(treeSize))
		if tree == nil {
			fmt.Fprintln(os.Stderr, "fast_create failed")
			os.Exit(1)
		}

		var sink C.int64_t
		for i := 0; i < warmup; i++ {
			sink += C.fast_search(tree, C.int32_t(queries[i]))
		}

		t0 := time.Now()
		for i := 0; i < numQueries; i++ {
			sink += C.fast_search(tree, C.int32_t(queries[i]))
		}
		elapsed := time.Since(t0).Seconds()
		emitJSON("fast_ffi", treeSize, numQueries, elapsed)

		C.fast_destroy(tree)
		_ = sink
	}

	runtime.GC()

	// --- google/btree (B-tree, degree 32) ---
	{
		bt := btree.New(32)
		for i := 0; i < treeSize; i++ {
			bt.ReplaceOrInsert(Int32Item{Key: keys[i], Value: int64(i)})
		}

		var sink int64
		pivot := Int32Item{}

		// Warmup
		for i := 0; i < warmup; i++ {
			pivot.Key = queries[i]
			var found int64 = -1
			bt.DescendLessOrEqual(pivot, func(item btree.Item) bool {
				found = item.(Int32Item).Value
				return false // stop after first (largest <= query)
			})
			sink += found
		}

		t0 := time.Now()
		for i := 0; i < numQueries; i++ {
			pivot.Key = queries[i]
			var found int64 = -1
			bt.DescendLessOrEqual(pivot, func(item btree.Item) bool {
				found = item.(Int32Item).Value
				return false
			})
			sink += found
		}
		elapsed := time.Since(t0).Seconds()
		emitJSON("google/btree", treeSize, numQueries, elapsed)

		_ = sink
	}

	runtime.GC()

	// --- sort.Search (binary search on sorted slice) ---
	{
		var sink int64
		for i := 0; i < warmup; i++ {
			q := int(queries[i])
			idx := sort.Search(treeSize, func(j int) bool { return int(keys[j]) > q })
			idx--
			if idx < 0 {
				sink += -1
			} else {
				sink += int64(idx)
			}
		}

		t0 := time.Now()
		for i := 0; i < numQueries; i++ {
			q := int(queries[i])
			idx := sort.Search(treeSize, func(j int) bool { return int(keys[j]) > q })
			idx--
			if idx < 0 {
				sink += -1
			} else {
				sink += int64(idx)
			}
		}
		elapsed := time.Since(t0).Seconds()
		emitJSON("sort.Search", treeSize, numQueries, elapsed)

		_ = sink
	}
}
