{-# LANGUAGE ForeignFunctionInterface #-}
module BlackHole.Hash (hashBytes) where
import qualified Data.ByteString as BS
import qualified Data.ByteString.Unsafe as BSU
import Data.Word (Word8,Word64)
import Foreign (Ptr,castPtr)
import Foreign.C.Types (CSize(..))
import System.IO.Unsafe (unsafePerformIO)
foreign import ccall unsafe "bh_fnv64" c_hash :: Ptr Word8 -> CSize -> IO Word64
-- FNV-1a uses defined unsigned overflow. Duplicate candidates are still
-- compared byte-for-byte by the archive layer, so hashes never imply equality.
hashBytes :: BS.ByteString -> Word64
hashBytes bytes = unsafePerformIO $ BSU.unsafeUseAsCStringLen bytes $ \(source,n) ->
  c_hash (castPtr source) (fromIntegral n)
{-# NOINLINE hashBytes #-}
