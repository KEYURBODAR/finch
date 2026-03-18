# SPDX-License-Identifier: AGPL-3.0-only
import asyncdispatch, tables

var inflightRefreshes {.threadvar.}: Table[string, Future[void]]

proc ensureInflightTable() =
  if inflightRefreshes.len == 0:
    inflightRefreshes = initTable[string, Future[void]]()

proc coalesceRefresh*(key: string; body: proc(): Future[void] {.closure.}): Future[bool] {.async.} =
  ## Returns true for the leader request that performed the refresh.
  ## Followers wait for the in-flight refresh and return false.
  if key.len == 0:
    await body()
    return true

  ensureInflightTable()

  if key in inflightRefreshes:
    try:
      await inflightRefreshes[key]
    except CatchableError:
      discard
    return false

  let refresh = body()
  inflightRefreshes[key] = refresh
  try:
    await refresh
    return true
  finally:
    if key in inflightRefreshes and inflightRefreshes[key] == refresh:
      inflightRefreshes.del(key)
