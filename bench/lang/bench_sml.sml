(* Cross-language benchmark: Standard ML — Array binary search vs FAST FFI.
 *
 * The SML Basis Library does not include ordered tree containers.
 * Array binary search is the standard approach. MLton's extended
 * libraries do not provide a tree-based ordered container either.
 *
 * Compile with MLton:
 *   mlton -output bench_sml -link-opt "-L../../build -lfast -Wl,-rpath,../../build" bench_sml.mlb
 *)

val c_fast_create = _import "fast_create" public : Int32.int array * Word64.word -> MLton.Pointer.t;
val c_fast_destroy = _import "fast_destroy" public : MLton.Pointer.t -> unit;
val c_fast_search = _import "fast_search" public : MLton.Pointer.t * Int32.int -> Int64.int;

fun emitJSON compiler method treeSize numQueries sec =
    let
        val mqs = Real.fromLargeInt (IntInf.fromInt numQueries) / sec / 1e6
        val nsq = sec * 1e9 / Real.fromLargeInt (IntInf.fromInt numQueries)
    in
        print (concat [
            "{\"language\":\"sml\",\"compiler\":\"", compiler,
            "\",\"method\":\"", method,
            "\",\"tree_size\":", Int.toString treeSize,
            ",\"num_queries\":", Int.toString numQueries,
            ",\"total_sec\":", Real.fmt (StringCvt.FIX (SOME 4)) sec,
            ",\"mqs\":", Real.fmt (StringCvt.FIX (SOME 2)) mqs,
            ",\"ns_per_query\":", Real.fmt (StringCvt.FIX (SOME 1)) nsq,
            "}\n"
        ])
    end

fun binarySearch (keys : Int32.int array) (n : int) (key : Int32.int) : Int64.int =
    if key < Array.sub (keys, 0) then ~1 : Int64.int
    else
        let
            val lo = ref 0
            val hi = ref (n - 1)
        in
            while !lo < !hi do
                let val mid = !lo + (!hi - !lo + 1) div 2
                in
                    if Array.sub (keys, mid) <= key then lo := mid
                    else hi := mid - 1
                end;
            Int64.fromInt (!lo)
        end

fun main () =
    let
        val args = CommandLine.arguments ()
        val treeSize = case args of (s :: _) => valOf (Int.fromString s) | _ => 1000000
        val numQueries = case args of (_ :: s :: _) => valOf (Int.fromString s) | _ => 5000000

        (* Generate sorted keys *)
        val keys = Array.tabulate (treeSize, fn i => Int32.fromInt (i * 3 + 1))
        val maxKey = Int32.toInt (Array.sub (keys, treeSize - 1))

        (* Generate random queries (simple LCG) *)
        val rngState = ref (Word64.fromInt 42)
        fun nextRand () =
            let
                val s = Word64.+ (Word64.* (!rngState, 0w6364136223846793005), 0w1442695040888963407)
                val _ = rngState := s
            in
                Int32.fromInt (Word64.toInt (Word64.mod (Word64.>> (s, 0w33), Word64.fromInt (maxKey + 1))))
            end
        val queries = Array.tabulate (numQueries, fn _ => nextRand ())

        val warmup = Int.min (numQueries, 100000)
        val sink = ref (0 : Int64.int)

        (* --- FAST FFI --- *)
        val treePtr = c_fast_create (keys, Word64.fromInt treeSize)
        val _ =
            let val i = ref 0
            in while !i < warmup do (
                sink := Int64.+ (!sink, c_fast_search (treePtr, Array.sub (queries, !i)));
                i := !i + 1
            ) end

        val timer = Timer.startRealTimer ()
        val _ =
            let val i = ref 0
            in while !i < numQueries do (
                sink := Int64.+ (!sink, c_fast_search (treePtr, Array.sub (queries, !i)));
                i := !i + 1
            ) end
        val elapsed = Time.toReal (Timer.checkRealTimer timer)
        val _ = emitJSON "mlton" "fast_ffi" treeSize numQueries elapsed
        val _ = c_fast_destroy treePtr

        (* --- Binary search --- *)
        val _ =
            let val i = ref 0
            in while !i < warmup do (
                sink := Int64.+ (!sink, binarySearch keys treeSize (Array.sub (queries, !i)));
                i := !i + 1
            ) end

        val timer = Timer.startRealTimer ()
        val _ =
            let val i = ref 0
            in while !i < numQueries do (
                sink := Int64.+ (!sink, binarySearch keys treeSize (Array.sub (queries, !i)));
                i := !i + 1
            ) end
        val elapsed = Time.toReal (Timer.checkRealTimer timer)
        val _ = emitJSON "mlton" "Array.bsearch" treeSize numQueries elapsed
    in
        ()
    end

val _ = main ()
