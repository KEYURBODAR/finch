import std/[strutils, os, asyncdispatch]
import packedjson

import ../src/[types, consts, apiutils]

type Match = tuple[path: string, value: string]

proc genParams(variables: string; fieldToggles = ""): seq[(string, string)] =
  result.add ("variables", variables)
  result.add ("features", gqlFeatures)
  if fieldToggles.len > 0:
    result.add ("fieldToggles", fieldToggles)

proc tweetDetailReq(id: string): ApiReq =
  let cookieVars = tweetDetailVars % [id, ""]
  let cookieUrl = ApiUrl(
    endpoint: graphTweetDetail,
    params: genParams(cookieVars, tweetDetailFieldToggles)
  )
  let oauthUrl = ApiUrl(
    endpoint: graphTweet,
    params: genParams(tweetVars % [id, ""], tweetDetailFieldToggles)
  )
  ApiReq(cookie: cookieUrl, oauth: oauthUrl)

proc collectMatches(node: packedjson.JsonNode; path: string; matches: var seq[Match]) =
  case node.kind
  of packedjson.JObject:
    for k, v in node:
      let next = if path.len == 0: k else: path & "." & k
      if k.toLowerAscii.contains("article") or
         k in ["plain_text", "preview_text", "title", "body", "rich_content", "rich_content_state", "summary_text"]:
        if v.kind in {packedjson.JString, packedjson.JInt, packedjson.JFloat, packedjson.JBool}:
          matches.add (next, $v)
      collectMatches(v, next, matches)
  of packedjson.JArray:
    for i, v in node:
      collectMatches(v, path & "[" & $i & "]", matches)
  else:
    discard

when isMainModule:
  if paramCount() < 1:
    quit "usage: nim r tools/probe_article_graphql.nim <tweet_id>"

  let tweetId = paramStr(1)
  let js = waitFor fetch(tweetDetailReq(tweetId))
  writeFile("/tmp/article_tweetdetail_" & tweetId & ".json", $js)

  var hits: seq[Match] = @[]
  collectMatches(js, "", hits)
  for (path, value) in hits:
    echo path, " = ", value[0 .. min(value.high, 400)]
