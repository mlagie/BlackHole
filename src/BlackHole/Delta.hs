{-# LANGUAGE BangPatterns #-}
module BlackHole.Delta
  ( DeltaOp(..)
  , buildDelta
  , encodeDelta
  , decodeDelta
  , applyDelta
  ) where

import qualified Data.ByteString as BS
import Data.Bits (shiftL, shiftR, (.|.), (.&.))
import Data.Word (Word8, Word32, Word64)
import qualified Data.Map.Strict as Map

data DeltaOp
  = Copy !Word32 !Word32
  | Insert !BS.ByteString
  deriving (Show, Eq)

-- 256-byte anchors find shared sequences in small sources. Rolling hashes
-- keep a scan linear in target length; collisions are always byte-verified.
-- At most 16384 anchors and four offsets/hash are retained. Comparison work
-- is capped at 8*(base+target) bytes, then the remaining target is literal.
blockSize :: Int
blockSize = 256

buildDelta :: BS.ByteString -> BS.ByteString -> [DeltaOp]
buildDelta base target = go 0 0 initialHash budget
  where
    stride = max blockSize (((BS.length base `div` 16384) `div` blockSize + 1) * blockSize)
    index = Map.fromListWith (\new old -> take 4 (new ++ old))
      [ (hashBlock (BS.take blockSize (BS.drop offset base)), [offset])
      | offset <- take 16384 [0, stride .. BS.length base - blockSize] ]
    n = BS.length target
    budget = 8 * (BS.length base + n)
    initialHash = hashBlock (BS.take blockSize target)
    power = 257 ^ (blockSize - 1) :: Word64
    literal start end rest
      | start == end = rest
      | otherwise = Insert (BS.take (end-start) (BS.drop start target)) : rest
    go !position !start !key !remaining
      | position + blockSize > n || remaining <= 0 = literal start n []
      | otherwise =
          let candidates = Map.findWithDefault [] key index
              (match, left) = bestMatch position remaining candidates Nothing
          in case match of
            Just (offset, len) | len >= blockSize ->
              let next = position + len
                  nextHash = hashBlock (BS.take blockSize (BS.drop next target))
              in literal start position
                (Copy (fromIntegral offset) (fromIntegral len) : go next next nextHash left)
            _ ->
              let nextKey = if position + blockSize < n
                    then (key - fromIntegral (BS.index target position) * power) * 257
                      + fromIntegral (BS.index target (position + blockSize))
                    else 0
              in go (position+1) start nextKey left
    bestMatch _ left [] best = (best, left)
    bestMatch position left (offset:rest) best
      | left <= 0 = (best, 0)
      | otherwise =
          let limit = min left (min (BS.length base-offset) (n-position))
              len = commonLength offset position limit 0
              next = case best of
                Just (_, old) | old >= len -> best
                _ -> Just (offset, len)
          in bestMatch position (left - max 1 (len+1)) rest next
    commonLength source dest limit !i
      | i >= limit = i
      | BS.index base (source+i) == BS.index target (dest+i) =
          commonLength source dest limit (i+1)
      | otherwise = i

hashBlock :: BS.ByteString -> Word64
hashBlock = BS.foldl' (\h b -> h * 257 + fromIntegral b) 0

putVar :: Word64 -> [Word8]
putVar n
  | n < 128 = [fromIntegral n]
  | otherwise = (fromIntegral (n .&. 127) .|. 128) : putVar (n `shiftR` 7)

getVar :: [Word8] -> Either String (Word64, [Word8])
getVar = go 0 0
  where
    go !shift !value (b:rest)
      | shift > 63 = Left "Varint DELTA trop long"
      | otherwise =
          let next = value .|. (fromIntegral (b .&. 127) `shiftL` shift)
          in if b .&. 128 == 0 then Right (next, rest)
             else go (shift + 7) next rest
    go _ _ [] = Left "Varint DELTA tronque"

encodeDelta :: [DeltaOp] -> BS.ByteString
encodeDelta = BS.pack . concatMap encode
  where
    encode (Copy offset length') =
      0 : putVar (fromIntegral offset) ++ putVar (fromIntegral length')
    encode (Insert bytes) =
      1 : putVar (fromIntegral (BS.length bytes)) ++ BS.unpack bytes

decodeDelta :: BS.ByteString -> Either String [DeltaOp]
decodeDelta = go . BS.unpack
  where
    go [] = Right []
    go (tag:rest) = case tag of
      0 -> do
        (offset, rest1) <- getVar rest
        (length', rest2) <- getVar rest1
        if offset > fromIntegral (maxBound :: Word32) ||
           length' > fromIntegral (maxBound :: Word32) ||
           length' == 0
          then Left "Instruction COPY DELTA invalide"
          else (Copy (fromIntegral offset) (fromIntegral length') :)
            <$> go rest2
      1 -> do
        (length', rest1) <- getVar rest
        if length' > fromIntegral (length rest1)
          then Left "Instruction INSERT DELTA tronquee"
          else (Insert (BS.pack (take (fromIntegral length') rest1)) :)
            <$> go (drop (fromIntegral length') rest1)
      _ -> Left "Instruction DELTA inconnue"

applyDelta :: BS.ByteString -> Word32 -> [DeltaOp] -> Either String BS.ByteString
applyDelta base expected = go 0 []
  where
    limit = fromIntegral expected :: Int
    go !size acc [] =
      if size == limit then Right (BS.concat (reverse acc))
      else Left "Taille DELTA reconstruite incoherente"
    go !size acc (op:rest) =
      case op of
        Copy offset length'
          | fromIntegral offset > BS.length base ||
            fromIntegral length' > BS.length base - fromIntegral offset ->
              Left "COPY DELTA hors limites"
          | size > limit - fromIntegral length' ->
              Left "DELTA depasse la taille attendue"
          | otherwise ->
              go (size + fromIntegral length')
                (BS.take (fromIntegral length') (BS.drop (fromIntegral offset) base):acc) rest
        Insert bytes
          | size > limit - BS.length bytes ->
              Left "INSERT DELTA depasse la taille attendue"
          | otherwise -> go (size + BS.length bytes) (bytes:acc) rest
