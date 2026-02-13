%---------------------------------------------------------------------------%
% Mercury bindings for the FAST search tree library.
%
% Usage:
%   :- import_module fast.
%   main(!IO) :-
%       fast.create([1, 3, 5, 7, 9], Tree, !IO),
%       fast.search(Tree, 5, Index, !IO),
%       fast.destroy(Tree, !IO).
%
% Compile with: mmc --make --link-flags "-lfast" program.m
%---------------------------------------------------------------------------%

:- module fast.
:- interface.

:- import_module io, list, int.

:- type fast_tree.

:- pred create(list(int)::in, fast_tree::out, io::di, io::uo) is det.
:- pred destroy(fast_tree::in, io::di, io::uo) is det.
:- pred search(fast_tree::in, int::in, int::out, io::di, io::uo) is det.
:- pred search_lower_bound(fast_tree::in, int::in, int::out,
    io::di, io::uo) is det.
:- pred size(fast_tree::in, int::out, io::di, io::uo) is det.

:- implementation.

:- import_module require.

:- pragma foreign_type("C", fast_tree, "fast_tree_t *").

:- pragma foreign_decl("C", "
#include \"fast.h\"
#include <stdlib.h>
").

:- pred create_ffi(int::in, c_pointer::in, fast_tree::out,
    io::di, io::uo) is det.
:- pragma foreign_proc("C",
    create_ffi(N::in, Buf::in, Tree::out, _IO0::di, _IO::uo),
    [will_not_call_mercury, promise_pure, thread_safe],
"
    Tree = fast_create((const int32_t *)Buf, (size_t)N);
").

create(Keys, Tree, !IO) :-
    list.length(Keys, N),
    % Allocate a C array and copy keys
    create_c_array(Keys, N, Buf, !IO),
    create_ffi(N, Buf, Tree, !IO),
    free_c_array(Buf, !IO).

:- pred create_c_array(list(int)::in, int::in, c_pointer::out,
    io::di, io::uo) is det.
:- pragma foreign_proc("C",
    create_c_array(Keys::in, N::in, Buf::out, _IO0::di, _IO::uo),
    [will_not_call_mercury, promise_pure],
"
    Buf = (MR_Word)malloc(N * sizeof(int32_t));
").

:- pred free_c_array(c_pointer::in, io::di, io::uo) is det.
:- pragma foreign_proc("C",
    free_c_array(Buf::in, _IO0::di, _IO::uo),
    [will_not_call_mercury, promise_pure],
"
    free((void *)Buf);
").

:- pragma foreign_proc("C",
    destroy(Tree::in, _IO0::di, _IO::uo),
    [will_not_call_mercury, promise_pure, thread_safe],
"
    fast_destroy(Tree);
").

:- pragma foreign_proc("C",
    search(Tree::in, Key::in, Result::out, _IO0::di, _IO::uo),
    [will_not_call_mercury, promise_pure, thread_safe],
"
    Result = (MR_Integer)fast_search(Tree, (int32_t)Key);
").

:- pragma foreign_proc("C",
    search_lower_bound(Tree::in, Key::in, Result::out, _IO0::di, _IO::uo),
    [will_not_call_mercury, promise_pure, thread_safe],
"
    Result = (MR_Integer)fast_search_lower_bound(Tree, (int32_t)Key);
").

:- pragma foreign_proc("C",
    size(Tree::in, N::out, _IO0::di, _IO::uo),
    [will_not_call_mercury, promise_pure, thread_safe],
"
    N = (MR_Integer)fast_size(Tree);
").
