(* Standard ML bindings for the FAST search tree library.
 *
 * For use with MLton. Compile with:
 *   mlton -link-opt "-lfast" program.mlb
 *
 * Usage:
 *   val tree = Fast.create [1, 3, 5, 7, 9]
 *   val idx  = Fast.search (tree, 5)   (* returns 2 *)
 *   val _    = Fast.destroy tree
 *)

structure Fast :> sig
    type tree
    val create  : Int32.int list -> tree
    val destroy : tree -> unit
    val search  : tree * Int32.int -> Int64.int
    val searchLowerBound : tree * Int32.int -> Int64.int
    val size    : tree -> int
    val keyAt   : tree * int -> Int32.int
end = struct

    type tree = MLton.Pointer.t

    val c_create = _import "fast_create" public : Int32.int array * Word64.word -> MLton.Pointer.t;
    val c_destroy = _import "fast_destroy" public : MLton.Pointer.t -> unit;
    val c_search = _import "fast_search" public : MLton.Pointer.t * Int32.int -> Int64.int;
    val c_search_lower_bound = _import "fast_search_lower_bound" public : MLton.Pointer.t * Int32.int -> Int64.int;
    val c_size = _import "fast_size" public : MLton.Pointer.t -> Word64.word;
    val c_key_at = _import "fast_key_at" public : MLton.Pointer.t * Word64.word -> Int32.int;

    fun create keys =
        let
            val arr = Array.fromList keys
            val n = Word64.fromInt (Array.length arr)
        in
            c_create (arr, n)
        end

    fun destroy tree = c_destroy tree

    fun search (tree, key) = c_search (tree, key)

    fun searchLowerBound (tree, key) = c_search_lower_bound (tree, key)

    fun size tree = Word64.toInt (c_size tree)

    fun keyAt (tree, idx) = c_key_at (tree, Word64.fromInt idx)
end
