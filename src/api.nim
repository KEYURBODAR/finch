# SPDX-License-Identifier: AGPL-3.0-only
import asyncdispatch, httpclient, strutils, sequtils, sugar
from std/json import JNull
import packedjson
import types, query, formatters, consts, apiutils, parser
import experimental/parser as newParser

proc mergeUserData(primary, secondary: User): User =
  result = primary

  if result.id.len == 0: result.id = secondary.id
  if result.username.len == 0: result.username = secondary.username
  if result.fullname.len == 0 or result.fullname == result.username:
    result.fullname = secondary.fullname
  if result.location.len == 0: result.location = secondary.location
  if result.website.len == 0: result.website = secondary.website
  if result.bio.len == 0: result.bio = secondary.bio
  if result.userPic.len == 0: result.userPic = secondary.userPic
  if result.banner.len == 0: result.banner = secondary.banner
  if result.pinnedTweet == 0: result.pinnedTweet = secondary.pinnedTweet

  result.following = max(result.following, secondary.following)
  result.followers = max(result.followers, secondary.followers)
  result.tweets = max(result.tweets, secondary.tweets)
  result.likes = max(result.likes, secondary.likes)
  result.media = max(result.media, secondary.media)

  if result.verifiedType == none:
    result.verifiedType = secondary.verifiedType
  if result.affiliateBadgeName.len == 0:
    result.affiliateBadgeName = secondary.affiliateBadgeName
  if result.affiliateBadgeUrl.len == 0:
    result.affiliateBadgeUrl = secondary.affiliateBadgeUrl
  if result.affiliateBadgeTarget.len == 0:
    result.affiliateBadgeTarget = secondary.affiliateBadgeTarget
  result.affiliatesCount = max(result.affiliatesCount, secondary.affiliatesCount)

  result.protected = result.protected or secondary.protected
  result.suspended = result.suspended or secondary.suspended

proc isIncompleteUser(user: User): bool =
  user.id.len > 0 and user.following == 0 and user.followers == 0 and
  user.tweets == 0 and user.likes == 0 and user.media == 0

proc getGraphUserById*(id: string): Future[User] {.async.}

# Helper to generate params object for GraphQL requests
proc genParams(variables: string; fieldToggles = ""): seq[(string, string)] =
  result.add ("variables", variables)
  result.add ("features", gqlFeatures)
  if fieldToggles.len > 0:
    result.add ("fieldToggles", fieldToggles)

proc apiUrl(endpoint, variables: string; fieldToggles = ""): ApiUrl =
  return ApiUrl(endpoint: endpoint, params: genParams(variables, fieldToggles))

proc apiReq(endpoint, variables: string; fieldToggles = ""): ApiReq =
  let url = apiUrl(endpoint, variables, fieldToggles)
  return ApiReq(cookie: url, oauth: url)

proc userTimelineVars(userId: string; cursor: string; includePromotedContent=false): string =
  var variables = %*{
    "userId": userId,
    "count": 20,
    "includePromotedContent": includePromotedContent,
    "withVoice": true
  }
  if cursor.len > 0:
    variables["cursor"] = %cursor
  $variables

proc userListsVars(userId: string; cursor: string): string =
  var variables = %*{
    "userId": userId,
    "count": 20,
    "isListMemberTargetUserId": false
  }
  if cursor.len > 0:
    variables["cursor"] = %cursor
  $variables

proc mediaUrl(id: string; cursor: string): ApiReq =
  result = ApiReq(
    cookie: apiUrl(graphUserMedia, userMediaVars % [id, cursor]),
    oauth: apiUrl(graphUserMediaV2, restIdVars % [id, cursor])
  )

proc userTweetsVarsJson(userId: string; cursor: string; count=20; includePromotedContent=false): string =
  var variables = %*{
    "userId": userId,
    "count": count,
    "includePromotedContent": includePromotedContent,
    "withQuickPromoteEligibilityTweetFields": true,
    "withVoice": true,
    "withV2Timeline": true
  }
  if cursor.len > 0:
    variables["cursor"] = %cursor
  $variables

proc userTweetsUrl(id: string; cursor: string; count=20): ApiReq =
  let
    classic = apiUrl(graphUserTweets, userTweetsVarsJson(id, cursor, count), userTweetsFieldToggles)
    v2 = apiUrl(graphUserTweetsV2, restIdVars % [id, cursor])
  result = ApiReq(cookie: classic, oauth: v2)

proc userTweetsAndRepliesUrl(id: string; cursor: string): ApiReq =
  let cookieVars = userTweetsAndRepliesVars % [id, cursor]
  result = ApiReq(
    cookie: apiUrl(graphUserTweetsAndReplies, cookieVars, userTweetsFieldToggles),
    oauth: apiUrl(graphUserTweetsAndRepliesV2, restIdVars % [id, cursor])
  )

proc userArticlesUrl(id: string; cursor: string): ApiReq =
  apiReq(graphUserArticles, userTimelineVars(id, cursor))

proc userHighlightsUrl(id: string; cursor: string): ApiReq =
  apiReq(graphUserHighlights, userTimelineVars(id, cursor))

proc userListsUrl(id: string; cursor: string): ApiReq =
  apiReq(graphCombinedLists, userListsVars(id, cursor))

proc userAffiliatesVars(userId: string; cursor: string): string =
  var variables = %*{
    "userId": userId,
    "count": 40,
    "teamName": "NotAssigned",
    "includePromotedContent": false,
    "withClientEventToken": false,
    "withVoice": true
  }
  if cursor.len > 0:
    variables["cursor"] = %cursor
  $variables

proc userAffiliatesUrl(id: string; cursor: string): ApiReq =
  apiReq(graphUserAffiliates, userAffiliatesVars(id, cursor))

proc tweetDetailUrl(id: string; cursor: string): ApiReq =
  let cookieVars = tweetDetailVars % [id, cursor]
  result = ApiReq(
    cookie: apiUrl(graphTweetDetail, cookieVars, tweetDetailFieldToggles),
    oauth: apiUrl(graphTweet, tweetVars % [id, cursor])
  )

proc userUrl(username: string): ApiReq =
  let cookieVars = """{"screen_name":"$1","withGrokTranslatedBio":false,"withHighlightedLabel":true}""" % username
  result = ApiReq(
    cookie: apiUrl(graphUser, cookieVars, userFieldToggles),
    oauth: apiUrl(graphUserV2, """{"screen_name": "$1","withHighlightedLabel":true}""" % username, userFieldToggles)
  )

proc getGraphUser*(username: string): Future[User] {.async.} =
  if username.len == 0: return
  let js = await fetchRaw(userUrl(username))
  result = parseGraphUser(js)
  if isIncompleteUser(result):
    let richer = await getGraphUserById(result.id)
    if richer.id.len > 0:
      result = mergeUserData(result, richer)

proc getGraphUserById*(id: string): Future[User] {.async.} =
  if id.len == 0 or id.any(c => not c.isDigit): return
  let
    url = apiReq(graphUserById, """{"rest_id": "$1"}""" % id)
    js = await fetchRaw(url)
  result = parseGraphUser(js)

proc getGraphUserTweets*(id: string; kind: TimelineKind; after=""; count=20): Future[Profile] {.async.} =
  if id.len == 0: return
  let
    cursor = if after.len > 0: "\"cursor\":\"$1\"," % after else: ""
    url = case kind
      of TimelineKind.tweets: userTweetsUrl(id, after, count)
      of TimelineKind.replies: userTweetsAndRepliesUrl(id, cursor)
      of TimelineKind.media: mediaUrl(id, cursor)
    js = await fetch(url)
  if js.kind == JNull:
    return Profile(tweets: Timeline(beginning: after.len == 0, errorText: "This surface could not be refreshed right now."))
  result = parseGraphTimeline(js, after)

proc getGraphUserArticles*(id: string; after=""): Future[Profile] {.async.} =
  if id.len == 0: return
  let
    js = await fetch(userArticlesUrl(id, after))
  if js.kind == JNull:
    return Profile(tweets: Timeline(beginning: after.len == 0, errorText: "Articles could not be refreshed right now."))
  result = parseGraphTimeline(js, after)

proc getGraphUserHighlights*(id: string; after=""): Future[Profile] {.async.} =
  if id.len == 0: return
  let
    js = await fetch(userHighlightsUrl(id, after))
  if js.kind == JNull:
    return Profile(tweets: Timeline(beginning: after.len == 0, errorText: "Highlights could not be refreshed right now."))
  result = parseGraphTimeline(js, after)

proc getGraphUserLists*(id: string; after=""): Future[Result[List]] {.async.} =
  if id.len == 0: return
  let
    js = await fetch(userListsUrl(id, after))
  result = parseGraphListTimeline(js, after)

proc getGraphUserAffiliates*(id: string; after=""): Future[Result[User]] {.async.} =
  if id.len == 0: return
  let
    js = await fetch(userAffiliatesUrl(id, after))
  if js.kind == JNull:
    return Result[User](beginning: after.len == 0, errorText: "Affiliate roster could not be refreshed right now.")
  result = parseGraphAffiliates(js, after)

proc getGraphListTweets*(id: string; after=""): Future[Timeline] {.async.} =
  if id.len == 0: return
  let
    cursor = if after.len > 0: "\"cursor\":\"$1\"," % after else: ""
    url = apiReq(graphListTweets, listTimelineVars % [id, cursor])
    js = await fetch(url)
  result = parseGraphTimeline(js, after).tweets

proc getGraphListBySlug*(name, list: string): Future[List] {.async.} =
  let
    variables = %*{"screenName": name, "listSlug": list}
    url = apiReq(graphListBySlug, $variables)
    js = await fetch(url)
  result = parseGraphList(js)

proc getGraphList*(id: string): Future[List] {.async.} =
  let 
    url = apiReq(graphListById, """{"listId": "$1"}""" % id)
    js = await fetch(url)
  result = parseGraphList(js)


proc getGraphListMembers*(list: List; after=""): Future[Result[User]] {.async.} =
  if list.id.len == 0: return
  var
    variables = %*{
      "listId": list.id,
      "withBirdwatchPivots": false,
      "withDownvotePerspective": false,
      "withReactionsMetadata": false,
      "withReactionsPerspective": false
    }
  if after.len > 0:
    variables["cursor"] = % after
  let 
    url = apiReq(graphListMembers, $variables)
    js = await fetchRaw(url)
  result = parseGraphListMembers(js, after)

proc getGraphTweetResult*(id: string): Future[Tweet] {.async.} =
  if id.len == 0: return
  let
    url = apiReq(graphTweetResult, """{"rest_id": "$1"}""" % id)
    js = await fetch(url)
  result = parseGraphTweetResult(js)

proc getGraphTweet(id: string; after=""): Future[Conversation] {.async.} =
  if id.len == 0: return
  let
    cursor = if after.len > 0: "\"cursor\":\"$1\"," % after else: ""
    js = await fetch(tweetDetailUrl(id, cursor))
  result = parseGraphConversation(js, id)

proc getReplies*(id, after: string): Future[Result[Chain]] {.async.} =
  result = (await getGraphTweet(id, after)).replies
  result.beginning = after.len == 0

proc getTweet*(id: string; after=""): Future[Conversation] {.async.} =
  result = await getGraphTweet(id)
  if after.len > 0:
    result.replies = await getReplies(id, after)

proc getGraphEditHistory*(id: string): Future[EditHistory] {.async.} =
  if id.len == 0: return
  let
    url = apiReq(graphTweetEditHistory, tweetEditHistoryVars % id)
    js = await fetch(url)
  result = parseGraphEditHistory(js, id)

proc getGraphTweetSearch*(query: Query; after=""): Future[Timeline] {.async.} =
  let q = genQueryParam(query)
  if q.len == 0 or q == emptyQuery:
    return Timeline(query: query, beginning: true)

  var
    variables = %*{
      "rawQuery": q,
      "query_source": "typedQuery",
      "count": 20,
      "product": (if query.sort == top: "Top" else: "Latest"),
      "withDownvotePerspective": false,
      "withReactionsMetadata": false,
      "withReactionsPerspective": false
    }
  if after.len > 0:
    variables["cursor"] = % after
  let 
    url = apiReq(graphSearchTimeline, $variables)
    js = await fetch(url)
  if js.kind == JNull:
    echo "[search] Tweet search returned JNull for query: ", q
    return Timeline(query: query, beginning: after.len == 0,
      errorText: "Search couldn't complete. Try again in a moment.")
  result = parseGraphSearch[Tweets](js, after)
  result.query = query

  # when no more items are available the API just returns the last page in
  # full. this detects that and clears the page instead.
  if after.len > 0 and result.bottom.len > 0 and 
     after[0..<64] == result.bottom[0..<64]:
    result.content.setLen(0)
    result.bottom.setLen(0)

proc getGraphUserSearch*(query: Query; after=""): Future[Result[User]] {.async.} =
  if query.text.len == 0:
    return Result[User](query: query, beginning: true)

  let rawQuery =
    if query.text.len > 0 and query.text[0] == '@':
      query.text[1 .. ^1].strip()
    else:
      query.text.strip()

  var
    variables = %*{
      "rawQuery": rawQuery,
      "query_source": "typedQuery",
      "count": 20,
      "product": "People",
      "withDownvotePerspective": false,
      "withReactionsMetadata": false,
      "withReactionsPerspective": false
    }
  if after.len > 0:
    variables["cursor"] = % after
    result.beginning = false

  let 
    url = apiReq(graphSearchTimeline, $variables)
    js = await fetch(url)
  if js.kind == JNull:
    echo "[search] User search returned JNull for query: ", rawQuery
    result = Result[User](query: query, beginning: after.len == 0,
      errorText: "Search couldn't complete. Try again in a moment.")
    return
  result = parseGraphSearch[User](js, after)
  result.query = query

proc getPhotoRail*(id: string): Future[PhotoRail] {.async.} =
  if id.len == 0: return
  let js = await fetch(mediaUrl(id, ""))
  result = parseGraphPhotoRail(js)

proc resolve*(url: string; prefs: Prefs): Future[string] {.async.} =
  let client = newAsyncHttpClient(maxRedirects=0)
  try:
    let resp = await client.request(url, HttpHead)
    result = resp.headers["location"].replaceUrls(prefs)
  except CatchableError:
    discard
  finally:
    client.close()
