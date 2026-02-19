;;;; Cross-language benchmark: Common Lisp — vector binary search vs FAST FFI (CFFI).
;;;;
;;;; Common Lisp does not include an ordered tree container in its standard.
;;;; Vector binary search is the standard approach. cl-containers (via
;;;; Quicklisp) provides red-black trees but is not widely deployed.
;;;;
;;;; Run with SBCL:
;;;;   sbcl --noinform --non-interactive --load bench_lisp.lisp
;;;; Run with CLISP:
;;;;   clisp bench_lisp.lisp <tree_size> <num_queries>

;;; Load CFFI
(handler-case (require :cffi)
  (error ()
    (handler-case (progn (require :asdf) (asdf:load-system :cffi))
      (error ()
        (format *error-output* "CFFI not available~%")
        (quit)))))

(defpackage #:bench
  (:use #:cl #:cffi))

(in-package #:bench)

;;; Load libfast
(define-foreign-library libfast
  (:unix "libfast.so")
  (:darwin "libfast.dylib")
  (t (:default "libfast")))

(handler-case (use-foreign-library libfast)
  (error (c) (format *error-output* "Cannot load libfast: ~a~%" c) (quit)))

(defcfun ("fast_create" %fast-create) :pointer
  (keys :pointer) (n :size))
(defcfun ("fast_destroy" %fast-destroy) :void
  (tree :pointer))
(defcfun ("fast_search" %fast-search) :int64
  (tree :pointer) (key :int32))

(defun emit-json (compiler method tree-size num-queries sec)
  (let ((mqs (/ num-queries sec 1d6))
        (nsq (/ (* sec 1d9) num-queries)))
    (format t "{\"language\":\"lisp\",\"compiler\":\"~a\",\"method\":\"~a\",\"tree_size\":~d,\"num_queries\":~d,\"total_sec\":~,4f,\"mqs\":~,2f,\"ns_per_query\":~,1f}~%"
            compiler method tree-size num-queries sec mqs nsq)
    (finish-output)))

(defun binary-search (keys n key)
  "Binary search: largest index where keys[i] <= key, or -1."
  (declare (type (simple-array (signed-byte 32) (*)) keys)
           (type fixnum n)
           (type (signed-byte 32) key)
           (optimize (speed 3) (safety 0)))
  (if (< key (aref keys 0))
      -1
      (let ((lo 0) (hi (1- n)))
        (declare (type fixnum lo hi))
        (loop while (< lo hi)
              do (let ((mid (+ lo (ceiling (- hi lo) 2))))
                   (if (<= (aref keys mid) key)
                       (setf lo mid)
                       (setf hi (1- mid)))))
        lo)))

(defun main ()
  (let* ((args #+sbcl (cdr sb-ext:*posix-argv*)
               #+clisp ext:*args*
               #-(or sbcl clisp) nil)
         (tree-size (if (>= (length args) 1) (parse-integer (first args)) 1000000))
         (num-queries (if (>= (length args) 2) (parse-integer (second args)) 1000000))
         (compiler #+sbcl (format nil "sbcl-~a" (lisp-implementation-version))
                   #+clisp (format nil "clisp-~a" (lisp-implementation-version))
                   #-(or sbcl clisp) "unknown-cl"))

    ;; Generate sorted keys
    (let ((keys (make-array tree-size :element-type '(signed-byte 32))))
      (dotimes (i tree-size)
        (setf (aref keys i) (+ (* i 3) 1)))
      (let* ((max-key (aref keys (1- tree-size)))
             ;; Generate random queries
             (queries (make-array num-queries :element-type '(signed-byte 32)))
             (rng-state 42))
        (dotimes (i num-queries)
          (setf rng-state (mod (+ (* rng-state 1103515245) 12345) 2147483648))
          (setf (aref queries i) (mod rng-state (1+ max-key))))

        (let ((warmup (min num-queries 10000)))

          ;; --- FAST FFI ---
          (with-foreign-object (buf :int32 tree-size)
            (dotimes (i tree-size)
              (setf (mem-aref buf :int32 i) (aref keys i)))
            (let ((tree (%fast-create buf tree-size)))
              (when (null-pointer-p tree)
                (format *error-output* "fast_create failed~%")
                (quit))

              ;; Warmup
              (dotimes (i warmup)
                (%fast-search tree (aref queries i)))

              (let* ((t0 (get-internal-real-time))
                     (sink 0))
                (declare (type fixnum sink))
                (dotimes (i num-queries)
                  (incf sink (%fast-search tree (aref queries i))))
                (let ((elapsed (/ (- (get-internal-real-time) t0)
                                  (float internal-time-units-per-second 1d0))))
                  (emit-json compiler "fast_ffi" tree-size num-queries elapsed))
                ;; prevent optimization
                (when (= sink most-negative-fixnum)
                  (format *error-output* "~d~%" sink)))

              (%fast-destroy tree)))

          ;; --- Binary search ---
          (dotimes (i warmup)
            (binary-search keys tree-size (aref queries i)))

          (let* ((t0 (get-internal-real-time))
                 (sink 0))
            (declare (type fixnum sink))
            (dotimes (i num-queries)
              (incf sink (binary-search keys tree-size (aref queries i))))
            (let ((elapsed (/ (- (get-internal-real-time) t0)
                              (float internal-time-units-per-second 1d0))))
              (emit-json compiler "vector-bsearch" tree-size num-queries elapsed))
            (when (= sink most-negative-fixnum)
              (format *error-output* "~d~%" sink))))))))

(main)
