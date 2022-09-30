module DNS.Types (
  -- * DNS message
    DNSMessage(..)
  , defaultQuery
  , defaultResponse
  -- ** Header
  , DNSHeader(..)
  , Identifier
  , DNSFlags(..)
  , QorR(..)
  -- ** EDNS header
  , EDNSheader(..)
  , EDNS(..)
  , defaultEDNS
  , minUdpSize
  , maxUdpSize
  -- * Resource record
  , ResourceRecord(..)
  , CLASS
  , classIN
  , TTL
  -- ** Sections
  , Question(..)
  , Answers
  , AuthorityRecords
  , AdditionalRecords
  -- * Resource data
  -- ** Types
  , RData
  , fromRData
  , toRData
  , rdataType
  -- ** Class
  , ResourceData
  -- ** Basic resource data
  -- *** A RR
  , RD_A
  , rd_a
  , a_ipv4
  -- *** NS RR
  , RD_NS
  , rd_ns
  , ns_domain
  -- *** CNAME RR
  , RD_CNAME
  , rd_cname
  , cname_domain
  -- *** SOA RR
  , RD_SOA
  , rd_soa
  , soa_mname
  , soa_rname
  , soa_serial
  , soa_refresh
  , soa_retry
  , soa_expire
  , soa_minimum
  -- *** NULL RR
  , RD_NULL
  , rd_null
  , null_opaque
  -- *** PTR RR
  , RD_PTR
  , rd_ptr
  , ptr_domain
  -- *** MX RR
  , RD_MX
  , rd_mx
  , mx_preference
  , mx_exchange
  -- *** TXT RR
  , RD_TXT
  , rd_txt
  , txt_opaque
  -- *** RP RR
  , RD_RP(..)
  , rd_rp
  -- *** AAAA RR
  , RD_AAAA(..)
  , rd_aaaa
  -- *** SRV RR
  , RD_SRV(..)
  , rd_srv
  -- *** DNAME RR
  , RD_DNAME(..)
  , rd_dname
  -- *** OPT RR
  , RD_OPT(..)
  , rd_opt
  -- *** TLSA RR
  , RD_TLSA(..)
  , rd_tlsa
  -- ** DNSSEC resource data
  , RD_RRSIG(..)
  , rd_rrsig
  , RD_DS(..)
  , rd_ds
  , RD_NSEC(..)
  , rd_nsec
  , RD_DNSKEY(..)
  , rd_dnskey
  , RD_NSEC3(..)
  , rd_nsec3
  , RD_NSEC3PARAM(..)
  , rd_nsec3param
  , RD_CDS(..)
  , rd_cds
  , RD_CDNSKEY(..)
  , rd_cdnskey
  -- * OPT resource data
  , OData(..)
  , odataToOptCode
  -- ** OptCode
  , OptCode (
    NSID
  , DAU
  , DHU
  , N3U
  , ClientSubnet
  )
  , fromOptCode
  , toOptCode
  -- ** OptData
  , OptData
  , fromOData
  , toOData
  -- ** Optional data
  , OD_NSID(..)
  , od_nsid
  , OD_DAU(..)
  , od_dau
  , OD_DHU(..)
  , od_dhu
  , OD_N3U(..)
  , od_n3u
  , OD_ClientSubnet(..)
  , od_clientSubnet
  , od_ecsGeneric
  , od_unknown
  -- * Basic types
  -- ** Domain
  , Domain
  , domainToByteString
  , byteStringToDomain
  , domainToText
  , textToDomain
  -- ** Mailbox
  , Mailbox
  , mailboxToByteString
  , byteStringToMailbox
  , mailboxToText
  , textToMailbox
  -- ** Opaque
  , Opaque
  , opaqueToByteString
  , byteStringToOpaque
  , opaqueToShortByteString
  , shortByteStringToOpaque
  -- ** TYPE
  , TYPE (
    A
  , NS
  , CNAME
  , SOA
  , NULL
  , PTR
  , MX
  , TXT
  , RP
  , AAAA
  , SRV
  , DNAME
  , OPT
  , DS
  , RRSIG
  , NSEC
  , DNSKEY
  , NSEC3
  , NSEC3PARAM
  , TLSA
  , CDS
  , CDNSKEY
  , CSYNC
  , AXFR
  , ANY
  , CAA
  )
  , fromTYPE
  , toTYPE
  -- ** OPCODE
  , OPCODE(
    OP_STD
  , OP_INV
  , OP_SSR
  , OP_NOTIFY
  , OP_UPDATE
  )
  -- ** RCODE
  , RCODE(
    NoErr
  , FormatErr
  , ServFail
  , NameErr
  , NotImpl
  , Refused
  , YXDomain
  , YXRRSet
  , NXRRSet
  , NotAuth
  , NotZone
  , BadVers
  , BadKey
  , BadTime
  , BadMode
  , BadName
  , BadAlg
  , BadTrunc
  , BadCookie
  )
  , fromRCODE
  , toRCODE
  -- ** Errors
  , DNSError(..)
  ) where

import DNS.Types.Domain
import DNS.Types.EDNS
import DNS.Types.Error
import DNS.Types.Message
import DNS.Types.Opaque
import DNS.Types.RData
import DNS.Types.Sec
import DNS.Types.Type
