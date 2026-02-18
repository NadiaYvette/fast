#=
Julia bindings for the FAST (Fast Architecture Sensitive Tree) library.

Usage:
    include("Fast.jl")
    using .Fast
    tree = Fast.create(Int32[1, 3, 5, 7, 9])
    Fast.search(tree, Int32(5))    # returns 2
    Fast.search(tree, Int32(0))    # returns -1
    Fast.destroy(tree)

Or with do-block for automatic cleanup:
    Fast.with_tree(Int32[1, 3, 5, 7, 9]) do tree
        Fast.search(tree, Int32(5))
    end
=#

module Fast

# Locate the shared library
const LIBFAST = let
    candidates = [
        joinpath(@__DIR__, "..", "..", "build", "libfast.so"),
        joinpath(@__DIR__, "..", "..", "build", "libfast.dylib"),
        "libfast.so",
        "libfast",
    ]
    found = findfirst(isfile, candidates)
    found !== nothing ? candidates[found] : "libfast"
end

"""Opaque handle to a FAST tree."""
mutable struct Tree
    ptr::Ptr{Cvoid}
end

"""Build a FAST tree from a sorted vector of Int32 keys."""
function create(keys::Vector{Int32})
    ptr = ccall((:fast_create, LIBFAST), Ptr{Cvoid},
                (Ptr{Int32}, Csize_t),
                keys, length(keys))
    ptr == C_NULL && error("fast_create failed")
    return Tree(ptr)
end

"""Free the FAST tree."""
function destroy(tree::Tree)
    if tree.ptr != C_NULL
        ccall((:fast_destroy, LIBFAST), Cvoid, (Ptr{Cvoid},), tree.ptr)
        tree.ptr = C_NULL
    end
    nothing
end

"""Search: return index of largest key <= query, or -1."""
function search(tree::Tree, key::Int32)
    return ccall((:fast_search, LIBFAST), Int64,
                 (Ptr{Cvoid}, Int32),
                 tree.ptr, key)
end

"""Lower bound: return index of first key >= query."""
function lower_bound(tree::Tree, key::Int32)
    return ccall((:fast_search_lower_bound, LIBFAST), Int64,
                 (Ptr{Cvoid}, Int32),
                 tree.ptr, key)
end

"""Number of keys in the tree."""
function size(tree::Tree)
    return Int(ccall((:fast_size, LIBFAST), Csize_t,
                     (Ptr{Cvoid},), tree.ptr))
end

"""Key at the given sorted index."""
function key_at(tree::Tree, index::Integer)
    return ccall((:fast_key_at, LIBFAST), Int32,
                 (Ptr{Cvoid}, Csize_t),
                 tree.ptr, Csize_t(index))
end

"""Create a tree, pass it to f, then destroy it."""
function with_tree(f::Function, keys::Vector{Int32})
    tree = create(keys)
    try
        return f(tree)
    finally
        destroy(tree)
    end
end

end # module
