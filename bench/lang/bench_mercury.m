%---------------------------------------------------------------------------%
% Cross-language benchmark: Mercury — tree234 (2-3-4 tree) vs FAST FFI.
%
% Mercury's standard library tree234 module provides a 2-3-4 tree
% (equivalent to a red-black tree) with lower_bound_search, which is
% the natural comparison target for FAST's search operation.
%
% Compile:
%   mmc --make --grade hlc.gc \
%       --c-include-directory ../../include \
%       --ld-flags "-L../../build -lfast -Wl,-rpath,../../build" \
%       bench_mercury
%
% Run:
%   ./bench_mercury <tree_size> <num_queries>
%---------------------------------------------------------------------------%

:- module bench_mercury.
:- interface.
:- import_module io.

:- pred main(io::di, io::uo) is det.

:- implementation.

:- import_module int, float, string, list, pair.
:- import_module tree234.

:- pragma foreign_decl("C", "
#include ""fast.h""
#include <stdlib.h>
#include <time.h>
").

:- type fast_tree.
:- pragma foreign_type("C", fast_tree, "fast_tree_t *").

:- pred fast_create_raw(int::in, c_pointer::in, fast_tree::out,
    io::di, io::uo) is det.
:- pragma foreign_proc("C",
    fast_create_raw(N::in, Buf::in, Tree::out, _IO0::di, _IO::uo),
    [will_not_call_mercury, promise_pure, thread_safe],
"
    Tree = fast_create((const int32_t *)Buf, (size_t)N);
").

:- pred fast_destroy(fast_tree::in, io::di, io::uo) is det.
:- pragma foreign_proc("C",
    fast_destroy(Tree::in, _IO0::di, _IO::uo),
    [will_not_call_mercury, promise_pure, thread_safe],
"
    fast_destroy(Tree);
").

:- pred fast_search(fast_tree::in, int::in, int::out,
    io::di, io::uo) is det.
:- pragma foreign_proc("C",
    fast_search(Tree::in, Key::in, Result::out, _IO0::di, _IO::uo),
    [will_not_call_mercury, promise_pure, thread_safe],
"
    Result = (MR_Integer)fast_search(Tree, (int32_t)Key);
").

:- pred alloc_keys(int::in, c_pointer::out, io::di, io::uo) is det.
:- pragma foreign_proc("C",
    alloc_keys(N::in, Buf::out, _IO0::di, _IO::uo),
    [will_not_call_mercury, promise_pure],
"
    int32_t *b = malloc(N * sizeof(int32_t));
    for (int i = 0; i < N; i++) b[i] = i * 3 + 1;
    Buf = (MR_Word)b;
").

:- pred free_buf(c_pointer::in, io::di, io::uo) is det.
:- pragma foreign_proc("C",
    free_buf(Buf::in, _IO0::di, _IO::uo),
    [will_not_call_mercury, promise_pure],
"
    free((void *)Buf);
").

:- pred get_time(float::out, io::di, io::uo) is det.
:- pragma foreign_proc("C",
    get_time(T::out, _IO0::di, _IO::uo),
    [will_not_call_mercury, promise_pure],
"
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    T = (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
").

:- pred emit_json(string::in, string::in, int::in, int::in, float::in,
    io::di, io::uo) is det.
emit_json(Compiler, Method, TreeSize, NumQueries, Sec, !IO) :-
    Mqs = float(NumQueries) / Sec / 1.0e6,
    Nsq = Sec * 1.0e9 / float(NumQueries),
    io.format(
        "{\"language\":\"mercury\",\"compiler\":\"%s\",\"method\":\"%s\",\"tree_size\":%d,\"num_queries\":%d,\"total_sec\":%.4f,\"mqs\":%.2f,\"ns_per_query\":%.1f}\n",
        [s(Compiler), s(Method), i(TreeSize), i(NumQueries),
         f(Sec), f(Mqs), f(Nsq)], !IO),
    io.flush_output(!IO).

:- pred bench_fast_loop(fast_tree::in, list(int)::in, int::in, int::out,
    io::di, io::uo) is det.
bench_fast_loop(_, [], Sink, Sink, !IO).
bench_fast_loop(Tree, [Q | Qs], SinkIn, SinkOut, !IO) :-
    fast_search(Tree, Q, Idx, !IO),
    Sink1 = SinkIn + Idx,
    bench_fast_loop(Tree, Qs, Sink1, SinkOut, !IO).

:- pred bench_tree234_loop(tree234(int, int)::in, list(int)::in,
    int::in, int::out, io::di, io::uo) is det.
bench_tree234_loop(_, [], Sink, Sink, !IO).
bench_tree234_loop(Tree, [Q | Qs], SinkIn, SinkOut, !IO) :-
    ( if tree234.lower_bound_search(Tree, Q, _, Idx) then
        Sink1 = SinkIn + Idx
    else
        Sink1 = SinkIn + (-1)
    ),
    bench_tree234_loop(Tree, Qs, Sink1, SinkOut, !IO).

:- pred make_queries(int::in, int::in, int::in, list(int)::out) is det.
make_queries(N, MaxKey, SeedIn, Qs) :-
    make_queries_acc(N, MaxKey, SeedIn, [], QsRev),
    list.reverse(QsRev, Qs).

:- pred make_queries_acc(int::in, int::in, int::in,
    list(int)::in, list(int)::out) is det.
make_queries_acc(N, MaxKey, SeedIn, Acc, Qs) :-
    ( if N =< 0 then
        Qs = Acc
    else
        Seed1 = (SeedIn * 1103515245 + 12345) mod 2147483648,
        Q = Seed1 mod (MaxKey + 1),
        make_queries_acc(N - 1, MaxKey, Seed1, [Q | Acc], Qs)
    ).

main(!IO) :-
    io.command_line_arguments(Args, !IO),
    ( Args = [A1, A2 | _] ->
        TreeSize = string.det_to_int(A1),
        NumQueries = string.det_to_int(A2)
    ; Args = [A1 | _] ->
        TreeSize = string.det_to_int(A1),
        NumQueries = 500000
    ;
        TreeSize = 100000,
        NumQueries = 500000
    ),

    MaxKey = (TreeSize - 1) * 3 + 1,
    make_queries(NumQueries, MaxKey, 42, Queries),

    Warmup = int.min(NumQueries, 10000),
    list.det_split_list(Warmup, Queries, WarmupQs, _),

    % --- FAST FFI ---
    alloc_keys(TreeSize, Buf, !IO),
    fast_create_raw(TreeSize, Buf, Tree, !IO),
    free_buf(Buf, !IO),

    bench_fast_loop(Tree, WarmupQs, 0, _, !IO),

    get_time(T0, !IO),
    bench_fast_loop(Tree, Queries, 0, _, !IO),
    get_time(T1, !IO),
    ElapsedFFI = T1 - T0,
    emit_json("mmc", "fast_ffi", TreeSize, NumQueries, ElapsedFFI, !IO),

    fast_destroy(Tree, !IO),

    % --- tree234 (2-3-4 tree from Mercury standard library) ---
    % Build tree from sorted association list: [(key1 - idx1), ...]
    AssocList = list.map(
        func(I) = (I * 3 + 1) - I,
        0 `..` (TreeSize - 1)
    ),
    tree234.from_sorted_assoc_list(AssocList, Tree234),

    % Warmup
    bench_tree234_loop(Tree234, WarmupQs, 0, _, !IO),

    get_time(T2, !IO),
    bench_tree234_loop(Tree234, Queries, 0, _, !IO),
    get_time(T3, !IO),
    ElapsedNative = T3 - T2,
    emit_json("mmc", "tree234", TreeSize, NumQueries, ElapsedNative, !IO).
