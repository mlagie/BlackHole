{-# LANGUAGE NoRebindableSyntax #-}
{-# OPTIONS_GHC -fno-warn-missing-import-lists #-}
{-# OPTIONS_GHC -w #-}
module PackageInfo_blackhole (
    name,
    version,
    synopsis,
    copyright,
    homepage,
  ) where

import Data.Version (Version(..))
import Prelude

name :: String
name = "blackhole"
version :: Version
version = Version [0,12,5,0] []

synopsis :: String
synopsis = "Archiveur hybride Zstandard et mathematique sans perte"
copyright :: String
copyright = ""
homepage :: String
homepage = ""
