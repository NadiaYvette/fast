;;; Scheme bindings for the FAST search tree library.
;;;
;;; For Chez Scheme. Usage:
;;;   (load "fast.scm")
;;;   (define tree (fast-create '#(1 3 5 7 9)))
;;;   (fast-search tree 5)    ; => 2
;;;   (fast-destroy tree)
;;;
;;; Run with: scheme --libdirs /path/to/libfast fast.scm

(library (fast)
  (export fast-create
          fast-destroy
          fast-search
          fast-search-lower-bound
          fast-size
          fast-key-at)
  (import (chezscheme))

  ;; Load the shared library
  (load-shared-object "libfast.so")

  ;; FFI declarations
  (define c-fast-create
    (foreign-procedure "fast_create"
      (u8* size_t) void*))

  (define c-fast-destroy
    (foreign-procedure "fast_destroy"
      (void*) void))

  (define c-fast-search
    (foreign-procedure "fast_search"
      (void* int) integer-64))

  (define c-fast-search-lower-bound
    (foreign-procedure "fast_search_lower_bound"
      (void* int) integer-64))

  (define c-fast-size
    (foreign-procedure "fast_size"
      (void*) size_t))

  (define c-fast-key-at
    (foreign-procedure "fast_key_at"
      (void* size_t) int))

  ;; Build a FAST tree from a vector of sorted int32 keys.
  (define (fast-create keys-vec)
    (let* ([n (vector-length keys-vec)]
           [bv (make-bytevector (* n 4))])
      ;; Pack keys into a bytevector as int32 little-endian
      (do ([i 0 (+ i 1)])
          ((= i n))
        (bytevector-s32-set! bv (* i 4) (vector-ref keys-vec i) (endianness little)))
      (c-fast-create bv n)))

  ;; Free the tree.
  (define (fast-destroy tree)
    (c-fast-destroy tree))

  ;; Search: return index of largest key <= query, or -1.
  (define (fast-search tree key)
    (c-fast-search tree key))

  ;; Lower bound: return index of first key >= query.
  (define (fast-search-lower-bound tree key)
    (c-fast-search-lower-bound tree key))

  ;; Number of keys.
  (define (fast-size tree)
    (c-fast-size tree))

  ;; Key at sorted index.
  (define (fast-key-at tree index)
    (c-fast-key-at tree index))
)
