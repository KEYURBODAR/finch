# SPDX-License-Identifier: AGPL-3.0-only
import asyncdispatch, httpclient, json, os, osproc, options, strutils, uri
import std/re
import xmltree, htmlparser

import types, apiutils, auth, redis_cache

const
  articleEndpoint = "article_fetch"
  articleHostPath = "/i/article/"

let hrefRegex = re"""href="([^"]+)""""

proc normalizeArticleUrl*(url: string): string =
  if url.len == 0:
    return

  var parsed = parseUri(url)
  if parsed.hostname.len == 0:
    return

  parsed.anchor = ""
  parsed.query = ""
  if parsed.scheme == "http":
    parsed.scheme = "https"
  parsed.hostname = parsed.hostname.replace("twitter.com", "x.com")
  result = $parsed

proc isArticleUrl*(url: string): bool =
  let normalized = normalizeArticleUrl(url)
  normalized.startsWith("https://x.com" & articleHostPath)

proc htmlAnchorHrefs(html: string): seq[string] =
  if html.len == 0:
    return

  var matches: array[1, string]
  var start = 0
  while true:
    let idx = html.find(hrefRegex, matches, start)
    if idx < 0:
      break
    result.add matches[0]
    start = idx + matches[0].len + 6

  if result.len == 0:
    let doc = parseHtml(html)
    for anchor in doc.findAll("a"):
      let href = anchor.attr("href")
      if href.len > 0:
        result.add href

proc getArticleUrl*(tweet: Tweet): string =
  if tweet.isNil:
    return

  if tweet.articleUrl.len > 0:
    return normalizeArticleUrl(tweet.articleUrl)

  if tweet.article.isSome and tweet.article.get.url.len > 0:
    return normalizeArticleUrl(tweet.article.get.url)

  if tweet.card.isSome:
    let card = tweet.card.get
    for candidate in [card.url, card.dest]:
      if candidate.isArticleUrl:
        return normalizeArticleUrl(candidate)

  for candidate in htmlAnchorHrefs(tweet.text) & htmlAnchorHrefs(tweet.note):
    if candidate.isArticleUrl:
      return normalizeArticleUrl(candidate)

proc parseArticleHtml(html, url: string): Article =
  let script = getAppDir() / "tools" / "parse_article_html.py"
  let cmd = "python3 " & quoteShell(script) & " " & quoteShell(url)
  var output = ""
  var exitCode = 1
  try:
    (output, exitCode) = execCmdEx(cmd, options = {poUsePath}, input = html)
  except CatchableError:
    return Article(url: url)
  if exitCode != 0 or output.len == 0:
    return Article(url: url)

  try:
    let parsed = parseJson(output)
    result = Article(
      url: parsed["url"].getStr,
      title: parsed["title"].getStr,
      body: parsed["body"].getStr
    )
  except CatchableError:
    result = Article(url: url)

proc fetchArticleHtml(url: string): Future[string] {.async.} =
  let req = ApiReq(
    cookie: ApiUrl(endpoint: articleEndpoint),
    oauth: ApiUrl(endpoint: articleEndpoint)
  )

  var
    client: AsyncHttpClient
    session = await getAndValidateSession(req)

  try:
    let target = parseUri(url)
    var headers = await genHeaders(session, target)
    headers["accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
    headers.del("content-type")
    headers.del("origin")
    headers.del("x-twitter-active-user")
    headers.del("x-twitter-client-language")
    headers.del("priority")

    client = newAsyncHttpClient(headers = headers, maxRedirects = 5)
    let resp = await client.get(url)
    if resp.code.int in 200 .. 299:
      result = await resp.body
  finally:
    if not client.isNil:
      client.close()
    release(session)

  if result.len == 0:
    var publicClient: AsyncHttpClient
    try:
      publicClient = newAsyncHttpClient(maxRedirects = 5)
      publicClient.headers = newHttpHeaders({
        "accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "accept-language": "en-US,en;q=0.9",
        "user-agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36"
      })
      let resp = await publicClient.get(url)
      if resp.code.int in 200 .. 299:
        result = await resp.body
    finally:
      if not publicClient.isNil:
        publicClient.close()

proc getArticle*(url: string): Future[Article] {.async.} =
  let normalized = normalizeArticleUrl(url)
  if normalized.len == 0:
    return

  let cached = await getCachedArticle(normalized)
  if cached.url.len > 0 and (cached.title.len > 0 or cached.body.len > 0):
    return cached

  let html = await fetchArticleHtml(normalized)
  if html.len == 0:
    return Article(url: normalized)

  result = parseArticleHtml(html, normalized)
  if result.url.len == 0:
    result.url = normalized

  if result.title.len > 0 or result.body.len > 0:
    await cache(result)

proc hydrateArticle*(tweet: Tweet) {.async.} =
  if tweet.isNil:
    return

  let articleUrl = tweet.getArticleUrl
  if articleUrl.len > 0:
    var shouldFetch = not tweet.article.isSome
    if tweet.article.isSome:
      let current = tweet.article.get
      shouldFetch = current.body.len == 0 or current.partial

    if shouldFetch:
      let article = await getArticle(articleUrl)
      if article.url.len > 0 and (article.title.len > 0 or article.body.len > 0):
        tweet.article = some(article)
      elif tweet.article.isSome:
        var current = tweet.article.get
        current.url = articleUrl
        tweet.article = some(current)

  if tweet.quote.isSome:
    await hydrateArticle(tweet.quote.get)

proc hydrateConversationArticles*(conv: Conversation) {.async.} =
  if conv.isNil or conv.tweet.isNil:
    return

  for tweet in conv.before.content:
    await hydrateArticle(tweet)
  await hydrateArticle(conv.tweet)
  for tweet in conv.after.content:
    await hydrateArticle(tweet)
