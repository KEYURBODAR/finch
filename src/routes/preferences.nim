# SPDX-License-Identifier: AGPL-3.0-only
import std/[tables, strutils, uri]

import jester

import router_utils
import ../[types, local_data]
import ../views/[general, preferences]

export preferences

const finchIdentityCookie = "finch_identity_key"

template prefsCurrentIdentityKey*(): untyped =
  block:
    let rawKey = cookies(request).getOrDefault(finchIdentityCookie)
    if validIdentityKey(rawKey): rawKey else: ""

proc createPrefRouter*(cfg: Config) =
  router preferences:
    get "/settings":
      let
        prefs = requestPrefs()
        identityKey = prefsCurrentIdentityKey()
        collections =
          if identityKey.len > 0:
            getCollections(ensureOwner(identityKey))
          else:
            @[]
        html = renderPreferences(prefs, refPath(), identityKey, collections)
      resp renderMain(html, request, cfg, prefs, "Preferences")

    get "/settings/@i?":
      redirect("/settings")

    post "/saveprefs":
      genUpdatePrefs()
      redirect(refPath())

    post "/resetprefs":
      genResetPrefs()
      redirect("/settings?referer=" & encodeUrl(refPath()))

    post "/enablehls":
      savePref("hlsPlayback", "on", request)
      redirect(refPath())
