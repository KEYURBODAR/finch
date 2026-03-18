# SPDX-License-Identifier: AGPL-3.0-only
import strutils, options
import karax/[karaxdsl, vdom]

import actions, renderutils
import ".."/[types, utils]

proc renderArticlePhoto(photo: Photo): VNode =
  buildHtml(tdiv(class="attachments article-attachments")):
    tdiv(class="gallery-row"):
      tdiv(class="attachment image"):
        let
          named = "name=" in photo.url
          small = if named: photo.url else: photo.url & smallWebp
        a(href=getOrigPicUrl(photo.url), class="still-image", target="_blank"):
          genImg(small, alt=photo.altText)
        if photo.altText.len > 0:
          p(class="alt-text"): text "ALT  " & photo.altText

proc renderArticleBlocks(article: Article): VNode =
  let blocks = if article.blocks.len > 0:
      article.blocks
    else:
      @[ArticleBlock(kind: paragraph, text: article.body)]

  buildHtml(tdiv(class="article-panel-body")):
    var i = 0
    while i < blocks.len:
      let articleBlock = blocks[i]
      case articleBlock.kind
      of paragraph:
        if articleBlock.text.len > 0:
          p:
            text articleBlock.text
        inc i
      of orderedListItem:
        ol(class="article-list ordered"):
          while i < blocks.len and blocks[i].kind == orderedListItem:
            li:
              text blocks[i].text
            inc i
      of unorderedListItem:
        ul(class="article-list unordered"):
          while i < blocks.len and blocks[i].kind == unorderedListItem:
            li:
              text blocks[i].text
            inc i
      of image:
        if articleBlock.photo.isSome:
          renderArticlePhoto(articleBlock.photo.get)
        inc i
      of tweetEmbed:
        tdiv(class="article-embed"):
          span(class="article-embed-kicker"):
            text "Embedded tweet"
          let
            rawUrl = "https://x.com/i/web/status/" & articleBlock.tweetId
            localUrl = finchInternalHref(rawUrl)
          a(class="article-embed-link", href=localUrl):
            text localUrl
        inc i

proc renderArticlePanel*(article: Article; links: openArray[PageActionLink] = []): VNode =
  buildHtml(tdiv(class="article-panel card")):
    tdiv(class="article-panel-header"):
      tdiv(class="article-panel-kicker"):
        text "Article"
      if links.len > 0:
        renderPageActions(links)

    if article.title.len > 0:
      h2(class="article-panel-title"):
        text article.title

    if article.url.len > 0:
      let articleHref = finchInternalHref(article.url)
      if articleHref.len == 0 or not articleHref.startsWith("/i/article/"):
        a(class="article-panel-url", href=(if articleHref.len > 0: articleHref else: article.url)):
          text (if articleHref.len > 0 and articleHref != article.url: articleHref else: article.url)

    if article.cover.isSome:
      renderArticlePhoto(article.cover.get)

    if article.blocks.len > 0 or article.body.len > 0:
      renderArticleBlocks(article)

proc renderArticleFallbackPanel*(url, title, body, coverUrl: string): VNode =
  var article = Article(
    url: url,
    title: title,
    body: body,
    partial: true
  )
  if coverUrl.len > 0:
    article.cover = some(Photo(url: coverUrl))
  renderArticlePanel(article)

proc articlePreviewExcerpt(text: string; maxLen=220): string =
  result = text.strip
  if result.len <= maxLen:
    return
  result = result[0 ..< maxLen].strip(chars={' ', '\n', '\t'}) & "…"

proc renderCompactArticlePreview*(url, title, body, coverUrl: string; hrefOverride=""): VNode =
  let
    safeTitle = if title.strip.len > 0: title.strip else: url
    excerpt = articlePreviewExcerpt(body)
    articleHref = if hrefOverride.len > 0: hrefOverride else: finchInternalHref(url)
  buildHtml(a(class="article-preview-card card", href=articleHref)):
    if coverUrl.len > 0:
      tdiv(class="article-preview-media"):
        tdiv(class="attachment image"):
          let
            named = "name=" in coverUrl
            small = if named: coverUrl else: coverUrl & smallWebp
          genImg(small, alt=safeTitle)
    tdiv(class="article-preview-content"):
      span(class="article-preview-kicker"):
        text "Article"
      h3(class="article-preview-title"):
        text safeTitle
      if excerpt.len > 0:
        p(class="article-preview-body"):
          text excerpt
