{-# LANGUAGE OverloadedStrings #-}

module FileCGIApp (fileCgiApp) where

import Control.Monad.IO.Class (liftIO)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BS
import Network.HTTP.Types
import Network.Wai
import Network.Wai.Application.Classic
import Types

data Perhaps a = Found a | Redirect | Fail

-- fileCgiApp :: ClassicAppSpec -> FileAppSpec -> CgiAppSpec -> RevProxyAppSpec -> RouteDB -> Application
fileCgiApp :: ClassicAppSpec -> FileAppSpec -> CgiAppSpec -> RouteDB -> Application
fileCgiApp cspec filespec cgispec um req = case mmp of
    Fail -> do
        let st = preconditionFailed412
        liftIO $ logger cspec req st Nothing
        fastResponse st defaultHeader "Precondition Failed\r\n"
    Redirect -> do
        let st = movedPermanently301
            hdr = defaultHeader ++ redirectHeader req
        liftIO $ logger cspec req st Nothing
        fastResponse st hdr "Moved Permanently\r\n"
    Found (RouteFile  src dst) ->
        fileApp cspec filespec (FileRoute src dst) req
    Found (RouteRedirect src dst) ->
        redirectApp cspec (RedirectRoute src dst) req
    Found (RouteCGI   src dst) ->
        cgiApp cspec cgispec (CgiRoute src dst) req
  where
    mmp = case getBlock (serverName req) um of
        Nothing  -> Fail
        Just blk -> getRoute (rawPathInfo req) blk
    fastResponse st hdr body = return $ responseLBS st hdr body
    defaultHeader = [("Content-Type", "text/plain")
                    ,("Server", softwareName cspec)]

getBlock :: ByteString -> RouteDB -> Maybe [Route]
getBlock _ [] = Nothing
getBlock key (Block doms maps : ms)
  | "*" `elem` doms = Just maps
  | key `elem` doms = Just maps
  | otherwise       = getBlock key ms

getRoute :: ByteString -> [Route] -> Perhaps Route
getRoute _ []                = Fail
getRoute key (m:ms)
  | src `isPrefixOf` key     = Found m
  | src `isMountPointOf` key = Redirect
  | otherwise                = getRoute key ms
  where
    src = routeSource m

routeSource :: Route -> Src
routeSource (RouteFile     src _)     = src
routeSource (RouteRedirect src _)     = src
routeSource (RouteCGI      src _)     = src
routeSource (RouteRevProxy src _ _ _) = src

isPrefixOf :: Path -> ByteString -> Bool
isPrefixOf src key = src' `BS.isPrefixOf` key
  where
    src' = pathByteString src

isMountPointOf :: Path -> ByteString -> Bool
isMountPointOf src key = hasTrailingPathSeparator src
                      && BS.length src' - BS.length key == 1
                      && key `BS.isPrefixOf` src'
  where
    src' = pathByteString src
