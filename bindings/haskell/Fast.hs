{- |
Haskell bindings for the FAST search tree library.

Usage:

@
import Fast
main = do
    tree <- fastCreate [1, 3, 5, 7, 9]
    idx  <- fastSearch tree 5   -- returns 2
    fastDestroy tree
@

Compile with: ghc -lfast Fast.hs
-}

module Fast
    ( FastTree
    , fastCreate
    , fastDestroy
    , fastSearch
    , fastSearchLowerBound
    , fastSize
    , fastKeyAt
    , withFastTree
    ) where

import Foreign
import Foreign.C.Types
import Foreign.ForeignPtr
import Control.Exception (bracket)

-- Opaque pointer type
data FastTreeRaw
type FastTreePtr = Ptr FastTreeRaw

-- | Opaque handle to a FAST tree.
newtype FastTree = FastTree (ForeignPtr FastTreeRaw)

-- FFI imports
foreign import ccall "fast_create"
    c_fast_create :: Ptr Int32 -> CSize -> IO FastTreePtr

foreign import ccall "&fast_destroy"
    c_fast_destroy_ptr :: FunPtr (FastTreePtr -> IO ())

foreign import ccall "fast_destroy"
    c_fast_destroy :: FastTreePtr -> IO ()

foreign import ccall "fast_search"
    c_fast_search :: FastTreePtr -> Int32 -> IO Int64

foreign import ccall "fast_search_lower_bound"
    c_fast_search_lower_bound :: FastTreePtr -> Int32 -> IO Int64

foreign import ccall "fast_size"
    c_fast_size :: FastTreePtr -> IO CSize

foreign import ccall "fast_key_at"
    c_fast_key_at :: FastTreePtr -> CSize -> IO Int32

-- | Build a FAST tree from a sorted list of keys.
fastCreate :: [Int32] -> IO FastTree
fastCreate keys = withArrayLen keys $ \len ptr -> do
    raw <- c_fast_create ptr (fromIntegral len)
    if raw == nullPtr
        then error "fast_create failed"
        else FastTree <$> newForeignPtr c_fast_destroy_ptr raw

-- | Explicitly destroy the tree (optional; GC will handle it).
fastDestroy :: FastTree -> IO ()
fastDestroy (FastTree fp) = finalizeForeignPtr fp

-- | Search: returns index of largest key <= query, or -1.
fastSearch :: FastTree -> Int32 -> IO Int64
fastSearch (FastTree fp) key = withForeignPtr fp $ \p -> c_fast_search p key

-- | Lower bound: returns index of first key >= query.
fastSearchLowerBound :: FastTree -> Int32 -> IO Int64
fastSearchLowerBound (FastTree fp) key =
    withForeignPtr fp $ \p -> c_fast_search_lower_bound p key

-- | Number of keys.
fastSize :: FastTree -> IO Int
fastSize (FastTree fp) = withForeignPtr fp $ \p ->
    fromIntegral <$> c_fast_size p

-- | Key at sorted index.
fastKeyAt :: FastTree -> Int -> IO Int32
fastKeyAt (FastTree fp) idx = withForeignPtr fp $ \p ->
    c_fast_key_at p (fromIntegral idx)

-- | Bracket-style usage: create, use, destroy.
withFastTree :: [Int32] -> (FastTree -> IO a) -> IO a
withFastTree keys = bracket (fastCreate keys) fastDestroy
