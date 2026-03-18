# SPDX-License-Identifier: AGPL-3.0-only
import strutils, uri, sequtils, options, algorithm, math
import json

import jester

import router_utils
import ".."/[query, types, api, formatters, redis_cache, following_scope, timeline_collect]
from .. / refresh_coordinator import coalesceRefresh
import ../local_identity
import ../exporters
import ../views/[general, search]

include "../views/opensearch.nimf"

export search
export exporters

proc searchTimelineCacheId*(query: Query; cursor: string): string =
  genQueryUrl(query) & "|" & cursor

proc frontierRefreshKey(kind, cacheId: string): string =
  if cacheId.len == 0:
    return ""
  kind & ":" & cacheId

proc exactUserCandidate*(q: string): string =
  result = q.strip
  if result.startsWith("@"):
    result = result[1 .. ^1]
  if result.len == 0 or result.len > 15:
    return ""
  if result.anyIt(it notin {'a'..'z', 'A'..'Z', '0'..'9', '_'}):
    return ""

proc withExactUserMatch*(results: Result[User]): Future[Result[User]] {.async.} =
  result = results
  let candidate = exactUserCandidate(results.query.text)
  if candidate.len == 0:
    return

  if results.content.anyIt(it.username.toLowerAscii == candidate.toLowerAscii):
    return

  let exact = await getGraphUser(candidate)
  if exact.id.len == 0 or exact.username.len == 0:
    return
  if exact.username.toLowerAscii != candidate.toLowerAscii:
    return

  result.content.insert(exact, 0)

proc rerankUserSearch*(results: var Result[User]) =
  let needle = exactUserCandidate(results.query.text).toLowerAscii()
  if needle.len == 0 or results.content.len < 2:
    return

  proc score(u: User): int =
    if u.username.len == 0:
      return -1_000_000

    let uname = u.username.toLowerAscii()
    let fname = u.fullname.toLowerAscii()

    # Match quality (dominates), then verification, then popularity.
    if uname == needle:
      result += 100_000
    elif uname.startsWith(needle):
      result += 80_000
    elif fname.startsWith(needle):
      result += 40_000
    elif uname.contains(needle):
      result += 20_000
    elif fname.contains(needle):
      result += 10_000

    case u.verifiedType
    of government:
      result += 4_000
    of business:
      result += 3_000
    of blue:
      result += 2_000
    else:
      discard

    if u.followers > 0:
      # log10 scaling keeps huge accounts from completely flattening relevance
      result += min(20_000, int(log10(float(u.followers) + 1.0) * 4_000.0))

    if u.protected:
      result -= 1_000

  results.content.sort(proc(a, b: User): int =
    let sa = score(a)
    let sb = score(b)
    if sa != sb: return cmp(sb, sa)
    if a.followers != b.followers: return cmp(b.followers, a.followers)
    return cmp(a.username.toLowerAscii(), b.username.toLowerAscii())
  )

proc fetchTweetSearchResults*(req: Request; query: Query; cursor: string; forceRefresh=false): Future[Timeline] {.async.} =
  if pureProfileTimelineQuery(query):
    result = await collectUserTimelineMatches(query, 20, cursor)
    await cacheTimeline(result)
    return
  let
    ownerId = getFinchOwnerId(req)
    cacheId = searchTimelineCacheId(query, cursor)
    cached = if forceRefresh: none(Timeline) else: await getCachedSearchTimeline(cacheId)
  if cached.isSome:
    result = cached.get
  else:
    if cursor.len == 0 and not forceRefresh:
      let refreshed = await coalesceRefresh(frontierRefreshKey("search-page", cacheId), proc(): Future[void] {.async.} =
        let live = await getGraphTweetSearch(query, cursor)
        await cacheSearchTimeline(cacheId, live, cursor)
      )
      let nowCached = await getCachedSearchTimeline(cacheId)
      if nowCached.isSome:
        result = nowCached.get
      elif not refreshed:
        result = await getGraphTweetSearch(query, cursor)
      else:
        result = await getGraphTweetSearch(query, cursor)
    else:
      result = await getGraphTweetSearch(query, cursor)
      await cacheSearchTimeline(cacheId, result, cursor)
  result.query = query
  if query.scope == scopeFollowing and ownerId.len > 0:
    result = filterTimelineToFollowing(result, ownerId)
  result = filterTimelineByQuery(result, query)
  result.query = query
  await cacheTimeline(result)

proc mergeTimelinePages(base: var Timeline; page: Timeline) =
  if base.query.text.len == 0 and base.query.fromUser.len == 0 and base.content.len == 0:
    base = page
    return
  if page.content.len > 0:
    base.content.add page.content
  base.bottom = page.bottom
  if base.errorText.len == 0:
    base.errorText = page.errorText

proc fetchTweetSearchExportResults*(req: Request; query: Query; cursor: string; desiredLimit: int; forceRefresh=false): Future[Timeline] {.async.} =
  if pureProfileTimelineQuery(query):
    return await collectUserTimelineMatches(query, desiredLimit, cursor)
  var
    nextCursor = cursor
    pages = 0
    merged = Timeline(query: query, beginning: cursor.len == 0)
    pageBudget =
      if desiredLimit > 0:
        let pagesNeeded = max(1, (desiredLimit + 19) div 20)
        min(50, pagesNeeded + 3)
      else:
        25
  while true:
    let page = await fetchTweetSearchResults(req, query, nextCursor, forceRefresh=(forceRefresh and pages == 0))
    mergeTimelinePages(merged, page)
    merged = dedupeTimeline(merged)
    inc pages
    if desiredLimit <= 0 or merged.content.len >= desiredLimit:
      break
    if page.bottom.len == 0 or page.bottom == nextCursor or pages >= pageBudget:
      break
    nextCursor = page.bottom
  result = dedupeTimeline(filterTimelineByQuery(merged, query))
  result.requestedCount = desiredLimit
  result.pagesFetched = pages
  result.pageBudget = pageBudget
  result.budgetExhausted = desiredLimit > 0 and result.content.len < desiredLimit and pages >= pageBudget and result.bottom.len > 0

proc createSearchRouter*(cfg: Config) =
  router search:
    get "/search/@fmt/?":
      cond @"fmt" in ["json", "md", "txt"]
      let q = @"q"
      if q.len > 500:
        resp Http400, showError("Search input too long.", cfg)

      var query = initQuery(params(request))
      query.applyFeedDefaults(requestPrefs())
      let cursor = getCursor()
      let exportLimit = normalizeExportLimit(request.params.getOrDefault("limit"))

      case query.kind
      of users:
        var users: Result[User]
        try:
          users = await getGraphUserSearch(query, cursor)
          if cursor.len == 0:
            users = await withExactUserMatch(users)
          rerankUserSearch(users)
        except InternalError:
          users = Result[User](beginning: true, query: query)

        case @"fmt"
        of "json":
          respJson userSearchToJson(limitUserResults(users, exportLimit))
        of "md":
          resp userSearchToMarkdown(limitUserResults(users, exportLimit)), "text/markdown; charset=utf-8"
        of "txt":
          resp userSearchToText(limitUserResults(users, exportLimit)), "text/plain; charset=utf-8"
        else:
          resp Http404
      of tweets:
        let limitRaw = request.params.getOrDefault("limit")
        let selectedRaw = exportSelectionRaw(request.params.getOrDefault("selected_ids"), limitRaw)
        let tweets = limitTimeline(filterTimelineBySelected(
          await fetchTweetSearchExportResults(request, query, cursor, exportLimit), selectedRaw), exportLimit)
        case @"fmt"
        of "json":
          respJson searchTimelineToJson(tweets, cfg, selectedRaw, exportLimit)
        of "md":
          resp searchTimelineToMarkdown(tweets, cfg), "text/markdown; charset=utf-8"
        of "txt":
          resp searchTimelineToText(tweets, cfg), "text/plain; charset=utf-8"
        else:
          resp Http404
      else:
        resp Http404, showError("Invalid search", cfg)

    get "/search/live/json":
      let q = @"q"
      if q.len > 500:
        resp Http400, showError("Search input too long.", cfg)

      var query = initQuery(params(request))
      query.applyFeedDefaults(requestPrefs())
      let exportLimit = normalizeExportLimit(request.params.getOrDefault("limit"))

      case query.kind
      of users:
        var users: Result[User]
        try:
          users = await getGraphUserSearch(query, getCursor())
          users = await withExactUserMatch(users)
          rerankUserSearch(users)
        except InternalError:
          users = Result[User](beginning: true, query: query)
        respJson wrapLivePayload("search_live", userSearchToJson(limitUserResults(users, exportLimit)))
      of tweets:
        let limitRaw = request.params.getOrDefault("limit")
        let selectedRaw = exportSelectionRaw(request.params.getOrDefault("selected_ids"), limitRaw)
        let tweets = limitTimeline(filterTimelineBySelected(
          await fetchTweetSearchExportResults(request, query, getCursor(), exportLimit, forceRefresh=true), selectedRaw), exportLimit)
        respJson wrapLivePayload("search_live", searchTimelineToJson(tweets, cfg, selectedRaw, exportLimit))
      else:
        resp Http404, showError("Invalid search", cfg)

    get "/search/?":
      let q = @"q"
      if q.len > 500:
        resp Http400, showError("Search input too long.", cfg)

      let prefs = requestPrefs()
      var query = initQuery(params(request))
      query.applyFeedDefaults(prefs)
      let
        display = displayQuery(query)
        title = "Search" & (if display.len > 0: " (" & display & ")" else: "")

      case query.kind
      of users:
        if "," in q:
          redirect("/" & q)
        var users: Result[User]
        try:
          users = await getGraphUserSearch(query, getCursor())
          users = await withExactUserMatch(users)
          rerankUserSearch(users)
        except InternalError:
          users = Result[User](beginning: true, query: query)
        resp renderMain(renderUserSearch(users, prefs), request, cfg, prefs, title)
      of tweets:
        let
          ownerId = getFinchOwnerId(request)
        if query.scope == scopeFollowing and ownerId.len == 0:
          let referer = getPath()
          redirect("/f/identity?referer=" & encodeUrl(referer))

        let tweets = await fetchTweetSearchResults(request, query, getCursor())
        let
          rss = if cfg.enableRSSSearch: "/search/rss?" & genQueryUrl(query) else: ""
        resp renderMain(renderTweetSearch(tweets, prefs, getPath()),
                        request, cfg, prefs, title, rss=rss)
      else:
        resp Http404, showError("Invalid search", cfg)

    get "/hashtag/@hash":
      redirect("/search?f=tweets&q=" & encodeUrl("#" & @"hash"))

    get "/opensearch":
      let url = getUrlPrefix(cfg) & "/search?f=tweets&q="
      resp Http200, {"Content-Type": "application/opensearchdescription+xml"},
                     generateOpenSearchXML(cfg.title, cfg.hostname, url)
