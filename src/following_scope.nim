# SPDX-License-Identifier: AGPL-3.0-only
import sequtils, sets, strutils
import options

import types
import local_data

proc followingUsernames*(ownerId: string): seq[string] =
  ## Return usernames saved in the Finch-local "Following" collection for this owner.
  if ownerId.len == 0:
    return
  let collection = getOrCreateFollowing(ownerId)
  for member in getCollectionMembers(collection.id):
    if member.username.len > 0:
      result.add member.username

proc tweetMatchesFollowingScope(tweet: Tweet; allowed: HashSet[string]): bool =
  if tweet.id == 0 or tweet.user.username.len == 0:
    return false
  if tweet.retweet.isSome:
    return tweet.user.username.toLowerAscii in allowed
  tweet.user.username.toLowerAscii in allowed

proc filterTimelineToFollowing*(timeline: Timeline; ownerId: string): Timeline =
  ## Apply a Finch-local "following" scope to an X search timeline without any
  ## additional upstream calls: results are filtered to tweets (and retweets)
  ## authored by accounts present in the local Following collection.
  result = timeline
  let allowedUsernames = followingUsernames(ownerId).mapIt(it.toLowerAscii).toHashSet
  if allowedUsernames.len == 0:
    result.content = @[]
    return
  result.content = @[]
  for thread in timeline.content:
    if thread.len == 0:
      continue
    var filtered: Tweets = @[]
    for tweet in thread:
      if tweetMatchesFollowingScope(tweet, allowedUsernames):
        filtered.add tweet
    if filtered.len > 0:
      result.content.add filtered
