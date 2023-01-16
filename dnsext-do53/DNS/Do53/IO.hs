{-# LANGUAGE OverloadedStrings #-}

module DNS.Do53.IO (
    openTCP
    -- * Receiving DNS messages
  , recvTCP
  , recvVC
  , decodeVCLength
    -- * Sending pre-encoded messages
  , sendTCP
  , sendVC
  , encodeVCLength
  ) where

import qualified Control.Exception as E
import DNS.Types hiding (Seconds)
import qualified Data.ByteString as BS
import Network.Socket (Socket, openSocket, connect, getAddrInfo, AddrInfo(..), defaultHints, HostName, PortNumber, SocketType(..), AddrInfoFlag(..))
import Network.Socket.ByteString (recv)
import qualified Network.Socket.ByteString as NSB
import System.IO.Error

import DNS.Do53.Imports

----------------------------------------------------------------

-- | Opening a TCP socket.
openTCP :: HostName -> PortNumber -> IO Socket
openTCP h p = do
    ai <- makeAddrInfo h p
    sock <- openSocket ai
    connect sock $ addrAddress ai
    return sock

makeAddrInfo :: HostName -> PortNumber -> IO AddrInfo
makeAddrInfo nh p = do
    let hints = defaultHints {
            addrFlags = [AI_ADDRCONFIG, AI_NUMERICHOST, AI_NUMERICSERV]
          , addrSocketType = Stream
          }
    let np = show p
    head <$> getAddrInfo (Just hints) (Just nh) (Just np)

----------------------------------------------------------------

-- | Receiving data from a virtual circuit.
recvVC :: (Int -> IO ByteString) -> IO ByteString
recvVC rcv = do
    len <- decodeVCLength <$> rcv 2
    rcv len

-- | Decoding the length from the first two bytes.
decodeVCLength :: ByteString -> Int
decodeVCLength bs = case BS.unpack bs of
  [hi, lo] -> 256 * fromIntegral hi + fromIntegral lo
  _        -> 0              -- never reached

-- | Receiving data from a TCP socket.
--   'NetworkFailure' is thrown if necessary.
recvTCP :: Socket -> Int -> IO ByteString
recvTCP sock len = recv1 `E.catch` \e -> E.throwIO $ NetworkFailure e
  where
    recv1 = do
        bs1 <- recvCore len
        if BS.length bs1 == len then
            return bs1
          else do
            loop bs1
    loop bs0 = do
        let left = len - BS.length bs0
        bs1 <- recvCore left
        let bs = bs0 <> bs1
        if BS.length bs == len then
            return bs
          else
            loop bs
    eofE = mkIOError eofErrorType "connection terminated" Nothing Nothing
    recvCore len0 = do
        bs <- recv sock len0
        if bs == "" then
            E.throwIO eofE
          else
            return bs

----------------------------------------------------------------

-- | Send a single encoded 'DNSMessage' over VC.  An explicit length is
-- prepended to the encoded buffer before transmission.  If you want to
-- send a batch of multiple encoded messages back-to-back over a single
-- VC connection, and then loop to collect the results, use 'encodeVC'
-- to prefix each message with a length, and then use 'sendAll' to send
-- a concatenated batch of the resulting encapsulated messages.
--
sendVC :: ([ByteString] -> IO ()) -> ByteString -> IO ()
sendVC writev bs = do
    let lb = encodeVCLength $ BS.length bs
    writev [lb,bs]

-- | Sending data to a TCP socket.
sendTCP :: Socket -> [ByteString] -> IO ()
sendTCP = NSB.sendMany

-- | Encapsulate an encoded 'DNSMessage' buffer for transmission over a VC
-- virtual circuit.  With VC the buffer needs to start with an explicit
-- length (the length is implicit with UDP).
--
encodeVCLength :: Int -> ByteString
encodeVCLength len = BS.pack [fromIntegral u, fromIntegral l]
    where
      (u,l) = len `divMod` 256
