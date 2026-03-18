# Changes Applied (Audit Remediation)

Summary of fixes applied from the full audit and Claude's review.

---

## X-Native lists (full build)

- **apiutils.nim:** Added `fetchPost(endpoint, variables)` for X GraphQL POST (list mutations), using `getWriteSession()`, same headers as cookie GET, gzip/error handling, `release(session)` in finally.
- **x_lists.nim:** New module with `createXList`, `deleteXList`, `addMemberToXList`, `removeMemberFromXList` (calling `fetchPost` with consts from `consts.nim`). Response parsing supports common response shapes; mutation endpoint IDs in consts are **placeholders** — replace with real IDs from x.com DevTools (Network tab when creating a list / adding a member). Also `syncFollowingToX` and `syncListMemberToX` for route use.
- **Schema:** `StoredCollection` and `FinchCollection` now have `xListId` and `xListOwner` (default ""). `local_data.nim`: `setCollectionXListId(collectionId, xListId, xListOwner)`, `collectionToObject` and create/import paths updated.
- **Read path:** In `fetchCollectionTimeline`, when `collection.xListId.len > 0`, timeline is loaded via `getGraphListTweets(collection.xListId, cursor)` and returned; otherwise existing merged member-timeline logic runs.
- **Follow/unfollow and add/remove:** Follow, unfollow, add-to-list, and remove-from-list routes call the sync procs (which call X mutations when the collection has `xListId`). On first follow, if Following has no `xListId`, a new X list is created and linked, then the member is added.
- **Migration:** POST `/api/f/lists/:id/migrate` creates an X list, adds all current members (with pacing), and sets `xListId`/`xListOwner`. List timeline and members pages show a “Migrate to X list” banner when `xListId` is empty (list view only).
- **Views:** `renderMigrateBanner` in `local_ui.nim`; styles in `local.scss` for `.finch-migrate-banner`.

---

## Latest round (code bugs + backlog)

**Search and API:**
- **Response body trim** — In `apiutils.nim`, `fetch()` and `fetchRaw()` now strip the response body before checking for JSON. Responses with leading/trailing whitespace or BOM are no longer treated as non-JSON and returning JNull (fixes "Search results are temporarily unavailable" when the API actually returns valid JSON).
- **Referer header** — Added `Referer: https://x.com/` for cookie-session GraphQL requests so X is less likely to reject them.
- **Search response paths** — In `parser.nim`, `parseGraphSearch` now also tries `data.search.timeline.instructions` as a third fallback when the API uses a different shape.
- **Search error copy** — Message when search fails is now: "Search couldn't complete. Try again in a moment."

**Backoff and rate limits:**
- **Network retry** — In `apiutils.nim`, `fetch()` and `fetchRaw()` now catch `OSError`, apply the same backoff as `BadClientError`, and retry up to 3 times before failing.
- **Per-endpoint reset** — In `auth.nim`, `setLimited` now uses `defaultResetForEndpoint(api)` when no reset is passed, so 429s without headers get a sensible default (15 min for search/timeline) instead of a hardcoded value.

**UX and accessibility:**
- **Nav aria-label** — In `views/general.nim`, `renderNavAction` adds `aria-label=label` on the nav link for screen readers and touch.
- **Focus styles** — In `sass/index.scss`, added explicit `outline` for `a`, `button`, `input`, `select` on focus, and `:focus:not(:focus-visible)` to clear it for pointer users so keyboard focus remains visible.

**Build and tests:**
- **nimble test** — Added `task test, "Run Python tests"` to `nitter.nimble` so you can run `nimble test` (requires pytest and the `tests/` suite).

---

---

## 1. Theme preference removed

- **prefs_impl.nim:** Removed `theme(select, "Nitter")` from the Display pref list. Removed `or name == "theme"` from `genParsePrefs` and `genUpdatePrefs` (theme no longer exists).
- **nitter.conf / nitter.example.conf:** Removed `theme = "Nitter"` from `[Preferences]`.
- **public/css/themes/:** Deleted all 9 theme CSS files (auto, black, dracula, mastodon, nitter, pleroma, twitter, twitter_dark, etc.).
- **general.nim:** Left `data-theme="dark"` hardcoded on `<html>` (no change).

---

## 2. Critical bugs (your 4 issues)

- **BUG 1 – User search / single result:** In **api.nim**, `getGraphUserSearch` now has a fast path: when there is no cursor and the query looks like a single username (alphanumeric + `_`, length ≤ 15), it calls `getGraphUser(rawQuery)` and returns that user directly instead of relying only on People search.
- **BUG 2 – 15–20+ accounts:** In **routes/local.nim**, `splitLocalUsernames` default cap raised from `maxUsers=15` to `maxUsers=50`.
- **BUG 3 – Load more / pagination:** In **routes/timeline.nim**, when `scroll` is set and the profile timeline is empty, response changed from `Http404` to `Http204` so infinite scroll treats it as “no more items” instead of an error.
- **BUG 4 – General search no results:** In **prefs_impl.nim**, default for `excludeRepliesByDefault` changed from `true` to `false` so search and feeds are not over-filtered by default.

---

## 3. Backend / config / cookies

- **auth.nim:** Session score formula fixed (B1): removed `result += min(session.totalRequests, 500)` so we no longer penalize high-usage sessions; score is now `pending * 1000 - min(idleSeconds, 300)`.
- **config.nim:** Default `localDataPath` changed from `"./finch_local.db"` to `"./finch_local.json"` to match actual JSON storage.
- **router_utils.nim:** Prefs cookie `sameSite`: when `cfg.useHttps` is false, use `SameSite.Lax` instead of `SameSite.None` so cookies work over HTTP. Added `setCookie, SameSite` to jester import.
- **nitter.nim:** InternalError handler no longer interpolates `error.exc.msg` into the HTML response (XSS risk removed); message is fixed. `renderError` still uses `verbatim` for messages that contain safe HTML (e.g. rate limit message with link).
- **nitter.conf:** `enableDebug` set to `false`.
- **.gitignore:** Added `sessions.jsonl`, `finch_local.json`, `finch_local.db`, and `.nimcache*/` so credentials and build artifacts are not committed.

---

## 4. Tid, hot cache, avatar URLs

- **tid.nim:** `newAsyncHttpClient(timeout = 5000)` and fetch wrapped in `try/except`; on failure we keep using stale cache; if cache is empty we raise instead of sampling empty list.
- **routes/local.nim:** Hot local timeline cache capped at `hotLocalTimelineMaxEntries = 100`; when at capacity we evict the entry with the oldest `expiresAt` before inserting.
- **local_data.nim:** Added `normalizeAvatarUrl(url)` that prefixes relative avatar paths with `https://pbs.twimg.com/`. Used in `collectionToObject` (preview members) and `memberToObject` so stored relative avatars render correctly.

---

## 5. UI (SCSS + views)

- **Error panel:** In **sass/include/_variables.scss**, `$error_red` changed from `#420a05` to `#7f1d1d`. In **sass/general.scss**, `.error-panel` given `border: 1px solid #ef4444` for visibility on dark background.
- **Show more button:** In **sass/timeline.scss**, `.show-more a` `border-radius` changed from `var(--radius-full)` to `0` to match the sharp design system.
- **Mobile nav:** In **sass/navbar.scss**, at 780px we now hide `.nav-action-label` and keep `.nav-action-icon` (icons only on mobile).
- **Tweet hover:** In **sass/tweet/_base.scss**, `.tweet-link` given `transition: background-color var(--transition-fast)`.
- **Identity modal backdrop:** In **sass/local.scss**, `.finch-identity-modal` background changed from `rgba(9, 9, 11, 0.82)` to `color-mix(in srgb, var(--background) 82%, transparent)`.
- **Empty collection card:** In **sass/local.scss**, added `.finch-collection-card-empty` (muted, italic). In **views/local_ui.nim**, when `collection.previewMembers.len == 0` we render `span(class="finch-collection-card-empty"): text "No members yet"`.

---

## Not done (deferred)

- **SQLite migration** for `finch_local` (B3/A2): still JSON file; migration is a larger change.
- **Per-endpoint reset map** for `setLimited` (B2): still using 15‑min default when headers lack reset.
- **requireIdentity POST state** (B6): redirect still loses POST; replay would need session/Redis.
- **Tests wired to build** (B7): no `make test` or nimble test task added.
- **Bundled TID fallback:** tid.nim still only uses GitHub; no bundled `pair.json` in repo.
- **User-Agent rotation, exponential backoff, request rate limiting at edge:** not implemented.
- **Home example chips configurable** from `nitter.conf`: chips remain hardcoded in views.

---

## Rebuild CSS after pulling

SCSS was updated; regenerate compiled CSS:

```bash
nimble scss
```

Or:

```bash
nim r --hint[Processing]:off tools/gencss
```

Then reload the app and test search, 15+ accounts, load more, and the UI tweaks above.
