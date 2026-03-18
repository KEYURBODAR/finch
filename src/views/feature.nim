# SPDX-License-Identifier: AGPL-3.0-only
import karax/[karaxdsl, vdom]

proc renderFeature*(): VNode =
  buildHtml(tdiv(class="overlay-panel")):
    h1: text "Feature not available"
    p:
      text "This feature isn't supported yet. "
      text "Check back later or visit the "
      a(href="/about"): text "About page"
      text " for more information."
