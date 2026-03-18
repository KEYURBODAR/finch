# SPDX-License-Identifier: AGPL-3.0-only
## X-native list mutations. Mutation endpoint IDs in consts.nim are placeholders;
## replace with real IDs from x.com DevTools (Network tab when creating a list / adding a member).
import asyncdispatch, packedjson, strutils
import apiutils, consts, local_data, types

type
  CreateListResult* = object
    ok*: bool
    listId*: string
    listOwnerId*: string
    error*: string

  MutateListResult* = object
    ok*: bool
    error*: string

proc createXList*(name, description, mode: string): Future[CreateListResult] {.async.} =
  ## mode: "Public" or "Private". Returns listId and owner id from response when ok.
  result = CreateListResult(ok: false)
  try:
    var variables = newJObject()
    variables["name"] = %name
    variables["description"] = %description
    variables["isPrivate"] = %(mode.toLowerAscii == "private")
    let js = await fetchPost(graphCreateList, variables)
    echo "[x_lists] createXList response: ", $js
    let data = js{"data"}
    if data.kind != JObject:
      result.error = "Unexpected response: no data"
      return
    # Try all known response key paths — X uses different ones
    var listNode = data{"list"}
    if listNode.kind == JNull:
      listNode = data{"create_list", "list"}
    if listNode.kind == JNull:
      listNode = data{"createList", "list"}
    if listNode.kind == JNull:
      # Only fail if we truly got no list data
      let errs = js{"errors"}
      if errs.kind == JArray and errs.len > 0:
        result.error = errs[0].getOrDefault("message").getStr
      else:
        result.error = "Create list failed — no list node in response"
      return
    result.listId = listNode{"rest_id"}.getStr
    if result.listId.len == 0:
      result.listId = listNode{"id_str"}.getStr
    if result.listId.len == 0:
      result.listId = listNode{"id"}.getStr
    let ownerNode = listNode{"user_results", "result"}
    if ownerNode.kind != JNull:
      result.listOwnerId = ownerNode{"rest_id"}.getStr
    if result.listOwnerId.len == 0:
      let ownerLegacy = listNode{"user"}
      if ownerLegacy.kind != JNull:
        result.listOwnerId = ownerLegacy{"rest_id"}.getStr
        if result.listOwnerId.len == 0:
          result.listOwnerId = ownerLegacy{"id"}.getStr
    if result.listId.len > 0:
      result.ok = true
      echo "[x_lists] created list ", result.listId, " owner: ", result.listOwnerId
  except CatchableError as e:
    echo "[x_lists] createXList exception: ", e.name, " — ", e.msg
    result.error = e.msg

proc deleteXList*(listId: string): Future[MutateListResult] {.async.} =
  result = MutateListResult(ok: false)
  if listId.len == 0:
    result.error = "listId required"
    return
  try:
    var variables = newJObject()
    variables["listId"] = %listId
    let js = await fetchPost(graphDeleteList, variables)
    echo "[x_lists] deleteXList response: ", $js
    let data = js{"data"}
    if data.kind != JObject:
      result.error = "Unexpected response"
      return
    # Try snake_case and camelCase
    let delNode = if data{"list_delete"}.kind != JNull: data{"list_delete"}
                  elif data{"deleteList"}.kind != JNull: data{"deleteList"}
                  else: newJNull()
    if delNode.kind != JNull:
      result.ok = true
  except CatchableError as e:
    echo "[x_lists] deleteXList exception: ", e.name, " — ", e.msg
    result.error = e.msg

proc addMemberToXList*(listId, userId: string): Future[MutateListResult] {.async.} =
  result = MutateListResult(ok: false)
  if listId.len == 0 or userId.len == 0:
    result.error = "listId and userId required"
    return
  try:
    var variables = newJObject()
    variables["listId"] = %listId
    variables["userId"] = %userId
    let js = await fetchPost(graphListAddMember, variables)
    echo "[x_lists] addMember response for user ", userId, ": ", $js
    let data = js{"data"}
    if data.kind != JObject:
      result.error = "Unexpected response: no data"
      return
    # X returns data.list_add_member (snake_case) — check both formats
    let addNode = if data{"list_add_member"}.kind != JNull: data{"list_add_member"}
                  elif data{"listAddMember"}.kind != JNull: data{"listAddMember"}
                  elif data{"list"}.kind != JNull: data{"list"}
                  else: newJNull()
    if addNode.kind != JNull:
      result.ok = true
      echo "[x_lists] addMember OK for user ", userId, " to list ", listId
    else:
      result.error = "No list mutation node in response"
      echo "[x_lists] addMember failed — response data keys: ", $data
  except CatchableError as e:
    echo "[x_lists] addMember exception: ", e.name, " — ", e.msg
    result.error = e.msg

proc removeMemberFromXList*(listId, userId: string): Future[MutateListResult] {.async.} =
  result = MutateListResult(ok: false)
  if listId.len == 0 or userId.len == 0:
    result.error = "listId and userId required"
    return
  try:
    var variables = newJObject()
    variables["listId"] = %listId
    variables["userId"] = %userId
    let js = await fetchPost(graphListRemoveMember, variables)
    echo "[x_lists] removeMember response: ", $js
    let data = js{"data"}
    if data.kind != JObject:
      result.error = "Unexpected response"
      return
    let remNode = if data{"list_remove_member"}.kind != JNull: data{"list_remove_member"}
                  elif data{"listRemoveMember"}.kind != JNull: data{"listRemoveMember"}
                  else: newJNull()
    if remNode.kind != JNull:
      result.ok = true
  except CatchableError as e:
    echo "[x_lists] removeMember exception: ", e.name, " — ", e.msg
    result.error = e.msg

proc syncFollowingToX*(collection: FinchCollection; user: User; state: bool): Future[void] {.async.} =
  try:
    if state:
      if collection.xListId.len == 0:
        let cr = await createXList("Finch Following", "Managed by Finch", "Private")
        if cr.ok and cr.listId.len > 0:
          setCollectionXListId(collection.id, cr.listId, cr.listOwnerId)
          discard await addMemberToXList(cr.listId, user.id)
      else:
        discard await addMemberToXList(collection.xListId, user.id)
    else:
      if collection.xListId.len > 0:
        discard await removeMemberFromXList(collection.xListId, user.id)
  except CatchableError:
    discard

proc syncListMemberToX*(collection: FinchCollection; user: User; add: bool): Future[void] {.async.} =
  try:
    if add:
      if collection.xListId.len == 0:
        # Auto-create X list on first member add
        let cr = await createXList(collection.name, collection.description, "Private")
        if cr.ok and cr.listId.len > 0:
          setCollectionXListId(collection.id, cr.listId, cr.listOwnerId)
          echo "[x_lists] auto-created X list ", cr.listId, " for collection ", collection.id
          discard await addMemberToXList(cr.listId, user.id)
        else:
          echo "[x_lists] auto-create failed: ", cr.error
      else:
        discard await addMemberToXList(collection.xListId, user.id)
    else:
      if collection.xListId.len > 0:
        discard await removeMemberFromXList(collection.xListId, user.id)
  except CatchableError as e:
    echo "[x_lists] syncListMemberToX error: ", e.name, " — ", e.msg

proc migrateCollectionToX*(collection: FinchCollection): Future[bool] {.async.} =
  if collection.id.len == 0:
    return false
  if collection.xListId.len > 0:
    return true

  let created = await createXList(collection.name, collection.description, "Private")
  if not created.ok or created.listId.len == 0:
    return false

  setCollectionXListId(collection.id, created.listId, created.listOwnerId)
  for member in getCollectionMembers(collection.id):
    if member.userId.len == 0:
      continue
    let added = await addMemberToXList(created.listId, member.userId)
    if not added.ok:
      return false
  true
