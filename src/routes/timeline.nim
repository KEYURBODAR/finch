# SPDX-License-Identifier: AGPL-3.0-only
import asyncdispatch, hashes, strutils, sequtils, uri, options, times
import jester, karax/vdom

import router_utils
import ".."/[types, redis_cache, formatters, query, api, local_data, timeline_collect]
from .. / refresh_coordinator import coalesceRefresh
import ../local_identity
import ../exporters
import ../views/[general, profile, timeline, status, search]

export vdom
export uri, sequtils
export router_utils
export redis_cache, formatters, query, api
export exporters
export profile, timeline, status

proc affiliatesCacheKey(userId, after: string): string =
  "affiliates:v3:" & userId & ":" & after

proc profileSurfaceCacheId(query: Query; after: string): string =
  let scope = [
    $query.kind,
    query.fromUser.join(","),
    after
  ].join("|")
  $hash(scope)

proc searchTimelineCacheId(query: Query; after: string): string =
  $hash(genQueryUrl(query) & "|" & after)

proc frontierRefreshKey(kind, cacheId: string): string =
  if cacheId.len == 0:
    return ""
  kind & ":" & cacheId

proc fetchAffiliatesProfile*(userId, after: string): Future[Result[User]] {.async.} =
  let key = affiliatesCacheKey(userId, after)
  let cached = await getCachedUserSearch(key)
  if cached.isSome:
    return cached.get

  try:
    result = await getGraphUserAffiliates(userId, after)
    if result.content.anyIt(it.username.len > 0):
      await cacheUserSearch(key, result)
  except RateLimitError, NoSessionsError, InternalError, BadClientError:
    let stale = await getCachedUserSearch(key)
    if stale.isSome:
      result = stale.get
      result.errorText = "Showing cached affiliate roster. Live refresh is temporarily unavailable."
    else:
      result = Result[User](
        beginning: after.len == 0,
        errorText: "Affiliate roster is temporarily unavailable."
      )

proc hydrateProfileTabs(user: User; activeKind: QueryKind): Future[ProfileTabState] {.async.} =
  discard user
  discard activeKind
  result = ProfileTabState(
    showArticles: true,
    showHighlights: true,
    showAffiliates: true
  )

template currentFinchOwnerId*(req: Request): untyped =
  getFinchOwnerId(req)

proc getQuery*(request: Request; tab, name: string; prefs: Prefs): Query =
  case tab
  of "media": result = getMediaQuery(name)
  of "articles": result = getArticlesQuery(name)
  of "highlights": result = getHighlightsQuery(name)
  of "affiliates": result = Query(kind: affiliates, fromUser: @[name])
  of "search":
    result = initQuery(params(request), name=name)
    result.applyFeedDefaults(prefs)
  else: result = Query(fromUser: @[name])

template skipIf[T](cond: bool; default; body: Future[T]): Future[T] =
  if cond:
    let fut = newFuture[T]()
    fut.complete(default)
    fut
  else:
    body

proc fetchProfile*(after: string; query: Query; skipRail=false; forceRefresh=false): Future[Profile] {.async.} =
  let
    name = query.fromUser[0]
    userId = await getUserId(name)

  if userId.len == 0:
    return Profile(user: User(username: name))
  elif userId == "suspended":
    return Profile(user: User(username: name, suspended: true))

  # temporary fix to prevent errors from people browsing
  # timelines during/immediately after deployment
  var after = after
  if query.kind in {posts, replies} and after.startsWith("scroll"):
    after.setLen 0

  let
    useSurfaceCache = query.kind in {posts, replies, media, articles, highlights}
    surfaceCacheId = if useSurfaceCache: profileSurfaceCacheId(query, after) else: ""

  let
    rail =
      skipIf(skipRail or query.kind == media, @[]):
        getCachedPhotoRail(userId)

    user = getCachedUser(name)

  var cachedSurface = none(Profile)
  if useSurfaceCache and not forceRefresh:
    cachedSurface = await getCachedProfileSurface(surfaceCacheId)
    if cachedSurface.isSome:
      result = cachedSurface.get
      result.user = await user
      result.photoRail = await rail
      result.tweets.query = query
      return

  try:
    if useSurfaceCache and after.len == 0:
      let refreshKey = frontierRefreshKey("profile-surface", surfaceCacheId)
      let refreshed = await coalesceRefresh(refreshKey, proc(): Future[void] {.async.} =
        let live =
          case query.kind
          of posts: await getGraphUserTweets(userId, TimelineKind.tweets, after)
          of replies: await getGraphUserTweets(userId, TimelineKind.replies, after)
          of media: await getGraphUserTweets(userId, TimelineKind.media, after)
          of articles: await getGraphUserArticles(userId, after)
          of highlights: await getGraphUserHighlights(userId, after)
          of affiliates: Profile()
          else:
            if pureProfileTimelineQuery(query):
              Profile(tweets: await collectUserTimelineMatches(query, 20, after))
            else:
              Profile(tweets: await getGraphTweetSearch(query, after))
        await cacheProfileSurface(surfaceCacheId, live, after)
      )

      if refreshed:
        let nowCached = await getCachedProfileSurface(surfaceCacheId)
        if nowCached.isSome:
          result = nowCached.get
      else:
        let nowCached = await getCachedProfileSurface(surfaceCacheId)
        if nowCached.isSome:
          result = nowCached.get
        else:
          result =
            case query.kind
            of posts: await getGraphUserTweets(userId, TimelineKind.tweets, after)
            of replies: await getGraphUserTweets(userId, TimelineKind.replies, after)
            of media: await getGraphUserTweets(userId, TimelineKind.media, after)
            of articles: await getGraphUserArticles(userId, after)
            of highlights: await getGraphUserHighlights(userId, after)
            of affiliates: Profile()
            else:
              if pureProfileTimelineQuery(query):
                Profile(tweets: await collectUserTimelineMatches(query, 20, after))
              else:
                Profile(tweets: await getGraphTweetSearch(query, after))
      if result.user.id.len == 0 and result.tweets.query.text.len == 0 and result.tweets.content.len == 0 and result.tweets.bottom.len == 0:
        result =
          case query.kind
          of posts: await getGraphUserTweets(userId, TimelineKind.tweets, after)
          of replies: await getGraphUserTweets(userId, TimelineKind.replies, after)
          of media: await getGraphUserTweets(userId, TimelineKind.media, after)
          of articles: await getGraphUserArticles(userId, after)
          of highlights: await getGraphUserHighlights(userId, after)
          of affiliates: Profile()
          else:
            if pureProfileTimelineQuery(query):
              Profile(tweets: await collectUserTimelineMatches(query, 20, after))
            else:
              Profile(tweets: await getGraphTweetSearch(query, after))
    else:
      result =
        case query.kind
        of posts: await getGraphUserTweets(userId, TimelineKind.tweets, after)
        of replies: await getGraphUserTweets(userId, TimelineKind.replies, after)
        of media: await getGraphUserTweets(userId, TimelineKind.media, after)
        of articles: await getGraphUserArticles(userId, after)
        of highlights: await getGraphUserHighlights(userId, after)
        of affiliates: Profile()
        else:
          if pureProfileTimelineQuery(query):
            Profile(tweets: await collectUserTimelineMatches(query, 20, after))
          else:
            Profile(tweets: await getGraphTweetSearch(query, after))
  except RateLimitError, NoSessionsError, InternalError:
    if cachedSurface.isSome:
      result = cachedSurface.get
      result.tweets.errorText = "Showing cached profile surface. Live refresh is temporarily unavailable."
    elif query.kind in {posts, replies} and after.len == 0:
      let fallbackQuery =
        if query.kind == replies:
          Query(kind: tweets, fromUser: @[name], filters: @["replies"], sort: latest, scope: scopeAll, sep: "OR")
        else:
          Query(kind: tweets, fromUser: @[name], sort: latest, scope: scopeAll, sep: "OR")
      let searchFallback = await getGraphTweetSearch(fallbackQuery)
      if searchFallback.content.len > 0 or searchFallback.bottom.len > 0:
        result = Profile(tweets: searchFallback)
        result.tweets.errorText = "Showing search-backed profile results. Live timeline refresh is temporarily unavailable."
      else:
        result = Profile(
          tweets: Timeline(
            beginning: after.len == 0,
            query: query,
            errorText: "Current surface is temporarily unavailable."
          )
        )
    else:
      result = Profile(
        tweets: Timeline(
          beginning: after.len == 0,
          query: query,
          errorText: "Current surface is temporarily unavailable."
        )
      )

  result.user = await user
  result.photoRail = await rail

  result.tweets.query = query
  result = filterProfileByQuery(result, query)
  if useSurfaceCache:
    await cacheProfileSurface(surfaceCacheId, result, after)
  await cache(result.user)
  await cacheTimeline(result.tweets)
  if result.pinned.isSome:
    await cacheTweetGraph(result.pinned.get)

proc mergeTimelinePages(base: var Timeline; page: Timeline) =
  if base.query.fromUser.len == 0 and base.query.text.len == 0 and base.content.len == 0:
    base = page
    return
  if page.content.len > 0:
    base.content.add page.content
  base.bottom = page.bottom
  if base.errorText.len == 0:
    base.errorText = page.errorText

proc fetchProfileExportProfile*(query: Query; desiredLimit: int; forceRefresh=false): Future[Profile] {.async.} =
  result = await fetchProfile("", query, forceRefresh=forceRefresh)
  if desiredLimit <= 0:
    result = filterProfileByQuery(result, query)
    result.tweets = dedupeTimeline(result.tweets)
    return
  var
    nextCursor = result.tweets.bottom
    pages = 0
  while result.tweets.content.len < desiredLimit and nextCursor.len > 0 and pages < 25:
    let page = await fetchProfile(nextCursor, query, skipRail=true)
    mergeTimelinePages(result.tweets, page.tweets)
    if page.tweets.bottom.len == 0 or page.tweets.bottom == nextCursor:
      break
    nextCursor = page.tweets.bottom
    inc pages
  result = filterProfileByQuery(result, query)
  result.tweets = dedupeTimeline(result.tweets)

proc fetchProfileSearchExportTimeline*(query: Query; desiredLimit: int; forceRefresh=false): Future[Timeline] {.async.} =
  if pureProfileTimelineQuery(query):
    return await collectUserTimelineMatches(query, desiredLimit)
  var
    nextCursor = ""
    pages = 0
    merged = Timeline(query: query, beginning: true)
    pageBudget =
      if desiredLimit > 0:
        let pagesNeeded = max(1, (desiredLimit + 19) div 20)
        min(50, pagesNeeded + 3)
      else:
        25
  while true:
    let cacheId = searchTimelineCacheId(query, nextCursor)
    var page: Timeline
    if forceRefresh and pages == 0:
      page = await getGraphTweetSearch(query, nextCursor)
    else:
      let cached = await getCachedSearchTimeline(cacheId)
      if cached.isSome:
        page = cached.get
      elif nextCursor.len == 0:
        let refreshKey = frontierRefreshKey("search-export", cacheId)
        let refreshed = await coalesceRefresh(refreshKey, proc(): Future[void] {.async.} =
          let live = await getGraphTweetSearch(query, nextCursor)
          await cacheSearchTimeline(cacheId, live, nextCursor)
        )
        let nowCached = await getCachedSearchTimeline(cacheId)
        if nowCached.isSome:
          page = nowCached.get
        elif not refreshed:
          page = await getGraphTweetSearch(query, nextCursor)
        else:
          page = await getGraphTweetSearch(query, nextCursor)
      else:
        let live = await getGraphTweetSearch(query, nextCursor)
        await cacheSearchTimeline(cacheId, live, nextCursor)
        page = live
    page.query = query
    page = filterTimelineByQuery(page, query)
    await cacheTimeline(page)
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

proc buildProfileTabs*(user: User; activeKind: QueryKind): Future[ProfileTabState] {.async.} =
  result = await hydrateProfileTabs(user, activeKind)

proc showTimeline*(request: Request; query: Query; cfg: Config; prefs: Prefs;
                   rss, after: string): Future[string] {.async.} =
  if query.fromUser.len != 1:
    let
      timeline = await getGraphTweetSearch(query, after)
      html = renderTweetSearch(timeline, prefs, getPath())
    return renderMain(html, request, cfg, prefs, "Multi", rss=rss)

  var profile = await fetchProfile(after, query, skipRail=prefs.hideMediaRail)
  template u: untyped = profile.user

  if u.suspended:
    return showError(getSuspended(u.username), cfg)

  if profile.user.id.len == 0: return

  let ownerId = currentFinchOwnerId(request)
  let profileActions = getProfileActions(ownerId, profile.user, getPath())
  let tabs = await buildProfileTabs(profile.user, query.kind)
  let pHtml =
    if query.kind == affiliates:
      let affiliates = await fetchAffiliatesProfile(profile.user.id, after)
      renderProfileAffiliates(profile.user, affiliates, prefs, getPath(), ownerId, profileActions, tabs)
    else:
      renderProfile(profile, prefs, getPath(), profileActions, tabs)
  result = renderMain(pHtml, request, cfg, prefs, pageTitle(u), pageDesc(u),
                      rss=rss, images = @[u.getUserPic("_400x400")],
                      banner=u.banner)

template respTimeline*(timeline: typed) =
  let t = timeline
  if t.len == 0:
    resp Http404, showError("User \"" & @"name" & "\" not found", cfg)
  resp t

template respUserId*() =
  cond @"user_id".len > 0
  let username = await getCachedUsername(@"user_id")
  if username.len > 0:
    redirect("/" & username)
  else:
    resp Http404, showError("User not found", cfg)

proc createTimelineRouter*(cfg: Config) =
  router timeline:
    get "/@name/articles/@fmt/?":
      condValidUsername(@"name")
      cond @"fmt" in ["json", "md", "txt"]

      let query = getArticlesQuery(@"name")
      let exportLimit = normalizeExportLimit(request.params.getOrDefault("limit"))
      let selectedRaw = exportSelectionRaw(request.params.getOrDefault("selected_ids"),
                                           request.params.getOrDefault("limit"))
      let profile = limitProfile(filterProfileBySelected(await fetchProfileExportProfile(query, exportLimit, forceRefresh=true), selectedRaw), exportLimit)

      if profile.user.suspended:
        resp Http404, showError(getSuspended(profile.user.username), cfg)

      if profile.user.id.len == 0:
        resp Http404, showError("User \"" & @"name" & "\" not found", cfg)

      case @"fmt"
      of "json":
        respJson profileToJson(profile, cfg, selectedRaw, exportLimit)
      of "md":
        resp profileToMarkdown(profile, cfg), "text/markdown; charset=utf-8"
      of "txt":
        resp profileToText(profile, cfg), "text/plain; charset=utf-8"
      else:
        resp Http404

    get "/@name/articles/live/json":
      condValidUsername(@"name")

      let query = getArticlesQuery(@"name")
      let exportLimit = normalizeExportLimit(request.params.getOrDefault("limit"))
      let selectedRaw = exportSelectionRaw(request.params.getOrDefault("selected_ids"),
                                           request.params.getOrDefault("limit"))
      let profile = limitProfile(filterProfileBySelected(await fetchProfileExportProfile(query, exportLimit, forceRefresh=true), selectedRaw), exportLimit)

      if profile.user.suspended:
        resp Http404, showError(getSuspended(profile.user.username), cfg)
      if profile.user.id.len == 0:
        resp Http404, showError("User \"" & @"name" & "\" not found", cfg)

      respJson wrapLivePayload("profile_live", profileToJson(profile, cfg, selectedRaw, exportLimit))

    get "/@name/highlights/@fmt/?":
      condValidUsername(@"name")
      cond @"fmt" in ["json", "md", "txt"]

      let query = getHighlightsQuery(@"name")
      let exportLimit = normalizeExportLimit(request.params.getOrDefault("limit"))
      let selectedRaw = exportSelectionRaw(request.params.getOrDefault("selected_ids"),
                                           request.params.getOrDefault("limit"))
      let profile = limitProfile(filterProfileBySelected(await fetchProfileExportProfile(query, exportLimit, forceRefresh=true), selectedRaw), exportLimit)

      if profile.user.suspended:
        resp Http404, showError(getSuspended(profile.user.username), cfg)

      if profile.user.id.len == 0:
        resp Http404, showError("User \"" & @"name" & "\" not found", cfg)

      case @"fmt"
      of "json":
        respJson profileToJson(profile, cfg, selectedRaw, exportLimit)
      of "md":
        resp profileToMarkdown(profile, cfg), "text/markdown; charset=utf-8"
      of "txt":
        resp profileToText(profile, cfg), "text/plain; charset=utf-8"
      else:
        resp Http404

    get "/@name/highlights/live/json":
      condValidUsername(@"name")

      let query = getHighlightsQuery(@"name")
      let exportLimit = normalizeExportLimit(request.params.getOrDefault("limit"))
      let selectedRaw = exportSelectionRaw(request.params.getOrDefault("selected_ids"),
                                           request.params.getOrDefault("limit"))
      let profile = limitProfile(filterProfileBySelected(await fetchProfileExportProfile(query, exportLimit), selectedRaw), exportLimit)

      if profile.user.suspended:
        resp Http404, showError(getSuspended(profile.user.username), cfg)
      if profile.user.id.len == 0:
        resp Http404, showError("User \"" & @"name" & "\" not found", cfg)

      respJson wrapLivePayload("profile_live", profileToJson(profile, cfg, selectedRaw, exportLimit))

    get "/@name/affiliates/@fmt/?":
      condValidUsername(@"name")
      cond @"fmt" in ["json", "md", "txt"]

      let
        username = @"name"
        user = await getCachedUser(username)

      if user.suspended:
        resp Http404, showError(getSuspended(username), cfg)
      if user.id.len == 0:
        resp Http404, showError("User \"" & username & "\" not found", cfg)

      let exportLimit = normalizeExportLimit(request.params.getOrDefault("limit"))
      var affiliateResults = limitUserResults(await fetchAffiliatesProfile(user.id, getCursor()), exportLimit)
      affiliateResults.query = Query(kind: affiliates, fromUser: @[username])

      case @"fmt"
      of "json":
        respJson userSearchToJson(affiliateResults)
      of "md":
        resp userSearchToMarkdown(affiliateResults), "text/markdown; charset=utf-8"
      of "txt":
        resp userSearchToText(affiliateResults), "text/plain; charset=utf-8"
      else:
        resp Http404

    get "/@name/affiliates/live/json":
      condValidUsername(@"name")

      let
        username = @"name"
        user = await getCachedUser(username)

      if user.suspended:
        resp Http404, showError(getSuspended(username), cfg)
      if user.id.len == 0:
        resp Http404, showError("User \"" & username & "\" not found", cfg)

      let exportLimit = normalizeExportLimit(request.params.getOrDefault("limit"))
      var affiliateResults = limitUserResults(await fetchAffiliatesProfile(user.id, getCursor()), exportLimit)
      affiliateResults.query = Query(kind: affiliates, fromUser: @[username])
      respJson wrapLivePayload("profile_affiliates_live", userSearchToJson(affiliateResults))

    get "/@name/lists/@fmt/?":
      condValidUsername(@"name")
      cond @"fmt" in ["json", "md", "txt"]

      let
        username = @"name"
        user = await getCachedUser(username)

      if user.suspended:
        resp Http404, showError(getSuspended(username), cfg)

      if user.id.len == 0:
        resp Http404, showError("User \"" & username & "\" not found", cfg)

      let exportLimit = normalizeExportLimit(request.params.getOrDefault("limit"))
      var lists = await getGraphUserLists(user.id, getCursor())
      if exportLimit > 0 and lists.content.len > exportLimit:
        lists.content = lists.content[0 ..< exportLimit]
        lists.bottom = ""
      lists.query = getListsQuery(username)

      case @"fmt"
      of "json":
        respJson profileListsToJson(user, lists)
      of "md":
        resp profileListsToMarkdown(user, lists), "text/markdown; charset=utf-8"
      of "txt":
        resp profileListsToText(user, lists), "text/plain; charset=utf-8"
      else:
        resp Http404

    get "/@name/lists/live/json":
      condValidUsername(@"name")

      let
        username = @"name"
        user = await getCachedUser(username)

      if user.suspended:
        resp Http404, showError(getSuspended(username), cfg)
      if user.id.len == 0:
        resp Http404, showError("User \"" & username & "\" not found", cfg)

      let exportLimit = normalizeExportLimit(request.params.getOrDefault("limit"))
      var lists = await getGraphUserLists(user.id, getCursor())
      if exportLimit > 0 and lists.content.len > exportLimit:
        lists.content = lists.content[0 ..< exportLimit]
        lists.bottom = ""
      lists.query = getListsQuery(username)
      await cache(user)
      respJson wrapLivePayload("profile_lists_live", profileListsToJson(user, lists))

    get "/@name/article/?":
      condValidUsername(@"name")
      redirect("/" & @"name" & "/articles")

    get "/@name/affiliate/?":
      condValidUsername(@"name")
      redirect("/" & @"name" & "/affiliates")

    get "/@name/highlight/?":
      condValidUsername(@"name")
      redirect("/" & @"name" & "/highlights")

    get "/@name/list/?":
      condValidUsername(@"name")
      redirect("/" & @"name" & "/lists")

    get "/@name/with_replies/@fmt/?":
      condValidUsername(@"name")
      redirect("/" & @"name" & "/search?q=" & encodeUrl("filter:replies"))

    get "/@name/with_replies/?":
      condValidUsername(@"name")
      redirect("/" & @"name" & "/search?q=" & encodeUrl("filter:replies"))

    get "/@name/with_replies/live/json":
      condValidUsername(@"name")
      redirect("/" & @"name" & "/search/live/json?q=" & encodeUrl("filter:replies"))

    get "/@name/media/@fmt/?":
      condValidUsername(@"name")
      cond @"fmt" in ["json", "md", "txt"]

      let query = getMediaQuery(@"name")
      let exportLimit = normalizeExportLimit(request.params.getOrDefault("limit"))
      let selectedRaw = request.params.getOrDefault("selected_ids")
      let profile = limitProfile(filterProfileBySelected(await fetchProfileExportProfile(query, exportLimit), selectedRaw), exportLimit)

      if profile.user.suspended:
        resp Http404, showError(getSuspended(profile.user.username), cfg)

      if profile.user.id.len == 0:
        resp Http404, showError("User \"" & @"name" & "\" not found", cfg)

      case @"fmt"
      of "json":
        respJson profileToJson(profile, cfg, selectedRaw, exportLimit)
      of "md":
        resp profileToMarkdown(profile, cfg), "text/markdown; charset=utf-8"
      of "txt":
        resp profileToText(profile, cfg), "text/plain; charset=utf-8"
      else:
        resp Http404

    get "/@name/media/live/json":
      condValidUsername(@"name")

      let query = getMediaQuery(@"name")
      let exportLimit = normalizeExportLimit(request.params.getOrDefault("limit"))
      let selectedRaw = request.params.getOrDefault("selected_ids")
      let profile = limitProfile(filterProfileBySelected(await fetchProfileExportProfile(query, exportLimit), selectedRaw), exportLimit)

      if profile.user.suspended:
        resp Http404, showError(getSuspended(profile.user.username), cfg)
      if profile.user.id.len == 0:
        resp Http404, showError("User \"" & @"name" & "\" not found", cfg)

      respJson wrapLivePayload("profile_live", profileToJson(profile, cfg, selectedRaw, exportLimit))

    get "/@name/search/@fmt/?":
      condValidUsername(@"name")
      cond @"fmt" in ["json", "md", "txt"]
      var query = initQuery(params(request), name = @"name")
      query.applyFeedDefaults(requestPrefs())
      let exportLimit = normalizeExportLimit(request.params.getOrDefault("limit"))
      let selectedRaw = exportSelectionRaw(request.params.getOrDefault("selected_ids"),
                                           request.params.getOrDefault("limit"))
      let results = limitTimeline(filterTimelineBySelected(await fetchProfileSearchExportTimeline(query, exportLimit, forceRefresh=true), selectedRaw), exportLimit)

      case @"fmt"
      of "json":
        respJson searchTimelineToJson(results, cfg, selectedRaw, exportLimit)
      of "md":
        resp searchTimelineToMarkdown(results, cfg), "text/markdown; charset=utf-8"
      of "txt":
        resp searchTimelineToText(results, cfg), "text/plain; charset=utf-8"
      else:
        resp Http404

    get "/@name/search/live/json":
      condValidUsername(@"name")
      var query = initQuery(params(request), name = @"name")
      query.applyFeedDefaults(requestPrefs())
      let exportLimit = normalizeExportLimit(request.params.getOrDefault("limit"))
      let selectedRaw = exportSelectionRaw(request.params.getOrDefault("selected_ids"),
                                           request.params.getOrDefault("limit"))
      let results = limitTimeline(filterTimelineBySelected(await fetchProfileSearchExportTimeline(query, exportLimit), selectedRaw), exportLimit)
      respJson wrapLivePayload("search_live", searchTimelineToJson(results, cfg, selectedRaw, exportLimit))

    get "/@name/@fmt/?":
      condValidUsername(@"name")
      cond @"fmt" in ["json", "md", "txt"]

      let query = Query(fromUser: @[@"name"])
      let exportLimit = normalizeExportLimit(request.params.getOrDefault("limit"))
      let selectedRaw = exportSelectionRaw(request.params.getOrDefault("selected_ids"),
                                           request.params.getOrDefault("limit"))
      let profile = limitProfile(filterProfileBySelected(await fetchProfileExportProfile(query, exportLimit, forceRefresh=true), selectedRaw), exportLimit)

      if profile.user.suspended:
        resp Http404, showError(getSuspended(profile.user.username), cfg)

      if profile.user.id.len == 0:
        resp Http404, showError("User \"" & @"name" & "\" not found", cfg)

      case @"fmt"
      of "json":
        respJson profileToJson(profile, cfg, selectedRaw, exportLimit)
      of "md":
        resp profileToMarkdown(profile, cfg), "text/markdown; charset=utf-8"
      of "txt":
        resp profileToText(profile, cfg), "text/plain; charset=utf-8"
      else:
        resp Http404

    get "/@name/live/json":
      condValidUsername(@"name")

      let query = Query(fromUser: @[@"name"])
      let exportLimit = normalizeExportLimit(request.params.getOrDefault("limit"))
      let selectedRaw = exportSelectionRaw(request.params.getOrDefault("selected_ids"),
                                           request.params.getOrDefault("limit"))
      let profile = limitProfile(filterProfileBySelected(await fetchProfileExportProfile(query, exportLimit), selectedRaw), exportLimit)

      if profile.user.suspended:
        resp Http404, showError(getSuspended(profile.user.username), cfg)
      if profile.user.id.len == 0:
        resp Http404, showError("User \"" & @"name" & "\" not found", cfg)

      respJson wrapLivePayload("profile_live", profileToJson(profile, cfg, selectedRaw, exportLimit))

    get "/i/user/@user_id":
      respUserId()

    get "/intent/user":
      respUserId()

    get "/intent/follow/?":
      let username = request.params.getOrDefault("screen_name")
      if username.len == 0:
        resp Http400, showError("Missing screen_name parameter", cfg)
      redirect("/" & username)

    get "/@name/?@tab?/?":
      condValidUsername(@"name")
      cond @"tab" in ["media", "articles", "highlights", "affiliates", "search", ""]
      let
        prefs = requestPrefs()
        after = getCursor()
        names = getNames(@"name")

      var query = request.getQuery(@"tab", @"name", prefs)
      if names.len != 1:
        query.fromUser = names

      # used for the infinite scroll feature
      if @"scroll".len > 0:
        if query.fromUser.len != 1:
          var timeline = await getGraphTweetSearch(query, after)
          if timeline.content.len == 0: 
            resp Http204
          timeline.beginning = true
          resp $renderTweetSearch(timeline, prefs, getPath())
        else:
          var profile = await fetchProfile(after, query, skipRail=true)
          if profile.tweets.content.len == 0: resp Http204
          profile.tweets.beginning = true
          resp $renderTimelineTweets(profile.tweets, prefs, getPath())

      let rssEnabled =
        if @"tab".len == 0: cfg.enableRSSUserTweets
        elif @"tab" == "media": cfg.enableRSSUserMedia
        elif @"tab" == "articles": cfg.enableRSSUserTweets
        elif @"tab" == "highlights": cfg.enableRSSUserTweets
        elif @"tab" == "affiliates": false
        elif @"tab" == "search": cfg.enableRSSSearch
        else: false

      let rss =
        if not rssEnabled: 
          ""
        elif @"tab".len == 0:
          "/$1/rss" % @"name"
        elif @"tab" == "search":
          "/$1/search/rss?$2" % [@"name", genQueryUrl(query)]
        else:
          "/$1/$2/rss" % [@"name", @"tab"]

      respTimeline(await showTimeline(request, query, cfg, prefs, rss, after))

    get "/@name/lists/?":
      condValidUsername(@"name")
      let
        prefs = requestPrefs()
        username = @"name"
        user = await getCachedUser(username)

      if user.suspended:
        resp Http404, showError(getSuspended(username), cfg)

      if user.id.len == 0:
        resp Http404, showError("User \"" & username & "\" not found", cfg)

      var lists = await getGraphUserLists(user.id, getCursor())
      lists.query = getListsQuery(username)

      let profileActions = getProfileActions(currentFinchOwnerId(request), user, getPath())
      let tabs = await buildProfileTabs(user, lists.query.kind)
      let html = renderProfileLists(user, lists, prefs, getPath(), profileActions, tabs)
      resp renderMain(html, request, cfg, prefs, pageTitle(user), pageDesc(user), images = @[user.getUserPic("_400x400")], banner=user.banner)
