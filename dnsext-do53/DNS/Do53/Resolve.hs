{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}

module DNS.Do53.Resolve (
    resolve,
)
where

import Control.Concurrent.Async (Async, waitCatchSTM)
import Control.Concurrent.STM
import Control.Exception as E
import Control.Monad (when)
import DNS.Do53.Types
import qualified DNS.Log as Log
import qualified DNS.ThreadStats as TStat
import DNS.Types
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as NE

----------------------------------------------------------------

-- In lookup loop, we try UDP until we get a response.  If the response
-- is truncated, we try TCP once, with no further UDP retries.
--
-- For now, we optimize for low latency high-availability caches
-- (e.g.  running on a loopback interface), where TCP is cheap
-- enough.  We could attempt to complete the TCP lookup within the
-- original time budget of the truncated UDP query, by wrapping both
-- within a a single 'timeout' thereby staying within the original
-- time budget, but it seems saner to give TCP a full opportunity to
-- return results.  TCP latency after a truncated UDP reply will be
-- atypical.
--
-- Future improvements might also include support for TCP on the
-- initial query.
--
-- This function merges the query flag overrides from the resolver
-- configuration with any additional overrides from the caller.
--
resolve :: ResolveEnv -> Resolver
resolve _ Question{..} _
    | qtype == AXFR = return $ Left InvalidAXFRLookup
resolve ResolveEnv{..} q qctl = case renvResolveInfos of
    ri :| [] -> resolver ri q qctl
    ris
        | concurrent -> resolveConcurrent ris resolver q qctl
        | otherwise -> resolveSequential ris resolver q qctl
  where
    concurrent = renvConcurrent
    resolver = renvResolver

resolveSequential
    :: NonEmpty ResolveInfo -> OneshotResolver -> Resolver
resolveSequential ris0 resolver q qctl = loop ris0
  where
    loop ris' = do
        let (ri, mris) = NE.uncons ris'
        eres <- resolver ri q qctl
        case eres of
            Left e -> case mris of
                Nothing -> return $ Left e
                Just ris -> loop ris
            res@(Right _) -> return res

resolveConcurrent
    :: NonEmpty ResolveInfo -> OneshotResolver -> Resolver
resolveConcurrent ris@(ResolveInfo{rinfoActions = riAct} :| _) resolver q@Question{..} qctl = do
    caller <- TStat.getThreadLabel
    ex <- E.try $ raceAny [(caller ++ ": do53-res: " ++ show (rinfoIP ri), resolver' ri) | ri <- NE.toList ris]
    case ex of
        Right r@Result{..} -> do
            let ~tag =
                    "    query "
                        ++ show qname
                        ++ " "
                        ++ show qtype
                        ++ " to "
                        ++ show resultIP
                        ++ "#"
                        ++ show resultPort
                        ++ "/"
                        ++ resultTag
            ractionLog riAct Log.DEMO Nothing [tag ++ ": win"]
            return $ Right r
        le@(Left (_ :: DNSError)) -> return le
  where
    resolver' ri = do
        erply <- resolver ri q qctl
        case erply of
            Right rply -> return rply
            Left e -> throwIO e

----------------------------------------------------------------

-- $setup
-- >>> :seti -Wno-type-defaults
-- >>> import Data.Functor
-- >>> import Control.Concurrent

raceAny :: [(String, IO a)] -> IO a
raceAny ios = TStat.withAsyncs ios waitAnyRightCancel

waitAnyRightCancel :: [Async a] -> IO a
waitAnyRightCancel asyncs = atomically (waitAnyRightSTM asyncs)

-- |
-- The first value is returned and others are canceled at that time.
-- The last exception is returned when all throws an exception.
--
-- >>> tsleep n = threadDelay $ n * 100 * 1000
-- >>> right n x = tsleep n $> x
-- >>> left = fail
-- >>> TStat.withAsyncs [("a1", right 1 "good1"), ("a1", right 20 "good2"), ("a3", right 20 "good3")] (atomically . waitAnyRightSTM)
-- "good1"
-- >>> TStat.withAsyncs [("a1", right 1 "good1"), ("a1", right 20 "good2"), ("a3", left "bad")] (atomically . waitAnyRightSTM)
-- "good1"
-- >>> TStat.withAsyncs [("a1", right 1 "good1"), ("a2", left "bad"), ("a3", right 20 "good3")] (atomically . waitAnyRightSTM)
-- "good1"
-- >>> TStat.withAsyncs [("a1", left "bad"), ("a2", right 2 "good2"), ("a3", right 20 "good3")] (atomically . waitAnyRightSTM)
-- "good2"
-- >>> TStat.withAsyncs [("a1", left "bad1"), ("a2", left "bad2"), ("a3", left "bad3")] (atomically . waitAnyRightSTM)
-- *** Exception: user error (bad3)
waitAnyRightSTM :: [Async a] -> STM a
waitAnyRightSTM = getAnyRight . map waitCatchSTM

getAnyRight :: [STM (Either SomeException a)] -> STM a
getAnyRight [] = error "getAnyRight: null input"
getAnyRight ws0 = go id True ws0
  where
    -- The blocked list is original list: all is blocked
    go _ True [] = retry
    -- The blocked list is not original list: retry for only blocked STMs
    go blockedB False [] = getAnyRight $ blockedB []
    go blockedB orig (t : ts) = do
        ---- t is not blocked
        --------------- t is blocked, accumulate blocked STM
        e <- t `orElse` (Right <$> go (blockedB . (t :)) orig ts)
        case e of
            Right rv -> pure rv
            Left err -> do
                when (null ts && null (blockedB [])) $ throwSTM err
                -- go through with ts, not original list anymore
                go blockedB False ts
