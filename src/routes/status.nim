# SPDX-License-Identifier: AGPL-3.0-only
import asyncdispatch, strutils, sequtils, uri, options, sugar, json, times

import jester, karax/vdom

import router_utils
import ".."/[types, formatters, api, redis_cache]
from ../articles import getArticle, getArticleUrl, hydrateArticle, hydrateConversationArticles
import ../exporters
import ../views/[general, status]
from ../views/article import renderArticlePanel

export uri, sequtils, options, sugar
export router_utils
export api, formatters
export exporters
export status

proc resolveTweetArticle*(tweet: Tweet): Article

proc searchTweetForArticleId(id: string): Future[Tweet] {.async.} =
  if id.len == 0:
    return

  for raw in [
    "x.com/i/article/" & id,
    "twitter.com/i/article/" & id,
    "\"x.com/i/article/" & id & "\""
  ]:
    let query = Query(kind: tweets, text: raw, sort: latest, scope: scopeAll, sep: "OR")
    let timeline = await getGraphTweetSearch(query)
    for thread in timeline.content:
      for tweet in thread:
        if tweet.isNil:
          continue
        let article = resolveTweetArticle(tweet)
        if article.url.len > 0 and articleIdFromUrl(article.url) == id:
          return tweet
        if article.url.len == 0 and getArticleUrl(tweet).len > 0 and articleIdFromUrl(getArticleUrl(tweet)) == id:
          return tweet

proc ensureConversationArticles*(conv: Conversation): Future[void] {.async.} =
  await hydrateConversationArticles(conv)

proc ensureTweetArticle*(tweet: Tweet): Future[void] {.async.} =
  await hydrateArticle(tweet)

proc articleEnvelope*(tweet: Tweet; cfg: Config): JsonNode =
  var article = tweet.article.get
  if article.url.len == 0:
    article.url = getArticleUrl(tweet)
  result = newJObject()
  result["schema"] = % exportSchemaVersion
  result["kind"] = % "article"
  result["tweet_id"] = % $tweet.id
  result["tweet_url"] = % (getUrlPrefix(cfg) & getLink(tweet, focus=false))
  result["partial"] = % article.partial
  result["article"] = articleToJson(article)
  if article.partial:
    result["warning"] = % "preview_only"

proc articlePanel*(article: Article; basePath: string): VNode =
  renderArticlePanel(article, [
    ("HTML", basePath),
    ("JSON", basePath & "/json"),
    ("MD", basePath & "/md"),
    ("TXT", basePath & "/txt")
  ])

proc articleWithUrl*(tweet: Tweet): Article =
  result = tweet.article.get
  if result.url.len == 0:
    result.url = getArticleUrl(tweet)

proc textLooksLikeStandaloneArticleToken(value: string): bool =
  let stripped = value.strip.toLowerAscii()
  if stripped.len == 0:
    return true
  if stripped.startsWith("x.com/i/article/") or
     stripped.startsWith("twitter.com/i/article/") or
     stripped.startsWith("/i/article/"):
    return true
  if (stripped.startsWith("https://t.co/") or
      stripped.startsWith("http://t.co/") or
      stripped.startsWith("t.co/")) and
      ' ' notin stripped and '\n' notin stripped and '\t' notin stripped:
    return true
  false

proc fallbackArticleForTweet(tweet: Tweet): Article =
  let articleUrl = getArticleUrl(tweet)
  if articleUrl.len == 0:
    return

  result = Article(url: articleUrl, partial: true)
  if tweet.card.isSome:
    let card = tweet.card.get
    result.title = card.title.strip
    result.body = card.text.strip
    if card.image.len > 0:
      result.cover = some(Photo(url: card.image))

  if result.body.len == 0 and not textLooksLikeStandaloneArticleToken(tweet.text):
    result.body = tweet.text.strip

proc resolveTweetArticle*(tweet: Tweet): Article =
  if tweet.isNil:
    return
  if tweet.article.isSome:
    result = articleWithUrl(tweet)
  else:
    result = fallbackArticleForTweet(tweet)

proc hasFullArticle(tweet: Tweet): bool =
  if tweet.isNil or tweet.article.isNone:
    return false
  let article = tweet.article.get
  (article.blocks.len > 0 or article.body.len > 0) and not article.partial

proc fetchTweetForArticle*(id: string): Future[Tweet] {.async.} =
  if id.len == 0:
    return

  let stored = await getStoredTweet(parseBiggestInt(id).int64)
  if stored.tweet != nil:
    let storedArticle = resolveTweetArticle(stored.tweet)
    if storedArticle.url.len > 0:
      let articleId = articleIdFromUrl(storedArticle.url)
      if articleId.len > 0:
        await cacheArticleTweetRef(articleId, stored.tweet.id, stored.tweet.user.username)
      if hasFullArticle(stored.tweet):
        return stored.tweet

  let conv = await getTweet(id, "")
  if conv == nil or conv.tweet == nil or conv.tweet.id == 0:
    if stored.tweet != nil:
      return stored.tweet
    return

  if not hasFullArticle(conv.tweet):
    await ensureTweetArticle(conv.tweet)
  await cacheConversation(conv)
  result = conv.tweet

proc fetchStandaloneArticle*(id: string): Future[Article] {.async.} =
  if id.len == 0:
    return
  let cachedRef = await getCachedArticleTweetRef(id)
  if cachedRef.isSome:
    let refData = cachedRef.get
    let tweet = await fetchTweetForArticle($refData.tweetId)
    if tweet != nil:
      let article = resolveTweetArticle(tweet)
      if article.url.len > 0:
        return article
  let found = await searchTweetForArticleId(id)
  if found != nil:
    await ensureTweetArticle(found)
    let article = resolveTweetArticle(found)
    if article.url.len > 0:
      let articleId = articleIdFromUrl(article.url)
      if articleId.len > 0:
        await cacheArticleTweetRef(articleId, found.id, found.user.username)
      await cacheTweetGraph(found)
      return article
  let articleUrl = "https://x.com/i/article/" & id
  result = await getArticle(articleUrl)

proc articleEnvelopeForArticle*(article: Article): JsonNode =
  result = newJObject()
  result["schema"] = % exportSchemaVersion
  result["kind"] = % "article"
  result["partial"] = % article.partial
  result["article"] = articleToJson(article)
  if article.partial:
    result["warning"] = % "preview_only"

proc safeIso(dt: DateTime): string =
  try:
    dt.utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
  except AssertionDefect:
    ""

proc liveStatusEnvelope*(cached: CachedTweet; live: Tweet; cfg: Config): JsonNode =
  var ctx = newJObject()
  ctx["schema"] = % exportSchemaVersion
  ctx["kind"] = % "status_live"
  ctx["tweet_id"] = % $live.id
  ctx["checked_at_iso"] = % safeIso(now().utc)
  ctx["url"] = % (getUrlPrefix(cfg) & getLink(live, focus=false))
  ctx["cache"] = %*{
    "hit": cached.tweet != nil and cached.tweet.id != 0,
    "cached_at_iso": safeIso(cached.cachedAt)
  }

  if cached.tweet != nil and cached.tweet.id != 0:
    ctx["cached"] = compactStatusTweetToJson(cached.tweet, cfg)
  ctx["live"] = compactStatusTweetToJson(live, cfg)

  if cached.tweet != nil and cached.tweet.id != 0:
    ctx["stats_delta"] = %*{
      "replies": live.stats.replies - cached.tweet.stats.replies,
      "retweets": live.stats.retweets - cached.tweet.stats.retweets,
      "likes": live.stats.likes - cached.tweet.stats.likes,
      "views": live.stats.views - cached.tweet.stats.views
    }
  ctx

proc createStatusRouter*(cfg: Config) =
  router status:
    get "/i/article/@id/@fmt/?":
      cond @"fmt" in ["json", "md", "txt"]
      let id = @"id"

      if id.len == 0 or id.any(c => not c.isDigit):
        resp Http404, showError("Invalid article ID", cfg)

      let article = await fetchStandaloneArticle(id)
      if article.url.len == 0 or (article.title.len == 0 and article.body.len == 0):
        resp Http404, showError("Article not found", cfg)

      case @"fmt"
      of "json":
        respJson articleEnvelopeForArticle(article)
      of "md":
        resp "# Article\n\n" &
          (if article.partial: "> Preview only. Full article body is not currently available from upstream.\n\n" else: "") &
          (if article.title.len > 0: "## " & article.title & "\n\n" else: "") &
          (if article.url.len > 0: article.url & "\n\n" else: "") &
          articleMarkdownBody(article).strip & "\n",
          "text/markdown; charset=utf-8"
      of "txt":
        resp ("ARTICLE\n\n" &
          (if article.partial: "status: preview_only\nwarning: full article body unavailable from upstream\n" else: "") &
          (if article.title.len > 0: "title: " & article.title & "\n" else: "") &
          (if article.url.len > 0: "url: " & article.url & "\n" else: "") &
          (if articleTextBody(article).len > 0: "\n" & articleTextBody(article).join("\n") & "\n" else: "\n")),
          "text/plain; charset=utf-8"
      else:
        resp Http404

    get "/i/article/@id/?":
      let id = @"id"

      if id.len == 0 or id.any(c => not c.isDigit):
        resp Http404, showError("Invalid article ID", cfg)

      let article = await fetchStandaloneArticle(id)
      if article.url.len == 0 or (article.title.len == 0 and article.body.len == 0):
        resp Http404, showError("Article not found", cfg)

      let
        basePath = "/i/article/" & id
        html = articlePanel(article, basePath)
      resp renderMain(html, request, cfg, requestPrefs(),
                      titleText=article.title,
                      desc=article.body)

    get "/@name/status/@id/@fmt/?":
      condValidUsername(@"name")
      cond @"fmt" in ["json", "md", "txt"]
      let id = @"id"

      if id.len > 19 or id.any(c => not c.isDigit):
        resp Http404, showError("Invalid tweet ID", cfg)

      let conv = await getTweet(id, getCursor())

      if conv == nil or conv.tweet == nil or conv.tweet.id == 0:
        var error = "Tweet not found"
        if conv != nil and conv.tweet != nil and conv.tweet.tombstone.len > 0:
          error = conv.tweet.tombstone
        resp Http404, showError(error, cfg)

      await ensureConversationArticles(conv)
      await cacheConversation(conv)

      case @"fmt"
      of "json":
        respJson compactConversationToJson(conv, cfg)
      of "md":
        resp conversationToMarkdown(conv, cfg), "text/markdown; charset=utf-8"
      of "txt":
        resp conversationToText(conv, cfg), "text/plain; charset=utf-8"
      else:
        resp Http404

    get "/@name/status/@id/live/json":
      condValidUsername(@"name")
      let id = @"id"

      if id.len > 19 or id.any(c => not c.isDigit):
        resp Http404, showError("Invalid tweet ID", cfg)

      let cached = await getStoredTweet(parseBiggestInt(id).int64)
      let conv = await getTweet(id, "")
      if conv == nil or conv.tweet == nil or conv.tweet.id == 0:
        resp Http404, showError("Tweet not found", cfg)

      await ensureTweetArticle(conv.tweet)
      await cacheConversation(conv)
      respJson liveStatusEnvelope(cached, conv.tweet, cfg)

    get "/@name/status/@id/article/@fmt/?":
      condValidUsername(@"name")
      cond @"fmt" in ["json", "md", "txt"]
      let id = @"id"

      if id.len > 19 or id.any(c => not c.isDigit):
        resp Http404, showError("Invalid tweet ID", cfg)

      let tweet = await fetchTweetForArticle(id)
      if tweet == nil or tweet.id == 0:
        resp Http404, showError("Tweet not found", cfg)

      let article = resolveTweetArticle(tweet)
      if article.url.len == 0:
        resp Http404, showError("Article not found", cfg)
      case @"fmt"
      of "json":
        respJson articleEnvelopeForArticle(article)
      of "md":
        resp "# Article\n\n" &
          (if article.partial: "> Preview only. Full article body is not currently available from upstream.\n\n" else: "") &
          (if article.title.len > 0: "## " & article.title & "\n\n" else: "") &
          (if article.url.len > 0: article.url & "\n\n" else: "") &
          articleMarkdownBody(article).strip & "\n",
          "text/markdown; charset=utf-8"
      of "txt":
        resp ("ARTICLE\n\n" &
          (if article.partial: "status: preview_only\nwarning: full article body unavailable from upstream\n" else: "") &
          (if article.title.len > 0: "title: " & article.title & "\n" else: "") &
          (if article.url.len > 0: "url: " & article.url & "\n" else: "") &
          (if articleTextBody(article).len > 0: "\n" & articleTextBody(article).join("\n") & "\n" else: "\n")),
          "text/plain; charset=utf-8"
      else:
        resp Http404

    get "/@name/status/@id/article/?":
      condValidUsername(@"name")
      let id = @"id"

      if id.len > 19 or id.any(c => not c.isDigit):
        resp Http404, showError("Invalid tweet ID", cfg)

      let tweet = await fetchTweetForArticle(id)
      if tweet == nil or tweet.id == 0:
        resp Http404, showError("Tweet not found", cfg)

      let article = resolveTweetArticle(tweet)
      if article.url.len == 0:
        resp Http404, showError("Article not found", cfg)

      let
        basePath = getLink(tweet, focus=false) & "/article"
        html = articlePanel(article, basePath)
      resp renderMain(html, request, cfg, requestPrefs(),
                      titleText=article.title,
                      desc=article.body,
                      ogTitle=pageTitle(tweet.user))

    get "/@name/status/@id/?":
      condValidUsername(@"name")
      let id = @"id"

      if id.len > 19 or id.any(c => not c.isDigit):
        resp Http404, showError("Invalid tweet ID", cfg)

      let prefs = requestPrefs()

      # used for the infinite scroll feature
      if @"scroll".len > 0:
        let replies = await getReplies(id, getCursor())
        if replies.content.len == 0:
          resp Http204
        resp $renderReplies(replies, prefs, getPath())

      let conv = await getTweet(id, getCursor())

      if conv == nil or conv.tweet == nil or conv.tweet.id == 0:
        var error = "Tweet not found"
        if conv != nil and conv.tweet != nil and conv.tweet.tombstone.len > 0:
          error = conv.tweet.tombstone
        resp Http404, showError(error, cfg)

      if not prefs.hideInlineArticles:
        await ensureConversationArticles(conv)
      await cacheConversation(conv)

      let
        title = pageTitle(conv.tweet)
        ogTitle = pageTitle(conv.tweet.user)
        desc =
          block:
            let rawText = conv.tweet.text.strip.toLowerAscii()
            let looksLikeArticleToken =
              rawText.len == 0 or
              rawText.startsWith("x.com/i/article/") or
              rawText.startsWith("twitter.com/i/article/") or
              rawText.startsWith("/i/article/") or
              (((rawText.startsWith("https://t.co/") or
                 rawText.startsWith("http://t.co/") or
                 rawText.startsWith("t.co/")) and
                 ' ' notin rawText and '\n' notin rawText and '\t' notin rawText))
            let articleDesc =
              block:
                let article = resolveTweetArticle(conv.tweet)
                if article.body.len > 0:
                  article.body
                elif article.title.len > 0:
                  article.title
                elif conv.tweet.card.isSome and conv.tweet.card.get.text.strip.len > 0:
                  conv.tweet.card.get.text.strip
                elif conv.tweet.card.isSome and conv.tweet.card.get.title.strip.len > 0:
                  conv.tweet.card.get.title.strip
                else:
                  ""
            if looksLikeArticleToken and articleDesc.len > 0:
              articleDesc
            else:
              conv.tweet.text

      var
        images = conv.tweet.photos.mapIt(it.url)
        video = ""

      if conv.tweet.video.isSome():
        images = @[get(conv.tweet.video).thumb]
        video = getVideoEmbed(cfg, conv.tweet.id)
      elif conv.tweet.gif.isSome():
        images = @[get(conv.tweet.gif).thumb]
        video = getPicUrl(get(conv.tweet.gif).url)
      elif conv.tweet.card.isSome():
        let card = conv.tweet.card.get()
        if card.image.len > 0:
          images = @[card.image]
        elif card.video.isSome():
          images = @[card.video.get().thumb]

      let html = renderStatusPage(conv, prefs, getPath() & "#m")
      resp renderMain(html, request, cfg, prefs, title, desc, ogTitle,
                      images=images, video=video)

    get "/@name/status/@id/history/?":
      condValidUsername(@"name")
      let id = @"id"

      if id.len > 19 or id.any(c => not c.isDigit):
        resp Http404, showError("Invalid tweet ID", cfg)

      let edits = await getGraphEditHistory(id)
      if edits.latest == nil or edits.latest.id == 0:
        resp Http404, showError("Tweet history not found", cfg)

      let
        prefs = requestPrefs()
        title = "History for " & pageTitle(edits.latest)
        ogTitle = "Edit History for " & pageTitle(edits.latest.user)
        desc = edits.latest.text

      let html = renderEditHistory(edits, prefs, getPath())
      resp renderMain(html, request, cfg, prefs, title, desc, ogTitle)

    get "/@name/@s/@id/@m/?@i?":
      cond @"s" in ["status", "statuses"]
      cond @"m" in ["video", "photo"]
      redirect("/$1/status/$2" % [@"name", @"id"])

    get "/@name/statuses/@id/?":
      redirect("/$1/status/$2" % [@"name", @"id"])

    get "/i/web/status/@id":
      redirect("/i/status/" & @"id")

    get "/i/status/@id":
      let id = @"id"
      if id.len > 19 or id.any(c => not c.isDigit):
        resp Http404, showError("Invalid tweet ID", cfg)

      let conv = await getTweet(id, "")
      if conv == nil or conv.tweet == nil or conv.tweet.id == 0:
        resp Http404, showError("Tweet not found", cfg)
      redirect(getLink(conv.tweet, focus=false))

    get "/@name/thread/@id/?":
      redirect("/$1/status/$2" % [@"name", @"id"])
