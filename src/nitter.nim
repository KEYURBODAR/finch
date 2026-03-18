# SPDX-License-Identifier: AGPL-3.0-only
import asyncdispatch, strformat, logging, strutils, uri, times
from net import Port
from htmlgen import a
from os import getEnv

import jester

import types, config, prefs, formatters, redis_cache, http_pool, auth, apiutils, local_data, local_identity
import views/[general, home]
import routes/[
  preferences, timeline, status, media, search, rss, list, debug, private_admin,
  unsupported, embed, resolver, router_utils, local]

const instancesUrl = "https://github.com/zedeus/nitter/wiki/Instances"
const issuesUrl = "https://github.com/zedeus/nitter/issues"

let
  configPath = getEnv("NITTER_CONF_FILE", "./nitter.conf")
  (cfg, fullCfg) = getConfig(configPath)

  sessionsPath = getEnv("NITTER_SESSIONS_FILE", "./sessions.jsonl")

proc productionMode(): bool =
  let value = getEnv("NITTER_ENV", getEnv("RAILWAY_ENVIRONMENT", "")).toLowerAscii
  value in ["production", "prod"] or getEnv("RAILWAY_ENVIRONMENT", "").len > 0

proc failStartup(message: string) =
  stdout.write "Startup validation failed: " & message & "\n"
  stdout.flushFile
  quit(1)

proc validateRuntime(cfg: Config) =
  if not productionMode():
    return
  if cfg.hmacKey.len < 32 or cfg.hmacKey == "secretkey":
    failStartup("set a strong NITTER_HMAC_KEY before running in production")
  if cfg.enableAdmin:
    failStartup("disable admin routes in production (set NITTER_ENABLE_ADMIN=false)")
  if not cfg.useHttps:
    failStartup("set NITTER_HTTPS=true for production")
  if cfg.hostname.len == 0 or cfg.hostname in ["127.0.0.1", "localhost", "nitter.net"]:
    failStartup("set NITTER_HOSTNAME to your public Railway/VPS hostname")

validateRuntime(cfg)

initSessionPool(cfg, sessionsPath)

if not cfg.enableDebug:
  # Silence Jester's query warning
  addHandler(newConsoleLogger())
  setLogFilter(lvlError)

stdout.write &"Starting Finch at {getUrlPrefix(cfg)}\n"
stdout.flushFile

updateDefaultPrefs(fullCfg)
setCacheTimes(cfg)
setHmacKey(cfg.hmacKey)
setProxyEncoding(cfg.base64Media)
setMaxHttpConns(cfg.httpMaxConns)
setHttpProxy(cfg.proxy, cfg.proxyAuth)
setApiProxy(cfg.apiProxy)
setDisableTid(cfg.disableTid)
setMaxConcurrentReqs(cfg.maxConcurrentReqs)
waitFor initRedisPool(cfg)
stdout.write &"Connected to Redis at {cfg.redisHost}:{cfg.redisPort}\n"
stdout.flushFile
initLocalData(cfg)

createUnsupportedRouter(cfg)
createResolverRouter(cfg)
createPrefRouter(cfg)
createLocalRouter(cfg)
createTimelineRouter(cfg)
createListRouter(cfg)
createStatusRouter(cfg)
createSearchRouter(cfg)
createMediaRouter(cfg)
createEmbedRouter(cfg)
createRssRouter(cfg)
createDebugRouter(cfg)
createPrivateAdminRouter(cfg)

settings:
  port = Port(cfg.port)
  staticDir = cfg.staticDir
  bindAddr = cfg.address
  reusePort = false

routes:
  before:
    # skip all file URLs
    cond "." notin request.path
    applyUrlPrefs()

  get "/go":
    let raw = @"q"
    if raw.len == 0:
      redirect("/")

    let q = raw.strip()
    if q.len == 0:
      redirect("/")
    if q.len > 500:
      resp Http400, showError("Search input too long.", cfg)

    let lower = q.toLowerAscii
    if lower in ["lists", "/lists"]:
      redirect("/f/lists")
    if lower in ["following", "/following"]:
      redirect("/f/following")

    if q.len == 27 and q.startsWith("fc_"):
      let hex = q[3 .. ^1]
      if hex.len == 24 and hex.allCharsInSet({'0'..'9', 'a'..'f', 'A'..'F'}):
        redirect("/f/lists/" & q)

    if q.startsWith("@"):
      let candidate = exactUserCandidate(q)
      if candidate.len > 0:
        redirect("/" & candidate)

    redirect("/search?f=tweets&q=" & encodeUrl(q))

  get "/":
    resp renderMain(
      renderHome(),
      request,
      cfg,
      requestPrefs(),
      desc="Search-first X reader for profiles, posts, operators, feeds, and private diagnostics.",
      ogTitle=cfg.title)

  get "/about":
    redirect("/")

  get "/explore":
    redirect("/")

  get "/help":
    redirect("/")

  get "/i/redirect":
    let url = decodeUrl(@"url")
    if url.len == 0: resp Http404
    redirect(replaceUrls(url, requestPrefs()))

  error Http404:
    resp Http404, showError("Page not found", cfg)

  error InternalError:
    echo error.exc.name, ": ", error.exc.msg
    resp Http500, showError(
      "An error occurred. Please open a GitHub issue with the URL you tried to visit.", cfg)

  error BadClientError:
    echo error.exc.name, ": ", error.exc.msg
    resp Http500, showError("Network error occurred, please try again.", cfg)

  error RateLimitError:
    const link = a("another instance", href = instancesUrl)
    let err = cast[ref RateLimitError](error.exc)
    let detail =
      if err.resetAt > 0:
        &"X endpoint <code>{err.endpoint}</code> is exhausted until {fromUnix(err.resetAt).utc.format(\"yyyy-MM-dd HH:mm 'UTC'\")}. Loaded sessions: {err.sessionTotal}."
      elif err.endpoint.len > 0:
        &"X endpoint <code>{err.endpoint}</code> is exhausted right now. Loaded sessions: {err.sessionTotal}."
      else:
        "Finch temporarily exhausted live X capacity for this route."
    resp Http429, showErrorHtml(
      &"Finch temporarily exhausted live capacity for this route.<br>{detail}<br>Use {link} or try again later.", cfg)

  error NoSessionsError:
    const link = a("another instance", href = instancesUrl)
    let err = cast[ref NoSessionsError](error.exc)
    let detail =
      if err.resetAt > 0:
        &"No healthy session is available for X endpoint <code>{err.endpoint}</code> until {fromUnix(err.resetAt).utc.format(\"yyyy-MM-dd HH:mm 'UTC'\")}. Loaded sessions: {err.sessionTotal}."
      elif err.endpoint.len > 0:
        &"No healthy session is available for X endpoint <code>{err.endpoint}</code> right now. Loaded sessions: {err.sessionTotal}."
      else:
        "Finch could not find a healthy X session for this request right now."
    resp Http429, showErrorHtml(
      &"Finch could not get a healthy session for this request right now.<br>{detail}<br>Use {link} or try again later.", cfg)

  extend rss, ""
  extend local, ""
  extend status, ""
  extend search, ""
  extend timeline, ""
  extend media, ""
  extend list, ""
  extend preferences, ""
  extend resolver, ""
  extend embed, ""
  extend debug, ""
  extend privateAdmin, ""
  extend unsupported, ""
