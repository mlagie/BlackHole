{-# LANGUAGE ForeignFunctionInterface #-}
module BlackHole.Transform
  ( normalizeEscapes, restoreEscapes, encodeTextWords, restoreTextWords ) where
import qualified Data.ByteString as BS
import qualified Data.ByteString.Unsafe as BSU
import Foreign
import Foreign.C.Types
import System.IO.Unsafe (unsafePerformIO)

type Native = Ptr Word8 -> CSize -> Ptr Word8 -> CSize -> IO CSize
foreign import ccall safe "bh_normalize" c_normalize :: Native
foreign import ccall safe "bh_denormalize" c_denormalize :: Native
foreign import ccall safe "bh_tokenize" c_words :: Native
foreign import ccall safe "bh_detokenize" c_unwords :: Native

limit :: Int
limit = 67108864

normalizeEscapes :: BS.ByteString -> IO (Either String BS.ByteString)
normalizeEscapes bytes = forward c_normalize
  (BS.length bytes + (BS.length bytes+7) `div` 8 + 4) bytes

encodeTextWords :: BS.ByteString -> IO (Either String BS.ByteString)
encodeTextWords bytes = forward c_words (min limit (BS.length bytes*2+4)) bytes

forward :: Native -> Int -> BS.ByteString -> IO (Either String BS.ByteString)
forward native capacity bytes
  | BS.length bytes > limit = return (Left "Transformation: entree trop grande")
  | otherwise = BSU.unsafeUseAsCStringLen bytes $ \(source, size) -> do
      buffer <- mallocForeignPtrBytes (max 1 capacity)
      withForeignPtr buffer $ \destination -> do
        result <- native (castPtr source) (fromIntegral size) destination (fromIntegral capacity)
        if result > fromIntegral capacity || result > fromIntegral limit || result < 4
          then return (Left "Transformation impossible ou trop grande")
          else Right <$> BS.packCStringLen (castPtr destination, fromIntegral result)

restoreEscapes :: Word32 -> BS.ByteString -> Either String BS.ByteString
restoreEscapes = backward c_denormalize
{-# NOINLINE restoreEscapes #-}
restoreTextWords :: Word32 -> BS.ByteString -> Either String BS.ByteString
restoreTextWords = backward c_unwords
{-# NOINLINE restoreTextWords #-}

backward :: Native -> Word32 -> BS.ByteString -> Either String BS.ByteString
backward native wanted bytes
  | wanted > fromIntegral limit || BS.length bytes > limit = Left "Transformation: taille invalide"
  | otherwise = unsafePerformIO $ BSU.unsafeUseAsCStringLen bytes $ \(source, size) -> do
      buffer <- mallocForeignPtrBytes (max 1 (fromIntegral wanted))
      withForeignPtr buffer $ \destination -> do
        result <- native (castPtr source) (fromIntegral size) destination (fromIntegral wanted)
        if result /= fromIntegral wanted
          then return (Left "Transformation texte corrompue")
          else Right <$> BS.packCStringLen (castPtr destination, fromIntegral result)
