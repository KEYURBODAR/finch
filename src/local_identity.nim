# SPDX-License-Identifier: AGPL-3.0-only
import std/tables
from jester import Request, cookies, setCookie, SameSite

import types
import local_data

const
  finchIdentityCookie* = "finch_identity_key"
  finchIdentitySkipCookie* = "finch_identity_skip"

proc getFinchIdentityKey*(req: Request): string =
  result = cookies(req).getOrDefault(finchIdentityCookie)
  if not validIdentityKey(result):
    result = ""

proc hasFinchIdentity*(req: Request): bool =
  getFinchIdentityKey(req).len > 0

proc getFinchOwnerId*(req: Request): string =
  ownerIdFromKey(getFinchIdentityKey(req))

proc shouldPromptForIdentity*(req: Request): bool =
  not hasFinchIdentity(req) and cookies(req).getOrDefault(finchIdentitySkipCookie) != "1"

template saveFinchIdentity*(key: string; cfg: Config) =
  setCookie(finchIdentityCookie, key, daysForward(3650), httpOnly=true,
            secure=cfg.useHttps, sameSite=Lax, path="/")
  setCookie(finchIdentitySkipCookie, "", daysForward(-10), httpOnly=true,
            secure=cfg.useHttps, sameSite=Lax, path="/")

template clearFinchIdentity*(cfg: Config) =
  setCookie(finchIdentityCookie, "", daysForward(-10), httpOnly=true,
            secure=cfg.useHttps, sameSite=Lax, path="/")

template saveFinchIdentitySkip*(cfg: Config) =
  setCookie(finchIdentitySkipCookie, "1", daysForward(180), httpOnly=true,
            secure=cfg.useHttps, sameSite=Lax, path="/")
