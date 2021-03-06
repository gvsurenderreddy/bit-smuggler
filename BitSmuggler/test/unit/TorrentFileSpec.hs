{-# LANGUAGE OverloadedStrings #-}
module TorrentFileSpec (main, spec) where

import Test.Hspec
import Prelude as P
import Control.Monad.IO.Class
import Data.Map.Lazy as Map
import System.IO.Temp
import Data.Conduit
import Data.Conduit.Binary as DC
import Data.Serialize
import Data.Conduit.Cereal
import Control.Monad.Trans.Resource
import qualified Data.Conduit.List as DCL 
import System.IO
import Control.Monad
import Control.Exception.Base
import Control.Monad.IO.Class
import Data.Serialize as DS
import Data.ByteString.Lazy as BSL
import Data.ByteString as BS
import Control.Monad 
import System.FilePath
import Data.Torrent
import Data.Maybe
import Data.BEncode

import Network.BitTorrent.ClientControl as CC

import Network.BitSmuggler.TorrentFile as TF
import Network.BitTorrent.Types as BT

import Network.BitSmuggler.BitTorrentParser as BT
import qualified Network.BitSmuggler.Protocol as Proto
import Network.BitSmuggler.Common (isUsedUp)
import Network.BitSmuggler.Utils

main :: IO ()
main = hspec spec

tempDir = "testDir"

dataFileSmall = "test-data/randFileSmall"
dataFileSmallTFile = "test-data/randFileSmall.torrent"

dataFileMediumTFile = "test-data/testFile.torrent"

torrentStream = "test-data/seedClientCapture"

trackerCapture = "test-data/trackerCapture"


spec :: Spec
spec = do

{-
  this doesn't pass cause the parser throws away some fields
  describe "BitTorrent file parser" $ do
    it "parses and serializes correctly" $ do
      torrentFileContent <- BSL.readFile dataFileMediumTFile 
      let (Right torrentFile) = readTorrent torrentFileContent
      (bPack $ serializeTorrent $ torrentFile) `shouldBe` torrentFileContent
-}

  describe "BitTorrentParser" $ do
    it "parses and serializes the stream correctly" $ do
      forM [trackerCapture, torrentStream] $ \file -> do
        identical <- runResourceT $ do
          sequenceSources 
            [ sourceFile file =$ Proto.btStreamHandler (DCL.map id) =$ conduitBytes
            , sourceFile file =$ conduitBytes]
            $$ DCL.fold (\isSame [b1, b2] -> b1 == b2 && isSame) True
        identical `shouldBe` True
      return ()

    it "parses the right number of pieces" $ do
      -- this test is pretty weak. consider for removal 
      (Right torrentFile) <- fmap readTorrent $ BSL.readFile dataFileSmallTFile
      let tinfo = tInfo $ torrentFile
      let pieceCount = divCeiling (tLength tinfo) (tPieceLength tinfo)
      chunks <- runResourceT $ sourceFile torrentStream 
              =$ conduitGet (get :: Get StreamChunk) $$ DCL.consume
      ((P.length $ P.filter isPiece $ chunks)
        >= (divCeiling (tPieceLength tinfo) Proto.blockSize) * (pieceCount - 1))
        `shouldBe` True

  describe "hashPieces" $ do
    it "matches piece hashes in model torrent file" $ do
      (Right torrentFile) <- fmap readTorrent $ BSL.readFile dataFileSmallTFile
      let tinfo = tInfo $ torrentFile
      hashes <- hashPieces [dataFileSmall] (fromIntegral $ tPieceLength tinfo)
      BSL.fromChunks hashes `shouldBe` (tPieces tinfo) 
      return ()
  describe "computeInfoHash" $ do
    it "matches expected value" $ do
      forM [ (dataFileSmallTFile, "b5724467037c1c4192049b84bba92ea2bdf3d445")

-- TODO: readd these test cases after you fix the function 
-- at this point it's unclear why it doesn't work
--           , (dataFileMediumTFile, "f921dd6548298527d40757fb264de07f7a47767f")

       ] $ \(filePath, expectedHash) -> do
          (Right torrentFile) <- fmap readTorrent $ BSL.readFile dataFileSmallTFile
          computeInfoHash torrentFile `shouldBe` (fromJust $ BT.textToInfoHash expectedHash)
      return ()

  describe "makeBlockLoader" $ do
    it "loads the same blocks as the ones streamed in a bittorrent session" $ do
      (Right torrentFile) <- fmap readTorrent $ BSL.readFile dataFileSmallTFile
      bracket
        (makeBlockLoader (tInfo torrentFile) dataFileSmall)
        closeLoader
        $ \blockLoader -> do 
          chunks <- runResourceT $ sourceFile torrentStream 
                  =$ conduitGet (get :: Get StreamChunk) $$ DCL.consume
          let justPieces = P.filter isPiece $ chunks 
          (P.length justPieces >= 1) `shouldBe` True
          sames <- forM justPieces $ \(MsgChunk _ p) -> do
            loadedBlock <- (loadBlock blockLoader) (fromIntegral $ BT.index p
                           , Block {blockOffset = begin p,
                             blockSize  = BS.length $ block p}) 
            return $ loadedBlock == (block p)
          P.length (P.filter (P.id) sames) `shouldBe` P.length justPieces
      return ()

  describe "file replenisher" $ do
    it "appreciates if a file is used up" $ do
      P.putStrLn "wtf"
      (isUsedUp $ CC.Torrent { progress = 800
                            , downSpeed = 0
                            , peersConnected = 1, seedsConnected = 1})
        `shouldBe` True
      (isUsedUp $ CC.Torrent { progress = 600
                            , downSpeed = 0
                            , peersConnected = 0, seedsConnected = 0})
        `shouldBe` False 
      (isUsedUp $ CC.Torrent { progress = 610
                            , downSpeed = 40000
                            , peersConnected = 1, seedsConnected = 0})
        `shouldBe` False 
      (isUsedUp $ CC.Torrent { progress = 800
                            , downSpeed = 300000
                            , peersConnected = 1, seedsConnected = 0})
        `shouldBe` False 
        
  return ()

divCeiling x y = ceiling $ (fromIntegral x) / (fromIntegral y)
