# SPDX-License-Identifier: AGPL-3.0-only
import asyncdispatch, tables, times, hashes, uri

import jester

import router_utils, timeline
import ../[query, types, following_scope, redis_cache]
import ../local_identity

include "../views/rss.nimf"

export times, hashes

proc redisKey*(page, name, cursor: string): string =
  result = page & ":" & name
  if cursor.len > 0:
    result &= ":" & cursor

proc timelineRss*(req: Request; cfg: Config; query: Query; prefs: Prefs): Future[Rss] {.async.} =
  var profile: Profile
  let
    name = req.params.getOrDefault("name")
    after = getCursor(req)
    names = getNames(name)

  if names.len == 1:
    profile = await fetchProfile(after, query, skipRail=true)
  else:
    var q = query
    q.fromUser = names
    profile.tweets = await getGraphTweetSearch(q, after)
    profile.tweets.query = q
    profile.tweets = filterTimelineByQuery(profile.tweets, q)
    # this is kinda dumb
    profile.user = User(
      username: name,
      fullname: names.join(" | "),
      userpic: "https://abs.twimg.com/sticky/default_profile_images/default_profile.png"
    )

  if profile.user.suspended:
    return Rss(feed: profile.user.username, cursor: "suspended")

  if profile.user.fullname.len > 0:
    let rss = renderTimelineRss(profile, cfg, prefs, multi=(names.len > 1))
    return Rss(feed: rss, cursor: profile.tweets.bottom)

proc fetchSearchRssTimeline*(req: Request; query: Query; cursor: string): Future[Timeline] {.async.} =
  result = await getGraphTweetSearch(query, cursor)
  result.query = query

  if query.scope == scopeFollowing:
    let ownerId = getFinchOwnerId(req)
    if ownerId.len == 0:
      return
    result = filterTimelineToFollowing(result, ownerId)
  result = filterTimelineByQuery(result, query)

template respRss*(rss, page) =
  if rss.cursor.len == 0:
    let info = case page
               of "User": " \"" & @"name" & "\" "
               of "List": " \"" & @"id" & "\" "
               else: " "

    resp Http404, showError(page & info & "not found", cfg)
  elif rss.cursor.len == 9 and rss.cursor == "suspended":
    resp Http404, showError(getSuspended(@"name"), cfg)

  let headers = {"Content-Type": "application/rss+xml; charset=utf-8",
                 "Min-Id": rss.cursor}
  resp Http200, headers, rss.feed

proc createRssRouter*(cfg: Config) =
  router rss:
    get "/search/rss":
      if not cfg.enableRSSSearch:
        resp Http403, showError("RSS feed is disabled", cfg)
      if @"q".len > 200:
        resp Http400, showError("Search input too long.", cfg)

      let prefs = requestPrefs()
      var query = initQuery(params(request))
      query.applyFeedDefaults(prefs)
      if query.kind != tweets:
        resp Http400, showError("Only Tweet searches are allowed for RSS feeds.", cfg)

      let
        cursor = getCursor()
        key = redisKey("search", $hash(genQueryUrl(query)), cursor)

      var rss = await getCachedRss(key)
      if rss.cursor.len > 0:
        respRss(rss, "Search")

      if query.scope == scopeFollowing:
        if getFinchOwnerId(request).len == 0:
          resp Http401, showError("Finch identity is required for following-scoped RSS.", cfg)
      let tweets = await fetchSearchRssTimeline(request, query, cursor)
      await cacheTimeline(tweets)
      rss.cursor = tweets.bottom
      rss.feed = renderSearchRss(tweets.content, displayQuery(query), genQueryUrl(query), cfg, prefs)

      await cacheRss(key, rss)
      respRss(rss, "Search")

    get "/@name/rss":
      condValidUsername(@"name")
      if not cfg.enableRSSUserTweets:
        resp Http403, showError("RSS feed is disabled", cfg)
      let
        prefs = requestPrefs()
        name = @"name"
        key = redisKey("twitter", name, getCursor())

      var rss = await getCachedRss(key)
      if rss.cursor.len > 0:
        respRss(rss, "User")

      rss = await timelineRss(request, cfg, Query(fromUser: @[name]), prefs)

      await cacheRss(key, rss)
      respRss(rss, "User")

    get "/@name/@tab/rss":
      condValidUsername(@"name")
      cond @"tab" in ["media", "articles", "highlights", "search"]
      let rssEnabled = case @"tab"
        of "media": cfg.enableRSSUserMedia
        of "articles": cfg.enableRSSUserTweets
        of "highlights": cfg.enableRSSUserTweets
        of "search": cfg.enableRSSSearch
        else: false
      if not rssEnabled:
        resp Http403, showError("RSS feed is disabled", cfg)
      let
        prefs = requestPrefs()
        name = @"name"
        tab = @"tab"
        query =
          case tab
          of "media": getMediaQuery(name)
          of "articles": getArticlesQuery(name)
          of "highlights": getHighlightsQuery(name)
          of "search": initQuery(params(request), name=name)
          else: Query(fromUser: @[name])

      let searchKey = if tab != "search": ""
                      else: ":" & $hash(genQueryUrl(query))

      let key = redisKey(tab, name & searchKey, getCursor())

      var rss = await getCachedRss(key)
      if rss.cursor.len > 0:
        respRss(rss, "User")

      rss = await timelineRss(request, cfg, query, prefs)

      await cacheRss(key, rss)
      respRss(rss, "User")

    get "/@name/lists/@slug/rss":
      condValidUsername(@"name")
      if not cfg.enableRSSList:
        resp Http403, showError("RSS feed is disabled", cfg)
      let
        slug = decodeUrl(@"slug")
        list = await getCachedList(@"name", slug)
        cursor = getCursor()

      if list.id.len == 0:
        resp Http404, showError("List \"" & @"slug" & "\" not found", cfg)

      let url = "/i/lists/" & list.id & "/rss"
      if cursor.len > 0:
        redirect(url & "?cursor=" & encodeUrl(cursor, false))
      else:
        redirect(url)

    get "/i/lists/@id/rss":
      if not cfg.enableRSSList:
        resp Http403, showError("RSS feed is disabled", cfg)
      let
        prefs = requestPrefs()
        id = @"id"
        cursor = getCursor()
        key = redisKey("lists", id, cursor)

      var rss = await getCachedRss(key)
      if rss.cursor.len > 0:
        respRss(rss, "List")

      let
        list = await getCachedList(id=id)
        timeline = await getGraphListTweets(list.id, cursor)
      rss.cursor = timeline.bottom
      rss.feed = renderListRss(timeline.content, list, cfg, prefs)

      await cacheRss(key, rss)
      respRss(rss, "List")
