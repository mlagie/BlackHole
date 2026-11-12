{-# LANGUAGE BangPatterns #-}
module BlackHole.Diagnostics
  ( traceEvent
  , traceSpanStart
  , traceSpanEnd
  ) where

import Control.Concurrent.MVar (MVar, newMVar, modifyMVar_)
import Data.Char (isSpace)
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import System.Environment (lookupEnv)
import System.IO (hFlush, hPutStrLn, stderr)
import System.IO.Unsafe (unsafePerformIO)

traceLock :: MVar ()
traceLock = unsafePerformIO (newMVar ())
{-# NOINLINE traceLock #-}

traceEvent :: String -> [(String, String)] -> IO ()
traceEvent event fields = do
  enabled <- lookupEnv "BLACKHOLE_TRACE"
  case enabled of
    Nothing -> return ()
    Just "" -> return ()
    Just "0" -> return ()
    Just _ -> do
      timestamp <- getMonotonicTimeNSec
      modifyMVar_ traceLock $ \() -> do
        hPutTrace (show timestamp ++ "\t" ++ event ++
          concatMap (\(key, value) -> "\t" ++ key ++ "=" ++ clean value) fields)
        return ()
  where
    clean = map (\character -> if isSpace character then '_' else character)
    hPutTrace line = do
      hPutStrLn stderr line
      hFlush stderr

traceSpanStart :: String -> [(String, String)] -> IO Word64
traceSpanStart name fields = do
  started <- getMonotonicTimeNSec
  traceEvent (name ++ "_start") fields
  return started

traceSpanEnd :: String -> Word64 -> [(String, String)] -> IO ()
traceSpanEnd name started fields = do
  finished <- getMonotonicTimeNSec
  traceEvent (name ++ "_end")
    (("duration_ns", show (finished - started)) : fields)
