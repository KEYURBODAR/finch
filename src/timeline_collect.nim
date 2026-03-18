# SPDX-License-Identifier: AGPL-3.0-only
import asyncdispatch, sets, hashes, strutils, options

import types, query, api, exporters, redis_cache

proc collectTimelineCacheId(query: Query; desiredLimit: int; cursor: string): string =
  let scope =
    [
      $query.kind,
      $query.sort,
      $query.scope,
      query.text,
      query.filters.join(","),
      query.includes.join(","),
      query.excludes.join(","),
      query.fromUser.join(","),
      query.toUser.join(","),
      query.mentions.join(","),
      query.since,
      query.until,
      query.minLikes,
      query.minRetweets,
      query.minReplies,
      $desiredLimit,
      cursor
    ].join("|")
  $hash(scope)

proc mergeTimelinePages(base: var Timeline; page: Timeline) =
  if page.content.len > 0:
    base.content.add page.content
  base.bottom = page.bottom
  if base.errorText.len == 0:
    base.errorText = page.errorText

proc collectUserTimelineMatches*(query: Query; desiredLimit: int; cursor=""): Future[Timeline] {.async.} =
  result = Timeline(query: query, beginning: cursor.len == 0)
  if query.fromUser.len != 1:
    return

  let cacheId = collectTimelineCacheId(query, desiredLimit, cursor)
  let cached = await getCachedCollectTimeline(cacheId)
  if cached.isSome:
    return cached.get

  let user = await getGraphUser(query.fromUser[0])
  if user.id.len == 0:
    return

  var
    nextCursor = cursor
    pages = 0
    seenCursors = initHashSet[string]()
    merged = Timeline(query: query, beginning: cursor.len == 0)
    pageBudget =
      if desiredLimit > 0:
        let pagesNeeded = max(1, (desiredLimit + 19) div 20)
        min(50, pagesNeeded + 3)
      else:
        25

  while true:
    let pageSize = if desiredLimit > 0: min(100, max(20, desiredLimit - merged.content.len)) else: 100
    let profile = await getGraphUserTweets(user.id, TimelineKind.tweets, nextCursor, pageSize)
    var page = profile.tweets
    page.query = query
    page = dedupeTimeline(filterTimelineByQuery(page, query))
    mergeTimelinePages(merged, page)
    merged = dedupeTimeline(merged)
    inc pages

    let newCursor = profile.tweets.bottom
    if desiredLimit > 0 and merged.content.len >= desiredLimit:
      break
    if newCursor.len == 0 or newCursor == nextCursor or newCursor in seenCursors or pages >= pageBudget:
      break
    seenCursors.incl newCursor
    nextCursor = newCursor

  result = dedupeTimeline(filterTimelineByQuery(merged, query))
  result.requestedCount = desiredLimit
  result.pagesFetched = pages
  result.pageBudget = pageBudget
  result.budgetExhausted = desiredLimit > 0 and result.content.len < desiredLimit and pages >= pageBudget and result.bottom.len > 0
  if result.content.len > 0:
    await cacheCollectTimeline(cacheId, result)
