#!/usr/bin/env ruby
# Cross-language benchmark: Ruby — Array#bsearch vs FAST FFI (ffi gem).
#
# Ruby's standard library does not include an ordered tree container.
# Array#bsearch (binary search on sorted array) is the standard approach.
# For a tree-based comparison, the rbtree gem (gem install rbtree)
# provides a C-extension red-black tree with upper_bound/lower_bound.
#
# Run: ruby bench_ruby.rb <tree_size> <num_queries>

require 'ffi'
require 'json'

module FastLib
  extend FFI::Library

  lib_paths = [
    File.expand_path('../../build/libfast.so', __dir__),
    File.expand_path('../../build/libfast.dylib', __dir__),
    'libfast.so',
    'fast',
  ]
  found = lib_paths.find { |p| File.exist?(p) rescue false }
  ffi_lib(found || 'fast')

  attach_function :fast_create,  [:pointer, :size_t], :pointer
  attach_function :fast_destroy, [:pointer], :void
  attach_function :fast_search,  [:pointer, :int32], :int64
end

def emit_json(compiler, method, tree_size, num_queries, sec)
  mqs = num_queries / sec / 1e6
  nsq = sec * 1e9 / num_queries
  puts JSON.generate({
    language: "ruby", compiler: compiler, method: method,
    tree_size: tree_size, num_queries: num_queries,
    total_sec: sec.round(4), mqs: mqs.round(2), ns_per_query: nsq.round(1),
  })
  $stdout.flush
end

tree_size = (ARGV[0] || 1_000_000).to_i
num_queries = (ARGV[1] || 5_000_000).to_i

compiler = "#{RUBY_ENGINE}-#{RUBY_VERSION}"

# Generate sorted keys
keys = Array.new(tree_size) { |i| i * 3 + 1 }
max_key = keys.last

# Generate random queries
rng = Random.new(42)
queries = Array.new(num_queries) { rng.rand(0..max_key) }

warmup = [num_queries, 10_000].min

# --- FAST FFI ---
buf = FFI::MemoryPointer.new(:int32, tree_size)
buf.write_array_of_int32(keys)
tree = FastLib.fast_create(buf, tree_size)
raise "fast_create failed" if tree.null?

warmup.times { |i| FastLib.fast_search(tree, queries[i]) }

t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
sink = 0
queries.each { |q| sink += FastLib.fast_search(tree, q) }
elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
emit_json(compiler, "fast_ffi", tree_size, num_queries, elapsed)

FastLib.fast_destroy(tree)

# --- Array#bsearch ---
warmup.times do |i|
  q = queries[i]
  idx = keys.bsearch_index { |x| x > q }
  idx = idx ? idx - 1 : tree_size - 1
end

t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
sink = 0
queries.each do |q|
  idx = keys.bsearch_index { |x| x > q }
  idx = idx ? idx - 1 : tree_size - 1
  idx = -1 if q < keys[0]
  sink += idx
end
elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
emit_json(compiler, "Array#bsearch", tree_size, num_queries, elapsed)
