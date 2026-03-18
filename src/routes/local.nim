# SPDX-License-Identifier: AGPL-3.0-only
import algorithm, asyncdispatch, hashes, json, options, sequtils, sets, strformat, strutils, tables, times, unicode, uri, xmltree
import packedjson except JsonNode, newJArray, newJObject, newJNull, JObject, JNull, `%*`, `%`

import jester

import router_utils
import timeline
import ../[api, apiutils, consts, exporters, formatters, local_data, prefs, query, types, redis_cache, utils]
import ../views/[general, identity, local_ui]

const
  finchIdentityCookie = "finch_identity_key"
  finchIdentitySkipCookie = "finch_identity_skip"
  hotLocalTimelineTtl = 5 * 60
  hotLocalTimelineMaxEntries = 100

type HotLocalTimelineEntry = object
  collectionId: string
  expiresAt: int64
  timeline: Timeline

type AttentionAccumulator = object
  key: string
  label: string
  href: string
  kind: AttentionEntityKind
  touches: int
  uniqueMembers: HashSet[string]
  latestAt: DateTime
  memberSamples: OrderedTable[string, FinchCollectionMember]
  sources: seq[AttentionSource]

const
  attentionSourceMax = 6

proc attentionReasonPriority(kind: AttentionSignalKind): int =
  case kind
  of attentionQuote: 4
  of attentionRepost: 3
  of attentionMention: 2
  of attentionLink: 1

proc addAttentionSource(entry: var AttentionAccumulator; member: FinchCollectionMember;
                        href, actorLabel: string; signal: AttentionSignalKind) =
  if href.len == 0 or actorLabel.len == 0:
    return
  for idx in 0 ..< entry.sources.len:
    if entry.sources[idx].href == href and
       entry.sources[idx].actorLabel.toLowerAscii == actorLabel.toLowerAscii:
      if signal notin entry.sources[idx].reasons:
        entry.sources[idx].reasons.add signal
      if attentionReasonPriority(signal) > attentionReasonPriority(entry.sources[idx].kind):
        entry.sources[idx].kind = signal
      return
  if entry.sources.len < attentionSourceMax:
    entry.sources.add AttentionSource(
      member: member,
      actorLabel: actorLabel,
      kind: signal,
      reasons: @[signal],
      href: href
    )

var hotLocalTimelines: Table[string, HotLocalTimelineEntry]

template requireIdentity*(cfg: Config; path: string) =
  let referer = if path.len > 0: path else: refPath()
  redirect("/f/identity?referer=" & encodeUrl(referer))

template localCurrentIdentityKey*(): untyped =
  block:
    let rawKey = cookies(request).getOrDefault(finchIdentityCookie)
    if validIdentityKey(rawKey): rawKey else: ""

template rememberIdentity*(key: string; cfg: Config) =
  setCookie(finchIdentityCookie, key, daysForward(3650), httpOnly=true,
            secure=cfg.useHttps, sameSite=Lax, path="/")
  setCookie(finchIdentitySkipCookie, "", daysForward(-10), httpOnly=true,
            secure=cfg.useHttps, sameSite=Lax, path="/")

template forgetIdentity*(cfg: Config) =
  setCookie(finchIdentityCookie, "", daysForward(-10), httpOnly=true,
            secure=cfg.useHttps, sameSite=Lax, path="/")

template skipIdentity*(cfg: Config) =
  setCookie(finchIdentitySkipCookie, "1", daysForward(180), httpOnly=true,
            secure=cfg.useHttps, sameSite=Lax, path="/")

proc hotCacheNow(): int64 =
  epochTime().int64

proc getHotLocalTimeline*(cacheId: string): Option[Timeline] =
  if cacheId.len == 0:
    return none(Timeline)
  let nowTs = hotCacheNow()
  if cacheId in hotLocalTimelines:
    let entry = hotLocalTimelines[cacheId]
    if entry.expiresAt > nowTs:
      return some(entry.timeline)
    hotLocalTimelines.del(cacheId)
  none(Timeline)

proc getAnyHotLocalTimeline*(collectionId: string): Option[Timeline] =
  if collectionId.len == 0:
    return none(Timeline)
  let nowTs = hotCacheNow()
  for pair in hotLocalTimelines.pairs.toSeq:
    let
      cacheId = pair[0]
      entry = pair[1]
    if entry.expiresAt <= nowTs:
      hotLocalTimelines.del(cacheId)
      continue
    if entry.collectionId == collectionId:
      return some(entry.timeline)
  none(Timeline)

proc cacheHotLocalTimeline*(cacheId, colId: string; timeline: Timeline) =
  if cacheId.len == 0 or colId.len == 0:
    return
  # Evict expired and cap size: remove oldest by expiry when over limit
  let nowTs = hotCacheNow()
  if hotLocalTimelines.len >= hotLocalTimelineMaxEntries:
    var oldest: string
    var oldestTs = int64.high
    for k, v in hotLocalTimelines.pairs:
      if v.expiresAt < oldestTs:
        oldestTs = v.expiresAt
        oldest = k
    if oldest.len > 0:
      hotLocalTimelines.del(oldest)
  hotLocalTimelines[cacheId] = HotLocalTimelineEntry(
    collectionId: colId,
    expiresAt: nowTs + hotLocalTimelineTtl,
    timeline: timeline
  )

proc invalidateHotLocalTimeline*(collectionId: string) =
  if collectionId.len == 0:
    hotLocalTimelines.clear()
    return
  for pair in hotLocalTimelines.pairs.toSeq:
    let
      cacheId = pair[0]
      entry = pair[1]
    if entry.collectionId == collectionId:
      hotLocalTimelines.del(cacheId)

proc localRssTitle*(tweet: Tweet; retweet: string): string =
  if tweet.pinned:
    result = "Pinned: "
  elif retweet.len > 0:
    result = &"RT by @{retweet}: "
  elif tweet.reply.len > 0:
    result = &"R to @{tweet.reply[0]}: "

  var text = stripHtml(tweet.text)
  if unicode.runeLen(text) > 48:
    text = unicode.runeSubStr(text, 0, 48) & "..."
  result &= xmltree.escape(text)
  if result.len > 0:
    return

  if tweet.photos.len > 0:
    result &= "Image"
  elif tweet.video.isSome:
    result &= "Video"
  elif tweet.gif.isSome:
    result &= "Gif"

proc localRssTweet*(tweet: Tweet; cfg: Config; prefs: Prefs): string =
  let
    tweet = tweet.retweet.get(tweet)
    urlPrefix = getUrlPrefix(cfg)
    text = replaceUrls(tweet.text, prefs, absolute=urlPrefix)
  result = "<p>" & text.replace("\n", "<br>\n") & "</p>"
  if tweet.photos.len > 0:
    for photo in tweet.photos:
      result.add &"""<img src="{urlPrefix}{getPicUrl(photo.url)}" style="max-width:250px;" />"""
  elif tweet.video.isSome:
    result.add &"""<a href="{urlPrefix}{tweet.getLink}"><br>Video<br><img src="{urlPrefix}{getPicUrl(get(tweet.video).thumb)}" style="max-width:250px;" /></a>"""
  elif tweet.gif.isSome:
    let
      thumb = &"{urlPrefix}{getPicUrl(get(tweet.gif).thumb)}"
      url = &"{urlPrefix}{getPicUrl(get(tweet.gif).url)}"
    result.add &"""<video poster="{thumb}" autoplay muted loop style="max-width:250px;"><source src="{url}" type="video/mp4"></video>"""
  elif tweet.card.isSome:
    let card = tweet.card.get()
    if card.image.len > 0:
      result.add &"""<img src="{urlPrefix}{getPicUrl(card.image)}" style="max-width:250px;" />"""

proc localRssItems*(tweets: seq[Tweets]; cfg: Config; prefs: Prefs): string =
  let urlPrefix = getUrlPrefix(cfg)
  var links: seq[string]
  for thread in tweets:
    for item in thread:
      let retweet = if item.retweet.isSome: item.user.username else: ""
      let tweet = if retweet.len > 0: item.retweet.get else: item
      let link = getLink(tweet)
      let description = localRssTweet(tweet, cfg, prefs).strip(chars = {'\n'})
      if link in links:
        continue
      links.add link
      result.add &"""
      <item>
        <title>{localRssTitle(tweet, retweet)}</title>
        <dc:creator>@{tweet.user.username}</dc:creator>
        <description><![CDATA[{description}]]></description>
        <pubDate>{getRfc822Time(tweet)}</pubDate>
        <guid>{urlPrefix & link}</guid>
        <link>{urlPrefix & link}</link>
      </item>
"""

proc renderLocalSearchRss*(tweets: seq[Tweets]; name, feedPath: string; cfg: Config; prefs: Prefs): string =
  let
    link = &"{getUrlPrefix(cfg)}{feedPath}"
    escName = xmltree.escape(name)
  result = &"""<?xml version="1.0" encoding="UTF-8"?>
<rss xmlns:atom="http://www.w3.org/2005/Atom" xmlns:dc="http://purl.org/dc/elements/1.1/" version="2.0">
  <channel>
    <atom:link href="{link}" rel="self" type="application/rss+xml" />
    <title>{escName}</title>
    <link>{link}</link>
    <description>Finch feed for "{escName}". Generated by {getUrlPrefix(cfg)}</description>
    <language>en-us</language>
    <ttl>40</ttl>
{localRssItems(tweets, cfg, prefs)}
  </channel>
</rss>
"""

proc collectionToJsonNode*(collection: FinchCollection): json.JsonNode =
  var previews = newJArray()
  for member in collection.previewMembers:
    previews.add %*{
      "username": member.username,
      "fullname": member.fullname,
      "avatar": member.avatar
    }
  result = %*{
    "id": collection.id,
    "kind": $collection.kind,
    "slug": collection.slug,
    "name": collection.name,
    "description": collection.description,
    "members": collection.membersCount,
    "preview_members": previews
  }

proc localTimelineEnvelope*(collection: FinchCollection; timeline: Timeline; cfg: Config;
                            selectedRaw=""; exportLimit=0): json.JsonNode =
  %*{
    "schema": localSchemaVersion,
    "kind": "finch_collection",
    "collection": collectionToJsonNode(collection),
    "timeline": searchTimelineToJson(timeline, cfg, selectedRaw, exportLimit)
  }

proc localMembersEnvelope*(collection: FinchCollection; members: seq[FinchCollectionMember]): json.JsonNode =
  var items = newJArray()
  for member in members:
    items.add %*{
      "username": member.username,
      "fullname": member.fullname,
      "avatar": member.avatar,
      "user_id": member.userId,
      "added_at_iso": member.addedAtIso
    }
  %*{
    "schema": localSchemaVersion,
    "kind": "finch_collection_members",
    "collection": collectionToJsonNode(collection),
    "items": items
  }

proc localTimelineMarkdown*(collection: FinchCollection; timeline: Timeline; cfg: Config): string =
  "# " & collection.name & "\n\n" &
    (if collection.description.len > 0: collection.description & "\n\n" else: "") &
    searchTimelineToMarkdown(timeline, cfg)

proc localTimelineText*(collection: FinchCollection; timeline: Timeline; cfg: Config): string =
  collection.name.toUpperAscii & "\n\n" &
    (if collection.description.len > 0: collection.description & "\n\n" else: "") &
    searchTimelineToText(timeline, cfg)

proc localMembersMarkdown*(collection: FinchCollection; members: seq[FinchCollectionMember]): string =
  var blocks = @["# " & collection.name & " members", ""]
  for member in members:
    blocks.add "- @" & member.username & (if member.fullname.len > 0: " — " & member.fullname else: "")
  blocks.join("\n").strip & "\n"

proc localMembersText*(collection: FinchCollection; members: seq[FinchCollectionMember]): string =
  var lines = @[collection.name & " members", ""]
  for member in members:
    lines.add("@" & member.username & (if member.fullname.len > 0: " — " & member.fullname else: ""))
  lines.join("\n").strip & "\n"

proc attentionReasonLabel*(kind: AttentionSignalKind): string =
  case kind
  of attentionMention: "mentioned"
  of attentionRepost: "reposted"
  of attentionQuote: "quoted"
  of attentionLink: "linked"

proc attentionReasons*(source: AttentionSource): seq[string] =
  for kind in [attentionQuote, attentionRepost, attentionMention, attentionLink]:
    if kind in source.reasons:
      result.add attentionReasonLabel(kind)

proc attentionSourceSummary*(source: AttentionSource): string =
  source.actorLabel & " " & attentionReasons(source).join(" + ")

proc limitAttentionEntities*(entities: seq[AttentionEntity]; limit: int): seq[AttentionEntity] =
  if limit <= 0 or entities.len <= limit:
    return entities
  entities[0 ..< limit]

proc attentionEntityToJson*(entity: AttentionEntity): json.JsonNode =
  var
    reasons = newJArray()
    sources = newJArray()
  for source in entity.sources:
    let reasonLabels = attentionReasons(source)
    var sourceNode = %*{
      "actor": source.actorLabel,
      "href": source.href,
      "summary": attentionSourceSummary(source)
    }
    for reason in reasonLabels:
      reasons.add %reason
    sourceNode["reasons"] = reasons
    reasons = newJArray()
    sources.add sourceNode

  result = %*{
    "key": entity.key,
    "kind": $entity.kind,
    "label": entity.label,
    "title": entity.title,
    "subtitle": entity.subtitle,
    "bio": entity.bio,
    "avatar": entity.avatar,
    "href": entity.href,
    "followers": entity.followers,
    "followers_count": entity.followersCount,
    "members": entity.uniqueMembers,
    "signals": entity.touches,
    "score": entity.score,
    "last_seen": entity.lastSeenLabel,
    "last_seen_unix": entity.lastSeenUnix,
    "sources": sources
  }

proc localAttentionEnvelope*(collection: FinchCollection; entities: seq[AttentionEntity];
                             query: Query; includeMembers: bool; sortBy: string;
                             exportLimit=0): json.JsonNode =
  var items = newJArray()
  let limited = limitAttentionEntities(entities, exportLimit)
  for entity in limited:
    items.add attentionEntityToJson(entity)
  %*{
    "schema": localSchemaVersion,
    "kind": "finch_collection_attention",
    "collection": collectionToJsonNode(collection),
    "query_built": displayQuery(query),
    "include_members": includeMembers,
    "sort_by": sortBy,
    "n_requested": exportLimit,
    "n_returned": limited.len,
    "items": items
  }

proc localAttentionMarkdown*(collection: FinchCollection; entities: seq[AttentionEntity];
                             query: Query; includeMembers: bool; sortBy: string;
                             exportLimit=0): string =
  let limited = limitAttentionEntities(entities, exportLimit)
  var lines = @[
    "# " & collection.name & " attention",
    "",
    "- query: " & displayQuery(query),
    "- include_members: " & $(includeMembers),
    "- sort_by: " & sortBy,
    ""
  ]
  for entity in limited:
    lines.add "## " & entity.title
    lines.add ""
    lines.add "- handle: " & entity.subtitle
    if entity.followers.len > 0:
      lines.add "- followers: " & entity.followers
    lines.add "- members: " & $entity.uniqueMembers
    lines.add "- signals: " & $entity.touches
    lines.add "- last_seen: " & entity.lastSeenLabel
    if entity.bio.len > 0:
      lines.add "- bio: " & entity.bio
    if entity.sources.len > 0:
      lines.add "- why:"
      for source in entity.sources:
        lines.add "  - " & attentionSourceSummary(source) & " — " & source.href
    lines.add ""
  lines.join("\n").strip & "\n"

proc localAttentionText*(collection: FinchCollection; entities: seq[AttentionEntity];
                         query: Query; includeMembers: bool; sortBy: string;
                         exportLimit=0): string =
  let limited = limitAttentionEntities(entities, exportLimit)
  var lines = @[
    collection.name.toUpperAscii & " ATTENTION",
    "",
    "query: " & displayQuery(query),
    "include_members: " & $(includeMembers),
    "sort_by: " & sortBy,
    ""
  ]
  for entity in limited:
    lines.add entity.title
    lines.add "  " & entity.subtitle
    if entity.followers.len > 0:
      lines.add "  followers: " & entity.followers
    lines.add "  members: " & $entity.uniqueMembers
    lines.add "  signals: " & $entity.touches
    lines.add "  last seen: " & entity.lastSeenLabel
    if entity.bio.len > 0:
      lines.add "  bio: " & entity.bio
    for source in entity.sources:
      lines.add "  why: " & attentionSourceSummary(source) & " — " & source.href
    lines.add ""
  lines.join("\n").strip & "\n"

proc renderLocalAttentionRss*(entities: seq[AttentionEntity]; name, feedPath: string;
                              query: Query; includeMembers: bool; sortBy: string;
                              cfg: Config): string =
  let
    link = &"{getUrlPrefix(cfg)}{feedPath}"
    escName = xmltree.escape(name)
  var items = ""
  for entity in entities:
    let itemLink =
      if entity.sources.len > 0 and entity.sources[0].href.len > 0:
        getUrlPrefix(cfg) & entity.sources[0].href
      else:
        getUrlPrefix(cfg) & entity.href
    let description = xmltree.escape(
      ("Followers: " & (if entity.followers.len > 0: entity.followers else: "—")) & "\n" &
      ("Members: " & $entity.uniqueMembers) & "\n" &
      ("Signals: " & $entity.touches) & "\n" &
      ("Last seen: " & entity.lastSeenLabel) & "\n" &
      (if entity.bio.len > 0: "Bio: " & entity.bio & "\n" else: "") &
      (if entity.sources.len > 0:
        "Why: " & entity.sources.mapIt(attentionSourceSummary(it)).join(" | ")
      else:
        "Why: none")
    )
    let pubDate =
      if entity.lastSeenUnix > 0:
        fromUnix(entity.lastSeenUnix).utc.format("ddd', 'dd MMM yyyy HH:mm:ss 'GMT'")
      else:
        now().utc.format("ddd', 'dd MMM yyyy HH:mm:ss 'GMT'")
    items &= &"""
      <item>
        <title>{xmltree.escape(entity.title)}</title>
        <description><![CDATA[{description}]]></description>
        <pubDate>{pubDate}</pubDate>
        <guid>{xmltree.escape(itemLink)}</guid>
        <link>{xmltree.escape(itemLink)}</link>
      </item>
"""
  result = &"""<?xml version="1.0" encoding="UTF-8"?>
<rss xmlns:atom="http://www.w3.org/2005/Atom" version="2.0">
  <channel>
    <atom:link href="{link}" rel="self" type="application/rss+xml" />
    <title>{escName}</title>
    <link>{link}</link>
    <description>Attention feed for "{escName}" ({xmltree.escape(displayQuery(query))}, include_members={includeMembers}, sort={sortBy}). Generated by {getUrlPrefix(cfg)}</description>
    <language>en-us</language>
    <ttl>40</ttl>
{items}
  </channel>
</rss>
"""

proc loadUserForLocal*(username: string): Future[User] {.async.} =
  result = await getCachedUser(username)
  if result.id.len == 0:
    result = await getGraphUser(username)
    if result.id.len > 0:
      await cache(result)

type
  LocalCreateListResult = object
    ok*: bool
    listId*: string
    listOwnerId*: string
    error*: string

  LocalMutateListResult = object
    ok*: bool
    error*: string

proc createXList*(name, description, mode: string): Future[LocalCreateListResult] {.async.} =
  result = LocalCreateListResult(ok: false)
  var variables = packedjson.newJObject()
  variables["name"] = packedjson.`%`(name)
  variables["description"] = packedjson.`%`(description)
  variables["isPrivate"] = packedjson.`%`(mode.toLowerAscii == "private")
  let js = await fetchPost(graphCreateList, variables)
  let data = js{"data"}
  if data.kind != packedjson.JObject:
    result.error = "Unexpected response: no data"
    return
  var listNode = data{"list"}
  if listNode.kind == packedjson.JNull: listNode = data{"create_list", "list"}
  if listNode.kind == packedjson.JNull: listNode = data{"createList", "list"}
  if listNode.kind == packedjson.JNull:
    result.error = "Create list failed"
    return
  result.listId = packedjson.getStr(listNode{"rest_id"})
  if result.listId.len == 0: result.listId = packedjson.getStr(listNode{"id_str"})
  if result.listId.len == 0: result.listId = packedjson.getStr(listNode{"id"})
  let ownerNode = listNode{"user_results", "result"}
  if ownerNode.kind != packedjson.JNull:
    result.listOwnerId = packedjson.getStr(ownerNode{"rest_id"})
  if result.listId.len > 0:
    result.ok = true

proc deleteXList*(listId: string): Future[LocalMutateListResult] {.async.} =
  result = LocalMutateListResult(ok: false)
  if listId.len == 0:
    result.error = "listId required"
    return
  var variables = packedjson.newJObject()
  variables["listId"] = packedjson.`%`(listId)
  let js = await fetchPost(graphDeleteList, variables)
  let data = js{"data"}
  if data.kind != packedjson.JObject:
    result.error = "Unexpected response"
    return
  let delNode = if data{"list_delete"}.kind != packedjson.JNull: data{"list_delete"}
                elif data{"deleteList"}.kind != packedjson.JNull: data{"deleteList"}
                else: packedjson.newJNull()
  if delNode.kind != packedjson.JNull:
    result.ok = true

proc addMemberToXList*(listId, userId: string): Future[LocalMutateListResult] {.async.} =
  result = LocalMutateListResult(ok: false)
  if listId.len == 0 or userId.len == 0:
    result.error = "listId and userId required"
    return
  var variables = packedjson.newJObject()
  variables["listId"] = packedjson.`%`(listId)
  variables["userId"] = packedjson.`%`(userId)
  let js = await fetchPost(graphListAddMember, variables)
  let data = js{"data"}
  if data.kind != packedjson.JObject:
    result.error = "Unexpected response"
    return
  let addNode = if data{"list_add_member"}.kind != packedjson.JNull: data{"list_add_member"}
                elif data{"listAddMember"}.kind != packedjson.JNull: data{"listAddMember"}
                elif data{"list"}.kind != packedjson.JNull: data{"list"}
                else: packedjson.newJNull()
  if addNode.kind != packedjson.JNull:
    result.ok = true

proc removeMemberFromXList*(listId, userId: string): Future[LocalMutateListResult] {.async.} =
  result = LocalMutateListResult(ok: false)
  if listId.len == 0 or userId.len == 0:
    result.error = "listId and userId required"
    return
  var variables = packedjson.newJObject()
  variables["listId"] = packedjson.`%`(listId)
  variables["userId"] = packedjson.`%`(userId)
  let js = await fetchPost(graphListRemoveMember, variables)
  let data = js{"data"}
  if data.kind != packedjson.JObject:
    result.error = "Unexpected response"
    return
  let remNode = if data{"list_remove_member"}.kind != packedjson.JNull: data{"list_remove_member"}
                elif data{"listRemoveMember"}.kind != packedjson.JNull: data{"listRemoveMember"}
                elif data{"list"}.kind != packedjson.JNull: data{"list"}
                else: packedjson.newJNull()
  if remNode.kind != packedjson.JNull:
    result.ok = true

proc syncFollowingToX*(collection: FinchCollection; user: User; state: bool): Future[void] {.async.} =
  if state:
    var active = collection
    if active.xListId.len == 0:
      let created = await createXList("Finch Following", "Managed by Finch", "Private")
      if not created.ok or created.listId.len == 0:
        raise newException(IOError, "Could not create backing X list")
      setCollectionXListId(active.id, created.listId, created.listOwnerId)
      active = getCollectionById(active.ownerId, active.id)
    let added = await addMemberToXList(active.xListId, user.id)
    if not added.ok:
      raise newException(IOError, "Could not add member to backing X list")
  elif collection.xListId.len > 0:
    let removed = await removeMemberFromXList(collection.xListId, user.id)
    if not removed.ok:
      raise newException(IOError, "Could not remove member from backing X list")

proc syncListMemberToX*(collection: FinchCollection; user: User; add: bool): Future[void] {.async.} =
  if add:
    var active = collection
    if active.xListId.len == 0:
      let created = await createXList(active.name, active.description, "Private")
      if not created.ok or created.listId.len == 0:
        raise newException(IOError, "Could not create backing X list")
      setCollectionXListId(active.id, created.listId, created.listOwnerId)
      active = getCollectionById(active.ownerId, active.id)
    let added = await addMemberToXList(active.xListId, user.id)
    if not added.ok:
      raise newException(IOError, "Could not add member to backing X list")
  elif collection.xListId.len > 0:
    let removed = await removeMemberFromXList(collection.xListId, user.id)
    if not removed.ok:
      raise newException(IOError, "Could not remove member from backing X list")

proc migrateCollectionToX*(collection: FinchCollection): Future[bool] {.async.} =
  if collection.id.len == 0:
    return false
  if collection.xListId.len > 0:
    return true
  let created = await createXList(collection.name, collection.description, "Private")
  if not created.ok or created.listId.len == 0:
    return false
  setCollectionXListId(collection.id, created.listId, created.listOwnerId)
  for member in getCollectionMembers(collection.id):
    if member.userId.len == 0:
      continue
    let added = await addMemberToXList(created.listId, member.userId)
    if not added.ok:
      return false
  true

proc ensureXBackedCollection*(collection: FinchCollection): Future[tuple[ok: bool, collection: FinchCollection, error: string]] {.async.} =
  if collection.id.len == 0:
    return (false, collection, "Collection not found")
  if collection.xListId.len > 0:
    return (true, collection, "")

  let created = await createXList(collection.name, collection.description, "Private")
  if not created.ok or created.listId.len == 0:
    return (false, collection, if created.error.len > 0: created.error else: "Could not create X list")

  setCollectionXListId(collection.id, created.listId, created.listOwnerId)
  (true, getCollectionById(collection.ownerId, collection.id), "")

proc normalizeLocalUsername*(value: string): string =
  result = value.strip
  while result.len > 0 and result[0] == '@':
    result = result[1 .. ^1]

proc splitLocalUsernames*(value: string; maxUsers=50): seq[string] =
  var seen: HashSet[string]
  for raw in value.split({',', ' ', '\t', '\n', '\r'}):
    let username = normalizeLocalUsername(raw)
    if username.len == 0:
      continue
    if username.len > 15:
      continue
    if username.anyIt(it notin {'a'..'z', 'A'..'Z', '0'..'9', '_'}):
      continue
    let key = username.toLowerAscii
    if key in seen:
      continue
    seen.incl key
    result.add username
    if result.len >= maxUsers:
      break

proc selectedAffiliateUsernames*(req: Request): seq[string] =
  var seen: HashSet[string]
  for key, value in params(req):
    if not key.startsWith("affiliate_") or value notin ["on", "true", "1"]:
      continue
    let username = normalizeLocalUsername(key[10 .. ^1])
    if username.len == 0:
      continue
    let needle = username.toLowerAscii()
    if needle in seen:
      continue
    seen.incl needle
    result.add username

proc selectedMemberScope*(req: Request): seq[string] =
  var seen: HashSet[string]
  for key, value in params(req):
    if not key.startsWith("scope_member_") or value notin ["on", "true", "1"]:
      continue
    let username = normalizeLocalUsername(key["scope_member_".len .. ^1])
    if username.len == 0:
      continue
    let needle = username.toLowerAscii()
    if needle in seen:
      continue
    seen.incl needle
    result.add username

  if result.len == 0 and req.params.getOrDefault("member_scope_mode") == "explicit":
    return @["__finch_none__"]

  if result.len == 0:
    result = parseUserScope(req.params.getOrDefault("members"))

proc selectedRemovalMembers*(req: Request): seq[string] =
  var seen: HashSet[string]
  for key, value in params(req):
    if not key.startsWith("remove_member_") or value notin ["on", "true", "1"]:
      continue
    let username = normalizeLocalUsername(key["remove_member_".len .. ^1])
    if username.len == 0:
      continue
    let needle = username.toLowerAscii()
    if needle in seen:
      continue
    seen.incl needle
    result.add username

proc filterCollectionMembers*(usernames, memberScope: seq[string]): seq[string] =
  if memberScope.len == 0:
    return usernames
  if memberScope.len == 1 and memberScope[0] == "__finch_none__":
    return @[]

  let scope = memberScope.mapIt(it.toLowerAscii)
  for username in usernames:
    if username.toLowerAscii in scope:
      result.add username

proc buildCollectionQuery*(req: Request; usernames: seq[string]; prefs: Prefs): Query =
  result = initQuery(params(req))
  result.applyFeedDefaults(prefs)
  result.kind = tweets
  # Finch-local lists/following already provide member scoping.
  result.scope = scopeAll
  result.fromUser = usernames

proc collectionTimelinePageBudget(desiredLimit: int): int =
  if desiredLimit > 0:
    let pagesNeeded = max(1, (desiredLimit + 19) div 20)
    min(50, pagesNeeded + 3)
  else:
    25

proc attentionSourcePageBudget(query: Query): int =
  if query.since.len > 0 or query.until.len > 0:
    25
  else:
    12

proc collectionTimelineCacheId(collection: FinchCollection; effectiveUsers, memberScope: seq[string];
                               query: Query; cursor: string): string =
  let queryKey = [
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
    cursor
  ].join("|")
  "collection:" & collection.id & ":" &
    $hash(effectiveUsers.join(",").toLowerAscii & "|" &
          memberScope.join(",").toLowerAscii & "|" & queryKey)

proc hasRestrictiveCollectionQuery(query: Query): bool =
  query.text.strip.len > 0 or
  query.filters.len > 0 or
  query.excludes.len > 0 or
  query.includes.len > 0 or
  query.since.len > 0 or
  query.until.len > 0 or
  query.minLikes.len > 0 or
  query.minRetweets.len > 0 or
  query.minReplies.len > 0

proc shouldTrustEmptyCollectionCache(collection: FinchCollection; query: Query; cursor: string;
                                     effectiveUsers: seq[string]): bool =
  if cursor.len > 0:
    return true
  if effectiveUsers.len == 0:
    return true
  if hasRestrictiveCollectionQuery(query):
    return true
  collection.xListId.len == 0

proc matchesLocalCollection(tweet: Tweet; allowedUsers: HashSet[string]; query: Query): bool
proc matchesLocalQuery(tweet: Tweet; query: Query): bool

proc strippedCollectionQuery(query: Query): Query =
  result = query
  result.text.setLen 0
  result.since.setLen 0
  result.until.setLen 0
  result.minLikes.setLen 0
  result.minRetweets.setLen 0
  result.minReplies.setLen 0

proc deriveCachedCollectionTimeline(base: Timeline; allowedUsers: seq[string];
                                    query: Query): Timeline =
  result = base
  result.query = query
  let allowed = allowedUsers.mapIt(it.toLowerAscii).toHashSet
  result.content = @[]
  for thread in base.content:
    if thread.len == 0:
      continue
    var filtered: Tweets = @[]
    for tweet in thread:
      if matchesLocalCollection(tweet, allowed, query) and matchesLocalQuery(tweet, query):
        filtered.add tweet
    if filtered.len > 0:
      result.content.add filtered

proc displayTweet(tweet: Tweet): Tweet =
  if tweet.retweet.isSome:
    get(tweet.retweet)
  else:
    tweet

proc containsInsensitive(haystack, needle: string): bool =
  haystack.toLowerAscii.contains(needle.toLowerAscii)

proc tweetHasLinks(tweet: Tweet): bool =
  tweet.card.isSome or tweet.articleUrl.len > 0 or
    tweet.text.contains("http://") or tweet.text.contains("https://")

proc tweetHasMedia(tweet: Tweet): bool =
  tweet.photos.len > 0 or tweet.video.isSome or tweet.gif.isSome or tweet.article.isSome

proc localDateKey(time: DateTime): string =
  time.utc.format("yyyy-MM-dd")

proc matchesLocalQuery(tweet: Tweet; query: Query): bool =
  let shown = displayTweet(tweet)
  let isReply = tweet.reply.len > 0 or tweet.replyId != 0 or shown.reply.len > 0 or shown.replyId != 0
  let isRetweet = tweet.retweet.isSome
  let isQuote = tweet.quote.isSome or shown.quote.isSome
  let hasImages = shown.photos.len > 0
  let hasVideos = shown.video.isSome or shown.gif.isSome
  let hasLinks = tweetHasLinks(shown)
  let hasMedia = tweetHasMedia(shown)

  if "replies" in query.excludes and isReply:
    return false
  if "replies" in query.filters and not isReply:
    return false
  if "nativeretweets" in query.excludes and isRetweet:
    return false
  if "nativeretweets" in query.filters and not isRetweet:
    return false
  if "quote" in query.excludes and isQuote:
    return false
  if "quote" in query.filters and not isQuote:
    return false
  if "images" in query.filters and not hasImages:
    return false
  if "images" in query.excludes and hasImages:
    return false
  if "videos" in query.filters and not hasVideos:
    return false
  if "videos" in query.excludes and hasVideos:
    return false
  if "links" in query.filters and not hasLinks:
    return false
  if "links" in query.excludes and hasLinks:
    return false
  if "media" in query.filters and not hasMedia:
    return false
  if "media" in query.excludes and hasMedia:
    return false

  if query.minLikes.len > 0 and shown.stats.likes < parseInt(query.minLikes):
    return false
  if query.minRetweets.len > 0 and shown.stats.retweets < parseInt(query.minRetweets):
    return false
  if query.minReplies.len > 0 and shown.stats.replies < parseInt(query.minReplies):
    return false

  let day = localDateKey(shown.time)
  if query.since.len > 0 and day < query.since:
    return false
  if query.until.len > 0 and day > query.until:
    return false

  if query.text.len > 0:
    let articleText =
      if shown.article.isSome:
        shown.article.get.title & "\n" & shown.article.get.body
      else:
        ""
    let cardText =
      if shown.card.isSome:
        let card = shown.card.get
        card.title & "\n" & card.text
      else:
        ""
    let haystack = [shown.text, articleText, cardText].join("\n")
    if not containsInsensitive(haystack, query.text):
      return false

  true

proc matchesLocalCollection(tweet: Tweet; allowedUsers: HashSet[string]; query: Query): bool =
  if tweet.id == 0:
    return false

  if "nativeretweets" in query.excludes and tweet.retweet.isSome:
    return false
  if "quote" in query.excludes and tweet.quote.isSome:
    return false
  if "replies" in query.excludes and (tweet.reply.len > 0 or tweet.replyId != 0):
    return false

  if tweet.retweet.isSome:
    return tweet.user.username.toLowerAscii in allowedUsers

  tweet.user.username.toLowerAscii in allowedUsers

proc filterLocalTimeline(timeline: Timeline; allowedUsernames: seq[string]): Timeline =
  result = timeline
  let allowed = allowedUsernames.mapIt(it.toLowerAscii).toHashSet
  result.content = @[]
  for thread in timeline.content:
    if thread.len == 0:
      continue
    var filtered: Tweets = @[]
    for tweet in thread:
      if matchesLocalCollection(tweet, allowed, timeline.query):
        filtered.add tweet
    if filtered.len > 0:
      result.content.add filtered

proc applyMemberFilters(tweet: Tweet; membersByName: Table[string, FinchCollectionMember]): bool =
  let shown = displayTweet(tweet)
  let authorKey = shown.user.username.toLowerAscii
  if authorKey notin membersByName:
    return true
  let mf = membersByName[authorKey].filters
  if mf.hideRetweets and tweet.retweet.isSome:
    return false
  if mf.hideQuotes and (tweet.quote.isSome or shown.quote.isSome):
    return false
  if mf.hideReplies and (tweet.reply.len > 0 or tweet.replyId != 0 or shown.reply.len > 0 or shown.replyId != 0):
    return false
  true

proc filterXCollectionTimeline(raw: Timeline; effectiveUsers: seq[string];
                              membersByName: Table[string, FinchCollectionMember];
                              query: Query): Timeline =
  result = raw
  result.query = query
  result.content = @[]
  let allowedUsers = effectiveUsers.mapIt(it.toLowerAscii).toHashSet
  for thread in raw.content:
    if thread.len == 0:
      continue
    var filtered: Tweets = @[]
    for tweet in thread:
      if tweet.id == 0:
        continue
      if not matchesLocalCollection(tweet, allowedUsers, query):
        continue
      if not applyMemberFilters(tweet, membersByName):
        continue
      if not matchesLocalQuery(tweet, query):
        continue
      filtered.add tweet
    if filtered.len > 0:
      result.content.add filtered

proc buildMergedCollectionTimeline(collection: FinchCollection; effectiveUsers: seq[string];
                                   req: Request; prefs: Prefs): Future[Timeline] {.async.} =
  result = Timeline(
    beginning: getCursor(req).len == 0,
    query: buildCollectionQuery(req, effectiveUsers, prefs)
  )
  if effectiveUsers.len == 0:
    return

  let
    membersByName = getCollectionMembers(collection.id).mapIt((it.username.toLowerAscii, it)).toTable
    allowedUsers = effectiveUsers.mapIt(it.toLowerAscii).toHashSet
  var merged: seq[Tweet]
  var seen: HashSet[int64]
  var timelineReqs: seq[(string, Future[Profile])]
  var attempted = 0
  var succeeded = 0
  var failed = 0
  var failedUsernames: seq[string]

  for username in effectiveUsers:
    let key = username.toLowerAscii
    var userId = membersByName.getOrDefault(key).userId
    if userId.len == 0:
      try:
        let user = await loadUserForLocal(username)
        userId = user.id
      except RateLimitError, NoSessionsError, InternalError, BadClientError:
        inc failed
        failedUsernames.add key
        continue
    if userId.len == 0:
      continue
    timelineReqs.add (key, getGraphUserTweets(userId, TimelineKind.tweets))

  for (key, profileFuture) in timelineReqs:
    inc attempted
    try:
      let profile = await profileFuture
      inc succeeded
      for thread in profile.tweets.content:
        for tweet in thread:
          if tweet.id == 0 or tweet.id in seen:
            continue
          seen.incl tweet.id
          # Apply per-member filters
          let authorKey = tweet.user.username.toLowerAscii
          if authorKey in membersByName:
            let mf = membersByName[authorKey].filters
            if mf.hideRetweets and tweet.retweet.isSome:
              continue
            if mf.hideQuotes and tweet.quote.isSome:
              continue
            if mf.hideReplies and tweet.reply.len > 0:
              continue
          if matchesLocalCollection(tweet, allowedUsers, result.query) and
             matchesLocalQuery(tweet, result.query):
            merged.add tweet
    except RateLimitError, NoSessionsError, InternalError, BadClientError:
      inc failed
      failedUsernames.add key

  merged.sort(proc (a, b: Tweet): int = cmp(b.time, a.time))
  result.content = merged.mapIt(@[it])
  if succeeded == 0 and attempted > 0:
    result.errorText = "Finch could not refresh this collection right now."
  elif failed > 0 and result.content.len == 0:
    result.errorText = "No matching posts were confirmed right now. Some member timelines could not be refreshed."
  elif failed > 0:
    result.errorText = "Some member timelines could not be refreshed. Showing confirmed results."

proc fetchCollectionTimeline*(req: Request; collection: FinchCollection;
                              forceFresh=false; cursorOverride=""): Future[Timeline] {.async.} =
  let
    prefs = getPrefs(cookies(req), params(req))
    query = buildCollectionQuery(req, collectionUsernames(collection.id), prefs)
    cursor = if cursorOverride.len > 0: cursorOverride else: getCursor(req)

  let
    usernames = collectionUsernames(collection.id)
    scopedUsers = selectedMemberScope(req)
    effectiveUsers = filterCollectionMembers(usernames, scopedUsers)
    cacheId = collectionTimelineCacheId(collection, effectiveUsers, scopedUsers, query, cursor)
    membersByName = getCollectionMembers(collection.id).mapIt((it.username.toLowerAscii, it)).toTable

  if not forceFresh:
    let hotCached = getHotLocalTimeline(cacheId)
    if hotCached.isSome:
      let candidate = hotCached.get
      if candidate.content.len > 0 or shouldTrustEmptyCollectionCache(collection, query, cursor, effectiveUsers):
        result = candidate
        result.query = query
        return
    let cached = await getCachedLocalTimeline(cacheId)
    if cached.isSome:
      let candidate = cached.get
      if candidate.content.len > 0 or shouldTrustEmptyCollectionCache(collection, query, cursor, effectiveUsers):
        result = candidate
        result.query = query
        cacheHotLocalTimeline(cacheId, collection.id, result)
        return

  try:
    if collection.xListId.len > 0:
      let rawTimeline = await getGraphListTweets(collection.xListId, cursor)
      result = filterXCollectionTimeline(rawTimeline, effectiveUsers, membersByName, query)
    else:
      result = await buildMergedCollectionTimeline(collection, effectiveUsers, req, prefs)
  except RateLimitError, NoSessionsError, InternalError, BadClientError:
    let fallback = await getCachedLocalTimeline(cacheId)
    if fallback.isSome:
      result = fallback.get
      result.query = query
      cacheHotLocalTimeline(cacheId, collection.id, result)
      return
    result = Timeline(
      beginning: cursor.len == 0,
      query: query,
      content: @[],
      errorText: "Finch could not refresh this collection right now."
    )
    return

  if result.content.len == 0 and result.errorText.len > 0:
    let fallback = await getCachedLocalTimeline(cacheId)
    if fallback.isSome:
      result = fallback.get
      result.query = query
      result.errorText = "Showing cached collection results. Live refresh could not be completed."
      cacheHotLocalTimeline(cacheId, collection.id, result)
      return
    # Do not poison cache with uncertain empty/error results.
    return

  await cacheTimeline(result)
  if result.content.len > 0 or shouldTrustEmptyCollectionCache(collection, query, cursor, effectiveUsers):
    cacheHotLocalTimeline(cacheId, collection.id, result)
    await cacheLocalTimeline(cacheId, result)

proc mergeTimelinePages(base: var Timeline; page: Timeline) =
  if base.content.len == 0 and base.query.text.len == 0 and base.query.fromUser.len == 0:
    base = page
    return
  if page.content.len > 0:
    base.content.add page.content
  base.bottom = page.bottom
  if base.errorText.len == 0:
    base.errorText = page.errorText

proc fetchCollectionExportTimeline*(req: Request; collection: FinchCollection; desiredLimit: int;
                                    forceFresh=false; pageBudgetOverride=0): Future[Timeline] {.async.} =
  var
    nextCursor = getCursor(req)
    pages = 0
    merged = Timeline(beginning: nextCursor.len == 0)
    pageBudget =
      if pageBudgetOverride > 0: pageBudgetOverride
      else: collectionTimelinePageBudget(desiredLimit)
  while true:
    let page = await fetchCollectionTimeline(req, collection, forceFresh=forceFresh, cursorOverride=nextCursor)
    mergeTimelinePages(merged, page)
    merged = dedupeTimeline(merged)
    inc pages
    if desiredLimit > 0 and merged.content.len >= desiredLimit:
      break
    if page.bottom.len == 0 or page.bottom == nextCursor or pages >= pageBudget:
      break
    nextCursor = page.bottom
  result = dedupeTimeline(merged)
  result.requestedCount = desiredLimit
  result.pagesFetched = pages
  result.pageBudget = pageBudget
  result.budgetExhausted = desiredLimit > 0 and result.content.len < desiredLimit and
    pages >= pageBudget and result.bottom.len > 0

proc fetchAttentionSourceTimeline*(req: Request; collection: FinchCollection;
                                   forceFresh=false): Future[Timeline] {.async.} =
  let
    prefs = getPrefs(cookies(req), params(req))
    query = buildCollectionQuery(req, collectionUsernames(collection.id), prefs)
    pageBudget = attentionSourcePageBudget(query)
  result = await fetchCollectionExportTimeline(req, collection, 0, forceFresh=forceFresh,
                                               pageBudgetOverride=pageBudget)
  result.pageBudget = pageBudget
  result.budgetExhausted = result.bottom.len > 0 and result.pagesFetched >= pageBudget

proc attentionTimeLabel(time: DateTime): string =
  let since = now() - time
  if since.inDays >= 1:
    result = time.format("MMM d")
  elif since.inHours >= 1:
    result = $since.inHours & "h ago"
  elif since.inMinutes >= 1:
    result = $since.inMinutes & "m ago"
  else:
    result = "just now"

proc extractAccountMentions(text: string): seq[string] =
  var seen: HashSet[string]
  var i = 0
  while i < text.len:
    if text[i] == '@':
      var j = i + 1
      while j < text.len and (text[j].isAlphaNumeric or text[j] == '_'):
        inc j
      if j > i + 1:
        let username = text[i + 1 ..< j]
        let key = username.toLowerAscii
        if key notin seen:
          seen.incl key
          result.add username
      i = j
    else:
      inc i

proc normalizeAttentionDomain(value: string): string =
  let raw = value.strip(chars = {' ', '\t', '\n', '\r', ')', ']', '}', '>', ',', '.', ';', ':', '"', '\''})
  if raw.len == 0 or (not raw.startsWith("http://") and not raw.startsWith("https://")):
    return ""
  try:
    var host = parseUri(raw).hostname.toLowerAscii
    if host.startsWith("www."):
      host = host[4 .. ^1]
    if host.len == 0 or host in ["x.com", "twitter.com", "t.co", "127.0.0.1", "localhost"]:
      return ""
    host
  except CatchableError:
    ""

proc attentionSourceHref(tweet: Tweet): string =
  if tweet.id == 0:
    return ""
  getLink(tweet.id, tweet.user.username)

proc extractDomains(tweet: Tweet): seq[string] =
  let shown = displayTweet(tweet)
  var seen: HashSet[string]
  for candidate in [tweet.articleUrl, shown.articleUrl,
                    (if shown.card.isSome: shown.card.get.url else: ""),
                    (if shown.card.isSome: shown.card.get.dest else: "")]:
    let host = normalizeAttentionDomain(candidate)
    if host.len > 0 and host notin seen:
      seen.incl host
      result.add host
  for token in strutils.splitWhitespace(shown.text):
    let host = normalizeAttentionDomain(token)
    if host.len > 0 and host notin seen:
      seen.incl host
      result.add host

proc upsertAttentionAccount(accumulators: var OrderedTable[string, AttentionAccumulator];
                            member: FinchCollectionMember; username: string; tweet: Tweet;
                            signal: AttentionSignalKind) =
  if username.strip.len == 0:
    return
  let key = "account:" & username.toLowerAscii
  if key notin accumulators:
    accumulators[key] = AttentionAccumulator(
      key: key,
      label: "@" & username,
      href: "/" & username,
      kind: attentionAccount,
      latestAt: tweet.time
    )
  var entry = accumulators[key]
  inc entry.touches
  entry.uniqueMembers.incl member.username.toLowerAscii
  if member.username.toLowerAscii notin entry.memberSamples and entry.memberSamples.len < 5:
    entry.memberSamples[member.username.toLowerAscii] = member
  addAttentionSource(entry, member, attentionSourceHref(tweet), "@" & member.username, signal)
  if tweet.time > entry.latestAt:
    entry.latestAt = tweet.time
  accumulators[key] = entry

proc upsertAttentionDomain(accumulators: var OrderedTable[string, AttentionAccumulator];
                           member: FinchCollectionMember; domain: string; tweet: Tweet) =
  if domain.strip.len == 0:
    return
  let key = "domain:" & domain.toLowerAscii
  if key notin accumulators:
    accumulators[key] = AttentionAccumulator(
      key: key,
      label: domain,
      href: "https://" & domain,
      kind: attentionDomain,
      latestAt: tweet.time
    )
  var entry = accumulators[key]
  inc entry.touches
  entry.uniqueMembers.incl member.username.toLowerAscii
  if member.username.toLowerAscii notin entry.memberSamples and entry.memberSamples.len < 5:
    entry.memberSamples[member.username.toLowerAscii] = member
  addAttentionSource(entry, member, attentionSourceHref(tweet), "@" & member.username, attentionLink)
  if tweet.time > entry.latestAt:
    entry.latestAt = tweet.time
  accumulators[key] = entry

proc buildAttentionEntities*(collection: FinchCollection; timeline: Timeline;
                             includeMembers=false): seq[AttentionEntity] =
  let
    members = getCollectionMembers(collection.id)
    memberLookup = members.mapIt((it.username.toLowerAscii, it)).toTable
    collectionMembers = members.mapIt(it.username.toLowerAscii).toHashSet
    hiddenEntities = getHiddenAttention(collection.id).toHashSet
  var accumulators: OrderedTable[string, AttentionAccumulator]

  for thread in timeline.content:
    if thread.len == 0:
      continue
    let tweet = thread[0]
    let authorKey = tweet.user.username.toLowerAscii
    if authorKey notin memberLookup:
      continue
    let member = memberLookup[authorKey]
    let retweeting = tweet.retweet.isSome

    if not retweeting:
      var domainSignals: HashSet[string]
      for domain in extractDomains(tweet):
        domainSignals.incl domain

      for username in extractAccountMentions(tweet.text):
        let entityKey = "account:" & username.toLowerAscii
        if entityKey in hiddenEntities:
          continue
        if username.toLowerAscii != authorKey and (includeMembers or username.toLowerAscii notin collectionMembers):
          upsertAttentionAccount(accumulators, member, username, tweet, attentionMention)
      for domain in domainSignals:
        let entityKey = "domain:" & domain.toLowerAscii
        if entityKey in hiddenEntities:
          continue
        upsertAttentionDomain(accumulators, member, domain, tweet)

    if tweet.quote.isSome:
      let username = tweet.quote.get.user.username
      let entityKey = "account:" & username.toLowerAscii
      if username.toLowerAscii != authorKey and (includeMembers or username.toLowerAscii notin collectionMembers) and entityKey notin hiddenEntities:
        upsertAttentionAccount(accumulators, member, username, tweet, attentionQuote)
    if tweet.retweet.isSome:
      let username = tweet.retweet.get.user.username
      let entityKey = "account:" & username.toLowerAscii
      if username.toLowerAscii != authorKey and (includeMembers or username.toLowerAscii notin collectionMembers) and entityKey notin hiddenEntities:
        upsertAttentionAccount(accumulators, member, username, tweet, attentionRepost)

  for _, entry in accumulators.pairs:
    result.add AttentionEntity(
      key: entry.key,
      label: entry.label,
      title: entry.label,
      subtitle: if entry.kind == attentionAccount: "Account" else: "Domain",
      avatar: "",
      verifiedType: VerifiedType.none,
      affiliateBadgeName: "",
      affiliateBadgeUrl: "",
      affiliateBadgeTarget: "",
      href: entry.href,
      kind: entry.kind,
      touches: entry.touches,
      uniqueMembers: entry.uniqueMembers.len,
      score: entry.uniqueMembers.len * 10 + entry.touches,
      lastSeenLabel: attentionTimeLabel(entry.latestAt),
      lastSeenUnix: entry.latestAt.toTime.toUnix,
      memberSamples: entry.memberSamples.values.toSeq,
      sources: entry.sources
    )

proc sortAttentionEntities*(entities: var seq[AttentionEntity]; sortBy="score") =
  entities.sort(proc(a, b: AttentionEntity): int =
    case sortBy.toLowerAscii
    of "members":
      result = cmp(b.uniqueMembers, a.uniqueMembers)
      if result == 0:
        result = cmp(b.touches, a.touches)
      if result == 0:
        result = cmp(b.score, a.score)
    of "signals", "touches":
      result = cmp(b.touches, a.touches)
      if result == 0:
        result = cmp(b.uniqueMembers, a.uniqueMembers)
      if result == 0:
        result = cmp(b.score, a.score)
    of "recent":
      result = cmp(b.lastSeenUnix, a.lastSeenUnix)
      if result == 0:
        result = cmp(b.score, a.score)
    of "followers":
      result = cmp(b.followersCount, a.followersCount)
      if result == 0:
        result = cmp(b.score, a.score)
    of "alpha":
      result = cmp(a.title.toLowerAscii, b.title.toLowerAscii)
    else:
      result = cmp(b.score, a.score)
      if result == 0:
        result = cmp(b.uniqueMembers, a.uniqueMembers)
      if result == 0:
        result = cmp(b.touches, a.touches))

proc enrichAttentionEntities*(entities: seq[AttentionEntity]; allowFetch=false): Future[seq[AttentionEntity]] {.async.} =
  result = entities
  var fetched = 0
  for i, entity in result.mpairs:
    if entity.kind != attentionAccount:
      entity.title = entity.label
      entity.subtitle = "Linked domain"
      continue
    let username = entity.label.strip(chars = {'@'})
    if username.len == 0:
      continue
    var user = await getCachedUser(username, fetch=false)
    if user.username.len == 0 and allowFetch and fetched < 20:
      try:
        user = await getCachedUser(username, fetch=true)
        if user.username.len > 0:
          inc fetched
      except CatchableError:
        discard
    if user.username.len == 0:
      entity.title = entity.label
      entity.subtitle = "Account"
      continue
    entity.label = "@" & user.username
    entity.title = if user.fullname.len > 0: user.fullname else: user.username
    entity.subtitle = "@" & user.username
    entity.avatar = user.getUserPic("_bigger")
    entity.verifiedType = user.verifiedType
    entity.affiliateBadgeName = user.affiliateBadgeName
    entity.affiliateBadgeUrl = user.affiliateBadgeUrl
    entity.affiliateBadgeTarget = user.affiliateBadgeTarget
    entity.followersCount = user.followers
    if user.followers > 0:
      entity.followers = compactCount(user.followers)
    if user.bio.len > 0:
      entity.bio = stripHtml(user.bio, shorten=true)

template noticeFromRequest*(key: string): untyped =
  case key
  of "created": "Recovery key created. Export it before you lose it."
  of "imported": "Finch key imported."
  of "cleared": "This browser no longer holds a Finch key."
  else: ""

template renderIdentityUi*(identityKey, referer, notice: string; followingCount, listCount: int): untyped =
  renderIdentityPage(identityKey, referer, notice, followingCount, listCount)

template renderCollectionsUi*(title, subtitle: string; collections: seq[FinchCollection];
                              canCreate=false): untyped =
  renderCollectionsIndex(title, subtitle, collections, canCreate)

template renderLocalTimelineUi*(collection: FinchCollection; timeline: Timeline; prefs: Prefs;
                                path, memberScope: string): untyped =
  renderLocalTimeline(collection, timeline, prefs, path, memberScope)

template renderLocalMembersUi*(collection: FinchCollection; members: seq[FinchCollectionMember]): untyped =
  renderLocalMembers(collection, members)

template renderLocalAttentionUi*(collection: FinchCollection; entities: seq[AttentionEntity];
                                 query: Query; memberScope: string; includeMembers: bool;
                                 sortBy: string): untyped =
  renderLocalAttention(collection, entities, query, memberScope, includeMembers, sortBy)

proc extractIdentityKeyFromBundle*(bundle: string): string =
  try:
    json.parseJson(bundle){"identity_key"}.getStr
  except CatchableError:
    ""

proc createLocalRouter*(cfg: Config) =
  router local:
    get "/f/identity":
      let
        identityKey = localCurrentIdentityKey()
        referer = if @"referer".len > 0: @"referer" else: "/"
        ownerId = if identityKey.len > 0: ensureOwner(identityKey) else: ""
        collections = if ownerId.len > 0: getCollections(ownerId) else: @[]
        followingCount = collections.filterIt(it.kind == following).foldl(a + b.membersCount, 0)
        listCount = collections.countIt(it.kind == localList)
        html = renderIdentityUi(identityKey, referer, noticeFromRequest(@"notice"), followingCount, listCount)
      resp renderMain(html, request, cfg, requestPrefs(), "Finch key")

    get "/f/lists":
      let identityKey = localCurrentIdentityKey()
      if identityKey.len == 0:
        requireIdentity(cfg, request.path)
      let
        ownerId = ensureOwner(identityKey)
        collections = getCollections(ownerId, "list")
        html = renderCollectionsUi("Lists", "Your Finch lists live here and sync to X for live membership and timeline reads.", collections, canCreate=true)
      resp renderMain(html, request, cfg, requestPrefs(), "Lists")

    get "/f/following":
      let identityKey = localCurrentIdentityKey()
      if identityKey.len == 0:
        requireIdentity(cfg, request.path)
      let
        ownerId = ensureOwner(identityKey)
        collection = getOrCreateFollowing(ownerId)
        timeline = await fetchCollectionTimeline(request, collection)
        memberScope = selectedMemberScope(request).join(",")
        html = renderLocalTimelineUi(collection, timeline, requestPrefs(), getPath(), memberScope)
      resp renderMain(html, request, cfg, requestPrefs(), "Following")

    get "/f/following/attention":
      let identityKey = localCurrentIdentityKey()
      if identityKey.len == 0:
        requireIdentity(cfg, request.path)
      let
        ownerId = ensureOwner(identityKey)
        collection = getOrCreateFollowing(ownerId)
        timeline = await fetchAttentionSourceTimeline(request, collection)
        memberScope = selectedMemberScope(request).join(",")
        includeMembers = request.params.getOrDefault("include_members") in ["on", "true", "1"]
        sortBy = request.params.getOrDefault("sort_by", "score")
      var entities = await enrichAttentionEntities(buildAttentionEntities(collection, timeline,
        includeMembers=includeMembers))
      sortAttentionEntities(entities, sortBy)
      let html = renderLocalAttentionUi(collection, entities, timeline.query, memberScope, includeMembers, sortBy)
      resp renderMain(html, request, cfg, requestPrefs(), "Following attention")

    get "/f/following/attention/live/json":
      let identityKey = localCurrentIdentityKey()
      if identityKey.len == 0:
        requireIdentity(cfg, request.path)
      let
        ownerId = ensureOwner(identityKey)
        collection = getOrCreateFollowing(ownerId)
        timeline = await fetchAttentionSourceTimeline(request, collection, forceFresh=true)
        includeMembers = request.params.getOrDefault("include_members") in ["on", "true", "1"]
        sortBy = request.params.getOrDefault("sort_by", "score")
        exportLimit = normalizeExportLimit(request.params.getOrDefault("limit"))
      var entities = await enrichAttentionEntities(buildAttentionEntities(collection, timeline,
        includeMembers=includeMembers), allowFetch=true)
      sortAttentionEntities(entities, sortBy)
      respJson wrapLivePayload("finch_following_attention_live",
        localAttentionEnvelope(collection, entities, timeline.query, includeMembers, sortBy, exportLimit))

    get "/f/following/attention/rss":
      let identityKey = localCurrentIdentityKey()
      if identityKey.len == 0:
        requireIdentity(cfg, request.path)
      let
        ownerId = ensureOwner(identityKey)
        collection = getOrCreateFollowing(ownerId)
        timeline = await fetchAttentionSourceTimeline(request, collection)
        includeMembers = request.params.getOrDefault("include_members") in ["on", "true", "1"]
        sortBy = request.params.getOrDefault("sort_by", "score")
        exportLimit = normalizeExportLimit(request.params.getOrDefault("limit"))
      var entities = await enrichAttentionEntities(buildAttentionEntities(collection, timeline,
        includeMembers=includeMembers))
      sortAttentionEntities(entities, sortBy)
      entities = limitAttentionEntities(entities, exportLimit)
      resp renderLocalAttentionRss(entities, collection.name & " attention", "/f/following/attention/rss",
        timeline.query, includeMembers, sortBy, cfg), "application/rss+xml; charset=utf-8"

    get "/f/following/attention/@fmt":
      cond @"fmt" in ["json", "md", "txt"]
      let identityKey = localCurrentIdentityKey()
      if identityKey.len == 0:
        requireIdentity(cfg, request.path)
      let
        ownerId = ensureOwner(identityKey)
        collection = getOrCreateFollowing(ownerId)
        timeline = await fetchAttentionSourceTimeline(request, collection)
        includeMembers = request.params.getOrDefault("include_members") in ["on", "true", "1"]
        sortBy = request.params.getOrDefault("sort_by", "score")
        exportLimit = normalizeExportLimit(request.params.getOrDefault("limit"))
      var entities = await enrichAttentionEntities(buildAttentionEntities(collection, timeline,
        includeMembers=includeMembers))
      sortAttentionEntities(entities, sortBy)
      case @"fmt"
      of "json":
        respJson localAttentionEnvelope(collection, entities, timeline.query, includeMembers, sortBy, exportLimit)
      of "md":
        resp localAttentionMarkdown(collection, entities, timeline.query, includeMembers, sortBy, exportLimit),
          "text/markdown; charset=utf-8"
      of "txt":
        resp localAttentionText(collection, entities, timeline.query, includeMembers, sortBy, exportLimit),
          "text/plain; charset=utf-8"
      else:
        resp Http404

    get "/f/following/live/json":
      let identityKey = localCurrentIdentityKey()
      if identityKey.len == 0:
        requireIdentity(cfg, request.path)
      let
        ownerId = ensureOwner(identityKey)
        collection = getOrCreateFollowing(ownerId)
        exportLimit = normalizeExportLimit(request.params.getOrDefault("limit"))
        selectedRaw = exportSelectionRaw(request.params.getOrDefault("selected_ids"),
                                         request.params.getOrDefault("limit"))
        timeline = limitTimeline(filterTimelineBySelected(
          await fetchCollectionExportTimeline(request, collection, exportLimit, forceFresh=true), selectedRaw), exportLimit)
      respJson wrapLivePayload("finch_following_live", localTimelineEnvelope(collection, timeline, cfg, selectedRaw, exportLimit))

    get "/f/following/rss":
      let identityKey = localCurrentIdentityKey()
      if identityKey.len == 0:
        requireIdentity(cfg, request.path)
      let
        ownerId = ensureOwner(identityKey)
        prefs = requestPrefs()
        collection = getOrCreateFollowing(ownerId)
        timeline = await fetchCollectionTimeline(request, collection)
      resp renderLocalSearchRss(timeline.content, collection.name, "/f/following", cfg, prefs),
        "application/rss+xml; charset=utf-8"

    get "/f/following/@fmt":
      cond @"fmt" in ["json", "md", "txt"]
      let identityKey = localCurrentIdentityKey()
      if identityKey.len == 0:
        requireIdentity(cfg, request.path)
      let
        ownerId = ensureOwner(identityKey)
        collection = getOrCreateFollowing(ownerId)
        exportLimit = normalizeExportLimit(request.params.getOrDefault("limit"))
        selectedRaw = exportSelectionRaw(request.params.getOrDefault("selected_ids"),
                                         request.params.getOrDefault("limit"))
        timeline = limitTimeline(filterTimelineBySelected(
          await fetchCollectionExportTimeline(request, collection, exportLimit), selectedRaw), exportLimit)
      case @"fmt"
      of "json":
        respJson localTimelineEnvelope(collection, timeline, cfg, selectedRaw, exportLimit)
      of "md":
        resp localTimelineMarkdown(collection, timeline, cfg), "text/markdown; charset=utf-8"
      of "txt":
        resp localTimelineText(collection, timeline, cfg), "text/plain; charset=utf-8"
      else:
        resp Http404

    get "/f/lists/@id":
      let identityKey = localCurrentIdentityKey()
      if identityKey.len == 0:
        requireIdentity(cfg, request.path)
      let
        ownerId = ensureOwner(identityKey)
        collection = getCollectionById(ownerId, @"id")
      if collection.id.len == 0:
        resp Http404, showError("Local list not found", cfg)
      let
        timeline = await fetchCollectionTimeline(request, collection)
        memberScope = selectedMemberScope(request).join(",")
        html = renderLocalTimelineUi(collection, timeline, requestPrefs(), getPath(), memberScope)
      resp renderMain(html, request, cfg, requestPrefs(), collection.name)

    get "/f/lists/@id/attention":
      let identityKey = localCurrentIdentityKey()
      if identityKey.len == 0:
        requireIdentity(cfg, request.path)
      let
        ownerId = ensureOwner(identityKey)
        collection = getCollectionById(ownerId, @"id")
      if collection.id.len == 0:
        resp Http404, showError("Local list not found", cfg)
      let
        timeline = await fetchAttentionSourceTimeline(request, collection)
        memberScope = selectedMemberScope(request).join(",")
        includeMembers = request.params.getOrDefault("include_members") in ["on", "true", "1"]
        sortBy = request.params.getOrDefault("sort_by", "score")
      var entities = await enrichAttentionEntities(buildAttentionEntities(collection, timeline,
        includeMembers=includeMembers))
      sortAttentionEntities(entities, sortBy)
      let html = renderLocalAttentionUi(collection, entities, timeline.query, memberScope, includeMembers, sortBy)
      resp renderMain(html, request, cfg, requestPrefs(), collection.name & " attention")

    get "/f/lists/@id/attention/live/json":
      let identityKey = localCurrentIdentityKey()
      if identityKey.len == 0:
        requireIdentity(cfg, request.path)
      let
        ownerId = ensureOwner(identityKey)
        collection = getCollectionById(ownerId, @"id")
      if collection.id.len == 0:
        resp Http404, showError("Local list not found", cfg)
      let
        timeline = await fetchAttentionSourceTimeline(request, collection, forceFresh=true)
        includeMembers = request.params.getOrDefault("include_members") in ["on", "true", "1"]
        sortBy = request.params.getOrDefault("sort_by", "score")
        exportLimit = normalizeExportLimit(request.params.getOrDefault("limit"))
      var entities = await enrichAttentionEntities(buildAttentionEntities(collection, timeline,
        includeMembers=includeMembers), allowFetch=true)
      sortAttentionEntities(entities, sortBy)
      respJson wrapLivePayload("finch_list_attention_live",
        localAttentionEnvelope(collection, entities, timeline.query, includeMembers, sortBy, exportLimit))

    get "/f/lists/@id/attention/rss":
      let identityKey = localCurrentIdentityKey()
      if identityKey.len == 0:
        requireIdentity(cfg, request.path)
      let
        ownerId = ensureOwner(identityKey)
        collection = getCollectionById(ownerId, @"id")
      if collection.id.len == 0:
        resp Http404, showError("Local list not found", cfg)
      let
        timeline = await fetchAttentionSourceTimeline(request, collection)
        includeMembers = request.params.getOrDefault("include_members") in ["on", "true", "1"]
        sortBy = request.params.getOrDefault("sort_by", "score")
        exportLimit = normalizeExportLimit(request.params.getOrDefault("limit"))
      var entities = await enrichAttentionEntities(buildAttentionEntities(collection, timeline,
        includeMembers=includeMembers))
      sortAttentionEntities(entities, sortBy)
      entities = limitAttentionEntities(entities, exportLimit)
      resp renderLocalAttentionRss(entities, collection.name & " attention",
        "/f/lists/" & collection.id & "/attention/rss", timeline.query, includeMembers, sortBy, cfg),
        "application/rss+xml; charset=utf-8"

    get "/f/lists/@id/attention/@fmt":
      cond @"fmt" in ["json", "md", "txt"]
      let identityKey = localCurrentIdentityKey()
      if identityKey.len == 0:
        requireIdentity(cfg, request.path)
      let
        ownerId = ensureOwner(identityKey)
        collection = getCollectionById(ownerId, @"id")
      if collection.id.len == 0:
        resp Http404, showError("Local list not found", cfg)
      let
        timeline = await fetchAttentionSourceTimeline(request, collection)
        includeMembers = request.params.getOrDefault("include_members") in ["on", "true", "1"]
        sortBy = request.params.getOrDefault("sort_by", "score")
        exportLimit = normalizeExportLimit(request.params.getOrDefault("limit"))
      var entities = await enrichAttentionEntities(buildAttentionEntities(collection, timeline,
        includeMembers=includeMembers))
      sortAttentionEntities(entities, sortBy)
      case @"fmt"
      of "json":
        respJson localAttentionEnvelope(collection, entities, timeline.query, includeMembers, sortBy, exportLimit)
      of "md":
        resp localAttentionMarkdown(collection, entities, timeline.query, includeMembers, sortBy, exportLimit),
          "text/markdown; charset=utf-8"
      of "txt":
        resp localAttentionText(collection, entities, timeline.query, includeMembers, sortBy, exportLimit),
          "text/plain; charset=utf-8"
      else:
        resp Http404

    get "/f/lists/@id/live/json":
      let identityKey = localCurrentIdentityKey()
      if identityKey.len == 0:
        requireIdentity(cfg, request.path)
      let
        ownerId = ensureOwner(identityKey)
        collection = getCollectionById(ownerId, @"id")
      if collection.id.len == 0:
        resp Http404, showError("Local list not found", cfg)
      let
        exportLimit = normalizeExportLimit(request.params.getOrDefault("limit"))
        selectedRaw = exportSelectionRaw(request.params.getOrDefault("selected_ids"),
                                         request.params.getOrDefault("limit"))
        timeline = limitTimeline(filterTimelineBySelected(
          await fetchCollectionExportTimeline(request, collection, exportLimit, forceFresh=true), selectedRaw), exportLimit)
      respJson wrapLivePayload("finch_list_live", localTimelineEnvelope(collection, timeline, cfg, selectedRaw, exportLimit))

    get "/f/lists/@id/rss":
      let identityKey = localCurrentIdentityKey()
      if identityKey.len == 0:
        requireIdentity(cfg, request.path)
      let
        ownerId = ensureOwner(identityKey)
        prefs = requestPrefs()
        collection = getCollectionById(ownerId, @"id")
      if collection.id.len == 0:
        resp Http404, showError("Local list not found", cfg)
      let timeline = await fetchCollectionTimeline(request, collection)
      resp renderLocalSearchRss(timeline.content, collection.name, "/f/lists/" & collection.id, cfg, prefs),
        "application/rss+xml; charset=utf-8"

    get "/f/lists/@id/@fmt":
      cond @"fmt" in ["json", "md", "txt"]
      let identityKey = localCurrentIdentityKey()
      if identityKey.len == 0:
        requireIdentity(cfg, request.path)
      let
        ownerId = ensureOwner(identityKey)
        collection = getCollectionById(ownerId, @"id")
      if collection.id.len == 0:
        resp Http404, showError("Local list not found", cfg)
      let
        exportLimit = normalizeExportLimit(request.params.getOrDefault("limit"))
        selectedRaw = exportSelectionRaw(request.params.getOrDefault("selected_ids"),
                                         request.params.getOrDefault("limit"))
        timeline = limitTimeline(filterTimelineBySelected(
          await fetchCollectionExportTimeline(request, collection, exportLimit), selectedRaw), exportLimit)
      case @"fmt"
      of "json":
        respJson localTimelineEnvelope(collection, timeline, cfg, selectedRaw, exportLimit)
      of "md":
        resp localTimelineMarkdown(collection, timeline, cfg), "text/markdown; charset=utf-8"
      of "txt":
        resp localTimelineText(collection, timeline, cfg), "text/plain; charset=utf-8"
      else:
        resp Http404

    get "/f/lists/@id/members":
      let identityKey = localCurrentIdentityKey()
      if identityKey.len == 0:
        requireIdentity(cfg, request.path)
      let
        ownerId = ensureOwner(identityKey)
        collection = getCollectionById(ownerId, @"id")
      if collection.id.len == 0:
        resp Http404, showError("Local list not found", cfg)
      let html = renderLocalMembersUi(collection, getCollectionMembers(collection.id))
      resp renderMain(html, request, cfg, requestPrefs(), collection.name & " members")

    get "/f/following/members":
      let identityKey = localCurrentIdentityKey()
      if identityKey.len == 0:
        requireIdentity(cfg, request.path)
      let
        ownerId = ensureOwner(identityKey)
        collection = getOrCreateFollowing(ownerId)
      let html = renderLocalMembersUi(collection, getCollectionMembers(collection.id))
      resp renderMain(html, request, cfg, requestPrefs(), "Following members")

    get "/f/lists/@id/members/@fmt":
      cond @"fmt" in ["json", "md", "txt"]
      let identityKey = localCurrentIdentityKey()
      if identityKey.len == 0:
        requireIdentity(cfg, request.path)
      let
        ownerId = ensureOwner(identityKey)
        collection = getCollectionById(ownerId, @"id")
        exportLimit = normalizeExportLimit(request.params.getOrDefault("limit"))
        rawMembers = if collection.id.len > 0: getCollectionMembers(collection.id) else: @[]
        members = if exportLimit > 0 and rawMembers.len > exportLimit: rawMembers[0 ..< exportLimit] else: rawMembers
      if collection.id.len == 0:
        resp Http404, showError("Local list not found", cfg)
      case @"fmt"
      of "json":
        respJson localMembersEnvelope(collection, members)
      of "md":
        resp localMembersMarkdown(collection, members), "text/markdown; charset=utf-8"
      of "txt":
        resp localMembersText(collection, members), "text/plain; charset=utf-8"
      else:
        resp Http404

    get "/f/data/export":
      let identityKey = localCurrentIdentityKey()
      if identityKey.len == 0:
        requireIdentity(cfg, request.path)
      let
        ownerId = ensureOwner(identityKey)
        payload = exportOwnerData(ownerId)
      respJson payload

    post "/api/f/identity/create":
      let key = newIdentityKey()
      discard ensureOwner(key)
      rememberIdentity(key, cfg)
      redirect("/f/identity?notice=created&referer=" & encodeUrl(refPath()))

    post "/api/f/identity/import":
      let key = @"identity_key".strip
      if not validIdentityKey(key):
        resp Http400, showError("Invalid Finch key", cfg)
      discard ensureOwner(key)
      rememberIdentity(key, cfg)
      redirect("/f/identity?notice=imported&referer=" & encodeUrl(refPath()))

    post "/api/f/identity/skip":
      skipIdentity(cfg)
      redirect(refPath())

    post "/api/f/identity/clear":
      forgetIdentity(cfg)
      redirect("/f/identity?notice=cleared&referer=" & encodeUrl(refPath()))

    post "/api/f/lists":
      let identityKey = localCurrentIdentityKey()
      if identityKey.len == 0:
        requireIdentity(cfg, refPath())
      let ownerId = ensureOwner(identityKey)
      let name = @"name".strip
      if name.len == 0:
        redirect("/f/lists")
      let collection = createCollection(ownerId, localList, name, @"description")
      let created = await createXList(collection.name, collection.description, "Private")
      if not created.ok or created.listId.len == 0:
        discard deleteCollection(ownerId, collection.id)
        resp Http503, showError("Could not create the backing X list right now.", cfg)
      setCollectionXListId(collection.id, created.listId, created.listOwnerId)
      redirect("/f/lists/" & collection.id)

    post "/api/f/lists/@id/delete":
      let identityKey = localCurrentIdentityKey()
      if identityKey.len == 0:
        requireIdentity(cfg, refPath())
      let ownerId = ensureOwner(identityKey)
      let collection = getCollectionById(ownerId, @"id")
      if collection.id.len == 0:
        resp Http404, showError("Local list not found", cfg)
      if collection.xListId.len > 0:
        let deleted = await deleteXList(collection.xListId)
        if not deleted.ok:
          resp Http503, showError("Could not delete the backing X list right now.", cfg)
      if deleteCollection(ownerId, @"id"):
        invalidateHotLocalTimeline(@"id")
        await invalidateLocalTimelineCache(@"id")
      redirect("/f/lists")

    post "/api/f/follow/@username":
      let identityKey = localCurrentIdentityKey()
      if identityKey.len == 0:
        requireIdentity(cfg, refPath())
      let
        ownerId = ensureOwner(identityKey)
        user = await loadUserForLocal(@"username")
      if user.username.len == 0:
        resp Http404, showError("User not found", cfg)
      var collection = getOrCreateFollowing(ownerId)
      let newState = not isMember(collection.id, user.username)
      if newState:
        let ready = await ensureXBackedCollection(collection)
        if not ready.ok:
          resp Http503, showError("Could not sync Finch Following to X right now.", cfg)
        collection = ready.collection
      await syncFollowingToX(collection, user, newState)
      discard setFollowing(ownerId, user, newState)
      invalidateHotLocalTimeline(collection.id)
      await invalidateLocalTimelineCache(collection.id)
      redirect(refPath())

    post "/api/f/following/members":
      let identityKey = localCurrentIdentityKey()
      if identityKey.len == 0:
        requireIdentity(cfg, refPath())
      let usernames = splitLocalUsernames(@"username")
      if usernames.len == 0:
        redirect(refPath())
      let ownerId = ensureOwner(identityKey)
      var collection = getOrCreateFollowing(ownerId)
      let ready = await ensureXBackedCollection(collection)
      if not ready.ok:
        resp Http503, showError("Could not sync Finch Following to X right now.", cfg)
      collection = ready.collection
      for username in usernames:
        let user = await loadUserForLocal(username)
        if user.username.len == 0:
          continue
        await syncFollowingToX(collection, user, true)
        discard setFollowing(ownerId, user, true)
      invalidateHotLocalTimeline(collection.id)
      await invalidateLocalTimelineCache(collection.id)
      redirect(refPath())

    post "/api/f/following/attention/hide":
      let identityKey = localCurrentIdentityKey()
      if identityKey.len == 0:
        requireIdentity(cfg, refPath())
      let ownerId = ensureOwner(identityKey)
      let collection = getOrCreateFollowing(ownerId)
      hideAttentionEntity(collection.id, request.params.getOrDefault("entity_key"))
      redirect(refPath())

    post "/api/f/profile/@username/lists":
      let identityKey = localCurrentIdentityKey()
      if identityKey.len == 0:
        requireIdentity(cfg, refPath())
      let
        ownerId = ensureOwner(identityKey)
        user = await loadUserForLocal(@"username")
      if user.username.len == 0:
        resp Http404, showError("User not found", cfg)

      var selectedIds: seq[string]
      for key, value in params(request):
        if key.startsWith("list_") and value in ["on", "true", "1"]:
          selectedIds.add key[5 .. ^1]

      let newListName = @"new_list_name".strip
      if newListName.len > 0:
        let newList = createCollection(ownerId, localList, newListName, @"new_list_description")
        let created = await createXList(newList.name, newList.description, "Private")
        if not created.ok or created.listId.len == 0:
          discard deleteCollection(ownerId, newList.id)
          resp Http503, showError("Could not create the backing X list right now.", cfg)
        setCollectionXListId(newList.id, created.listId, created.listOwnerId)
        selectedIds.add newList.id

      let allowed = getCollections(ownerId, "list").mapIt(it.id)
      for collectionId in allowed:
        let col = getCollectionById(ownerId, collectionId)
        if col.id.len == 0:
          continue
        if collectionId in selectedIds:
          let ready = await ensureXBackedCollection(col)
          if not ready.ok:
            resp Http503, showError("Could not sync list membership to X right now.", cfg)
          await syncListMemberToX(ready.collection, user, true)
          upsertMember(collectionId, user)
        elif isMember(collectionId, user.username):
          if col.xListId.len > 0:
            await syncListMemberToX(col, user, false)
          removeMember(collectionId, user.username)
      for collectionId in allowed:
        invalidateHotLocalTimeline(collectionId)
        await invalidateLocalTimelineCache(collectionId)
      redirect(refPath())

    post "/api/f/lists/@id/migrate":
      let identityKey = localCurrentIdentityKey()
      if identityKey.len == 0:
        requireIdentity(cfg, refPath())
      let
        ownerId = ensureOwner(identityKey)
        collection = getCollectionById(ownerId, @"id")
      if collection.id.len == 0:
        resp Http404, showError("List not found", cfg)
      if collection.xListId.len > 0:
        redirect("/f/lists/" & collection.id)
      let ok = await migrateCollectionToX(collection)
      if not ok:
        redirect("/f/lists/" & collection.id & "?migrate_error=1")
      invalidateHotLocalTimeline(collection.id)
      await invalidateLocalTimelineCache(collection.id)
      redirect("/f/lists/" & collection.id)

    post "/api/f/lists/@id/members":
      let identityKey = localCurrentIdentityKey()
      if identityKey.len == 0:
        requireIdentity(cfg, refPath())
      let usernames = splitLocalUsernames(@"username")
      if usernames.len == 0:
        redirect(refPath())
      let
        ownerId = ensureOwner(identityKey)
      var collection = getCollectionById(ownerId, @"id")
      if collection.id.len == 0:
        resp Http404, showError("Local list not found", cfg)
      let ready = await ensureXBackedCollection(collection)
      if not ready.ok:
        resp Http503, showError("Could not sync this list to X right now.", cfg)
      collection = ready.collection
      for username in usernames:
        let user = await loadUserForLocal(username)
        if user.username.len == 0:
          continue
        await syncListMemberToX(collection, user, true)
        upsertMember(collection.id, user)
      invalidateHotLocalTimeline(collection.id)
      await invalidateLocalTimelineCache(collection.id)
      redirect(refPath())

    post "/api/f/lists/@id/attention/hide":
      let identityKey = localCurrentIdentityKey()
      if identityKey.len == 0:
        requireIdentity(cfg, refPath())
      let
        ownerId = ensureOwner(identityKey)
        collection = getCollectionById(ownerId, @"id")
      if collection.id.len == 0:
        redirect(refPath())
      hideAttentionEntity(collection.id, request.params.getOrDefault("entity_key"))
      redirect(refPath())

    post "/api/f/lists/@id/members/@username/remove":
      let identityKey = localCurrentIdentityKey()
      if identityKey.len == 0:
        requireIdentity(cfg, refPath())
      let
        ownerId = ensureOwner(identityKey)
        collection = getCollectionById(ownerId, @"id")
      if collection.id.len == 0:
        resp Http404, showError("Local list not found", cfg)
      let username = normalizeLocalUsername(@"username")
      let user = await loadUserForLocal(username)
      if user.username.len > 0 and collection.xListId.len > 0:
        await syncListMemberToX(collection, user, false)
      removeMember(collection.id, username)
      invalidateHotLocalTimeline(collection.id)
      await invalidateLocalTimelineCache(collection.id)
      redirect(refPath())

    post "/api/f/lists/@id/members/remove":
      let identityKey = localCurrentIdentityKey()
      if identityKey.len == 0:
        requireIdentity(cfg, refPath())
      let ownerId = ensureOwner(identityKey)
      let collection = getCollectionById(ownerId, @"id")
      if collection.id.len == 0:
        resp Http404, showError("Local list not found", cfg)
      let usernames = selectedRemovalMembers(request)
      if usernames.len == 0:
        redirect(refPath())
      if collection.xListId.len > 0:
        for username in usernames:
          let user = await loadUserForLocal(username)
          if user.username.len > 0:
            await syncListMemberToX(collection, user, false)
      removeMembers(collection.id, usernames)
      invalidateHotLocalTimeline(collection.id)
      await invalidateLocalTimelineCache(collection.id)
      redirect(refPath())

    post "/api/f/lists/@id/members/@username/filters":
      let identityKey = localCurrentIdentityKey()
      if identityKey.len == 0:
        requireIdentity(cfg, refPath())
      let
        ownerId = ensureOwner(identityKey)
        collection = getCollectionById(ownerId, @"id")
      if collection.id.len == 0:
        resp Http404, showError("Local list not found", cfg)
      let username = normalizeLocalUsername(@"username")
      let filters = MemberFilterPrefs(
        hideRetweets: @"hideRetweets" in ["on", "true", "1"],
        hideQuotes: @"hideQuotes" in ["on", "true", "1"],
        hideReplies: @"hideReplies" in ["on", "true", "1"]
      )
      setMemberFilters(collection.id, username, filters)
      redirect(refPath())

    post "/api/f/following/members/@username/filters":
      let identityKey = localCurrentIdentityKey()
      if identityKey.len == 0:
        requireIdentity(cfg, refPath())
      let
        ownerId = ensureOwner(identityKey)
        collection = getOrCreateFollowing(ownerId)
      let username = normalizeLocalUsername(@"username")
      let filters = MemberFilterPrefs(
        hideRetweets: @"hideRetweets" in ["on", "true", "1"],
        hideQuotes: @"hideQuotes" in ["on", "true", "1"],
        hideReplies: @"hideReplies" in ["on", "true", "1"]
      )
      setMemberFilters(collection.id, username, filters)
      redirect(refPath())

    post "/api/f/following/members/@username/remove":
      let identityKey = localCurrentIdentityKey()
      if identityKey.len == 0:
        requireIdentity(cfg, refPath())
      let
        ownerId = ensureOwner(identityKey)
      var collection = getOrCreateFollowing(ownerId)
      let ready = await ensureXBackedCollection(collection)
      if not ready.ok:
        resp Http503, showError("Could not sync Finch Following to X right now.", cfg)
      collection = ready.collection
      let username = normalizeLocalUsername(@"username")
      let user = await loadUserForLocal(username)
      if user.username.len > 0:
        await syncFollowingToX(collection, user, false)
      removeMember(collection.id, username)
      invalidateHotLocalTimeline(collection.id)
      await invalidateLocalTimelineCache(collection.id)
      redirect(refPath())

    post "/api/f/following/members/remove":
      let identityKey = localCurrentIdentityKey()
      if identityKey.len == 0:
        requireIdentity(cfg, refPath())
      let ownerId = ensureOwner(identityKey)
      let collection = getOrCreateFollowing(ownerId)
      let usernames = selectedRemovalMembers(request)
      if usernames.len == 0:
        redirect(refPath())
      if collection.xListId.len > 0:
        for username in usernames:
          let user = await loadUserForLocal(username)
          if user.username.len > 0:
            await syncFollowingToX(collection, user, false)
      removeMembers(collection.id, usernames)
      invalidateHotLocalTimeline(collection.id)
      await invalidateLocalTimelineCache(collection.id)
      redirect(refPath())

    post "/api/f/affiliates/@username/following":
      let identityKey = localCurrentIdentityKey()
      if identityKey.len == 0:
        requireIdentity(cfg, refPath())
      let usernames = selectedAffiliateUsernames(request)
      if usernames.len == 0:
        redirect(refPath())
      let ownerId = ensureOwner(identityKey)
      var collection = getOrCreateFollowing(ownerId)
      let ready = await ensureXBackedCollection(collection)
      if not ready.ok:
        resp Http503, showError("Could not sync Finch Following to X right now.", cfg)
      collection = ready.collection
      for username in usernames:
        let user = await loadUserForLocal(username)
        if user.username.len == 0:
          continue
        await syncFollowingToX(collection, user, true)
        discard setFollowing(ownerId, user, true)
      invalidateHotLocalTimeline(collection.id)
      await invalidateLocalTimelineCache(collection.id)
      redirect(refPath())

    post "/api/f/affiliates/@username/lists":
      let identityKey = localCurrentIdentityKey()
      if identityKey.len == 0:
        requireIdentity(cfg, refPath())
      let usernames = selectedAffiliateUsernames(request)
      if usernames.len == 0:
        redirect(refPath())
      let ownerId = ensureOwner(identityKey)

      var selectedIds: seq[string]
      for key, value in params(request):
        if key.startsWith("list_") and value in ["on", "true", "1"]:
          selectedIds.add key[5 .. ^1]

      let newListName = @"new_list_name".strip
      if newListName.len > 0:
        let newList = createCollection(ownerId, localList, newListName, @"new_list_description")
        let created = await createXList(newList.name, newList.description, "Private")
        if not created.ok or created.listId.len == 0:
          discard deleteCollection(ownerId, newList.id)
          resp Http503, showError("Could not create the backing X list right now.", cfg)
        setCollectionXListId(newList.id, created.listId, created.listOwnerId)
        selectedIds.add newList.id

      if selectedIds.len == 0:
        redirect(refPath())

      for username in usernames:
        let user = await loadUserForLocal(username)
        if user.username.len == 0:
          continue
        for collectionId in selectedIds:
          let col = getCollectionById(ownerId, collectionId)
          if col.id.len > 0:
            let ready = await ensureXBackedCollection(col)
            if not ready.ok:
              resp Http503, showError("Could not sync this list to X right now.", cfg)
            await syncListMemberToX(ready.collection, user, true)
            upsertMember(collectionId, user)
      for collectionId in selectedIds:
        invalidateHotLocalTimeline(collectionId)
        await invalidateLocalTimelineCache(collectionId)
      redirect(refPath())

    post "/api/f/data/import":
      let bundle = @"bundle".strip
      if bundle.len == 0:
        redirect("/settings")
      var key = localCurrentIdentityKey()
      if key.len == 0:
        key = extractIdentityKeyFromBundle(bundle)
      if not validIdentityKey(key):
        resp Http400, showError("Import bundle does not include a valid Finch key", cfg)
      discard importOwnerData(key, bundle)
      rememberIdentity(key, cfg)
      redirect("/f/identity?notice=imported&referer=" & encodeUrl(refPath()))

    post "/api/f/data/reset":
      let identityKey = localCurrentIdentityKey()
      if identityKey.len == 0:
        requireIdentity(cfg, refPath())
      let ownerId = ensureOwner(identityKey)
      invalidateHotLocalTimeline("")
      await invalidateAllLocalTimelineCaches()
      discard ownerId
      redirect("/settings?referer=" & encodeUrl(refPath()))

    post "/api/f/data/delete":
      let identityKey = localCurrentIdentityKey()
      if identityKey.len == 0:
        requireIdentity(cfg, refPath())
      let ownerId = ensureOwner(identityKey)
      clearOwnerCollections(ownerId)
      forgetIdentity(cfg)
      redirect("/f/identity?notice=cleared&referer=" & encodeUrl(refPath()))
