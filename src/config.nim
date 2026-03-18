# SPDX-License-Identifier: AGPL-3.0-only
import parsecfg except Config
import os, types, strutils

proc getEnvString(name, default: string): string =
  let value = getEnv(name)
  if value.len > 0: value else: default

proc getEnvBool(name: string; default: bool): bool =
  let value = getEnv(name)
  if value.len == 0:
    return default
  try:
    return parseBool(value)
  except ValueError:
    return default

proc getEnvInt(name: string; default: int): int =
  let value = getEnv(name)
  if value.len == 0:
    return default
  try:
    return parseInt(value)
  except ValueError:
    return default

proc get*[T](config: parseCfg.Config; section, key: string; default: T): T =
  let val = config.getSectionValue(section, key)
  if val.len == 0: return default

  when T is int: parseInt(val)
  elif T is bool: parseBool(val)
  elif T is string: val

proc getConfig*(path: string): (Config, parseCfg.Config) =
  var cfg = loadConfig(path)

  let masterRss = cfg.get("Config", "enableRSS", true)

  let conf = Config(
    # Server
    address: getEnvString("NITTER_ADDRESS", cfg.get("Server", "address", "0.0.0.0")),
    port: getEnvInt("PORT", getEnvInt("NITTER_PORT", cfg.get("Server", "port", 8080))),
    useHttps: getEnvBool("NITTER_HTTPS", cfg.get("Server", "https", true)),
    httpMaxConns: getEnvInt("NITTER_HTTP_MAX_CONNECTIONS", cfg.get("Server", "httpMaxConnections", 100)),
    staticDir: getEnvString("NITTER_STATIC_DIR", cfg.get("Server", "staticDir", "./public")),
    title: getEnvString("NITTER_TITLE", cfg.get("Server", "title", "Finch")),
    hostname: getEnvString("NITTER_HOSTNAME", cfg.get("Server", "hostname", "nitter.net")),

    # Cache
    listCacheTime: getEnvInt("NITTER_LIST_CACHE_MINUTES", cfg.get("Cache", "listMinutes", 120)),
    rssCacheTime: getEnvInt("NITTER_RSS_CACHE_MINUTES", cfg.get("Cache", "rssMinutes", 10)),

    redisHost: getEnvString("NITTER_REDIS_HOST", cfg.get("Cache", "redisHost", "localhost")),
    redisPort: getEnvInt("NITTER_REDIS_PORT", cfg.get("Cache", "redisPort", 6379)),
    redisConns: getEnvInt("NITTER_REDIS_CONNECTIONS", cfg.get("Cache", "redisConnections", 20)),
    redisMaxConns: getEnvInt("NITTER_REDIS_MAX_CONNECTIONS", cfg.get("Cache", "redisMaxConnections", 30)),
    redisPassword: getEnvString("NITTER_REDIS_PASSWORD", cfg.get("Cache", "redisPassword", "")),

    # Config
    hmacKey: getEnvString("NITTER_HMAC_KEY", cfg.get("Config", "hmacKey", "secretkey")),
    base64Media: getEnvBool("NITTER_BASE64_MEDIA", cfg.get("Config", "base64Media", false)),
    minTokens: getEnvInt("NITTER_TOKEN_COUNT", cfg.get("Config", "tokenCount", 10)),
    enableRSSUserTweets: masterRss and getEnvBool("NITTER_ENABLE_RSS_USER_TWEETS", cfg.get("Config", "enableRSSUserTweets", true)),
    enableRSSUserReplies: masterRss and getEnvBool("NITTER_ENABLE_RSS_USER_REPLIES", cfg.get("Config", "enableRSSUserReplies", true)),
    enableRSSUserMedia: masterRss and getEnvBool("NITTER_ENABLE_RSS_USER_MEDIA", cfg.get("Config", "enableRSSUserMedia", true)),
    enableRSSSearch: masterRss and getEnvBool("NITTER_ENABLE_RSS_SEARCH", cfg.get("Config", "enableRSSSearch", true)),
    enableRSSList: masterRss and getEnvBool("NITTER_ENABLE_RSS_LIST", cfg.get("Config", "enableRSSList", true)),
    enableAdmin: getEnvBool("NITTER_ENABLE_ADMIN", cfg.get("Config", "enableAdmin", false)),
    enableDebug: getEnvBool("NITTER_ENABLE_DEBUG", cfg.get("Config", "enableDebug", false)),
    proxy: getEnvString("NITTER_PROXY", cfg.get("Config", "proxy", "")),
    proxyAuth: getEnvString("NITTER_PROXY_AUTH", cfg.get("Config", "proxyAuth", "")),
    apiProxy: getEnvString("NITTER_API_PROXY", cfg.get("Config", "apiProxy", "")),
    disableTid: getEnvBool("NITTER_DISABLE_TID", cfg.get("Config", "disableTid", false)),
    maxConcurrentReqs: getEnvInt("NITTER_MAX_CONCURRENT_REQS", cfg.get("Config", "maxConcurrentReqs", 2)),
    localDataPath: getEnvString("NITTER_LOCAL_DATA_PATH", cfg.get("Config", "localDataPath", "./finch_local.json"))
  )

  return (conf, cfg)
