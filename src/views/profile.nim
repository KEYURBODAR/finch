# SPDX-License-Identifier: AGPL-3.0-only
import strutils, strformat
import karax/[karaxdsl, vdom, vstyles]

import renderutils, search
import ".."/[types, utils, formatters]

proc renderStat(num: int; class: string; text=""): VNode =
  let t = if text.len > 0: text else: class
  buildHtml(li(class=class)):
    span(class="profile-stat-header"): text capitalizeAscii(t)
    span(class="profile-stat-num"):
      text insertSep($num, ',')

proc renderUserCard*(user: User; prefs: Prefs): VNode =
  buildHtml(tdiv(class="profile-card")):
    tdiv(class="profile-card-info"):
      let
        url = getPicUrl(user.getUserPic())
        size =
          if prefs.autoplayGifs and user.userPic.endsWith("gif"): ""
          else: "_400x400"

      a(class="profile-card-avatar", href=url, target="_blank"):
        genImg(user.getUserPic(size))

      tdiv(class="profile-card-tabs-name"):
        linkUser(user, class="profile-card-fullname")
        verifiedIcon(user)
        linkUser(user, class="profile-card-username")

    tdiv(class="profile-card-extra"):
      if user.bio.len > 0:
        tdiv(class="profile-bio"):
          p(dir="auto"):
            verbatim replaceUrls(user.bio, prefs)

      if user.location.len > 0:
        tdiv(class="profile-location"):
          span: icon "location"
          let (place, url) = getLocation(user)
          if url.len > 1:
            a(href=url): text place
          elif "://" in place:
            a(href=place): text place
          else:
            span: text place

      if user.website.len > 0:
        tdiv(class="profile-website"):
          span:
            let url = replaceUrls(user.website, prefs)
            icon "link"
            a(href=url): text url.shortLink

      tdiv(class="profile-joindate"):
        span(title=getJoinDateFull(user)):
          icon "calendar", getJoinDate(user)

      tdiv(class="profile-card-extra-links"):
        ul(class="profile-statlist"):
          renderStat(user.tweets, "posts", text="Tweets")
          renderStat(user.following, "following")
          renderStat(user.followers, "followers")
          renderStat(user.likes, "likes")

proc renderPhotoRail(profile: Profile): VNode =
  let count = insertSep($profile.user.media, ',')
  buildHtml(tdiv(class="photo-rail-card")):
    tdiv(class="photo-rail-header"):
      a(href=(&"/{profile.user.username}/media")):
        icon "picture", count & " Photos and videos"

    input(id="photo-rail-grid-toggle", `type`="checkbox")
    label(`for`="photo-rail-grid-toggle", class="photo-rail-header-mobile"):
      icon "picture", count & " Photos and videos"
      icon "down"

    tdiv(class="photo-rail-grid"):
      for i, photo in profile.photoRail:
        if i == 16: break
        let photoSuffix =
          if "format" in photo.url or "placeholder" in photo.url: ""
          else: ":thumb"
        a(href=(&"/{profile.user.username}/status/{photo.tweetId}#m")):
          genImg(photo.url & photoSuffix)

proc renderBanner(banner: string): VNode =
  buildHtml():
    if banner.len == 0:
      a()
    elif banner.startsWith('#'):
      a(style={backgroundColor: banner})
    else:
      a(href=getPicUrl(banner), target="_blank"): genImg(banner)

proc renderProtected(username: string): VNode =
  buildHtml(tdiv(class="timeline-container")):
    tdiv(class="timeline-header timeline-protected"):
      h2: text "This account's tweets are protected."
      p: text &"Only confirmed followers have access to @{username}'s tweets."

proc renderProfile*(profile: var Profile; prefs: Prefs; path: string): VNode =
  profile.tweets.query.fromUser = @[profile.user.username]
  let
    isGalleryView = profile.tweets.query.kind == media and
      profile.tweets.query.view == "gallery"
    viewClass = if isGalleryView: " media-only" else: ""

  buildHtml(tdiv(class=("profile-tabs" & viewClass))):
    if not isGalleryView and not prefs.hideBanner:
      tdiv(class="profile-banner"):
        renderBanner(profile.user.banner)

    if not isGalleryView:
      let sticky = if prefs.stickyProfile: " sticky" else: ""
      tdiv(class=("profile-tab" & sticky)):
        renderUserCard(profile.user, prefs)
        if profile.photoRail.len > 0:
          renderPhotoRail(profile)

    if profile.user.protected:
      renderProtected(profile.user.username)
    else:
      renderTweetSearch(profile.tweets, prefs, path, profile.pinned)

proc renderAffiliateBulkPanel*(affiliates: seq[User]; prefs: Prefs): VNode =
  buildHtml(tdiv(class="affiliate-bulk-panel")):
    p(class="affiliate-desc"):
      text "Add affiliate accounts to Following or Lists."
    if affiliates.len > 0:
      tdiv(class="affiliate-list"):
        for user in affiliates:
          tdiv(class="affiliate-item"):
            a(href=("/" & user.username)):
              genImg(user.getUserPic("_bigger"), class=prefs.getAvatarClass)
            tdiv(class="affiliate-info"):
              linkUser(user, class="fullname")
              linkUser(user, class="username")
    else:
      tdiv(class="timeline-header"):
        h2(class="timeline-none"):
          text "No affiliates found."

proc renderProfileListsBody*(lists: seq[List]; username: string): VNode =
  buildHtml(tdiv(class="profile-lists")):
    if lists.len == 0:
      tdiv(class="timeline-header"):
        h2(class="timeline-none"):
          text &"No lists from @{username}."
    else:
      for list in lists:
        tdiv(class="list-item"):
          a(href=(&"/i/lists/{list.id}")):
            text list.name
          if list.description.len > 0:
            p(class="list-description"): text list.description
