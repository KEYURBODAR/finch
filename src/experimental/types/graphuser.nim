import options, strutils
from ../../types import User, VerifiedType

type
  GraphUser* = object
    data*: tuple[userResult: Option[UserData], user: Option[UserData]]

  UserData* = object
    result*: UserResult

  UserCore* = object
    name*: string
    screenName*: string
    createdAt*: string

  UserBio* = object
    description*: string

  UserAvatar* = object
    imageUrl*: string

  Verification* = object
    verifiedType*: VerifiedType

  Location* = object
    location*: string

  Privacy* = object
    protected*: bool

  BusinessAccount* = object
    affiliatesCount*: int

  BadgeImage* = object
    url*: string

  BadgeUrl* = object
    url*: string

  AffiliateLabel* = object
    description*: string
    badge*: BadgeImage
    url*: BadgeUrl

  AffiliatesHighlightedLabel* = object
    label*: AffiliateLabel

  UserResult* = object
    legacy*: User
    restId*: string
    isBlueVerified*: bool
    core*: UserCore
    avatar*: UserAvatar
    unavailableReason*: Option[string]
    reason*: Option[string]
    privacy*: Option[Privacy]
    profileBio*: Option[UserBio]
    verification*: Option[Verification]
    location*: Option[Location]
    businessAccount*: Option[BusinessAccount]
    affiliatesHighlightedLabel*: Option[AffiliatesHighlightedLabel]

proc enumHook*(s: string; v: var VerifiedType) =
  v = try:
    parseEnum[VerifiedType](s)
  except:
    VerifiedType.none
