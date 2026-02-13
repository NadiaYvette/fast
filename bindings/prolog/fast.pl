/** <module> FAST search tree bindings for SWI-Prolog

Bindings for the FAST (Fast Architecture Sensitive Tree) library.

Usage:
==
    :- use_module(fast).
    ?- fast_create([1, 3, 5, 7, 9], Tree),
       fast_search(Tree, 5, Index),
       format("Index: ~w~n", [Index]),
       fast_destroy(Tree).
==

Load the shared library first:
==
    :- use_foreign_library(foreign(libfast)).
==

@author FAST bindings
*/

:- module(fast, [
    fast_create/2,
    fast_destroy/1,
    fast_search/3,
    fast_search_lower_bound/3,
    fast_size/2,
    fast_key_at/3
]).

:- use_foreign_library(foreign(libfast)).

%% fast_create(+Keys:list(integer), -Tree) is det.
%  Build a FAST tree from a sorted list of integer keys.
fast_create(Keys, Tree) :-
    length(Keys, N),
    fast_create_ffi(Keys, N, Tree).

%% fast_destroy(+Tree) is det.
%  Free the memory associated with a FAST tree.

%% fast_search(+Tree, +Key:integer, -Index:integer) is det.
%  Search for the largest key <= Key. Index is -1 if Key < all keys.

%% fast_search_lower_bound(+Tree, +Key:integer, -Index:integer) is det.
%  Find the first key >= Key.

%% fast_size(+Tree, -Size:integer) is det.
%  Get the number of keys in the tree.

%% fast_key_at(+Tree, +Index:integer, -Key:integer) is det.
%  Get the key at the given sorted index.

% These predicates would be implemented via SWI-Prolog's C foreign
% interface.  A C glue file (fast_pl.c) would register these predicates
% using PL_register_foreign().  The skeleton below shows the approach:
%
% In fast_pl.c:
%   static foreign_t pl_fast_create(term_t keys_t, term_t n_t, term_t tree_t) {
%       /* Convert Prolog list to C array, call fast_create,
%          return pointer as integer */
%   }
%   install_t install_fast() {
%       PL_register_foreign("fast_create_ffi", 3, pl_fast_create, 0);
%       PL_register_foreign("fast_destroy",    1, pl_fast_destroy, 0);
%       PL_register_foreign("fast_search",     3, pl_fast_search, 0);
%       ...
%   }
%
% For a simpler approach, use SWI-Prolog's built-in C FFI via ffi_call/3:

:- if(current_prolog_flag(bounded, false)).  % Check for SWI-Prolog

fast_create_ffi(Keys, N, Tree) :-
    % Allocate C array, copy keys, call fast_create
    % This is a placeholder for the actual FFI implementation
    throw(error(existence_error(procedure, fast_create_ffi/3),
                context(fast, 'Requires C glue code - see fast_pl.c'))).

:- endif.
