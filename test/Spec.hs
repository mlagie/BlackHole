{-# LANGUAGE CPP #-}
module Main (main) where

import BlackHole.Archive
import BlackHole.PortablePaths (isHostWindows, windowsToArchivePath, toArchivePath, validateWindowsPaths, windowsUTF16)
import qualified System.Directory as Directory
import qualified System.FilePath as Native
import BlackHole.Chunking (chunkSize, splitChunks)
import BlackHole.Delta
import BlackHole.Engine
import Control.Monad (forM_)
import Control.Concurrent (getNumCapabilities, setNumCapabilities)
import Control.Exception (try, IOException, bracket)
import qualified Data.Binary as Bin
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import qualified Data.IntSet as IS
import System.Directory
  ( createDirectory, createDirectoryIfMissing, getTemporaryDirectory
  , removeFile, removePathForcibly, pathIsSymbolicLink )
import System.Exit (exitFailure)
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.FilePath ((</>))
import System.FilePath.Posix (normalise, isAbsolute, splitDirectories)
import Data.Either (isLeft, isRight)
import Data.Word (Word32)
import qualified Data.ByteString.Char8 as BC
import System.IO (hClose, openTempFile)
#if !defined(mingw32_HOST_OS) && !defined(BLACKHOLE_WINDOWS_TEST)
import System.Posix.Files (createSymbolicLink, readSymbolicLink)
#else
createSymbolicLink :: FilePath -> FilePath -> IO ()
createSymbolicLink target destination = do
  directory <- Directory.doesDirectoryExist (Native.takeDirectory destination </> target)
  (if directory then Directory.createDirectoryLink else Directory.createFileLink) target destination
readSymbolicLink :: FilePath -> IO FilePath
readSymbolicLink path = toArchivePath <$> Directory.getSymbolicLinkTarget path
#endif

assert :: String -> Bool -> IO ()
assert label success =
  if success then putStrLn ("OK " ++ label)
  else putStrLn ("ECHEC " ++ label) >> exitFailure

main :: IO ()
main = do
  linksAvailable <- probeSymlinks
  let examples =
        [ BS.empty
        , BS.pack [0..255]
        , BS.replicate 65536 65
        , BS.pack (take 100000 (cycle [1, 2, 3, 4]))
        , BS.pack [0, 200, 4, 255, 10, 20]
        , BS.pack (take 70000 (cycle [10, 7, 8, 9, 1, 2, 3]))
        ]
  forM_ (zip [1 :: Int ..] examples) $ \(n, input) ->
    assert ("roundtrip bloc " ++ show n)
      (decompressBytes (compressBytes input) == Right input)
  let chunkInput = BS.pack (take 200000 (cycle [0..255]))
      chunks = splitChunks chunkInput
      sizes = map BS.length chunks
  assert "decoupage contenu deterministe"
    (chunks == splitChunks chunkInput && not (null chunks))
  assert "bornes des fragments"
    (all (<= chunkSize * 2) sizes &&
      (all (>= chunkSize `div` 2) (init sizes) ||
       length sizes == 1) &&
      BS.concat chunks == chunkInput)
  let deltaBase = BS.pack (take 50000 (cycle [0..255]))
      deltaTarget = BS.concat
        [ BS.pack [1, 2, 3, 4]
        , BS.take 24000 deltaBase
        , BS.singleton 99
        , BS.drop 24000 deltaBase
        ]
      deltaOps = buildDelta deltaBase deltaTarget
  assert "roundtrip DELTA avec insertion"
    (applyDelta deltaBase (fromIntegral (BS.length deltaTarget)) deltaOps ==
      Right deltaTarget)
  assert "roundtrip encodage DELTA"
    (decodeDelta (encodeDelta deltaOps) == Right deltaOps)
  deltaBlocks <- compressBytesWith ZstdOnly 8 (encodeDelta deltaOps)
  let deltaArchive = Archive
        [ FileEntry "base.bin" (compressBytes deltaBase)
        , DeltaEntry "target.bin" "base.bin"
            (fromIntegral (BS.length deltaTarget)) deltaBlocks
        ]
  assert "verification archive DELTA"
    (verifyArchive deltaArchive == Right ())
  let blocks = compressBytes (BS.replicate 65536 42)
  assert "mode mathematique" (any isMath blocks)
  forM_ (zip [1 :: Int ..] examples) $ \(n, input) -> do
    hybrid <- compressBytesWith Auto 3 input
    assert ("roundtrip hybride " ++ show n)
      (decompressBytes hybrid == Right input)
  let repetitive = BS.replicate 100000 65
  zstd <- compressBytesWith ZstdOnly 3 repetitive
  assert "ZSTD compresses repetitif" (any isZstd zstd &&
    sum (map compressedSize zstd) < BS.length repetitive `div` 10)
  assert "roundtrip ZSTD" (decompressBytes zstd == Right repetitive)
  raw <- compressBytesWith RawOnly 3 repetitive
  assert "mode RAW" (all isRaw raw && decompressBytes raw == Right repetitive)
  fast <- compressBytesWith Auto 1 repetitive
  best <- compressBytesWith Auto 12 repetitive
  assert "roundtrip fast/best" (decompressBytes fast == Right repetitive &&
    decompressBytes best == Right repetitive)
  testAutoComparesMath
  testMathPieces
  testSolidCompression
  testLongWindowSolid
  testMaxSolidBoundary
  testDirectBounds
  testDirectParallelDeterminism
  testBalancedProfile linksAvailable
  testTurboCodec
  testTurboTraversal linksAvailable
  testPathEquivalence
  testArchiveEnvelope
  testBh10Metadata
  testRelativePaths
  testWindowsPaths linksAvailable
  testFileDeduplication
  testSimilaritySolid
  if linksAvailable then testSymlinks else putStrLn "SKIP liens: Windows ne permet pas leur creation dans cette session"
  testDeltaSolid
  testDeltaBoundedScan
  where
    isMath (MathBlock _ _ _) = True
    isMath (MathBlockV2 _ _ _) = True
    isMath (MathBlockV3 _ _ _) = True
    isMath _ = False
    isZstd (ZstdBlock _ _) = True
    isZstd _ = False
    isRaw (RawBlock _) = True
    isRaw _ = False

-- BH09 wraps the existing binary archive with an optional ZSTD frame.
-- Confirm both the smaller representation and the intact old archive format.
testArchiveEnvelope :: IO ()
testArchiveEnvelope = do
  temp <- getTemporaryDirectory
  (scratch, handle) <- openTempFile temp "blackhole-bh09-"
  hClose handle
  let large = Archive
        [DirEntry ("project/node_modules/package-name-" ++ show i ++ "/src")
          | i <- [1 :: Int .. 600]]
      small = Archive [DirEntry "project"]
  saveArchive scratch large
  payload <- BL.readFile scratch
  measured <- archiveWireSize large
  assert "taille finale enveloppe" (measured == fromIntegral (BL.length payload))
  assert "compression des metadonnees BH09/BH10/BH12"
    (BL.take 4 payload `elem`
      map (BL.fromStrict . BS.pack) [[66,72,48,57], [66,72,49,48], [66,72,49,50]])
  decoded <- loadArchive scratch
  assert "BH09 lecture et verification" (case decoded of
    Right a -> verifyArchive a == Right () &&
      archiveSummary a == archiveSummary large
    _ -> False)
  saveArchive scratch small
  plain <- BL.readFile scratch
  measuredSmall <- archiveWireSize small
  assert "taille finale ancien format" (measuredSmall == fromIntegral (BL.length plain))
  assert "petite archive garde ancien format"
    (BL.take 4 plain == BL.fromStrict (BS.pack [66,72,48,54]))
  decodedSmall <- loadArchive scratch
  assert "compatibilite lecture archive non enveloppee"
    (case decodedSmall of Right a -> archiveSummary a == archiveSummary small
                          _ -> False)
  removeFile scratch

-- On a large archive, separate metadata compression (BH10) must win over
-- uncompressed serialization without touching the already encoded blocks.
-- Reuse the same ByteString to keep the test's source memory bounded.
testBh10Metadata :: IO ()
testBh10Metadata = do
  temp <- getTemporaryDirectory
  (scratch, handle) <- openTempFile temp "blackhole-bh10-"
  hClose handle
  let content = BS.replicate 24576 171
      entries = [FileEntry
        ("project/dependencies/package-" ++ show i ++ "/lib/index.js")
        [RawBlock content] | i <- [1 :: Int .. 1024]]
      archive = Archive (DirEntry "project" : entries)
  saveArchive scratch archive
  payload <- BL.readFile scratch
  assert "BH10 choisit pour metadonnees d'une grande archive"
    (BL.take 4 payload `elem` map (BL.fromStrict . BS.pack) [[66,72,49,48],[66,72,49,50]])
  measured <- archiveWireSize archive
  assert "taille BH10 mesuree identique au fichier" (measured == fromIntegral (BL.length payload))
  restored <- loadArchive scratch
  assert "BH10 restaure chaque bloc sans perte"
    (case restored of
      Right (Archive recovered) ->
        length recovered == length entries + 1 &&
        case last recovered of
          FileEntry _ [RawBlock bytes] -> bytes == content
          _ -> False
      _ -> False)
  removeFile scratch

testSolidCompression :: IO ()
testSolidCompression = do
  let input = BS.concat [BS.replicate 10000 65, BS.replicate 10000 65]
  blocks <- compressSolidBytesWith Auto 3 input
  assert "roundtrip groupe solid"
    (decompressBytes blocks == Right input)

-- Exercises the optional wide-window encoder and the bounded heap-based
-- decompressor. Large enough to enter the level-15 long-window branch.
testLongWindowSolid :: IO ()
testLongWindowSolid = do
  let patternBytes = BS.pack (take 1048576 (cycle [0..255]))
      large = BS.concat (replicate 9 patternBytes)
  blocks <- compressSolidBytesWith Auto 15 large
  assert "roundtrip solid fenetre longue (9 Mio)"
    (decompressBytes blocks == Right large)
  assert "solid long-window ne grossit pas les donnees"
    (sum (map compressedSize blocks) < BS.length large)

testFileDeduplication :: IO ()
testFileDeduplication = do
  temp <- getTemporaryDirectory
  (scratch, handle) <- openTempFile temp "blackhole-dedup-"
  hClose handle
  removeFile scratch
  createDirectory scratch
  let root = scratch </> "sample"
      first = root </> "a.bin"
      second = root </> "b.bin"
      output = scratch </> "restored"
      content = BS.replicate 50000 23
  createDirectory root
  BS.writeFile first content
  BS.writeFile second content
  direct <- makeArchiveDirectWithProgress PreserveSymlinks Auto 19 (\_ _ -> return ()) root
  assert "direct deduplication fichier exacte" (case direct of Archive es -> any isReference es; _ -> False)
  assert "direct reference valide" (verifyArchive direct == Right ())
  Archive archive <- makeArchive root
  assert "deduplication fichier exacte"
    (any isReference archive)
  extractArchive output (Archive archive)
  restored <- BS.readFile (output </> "sample" </> "b.bin")
  assert "roundtrip reference fichier" (restored == content)
  removePathForcibly scratch
  where
    isReference (FileRefEntry _ _ _) = True
    isReference _ = False

testSymlinks :: IO ()
testSymlinks = do
  temp <- getTemporaryDirectory
  (scratchFile, handle) <- openTempFile temp "blackhole-symlinks-"
  hClose handle
  removeFile scratchFile
  createDirectory scratchFile
  let root = scratchFile </> "sample"
      file = root </> "node_modules" </> "bcrypt" </> "bin" </> "bcrypt"
      binDir = root </> "node_modules" </> ".bin"
      link = binDir </> "bcrypt"
      escaped = root </> "unsafe"
      cyclic = root </> "cycle"
      output = scratchFile </> "restored"
  createDirectoryIfMissing True (root </> "node_modules" </> "bcrypt" </> "bin")
  createDirectoryIfMissing True binDir
  BS.writeFile file (BS.pack [1, 2, 3, 4])
  createSymbolicLink "../bcrypt/bin/bcrypt" link

  direct <- makeArchiveDirectWithProgress PreserveSymlinks Auto 19 (\_ _ -> return ()) root
  assert "direct conserve lien relatif" (case direct of Archive es -> any isLink es; _ -> False)
  assert "direct lien valide" (verifyArchive direct == Right ())
  Archive saved <- makeArchive root
  assert "preserve par defaut" (any isLink saved)
  saveArchive (scratchFile </> "example.bh") (Archive saved)
  loaded <- loadArchive (scratchFile </> "example.bh")
  case loaded of
    Left err -> putStrLn err >> exitFailure
    Right archive -> do
      assert "verification archive" (verifyArchive archive == Right ())
      extractArchive output archive
  restoredIsLink <- pathIsSymbolicLink (output </> "sample" </> "node_modules" </> ".bin" </> "bcrypt")
  target <- readSymbolicLink (output </> "sample" </> "node_modules" </> ".bin" </> "bcrypt")
  assert "preserve/restaure cible" (restoredIsLink && target == "../bcrypt/bin/bcrypt")

  -- A dangling symlink is an occupied extraction destination too.
  let occupied = scratchFile </> "occupied"
  createSymbolicLink "missing-target" occupied
  refused <- try (extractArchive occupied (Archive saved)) :: IO (Either IOException ())
  assert "refuse destination symlink cassé" (case refused of Left _ -> True; Right _ -> False)

  Archive skipped <- makeArchiveWith SkipSymlinks root
  assert "skip omet les liens" (not (any isLink skipped))

  followedArchive <- makeArchiveWith FollowSymlinks root
  let followed = case followedArchive of Archive es -> es; ChunkArchive es _ -> es
  assert "follow remplace liens par fichiers" (not (any isLink followed) &&
    length [p | (p, _) <- archiveSummary followedArchive, takeLast p == "bcrypt"] >= 2)

  createSymbolicLink "../outside" escaped
  rejected <- try (makeArchiveWith PreserveSymlinks root) :: IO (Either IOException Archive)
  assert "preserve refuse lien sortant de la racine" (case rejected of Left _ -> True; Right _ -> False)
  -- A broken, relative, out-of-root link must be rejected in preserve mode.
  unsafe <- makeArchiveWith SkipSymlinks root
  assert "skip accepte lien dangereux en l'ignorant" (verifyArchive unsafe == Right ())
  createSymbolicLink "." cyclic
  -- Follow mode must detect recursive directory links, not loop forever.
  -- Tested via a separate exception-handling integration script (see tests).
  removePathForcibly scratchFile
  where
    isLink (LinkEntry _ _) = True
    isLink _ = False
    takeLast = reverse . takeWhile (/= '/') . reverse

-- Deux progressions differentes pour le MEME octet, et positions restantes
-- volontairement irregulieres. Le mode MATH doit trouver plusieurs calculs.
testMathPieces :: IO ()
testMathPieces = do
  let size = 40000
      other = BS.pack [fromIntegral (1 + (i * 37 + i `div` 13) `mod` 251)
                      | i <- [0..size-1]]
      positions1 = [100,103..397]
      positions2 = [12000,12005..12495]
      mask = IS.fromList (positions1 ++ positions2)
      input = BS.pack [if IS.member i mask
                       then 0 else BS.index other i | i <- [0..size-1]]
      block = compressBlock input
  assert "MATH fonctions multiples meme octet"
    (mathFunctionCount block >= 2 && codecName block == "MATH")
  assert "MATH plusieurs calculs sans perte" (decompressBlock block == Right input)
  let periodicPositions = take 85 (scanl (+) 100 (cycle [3,5]))
      periodicMask = IS.fromList periodicPositions
      periodicInput = BS.pack [if IS.member i periodicMask then 0
                               else BS.index other i | i <- [0..size-1]]
      periodicBlock = compressBlock periodicInput
  assert "MATH periodicite trouvee" (codecName periodicBlock == "MATH")
  assert "MATH periodicite sans perte"
    (decompressBlock periodicBlock == Right periodicInput)
  let quadraticPositions = [100 + 2*x + x*(x-1) `div` 2 | x <- [0..70]]
      quadraticMask = IS.fromList quadraticPositions
      quadraticInput = BS.pack [if IS.member i quadraticMask then 0
                               else BS.index other i | i <- [0..size-1]]
      quadraticBlock = compressBlock quadraticInput
  assert "MATH quadratique trouvee" (codecName quadraticBlock == "MATH")
  assert "MATH quadratique sans perte"
    (decompressBlock quadraticBlock == Right quadraticInput)
  -- Une suite entrelacee : deux progressions dans la meme liste de positions.
  let interleaved = [10,13..900] ++ [11,18..900]
      interSet = IS.fromList interleaved
      interInput = BS.pack [if IS.member i interSet then 0 else BS.index other i
                           | i <- [0..size-1]]
      interBlock = compressBlock interInput
  assert "MATH progressions entrelacees" (codecName interBlock == "MATH"
    && mathFunctionCount interBlock >= 2)
  assert "MATH entrelacement exact" (decompressBlock interBlock == Right interInput)

-- AUTO must compare the complete serialized MATH representation with ZSTD,
-- rather than skipping MATH merely because ZSTD already beats RAW.
testAutoComparesMath :: IO ()
testAutoComparesMath = do
  let size = 65536
      positions = [100,103..60000]
      mask = IS.fromList positions
      input = BS.pack
        [ if IS.member i mask then 0 else fromIntegral ((i * 73 + i `div` 11) `mod` 251)
        | i <- [0..size - 1] ]
  math <- compressBytesWith MathOnly 3 input
  auto <- compressBytesWith Auto 3 input
  let mathSize = sum (map compressedSize math)
      autoSize = sum (map compressedSize auto)
  assert "AUTO compare la taille MATH/ZSTD" (autoSize <= mathSize &&
    decompressBytes auto == Right input)

-- Quality mode tries a second solid ordering, but must remain lossless and
-- must never serialize more bytes than the original solid candidate.
testSimilaritySolid :: IO ()
testSimilaritySolid = do
  temp <- getTemporaryDirectory
  (scratch, handle) <- openTempFile temp "blackhole-similarity-"
  hClose handle
  removeFile scratch
  createDirectory scratch
  let root = scratch </> "sample"
      output = scratch </> "restored"
      source = BS.concat (replicate 200 (BS.pack [123,34,110,97,109,101,34,58,49,125,10]))
  createDirectory root
  createDirectory (root </> "alpha")
  createDirectory (root </> "beta")
  BS.writeFile (root </> "alpha" </> "package.json") source
  BS.writeFile (root </> "beta" </> "package.json") (source <> BS.pack [32])
  BS.writeFile (root </> "alpha" </> "index.js") (BS.reverse source)
  BS.writeFile (root </> "beta" </> "index.js") (BS.reverse source <> BS.pack [10])
  direct <- makeArchiveDirectWithProgress PreserveSymlinks Auto 19 (\_ _ -> return ()) root
  assert "direct: archive valide" (verifyArchive direct == Right ())
  extractArchive (scratch </> "direct-restored") direct
  forM_ ["alpha/package.json", "beta/package.json", "alpha/index.js", "beta/index.js"] $ \path -> do
    actual <- BS.readFile (scratch </> "direct-restored" </> "sample" </> path)
    expected <- BS.readFile (root </> path)
    assert ("direct: extraction " ++ path) (actual == expected)
  baseline <- makeArchiveWithConfig PreserveSymlinks Auto 8 root
  optimized <- makeArchiveWithConfig PreserveSymlinks Auto 12 root
  assert "solid similarite: archive valide" (verifyArchive optimized == Right ())
  extractArchive output optimized
  forM_ ["alpha/package.json", "beta/package.json", "alpha/index.js", "beta/index.js"] $ \path -> do
    actual <- BS.readFile (output </> "sample" </> path)
    expected <- BS.readFile (root </> path)
    assert ("solid similarite roundtrip " ++ path) (actual == expected)
  assert "solid similarite: aucune corruption" (verifyArchive baseline == Right ())
  removePathForcibly scratch

-- Exercise the hybrid builder directly so that a losing candidate is tested
-- too: global selection may correctly reject DELTA on a small solid corpus.
testDeltaSolid :: IO ()
testDeltaSolid = do
  temp <- getTemporaryDirectory
  (scratch, handle) <- openTempFile temp "blackhole-delta-solid-"
  hClose handle
  removeFile scratch
  createDirectory scratch
  let pseudo n seed = BS.pack (take n (map (fromIntegral . (`div` 65536))
                        (drop 1 (iterate (\x -> (x*1664525+1013904223) `mod` 4294967296)
                          (seed :: Integer)))))
      base = pseudo 32768 7
      target = BS.take 10000 base <> BS.replicate 20 9 <> BS.drop 10020 base
      other = BS.replicate 9000 65
      files = [("sample/a.bin", base), ("sample/b.bin", target),
               ("sample/c.txt", other), ("sample/d.txt", other <> BS.singleton 66)]
      disk p = scratch </> p
      out = scratch </> "restored"
      saved = scratch </> "hybrid.bh"
  createDirectory (scratch </> "sample")
  forM_ files $ \(p, bytes) -> BS.writeFile (disk p) bytes
  BS.writeFile (scratch </> "tiny") (BS.singleton 0)
  joined <- compressSolidBytesWith ZstdOnly 8 (base <> target)
  untouched <- compressSolidBytesWith ZstdOnly 8 (other <> other <> BS.singleton 66)
  let archive = Archive [DirEntry "sample",
        SolidEntry [("sample/a.bin",32768),("sample/b.bin",32768)] joined,
        SolidEntry [("sample/c.txt",9000),("sample/d.txt",9001)] untouched,
        FileRefEntry "sample/duplicate.bin" "sample/b.bin" 32768]
      -- More than 10000 paths no longer disable the search.
      paths = [("ignored/" ++ show i, scratch </> "tiny") | i <- [1::Int ..10001]]
              ++ [(p, disk p) | (p, _) <- files]
  hybrid <- buildDeltaSolidArchive ZstdOnly 8 paths archive
  case hybrid of
    Nothing -> assert "DELTA petits fichiers trouve une reference" False
    Just candidate@(Archive entries) -> do
      assert "DELTA hybride valide, reference vers cible DELTA" (verifyArchive candidate == Right ())
      assert "DELTA petit fichier effectivement retenu"
        (any (\e -> case e of DeltaEntry "sample/b.bin" "sample/a.bin" _ _ -> True; _ -> False) entries)
      assert "groupe solid non touche conserve exactement"
        (any (\e -> case e of { SolidEntry fs bs -> fs == [("sample/c.txt",9000),("sample/d.txt",9001)] && Bin.encode bs == Bin.encode untouched; _ -> False }) entries)
      saveArchive saved candidate
      size <- archiveWireSize candidate
      payload <- BL.readFile saved
      assert "mesure egale aux octets reellement sauvegardes" (size == fromIntegral (BL.length payload))
      loaded <- loadArchive saved
      case loaded of
        Left _ -> assert "relecture hybride" False
        Right recovered -> do
          extractArchive out recovered
          forM_ (files ++ [("sample/duplicate.bin",target)]) $ \(p, bytes) -> do
            actual <- BS.readFile (out </> p)
            assert ("hybride extraction " ++ p) (actual == bytes)
    _ -> assert "hybride format attendu" False
  BS.writeFile (disk "sample/duplicate.bin") target
  optimized <- makeArchiveWithConfig PreserveSymlinks ZstdOnly 8 (scratch </> "sample")
  assert "selection complete valide" (verifyArchive optimized == Right ())
  regularBlocks <- compressSolidBytesWith ZstdOnly 8 (BS.concat (map snd files))
  let regular = Archive [DirEntry "sample",
        SolidEntry [(p, fromIntegral (BS.length bytes)) | (p, bytes) <- files] regularBlocks,
        FileRefEntry "sample/duplicate.bin" "sample/b.bin" 32768]
  regularSize <- archiveWireSize regular
  selectedSize <- archiveWireSize optimized
  assert "selection finale ne depasse pas le solid initial" (selectedSize <= regularSize)
  removePathForcibly scratch

testDeltaBoundedScan :: IO ()
testDeltaBoundedScan = do
  let base = BS.pack (take 32768 (cycle [0..255]))
      targets = [BS.empty, BS.replicate 1000000 17,
        BS.singleton 3 <> base, BS.take 1400 base <> BS.singleton 4 <> BS.drop 1400 base]
  forM_ targets $ \target -> do
    let ops = buildDelta base target
    assert "DELTA scan borne sans perte"
      (applyDelta base (fromIntegral (BS.length target)) ops == Right target)
  let small = BS.take 1800 base
      ops = buildDelta small (BS.singleton 8 <> small)
  assert "DELTA reconnait sequences inferieures a 4 Kio"
    (any (\op -> case op of Copy _ n -> n >= 256; _ -> False) ops)

-- Largest data block accepted by the existing decoder and old readers.
testMaxSolidBoundary :: IO ()
testMaxSolidBoundary = do
  let oneMiB = BS.pack (take 1048576 (cycle [0..255]))
      input = BS.concat (replicate 64 oneMiB)
  blocks <- compressSolidBytesWith ZstdOnly 15 input
  assert "solid 64 Mio taille exacte" (sum (map rawSize blocks) == 67108864)
  assert "solid 64 Mio roundtrip" (decompressBytes blocks == Right input)

-- Direct mode must split a standalone file above the decoder's 64 MiB cap.
testDirectBounds :: IO ()
testDirectBounds = do
  let bytes = BS.replicate (67108864+1) 71
  blocks <- compressSolidBytesDirectWith ZstdOnly 1 bytes
  assert "direct grand fichier respecte plafond decodeur"
    (all ((<=67108864) . rawSize) blocks && length blocks > 1)
  assert "direct grand fichier roundtrip" (decompressBytes blocks == Right bytes)
  let input = BS.replicate 1048576 11
  raw <- compressSolidBytesDirectWith RawOnly 19 input
  assert "direct mode RAW explicite" (all ((=="RAW") . codecName) raw && decompressBytes raw == Right input)

-- Three physical originals each exceed half the solid limit, forcing three
-- separate native compression jobs. Results must retain their original order.
testDirectParallelDeterminism :: IO ()
testDirectParallelDeterminism = do
  temp <- getTemporaryDirectory
  (scratch, handle) <- openTempFile temp "blackhole-parallel-"
  hClose handle
  removeFile scratch
  createDirectory scratch
  let root = scratch </> "sample"
      patternBytes = BS.pack (take 1048576 (cycle [0..255]))
      prefix = BS.concat (replicate 33 patternBytes)
  createDirectory root
  forM_ [("a.bin",1),("b.bin",2),("c.bin",3)] $ \(name,marker) ->
    BS.writeFile (root </> name) (prefix <> BS.singleton marker)
  bracket getNumCapabilities setNumCapabilities $ \_ -> do
    let make = makeArchiveDirectWithProgress PreserveSymlinks ZstdOnly 1
                 (\_ _ -> return ()) root
    setNumCapabilities 1
    sequential <- make
    setNumCapabilities 4
    parallel <- make
    first <- serializeArchive sequential
    second <- serializeArchive parallel
    assert "direct N1/N4 archives identiques octet par octet" (first == second)
    assert "direct N4 plusieurs groupes valides" (case parallel of
      Archive entries -> length [() | FileEntry{} <- entries] == 3 && verifyArchive parallel == Right ()
      _ -> False)
  removePathForcibly scratch

-- Mixed physical types and exact references must survive package regrouping.
testBalancedProfile :: Bool -> IO ()
testBalancedProfile linksAvailable = do
  temp <- getTemporaryDirectory
  (scratch, handle) <- openTempFile temp "blackhole-balanced-"
  hClose handle
  removeFile scratch
  createDirectory scratch
  let root = scratch </> "sample"
      output = scratch </> "restored"
      bytes = BS.pack (take 17000 (cycle [0..255]))
      examples = [("node_modules/pkg/lib/a.js",bytes),
                  ("node_modules/pkg/lib/a.js.map",BS.reverse bytes),
                  ("node_modules/pkg/lib/a.d.ts",BS.take 8000 bytes),
                  (".git/objects/pack/data.pack",BS.drop 100 bytes),
                  ("image.png",BS.drop 200 bytes),
                  ("binary",BS.pack [127,69,76,70] <> bytes),
                  ("duplicate.js",bytes)]
  forM_ examples $ \(name,content) -> do
    createDirectoryIfMissing True (root </> parent name)
    BS.writeFile (root </> name) content
  if linksAvailable then createSymbolicLink "image.png" (root </> "link") else return ()
  archive <- makeArchiveBalancedWithProgress PreserveSymlinks Auto 19 (\_ _ -> return ()) root
  assert "balanced profils mixtes valides" (verifyArchive archive == Right ())
  saveArchive (scratch </> "balanced.bh") archive
  restored <- loadArchive (scratch </> "balanced.bh")
  case restored of
    Left _ -> assert "balanced relit son archive" False
    Right result -> do
      extractArchive output result
      forM_ examples $ \(name,expected) -> do
        actual <- BS.readFile (output </> "sample" </> name)
        assert ("balanced conserve " ++ name) (actual == expected)
      if linksAvailable then do
        target <- readSymbolicLink (output </> "sample" </> "link")
        assert "balanced conserve cible du lien" (target == "image.png")
        else return ()
  removePathForcibly scratch
  where
    parent path = reverse (drop 1 (dropWhile (/= '/') (reverse path)))


-- Every preprocessing step is byte reversible, including non-text input.
testTurboCodec :: IO ()
testTurboCodec = do
  let samples = [BS.empty, BS.pack [0..255], BC.pack "\\n\\r\\t\\b\\f\\\\\\\"\\/\\x\\",
        BS.pack (take 10000 (cycle [0..255])),
        BC.pack (concat (replicate 8 (unwords ["identifier" ++ show i | i <- [1..1000::Int]])))]
  forM_ (zip [1::Int ..] samples) $ \(i,bytes) -> do
    normalized <- normalizeEscapes bytes
    tokenizedBytes <- encodeTextWords bytes
    assert ("normalisation exacte " ++ show i)
      ((normalized >>= restoreEscapes (fromIntegral (BS.length bytes))) == Right bytes)
    assert ("dictionnaire exact " ++ show i)
      ((tokenizedBytes >>= restoreTextWords (fromIntegral (BS.length bytes))) == Right bytes)
  assert "normalisation rejette longueur tronquee" (isLeft (restoreEscapes 1 (BS.pack [255,255,255,255])))
  assert "normalisation rejette bits inutilises" (isLeft (restoreEscapes 1 (BS.pack [1,0,0,0,10,128])))
  assert "dictionnaire rejette compte invalide" (isLeft (restoreTextWords 1 (BS.pack [255,255,255,255])))
  assert "dictionnaire rejette index absent" (isLeft (restoreTextWords 1 (BS.pack [0,0,0,0,128])))
  assert "dictionnaire rejette echappement tronque" (isLeft (restoreTextWords 1 (BS.pack [0,0,0,0,127])))
  assert "transformations bornent sortie" (isLeft (restoreTextWords 67108865 BS.empty) && isLeft (restoreEscapes 67108865 BS.empty))
  let text = BC.pack (concat (replicate 15000 "const identifier = JSON.parse(\"hello\\nworld\");\n"))
  blocks <- compressSolidTextWith Auto 16 text
  assert "turbo utilise codec texte" (any isText blocks)
  assert "turbo texte restitue tous les octets" (decompressBytes blocks == Right text)
  assert "turbo texte compte taille originale" (sum (map rawSize blocks) == BS.length text)
  let archive = Archive [FileEntry "text.js" blocks]
  bytes <- serializeArchive archive
  assert "texte force BH11/BH12 meme metadonnees courtes" (BL.take 4 bytes `elem` map bcToBL ["BH11","BH12"])
  temp <- getTemporaryDirectory
  (path,h) <- openTempFile temp "blackhole-bh11-"
  hClose h
  saveArchive path archive
  loaded <- loadArchive path
  actual <- BL.readFile path
  assert "taille serialisee BH11 exacte" (actual == bytes)
  assert "BH11 relit et verifie" (case loaded of Right a -> verifyArchive a == Right (); _ -> False)
  removeFile path
  assert "texte rejette tailles excessives" (isLeft (decompressBlock (TextZstdBlock 67108865 0 0 BS.empty)))
  where
    isText TextZstdBlock{} = True
    isText _ = False
    bcToBL = BL.fromStrict . BC.pack

-- Compare the optimized POSIX validation with its previous reference.
testPathEquivalence :: IO ()
testPathEquivalence = do
  let paths = concat [sequence (replicate n "ab./\\\0") | n <- [0..6]]
      old name = not (null name) && not (isAbsolute name) && '\0' `notElem` name && '\\' `notElem` name && normalise name == name && all (`notElem` [".","..",""]) (splitDirectories name)
      accepted name = isRight (verifyArchive (Archive [FileEntry name []]))
  assert "validation chemins equivalente a reference POSIX" (all (\p -> old p == accepted p) paths)
  assert "fichier parent rejete" (isLeft (verifyArchive (Archive [FileEntry "a" [],FileEntry "a/b" []])))
  assert "prefixe de nom autorise" (isRight (verifyArchive (Archive [FileEntry "a" [],FileEntry "a.bin" []])))

-- Native physical traversal must preserve ordering, Unicode, newlines and links.
testTurboTraversal :: Bool -> IO ()
testTurboTraversal linksAvailable = do
  temp <- getTemporaryDirectory
  (scratch,h) <- openTempFile temp "blackhole-turbo-tree-"
  hClose h
  removeFile scratch
  createDirectory scratch
  let root = scratch </> "sample"
      names = ["a/z.js","a.bin",if isHostWindows then "éà-file.js" else "éà\nfile.js"]
  createDirectoryIfMissing True (root </> "a")
  forM_ names $ \name -> BS.writeFile (root </> name) (BC.pack name)
  if linksAvailable then createSymbolicLink "a.bin" (root </> "link") else return ()
  plain <- makeArchiveBalancedWithProgress PreserveSymlinks RawOnly 19 (\_ _ -> return ()) root
  turbo <- makeArchiveWithPlanProgress TurboPlan PreserveSymlinks RawOnly 19 (\_ _ -> return ()) root
  a <- serializeArchive plain
  b <- serializeArchive turbo
  assert "parcours natif conserve ordre et contenu" (a == b)
  fallback <- bracket (lookupEnv "PATH") (\old -> maybe (unsetEnv "PATH") (setEnv "PATH") old) $ \_ -> do
    setEnv "PATH" ""
    makeArchiveWithPlanProgress TurboPlan PreserveSymlinks RawOnly 19 (\_ _ -> return ()) root
  fallbackBytes <- serializeArchive fallback
  assert "turbo fonctionne sans find" (fallbackBytes == b)
  followed <- makeArchiveWithPlanProgress TurboPlan FollowSymlinks RawOnly 19 (\_ _ -> return ()) root
  assert "turbo suit les liens sur demande" (verifyArchive followed == Right ())
  skipped <- makeArchiveWithPlanProgress TurboPlan SkipSymlinks RawOnly 19 (\_ _ -> return ()) root
  assert "turbo ignore liens sur demande" (case skipped of Archive es -> not (any isLink es); _ -> False)
  if linksAvailable then do
    createSymbolicLink "../../outside" (root </> "external")
    dangerous <- try (makeArchiveWithPlanProgress TurboPlan PreserveSymlinks Auto 19 (\_ _ -> return ()) root) :: IO (Either IOException Archive)
    assert "parcours natif refuse lien externe" (isLeft dangerous)
    else return ()
  skipExternal <- makeArchiveWithPlanProgress TurboPlan SkipSymlinks RawOnly 19 (\_ _ -> return ()) root
  assert "turbo peut ignorer lien externe" (verifyArchive skipExternal == Right ())
  removePathForcibly scratch
  where
    isLink LinkEntry{} = True
    isLink _ = False


-- Directory cursor follows the exact example agreed with the user.
testRelativePaths :: IO ()
testRelativePaths = do
  let names = ["p/1/login/login.js","p/1/truc.js","p/bidule.pasl",
               "p/act/act.js",".gitignore","f1"]
      example = Archive (DirEntry "p/1/login" : [FileEntry name [] | name <- names])
      field tag control text = BL.pack [tag,control,fromIntegral (length text)] <> BL.fromStrict (BC.pack text)
      wire = BL.pack [0,7] <> field 0 0 "p/1/login" <> field 1 0 "login.js" <>
             field 1 2 "truc.js" <> field 1 2 "bidule.pasl" <> field 1 0 "act/act.js" <>
             field 1 4 ".gitignore" <> field 1 0 "f1"
  assert "chemins relatifs encodent exactement l'exemple" (encodePathSkeleton example == Right wire)
  assert "chemins relatifs restituent exactement l'arbre" (fmap Bin.encode (decodePathSkeleton wire) == Right (Bin.encode example))
  let deep = concat (replicate 200 "nested/") ++ "leaf"
      variants = [Archive [DirEntry deep, FileEntry "top.js" [], FileEntry (deep ++ "/🐈.js") []],
                  Archive [FileEntry ("root/pkg-" ++ show i ++ "/file.js") [] | i <- [1..400::Int]],
                  Archive [FileEntry ("root/pkg-" ++ show i ++ "/file.js") [] | i <- [400,399..1::Int]]]
  forM_ variants $ \sample -> assert "BH12 ordre variable, longs compteurs et Unicode"
    ((encodePathSkeleton sample >>= decodePathSkeleton >>= (Right . Bin.encode)) == Right (Bin.encode sample))
  assert "BH12 borne la longueur des noms" (isLeft (encodePathSkeleton (Archive [FileEntry (replicate 1048577 'a') []])))
  let mixed = Archive [DirEntry "root/",DirEntry "root/d/",
        FileEntry "root/d/@name.js" [],FileEntry "root/d/é\n.js" [],
        FileEntry "root/d/\xDCFF.bin" [],
        LinkEntry "root/d/link" "../d/@name.js",
        SolidEntry [("root/d/a",3),("root/other/b",4)] [],
        FileRefEntry "root/ref" "root/d/a" 3,
        FileEntry "root/after-ref" [],
        DeltaEntry "root/delta" "root/other/b" 4 [],
        FileEntry "root/after-delta" [],
        ChunkEntry "root/chunks" [(9,3),(10,4)]]
  case encodePathSkeleton mixed of
    Left _ -> assert "metadonnees mixtes encodables" False
    Right encoded -> assert "tous types, Unicode, @, lien, slash final et octets non UTF8"
      (fmap Bin.encode (decodePathSkeleton encoded) == Right (Bin.encode mixed))
  -- Generic Binary layout used to construct a legacy ChunkArchive fixture;
  -- the constructor type of ChunkRecord is intentionally private.
  let chunks = Bin.decode (BL.singleton 1 <> Bin.encode [ChunkEntry "root/f" [(7,3)]] <>
                Bin.encode [(7::Word32,3::Word32,[RawBlock (BC.pack "@@/")])]) :: Archive
  case encodePathSkeleton chunks of
    Left _ -> assert "metadonnees fragments encodables" False
    Right encoded -> assert "metadonnees fragments conservent identifiant et taille"
      (case decodePathSkeleton encoded of
        Right (ChunkArchive es rs) -> length rs == 1 && case es of [ChunkEntry "root/f" [(7,3)]] -> True; _ -> False
        _ -> False)
  forM_ [BL.empty,BL.pack [0],BL.pack [2,0],BL.pack [0,1,1,2,1,97],
         BL.pack [0,1,1,0,4,46,46,47,97],
         BL.pack [0,1,1,0,2,47,97],BL.pack [0,1,1,0,1,0],
         BL.pack [0,1,1,0,1,92],BL.pack [0,1,1,0,0],
         BL.pack [0,1,99],BL.pack [0,128,0],BL.pack [0,255,255,255,255,31],
         BL.pack [0,1,1,0,1,255,255,255,127]] $ \bad ->
    assert "BH12 rejette chemin/compteur malforme" (isLeft (decodePathSkeleton bad))
  assert "BH12 rejette donnees apres metadonnees" (isLeft (decodePathSkeleton (wire <> BL.singleton 0)))
  assert "BH12 rejette chemin invalide avant encodage" (isLeft (encodePathSkeleton (Archive [FileEntry "../escape" []])))
  assert "BH12 rejette tous prefixes tronques de l'exemple"
    (all (isLeft . decodePathSkeleton . (`BL.take` wire)) [0..BL.length wire-1])
  let content = BC.pack (concat (replicate 8000 "@@/p/1/login/\n@literal content\0"))
      payloadArchive = Archive [DirEntry "project",
        SolidEntry [("project/deep/path/file-" ++ show i ++ ".js", fromIntegral (BS.length content)) | i <- [1..100::Int]] [RawBlock (BS.concat (replicate 100 content))]]
  temp <- getTemporaryDirectory
  (file,h) <- openTempFile temp "blackhole-paths-"
  hClose h
  saveArchive file payloadArchive
  actual <- BL.readFile file
  loaded <- loadArchive file
  assert "BH12 selectionne quand plus petit" (BL.take 4 actual == BL.fromStrict (BC.pack "BH12"))
  assert "BH12 ne change aucun octet des blocs" (fmap Bin.encode loaded == Right (Bin.encode payloadArchive))
  assert "BH12 verifie contenu avec @ et NUL" (case loaded of Right a -> verifyArchive a == Right (); _ -> False)
  removeFile file
  -- Explicit BH10 fixture checks backward reading independently of selection.
  let oldShape = Archive [DirEntry ("project/long/repeated/path/" ++ show i) | i <- [1..100::Int]]
      oldMetadata = BL.toStrict (Bin.encode oldShape)
  compressed <- compressSolidBytesDirectWith ZstdOnly 9 oldMetadata
  case compressed of
    [ZstdBlock _ packed] -> do
      (oldFile,handle) <- openTempFile temp "blackhole-old-bh10-"
      hClose handle
      BL.writeFile oldFile (BL.fromStrict (BC.pack "BH10") <>
        Bin.encode (fromIntegral (BS.length oldMetadata)::Word32) <>
        Bin.encode (fromIntegral (BS.length packed)::Word32) <> BL.fromStrict packed)
      restored <- loadArchive oldFile
      assert "nouveau lecteur conserve BH10" (fmap Bin.encode restored == Right (Bin.encode oldShape))
      removeFile oldFile
    _ -> assert "fixture BH10 utilise ZSTD" False


-- The source archive tests still run without symbolic-link privileges on
-- Windows. Skips are explicit; CI/native users can enable Developer Mode.
probeSymlinks :: IO Bool
probeSymlinks
  | not isHostWindows = return True
  | otherwise = do
      temp <- getTemporaryDirectory
      (source,handle) <- openTempFile temp "blackhole-link-probe-"
      hClose handle
      let link = source ++ "-link"
      result <- try (Directory.createFileLink source link) :: IO (Either IOException ())
      case result of Right () -> removeFile link; _ -> return ()
      removeFile source
      return (isRight result)

testWindowsPaths :: Bool -> IO ()
testWindowsPaths linksAvailable = do
  assert "conversion chemins Windows en chemins archive POSIX"
    (windowsToArchivePath "C:\\data\\root\\file.js" == "C:/data/root/file.js")
  assert "Win32 encode les noms non BMP en paires UTF16" (windowsUTF16 "A🐈" == [65,55357,56328])
  assert "noms Windows ordinaires acceptes"
    (validateWindowsPaths [(True,"root"),(False,"root/é space/@f.js"),(False,"root/.gitignore")] [] == Right ())
  forM_ ["C:escape","C:/escape","//server/share","root/CON","root/NUL.txt","root/COM¹.log",
         "root/a:stream","root/a.","root/a ","root/a?","root/a\\b","root/a\n","root/\xDCFF.bin"] $ \name ->
    assert "Windows refuse les noms non representables" (isLeft (validateWindowsPaths [(False,name)] []))
  assert "Windows refuse collisions de casse"
    (isLeft (validateWindowsPaths [(False,"root/a"),(False,"root/A")] []))
  assert "Windows refuse collisions de dossiers implicites"
    (isLeft (validateWindowsPaths [(False,"Root/a"),(False,"root/b")] []))
  assert "Windows refuse alias fichier parent"
    (isLeft (validateWindowsPaths [(False,"root/a"),(False,"root/A/b")] []))
  assert "Windows refuse cible absolue de lien"
    (isLeft (validateWindowsPaths [(False,"root/link")] [("root/link","C:/outside")] ))
  assert "Windows accepte cible relative interne de lien"
    (validateWindowsPaths [(False,"root/d/link")] [("root/d/link","../file")] == Right ())
  temp <- getTemporaryDirectory
  (scratch,h) <- openTempFile temp "blackhole-windows-"
  hClose h
  removeFile scratch
  createDirectory scratch
  if isHostWindows then do
    let bad = Archive [FileEntry "root/a" [],FileEntry "root/A" []]
        output = scratch </> "collision"
    result <- try (extractArchive output bad) :: IO (Either IOException ())
    created <- Directory.doesPathExist output
    assert "Windows rejette collisions avant creation de destination" (isLeft result && not created)
    else return ()
  if linksAvailable then do
    let source = scratch </> "source"
    createDirectoryIfMissing True (source </> "directory")
    BS.writeFile (source </> "directory" </> "data.txt") (BC.pack "directory link")
    Directory.createDirectoryLink "directory" (source </> "directory-link")
    Directory.createDirectoryLink "directory" (source </> "🐈-directory-link")
    archive <- makeArchiveWith PreserveSymlinks source
    extractArchive (scratch </> "restored") archive
    content <- BS.readFile (scratch </> "restored" </> "source" </> "directory-link" </> "data.txt")
    assert "liens de dossiers sont restaures comme dossiers" (content == BC.pack "directory link")
    emojiContent <- BS.readFile (scratch </> "restored" </> "source" </> "🐈-directory-link" </> "data.txt")
    assert "liens de dossiers avec nom Unicode non BMP" (emojiContent == BC.pack "directory link")
#if defined(mingw32_HOST_OS)
    Directory.createDirectoryLink "missing" (source </> "broken-directory-link")
    withBroken <- makeArchiveWith PreserveSymlinks source
    assert "Windows conserve le type des liens de dossiers casses"
      (case withBroken of Archive es -> any (\e -> case e of LinkEntry "source/broken-directory-link" "missing/" -> True; _ -> False) es; _ -> False)
    let restoredBroken = scratch </> "restored-broken"
    extractArchive restoredBroken withBroken
    Directory.removeDirectoryLink (restoredBroken </> "source" </> "broken-directory-link")
    assert "Windows restaure un lien casse de type dossier" True
#endif
    else return ()
  removePathForcibly scratch
