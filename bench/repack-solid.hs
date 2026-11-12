-- Compile with -O2; see CHANGELOG-MAX.md. No files are omitted.
import BlackHole.Archive
import BlackHole.Engine
import qualified Data.ByteString as BS
import Data.List (sortOn)
import Data.Word (Word32)
import System.Environment (getArgs)
import System.FilePath (takeFileName,takeExtension)
import Control.Monad (forM)
import Text.Read (readMaybe)

type File = (FilePath, Word32, BS.ByteString)
main :: IO ()
main = do
  args <- getArgs
  case args of
    [input,output,quality] | Just level <- readMaybe quality, level >= 1 && level <= 22 -> do
      loaded <- loadArchive input
      original <- either (ioError . userError) return loaded
      either (ioError . userError) return (verifyArchive original)
      case original of
        Archive entries -> do
          collected <- mapM collect entries
          let files = concat [fs | (fs,_) <- collected]
              others = concat [es | (_,es) <- collected]
              ordered = sortOn similarityKey files
              groups = groupFiles ordered
          rebuilt <- forM groups $ \group -> do
            let bytes = BS.concat [content | (_,_,content) <- group]
            blocks <- compressSolidBytesWith Auto level bytes
            return (SolidEntry [(p,n) | (p,n,_) <- group] blocks)
          let candidate = Archive (rebuilt ++ others)
          either (ioError . userError) return (verifyArchive candidate)
          before <- archiveWireSize original
          after <- archiveWireSize candidate
          let winner = if after < before then candidate else original
          saveArchive output winner
          putStrLn ("Original serialized bytes: " ++ show before)
          putStrLn ("Candidate serialized bytes: " ++ show after)
          putStrLn ("Saved serialized bytes: " ++ show (min before after))
          putStrLn "Archive verifies; no file omitted"
        _ -> ioError (userError "This diagnostic accepts solid archives, not chunk archives")
    _ -> ioError (userError "Usage: repack-solid INPUT.bh OUTPUT.bh LEVEL(1..22)")

collect :: Entry -> IO ([File],[Entry])
collect entry@(FileEntry path blocks)
  | sum (map (toInteger . rawSize) blocks) > 67108864 = return ([],[entry])
  | otherwise = do
      content <- either (ioError . userError) return (decompressBytes blocks)
      return ([(path,fromIntegral (BS.length content),content)],[])
collect (SolidEntry files blocks) = do
  content <- either (ioError . userError) return (decompressBytes blocks)
  return (splitFiles content files,[])
collect entry = return ([],[entry])

splitFiles :: BS.ByteString -> [(FilePath,Word32)] -> [File]
splitFiles _ [] = []
splitFiles content ((path,n):rest) =
  let (first,next) = BS.splitAt (fromIntegral n) content
  in (path,n,first):splitFiles next rest

similarityKey :: File -> (String,String,String,FilePath)
similarityKey (path,_,_) =
  let name=takeFileName path
      ext=takeExtension name
      bucket=if name `elem` ["package.json","package-lock.json","index.js","index.d.ts",
                            "tsconfig.json","README.md","Cargo.toml","Cargo.lock"]
             then name else ext
  in (bucket,ext,name,path)

groupFiles :: [File] -> [[File]]
groupFiles = go [] 0
  where
    go acc _ [] = [reverse acc | not (null acc)]
    go acc size allFiles@(file@(_,n,_):rest)
      | not (null acc) && size + toInteger n > 67108864 = reverse acc:go [] 0 allFiles
      | otherwise = go (file:acc) (size+toInteger n) rest
