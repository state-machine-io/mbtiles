{-|
Module      : Database.Mbtiles
Description : Haskell MBTiles client.
Copyright   : (c) Joe Canero, 2017
License     : BSD3
Maintainer  : jmc41493@gmail.com
Stability   : experimental
Portability : POSIX

This module provides support for reading, writing, and updating
an mbtiles database, as well as reading
metadata from the database.

There is also support for creating a pool of connections to
an mbtiles database and streaming tiles.

See the associated README.md for basic usage examples.
-}

{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}

module Database.Mbtiles
(
  -- * Types
  MbtilesT
, MbtilesIO
, MbtilesMeta
, MBTilesError(..)
, Z(..)
, X(..)
, Y(..)
, Tile(..)
, DataTile(..)

  -- * Typeclasses
, ToTile(..)
, FromTile(..)

  -- * The MbtilesT monad transformer
, runMbtilesT
, runMbtiles

  -- ** Pooling
, MbtilesPool
, getMbtilesPool
, runMbtilesPoolT

  -- * Mbtiles read/write functionality
, getTile
, writeTile
, writeTiles
, updateTile
, updateTiles

  -- * Mbtiles metadata functionality
, getMetadata
, getName
, getType
, getVersion
, getDescription
, getFormat

  -- * Streaming tiles
, TileStream
, startTileStream
, endTileStream
, nextTile
) where

import           Control.Monad
import           Control.Monad.IO.Class
import           Control.Monad.Reader
import           Control.Monad.Trans.Control
import qualified Data.ByteString.Lazy        as BL
import           Data.HashMap.Strict         ((!))
import qualified Data.HashMap.Strict         as M hiding ((!))
import           Data.Monoid
import           Data.Pool
import           Data.Text                   (Text)
import           Data.Tile
import           Database.Mbtiles.Query
import           Database.Mbtiles.Types
import           Database.Mbtiles.Utility
import           Database.SQLite.Simple
import           System.Directory

-- | Given a path to an MBTiles file, run the 'MbtilesT' action.
-- This will open a connection to the MBTiles file, run the action,
-- and then close the connection.
-- Some validation will be performed first. Of course, we will check if the
-- MBTiles file actually exists. If it does, we need to validate its schema according
-- to the MBTiles spec.
runMbtilesT :: (MonadIO m) => FilePath -> MbtilesT m a -> m (Either MBTilesError a)
runMbtilesT mbtilesPath mbt = do
  m <- validateMBTiles mbtilesPath
  either (return . Left) processMbt m
  where
    processMbt (c, d) = do
      m <- mkMbtilesData c d
      v <- runReaderT (unMbtilesT mbt) m
      closeAll m
      return $ Right v

-- | A pool of connections to an MBTiles database.
type MbtilesPool = Pool MbtilesData

-- | Given a path to an MBTiles file, create a connection pool
-- to an MBTiles database. This will perform the same validation as 'runMbtilesT'.
getMbtilesPool :: (MonadIO m) => FilePath -> m (Either MBTilesError MbtilesPool)
getMbtilesPool fp = do
  m <- validateMBTiles fp
  either (return . Left) (fmap Right . liftIO . buildPool) m
  where
    buildPool (_, d) =
      createPool (openConnection d) closeAll 1 900 1000
    openConnection d = open fp >>= flip mkMbtilesData d

-- | Given access to an 'MbtilesPool', run an action against that pool.
runMbtilesPoolT :: (MonadBaseControl IO m) => MbtilesPool -> MbtilesT m a -> m a
runMbtilesPoolT p mbt = control $ \runInIO -> 
  withResource p $ \resource -> runInIO $ runReaderT (unMbtilesT mbt) resource

type ValidationResult = (Connection, MbtilesMeta)

closeAll :: (MonadIO m) => MbtilesData -> m ()
closeAll MbtilesData{r = rs, conn = c} =
      closeStmt rs >> closeConn c

mkMbtilesData :: (MonadIO m) => Connection -> MbtilesMeta -> m MbtilesData
mkMbtilesData c d =
      MbtilesData <$>
        openStmt c getTileQuery <*>
        pure c                  <*>
        pure d

validateMBTiles :: (MonadIO m) => FilePath -> m (Either MBTilesError ValidationResult)
validateMBTiles mbtilesPath = liftIO $
  doesFileExist mbtilesPath >>=
  ifExistsOpen              >>=
  validator schema          >>=
  validator metadata        >>=
  validator tiles           >>=
  validator metadataValues
  where
    ifExistsOpen False = return $ Left DoesNotExist
    ifExistsOpen True  = Right <$> open mbtilesPath

    schema c = do
      valid <- mconcat $ map (fmap All) [doesTableExist c tilesTable, doesTableExist c metadataTable]
      if getAll valid then return $ Right c else return $ Left InvalidSchema

    metadata = columnChecker metadataTable metadataColumns InvalidMetadata
    tiles = columnChecker tilesTable tilesColumns InvalidTiles
    metadataValues c = do
      m <- getDBMetadata c
      if all (`M.member` m) requiredMeta
        then return $ Right (c, m)
        else return $ Left InvalidMetadata

-- | Specialized version of 'runMbtilesT' to run in the IO monad.
runMbtiles :: FilePath -> MbtilesIO a -> IO (Either MBTilesError a)
runMbtiles = runMbtilesT

-- | Given a 'Tile`, return the corresponding tile data, if it exists.
getTile :: (MonadIO m, FromTile a) => Tile -> MbtilesT m (Maybe a)
getTile t@(Tile (Z z, X x, Y y)) = MbtilesT $ do
  rs <- r <$> ask
  fmap unwrapTile <$> liftIO (do
    bindNamed rs [":zoom" := z, ":col" := x, ":row" := y']
    res <- nextRow rs
    reset rs
    return res)
  where unwrapTile (Only bs) = fromTile bs
        Tile (_, _, Y y') = flipY t

-- | Create a 'TileStream' data type that will be used to stream tiles
-- from the MBTiles database. When streaming is complete, you must
-- call 'endTileStream' to clean up the 'TileStream' resource. Tiles are streamed
-- from the database in an ordered fashion, where they are sorted by zoom level,
-- then tile column, then tile row, in ascending order.
startTileStream :: (MonadIO m) => MbtilesT m TileStream
startTileStream = MbtilesT $ asks conn >>= liftIO . openTileStream

-- | Close a given 'TileStream' when streaming is complete.
endTileStream :: (MonadIO m) => TileStream -> MbtilesT m ()
endTileStream = liftIO . closeTileStream

-- | Reset a 'TileStream' and prepare it to return results via 'nextTile' again.
resetTileStream :: (MonadIO m) => TileStream -> MbtilesT m ()
resetTileStream (TileStream ts) = liftIO $ reset ts

-- | Receive the next 'Tile' from the 'TileStream'.
nextTile :: (MonadIO m, FromTile a) => TileStream -> MbtilesT m (Maybe (DataTile a))
nextTile (TileStream ts) = liftIO $ nextRow ts

-- | Returns the 'MbtilesMeta' that was found in the MBTiles file.
-- This returns all of the currently available metadata for the MBTiles database.
getMetadata :: (MonadIO m) => MbtilesT m MbtilesMeta
getMetadata = MbtilesT $ reader meta

-- | Helper function for getting the specified name of the MBTiles from metadata.
getName :: (MonadIO m) => MbtilesT m Text
getName = findMeta "name" <$> getMetadata

-- | Helper function for getting the type of the MBTiles from metadata.
getType :: (MonadIO m) => MbtilesT m Text
getType = findMeta "type" <$> getMetadata

-- | Helper function for getting the version of the MBTiles from metadata.
getVersion :: (MonadIO m) => MbtilesT m Text
getVersion = findMeta "version" <$> getMetadata

-- | Helper function for getting the description of the MBTiles from metadata.
getDescription :: (MonadIO m) => MbtilesT m Text
getDescription = findMeta "description" <$> getMetadata

-- | Helper function for getting the format of the MBTiles from metadata.
getFormat :: (MonadIO m) => MbtilesT m Text
getFormat = findMeta "format" <$> getMetadata

-- | Write new tile data to the tile at the specified 'Z', 'X', and 'Y' parameters.
-- This function assumes that the tile does not already exist.
writeTile :: (MonadIO m, ToTile a) => DataTile a -> MbtilesT m ()
writeTile d = writeTiles [d]

-- | Batch write new tile data to the tile at the specified 'Z', 'X', and 'Y' parameters.
-- This function assumes that the tiles do not already exist.
writeTiles :: (MonadIO m, ToTile a) => [DataTile a] -> MbtilesT m ()
writeTiles = execQueryOnTiles newTileQuery

-- | Update existing tile data for the tile at the specified 'Z', 'X', and 'Y' parameters.
-- This function assumes that the tile does already exist.
updateTile :: (MonadIO m, ToTile a) => DataTile a -> MbtilesT m ()
updateTile d = updateTiles [d]

-- | Batch update tile data for the tiles at the specified 'Z', 'X', and 'Y' parameters.
-- This function assumes that the tiles do already exist.
updateTiles :: (MonadIO m, ToTile a) => [DataTile a] -> MbtilesT m ()
updateTiles = execQueryOnTiles updateTileQuery

-- execute a query on an array of tile coordinates.
-- need to wrap the Y coordinate, since mbtiles are in TMS.
execQueryOnTiles :: (MonadIO m, ToTile a) => Query -> [DataTile a] -> MbtilesT m ()
execQueryOnTiles q ts = MbtilesT $ do
  c <- conn <$> ask
  liftIO $
    executeMany c q $ map mkRow ts
  where
    mkRow (DataTile t d) = let Tile (z, x, y) = flipY t in (toTile d, z, x, y)

findMeta :: Text -> MbtilesMeta -> Text
findMeta t m = m ! t
