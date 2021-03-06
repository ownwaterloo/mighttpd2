{-# LANGUAGE OverloadedStrings, CPP #-}

module Single (single, mainLoop, closeService, ifRouteFileIsValid) where

import Config
import Route
import Control.Applicative
import Control.Concurrent
import Control.Exception
import Control.Monad
import qualified Data.ByteString.Char8 as BS
import Data.Conduit.Network
import Network
import Network.HTTP.Date
import Network.Wai.Application.Classic hiding ((</>), (+++))
import Network.Wai.Handler.Warp
import System.Date.Cache
import System.Exit
import System.Posix
import System.IO.Error (ioeGetErrorString)
#ifdef REV_PROXY
import qualified Network.HTTP.Conduit as H
#endif
#ifdef TLS
import Network.Wai.Handler.WarpTLS
#endif

import FileCGIApp
import FileCache
import Log
import Report
import Resource (setGroupUser)
import Signal
import State
import Types
import Utils

----------------------------------------------------------------

#ifdef REV_PROXY
type ConnPool = H.Manager
#else
type ConnPool = ()
#endif

----------------------------------------------------------------

single :: Option -> RouteDB -> Service -> Reporter -> Stater -> Logger -> IO ()
single opt route service rpt stt lgr = reportDo rpt $ do
    setGroupUser opt -- don't change the user of the master process
    ignoreSigChild
    getInfo <- fileCacheInit
    setHandler sigStop   stopHandler
    setHandler sigRetire retireHandler
    setHandler sigInfo   infoHandler
#ifdef REV_PROXY
    mgr <- H.newManager H.def { H.managerConnCount = 1024 -- FIXME
                              , H.managerResponseTimeout
                              = (/=0) `mfilter` Just (opt_proxy_timeout opt)
                                `mplus` H.managerResponseTimeout H.def
                              }
#else
    let mgr = ()
#endif
    setHandler sigReload (reloadHandler lgr getInfo mgr)
    report rpt "Worker Mighty started"
    reload opt route service rpt stt lgr getInfo mgr
  where
    stopHandler = Catch $ do
        report rpt "Worker Mighty finished"
        finReporter rpt
        finLogger lgr
        closeService service
        exitImmediately ExitSuccess
    retireHandler = Catch $ ifWarpThreadsAreActive stt $ do
        report rpt "Worker Mighty retiring"
        closeService service
        goRetiring stt
    reloadHandler lggr getInfo mgr = Catch $ ifWarpThreadsAreActive stt $
        ifRouteFileIsValid rpt opt $ \newroute -> do
            report rpt "Worker Mighty reloaded"
            void . forkIO $ reload opt newroute service rpt stt lggr getInfo mgr
    infoHandler = Catch $ do
        i <- bshow <$> getConnectionCounter stt
        status <- bshow <$> getServerStatus stt
        report rpt $ status +++ ": # of connections = " +++ i

ifRouteFileIsValid :: Reporter -> Option -> (RouteDB -> IO ()) -> IO ()
ifRouteFileIsValid rpt opt act = case opt_routing_file opt of
    Nothing    -> return ()
    Just rfile -> try (parseRoute rfile) >>= either reportError act
  where
    reportError = report rpt . BS.pack . ioeGetErrorString

----------------------------------------------------------------

reload :: Option -> RouteDB -> Service
       -> Reporter -> Stater -> Logger
       -> (Path -> IO FileInfo) -> ConnPool
       -> IO ()
reload opt route service rpt stt lgr getInfo _mgr = reportDo rpt $ do
    setMyWarpThreadId stt
    zdater <- initZoneDater
#ifdef REV_PROXY
    let app req = fileCgiApp (cspec zdater) filespec cgispec revproxyspec route req
#else
    let app req = fileCgiApp (cspec zdater) filespec cgispec route req
#endif
    case service of
        HttpOnly s  -> runSettingsSocket setting s app
#ifdef TLS
        HttpsOnly s -> runTLSSocket tlsSetting setting s app
        HttpAndHttps s1 s2 -> do
            tid <- forkIO $ runSettingsSocket setting s1 app
            addAnotherWarpThreadId stt tid
            runTLSSocket tlsSetting setting s2 app
#else
        _ -> error "never reach"
#endif
  where
    debug = opt_debug_mode opt
    setting = defaultSettings {
        settingsPort        = opt_port opt
      , settingsOnException = if debug then printStdout else warpHandler rpt
      , settingsOnOpen      = increment stt
      , settingsOnClose     = decrement stt
      , settingsTimeout     = opt_connection_timeout opt
      , settingsHost        = HostAny
      , settingsFdCacheDuration     = opt_fd_cache_duration opt
      , settingsResourceTPerRequest = False
      }
    serverName = BS.pack $ opt_server_name opt
    cspec zdater = ClassicAppSpec {
        softwareName = serverName
      , logger = apatcheLogger lgr
      , dater = zdater
      , statusFileDir = fromString $ opt_status_file_dir opt
      }
    filespec = FileAppSpec {
        indexFile = fromString $ opt_index_file opt
      , isHTML = \x -> ".html" `isSuffixOf` x || ".htm" `isSuffixOf` x
      , getFileInfo = getInfo
      }
    cgispec = CgiAppSpec {
        indexCgi = "index.cgi"
      }
    initZoneDater = fst <$> clockDateCacher DateCacheConf {
        getTime = epochTime
      , formatDate = return . formatHTTPDate . epochTimeToHTTPDate
      }
#ifdef REV_PROXY
    revproxyspec = RevProxyAppSpec {
        revProxyManager = _mgr
      }
#endif
#ifdef TLS
    tlsSetting = defaultTlsSettings {
        certFile = opt_tls_cert_file opt
      , keyFile  = opt_tls_key_file opt
      }
#endif

----------------------------------------------------------------

mainLoop :: Reporter -> Stater -> Logger -> IO ()
mainLoop rpt stt lgr = do
    threadDelay 1000000
    retiring <- isRetiring stt
    counter <- getConnectionCounter stt
    if retiring && counter == 0 then do
        report rpt "Worker Mighty retired"
        finReporter rpt
        finLogger lgr
        exitSuccess
      else
        mainLoop rpt stt lgr

----------------------------------------------------------------

closeService :: Service -> IO ()
closeService (HttpOnly s) = sClose s
closeService (HttpsOnly s) = sClose s
closeService (HttpAndHttps s1 s2) = sClose s1 >> sClose s2
