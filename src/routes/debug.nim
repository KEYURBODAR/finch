# SPDX-License-Identifier: AGPL-3.0-only
import json, jester, os, strutils

import router_utils
import ".."/[auth, types]

proc constantTimeEqual(a, b: string): bool =
  if a.len != b.len:
    return false

  var mismatch = 0'u8
  for i in 0 ..< a.len:
    mismatch = mismatch or (a[i].uint8 xor b[i].uint8)

  mismatch == 0

template requireAdminAuth*() {.dirty.} =
  cond cfg.enableAdmin

  let adminToken = getEnv("NITTER_ADMIN_TOKEN", "")
  if adminToken.len == 0:
    resp Http403, "Admin token not configured. Set NITTER_ADMIN_TOKEN environment variable."

  let
    authHeader = request.headers.getOrDefault("Authorization")
    queryToken = @"token"
    bearerToken =
      if authHeader.startsWith("Bearer ") and authHeader.len > 7:
        authHeader[7..^1]
      else:
        ""
    authenticated =
      constantTimeEqual(bearerToken, adminToken) or
      (queryToken.len > 0 and constantTimeEqual(queryToken, adminToken))

  if not authenticated:
    resp Http401, "Unauthorized"

proc createDebugRouter*(cfg: Config) =
  router debug:
    get "/.health":
      cond cfg.enableAdmin
      respJson %*{
        "status": "ok",
        "sessions": sessionCount()
      }

    get "/.sessions":
      requireAdminAuth()
      respJson getSessionPoolDebug()
