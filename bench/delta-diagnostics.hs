-- Compile with -O2 for corpus diagnostics; see README.md.
-- Usage: delta-diagnostics SOURCE_DIRECTORY SOLID_ARCHIVE.bh
-- SOURCE_DIRECTORY must be the unchanged source of SOLID_ARCHIVE.bh.
import BlackHole.Archive
import BlackHole.Engine (Codec(..))
import qualified Data.Set as Set
import Data.List (sort)
import System.Environment (getArgs)
import System.Directory (listDirectory, doesDirectoryExist, pathIsSymbolicLink)
import System.FilePath ((</>), takeFileName, dropTrailingPathSeparator)

main :: IO ()
main = do
  args <- getArgs
  case args of
    [source, archivePath] -> do
      loaded <- loadArchive archivePath
      archive <- either (ioError . userError) return loaded
      case archive of
        Archive entries -> do
          let originals = Set.fromList (concatMap originalNames entries)
          paths <- gather source (takeFileName (dropTrailingPathSeparator source))
          let files = filter (\(p, _) -> Set.member p originals) paths
          size <- archiveWireSize archive
          putStrLn ("Solid serialized bytes: " ++ show size)
          candidate <- buildDeltaSolidArchive Auto 15 files archive
          case candidate of
            Nothing -> putStrLn "No DELTA passed the local filter within the budgets"
            Just hybrid@(Archive es) -> do
              hybridSize <- archiveWireSize hybrid
              putStrLn ("Hybrid serialized bytes: " ++ show hybridSize)
              putStrLn ("DELTA entries: " ++ show (length [() | DeltaEntry{} <- es]))
              putStrLn ("Difference hybrid - solid: " ++ show (hybridSize-size))
              putStrLn ("Hybrid verifies: " ++ show (verifyArchive hybrid == Right ()))
            _ -> ioError (userError "Unexpected hybrid representation")
        _ -> ioError (userError "Use a solid Archive, not a ChunkArchive")
    _ -> ioError (userError "Usage: delta-diagnostics.hs SOURCE_DIRECTORY SOLID_ARCHIVE.bh")
  where
    originalNames (FileEntry p _) = [p]
    originalNames (SolidEntry fs _) = map fst fs
    originalNames _ = []
    gather full relative = do
      link <- pathIsSymbolicLink full
      if link then return [] else do
        directory <- doesDirectoryExist full
        if not directory then return [(relative, full)] else do
          names <- sort <$> listDirectory full
          concat <$> mapM (\name -> gather (full </> name) (relative </> name)) names
