(* OCaml bindings for the FAST search tree library.
 *
 * Build:
 *   ocamlfind ocamlopt -package ctypes,ctypes.foreign -linkpkg fast.ml -cclib -lfast
 *
 * Or with C stubs (see fast_stubs.c):
 *   ocamlfind ocamlopt fast_stubs.c fast.ml -cclib -lfast
 *
 * Usage:
 *   let tree = Fast.create [|1l; 3l; 5l; 7l; 9l|]
 *   let idx  = Fast.search tree 5l   (* returns 2L *)
 *   let ()   = Fast.destroy tree
 *)

type t  (* opaque C pointer *)

external create  : int32 array -> int -> t = "caml_fast_create"
external destroy : t -> unit = "caml_fast_destroy"
external search  : t -> int32 -> int64 = "caml_fast_search"
external search_lower_bound : t -> int32 -> int64 = "caml_fast_search_lower_bound"
external size    : t -> int = "caml_fast_size"
external key_at  : t -> int -> int32 = "caml_fast_key_at"

let create_from_list keys =
  let arr = Array.of_list keys in
  create arr (Array.length arr)
