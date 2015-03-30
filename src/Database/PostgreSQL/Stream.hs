{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoMonomorphismRestriction #-}

module Database.PostgreSQL.Stream (
  query,
  query_,

  execute,
  execute_,

  stream,
  stream_,

  PoolSettings(..),
  pgPool,
  withPgConnection,
  PQ.Connection,

  ConnSettings(..),
  connect,
  connect_alt,

  sql,

  fmtSQL,
  fmtQuery,

  module Database.PostgreSQL.Stream.Types
) where

import Database.PostgreSQL.Stream.Types
import Database.PostgreSQL.Stream.FromRow
import Database.PostgreSQL.Stream.QueryBuilder
import Database.PostgreSQL.Stream.Connection

import qualified PostgreSQLBinary.Decoder as PD
import qualified Database.PostgreSQL.LibPQ as PQ

import Data.Int
import Data.Text
import Data.Pool
import Data.Monoid
import Data.ByteString (ByteString)
import Data.ByteString.Char8 as B8
import qualified Data.Vector.Storable as V
import Data.UUID.V4(nextRandom)
import Data.UUID(toASCIIBytes, toWords)

import Control.Exception as E
import Control.Monad.Trans
import Control.Applicative
import Control.Monad.Trans.Resource (ResourceT)

import qualified Data.Conduit as C
import qualified Data.Conduit.List as CL

-------------------------------------------------------------------------------
-- Query
-------------------------------------------------------------------------------

-- Execute SQL query with arguments.
query :: (FromRow r, ToSQL q) => PQ.Connection -> Query -> q -> IO [r]
query conn q args = do
  -- Formatted query
  let query = fmtQuery q args
  -- Execute the query
  result <- PQ.execParams conn query [] PQ.Binary
  case result of
    Nothing -> throw (QueryError "Query execution error." q)
    Just rows -> parseRows q rows

-- Execute SQL query without arguments.
query_ :: (FromRow r) => PQ.Connection -> Query -> IO [r]
query_ conn q = do
  -- Execute the query
  result <- PQ.execParams conn (fromQuery q) [] PQ.Binary
  case result of
    Nothing -> throw (QueryError "Query execution error." q)
    Just rows -> parseRows q rows

-------------------------------------------------------------------------------
-- Execute
-------------------------------------------------------------------------------

execute :: (ToSQL q) => PQ.Connection -> Query -> q -> IO ()
execute conn q args = do
  -- Formatted query
  let query = fmtQuery q args
  -- Execute the query
  result <- PQ.execParams conn query [] PQ.Binary
  case result of
    Nothing -> throw (QueryError "Query execution error." q)
    Just rc -> return ()

execute_ :: PQ.Connection -> Query -> IO ()
execute_ conn q = do
  -- Execute the query
  result <- PQ.execParams conn (fromQuery q) [] PQ.Binary
  case result of
    Nothing -> throw (QueryError "Query execution error." q)
    Just rc -> return ()

-------------------------------------------------------------------------------
-- Transaction
-------------------------------------------------------------------------------

data IsolationLevel
   = DefaultIsolationLevel
   | ReadCommitted
   | RepeatableRead
   | Serializable
   deriving (Show, Eq, Ord, Enum, Bounded)

data ReadWriteMode
   = DefaultReadWriteMode
   | ReadWrite
   | ReadOnly
   deriving (Show, Eq, Ord, Enum, Bounded)

data TransactionMode = TransactionMode
  { isolationLevel :: !IsolationLevel
  , readWriteMode  :: !ReadWriteMode
  } deriving (Show, Eq)

beginMode :: TransactionMode -> PQ.Connection -> IO ()
beginMode mode conn = do
  let begin_query = (Query (mconcat ["BEGIN", isolevel, readmode, ";"]))
  rc <- execute_ conn begin_query
  return ()

  where
    isolevel =
      case isolationLevel mode of
        DefaultIsolationLevel -> ""
        ReadCommitted  -> " ISOLATION LEVEL READ COMMITTED"
        RepeatableRead -> " ISOLATION LEVEL REPEATABLE READ"
        Serializable   -> " ISOLATION LEVEL SERIALIZABLE"
    readmode =
      case readWriteMode mode of
        DefaultReadWriteMode -> ""
        ReadWrite -> " READ WRITE"
        ReadOnly  -> " READ ONLY"

defaultTransactionMode :: TransactionMode
defaultTransactionMode =  TransactionMode
                            defaultIsolationLevel
                            defaultReadWriteMode

defaultIsolationLevel  :: IsolationLevel
defaultIsolationLevel  =  DefaultIsolationLevel

defaultReadWriteMode   :: ReadWriteMode
defaultReadWriteMode   =  DefaultReadWriteMode

-- | Rollback a transaction.
rollback :: PQ.Connection -> IO ()
rollback conn = execute_ conn "ABORT" >> return ()

-- | Commit a transaction.
commit :: PQ.Connection -> IO ()
commit conn = execute_ conn "COMMIT" >> return ()

-- | Begin a transaction.
begin :: PQ.Connection -> IO ()
begin = beginMode defaultTransactionMode

withTransactionMode :: TransactionMode -> PQ.Connection -> IO a -> IO a
withTransactionMode mode conn act =
  mask $ \restore -> do
    beginMode mode conn
    r <- restore act `E.onException` rollback conn
    commit conn
    return r

-------------------------------------------------------------------------------
-- Streaming Queries
-------------------------------------------------------------------------------

newCursor :: IO (Identifier)
newCursor = do
  uid <- nextRandom
  let (a,b,c,d) = toWords uid
  let bshow = B8.pack . show
  return $ Identifier ("cursor" <> bshow a <> bshow b <> bshow c <> bshow d)

stream :: (FromRow r, ToSQL a) =>
     PQ.Connection                    -- ^ Connection
  -> Query                            -- ^ Query
  -> a                                -- ^ Query arguments
  -> Int                              -- ^ Batch size
  -> C.Source (ResourceT IO) [r]      -- ^ Source conduit
stream conn q args n = do
  -- Generate a new cursor from a uuid
  cursor_name <- liftIO $ newCursor
  liftIO $ beginMode defaultTransactionMode conn

  let subsql = fmtQuery q args
  let cursor_query = Query (mconcat [ "DECLARE {1} NO SCROLL CURSOR FOR ", subsql ])

  -- Execute the cursor setup
  liftIO $ execute conn cursor_query (Only cursor_name)

  let fetch_cursor = [sql|FETCH FORWARD {1} FROM {2};|]

  {-liftIO $ putStrLn $ fmtQuery fetch_cursor (n, cursor_name)-}
  loop conn fetch_cursor cursor_name n
  liftIO $ commit conn

  where
   loop conn q cursor_name n = do
      res <- liftIO $ query conn q (n, cursor_name)
      case res of
        [] -> return ()
        _  -> C.yield res >> loop conn q cursor_name n

stream_ :: (FromRow r) => PQ.Connection -> Query -> Int -> C.Source (ResourceT IO) [r]
stream_ conn q n = stream conn q () n
