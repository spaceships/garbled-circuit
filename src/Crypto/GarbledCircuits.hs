{-# LANGUAGE FlexibleInstances, RankNTypes #-}

module Crypto.GarbledCircuits
  ( garblerProto
  , evaluatorProto
  , connectTo
  , listenAt
  , Connection (..)
  , simpleSocket
  )
where

import Crypto.GarbledCircuits.GarbledGate
import Crypto.GarbledCircuits.TruthTable
import Crypto.GarbledCircuits.Eval
import Crypto.GarbledCircuits.Types
import Crypto.GarbledCircuits.Util

import           Crypto.Cipher.AES
import           Control.Monad
import qualified Data.ByteString.Char8 as BS
import           Data.Serialize
import           Network.Socket hiding (send, recv)
import           Network.BSD
import           System.IO

#ifdef DEBUG
import Debug.Trace
#else
traceM :: Monad m => String -> m ()
traceM _ = return ()
#endif

type Port = Int

data Connection = Connection { send :: Serialize a => a -> IO ()
                             , recv :: Serialize a => IO a
                             }

garblerProto :: Program Circuit -> [Bool] -> Connection -> IO [Bool]
garblerProto prog inp con = do
      (gg, ctx) <- garble prog
      traceM "[garblerProto] circuit garbled"
      let myWires    = inputWires PartyA gg ctx inp
          theirPairs = inputPairs PartyB gg ctx
      traceM "[garblerProto] sending circuit"
      send con (halfGates gg)
      traceM "[garblerProto] sending my input wires"
      send con myWires
      traceM "[garblerProto] sending key"
      send con (fst (ctx_key ctx))
      traceM "[garblerProto] performing OT"
      otSendWirelabels con theirPairs
      traceM "[garblerProto] recieving output"
      wires <- recv con
      let result = map (ungarble ctx) wires
      traceM "[garblerProto] sending ungarbled output"
      send con result
      return result

evaluatorProto :: Program Circuit -> [Bool] -> Connection -> IO [Bool]
evaluatorProto prog inp con = do
      let tt = circ2tt prog
      traceM "[evaluatorProto] recieving circuit"
      hgs <- recv con :: IO [(Wirelabel,Wirelabel)]
      traceM "[evaluatorProto] recieving garbler input wires"
      inpA <- recv con :: IO [Wirelabel]
      traceM "[evaluatorProto] recieving key"
      key <- recv con :: IO ByteString
      traceM "[evaluatorProto] performing OT"
      inpB <- otRecvWirelabels con inp
      traceM "[evaluatorProto] evaluating garbled circuit"
      let gg  = reconstruct tt hgs
          k   = initAES (key :: ByteString)
          out = eval gg k inpA inpB
      traceM ("[evaluatorProto] output =\n" ++ showOutput (prog_output gg) out)
      traceM "[evaluatorProto] sending output wires"
      send con out
      traceM "[evaluatorProto] recieving ungarbled output"
      recv con

otSendWirelabels :: Connection -> [WirelabelPair] -> IO ()
otSendWirelabels con wlps = do
    traceM "[otSendWirelabels] WARNING: not actually OT"
    inps <- recv con
    let wires = zipWith sel inps wlps
    send con wires

otRecvWirelabels :: Connection -> [Bool] -> IO [Wirelabel]
otRecvWirelabels con inps = do
    traceM "[otRecvWirelabels] WARNING: not actually OT"
    send con inps
    recv con

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

showOutput :: [Ref GarbledGate] -> [Wirelabel] -> String
showOutput refs = init . unlines . zipWith (\r w -> "\t" ++ show r ++ " " ++ showWirelabel w) refs

simpleSocket :: Handle -> Connection
simpleSocket h = Connection { send = bsPut, recv = bsGet }
  where
    bsPut :: Serialize a => a -> IO ()
    bsPut x = do
      let encoding = encode x; n = BS.length encoding
      traceM ("[send] sending " ++ show n ++ " bytes")
      BS.hPut h (encode n)
      BS.hPut h encoding
    bsGet :: Serialize a => IO a
    bsGet = do 
      num <- BS.hGet h 8
      let n = either (err "recieve") id (decode num)
      str <- BS.hGet h n
      traceM ("[recv] recieved " ++ show n ++ " bytes")
      either (err "recv") return (decode str)