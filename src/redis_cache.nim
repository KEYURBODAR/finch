# SPDX-License-Identifier: AGPL-3.0-only
import asyncdispatch, times, strformat, strutils, tables, hashes, options
import redis, redpool, flatty, supersnappy

import types, api

const
  redisNil = "\0\0"
  baseCacheTime = 60 * 60
  contentStoreTime = 45 * 24 * 60 * 60
  archiveStoreTime = 365 * 24 * 60 * 60
  userSearchCacheTime = baseCacheTime * 12
  userCacheVersion = "p6:"
  profileSurfaceCacheVersion = "ps1:"
  profileTabsCacheVersion = "pt1:"
  profileFrontierCacheVersion = "pf1:"
  searchTimelineCacheVersion = "st1:"
  searchFrontierCacheVersion = "sf1:"
  listTimelineCacheVersion = "ls1:"
  listFrontierCacheVersion = "lf1:"
  localTimelineCacheVersion = "lt3:"
  collectTimelineCacheVersion = "ctq2:"
  articleTweetIndexVersion = "ati1:"

var
  pool: RedisPool
  rssCacheTime: int
  listCacheTime*: int

type SeenIds = ref object
  ids: seq[int64]

type StoredTweetMeta = object
  firstSeen: DateTime
  lastSeen: DateTime

type ArticleTweetRef* = object
  tweetId*: int64
  username*: string

type FrontierSnapshot* = object
  newestTweetId*: int64
  newestTweetTime*: DateTime
  checkedAt*: DateTime
  bottomCursor*: string

template dawait(future) =
  discard await future

# flatty can't serialize DateTime, so we need to define this
proc toFlatty*(s: var string, x: DateTime) =
  s.toFlatty(x.toTime().toUnix())

proc fromFlatty*(s: string, i: var int, x: var DateTime) =
  var unix: int64
  s.fromFlatty(i, unix)
  x = fromUnix(unix).utc()

proc setCacheTimes*(cfg: Config) =
  rssCacheTime = cfg.rssCacheTime * 60
  listCacheTime = cfg.listCacheTime * 60

proc migrate*(key, match: string) {.async.} =
  pool.withAcquire(r):
    let hasKey = await r.get(key)
    if hasKey == redisNil:
      let list = await r.scan(newCursor(0), match, 100000)
      r.startPipelining()
      for item in list:
        dawait r.del(item)
      await r.setk(key, "true")
      dawait r.flushPipeline()

proc initRedisPool*(cfg: Config) {.async.} =
  try:
    pool = await newRedisPool(cfg.redisConns, cfg.redisMaxConns,
                              host=cfg.redisHost, port=cfg.redisPort,
                              password=cfg.redisPassword)

    await migrate("flatty", "*:*")
    await migrate("snappyRss", "rss:*")
    await migrate("userBuckets", "p:*")
    await migrate("profileDates", "p:*")
    await migrate("profileStats", "p:*")
    await migrate("userType", "p:*")
    await migrate("verifiedType", "p:*")

    pool.withAcquire(r):
      # optimize memory usage for user ID buckets
      await r.configSet("hash-max-ziplist-entries", "1000")

  except OSError:
    stdout.write "Failed to connect to Redis.\n"
    stdout.flushFile
    quit(1)

template uidKey(name: string): string = "pid:" & $(hash(name) div 1_000_000)
template userKey(name: string): string = userCacheVersion & name
template profileSurfaceKey(id: string): string = profileSurfaceCacheVersion & id
template profileTabsKey(id: string): string = profileTabsCacheVersion & id
template profileFrontierKey(id: string): string = profileFrontierCacheVersion & id
template searchTimelineKey(id: string): string = searchTimelineCacheVersion & id
template searchFrontierKey(id: string): string = searchFrontierCacheVersion & id
template listTimelineKey(id: string): string = listTimelineCacheVersion & id
template listFrontierKey(id: string): string = listFrontierCacheVersion & id
template localTimelineKey(id: string): string = localTimelineCacheVersion & id
template collectTimelineKey(id: string): string = collectTimelineCacheVersion & id
template articleTweetIndexKey(id: string): string = articleTweetIndexVersion & id
template listKey(l: List): string = "l2:" & l.id
template tweetKey(id: int64): string = "t:" & $id
template storedTweetKey(id: int64): string = "ct:" & $id
template storedTweetMetaKey(id: int64): string = "ctm:" & $id
template articleKey(url: string): string = "a:" & $hash(url)
template userSearchKey(q: string): string = "us:" & $hash(toLower(q))
template userSearchResultKey(q: string): string = "us2:" & $hash(toLower(q))

proc userCacheKey(name: string): string =
  userCacheVersion & toLower(name)

proc isLikelyPartialUser(data: User): bool =
  data.id.len > 0 and data.following == 0 and data.followers == 0 and
  data.tweets == 0 and data.likes == 0 and data.media == 0

proc mergeUsers(existing, incoming: User): User =
  result = existing

  if result.id.len == 0: result.id = incoming.id
  if result.username.len == 0: result.username = incoming.username
  if result.fullname.len == 0 or result.fullname == result.username:
    result.fullname = incoming.fullname
  if result.location.len == 0: result.location = incoming.location
  if result.website.len == 0: result.website = incoming.website
  if result.bio.len == 0: result.bio = incoming.bio
  if result.userPic.len == 0: result.userPic = incoming.userPic
  if result.banner.len == 0: result.banner = incoming.banner
  if result.pinnedTweet == 0: result.pinnedTweet = incoming.pinnedTweet

  result.following = max(result.following, incoming.following)
  result.followers = max(result.followers, incoming.followers)
  result.tweets = max(result.tweets, incoming.tweets)
  result.likes = max(result.likes, incoming.likes)
  result.media = max(result.media, incoming.media)

  if result.verifiedType == none:
    result.verifiedType = incoming.verifiedType
  if result.affiliateBadgeName.len == 0:
    result.affiliateBadgeName = incoming.affiliateBadgeName
  if result.affiliateBadgeUrl.len == 0:
    result.affiliateBadgeUrl = incoming.affiliateBadgeUrl
  if result.affiliateBadgeTarget.len == 0:
    result.affiliateBadgeTarget = incoming.affiliateBadgeTarget
  result.affiliatesCount = max(result.affiliatesCount, incoming.affiliatesCount)

  result.protected = result.protected or incoming.protected
  result.suspended = result.suspended or incoming.suspended

  if result.joinDate.year < 1971 or (incoming.joinDate.year >= 1971 and incoming.joinDate < result.joinDate):
    result.joinDate = incoming.joinDate

proc get(query: string): Future[string] {.async.} =
  pool.withAcquire(r):
    result = await r.get(query)

proc setEx(key: string; time: int; data: string) {.async.} =
  pool.withAcquire(r):
    dawait r.setEx(key, time, data)

proc delKey(key: string) {.async.} =
  pool.withAcquire(r):
    dawait r.del(key)

proc cacheUserId(username, id: string) {.async.} =
  if username.len == 0 or id.len == 0: return
  let name = toLower(username)
  pool.withAcquire(r):
    dawait r.hSet(name.uidKey, name, id)

proc cache*(data: List) {.async.} =
  await setEx(data.listKey, listCacheTime, compress(toFlatty(data)))

proc cache*(data: PhotoRail; name: string) {.async.} =
  await setEx("pr2:" & toLower(name), baseCacheTime * 2, compress(toFlatty(data)))

proc cache*(data: User) {.async.} =
  if data.username.len == 0: return
  let name = toLower(data.username)
  await cacheUserId(name, data.id)
  var merged = data
  let raw = await get(name.userKey)
  if raw != redisNil:
    try:
      let existing = fromFlatty(uncompress(raw), User)
      merged = mergeUsers(existing, data)
    except CatchableError, Defect:
      await delKey(name.userKey)
  pool.withAcquire(r):
    dawait r.setEx(name.userKey, baseCacheTime, compress(toFlatty(merged)))

proc cache*(data: Tweet) {.async.} =
  if data.isNil or data.id == 0: return
  pool.withAcquire(r):
    dawait r.setEx(data.id.tweetKey, contentStoreTime, compress(toFlatty(data)))

proc cache*(data: Article) {.async.} =
  if data.url.len == 0: return
  await setEx(data.url.articleKey, baseCacheTime * 24, compress(toFlatty(data)))

proc articleIdFromUrl*(url: string): string =
  let lowered = toLowerAscii(url)
  let pos = lowered.find("/i/article/")
  if pos < 0:
    return ""
  let tail = url[pos + "/i/article/".len .. ^1]
  for ch in tail:
    if ch in {'0'..'9'}:
      result.add ch
    else:
      break

proc cacheArticleTweetRef*(articleId: string; tweetId: int64; username: string) {.async.} =
  if articleId.len == 0 or tweetId == 0 or username.len == 0:
    return
  let data = ArticleTweetRef(tweetId: tweetId, username: username)
  await setEx(articleId.articleTweetIndexKey, archiveStoreTime, compress(toFlatty(data)))

proc getCachedArticleTweetRef*(articleId: string): Future[Option[ArticleTweetRef]] {.async.} =
  if articleId.len == 0:
    return none(ArticleTweetRef)
  let raw = await get(articleId.articleTweetIndexKey)
  if raw == redisNil:
    return none(ArticleTweetRef)
  try:
    return some(fromFlatty(uncompress(raw), ArticleTweetRef))
  except CatchableError, Defect:
    await delKey(articleId.articleTweetIndexKey)
    return none(ArticleTweetRef)

proc cacheRss*(query: string; rss: Rss) {.async.} =
  let key = "rss:" & query
  pool.withAcquire(r):
    dawait r.hSet(key, "min", rss.cursor)
    if rss.cursor != "suspended":
      dawait r.hSet(key, "rss", compress(rss.feed))
    dawait r.expire(key, rssCacheTime)

proc getCachedUserSearchJson*(q: string): Future[string] {.async.} =
  ## Cache for `/search/json?f=users&q=...` used by autocomplete.
  ## Stores raw JSON to avoid consuming session budget on repeated queries.
  if q.len == 0:
    return ""
  let raw = await get(q.userSearchKey)
  if raw == redisNil:
    return ""
  try:
    return uncompress(raw)
  except CatchableError, Defect:
    await delKey(q.userSearchKey)
    return ""

proc cacheUserSearchJson*(q, payload: string) {.async.} =
  if q.len == 0 or payload.len == 0:
    return
  await setEx(q.userSearchKey, userSearchCacheTime, compress(payload))

proc getCachedUserSearch*(q: string): Future[Option[Result[User]]] {.async.} =
  ## Cache for autocomplete-backed user search results.
  ## Stores a parsed `Result[User]` to avoid brittle JSON stringification inside router macros.
  if q.len == 0:
    return none(Result[User])
  let raw = await get(q.userSearchResultKey)
  if raw == redisNil:
    return none(Result[User])
  try:
    return some(fromFlatty(uncompress(raw), Result[User]))
  except CatchableError, Defect:
    await delKey(q.userSearchResultKey)
    return none(Result[User])

proc cacheUserSearch*(q: string; data: Result[User]) {.async.} =
  if q.len == 0 or data.content.len == 0:
    return
  await setEx(q.userSearchResultKey, userSearchCacheTime, compress(toFlatty(data)))

template deserialize(data, T) =
  try:
    result = fromFlatty(uncompress(data), T)
  except:
    echo "Decompression failed($#): '$#'" % [astToStr(T), data]

proc getUserId*(username: string): Future[string] {.async.} =
  let name = toLower(username)
  pool.withAcquire(r):
    result = await r.hGet(name.uidKey, name)
    if result == redisNil:
      let user = await getGraphUser(username)
      if user.suspended:
        return "suspended"
      else:
        await all(cacheUserId(name, user.id), cache(user))
        return user.id

proc getCachedUser*(username: string; fetch=true): Future[User] {.async.} =
  let key = userCacheKey(username)
  let prof = await get(key)
  if prof != redisNil:
    try:
      result = fromFlatty(uncompress(prof), User)
    except CatchableError, Defect:
      await delKey(key)
      if fetch:
        result = await getGraphUser(username)
        await cache(result)
        return
    if fetch and isLikelyPartialUser(result):
      let refreshed = await getGraphUser(username)
      if refreshed.id.len > 0:
        result = mergeUsers(result, refreshed)
        await cache(result)
  elif fetch:
    result = await getGraphUser(username)
    await cache(result)

proc getCachedUsername*(userId: string): Future[string] {.async.} =
  let
    key = "i:" & userId
    username = await get(key)

  if username != redisNil:
    result = username
  else:
    let user = await getGraphUserById(userId)
    result = user.username
    await setEx(key, baseCacheTime, result)
    if result.len > 0 and user.id.len > 0:
      await all(cacheUserId(result, user.id), cache(user))

# proc getCachedTweet*(id: int64): Future[Tweet] {.async.} =
#   if id == 0: return
#   let tweet = await get(id.tweetKey)
#   if tweet != redisNil:
#     tweet.deserialize(Tweet)
#   else:
#     result = await getGraphTweetResult($id)
#     if not result.isNil:
#       await cache(result)

proc getCachedPhotoRail*(id: string): Future[PhotoRail] {.async.} =
  if id.len == 0: return
  let rail = await get("pr2:" & toLower(id))
  if rail != redisNil:
    try:
      result = fromFlatty(uncompress(rail), PhotoRail)
    except CatchableError, Defect:
      await delKey("pr2:" & toLower(id))
      result = await getPhotoRail(id)
      await cache(result, id)
  else:
    result = await getPhotoRail(id)
    await cache(result, id)

proc getCachedList*(username=""; slug=""; id=""): Future[List] {.async.} =
  let
    key = if id.len == 0: "" else: "l2:" & id
    raw = if key.len == 0: redisNil else: await get(key)

  if raw != redisNil:
    try:
      result = fromFlatty(uncompress(raw), List)
      return
    except CatchableError, Defect:
      await delKey(key)

  if id.len > 0:
    result = await getGraphList(id)
  else:
    result = await getGraphListBySlug(username, slug)
  await cache(result)

proc getCachedArticle*(url: string): Future[Article] {.async.} =
  if url.len == 0: return
  let article = await get(url.articleKey)
  if article != redisNil:
    try:
      result = fromFlatty(uncompress(article), Article)
    except CatchableError, Defect:
      await delKey(url.articleKey)

proc cacheStoredTweet*(tweet: Tweet) {.async.} =
  if tweet.isNil or tweet.id == 0:
    return
  let ts = now().utc
  var meta = StoredTweetMeta(firstSeen: ts, lastSeen: ts)

  let rawMeta = await get(tweet.id.storedTweetMetaKey)
  if rawMeta != redisNil:
    try:
      meta = fromFlatty(uncompress(rawMeta), StoredTweetMeta)
    except CatchableError, Defect:
      try:
        let legacy = parse(rawMeta, "yyyy-MM-dd'T'HH:mm:ss'Z'").utc
        meta = StoredTweetMeta(firstSeen: legacy, lastSeen: legacy)
      except CatchableError:
        discard

  if meta.firstSeen.year < 1971:
    meta.firstSeen = ts
  meta.lastSeen = ts

  await all(
    setEx(tweet.id.storedTweetKey, contentStoreTime, compress(toFlatty(tweet))),
    setEx(tweet.id.storedTweetMetaKey, contentStoreTime, compress(toFlatty(meta)))
  )

proc getStoredTweet*(id: int64): Future[CachedTweet] {.async.} =
  if id == 0:
    return
  let
    rawTweet = await get(id.storedTweetKey)
    cachedMeta = await get(id.storedTweetMetaKey)
  if rawTweet != redisNil:
    try:
      result.tweet = fromFlatty(uncompress(rawTweet), Tweet)
    except CatchableError, Defect:
      await all(delKey(id.storedTweetKey), delKey(id.storedTweetMetaKey))
      result.tweet = nil
  if cachedMeta != redisNil and cachedMeta.len > 0:
    try:
      let meta = fromFlatty(uncompress(cachedMeta), StoredTweetMeta)
      result.cachedAt = meta.lastSeen
      result.firstSeen = meta.firstSeen
    except CatchableError, Defect:
      try:
        let legacy = parse(cachedMeta, "yyyy-MM-dd'T'HH:mm:ss'Z'").utc
        result.cachedAt = legacy
        result.firstSeen = legacy
      except CatchableError:
        discard

proc cacheTweetGraph*(tweet: Tweet; seen: SeenIds) {.async.} =
  if tweet.isNil or tweet.id == 0:
    return
  var i = 0
  while i < seen.ids.len:
    if seen.ids[i] == tweet.id:
      return
    inc i
  seen.ids.add tweet.id

  await all(cache(tweet.user), cache(tweet), cacheStoredTweet(tweet))

  if tweet.article.isSome:
    await cache(tweet.article.get)
    let articleId = articleIdFromUrl(tweet.article.get.url)
    if articleId.len > 0:
      await cacheArticleTweetRef(articleId, tweet.id, tweet.user.username)

  if tweet.quote.isSome:
    await cacheTweetGraph(tweet.quote.get, seen)

  if tweet.retweet.isSome:
    await cacheTweetGraph(tweet.retweet.get, seen)

proc cacheTweetGraph*(tweet: Tweet) {.async.} =
  let seen = SeenIds(ids: @[])
  await cacheTweetGraph(tweet, seen)

proc cacheTimeline*(timeline: Timeline) {.async.} =
  let seen = SeenIds(ids: @[])
  for thread in timeline.content:
    for tweet in thread:
      await cacheTweetGraph(tweet, seen)

proc newestTimelineTweet(timeline: Timeline): Tweet =
  for thread in timeline.content:
    if thread.len > 0 and not thread[0].isNil:
      return thread[0]
  return nil

proc timelineSnapshot(timeline: Timeline): Option[FrontierSnapshot] =
  let newest = newestTimelineTweet(timeline)
  if newest.isNil or newest.id == 0:
    return none(FrontierSnapshot)
  some(FrontierSnapshot(
    newestTweetId: newest.id,
    newestTweetTime: newest.time,
    checkedAt: now().utc,
    bottomCursor: timeline.bottom
  ))

proc getCachedProfileTabs*(userId: string): Future[Option[ProfileTabState]] {.async.} =
  if userId.len == 0:
    return none(ProfileTabState)
  let raw = await get(userId.profileTabsKey)
  if raw == redisNil:
    return none(ProfileTabState)
  try:
    return some(fromFlatty(uncompress(raw), ProfileTabState))
  except CatchableError, Defect:
    await delKey(userId.profileTabsKey)
    return none(ProfileTabState)

proc cacheProfileTabs*(userId: string; tabs: ProfileTabState) {.async.} =
  if userId.len == 0:
    return
  await setEx(userId.profileTabsKey, baseCacheTime * 24, compress(toFlatty(tabs)))

proc getCachedProfileFrontier*(cacheId: string): Future[Option[FrontierSnapshot]] {.async.} =
  if cacheId.len == 0:
    return none(FrontierSnapshot)
  let raw = await get(cacheId.profileFrontierKey)
  if raw == redisNil:
    return none(FrontierSnapshot)
  try:
    return some(fromFlatty(uncompress(raw), FrontierSnapshot))
  except CatchableError, Defect:
    await delKey(cacheId.profileFrontierKey)
    return none(FrontierSnapshot)

proc cacheProfileFrontier*(cacheId: string; timeline: Timeline) {.async.} =
  if cacheId.len == 0:
    return
  let snapshot = timelineSnapshot(timeline)
  if snapshot.isSome:
    await setEx(cacheId.profileFrontierKey, archiveStoreTime, compress(toFlatty(snapshot.get)))

proc timelineFrontierTtl*(cursor: string): int =
  if cursor.len == 0:
    # Keep frontier pages durable in cache by default; LIVE is the explicit
    # refresh path for users who want the newest head immediately.
    return archiveStoreTime
  return archiveStoreTime

proc getCachedProfileSurface*(cacheId: string): Future[Option[Profile]] {.async.} =
  if cacheId.len == 0:
    return none(Profile)
  let raw = await get(cacheId.profileSurfaceKey)
  if raw == redisNil:
    return none(Profile)
  try:
    return some(fromFlatty(uncompress(raw), Profile))
  except CatchableError, Defect:
    await delKey(cacheId.profileSurfaceKey)
    return none(Profile)

proc cacheProfileSurface*(cacheId: string; profile: Profile; cursor="") {.async.} =
  if cacheId.len == 0:
    return
  await setEx(cacheId.profileSurfaceKey, timelineFrontierTtl(cursor), compress(toFlatty(profile)))
  if cursor.len == 0:
    await cacheProfileFrontier(cacheId, profile.tweets)

proc getCachedSearchTimeline*(cacheId: string): Future[Option[Timeline]] {.async.} =
  if cacheId.len == 0:
    return none(Timeline)
  let raw = await get(cacheId.searchTimelineKey)
  if raw == redisNil:
    return none(Timeline)
  try:
    return some(fromFlatty(uncompress(raw), Timeline))
  except CatchableError, Defect:
    await delKey(cacheId.searchTimelineKey)
    return none(Timeline)

proc getCachedSearchFrontier*(cacheId: string): Future[Option[FrontierSnapshot]] {.async.} =
  if cacheId.len == 0:
    return none(FrontierSnapshot)
  let raw = await get(cacheId.searchFrontierKey)
  if raw == redisNil:
    return none(FrontierSnapshot)
  try:
    return some(fromFlatty(uncompress(raw), FrontierSnapshot))
  except CatchableError, Defect:
    await delKey(cacheId.searchFrontierKey)
    return none(FrontierSnapshot)

proc cacheSearchFrontier*(cacheId: string; timeline: Timeline) {.async.} =
  if cacheId.len == 0:
    return
  let snapshot = timelineSnapshot(timeline)
  if snapshot.isSome:
    await setEx(cacheId.searchFrontierKey, archiveStoreTime, compress(toFlatty(snapshot.get)))

proc cacheSearchTimeline*(cacheId: string; timeline: Timeline; cursor="") {.async.} =
  if cacheId.len == 0:
    return
  await setEx(cacheId.searchTimelineKey, timelineFrontierTtl(cursor), compress(toFlatty(timeline)))
  if cursor.len == 0:
    await cacheSearchFrontier(cacheId, timeline)

proc getCachedListTimeline*(cacheId: string): Future[Option[Timeline]] {.async.} =
  if cacheId.len == 0:
    return none(Timeline)
  let raw = await get(cacheId.listTimelineKey)
  if raw == redisNil:
    return none(Timeline)
  try:
    return some(fromFlatty(uncompress(raw), Timeline))
  except CatchableError, Defect:
    await delKey(cacheId.listTimelineKey)
    return none(Timeline)

proc getCachedListFrontier*(cacheId: string): Future[Option[FrontierSnapshot]] {.async.} =
  if cacheId.len == 0:
    return none(FrontierSnapshot)
  let raw = await get(cacheId.listFrontierKey)
  if raw == redisNil:
    return none(FrontierSnapshot)
  try:
    return some(fromFlatty(uncompress(raw), FrontierSnapshot))
  except CatchableError, Defect:
    await delKey(cacheId.listFrontierKey)
    return none(FrontierSnapshot)

proc cacheListFrontier*(cacheId: string; timeline: Timeline) {.async.} =
  if cacheId.len == 0:
    return
  let snapshot = timelineSnapshot(timeline)
  if snapshot.isSome:
    await setEx(cacheId.listFrontierKey, archiveStoreTime, compress(toFlatty(snapshot.get)))

proc cacheListTimeline*(cacheId: string; timeline: Timeline; cursor="") {.async.} =
  if cacheId.len == 0:
    return
  await setEx(cacheId.listTimelineKey, timelineFrontierTtl(cursor), compress(toFlatty(timeline)))
  if cursor.len == 0:
    await cacheListFrontier(cacheId, timeline)

proc getCachedLocalTimeline*(cacheId: string): Future[Option[Timeline]] {.async.} =
  if cacheId.len == 0:
    return none(Timeline)
  let raw = await get(cacheId.localTimelineKey)
  if raw == redisNil:
    return none(Timeline)
  try:
    return some(fromFlatty(uncompress(raw), Timeline))
  except CatchableError, Defect:
    await delKey(cacheId.localTimelineKey)
    return none(Timeline)

proc cacheLocalTimeline*(cacheId: string; timeline: Timeline) {.async.} =
  if cacheId.len == 0:
    return
  await setEx(cacheId.localTimelineKey, baseCacheTime * 2, compress(toFlatty(timeline)))

proc getCachedCollectTimeline*(cacheId: string): Future[Option[Timeline]] {.async.} =
  if cacheId.len == 0:
    return none(Timeline)
  let raw = await get(cacheId.collectTimelineKey)
  if raw == redisNil:
    return none(Timeline)
  try:
    return some(fromFlatty(uncompress(raw), Timeline))
  except CatchableError, Defect:
    await delKey(cacheId.collectTimelineKey)
    return none(Timeline)

proc cacheCollectTimeline*(cacheId: string; timeline: Timeline) {.async.} =
  if cacheId.len == 0:
    return
  await setEx(cacheId.collectTimelineKey, baseCacheTime div 12, compress(toFlatty(timeline)))

proc invalidateLocalTimelineCache*(collectionId: string) {.async.} =
  if collectionId.len == 0:
    return
  let match = localTimelineCacheVersion & "collection:" & collectionId & ":*"
  pool.withAcquire(r):
    let items = await r.scan(newCursor(0), match, 1000)
    if items.len == 0:
      return
    r.startPipelining()
    for item in items:
      dawait r.del(item)
    dawait r.flushPipeline()

proc invalidateAllLocalTimelineCaches*() {.async.} =
  let match = localTimelineCacheVersion & "collection:*"
  pool.withAcquire(r):
    let items = await r.scan(newCursor(0), match, 1000)
    if items.len == 0:
      return
    r.startPipelining()
    for item in items:
      dawait r.del(item)
    dawait r.flushPipeline()

proc cacheConversation*(conv: Conversation) {.async.} =
  if conv.isNil or conv.tweet.isNil:
    return
  let seen = SeenIds(ids: @[])
  await cacheTweetGraph(conv.tweet, seen)
  for tweet in conv.before.content:
    await cacheTweetGraph(tweet, seen)
  for tweet in conv.after.content:
    await cacheTweetGraph(tweet, seen)
  for chain in conv.replies.content:
    for tweet in chain.content:
      await cacheTweetGraph(tweet, seen)

proc getCachedRss*(key: string): Future[Rss] {.async.} =
  let k = "rss:" & key
  pool.withAcquire(r):
    result.cursor = await r.hGet(k, "min")
    if result.cursor.len > 2:
      if result.cursor != "suspended":
        let feed = await r.hGet(k, "rss")
        if feed.len > 0 and feed != redisNil:
          try: result.feed = uncompress feed
          except: echo "Decompressing RSS failed: ", feed
    else:
      result.cursor.setLen 0
