{-# LANGUAGE CPP #-}
{-# LANGUAGE ForeignFunctionInterface #-}
module BlackHole.Platform (FileKind(..), fileKind, readArchiveLink, createArchiveLink) where
import qualified System.Directory as D
import qualified System.FilePath as N
import BlackHole.PortablePaths (toArchivePath, fromArchivePath, windowsUTF16)
#if !defined(mingw32_HOST_OS) && !defined(BLACKHOLE_WINDOWS_TEST)
import qualified System.Posix.Files as P
#else
import Control.Monad (when)
import qualified System.FilePath.Windows as W
import Data.List (isPrefixOf)
#endif
#if defined(mingw32_HOST_OS)
import Foreign.Ptr (Ptr)
import Foreign.Marshal.Array (withArray0)
import Data.Word (Word16)
import Foreign.C.Types (CInt(..))
foreign import ccall safe "bh_windows_directory_attribute"
  directoryAttribute :: Ptr Word16 -> IO CInt
#endif

data FileKind = RegularFile | Directory | SymbolicLink | Unsupported deriving (Eq,Show)
fileKind :: Bool -> FilePath -> IO FileKind
#if !defined(mingw32_HOST_OS) && !defined(BLACKHOLE_WINDOWS_TEST)
fileKind follow path = do
  status <- (if follow then P.getFileStatus else P.getSymbolicLinkStatus) path
  return (if P.isSymbolicLink status then SymbolicLink else if P.isDirectory status then Directory
    else if P.isRegularFile status then RegularFile else Unsupported)
#else
fileKind follow path = do
  link <- if follow then return False else D.pathIsSymbolicLink path
  if link then return SymbolicLink else do
    directory <- D.doesDirectoryExist path
    regular <- D.doesFileExist path
    return (if directory then Directory else if regular then RegularFile else Unsupported)
#endif

readArchiveLink :: FilePath -> IO FilePath
#if !defined(mingw32_HOST_OS) && !defined(BLACKHOLE_WINDOWS_TEST)
readArchiveLink = P.readSymbolicLink
#else
readArchiveLink path = do
  target <- D.getSymbolicLinkTarget path
  when (W.hasDrive target || W.isAbsolute target) $
    ioError (userError "Lien Windows absolu: utiliser --follow-symlinks pour inclure son contenu")
#if defined(mingw32_HOST_OS)
  absolute <- W.normalise <$> D.makeAbsolute path
  let extended = if "\\\\?\\" `isPrefixOf` absolute then absolute
        else if "\\\\" `isPrefixOf` absolute then "\\\\?\\UNC\\" ++ drop 2 absolute
        else "\\\\?\\" ++ absolute
  attributes <- withArray0 0 (windowsUTF16 extended) directoryAttribute
  when (attributes < 0) (ioError (userError "Impossible de lire le type du lien Windows"))
  let directory = attributes /= 0
  targetDirectory <- D.doesDirectoryExist (N.takeDirectory path N.</> target)
  when (not directory && targetDirectory) $
    ioError (userError "Lien Windows de type fichier visant un dossier: non representable dans BH12")
#else
  directory <- D.doesDirectoryExist path
#endif
  let archived = toArchivePath target
  -- BH12 has no separate link-kind field. A trailing slash carries the native
  -- directory-link semantics, including dangling directory links, across hosts.
  return (if directory && not (null archived) && last archived /= '/' then archived ++ "/" else archived)
#endif

createArchiveLink :: Bool -> FilePath -> FilePath -> IO ()
#if !defined(mingw32_HOST_OS) && !defined(BLACKHOLE_WINDOWS_TEST)
createArchiveLink _ = P.createSymbolicLink
#else
createArchiveLink directory target destination =
  (if directory then D.createDirectoryLink else D.createFileLink) (fromArchivePath target) destination
#endif
