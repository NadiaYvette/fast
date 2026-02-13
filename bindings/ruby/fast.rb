# Ruby bindings for the FAST search tree library.
#
# Requires the 'ffi' gem:  gem install ffi
#
# Usage:
#   require_relative 'fast'
#   tree = Fast::Tree.new([1, 3, 5, 7, 9])
#   tree.search(5)  # => 2
#   tree.search(0)  # => -1
#   tree.close

require 'ffi'

module Fast
  module Lib
    extend FFI::Library

    lib_paths = [
      File.expand_path('../../build/libfast.so', __dir__),
      File.expand_path('../../build/libfast.dylib', __dir__),
      'libfast.so',
      'fast',
    ]

    found = lib_paths.find { |p| File.exist?(p) rescue false }
    ffi_lib(found || 'fast')

    attach_function :fast_create,             [:pointer, :size_t],       :pointer
    attach_function :fast_destroy,            [:pointer],                :void
    attach_function :fast_search,             [:pointer, :int32],        :int64
    attach_function :fast_search_lower_bound, [:pointer, :int32],        :int64
    attach_function :fast_size,               [:pointer],                :size_t
    attach_function :fast_key_at,             [:pointer, :size_t],       :int32
  end

  class Tree
    def initialize(keys)
      buf = FFI::MemoryPointer.new(:int32, keys.length)
      buf.write_array_of_int32(keys)
      @ptr = Lib.fast_create(buf, keys.length)
      raise "fast_create failed" if @ptr.null?
    end

    def search(key)
      Lib.fast_search(@ptr, key)
    end

    def lower_bound(key)
      Lib.fast_search_lower_bound(@ptr, key)
    end

    def size
      Lib.fast_size(@ptr)
    end

    def key_at(index)
      Lib.fast_key_at(@ptr, index)
    end

    def close
      if @ptr && !@ptr.null?
        Lib.fast_destroy(@ptr)
        @ptr = nil
      end
    end
  end
end
