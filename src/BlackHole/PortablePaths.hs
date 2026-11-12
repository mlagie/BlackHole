{-# LANGUAGE CPP #-}
module BlackHole.PortablePaths
  ( isHostWindows, toArchivePath, fromArchivePath, windowsToArchivePath
  , validateWindowsPaths, nativePathKey, windowsUTF16 ) where
import Data.Char (ord, toLower, toUpper)
import Data.Word (Word16)
import Data.List (isPrefixOf)
import Control.Monad (foldM, unless)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified System.FilePath as Native
import qualified System.FilePath.Posix as A
import qualified System.FilePath.Windows as W

isHostWindows :: Bool
#if defined(mingw32_HOST_OS) || defined(BLACKHOLE_WINDOWS_TEST)
isHostWindows = True
#else
isHostWindows = False
#endif

windowsToArchivePath :: FilePath -> FilePath
windowsToArchivePath = map (\c -> if c == '\\' then '/' else c)

-- Use the actual host separator even in the Linux Windows-branch test build.
toArchivePath :: FilePath -> FilePath
toArchivePath = if Native.pathSeparator == '\\' then windowsToArchivePath else id
fromArchivePath :: FilePath -> FilePath
fromArchivePath = if Native.pathSeparator == '/' then id else map (\c -> if c == '/' then Native.pathSeparator else c)
nativePathKey :: FilePath -> FilePath
nativePathKey = if isHostWindows then map toLower . Native.normalise else id

-- Archive syntax remains POSIX on every host. Windows rules are an extraction
-- preflight, so listing/verifying a Linux archive never renames its contents.
validateWindowsPaths :: [(Bool,FilePath)] -> [(FilePath,FilePath)] -> Either String ()
validateWindowsPaths entries links = do
  mapM_ (validPath . snd) entries
  mapM_ (validTarget . snd) links
  _ <- foldM addPrefixes Map.empty (map snd entries)
  let names = map (key . snd) entries
      known = Set.fromList names
      nonDirs = [key p | (False,p) <- entries]
      descendant p = case Set.lookupGE (p ++ "/") known of
        Just candidate -> (p ++ "/") `isPrefixOf` candidate
        Nothing -> False
  unless (Set.size known == length names) (Left "Windows: chemins identiques apres conversion")
  unless (not (any descendant nonDirs)) (Left "Windows: fichier ou lien utilise comme dossier parent")
  return ()
  where
    key = map toLower . A.dropTrailingPathSeparator
    validPath p = unless (not (null p) && not (A.isAbsolute p) && not (W.hasDrive p) &&
        not ('\\' `elem` p) && all validPart (A.splitDirectories p))
      (Left ("Windows: nom de fichier non representable: " ++ show p))
    validTarget p = unless (not (null p) && not (W.hasDrive p) && not (W.isAbsolute p) &&
        not (A.isAbsolute p) && not ('\\' `elem` p) &&
        all (\part -> part `elem` [".",".."] || validPart part) (A.splitDirectories p))
      (Left ("Windows: cible de lien non representable: " ++ show p))
    validPart p = not (null p) && p `notElem` [".",".."] && W.isValid p &&
      last p `notElem` [' ','.'] && all validChar p && not (reserved p)
    validChar c = ord c >= 32 && not (ord c >= 55296 && ord c <= 57343) &&
      c `notElem` "<>:\"/\\|?*"
    reserved p = let stem = map toUpper (takeWhile (/='.') p)
      in stem `elem` (["CON","PRN","AUX","NUL","CONIN$","CONOUT$"] ++
           [prefix ++ [digit] | prefix <- ["COM","LPT"], digit <- "123456789¹²³"])
    addPrefixes known p = foldM add known (drop 1 (scanl (A.</>) "" (A.splitDirectories p)))
    add known p = case Map.lookup (key p) known of
      Just previous | previous /= p -> Left ("Windows: collision de casse entre " ++ show previous ++ " et " ++ show p)
      _ -> Right (Map.insert (key p) p known)


-- Win32 W APIs require UTF16 code units; wchar_t is 16-bit on Windows.
-- Converting each Haskell Char directly to a 16-bit wchar loses non-BMP names.
windowsUTF16 :: String -> [Word16]
windowsUTF16 = concatMap encode
  where
    encode c
      | ord c <= 65535 = [fromIntegral (ord c)]
      | otherwise = let n = ord c - 65536 in
          [fromIntegral (55296 + n `div` 1024),fromIntegral (56320 + n `mod` 1024)]
