# SPDX-License-Identifier: AGPL-3.0-only
import httpclient, asyncdispatch, options, strutils, uri, times, math, tables
import jsony, packedjson, zippy, oauth1
import types, auth, consts, parserutils, http_pool, tid
import experimental/types/common

proc extractErrorCode(body: string): Error =
  try:
    let js = parseJson(body)
    js{"errors"}.getError
  except CatchableError:
    null

const
  rlRemaining = "x-rate-limit-remaining"
  rlReset = "x-rate-limit-reset"
  rlLimit = "x-rate-limit-limit"
  errorsToSkip = {null, doesntExist, tweetNotFound, timeout, unauthorized, badRequest}

var 
  pool: HttpPool
  disableTid: bool
  apiProxy: string

proc setDisableTid*(disable: bool) =
  disableTid = disable

proc setApiProxy*(url: string) =
  if url.len > 0:
    apiProxy = url.strip(chars={'/'}) & "/"
    if "http" notin apiProxy:
      apiProxy = "http://" & apiProxy

proc toUrl(req: ApiReq; sessionKind: SessionKind): Uri =
  case sessionKind
  of oauth:  
    let o = req.oauth
    parseUri("https://api.x.com/graphql")   / o.endpoint ? o.params
  of cookie: 
    let c = req.cookie
    parseUri("https://x.com/i/api/graphql") / c.endpoint ? c.params

proc getOauthHeader(url, oauthToken, oauthTokenSecret: string): string =
  let
    encodedUrl = url.replace(",", "%2C").replace("+", "%20")
    params = OAuth1Parameters(
      consumerKey: consumerKey,
      signatureMethod: "HMAC-SHA1",
      timestamp: $int(round(epochTime())),
      nonce: "0",
      isIncludeVersionToHeader: true,
      token: oauthToken
    )
    signature = getSignature(HttpGet, encodedUrl, "", params, consumerSecret, oauthTokenSecret)

  params.signature = percentEncode(signature)

  return getOauth1RequestHeader(params)["authorization"]

proc getCookieHeader(session: Session): string =
  proc enc(value: string): string =
    percentEncode(value)

  var parts = @[
    "auth_token=" & enc(session.authToken),
    "ct0=" & enc(session.ct0)
  ]
  if session.guestId.len > 0:
    parts.add "guest_id=" & enc(session.guestId)
  if session.guestIdAds.len > 0:
    parts.add "guest_id_ads=" & enc(session.guestIdAds)
  if session.guestIdMarketing.len > 0:
    parts.add "guest_id_marketing=" & enc(session.guestIdMarketing)
  parts.join("; ")

proc genHeaders*(session: Session, url: Uri): Future[HttpHeaders] {.async.} =
  result = newHttpHeaders({
    "accept": "*/*",
    "accept-encoding": "gzip",
    "accept-language": "en-US,en;q=0.9",
    "connection": "keep-alive",
    "content-type": "application/json",
    "origin": "https://x.com",
    "user-agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36",
    "x-twitter-active-user": "yes",
    "x-twitter-client-language": "en",
    "priority": "u=1, i"
  })

  case session.kind
  of SessionKind.oauth:
    result["authorization"] = getOauthHeader($url, session.oauthToken, session.oauthSecret)
  of SessionKind.cookie:
    result["x-twitter-auth-type"] = "OAuth2Session"
    result["x-csrf-token"] = session.ct0
    result["cookie"] = getCookieHeader(session)
    result["sec-ch-ua"] = """"Google Chrome";v="142", "Chromium";v="142", "Not A(Brand";v="24""""
    result["sec-ch-ua-mobile"] = "?0"
    result["sec-ch-ua-platform"] = "Windows"
    result["sec-fetch-dest"] = "empty"
    result["sec-fetch-mode"] = "cors"
    result["sec-fetch-site"] = "same-site"
    if disableTid:
      result["authorization"] = bearerToken2
    else:
      result["authorization"] = bearerToken
      result["x-client-transaction-id"] = await genTid(url.path)

proc getAndValidateSession*(req: ApiReq): Future[Session] {.async.} =
  result = await getSession(req)
  case result.kind
  of SessionKind.oauth:
    if result.oauthToken.len == 0:
      echo "[sessions] Empty oauth token, session: ", result.pretty
      invalidate(result)
      raise newException(BadClientError, "empty oauth credentials")
  of SessionKind.cookie:
    if result.authToken.len == 0 or result.ct0.len == 0:
      echo "[sessions] Empty cookie credentials, session: ", result.pretty
      invalidate(result)
      raise newException(BadClientError, "empty cookie credentials")

proc maxSessionAttempts(): int =
  max(1, sessionCount())

proc sleepBackoff(attempt: int): Future[void] =
  sleepAsync(min(4000, 500 * (1 shl max(0, attempt - 1))))

template fetchImpl(result, fetchBody) {.dirty.} =
  once:
    pool = HttpPool()

  try:
    var resp: AsyncResponse
    pool.use(await genHeaders(session, url)):
      template getContent =
        # TODO: this is a temporary simple implementation
        if apiProxy.len > 0:
          let rawUrl = $url
          let proxied =
            if rawUrl.startsWith("https://"): apiProxy & rawUrl[8 .. ^1]
            elif rawUrl.startsWith("http://"): apiProxy & rawUrl[7 .. ^1]
            else: apiProxy & rawUrl
          resp = await c.get(proxied)
        else:
          resp = await c.get($url)
        result = await resp.body

      getContent()

      if resp.status == $Http503:
        badClient = true
        raise newException(BadClientError, "Bad client")

    if resp.headers.hasKey(rlRemaining):
      let
        remaining = parseInt(resp.headers[rlRemaining])
        reset = parseInt(resp.headers[rlReset])
        limit = parseInt(resp.headers[rlLimit])
      session.setRateLimit(req, remaining, reset, limit)

      if result.len > 0:
        if resp.headers.getOrDefault("content-encoding") == "gzip":
          result = uncompress(result, dfGzip)

      if result.startsWith("{\"errors"):
        let error = extractErrorCode(result)
        if error notin errorsToSkip:
          echo "Fetch error, API: ", url.path, ", error: ", error
          if error in {expiredToken, badToken, locked, noCsrf}:
            var invalid = session
            invalidate(invalid)
            raise newException(BadClientError, "session invalid: " & $error)
          elif error in {rateLimited}:
            setLimited(session, req)
            raise rateLimitError(req, session.apis[req.cookie.endpoint].reset)
      elif result.startsWith("429 Too Many Requests"):
        echo "[sessions] 429 error, API: ", url.path, ", session: ", session.pretty
        setLimited(session, req)
        raise rateLimitError(req, session.apis[req.cookie.endpoint].reset)

    fetchBody

    if resp.status == $Http400:
      echo "ERROR 400, ", url.path, ": ", result
      raise newException(InternalError, $url)
  except InternalError as e:
    raise e
  except BadClientError as e:
    raise e
  except OSError as e:
    raise e
  except Exception as e:
    let s = session.pretty
    echo "error: ", e.name, ", msg: ", e.msg, ", session: ", s, ", url: ", url
    raise newException(InternalError, e.msg)
  finally:
    release(session)

proc fetch*(req: ApiReq): Future[JsonNode] {.async.} =
  let attempts = maxSessionAttempts()
  var lastRateLimit: ref RateLimitError = nil
  for attempt in 0 ..< attempts:
    try:
      var
        body: string
        session = await getAndValidateSession(req)
      let url = req.toUrl(session.kind)

      fetchImpl body:
        if body.startsWith('{') or body.startsWith('['):
          result = parseJson(body)
        else:
          echo resp.status, ": ", body, " --- url: ", url
          result = newJNull()

        let error = result.getError
        if error != null and error notin errorsToSkip:
          echo "Fetch error, API: ", url.path, ", error: ", error
          if error in {expiredToken, badToken, locked, noCsrf}:
            var invalid = session
            invalidate(invalid)
            raise newException(BadClientError, "session invalid: " & $error)
          elif error == rateLimited:
            setLimited(session, req)
            raise rateLimitError(req, session.apis[req.cookie.endpoint].reset)
      return
    except RateLimitError as e:
      lastRateLimit = e
      if attempt + 1 >= attempts:
        raise e
      echo "[sessions] Rate limited, rotating session for ", req.cookie.endpoint
      continue
    except BadClientError as e:
      if attempt + 1 >= attempts:
        raise e
      echo "[sessions] Bad session/client for ", req.cookie.endpoint, ", retrying with another session..."
      await sleepBackoff(attempt + 1)
      continue
    except OSError as e:
      if attempt + 1 >= attempts:
        raise newException(BadClientError, e.msg)
      await sleepBackoff(attempt + 1)
      continue
  if not lastRateLimit.isNil:
    raise lastRateLimit

proc fetchRaw*(req: ApiReq): Future[string] {.async.} =
  let attempts = maxSessionAttempts()
  var lastRateLimit: ref RateLimitError = nil
  for attempt in 0 ..< attempts:
    try:
      var session = await getAndValidateSession(req)
      let url = req.toUrl(session.kind)

      fetchImpl result:
        if not (result.startsWith('{') or result.startsWith('[')):
          echo resp.status, ": ", result, " --- url: ", url
          result.setLen(0)
      return
    except RateLimitError as e:
      lastRateLimit = e
      if attempt + 1 >= attempts:
        raise e
      continue
    except BadClientError as e:
      if attempt + 1 >= attempts:
        raise e
      await sleepBackoff(attempt + 1)
      continue
    except OSError as e:
      if attempt + 1 >= attempts:
        raise newException(BadClientError, e.msg)
      await sleepBackoff(attempt + 1)
      continue
  if not lastRateLimit.isNil:
    raise lastRateLimit

proc fetchPost*(endpoint: string; variables: packedjson.JsonNode): Future[packedjson.JsonNode] {.async.} =
  ## POST to X GraphQL (list mutations). Uses getWriteSession; caller must not release (done here).
  once:
    pool = HttpPool()

  let attempts = maxSessionAttempts()
  var lastRateLimit: ref RateLimitError = nil
  for attempt in 0 ..< attempts:
    var session: Session = nil
    try:
      session = await getWriteSession()
      let url = parseUri("https://x.com/i/api/graphql") / endpoint
      let headers = await genHeaders(session, url)
      let feats = parseJson(gqlFeatures)
      var bodyNode = newJObject()
      bodyNode["variables"] = variables
      bodyNode["features"] = feats
      let bodyStr = $bodyNode

      var resp: AsyncResponse
      var body: string
      let rawUrl = $url
      let postUrl =
        if apiProxy.len > 0:
          if rawUrl.startsWith("https://"): apiProxy & rawUrl[8 .. ^1]
          elif rawUrl.startsWith("http://"): apiProxy & rawUrl[7 .. ^1]
          else: apiProxy & rawUrl
        else:
          rawUrl
      pool.use(headers):
        resp = await c.post(postUrl, bodyStr)
        body = await resp.body

      if body.len > 0 and resp.headers.getOrDefault("content-encoding") == "gzip":
        body = uncompress(body, dfGzip)

      if body.startsWith("{\"errors"):
        echo "[fetchPost] GraphQL error, endpoint: ", endpoint, ", body: ", body[0 ..< min(body.len, 300)]
        let error = extractErrorCode(body)
        if error in {expiredToken, badToken, locked, noCsrf}:
          invalidate(session)
          raise newException(BadClientError, "session invalid: " & $error)
        elif error in {rateLimited}:
          let req = ApiReq(cookie: ApiUrl(endpoint: endpoint, params: @[]))
          setLimited(session, req)
          raise rateLimitError(req, session.apis[req.cookie.endpoint].reset)
        raise newException(InternalError, "GraphQL errors: " & body)
      if body.startsWith("429 Too Many Requests"):
        echo "[fetchPost] 429 rate limited, endpoint: ", endpoint
        let req = ApiReq(cookie: ApiUrl(endpoint: endpoint, params: @[]))
        setLimited(session, req)
        raise rateLimitError(req, session.apis[req.cookie.endpoint].reset)

      if body.strip.len == 0 or not (body.strip.startsWith("{") or body.strip.startsWith("[")):
        echo "[fetchPost] Invalid/empty response, endpoint: ", endpoint, ", len: ", body.len
        raise newException(InternalError, "Invalid response")
      result = parseJson(body.strip)
      return
    except RateLimitError as e:
      lastRateLimit = e
      if attempt + 1 >= attempts:
        raise e
      continue
    except BadClientError as e:
      if attempt + 1 >= attempts:
        raise e
      await sleepBackoff(attempt + 1)
      continue
    except OSError as e:
      if attempt + 1 >= attempts:
        raise newException(BadClientError, e.msg)
      await sleepBackoff(attempt + 1)
      continue
    except CatchableError as e:
      echo "[fetchPost] error: ", e.name, ", msg: ", e.msg, ", endpoint: ", endpoint
      raise e
    finally:
      if not session.isNil:
        release(session)
  if not lastRateLimit.isNil:
    raise lastRateLimit
