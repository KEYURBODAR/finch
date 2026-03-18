# SPDX-License-Identifier: AGPL-3.0-only
import strutils, strformat, times, uri, tables, xmltree, htmlparser, htmlgen, math, options
import std/[enumerate, re]
import types, utils, query

const
  cards = "cards.twitter.com/cards"
  tco = "https://t.co"
  twitter = parseUri("https://x.com")

let
  twRegex = re"(?<=(?<!\S)https:\/\/|(?<=\s))(www\.|mobile\.)?twitter\.com"
  twLinkRegex = re"""<a href="https:\/\/twitter.com([^"]+)">twitter\.com(\S+)</a>"""
  xRegex = re"(?<=(?<!\S)https:\/\/|(?<=\s))(www\.|mobile\.)?x\.com"
  xLinkRegex = re"""<a href="https:\/\/x.com([^"]+)">x\.com(\S+)</a>"""

  ytRegex = re(r"([A-z.]+\.)?youtu(be\.com|\.be)", {reStudy, reIgnoreCase})

  rdRegex = re"(?<![.b])((www|np|new|amp|old)\.)?reddit.com"
  rdShortRegex = re"(?<![.b])redd\.it\/"
  # Videos cannot be supported uniformly between Teddit and Libreddit,
  # so v.redd.it links will not be replaced.
  # Images aren't supported due to errors from Teddit when the image
  # wasn't first displayed via a post on the Teddit instance.

  wwwRegex = re"https?://(www[0-9]?\.)?"
  m3u8Regex = re"""url="(.+.m3u8)""""
  userPicRegex = re"_(normal|bigger|mini|200x200|400x400)(\.[A-z]+)$"
  extRegex = re"(\.[A-z]+)$"
  illegalXmlRegex = re"(*UTF8)[^\x09\x0A\x0D\x20-\x{D7FF}\x{E000}-\x{FFFD}\x{10000}-\x{10FFFF}]"

proc getUrlPrefix*(cfg: Config): string =
  if cfg.useHttps: https & cfg.hostname
  else: "http://" & cfg.hostname

proc shorten*(text: string; length=28): string =
  result = text
  if result.len > length:
    result = result[0 ..< length] & "…"

proc compactCount*(num: int): string =
  if num < 1000 and num > -1000:
    return $num

  let
    negative = num < 0
    absNum = abs(num)
  var
    scaled = absNum.float
    suffix = ""

  if absNum >= 1_000_000_000:
    scaled = absNum.float / 1_000_000_000.0
    suffix = "B"
  elif absNum >= 1_000_000:
    scaled = absNum.float / 1_000_000.0
    suffix = "M"
  else:
    scaled = absNum.float / 1000.0
    suffix = "K"

  let decimals = if scaled < 10: 2 else: 1
  let rollover = 1000.0 - (1.0 / pow(10.0, decimals.float))
  if suffix == "K" and scaled >= rollover:
    scaled = absNum.float / 1_000_000.0
    suffix = "M"
  elif suffix == "M" and scaled >= rollover:
    scaled = absNum.float / 1_000_000_000.0
    suffix = "B"
  let finalDecimals = if scaled < 10: 2 else: 1
  var text = formatFloat(scaled, ffDecimal, finalDecimals)
  if "." in text:
    while text.len > 0 and text[^1] == '0':
      text.setLen(text.len - 1)
    if text.len > 0 and text[^1] == '.':
      text.setLen(text.len - 1)
  if negative:
    text = "-" & text
  text & suffix

proc shortLink*(text: string; length=28): string =
  result = text.replace(wwwRegex, "").shorten(length)
    
proc stripHtml*(text: string; shorten=false): string =
  var html = parseHtml(text)
  for el in html.findAll("a"):
    let link = el.attr("href")
    if "http" in link:
      if el.len == 0: continue
      el[0].text =
        if shorten: link.shortLink
        else: link
  html.innerText()

proc sanitizeXml*(text: string): string =
  text.replace(illegalXmlRegex, "")

proc replaceUrls*(body: string; prefs: Prefs; absolute=""): string =
  result = body

  if prefs.replaceYouTube.len > 0 and "youtu" in result:
    let youtubeHost = strip(prefs.replaceYouTube, chars={'/'})
    result = result.replace(ytRegex, youtubeHost)

  if prefs.replaceTwitter.len > 0:
    let twitterHost = strip(prefs.replaceTwitter, chars={'/'})
    if tco in result:
      result = result.replace(tco, https & twitterHost & "/t.co")
    if "x.com" in result:
      result = result.replace(xRegex, twitterHost)
      result = result.replacef(xLinkRegex, a(
        twitterHost & "$2", href = https & twitterHost & "$1"))
    if "twitter.com" in result:
      result = result.replace(cards, twitterHost & "/cards")
      result = result.replace(twRegex, twitterHost)
      result = result.replacef(twLinkRegex, a(
        twitterHost & "$2", href = https & twitterHost & "$1"))

  if prefs.replaceReddit.len > 0 and ("reddit.com" in result or "redd.it" in result):
    let redditHost = strip(prefs.replaceReddit, chars={'/'})
    result = result.replace(rdShortRegex, redditHost & "/comments/")
    result = result.replace(rdRegex, redditHost)
    if redditHost in result and "/gallery/" in result:
      result = result.replace("/gallery/", "/comments/")

  if absolute.len > 0 and "href" in result:
    result = result.replace("href=\"/", &"href=\"{absolute}/")

proc getM3u8Url*(content: string): string =
  var matches: array[1, string]
  if re.find(content, m3u8Regex, matches) != -1:
    result = matches[0]

proc proxifyVideo*(manifest: string; proxy: bool): string =
  var replacements: seq[(string, string)]
  for line in manifest.splitLines:
    let url =
      if line.startsWith("#EXT-X-MAP:URI"): line[16 .. ^2]
      elif line.startsWith("#EXT-X-MEDIA") and "URI=" in line:
        line[line.find("URI=") + 5 .. -1 + line.find("\"", start= 5 + line.find("URI="))]
      else: line
    if url.startsWith('/'):
      let path = "https://video.twimg.com" & url
      replacements.add (url, if proxy: path.getVidUrl else: path)
  return manifest.multiReplace(replacements)

proc getUserPic*(userPic: string; style=""): string =
  if userPic.len == 0:
    return "/pic/abs.twimg.com%2Fsticky%2Fdefault_profile_images%2Fdefault_profile_normal.png"
  userPic.replacef(userPicRegex, "$2").replacef(extRegex, style & "$1")

proc getUserPic*(user: User; style=""): string =
  getUserPic(user.userPic, style)

proc getVideoEmbed*(cfg: Config; id: int64): string =
  &"{getUrlPrefix(cfg)}/i/videos/{id}"

proc pageTitle*(user: User): string =
  &"{user.fullname} (@{user.username})"

proc pageTitle*(tweet: Tweet): string =
  let canonical =
    if tweet.retweet.isSome: tweet.retweet.get
    else: tweet
  &"{pageTitle(canonical.user)}: \"{stripHtml(canonical.text)}\""

proc pageDesc*(user: User): string =
  if user.bio.len > 0:
    stripHtml(user.bio)
  else:
    "The latest tweets from " & user.fullname

proc getJoinDate*(user: User): string =
  user.joinDate.format("'Joined' MMMM YYYY")

proc getJoinDateFull*(user: User): string =
  user.joinDate.format("h:mm tt - d MMM YYYY")

proc getTime*(tweet: Tweet): string =
  tweet.time.format("MMM d', 'YYYY' · 'h:mm tt' UTC'")

proc getRfc822Time*(tweet: Tweet): string =
  tweet.time.format("ddd', 'dd MMM yyyy HH:mm:ss 'GMT'")

proc getIsoTime*(tweet: Tweet): string =
  tweet.time.utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")

proc getShortTime*(tweet: Tweet): string =
  let now = now()
  let since = now - tweet.time

  if now.year != tweet.time.year:
    result = tweet.time.format("d MMM yyyy")
  elif since.inDays >= 1:
    result = tweet.time.format("MMM d")
  elif since.inHours >= 1:
    result = $since.inHours & "h"
  elif since.inMinutes >= 1:
    result = $since.inMinutes & "m"
  elif since.inSeconds > 1:
    result = $since.inSeconds & "s"
  else:
    result = "now"

proc getDuration*(video: Video): string =
  let 
    ms = video.durationMs
    sec = int(round(ms / 1000))
    min = floorDiv(sec, 60)
    hour = floorDiv(min, 60)
  if hour > 0:
    return &"{hour}:{min mod 60}:{sec mod 60:02}"
  else:
    return &"{min mod 60}:{sec mod 60:02}"

proc getLink*(id: int64; username="i"; focus=true): string =
  var username = username
  if username.len == 0:
    username = "i"
  result = &"/{username}/status/{id}"
  if focus: result &= "#m"

proc getLink*(tweet: Tweet; focus=true): string =
  if tweet.id == 0: return
  let canonical =
    if tweet.retweet.isSome: tweet.retweet.get
    else: tweet
  var username = canonical.user.username
  return getLink(canonical.id, username, focus)

proc getTwitterLink*(path: string; params: Table[string, string]): string =
  var
    username = params.getOrDefault("name")
    query = initQuery(params, username)
    path = path

  if path == "/" or path.startsWith("/f") or path.startsWith("/api") or
     path.startsWith("/settings"):
    return ""

  if "," in username:
    query.fromUser = username.split(",")
    path = "/search"

  if "/search" notin path and query.fromUser.len < 2:
    return $(twitter / path)

  let p = {
    "f": if query.kind == users: "user" else: "live",
    "q": genQueryParam(query),
    "src": "typed_query"
  }

  result = $(twitter / path ? p)
  if username.len > 0:
    result = result.replace("/" & username, "")

proc getLocation*(u: User | Tweet): (string, string) =
  if "://" in u.location: return (u.location, "")
  let loc = u.location.split(":")
  let url = if loc.len > 1: "/search?f=tweets&q=place:" & loc[1] else: ""
  (loc[0], url)

proc getSuspended*(username: string): string =
  &"User \"{username}\" has been suspended"

proc titleize*(str: string): string =
  const
    lowercase = {'a'..'z'}
    delims = {' ', '('}

  result = str
  for i, c in enumerate(str):
    if c in lowercase and (i == 0 or str[i - 1] in delims):
      result[i] = c.toUpperAscii
