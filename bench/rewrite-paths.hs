module Main where
import BlackHole.Archive
import qualified Data.Binary as Bin
import qualified Data.ByteString.Lazy as BL
import System.Environment (getArgs)
main :: IO ()
main = do
  [source,destination] <- getArgs
  Right archive <- loadArchive source
  old <- BL.readFile source
  saveArchive destination archive
  new <- BL.readFile destination
  Right recovered <- loadArchive destination
  if Bin.encode recovered /= Bin.encode archive then fail "Archive changee" else pure ()
  putStrLn ("old bytes=" ++ show (BL.length old) ++ " new bytes=" ++ show (BL.length new))
  putStrLn ("header=" ++ show (BL.take 4 new))
  putStrLn ("relative skeleton bytes=" ++ show (fmap BL.length (encodePathSkeleton archive)))
