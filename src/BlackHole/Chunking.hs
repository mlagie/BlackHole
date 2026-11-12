module BlackHole.Chunking
  ( chunkSize
  , splitChunks
  ) where

import qualified Data.ByteString as BS
import Data.Bits ((.&.), xor)
import Data.Word (Word64)

chunkSize :: Int
chunkSize = 16384

splitChunks :: BS.ByteString -> [BS.ByteString]
splitChunks bytes
  | BS.null bytes = []
  | otherwise = go 0 (2166136261 :: Word64) 0
  where
    minSize = chunkSize `div` 2
    maxSize = chunkSize * 2
    -- A power-of-two mask gives an average boundary near 16 KiB.
    boundaryMask :: Word64
    boundaryMask = 0x3fff

    go offset hash start
      | offset >= BS.length bytes = [BS.drop start bytes | offset > start]
      | offset - start >= maxSize =
          BS.take (offset - start) (BS.drop start bytes) :
          go offset hash offset
      | otherwise =
          let byte = fromIntegral (BS.index bytes offset)
              nextHash = (hash * 16777619 `xor` byte) .&. 0xffffffff
              length' = offset + 1 - start
          in if length' >= minSize && (nextHash .&. boundaryMask) == 0
               then BS.take length' (BS.drop start bytes) :
                    go (offset + 1) nextHash (offset + 1)
               else go (offset + 1) nextHash start
