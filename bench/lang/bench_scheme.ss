;;; Cross-language benchmark: Chez Scheme — vector binary search vs FAST FFI.
;;;
;;; Chez Scheme's standard library does not include ordered tree containers.
;;; We compare FAST FFI (via foreign-procedure) against binary search on a
;;; sorted Scheme vector.
;;;
;;; Run:
;;;   scheme --script bench_scheme.ss <tree_size> <num_queries>

(import (chezscheme))

;;; Load libfast
(let ([script-dir (or (and (top-level-bound? 'source-directories)
                           (pair? (source-directories))
                           (car (source-directories)))
                      ".")])
  (let ([lib-path (string-append script-dir "/../../build/libfast.so")])
    (if (file-exists? lib-path)
        (load-shared-object lib-path)
        (load-shared-object "libfast.so"))))

;;; FFI declarations
(define fast-create
  (foreign-procedure "fast_create" (void* size_t) void*))
(define fast-destroy
  (foreign-procedure "fast_destroy" (void*) void))
(define fast-search
  (foreign-procedure "fast_search" (void* integer-32) integer-64))

;;; Emit JSON result
(define (emit-json compiler method tree-size num-queries sec)
  (let ([mqs (/ (inexact num-queries) sec 1e6)]
        [nsq (/ (* sec 1e9) (inexact num-queries))])
    (printf "{\"language\":\"scheme\",\"compiler\":\"~a\",\"method\":\"~a\",\"tree_size\":~d,\"num_queries\":~d,\"total_sec\":~,4f,\"mqs\":~,2f,\"ns_per_query\":~,1f}\n"
            compiler method tree-size num-queries sec mqs nsq)
    (flush-output-port (current-output-port))))

;;; Binary search: largest index where keys[i] <= key, or -1
(define (binary-search keys n key)
  (if (fx< key (bytevector-s32-native-ref keys 0))
      -1
      (let loop ([lo 0] [hi (fx- n 1)])
        (if (fx>= lo hi)
            lo
            (let ([mid (fx+ lo (fxsra (fx+ (fx- hi lo) 1) 1))])
              (if (fx<= (bytevector-s32-native-ref keys (fx* mid 4)) key)
                  (loop mid hi)
                  (loop lo (fx- mid 1))))))))

;;; High-resolution timing
(define (current-time-ns)
  (let ([t (current-time 'time-monotonic)])
    (+ (* (time-second t) 1000000000)
       (time-nanosecond t))))

;;; Main
(let* ([args (command-line-arguments)]
       [tree-size (if (>= (length args) 1) (string->number (car args)) 1000000)]
       [num-queries (if (>= (length args) 2) (string->number (cadr args)) 5000000)]
       [compiler (let-values ([(major minor patch) (scheme-version-number)])
                   (format "chez-~a.~a.~a" major minor patch))])

  ;; Generate sorted keys as a bytevector of int32 (native endian)
  (let ([keys-bv (make-bytevector (* tree-size 4))])
    (do ([i 0 (fx+ i 1)])
        ((fx= i tree-size))
      (bytevector-s32-native-set! keys-bv (fx* i 4) (fx+ (fx* i 3) 1)))

    (let ([max-key (bytevector-s32-native-ref keys-bv (fx* (fx- tree-size 1) 4))])

      ;; Generate random queries as a vector of fixnums
      (random-seed 42)
      (let ([queries (make-vector num-queries)])
        (do ([i 0 (fx+ i 1)])
            ((fx= i num-queries))
          (vector-set! queries i (random (fx+ max-key 1))))

        (let ([warmup (min num-queries 100000)]
              [sink 0])

          ;; --- FAST FFI ---
          ;; Need to copy keys into a foreign-alloc'd u32 buffer for FFI
          (let ([ffi-buf (foreign-alloc (* tree-size 4))])
            (do ([i 0 (fx+ i 1)])
                ((fx= i tree-size))
              (foreign-set! 'integer-32 ffi-buf (fx* i 4)
                           (bytevector-s32-native-ref keys-bv (fx* i 4))))

            (let ([tree (fast-create ffi-buf tree-size)])
              ;; Warmup
              (do ([i 0 (fx+ i 1)])
                  ((fx= i warmup))
                (set! sink (+ sink (fast-search tree (vector-ref queries i)))))

              (let ([t0 (current-time-ns)])
                (do ([i 0 (fx+ i 1)])
                    ((fx= i num-queries))
                  (set! sink (+ sink (fast-search tree (vector-ref queries i)))))
                (let ([elapsed (/ (- (current-time-ns) t0) 1e9)])
                  (emit-json compiler "fast_ffi" tree-size num-queries elapsed)))

              (fast-destroy tree)
              (foreign-free ffi-buf)))

          ;; --- Vector binary search ---
          ;; Warmup
          (do ([i 0 (fx+ i 1)])
              ((fx= i warmup))
            (set! sink (+ sink (binary-search keys-bv tree-size
                                              (vector-ref queries i)))))

          (let ([t0 (current-time-ns)])
            (do ([i 0 (fx+ i 1)])
                ((fx= i num-queries))
              (set! sink (+ sink (binary-search keys-bv tree-size
                                                (vector-ref queries i)))))
            (let ([elapsed (/ (- (current-time-ns) t0) 1e9)])
              (emit-json compiler "binary_search" tree-size num-queries elapsed)))

          ;; Prevent optimization
          (when (= sink (least-fixnum))
            (display sink (current-error-port))))))))
