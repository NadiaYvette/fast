#!/usr/bin/env julia
# Cross-language benchmark: Julia — searchsortedfirst vs FAST FFI (ccall).
#
# Julia's standard library does not include an ordered tree container.
# searchsortedfirst (binary search on sorted Vector) is the standard
# approach. For a tree-based comparison, DataStructures.jl provides
# SortedDict backed by a 2-3 tree (Pkg.add("DataStructures")).
#
# Run: julia bench_julia.jl <tree_size> <num_queries>

using Printf

# Locate libfast.so
const LIBFAST = let
    candidates = [
        joinpath(@__DIR__, "..", "..", "build", "libfast.so"),
        joinpath(@__DIR__, "..", "..", "build", "libfast.dylib"),
        "libfast.so",
    ]
    found = findfirst(isfile, candidates)
    found !== nothing ? candidates[found] : "libfast"
end

function emit_json(method::String, tree_size::Int, num_queries::Int, sec::Float64)
    mqs = num_queries / sec / 1e6
    nsq = sec * 1e9 / num_queries
    ver = string("julia-", VERSION)
    @printf("{\"language\":\"julia\",\"compiler\":\"%s\",\"method\":\"%s\",\"tree_size\":%d,\"num_queries\":%d,\"total_sec\":%.4f,\"mqs\":%.2f,\"ns_per_query\":%.1f}\n",
            ver, method, tree_size, num_queries, sec, mqs, nsq)
    flush(stdout)
end

function fast_search_bench(tree_ptr::Ptr{Cvoid}, key::Int32)::Int64
    ccall((:fast_search, LIBFAST), Int64, (Ptr{Cvoid}, Int32), tree_ptr, key)
end

function native_search(keys::Vector{Int32}, key::Int32)::Int64
    # searchsortedfirst is Julia's standard library binary search
    idx = searchsortedfirst(keys, key)
    if idx > length(keys)
        return Int64(length(keys) - 1)
    elseif keys[idx] == key
        return Int64(idx - 1)  # 0-based
    elseif idx == 1
        return Int64(-1)
    else
        return Int64(idx - 2)  # 0-based, largest key <= query
    end
end

# Note: Julia's standard library does not include a tree-based ordered
# container. searchsortedfirst (binary search on sorted Vector) is the
# standard approach. For a tree-based comparison, one would need
# DataStructures.jl (SortedDict), but we benchmark only stdlib here.

function main()
    tree_size = length(ARGS) >= 1 ? parse(Int, ARGS[1]) : 1_000_000
    num_queries = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : 5_000_000

    # Generate sorted keys
    keys = Int32[i * 3 + 1 for i in 0:tree_size-1]
    max_key = keys[end]

    # Generate random queries
    rng = Xoshiro(42)
    queries = Int32[rand(rng, Int32(0):max_key) for _ in 1:num_queries]

    warmup = min(num_queries, 100_000)

    # --- FAST FFI ---
    tree_ptr = ccall((:fast_create, LIBFAST), Ptr{Cvoid},
                     (Ptr{Int32}, Csize_t), keys, length(keys))
    tree_ptr == C_NULL && error("fast_create failed")

    sink = Int64(0)
    for i in 1:warmup
        sink += fast_search_bench(tree_ptr, queries[i])
    end

    t0 = time_ns()
    sink = Int64(0)
    for i in 1:num_queries
        sink += fast_search_bench(tree_ptr, queries[i])
    end
    elapsed = (time_ns() - t0) / 1e9
    emit_json("fast_ffi", tree_size, num_queries, elapsed)

    ccall((:fast_destroy, LIBFAST), Cvoid, (Ptr{Cvoid},), tree_ptr)

    # --- searchsortedfirst ---
    sink = Int64(0)
    for i in 1:warmup
        sink += native_search(keys, queries[i])
    end

    t0 = time_ns()
    sink = Int64(0)
    for i in 1:num_queries
        sink += native_search(keys, queries[i])
    end
    elapsed = (time_ns() - t0) / 1e9
    emit_json("searchsortedfirst", tree_size, num_queries, elapsed)

    # prevent dead-code elimination
    sink == typemin(Int64) && println(stderr, sink)
end

using Random
main()
