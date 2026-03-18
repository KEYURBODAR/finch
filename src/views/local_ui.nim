# SPDX-License-Identifier: AGPL-3.0-only
import strutils, strformat
import karax/[karaxdsl, vdom]

import renderutils
import ".."/types

proc collectionEmptyMessage*(explicitNone, hasDate, hasText, hasFilters: bool): VNode =
  let msg =
    if explicitNone: "No profiles selected. Choose members to see posts."
    elif hasDate and (hasText or hasFilters): "No posts match these filters in the selected range."
    elif hasDate: "No posts found in this date range."
    elif hasText or hasFilters: "No posts match these filters."
    else: "No posts available yet."

  buildHtml(tdiv(class="timeline-header")):
    h2(class="timeline-none"): text msg
