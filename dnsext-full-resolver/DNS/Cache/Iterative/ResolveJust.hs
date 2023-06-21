{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module DNS.Cache.Iterative.ResolveJust (
    runResolveJust,
    resolveJust,
    runIterative,
) where

-- GHC packages
import Control.Monad (join, when)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Reader (asks)
import Data.Function (on)
import Data.Functor (($>))
import Data.List (groupBy, sort, uncons)
import Data.Maybe (isJust)
import qualified Data.Set as Set

-- other packages

import System.Console.ANSI.Types

-- dns packages

import DNS.Do53.Client (
    QueryControls (..),
 )
import DNS.Do53.Memo (
    rankedAdditional,
    rankedAnswer,
    rankedAuthority,
 )
import qualified DNS.Do53.Memo as Cache
import DNS.SEC (
    RD_DNSKEY,
    RD_DS (..),
    TYPE (DNSKEY, DS),
 )
import DNS.Types (
    DNSMessage,
    Domain,
    RData,
    ResourceRecord (..),
    TYPE (A, AAAA, NS, SOA),
 )
import qualified DNS.Types as DNS
import Data.IP (IP (IPv4, IPv6))

-- this package
import DNS.Cache.Iterative.Cache
import DNS.Cache.Iterative.Helpers
import DNS.Cache.Iterative.Norec
import DNS.Cache.Iterative.Random
import DNS.Cache.Iterative.Root
import DNS.Cache.Iterative.Types
import DNS.Cache.Iterative.Utils
import DNS.Cache.Iterative.Verify
import qualified DNS.Log as Log

-- 権威サーバーからの解決結果を得る
runResolveJust
    :: Env
    -> Domain
    -> TYPE
    -> QueryControls
    -> IO (Either QueryError (DNSMessage, Delegation))
runResolveJust cxt n typ cd = runDNSQuery (resolveJust n typ) cxt cd

-- 反復検索を使って最終的な権威サーバーからの DNSMessage とその委任情報を得る. CNAME は解決しない.
resolveJust :: Domain -> TYPE -> DNSQuery (DNSMessage, Delegation)
resolveJust = resolveJustDC 0

resolveJustDC :: Int -> Domain -> TYPE -> DNSQuery (DNSMessage, Delegation)
resolveJustDC dc n typ
    | dc > mdc = do
        lift . logLn Log.WARN $
            "resolve-just: not sub-level delegation limit exceeded: " ++ show (n, typ)
        throwDnsError DNS.ServerFailure
    | otherwise = do
        lift . logLn Log.DEMO $
            "resolve-just: " ++ "dc=" ++ show dc ++ ", " ++ show (n, typ)
        root <- refreshRoot
        nss@Delegation{..} <- iterative_ dc root $ reverse $ DNS.superDomains n
        sas <- delegationIPs dc nss
        lift . logLn Log.DEMO . unwords $
            ["resolve-just: query", show (n, typ), "selected addresses:"]
                ++ [show sa | sa <- sas]
        let dnssecOK = not (null delegationDS) && not (null delegationDNSKEY)
        (,) <$> norec dnssecOK sas n typ <*> pure nss
  where
    mdc = maxNotSublevelDelegation

-- Filter authoritative server addresses from the delegation information.
-- If the resolution result is NODATA, IllegalDomain is returned.
delegationIPs :: Int -> Delegation -> DNSQuery [IP]
delegationIPs dc Delegation{..} = do
    disableV6NS <- lift $ asks disableV6NS_

    let ipnum = 4
        ips = takeDEntryIPs disableV6NS delegationNS

        takeNames (DEonlyNS name) xs
            | not $
                name `DNS.isSubDomainOf` delegationZone =
                name : xs {- skip sub-domain without glue to avoid loop -}
        takeNames _ xs = xs

        names = foldr takeNames [] $ uncurry (:) delegationNS

        result
            | not (null ips) = selectIPs ipnum ips
            | not (null names) = do
                mayName <- randomizedSelect names
                let neverReach = do
                        lift $ logLn Log.DEMO $ "delegationIPs: never reach this action."
                        throwDnsError DNS.ServerFailure
                maybe neverReach (fmap ((: []) . fst) . resolveNS disableV6NS dc) mayName
            | disableV6NS && not (null allIPs) = do
                lift . logLn Log.DEMO . concat $
                    [ "delegationIPs: server-fail: domain: "
                    , show delegationZone
                    , ", delegation is empty."
                    ]
                throwDnsError DNS.ServerFailure
            | otherwise = do
                lift . logLn Log.DEMO . concat $
                    [ "delegationIPs: illegal-domain: "
                    , show delegationZone
                    , ", delegation is empty."
                    , " without glue sub-domains: "
                    , show subNames
                    ]
                throwDnsError DNS.IllegalDomain
          where
            allIPs = takeDEntryIPs False delegationNS

        takeSubNames (DEonlyNS name) xs
            | name `DNS.isSubDomainOf` delegationZone =
                name : xs {- sub-domain name without glue -}
        takeSubNames _ xs = xs
        subNames = foldr takeSubNames [] $ uncurry (:) delegationNS

    result

resolveNS :: Bool -> Int -> Domain -> DNSQuery (IP, ResourceRecord)
resolveNS disableV6NS dc ns = do
    let axPairs = axList disableV6NS (== ns) (,)

        lookupAx
            | disableV6NS = lk4
            | otherwise = join $ randomizedSelectN (lk46, [lk64])
          where
            lk46 = lk4 +? lk6
            lk64 = lk6 +? lk4
            lk4 = lookupCache ns A
            lk6 = lookupCache ns AAAA
            lx +? ly = maybe ly (return . Just) =<< lx

        query1Ax
            | disableV6NS = q4
            | otherwise = join $ randomizedSelectN (q46, [q64])
          where
            q46 = q4 +!? q6
            q64 = q6 +!? q4
            q4 = querySection A
            q6 = querySection AAAA
            qx +!? qy = do
                xs <- qx
                if null xs then qy else pure xs
            querySection typ =
                lift . cacheAnswerAx
                    =<< resolveJustDC (succ dc) ns typ {- resolve for not sub-level delegation. increase dc (delegation count) -}
            cacheAnswerAx (msg, _) = withSection rankedAnswer msg $ \rrs rank -> do
                let ps = axPairs rrs
                cacheSection (map snd ps) rank
                return ps

        resolveAXofNS :: DNSQuery (IP, ResourceRecord)
        resolveAXofNS = do
            let failEmptyAx
                    | disableV6NS = do
                        lift . logLn Log.WARN $
                            "resolveNS: server-fail: NS: " ++ show ns ++ ", address is empty."
                        throwDnsError DNS.ServerFailure
                    | otherwise = do
                        lift . logLn Log.WARN $
                            "resolveNS: illegal-domain: NS: " ++ show ns ++ ", address is empty."
                        throwDnsError DNS.IllegalDomain
            maybe failEmptyAx pure
                =<< randomizedSelect {- 失敗時: NS に対応する A の返答が空 -}
                =<< maybe query1Ax (pure . axPairs . fst)
                =<< lift lookupAx

    resolveAXofNS

fillDelegationDNSKEY :: Int -> Delegation -> DNSQuery Delegation
fillDelegationDNSKEY _ d@Delegation{delegationDS = []} = return d {- DS(Delegation Signer) does not exist -}
fillDelegationDNSKEY _ d@Delegation{delegationDS = _ : _, delegationDNSKEY = _ : _} = return d {- already filled -}
fillDelegationDNSKEY dc d@Delegation{delegationDS = _ : _, delegationDNSKEY = [], ..} =
    maybe query (lift . fill . toDNSKEYs)
        =<< lift (lookupCache delegationZone DNSKEY)
  where
    toDNSKEYs (rrs, _) = rrListWith DNSKEY DNS.fromRData delegationZone const rrs
    fill dnskeys = return d{delegationDNSKEY = dnskeys}
    query = do
        ips <- delegationIPs dc d
        let nullIPs = logLn Log.WARN "fillDelegationDNSKEY: ip list is null" *> return d
            verifyFailed es = logLn Log.WARN ("fillDelegationDNSKEY: " ++ es) *> return d
        if null ips
            then lift nullIPs
            else
                lift . either verifyFailed fill
                    =<< cachedDNSKEY (delegationDS d) ips delegationZone

-- 反復後の委任情報を得る
runIterative
    :: Env
    -> Delegation
    -> Domain
    -> QueryControls
    -> IO (Either QueryError Delegation)
runIterative cxt sa n cd = runDNSQuery (iterative sa n) cxt cd

-- 反復検索
-- 繰り返し委任情報をたどって目的の答えを知るはずの権威サーバー群を見つける
iterative :: Delegation -> Domain -> DNSQuery Delegation
iterative sa n = iterative_ 0 sa $ reverse $ DNS.superDomains n

iterative_ :: Int -> Delegation -> [Domain] -> DNSQuery Delegation
iterative_ _ nss0 [] = return nss0
iterative_ dc nss0 (x : xs) =
    {- If NS is not returned, the information of the same NS is used for the child domain. or.jp and ad.jp are examples of this case. -}
    step nss0 >>= mayDelegation (recurse nss0 xs) (`recurse` xs)
  where
    recurse = iterative_ dc {- sub-level delegation. increase dc only not sub-level case. -}
    name = x

    lookupNX :: ContextT IO Bool
    lookupNX = isJust <$> lookupCache name Cache.NX

    stepQuery :: Delegation -> DNSQuery MayDelegation
    stepQuery nss@Delegation{..} = do
        let zone = delegationZone
            dnskeys = delegationDNSKEY
        lift . logLn Log.DEMO $
            "zone: " ++ show zone ++ ":\n" ++ ppDelegation delegationNS
        sas <- delegationIPs dc nss {- When the same NS information is inherited from the parent domain, balancing is performed by re-selecting the NS address. -}
        lift . logLn Log.DEMO . unwords $
            ["iterative: query", show (name, A), "with selected addresses:"]
                ++ [show sa | sa <- sas]
        let dnssecOK = not (null delegationDS) && not (null delegationDNSKEY)
        {- Use `A` for iterative queries to the authoritative servers during iterative resolution.
           See the following document:
           QNAME Minimisation Examples: https://datatracker.ietf.org/doc/html/rfc9156#section-4 -}
        msg <- norec dnssecOK sas name A
        let withNoDelegation handler = mayDelegation handler (return . HasDelegation)
            sharedHandler = subdomainShared dc nss name msg
            cacheHandler = cacheNoDelegation zone dnskeys name msg $> NoDelegation
        delegationWithCache zone dnskeys name msg
            >>= withNoDelegation sharedHandler
            >>= lift . withNoDelegation cacheHandler

    step :: Delegation -> DNSQuery MayDelegation
    step nss = do
        let withNXC nxc
                | nxc = return NoDelegation
                | otherwise = stepQuery nss
        md <- maybe (withNXC =<< lift lookupNX) return =<< lift (lookupDelegation name)
        let fills d = fillsDNSSEC dc nss d
        mayDelegation (return NoDelegation) (fmap HasDelegation . fills) md

data MayDelegation
    = NoDelegation {- no delegation information -}
    | HasDelegation Delegation

mayDelegation :: a -> (Delegation -> a) -> MayDelegation -> a
mayDelegation n h md = case md of
    NoDelegation -> n
    HasDelegation d -> h d

maxNotSublevelDelegation :: Int
maxNotSublevelDelegation = 16

{- Workaround delegation for one authoritative server has both domain zone and sub-domain zone -}
subdomainShared
    :: Int -> Delegation -> Domain -> DNSMessage -> DNSQuery MayDelegation
subdomainShared dc nss dom msg = withSection rankedAuthority msg $ \rrs rank -> do
    let soaRRs =
            rrListWith SOA (DNS.fromRData :: RData -> Maybe DNS.RD_SOA) dom (\_ x -> x) rrs
        getWorkaround = fillsDNSSEC dc nss (Delegation dom (delegationNS nss) [] [])
        verifySOA = do
            d <- getWorkaround
            let dnskey = delegationDNSKEY d
            case dnskey of
                [] -> return $ HasDelegation d
                _ : _ -> do
                    (rrset, _) <- lift $ verifyAndCache dnskey soaRRs (rrsigList dom SOA rrs) rank
                    if rrsetVerified rrset
                        then return $ HasDelegation d
                        else do
                            lift . logLn Log.WARN . unwords $
                                [ "subdomainShared:"
                                , show dom ++ ":"
                                , "verification error. invalid SOA:"
                                , show soaRRs
                                ]
                            lift . clogLn Log.DEMO (Just Red) $
                                show dom ++ ": verification error. invalid SOA"
                            throwDnsError DNS.ServerFailure

    case soaRRs of
        [] -> return NoDelegation {- not workaround fallbacks -}
        {- When `A` records are found, indistinguishable from the A definition without sub-domain cohabitation -}
        [_] -> verifySOA
        _ : _ : _ -> do
            lift . logLn Log.WARN . unwords $
                [ "subdomainShared:"
                , show dom ++ ":"
                , "multiple SOAs are found:"
                , show soaRRs
                ]
            lift . logLn Log.DEMO $ show dom ++ ": multiple SOA: " ++ show soaRRs
            throwDnsError DNS.ServerFailure

fillsDNSSEC :: Int -> Delegation -> Delegation -> DNSQuery Delegation
fillsDNSSEC dc nss d = do
    filled@Delegation{..} <- fillDelegationDNSKEY dc =<< fillDelegationDS dc nss d
    when (not (null delegationDS) && null delegationDNSKEY) $ do
        lift . logLn Log.WARN . unwords $
            [ "fillsDNSSEC:"
            , show delegationZone ++ ":"
            , "DS is not null, and DNSKEY is null"
            ]
        lift . clogLn Log.DEMO (Just Red) $
            show delegationZone
                ++ ": verification error. dangling DS chain. DS exists, and DNSKEY does not exists"
        throwDnsError DNS.ServerFailure
    return filled

fillDelegationDS :: Int -> Delegation -> Delegation -> DNSQuery Delegation
fillDelegationDS dc src dest
    | null $ delegationDNSKEY src = return dest {- no DNSKEY, not chained -}
    | null $ delegationDS src = return dest {- no DS, not chained -}
    | not $ null $ delegationDS dest = return dest {- already filled -}
    | otherwise = do
        maybe query (lift . fill . toDSs)
            =<< lift (lookupCache (delegationZone dest) DS)
  where
    toDSs (rrs, _rank) = rrListWith DS DNS.fromRData (delegationZone dest) const rrs
    fill dss = return dest{delegationDS = dss}
    query = do
        ips <- delegationIPs dc src
        let nullIPs = logLn Log.WARN "fillDelegationDS: ip list is null" *> return dest
            domTraceMsg = show (delegationZone src) ++ " -> " ++ show (delegationZone dest)
            verifyFailed es = do
                lift (logLn Log.WARN $ "fillDelegationDS: " ++ es)
                throwDnsError DNS.ServerFailure
            result (e, vinfo) = do
                let traceLog (verifyColor, verifyMsg) =
                        lift . clogLn Log.DEMO (Just verifyColor) $
                            "fill delegation - " ++ verifyMsg ++ ": " ++ domTraceMsg
                maybe (pure ()) traceLog vinfo
                either verifyFailed fill e
        if null ips
            then lift nullIPs
            else result =<< queryDS (delegationDNSKEY src) ips (delegationZone dest)

queryDS
    :: [RD_DNSKEY]
    -> [IP]
    -> Domain
    -> DNSQuery (Either String [RD_DS], (Maybe (Color, String)))
queryDS dnskeys ips dom = do
    msg <- norec True ips dom DS
    withSection rankedAnswer msg $ \rrs rank -> do
        let (dsrds, dsRRs) = unzip $ rrListWith DS DNS.fromRData dom (,) rrs
            rrsigs = rrsigList dom DS rrs
        (rrset, cacheDS) <- lift $ verifyAndCache dnskeys dsRRs rrsigs rank
        let verifyResult
                | null dsrds = return (Right [], Nothing {- no DS, so no verify -})
                | rrsetVerified rrset =
                    lift cacheDS
                        *> return (Right dsrds, Just (Green, "verification success - RRSIG of DS"))
                | otherwise =
                    return
                        ( Left "queryDS: verification failed - RRSIG of DS"
                        , Just (Red, "verification failed - RRSIG of DS")
                        )
        verifyResult

-- Caching while retrieving delegation information from the authoritative server's reply
delegationWithCache
    :: Domain -> [RD_DNSKEY] -> Domain -> DNSMessage -> DNSQuery MayDelegation
delegationWithCache zoneDom dnskeys dom msg = do
    (verifyMsg, verifyColor, raiseOnFailure, dss, cacheDS) <- withSection rankedAuthority msg $ \rrs rank -> do
        let (dsrds, dsRRs) = unzip $ rrListWith DS DNS.fromRData dom (,) rrs
        (rrset, cacheDS) <-
            lift $ verifyAndCache dnskeys dsRRs (rrsigList dom DS rrs) rank
        let (verifyMsg, verifyColor, raiseOnFailure)
                | null nsps = ("no delegation", Nothing, pure ())
                | null dsrds = ("delegation - no DS, so no verify", Just Yellow, pure ())
                | rrsetVerified rrset =
                    ("delegation - verification success - RRSIG of DS", Just Green, pure ())
                | otherwise =
                    ( "delegation - verification failed - RRSIG of DS"
                    , Just Red
                    , throwDnsError DNS.ServerFailure
                    )
        return
            ( verifyMsg
            , verifyColor
            , raiseOnFailure
            , if rrsetVerified rrset then dsrds else []
            , cacheDS
            )

    let found x = do
            cacheDS
            cacheNS
            cacheAdds
            clogLn Log.DEMO Nothing $ ppDelegation (delegationNS x)
            return x

    lift . clogLn Log.DEMO verifyColor $
        "delegationWithCache: " ++ domTraceMsg ++ ", " ++ verifyMsg
    raiseOnFailure
    lift . maybe (pure NoDelegation) (fmap HasDelegation . found) $
        takeDelegationSrc nsps dss adds {- There is delegation information only when there is a selectable NS -}
  where
    domTraceMsg = show zoneDom ++ " -> " ++ show dom

    (nsps, cacheNS) = withSection rankedAuthority msg $ \rrs rank ->
        let nsps_ = nsList dom (,) rrs in (nsps_, cacheNoRRSIG (map snd nsps_) rank)

    (adds, cacheAdds) = withSection rankedAdditional msg $ \rrs rank ->
        let axs = filter match rrs in (axs, cacheSection axs rank)
      where
        match rr = rrtype rr `elem` [A, AAAA] && rrname rr `Set.member` nsSet
        nsSet = Set.fromList $ map fst nsps

-- If Nothing, it is a miss-hit against the cache.
-- If Just NoDelegation, cache hit but no delegation information.
lookupDelegation :: Domain -> ContextT IO (Maybe MayDelegation)
lookupDelegation dom = do
    disableV6NS <- asks disableV6NS_
    let lookupDEs ns = do
            let deListA =
                    rrListWith
                        A
                        (`DNS.rdataField` DNS.a_ipv4)
                        ns
                        (\v4 _ -> DEwithAx ns (IPv4 v4))
                deListAAAA =
                    rrListWith
                        AAAA
                        (`DNS.rdataField` DNS.aaaa_ipv6)
                        ns
                        (\v6 _ -> DEwithAx ns (IPv6 v6))

            lk4 <- fmap (deListA . fst) <$> lookupCache ns A
            lk6 <- fmap (deListAAAA . fst) <$> lookupCache ns AAAA
            return $ case lk4 <> lk6 of
                Nothing
                    | ns `DNS.isSubDomainOf` dom -> [] {- miss-hit with sub-domain case cause iterative loop, so return null to skip this NS -}
                    | otherwise -> [DEonlyNS ns {- the case both A and AAAA are miss-hit -}]
                Just as -> as {- just return address records. null case is wrong cache, so return null to skip this NS -}
        noCachedV4NS es = disableV6NS && null (v4DEntryList es)
        fromDEs es
            | noCachedV4NS es = Nothing
            {- all NS records for A are skipped under disableV6NS, so handle as miss-hit NS case -}
            | otherwise =
                (\des -> HasDelegation $ Delegation dom des [] []) <$> uncons es
        {- Nothing case, all NS records are skipped, so handle as miss-hit NS case -}
        getDelegation :: ([ResourceRecord], a) -> ContextT IO (Maybe MayDelegation)
        getDelegation (rrs, _) = do
            {- NS cache hit -}
            let nss = sort $ nsList dom const rrs
            case nss of
                [] -> return $ Just NoDelegation {- hit null NS list, so no delegation -}
                _ : _ -> fromDEs . concat <$> mapM lookupDEs nss

    maybe (return Nothing) getDelegation =<< lookupCache dom NS

v4DEntryList :: [DEntry] -> [DEntry]
v4DEntryList [] = []
v4DEntryList des@(de : _) = concatMap skipAAAA $ byNS des
  where
    byNS = groupBy ((==) `on` nsDomain)
    skipAAAA = nullCase . filter (not . aaaaDE)
      where
        aaaaDE (DEwithAx _ (IPv6{})) = True
        aaaaDE _ = False
        nullCase [] = [DEonlyNS (nsDomain de)]
        nullCase es@(_ : _) = es

nsDomain :: DEntry -> Domain
nsDomain (DEwithAx dom _) = dom
nsDomain (DEonlyNS dom) = dom