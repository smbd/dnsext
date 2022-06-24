
module DNSC.ServerMonitor (
  monitor,
  Params,
  makeParams,
  showParams,
  ) where

-- GHC packages
import Control.Applicative ((<|>))
import Control.Concurrent (forkIO, forkFinally, threadWaitRead)
import Control.Concurrent.STM (STM, atomically, newTVarIO, readTVar, writeTVar)
import Control.Monad ((<=<), guard, when, unless, void)
import Data.Functor (($>))
import Data.List (isInfixOf, find)
import Data.Char (toUpper)
import qualified Data.ByteString.Char8 as B8
import System.IO (IOMode (ReadWriteMode), Handle, hGetLine, hIsEOF, hPutStr, hPutStrLn, hFlush, hClose, stdin, stdout)

-- dns packages
import Network.Socket (AddrInfo (..), SocketType (Stream), HostName, PortNumber, Socket, SockAddr)
import qualified Network.Socket as S
import qualified Network.DNS as DNS

-- other packages
import UnliftIO (tryAny, waitSTM, withAsync)

-- this package
import qualified DNSC.DNSUtil as Config
import DNSC.SocketUtil (addrInfo)
import qualified DNSC.Log as Log
import qualified DNSC.Cache as Cache
import DNSC.Iterative (Context (..))


data Params =
  Params
  { isRecvSendMsg :: Bool
  , isExtendedLookup :: Bool
  , numCapabilities :: Int
  , logOutput :: Log.FOutput
  , logLevel :: Log.Level
  , maxCacheSize :: Int
  , disableV6NS :: Bool
  , concurrency :: Int
  , dnsPort :: Int
  , dnsHosts :: [String]
  }

makeParams :: Int -> Log.FOutput -> Log.Level -> Int -> Bool -> Int -> Int -> [String]
           -> Params
makeParams capabilities output level maxSize disableV6 conc port hosts =
  Params
  { isRecvSendMsg = Config.isRecvSendMsg
  , isExtendedLookup = Config.isExtendedLookup
  , numCapabilities = capabilities
  , logOutput = output
  , logLevel = level
  , maxCacheSize = maxSize
  , disableV6NS = disableV6
  , concurrency = conc
  , dnsPort = port
  , dnsHosts = hosts
  }

showParams :: Params -> [String]
showParams params =
  [ field  "recvmsg / sendmsg" isRecvSendMsg
  , field  "extended lookup" isExtendedLookup
  , field  "capabilities" numCapabilities
  , field_ "log output" (showOut . logOutput)
  , field  "log level" logLevel
  , field  "max cache size" maxCacheSize
  , field  "disable queries to IPv6 NS" disableV6NS
  , field  "concurrency" concurrency
  , field  "DNS port" dnsPort
  ] ++
  if null hosts
  then ["DNS host list: null"]
  else  "DNS host list:" : map ("DNS host: " ++) hosts
  where
    field_ label toS = label ++ ": " ++ toS params
    field label get = field_ label (show . get)
    showOut Log.FStdout = "stdout - fast-logger"
    showOut Log.FStderr = "stderr - fast-logger"
    hosts = dnsHosts params

monitorSockets :: PortNumber -> [HostName] -> IO [(Socket, SockAddr)]
monitorSockets port = mapM aiSocket . filter ((== Stream) . addrSocketType) <=< addrInfo port
  where
    aiSocket ai = (,) <$> S.socket (addrFamily ai) (addrSocketType ai) (addrProtocol ai) <*> pure (addrAddress ai)

data Command
  = Param
  | Find String
  | Lookup DNS.Domain DNS.TYPE
  | Status
  | Noop
  | Exit
  | Quit
  deriving Show

monitor :: Bool -> Params -> Context
        -> ([(IO (Int, Int), IO (Int, Int), IO (Int, Int))], IO (Int, Int), IO (Int, Int))
        -> IO () -> IO [IO ()]
monitor stdConsole params cxt getsSizeInfo flushLog = do
  ps <- monitorSockets 10023 ["::1", "127.0.0.1"]
  let ss = map fst ps
  sequence_ [ S.setSocketOption sock S.ReuseAddr 1 | sock <- ss ]
  mapM_ (uncurry S.bind) ps
  sequence_ [ S.listen sock 5 | sock <- ss ]
  monQuit <- do
    qRef <- newTVarIO False
    return (writeTVar qRef True, readTVar qRef >>= guard)
  when stdConsole $ runStdConsole monQuit
  return $ map (monitorServer monQuit) ss
  where
    runStdConsole monQuit = do
      let repl = console params cxt getsSizeInfo flushLog monQuit stdin stdout "<std>"
      void $ forkIO repl
    logLn level = logLines_ cxt level . (:[])
    handle onError = either onError return <=< tryAny
    monitorServer monQuit@(_, waitQuit) s = do
      let step = do
            socketWaitRead s
            (sock, addr) <- S.accept s
            sockh <- S.socketToHandle sock ReadWriteMode
            let repl = console params cxt getsSizeInfo flushLog monQuit sockh sockh $ show addr
            void $ forkFinally repl (\_ -> hClose sockh)
          loop =
            either (const $ return ()) (const loop)
            =<< withWait waitQuit (handle (logLn Log.NOTICE . ("monitor io-error: " ++) . show) step)
      loop

console :: Params -> Context -> ([(IO (Int, Int), IO (Int, Int), IO (Int, Int))], IO (Int, Int), IO (Int, Int))
           -> IO () -> (STM (), STM ()) -> Handle -> Handle -> String -> IO ()
console params cxt (pQSizeList, ucacheQSize, logQSize) flushLog (issueQuit, waitQuit) inH outH ainfo = do
  let input = do
        s <- hGetLine inH
        let err = hPutStrLn outH ("monitor error: " ++ ainfo ++ ": command parse error: " ++ show s)
        maybe (err $> False) runCmd $ parseCmd $ words s

      step = do
        eof <- hIsEOF inH
        if eof then return True else input

      repl = do
        hPutStr outH "monitor> " *> hFlush outH
        either
          (const $ return ())
          (\exit -> unless exit repl)
          =<< withWait waitQuit (handle (($> False) . print) step)

  repl

  where
    handle onError = either onError return <=< tryAny

    parseTYPE s =
      find match types
      where
        us = map toUpper s
        match t = show t == us
        types = map DNS.toTYPE [1..512]

    parseCmd []  =    Just Noop
    parseCmd ws  =  case ws of
      "param" : _ ->  Just Param
      "find" : s : _      ->  Just $ Find s
      ["lookup", n, typ]  ->  Lookup (B8.pack n) <$> parseTYPE typ
      "status" : _  ->  Just Status
      "exit" : _  ->  Just Exit
      "quit" : _  ->  Just Quit
      _           ->  Nothing

    runCmd Quit  =  flushLog *> atomically issueQuit $> True
    runCmd Exit  =  return True
    runCmd cmd   =  dispatch cmd $> False
      where
        outLn = hPutStrLn outH
        dispatch Param            =  mapM_ outLn $ showParams params
        dispatch Noop             =  return ()
        dispatch (Find s)         =  mapM_ outLn . filter (s `isInfixOf`) . map show . Cache.dump =<< getCache_ cxt
        dispatch (Lookup dom typ) =  maybe (outLn "miss.") hit =<< lookupCache
          where lookupCache = do
                  cache <- getCache_ cxt
                  ts <- currentSeconds_ cxt
                  return $ Cache.lookup ts dom typ DNS.classIN cache
                hit (rrs, rank) = mapM_ outLn $ ("hit: " ++ show rank) : map show rrs
        dispatch Status           =  printStatus
        dispatch x                =  outLn $ "command: unknown state: " ++ show x

    printStatus = do
      let outLn = hPutStrLn outH
      outLn . ("cache size: " ++) . show . Cache.size =<< getCache_ cxt
      let psize s getSize = do
            (cur, mx) <- getSize
            outLn $ s ++ " size: " ++ show cur ++ " / " ++ show mx
      sequence_
        [ do psize ("request queue " ++ show i) reqQSize
             psize ("decoded queue " ++ show i) decQSize
             psize ("response queue " ++ show i) resQSize
        | (i, (reqQSize, decQSize, resQSize)) <- zip [0 :: Int ..] pQSizeList
        ]
      psize "ucache queue" ucacheQSize
      lmx <- snd <$> logQSize
      when (lmx >= 0) $ psize "log queue" logQSize


withWait :: STM a -> IO b -> IO (Either a b)
withWait qstm blockAct =
  withAsync blockAct $ \a ->
  atomically $
    (Left  <$> qstm)
    <|>
    (Right <$> waitSTM a)

socketWaitRead :: Socket -> IO ()
socketWaitRead sock = S.withFdSocket sock $ threadWaitRead . fromIntegral
