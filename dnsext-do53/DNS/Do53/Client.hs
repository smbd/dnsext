module DNS.Do53.Client (
  -- * Lookups returning each type
    lookupA
  , lookupAAAA
  , lookupMX
  , lookupAviaMX
  , lookupAAAAviaMX
  , lookupNS
  , lookupNSAuth
  , lookupTXT
  , lookupSOA
  , lookupPTR
  , lookupRDNS
  , lookupSRV
  -- * Lookups returning requested RData
  , lookup
  , lookupAuth
  , lookup'
  , lookupAuth'
  -- * Lookups returning DNS Messages
  , lookupRaw
  -- * Configuration for sutf resolver
  , ResolvConf
  , defaultResolvConf
  , withResolvConf
  , LookupEnv
  -- ** Accessors
  , resolvInfo
  , resolvTimeout
  , resolvRetry
  , resolvConcurrent
  , resolvCacheConf
  , resolvQueryControls
  -- ** Specifying DNS servers
  , FileOrNumericHost(..)
  -- ** Configuring cache
  , CacheConf
  , defaultCacheConf
  , maximumTTL
  , pruningDelay
  -- * Query control
  , QueryControls
  , FlagOp(..)
  , rdFlag
  , adFlag
  , cdFlag
  , doFlag
  , ednsEnabled
  , ednsSetVersion
  , ednsSetUdpSize
  , ednsSetOptions
  , ODataOp(..)
  , encodeQuery
  ) where

import Prelude hiding (lookup)

import DNS.Do53.Lookup
import DNS.Do53.LookupX
import DNS.Do53.Query
import DNS.Do53.Types
