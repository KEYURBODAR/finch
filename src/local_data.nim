# SPDX-License-Identifier: AGPL-3.0-only
import std/[json, options, os, sequtils, strutils, sysrand, times]
import jsony
import nimcrypto

import types, formatters

type
  StoredMember = object
    userId: string
    username: string
    fullname: string
    avatar: string
    verifiedType: string = ""
    affiliateBadgeName: string = ""
    affiliateBadgeUrl: string = ""
    affiliateBadgeTarget: string = ""
    addedAtIso: string
    filters: MemberFilterPrefs

  StoredCollection = object
    id: string
    slug: string
    name: string
    description: string
    createdAtIso: string
    updatedAtIso: string
    kind: string
    members: seq[StoredMember]
    xListId: string = ""
    xListOwner: string = ""
    hiddenAttention: seq[string] = @[]

  StoredOwner = object
    ownerId: string
    createdAtIso: string
    updatedAtIso: string
    collections: seq[StoredCollection]

  LocalStore = object
    schema: int
    owners: seq[StoredOwner]

var
  localStore: LocalStore
  localDataPath: string

const
  localSchemaVersion* = 1
  identityKeyPrefix* = "fk_"
  localListPrefix* = "fc_"
  followingPrefix* = "ff_"

proc nowIso*(): string =
  now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")

proc toHexString(bytes: openArray[byte]): string =
  result = newStringOfCap(bytes.len * 2)
  for b in bytes:
    result.add toHex(b.int, 2).toLowerAscii

proc randomTokenHex(size: int): string =
  toHexString(urandom(size))

proc slugify*(value: string): string =
  var lastDash = false
  for ch in value.toLowerAscii:
    if ch in {'a'..'z', '0'..'9'}:
      result.add ch
      lastDash = false
    elif not lastDash and result.len > 0:
      result.add '-'
      lastDash = true
  result = result.strip(chars = {'-'})
  if result.len == 0:
    result = "list"

proc newIdentityKey*(): string =
  identityKeyPrefix & randomTokenHex(64)

proc ownerIdFromKey*(key: string): string =
  if key.len == 0:
    return ""
  "fo_" & $sha256.digest(key)

proc validIdentityKey*(key: string): bool =
  if not key.startsWith(identityKeyPrefix):
    return false
  let tail = key[identityKeyPrefix.len .. ^1]
  tail.len >= 64 and tail.len mod 2 == 0 and tail.allCharsInSet(HexDigits)

proc normalizeAvatarUrl*(url: string): string =
  if url.len == 0: return ""
  if url.startsWith("http"):
    return url
  return "https://pbs.twimg.com/" & url.strip(chars = {'/'})

proc collectionKindString(kind: FinchCollectionKind): string =
  if kind == following: "following" else: "list"

proc parseCollectionKind(value: string): FinchCollectionKind =
  if value == "following": following else: localList

proc parseVerifiedType(value: string): VerifiedType =
  case value.toLowerAscii
  of "blue": VerifiedType.blue
  of "business": VerifiedType.business
  of "government": VerifiedType.government
  else: VerifiedType.none

proc touchOwner(ownerId: string) =
  for owner in localStore.owners.mitems:
    if owner.ownerId == ownerId:
      owner.updatedAtIso = nowIso()
      break

proc saveStore() =
  if localDataPath.len == 0:
    return
  let
    parentDir = splitFile(localDataPath).dir
    tmpPath = localDataPath & ".tmp"
  if parentDir.len > 0:
    createDir(parentDir)
  writeFile(tmpPath, localStore.toJson)
  if fileExists(localDataPath):
    removeFile(localDataPath)
  moveFile(tmpPath, localDataPath)

proc ownerIndex(ownerId: string): int =
  for i, owner in localStore.owners:
    if owner.ownerId == ownerId:
      return i
  -1

proc collectionIndex(owner: StoredOwner; collectionId: string): int =
  for i, collection in owner.collections:
    if collection.id == collectionId:
      return i
  -1

proc findCollectionIndex(collectionId: string): (int, int) =
  for ownerIdx, owner in localStore.owners:
    let colIdx = collectionIndex(owner, collectionId)
    if colIdx >= 0:
      return (ownerIdx, colIdx)
  (-1, -1)

proc collectionToObject(ownerId: string; collection: StoredCollection): FinchCollection =
  result = FinchCollection(
    id: collection.id,
    ownerId: ownerId,
    slug: collection.slug,
    name: collection.name,
    description: collection.description,
    createdAtIso: collection.createdAtIso,
    updatedAtIso: collection.updatedAtIso,
    kind: parseCollectionKind(collection.kind),
    membersCount: collection.members.len,
    xListId: collection.xListId,
    xListOwner: collection.xListOwner
  )
  for member in collection.members[0 ..< min(collection.members.len, 15)]:
    result.previewMembers.add FinchCollectionMember(
      collectionId: collection.id,
      userId: member.userId,
      username: member.username,
      fullname: member.fullname,
      avatar: normalizeAvatarUrl(member.avatar),
      verifiedType: parseVerifiedType(member.verifiedType),
      affiliateBadgeName: member.affiliateBadgeName,
      affiliateBadgeUrl: normalizeAvatarUrl(member.affiliateBadgeUrl),
      affiliateBadgeTarget: member.affiliateBadgeTarget,
      addedAtIso: member.addedAtIso
    )

proc memberToObject(collectionId: string; member: StoredMember): FinchCollectionMember =
  FinchCollectionMember(
    collectionId: collectionId,
    userId: member.userId,
    username: member.username,
    fullname: member.fullname,
    avatar: normalizeAvatarUrl(member.avatar),
    verifiedType: parseVerifiedType(member.verifiedType),
    affiliateBadgeName: member.affiliateBadgeName,
    affiliateBadgeUrl: normalizeAvatarUrl(member.affiliateBadgeUrl),
    affiliateBadgeTarget: member.affiliateBadgeTarget,
    addedAtIso: member.addedAtIso,
    filters: member.filters
  )

proc uniqueSlug(ownerId, baseSlug, kind: string): string =
  result = baseSlug
  var suffix = 2
  let ownerIdx = ownerIndex(ownerId)
  if ownerIdx < 0:
    return

  while true:
    var collision = false
    for collection in localStore.owners[ownerIdx].collections:
      if collection.kind == kind and collection.slug == result:
        collision = true
        break
    if not collision:
      return
    result = baseSlug & "-" & $suffix
    inc suffix

proc createCollectionId(kind: FinchCollectionKind): string =
  if kind == following:
    followingPrefix & randomTokenHex(12)
  else:
    localListPrefix & randomTokenHex(12)

proc initLocalData*(cfg: Config) =
  localDataPath = cfg.localDataPath
  localStore = LocalStore(schema: localSchemaVersion)
  if fileExists(localDataPath):
    try:
      localStore = readFile(localDataPath).fromJson(LocalStore)
    except CatchableError:
      discard
  if localStore.schema == 0:
    localStore.schema = localSchemaVersion
  saveStore()

proc ensureOwner*(key: string): string =
  result = ownerIdFromKey(key)
  if result.len == 0:
    return

  let idx = ownerIndex(result)
  if idx >= 0:
    touchOwner(result)
    saveStore()
    return

  let ts = nowIso()
  localStore.owners.add StoredOwner(
    ownerId: result,
    createdAtIso: ts,
    updatedAtIso: ts,
    collections: @[]
  )
  saveStore()

proc getCollectionBySlug(ownerId, slug, kind: string): FinchCollection =
  let ownerIdx = ownerIndex(ownerId)
  if ownerIdx < 0:
    return
  for collection in localStore.owners[ownerIdx].collections:
    if collection.slug == slug and collection.kind == kind:
      return collectionToObject(ownerId, collection)

proc getCollectionById*(ownerId, id: string): FinchCollection =
  let ownerIdx = ownerIndex(ownerId)
  if ownerIdx < 0:
    return
  for collection in localStore.owners[ownerIdx].collections:
    if collection.id == id:
      return collectionToObject(ownerId, collection)

proc createCollection*(ownerId: string; kind: FinchCollectionKind; name, description: string): FinchCollection =
  let
    ts = nowIso()
    normalizedKind = collectionKindString(kind)
    baseSlug = if kind == following: "following" else: slugify(name)
    ownerIdx = ownerIndex(ownerId)
  if ownerIdx < 0:
    return

  let collection = StoredCollection(
    id: createCollectionId(kind),
    slug: uniqueSlug(ownerId, baseSlug, normalizedKind),
    name: if kind == following: "Following" else: (if name.strip.len > 0: name.strip else: "Untitled list"),
    description: description.strip,
    createdAtIso: ts,
    updatedAtIso: ts,
    kind: normalizedKind,
    members: @[],
    xListId: "",
    xListOwner: ""
  )
  localStore.owners[ownerIdx].collections.insert(collection, 0)
  touchOwner(ownerId)
  saveStore()
  result = collectionToObject(ownerId, collection)

proc getOrCreateFollowing*(ownerId: string): FinchCollection =
  result = getCollectionBySlug(ownerId, "following", "following")
  if result.id.len == 0:
    result = createCollection(ownerId, following, "Following", "")

proc getCollections*(ownerId: string; kind = ""): seq[FinchCollection] =
  let ownerIdx = ownerIndex(ownerId)
  if ownerIdx < 0:
    return
  for collection in localStore.owners[ownerIdx].collections:
    if kind.len == 0 or collection.kind == kind:
      result.add collectionToObject(ownerId, collection)

proc getCollectionMembers*(collectionId: string): seq[FinchCollectionMember] =
  let (ownerIdx, colIdx) = findCollectionIndex(collectionId)
  if ownerIdx < 0 or colIdx < 0:
    return
  for member in localStore.owners[ownerIdx].collections[colIdx].members:
    result.add memberToObject(collectionId, member)

proc getHiddenAttention*(collectionId: string): seq[string] =
  let (ownerIdx, colIdx) = findCollectionIndex(collectionId)
  if ownerIdx < 0 or colIdx < 0:
    return
  result = localStore.owners[ownerIdx].collections[colIdx].hiddenAttention

proc collectionUsernames*(collectionId: string): seq[string] =
  for member in getCollectionMembers(collectionId):
    result.add member.username

proc touchCollection(collectionId: string) =
  let (ownerIdx, colIdx) = findCollectionIndex(collectionId)
  if ownerIdx < 0 or colIdx < 0:
    return
  let ts = nowIso()
  localStore.owners[ownerIdx].collections[colIdx].updatedAtIso = ts
  touchOwner(localStore.owners[ownerIdx].ownerId)

proc memberFromUser*(collectionId: string; user: User): FinchCollectionMember =
  FinchCollectionMember(
    collectionId: collectionId,
    userId: user.id,
    username: user.username,
    fullname: user.fullname,
    avatar: user.getUserPic(),
    verifiedType: user.verifiedType,
    affiliateBadgeName: user.affiliateBadgeName,
    affiliateBadgeUrl: user.affiliateBadgeUrl,
    affiliateBadgeTarget: user.affiliateBadgeTarget,
    addedAtIso: nowIso()
  )

proc upsertMember*(collectionId: string; user: User) =
  if collectionId.len == 0 or user.username.len == 0:
    return
  let (ownerIdx, colIdx) = findCollectionIndex(collectionId)
  if ownerIdx < 0 or colIdx < 0:
    return

  let record = StoredMember(
    userId: user.id,
    username: user.username,
    fullname: user.fullname,
    avatar: user.getUserPic(),
    verifiedType: $user.verifiedType,
    affiliateBadgeName: user.affiliateBadgeName,
    affiliateBadgeUrl: user.affiliateBadgeUrl,
    affiliateBadgeTarget: user.affiliateBadgeTarget,
    addedAtIso: nowIso()
  )

  var members = localStore.owners[ownerIdx].collections[colIdx].members
  members = members.filterIt(it.username != user.username)
  members.insert(record, 0)
  localStore.owners[ownerIdx].collections[colIdx].members = members
  touchCollection(collectionId)
  saveStore()

proc setCollectionXListId*(collectionId, xListId, xListOwner: string) =
  if collectionId.len == 0 or xListId.len == 0:
    return
  let (ownerIdx, colIdx) = findCollectionIndex(collectionId)
  if ownerIdx < 0 or colIdx < 0:
    return
  localStore.owners[ownerIdx].collections[colIdx].xListId = xListId
  localStore.owners[ownerIdx].collections[colIdx].xListOwner = xListOwner
  touchCollection(collectionId)
  saveStore()

proc removeMember*(collectionId, username: string) =
  if collectionId.len == 0 or username.len == 0:
    return
  let (ownerIdx, colIdx) = findCollectionIndex(collectionId)
  if ownerIdx < 0 or colIdx < 0:
    return
  let before = localStore.owners[ownerIdx].collections[colIdx].members.len
  localStore.owners[ownerIdx].collections[colIdx].members =
    localStore.owners[ownerIdx].collections[colIdx].members.filterIt(it.username != username)
  if localStore.owners[ownerIdx].collections[colIdx].members.len != before:
    touchCollection(collectionId)
    saveStore()

proc removeMembers*(collectionId: string; usernames: seq[string]) =
  if collectionId.len == 0 or usernames.len == 0:
    return
  let needles = usernames.mapIt(it.toLowerAscii)
  let (ownerIdx, colIdx) = findCollectionIndex(collectionId)
  if ownerIdx < 0 or colIdx < 0:
    return
  let before = localStore.owners[ownerIdx].collections[colIdx].members.len
  localStore.owners[ownerIdx].collections[colIdx].members =
    localStore.owners[ownerIdx].collections[colIdx].members.filterIt(it.username.toLowerAscii notin needles)
  if localStore.owners[ownerIdx].collections[colIdx].members.len != before:
    touchCollection(collectionId)
    saveStore()

proc deleteCollection*(ownerId, collectionId: string): bool =
  let ownerIdx = ownerIndex(ownerId)
  if ownerIdx < 0 or collectionId.len == 0:
    return false
  let before = localStore.owners[ownerIdx].collections.len
  localStore.owners[ownerIdx].collections = localStore.owners[ownerIdx].collections.filterIt(
    it.id != collectionId or it.kind == "following"
  )
  result = localStore.owners[ownerIdx].collections.len != before
  if result:
    touchOwner(ownerId)
    saveStore()

proc clearOwnerCollections*(ownerId: string) =
  let ownerIdx = ownerIndex(ownerId)
  if ownerIdx < 0:
    return
  localStore.owners[ownerIdx].collections.setLen(0)
  touchOwner(ownerId)
  saveStore()

proc setMemberFilters*(collectionId, username: string; filters: MemberFilterPrefs) =
  if collectionId.len == 0 or username.len == 0:
    return
  let (ownerIdx, colIdx) = findCollectionIndex(collectionId)
  if ownerIdx < 0 or colIdx < 0:
    return
  for i, m in localStore.owners[ownerIdx].collections[colIdx].members:
    if m.username == username:
      localStore.owners[ownerIdx].collections[colIdx].members[i].filters = filters
      saveStore()
      return

proc isMember*(collectionId, username: string): bool =
  let (ownerIdx, colIdx) = findCollectionIndex(collectionId)
  if ownerIdx < 0 or colIdx < 0:
    return false
  localStore.owners[ownerIdx].collections[colIdx].members.anyIt(it.username == username)

proc hideAttentionEntity*(collectionId, entityKey: string) =
  if collectionId.len == 0 or entityKey.len == 0:
    return
  let (ownerIdx, colIdx) = findCollectionIndex(collectionId)
  if ownerIdx < 0 or colIdx < 0:
    return
  let needle = entityKey.strip.toLowerAscii
  if needle.len == 0:
    return
  if needle notin localStore.owners[ownerIdx].collections[colIdx].hiddenAttention:
    localStore.owners[ownerIdx].collections[colIdx].hiddenAttention.add needle
    touchCollection(collectionId)
    saveStore()

proc setFollowing*(ownerId: string; user: User; state: bool): bool =
  let collection = getOrCreateFollowing(ownerId)
  if state:
    upsertMember(collection.id, user)
    return true
  removeMember(collection.id, user.username)
  false

proc toggleFollowing*(ownerId: string; user: User): bool =
  let collection = getOrCreateFollowing(ownerId)
  result = not isMember(collection.id, user.username)
  discard setFollowing(ownerId, user, result)

proc getCollectionChoices*(ownerId, username: string): seq[FinchCollectionChoice] =
  for collection in getCollections(ownerId, "list"):
    result.add FinchCollectionChoice(collection: collection, selected: isMember(collection.id, username))

proc getAuthorAffinity*(ownerId, username: string): tuple[followed: bool, listCount: int] =
  let ownerIdx = ownerIndex(ownerId)
  if ownerIdx < 0 or username.len == 0:
    return

  let needle = username.toLowerAscii
  for collection in localStore.owners[ownerIdx].collections:
    let present = collection.members.anyIt(it.username.toLowerAscii == needle)
    if not present:
      continue
    if collection.kind == "following":
      result.followed = true
    elif collection.kind == "list":
      inc result.listCount

proc saveCollectionSelections*(ownerId: string; user: User; selectedIds: seq[string]) =
  let allowed = getCollections(ownerId, "list").mapIt(it.id)
  for collectionId in allowed:
    if collectionId in selectedIds:
      upsertMember(collectionId, user)
    else:
      removeMember(collectionId, user.username)

proc getProfileActions*(ownerId: string; user: User; referer: string): FinchProfileActions =
  if ownerId.len == 0:
    return FinchProfileActions(hasIdentity: false, referer: referer)
  let followingCollection = getOrCreateFollowing(ownerId)
  FinchProfileActions(
    hasIdentity: true,
    followed: isMember(followingCollection.id, user.username),
    collections: getCollectionChoices(ownerId, user.username),
    referer: referer
  )

proc exportOwnerData*(ownerId: string): JsonNode =
  var collections = newJArray()
  for collection in getCollections(ownerId):
    var members = newJArray()
    for member in getCollectionMembers(collection.id):
      members.add %*{
        "collection_id": member.collectionId,
        "user_id": member.userId,
        "username": member.username,
        "fullname": member.fullname,
        "avatar": member.avatar,
        "added_at_iso": member.addedAtIso
      }
    collections.add %*{
      "id": collection.id,
      "kind": collectionKindString(collection.kind),
      "slug": collection.slug,
      "name": collection.name,
      "description": collection.description,
      "created_at_iso": collection.createdAtIso,
      "updated_at_iso": collection.updatedAtIso,
      "hidden_attention": getHiddenAttention(collection.id),
      "members": members
    }

  result = %*{
    "schema": localSchemaVersion,
    "kind": "finch_local_export",
    "owner_id": ownerId,
    "exported_at_iso": nowIso(),
    "collections": collections
  }

proc importOwnerData*(identityKey, raw: string): string =
  let
    node = parseJson(raw)
    ownerId = ensureOwner(identityKey)
  if ownerId.len == 0:
    return ""

  if node.kind != JObject or node{"collections"}.kind != JArray:
    return ownerId

  for item in node["collections"].items:
    if item.kind != JObject:
      continue

    let kind =
      if item{"kind"}.getStr == "following": following
      else: localList

    let target =
      if kind == following:
        getOrCreateFollowing(ownerId)
      else:
        var existing = getCollectionById(ownerId, item{"id"}.getStr)
        if existing.id.len == 0:
          let ownerIdx = ownerIndex(ownerId)
          let slugBase = if item{"slug"}.getStr.len > 0: item{"slug"}.getStr else: slugify(item{"name"}.getStr)
          let stored = StoredCollection(
            id: if item{"id"}.getStr.startsWith(localListPrefix): item{"id"}.getStr else: createCollectionId(localList),
            slug: uniqueSlug(ownerId, slugBase, "list"),
            name: if item{"name"}.getStr.len > 0: item{"name"}.getStr else: "Untitled list",
            description: item{"description"}.getStr,
            createdAtIso: if item{"created_at_iso"}.getStr.len > 0: item{"created_at_iso"}.getStr else: nowIso(),
            updatedAtIso: nowIso(),
            kind: "list",
            members: @[],
            xListId: "",
            xListOwner: "",
            hiddenAttention: item{"hidden_attention"}.getElems.mapIt(it.getStr.toLowerAscii)
          )
          localStore.owners[ownerIdx].collections.insert(stored, 0)
          saveStore()
          existing = collectionToObject(ownerId, stored)
        else:
          let (existingOwnerIdx, existingColIdx) = findCollectionIndex(existing.id)
          if existingOwnerIdx >= 0 and existingColIdx >= 0:
            localStore.owners[existingOwnerIdx].collections[existingColIdx].name =
              if item{"name"}.getStr.len > 0: item{"name"}.getStr else: existing.name
            localStore.owners[existingOwnerIdx].collections[existingColIdx].description =
              item{"description"}.getStr
            localStore.owners[existingOwnerIdx].collections[existingColIdx].hiddenAttention =
              item{"hidden_attention"}.getElems.mapIt(it.getStr.toLowerAscii)
            touchCollection(existing.id)
            saveStore()
          existing = getCollectionById(ownerId, existing.id)
        existing

    if item{"members"}.kind == JArray:
      for member in item["members"].items:
        let user = User(
          id: member{"user_id"}.getStr,
          username: member{"username"}.getStr,
          fullname: member{"fullname"}.getStr,
          userPic: member{"avatar"}.getStr
        )
        if user.username.len > 0:
          upsertMember(target.id, user)

  ownerId
