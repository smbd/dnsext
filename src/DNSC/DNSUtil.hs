{-# LANGUAGE CPP #-}

module DNSC.DNSUtil (
  mkRecv, mkSend,
  lookupRaw,

  -- interfaces to check compile-time configs
  isRecvSendMsg,
  isExtendedLookup,
  ) where

-- GHC packages
import qualified Control.Exception as E
import Control.Monad (void)

-- dns packages
import Network.Socket (Socket, SockAddr)
#if MIN_VERSION_network(3,1,2)
import qualified Network.Socket as Socket
#endif
import qualified Network.Socket.ByteString as Socket
import Network.DNS (DNSMessage)
import qualified Network.DNS as DNS

-- this package
import DNSC.Types

---

#if MIN_VERSION_network(3,1,2)
type Cmsg = Socket.Cmsg
#else
type Cmsg = ()
#endif

-- return tuples that can be reused in request and response queues
mkRecv :: Bool -> Timestamp -> Socket -> IO (DNSMessage, (SockAddr, [Cmsg], Bool))
#if MIN_VERSION_network(3,1,2)
mkRecv wildcard now
  | wildcard    =  recvDNS recvMsg
  | otherwise   =  recvDNS recvFrom
#else
mkRecv wildcard now =  recvDNS recvFrom
#endif
  where
    recvDNS recv sock = do
      (bs, ai) <- recv sock `E.catch` \e -> E.throwIO $ DNS.NetworkFailure e
      case DNS.decodeAt now bs of
        Left  e   -> E.throwIO e
        Right msg -> return (msg, ai)

#if MIN_VERSION_network(3,1,2)
    recvMsg sock = do
      let cbufsiz = 64
      (peer, bs, cmsgs, _) <- Socket.recvMsg sock bufsiz cbufsiz 0
      return (bs, (peer, cmsgs, wildcard))
#endif

    recvFrom sock = do
      (bs, peer) <- Socket.recvFrom sock bufsiz
      return (bs, (peer, [], wildcard))
    bufsiz = 16384 -- maxUdpSize in dns package, internal/Network/DNS/Types/Internal.hs

mkSend :: Bool -> Socket -> DNSMessage -> SockAddr -> [Cmsg] -> IO ()
#if MIN_VERSION_network(3,1,2)
mkSend wildcard
  | wildcard   =  sendDNS sendMsg
  | otherwise  =  sendDNS sendTo
#else
mkSend _       =  sendDNS sendTo
#endif
  where
    sendDNS send sock msg addr cmsgs =
      void $ send sock (DNS.encode msg) addr cmsgs

#if MIN_VERSION_network(3,1,2)
    sendMsg sock bs addr cmsgs = Socket.sendMsg sock addr [bs] cmsgs 0
#endif

    sendTo sock bs addr _ = Socket.sendTo sock bs addr

-- available recvMsg and sendMsg or not
isRecvSendMsg :: Bool
#if MIN_VERSION_network(3,1,2)
isRecvSendMsg = True
#else
isRecvSendMsg = False
#endif

---

lookupRaw :: Timestamp -> DNS.Resolver -> DNS.Domain -> DNS.TYPE -> IO (Either DNS.DNSError DNSMessage)
isExtendedLookup :: Bool
#if EXTENDED_LOOKUP
lookupRaw now rslv dom typ = DNS.lookupRawRecv rslv dom typ mempty rcv
  where
    rcv sock = do
      bs <- Socket.recv sock bufsiz
      case DNS.decodeAt now bs of
        Left  e   -> E.throwIO e
        Right msg -> return msg
    bufsiz = 16384 -- maxUdpSize in dns package, internal/Network/DNS/Types/Internal.hs

isExtendedLookup = True
#else
lookupRaw _ = DNS.lookupRaw

isExtendedLookup = False
#endif
