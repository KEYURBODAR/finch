import std/[asyncdispatch, times, json, strutils, strformat, tables, sequtils, os]
import types
import experimental/parser/session

var
  sessionPool: seq[Session]
  enableLogging = false
  # max requests at a time per session to avoid race conditions
  maxConcurrentReqs = 2

proc setMaxConcurrentReqs*(reqs: int) =
  if reqs > 0:
    maxConcurrentReqs = reqs

template log(str: varargs[string, `$`]) =
  echo "[sessions] ", str.join("")

proc endpoint(req: ApiReq; session: Session): string =
  case session.kind
  of oauth: req.oauth.endpoint
  of cookie: req.cookie.endpoint

proc endpointName(req: ApiReq): string =
  if req.cookie.endpoint.len > 0:
    req.cookie.endpoint
  elif req.oauth.endpoint.len > 0:
    req.oauth.endpoint
  else:
    "unknown"

proc pretty*(session: Session): string =
  if session.isNil:
    return "<null>"

  if session.id > 0 and session.username.len > 0:
    result = $session.id & " (" & session.username & ")"
  elif session.username.len > 0:
    result = session.username
  elif session.id > 0:
    result = $session.id
  else:
    result = "<unknown>"
  result = $session.kind & " " & result

proc snowflakeToEpoch(flake: int64): int64 =
  int64(((flake shr 22) + 1288834974657) div 1000)

proc getSessionPoolHealth*(): JsonNode =
  let now = epochTime().int

  var
    totalReqs = 0
    limitedCount = 0
    reqsPerApi: Table[string, int]
    nextResets: Table[string, int]
    oldest = now.int64
    newest = 0'i64
    average = 0'i64

  for session in sessionPool:
    let created = snowflakeToEpoch(session.id)
    if created > newest:
      newest = created
    if created < oldest:
      oldest = created
    average += created

    if session.apis.values.toSeq.anyIt(it.remaining <= 0 and it.reset > now):
      inc limitedCount

    for api in session.apis.keys:
      let
        apiStatus = session.apis[api]
        reqs = apiStatus.limit - apiStatus.remaining

      # no requests made with this session and endpoint since the limit reset
      if apiStatus.reset < now:
        continue

      reqsPerApi.mgetOrPut($api, 0).inc reqs
      totalReqs.inc reqs
      if apiStatus.remaining <= 0 and (api notin nextResets or apiStatus.reset < nextResets[api]):
        nextResets[api] = apiStatus.reset

  if sessionPool.len > 0:
    average = average div sessionPool.len
  else:
    oldest = 0
    average = 0

  return %*{
    "sessions": %*{
      "total": sessionPool.len,
      "limited": limitedCount,
      "oldest": $fromUnix(oldest),
      "newest": $fromUnix(newest),
      "average": $fromUnix(average)
    },
    "requests": %*{
      "total": totalReqs,
      "apis": reqsPerApi
    },
    "next_resets": nextResets
  }

proc getSessionPoolDebug*(): JsonNode =
  let now = epochTime().int
  var list = newJObject()

  for session in sessionPool:
    let sessionJson = %*{
      "apis": newJObject(),
      "pending": session.pending,
      "last_used_at": session.lastUsedAt,
      "total_requests": session.totalRequests
    }

    for api in session.apis.keys:
      let
        apiStatus = session.apis[api]
        obj = %*{}

      if apiStatus.reset > now.int:
        obj["remaining"] = %apiStatus.remaining
        obj["reset"] = %apiStatus.reset

      if "remaining" notin obj:
        continue

      sessionJson{"apis", $api} = obj
      list[$session.id] = sessionJson

  return %list

proc nextResetForApi(req: ApiReq): int =
  let
    now = epochTime().int
    api = endpointName(req)
  result = 0
  for session in sessionPool:
    if api notin session.apis:
      continue
    let limit = session.apis[api]
    if limit.remaining > 0 or limit.reset <= now:
      continue
    if result == 0 or limit.reset < result:
      result = limit.reset

proc rateLimitError*(req: ApiReq; resetAt=0): ref RateLimitError =
  result = newException(RateLimitError, "rate limited")
  result.endpoint = endpointName(req)
  result.resetAt = (if resetAt > 0: resetAt else: nextResetForApi(req))
  result.sessionTotal = sessionPool.len

proc noSessionsError*(req: ApiReq): ref NoSessionsError =
  let resetAt = nextResetForApi(req)
  result = newException(NoSessionsError,
    if resetAt > 0:
      &"no sessions available for {endpointName(req)} until {resetAt}"
    else:
      &"no sessions available for {endpointName(req)}")
  result.endpoint = endpointName(req)
  result.resetAt = resetAt
  result.sessionTotal = sessionPool.len

proc sessionCount*(): int =
  sessionPool.len

proc isLimited(session: Session; req: ApiReq): bool =
  if session.isNil:
    return true

  let api = req.endpoint(session)
  if api in session.apis:
    let limit = session.apis[api]
    return limit.remaining <= 0 and limit.reset > epochTime().int
  else:
    return false

proc isReady(session: Session; req: ApiReq): bool =
  not (session.isNil or session.pending >= maxConcurrentReqs or session.isLimited(req))

proc invalidate*(session: var Session) =
  if session.isNil: return
  log "invalidating: ", session.pretty

  let idx = sessionPool.find(session)
  if idx > -1: sessionPool.delete(idx)
  session = nil

proc release*(session: Session) =
  if session.isNil: return
  dec session.pending

proc getSession*(req: ApiReq): Future[Session] {.async.} =
  var
    best: Session = nil
    bestScore = high(int)
    nowTs = epochTime().int

  for session in sessionPool:
    if not session.isReady(req):
      continue
    let score = session.pending * 1_000_000 + session.totalRequests * 100 + session.lastUsedAt
    if score < bestScore:
      bestScore = score
      best = session

  if not best.isNil and best.isReady(req):
    inc best.pending
    inc best.totalRequests
    best.lastUsedAt = nowTs
    result = best
  else:
    log "no sessions available for API: ", req.cookie.endpoint
    raise noSessionsError(req)

proc getWriteSession*(): Future[Session] {.async.} =
  ## Returns first available cookie session for list mutations. Caller must release(session) when done.
  var
    best: Session = nil
    bestScore = high(int)
    nowTs = epochTime().int

  for session in sessionPool:
    if session.kind != SessionKind.cookie:
      continue
    if not session.isReady(ApiReq(cookie: ApiUrl(endpoint: "list_write"))):
      continue
    let score = session.pending * 1_000_000 + session.totalRequests * 100 + session.lastUsedAt
    if score < bestScore:
      bestScore = score
      best = session

  if not best.isNil:
    inc best.pending
    inc best.totalRequests
    best.lastUsedAt = nowTs
    return best
  raise noSessionsError(ApiReq(cookie: ApiUrl(endpoint: "list_write")))

proc setLimited*(session: Session; req: ApiReq) =
  let api = req.endpoint(session)
  let fallbackReset = epochTime().int + 15 * 60
  let current = session.apis.getOrDefault(api)
  session.apis[api] = RateLimit(
    limit: max(1, current.limit),
    remaining: 0,
    reset: max(current.reset, fallbackReset)
  )
  log "rate limited by api: ", api, ", ", session.pretty

proc setRateLimit*(session: Session; req: ApiReq; remaining, reset, limit: int) =
  # avoid undefined behavior in race conditions
  let api = req.endpoint(session)
  if api in session.apis:
    let rateLimit = session.apis[api]
    if rateLimit.reset >= reset and rateLimit.remaining < remaining:
      return
    if rateLimit.reset == reset and rateLimit.remaining >= remaining:
      session.apis[api].remaining = remaining
      return

  session.apis[api] = RateLimit(limit: limit, remaining: remaining, reset: reset)

proc initSessionPool*(cfg: Config; path: string) =
  enableLogging = cfg.enableDebug

  if path.endsWith(".json"):
    log "ERROR: .json is not supported, the file must be a valid JSONL file ending in .jsonl"
    quit 1

  var attempts = 0
  while not fileExists(path) and attempts < 20:
    sleep(250)
    inc attempts

  if not fileExists(path):
    log "ERROR: ", path, " not found. This file is required to authenticate API requests."
    quit 1

  log "parsing JSONL account sessions file: ", path
  for line in path.lines:
    sessionPool.add parseSession(line)

  log "successfully added ", sessionPool.len, " valid account sessions"
  if sessionPool.len < 3:
    log "WARNING: only ", $sessionPool.len, " session(s) loaded. Public usage will be fragile with fewer than 3 healthy accounts."
