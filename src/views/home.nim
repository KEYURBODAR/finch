# SPDX-License-Identifier: AGPL-3.0-only
import karax/[karaxdsl, vdom]

import renderutils
import ".."/types

proc renderHome*(cfg: Config): VNode =
  buildHtml(tdiv(class="overlay-panel")):
    h1(class="home-title"): text cfg.title
    p(class="home-subtitle"):
      text "Fast, private access to X."

    tdiv(class="home-search"):
      form(`method`="get", action="/search", autocomplete="off"):
        hiddenField("f", "tweets")
        input(`type`="text", name="q", id="finch-go-input", autofocus="",
              placeholder="from:elonmusk filter:links min_faves:50", dir="auto",
              `aria-label`="Search posts")
        button(`type`="submit"): icon "search"

    tdiv(class="home-chips"):
      a(class="chip", href="/search?q=from%3Aelonmusk+filter%3Alinks+min_faves%3A50&f=tweets"):
        text "from:elonmusk filter:links min_faves:50"
      a(class="chip", href="/search?q=filter%3Amedia+min_retweets%3A100&f=tweets"):
        text "filter:media min_retweets:100"
      a(class="chip", href="/search?q=lang%3Aen+near%3A%22San+Francisco%22&f=tweets"):
        text "lang:en near:\"San Francisco\""

    tdiv(class="home-links"):
      a(href="/following"): text "Following"
      a(href="/lists"): text "Lists"
