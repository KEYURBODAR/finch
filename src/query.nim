# SPDX-License-Identifier: AGPL-3.0-only
import strutils, strformat, sequtils, tables, uri

import types

const
  validFilters* = @[
    "media", "images", "twimg", "videos",
    "native_video", "consumer_video", "spaces",
    "links", "news", "quote", "mentions",
    "replies", "retweets", "nativeretweets"
  ]

  emptyQuery* = "include:nativeretweets"

template `@`(param: string): untyped =
  if param in pms: pms[param]
  else: ""

proc validateNumber(value: string): string =
  if value.anyIt(not it.isDigit):
    return ""
  return value

proc addUnique(items: var seq[string]; value: string) =
  if value.len == 0 or value in items:
    return
  items.add value

proc normalizeUsername(value: string): string =
  result = value.strip(chars={'(', ')', ',', ' ', '\t', '\n', '\r'})
  if result.startsWith("@"):
    result = result[1 .. ^1]
  if result.len == 0:
    return ""
  if result.anyIt(it notin {'a'..'z', 'A'..'Z', '0'..'9', '_'}):
    return ""

proc normalizeFilter(value: string): string =
  case value.toLowerAscii
  of "nativereposts":
    "nativeretweets"
  else:
    value.toLowerAscii

proc splitUsers(value: string): seq[string] =
  for item in value.split({',', ' '}):
    let username = normalizeUsername(item)
    if username.len > 0 and username notin result:
      result.add username

proc parseUserScope*(value: string): seq[string] =
  splitUsers(value)

proc splitQueryTokens(value: string): seq[string] =
  var
    token = ""
    quote = '\0'

  for ch in value:
    if quote != '\0':
      token.add ch
      if ch == quote:
        quote = '\0'
      continue

    case ch
    of ' ', '\t', '\n', '\r':
      if token.len > 0:
        result.add token
        token.setLen 0
    of '"', '\'':
      token.add ch
      quote = ch
    else:
      token.add ch

  if token.len > 0:
    result.add token

proc stripFromOperators(value: string): string =
  var residual: seq[string]
  for token in splitQueryTokens(value):
    let normalized = token.strip(chars={'(', ')', ' '})
    if normalized.len == 0:
      continue
    if normalized.toLowerAscii.startsWith("from:"):
      continue
    residual.add token
  result = residual.join(" ").strip

proc normalizedToken(token: string): string =
  token.strip(chars={'(', ')', ' '})

proc tokenStartsWith(token, prefix: string): bool =
  token.toLowerAscii.startsWith(prefix)

proc parseRawQuery(raw: string; allowFromOperators: bool): Query =
  let tokens = splitQueryTokens(raw)
  var
    residual: seq[string]
    prevWasUserOp = false

  for i, token in tokens:
    let
      normalized = normalizedToken(token)
      lower = normalized.toLowerAscii
      nextToken =
        if i < tokens.high: normalizedToken(tokens[i + 1]).toLowerAscii
        else: ""

    if normalized.len == 0:
      prevWasUserOp = false
      continue

    if lower == "or" and prevWasUserOp and
       (nextToken.startsWith("from:") or nextToken.startsWith("to:") or
        nextToken.startsWith("@")):
      continue

    if allowFromOperators and tokenStartsWith(lower, "from:"):
      for user in splitUsers(normalized[5 .. ^1]):
        result.fromUser.addUnique(user)
      prevWasUserOp = true
      continue

    if tokenStartsWith(lower, "to:"):
      for user in splitUsers(normalized[3 .. ^1]):
        result.toUser.addUnique(user)
      prevWasUserOp = true
      continue

    if normalized.startsWith("@"):
      let mention = normalizeUsername(normalized)
      if mention.len > 0:
        result.mentions.addUnique(mention)
        prevWasUserOp = true
        continue

    if tokenStartsWith(lower, "filter:"):
      let filter = normalizeFilter(normalized[7 .. ^1])
      if filter in validFilters:
        result.filters.addUnique(filter)
        prevWasUserOp = false
        continue

    if tokenStartsWith(lower, "-filter:"):
      let filter = normalizeFilter(normalized[8 .. ^1])
      if filter in validFilters:
        result.excludes.addUnique(filter)
        prevWasUserOp = false
        continue

    if tokenStartsWith(lower, "include:"):
      let includedFilter = normalizeFilter(normalized[8 .. ^1])
      if includedFilter in validFilters:
        result.includes.addUnique(includedFilter)
        prevWasUserOp = false
        continue

    if tokenStartsWith(lower, "since:"):
      result.since = normalized[6 .. ^1]
      prevWasUserOp = false
      continue

    if tokenStartsWith(lower, "until:"):
      result.until = normalized[6 .. ^1]
      prevWasUserOp = false
      continue

    if tokenStartsWith(lower, "min_faves:"):
      result.minLikes = validateNumber(normalized[10 .. ^1])
      prevWasUserOp = false
      continue

    if tokenStartsWith(lower, "min_retweets:") or tokenStartsWith(lower, "min_reposts:"):
      let idx = if lower.startsWith("min_retweets:"): 13 else: 12
      result.minRetweets = validateNumber(normalized[idx .. ^1])
      prevWasUserOp = false
      continue

    if tokenStartsWith(lower, "min_replies:"):
      result.minReplies = validateNumber(normalized[12 .. ^1])
      prevWasUserOp = false
      continue

    prevWasUserOp = false
    residual.add token

  result.text = residual.join(" ").strip

proc mergeUsers(dest: var seq[string]; value: string) =
  for user in splitUsers(value):
    dest.addUnique(user)

proc repliesExplicitlyRequested*(query: Query): bool =
  "replies" in query.filters or "replies" in query.includes

proc pureProfileTimelineQuery*(query: Query): bool =
  query.kind == tweets and
  query.fromUser.len == 1 and
  query.text.len == 0 and
  query.toUser.len == 0 and
  query.mentions.len == 0

proc applyFeedDefaults*(query: var Query; prefs: Prefs) =
  if query.kind != tweets:
    return
  if prefs.excludeRepliesByDefault and
     not repliesExplicitlyRequested(query) and
     "replies" notin query.excludes:
    query.excludes.addUnique("replies")

proc initQuery*(pms: Table[string, string]; name=""): Query =
  let scopeVal = parseEnum[SearchScope](@"scope", scopeAll)
  result.kind = parseEnum[QueryKind](@"f", tweets)
  result.sort = latest
  result.scope = scopeVal
  result.sep = "OR"

  if result.kind == users:
    result.text = @"q"
    return

  let allowFromOperators = name.len == 0
  result = parseRawQuery(@"q", allowFromOperators)
  result.kind = parseEnum[QueryKind](@"f", tweets)
  result.sort = latest
  result.scope = scopeVal
  result.sep = "OR"

  for filter in validFilters:
    if "f-" & filter in pms:
      result.filters.addUnique(filter)
    if "e-" & filter in pms:
      result.excludes.addUnique(filter)
    if "i-" & filter in pms:
      result.includes.addUnique(filter)

  result.fromUser.mergeUsers(@"from_user")
  result.toUser.mergeUsers(@"to_user")
  result.mentions.mergeUsers(@"mentions")

  if @"since".len > 0:
    result.since = @"since"
  if @"until".len > 0:
    result.until = @"until"
  if @"min_faves".len > 0:
    result.minLikes = validateNumber(@"min_faves")
  if @"min_retweets".len > 0:
    result.minRetweets = validateNumber(@"min_retweets")
  if @"min_replies".len > 0:
    result.minReplies = validateNumber(@"min_replies")

  if name.len > 0:
    result.fromUser = splitUsers(name)
    result.text = stripFromOperators(result.text)

proc getMediaQuery*(name: string): Query =
  Query(
    kind: media,
    filters: @["twimg", "native_video"],
    fromUser: @[name],
    sep: "OR"
  )

proc getArticlesQuery*(name: string): Query =
  Query(
    kind: articles,
    fromUser: @[name]
  )

proc getHighlightsQuery*(name: string): Query =
  Query(
    kind: highlights,
    fromUser: @[name]
  )

proc getListsQuery*(name: string): Query =
  Query(
    kind: lists,
    fromUser: @[name]
  )

proc getReplyQuery*(name: string): Query =
  Query(
    kind: replies,
    fromUser: @[name]
  )

proc displayQuery*(query: Query): string =
  var parts: seq[string]

  if query.kind == users:
    return query.text

  if query.fromUser.len > 0:
    if query.fromUser.len == 1:
      parts.add "from:" & query.fromUser[0]
    else:
      parts.add query.fromUser.mapIt("from:" & it).join(" OR ")

  if query.toUser.len > 0:
    if query.toUser.len == 1:
      parts.add "to:" & query.toUser[0]
    else:
      parts.add query.toUser.mapIt("to:" & it).join(" OR ")

  for mention in query.mentions:
    parts.add "@" & mention

  for f in query.filters:
    parts.add "filter:" & f
  for e in query.excludes:
    if e == "nativeretweets":
      parts.add "-filter:nativeretweets"
    else:
      parts.add "-filter:" & e
  for i in query.includes:
    parts.add "include:" & i

  if query.since.len > 0:
    parts.add "since:" & query.since
  if query.until.len > 0:
    parts.add "until:" & query.until
  if query.minLikes.len > 0:
    parts.add "min_faves:" & query.minLikes
  if query.minRetweets.len > 0:
    parts.add "min_retweets:" & query.minRetweets
  if query.minReplies.len > 0:
    parts.add "min_replies:" & query.minReplies
  if query.text.len > 0:
    parts.add query.text

  parts.join(" ").strip

proc genQueryParam*(query: Query): string =
  var
    filters: seq[string]
    param: string

  if query.kind == users:
    return query.text

  if query.fromUser.len > 0:
    param = "("
    for i, user in query.fromUser:
      param &= &"from:{user}"
      if i < query.fromUser.high:
        param &= " OR "
    param &= ")"

  if query.fromUser.len > 0 and query.kind in {posts, media, articles, highlights}:
    param &= " (filter:self_threads OR -filter:replies)"

  if "nativeretweets" notin query.excludes:
    if param.len > 0:
      param &= " include:nativeretweets"
    else:
      param = "include:nativeretweets"

  for f in query.filters:
    filters.add "filter:" & f
  for e in query.excludes:
    if e == "nativeretweets": continue
    filters.add "-filter:" & e
  for i in query.includes:
    filters.add "include:" & i

  if query.toUser.len > 0:
    let targets = query.toUser.mapIt("to:" & it)
    if param.len > 0:
      param &= " "
    if targets.len == 1:
      param &= targets[0]
    else:
      param &= "(" & targets.join(" OR ") & ")"

  if query.mentions.len > 0:
    if param.len > 0:
      param &= " "
    param &= query.mentions.mapIt("@" & it).join(" ")

  if filters.len > 0:
    let filterExpr = "(" & filters.join(&" {query.sep} ") & ")"
    if param.len > 0:
      result = strip(param & " " & filterExpr)
    else:
      result = filterExpr
  else:
    result = strip(param)

  if query.since.len > 0:
    result &= " since:" & query.since
  if query.until.len > 0:
    result &= " until:" & query.until
  if query.minLikes.len > 0:
    result &= " min_faves:" & query.minLikes
  if query.minRetweets.len > 0:
    result &= " min_retweets:" & query.minRetweets
  if query.minReplies.len > 0:
    result &= " min_replies:" & query.minReplies
  if query.text.len > 0:
    if result.len > 0:
      result &= " " & query.text
    else:
      result = query.text

proc genQueryUrl*(query: Query): string =
  if query.kind notin {tweets, users}: return

  var params = @[&"f={query.kind}"]
  if query.kind == tweets:
    if query.scope != scopeFollowing and query.sort != latest:
      params.add "sort=" & encodeUrl($query.sort)
    if query.scope != scopeAll:
      params.add "scope=" & encodeUrl($query.scope)
  let display = displayQuery(query)
  if display.len > 0:
    params.add "q=" & encodeUrl(display)

  if params.len > 0:
    result &= params.join("&")
