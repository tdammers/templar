{-#LANGUAGE NoImplicitPrelude #-}
{-#LANGUAGE OverloadedStrings #-}
{-#LANGUAGE OverloadedLists #-}
{-#LANGUAGE TemplateHaskell #-}
{-#LANGUAGE LambdaCase #-}
{-#LANGUAGE ScopedTypeVariables #-}
module Web.Templar.ServerConfig
where

import ClassyPrelude
import Web.Templar.Rule
import Data.Aeson as JSON
import Data.Aeson.TH
import qualified Data.Yaml as YAML
import Web.Templar.Backends
import Data.Default
import System.FilePath.Glob (glob)
import System.Environment (getEnv, lookupEnv)
import Control.MaybeEitherMonad (maybeFail)
import System.Directory (doesFileExist)

data BackendCacheConfig =
    FilesystemCache FilePath |
    MemCache
    deriving (Show)

instance FromJSON BackendCacheConfig where
    parseJSON (String str) = maybeFail $ backendCacheConfigFromString str
    parseJSON (Object obj) = do
        (obj .: "type") >>= \case
            "file" -> FilesystemCache <$> (obj .:? "dir" .!= ".cache")
            "mem" -> return MemCache
            x -> fail $ "Invalid backend cache type: '" <> x
    parseJSON x = fail $ "Invalid backend cache specification: " <> show x

backendCacheConfigFromString :: Text -> Maybe BackendCacheConfig
backendCacheConfigFromString str = do
    case splitSeq ":" str of
        ["file", dir] -> return $ FilesystemCache (unpack dir)
        ["file"] -> return $ FilesystemCache ".cache"
        ["mem"] -> return MemCache
        xs -> Nothing

data ServerDriver = WarpDriver Int
                  | CGIDriver
                  | SCGIDriver
                  | FastCGIDriver
                  | DefaultDriver
    deriving (Show, Read, Eq)

instance Default ServerDriver where
    def = DefaultDriver

instance FromJSON ServerDriver where
    parseJSON (String "warp") =
        return $ WarpDriver 5000
    parseJSON (String "cgi") =
        return $ CGIDriver
    parseJSON (String "fastcgi") =
        return $ FastCGIDriver
    parseJSON (String "fcgi") =
        return $ FastCGIDriver
    parseJSON (String "scgi") =
        return $ SCGIDriver
    parseJSON (String "default") =
        return def
    parseJSON (Object o) = do
        st :: Text <- o .: "type"
        case st of
            "warp" -> do
                port <- fromMaybe 5000 <$> o .:? "port"
                return $ WarpDriver port
            "cgi" -> return CGIDriver
            "fcgi" -> return FastCGIDriver
            "fastcgi" -> return FastCGIDriver
            "scgi" -> return SCGIDriver

data ServerConfig =
    ServerConfig
        { scBackendCache :: [BackendCacheConfig]
        , scDriver :: ServerDriver
        }
        deriving (Show)

instance Default ServerConfig where
    def = ServerConfig
            { scBackendCache = def
            , scDriver = def
            }

instance Monoid ServerConfig where
    mempty = def
    mappend = scAppend

instance FromJSON ServerConfig where
    parseJSON (Object obj) = do
        caches <- fromMaybe []
                    <$> ( obj .:? "backend-cache"
                          <|> (fmap (:[]) <$> obj .:? "backend-cache")
                        )
        driver <- fromMaybe def
                    <$> ( obj .:? "driver" )
        return $ ServerConfig
            { scBackendCache = caches
            , scDriver = driver
            }

scAppend :: ServerConfig -> ServerConfig -> ServerConfig
scAppend a b =
    ServerConfig
        { scBackendCache =
            firstNonNull (scBackendCache b) (scBackendCache a)
        , scDriver =
            if scDriver b == DefaultDriver
                then scDriver a
                else scDriver b
        }

firstNonNull :: [a] -> [a] -> [a]
firstNonNull [] xs = xs
firstNonNull xs _ = xs

loadServerConfigFile :: FilePath -> IO ServerConfig
loadServerConfigFile fn = do
    hPutStrLn stderr $ "Loading: " <> fn
    YAML.decodeFileEither fn >>=
        either
            (fail . show)
            return

loadServerConfig :: FilePath -> IO ServerConfig
loadServerConfig dir = do
    hPutStrLn stderr $ "loadServerConfig " ++ dir
    homeDirMay <- lookupEnv "HOME"
    let systemGlobalFilename = "/etc/templar/server.yml"
        globalFilename = "/usr/local/etc/templar/server.yml"
        userFilenameMay = (</> ".config" </> "templar" </> "server.yml") <$> homeDirMay
        localFilename = dir </> "config" </> "server.yml"
        serverConfigFilename = dir </> "server.yml"
    let filenames' = catMaybes
            [ Just systemGlobalFilename
            , Just globalFilename
            , userFilenameMay
            , Just localFilename
            , Just serverConfigFilename
            ]
    filenames <- filterM doesFileExist filenames'
    hPutStrLn stderr $ show filenames
    mconcat <$> forM filenames loadServerConfigFile