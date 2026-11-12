{-# LANGUAGE ForeignFunctionInterface #-}
-- Deterministic libzstd codec. Decompression is bounded by the stored block size.
module BlackHole.Zstd (compressZstd, compressZstdWindow, compressZstdLong, compressZstdLongMT, compressZstdText, decompressZstd, decompressArchiveZstd) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Unsafe as BSU
import Foreign
import Foreign.C.Types
import Control.Exception (bracket)
import System.IO.Unsafe (unsafePerformIO)

foreign import ccall unsafe "ZSTD_compressBound"
  c_compressBound :: CSize -> CSize
foreign import ccall safe "ZSTD_compress"
  c_compress :: Ptr Word8 -> CSize -> Ptr Word8 -> CSize -> CInt -> IO CSize
-- Advanced context for long-distance matches in solid groups.
-- Parameter constants come from zstd.h: compressionLevel=100,
-- windowLog=101, enableLongDistanceMatching=160. A 64 MiB window does
-- not automatically enable LDM; the two variants must remain distinct.
foreign import ccall unsafe "ZSTD_createCCtx"
  c_createCCtx :: IO (Ptr ())
foreign import ccall unsafe "ZSTD_freeCCtx"
  c_freeCCtx :: Ptr () -> IO CSize
foreign import ccall unsafe "ZSTD_CCtx_setParameter"
  c_setParameter :: Ptr () -> CInt -> CInt -> IO CSize
foreign import ccall safe "ZSTD_compress2"
  c_compress2 :: Ptr () -> Ptr Word8 -> CSize -> Ptr Word8 -> CSize -> IO CSize
foreign import ccall unsafe "ZSTD_decompress"
  c_decompress :: Ptr Word8 -> CSize -> Ptr Word8 -> CSize -> IO CSize
foreign import ccall unsafe "ZSTD_isError"
  c_isError :: CSize -> CUInt
compressZstd :: Int -> BS.ByteString -> IO (Either String BS.ByteString)
compressZstd level input =
  BSU.unsafeUseAsCStringLen input $ \(source, lengthIn) -> do
    let capacity = fromIntegral (c_compressBound (fromIntegral lengthIn))
    -- Large archives can exceed the native thread stack. Allocate the
    -- compression buffer on the managed heap, not via allocaBytes.
    buffer <- mallocForeignPtrBytes capacity
    withForeignPtr buffer $ \destination -> do
      result <- c_compress destination (fromIntegral capacity)
                    (castPtr source) (fromIntegral lengthIn) (fromIntegral level)
      if c_isError result /= 0
        then return (Left "Erreur de compression Zstandard")
        else Right <$> BS.packCStringLen (castPtr destination, fromIntegral result)

-- A wider ZSTD window can reuse data separated by many megabytes.
-- The decoder needs no new archive format: the window is recorded in the
-- standard ZSTD frame header. The function checks all native return codes.
-- We compare this result against the ordinary stream at the call site.
compressZstdWindow :: Int -> BS.ByteString -> IO (Either String BS.ByteString)
compressZstdWindow = compressZstdContext False

compressZstdLong :: Int -> BS.ByteString -> IO (Either String BS.ByteString)
compressZstdLong = compressZstdContext True

compressZstdContext :: Bool -> Int -> BS.ByteString -> IO (Either String BS.ByteString)
compressZstdContext enableLdm = compressZstdConfigured enableLdm 0

compressZstdLongMT :: Int -> Int -> BS.ByteString -> IO (Either String BS.ByteString)
compressZstdLongMT level workers = compressZstdConfigured True (max 1 (min 4 workers)) level

compressZstdConfigured :: Bool -> Int -> Int -> BS.ByteString -> IO (Either String BS.ByteString)
compressZstdConfigured enableLdm workers = compressZstdProfile enableLdm workers 0

compressZstdText :: Int -> BS.ByteString -> IO (Either String BS.ByteString)
compressZstdText workers input = do
  packed <- compressZstdProfile True (max 1 (min 4 workers)) 1 12 input
  case packed of
    Right bytes -> return (Right bytes)
    Left _ -> compressZstdProfile True 0 1 12 input

compressZstdProfile :: Bool -> Int -> Int -> Int -> BS.ByteString -> IO (Either String BS.ByteString)
compressZstdProfile enableLdm workers textProfile level input =
  bracket c_createCCtx (\ctx -> if ctx == nullPtr then return ()
    else do { _ <- c_freeCCtx ctx; return () }) $ \ctx ->
    if ctx == nullPtr then return (Left "ZSTD: impossible d'allouer le contexte")
    else do
      r1 <- c_setParameter ctx 100 (fromIntegral level)
      r2 <- c_setParameter ctx 101 26 -- windowLog = 26 (64 Mio)
      r3 <- c_setParameter ctx 160 (if enableLdm then 1 else 0)
      text <- if textProfile == 0 then return [] else sequence
        [ c_setParameter ctx 107 7, c_setParameter ctx 104 3
        , c_setParameter ctx 105 3, c_setParameter ctx 106 32 ]
      -- Keep jobs smaller than the usual 8-16 MiB solid batches. With a
      -- 16 MiB job, those batches silently fall back to one native worker.
      -- The window and overlap are unchanged, so cross-job matches remain
      -- available and the compression profile is not weakened.
      mt <- if workers <= 0 then return [] else sequence
        [ c_setParameter ctx 400 (fromIntegral workers)
        , c_setParameter ctx 401 4194304
        , c_setParameter ctx 402 (if textProfile /= 0 then 5 else 7) ]
      if any ((/= 0) . c_isError) ([r1, r2, r3] ++ text ++ mt)
        then return (Left "ZSTD: parametres de compression invalides")
        else BSU.unsafeUseAsCStringLen input $ \(source, lengthIn) -> do
          let capacity = fromIntegral (c_compressBound (fromIntegral lengthIn))
          buffer <- mallocForeignPtrBytes capacity
          withForeignPtr buffer $ \destination -> do
            result <- c_compress2 ctx destination (fromIntegral capacity)
                       (castPtr source) (fromIntegral lengthIn)
            if c_isError result /= 0
              then return (Left "ZSTD: compression longue distance invalide")
              else Right <$> BS.packCStringLen
                (castPtr destination, fromIntegral result)

-- Pure facade is safe here: libzstd decompression is deterministic, has no
-- observable side effects, and all native buffers are local to this call.
-- The size cap prevents an archive from requesting unbounded allocations.
decompressZstd :: Word32 -> BS.ByteString -> Either String BS.ByteString
decompressZstd wanted encoded
  | wanted > 67108864 = Left "Bloc Zstandard trop grand (limite 64 Mio)"
  | BS.null encoded = Left "Trame Zstandard vide"
  | otherwise = unsafePerformIO $ do
      BSU.unsafeUseAsCStringLen encoded $ \(source, lengthIn) -> do
        buffer <- mallocForeignPtrBytes (max 1 (fromIntegral wanted))
        withForeignPtr buffer $ \destination -> do
          result <- c_decompress destination (fromIntegral wanted)
                      (castPtr source) (fromIntegral lengthIn)
          if c_isError result /= 0 || result /= fromIntegral wanted
            then return (Left "Trame Zstandard corrompue ou taille invalide")
            else Right <$> BS.packCStringLen (castPtr destination, fromIntegral result)
{-# NOINLINE decompressZstd #-}


-- BH09 optionally compresses the already serialized archive.  It is only
-- used for bounded-size archives: never trust the announced size of a
-- damaged or hostile frame without checking it first.
-- This larger cap is separate from the strict 16 MiB limit for data blocks.
decompressArchiveZstd :: Word32 -> BS.ByteString -> Either String BS.ByteString
decompressArchiveZstd wanted encoded
  | wanted > 268435456 = Left "BH09: archive decompressee trop grande (256 Mio)"
  | BS.null encoded = Left "BH09: charge utile vide"
  | otherwise = unsafePerformIO $
      BSU.unsafeUseAsCStringLen encoded $ \(source, lengthIn) ->
        do
          buffer <- mallocForeignPtrBytes (max 1 (fromIntegral wanted))
          withForeignPtr buffer $ \destination -> do
            result <- c_decompress destination (fromIntegral wanted)
                      (castPtr source) (fromIntegral lengthIn)
            if c_isError result /= 0 || result /= fromIntegral wanted
              then return (Left "BH09: charge utile corrompue ou taille invalide")
              else Right <$> BS.packCStringLen
                (castPtr destination, fromIntegral result)
{-# NOINLINE decompressArchiveZstd #-}
