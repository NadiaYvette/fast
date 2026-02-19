(* Cross-language benchmark: OCaml — Array binary search vs FAST FFI.

   Compile:
     ocamlfind ocamlopt -package unix -linkpkg \
         ../../bindings/ocaml/fast_stubs.c bench_ocaml.ml \
         -cclib "-L../../build -lfast -Wl,-rpath,../../build" \
         -ccopt "-I../../include" -o bench_ocaml
*)

(* Opaque type for FAST tree pointer (matches C stubs) *)
type fast_tree

(* Import from C stubs (fast_stubs.c) *)
external fast_create : int32 array -> int -> fast_tree = "caml_fast_create"
external fast_destroy : fast_tree -> unit = "caml_fast_destroy"
external fast_search : fast_tree -> int32 -> int64 = "caml_fast_search"

let emit_json meth tree_size num_queries sec =
  let mqs = float_of_int num_queries /. sec /. 1e6 in
  let nsq = sec *. 1e9 /. float_of_int num_queries in
  Printf.printf
    "{\"language\":\"ocaml\",\"compiler\":\"ocaml-%s\",\"method\":\"%s\",\"tree_size\":%d,\"num_queries\":%d,\"total_sec\":%.4f,\"mqs\":%.2f,\"ns_per_query\":%.1f}\n"
    Sys.ocaml_version meth tree_size num_queries sec mqs nsq;
  flush stdout

module Int32Map = Map.Make(Int32)

let binary_search (keys : int32 array) (n : int) (key : int32) : int64 =
  if key < keys.(0) then Int64.minus_one
  else begin
    let lo = ref 0 in
    let hi = ref (n - 1) in
    while !lo < !hi do
      let mid = !lo + (!hi - !lo + 1) / 2 in
      if keys.(mid) <= key then lo := mid
      else hi := mid - 1
    done;
    Int64.of_int !lo
  end

let () =
  let tree_size = if Array.length Sys.argv > 1 then int_of_string Sys.argv.(1) else 1_000_000 in
  let num_queries = if Array.length Sys.argv > 2 then int_of_string Sys.argv.(2) else 5_000_000 in

  (* Generate sorted keys *)
  let keys = Array.init tree_size (fun i -> Int32.of_int (i * 3 + 1)) in
  let max_key = Int32.to_int keys.(tree_size - 1) in

  (* Generate random queries *)
  Random.init 42;
  let queries = Array.init num_queries (fun _ -> Int32.of_int (Random.int (max_key + 1))) in

  let warmup = min num_queries 100_000 in

  (* --- FAST FFI --- *)
  let tree = fast_create keys tree_size in
  let sink = ref 0L in
  for i = 0 to warmup - 1 do
    sink := Int64.add !sink (fast_search tree queries.(i))
  done;

  let t0 = Unix.gettimeofday () in
  for i = 0 to num_queries - 1 do
    sink := Int64.add !sink (fast_search tree queries.(i))
  done;
  let elapsed = Unix.gettimeofday () -. t0 in
  emit_json "fast_ffi" tree_size num_queries elapsed;

  fast_destroy tree;

  (* --- Map (AVL tree, stdlib) --- *)
  let m = ref Int32Map.empty in
  for i = 0 to tree_size - 1 do
    m := Int32Map.add keys.(i) (Int64.of_int i) !m
  done;
  let the_map = !m in

  for i = 0 to warmup - 1 do
    let result = match Int32Map.find_last_opt (fun k -> k <= queries.(i)) the_map with
      | Some (_, v) -> v
      | None -> Int64.minus_one
    in
    sink := Int64.add !sink result
  done;

  let t0 = Unix.gettimeofday () in
  for i = 0 to num_queries - 1 do
    let result = match Int32Map.find_last_opt (fun k -> k <= queries.(i)) the_map with
      | Some (_, v) -> v
      | None -> Int64.minus_one
    in
    sink := Int64.add !sink result
  done;
  let elapsed = Unix.gettimeofday () -. t0 in
  emit_json "Map" tree_size num_queries elapsed;

  (* Prevent optimization *)
  if !sink = Int64.min_int then
    Printf.eprintf "%Ld\n" !sink
