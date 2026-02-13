;;;; Common Lisp bindings for the FAST search tree library.
;;;;
;;;; Requires CFFI: (ql:quickload :cffi)
;;;;
;;;; Usage:
;;;;   (ql:quickload :cffi)
;;;;   (load "fast.lisp")
;;;;   (defvar *tree* (fast:create #(1 3 5 7 9)))
;;;;   (fast:search *tree* 5)   ; => 2
;;;;   (fast:destroy *tree*)

(defpackage #:fast
  (:use #:cl #:cffi)
  (:export #:tree
           #:create
           #:destroy
           #:search
           #:search-lower-bound
           #:size
           #:key-at
           #:with-tree))

(in-package #:fast)

;;; Load the shared library
(define-foreign-library libfast
  (:unix "libfast.so")
  (:darwin "libfast.dylib")
  (t (:default "libfast")))

(use-foreign-library libfast)

;;; Opaque pointer type
(define-foreign-type tree-ptr :pointer)

;;; FFI function declarations
(defcfun ("fast_create" %create) :pointer
  (keys :pointer)
  (n :size))

(defcfun ("fast_destroy" %destroy) :void
  (tree :pointer))

(defcfun ("fast_search" %search) :int64
  (tree :pointer)
  (key :int32))

(defcfun ("fast_search_lower_bound" %search-lower-bound) :int64
  (tree :pointer)
  (key :int32))

(defcfun ("fast_size" %size) :size
  (tree :pointer))

(defcfun ("fast_key_at" %key-at) :int32
  (tree :pointer)
  (index :size))

;;; Wrapper type
(defstruct tree
  (ptr (null-pointer) :type foreign-pointer))

;;; Public API
(defun create (keys)
  "Build a FAST tree from a sorted vector of (signed-byte 32) keys."
  (let* ((n (length keys))
         (buf (foreign-alloc :int32 :count n)))
    (unwind-protect
         (progn
           (dotimes (i n)
             (setf (mem-aref buf :int32 i) (aref keys i)))
           (let ((ptr (%create buf n)))
             (if (null-pointer-p ptr)
                 (error "fast_create failed")
                 (make-tree :ptr ptr))))
      (foreign-free buf))))

(defun destroy (tree)
  "Free the FAST tree."
  (unless (null-pointer-p (tree-ptr tree))
    (%destroy (tree-ptr tree))
    (setf (tree-ptr tree) (null-pointer))))

(defun search (tree key)
  "Return index of largest key <= KEY, or -1."
  (%search (tree-ptr tree) key))

(defun search-lower-bound (tree key)
  "Return index of first key >= KEY."
  (%search-lower-bound (tree-ptr tree) key))

(defun size (tree)
  "Return number of keys."
  (%size (tree-ptr tree)))

(defun key-at (tree index)
  "Return key at sorted INDEX."
  (%key-at (tree-ptr tree) index))

(defmacro with-tree ((var keys) &body body)
  "Create a tree, bind it to VAR, execute BODY, then destroy it."
  `(let ((,var (create ,keys)))
     (unwind-protect (progn ,@body)
       (destroy ,var))))
