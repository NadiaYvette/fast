{- Cross-language benchmark: Haskell — Data.Map / Data.IntMap vs FAST FFI.

   Data.Map.Strict is a size-balanced BST (generic, polymorphic comparison).
   Data.IntMap.Strict is a PATRICIA trie specialized for Int keys.
   Since our keys are Int32 (convertible to Int), IntMap is the more
   idiomatic choice for integer-keyed lookups.

   Compile:
     ghc -O2 -o bench_haskell bench_haskell.hs \
         ../../bindings/haskell/Fast.hs -L../../build -lfast \
         -optl -Wl,-rpath,../../build
-}

module Main where

import Foreign
import Foreign.C.Types
import Data.Int
import Data.Word
import Data.Bits (shiftR)
import Data.IORef
import System.Environment (getArgs)
import System.Clock (getTime, Clock(Monotonic), toNanoSecs)
import Text.Printf (printf)
import System.IO (hFlush, stdout)
import qualified Data.Map.Strict as Map
import qualified Data.IntMap.Strict as IntMap
import qualified Data.Vector.Unboxed as V
import qualified Data.Vector.Storable as VS

-- FFI declarations (inline, avoid dependency on Fast module)
data FastTreeRaw
type FastTreePtr = Ptr FastTreeRaw

foreign import ccall "fast_create"
    c_fast_create :: Ptr Int32 -> CSize -> IO FastTreePtr
foreign import ccall "fast_destroy"
    c_fast_destroy :: FastTreePtr -> IO ()
foreign import ccall "fast_search"
    c_fast_search :: FastTreePtr -> Int32 -> IO Int64

emitJSON :: String -> String -> Int -> Int -> Double -> IO ()
emitJSON compiler method treeSize numQueries sec = do
    let mqs = fromIntegral numQueries / sec / 1e6
        nsq = sec * 1e9 / fromIntegral numQueries
    printf "{\"language\":\"haskell\",\"compiler\":\"%s\",\"method\":\"%s\",\"tree_size\":%d,\"num_queries\":%d,\"total_sec\":%.4f,\"mqs\":%.2f,\"ns_per_query\":%.1f}\n"
        compiler method treeSize numQueries sec mqs nsq
    hFlush stdout

main :: IO ()
main = do
    args <- getArgs
    let treeSize   = case args of (s:_) -> read s; _ -> 1000000
        numQueries = case args of (_:s:_) -> read s; _ -> 5000000

    let compiler = "ghc"

    -- Generate sorted keys (Storable vector for FFI pointer access)
    let keysS = VS.generate treeSize (\i -> fromIntegral (i * 3 + 1) :: Int32)
        -- Also keep an Unboxed version for Map building
        keys = V.generate treeSize (\i -> fromIntegral (i * 3 + 1) :: Int32)
        maxKey = keys V.! (treeSize - 1)

    -- Generate random queries (simple LCG)
    let mkQueries n = V.unfoldrExactN n (\s ->
            let s' = s * 6364136223846793005 + 1442695040888963407
                q  = fromIntegral ((s' `shiftR` 33) `mod` fromIntegral (maxKey + 1)) :: Int32
            in (q, s')) (42 :: Word)
        queries = mkQueries numQueries

    let warmup = min numQueries 100000

    -- --- FAST FFI ---
    VS.unsafeWith keysS $ \keysPtr -> do
        treePtr <- c_fast_create keysPtr (fromIntegral treeSize)
        sinkRef <- newIORef (0 :: Int64)

        -- Warmup
        V.forM_ (V.take warmup queries) $ \q -> do
            r <- c_fast_search treePtr q
            modifyIORef' sinkRef (+ r)

        t0 <- getTime Monotonic
        V.forM_ queries $ \q -> do
            r <- c_fast_search treePtr q
            modifyIORef' sinkRef (+ r)
        t1 <- getTime Monotonic

        let sec = fromIntegral (toNanoSecs t1 - toNanoSecs t0) / 1e9
        emitJSON compiler "fast_ffi" treeSize numQueries sec

        c_fast_destroy treePtr

    -- --- Data.Map (balanced BST / size-balanced tree) ---
    do
        let m = Map.fromList [(keys V.! i, fromIntegral i :: Int64) | i <- [0..treeSize-1]]
        sinkRef <- newIORef (0 :: Int64)

        V.forM_ (V.take warmup queries) $ \q ->
            case Map.lookupLE q m of
                Just (_, v) -> modifyIORef' sinkRef (+ v)
                Nothing     -> modifyIORef' sinkRef (+ (-1))

        t0 <- getTime Monotonic
        V.forM_ queries $ \q ->
            case Map.lookupLE q m of
                Just (_, v) -> modifyIORef' sinkRef (+ v)
                Nothing     -> modifyIORef' sinkRef (+ (-1))
        t1 <- getTime Monotonic

        let sec = fromIntegral (toNanoSecs t1 - toNanoSecs t0) / 1e9
        emitJSON compiler "Data.Map" treeSize numQueries sec

    -- --- Data.IntMap (PATRICIA trie, specialized for Int keys) ---
    do
        let im = IntMap.fromList [(fromIntegral (keys V.! i) :: Int, fromIntegral i :: Int64) | i <- [0..treeSize-1]]
        sinkRef <- newIORef (0 :: Int64)

        V.forM_ (V.take warmup queries) $ \q ->
            case IntMap.lookupLE (fromIntegral q) im of
                Just (_, v) -> modifyIORef' sinkRef (+ v)
                Nothing     -> modifyIORef' sinkRef (+ (-1))

        t0 <- getTime Monotonic
        V.forM_ queries $ \q ->
            case IntMap.lookupLE (fromIntegral q) im of
                Just (_, v) -> modifyIORef' sinkRef (+ v)
                Nothing     -> modifyIORef' sinkRef (+ (-1))
        t1 <- getTime Monotonic

        let sec = fromIntegral (toNanoSecs t1 - toNanoSecs t0) / 1e9
        emitJSON compiler "IntMap" treeSize numQueries sec

    return ()
