module Main (main) where

import BlackHole.Archive
import BlackHole.Engine (Codec(..))
import Control.Exception (SomeException, displayException, try)
import Control.Concurrent.MVar (newMVar, modifyMVar_)
import Control.Monad (forM_, unless, when)
import Data.Char (isAscii, isPrint)
import System.Environment (getArgs, lookupEnv, setEnv)
import System.Exit (exitFailure)
import System.IO (hFlush, stdout, stderr, hSetEncoding, utf8, hIsTerminalDevice)
import System.Directory (doesPathExist)
import System.FilePath (dropExtension, (</>), takeDirectory, takeExtension, takeFileName)
import GHC.Clock (getMonotonicTimeNSec)
import qualified Data.ByteString.Lazy as BL

usage :: String
usage = unlines
  [ "BlackHole - BH06/BH07/BH08/BH09/BH10/BH11/BH12 (metadonnees separees)"
  , "  blackhole compress CHEMIN [-o ARCHIVE.bh] [--fast|--best|--ultra|--balanced|--turbo] [--codec auto|zstd|math|raw]"
  , "                 [--level N (1..22)] [--workers N (1..64)] [--trace] [--direct] [--skip-symlinks|--preserve-symlinks|--follow-symlinks]"
  , "  blackhole extract ARCHIVE.bh [-o DOSSIER_SORTIE]"
  , "  blackhole ARCHIVE.bh  (extraction automatique dans un dossier deduit du nom)"
  , "  blackhole list ARCHIVE.bh"
  , "  blackhole test ARCHIVE.bh"
  , "  blackhole analyze ARCHIVE.bh"
  , "  Defaut : profil turbo, niveau 19, groupes solid et --codec auto"
  , "  --direct : regroupements solid distribues aux workers"
  , "  --workers N : N workers de compression avec file de taches partagee"
  , "  --turbo : texte reversible et parallelisme natif; chemins relatifs BH12 si plus petits"
  , "  --balanced : regroupement par paquet, niveaux adaptes, jusqu'a 4 travailleurs"
  , "  --fast : niveau 1; --best : niveau 12; --ultra : niveau 15, essais solid jusqu'a 64 Mio"
  ]

main :: IO ()
main = do
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8
  args <- getArgs
  result <- try (run args) :: IO (Either SomeException ())
  case result of
    Left err -> putStrLn ("Erreur : " ++ displayException err) >> exitFailure
    Right () -> return ()

run :: [String] -> IO ()
run ["--version"] = putStrLn "BlackHole 0.12.5"
run ("compress":source:options) = do
  let tracing = "--trace" `elem` options
      effectiveOptions = filter (/= "--trace") options
  when tracing (setEnv "BLACKHOLE_TRACE" "1")
  let (parsedPlan, expanded) = expandDirectOptions effectiveOptions
      plan = if parsedPlan == SearchPlan then TurboPlan else parsedPlan
      defaultLevel = if plan == TurboPlan && not (hasQualityOption expanded) then 19 else 8
  (workerOverride, cleanedOptions) <- extractWorkers expanded
  (out, mode, codec, level) <- compressOptions (source ++ ".bh") PreserveSymlinks Auto defaultLevel cleanedOptions
  progressOutput <- lookupEnv "BLACKHOLE_PROGRESS"
  started <- getMonotonicTimeNSec
  -- A rolling interval makes the displayed rate responsive to I/O variations.
  compressionProgress <- newMVar (0 :: Integer, started, 0 :: Integer, started)
  writingProgress <- newMVar (0 :: Integer, started, 0 :: Integer, started)
  interactive <- hIsTerminalDevice stdout
  -- A carriage return only returns to the *last* physical terminal row.
  -- Avoid terminal wrapping entirely and overwrite the full previous row.
  -- This works in Windows terminals without ANSI/VT escape support.
  consoleLock <- newMVar ()
  columnsEnv <- lookupEnv "COLUMNS"
  let consoleWidth = case columnsEnv >>= readPositiveInt of
        Just n -> max 16 (min 58 (n - 2))
        Nothing -> 58
      gui = progressOutput == Just "gui" || not interactive
      emit detailed compact = modifyMVar_ consoleLock $ \() -> do
        if gui
          then putStrLn detailed
          else do
            let safe = map (\c -> if isAscii c && isPrint c then c else '?') compact
                displayed = take consoleWidth safe
            putStr ("\r" ++ displayed ++ replicate (consoleWidth - length displayed) ' ')
        hFlush stdout
        return ()
      -- Print at most about five updates per second, including a final update.
      reportStage state stage done total name = modifyMVar_ state $ \(previous, lastTime, lastBytes, lastSample) -> do
        now <- getMonotonicTimeNSec
        let percent = if total <= 0 then 100 else min 100 (done * 100 `div` total)
            refresh = now - lastTime >= 200000000 || done >= total
            interval = fromIntegral (now - lastSample) / 1000000000 :: Double
            rate = if interval <= 0 then 0 else fromIntegral (max 0 (done - lastBytes)) / interval
            eta = if rate <= 0 then "calcul..." else formatDuration (fromIntegral (max 0 (total - done)) / rate)
            line = stage ++ " : " ++ show percent ++ " %" ++ name
                ++ " | Debit : " ++ formatRate rate ++ " | Temps restant : " ++ eta
            shortName = take 10 (if take 3 name == " - " then drop 3 name else name)
            compact = (if stage == "Compression" then "Comp " else "Write ")
                ++ show percent ++ "%"
                ++ (if null shortName then "" else " | " ++ shortName)
                ++ " | " ++ formatRate rate ++ " | ETA " ++ eta
        if refresh && (done /= previous || done >= total)
          then emit line compact >> return (done, now, done, now)
          else return (previous, lastTime, lastBytes, lastSample)
      reportFile done total file = reportStage compressionProgress "Compression" done total
          (if null file then "" else " - " ++ takeFileName file)
      reportWriting done total = reportStage writingProgress "Ecriture" done total ""
  archive <- case workerOverride of
    Nothing -> makeArchiveWithPlanProgressFiles plan mode codec level reportFile source
    Just n -> makeArchiveWithPlanProgressFilesWorkers n plan mode codec level reportFile source
  whenConsoleNewline gui
  putStrLn "Serialisation de l'archive..."
  saveArchiveWithProgress out archive reportWriting
  whenConsoleNewline gui
  finished <- getMonotonicTimeNSec
  let elapsed = fromIntegral (finished - started) / 1000000000 :: Double
  putStrLn "Compression : 100 % | Ecriture : 100 %"
  putStrLn ("Temps de compression : " ++ formatSeconds elapsed ++ " s")
  putStrLn ("Archive creee : " ++ out)
  printStats out archive

run ("extract":source:options) = do
  out <- outputOption "blackhole-extracted" options
  archive <- requireArchive source
  extractArchive out archive
  putStrLn ("Extraction terminee : " ++ out)
run [source]
  | takeExtension source == ".bh" = do
      out <- automaticOutputPath source
      archive <- requireArchive source
      extractArchive out archive
      putStrLn ("Extraction terminee : " ++ out)
run ["list", source] = do
  archive <- requireArchive source
  forM_ (archiveSummary archive) $ \(path, info) -> putStrLn (info ++ "\t" ++ path)
run ["test", source] = do
  archive <- requireArchive source
  either (ioError . userError) (const (putStrLn "Archive valide")) (verifyArchive archive)
run ["analyze", source] = requireArchive source >>= printStats source
run _ = putStrLn usage

readPositiveInt :: String -> Maybe Int
readPositiveInt value = case reads value of
  [(n, "")] | n > 0 -> Just n
  _ -> Nothing

whenConsoleNewline :: Bool -> IO ()
whenConsoleNewline gui = unless gui (putStrLn "")

formatRate :: Double -> String
formatRate rate
  | rate >= 1024 * 1024 = formatDecimal (rate / (1024 * 1024)) ++ " MiB/s"
  | rate >= 1024 = formatDecimal (rate / 1024) ++ " KiB/s"
  | otherwise = formatDecimal rate ++ " octets/s"

formatDecimal :: Double -> String
formatDecimal value = show (fromIntegral (round (value * 10) :: Integer) / 10 :: Double)

formatDuration :: Double -> String
formatDuration seconds =
  let total = max 0 (round seconds :: Integer)
      hours = total `div` 3600
      minutes = (total `mod` 3600) `div` 60
      secs = total `mod` 60
      padded n = if n < 10 then "0" ++ show n else show n
  in if hours > 0
       then show hours ++ ":" ++ padded minutes ++ ":" ++ padded secs
       else padded minutes ++ ":" ++ padded secs

printStats :: FilePath -> Archive -> IO ()
printStats path archive = do
  fileBytes <- BL.length <$> BL.readFile path
  let (files, original, encoded, raw, math, zstd) = archiveStats archive
      metadata = fromIntegral fileBytes - encoded
      ratio :: Double
      ratio = if original == 0 then 0 else fromIntegral fileBytes * 100 / fromIntegral original
  putStrLn ("Fichiers : " ++ show files)
  putStrLn ("Donnees d'origine : " ++ show original ++ " octets")
  putStrLn ("Blocs encodes : " ++ show encoded ++ " octets")
  putStrLn ("Surcout structure + metadonnees : " ++ show metadata ++ " octets")
  putStrLn ("Blocs : RAW=" ++ show raw ++ " MATH=" ++ show math ++ " ZSTD=" ++ show zstd)
  putStrLn ("Fonctions mathematiques stockees : " ++ show (archiveMathFunctions archive))
  putStrLn ("Archive : " ++ show fileBytes ++ " octets (" ++ show (round ratio :: Int) ++ " % des donnees originales)")

-- Consume value-taking options intact, so an output filename or codec value
-- cannot accidentally be interpreted as a quality flag.
expandDirectOptions :: [String] -> (CompressionPlan, [String])
expandDirectOptions [] = (SearchPlan, [])
expandDirectOptions ("--direct":rest) =
  let (plan, args) = expandDirectOptions rest
  in (if plan == SearchPlan then DirectPlan else plan, args)
expandDirectOptions ("--balanced":rest) =
  let (_, args) = expandDirectOptions rest in (BalancedPlan, "--level":"19":args)
expandDirectOptions ("--turbo":rest) =
  let (_, args) = expandDirectOptions rest in (TurboPlan, "--level":"19":args)
expandDirectOptions (option:value:rest)
  | option `elem` ["-o", "--codec", "--level", "--workers"] =
      let (plan, args) = expandDirectOptions rest in (plan, option:value:args)
expandDirectOptions (arg:rest) =
  let (plan, args) = expandDirectOptions rest in (plan, arg:args)

-- Parse this optional setting separately to keep the legacy option parser
-- and existing public compression APIs backward compatible.
extractWorkers :: [String] -> IO (Maybe Int, [String])
extractWorkers = go Nothing
  where
    go chosen [] = return (chosen, [])
    go _ ["--workers"] = ioError (userError "--workers attend un entier entre 1 et 64")
    go Nothing ("--workers":value:rest) = case reads value of
      [(n, "")] | n >= (1 :: Int) && n <= 64 -> go (Just n) rest
      _ -> ioError (userError "--workers attend un entier entre 1 et 64")
    go (Just _) ("--workers":_:_) = ioError (userError "--workers ne peut etre indique qu'une fois")
    go chosen (option:rest) = do
      (workers, remaining) <- go chosen rest
      return (workers, option : remaining)

hasQualityOption :: [String] -> Bool
hasQualityOption = any (`elem` ["--fast", "--best", "--ultra", "--level"])

compressOptions :: String -> SymlinkMode -> Codec -> Int -> [String] -> IO (String, SymlinkMode, Codec, Int)
compressOptions out mode codec level args = go out mode codec level False False False args
  where
    go path links compression quality seenOut seenMode seenLevel [] =
      let _ = (seenOut, seenMode, seenLevel)
      in return (path, links, compression, quality)
    go _ _ _ _ True _ _ ("-o":_) = ioError (userError "Option -o repetee")
    go _ _ _ _ _ _ _ ["-o"] = ioError (userError "Il manque le nom de sortie")
    go _ links compression quality _ seenMode seenLevel ("-o":value:rest) =
      go value links compression quality True seenMode seenLevel rest
    go path links _ quality seenOut seenMode seenLevel ("--codec":value:rest) =
      case value of
        "auto" -> go path links Auto quality seenOut seenMode seenLevel rest
        "zstd" -> go path links ZstdOnly quality seenOut seenMode seenLevel rest
        "math" -> go path links MathOnly quality seenOut seenMode seenLevel rest
        "raw" -> go path links RawOnly quality seenOut seenMode seenLevel rest
        _ -> ioError (userError "Codec inconnu : auto|zstd|math|raw")
    go path links compression _ seenOut seenMode False ("--fast":rest) =
      go path links compression 1 seenOut seenMode True rest
    go path links compression _ seenOut seenMode False ("--best":rest) =
      go path links compression 12 seenOut seenMode True rest
    go path links compression _ seenOut seenMode False ("--ultra":rest) =
      go path links compression 15 seenOut seenMode True rest
    go path links compression _ seenOut seenMode False ("--level":value:rest) =
      case reads value of
        [(parsedLevel, "")] | parsedLevel >= 1 && parsedLevel <= 22 ->
          go path links compression parsedLevel seenOut seenMode True rest
        _ -> ioError (userError "Niveau invalide : utiliser un entier de 1 a 22")
    go path _ compression quality seenOut False seenLevel ("--skip-symlinks":rest) =
      go path SkipSymlinks compression quality seenOut True seenLevel rest
    go path _ compression quality seenOut False seenLevel ("--preserve-symlinks":rest) =
      go path PreserveSymlinks compression quality seenOut True seenLevel rest
    go path _ compression quality seenOut False seenLevel ("--follow-symlinks":rest) =
      go path FollowSymlinks compression quality seenOut True seenLevel rest
    go _ _ _ _ _ _ _ _ = ioError (userError "Options invalides : voir blackhole --help")

outputOption :: String -> [String] -> IO String
outputOption defaultValue [] = return defaultValue
outputOption _ ["-o", value] = return value
outputOption _ _ = ioError (userError "Option invalide : utiliser -o CHEMIN")

automaticOutputPath :: FilePath -> IO FilePath
automaticOutputPath archive = choose (baseName archive) 0
  where
    directory = takeDirectory archive
    baseName path = directory </> dropExtension (takeFileName path)
    choose base suffix = do
      let candidate = base ++ concat (replicate suffix "-copy")
      exists <- doesPathExist candidate
      if exists then choose base (suffix + 1) else return candidate

requireArchive :: FilePath -> IO Archive
requireArchive path = do
  result <- loadArchive path
  either (ioError . userError) return result

formatSeconds :: Double -> String
formatSeconds seconds =
  let hundredths = round (seconds * 100) :: Integer
      whole = hundredths `div` 100
      fraction = hundredths `mod` 100
      fractionText = if fraction < 10 then "0" ++ show fraction else show fraction
  in show whole ++ "." ++ fractionText
