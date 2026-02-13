"""
Python bindings for the FAST (Fast Architecture Sensitive Tree) library.

Usage:
    from fast import FastTree
    tree = FastTree([1, 3, 5, 7, 9])
    idx = tree.search(5)   # returns 2
    idx = tree.search(0)   # returns -1
"""

import ctypes
import ctypes.util
import os
from pathlib import Path


def _load_library():
    """Locate and load libfast shared library."""
    # Try common locations relative to this file
    here = Path(__file__).parent
    candidates = [
        here / ".." / ".." / "build" / "libfast.so",
        here / ".." / ".." / "build" / "libfast.dylib",
        here / ".." / ".." / "libfast.so",
        Path("/usr/local/lib/libfast.so"),
        Path("/usr/lib/libfast.so"),
    ]
    for path in candidates:
        path = path.resolve()
        if path.exists():
            return ctypes.CDLL(str(path))

    # Fall back to system search
    name = ctypes.util.find_library("fast")
    if name:
        return ctypes.CDLL(name)

    raise OSError("Cannot find libfast shared library. Build the project first.")


_lib = _load_library()

# Declare function signatures
_lib.fast_create.argtypes = [ctypes.POINTER(ctypes.c_int32), ctypes.c_size_t]
_lib.fast_create.restype = ctypes.c_void_p

_lib.fast_destroy.argtypes = [ctypes.c_void_p]
_lib.fast_destroy.restype = None

_lib.fast_search.argtypes = [ctypes.c_void_p, ctypes.c_int32]
_lib.fast_search.restype = ctypes.c_int64

_lib.fast_search_lower_bound.argtypes = [ctypes.c_void_p, ctypes.c_int32]
_lib.fast_search_lower_bound.restype = ctypes.c_int64

_lib.fast_size.argtypes = [ctypes.c_void_p]
_lib.fast_size.restype = ctypes.c_size_t

_lib.fast_key_at.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
_lib.fast_key_at.restype = ctypes.c_int32


class FastTree:
    """A FAST (Fast Architecture Sensitive Tree) for high-throughput search."""

    def __init__(self, keys):
        """Build a FAST tree from a sorted list of 32-bit integer keys."""
        arr = (ctypes.c_int32 * len(keys))(*keys)
        self._ptr = _lib.fast_create(arr, len(keys))
        if not self._ptr:
            raise MemoryError("fast_create failed")

    def __del__(self):
        if hasattr(self, "_ptr") and self._ptr:
            _lib.fast_destroy(self._ptr)
            self._ptr = None

    def __enter__(self):
        return self

    def __exit__(self, *args):
        if self._ptr:
            _lib.fast_destroy(self._ptr)
            self._ptr = None

    def __len__(self):
        return _lib.fast_size(self._ptr)

    def search(self, key):
        """Return index of largest key <= query, or -1 if query < all keys."""
        return _lib.fast_search(self._ptr, key)

    def lower_bound(self, key):
        """Return index of first key >= query."""
        return _lib.fast_search_lower_bound(self._ptr, key)

    def key_at(self, index):
        """Return the key at the given sorted index."""
        return _lib.fast_key_at(self._ptr, index)
