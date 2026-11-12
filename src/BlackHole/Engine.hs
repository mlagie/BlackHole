{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE ScopedTypeVariables #-}
module BlackHole.Engine
  ( Block(..), MathExpr(..), compressBlock, decompressBlock, compressBytes, decompressBytes
  , normalizeEscapes, restoreEscapes, encodeTextWords, restoreTextWords, compressSolidTextWith
  , rawSize, compressedSize, Codec(..), compressBytesWith
  , compressSolidBytesTurboWith, compressSolidBytesDirectWith, compressSolidBytesWith, codecName, mathFunctionCount
  ) where

import BlackHole.Transform (normalizeEscapes, restoreEscapes, encodeTextWords, restoreTextWords)
import BlackHole.Zstd (compressZstd, compressZstdWindow, compressZstdLong, compressZstdLongMT, compressZstdText, decompressZstd)
import BlackHole.Diagnostics (traceEvent, traceSpanStart, traceSpanEnd)
import Control.Monad (foldM, forM_, replicateM_)
import Control.Concurrent (forkIO, getNumCapabilities)
import Control.Concurrent.Chan (Chan, newChan, readChan, writeChan)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, evaluate, throwIO, try)
import qualified Data.Binary as Bin
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import qualified Data.IntMap.Strict as IM
import qualified Data.IntSet as IS
import Data.List (foldl', sortBy)
import Data.Ord (comparing)
import Data.Word (Word8, Word32)
import Data.Int (Int32)
import GHC.Generics (Generic)

-- IMPORTANT: conserver l'ordre des trois premiers constructeurs pour BH01-03.
-- MathBlockV2 est un nouveau constructeur ajoute en fin de liste.
data Block = RawBlock BS.ByteString
           | MathBlock Word32 [(Word8, Word32, Word32, Word32)] BS.ByteString
           | ZstdBlock Word32 BS.ByteString
           | MathBlockV2 Word32 [(Word8, MathExpr)] BS.ByteString
           | MathBlockV3 Word32 BS.ByteString BS.ByteString
           | TextZstdBlock Word32 Word32 Word32 BS.ByteString
           deriving (Show, Eq, Generic)
instance Bin.Binary Block

-- Toutes les expressions utilisent les indices d'occurrences x=0..count-1.
-- Piecewise: plusieurs expressions peuvent concerner le meme octet.
data MathExpr = Linear Word32 Word32 Word32
              | Periodic Word32 [Word32] Word32
              | Quadratic Word32 Word32 Int32 Word32
              deriving (Show, Eq, Generic)
instance Bin.Binary MathExpr

blockSize :: Block -> Int
blockSize = fromIntegral . BL.length . Bin.encode

rawSize :: Block -> Int
rawSize (RawBlock b) = BS.length b
rawSize (TextZstdBlock raw _ _ _) = fromIntegral raw
rawSize (MathBlock n _ _) = fromIntegral n
rawSize (ZstdBlock n _) = fromIntegral n
rawSize (MathBlockV2 n _ _) = fromIntegral n
rawSize (MathBlockV3 n _ _) = fromIntegral n

compressedSize :: Block -> Int
compressedSize = blockSize

data Codec = Auto | MathOnly | ZstdOnly | RawOnly deriving (Show, Eq)

codecName :: Block -> String
codecName (RawBlock _) = "RAW"
codecName TextZstdBlock{} = "ZSTD"
codecName (MathBlock _ _ _) = "MATH"
codecName (MathBlockV2 _ _ _) = "MATH"
codecName (MathBlockV3 _ _ _) = "MATH"
codecName (ZstdBlock _ _) = "ZSTD"

mathFunctionCount :: Block -> Int
mathFunctionCount (MathBlock _ fs _) = length fs
mathFunctionCount (MathBlockV2 _ fs _) = length fs
mathFunctionCount (MathBlockV3 _ desc _) = case readVar (BS.unpack desc) of
  Right (n,_) -> fromIntegral n
  Left _ -> 0
mathFunctionCount _ = 0

-- Un segment couvre un sous-ensemble d'occurrences d'un octet. Le cas ou
-- la suite entiere n'est pas reguliere n'empeche plus la compression.
-- Recherche bornee (64 Kio), sans modele d'IA ni approximation avec perte.
-- V2 supporte les segments, contrairement a l'ancien MathBlock.
-- Les positions couvertes sont supprimees par INDICE, pas par valeur d'octet.
-- Format MATH v3: varints non signes et une etiquette par formule.
-- 0=progression, 1=ecarts periodiques, 2=quadratique (zig-zag).
-- Seules les expressions compactes et EXACTES sont admises.
putVar :: Integer -> [Word8]
putVar v
  | v < 0 = error "entier negatif dans putVar"
  | v < 128 = [fromIntegral v]
  | otherwise = fromIntegral (v `mod` 128 + 128) : putVar (v `div` 128)

readVar :: [Word8] -> Either String (Integer, [Word8])
readVar = go 0 0
  where
    go :: Integer -> Integer -> [Word8] -> Either String (Integer, [Word8])
    go shift value (b:bs)
      | shift > 35 = Left "Varint trop long"
      | otherwise =
          let v = value + toInteger (b `mod` 128) * (2 ^ shift)
          in if b < 128 then Right (v, bs) else go (shift + 7) v bs
    go _ _ [] = Left "Varint tronque"

zigzag :: Integer -> Integer
zigzag x = if x < 0 then -2*x - 1 else 2*x

unzigzag :: Integer -> Integer
unzigzag x = if odd x then -((x+1) `div` 2) else x `div` 2

encodeRule :: (Word8, MathExpr) -> [Word8]
encodeRule (byte, Linear a d n) = [byte, 0] ++ concatMap (putVar . toInteger) [a,d,n]
encodeRule (byte, Periodic a ds n) = [byte, 1] ++ putVar (toInteger a)
  ++ putVar (toInteger (length ds)) ++ concatMap (putVar . toInteger) ds ++ putVar (toInteger n)
encodeRule (byte, Quadratic a d dd n) = [byte, 2] ++ putVar (toInteger a)
  ++ putVar (toInteger d) ++ putVar (zigzag (toInteger dd)) ++ putVar (toInteger n)

encodeRules :: [(Word8, MathExpr)] -> BS.ByteString
encodeRules rules = BS.pack (putVar (toInteger (length rules)) ++ concatMap encodeRule rules)

decodeRules :: BS.ByteString -> Either String [(Word8, MathExpr)]
decodeRules dataBytes = do
  (count, rest) <- readVar (BS.unpack dataBytes)
  if count > 65536 then Left "Trop de fonctions mathematiques" else do
    (rules, tailBytes) <- parse (fromInteger count) rest
    if null tailBytes then Right rules else Left "Octets apres les fonctions"
  where
    parse :: Int -> [Word8] -> Either String ([(Word8, MathExpr)], [Word8])
    limited v = if v > 65536 then Left "Parametre de fonction trop grand" else Right (fromInteger v)
    parse 0 rest = Right ([], rest)
    parse n (byte:tag:rest) = do
      (a, afterA) <- readVar rest
      a' <- limited a
      (expr, afterExpr) <- case tag of
        0 -> do
          (d, r1) <- readVar afterA
          (count, r2) <- readVar r1
          d' <- limited d
          count' <- limited count
          Right (Linear a' d' count', r2)
        1 -> do
          (lengthPattern, r1) <- readVar afterA
          if lengthPattern < 1 || lengthPattern > 4 then Left "Periode invalide" else do
            (ds, r2) <- parseGaps (fromInteger lengthPattern) r1
            (count, r3) <- readVar r2
            count' <- limited count
            Right (Periodic a' ds count', r3)
        2 -> do
          (d, r1) <- readVar afterA
          (dd, r2) <- readVar r1
          (count, r3) <- readVar r2
          d' <- limited d
          count' <- limited count
          let dd' = unzigzag dd
          if dd' < toInteger (minBound :: Int32) || dd' > toInteger (maxBound :: Int32)
             then Left "Coefficient quadratique invalide"
             else Right (Quadratic a' d' (fromInteger dd') count', r3)
        _ -> Left "Type de fonction inconnu"
      (more, left) <- parse (n-1) afterExpr
      Right ((byte, expr):more, left)
    parse _ _ = Left "Fonctions tronquees"
    parseGaps :: Int -> [Word8] -> Either String ([Word32], [Word8])
    parseGaps 0 rest = Right ([], rest)
    parseGaps n rest = do
      (d, r) <- readVar rest
      d' <- limited d
      (ds, left) <- parseGaps (n-1) r
      Right (d':ds, left)

-- Recherche de progressions globales: les positions n'ont pas besoin d'etre
-- consecutives dans la liste d'occurrences. C'est un probleme de couverture
-- d'ensembles; l'heuristique choisit les regles par gain net en octets.
mathCandidatesV3 :: BS.ByteString -> [(Word8, MathExpr)]
mathCandidatesV3 input = map toRule (select IS.empty [] candidates)
  where
    posMap = snd $ BS.foldl' addPos (0 :: Int, IM.empty) input
    addPos (i, acc) b = (i+1, IM.insertWith (++) (fromIntegral b) [i] acc)
    groups = [(fromIntegral b :: Word8, reverse ps) | (b,ps) <- IM.toList posMap]
    candidates = sortBy (flip (comparing score))
      (filter ((> 0) . score) (concatMap groupCandidates groups))
    toRule (byte,expr,_,_) = (byte,expr)
    score (_,_,_,profit) = profit
    select _ chosen [] = reverse chosen
    select occupied chosen (c@(_,_,locations,_):rest)
      | length chosen >= 1024 = reverse chosen
      | IS.null (IS.intersection occupied locations) =
          select (IS.union occupied locations) (c:chosen) rest
      | otherwise = select occupied chosen rest
    makeCandidate byte expr =
      let places = exprPositions expr
          indices = either (const []) (map fromInteger) places
          locations = IS.fromList indices
          cost = length (encodeRule (byte,expr))
          valid = length indices == IS.size locations &&
                  all (\i -> i >= 0 && i < BS.length input && BS.index input i == byte) indices
      -- The rule count is stored once in every MathBlockV3. Charging one
      -- byte per candidate keeps the greedy pass from selecting many
      -- marginal rules that make the final serialized block larger.
      in (byte,expr,locations,if valid then IS.size locations - cost - 1 else -1)
    groupCandidates (byte,ps)
      | length ps < 7 = []
      | otherwise =
          let posSet = IS.fromList ps
              frequentSteps = filter ((>= 6) . snd) (IM.toList (stepFrequencies ps))
              steps = take 8 $ map fst $ sortBy
                (flip (comparing snd)) frequentSteps
              apCandidates = concatMap (runs byte ps posSet) steps
              periodicCandidates = concatMap (periodic byte ps) [1..4]
              quadraticCandidates = quadratic byte ps
          in apCandidates ++ periodicCandidates ++ quadraticCandidates
    periodic byte ps period
      | length ps < period + 8 = []
      | otherwise =
          let gaps = zipWith (-) (drop 1 ps) ps
              patternGaps = take period gaps
              repeated = 1 + length (takeWhile id
                (zipWith (==) gaps (cycle patternGaps)))
              count = min (length ps) repeated
          in [makeCandidate byte
                (Periodic (fromIntegral (case ps of first:_ -> first; [] -> 0))
                  (map fromIntegral patternGaps) (fromIntegral count))
             | count >= 22, all (> 0) patternGaps]
    quadratic byte (a:b:c:rest)
      | b > a && c > b =
          let first = b - a
              second = c - 2 * b + a
              tailDiff = zipWith (-) rest (c : rest)
              count = 3 + length (takeWhile (== second) tailDiff)
          in [makeCandidate byte
                (Quadratic (fromIntegral a) (fromIntegral first)
                  (fromIntegral second) (fromIntegral count))
             | count >= 20
             , toInteger second >= toInteger (minBound :: Int32)
             , toInteger second <= toInteger (maxBound :: Int32)]
    quadratic _ _ = []
    stepFrequencies ps = foldl' (\counts offset ->
      foldl' (\acc (a,b) ->
        let d = b-a in if d > 0 && d <= 4096
          then IM.insertWith (+) d (1::Int) acc else acc)
      counts (zip ps (drop offset ps))) IM.empty [1..6]
    runs byte ps posSet step
      | step <= 0 = []
      | otherwise =
          [ makeCandidate byte (Linear (fromIntegral p) (fromIntegral step) (fromIntegral n))
          | p <- ps, not (IS.member (p-step) posSet)
          , let n = runLength posSet p step
          , n >= 7 ]
    runLength :: IS.IntSet -> Int -> Int -> Int
    runLength posSet start step = go start 0
      where
        go !p !n | n < 65536 && IS.member p posSet = go (p+step) (n+1)
               | otherwise = n

compressBlock :: BS.ByteString -> Block
compressBlock input
  | BS.null input = RawBlock input
  | BS.length input > 65536 = RawBlock input
  -- Mathematical metadata is too expensive to amortize on tiny files.
  -- Keeping this path raw avoids building occurrence maps for the many
  -- small project files where no rule can beat the input anyway.
  | BS.length input < 4096 = RawBlock input
  | otherwise =
      let functions = mathCandidatesV3 input
          places = concatMap (\(_,expr) -> either (const []) (map fromInteger) (exprPositions expr)) functions
          removed = IS.fromList places
          leftovers = BS.pack [b | (i,b) <- zip [0..] (BS.unpack input), IS.notMember i removed]
          math = MathBlockV3 (fromIntegral (BS.length input)) (encodeRules functions) leftovers
          raw = RawBlock input
      in if not (null functions) && blockSize math < blockSize raw then math else raw

-- Cheap rejection test for the common case.  A useful mathematical rule
-- needs a repeated gap between occurrences of the same byte; inspect only
-- the first 8 KiB before allocating candidates for the complete block.
quickMathSignal :: BS.ByteString -> Bool
quickMathSignal input =
  any hasGapRun (IM.elems positions)
  where
    sample = BS.take 8192 input
    positions = snd (BS.foldl' addPos (0 :: Int, IM.empty) sample)
    addPos (index, acc) byte =
      (index + 1, IM.insertWith (++) (fromIntegral byte) [index] acc)
    hasGapRun reversedPositions =
      let ps = reverse reversedPositions
          gaps = zipWith (-) (drop 1 ps) ps
      in length gaps >= 64 &&
          (longestEqual gaps >= 63 || any (repeats gaps) [2..4] ||
            quadraticSignal gaps)
    repeats gaps period =
      length (takeWhile id
        (zipWith (==) gaps (cycle (take period gaps)))) >= 64
    quadraticSignal (_:rest@(_:_) ) =
      let second = zipWith (-) (drop 1 rest) rest
      in longestEqual second >= 62
    quadraticSignal _ = False
    longestEqual (x:xs) = 1 + length (takeWhile (== x) xs)
    longestEqual [] = 0

compressBytes :: BS.ByteString -> [Block]
compressBytes input
  | BS.null input = []
  | otherwise = let (a, rest) = BS.splitAt 65536 input
                in compressBlock a : compressBytes rest

exprCount :: MathExpr -> Word32
exprCount (Linear _ _ count) = count
exprCount (Periodic _ _ count) = count
exprCount (Quadratic _ _ _ count) = count

exprPositions :: MathExpr -> Either String [Integer]
exprPositions expr
  | count <= 0 || count > 65536 = Left "Nombre d'occurrences mathematiques invalide"
  | otherwise = case expr of
      Linear start step _
        | step == 0 -> Left "Pas lineaire nul"
        | otherwise -> Right [toInteger start + toInteger step * i | i <- [0..count-1]]
      Periodic start gaps _
        | null gaps || length gaps > 4 || any (==0) gaps -> Left "Motif periodique invalide"
        | otherwise -> Right (take (fromIntegral count)
                         (scanl (+) (toInteger start) (cycle (map toInteger gaps))))
      Quadratic start first second _ ->
        Right [toInteger start + toInteger first * i
              + toInteger second * i * (i-1) `div` 2 | i <- [0..count-1]]
  where count = toInteger (exprCount expr)

decompressBlock :: Block -> Either String BS.ByteString
decompressBlock (RawBlock bytes) = Right bytes
decompressBlock (TextZstdBlock wanted normalized tokenized encoded)
  | any (>67108864) [wanted,normalized,tokenized] = Left "Bloc texte trop grand"
  | otherwise = do
      tokenizedBytes <- decompressZstd tokenized encoded
      escaped <- restoreTextWords normalized tokenizedBytes
      restoreEscapes wanted escaped
decompressBlock (ZstdBlock size encoded) = decompressZstd size encoded
decompressBlock (MathBlock size functions leftovers)
  | size > 65536 = Left "Bloc mathematique historique trop grand"
  | otherwise = reconstruct size
      [ (v, Linear start step count) | (v,start,step,count) <- functions ] leftovers
decompressBlock (MathBlockV3 size desc leftovers)
  | size > 65536 = Left "Bloc mathematique V3 trop grand"
  | otherwise = do
      functions <- decodeRules desc
      reconstruct size functions leftovers
decompressBlock (MathBlockV2 size functions leftovers)
  | size > 65536 = Left "Bloc mathematique trop grand"
  | otherwise = reconstruct size functions leftovers

reconstruct :: Word32 -> [(Word8, MathExpr)] -> BS.ByteString -> Either String BS.ByteString
reconstruct size functions leftovers = do
  occupied <- foldM addFunction IM.empty functions
  if IM.size occupied + BS.length leftovers /= fromIntegral size
    then Left "Bloc corrompu : nombre de positions incoherent"
    else BS.pack <$> restore 0 (BS.unpack leftovers) occupied
  where
    addFunction acc (value, expr) = do
      positions <- exprPositions expr
      foldM (insertAt value) acc positions
    insertAt value acc p
      | p < 0 || p >= toInteger size = Left "Fonction : position hors bloc"
      | IM.member (fromInteger p) acc = Left "Fonctions : positions en conflit"
      | otherwise = Right (IM.insert (fromInteger p) value acc)
    restore idx remaining occupied
      | idx == fromIntegral size =
          if null remaining then Right [] else Left "Trop de donnees residuelles"
      | otherwise = case IM.lookup idx occupied of
          Just byte -> (byte :) <$> restore (idx+1) remaining occupied
          Nothing -> case remaining of
            [] -> Left "Donnees residuelles manquantes"
            byte:rest -> (byte :) <$> restore (idx+1) rest occupied

decompressBytes :: [Block] -> Either String BS.ByteString
decompressBytes blocks = BS.concat <$> mapM decompressBlock blocks

-- En AUTO, ZSTD est teste sur un grand bloc pour rester rapide. Si ZSTD
-- n'est pas rentable, recherche de fonctions sur des sous-blocs de 64 Kio.
-- Sur les petits blocs, on compare SYSTEMATIQUEMENT les deux representations.
compressBytesWith :: Codec -> Int -> BS.ByteString -> IO [Block]
compressBytesWith codec level input
  | BS.null input = return []
  | otherwise = do
      let pieces = splitPieces input
          workers = max 1 . min 4 <$> getNumCapabilities
      selected <- if BS.length input > 67108864 && length pieces > 1
        then do
          count <- workers
          traceEvent "large_file_blocks_parallel"
            [("bytes", show (BS.length input)), ("blocks", show (length pieces)),
             ("workers", show count)]
          parallelMapBounded count choose pieces
        else mapM choose pieces
      return (concat selected)
  where
    chunkSize = if level >= 12 then 4194304 else 1048576
    splitPieces bytes
      | BS.null bytes = []
      | otherwise =
          let (piece, rest) = BS.splitAt chunkSize bytes
          in piece : splitPieces rest

    splitMath piece = do
      let chunks = chunksOf 65536 piece
      if length chunks <= 1
        then mapM compressOne chunks
        else do
          capabilities <- getNumCapabilities
          let workers = max 1 (min 16 capabilities)
          parallelMapBounded workers compressOne chunks

    compressOne chunk = do
      block <- evaluate (compressMathBlock chunk)
      -- Force the actual binary size while the worker is running.
      _ <- evaluate (compressedSize block)
      return block

    compressMathBlock chunk
      | (codec == MathOnly || codec == Auto) &&
          (BS.length chunk < 65536 || not (quickMathSignal chunk)) =
          RawBlock chunk
      | otherwise = compressBlock chunk

    choose piece
      | codec == RawOnly = return [RawBlock piece]
      | codec == MathOnly = splitMath piece
      | otherwise = do
          encoded <- compressZstd level piece
          let raw = RawBlock piece
              packed = case encoded of
                Right bytes -> ZstdBlock (fromIntegral (BS.length piece)) bytes
                Left _ -> raw
              best = if blockSize packed < blockSize raw then packed else raw
          if codec == ZstdOnly
            then return [best]
            else if codec == Auto && level <= 1
              then return [best]
            else do
              -- MATH and ZSTD use different block boundaries.  Comparing
              -- their actual serialized sizes is necessary: a Zstd block
              -- smaller than RAW can still lose to several compact MATH
              -- blocks.  Keep the expensive search bounded to the normal
              -- chunk size; larger pieces are only searched when Zstd did
              -- not improve on RAW.
              let shouldTryMath =
                    case codec of
                      Auto -> BS.length piece > 65536 && best == raw
                      _ -> BS.length piece <= 65536 || best == raw
              alternatives <- if shouldTryMath then splitMath piece else return []
              let altSize = sum (map blockSize alternatives)
              return
                (if shouldTryMath && altSize < blockSize best
                   then alternatives
                   else [best])

-- Solid groups use one ZSTD stream so repeated dictionaries can span the
-- original file boundaries.  The archive layer stores the file offsets.
compressSolidBytesWith :: Codec -> Int -> BS.ByteString -> IO [Block]
compressSolidBytesWith codec level input
  | codec == RawOnly = return [RawBlock input]
  | codec == MathOnly = compressBytesWith codec level input
  | otherwise = do
      encoded <- compressZstd level input
      -- When quality matters, try a wide-window frame as well. Do not use
      -- it if it does not improve the *actual serialized* block size.
      window <- if level >= 15 && BS.length input >= 8388608
        then compressZstdWindow level input
        else return (Left "small solid block")
      long <- if level >= 15 && BS.length input >= 8388608
        then compressZstdLong level input
        else return (Left "small solid block")
      let raw = RawBlock input
          candidates = raw :
            [ZstdBlock (fromIntegral (BS.length input)) bytes |
              Right bytes <- [encoded, window, long]]
          best = foldl1 (\a b -> if blockSize b < blockSize a then b else a) candidates
      return [best]

-- One native compression per solid group. Keep RAW only when it is smaller;
-- a native LDM error falls back to ordinary ZSTD, not directly to RAW.
-- Larger standalone files retain the existing bounded block decomposition.
compressSolidBytesDirectWith :: Codec -> Int -> BS.ByteString -> IO [Block]
compressSolidBytesDirectWith codec level input
  | BS.length input > 67108864 = compressBytesWith codec level input
  | codec == RawOnly = return [RawBlock input]
  | codec == MathOnly = compressBytesWith codec level input
  | otherwise = do
      packed <- if level >= 15 && BS.length input >= 8388608
        then do
          long <- compressZstdLong level input
          case long of
            Right bytes -> return (Right bytes)
            Left _ -> compressZstd level input
        else compressZstd level input
      let raw = RawBlock input
          encoded = case packed of
            Right bytes -> ZstdBlock (fromIntegral (BS.length input)) bytes
            Left _ -> raw
      return [if blockSize encoded < blockSize raw then encoded else raw]

-- Fixed job boundaries and overlap keep native MT deterministic across worker
-- counts. Unsupported ZSTD multithreading falls back to the serial profile.
compressSolidBytesTurboWith :: Codec -> Int -> BS.ByteString -> IO [Block]
compressSolidBytesTurboWith codec level input
  | codec == RawOnly || codec == MathOnly || BS.length input < 8388608 ||
    BS.length input > 67108864 || level < 17 =
      compressSolidBytesDirectWith codec level input
  | otherwise = do
      workers <- max 1 . min 4 <$> getNumCapabilities
      packed <- if BS.length input >= 1048576
        then compressZstdLongMT level workers input
        else compressZstdLong level input
      case packed of
        Left _ -> compressSolidBytesDirectWith codec level input
        Right bytes -> do
          let raw = RawBlock input
              encoded = ZstdBlock (fromIntegral (BS.length input)) bytes
          return [if blockSize encoded < blockSize raw then encoded else raw]

-- Reversible lexical preprocessing; every original byte is reconstructed.
compressSolidTextWith :: Codec -> Int -> BS.ByteString -> IO [Block]
compressSolidTextWith codec level input
  | codec == RawOnly || codec == MathOnly || level < 12 || BS.length input < 262144 ||
    BS.length input > 67108864 = compressSolidBytesDirectWith codec level input
  | otherwise = do
      normalized <- normalizeEscapes input
      transformed <- case normalized of
        Left err -> return (Left err)
        Right bytes -> do
          tokenizedBytes <- encodeTextWords bytes
          case tokenizedBytes of
            Left err -> return (Left err)
            Right tokens -> do
              workers <- max 1 . min 4 <$> getNumCapabilities
              packed <- compressZstdText workers tokens
              return (fmap (\payload -> TextZstdBlock
                (fromIntegral (BS.length input)) (fromIntegral (BS.length bytes))
                (fromIntegral (BS.length tokens)) payload) packed)
      case transformed of
        Left _ -> compressSolidBytesTurboWith codec (max 17 level) input
        Right block -> return [if blockSize block < blockSize (RawBlock input)
          then block else RawBlock input]

chunksOf :: Int -> BS.ByteString -> [BS.ByteString]
chunksOf size bytes
  | BS.null bytes = []
  | otherwise = let (a,b) = BS.splitAt size bytes in a : chunksOf size b

parallelMapBounded :: forall a b. Int -> (a -> IO b) -> [a] -> IO [b]
parallelMapBounded workers action items
  | workers <= 1 = mapM action items
  | null items = return []
  | otherwise = do
      traceEvent "math_pool_start"
        [("workers", show workers), ("tasks", show (length items))]
      queue <- newChan
      slots <- mapM (const newEmptyMVar) items
      forM_ (zip3 [0 :: Int ..] items slots) (writeChan queue . Just)
      replicateM_ workers (writeChan queue Nothing)
      replicateM_ workers $ do
        _ <- forkIO (worker queue)
        return ()
      results <- mapM takeMVar slots
      mapM (either throwIO return) results
  where
    worker :: Chan (Maybe (Int, a, MVar (Either SomeException b))) -> IO ()
    worker queue = do
      next <- readChan queue
      case next of
        Nothing -> return ()
        Just (index, item, slot) -> do
          started <- traceSpanStart "math_task" [("index", show index)]
          result <- try (action item)
          traceSpanEnd "math_task" started
            [("index", show index),
             ("result", either (const "error") (const "ok") result)]
          putMVar slot result
          worker queue
