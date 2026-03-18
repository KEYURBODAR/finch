# SPDX-License-Identifier: AGPL-3.0-only
import times, sequtils, options, tables
import prefs_impl

genPrefsType()

type
  RateLimitError* = object of CatchableError
    endpoint*: string
    resetAt*: int
    sessionTotal*: int
  NoSessionsError* = object of CatchableError
    endpoint*: string
    resetAt*: int
    sessionTotal*: int
  InternalError* = object of CatchableError
  BadClientError* = object of CatchableError

  TimelineKind* {.pure.} = enum
    tweets, replies, media

  ApiUrl* = object
    endpoint*: string
    params*: seq[(string, string)]

  ApiReq* = object
    oauth*: ApiUrl
    cookie*: ApiUrl

  RateLimit* = object
    limit*: int
    remaining*: int
    reset*: int

  SessionKind* = enum
    oauth
    cookie

  Session* = ref object
    id*: int64
    username*: string
    pending*: int
    lastUsedAt*: int
    totalRequests*: int
    apis*: Table[string, RateLimit]
    case kind*: SessionKind
    of oauth:
      oauthToken*: string
      oauthSecret*: string
    of cookie:
      authToken*: string
      ct0*: string
      guestId*: string
      guestIdAds*: string
      guestIdMarketing*: string

  Error* = enum
    null = 0
    noUserMatches = 17
    protectedUser = 22
    missingParams = 25
    timeout = 29
    couldntAuth = 32
    doesntExist = 34
    unauthorized = 37
    invalidParam = 47
    userNotFound = 50
    suspended = 63
    rateLimited = 88
    expiredToken = 89
    listIdOrSlug = 112
    tweetNotFound = 144
    tweetNotAuthorized = 179
    forbidden = 200
    badRequest = 214
    badToken = 239
    locked = 326
    noCsrf = 353
    tweetUnavailable = 421
    tweetCensored = 422

  VerifiedType* = enum
    none = "None"
    blue = "Blue"
    business = "Business"
    government = "Government"

  User* = object
    id*: string
    username*: string
    fullname*: string
    location*: string
    website*: string
    bio*: string
    userPic*: string
    banner*: string
    pinnedTweet*: int64
    following*: int
    followers*: int
    tweets*: int
    likes*: int
    media*: int
    verifiedType*: VerifiedType
    affiliateBadgeName*: string
    affiliateBadgeUrl*: string
    affiliateBadgeTarget*: string
    affiliatesCount*: int
    protected*: bool
    suspended*: bool
    joinDate*: DateTime

  VideoType* = enum
    m3u8 = "application/x-mpegURL"
    mp4 = "video/mp4"
    vmap = "video/vmap"

  VideoVariant* = object
    contentType*: VideoType
    url*: string
    bitrate*: int
    resolution*: int

  Video* = object
    durationMs*: int
    url*: string
    thumb*: string
    available*: bool
    reason*: string
    title*: string
    description*: string
    playbackType*: VideoType
    variants*: seq[VideoVariant]

  QueryKind* = enum
    posts, replies, media, articles, highlights, affiliates, lists, users, tweets, userList

  FinchCollectionKind* = enum
    following = "following"
    localList = "list"

  AttentionEntityKind* = enum
    attentionAccount = "account"
    attentionDomain = "domain"

  AttentionSignalKind* = enum
    attentionMention = "mention"
    attentionRepost = "repost"
    attentionQuote = "quote"
    attentionLink = "link"

  SearchSort* = enum
    latest = "latest"
    top = "top"
    momentum = "momentum"

  SearchScope* = enum
    scopeAll = "all"
    scopeFollowing = "following"

  Query* = object
    kind*: QueryKind
    sort*: SearchSort
    scope*: SearchScope
    text*: string
    filters*: seq[string]
    includes*: seq[string]
    excludes*: seq[string]
    fromUser*: seq[string]
    toUser*: seq[string]
    mentions*: seq[string]
    since*: string
    until*: string
    minLikes*: string
    minRetweets*: string
    minReplies*: string
    sep*: string

  Gif* = object
    url*: string
    thumb*: string

  Photo* = object
    url*: string
    altText*: string

  GalleryPhoto* = object
    url*: string
    tweetId*: string
    color*: string

  PhotoRail* = seq[GalleryPhoto]

  Poll* = object
    options*: seq[string]
    values*: seq[int]
    votes*: int
    leader*: int
    status*: string

  CardKind* = enum
    amplify = "amplify"
    app = "app"
    appPlayer = "appplayer"
    player = "player"
    summary = "summary"
    summaryLarge = "summary_large_image"
    promoWebsite = "promo_website"
    promoVideo = "promo_video_website"
    promoVideoConvo = "promo_video_convo"
    promoImageConvo = "promo_image_convo"
    promoImageApp = "promo_image_app"
    storeLink = "direct_store_link_app"
    liveEvent = "live_event"
    broadcast = "broadcast"
    periscope = "periscope_broadcast"
    unified = "unified_card"
    moment = "moment"
    messageMe = "message_me"
    videoDirectMessage = "video_direct_message"
    imageDirectMessage = "image_direct_message"
    audiospace = "audiospace"
    newsletterPublication = "newsletter_publication"
    jobDetails = "job_details"
    hidden
    unknown

  Card* = object
    kind*: CardKind
    url*: string
    title*: string
    dest*: string
    text*: string
    image*: string
    video*: Option[Video]

  ArticleBlockKind* = enum
    paragraph = "paragraph"
    orderedListItem = "ordered_list_item"
    unorderedListItem = "unordered_list_item"
    image = "image"
    tweetEmbed = "tweet_embed"

  ArticleBlock* = object
    kind*: ArticleBlockKind
    text*: string
    photo*: Option[Photo]
    tweetId*: string

  Article* = object
    url*: string
    title*: string
    body*: string
    cover*: Option[Photo]
    photos*: seq[Photo]
    blocks*: seq[ArticleBlock]
    partial*: bool

  TweetStats* = object
    replies*: int
    retweets*: int
    likes*: int
    views*: int

  Tweet* = ref object
    id*: int64
    threadId*: int64
    replyId*: int64
    user*: User
    text*: string
    lang*: string
    time*: DateTime
    reply*: seq[string]
    hashtagCount*: int
    pinned*: bool
    hasThread*: bool
    available*: bool
    tombstone*: string
    location*: string
    # Unused, needed for backwards compat
    source*: string
    stats*: TweetStats
    retweet*: Option[Tweet]
    attribution*: Option[User]
    mediaTags*: seq[User]
    quote*: Option[Tweet]
    card*: Option[Card]
    poll*: Option[Poll]
    gif*: Option[Gif]
    video*: Option[Video]
    photos*: seq[Photo]
    articleUrl*: string
    article*: Option[Article]
    history*: seq[int64]
    note*: string

  CachedTweet* = object
    tweet*: Tweet
    cachedAt*: DateTime
    firstSeen*: DateTime

  Tweets* = seq[Tweet]

  Result*[T] = object
    content*: seq[T]
    top*, bottom*: string
    beginning*: bool
    query*: Query
    errorText*: string
    requestedCount*: int
    pagesFetched*: int
    pageBudget*: int
    budgetExhausted*: bool
    queryBuilt*: string

  Chain* = object
    content*: Tweets
    hasMore*: bool
    cursor*: string

  Conversation* = ref object
    tweet*: Tweet
    before*: Chain
    after*: Chain
    replies*: Result[Chain]

  EditHistory* = object
    latest*: Tweet
    history*: Tweets

  Timeline* = Result[Tweets]

  Profile* = object
    user*: User
    photoRail*: PhotoRail
    pinned*: Option[Tweet]
    tweets*: Timeline

  List* = object
    id*: string
    name*: string
    userId*: string
    username*: string
    description*: string
    members*: int
    subscribers*: int
    banner*: string

  MemberFilterPrefs* = object
    hideRetweets*: bool
    hideQuotes*: bool
    hideReplies*: bool

  FinchCollectionMember* = object
    collectionId*: string
    userId*: string
    username*: string
    fullname*: string
    avatar*: string
    verifiedType*: VerifiedType
    affiliateBadgeName*: string
    affiliateBadgeUrl*: string
    affiliateBadgeTarget*: string
    addedAtIso*: string
    filters*: MemberFilterPrefs

  FinchCollection* = object
    id*: string
    ownerId*: string
    slug*: string
    name*: string
    description*: string
    createdAtIso*: string
    updatedAtIso*: string
    kind*: FinchCollectionKind
    membersCount*: int
    previewMembers*: seq[FinchCollectionMember]
    xListId*: string      ## X list id when backed by native list
    xListOwner*: string  ## X user id of list owner

  AttentionEntity* = object
    key*: string
    label*: string
    title*: string
    subtitle*: string
    bio*: string
    avatar*: string
    verifiedType*: VerifiedType
    affiliateBadgeName*: string
    affiliateBadgeUrl*: string
    affiliateBadgeTarget*: string
    followers*: string
    followersCount*: int
    href*: string
    kind*: AttentionEntityKind
    touches*: int
    uniqueMembers*: int
    score*: int
    lastSeenLabel*: string
    lastSeenUnix*: int64
    memberSamples*: seq[FinchCollectionMember]
    sources*: seq[AttentionSource]

  AttentionSource* = object
    member*: FinchCollectionMember
    actorLabel*: string
    kind*: AttentionSignalKind
    reasons*: seq[AttentionSignalKind]
    href*: string

  FinchCollectionChoice* = object
    collection*: FinchCollection
    selected*: bool

  FinchProfileActions* = object
    hasIdentity*: bool
    followed*: bool
    collections*: seq[FinchCollectionChoice]
    referer*: string

  ProfileTabState* = object
    showArticles*: bool
    showHighlights*: bool
    showAffiliates*: bool

  GlobalObjects* = ref object
    tweets*: Table[string, Tweet]
    users*: Table[string, User]

  Config* = ref object
    address*: string
    port*: int
    useHttps*: bool
    httpMaxConns*: int
    title*: string
    hostname*: string
    staticDir*: string

    hmacKey*: string
    base64Media*: bool
    minTokens*: int
    enableRSSUserTweets*: bool
    enableRSSUserReplies*: bool
    enableRSSUserMedia*: bool
    enableRSSSearch*: bool
    enableRSSList*: bool
    enableAdmin*: bool
    enableDebug*: bool
    proxy*: string
    proxyAuth*: string
    apiProxy*: string
    disableTid*: bool
    maxConcurrentReqs*: int
    localDataPath*: string

    rssCacheTime*: int
    listCacheTime*: int

    redisHost*: string
    redisPort*: int
    redisConns*: int
    redisMaxConns*: int
    redisPassword*: string

  Rss* = object
    feed*, cursor*: string

proc contains*(thread: Chain; tweet: Tweet): bool =
  thread.content.anyIt(it.id == tweet.id)

proc add*(timeline: var seq[Tweets]; tweet: Tweet) =
  timeline.add @[tweet]
