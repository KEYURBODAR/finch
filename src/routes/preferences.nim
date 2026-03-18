# SPDX-License-Identifier: AGPL-3.0-only
import std/[tables, strutils, uri]

import jester

import router_utils
import ../[csrf, types, local_data]
import ../views/[general, preferences]

export preferences

const finchIdentityCookie = "finch_identity_key"

template prefsCurrentIdentityKey*(): untyped =
  block:
    let rawKey = cookies(request).getOrDefault(finchIdentityCookie)
    if validIdentityKey(rawKey): rawKey else: ""

template setCsrfCookie*() {.dirty.} =
  let csrfToken {.inject.} = generateCsrfToken()
  setCookie(csrfCookieName, csrfToken, daysForward(1), httpOnly=true,
            secure=cfg.useHttps, sameSite=Lax, path="/")

template validateCsrf*() {.dirty.} =
  let csrfCookie = cookies(request).getOrDefault(csrfCookieName)
  let csrfForm = @csrfFieldName
  if not csrfTokensMatch(csrfCookie, csrfForm):
    resp Http403, showError("Invalid or expired form token. Please go back and try again.", cfg)

proc createPrefRouter*(cfg: Config) =
  router preferences:
    get "/settings":
      setCsrfCookie()
      let
        prefs = requestPrefs()
        identityKey = prefsCurrentIdentityKey()
        collections =
          if identityKey.len > 0:
            getCollections(ensureOwner(identityKey))
          else:
            @[]
        html = renderPreferences(prefs, refPath(), identityKey, collections, csrfToken)
      resp renderMain(html, request, cfg, prefs, "Preferences")

    get "/settings/@i?":
      redirect("/settings")

    post "/saveprefs":
      validateCsrf()
      genUpdatePrefs()
      redirect(refPath())

    post "/resetprefs":
      validateCsrf()
      genResetPrefs()
      redirect("/settings?referer=" & encodeUrl(refPath()))

    post "/enablehls":
      validateCsrf()
      savePref("hlsPlayback", "on", request)
      redirect(refPath())
