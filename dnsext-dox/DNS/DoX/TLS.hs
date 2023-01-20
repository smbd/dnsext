{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module DNS.DoX.TLS where

import DNS.Do53.Internal
import Data.ByteString.Char8 ()
import Network.Socket hiding (recvBuf)
import Network.Socket.BufferPool
import Network.TLS (contextNew, handshake, bye)
import qualified UnliftIO.Exception as E

import DNS.DoX.Common

tlsResolver :: Resolver
tlsResolver ri@ResolvInfo{..} q qctl = vcResolver "TLS" perform ri q qctl
  where
    -- Using a fresh connection
    perform solve = E.bracket open close $ \sock -> do
      E.bracket (contextNew sock params) bye $ \ctx -> do
        handshake ctx
        (recv, recvBuf) <- makeRecv $ recvTLS ctx
        recvN <- makeReceiveN "" recv recvBuf
        let sendDoT = sendVC (sendManyTLS ctx)
            recvDoT = recvVC recvN
        solve sendDoT recvDoT

    open = openTCP rinfoHostName rinfoPortNumber
    params = getTLSParams rinfoHostName "dot" False
