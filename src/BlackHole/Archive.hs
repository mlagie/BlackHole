{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE ScopedTypeVariables #-}
module BlackHole.Archive
  ( Archive(..), Entry(..), SymlinkMode(..), CompressionPlan(..), makeArchiveWithPlanProgress, makeArchiveWithPlanProgressFiles, makeArchiveWithPlanProgressFilesWorkers, makeArchive, makeArchiveWith
  , makeArchiveWithConfig, makeArchiveWithConfigProgress, makeArchiveDirectWithProgress, makeArchiveBalancedWithProgress
  , encodePathSkeleton, decodePathSkeleton
  , archiveStats, archiveMathFunctions
  , saveArchive, saveArchiveWithProgress, serializeArchive, archiveWireSize, buildDeltaSolidArchive, loadArchive, extractArchive, verifyArchive, archiveSummary
  ) where

import BlackHole.Hash (hashBytes)
import BlackHole.Platform (FileKind(..), fileKind, readArchiveLink, createArchiveLink)
import BlackHole.PortablePaths (isHostWindows, toArchivePath, fromArchivePath, validateWindowsPaths, nativePathKey)
import Data.IORef (newIORef, readIORef, modifyIORef')
import BlackHole.Engine
import BlackHole.Chunking (splitChunks)
import BlackHole.Delta (applyDelta, buildDelta, decodeDelta, encodeDelta)
import BlackHole.Zstd (compressZstd, decompressArchiveZstd)
import BlackHole.Diagnostics (traceEvent, traceSpanStart, traceSpanEnd)
import Control.Monad (forM_, unless, when, replicateM, replicateM_, foldM)
import Control.Concurrent (forkIO, getNumCapabilities, myThreadId)
import Control.Concurrent.Chan (newChan, readChan, writeChan)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar, newMVar, modifyMVar_)
import Control.Exception (SomeException, try, throwIO, evaluate)
import System.IO.Error (catchIOError, isDoesNotExistError)
import qualified Data.Binary as Bin
import qualified Data.Binary.Get as Get
import qualified Data.Binary.Put as Put
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.List (sort, sortOn, foldl', groupBy, isInfixOf, isSuffixOf, isPrefixOf, intercalate)
import Data.Char (toLower, ord, chr)
import System.IO (withBinaryFile, IOMode(ReadMode, WriteMode), hFlush)
import Data.Word (Word32, Word64)
import Data.Bits ((.&.), (.|.), shiftL, shiftR)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import GHC.Generics (Generic)
import GHC.Clock (getMonotonicTimeNSec)
import System.Directory
  ( canonicalizePath, createDirectory, createDirectoryIfMissing
  , doesDirectoryExist, doesPathExist, getFileSize, listDirectory
  , pathIsSymbolicLink, findExecutable )
import System.FilePath
  ( (</>), isAbsolute, splitDirectories, takeDirectory
  , takeFileName, dropTrailingPathSeparator, makeRelative )
import qualified System.FilePath.Posix as A
import qualified System.Process as Process
import System.Exit (ExitCode(..))
import GHC.IO.Encoding (getFileSystemEncoding)
import qualified GHC.Foreign as Encoding

-- BH02 adds LinkEntry; BH01 archives can still be read.
data Entry = DirEntry FilePath | FileEntry FilePath [Block]
           | LinkEntry FilePath FilePath
           | SolidEntry [(FilePath, Word32)] [Block]
           | FileRefEntry FilePath FilePath Word32
           | ChunkEntry FilePath [(Word32, Word32)]
           | DeltaEntry FilePath FilePath Word32 [Block]
  deriving (Show, Generic)
instance Bin.Binary Entry

data ChunkRecord = ChunkRecord Word32 Word32 [Block]
  deriving (Show, Generic)
instance Bin.Binary ChunkRecord

data Archive = Archive [Entry]
            | ChunkArchive [Entry] [ChunkRecord]
  deriving (Show, Generic)
instance Bin.Binary Archive

isDeltaEntry :: Entry -> Bool
isDeltaEntry DeltaEntry{} = True
isDeltaEntry _ = False

-- The legacy structure must retain the BH01 constructor order.
data LegacyEntry = LegacyDir FilePath | LegacyFile FilePath [Block]
  deriving (Generic)
instance Bin.Binary LegacyEntry
newtype LegacyArchive = LegacyArchive [LegacyEntry] deriving (Generic)
instance Bin.Binary LegacyArchive

data SymlinkMode = SkipSymlinks | PreserveSymlinks | FollowSymlinks
  deriving (Show, Eq)

bh12Magic :: BL.ByteString
bh12Magic = BL.fromStrict (BS.pack [66,72,49,50])

bh11Magic :: BL.ByteString
bh11Magic = BL.fromStrict (BS.pack [66,72,49,49])

bh10Magic :: BL.ByteString
bh10Magic = BL.fromStrict (BS.pack [66, 72, 49, 48]) -- BH10

bh09Magic :: BL.ByteString
bh09Magic = BL.fromStrict (BS.pack [66, 72, 48, 57]) -- BH09

magic :: BL.ByteString
magic = BL.fromStrict (BS.pack [66, 72, 48, 55]) -- BH07

bh08Magic :: BL.ByteString
bh08Magic = BL.fromStrict (BS.pack [66, 72, 48, 56])

bh06Magic :: BL.ByteString
bh06Magic = BL.fromStrict (BS.pack [66, 72, 48, 54])

archiveWireSize :: Archive -> IO Integer
archiveWireSize archive = fromIntegral . BL.length <$> serializeArchive archive

smallerArchive :: Archive -> Archive -> IO Archive
smallerArchive baseline candidate = do
  oldSize <- archiveWireSize baseline
  newSize <- archiveWireSize candidate
  return (if newSize < oldSize then candidate else baseline)

validateArchive :: Archive -> Either String ()
validateArchive (Archive entries) = validatePaths entries
validateArchive (ChunkArchive entries records) = do
  validatePaths entries
  let ids = Set.fromList [ident | ChunkRecord ident _ _ <- records]
      refs = [(ident, size) | ChunkEntry _ chunks <- entries,
                              (ident, size) <- chunks]
  if length ids /= length records || any ((`Set.notMember` ids) . fst) refs
    then Left "Reference de fragment invalide"
    else if any invalidSize records
      then Left "Taille de fragment invalide"
      else Right ()
  where
    invalidSize (ChunkRecord _ size blocks) =
      size == 0 || fromIntegral size /= sum (map rawSize blocks)

currentPreviousMagic :: BL.ByteString
currentPreviousMagic = BL.fromStrict (BS.pack [66, 72, 48, 53]) -- BH05

previousMagic :: BL.ByteString
previousMagic = BL.fromStrict (BS.pack [66, 72, 48, 52]) -- BH04

legacy3Magic :: BL.ByteString
legacy3Magic = BL.fromStrict (BS.pack [66, 72, 48, 51]) -- BH03

legacy2Magic :: BL.ByteString
legacy2Magic = BL.fromStrict (BS.pack [66, 72, 48, 50]) -- BH02

oldMagic :: BL.ByteString
oldMagic = BL.fromStrict (BS.pack [66, 72, 48, 49]) -- BH01

-- pathIsSymbolicLink throws on missing paths on some Unix versions.
-- A missing path is not a symlink; propagate all other I/O errors.
pathIsSymbolicLinkSafe :: FilePath -> IO Bool
pathIsSymbolicLinkSafe path =
  pathIsSymbolicLink path `catchIOError` \err ->
    if isDoesNotExistError err then return False else ioError err

makeArchive :: FilePath -> IO Archive
makeArchive = makeArchiveWith PreserveSymlinks

makeArchiveWith :: SymlinkMode -> FilePath -> IO Archive
makeArchiveWith mode = makeArchiveWithConfig mode Auto 8

makeArchiveWithConfig :: SymlinkMode -> Codec -> Int -> FilePath -> IO Archive
makeArchiveWithConfig mode codec level =
  makeArchiveWithConfigProgress mode codec level (\_ _ -> return ())

makeArchiveWithConfigProgress :: SymlinkMode -> Codec -> Int -> (Integer -> Integer -> IO ()) -> FilePath -> IO Archive
makeArchiveWithConfigProgress mode codec level report =
  makeArchiveUsing Nothing SearchPlan mode codec level (\done total _ -> report done total)

makeArchiveDirectWithProgress :: SymlinkMode -> Codec -> Int -> (Integer -> Integer -> IO ()) -> FilePath -> IO Archive
makeArchiveDirectWithProgress mode codec level report =
  makeArchiveUsing Nothing DirectPlan mode codec level (\done total _ -> report done total)

makeArchiveBalancedWithProgress :: SymlinkMode -> Codec -> Int -> (Integer -> Integer -> IO ()) -> FilePath -> IO Archive
makeArchiveBalancedWithProgress mode codec level report =
  makeArchiveUsing Nothing BalancedPlan mode codec level (\done total _ -> report done total)

data CompressionPlan = SearchPlan | DirectPlan | BalancedPlan | TurboPlan deriving (Show, Eq)

makeArchiveWithPlanProgress :: CompressionPlan -> SymlinkMode -> Codec -> Int -> (Integer -> Integer -> IO ()) -> FilePath -> IO Archive
makeArchiveWithPlanProgress plan mode codec level report =
  makeArchiveUsing Nothing plan mode codec level (\done total _ -> report done total)

makeArchiveWithPlanProgressFiles :: CompressionPlan -> SymlinkMode -> Codec -> Int -> (Integer -> Integer -> FilePath -> IO ()) -> FilePath -> IO Archive
makeArchiveWithPlanProgressFiles = makeArchiveUsing Nothing

-- Optional explicit worker count. Work is taken dynamically from the shared
-- batch queue, not statically divided into equal file-count partitions.
makeArchiveWithPlanProgressFilesWorkers :: Int -> CompressionPlan -> SymlinkMode -> Codec -> Int -> (Integer -> Integer -> FilePath -> IO ()) -> FilePath -> IO Archive
makeArchiveWithPlanProgressFilesWorkers requested = makeArchiveUsing (Just (max 1 (min 64 requested)))

makeArchiveUsing :: Maybe Int -> CompressionPlan -> SymlinkMode -> Codec -> Int -> (Integer -> Integer -> FilePath -> IO ()) -> FilePath -> IO Archive
makeArchiveUsing requestedWorkers plan mode codec level report input = do
  traceEvent "compression_config"
    [("plan", show plan), ("codec", show codec), ("level", show level),
     ("input", input)]
  gatherStarted <- traceSpanStart "gather" []
  isLink <- pathIsSymbolicLinkSafe input
  exists <- doesPathExist input
  unless (isLink || exists) (ioError (userError "Chemin introuvable"))
  let basename = takeFileName (dropTrailingPathSeparator input)
      root = if basename == "." || null basename then "BlackHoleData" else basename
  -- In follow mode, a link may point anywhere at the root, but links found
  -- *within* this root cannot escape the canonical input directory.
  canonicalRoot <- canonicalizePath input
  rootIsDir <- doesDirectoryExist canonicalRoot
  let permittedRoot = if rootIsDir then canonicalRoot else takeDirectory canonicalRoot
  finder <- if not isHostWindows && plan == TurboPlan && not isLink && rootIsDir && mode /= FollowSymlinks
    then catchIOError (findExecutable "find") (\err ->
      if isDoesNotExistError err then return Nothing else ioError err) else return Nothing
  gathered <- case finder of
    Just executable -> gatherNative executable mode canonicalRoot input root
    Nothing -> gather permittedRoot Set.empty Nothing input root
  traceSpanEnd "gather" gatherStarted [("entries", show (length gathered))]
  dedupStarted <- traceSpanStart "deduplicate" []
  pending <- deduplicatePending gathered
  traceSpanEnd "deduplicate" dedupStarted
    [("pending", show (length pending))]
  -- File sizes are independent metadata reads.  Spread them across a small
  -- I/O pool while limiting outstanding disk operations.
  sizeStarted <- traceSpanStart "stat_sizes" []
  totalBytes <- sum <$> workerMap (max 1 (min 4 (length pending))) pendingSize pending
  traceSpanEnd "stat_sizes" sizeStarted [("bytes", show totalBytes)]
  progress <- newMVar 0
  let reportProgress bytes relative = modifyMVar_ progress $ \done -> do
        let next = done + bytes
        report next totalBytes relative
        return next
  capabilities <- getNumCapabilities
  -- Le nombre de threads est borne; l'ordre des entrees reste deterministe.
  let automaticWorkers = case codec of
        MathOnly -> max 1 (min 4 capabilities)
        -- ZSTD at high quality uses substantially more memory per batch.
        -- Four simultaneous large batches bound peak RAM while making use of
        -- multicore CPUs; lower levels can sustain more parallel batches.
        Auto -> max 1 (min (if level >= 20 then 2 else if level >= 15 then 4 else 8) capabilities)
        _ -> max 1 (min (if level >= 20 then 2 else if level >= 15 then 8 else 16) capabilities)
      workerCount = maybe automaticWorkers (max 1 . min 64) requestedWorkers
      -- Create several independent solid jobs per worker, provided there is
      -- sufficient input. This reduces idle cores on trees of small files.
      -- Keep a 1 MiB minimum target to preserve useful solid compression.
      batchLimit = max 1048576 (min 67108864 (totalBytes `div` fromIntegral (max 1 (workerCount * 4))))
  if direct
    then do
      directStarted <- traceSpanStart "encode_direct" []
      batches <- if packaged then groupPendingByPackageAtLimit batchLimit (plan == TurboPlan) level pending
        else groupPendingBySimilarityAt batchLimit pending
      traceEvent "batches"
        [("kind", "direct"), ("count", show (length batches)),
         ("workers", show workerCount), ("limit", show batchLimit)]
      entries <- concat <$> workerMap workerCount
        (encodePendingBatch reportProgress) batches
      traceSpanEnd "encode_direct" directStarted
        [("batches", show (length batches)), ("entries", show (length entries))]
      either (ioError . userError) return (validatePaths entries)
      return (Archive entries)
    else do
      searchStarted <- traceSpanStart "encode_search" []
      -- Standard BH06 baseline. In higher-quality mode we also evaluate an
      -- alternative solid ordering. Only the smaller *serialized* archive wins.
      batches <- groupPending level pending
      entries <- concat <$> workerMap workerCount
        (encodePendingBatch reportProgress) batches
      traceSpanEnd "encode_search" searchStarted
        [("batches", show (length batches)), ("entries", show (length entries))]
      either (ioError . userError) return (validatePaths entries)
      let regular = Archive entries
      improved <- if level >= 10 && codec /= RawOnly
        then do
          candidateStarted <- traceSpanStart "candidate_similarity" []
          similarBatches <- groupPendingBySimilarity level pending
          similarEntries <- concat <$> workerMap workerCount
            (encodePendingBatch (\_ _ -> return ())) similarBatches
          traceSpanEnd "candidate_similarity" candidateStarted
            [("batches", show (length similarBatches)),
             ("entries", show (length similarEntries))]
          either (ioError . userError) return (validatePaths similarEntries)
          let candidate = Archive similarEntries
          smallerArchive regular candidate
        else return regular
      -- Ultra quality: compare an additional, larger solid grouping. Keeping
      -- the smallest fully encoded archive avoids regressions in output size.
      ultra <- if level >= 15 && codec /= RawOnly && codec /= MathOnly
        then do
          candidateStarted <- traceSpanStart "candidate_32m" []
          hugeBatches <- groupPendingBySimilarityAt 33554432 pending
          hugeEntries <- concat <$> workerMap (max 1 (min 4 workerCount))
            (encodePendingBatch (\_ _ -> return ())) hugeBatches
          traceSpanEnd "candidate_32m" candidateStarted
            [("batches", show (length hugeBatches)),
             ("entries", show (length hugeEntries))]
          either (ioError . userError) return (validatePaths hugeEntries)
          let candidate = Archive hugeEntries
          smallerArchive improved candidate
        else return improved
      -- Explore the decoder's full 64 MiB block limit. The complete BH10
      -- serialization decides whether this wider context is worth retaining.
      widest <- if level >= 15 && codec /= RawOnly && codec /= MathOnly
        then do
          candidateStarted <- traceSpanStart "candidate_64m" []
          wideBatches <- groupPendingBySimilarityAt 67108864 pending
          wideEntries <- concat <$> workerMap workerCount
            (encodePendingBatch (\_ _ -> return ())) wideBatches
          traceSpanEnd "candidate_64m" candidateStarted
            [("batches", show (length wideBatches)),
             ("entries", show (length wideEntries))]
          smallerArchive ultra (Archive wideEntries)
        else return ultra
      -- Hybrid candidates retain the winning solid layout. The search budget is
      -- independent of the number of paths in the tree.
      delta <- if level >= 8 && codec /= MathOnly && codec /= RawOnly
        then do
          candidateStarted <- traceSpanStart "candidate_delta" []
          result <- buildDeltaSolidArchive codec level
            [(p, f) | PendingFile p f _ <- pending] widest
          traceSpanEnd "candidate_delta" candidateStarted
            [("selected", show (maybe False (const True) result))]
          return result
        else return Nothing
      withDelta <- maybe (return widest) (smallerArchive widest) delta
      chunkStarted <- traceSpanStart "candidate_chunks" []
      chunked <- buildChunkArchive codec (level :: Int) (\_ -> return ()) gathered
      traceSpanEnd "candidate_chunks" chunkStarted
        [("selected", show (maybe False (const True) chunked))]
      maybe (return withDelta) (smallerArchive withDelta) chunked
  where
    direct = plan /= SearchPlan
    packaged = plan == BalancedPlan || plan == TurboPlan
    pendingSize (PendingFile _ full _) = getFileSize full
    pendingSize _ = return 0

    encodePendingBatch = encodePendingBatchAt level False
    encodePendingBatchAt _ _ progress (PendingProfile quality normalized batch) =
      encodePendingBatchAt quality normalized progress batch
    encodePendingBatchAt _ _ _ (PendingSingle (PendingDir relative)) = return [DirEntry relative]
    encodePendingBatchAt _ _ _ (PendingSingle (PendingLink relative target)) =
      return [LinkEntry relative target]
    encodePendingBatchAt _ _ _ (PendingSingle (PendingRef relative target size)) =
      return [FileRefEntry relative target size]
    encodePendingBatchAt selectedLevel normalized reportProgress (PendingSingle file) =
      encodeFilesAt selectedLevel normalized reportProgress [file]
    encodePendingBatchAt selectedLevel normalized reportProgress (PendingFiles files) =
      encodeFilesAt selectedLevel normalized reportProgress files

    encodeFilesAt selectedLevel normalized reportProgress files = do
      contents <- mapM readPendingFile files
      let joined = BS.concat (map snd contents)
          sourceBytes = BS.length joined
      traceEvent "compression_batch"
        [("files", show (length files)), ("bytes", show sourceBytes),
         ("level", show selectedLevel), ("normalized", show normalized)]
      compressionStarted <- traceSpanStart "compression_batch" []
      blocks <- if normalized then compressSolidTextWith codec selectedLevel joined
        else if plan == TurboPlan then compressSolidBytesTurboWith codec selectedLevel joined
        else if direct then compressSolidBytesDirectWith codec selectedLevel joined
        else case files of
          [_] -> do
            directBlocks <- compressBytesWith codec selectedLevel joined
            if selectedLevel >= 15 && BS.length joined >= 8388608 &&
               BS.length joined <= 67108864 && codec /= RawOnly && codec /= MathOnly
              then do
                solid <- compressSolidBytesWith codec selectedLevel joined
                return (if BL.length (Bin.encode solid) < BL.length (Bin.encode directBlocks)
                  then solid else directBlocks)
              else return directBlocks
          _ -> compressSolidBytesWith codec selectedLevel joined
      traceSpanEnd "compression_batch" compressionStarted
        [("files", show (length files)), ("bytes", show sourceBytes),
         ("blocks", show (length blocks)),
         ("encoded_bytes", show (sum (map compressedSize blocks)))]
      forM_ contents $ \(file, bytes) ->
        reportProgress (fromIntegral (BS.length bytes)) (pendingRelativePath file)
      case files of
        [PendingFile relative _ _] -> return [FileEntry relative blocks]
        _ -> return [SolidEntry
              [(relative, fromIntegral (BS.length bytes)) | (PendingFile relative _ _, bytes) <- contents]
              blocks]

    readPendingFile (PendingFile relative full cached) = do
      bytes <- maybe (BS.readFile full) return cached
      return (PendingFile relative full (Just bytes), bytes)
    readPendingFile _ = ioError (userError "Groupe de compression invalide")

    pendingRelativePath (PendingFile relative _ _) = relative
    pendingRelativePath _ = ""

    buildChunkArchive :: Codec -> Int -> (Int -> IO ()) -> [Pending] -> IO (Maybe Archive)
    buildChunkArchive selectedCodec selectedLevel progress items = do
      (builtEntries, records) <- buildChunks Map.empty 0 [] [] items
      let candidate = ChunkArchive (reverse builtEntries) (reverse records)
      if null records then return Nothing else do
        either (ioError . userError) (const (return (Just candidate)))
          (validateArchive candidate)
      where
        buildChunks _ _ accEntries accRecords [] =
          return (accEntries, accRecords)
        buildChunks index next accEntries accRecords (item:rest) =
          case item of
            PendingDir path ->
              buildChunks index next (DirEntry path:accEntries) accRecords rest
            PendingLink path target ->
              buildChunks index next (LinkEntry path target:accEntries) accRecords rest
            PendingFile path full _ -> do
              bytes <- BS.readFile full
              (refs, next', index', newRecords) <-
                buildFileChunks index next accRecords bytes
              _ <- progress (fromIntegral (BS.length bytes))
              buildChunks index' next'
                (ChunkEntry path refs:accEntries) newRecords rest
            PendingRef path target size ->
              buildChunks index next
                (FileRefEntry path target size:accEntries) accRecords rest

        buildFileChunks index next records bytes = do
          (refsRev, nextId, known, stored) <-
            foldM addChunk ([], next, index, records) (splitChunks bytes)
          return (reverse refsRev, nextId, known, stored)
          where
            addChunk (refs, current, known, stored) chunk =
              let key = contentHash chunk
                  candidates = Map.findWithDefault [] key known
              in case findChunk chunk candidates of
                Just ident ->
                  return ((ident, fromIntegral (BS.length chunk)):refs,
                    current, known, stored)
                Nothing -> do
                  blocks <- compressBytesWith selectedCodec selectedLevel chunk
                  let ident = current + 1
                      record = ChunkRecord ident
                        (fromIntegral (BS.length chunk)) blocks
                      known' = Map.insertWith (++)
                        key [(chunk, ident)] known
                  return ((ident, fromIntegral (BS.length chunk)):refs,
                    ident, known', record:stored)

            findChunk _ [] = Nothing
            findChunk chunk ((chunkBytes, ident):rest)
              | chunk == chunkBytes = Just ident
              | otherwise = findChunk chunk rest

    gather permittedRoot ancestors parent full relative = do
      status <- fileKind False full
      if status == SymbolicLink then case mode of
        SkipSymlinks -> return []
        PreserveSymlinks -> do
          target <- readArchiveLink full
          unless (safeLinkTarget relative target) $
            ioError (userError ("Lien symbolique hors de l'archive ou absolu : " ++ full ++ " -> " ++ target))
          return [PendingLink relative target]
        FollowSymlinks -> do
          followed <- fileKind True full
          visit permittedRoot ancestors Nothing followed full relative
      else visit permittedRoot ancestors parent status full relative

    visit permittedRoot ancestors _ status full relative = do
      -- Resolve every visited path before containment/cycle checks. One lstat
      -- supplies the file type without two redundant status queries.
      canonical <- canonicalizePath full
      unless (inside permittedRoot canonical) $
        ioError (userError ("Lien symbolique hors du dossier source : " ++ full))
      if status == Directory
        then do
          when (Set.member (nativePathKey canonical) ancestors) $
            ioError (userError ("Boucle de liens symboliques : " ++ full))
          names <- sort <$> listDirectory full
          let child name = gather permittedRoot (Set.insert (nativePathKey canonical) ancestors)
                (Just canonical) (full </> name) (relative A.</> toArchivePath name)
          -- Parallelize the *root's* independent subtrees for every plan.
          -- Nested directories remain sequential to avoid spawning an
          -- unbounded number of competing directory scans on slow disks.
          children <- if Set.null ancestors && length names > 1
            then do
              capabilities <- getNumCapabilities
              workerMap (max 1 (min 8 capabilities)) child names
            else mapM child names
          return (PendingDir relative : concat children)
        else if status == RegularFile
          then return [PendingFile relative full Nothing]
          else ioError (userError ("Type de fichier non pris en charge : " ++ full))

gatherNative :: FilePath -> SymlinkMode -> FilePath -> FilePath -> FilePath -> IO [Pending]
gatherNative executable mode canonicalRoot source root = do
  raw <- Process.withCreateProcess
    (Process.proc executable ["-P", canonicalRoot, "-printf", "%y\\0%P\\0%l\\0"])
      { Process.std_out = Process.CreatePipe } $ \_ output _ handle -> do
        bytes <- case output of
          Just pipe -> BS.hGetContents pipe
          Nothing -> ioError (userError "Parcours natif: sortie indisponible")
        code <- Process.waitForProcess handle
        unless (code == ExitSuccess) (ioError (userError "Parcours natif incomplet"))
        return bytes
  encoding <- getFileSystemEncoding
  let decode bytes = BS.useAsCStringLen bytes (Encoding.peekCStringLen encoding)
      parse [lastField] | BS.null lastField = return []
      parse (kind:relative:target:rest) | BS.length kind == 1 = do
        name <- decode relative
        let archivePath = if null name then root else root A.</> name
            full = if null name then source else source </> name
        unless (safeName archivePath) (ioError (userError "Chemin natif invalide"))
        item <- case BS.head kind of
          100 -> return (Just (PendingDir archivePath))
          102 -> return (Just (PendingFile archivePath full Nothing))
          108 | mode == SkipSymlinks -> return Nothing
              | otherwise -> do
                  link <- decode target
                  unless (safeLinkTarget archivePath link) $
                    ioError (userError ("Lien symbolique dangereux : " ++ archivePath))
                  return (Just (PendingLink archivePath link))
          _ -> ioError (userError ("Type de fichier non pris en charge : " ++ archivePath))
        tailItems <- parse rest
        return (maybe tailItems (:tailItems) item)
      parse _ = ioError (userError "Parcours natif tronque")
  items <- parse (BS.split 0 raw)
  when (null items) (ioError (userError "Parcours natif vide"))
  return (sortOn key items)
  where
    key (PendingDir path) = A.splitDirectories (A.dropTrailingPathSeparator path)
    key (PendingFile path _ _) = A.splitDirectories path
    key (PendingLink path _) = A.splitDirectories path
    key (PendingRef path _ _) = A.splitDirectories path

data Pending = PendingDir FilePath | PendingLink FilePath FilePath
             | PendingRef FilePath FilePath Word32
             | PendingFile FilePath FilePath (Maybe BS.ByteString)

-- Deterministic budgets for DELTA exploration (not a bound on the complete
-- archiver): 32 MiB source cache per epoch, 128 MiB input reads, 128 MiB
-- base+target bytes attempted, two bases per target, <=128 signatures per source,
-- <=8 sources per signature. No delta chains: only retained originals enter
-- the index. Resetting an epoch trades search coverage for bounded memory.
buildDeltaSolidArchive :: Codec -> Int -> [(FilePath, FilePath)] -> Archive -> IO (Maybe Archive)
buildDeltaSolidArchive selectedCodec selectedLevel sourcePaths (Archive baseline) = do
  deltas <- search Map.empty Map.empty 0 0 0 Map.empty items
  if Map.null deltas then return Nothing else do
    rebuilt <- concat <$> mapM (rebuild deltas) baseline
    let refs = [e | e@FileRefEntry{} <- rebuilt]
        originals = [e | e <- rebuilt, not (isRef e)]
        candidate = Archive (originals ++ Map.elems deltas ++ refs)
    either (ioError . userError) (const (return (Just candidate)))
      (validateArchive candidate)
  where
    items = [PendingFile p f Nothing | (p, f) <- sourcePaths]
    sourceFiles = Map.fromList sourcePaths
    cacheLimit = 32 * 1024 * 1024 :: Int
    workLimit = 128 * 1024 * 1024 :: Int
    signatures bytes = Set.toList (Set.fromList
      [contentHash (BS.take 256 (BS.drop offset bytes)) |
        offset <- take 128 [0, stride .. BS.length bytes - 256]])
      where stride = max 1024 (((BS.length bytes `div` 128) `div` 256) * 256)
    search _ _ _ _ _ found [] = return found
    search sources index cached readBytes attempted found (item:rest) = case item of
      PendingFile path full _ -> do
        size <- getFileSize full
        if size < 4096 || size > 16777216 ||
           toInteger readBytes + size > toInteger workLimit
          then search sources index cached readBytes attempted found rest
          else do
            bytes <- BS.readFile full
            let n = BS.length bytes
                keys = signatures bytes
                counts = Map.fromListWith (+)
                  [(p, 1 :: Int) | key <- keys,
                    p <- Map.findWithDefault [] key index]
                candidates = take 2 (sortOn (\(p, count) -> (negate count, p))
                  (filter ((>= 2) . snd) (Map.toList counts)))
            (best, spent) <- foldM (tryBase path bytes sources)
              (Nothing, attempted) candidates
            case best of
              Just (_, entry) -> search sources index cached (readBytes+n)
                spent (Map.insert path entry found) rest
              Nothing -> do
                let reset = cached + n > cacheLimit
                    sources0 = if reset then Map.empty else sources
                    index0 = if reset then Map.empty else index
                    cached0 = if reset then 0 else cached
                    index1 = foldl' (\acc key -> Map.insertWith
                      (\new old -> take 8 (new ++ old)) key [path] acc) index0 keys
                search (Map.insert path bytes sources0) index1 (cached0+n)
                  (readBytes+n) spent found rest
      _ -> search sources index cached readBytes attempted found rest
    tryBase path bytes sources (best, spent) (reference, _) =
      case Map.lookup reference sources of
        Just base | spent + BS.length base + BS.length bytes <= workLimit -> do
          blocks <- compressBytesWith ZstdOnly selectedLevel
            (encodeDelta (buildDelta base bytes))
          let entry = DeltaEntry path reference (fromIntegral (BS.length bytes)) blocks
              cost = BL.length (Bin.encode entry)
          -- A conservative filter; the entire rebuilt archive is measured next.
          direct <- compressBytesWith selectedCodec selectedLevel bytes
          let directCost = BL.length (Bin.encode (FileEntry path direct))
              next = if cost >= directCost then best else case best of
                Just (oldCost, _) | oldCost <= cost -> best
                _ -> Just (cost, entry)
          return (next, spent + BS.length base + BS.length bytes)
        _ -> return (best, spent)
    rebuild deltas entry@(FileEntry path _)
      | Map.member path deltas = return []
      | otherwise = return [entry]
    rebuild deltas entry@(SolidEntry files _)
      | all (\(p, _) -> Map.notMember p deltas) files = return [entry]
      | otherwise = do
          let kept = filter (\(p, _) -> Map.notMember p deltas) files
          if null kept then return [] else do
            bytes <- BS.concat <$> mapM (\(p, _) -> BS.readFile (sourceFiles Map.! p)) kept
            blocks <- compressSolidBytesWith selectedCodec selectedLevel bytes
            return [SolidEntry kept blocks]
    rebuild _ entry = return [entry]
    isRef FileRefEntry{} = True
    isRef _ = False
buildDeltaSolidArchive _ _ _ _ = return Nothing

data PendingBatch = PendingSingle Pending | PendingFiles [Pending]
                  | PendingProfile Int Bool PendingBatch

deduplicatePending :: [Pending] -> IO [Pending]
deduplicatePending = go Map.empty
  where
    go _ [] = return []
    go seen (item:rest) = case item of
      PendingFile relative full _ -> do
        bytes <- BS.readFile full
        let key = contentHash bytes
        case findEqual key bytes (Map.findWithDefault [] key seen) of
          Just (target, size) ->
            (PendingRef relative target size :) <$> go seen rest
          Nothing -> do
            cached <- evaluate bytes
            let prepared = PendingFile relative full (Just cached)
            (prepared :) <$> go (Map.insertWith (++) key
              [(relative, bytes)] seen) rest
      _ -> (item :) <$> go seen rest

    findEqual _ _ [] = Nothing
    findEqual key bytes ((target, previous):rest)
      | bytes == previous = Just (target, fromIntegral (BS.length previous))
      | otherwise = findEqual key bytes rest

contentHash :: BS.ByteString -> Word64
contentHash = hashBytes

groupPending :: Int -> [Pending] -> IO [PendingBatch]
groupPending level = groupPendingAt (if level >= 8 then 16777216 else 1048576)

groupPendingAt :: Integer -> [Pending] -> IO [PendingBatch]
groupPendingAt maxSolidBytes = go
  where
    go [] = return []
    go (item:rest) = case item of
      PendingFile{} ->
        do
          firstSize <- pendingFileSize item
          (files, remaining) <- takeFiles maxSolidBytes firstSize [item] rest
          let batch = if length files > 1 then PendingFiles files
                      else PendingSingle item
          (batch :) <$> go remaining
      _ -> (PendingSingle item :) <$> go rest

    takeFiles _ _ acc [] = return (reverse acc, [])
    takeFiles limit current acc allItems@(next:rest) =
      case next of
        PendingFile _ full _ -> do
          size <- getFileSize full
          if current + size <= limit
            then takeFiles limit (current + size) (next:acc) rest
            else return (reverse acc, allItems)
        _ -> return (reverse acc, allItems)

    pendingFileSize (PendingFile _ full _) = getFileSize full
    pendingFileSize _ = return 0

-- An alternative solid strategy: group files with similar formats even when
-- they live in different subdirectories. This keeps all physical originals
-- before FileRefEntry values, preserving the existing forward-reference rule.
-- It is evaluated only in quality mode, and loses to the baseline when larger.
groupPendingBySimilarity :: Int -> [Pending] -> IO [PendingBatch]
groupPendingBySimilarity level =
  groupPendingBySimilarityAt (if level >= 8 then 16777216 else 1048576)

groupPendingBySimilarityAt :: Integer -> [Pending] -> IO [PendingBatch]
groupPendingBySimilarityAt sizeLimit pending = do
  let originals = [p | p@PendingFile{} <- pending]
      others = [p | p <- pending, not (isOriginal p)]
      sorted = sortOn similarityKey originals
  groups <- groupPendingAt sizeLimit sorted
  return (groups ++ map PendingSingle others)
  where
    isOriginal PendingFile{} = True
    isOriginal _ = False
    similarityKey (PendingFile relative _ _) =
      let filename = A.takeFileName relative
          ext = A.takeExtension filename
          -- Common build/dependency filenames strongly benefit from sharing
          -- a large ZSTD dictionary across package subtrees.
          bucket = if filename `elem` ["package.json", "package-lock.json",
                     "index.js", "index.d.ts", "tsconfig.json", "README.md",
                     "Cargo.toml", "Cargo.lock"]
                   then filename else ext
      in (bucket, ext, filename, relative)
    similarityKey _ = ("", "", "", "")

-- Package adjacency keeps a module's JS, source maps and declarations close.
-- Categories only select ordering/effort: every original byte is still stored.
groupPendingByPackageAt :: Bool -> Int -> [Pending] -> IO [PendingBatch]
groupPendingByPackageAt = groupPendingByPackageAtLimit 67108864

groupPendingByPackageAtLimit :: Integer -> Bool -> Int -> [Pending] -> IO [PendingBatch]
groupPendingByPackageAtLimit sizeLimit turbo level pending = do
  classified <- mapM classify [p | p@PendingFile{} <- pending]
  let sorted = sortOn fst classified
      categories = groupBy (\a b -> category a == category b) sorted
      others = [p | p <- pending, not (isFile p)]
  batches <- mapM makeCategory categories
  return (concat batches ++ map PendingSingle others)
  where
    isFile PendingFile{} = True
    isFile _ = False
    category ((kind, _, _, _), _) = kind
    makeCategory [] = return []
    makeCategory values@(first:_) = do
      groups <- groupPendingAt sizeLimit (map snd values)
      let quality = min level (case category first of
            "assets" -> 15
            "pack" -> 3
            "executable" -> 19
            _ -> 16)
      return (map (PendingProfile quality (turbo && category first == "text")) groups)
    classify file@(PendingFile path full cachedHeader) = do
      header <- case cachedHeader of
        Just bytes -> return (BS.take 4 bytes)
        Nothing -> withBinaryFile full ReadMode (\handle -> BS.hGet handle 4)
      let ext = map toLower (A.takeExtension path)
          kind | ext == ".pack" = "pack"
               | ext `elem` [".png", ".jpg", ".jpeg", ".woff", ".woff2", ".zip", ".gz", ".webp"] ||
                   "/.git/objects/" `isInfixOf` path = "assets"
               | ext `elem` [".node", ".exe"] || header == BS.pack [127,69,76,70] = "executable"
               | otherwise = "text"
          name = A.takeFileName path
          withoutMap = stripSuffix ".map" name
          base = case [suffix | suffix <- [".mjs", ".cjs", ".jsx", ".js", ".mts", ".cts", ".ts"],
                                suffix `isSuffixOf` withoutMap] of
            suffix:_ -> stripSuffix suffix withoutMap
            [] -> withoutMap
          components = afterLastModule (A.splitDirectories path)
          package = case components of
            scoped@('@':_):child:_ -> scoped A.</> child
            first:_ -> first
            [] -> ""
      return ((kind, package, base, path), file)
    classify _ = ioError (userError "Classification d'un fichier invalide")
    stripSuffix suffix value
      | suffix `isSuffixOf` value = take (length value - length suffix) value
      | otherwise = value
    afterLastModule parts = case [rest | (name, rest) <- tailsAfter parts, name == "node_modules"] of
      [] -> parts
      rests -> last rests
    tailsAfter [] = []
    tailsAfter (part:rest) = (part, rest) : tailsAfter rest

-- Pool fixe de workers CPU : pas un thread par fichier, les resultats
-- restent ordonnes, et les exceptions de travailleurs sont propagees.
workerMap :: forall a b. Int -> (a -> IO b) -> [a] -> IO [b]
workerMap threads action items
  | threads <= 1 = mapM action items
  | otherwise = do
      traceEvent "worker_pool_start"
        [("workers", show threads), ("tasks", show (length items))]
      queue <- newChan
      results <- mapM (const newEmptyMVar) items
      forM_ (zip3 [0 :: Int ..] items results) $ \(index, item, slot) -> do
        queued <- getMonotonicTimeNSec
        traceEvent "worker_task_queued"
          [("index", show index), ("queued_ns", show queued)]
        writeChan queue (Just (index, queued, item, slot))
      replicateM_ threads (writeChan queue Nothing)
      replicateM_ threads $ do
        _ <- forkIO $ let loop = do
                            next <- readChan queue
                            case next of
                              Nothing -> return ()
                              Just (index, queued, item, slot) -> do
                                thread <- show <$> myThreadId
                                startedAt <- getMonotonicTimeNSec
                                started <- traceSpanStart "worker_task"
                                  [("index", show index), ("thread", thread),
                                   ("wait_ns", show (startedAt - queued))]
                                result <- try (action item) :: IO (Either SomeException b)
                                traceSpanEnd "worker_task" started
                                  [("index", show index), ("thread", thread),
                                   ("result", either (const "error") (const "ok") result)]
                                putMVar slot result
                                loop
                      in loop
        return ()
      values <- mapM takeMVar results
      traceEvent "worker_pool_end"
        [("workers", show threads), ("tasks", show (length items))]
      mapM (either throwIO return) values

-- Canonicalized paths, not string prefixes, prevent /src2 being accepted for /src.
inside :: FilePath -> FilePath -> Bool
inside root candidate =
  let relative = makeRelative (nativePathKey root) (nativePathKey candidate)
  in not (isAbsolute relative) &&
     all (/= "..") (splitDirectories relative)

-- BH10 separates repetitive metadata (paths, sizes, archive entry tags) from
-- already-compressed block bodies.  This avoids spending CPU recompressing
-- an 80 MiB ZSTD stream only to save a few metadata kilobytes.  Each codec
-- block list remains serialized with the existing Binary instance.
-- The skeleton is an ordinary Archive with all block lists emptied.
stripBlocks :: Archive -> (Archive, [[Block]])
stripBlocks (Archive entries) =
  let (shapes, payloads) = unzip (map stripEntry entries)
  in (Archive shapes, concat payloads)
stripBlocks (ChunkArchive entries records) =
  let (shapes, entryPayloads) = unzip (map stripEntry entries)
      (recordShapes, recordPayloads) = unzip
        [(ChunkRecord ident size [], blocks) |
          ChunkRecord ident size blocks <- records]
  in (ChunkArchive shapes recordShapes, concat entryPayloads ++ recordPayloads)

stripEntry :: Entry -> (Entry, [[Block]])
stripEntry (FileEntry path blocks) = (FileEntry path [], [blocks])
stripEntry (SolidEntry files blocks) = (SolidEntry files [], [blocks])
stripEntry (DeltaEntry path base size blocks) =
  (DeltaEntry path base size [], [blocks])
stripEntry e = (e, [])

-- Decode each block list using the existing wire format.  Reject truncated
-- streams, trailing bytes, and skeletons that contain unexpected block data.
restoreBlocks :: Archive -> BL.ByteString -> Either String Archive
restoreBlocks (Archive entries) bytes = do
  (restored, remaining) <- restoreEntries entries bytes
  if BL.null remaining then Right (Archive restored)
    else Left "BH10: donnees apres le dernier bloc"
restoreBlocks (ChunkArchive entries records) bytes = do
  (restoredEntries, afterEntries) <- restoreEntries entries bytes
  (restoredRecords, remaining) <- restoreRecords records afterEntries
  if BL.null remaining then Right (ChunkArchive restoredEntries restoredRecords)
    else Left "BH10: donnees apres le dernier fragment"

restoreEntries :: [Entry] -> BL.ByteString -> Either String ([Entry], BL.ByteString)
restoreEntries [] bytes = Right ([], bytes)
restoreEntries (entry:entries) bytes = do
  (restored, remaining) <- case entry of
    FileEntry path [] -> do
      (blocks, rest) <- takeBlocks bytes
      Right (FileEntry path blocks, rest)
    SolidEntry paths [] -> do
      (blocks, rest) <- takeBlocks bytes
      Right (SolidEntry paths blocks, rest)
    DeltaEntry path base size [] -> do
      (blocks, rest) <- takeBlocks bytes
      Right (DeltaEntry path base size blocks, rest)
    FileEntry _ _ -> Left "BH10: squelette avec contenu inattendu"
    SolidEntry _ _ -> Left "BH10: groupe avec contenu inattendu"
    DeltaEntry _ _ _ _ -> Left "BH10: DELTA avec contenu inattendu"
    _ -> Right (entry, bytes)
  (tailEntries, final) <- restoreEntries entries remaining
  Right (restored : tailEntries, final)

restoreRecords :: [ChunkRecord] -> BL.ByteString -> Either String ([ChunkRecord], BL.ByteString)
restoreRecords [] bytes = Right ([], bytes)
restoreRecords (ChunkRecord ident size placeholder:records) bytes = do
  if not (null placeholder)
    then Left "BH10: fragment contenant des blocs dans le squelette"
    else do
      (blocks, remaining) <- takeBlocks bytes
      (tailRecords, final) <- restoreRecords records remaining
      Right (ChunkRecord ident size blocks : tailRecords, final)

takeBlocks :: BL.ByteString -> Either String ([Block], BL.ByteString)
takeBlocks bytes = case Bin.decodeOrFail bytes of
  Left (_, _, err) -> Left ("BH10: blocs invalides : " ++ err)
  Right (remaining, _, blocks) -> Right (blocks, remaining)

-- Build an optional BH10 envelope. The 12-byte header comprises the magic,
-- uncompressed skeleton length and compressed skeleton length, both Word32.
-- The encoded blocks are appended in their original order with no additional
-- compression or per-block overhead beyond their existing Binary encoding.
makeBh10 :: Archive -> IO (Maybe BL.ByteString)
makeBh10 archive = do
  let (skeleton, blockLists) = stripBlocks archive
      metadata = Bin.encode skeleton
      metadataLength = BL.length metadata
  if metadataLength > 268435456 || (metadataLength < 128 && not (requiresBh11 archive))
    then return Nothing
    else do
      compressed <- compressZstd 9 (BL.toStrict metadata)
      case compressed of
        Left _ -> return Nothing
        Right packed -> do
          let packedLength = BS.length packed
          if toInteger packedLength > toInteger (maxBound :: Word32)
            then return Nothing
            else do
              let header = (if requiresBh11 archive then bh11Magic else bh10Magic) <>
                    Bin.encode (fromIntegral metadataLength :: Word32) <>
                    Bin.encode (fromIntegral packedLength :: Word32)
                  payload = BL.concat (map Bin.encode blockLists)
              return (Just (header <> BL.fromStrict packed <> payload))

requiresBh11 :: Archive -> Bool
requiresBh11 archive = any (any isText) blockLists
  where
    (_,blockLists) = stripBlocks archive
    isText TextZstdBlock{} = True
    isText _ = False

-- Compare the complete on-disk representations.  BH09 may still be useful
-- for small archives, while BH10 generally benefits large solid archives.
saveArchive :: FilePath -> Archive -> IO ()
saveArchive path archive = saveArchiveWithProgress path archive (\_ _ -> return ())

-- Reports bytes actually written to the output file (not input bytes processed).
-- Chunked writes keep memory use bounded during the disk-write phase.
saveArchiveWithProgress :: FilePath -> Archive -> (Integer -> Integer -> IO ()) -> IO ()
saveArchiveWithProgress path archive report = do
  encoded <- serializeArchive archive
  let total = fromIntegral (BL.length encoded)
  withBinaryFile path WriteMode $ \handle -> do
    let writeChunks !done [] = hFlush handle >> report done total
        writeChunks !done (chunk:remaining) = do
          BS.hPut handle chunk
          let next = done + fromIntegral (BS.length chunk)
          report next total
          writeChunks next remaining
    writeChunks 0 (BL.toChunks encoded)

-- This is the single encoder used both for strategy selection and saving.
serializeArchive :: Archive -> IO BL.ByteString
serializeArchive archive = do
  previous <- serializePrevious archive
  relative <- case encodePathSkeleton archive of
    Left _ -> return Nothing
    Right metadata -> do
      let (_, blockLists) = stripBlocks archive
      makeMetadataEnvelope bh12Magic metadata blockLists
  return (case relative of
    Just candidate | BL.length candidate < BL.length previous -> candidate
    _ -> previous)

-- Preserve all previous encodings as exact size candidates and read formats.
serializePrevious :: Archive -> IO BL.ByteString
serializePrevious archive = do
  let header = case archive of
        ChunkArchive _ _ -> magic
        Archive entries | any isDeltaEntry entries -> bh08Magic
        Archive _ -> bh06Magic
      body = Bin.encode archive
      plain = header <> body
      bodyLength = BL.length body
  bh10 <- makeBh10 archive
  if requiresBh11 archive
    then case bh10 of
      Just container -> return container
      Nothing -> ioError (userError "BH11: metadonnees impossibles a encoder")
    else do
      let best = case bh10 of
            Just candidate | BL.length candidate < BL.length plain -> candidate
            _ -> plain
      -- Do not recompress a huge stream of independently ZSTD-coded payloads.
      -- The legacy BH09 envelope is retained for smaller archives, where it can
      -- sometimes recover additional local redundancy without excessive memory.
      if bodyLength > 16777216 || bodyLength < 128
        then return best
        else do
          compressed <- compressZstd 9 (BL.toStrict body)
          let alternative = case compressed of
                Right payload -> bh09Magic <>
                  Bin.encode (fromIntegral bodyLength :: Word32) <>
                  BL.fromStrict payload
                Left _ -> plain
          return (if BL.length alternative < BL.length best
            then alternative else best)
loadArchive :: FilePath -> IO (Either String Archive)
loadArchive path = do
  payload <- BL.readFile path
  let header = BL.take 4 payload
      body = BL.drop 4 payload
  if header == bh10Magic || header == bh11Magic || header == bh12Magic
    then case Bin.decodeOrFail body of
      Left (_, _, err) -> return (Left ("BH10: en-tete invalide : " ++ err))
      Right (afterLength, _, decodedLength :: Word32) ->
        case Bin.decodeOrFail afterLength of
          Left (_, _, err) -> return (Left ("BH10: taille invalide : " ++ err))
          Right (stream, _, packedLength :: Word32) ->
            if decodedLength > 268435456 ||
               fromIntegral packedLength > BL.length stream
              then return (Left "BH10: taille de metadonnees invalide")
              else do
                let (packed, storedBlocks) = BL.splitAt
                      (fromIntegral packedLength) stream
                case decompressArchiveZstd decodedLength (BL.toStrict packed) of
                  Left err -> return (Left err)
                  Right expanded -> return $ do
                    skeleton <- if header == bh12Magic
                      then decodePathSkeleton (BL.fromStrict expanded)
                      else decodeComplete (BL.fromStrict expanded)
                    restoreBlocks skeleton storedBlocks
    else if header == bh09Magic
    then case Bin.decodeOrFail body of
      Left (_, _, err) -> return (Left ("BH09: en-tete invalide : " ++ err))
      Right (compressed, _, decodedLength :: Word32) ->
        case decompressArchiveZstd decodedLength (BL.toStrict compressed) of
          Left err -> return (Left err)
          Right expanded -> return (decodeComplete (BL.fromStrict expanded))
    else if header == magic || header == bh08Magic || header == bh06Magic ||
       header == currentPreviousMagic || header == previousMagic ||
       header == legacy3Magic || header == legacy2Magic
      then return (decodeComplete body)
      else if header == oldMagic
        then return (fmap convertLegacy (decodeComplete body))
        else return (Left
          "Signature BH12/BH11/BH10/BH09/BH08/BH07/BH06/BH05/BH04/BH03/BH02/BH01 absente")
  where
    decodeComplete :: Bin.Binary a => BL.ByteString -> Either String a
    decodeComplete body = case Bin.decodeOrFail body of
      Left (_, _, err) -> Left ("Archive invalide : " ++ err)
      Right (remaining, _, value)
        | not (BL.null remaining) -> Left "Donnees apres la fin de l'archive"
        | otherwise -> Right value
    convertLegacy (LegacyArchive entries) = Archive (map convert entries)
    convert (LegacyDir name) = DirEntry name
    convert (LegacyFile name blocks) = FileEntry name blocks

safeName :: FilePath -> Bool
safeName [] = False
safeName ('/':_) = False
safeName path = go (0 :: Int) path
  where
    go state [] = state == 3
    go state ('/':rest)
      | state /= 3 = False
      | null rest = True
      | otherwise = go 0 rest
    go _ ('\0':_) = False
    go _ ('\\':_) = False
    go state ('.':rest) = go (if state < 3 then state+1 else 3) rest
    go _ (_:rest) = go 3 rest

-- Resolve '..' explicitly: System.FilePath.normalise does not collapse it.
-- The first path component is the archive root and must never be escaped.
-- This accepts typical Node.js links like .bin/bcrypt -> ../bcrypt/bin/bcrypt.
safeLinkTarget :: FilePath -> FilePath -> Bool
safeLinkTarget linkPath target =
  not (null target) && not (A.isAbsolute target)
  && all (`notElem` ['\0', '\\']) target
  && safeName linkPath
  && case A.splitDirectories linkPath of
       [] -> False
       root:_ -> case resolve [] (A.splitDirectories (A.takeDirectory linkPath)) of
         Nothing -> False
         Just base -> case resolve base (A.splitDirectories target) of
           Nothing -> False
           Just final -> not (null final) && headOf final == root
  where
    -- Link paths themselves have already been checked by safeName.
    -- Build the base from the archive root exactly once.
    resolve initial components = foldl step (Just initial) components
    step Nothing _ = Nothing
    step (Just acc) part
      | part == "." || null part = Just acc
      | part == ".." = case acc of
          [_] -> Nothing
          [] -> Nothing
          _ -> Just (init acc)
      | otherwise = Just (acc ++ [part])
    headOf (x:_) = x
    headOf [] = ""

entryNames :: Entry -> [FilePath]
entryNames (DirEntry path) = [path]
entryNames (FileEntry path _) = [path]
entryNames (LinkEntry path _) = [path]
entryNames (SolidEntry files _) = map fst files
entryNames (FileRefEntry path _ _) = [path]
entryNames (ChunkEntry path _) = [path]
entryNames (DeltaEntry path _ _ _) = [path]

validatePaths :: [Entry] -> Either String ()
validatePaths entries
  | not (all valid entries) = Left "Chemin ou cible de lien dangereux dans l'archive"
  | Set.size allNames /= length names = Left "Chemins dupliques dans l'archive"
  | any hasDescendant nonDirs = Left "Fichier ou lien symbolique utilise comme dossier parent"
  | otherwise = Right ()
  where
    names = concatMap entryNames entries
    allNames = Set.fromList names
    nonDirs = [name | e <- entries, not (isDir e), name <- entryNames e]
    hasDescendant name =
      let prefix = A.dropTrailingPathSeparator name ++ "/"
          next = if name == prefix then Set.lookupGT prefix allNames else Set.lookupGE prefix allNames
      in case next of Just candidate -> prefix `isPrefixOf` candidate; Nothing -> False
    isDir (DirEntry _) = True
    isDir _ = False
    valid (DirEntry path) = safeName path
    valid (FileEntry path _) = safeName path
    valid (LinkEntry path target) = safeName path && safeLinkTarget path target
    valid (SolidEntry files _) = not (null files) && all (safeName . fst) files
    valid (FileRefEntry path target size) =
      safeName path && safeName target && size <= 16777216
    valid (ChunkEntry path _) = safeName path
    valid (DeltaEntry path target size _) =
      safeName path && safeName target && size <= 16777216

verifyArchive :: Archive -> Either String ()
verifyArchive (Archive entries) = do
  validatePaths entries
  validateData Map.empty entries
  where
    validateData _ [] = Right ()
    validateData known (entry:rest) = case entry of
      DirEntry _ -> validateData known rest
      LinkEntry _ _ -> validateData known rest
      FileEntry path blocks -> do
        bytes <- decompressBytes blocks
        validateData (Map.insert path bytes known) rest
      SolidEntry files blocks -> do
        contents <- decompressBytes blocks
        validateSolid files contents
        let next = insertSolid contents known 0 files
        validateData next rest
        where
          insertSolid _ acc _ [] = acc
          insertSolid contents' acc offset ((path, size):remaining) =
            let bytes = BS.take (fromIntegral size)
                  (BS.drop offset contents')
            in insertSolid contents' (Map.insert path bytes acc)
                 (offset + fromIntegral size) remaining
      FileRefEntry path target size ->
        case Map.lookup target known of
          Just bytes
            | fromIntegral (BS.length bytes) == size ->
                validateData (Map.insert path bytes known) rest
            | otherwise -> Left "Reference de fichier de taille incoherente"
          Nothing -> Left "Reference vers un fichier absent"
      ChunkEntry _ _ -> Left "Fragment BH07 dans une archive BH06"
      DeltaEntry path target size blocks ->
        case Map.lookup target known of
          Nothing -> Left "Reference DELTA vers un fichier absent"
          Just base -> do
            instructions <- decompressBytes blocks
            ops <- decodeDelta instructions
            bytes <- applyDelta base size ops
            validateData (Map.insert path bytes known) rest
verifyArchive (ChunkArchive entries records) = do
  validateArchive (ChunkArchive entries records)
  let table = Map.fromList [(ident, (size, blocks)) |
        ChunkRecord ident size blocks <- records]
  mapM_ (verifyChunkEntry table) entries
  where
    verifyChunkEntry _ (DirEntry _) = Right ()
    verifyChunkEntry _ (LinkEntry _ _) = Right ()
    verifyChunkEntry _ (FileEntry _ _) =
      Left "Entree fichier inattendue dans BH07"
    verifyChunkEntry _ (SolidEntry _ _) =
      Left "Entree solid inattendue dans BH07"
    verifyChunkEntry _ (FileRefEntry _ _ _) =
      Left "Reference fichier inattendue dans BH07"
    verifyChunkEntry _ (DeltaEntry _ _ _ _) =
      Left "Entree DELTA inattendue dans BH07"
    verifyChunkEntry table (ChunkEntry _ refs) = do
      chunks <- mapM (lookupChunk table) refs
      if (sum (map (fromIntegral . BS.length) chunks) :: Int) ==
           sum [fromIntegral size | (_, size) <- refs]
        then Right ()
        else Left "Taille de fichier BH07 incoherente"
    lookupChunk table (ident, size) =
      case Map.lookup ident table of
        Nothing -> Left "Fragment BH07 absent"
        Just (storedSize, blocks)
          | storedSize /= size -> Left "Taille de reference BH07 incoherente"
          | otherwise -> decompressBytes blocks

extractArchive :: FilePath -> Archive -> IO ()
extractArchive destination archive = do
  either (ioError . userError) return (verifyArchive archive)
  when isHostWindows $ either (ioError . userError) return $
    validateWindowsPaths [(case e of DirEntry{} -> True; _ -> False,p) | e <- entries,p <- entryNames e]
      [(p,t) | LinkEntry p t <- entries]
  exists <- doesPathExist destination
  isLink <- pathIsSymbolicLinkSafe destination
  when (exists || isLink) (ioError (userError "Le dossier de destination existe deja"))
  createDirectory destination
  createdDirectories <- newIORef (Set.singleton "")
  let output path = destination </> fromArchivePath path
      ensureDirectory path
        | not isHostWindows = createDirectoryIfMissing True (output path)
        | otherwise = forM_ (drop 1 (scanl (A.</>) "" (A.splitDirectories path))) $ \part -> do
            known <- readIORef createdDirectories
            unless (Set.member part known) $ do
              occupied <- doesPathExist (output part)
              link <- pathIsSymbolicLinkSafe (output part)
              when (occupied || link) (ioError (userError ("Windows: collision de dossier: " ++ part)))
              createDirectory (output part)
              modifyIORef' createdDirectories (Set.insert part)
      writeOutput path bytes = do
        let parent = A.takeDirectory path
        unless (parent == ".") (ensureDirectory parent)
        when isHostWindows $ do
          occupied <- doesPathExist (output path)
          link <- pathIsSymbolicLinkSafe (output path)
          when (occupied || link) (ioError (userError ("Windows: collision de fichier: " ++ path)))
        BS.writeFile (output path) bytes
  -- Create symlinks LAST, so they can never redirect file writes.
  forM_ entries $ \entry -> case entry of
    DirEntry path -> ensureDirectory (A.dropTrailingPathSeparator path)
    FileEntry path blocks -> do
      either (ioError . userError) (writeOutput path)
        (decompressBytes blocks)
    FileRefEntry path target size -> do
      bytes <- BS.readFile (output target)
      when (fromIntegral (BS.length bytes) /= size) $
        ioError (userError "Reference de fichier incoherente")
      writeOutput path bytes
    DeltaEntry path target size blocks -> do
      base <- BS.readFile (output target)
      instructions <- either (ioError . userError) return
        (decompressBytes blocks)
      ops <- either (ioError . userError) return (decodeDelta instructions)
      bytes <- either (ioError . userError) return
        (applyDelta base size ops)
      writeOutput path bytes
    ChunkEntry path refs -> do
      contents <- either (ioError . userError) return
        (reconstructChunks records refs)
      writeOutput path contents
    SolidEntry files blocks -> do
      contents <- either (ioError . userError) return (decompressBytes blocks)
      writeSolidFiles writeOutput files contents
    LinkEntry _ _ -> return ()
  forM_ entries $ \entry -> case entry of
    LinkEntry path target -> do
      let parent = A.takeDirectory path
      unless (parent == ".") (ensureDirectory parent)
      when isHostWindows $ do
        occupied <- doesPathExist (output path)
        link <- pathIsSymbolicLinkSafe (output path)
        when (occupied || link) (ioError (userError ("Windows: collision de lien: " ++ path)))
      inferredDirectory <- if isHostWindows then doesDirectoryExist (takeDirectory (output path) </> fromArchivePath target) else return False
      let directory = (not (null target) && last target == '/') || inferredDirectory || directoryTarget Set.empty path target
      createArchiveLink directory target (output path)
    _ -> return ()
  where
    names = Set.fromList (map A.dropTrailingPathSeparator (concatMap entryNames entries))
    directories = Set.fromList [A.dropTrailingPathSeparator p | DirEntry p <- entries]
    links = Map.fromList [(p,t) | LinkEntry p t <- entries]
    hasChild p = case Set.lookupGE (p ++ "/") names of
      Just candidate -> (p ++ "/") `isPrefixOf` candidate
      Nothing -> False
    entries = case archive of Archive es -> es; ChunkArchive es _ -> es
    directoryTarget visited path target
      | Set.member path visited = False
      | otherwise = case resolveArchiveTarget path target of
          Nothing -> False
          Just resolved -> Set.member resolved directories || hasChild resolved ||
            case Map.lookup resolved links of
              Just t -> (not (null t) && last t == '/') || directoryTarget (Set.insert path visited) resolved t
              Nothing -> False
    records = case archive of
      ChunkArchive _ stored -> stored
      Archive _ -> []

reconstructChunks :: [ChunkRecord] -> [(Word32, Word32)] -> Either String BS.ByteString
reconstructChunks records refs = fmap BS.concat (mapM get refs)
  where
    table = Map.fromList [(ident, (size, blocks)) |
      ChunkRecord ident size blocks <- records]
    get (ident, expected) =
      case Map.lookup ident table of
        Nothing -> Left "Fragment BH07 absent"
        Just (stored, blocks)
          | stored /= expected -> Left "Taille de fragment BH07 incoherente"
          | otherwise -> do
              bytes <- decompressBytes blocks
              if fromIntegral (BS.length bytes) == expected
                then Right bytes
                else Left "Fragment BH07 corrompu"

validateSolid :: [(FilePath, Word32)] -> BS.ByteString -> Either String ()
validateSolid files contents
  | sum (map (fromIntegral . snd) files) /= BS.length contents =
      Left "Groupe solid incoherent"
  | otherwise = Right ()

writeSolidFiles :: (FilePath -> BS.ByteString -> IO ()) -> [(FilePath, Word32)] -> BS.ByteString -> IO ()
writeSolidFiles writeOutput files contents = go 0 files
  where
    go offset [] =
      when (offset /= BS.length contents) $
        ioError (userError "Donnees residuelles dans le groupe solid")
    go offset ((path, size):rest) = do
      let count = fromIntegral size
      when (offset + count > BS.length contents) $
        ioError (userError "Groupe solid tronque")
      writeOutput path (BS.take count (BS.drop offset contents))
      go (offset + count) rest

archiveSummary :: Archive -> [(FilePath, String)]
archiveSummary (Archive entries) =
  [ case e of
      DirEntry path -> (path, "dossier")
      FileEntry path blocks ->
        (path, show (sum (map rawSize blocks)) ++ " octets")
      LinkEntry path target -> (path, "lien -> " ++ target)
      SolidEntry (first:rest) _ ->
        (fst first, show (1 + length rest) ++ " fichiers solid")
      SolidEntry [] _ -> ("", "groupe solid vide")
      FileRefEntry path target size ->
        (path, show size ++ " octets (reference -> " ++ target ++ ")")
      ChunkEntry path refs ->
        (path, show (sum [fromIntegral n | (_, n) <- refs] :: Int) ++ " octets (fragments)")
      DeltaEntry path target size _ ->
        (path, show size ++ " octets (DELTA -> " ++ target ++ ")")
  | e <- entries ]
archiveSummary (ChunkArchive entries _) = archiveSummary (Archive entries)

-- Counts stored payload bytes and per-codec blocks. Metadata is everything
-- not accounted for by the encoded Block values (measured with Data.Binary).
archiveStats :: Archive -> (Int, Int, Int, Int, Int, Int)
archiveStats (Archive entries) =
  let files = [blocks | FileEntry _ blocks <- entries]
      solids = [(sizes, blocks) | SolidEntry sizes blocks <- entries]
      refs = [size | FileRefEntry _ _ size <- entries]
      deltas = [(size, blocks) | DeltaEntry _ _ size blocks <- entries]
      allBlocks = concat files ++ concat [blocks | (_, blocks) <- solids] ++
                  concat [blocks | (_, blocks) <- deltas]
      original = sum (map rawSize (concat files)) +
                 sum [fromIntegral size | (sizes, _) <- solids, (_, size) <- sizes]
                 + sum (map fromIntegral refs) +
                 sum [fromIntegral size | (size, _) <- deltas]
      rawCount = length [() | RawBlock _ <- allBlocks]
      mathCount = length [() | block <- allBlocks, codecName block == "MATH"]
      zstdCount = length [() | block <- allBlocks, codecName block == "ZSTD"]
      encoded = sum (map compressedSize allBlocks)
  in (length files + sum (map (length . fst) solids) + length refs +
      length deltas, original, encoded,
      rawCount, mathCount, zstdCount)
archiveStats (ChunkArchive entries records) =
  let blocks = concat [bs | ChunkRecord _ _ bs <- records]
      original = sum [fromIntegral size | ChunkEntry _ refs <- entries,
                                            (_, size) <- refs]
      fileCount = length [() | ChunkEntry _ _ <- entries]
  in (fileCount, original, sum (map compressedSize blocks),
      length [() | RawBlock _ <- blocks],
      length [() | b <- blocks, codecName b == "MATH"],
      length [() | block <- blocks, codecName block == "ZSTD"])

-- Nombre d'expressions effectivement stockees dans les blocs mathematiques.
archiveMathFunctions :: Archive -> Int
archiveMathFunctions (Archive entries) =
  sum [sum (map mathFunctionCount blocks) | FileEntry _ blocks <- entries] +
  sum [sum (map mathFunctionCount blocks) | SolidEntry _ blocks <- entries]
archiveMathFunctions (ChunkArchive _ records) =
  sum [sum (map mathFunctionCount blocks) | ChunkRecord _ _ blocks <- records]


-- BH12 path metadata: current directory, number of parent steps and the
-- remaining relative suffix. Counts and character values are bounded unsigned
-- LEB128 integers. Literal @ and / in file DATA never enter this parser.
-- Character values preserve all Haskell FilePath characters, including the
-- surrogate escapes used by the filesystem encoding for non-UTF8 filenames.
type PathCursor = ([FilePath], Int)

pathBudget, textLimit :: Int
pathBudget = 67108864
textLimit = 1048576

putNat :: Word32 -> Put.Put
putNat n
  | n < 128 = Put.putWord8 (fromIntegral n)
  | otherwise = Put.putWord8 (fromIntegral (n .&. 127) .|. 128) >> putNat (n `shiftR` 7)

getNat :: Get.Get Word32
getNat = go 0 0
  where
    go shift acc = do
      byte <- Get.getWord8
      when (shift == 28 && byte > 15) (fail "BH12: entier debordant")
      let result = acc .|. (fromIntegral (byte .&. 127) `shiftL` shift)
      if byte < 128
        then if shift > 0 && byte == 0 then fail "BH12: entier non canonique" else return result
        else go (shift+7) result

putCount :: Int -> Put.Put
putCount = putNat . fromIntegral

getCount :: Int -> Get.Get Int
getCount limit = do
  count <- getNat
  available <- Get.lookAhead (BL.length <$> Get.getRemainingLazyByteString)
  when (toInteger count > toInteger limit || toInteger count > toInteger available)
    (fail "BH12: nombre d'elements invalide")
  return (fromIntegral count)

putSmallText :: String -> Put.Put
putSmallText text = putCount (length text) >> mapM_ (putNat . fromIntegral . ord) text

getSmallText :: Get.Get String
getSmallText = do
  count <- getCount textLimit
  replicateM count $ do
    code <- getNat
    when (code > 1114111) (fail "BH12: caractere invalide")
    return (chr (fromIntegral code))

-- Files leave the cursor at their parent; directory entries enter that folder.
putRelativePath :: Bool -> [FilePath] -> FilePath -> Put.PutM [FilePath]
putRelativePath directory cwd path = do
  let trailing = not (null path) && last path == '/'
      parts = A.splitDirectories (A.dropTrailingPathSeparator path)
      parent = if directory then parts else init parts
      shared = length (takeWhile (uncurry (==)) (zip cwd parent))
      up = length cwd - shared
      suffix = intercalate "/" (drop shared parts)
  putNat (fromIntegral (up*2 + if trailing then 1 else 0))
  putSmallText suffix
  return parent

getRelativePath :: Bool -> PathCursor -> Get.Get (FilePath, PathCursor)
getRelativePath directory (cwd, spent) = do
  control <- getNat
  let up = fromIntegral (control `div` 2)
  when (up > length cwd) (fail "BH12: remontee au-dessus de la racine")
  suffix <- getSmallText
  unless ((null suffix && directory) ||
          (safeName suffix && last suffix /= '/'))
    (fail "BH12: suffixe de chemin invalide")
  let parts = take (length cwd-up) cwd ++ if null suffix then [] else A.splitDirectories suffix
      full = intercalate "/" parts ++ if odd control then "/" else ""
      cost = length full
  unless (safeName full && length parts <= 65535 && cost <= textLimit &&
          spent <= pathBudget-cost) (fail "BH12: chemin invalide ou budget depasse")
  let next = if directory then parts else init parts
  return (full, (next, spent+cost))

-- Reference paths use the same encoding but do not move the entry cursor.
getReferencePath :: PathCursor -> Get.Get (FilePath, PathCursor)
getReferencePath cursor@(cwd, _) = do
  (path, (_, spent)) <- getRelativePath False cursor
  return (path, (cwd, spent))

putPathEntry :: [FilePath] -> Entry -> Put.PutM [FilePath]
putPathEntry cwd entry = case entry of
  DirEntry path -> Put.putWord8 0 >> putRelativePath True cwd path
  FileEntry path _ -> Put.putWord8 1 >> putRelativePath False cwd path
  LinkEntry path target -> do
    Put.putWord8 2
    next <- putRelativePath False cwd path
    putSmallText target
    return next
  SolidEntry files _ -> do
    Put.putWord8 3
    putCount (length files)
    foldM (\current (path,size) -> do
      next <- putRelativePath False current path
      Put.putWord32be size
      return next) cwd files
  FileRefEntry path target size -> reference 4 path target size
  ChunkEntry path chunks -> do
    Put.putWord8 5
    next <- putRelativePath False cwd path
    putCount (length chunks)
    mapM_ (\(ident,size) -> Put.putWord32be ident >> Put.putWord32be size) chunks
    return next
  DeltaEntry path target size _ -> reference 6 path target size
  where
    reference tag path target size = do
      Put.putWord8 tag
      next <- putRelativePath False cwd path
      _ <- putRelativePath False next target
      Put.putWord32be size
      return next

getPathEntry :: PathCursor -> Get.Get (Entry, PathCursor)
getPathEntry cursor = do
  tag <- Get.getWord8
  case tag of
    0 -> do (path,next) <- getRelativePath True cursor; return (DirEntry path,next)
    1 -> do (path,next) <- getRelativePath False cursor; return (FileEntry path [],next)
    2 -> do
      (path,(cwd,spent)) <- getRelativePath False cursor
      target <- getSmallText
      when (length target > pathBudget-spent) (fail "BH12: budget liens depasse")
      unless (safeLinkTarget path target) (fail "BH12: lien dangereux")
      return (LinkEntry path target,(cwd,spent+length target))
    3 -> do
      count <- getCount 16777216
      (files,next) <- manyPaths count cursor
      return (SolidEntry files [],next)
    4 -> reference FileRefEntry
    5 -> do
      (path,next) <- getRelativePath False cursor
      count <- getCount 16777216
      chunks <- replicateM count ((,) <$> Get.getWord32be <*> Get.getWord32be)
      return (ChunkEntry path chunks,next)
    6 -> reference (\path target size -> DeltaEntry path target size [])
    _ -> fail "BH12: type d'entree inconnu"
  where
    reference constructor = do
      (path,next) <- getRelativePath False cursor
      (target,afterTarget) <- getReferencePath next
      size <- Get.getWord32be
      return (constructor path target size,afterTarget)
    manyPaths 0 current = return ([],current)
    manyPaths n current = do
      (path,next) <- getRelativePath False current
      size <- Get.getWord32be
      (rest,lastCursor) <- manyPaths (n-1) next
      return ((path,size):rest,lastCursor)

-- The payload lists are stored separately, exactly as in BH10/BH11.
encodePathSkeleton :: Archive -> Either String BL.ByteString
encodePathSkeleton archive = do
  let (skeleton, _) = stripBlocks archive
      (entries, records) = case skeleton of
        Archive es -> (es, [])
        ChunkArchive es rs -> (es, rs)
      texts = concatMap entryTexts entries
      cost = sum (map (toInteger . length) texts)
  validatePaths entries
  unless (cost <= toInteger pathBudget && all ((<=textLimit) . length) texts &&
          all ((<=65535) . length . A.splitDirectories) (concatMap entryPaths entries))
    (Left "BH12: budget de chemins depasse")
  return $ Put.runPut $ do
    Put.putWord8 (case skeleton of Archive _ -> 0; _ -> 1)
    putCount (length entries)
    _ <- foldM putPathEntry [] entries
    case skeleton of
      Archive _ -> return ()
      ChunkArchive _ _ -> do
        putCount (length records)
        mapM_ (\(ChunkRecord ident size _) -> Put.putWord32be ident >> Put.putWord32be size) records
  where
    entryPaths (FileRefEntry path target _) = [path,target]
    entryPaths (DeltaEntry path target _ _) = [path,target]
    entryPaths entry = entryNames entry
    entryTexts (LinkEntry path target) = [path,target]
    entryTexts (FileRefEntry path target _) = [path,target]
    entryTexts (DeltaEntry path target _ _) = [path,target]
    entryTexts entry = entryNames entry

decodePathSkeleton :: BL.ByteString -> Either String Archive
decodePathSkeleton bytes
  | BL.length bytes > 268435456 = Left "BH12: metadonnees trop grandes"
  | otherwise = case Get.runGetOrFail parser (BL.fromStrict (BL.toStrict bytes)) of
      Left (_,_,err) -> Left err
      Right (rest,_,archive) | BL.null rest -> Right archive
        | otherwise -> Left "BH12: donnees apres les metadonnees"
  where
    parser = do
      kind <- Get.getWord8
      when (kind > 1) (fail "BH12: type d'archive inconnu")
      count <- getCount 16777216
      entries <- readEntries count ([],0)
      if kind == 0 then return (Archive entries) else do
        n <- getCount 16777216
        records <- replicateM n (ChunkRecord <$> Get.getWord32be <*> Get.getWord32be <*> pure [])
        return (ChunkArchive entries records)
    readEntries 0 _ = return []
    readEntries n cursor = do
      (entry,next) <- getPathEntry cursor
      rest <- readEntries (n-1) next
      return (entry:rest)

makeMetadataEnvelope :: BL.ByteString -> BL.ByteString -> [[Block]] -> IO (Maybe BL.ByteString)
makeMetadataEnvelope signature metadata blockLists
  | BL.length metadata > 268435456 = return Nothing
  | otherwise = do
      compressed <- compressZstd 9 (BL.toStrict metadata)
      return $ case compressed of
        Left _ -> Nothing
        Right packed -> Just (signature <>
          Bin.encode (fromIntegral (BL.length metadata) :: Word32) <>
          Bin.encode (fromIntegral (BS.length packed) :: Word32) <>
          BL.fromStrict packed <> BL.concat (map Bin.encode blockLists))


-- Used only for inferring a directory target when links are restored last.
resolveArchiveTarget :: FilePath -> FilePath -> Maybe FilePath
resolveArchiveTarget path target = fmap (intercalate "/") $
  foldM step (A.splitDirectories (A.takeDirectory path)) (A.splitDirectories target)
  where
    step parts "." = Just parts
    step [] ".." = Nothing
    step parts ".." = Just (init parts)
    step parts name = Just (parts ++ [name])
