# SPDX-License-Identifier: AGPL-3.0-only
import strutils, strformat, uri, tables, sequtils, times, options

import jester

import router_utils
import ".."/[types, redis_cache, api]
from .. / refresh_coordinator import coalesceRefresh
import ../exporters
import ../views/[general, timeline, list]

export exporters

const
  hotListTimelineTtl = 5 * 60

type HotListTimelineEntry = object
  expiresAt: int64
  timeline: Timeline

var hotListTimelines: Table[string, HotListTimelineEntry]

proc listHotCacheKey*(listId, cursor: string): string =
  listId & ":" & cursor

proc listSurfaceCacheId*(listId, cursor: string): string =
  listId & "|" & cursor

proc frontierRefreshKey(kind, cacheId: string): string =
  if cacheId.len == 0:
    return ""
  kind & ":" & cacheId

proc getHotListTimeline*(listId, cursor: string): Option[Timeline] =
  let
    key = listHotCacheKey(listId, cursor)
    nowTs = epochTime().int64
  if key in hotListTimelines:
    let entry = hotListTimelines[key]
    if entry.expiresAt > nowTs:
      return some(entry.timeline)
    hotListTimelines.del(key)
  none(Timeline)

proc cacheHotListTimeline*(listId, cursor: string; timeline: Timeline) =
  if listId.len == 0:
    return
  hotListTimelines[listHotCacheKey(listId, cursor)] = HotListTimelineEntry(
    expiresAt: epochTime().int64 + hotListTimelineTtl,
    timeline: timeline
  )

template respList*(list, timeline, title, vnode: typed) =
  if list.id.len == 0:
    resp Http404, showError(&"""List "{@"id"}" not found""", cfg)

  let
    html = renderList(vnode, timeline.query, list)
    rss = if cfg.enableRSSList: &"""/i/lists/{@"id"}/rss""" else: ""

  resp renderMain(html, request, cfg, prefs, titleText=title, rss=rss, banner=list.banner)

template respListMembers*(list, members, title: typed) =
  if list.id.len == 0:
    resp Http404, showError(&"""List "{@"id"}" not found""", cfg)

  let
    html = renderList(renderListMembers(members), members.query, list)
    rss = if cfg.enableRSSList: &"""/i/lists/{@"id"}/rss""" else: ""

  resp renderMain(html, request, cfg, prefs, titleText=title, rss=rss, banner=list.banner)

proc title*(list: List): string =
  if list.name.len == 0:
    return "X List"
  if list.username.len == 0:
    return list.name
  &"@{list.username}/{list.name}"

proc unavailableListTimeline*(list: List): Timeline =
  Timeline(
    beginning: true,
    query: Query(kind: posts),
    errorText: "This X list could not be refreshed right now."
  )

proc unavailableListMembers*(): Result[User] =
  Result[User](
    beginning: true,
    query: Query(kind: userList),
    errorText: "This X list member roster could not be refreshed right now."
  )

proc mergeTimelinePages(base: var Timeline; page: Timeline) =
  if base.content.len == 0 and base.query.text.len == 0 and not base.beginning:
    base = page
    return
  if page.content.len > 0:
    base.content.add page.content
  base.bottom = page.bottom
  if base.errorText.len == 0:
    base.errorText = page.errorText

proc fetchListExportTimeline*(listId, cursor: string; desiredLimit: int; forceRefresh=false): Future[Timeline] {.async.} =
  var
    nextCursor = cursor
    pages = 0
    merged = Timeline(beginning: cursor.len == 0)
  while true:
    let cacheId = listSurfaceCacheId(listId, nextCursor)
    let page =
      if forceRefresh and pages == 0:
        await getGraphListTweets(listId, nextCursor)
      else:
        let cached = await getCachedListTimeline(cacheId)
        if cached.isSome:
          cached.get
        elif nextCursor.len == 0:
          let refreshed = await coalesceRefresh(frontierRefreshKey("list-export", cacheId), proc(): Future[void] {.async.} =
            let live = await getGraphListTweets(listId, nextCursor)
            await cacheListTimeline(cacheId, live, nextCursor)
          )
          let nowCached = await getCachedListTimeline(cacheId)
          if nowCached.isSome:
            nowCached.get
          elif not refreshed:
            await getGraphListTweets(listId, nextCursor)
          else:
            await getGraphListTweets(listId, nextCursor)
        else:
          let live = await getGraphListTweets(listId, nextCursor)
          await cacheListTimeline(cacheId, live, nextCursor)
          live
    mergeTimelinePages(merged, page)
    inc pages
    if desiredLimit <= 0 or merged.content.len >= desiredLimit:
      break
    if page.bottom.len == 0 or page.bottom == nextCursor or pages >= 25:
      break
    nextCursor = page.bottom
  result = dedupeTimeline(merged)

proc createListRouter*(cfg: Config) =
  router list:
    get "/@name/lists/@slug/@fmt/?":
      condValidUsername(@"name")
      cond @"slug" != "memberships"
      cond @"fmt" in ["json", "md", "txt"]
      let
        fmt = @"fmt"
        slug = decodeUrl(@"slug")
        list = await getCachedList(@"name", slug)
      if list.id.len == 0:
        resp Http404, showError(&"""List "{@"slug"}" not found""", cfg)
      redirect(&"/i/lists/{list.id}/{fmt}")

    get "/@name/lists/@slug/members/@fmt/?":
      condValidUsername(@"name")
      cond @"slug" != "memberships"
      cond @"fmt" in ["json", "md", "txt"]
      let
        fmt = @"fmt"
        slug = decodeUrl(@"slug")
        list = await getCachedList(@"name", slug)
      if list.id.len == 0:
        resp Http404, showError(&"""List "{@"slug"}" not found""", cfg)
      redirect(&"/i/lists/{list.id}/members/{fmt}")

    get "/@name/lists/@slug/?":
      condValidUsername(@"name")
      cond @"slug" != "memberships"
      let
        slug = decodeUrl(@"slug")
        list = await getCachedList(@"name", slug)
      if list.id.len == 0:
        resp Http404, showError(&"""List "{@"slug"}" not found""", cfg)
      redirect(&"/i/lists/{list.id}")

    get "/i/lists/@id/?":
      cond '.' notin @"id"
      let
        prefs = requestPrefs()
        requestedId = @"id"
        cursor = getCursor()
      var list = await getCachedList(id=requestedId)
      if list.id.len == 0:
        list = List(id: requestedId, name: "X List")
      var timeline = unavailableListTimeline(list)
      let redisCached =
        if list.id.len > 0: await getCachedListTimeline(listSurfaceCacheId(list.id, cursor))
        else: none(Timeline)
      let hotCached = getHotListTimeline(list.id, cursor)
      if redisCached.isSome:
        timeline = redisCached.get
      elif hotCached.isSome:
        timeline = hotCached.get
      else:
        try:
          let cacheId = listSurfaceCacheId(list.id, cursor)
          if cursor.len == 0:
            timeline = await getGraphListTweets(list.id, cursor)
            await cacheTimeline(timeline)
            cacheHotListTimeline(list.id, cursor, timeline)
            await cacheListTimeline(cacheId, timeline, cursor)
          else:
            timeline = await getGraphListTweets(list.id, cursor)
            await cacheTimeline(timeline)
            cacheHotListTimeline(list.id, cursor, timeline)
            await cacheListTimeline(cacheId, timeline, cursor)
        except RateLimitError, NoSessionsError, InternalError, BadClientError:
          if hotCached.isSome:
            timeline = hotCached.get
            timeline.errorText = "Showing cached X list results. Live refresh is temporarily unavailable."
      await cache(list)
      let
        vnode = renderTimelineTweets(timeline, prefs, request.path,
          emptyMessage="No posts are available for this X list right now.",
          exportFormId=("export-public-list-" & list.id))
      respList(list, timeline, list.title, vnode)

    get "/i/lists/@id/live/json":
      cond '.' notin @"id"
      let
        list = await getCachedList(id=(@"id"))
        exportLimit = normalizeExportLimit(request.params.getOrDefault("limit"))
        selectedRaw = exportSelectionRaw(request.params.getOrDefault("selected_ids"),
                                         request.params.getOrDefault("limit"))
      var timeline = unavailableListTimeline(list)
      try:
        timeline = await fetchListExportTimeline(list.id, getCursor(), exportLimit, forceRefresh=true)
        await cacheTimeline(timeline)
      except RateLimitError, NoSessionsError, InternalError, BadClientError:
        discard
      timeline = limitTimeline(filterTimelineBySelected(timeline, selectedRaw), exportLimit)
      await cache(list)

      if list.id.len == 0 or list.name.len == 0:
        resp Http404, showError(&"""List "{@"id"}" not found""", cfg)

      respJson wrapLivePayload("list_live", listTimelineToJson(list, timeline, cfg, selectedRaw, exportLimit))

    get "/i/lists/@id/@fmt/?":
      cond '.' notin @"id"
      cond @"fmt" in ["json", "md", "txt"]
      let
        list = await getCachedList(id=(@"id"))
        exportLimit = normalizeExportLimit(request.params.getOrDefault("limit"))
        selectedRaw = exportSelectionRaw(request.params.getOrDefault("selected_ids"),
                                         request.params.getOrDefault("limit"))
      var timeline = unavailableListTimeline(list)
      try:
        timeline = await fetchListExportTimeline(list.id, getCursor(), exportLimit)
        await cacheTimeline(timeline)
      except RateLimitError, NoSessionsError, InternalError, BadClientError:
        discard
      timeline = limitTimeline(filterTimelineBySelected(timeline, selectedRaw), exportLimit)
      await cache(list)

      if list.id.len == 0 or list.name.len == 0:
        resp Http404, showError(&"""List "{@"id"}" not found""", cfg)

      case @"fmt"
      of "json":
        respJson listTimelineToJson(list, timeline, cfg, selectedRaw, exportLimit)
      of "md":
        resp listTimelineToMarkdown(list, timeline, cfg), "text/markdown; charset=utf-8"
      of "txt":
        resp listTimelineToText(list, timeline, cfg), "text/plain; charset=utf-8"
      else:
        resp Http404

    get "/i/lists/@id/members":
      cond '.' notin @"id"
      let
        prefs = requestPrefs()
        list = await getCachedList(id=(@"id"))
      var members = unavailableListMembers()
      try:
        members = await getGraphListMembers(list, getCursor())
      except RateLimitError, NoSessionsError, InternalError, BadClientError:
        discard
      respListMembers(list, members, list.title)

    get "/i/lists/@id/members/@fmt/?":
      cond '.' notin @"id"
      cond @"fmt" in ["json", "md", "txt"]
      let
        list = await getCachedList(id=(@"id"))
        exportLimit = normalizeExportLimit(request.params.getOrDefault("limit"))
      var members = unavailableListMembers()
      try:
        members = await getGraphListMembers(list, getCursor())
      except RateLimitError, NoSessionsError, InternalError, BadClientError:
        discard

      if list.id.len == 0 or list.name.len == 0:
        resp Http404, showError(&"""List "{@"id"}" not found""", cfg)

      case @"fmt"
      of "json":
        respJson listMembersToJson(list, limitUserResults(members, exportLimit))
      of "md":
        resp listMembersToMarkdown(list, limitUserResults(members, exportLimit)), "text/markdown; charset=utf-8"
      of "txt":
        resp listMembersToText(list, limitUserResults(members, exportLimit)), "text/plain; charset=utf-8"
      else:
        resp Http404
