# Still not done — full backlog

This list is everything from the audits that is **not** yet implemented. Search showing "temporarily unavailable" or "No items found" is usually because **X’s API is not returning valid JSON** (expired/bad session, rate limit, or auth failure). The app now shows a clearer message and handles user-search JNull the same as tweet search.

---

## Why search still fails for you

- **Session in `sessions.jsonl`** may be expired, invalid, or flagged. X often returns an HTML error page or non‑JSON body → we treat it as "search unavailable."
- **Single session** — with only 1 account, any rate limit or auth failure means no fallback.
- **B10 (auth_failed)** — the audits say the provided cookie session didn’t pass a real authenticated smoke test. You need a **fresh** `auth_token` and `ct0` from the browser and to put them in `sessions.jsonl`.

**What was changed just now:**  
- Tweet and user search both set a clear `errorText` when the API returns null/non‑JSON.  
- Message: *"Search couldn't complete. X may have rate-limited or rejected the request; check that your session in sessions.jsonl is valid and try again."*  
- So you get the same explanatory message on both Tweets and Users when the backend fails, instead of a generic "No items found."

---

## Backend / session / API (not done)

| ID | What | Where |
|----|------|--------|
| **B2** | Per-endpoint rate-limit reset: `setLimited` always uses 15 min fallback; some endpoints (e.g. search) can be 24h. Need a small map of endpoint → default reset. | `auth.nim`, `apiutils.nim` |
| **B3** | `finch_local` still JSON file, full rewrite on every save, no locking. Migrate to SQLite. | `local_data.nim` |
| **B4** | Audit `osproc` usage in `articles.nim` (security/stability if it shells out). | `articles.nim` |
| **B5** | Hot local timeline cache: cap added (100) but no periodic sweep of expired entries; TTL only checked on read. | `routes/local.nim` |
| **B6** | `requireIdentity` redirect drops POST body; after creating identity the action is lost. Would need session/Redis to replay. | `routes/local.nim` |
| **B7** | Tests not wired to build: no `make test` or nimble task to run Python tests. | repo root, `nitter.nimble` |
| **B8** | Example/dev configs: ensure `enableDebug` and `hmacKey` are not left on defaults in any committed config. | configs |
| **B10** | Session in repo may be `auth_failed`. Need a **working** session for real validation. | your `sessions.jsonl` |
| **R2** | `noCsrf` (353): treat as needs-reauth, not just rate limit. | `apiutils.nim` |
| **R3** | Rotate User-Agent from a small pool instead of single static value. | `apiutils.nim` |
| **R4** | TID: add bundled fallback `pair.json` so we don’t depend only on GitHub. | `tid.nim`, repo assets |
| **R5** | Same as B3 — SQLite for local data. | `local_data.nim` |
| **R8** | Hot cache: optional background sweep for expired entries. | `routes/local.nim` |
| **R9** | Exponential backoff on network errors (e.g. OSError) before failing. | `apiutils.nim` |
| **R10** | Send full cookie set (e.g. `guest_id`, etc.) where the API expects it. | `apiutils.nim`, session schema |

---

## UI / UX (not done)

| ID | What |
|----|------|
| **UI-2** | Skeleton/loading state while search/timeline loads (no blank flash). |
| **UI-3** | Mobile nav: breadcrumb still hidden at 780px; could show last segment only. |
| **UI-4** | Profile banner height (e.g. 180px) and `object-position` (already partly done; verify). |
| **UI-5** | Show-more radius fixed to 0; verify everywhere. |
| **UI-7** | Empty timeline: structured empty state with icon + contextual message (e.g. "No results — try different filters"). |
| **UI-10** | Home example chips configurable via `nitter.conf` instead of hardcoded. |
| **UI-14** | `aria-label` on icon-only nav actions for accessibility. |
| **UI-15** | Focus styles: ensure keyboard focus is visible (e.g. `:focus-visible` and fallback for older browsers). |

---

## Data / security / ops (not done)

| ID | What |
|----|------|
| **A1** | Pre-commit hook to block commits containing `auth_token` / `ct0`. |
| **A2** | Same as B3/R5 — SQLite. |
| **A3** | TID: timeout added; bundled fallback and Redis cache still not done. |
| **A6** | Startup warning when `hmacKey` is still the default. |
| **A7** | `following_scope`: distinguish "following list empty" vs "error" so UI can show the right message. |
| **A8** | Identity: server-side validation that identity key still exists in DB; clear cookie if orphaned. |
| **A9** | Incoming request rate limiting at Finch edge (e.g. per-IP, Nginx or middleware). |

---

## Summary

- **Search "temporarily unavailable" / "No items found"** when the API fails: we now return a single, explicit error message for both tweet and user search and set `errorText` for user search when the API returns JNull. **You still need a valid session** in `sessions.jsonl`; otherwise X will keep returning non‑JSON and you’ll see that message.
- **Everything else** in the table above is still open and should be tackled in the order that matters for your deployment (e.g. session/auth first, then SQLite, then UX/empty states).
