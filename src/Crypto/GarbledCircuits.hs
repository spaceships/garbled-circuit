{-# LANGUAGE FlexibleInstances #-}

module Crypto.GarbledCircuits
  (
    garblerProto
  , evaluatorProto
  , module Crypto.GarbledCircuits.Language
  ,
  )
where

import Crypto.GarbledCircuits.Language
import Crypto.GarbledCircuits.GarbledGate
import Crypto.GarbledCircuits.TruthTable
import Crypto.GarbledCircuits.Eval
import Crypto.GarbledCircuits.Types
import Crypto.GarbledCircuits.Util

import           Crypto.Cipher.AES
import           Control.Monad
import           Data.Functor
import qualified Data.ByteString.Char8 as BS
import           Data.Serialize
import           Network.Socket
import           Network.BSD
import           System.IO

type Port = Int

garblerProto :: Port -> Program Circ -> [Bool] -> IO [Bool]
garblerProto port prog inp = do
    (gg, ctx) <- garble prog
    let myWires    = inputWires A gg ctx inp
        theirPairs = inputPairs B gg ctx
        outPairs   = outputPairs gg ctx
    listenAt port $ \h -> do
      hPutSerialize h (halfGates gg, myWires, fst (ctx_key ctx))
      otSendWirelabels h theirPairs
      wires <- hGetSerialize h
      let result = map (ungarble ctx) wires
      hPutSerialize h result
      return result

evaluatorProto :: HostName -> Port -> Program Circ -> [Bool] -> IO [Bool]
evaluatorProto host port prog inp = do
    let tt = circ2tt prog
    connectTo host port $ \h -> do
      (hgs, inpA, key) <- hGetSerialize h
      inpB <- otRecvWirelabels h inp
      let gg  = reconstruct tt hgs
          k   = initAES (key :: ByteString)
          out = eval gg k inpA inpB
      hPutSerialize h out
      hGetSerialize h

hPutSerialize :: Serialize a => Handle -> a -> IO ()
hPutSerialize h x = BS.hPutStrLn h (encode x)

hGetSerialize :: Serialize a => Handle -> IO a
hGetSerialize h = do
    str <- BS.hGetLine h
    either (err "hGetGarbledCircuit") return (decode str)

otSendWirelabels :: Handle -> [WirelabelPair] -> IO ()
otSendWirelabels = undefined

otRecvWirelabels :: Handle -> [Bool] -> IO [Wirelabel]
otRecvWirelabels = undefined

connectTo :: HostName -> Port -> (Handle -> IO a) -> IO a
connectTo host port_ f = withSocketsDo $ do
    let port = toEnum port_
    sock <- socket AF_INET Stream 0
    addrs <- liftM hostAddresses $ getHostByName host
    when (null addrs) $ err "connectTo" ("no such host: " ++ host)
    connect sock $ SockAddrInet port (head addrs)
    perform sock f

listenAt :: Port -> (Handle -> IO a) -> IO a
listenAt port_ f = withSocketsDo $ do
    let port = toEnum port_
    lsock <- socket AF_INET Stream 0
    bindSocket lsock (SockAddrInet port iNADDR_ANY)
    listen lsock sOMAXCONN
    (sock,SockAddrInet _ _) <- accept lsock
    perform sock f

perform :: Socket -> (Handle -> IO a) -> IO a
perform sock f = withSocketsDo $ do
    handle <- socketToHandle sock ReadWriteMode
    result <- f handle
    hClose handle
    return result
