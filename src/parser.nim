# SPDX-License-Identifier: AGPL-3.0-only
import strutils, options, times, math, tables
import packedjson, packedjson/deserialiser
import types, parserutils, utils
import experimental/parser/unifiedcard

proc parseGraphTweet(js: JsonNode): Tweet

proc countTagEntities(entities: JsonNode): int =
  if entities.isNull:
    return 0
  result = entities{"hashtags"}.len + entities{"symbols"}.len

proc parseCommunityNote(js: JsonNode): string =
  let subtitle = js{"subtitle"}
  result = subtitle{"text"}.getStr
  with entities, subtitle{"entities"}:
    result = expandBirdwatchEntities(result, entities)

proc parseUser(js: JsonNode; id=""): User =
  if js.isNull: return
  result = User(
    id: if id.len > 0: id else: js{"id_str"}.getStr,
    username: js{"screen_name"}.getStr,
    fullname: js{"name"}.getStr,
    location: js{"location"}.getStr,
    bio: js{"description"}.getStr,
    userPic: js{"profile_image_url_https"}.getImageStr.replace("_normal", ""),
    banner: js.getBanner,
    following: js{"friends_count"}.getInt,
    followers: js{"followers_count"}.getInt,
    tweets: js{"statuses_count"}.getInt,
    likes: js{"favourites_count"}.getInt,
    media: js{"media_count"}.getInt,
    protected: js{"protected"}.getBool(js{"privacy", "protected"}.getBool),
    joinDate: js{"created_at"}.getTime
  )

  if js{"is_blue_verified"}.getBool(false):
    result.verifiedType = blue

  with verifiedType, js{"verified_type"}:
    result.verifiedType = parseEnum[VerifiedType](verifiedType.getStr)

  result.expandUserEntities(js)

proc parseGraphUser(js: JsonNode): User =
  var user = js{"user_result", "result"}
  if user.isNull:
    user = js{"user_results", "result"}
  if user.isNull:
    user = js{"data", "user", "result"}
  if user.isNull:
    user = js{"data", "user_result", "result"}

  if user.isNull:
    if js{"core"}.notNull:
      user = js
    else:
      return

  if user{"legacy"}.notNull:
    result = parseUser(user{"legacy"}, user{"rest_id"}.getStr)
  else:
    result = User(id: user{"rest_id"}.getStr)

  if result.verifiedType == none and user{"is_blue_verified"}.getBool(false):
    result.verifiedType = blue

  result.affiliatesCount = user{"business_account", "affiliates_count"}.getInt

  let affiliateLabel = user{"affiliates_highlighted_label", "label"}
  if affiliateLabel.notNull:
    result.affiliateBadgeName = affiliateLabel{"description"}.getStr
    result.affiliateBadgeUrl = affiliateLabel{"badge", "url"}.getImageStr
    result.affiliateBadgeTarget = affiliateLabel{"url", "url"}.getStr

  # fallback to support UserMedia/recent GraphQL updates
  if result.username.len == 0:
    result.username = user{"core", "screen_name"}.getStr
    result.fullname = user{"core", "name"}.getStr
    result.userPic = user{"avatar", "image_url"}.getImageStr.replace("_normal", "")

    if user{"is_blue_verified"}.getBool(false):
      result.verifiedType = blue

    with verifiedType, user{"verification", "verified_type"}:
      result.verifiedType = parseEnum[VerifiedType](verifiedType.getStr)

  if result.affiliatesCount == 0:
    result.affiliatesCount = user{"business_account", "affiliates_count"}.getInt

  if result.affiliateBadgeName.len == 0:
    let affiliateLabel = user{"affiliates_highlighted_label", "label"}
    if affiliateLabel.notNull:
      result.affiliateBadgeName = affiliateLabel{"description"}.getStr
      result.affiliateBadgeUrl = affiliateLabel{"badge", "url"}.getImageStr
      result.affiliateBadgeTarget = affiliateLabel{"url", "url"}.getStr

proc parseTimelineList(js: JsonNode): List =
  if js.isNull:
    return

  let banner = js{"custom_banner_media", "media_info", "original_img_url"}.getImageStr
  let fallbackBanner = js{"default_banner_media", "media_info", "original_img_url"}.getImageStr

  result = List(
    id: js{"id_str"}.getStr(js{"id"}.getStr),
    name: js{"name"}.getStr,
    username: js{"user_results", "result", "legacy", "screen_name"}.getStr(
      js{"user_results", "result", "core", "screen_name"}.getStr),
    userId: js{"user_results", "result", "rest_id"}.getStr,
    description: js{"description"}.getStr,
    members: js{"member_count"}.getInt,
    subscribers: js{"subscriber_count"}.getInt,
    banner: if banner.len > 0: banner else: fallbackBanner
  )

proc parseGraphList*(js: JsonNode): List =
  if js.isNull: return

  var list = js{"data", "user_by_screen_name", "list"}
  if list.isNull:
    list = js{"data", "list"}
  if list.isNull:
    return

  result = List(
    id: list{"id_str"}.getStr,
    name: list{"name"}.getStr,
    username: list{"user_results", "result", "legacy", "screen_name"}.getStr,
    userId: list{"user_results", "result", "rest_id"}.getStr,
    description: list{"description"}.getStr,
    members: list{"member_count"}.getInt,
    subscribers: list{"subscriber_count"}.getInt,
    banner: list{"custom_banner_media", "media_info", "original_img_url"}.getImageStr
  )

proc parsePoll(js: JsonNode): Poll =
  let vals = js{"binding_values"}
  # name format is pollNchoice_*
  for i in '1' .. js{"name"}.getStr[4]:
    let choice = "choice" & i
    result.values.add parseInt(vals{choice & "_count"}.getStrVal("0"))
    result.options.add vals{choice & "_label"}.getStrVal

  let time = vals{"end_datetime_utc", "string_value"}.getDateTime
  if time > now():
    let timeLeft = $(time - now())
    result.status = timeLeft[0 ..< timeLeft.find(",")]
  else:
    result.status = "Final results"

  result.leader = result.values.find(max(result.values))
  result.votes = result.values.sum

proc parseVideoVariants(variants: JsonNode): seq[VideoVariant] =
  result = @[]
  for v in variants:
    let
      url = v{"url"}.getStr
      contentType = parseEnum[VideoType](v{"content_type"}.getStr("video/mp4"))
      bitrate = v{"bit_rate"}.getInt(v{"bitrate"}.getInt(0))

    result.add VideoVariant(
      contentType: contentType,
      bitrate: bitrate,
      url: url,
      resolution: if contentType == mp4: getMp4Resolution(url) else: 0
    )

proc parseVideo(js: JsonNode): Video =
  result = Video(
    thumb: js{"media_url_https"}.getImageStr,
    available: true,
    title: js{"ext_alt_text"}.getStr,
    durationMs: js{"video_info", "duration_millis"}.getInt
    # playbackType: mp4
  )

  with status, js{"ext_media_availability", "status"}:
    if status.getStr.len > 0 and status.getStr.toLowerAscii != "available":
      result.available = false

  with title, js{"additional_media_info", "title"}:
    result.title = title.getStr

  with description, js{"additional_media_info", "description"}:
    result.description = description.getStr

  result.variants = parseVideoVariants(js{"video_info", "variants"})

proc parseLegacyMediaEntities(js: JsonNode; result: var Tweet) =
  with jsMedia, js{"extended_entities", "media"}:
    for m in jsMedia:
      case m.getTypeName:
      of "photo":
        result.photos.add Photo(
          url: m{"media_url_https"}.getImageStr,
          altText: m{"ext_alt_text"}.getStr
        )
      of "video":
        result.video = some(parseVideo(m))
        with user, m{"additional_media_info", "source_user"}:
          if user{"id"}.getInt > 0:
            result.attribution = some(parseUser(user))
          else:
            result.attribution = some(parseGraphUser(user))
      of "animated_gif":
        result.gif = some Gif(
          url: m{"video_info", "variants"}[0]{"url"}.getImageStr,
          thumb: m{"media_url_https"}.getImageStr
        )
      else: discard

      with url, m{"url"}:
        if result.text.endsWith(url.getStr):
          result.text.removeSuffix(url.getStr)
          result.text = result.text.strip()

proc parseMediaEntities(js: JsonNode; result: var Tweet) =
  with mediaEntities, js{"media_entities"}:
    for mediaEntity in mediaEntities:
      with mediaInfo, mediaEntity{"media_results", "result", "media_info"}:
        case mediaInfo.getTypeName
        of "ApiImage":
          result.photos.add Photo(
            url: mediaInfo{"original_img_url"}.getImageStr,
            altText: mediaInfo{"alt_text"}.getStr
          )
        of "ApiVideo":
          let status = mediaEntity{"media_results", "result", "media_availability_v2", "status"}
          result.video = some Video(
            available: status.getStr == "Available",
            thumb: mediaInfo{"preview_image", "original_img_url"}.getImageStr,
            durationMs: mediaInfo{"duration_millis"}.getInt,
            variants: parseVideoVariants(mediaInfo{"variants"})
          )
        of "ApiGif":
          result.gif = some Gif(
            url: mediaInfo{"variants"}[0]{"url"}.getImageStr,
            thumb: mediaInfo{"preview_image", "original_img_url"}.getImageStr
          )
        else: discard

  # Remove media URLs from text
  with mediaList, js{"legacy", "entities", "media"}:
    for url in mediaList:
      let expandedUrl = url.getExpandedUrl
      if result.text.endsWith(expandedUrl):
        result.text.removeSuffix(expandedUrl)
        result.text = result.text.strip()

proc parsePromoVideo(js: JsonNode): Video =
  result = Video(
    thumb: js{"player_image_large"}.getImageVal,
    available: true,
    durationMs: js{"content_duration_seconds"}.getStrVal("0").parseInt * 1000,
    playbackType: vmap
  )

  var variant = VideoVariant(
    contentType: vmap,
    url: js{"player_hls_url"}.getStrVal(js{"player_stream_url"}.getStrVal(
        js{"amplify_url_vmap"}.getStrVal()))
  )

  if "m3u8" in variant.url:
    variant.contentType = m3u8
    result.playbackType = m3u8

  result.variants.add variant

proc parseBroadcast(js: JsonNode): Card =
  let image = js{"broadcast_thumbnail_large"}.getImageVal
  result = Card(
    kind: broadcast,
    url: js{"broadcast_url"}.getStrVal,
    title: js{"broadcaster_display_name"}.getStrVal,
    text: js{"broadcast_title"}.getStrVal,
    image: image,
    video: some Video(thumb: image)
  )

proc addArticlePhoto(article: var Article; photo: Photo) =
  if photo.url.len == 0:
    return

  for existing in article.photos:
    if existing.url == photo.url:
      return

  article.photos.add photo

proc parseArticlePhoto(js: JsonNode): Photo =
  if js.isNull:
    return

  result = Photo(
    url: js{"original_img_url"}.getImageStr,
    altText: js{"alt_text"}.getStr
  )

proc parseArticle(js: JsonNode): Article =
  if js.isNull:
    return

  result = Article(
    title: js{"title"}.getStr,
    body: ""
  )

  let cover = parseArticlePhoto(js{"cover_media", "media_info"})
  if cover.url.len > 0:
    result.cover = some(cover)

  var mediaById = initTable[string, Photo]()
  with mediaEntities, js{"media_entities"}:
    for mediaEntity in mediaEntities:
      let photo = parseArticlePhoto(mediaEntity{"media_info"})
      if photo.url.len == 0:
        continue
      let mediaId = mediaEntity{"media_id"}.getStr
      if mediaId.len > 0:
        mediaById[mediaId] = photo
      result.addArticlePhoto(photo)

  with state, js{"content_state", "blocks"}:
    var textBlocks: seq[string]
    var entityMap = initTable[string, JsonNode]()
    let rawEntityMap = js{"content_state", "entityMap"}
    case rawEntityMap.kind
    of JArray:
      for entry in rawEntityMap:
        var key = entry{"key"}.getStr
        if key.len == 0:
          key = $entry{"key"}.getInt
        let value = entry{"value"}
        if key.len > 0 and value.kind != JNull:
          entityMap[key] = value
    of JObject:
      for key, value in rawEntityMap.pairs:
        entityMap[key] = value
    else:
      discard

    for blk in state:
      let
        blockType = blk{"type"}.getStr
        text = blk{"text"}.getStr.strip

      if blockType == "atomic":
        let entityRanges = blk{"entityRanges"}
        if entityRanges.len == 0:
          continue

        var entityKey = ""
        for entityRange in entityRanges:
          let keyNode = entityRange.getOrDefault("key")
          case keyNode.kind
          of JString:
            entityKey = keyNode.getStr
          of JInt:
            entityKey = $keyNode.getInt
          else:
            discard
          break
        if entityKey.len == 0:
          continue

        if entityKey notin entityMap:
          continue
        let entity = entityMap[entityKey]
        case entity{"type"}.getStr
        of "MEDIA":
          for mediaItem in entity{"data", "mediaItems"}:
            let mediaId = mediaItem{"mediaId"}.getStr
            if mediaId.len == 0 or mediaId notin mediaById:
              continue
            let photo = mediaById[mediaId]
            result.addArticlePhoto(photo)
            result.blocks.add ArticleBlock(
              kind: image,
              photo: some(photo)
            )
        of "TWEET":
          let tweetId = entity{"data", "tweetId"}.getStr
          if tweetId.len > 0:
            result.blocks.add ArticleBlock(
              kind: tweetEmbed,
              tweetId: tweetId
            )
        else:
          discard
        continue

      if text.len == 0:
        continue

      case blockType
      of "ordered-list-item":
        result.blocks.add ArticleBlock(kind: orderedListItem, text: text)
      of "unordered-list-item":
        result.blocks.add ArticleBlock(kind: unorderedListItem, text: text)
      else:
        result.blocks.add ArticleBlock(kind: paragraph, text: text)

      textBlocks.add text

    if result.blocks.len > 0 and textBlocks.len > 0:
      result.body = textBlocks.join("\n\n")
      result.partial = false

  if result.body.len == 0:
    result.body = js{"plain_text"}.getStr
    if result.body.len > 0:
      result.partial = true
      if result.blocks.len == 0:
        result.blocks.add ArticleBlock(kind: paragraph, text: result.body)

  if result.body.len == 0:
    result.body = js{"preview_text"}.getStr
    if result.body.len > 0:
      result.partial = true
      if result.blocks.len == 0:
        result.blocks.add ArticleBlock(kind: paragraph, text: result.body)

proc parseCard(js: JsonNode; urls: JsonNode): Card =
  const imageTypes = ["summary_photo_image", "player_image", "promo_image",
                      "photo_image_full_size", "thumbnail_image", "thumbnail",
                      "event_thumbnail", "image"]
  let
    vals = ? js{"binding_values"}
    name = js{"name"}.getStr
    kind = parseEnum[CardKind](name[(name.find(":") + 1) ..< name.len], unknown)

  if kind == unified:
    return parseUnifiedCard(vals{"unified_card", "string_value"}.getStr)

  result = Card(
    kind: kind,
    url: vals.getCardUrl(kind),
    dest: vals.getCardDomain(kind),
    title: vals.getCardTitle(kind),
    text: vals{"description"}.getStrVal
  )

  if result.url.len == 0:
    result.url = js{"url"}.getStr

  case kind
  of promoVideo, promoVideoConvo, appPlayer, videoDirectMessage:
    result.video = some parsePromoVideo(vals)
    if kind == appPlayer:
      result.text = vals{"app_category"}.getStrVal(result.text)
  of broadcast:
    result = parseBroadcast(vals)
  of liveEvent:
    result.text = vals{"event_title"}.getStrVal
  of player:
    result.url = vals{"player_url"}.getStrVal
    if "youtube.com" in result.url:
      result.url = result.url.replace("/embed/", "/watch?v=")
  of audiospace, unknown:
    result.title = "This card type is not supported."
  else: discard

  for typ in imageTypes:
    with img, vals{typ & "_large"}:
      result.image = img.getImageVal
      break

  for u in ? urls:
    if u{"url"}.getStr == result.url:
      result.url = u.getExpandedUrl(result.url)
      break

  if kind in {videoDirectMessage, imageDirectMessage}:
    result.url.setLen 0

  if kind in {promoImageConvo, promoImageApp, imageDirectMessage} and
     result.url.len == 0 or result.url.startsWith("card://"):
    result.url = getPicUrl(result.image)

proc parseTweet(js: JsonNode; jsCard: JsonNode = newJNull();
                replyId: int64 = 0): Tweet =
  if js.isNull: return

  let time =
    if js{"created_at"}.notNull: js{"created_at"}.getTime
    else: js{"created_at_ms"}.getTimeFromMs

  result = Tweet(
    id: js{"id_str"}.getId,
    threadId: js{"conversation_id_str"}.getId,
    replyId: js{"in_reply_to_status_id_str"}.getId,
    text: js{"full_text"}.getStr,
    lang: js{"lang"}.getStr,
    time: time,
    hashtagCount: countTagEntities(js{"entities"}),
    hasThread: js{"self_thread"}.notNull,
    available: true,
    user: User(id: js{"user_id_str"}.getStr),
    stats: TweetStats(
      replies: js{"reply_count"}.getInt,
      retweets: js{"retweet_count"}.getInt,
      likes: js{"favorite_count"}.getInt,
      views: js{"views_count"}.getInt
    )
  )

  if result.replyId == 0:
    result.replyId = replyId

  # fix for pinned threads
  if result.hasThread and result.threadId == 0:
    result.threadId = js{"self_thread", "id_str"}.getId

  if "retweeted_status" in js:
    result.retweet = some Tweet()
  elif js{"is_quote_status"}.getBool:
    result.quote = some Tweet(id: js{"quoted_status_id_str"}.getId)

  # legacy
  with rt, js{"retweeted_status_id_str"}:
    result.retweet = some Tweet(id: rt.getId)
    return

  # graphql
  with rt, js{"retweeted_status_result", "result"}:
    # needed due to weird edgecase where the actual tweet data isn't included
    if "legacy" in rt:
      result.retweet = some parseGraphTweet(rt)
      return

  with reposts, js{"repostedStatusResults"}:
    with rt, reposts{"result"}:
      if "legacy" in rt:
        result.retweet = some parseGraphTweet(rt)
        return

  if jsCard.kind != JNull:
    let name = jsCard{"name"}.getStr
    if "poll" in name:
      if "image" in name:
        result.photos.add Photo(
          url: jsCard{"binding_values", "image_large"}.getImageVal
        )

      result.poll = some parsePoll(jsCard)
    elif name == "amplify":
      result.video = some parsePromoVideo(jsCard{"binding_values"})
    else:
      result.card = some parseCard(jsCard, js{"entities", "urls"})

  result.expandTweetEntities(js)
  parseLegacyMediaEntities(js, result)

  with jsWithheld, js{"withheld_in_countries"}:
    let withheldInCountries: seq[string] =
      if jsWithheld.kind != JArray: @[]
      else: jsWithheld.to(seq[string])

    # XX - Content is withheld in all countries
    # XY - Content is withheld due to a DMCA request.
    if js{"withheld_copyright"}.getBool or
       withheldInCountries.len > 0 and ("XX" in withheldInCountries or
                                        "XY" in withheldInCountries or
                                        "withheld" in result.text):
      result.text.removeSuffix(" Learn more.")
      result.available = false

proc parseGraphTweet(js: JsonNode): Tweet =
  if js.kind == JNull:
    return Tweet()

  case js.getTypeName:
  of "TweetUnavailable":
    return Tweet()
  of "TweetTombstone":
    with text, select(js{"tombstone", "richText"}, js{"tombstone", "text"}):
      return Tweet(text: text.getTombstone)
    return Tweet()
  of "TweetPreviewDisplay":
    return Tweet(text: "You're unable to view this Tweet because it's only available to the Subscribers of the account owner.")
  of "TweetWithVisibilityResults":
    return parseGraphTweet(js{"tweet"})
  else:
    discard

  if not js.hasKey("legacy"):
    return Tweet()

  var jsCard = select(js{"card"}, js{"tweet_card"}, js{"legacy", "tweet_card"})
  if jsCard.kind != JNull:
    let legacyCard = jsCard{"legacy"}
    if legacyCard.kind != JNull:
      let bindingArray = legacyCard{"binding_values"}
      if bindingArray.kind == JArray:
        var bindingObj: seq[(string, JsonNode)]
        for item in bindingArray:
          bindingObj.add((item{"key"}.getStr, item{"value"}))
        # Create a new card object with flattened structure
        jsCard = %*{
          "name": legacyCard{"name"},
          "url": legacyCard{"url"},
          "binding_values": %bindingObj
        }

  var replyId = 0
  with restId, js{"reply_to_results", "rest_id"}:
    replyId = restId.getId

  result = parseTweet(js{"legacy"}, jsCard, replyId)
  result.id = js{"rest_id"}.getId
  result.user = parseGraphUser(js{"core"})

  if result.reply.len == 0:
    with replyTo, js{"reply_to_user_results", "result", "core", "screen_name"}:
      result.reply = @[replyTo.getStr]

  with count, js{"views", "count"}:
    result.stats.views = count.getStr("0").parseInt

  with noteTweet, js{"note_tweet", "note_tweet_results", "result"}:
    result.expandNoteTweetEntities(noteTweet)
    result.hashtagCount = max(result.hashtagCount, countTagEntities(noteTweet{"entity_set"}))

  parseMediaEntities(js, result)

  with quoted, js{"quoted_status_result", "result"}:
    result.quote = some(parseGraphTweet(quoted))

  with quoted, js{"quotedPostResults"}:
    if "result" in quoted:
      result.quote = some(parseGraphTweet(quoted{"result"}))
    else:
      result.quote = some Tweet(id: js{"legacy", "quoted_status_id_str"}.getId)

  with articleResult, js{"article", "article_results", "result"}:
    var article = parseArticle(articleResult)
    article.url = result.articleUrl
    if article.title.len > 0 or article.body.len > 0:
      result.article = some(article)

  with ids, js{"edit_control", "edit_control_initial", "edit_tweet_ids"}:
    for id in ids:
      result.history.add parseBiggestInt(id.getStr)

  with birdwatch, js{"birdwatch_pivot"}:
    result.note = parseCommunityNote(birdwatch)

proc parseGraphThread(js: JsonNode): tuple[thread: Chain; self: bool] =
  for t in ? js{"content", "items"}:
    let entryId = t.getEntryId
    if "tweet-" in entryId and "promoted" notin entryId:
      let tweet = t.getTweetResult("item")
      if tweet.notNull:
        result.thread.content.add parseGraphTweet(tweet)

        let tweetDisplayType = select(
          t{"item", "content", "tweet_display_type"},
          t{"item", "itemContent", "tweetDisplayType"}
        )
        if tweetDisplayType.getStr == "SelfThread":
          result.self = true
      else:
        result.thread.content.add Tweet(id: entryId.getId)
    elif "cursor-showmore" in entryId:
      let cursor = t{"item", "content", "value"}
      result.thread.cursor = cursor.getStr
      result.thread.hasMore = true

proc parseGraphTweetResult*(js: JsonNode): Tweet =
  with tweet, js{"data", "tweet_result", "result"}:
    result = parseGraphTweet(tweet)

proc parseGraphConversation*(js: JsonNode; tweetId: string): Conversation =
  result = Conversation(replies: Result[Chain](beginning: true))

  let instructions = ? select(
    js{"data", "timelineResponse", "instructions"},
    js{"data", "timeline_response", "instructions"},
    js{"data", "threaded_conversation_with_injections_v2", "instructions"}
  )
  if instructions.len == 0:
    return

  for i in instructions:
    if i.getTypeName == "TimelineAddEntries":
      for e in i{"entries"}:
        let entryId = e.getEntryId
        if entryId.startsWith("tweet-"):
          let tweetResult = getTweetResult(e)
          if tweetResult.notNull:
            let tweet = parseGraphTweet(tweetResult)

            if not tweet.available:
              tweet.id = entryId.getId

            if entryId.endsWith(tweetId):
              result.tweet = tweet
            else:
              result.before.content.add tweet
          elif not entryId.endsWith(tweetId):
            result.before.content.add Tweet(id: entryId.getId)
        elif entryId.startsWith("conversationthread"):
          let (thread, self) = parseGraphThread(e)
          if self:
            result.after = thread
          elif thread.content.len > 0:
            result.replies.content.add thread
        elif entryId.startsWith("tombstone"):
          let
            content = select(e{"content", "content"}, e{"content", "itemContent"})
            tweet = Tweet(
              id: entryId.getId,
              available: false,
              text: content{"tombstoneInfo", "richText"}.getTombstone
            )

          if $tweet.id == tweetId:
            result.tweet = tweet
          else:
            result.before.content.add tweet
        elif entryId.startsWith("cursor-bottom"):
          var cursorValue = select(
            e{"content", "value"},
            e{"content", "content", "value"},
            e{"content", "itemContent", "value"}
          )
          result.replies.bottom = cursorValue.getStr

proc parseGraphEditHistory*(js: JsonNode; tweetId: string): EditHistory =
  let instructions = ? js{
    "data", "tweet_result_by_rest_id", "result", 
    "edit_history_timeline", "timeline", "instructions"
  }
  if instructions.len == 0:
    return

  for i in instructions:
    if i.getTypeName == "TimelineAddEntries":
      for e in i{"entries"}:
        let entryId = e.getEntryId
        if entryId == "latestTweet":
          with item, e{"content", "items"}[0]:
            let tweetResult = item.getTweetResult("item")
            if tweetResult.notNull:
              result.latest = parseGraphTweet(tweetResult)
        elif entryId == "staleTweets":
          for item in e{"content", "items"}:
            let tweetResult = item.getTweetResult("item")
            if tweetResult.notNull:
              result.history.add parseGraphTweet(tweetResult)

proc extractTweetsFromEntry*(e: JsonNode): seq[Tweet] =
  with tweetResult, getTweetResult(e):
    var tweet = parseGraphTweet(tweetResult)
    if not tweet.available:
      tweet.id = e.getEntryId.getId
    result.add tweet
    return

  for item in e{"content", "items"}:
    with tweetResult, item.getTweetResult("item"):
      var tweet = parseGraphTweet(tweetResult)
      if not tweet.available:
        tweet.id = item.getEntryId.getId
      result.add tweet

proc addUniqueSearchTweet(result: var Result[Tweets]; tweet: Tweet) =
  if tweet.id != 0:
    for thread in result.content:
      for existing in thread:
        if existing.id == tweet.id:
          return
  result.content.add tweet

proc parseGraphTimeline*(js: JsonNode; after=""): Profile =
  result = Profile(tweets: Timeline(beginning: after.len == 0))

  let instructions = ? select(
    js{"data", "list", "tweets_timeline", "timeline", "instructions"},
    select(
      js{"data", "user", "result", "timeline_v2", "timeline", "instructions"},
      js{"data", "user_result", "result", "timeline_v2", "timeline", "instructions"},
      select(
        js{"data", "list", "timeline_response", "timeline", "instructions"},
        js{"data", "user", "result", "timeline", "timeline", "instructions"},
        js{"data", "user_result", "result", "timeline_response", "timeline", "instructions"}
      )
    )
  )
  if instructions.len == 0:
    return

  for i in instructions:
    if i{"moduleItems"}.notNull:
      for item in i{"moduleItems"}:
        with tweetResult, item.getTweetResult("item"):
          let tweet = parseGraphTweet(tweetResult)
          if not tweet.available:
            tweet.id = item.getEntryId.getId
          result.tweets.content.add tweet
      continue

    if i{"entries"}.notNull:
      for e in i{"entries"}:
        let entryId = e.getEntryId
        if entryId.startsWith("tweet") or entryId.startsWith("profile-grid"):
          for tweet in extractTweetsFromEntry(e):
            result.tweets.content.add tweet
        elif "-conversation-" in entryId or entryId.startsWith("homeConversation"):
          let (thread, self) = parseGraphThread(e)
          result.tweets.content.add thread.content
        elif entryId.startsWith("cursor-bottom"):
          result.tweets.bottom = e{"content", "value"}.getStr

    if after.len == 0:
      if i.getTypeName == "TimelinePinEntry":
        let tweets = extractTweetsFromEntry(i{"entry"})
        if tweets.len > 0:
          var tweet = tweets[0]
          tweet.pinned = true
          result.pinned = some tweet

proc parseGraphPhotoRail*(js: JsonNode): PhotoRail =
  result = @[]

  let instructions = select(
    js{"data", "user", "result", "timeline", "timeline", "instructions"},
    js{"data", "user_result", "result", "timeline_response", "timeline", "instructions"}
  )
  if instructions.len == 0:
    return

  for i in instructions:
    if i{"moduleItems"}.notNull:
      for item in i{"moduleItems"}:
        with tweetResult, item.getTweetResult("item"):
          let t = parseGraphTweet(tweetResult)
          if not t.available:
            t.id = item.getEntryId.getId

          let photo = extractGalleryPhoto(t)
          if photo.url.len > 0:
            result.add photo

          if result.len == 16:
            return
      continue

    if i.getTypeName != "TimelineAddEntries":
      continue

    for e in i{"entries"}:
      let entryId = e.getEntryId
      if entryId.startsWith("tweet") or entryId.startsWith("profile-grid"):
        for t in extractTweetsFromEntry(e):
          let photo = extractGalleryPhoto(t)
          if photo.url.len > 0:
            result.add photo

          if result.len == 16:
            return

proc parseGraphSearch*[T: User | Tweets](js: JsonNode; after=""): Result[T] =
  result = Result[T](beginning: after.len == 0)

  let instructions = select(
    js{"data", "search", "timeline_response", "timeline", "instructions"},
    js{"data", "search_by_raw_query", "search_timeline", "timeline", "instructions"},
    js{"data", "search", "timeline", "instructions"}
  )
  if instructions.len == 0:
    return

  for instruction in instructions:
    let typ = getTypeName(instruction)
    if typ == "TimelineAddEntries":
      for e in instruction{"entries"}:
        let entryId = e.getEntryId
        when T is Tweets:
          if "promoted" notin entryId.toLowerAscii:
            for tweet in extractTweetsFromEntry(e):
              result.addUniqueSearchTweet(tweet)
        elif T is User:
          if entryId.startsWith("user"):
            with userRes, e{"content", "itemContent"}:
              result.content.add parseGraphUser(userRes)

        if entryId.startsWith("cursor-bottom"):
          result.bottom = e{"content", "value"}.getStr
    elif typ == "TimelineReplaceEntry":
      if instruction{"entry_id_to_replace"}.getStr.startsWith("cursor-bottom"):
        result.bottom = instruction{"entry", "content", "value"}.getStr

proc parseGraphAffiliates*(js: JsonNode; after=""): Result[User] =
  result = Result[User](
    beginning: after.len == 0,
    query: Query(kind: affiliates)
  )

  let instructions = select(
    js{"data", "user", "result", "timeline", "timeline", "instructions"},
    js{"data", "user_result", "result", "timeline", "timeline", "instructions"}
  )
  if instructions.len == 0:
    return

  for instruction in instructions:
    let typ = getTypeName(instruction)
    if typ == "TimelineAddEntries":
      for entry in instruction{"entries"}:
        let entryId = entry.getEntryId
        if entryId.startsWith("user-"):
          let userRes = entry{"content", "itemContent", "user_results", "result"}
          if userRes.notNull:
            result.content.add parseGraphUser(userRes)
        elif entryId.startsWith("cursor-bottom"):
          result.bottom = entry{"content", "value"}.getStr
    elif typ == "TimelineReplaceEntry":
      if instruction{"entry_id_to_replace"}.getStr.startsWith("cursor-bottom"):
        result.bottom = instruction{"entry", "content", "value"}.getStr

proc parseGraphListTimeline*(js: JsonNode; after=""): Result[List] =
  result = Result[List](
    beginning: after.len == 0,
    query: Query(kind: lists)
  )

  var instructions = js{"data", "viewer", "list_management_page", "list_management_timeline", "timeline", "instructions"}
  if instructions.isNull:
    instructions = js{"data", "user", "result", "timeline", "timeline", "instructions"}
  if instructions.isNull:
    instructions = js{"data", "viewer", "list_management_timeline", "timeline", "instructions"}
  if instructions.isNull:
    instructions = js{"data", "user", "result", "list_ownerships_timeline", "timeline", "instructions"}
  if instructions.isNull:
    instructions = js{"data", "user", "result", "list_memberships_timeline", "timeline", "instructions"}
  if instructions.len == 0:
    return

  for instruction in instructions:
    let typ = getTypeName(instruction)
    if typ == "TimelineAddEntries":
      for entry in instruction{"entries"}:
        let entryId = entry.getEntryId
        var item = entry{"content", "itemContent"}
        if item.isNull:
          let items = entry{"content", "items"}
          if items.len > 0:
            item = items[0]{"item", "itemContent"}
        if item{"itemType"}.getStr == "TimelineTwitterList":
          let list = parseTimelineList(item{"list"})
          if list.id.len > 0:
            result.content.add list
        elif entryId.startsWith("cursor-bottom"):
          result.bottom = entry{"content", "value"}.getStr
    elif typ == "TimelineReplaceEntry":
      if instruction{"entry_id_to_replace"}.getStr.startsWith("cursor-bottom"):
        result.bottom = instruction{"entry", "content", "value"}.getStr
