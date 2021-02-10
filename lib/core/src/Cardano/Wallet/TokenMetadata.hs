{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE ViewPatterns #-}

module Cardano.Wallet.TokenMetadata
    (
    -- * Convenience
      fillMetadata

    -- * Token Metadata Client
    , TokenMetadataClient
    , newMetadataClient
    , getTokenMetadata

    -- * Logging
    , TokenMetadataLog (..)

    -- * Generic metadata server client
    , metadataClient
    , BatchRequest (..)
    , BatchResponse (..)
    , SubjectProperties (..)
    , Property (..)
    , PropertyValue
    , Subject (..)
    , Signature (..)

    -- * Parsing
    , metadataFromProperties
    ) where

import Prelude

import Cardano.BM.Data.Severity
    ( Severity (..) )
import Cardano.BM.Data.Tracer
    ( HasPrivacyAnnotation, HasSeverityAnnotation (..) )
import Cardano.Wallet.Logging
    ( BracketLog (..), LoggedException (..), bracketTracer, produceTimings )
import Cardano.Wallet.Primitive.Types
    ( TokenMetadataServer (..) )
import Cardano.Wallet.Primitive.Types.Hash
    ( Hash (..) )
import Cardano.Wallet.Primitive.Types.TokenMap
    ( AssetId (..) )
import Cardano.Wallet.Primitive.Types.TokenPolicy
    ( AssetMetadata (..), TokenPolicyId (..) )
import Control.Monad
    ( when )
import Control.Tracer
    ( Tracer, contramap, traceWith )
import Data.Aeson
    ( FromJSON (..)
    , ToJSON (..)
    , Value (..)
    , eitherDecodeStrict'
    , encode
    , withObject
    , withText
    , (.:)
    )
import Data.Bifunctor
    ( first )
import Data.ByteArray.Encoding
    ( Base (Base16), convertFromBase, convertToBase )
import Data.ByteString
    ( ByteString )
import Data.Foldable
    ( toList )
import Data.Functor
    ( ($>) )
import Data.Hashable
    ( Hashable )
import Data.Maybe
    ( mapMaybe )
import Data.String
    ( IsString (..) )
import Data.Text
    ( Text )
import Data.Text.Class
    ( ToText (..) )
import Data.Time.Clock
    ( DiffTime )
import GHC.Generics
    ( Generic )
import GHC.TypeLits
    ( Symbol )
import Network.HTTP.Client
    ( HttpException
    , Manager
    , Request (..)
    , RequestBody (..)
    , Response (..)
    , brReadSome
    , requestFromURI
    , setRequestCheckStatus
    , withResponse
    )
import Network.HTTP.Client.TLS
    ( newTlsManager )
import Network.URI
    ( URI, relativeTo )
import Network.URI.Static
    ( relativeReference )
import Numeric.Natural
    ( Natural )
import UnliftIO.Exception
    ( SomeException, handle, handleAny )

import qualified Data.ByteString.Char8 as B8
import qualified Data.ByteString.Lazy as BL
import qualified Data.HashMap.Strict as HM
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Text.Encoding.Error as T

{-------------------------------------------------------------------------------
                                 Token Metadata
-------------------------------------------------------------------------------}

-- | Helper for adding metadata to sets of assets.
fillMetadata
    :: (Foldable t, Functor t)
    => TokenMetadataClient IO
    -> t AssetId
    -> (Maybe AssetMetadata -> AssetId -> a)
    -> IO (t a)
fillMetadata client assets f = do
    res <- getTokenMetadata client (toList assets)
    case res of
        Right (Map.fromList -> m) ->
            return $ fmap (\aid -> f (Map.lookup aid m) aid) assets
        Left _e -> do
            -- TODO: Trace error?
            return $ fmap (f Nothing) assets

{-------------------------------------------------------------------------------
                            Cardano Metadata Server
-------------------------------------------------------------------------------}

-- | Models a request to the @POST /metadata/query@ endpoint of the metadata
-- server -- the only one that we need.
data BatchRequest = BatchRequest
    { subjects :: [Subject]
    , properties :: [PropertyName]
    } deriving (Generic, Show, Eq)

-- | Models the response from the @POST /metadata/query@ endpoint of the
-- metadata server. This should contain properties each subject in the
-- 'BatchRequest'.
newtype BatchResponse = BatchResponse
    { getBatchResponse :: [SubjectProperties]
    } deriving (Generic, Show, Eq)

-- | Property values and signatures for a given subject.
data SubjectProperties = SubjectProperties
    { subject :: Subject
    , owner :: Signature
    -- TODO: use Data.SOP.NP and parameterize type by property names
    , properties :: ( Property "name"
                    -- , (PropertyValue "acronym", [Signature])
                    , Property "description"
                    -- , (PropertyValue "url", [Signature])
                    -- , (PropertyValue "logo", [Signature])
                    -- , (PropertyValue "unit", [Signature])
                    )
    } deriving (Generic, Show, Eq)

-- | A property value and its signatures.
data Property name = Property
    { value :: PropertyValue name
    , signatures :: [Signature]
    } deriving (Generic)

deriving instance Show (PropertyValue name) => Show (Property name)
deriving instance Eq (PropertyValue name) => Eq (Property name)

-- | A metadata server subject, which can be any string.
newtype Subject = Subject { unSubject :: Text }
    deriving (Generic, Show, Eq, Ord)
    deriving newtype (IsString, Hashable)

-- | Metadata property identifier.
newtype PropertyName = PropertyName { unPropertyName :: Text }
    deriving (Generic, Show, Eq)
    deriving newtype IsString

-- | The type of a given property name.
type family PropertyValue (name :: Symbol) :: *
type instance PropertyValue "name" = Text
type instance PropertyValue "acronym" = Text
type instance PropertyValue "description" = Text
type instance PropertyValue "url" = Text
-- type instance PropertyValue "logo" = AssetLogoBase64
type instance PropertyValue "unit" = AssetUnit

-- | Specification of a larger unit for an asset. For example, the "lovelace"
-- asset has the larger unit "ada" with 6 zeroes.
data AssetUnit = AssetUnit
    { name :: Text -- ^ Name of the larger asset.
    , decimals :: Natural  -- ^ Number of zeroes to add to base unit.
    } deriving (Generic, Show, Eq)

-- | Will be used in future for checking integrity and authenticity of metadata.
data Signature = Signature
    { signature :: ByteString
    , publicKey :: ByteString
    } deriving (Generic, Show, Eq)

{-------------------------------------------------------------------------------
                       Client for Cardano metadata-server
-------------------------------------------------------------------------------}

metadataClient
    :: Tracer IO TokenMetadataLog
    -> TokenMetadataServer
    -> Manager
    -> BatchRequest
    -> IO (Either TokenMetadataError BatchResponse)
metadataClient tr (TokenMetadataServer baseURI) manager batch = do
    res <- handleExc $ fmap parseResponse . doRequest =<< makeHttpReq batch
    traceWith tr $ MsgFetchResult batch res
    return res
  where
    -- Construct a Request from the batch.
    makeHttpReq query = do
        let json = encode query
            uri = endpoint `relativeTo` baseURI
        traceWith tr $ MsgFetchRequestBody uri json
        req <- requestFromURI uri
        pure $ setRequestCheckStatus req
            { method = "POST"
            , requestBody = RequestBodyLBS json
            , requestHeaders = [("Content-type", "application/json")]
            }
    endpoint = [relativeReference|metadata/query|]

    -- Read the request body. Status code has already been checked via
    -- 'setRequestStatus'.
    doRequest req = bracketTracer (contramap (MsgFetchRequest batch) tr) $ do
        withResponse req manager $ \res -> do
            bs <- brReadSome (responseBody res) maxResponseSize
            when (BL.length bs >= fromIntegral maxResponseSize) $
                traceWith tr (MsgFetchMetadataMaxSize maxResponseSize)
            pure $ BL.toStrict bs

    -- decode and parse json
    parseResponse bs =
        first (TokenMetadataJSONParseError bs) (eitherDecodeStrict' bs)

    -- Convert http-client exceptions to Left, handle any other synchronous
    -- exceptions that may occur.
    handleExc = handle (loggedErr TokenMetadataFetchError)
        . handleAny (loggedErr TokenMetadataClientError)
    loggedErr c = pure . Left . c . LoggedException

    -- Don't let a metadata server consume all our memory - limit to 10MiB
    maxResponseSize = 10*1024*1024

-----------
-- Errors

-- | The possible errors which can occur when fetching metadata.
data TokenMetadataError
    = TokenMetadataClientError (LoggedException SomeException)
        -- ^ Unhandled exception
    | TokenMetadataFetchError (LoggedException HttpException)
        -- ^ Error with HTTP request
    | TokenMetadataJSONParseError ByteString String
        -- ^ Error from aeson decoding of JSON
    deriving (Generic, Show, Eq)

instance ToText TokenMetadataError where
    toText = \case
        TokenMetadataClientError e ->
             "Unhandled exception: " <> toText e
        TokenMetadataFetchError e ->
             "Error querying metadata server: " <> toText e
        TokenMetadataJSONParseError json e -> mconcat
            [ "Error parsing metadata server response JSON: "
            , T.pack e
            , "\nThe first 250 characters of the response are:\n"
            , T.decodeUtf8With T.lenientDecode $ B8.take 250 json
            ]

-----------
-- Logging

data TokenMetadataLog
    = MsgNotConfigured
    | MsgFetchRequest BatchRequest BracketLog
    | MsgFetchRequestBody URI BL.ByteString
    | MsgFetchMetadataMaxSize Int
    | MsgFetchResult BatchRequest (Either TokenMetadataError BatchResponse)
    | MsgFetchMetadataTime BatchRequest DiffTime
    deriving (Show, Eq)

instance HasSeverityAnnotation TokenMetadataLog where
    getSeverityAnnotation = \case
        MsgNotConfigured -> Notice
        MsgFetchRequest _ b -> getSeverityAnnotation b
        MsgFetchRequestBody _ _ -> Debug
        MsgFetchMetadataMaxSize _ -> Warning
        MsgFetchResult _ (Right _) -> Info
        MsgFetchResult _ (Left _) -> Error
        MsgFetchMetadataTime _ _ -> Debug

instance ToText TokenMetadataLog where
    toText = \case
        MsgNotConfigured -> mconcat
            [ "No token metadata server is configured."
            ]
        MsgFetchRequest r BracketStart -> mconcat
            [ "Will fetch metadata: "
            , T.pack (show r)
            ]
        MsgFetchRequest _ b -> mconcat
            [ "Metadata fetch: "
            , toText b
            ]
        MsgFetchMetadataMaxSize max -> mconcat
            [ "Metadata server returned more data than the permitted maximum of"
            , toText max
            , " bytes."
            ]
        MsgFetchResult req res -> case res of
            Right (BatchResponse batch) -> mconcat
                [ "Successfully queried metadata-server for "
                , toText (length $ subjects req)
                , " assets, and received "
                , toText (length batch)
                , "."
                ]
            Left e -> mconcat
                [ "An error occurred while fetching metadata: "
                , toText e
                ]
        MsgFetchMetadataTime _ dt -> mconcat
            [ "Metadata request took: "
            , T.pack (show dt)
            ]

instance HasPrivacyAnnotation TokenMetadataLog

traceRequestTimings :: Tracer IO TokenMetadataLog -> IO (Tracer IO TokenMetadataLog)
traceRequestTimings tr = produceTimings msgQuery trDiffTime
  where
    trDiffTime = contramap (uncurry MsgFetchMetadataTime) tr
    msgQuery = \case
        MsgFetchRequest req b -> Just (req, b)
        _ -> Nothing

{-------------------------------------------------------------------------------
                           Requesting token metadata
-------------------------------------------------------------------------------}

-- | Represents a client for the metadata server.
newtype TokenMetadataClient m = TokenMetadataClient
    { _batchQuery :: BatchRequest -> m (Either TokenMetadataError BatchResponse)
    }

-- | Not a client for the metadata server.
nullTokenMetadataClient :: Applicative m => TokenMetadataClient m
nullTokenMetadataClient = TokenMetadataClient $ \_ ->
    pure . Right $ BatchResponse []

-- | Construct a 'TokenMetadataClient' for use with 'getTokenMetadata'.
newMetadataClient
    :: Tracer IO TokenMetadataLog -- ^ Logging
    -> Maybe TokenMetadataServer -- ^ URL of metadata server, if enabled.
    -> IO (TokenMetadataClient IO)
newMetadataClient tr (Just uri) = do
    trTimings <- traceRequestTimings tr
    TokenMetadataClient . metadataClient (tr <> trTimings) uri <$> newTlsManager
newMetadataClient tr Nothing =
    traceWith tr MsgNotConfigured $> nullTokenMetadataClient

-- | Fetches metadata for a list of assets using the given client.
getTokenMetadata
    :: TokenMetadataClient IO
    -> [AssetId]
    -> IO (Either TokenMetadataError [(AssetId, AssetMetadata)])
getTokenMetadata (TokenMetadataClient client) as =
    fmap fromResponse <$> client req
  where
    subjects = map assetIdToSubject as
    req = BatchRequest
        { subjects
        , properties = [PropertyName "name", PropertyName "description"]
        }
    subjectAsset = HM.fromList $ zip subjects as
    fromResponse :: BatchResponse -> [(AssetId, AssetMetadata)]
    fromResponse = mapMaybe (\ps -> (,)
        <$> HM.lookup (subject ps) subjectAsset
        <*> pure (metadataFromProperties ps))
        . getBatchResponse

-- | Creates a metadata server subject from an AssetId. The subject is the
-- policy id.
--
-- FIXME: Not oficially decided.
assetIdToSubject :: AssetId -> Subject
assetIdToSubject (AssetId (UnsafeTokenPolicyId (Hash p)) _) =
    Subject $ T.decodeLatin1 $ convertToBase Base16 p

-- | Convert metadata server properties response into an 'AssetMetadata' record.
-- Only the values are taken. Signatures are ignored (for now).
metadataFromProperties :: SubjectProperties -> AssetMetadata
metadataFromProperties (SubjectProperties _ _ ((Property n _, Property d _))) =
    AssetMetadata n d

{-------------------------------------------------------------------------------
                      Aeson instances for metadata-server
-------------------------------------------------------------------------------}

instance ToJSON BatchRequest where

instance ToJSON PropertyName where
    toJSON = String . unPropertyName
instance FromJSON PropertyName where
    parseJSON = withText "PropertyName" (pure . PropertyName)

instance FromJSON BatchResponse where
    parseJSON =  withObject "BatchResponse" $ \o ->
        BatchResponse <$> o .: "subjects"

instance ToJSON Subject where
    toJSON = String . unSubject
instance FromJSON Subject where
    parseJSON = withText "Subject" (pure . Subject)

instance FromJSON SubjectProperties where
   parseJSON = withObject "SubjectProperties" $ \o -> SubjectProperties
       <$> o .: "subject"
       <*> o .: "owner"
       <*> ((,) <$> o .: "name" <*> o .: "description")

instance FromJSON (PropertyValue name) => FromJSON (Property name) where
    parseJSON = withObject "Property" $ \o -> Property
        <$> o .: "value"
        <*> o .: "anSignatures"

instance FromJSON Signature where
    parseJSON = withObject "Signature" $ \o -> Signature
        <$> fmap unHex (o .: "signature")
        <*> fmap unHex (o .: "publicKey")

newtype Hex = Hex { unHex :: ByteString } deriving (Generic, Show, Eq)

instance FromJSON Hex where
    parseJSON = withText "hex bytestring" $
        either fail (pure . Hex) . convertFromBase Base16 . T.encodeUtf8

instance FromJSON AssetUnit where
    -- TODO: AssetUnit, when it's provided by the metadata server
