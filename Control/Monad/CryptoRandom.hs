{-# LANGUAGE FlexibleInstances, TypeSynonymInstances, FlexibleContexts
  , GeneralizedNewtypeDeriving, MultiParamTypeClasses #-}
{-|
  Maintainer: Thomas.DuBuisson@gmail.com
  Stability: beta
  Portability: portable 

Much like the "MonadRandom" package ("Control.Monad.Random"), this module
provides plumbing for the CryptoRandomGen generators.

-}
 
module Control.Monad.CryptoRandom
        ( CRandom(..)
        , CRandomR(..)
        , MonadCRandom(..)
        , MonadCRandomR(..)
        , ContainsGenError(..)
        , CRandT
        , CRand
        , runCRandT
        , evalCRandT
        , runCRand
        , evalCRand
        , newGenCRand
        , module Crypto.Random
        ) where

import Control.Applicative
import Control.Arrow (right, left)
import Control.Monad (liftM)
import Control.Monad.Error
import Control.Monad.IO.Class
import Control.Monad.Identity
import Control.Monad.State
import Crypto.Random (CryptoRandomGen(..), GenError(..))
import Data.Bits (xor, setBit, shiftR, shiftL, (.&.))
import Data.Int
import Data.List (foldl')
import Data.Word
import Data.Proxy
import qualified Data.ByteString as B

-- |@MonadCRandom m@ represents a monad that can produce
-- random values (or fail with a 'GenError').  It is suggested
-- you use the 'CRandT' transformer in your monad stack.
class (ContainsGenError e, MonadError e m) => MonadCRandom e m where
        getCRandom   :: CRandom a => m a
        getBytes     :: Int -> m B.ByteString
        getBytesWithEntropy :: Int -> B.ByteString -> m B.ByteString
        doReseed :: B.ByteString -> m ()

newGenCRand :: (CryptoRandomGen g, MonadCRandom GenError m, Functor m) => m g
newGenCRand = go 0
  where
  go 1000 = throwError (GenErrorOther "The generator instance requested by newGenCRand never instantiates.")
  go i = do let p = Proxy
                getTypedGen :: (Functor m, CryptoRandomGen g, MonadCRandom GenError m)
                            => Proxy g -> m (Either GenError g)
                getTypedGen pr = fmap newGen (getBytes $ proxy genSeedLength pr)
            res <- getTypedGen p 
            case res of
                Left _  -> go (i+1)
                Right g -> return (g `asProxyTypeOf` p)

class (ContainsGenError e, MonadError e m) => MonadCRandomR e m where
        getCRandomR  :: CRandomR a => (a,a) -> m a

class ContainsGenError e where
        toGenError :: e -> Maybe GenError
        fromGenError :: GenError -> e

instance ContainsGenError GenError where
        toGenError = Just
        fromGenError = id

-- |@CRandom a@ is much like the 'Random' class from the "System.Random" module in the "random" package.
-- The main difference is CRandom builds on "crypto-api"'s 'CryptoRandomGen', so it allows
-- explicit failure.
--
-- @crandomR (low,high) g@ as typically instantiated will generate a value between
-- [low, high] inclusively, swapping the pair if high < low.
--
-- Provided instances for @crandom g@ generates randoms between the bounds and between +/- 2^256
-- for Integer.
-- 
-- The 'crandomR' function has degraded (theoretically unbounded, probabilistically decent) performance
-- the closer your range size (high - low) is to 2^n (from the top).
class CRandom a where
    crandom   :: (CryptoRandomGen g) => g -> Either GenError (a, g)
    crandoms  :: (CryptoRandomGen g) => g -> [a]
    crandoms g =
        case crandom g of
                Left _       -> []
                Right (a,g') -> a : crandoms g'

class CRandomR a where
    crandomR  :: (CryptoRandomGen g) => (a, a) -> g -> Either GenError (a, g)
    crandomRs :: (CryptoRandomGen g) => (a, a) -> g -> [a]
    crandomRs r g =
        case crandomR r g of
                Left _       -> []
                Right (a,g') -> a : crandomRs r g'

instance CRandomR Integer where
   crandomR = crandomR_Num

instance CRandom Int where
    crandom = crandomR (minBound, maxBound)

instance CRandomR Int where
    crandomR = crandomR_Num

instance CRandom Word8 where
    crandom = crandomR (minBound, maxBound)

instance CRandomR Word8 where
    crandomR = crandomR_Num

instance CRandom Word16 where
    crandom = crandomR (minBound, maxBound)

instance CRandomR Word16 where
    crandomR = crandomR_Num

instance CRandom Word32 where
    crandom = crandomR (minBound, maxBound)

instance CRandomR Word32 where
    crandomR = crandomR_Num

instance CRandom Word64 where
    crandom = crandomR (minBound, maxBound)

instance CRandomR Word64 where
    crandomR = crandomR_Num

instance CRandom Int8 where
    crandom = crandomR (minBound, maxBound)

instance CRandomR Int8 where
    crandomR = crandomR_Num

instance CRandom Int16 where
    crandom = crandomR (minBound, maxBound)

instance CRandomR Int16 where
    crandomR = crandomR_Num

instance CRandom Int32 where
    crandom = crandomR (minBound, maxBound)

instance CRandomR Int32 where
    crandomR = crandomR_Num

instance CRandom Int64 where
    crandom = crandomR (minBound, maxBound)
instance CRandomR Int64 where
    crandomR = crandomR_Num

crandomR_Num :: (Integral a, CryptoRandomGen g) => (a,a) -> g -> Either GenError (a,g)
crandomR_Num (low, high) g
      | high < low = crandomR_Num  (high,low) g
      | high == low = Right (high, g)
      | otherwise = go g
      where
      mask    = foldl' setBit 0 [0 .. fromIntegral nrBits - 1]
      nrBits  = base2Log range
      range :: Integer
      range   = (fromIntegral high) - (fromIntegral low) + 1
      nrBytes = (nrBits + 7) `div` 8
      go gen =
        let offset = genBytes (fromIntegral nrBytes) gen
        in case offset of
        Left err -> Left err
        Right (bs, g') ->
                let res = fromIntegral low + (bs2i bs .&. mask)
                in if res > fromIntegral high then go g' else Right (fromIntegral res, g')
{-# INLINE crandomR_Num #-}

wrap :: (Monad m, ContainsGenError e, Error e) => (g -> Either GenError (a,g)) -> CRandT g e m a
wrap f = CRandT $ do
        g <- get
        case f g of
                Right (a,g') -> put g' >> return a
                Left x -> throwError (fromGenError x)

-- |CRandT is the transformer suggested for MonadCRandom.
newtype CRandT g e m a = CRandT { unCRandT :: StateT g (ErrorT e m) a } deriving (MonadError e, Monad, MonadIO, Functor, MonadFix)

instance (Functor m,Monad m,Error e) => Applicative (CRandT g e m) where
  pure = return
  (<*>) = ap

instance (Error e) => MonadTrans (CRandT g e) where
        lift = CRandT . lift . lift

-- |Simple users of generators can use CRand for
-- quick and easy generation of randoms.  See
-- below for a simple use of 'newGenIO' (from "crypto-api"),
-- 'getCRandom', 'getBytes', and 'runCRandom'.
--
-- @getRandPair = do
--   int <- getCRandom
--   bytes <- getBytes 100
--   return (int, bytes)
--
--  func = do
--   g <- newGenIO
--   case runCRand getRandPair g of
--       Right ((int,bytes), g') -> useRandomVals (int,bytes)
--       Left x -> handleGenError x
-- @
type CRand g e = CRandT g e Identity

runCRandT :: ContainsGenError e => CRandT g e m a -> g -> m (Either e (a,g))
runCRandT m g = runErrorT . flip runStateT g . unCRandT $ m

evalCRandT :: (ContainsGenError e, Monad m) => CRandT g e m a -> g -> m (Either e a)
evalCRandT m g = liftM (right fst) (runCRandT m g)

runCRand :: CRand g GenError a -> g -> Either GenError (a, g)
runCRand m = runIdentity . runCRandT m

evalCRand :: CRand g GenError a -> g -> Either GenError a
evalCRand m = runIdentity . evalCRandT m

instance (ContainsGenError e, Error e, Monad m, CryptoRandomGen g) => MonadCRandom e (CRandT g e m) where
        getCRandom  = wrap crandom
        getBytes i = wrap (genBytes i)
        getBytesWithEntropy i e = wrap (genBytesWithEntropy i e)
        doReseed bs = CRandT $ do
                        get >>= \g ->
                         case reseed bs g of
                            Right g' -> put g'
                            Left  x  -> throwError (fromGenError x)

instance (ContainsGenError e, Error e, Monad m, CryptoRandomGen g) => MonadCRandomR e (CRandT g e m) where
        getCRandomR = wrap . crandomR

instance Error GenError where
        noMsg = GenErrorOther "noMsg"
        strMsg = GenErrorOther

base2Log :: Integer -> Integer
base2Log i
        | i >= setBit 0 64 = 64 + base2Log (i `shiftR` 64)
        | i >= setBit 0 32 = 32 + base2Log (i `shiftR` 32)
        | i >= setBit 0 16 = 16 + base2Log (i `shiftR` 16)
        | i >= setBit 0 8  = 8  + base2Log (i `shiftR` 8)
        | i >= setBit 0 0  = 1  + base2Log (i `shiftR` 1)
        | otherwise        = 0

bs2i :: B.ByteString -> Integer
bs2i bs = B.foldl' (\i b -> (i `shiftL` 8) + fromIntegral b) 0 bs
{-# INLINE bs2i #-}

