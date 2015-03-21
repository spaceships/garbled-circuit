{-# LANGUAGE PackageImports #-}

module Crypto.GarbledCircuits.Encryption
  ( genKey
  , genR
  , hash
  , randBlock
  , randBool
  , updateKey
  , pad
  , updateR
  )
where

import Crypto.GarbledCircuits.Types
import Crypto.GarbledCircuits.Util

import qualified Data.ByteString    as BS
import           Control.Monad.State
import           Crypto.Cipher.AES
import           "crypto-random" Crypto.Random
import           Data.Bits ((.&.), (.|.))
import qualified Data.Bits          as Bits
import qualified Data.Serialize     as Ser
import           Data.Word

--------------------------------------------------------------------------------
-- encryption and decryption for wirelabels

-- The AES-based hash function from the halfgates paper (p8)
-- Uses native hw instructions if available
hash :: AES -> Wirelabel -> Int -> Wirelabel
hash key x i = encryptECB key k `xorBytes` k
  where
    k = double x `xorBytes` pad 16 (Ser.encode i)

pad :: Int -> ByteString -> ByteString
pad n ct = BS.append (BS.replicate (n - BS.length ct) 0) ct

double :: ByteString -> ByteString
double c = BS.pack result
  where
    (xs, carry) = shiftLeft (BS.unpack c)
    result      = if carry > 0 then xorWords xs irreducible else xs

irreducible :: [Word8]
irreducible = replicate 15 0 ++ [86]

shiftLeft :: [Word8] -> ([Word8], Word8)
shiftLeft []     = ([], 0)
shiftLeft (b:bs) = let (bs', c) = shiftLeft bs
                       msb = Bits.shiftR b 7
                       b'  = Bits.shiftL b 1 .|. c
                   in (b':bs', msb)

genKey :: Garble (Key, AES)
genKey = do
  key <- randBlock
  return (key, initAES key)

genR :: Garble Wirelabel
genR = do
    b <- randBlock
    let color = pad 16 $ Ser.encode (1 :: Int)
        wl    = orBytes color b
    return wl

randBlock :: Garble ByteString
randBlock = do
  gen <- lift get
  let (blk, gen') = cprgGenerate 16 gen
  lift $ put gen'
  return blk

randBool :: Garble Bool
randBool = do
  gen <- lift get
  let (blk, gen') = cprgGenerate 1 gen
      w8          = head (BS.unpack blk)
  lift (put gen')
  return (w8 .&. 1 > 0)

updateKey :: (Key, AES) -> Garble ()
updateKey k = lift.lift $ modify (\st -> st { ctx_key = k })

updateR :: Wirelabel -> Garble ()
updateR r = lift.lift $ modify (\st -> st { ctx_r = r })