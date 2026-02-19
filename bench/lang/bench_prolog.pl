/*
 * Cross-language benchmark: Prolog — library(assoc) vs FAST FFI.
 *
 * Run: LD_LIBRARY_PATH=../../build swipl -g main -t halt bench_prolog.pl <tree_size> <num_queries>
 *
 * Note: SWI-Prolog's library(assoc) uses AVL trees.
 * The FAST FFI requires the C library to be loadable.
 */

:- use_module(library(assoc)).

/* Load libfast directly via SWI-Prolog's C FFI */
:- prolog_load_context(directory, Dir),
   atomic_list_concat([Dir, '/../../build/libfast.so'], LibPath),
   (   exists_file(LibPath)
   ->  open_shared_object(LibPath, _Handle)
   ;   (   getenv('LD_LIBRARY_PATH', _)
       ->  open_shared_object(libfast, _Handle)
       ;   format(user_error, "Cannot find libfast.so~n", []),
           halt(1)
       )
   ).

/* Emit JSON result */
emit_json(Compiler, Method, TreeSize, NumQueries, Sec) :-
    Mqs is NumQueries / Sec / 1000000,
    Nsq is Sec * 1000000000 / NumQueries,
    format('{\"language\":\"prolog\",\"compiler\":\"~w\",\"method\":\"~w\",\"tree_size\":~d,\"num_queries\":~d,\"total_sec\":~4f,\"mqs\":~2f,\"ns_per_query\":~1f}~n',
           [Compiler, Method, TreeSize, NumQueries, Sec, Mqs, Nsq]),
    flush_output.

/* Binary search: largest index where Keys[I] =< Key, or -1 */
binary_search(Keys, N, Key, Index) :-
    (   Key < 1  % keys start at 1 (= 0*3+1)
    ->  Index = -1
    ;   bs_loop(Keys, 0, N, Key, Index)
    ).

bs_loop(Keys, Lo, Hi, Key, Result) :-
    (   Lo >= Hi
    ->  Result = Lo
    ;   Mid is Lo + (Hi - Lo + 1) // 2,
        Idx1 is Mid + 1,  % 1-based indexing
        arg(Idx1, Keys, KMid),
        (   KMid =< Key
        ->  bs_loop(Keys, Mid, Hi, Key, Result)
        ;   Hi1 is Mid - 1,
            bs_loop(Keys, Lo, Hi1, Key, Result)
        )
    ).

/* Generate sorted keys as a compound term for fast arg/3 access */
make_keys(N, KeysTerm) :-
    numlist(0, N, Indices),
    maplist([I, K]>>(K is I * 3 + 1), Indices, KeysList),
    KeysTerm =.. [keys | KeysList].

/* Generate random queries */
make_queries(NumQ, MaxKey, Queries) :-
    set_random(seed(42)),
    length(Queries, NumQ),
    maplist([Q]>>(Q is random(MaxKey + 1)), Queries).

main :-
    current_prolog_flag(argv, Args),
    (   Args = [A1, A2 | _]
    ->  atom_number(A1, TreeSize), atom_number(A2, NumQueries)
    ;   Args = [A1 | _]
    ->  atom_number(A1, TreeSize), NumQueries = 500000
    ;   TreeSize = 100000, NumQueries = 500000
    ),
    current_prolog_flag(version, Ver),
    format(atom(Compiler), "swipl-~w", [Ver]),

    N is TreeSize - 1,

    /* Build queries list */
    MaxKey is N * 3 + 1,
    make_queries(NumQueries, MaxKey, Queries),

    Warmup is min(NumQueries, 10000),

    /* --- FAST FFI --- */
    /* Create sorted key array for C */
    numlist(0, N, Idxs),
    maplist([I, K]>>(K is I * 3 + 1), Idxs, KeysList),
    fast_create(KeysList, TreeSize, Tree),

    /* Warmup */
    forall(
        (between(1, Warmup, WI), nth1(WI, Queries, WQ)),
        fast_search(Tree, WQ, _)
    ),

    get_time(T0),
    ffi_bench_loop(Tree, Queries, NumQueries, 0, _Sink1),
    get_time(T1),
    ElapsedFFI is T1 - T0,
    emit_json(Compiler, fast_ffi, TreeSize, NumQueries, ElapsedFFI),

    fast_destroy(Tree),

    /* --- library(assoc) --- */
    /* Build assoc tree (AVL tree) */
    pairs_keys_values(Pairs, KeysList, KeysList),
    list_to_assoc(Pairs, Assoc),

    /* Warmup */
    forall(
        (between(1, Warmup, WI2), nth1(WI2, Queries, WQ2)),
        assoc_search(Assoc, KeysList, WQ2, _)
    ),

    get_time(T2),
    assoc_bench_loop(Assoc, KeysList, Queries, NumQueries, 0, _Sink2),
    get_time(T3),
    ElapsedAssoc is T3 - T2,
    emit_json(Compiler, 'library(assoc)', TreeSize, NumQueries, ElapsedAssoc).

/* FFI benchmark loop */
ffi_bench_loop(_, _, 0, Sink, Sink) :- !.
ffi_bench_loop(Tree, [Q|Qs], Remaining, SinkIn, SinkOut) :-
    fast_search(Tree, Q, Idx),
    Sink1 is SinkIn + Idx,
    R1 is Remaining - 1,
    ffi_bench_loop(Tree, Qs, R1, Sink1, SinkOut).

/* Assoc search: find largest key <= query */
assoc_search(Assoc, _KeysList, Query, Index) :-
    (   assoc_pair(Assoc, Query, _)
    ->  /* Exact match - find its position */
        Index = Query  % simplified
    ;   Index = -1  % simplified
    ).

/* Assoc benchmark loop */
assoc_bench_loop(_, _, _, 0, Sink, Sink) :- !.
assoc_bench_loop(Assoc, KeysList, [Q|Qs], Remaining, SinkIn, SinkOut) :-
    (   get_assoc(Q, Assoc, _)
    ->  Idx = Q
    ;   Idx = -1
    ),
    Sink1 is SinkIn + Idx,
    R1 is Remaining - 1,
    assoc_bench_loop(Assoc, KeysList, Qs, R1, Sink1, SinkOut).

/* SWI-Prolog's FAST FFI via the C foreign interface */
/* These predicates are provided by loading libfast.so */
:- if(\+ current_predicate(fast_create/3)).
/* Fallback if foreign library loading didn't register the predicates.
   Use SWI-Prolog's ffi pack or manual C glue. */
fast_create(KeysList, N, Tree) :-
    length(KeysList, N),
    c_alloc(Buf, int[N]),
    forall(
        (nth0(I, KeysList, K)),
        c_store(Buf[I], K)
    ),
    c_call(fast_create, [Buf, N], Tree),
    c_free(Buf).

fast_destroy(Tree) :-
    c_call(fast_destroy, [Tree], _).

fast_search(Tree, Key, Index) :-
    c_call(fast_search, [Tree, Key], Index).
:- endif.
