# SPDX-License-Identifier: AGPL-3.0-only
import json, options, sequtils, strutils, times, tables, sets

import types, formatters, query, articles

type ExportContext = object
  users: OrderedTable[string, JsonNode]

const exportSchemaVersion* = 1
const maxExportItems* = 500

proc parseSelectedTweetIds*(raw: string): seq[int64] =
  for part in raw.split(','):
    let token = part.strip
    if token.len == 0:
      continue
    try:
      result.add parseBiggestInt(token).int64
    except ValueError:
      discard

proc filterTimelineBySelected*(results: Timeline; raw: string): Timeline =
  let selected = parseSelectedTweetIds(raw)
  if selected.len == 0:
    return results

  result = results
  result.content = @[]
  result.bottom = ""
  for thread in results.content:
    for tweet in thread:
      let displayId =
        if tweet.retweet.isSome: tweet.retweet.get.id
        else: tweet.id
      if displayId in selected:
        result.content.add @[tweet]

proc filterProfileBySelected*(profile: Profile; raw: string): Profile =
  result = profile
  result.tweets = filterTimelineBySelected(profile.tweets, raw)

proc displayTweet(tweet: Tweet): Tweet =
  if tweet.retweet.isSome:
    tweet.retweet.get
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

proc matchesTimelineQuery*(tweet: Tweet; query: Query): bool =
  let shown = displayTweet(tweet)
  let
    isReply = tweet.reply.len > 0 or tweet.replyId != 0 or shown.reply.len > 0 or shown.replyId != 0
    isRetweet = tweet.retweet.isSome
    isQuote = tweet.quote.isSome or shown.quote.isSome
    isSpace = shown.card.isSome and shown.card.get.kind in {audiospace, broadcast, periscope}
    hasImages = shown.photos.len > 0
    hasVideos = shown.video.isSome or shown.gif.isSome
    hasLinks = tweetHasLinks(shown)
    hasMedia = tweetHasMedia(shown)

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
  if "spaces" in query.excludes and isSpace:
    return false
  if "spaces" in query.filters and not isSpace:
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

proc filterTimelineByQuery*(results: Timeline; query: Query): Timeline =
  result = results
  result.query = query
  result.content = @[]
  for thread in results.content:
    if thread.len == 0:
      continue
    var filtered: Tweets = @[]
    for tweet in thread:
      if matchesTimelineQuery(tweet, query):
        filtered.add tweet
    if filtered.len > 0:
      result.content.add filtered

proc dedupeTimeline*(results: Timeline): Timeline =
  result = results
  result.content = @[]
  var seen = initHashSet[int64]()
  for thread in results.content:
    if thread.len == 0:
      continue
    var filtered: Tweets = @[]
    for tweet in thread:
      let displayId =
        if tweet.retweet.isSome: tweet.retweet.get.id
        else: tweet.id
      if displayId == 0 or displayId in seen:
        continue
      seen.incl displayId
      filtered.add tweet
    if filtered.len > 0:
      result.content.add filtered

proc filterProfileByQuery*(profile: Profile; query: Query): Profile =
  result = profile
  result.tweets = filterTimelineByQuery(profile.tweets, query)

proc normalizeExportLimit*(raw: string; defaultValue=0): int =
  if raw.len == 0:
    return defaultValue
  try:
    result = parseInt(raw)
  except ValueError:
    return defaultValue
  if result < 0:
    result = 0
  if result > maxExportItems:
    result = maxExportItems

proc exportSelectionRaw*(selectedRaw, limitRaw: string): string =
  if normalizeExportLimit(limitRaw) > 0:
    ""
  else:
    selectedRaw

proc limitTimeline*(results: Timeline; limit: int): Timeline =
  result = dedupeTimeline(results)
  if limit <= 0 or result.content.len <= limit:
    return
  result.content = result.content[0 ..< limit]
  result.bottom = ""

proc exportMetaJson*(results: Timeline): JsonNode =
  let requested =
    if results.requestedCount > 0: results.requestedCount
    else: 0
  let returned = results.content.len
  let partial =
    requested > 0 and returned < requested
  let exhaustedReason =
    if not partial:
      ""
    elif results.budgetExhausted:
      "budget_exhausted"
    elif results.bottom.len == 0:
      "timeline_exhausted"
    else:
      "partial"
  result = %*{
    "query_built": displayQuery(results.query),
    "n_requested": requested,
    "n_returned": returned,
    "partial": partial,
    "pages_fetched": results.pagesFetched,
    "page_budget": results.pageBudget,
    "budget_exhausted": results.budgetExhausted,
    "timeline_exhausted": partial and not results.budgetExhausted and results.bottom.len == 0
  }
  if results.bottom.len > 0:
    result["cursor_next"] = %results.bottom
  if exhaustedReason.len > 0:
    result["partial_reason"] = %exhaustedReason

proc withExportModeMeta*(payload: JsonNode; selectedRaw: string; exportLimit: int): JsonNode =
  result = payload
  let selectedCount =
    if selectedRaw.len == 0:
      0
    else:
      selectedRaw.split(',').mapIt(it.strip).filterIt(it.len > 0).len
  result["export"] = %*{
    "mode": (if exportLimit > 0: "last_n" elif selectedCount > 0: "selected" else: "all_visible"),
    "selected_count": selectedCount,
    "limit": exportLimit
  }

proc limitUserResults*(results: Result[User]; limit: int): Result[User] =
  result = results
  if limit <= 0 or result.content.len <= limit:
    return
  result.content = result.content[0 ..< limit]
  result.bottom = ""

proc limitProfile*(profile: Profile; limit: int): Profile =
  result = profile
  result.tweets = limitTimeline(result.tweets, limit)

proc initExportContext(): ExportContext =
  ExportContext(users: initOrderedTable[string, JsonNode]())

proc liveCheckedAt(): string =
  try:
    now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
  except AssertionDefect:
    ""

proc wrapLivePayload*(kind: string; payload: JsonNode): JsonNode =
  result = %*{
    "schema": exportSchemaVersion,
    "kind": kind,
    "mode": "live",
    "checked_at_iso": liveCheckedAt(),
    "payload": payload
  }

proc verifiedTypeValue(user: User): string =
  if user.verifiedType == VerifiedType.none: ""
  else: $user.verifiedType

proc safeDateTime(dt: DateTime; format: string): string =
  try:
    dt.utc.format(format)
  except AssertionDefect:
    ""

proc validJoinDate(dt: DateTime): bool =
  let year = safeDateTime(dt, "yyyy")
  if year.len != 4:
    return false
  try:
    parseInt(year) >= 2006
  except ValueError:
    false

proc userToJson(user: User): JsonNode =
  result = %*{
    "id": user.id,
    "username": user.username,
    "fullname": user.fullname,
    "avatar": getUserPic(user),
    "verified_type": verifiedTypeValue(user),
    "protected": user.protected
  }

  if user.affiliateBadgeName.len > 0:
    result["affiliate_badge"] = %*{
      "name": user.affiliateBadgeName,
      "image_url": user.affiliateBadgeUrl,
      "target_url": user.affiliateBadgeTarget
    }
  if user.affiliatesCount > 0:
    result["affiliates_count"] = %user.affiliatesCount

proc userKey(user: User): string =
  if user.id.len > 0: user.id else: user.username

proc registerUser(ctx: var ExportContext; user: User): string =
  result = userKey(user)
  if result.len == 0:
    result = user.username
  if result notin ctx.users:
    ctx.users[result] = userToJson(user)

proc usersToJson(ctx: ExportContext): JsonNode =
  result = newJObject()
  for key, value in ctx.users:
    result[key] = value

proc listToJsonNode(list: List): JsonNode =
  %*{
    "id": list.id,
    "name": list.name,
    "username": list.username,
    "description": list.description,
    "members": list.members,
    "subscribers": list.subscribers
  }

proc queryToJson(q: Query): JsonNode =
  result = %*{
    "kind": $q.kind,
    "text": q.text
  }
  if q.kind == tweets:
    result["sort"] = %($q.sort)
    result["scope"] = %($q.scope)
  if q.fromUser.len > 0:
    var users = newJArray()
    for user in q.fromUser:
      users.add %user
    result["from_user"] = users
  if q.toUser.len > 0:
    var users = newJArray()
    for user in q.toUser:
      users.add %user
    result["to_user"] = users
  if q.mentions.len > 0:
    var mentions = newJArray()
    for mention in q.mentions:
      mentions.add %mention
    result["mentions"] = mentions
  if q.filters.len > 0:
    var filters = newJArray()
    for item in q.filters:
      filters.add %item
    result["filters"] = filters
  if q.excludes.len > 0:
    var excludes = newJArray()
    for item in q.excludes:
      excludes.add %item
    result["excludes"] = excludes
  if q.since.len > 0:
    result["since"] = %q.since
  if q.until.len > 0:
    result["until"] = %q.until
  if q.minLikes.len > 0:
    result["min_faves"] = %q.minLikes
  if q.minRetweets.len > 0:
    result["min_retweets"] = %q.minRetweets
  if q.minReplies.len > 0:
    result["min_replies"] = %q.minReplies

proc videoVariantToJson(variant: VideoVariant): JsonNode =
  %*{
    "content_type": $variant.contentType,
    "url": variant.url,
    "bitrate": variant.bitrate,
    "resolution": variant.resolution
  }

proc videoToJson(video: Video): JsonNode =
  var variants = newJArray()
  for variant in video.variants:
    variants.add videoVariantToJson(variant)

  %*{
    "url": video.url,
    "thumb": video.thumb,
    "duration_ms": video.durationMs,
    "duration": getDuration(video),
    "available": video.available,
    "reason": video.reason,
    "title": video.title,
    "description": video.description,
    "playback_type": $video.playbackType,
    "variants": variants
  }

proc gifToJson(gif: Gif): JsonNode =
  %*{
    "url": gif.url,
    "thumb": gif.thumb
  }

proc photoToJson(photo: Photo): JsonNode =
  %*{
    "url": photo.url,
    "alt_text": photo.altText
  }

proc articleEmbedUrl(tweetId: string): string =
  if tweetId.len == 0: ""
  else: "https://x.com/i/web/status/" & tweetId

proc articlePhotoIndex(article: Article; photo: Photo): int =
  for i, candidate in article.photos:
    if candidate.url == photo.url:
      return i
  return -1

proc articleBlockToJson(article: Article; articleBlock: ArticleBlock): JsonNode =
  result = %*{
    "kind": $articleBlock.kind
  }

  case articleBlock.kind
  of paragraph, orderedListItem, unorderedListItem:
    result["text"] = %articleBlock.text
  of image:
    if articleBlock.photo.isSome:
      let photo = articleBlock.photo.get
      let idx = articlePhotoIndex(article, photo)
      if idx >= 0:
        result["photo_index"] = %idx
      else:
        result["url"] = %photo.url
      if photo.altText.len > 0:
        result["alt_text"] = %photo.altText
  of tweetEmbed:
    result["tweet_id"] = %articleBlock.tweetId
    let url = articleEmbedUrl(articleBlock.tweetId)
    if url.len > 0:
      result["url"] = %url

proc pollToJson(poll: Poll): JsonNode =
  var options = newJArray()
  for i, option in poll.options:
    let votes = if i < poll.values.len: poll.values[i] else: 0
    options.add(%*{
      "label": option,
      "votes": votes
    })

  %*{
    "status": poll.status,
    "votes": poll.votes,
    "leader": poll.leader,
    "options": options
  }

proc cardToJson(card: Card): JsonNode =
  var node = %*{
    "kind": $card.kind,
    "url": card.url,
    "title": card.title,
    "text": stripHtml(card.text)
  }
  if card.dest.len > 0:
    node["destination"] = %card.dest
  if card.image.len > 0:
    node["image"] = %card.image
  if card.video.isSome:
    node["video"] = videoToJson(card.video.get)
  node

proc articleToJson*(article: Article): JsonNode =
  var photos = newJArray()
  for photo in article.photos:
    photos.add photoToJson(photo)

  var blocks = newJArray()
  for articleBlock in article.blocks:
    blocks.add articleBlockToJson(article, articleBlock)

  result = %*{
    "url": article.url,
    "title": article.title,
    "body": article.body,
    "partial": article.partial
  }
  if article.cover.isSome:
    result["cover_photo"] = photoToJson(article.cover.get)
  if photos.len > 0:
    result["media"] = %*{
      "photos": photos
    }
  if blocks.len > 0:
    result["blocks"] = blocks

proc articleRefToJson(article: Article): JsonNode =
  result = %*{
    "url": article.url,
    "title": article.title,
    "partial": article.partial
  }
  if article.cover.isSome:
    result["cover_photo"] = photoToJson(article.cover.get)

proc articleMarkdownBody*(article: Article): string =
  var lines: seq[string]
  var previousList = false

  if article.cover.isSome:
    let cover = article.cover.get
    lines.add("Cover image: " & cover.url)
    lines.add("")

  let blocks = if article.blocks.len > 0:
      article.blocks
    else:
      @[ArticleBlock(kind: paragraph, text: article.body)]

  for articleBlock in blocks:
    case articleBlock.kind
    of paragraph:
      if previousList and (lines.len == 0 or lines[^1].len > 0):
        lines.add("")
      if articleBlock.text.len > 0:
        lines.add(articleBlock.text)
        lines.add("")
      previousList = false
    of orderedListItem:
      lines.add("1. " & articleBlock.text)
      previousList = true
    of unorderedListItem:
      lines.add("- " & articleBlock.text)
      previousList = true
    of image:
      if previousList and (lines.len == 0 or lines[^1].len > 0):
        lines.add("")
      if articleBlock.photo.isSome:
        lines.add("Image: " & articleBlock.photo.get.url)
        lines.add("")
      previousList = false
    of tweetEmbed:
      if previousList and (lines.len == 0 or lines[^1].len > 0):
        lines.add("")
      let url = articleEmbedUrl(articleBlock.tweetId)
      if url.len > 0:
        lines.add("Embedded tweet: " & url)
        lines.add("")
      previousList = false

  result = lines.join("\n").strip

proc articleTextBody*(article: Article; prefix=""): seq[string] =
  if article.cover.isSome:
    result.add(prefix & "cover_image: " & article.cover.get.url)

  let blocks = if article.blocks.len > 0:
      article.blocks
    else:
      @[ArticleBlock(kind: paragraph, text: article.body)]

  for articleBlock in blocks:
    case articleBlock.kind
    of paragraph:
      if articleBlock.text.len > 0:
        for line in articleBlock.text.splitLines:
          result.add(prefix & line)
    of orderedListItem:
      result.add(prefix & "1. " & articleBlock.text)
    of unorderedListItem:
      result.add(prefix & "- " & articleBlock.text)
    of image:
      if articleBlock.photo.isSome:
        result.add(prefix & "image: " & articleBlock.photo.get.url)
    of tweetEmbed:
      let url = articleEmbedUrl(articleBlock.tweetId)
      if url.len > 0:
        result.add(prefix & "embedded_tweet: " & url)

proc tweetToJson(tweet: Tweet; cfg: Config; ctx: var ExportContext): JsonNode =
  var photos = newJArray()
  for photo in tweet.photos:
    photos.add photoToJson(photo)

  let authorId = registerUser(ctx, tweet.user)
  let articleUrl = tweet.getArticleUrl

  result = %*{
    "id": $tweet.id,
    "url": getUrlPrefix(cfg) & getLink(tweet, focus=false),
    "text": stripHtml(tweet.text),
    "created_at_iso": safeDateTime(tweet.time, "yyyy-MM-dd'T'HH:mm:ss'Z'"),
    "author_id": authorId,
    "stats": %*{
      "replies": tweet.stats.replies,
      "retweets": tweet.stats.retweets,
      "likes": tweet.stats.likes,
      "views": tweet.stats.views
    },
    "media": %*{
      "photos": photos
    }
  }

  if tweet.gif.isSome:
    result["media"]["gif"] = gifToJson(tweet.gif.get)
  if tweet.video.isSome:
    result["media"]["video"] = videoToJson(tweet.video.get)
  if tweet.poll.isSome:
    result["poll"] = pollToJson(tweet.poll.get)
  if articleUrl.len > 0:
    result["article_url"] = %articleUrl
  if tweet.article.isSome:
    var article = tweet.article.get
    if article.url.len == 0:
      article.url = articleUrl
    result["article"] = articleToJson(article)
  elif tweet.card.isSome:
    result["card"] = cardToJson(tweet.card.get)
  if tweet.note.len > 0:
    result["note"] = %stripHtml(tweet.note)
  if tweet.quote.isSome:
    result["quote"] = tweetToJson(tweet.quote.get, cfg, ctx)

proc compactStatusTweetToJson*(tweet: Tweet; cfg: Config): JsonNode =
  var photos = newJArray()
  for photo in tweet.photos:
    photos.add photoToJson(photo)

  result = %*{
    "id": $tweet.id,
    "url": getUrlPrefix(cfg) & getLink(tweet, focus=false),
    "text": stripHtml(tweet.text),
    "created_at_iso": safeDateTime(tweet.time, "yyyy-MM-dd'T'HH:mm:ss'Z'"),
    "author": %*{
      "id": tweet.user.id,
      "username": tweet.user.username,
      "fullname": tweet.user.fullname
    },
    "stats": %*{
      "replies": tweet.stats.replies,
      "retweets": tweet.stats.retweets,
      "likes": tweet.stats.likes,
      "views": tweet.stats.views
    }
  }

  if photos.len > 0 or tweet.gif.isSome or tweet.video.isSome:
    result["media"] = %*{
      "photos": photos
    }
    if tweet.gif.isSome:
      result["media"]["gif"] = gifToJson(tweet.gif.get)
    if tweet.video.isSome:
      result["media"]["video"] = videoToJson(tweet.video.get)

  if tweet.article.isSome:
    var article = tweet.article.get
    if article.url.len == 0:
      article.url = tweet.getArticleUrl
    result["article"] = articleRefToJson(article)
  elif tweet.card.isSome:
    result["card"] = cardToJson(tweet.card.get)

  if tweet.note.len > 0:
    result["note"] = %stripHtml(tweet.note)

  if tweet.quote.isSome:
    result["quote"] = compactStatusTweetToJson(tweet.quote.get, cfg)

proc tweetToJson*(tweet: Tweet; cfg: Config): JsonNode =
  var ctx = initExportContext()
  let node = tweetToJson(tweet, cfg, ctx)
  result = %*{
    "schema": exportSchemaVersion,
    "tweet": node,
    "users": usersToJson(ctx)
  }

proc chainToJson(chain: Chain; cfg: Config; ctx: var ExportContext): JsonNode =
  var tweets = newJArray()
  for tweet in chain.content:
    tweets.add tweetToJson(tweet, cfg, ctx)

  %*{
    "has_more": chain.hasMore,
    "cursor": chain.cursor,
    "tweets": tweets
  }

proc conversationToJson*(conv: Conversation; cfg: Config): JsonNode =
  var
    ctx = initExportContext()
    before = newJArray()
    after = newJArray()

  for tweet in conv.before.content:
    before.add tweetToJson(tweet, cfg, ctx)

  for tweet in conv.after.content:
    after.add tweetToJson(tweet, cfg, ctx)

  result = %*{
    "schema": exportSchemaVersion,
    "kind": "status",
    "tweet": tweetToJson(conv.tweet, cfg, ctx),
    "thread": %*{
      "before": before,
      "after": after,
      "has_more_before": conv.before.hasMore,
      "has_more_after": conv.after.hasMore
    },
    "users": usersToJson(ctx)
  }

proc compactConversationToJson*(conv: Conversation; cfg: Config): JsonNode =
  result = %*{
    "schema": exportSchemaVersion,
    "kind": "status",
    "tweet": compactStatusTweetToJson(conv.tweet, cfg)
  }

  let hasBefore = conv.before.content.len > 0 or conv.before.hasMore
  let hasAfter = conv.after.content.len > 0 or conv.after.hasMore

  if hasBefore or hasAfter:
    var before = newJArray()
    var after = newJArray()

    for tweet in conv.before.content:
      before.add compactStatusTweetToJson(tweet, cfg)
    for tweet in conv.after.content:
      after.add compactStatusTweetToJson(tweet, cfg)

    result["thread"] = %*{
      "before": before,
      "after": after,
      "has_more_before": conv.before.hasMore,
      "has_more_after": conv.after.hasMore
    }

proc tweetMarkdown(tweet: Tweet; cfg: Config; depth=2): string

proc tweetMediaLines(tweet: Tweet): seq[string] =
  for photo in tweet.photos:
    result.add("- photo: " & photo.url)
  if tweet.gif.isSome:
    let gif = tweet.gif.get
    result.add("- gif: " & gif.url)
  if tweet.video.isSome:
    let video = tweet.video.get
    if video.url.len > 0:
      result.add("- video: " & video.url)

proc tweetMarkdown(tweet: Tweet; cfg: Config; depth=2): string =
  let
    titlePrefix = repeat("#", max(2, depth))
    authorLine = tweet.user.fullname & " (@" & tweet.user.username & ")"
    text = stripHtml(tweet.text)
    note = stripHtml(tweet.note)

  var sections = @[
    titlePrefix & " " & authorLine,
    "",
    "- url: " & getUrlPrefix(cfg) & getLink(tweet, focus=false),
    "- published: " & safeDateTime(tweet.time, "yyyy-MM-dd'T'HH:mm:ss'Z'"),
    "- stats: replies=" & $tweet.stats.replies & ", retweets=" & $tweet.stats.retweets &
      ", likes=" & $tweet.stats.likes & ", views=" & $tweet.stats.views,
    ""
  ]

  if text.len > 0:
    sections.add(text)
    sections.add("")

  if note.len > 0:
    sections.add("Note:")
    sections.add(note)
    sections.add("")

  let media = tweetMediaLines(tweet)
  if media.len > 0:
    sections.add("Media:")
    sections.add(media.join("\n"))
    sections.add("")

  if tweet.card.isSome:
    let card = tweet.card.get
    sections.add("Card: " & stripHtml(card.title))
    if card.url.len > 0:
      sections.add(card.url)
    sections.add("")

  let articleUrl = tweet.getArticleUrl
  if articleUrl.len > 0:
    sections.add("Article URL: " & articleUrl)
    if tweet.article.isSome:
      let article = tweet.article.get
      if article.partial:
        sections.add("Article status: preview only")
      if article.title.len > 0:
        sections.add("Article title: " & article.title)
      let articleBody = articleMarkdownBody(article)
      if articleBody.len > 0:
        sections.add("")
        sections.add(articleBody)
    sections.add("")

  if tweet.quote.isSome:
    sections.add("Quoted post:")
    sections.add("")
    sections.add(tweetMarkdown(tweet.quote.get, cfg, depth + 1))
    sections.add("")

  result = sections.join("\n").strip

proc conversationToMarkdown*(conv: Conversation; cfg: Config): string =
  var blocks = @["# Status export", "", tweetMarkdown(conv.tweet, cfg)]

  if conv.before.content.len > 0:
    blocks.add("")
    blocks.add("## Thread before")
    for tweet in conv.before.content:
      blocks.add("")
      blocks.add(tweetMarkdown(tweet, cfg, 3))

  if conv.after.content.len > 0:
    blocks.add("")
    blocks.add("## Thread after")
    for tweet in conv.after.content:
      blocks.add("")
      blocks.add(tweetMarkdown(tweet, cfg, 3))

  result = blocks.join("\n").strip & "\n"

proc tweetText(tweet: Tweet; cfg: Config; prefix=""): string =
  let authorLine = prefix & tweet.user.fullname & " (@" & tweet.user.username & ")"
  var sections = @[
    authorLine,
    prefix & "url: " & getUrlPrefix(cfg) & getLink(tweet, focus=false),
    prefix & "published: " & safeDateTime(tweet.time, "yyyy-MM-dd'T'HH:mm:ss'Z'"),
    prefix & "text: " & stripHtml(tweet.text)
  ]

  if tweet.note.len > 0:
    sections.add(prefix & "note: " & stripHtml(tweet.note))

  let articleUrl = tweet.getArticleUrl
  if articleUrl.len > 0:
    sections.add(prefix & "article_url: " & articleUrl)
    if tweet.article.isSome:
      let article = tweet.article.get
      if article.partial:
        sections.add(prefix & "article_status: preview_only")
      if article.title.len > 0:
        sections.add(prefix & "article_title: " & article.title)
      let articleLines = articleTextBody(article, prefix & "  ")
      if articleLines.len > 0:
        sections.add(prefix & "article_body:")
        sections.add(articleLines.join("\n"))

  if tweet.quote.isSome:
    sections.add(prefix & "quote:")
    sections.add(tweetText(tweet.quote.get, cfg, prefix & "  "))

  result = sections.join("\n")

proc conversationToText*(conv: Conversation; cfg: Config): string =
  var lines = @["STATUS EXPORT", "", tweetText(conv.tweet, cfg)]

  if conv.before.content.len > 0:
    lines.add("")
    lines.add("THREAD BEFORE")
    for tweet in conv.before.content:
      lines.add("")
      lines.add(tweetText(tweet, cfg))

  if conv.after.content.len > 0:
    lines.add("")
    lines.add("THREAD AFTER")
    for tweet in conv.after.content:
      lines.add("")
      lines.add(tweetText(tweet, cfg))

  result = lines.join("\n").strip & "\n"

proc searchItemToJson(thread: Tweets; cfg: Config; ctx: var ExportContext): JsonNode =
  if thread.len == 1:
    return tweetToJson(thread[0], cfg, ctx)

  var tweets = newJArray()
  for tweet in thread:
    tweets.add tweetToJson(tweet, cfg, ctx)

  %*{
    "kind": "thread",
    "tweets": tweets
  }

proc searchTimelineToJson*(results: Timeline; cfg: Config; selectedRaw=""; exportLimit=0): JsonNode =
  var
    ctx = initExportContext()
    items = newJArray()
  for thread in results.content:
    items.add searchItemToJson(thread, cfg, ctx)

  result = %*{
    "schema": exportSchemaVersion,
    "kind": "search",
    "meta": exportMetaJson(results),
    "query": queryToJson(results.query),
    "items": items,
    "users": usersToJson(ctx)
  }
  if selectedRaw.len > 0 or exportLimit > 0:
    result = withExportModeMeta(result, selectedRaw, exportLimit)
  if results.bottom.len > 0:
    result["next_cursor"] = %results.bottom

proc userSearchToJson*(results: Result[User]): JsonNode =
  var ctx = initExportContext()
  var items = newJArray()
  for user in results.content:
    items.add %registerUser(ctx, user)

  result = %*{
    "schema": exportSchemaVersion,
    "kind": "search",
    "query": queryToJson(results.query),
    "items": items,
    "users": usersToJson(ctx)
  }
  if results.bottom.len > 0:
    result["next_cursor"] = %results.bottom

proc searchTimelineToMarkdown*(results: Timeline; cfg: Config): string =
  var blocks = @["# Search export", "", "- query: " & displayQuery(results.query), ""]
  for thread in results.content:
    if thread.len == 1:
      blocks.add(tweetMarkdown(thread[0], cfg))
      blocks.add("")
    else:
      blocks.add("## Thread result")
      blocks.add("")
      for tweet in thread:
        blocks.add(tweetMarkdown(tweet, cfg, 3))
        blocks.add("")
  result = blocks.join("\n").strip & "\n"

proc userSearchToMarkdown*(results: Result[User]): string =
  var blocks = @["# Search export", "", "- query: " & displayQuery(results.query), ""]
  for user in results.content:
    blocks.add("## " & user.fullname & " (@" & user.username & ")")
    blocks.add("")
    if user.bio.len > 0:
      blocks.add(stripHtml(user.bio))
      blocks.add("")
  result = blocks.join("\n").strip & "\n"

proc searchTimelineToText*(results: Timeline; cfg: Config): string =
  var lines = @["SEARCH EXPORT", "", "query: " & displayQuery(results.query), ""]
  for thread in results.content:
    if thread.len == 1:
      lines.add(tweetText(thread[0], cfg))
      lines.add("")
    else:
      lines.add("THREAD RESULT")
      for tweet in thread:
        lines.add(tweetText(tweet, cfg))
        lines.add("")
  result = lines.join("\n").strip & "\n"

proc userSearchToText*(results: Result[User]): string =
  var lines = @["SEARCH EXPORT", "", "query: " & displayQuery(results.query), ""]
  for user in results.content:
    lines.add(user.fullname & " (@" & user.username & ")")
    if user.bio.len > 0:
      lines.add("bio: " & stripHtml(user.bio))
    lines.add("")
  result = lines.join("\n").strip & "\n"

proc profileToJson*(profile: Profile; cfg: Config; selectedRaw=""; exportLimit=0): JsonNode =
  var
    ctx = initExportContext()
    timeline = newJArray()
  for thread in profile.tweets.content:
    timeline.add searchItemToJson(thread, cfg, ctx)

  let userId = registerUser(ctx, profile.user)

  result = %*{
    "schema": exportSchemaVersion,
    "kind": "profile",
    "meta": exportMetaJson(profile.tweets),
    "user_id": userId,
    "timeline": timeline,
    "users": usersToJson(ctx)
  }
  if selectedRaw.len > 0 or exportLimit > 0:
    result = withExportModeMeta(result, selectedRaw, exportLimit)

  if profile.pinned.isSome:
    result["pinned"] = tweetToJson(profile.pinned.get, cfg, ctx)
    result["users"] = usersToJson(ctx)

  if profile.tweets.bottom.len > 0:
    result["next_cursor"] = %profile.tweets.bottom

proc profileToMarkdown*(profile: Profile; cfg: Config): string =
  var blocks = @[
    "# Profile export",
    "",
    "## " & profile.user.fullname & " (@" & profile.user.username & ")",
    ""
  ]

  if profile.user.bio.len > 0:
    blocks.add(stripHtml(profile.user.bio))
    blocks.add("")

  if profile.pinned.isSome:
    blocks.add("## Pinned")
    blocks.add("")
    blocks.add(tweetMarkdown(profile.pinned.get, cfg, 3))
    blocks.add("")

  blocks.add("## Timeline")
  blocks.add("")
  for thread in profile.tweets.content:
    if thread.len == 1:
      blocks.add(tweetMarkdown(thread[0], cfg, 3))
      blocks.add("")
    else:
      blocks.add("### Thread")
      blocks.add("")
      for tweet in thread:
        blocks.add(tweetMarkdown(tweet, cfg, 4))
        blocks.add("")

  result = blocks.join("\n").strip & "\n"

proc profileToText*(profile: Profile; cfg: Config): string =
  var lines = @[
    "PROFILE EXPORT",
    "",
    profile.user.fullname & " (@" & profile.user.username & ")"
  ]

  if profile.user.bio.len > 0:
    lines.add("bio: " & stripHtml(profile.user.bio))

  if profile.pinned.isSome:
    lines.add("")
    lines.add("PINNED")
    lines.add(tweetText(profile.pinned.get, cfg))

  lines.add("")
  lines.add("TIMELINE")
  for thread in profile.tweets.content:
    lines.add("")
    if thread.len == 1:
      lines.add(tweetText(thread[0], cfg))
    else:
      lines.add("THREAD")
      for tweet in thread:
        lines.add(tweetText(tweet, cfg))
        lines.add("")

  result = lines.join("\n").strip & "\n"

proc profileListsToJson*(user: User; results: Result[List]): JsonNode =
  var items = newJArray()
  for list in results.content:
    items.add listToJsonNode(list)

  result = %*{
    "schema": exportSchemaVersion,
    "kind": "profile_lists",
    "user": userToJson(user),
    "items": items
  }

  if results.bottom.len > 0:
    result["next_cursor"] = %results.bottom

proc profileListsToMarkdown*(user: User; results: Result[List]): string =
  var blocks = @[
    "# Profile lists export",
    "",
    "## " & user.fullname & " (@" & user.username & ")",
    ""
  ]

  for list in results.content:
    blocks.add("### " & list.name)
    blocks.add("")
    blocks.add("- url: /i/lists/" & list.id)
    if list.username.len > 0:
      blocks.add("- owner: @" & list.username)
    blocks.add("- members: " & $list.members)
    blocks.add("- subscribers: " & $list.subscribers)
    if list.description.len > 0:
      blocks.add("")
      blocks.add(stripHtml(list.description))
    blocks.add("")

  result = blocks.join("\n").strip & "\n"

proc profileListsToText*(user: User; results: Result[List]): string =
  var lines = @[
    "PROFILE LISTS EXPORT",
    "",
    user.fullname & " (@" & user.username & ")"
  ]

  for list in results.content:
    lines.add("")
    lines.add("name: " & list.name)
    lines.add("url: /i/lists/" & list.id)
    if list.username.len > 0:
      lines.add("owner: @" & list.username)
    lines.add("members: " & $list.members)
    lines.add("subscribers: " & $list.subscribers)
    if list.description.len > 0:
      lines.add("description: " & stripHtml(list.description))

  result = lines.join("\n").strip & "\n"

proc listTimelineToJson*(list: List; timeline: Timeline; cfg: Config; selectedRaw=""; exportLimit=0): JsonNode =
  var
    ctx = initExportContext()
    items = newJArray()

  for thread in timeline.content:
    items.add searchItemToJson(thread, cfg, ctx)

  result = %*{
    "schema": exportSchemaVersion,
    "kind": "list",
    "meta": exportMetaJson(timeline),
    "list": listToJsonNode(list),
    "items": items,
    "users": usersToJson(ctx)
  }
  if selectedRaw.len > 0 or exportLimit > 0:
    result = withExportModeMeta(result, selectedRaw, exportLimit)

  if timeline.bottom.len > 0:
    result["next_cursor"] = %timeline.bottom

proc listMembersToJson*(list: List; members: Result[User]): JsonNode =
  var
    ctx = initExportContext()
    items = newJArray()

  for user in members.content:
    items.add %registerUser(ctx, user)

  result = %*{
    "schema": exportSchemaVersion,
    "kind": "list_members",
    "list": listToJsonNode(list),
    "items": items,
    "users": usersToJson(ctx)
  }

  if members.bottom.len > 0:
    result["next_cursor"] = %members.bottom

proc listTimelineToMarkdown*(list: List; timeline: Timeline; cfg: Config): string =
  var blocks = @[
    "# List export",
    "",
    "## " & list.name & " (@" & list.username & ")",
    ""
  ]

  if list.description.len > 0:
    blocks.add(list.description)
    blocks.add("")

  for thread in timeline.content:
    if thread.len == 1:
      blocks.add(tweetMarkdown(thread[0], cfg, 3))
      blocks.add("")
    else:
      blocks.add("### Thread")
      blocks.add("")
      for tweet in thread:
        blocks.add(tweetMarkdown(tweet, cfg, 4))
        blocks.add("")

  result = blocks.join("\n").strip & "\n"

proc listMembersToMarkdown*(list: List; members: Result[User]): string =
  var blocks = @[
    "# List members export",
    "",
    "## " & list.name & " (@" & list.username & ")",
    ""
  ]

  if list.description.len > 0:
    blocks.add(list.description)
    blocks.add("")

  for user in members.content:
    blocks.add("### " & user.fullname & " (@" & user.username & ")")
    if user.bio.len > 0:
      blocks.add("")
      blocks.add(stripHtml(user.bio))
    blocks.add("")

  result = blocks.join("\n").strip & "\n"

proc listTimelineToText*(list: List; timeline: Timeline; cfg: Config): string =
  var lines = @[
    "LIST EXPORT",
    "",
    list.name & " (@" & list.username & ")"
  ]

  if list.description.len > 0:
    lines.add("description: " & list.description)

  for thread in timeline.content:
    lines.add("")
    if thread.len == 1:
      lines.add(tweetText(thread[0], cfg))
    else:
      lines.add("THREAD")
      for tweet in thread:
        lines.add(tweetText(tweet, cfg))
        lines.add("")

  result = lines.join("\n").strip & "\n"

proc listMembersToText*(list: List; members: Result[User]): string =
  var lines = @[
    "LIST MEMBERS EXPORT",
    "",
    list.name & " (@" & list.username & ")"
  ]

  if list.description.len > 0:
    lines.add("description: " & list.description)

  for user in members.content:
    lines.add("")
    lines.add(user.fullname & " (@" & user.username & ")")
    if user.bio.len > 0:
      lines.add("bio: " & stripHtml(user.bio))

  result = lines.join("\n").strip & "\n"
