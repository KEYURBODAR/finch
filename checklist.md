# Finch Checklist

Last updated: 2026-03-15

This file is the execution checklist for stabilizing Finch.

Current verdict:
- Finch is **not** stable enough yet.
- Core theme/style is good enough.
- Main problems are backend/session handling, collection reliability, and a set of UI/interaction bugs.
- `Following` and `Lists` should be treated as the primary product surfaces.
- Global search should be treated as best-effort, not as the most trusted surface.

## Ground Rules

- Do not hide failures behind fake empty states.
- Do not break currently working paths while fixing adjacent ones.
- Prefer simpler behavior over clever behavior.
- Keep the current visual direction; improve clarity and density instead of redesigning.

## Phase 0 — Critical Stabilization

### Backend / sessions
- [x] Replace random session selection in `/Users/keyur/example/finch/src/auth.nim`
  - Current problem: `sessionPool.sample()` can repeatedly hammer the same session.
  - Direction: deterministic least-loaded or round-robin selection.
- [x] Remove global `session.limited` / `session.limitedAt` behavior in `/Users/keyur/example/finch/src/auth.nim` and `/Users/keyur/example/finch/src/types.nim`
  - Current problem: one endpoint failure can poison the whole session.
  - Direction: per-endpoint limit state only.
- [x] Stop treating empty cookie credentials as rate limits in `/Users/keyur/example/finch/src/apiutils.nim`
  - Current problem: bad credentials raise `RateLimitError`.
  - Direction: use a distinct invalid-session path and invalidate immediately.
- [x] Stop collapsing unrelated upstream failures into `RateLimitError` in `/Users/keyur/example/finch/src/apiutils.nim`
  - Separate:
    - invalid session
    - csrf/session refresh required
    - real endpoint rate limit
    - transient upstream error
    - parse failure
    - null/404-ish response
- [x] Handle `noCsrf` distinctly in `/Users/keyur/example/finch/src/apiutils.nim`
  - Current problem: it is treated like a generic auth/rate issue.
  - Direction: mark session invalid / needs refresh, do not back off like a rate limit.
- [x] Add bounded retry with backoff in `/Users/keyur/example/finch/src/apiutils.nim`
  - Current problem: the current `retry` template retries only once and too bluntly.
  - Direction: loop by session count, retry on transient errors, rotate sessions properly.
- [x] Percent-encode cookie values in `/Users/keyur/example/finch/src/apiutils.nim`
  - Current problem: cookie header is concatenated raw.
- [ ] Add timeout and connection reset strategy in `/Users/keyur/example/finch/src/http_pool.nim`
  - Current problem: pool behavior is too optimistic under upstream/network failure.

### Collection reliability
- [~] Make `Following` and local `Lists` partial-success by default in `/Users/keyur/example/finch/src/routes/local.nim`
  - Progress:
    - local collections no longer short-circuit through live `xListId` reads first
    - uncertain empty/error collection results are no longer cached
  - Remaining:
    - render partial live results with a visible non-fatal warning when some member fetches fail
    - ensure one/few member failures never feel like full-surface failure
- [x] Make collection failures more honest
  - Replace generic:
    - `Current collection surface is temporarily unavailable.`
  - With:
    - cached fallback if available
    - partial refresh warning if some members failed
    - hard failure only when nothing cached and nothing fresh succeeded
- [x] Stop over-trusting X list sync in `/Users/keyur/example/finch/src/x_lists.nim`
  - Local Finch Following/Lists no longer depend on placeholder X mutation sync in normal add/remove flows.
- [x] Audit direct X list reading in `/Users/keyur/example/finch/src/routes/list.nim`
  - Current problem: user-reported false rate limits and poor reliability on public X lists.
  - Verified actual fetch path, parser path, and live JSON/HTML behavior for public X lists.

### Error honesty
- [ ] Remove fake certainty from empty states in `/Users/keyur/example/finch/src/views/timeline.nim` and related routes
  - Current generic messages like `No items found` are not acceptable.
- [x] Replace generic `No items found` / coarse empty states on core surfaces
  - Search/list/following empty states now use softer, surface-specific wording.
- [ ] Replace the current top-level raw rate-limit page wording in `/Users/keyur/example/finch/src/nitter.nim`
  - Current problem: over-broad and often misleading.
  - Direction: use clearer service state copy.

## Phase 1 — Core Product Reliability

### Following / Lists as primary surfaces
- [x] Rebuild local collection logic around merged member timelines first, filtering second
  - Files:
    - `/Users/keyur/example/finch/src/routes/local.nim`
    - `/Users/keyur/example/finch/src/following_scope.nim`
  - X-backed Finch collections now prefer the backing `xListId` timeline path and apply local filtering on top.
  - Legacy collections without `xListId` still fall back to merged member timelines.
- [x] Make Finch local `Lists` / `Following` real X-backed synced collections
  - create/add/remove/delete now sync live to backing X lists
  - local read paths prefer the backing `xListId` timeline
- [x] Verify member-scoped filtering actually works
  - User-reported issue: list searches can still show wrong or empty results.
  - Fixed explicit-empty scope semantics (`member_scope_mode=explicit`) so `Clear` no longer silently reverts to all members.
- [ ] Ensure old pre-X-list local lists/following still behave correctly
  - Need migration/audit path for legacy `finch_local.json` owners/collections.
- [x] Add list deletion support
  - Delete now posts to the correct backend route and completes cleanly.
- [ ] Add multi-select removal support in Following
  - Current problem: only one-by-one removal exists.
- [ ] Add backend-backed reset actions
  - `cleanup everything / reset`
    - clear caches and temp state only
    - keep lists/following/recovery data
  - `delete everything`
    - full local reset
    - remove identity-owned following/lists data cleanly

### Replies handling
- [ ] Remove dedicated `Tweets & Replies` from the main product path
  - Current state: tab is partly removed in some surfaces but route support still exists.
  - Files:
    - `/Users/keyur/example/finch/src/routes/timeline.nim`
    - `/Users/keyur/example/finch/src/routes/rss.nim`
    - `/Users/keyur/example/finch/src/views/search.nim`
    - `/Users/keyur/example/finch/src/views/general.nim`
- [x] Keep replies only as an explicit filter
  - Default disabled.
  - Preference-controlled default exclusion is active on the current build.

## Phase 2 — UI / Interaction Fixes

### Inputs and controls
- [x] Fix date inputs in `/Users/keyur/example/finch/src/views/renderutils.nim` and related CSS
  - Restored native date input with a working calendar trigger while keeping direct typing available.
- [x] Fix `Select all / Clear` behavior for:
  - affiliate bulk panel
  - local member filter
  - any multi-select export UI added later
  - Files:
    - `/Users/keyur/example/finch/public/js/localActions.js`
    - `/Users/keyur/example/finch/src/views/local_ui.nim`
    - `/Users/keyur/example/finch/src/views/profile.nim`
- [x] Add bulk select/remove controls to collection member management
  - Lists/Following members now support `Select all`, `Clear`, and `Remove selected`.
- [ ] Disable infinite scroll by default
  - Current default in `/Users/keyur/example/finch/src/prefs_impl.nim` is `true`.
  - Direction:
    - default `false`
    - use `Load more`
    - append results progressively after click
- [x] Disable infinite scroll by default
- [ ] Remove `HTML` action from export/action bars for user-facing surfaces
  - Current problem: unnecessary noise.
  - Files:
    - `/Users/keyur/example/finch/src/views/profile.nim`
    - `/Users/keyur/example/finch/src/views/status.nim`
    - `/Users/keyur/example/finch/src/views/list.nim`
    - `/Users/keyur/example/finch/src/views/local_ui.nim`
    - `/Users/keyur/example/finch/src/views/search.nim`
- [x] Remove `HTML` action from user-facing export bars

### Identity row / badges / layout
- [ ] Fix badge links to stay inside Finch where Finch has a valid route
  - Current problem: affiliate badge can jump to `x.com`.
  - Direction:
    - if target is a profile, route to Finch profile
    - if target is an article/post/list that Finch can render, route to Finch equivalent
- [ ] Fix verified tick positioning and baseline
  - Current problem: visual alignment remains inconsistent.
- [ ] Fix affiliate badge rendering consistency
  - Current problem: some badges/logos do not display cleanly or at all.
- [ ] Tighten profile card density
  - Keep current style, reduce wasted space.
- [x] Add `Show bio / Hide bio` preference
  - Sidebar bio can now be hidden without changing the rest of the profile card.

### Surface messaging
- [ ] Replace generic `No items found`
  - Use surface-specific messages:
    - search
    - list
    - following
    - articles
    - highlights
    - affiliates
- [ ] Keep `Articles`, `Highlights`, `Affiliates` visible by default
  - No aggressive tab hiding.
  - Show honest empty/unavailable states instead.
- [x] Keep `Articles`, `Highlights`, and `Affiliates` visible by default

## Phase 3 — Articles, Links, and Exports

### Article rendering
- [ ] Improve article previews in timelines
- [x] Improve article previews in timelines
  - Current problem: often only plain article links are shown until post click.
  - Direction:
    - show title
    - show cover image if available
    - show short body excerpt if available
- [ ] Make internal X links route to Finch equivalents where possible
  - profiles
  - posts
  - articles
  - lists
- [ ] Audit article hydration and partial article behavior
  - Files:
    - `/Users/keyur/example/finch/src/articles.nim`
    - `/Users/keyur/example/finch/src/exporters.nim`
    - `/Users/keyur/example/finch/src/routes/status.nim`

### Exporting selected / last N posts
- [ ] Add export count input for:
  - individual profile
  - search
  - following
  - lists
- [x] Add export count input for:
  - individual profile
  - search
  - following
  - lists
- [x] Add manual post selection UI with checkbox on each post
  - minimal left-side checkbox
  - selection-aware export
- [x] Define export limits
  - Decide sane max for:
    - 50
    - 100
    - 200
    - 300
  - Implemented backend cap: `maxExportItems = 500` via route-level `limit` parameter.
- [x] Ensure exports respect active filters and member scope.

## Phase 4 — Backend Data Model and Storage

- [~] Harden local store writes in `/Users/keyur/example/finch/src/local_data.nim`
  - Progress:
    - `saveStore()` now writes to a temp file and swaps it into place atomically.
  - Remaining:
    - add real cross-process locking if we want stronger multi-user safety on shared hosts.
- [ ] Separate cache cleanup from owner data cleanup
  - Needed for `reset` vs `delete everything`.
- [x] Add backend reset/delete actions for Finch local data
  - `Cleanup caches` clears local timeline caches.
  - `Delete everything` clears Following/Lists for the current Finch key and forgets the key on this browser.
- [ ] Audit import/export correctness
  - Recovery key import
  - Finch bundle import
  - Finch bundle export
  - legacy data behavior
- [ ] Remove stray binaries, caches, temp files, and debug artifacts from runtime assumptions
  - This is repo/runtime hygiene, not product logic.
- [x] Remove major local build/debug junk from the project folder
  - `.nimcache-*`, extra binaries, screenshots, and temp/debug artifacts were cleaned out earlier in this pass.

## Phase 5 — Performance and Perceived Speed

- [ ] Keep route prefetch, but verify it does not overfetch under public multi-user usage
- [ ] Make local actions optimistic where safe
  - follow
  - add to list
  - remove member
  - create list
- [ ] Reduce overfetch on profile open
- [ ] Make cached repeat reads noticeably faster for:
  - profiles
  - following
  - lists
  - affiliates
- [ ] Prefer stale-while-refresh for hot surfaces
- [ ] Defer heavy media below the fold

## Phase 6 — Cleanup / DX / Security

- [ ] Tighten `.gitignore`
  - exclude build artifacts
  - exclude local DB/data/session files clearly
- [ ] Remove dead binaries and temp junk from repo folder
- [x] Tighten `.gitignore` for build/debug artifacts
- [x] Remove dead binaries, caches, and temp junk from the repo folder
- [ ] Audit `renderErrorHtml` usage in `/Users/keyur/example/finch/src/views/general.nim`
  - safe only for trusted hardcoded HTML
- [ ] Audit all `verbatim` render paths
  - bio/text/article rendering should stay safe
- [ ] Clean compiler warnings:
  - unused imports
  - deprecated `htmlparser` path
- [ ] Document real operational expectations in README
  - no hand-wavy “just works”
  - clear explanation of local vs public behavior

## Verified Findings

- [x] `public/css/style.css` is not zero bytes anymore.
- [x] `renderError` itself now escapes plain text; raw HTML rendering still exists separately in `renderErrorHtml`.
- [x] `auth.nim` previously used random session sampling and global `limited` / `limitedAt`; this is now patched in the current working tree.
- [x] Local Finch collections no longer try live `xListId` timeline reads before their own saved-member timeline merge.
- [x] Local Finch collections no longer cache uncertain empty/error timeline results.
- [x] `apiutils.nim` previously raised `RateLimitError` for empty cookie credentials; this is now patched in the current working tree.
- [x] `apiutils.nim` still uses a single static user-agent and static client hints.
- [x] `prefs_impl.nim` still enables infinite scroll by default.
- [x] `x_lists.nim` still states that mutation endpoint IDs are placeholders.
- [x] `views/timeline.nim` still has generic `No items found`.
- [x] `Following` / `Lists` still use fallback messaging that can be misleading or too coarse.
- [x] `HTML` action is still present across many surfaces.

## Open Questions To Verify During Fixing

- [ ] Does direct public X list reading become reliable after backend/session fixes, or is there a deeper list-specific request issue?
- [ ] Are old local lists/following entries fully compatible with the current direct-X-list additions?
- [ ] What is the highest safe export limit per surface without making UX or session load unacceptable?
- [ ] Which X links can be safely rewritten to Finch equivalents with full parity?

## Immediate Execution Order

1. Phase 0 backend/session stabilization
2. Phase 1 list/following reliability
3. Phase 2 UI/control fixes
4. Phase 3 exports/article/link routing
5. Phase 4 storage/reset/import-export hardening
6. Phase 5 speed improvements
7. Phase 6 cleanup/security/DX
