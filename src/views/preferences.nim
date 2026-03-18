# SPDX-License-Identifier: AGPL-3.0-only
import tables, macros, strutils
import karax/[karaxdsl, vdom]

import renderutils
import ../types, ../prefs_impl

macro renderPrefs*(): untyped =
  result = nnkCall.newTree(
    ident("buildHtml"), ident("tdiv"), nnkStmtList.newTree())

  for header, options in prefList:
    let sectionName = case header
      of "Speed and calls": "Performance"
      of "Link rewrites": "Link redirects"
      of "Finch data": "Your data"
      else: header

    result[2].add nnkCall.newTree(
      ident("legend"),
      nnkStmtList.newTree(
        nnkCommand.newTree(ident("text"), newLit(sectionName))))

    for pref in options:
      # TODO: set bidiSupport default to true in prefs_impl.nim
      if pref.name == "bidiSupport": continue

      let label = case pref.name
        of "stickyNav": "Sticky navigation"
        of "stickyProfile": "Sticky sidebar"
        of "squareAvatars": "Square avatars"
        of "hideBanner": "Hide banners"
        of "hidePhotoRail": "Hide media sidebar"
        of "profileBioSidebar": "Show bio in sidebar"
        of "hideTweetStats": "Hide engagement counts"
        of "hidePins": "Hide pinned"
        of "hideReplies": "Hide replies"
        of "hideFilteredReplies": "Exclude replies by default"
        of "hideCommunityNotes": "Hide community notes"
        of "hideCards": "Hide link previews"
        of "hideArticles": "Hide article previews"
        of "autoplayGifs": "Autoplay GIFs"
        of "gifsMp4": "GIFs as MP4"
        of "hlsPlayback": "HLS video playback"
        of "proxyVideos": "Proxy videos"
        of "muteVideos": "Mute videos"
        of "hideMediaPreview": "Hide all media"
        of "preloadImages": "Preload media"
        of "infiniteScroll": "Infinite scroll"
        else: pref.label

      let procName = ident("gen" & capitalizeAscii($pref.kind))
      let state = nnkDotExpr.newTree(ident("prefs"), ident(pref.name))
      var stmt = nnkStmtList.newTree(
        nnkCall.newTree(procName, newLit(pref.name), newLit(label), state))

      case pref.kind
      of checkbox: discard
      of input: stmt[0].add newLit(pref.placeholder)
      of select:
        if pref.name == "theme":
          stmt[0].add ident("themes")
        else:
          stmt[0].add newLit(pref.options)

      result[2].add stmt

proc renderPreferences*(prefs: Prefs; path: string; themes: seq[string];
                        prefsUrl: string): VNode =
  buildHtml(tdiv(class="overlay-panel")):
    fieldset(class="preferences"):
      form(`method`="post", action="/saveprefs", autocomplete="off"):
        refererField path

        p(class="settings-subtitle"):
          text "These preferences are stored locally in your browser."

        renderPrefs()

        legend: text "Bookmark"
        p(class="bookmark-note"):
          text "Save this URL to restore your preferences (?prefs works on all pages)"
        pre(class="prefs-code"):
          text prefsUrl
        p(class="bookmark-note"):
          verbatim "You can override preferences with query parameters (e.g. <code>?hlsPlayback=on</code>). These overrides aren't saved to cookies, and links won't retain the parameters. Intended for configuring RSS feeds and other cookieless environments. Hover over a preference to see its name."

        button(`type`="submit", class="pref-submit"):
          text "Save preferences"

      buttonReferer "/resetprefs", "Reset preferences", path, class="pref-reset"
