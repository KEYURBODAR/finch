# Finch Full Audit & Remediation Proposal

**Scope:** `example/finch` (Nitter fork with custom UI and new features)  
**Focus:** Backend, cookies/sessions, UI bugs, errors, and inconsistencies.

---

## 1. Executive Summary

Finch is a Nim/Jester app that proxies X (Twitter) via a session pool (OAuth or cookie-based), with server-rendered Karax HTML, Redis cache, and local identity/collections (Following, Lists) stored in a JSON file. The audit found issues in **theme/prefs application**, **cookie and session handling**, **error display safety**, **config/docs alignment**, **session invalidation**, and **route/UI edge cases**. The proposal below orders fixes by impact and dependency.

---

## 2. Tech Stack (Reference)

| Layer        | Technology |
|-------------|------------|
| Language    | Nim 2.x    |
| Server      | Jester     |
| Frontend    | Karax (server-rendered HTML) |
| Cache       | Redis      |
| Config      | INI-style `nitter.conf` |
| X auth      | Session pool from `sessions.jsonl` (OAuth or cookie) |
| Local data  | JSON file (`localDataPath`) |

---

## 3. Findings by Area

### 3.1 UI / Theme & Preferences

| Id | Finding | Location | Severity |
|----|---------|----------|----------|
| **U1** | **Theme preference ignored** — `data-theme` is hardcoded to `"dark"` on `<html>`, so the user’s theme preference (e.g. "Nitter") is never applied. Prefs define `theme(select, "Nitter")` but the layout doesn’t use it. | `src/views/general.nim` ~213 | High |
| **U2** | Theme is not exposed in the Settings UI — Preferences view has no theme selector, so users cannot change theme even if the backend respected it. | `src/views/preferences.nim` | Medium |
| **U3** | `genApplyPrefs` in the `before` filter runs without `cfg` in the template’s view; `savePref` needs `cfg` for `secure=cfg.useHttps`. This works only because `applyUrlPrefs` is invoked from the main `routes` block where `cfg` is in scope. If refactored, this could break. | `src/routes/router_utils.nim`, `nitter.nim` before filter | Low |

**Recommendation (U1–U2):**  
- In `general.nim`, set `data-theme` (or a class) from `prefs.theme` (with a safe default, e.g. `"dark"`).  
- Ensure CSS uses `[data-theme="..."]` (or a class) for theme-specific rules.  
- Add a theme control (e.g. select) to the preferences view and wire it to the existing `theme` pref.

---

### 3.2 Cookies & Session (Backend ↔ X)

| Id | Finding | Location | Severity |
|----|---------|----------|----------|
| **C1** | **Prefs cookie `sameSite=None`** — `savePref` uses `sameSite=None`, which requires `Secure`. If the app is ever served over HTTP (e.g. `https = false`), those cookies may not be set or sent in some browsers. | `src/routes/router_utils.nim` | Medium |
| **C2** | **Session invalidation is in-memory only** — `invalidate()` in `auth.nim` removes a session from `sessionPool` but does not persist that to `sessions.jsonl`. After restart, invalidated sessions reappear. Comment in code: “TODO: This isn’t sufficient, but it works for now”. | `src/auth.nim` ~156 | Medium |
| **C3** | Cookie header building does not percent-encode values — `getCookieHeader` concatenates raw `session.authToken`, `session.ct0`, etc. If any value contained `;` or `=`, it could break the Cookie header or be misparsed. | `src/apiutils.nim` `getCookieHeader` | Low |
| **C4** | Empty cookie credentials raise `rateLimitError()` — When `authToken` or `ct0` is empty, the code raises rate limit error. Semantically this is “bad/invalid session”; using rate limit can confuse logging and retry logic. | `src/apiutils.nim` `getAndValidateSession` | Low |

**Recommendation (C1):**  
- When `cfg.useHttps` is false, use `sameSite=Lax` (or `Strict`) for preference cookies so they work over HTTP.  

**Recommendation (C2):**  
- Either: (a) persist invalidations (e.g. remove or mark line in `sessions.jsonl`), or (b) document that invalidation is process-lifecycle only and that restart brings sessions back.  

**Recommendation (C3–C4):**  
- Optionally percent-encode cookie value parts; treat empty cookie credentials as `BadClientError` (or a dedicated “invalid session”) and invalidate the session instead of overloading rate limit.

---

### 3.3 Backend Logic & Config

| Id | Finding | Location | Severity |
|----|---------|----------|----------|
| **B1** | **`localDataPath` default mismatch** — `config.nim` default is `"./finch_local.db"`; `nitter.example.conf` uses `"./finch_local.json"`. The store is JSON (`local_data.nim` uses `toJson`/`fromJson`). Using `.db` is misleading and can cause operators to expect a different format. | `src/config.nim`, `nitter.example.conf` | Medium |
| **B2** | **App will not start without `sessions.jsonl`** — `initSessionPool` calls `quit(1)` if the file is missing. No fallback or clear message for “run a setup step first”. | `src/auth.nim` | Medium |
| **B3** | Broad `except` in experimental code — e.g. `experimental/types/graphuser.nim` uses bare `except:`; `http_pool.nim` uses `except: discard` when closing client. This can hide real errors. | Multiple under `experimental/`, `http_pool.nim` | Low |
| **B4** | `fetchImpl` proxy URL replacement is naive — `($url).replace("https://", apiProxy)` only replaces the first occurrence and doesn’t handle all URL forms. | `src/apiutils.nim` | Low |

**Recommendation (B1):**  
- Change default in `config.nim` to `"./finch_local.json"` and align example config and docs.  

**Recommendation (B2):**  
- Improve error message (e.g. “Create sessions.jsonl with at least one session; see README”) and consider exiting with a distinct code or doc link.  

**Recommendation (B3–B4):**  
- Narrow exception handling to specific types where possible; fix or document proxy URL handling.

---

### 3.4 Error Handling & Security

| Id | Finding | Location | Severity |
|----|---------|----------|----------|
| **E1** | **Error messages rendered as raw HTML** — `renderError` uses `verbatim error`, so the string is injected unescaped. If `error` ever comes from exception messages or user-influenced input, this is an XSS vector. Currently many call sites use fixed strings; `InternalError` uses `error.exc.msg`. | `src/views/general.nim` `renderError`, `nitter.nim` error handlers | High |
| **E2** | Generic error copy for BadClientError — “Network error occurred, please try again.” is shown for both CSRF and network/OS errors, which can hinder debugging and user guidance. | `nitter.nim` error BadClientError | Low |

**Recommendation (E1):**  
- Escape error content before rendering (e.g. HTML-escape or use a text node instead of `verbatim` so the template engine escapes it). Ensure exception messages are not directly interpolated into HTML without escaping.  

**Recommendation (E2):**  
- Optionally differentiate CSRF vs network errors and show a short, safe message per case.

---

### 3.5 Local / Identity & Routes

| Id | Finding | Location | Severity |
|----|---------|----------|----------|
| **L1** | Duplicate identity cookie logic — `local.nim` and `local_identity.nim` both define `finchIdentityCookie` / `finchIdentitySkipCookie` and similar cookie setters (`rememberIdentity` vs `saveFinchIdentity`, etc.). Logic is duplicated and could drift. | `src/routes/local.nim`, `src/local_identity.nim` | Medium |
| **L2** | Route handler order in `/f/lists/@id/members/@fmt` — Members and 404 check order is suboptimal: members are computed even when `collection.id.len == 0`; the `else: resp Http404` in the `case @"fmt"` is dead because of the route `cond`. | `src/routes/local.nim` | Low |
| **L3** | Preferences form and identity import — The settings page has nested forms (main prefs form and identity import / bundle import). Ensure `referer` and action URLs are correct and that duplicate submit targets don’t cause confusion. | `src/views/preferences.nim` | Low |

**Recommendation (L1):**  
- Centralize cookie names and identity cookie helpers in `local_identity.nim` and have `local.nim` call them instead of redefining.  

**Recommendation (L2):**  
- Check `collection.id.len == 0` first and return 404 before computing members; remove dead `else` branch if desired.

---

### 3.6 Docs & Repo State

| Id | Finding | Location | Severity |
|----|---------|----------|----------|
| **D1** | PHASE0_INVENTORY states that the provided cookie session fails authenticated smoke test (`auth_failed`), so full battle testing is blocked until there is a working X session. | `docs/PHASE0_INVENTORY.md` | Info |
| **D2** | ARCHITECTURE_PLAN describes an “upstream” and “model” layout that doesn’t fully match current `api.nim` / `apiutils.nim` and `experimental/` structure — useful as target, but current code paths should be documented. | `docs/ARCHITECTURE_PLAN.md` | Info |

---

## 4. Prioritized Remediation Proposal

### Phase A — Quick wins (no new features)

1. **Theme (U1)**  
   - In `general.nim`, set `data-theme` (or class) from `prefs.theme` with fallback `"dark"`.  
   - Confirm CSS supports that attribute/class.

2. **Error XSS (E1)**  
   - In `renderError`, stop using `verbatim` for the message; escape HTML or render as plain text (e.g. so that `error.exc.msg` cannot inject script).

3. **Config default (B1)**  
   - Set `localDataPath` default to `"./finch_local.json"` in `config.nim` and align example config and README.

4. **Prefs over HTTP (C1)**  
   - When `useHttps` is false, set prefs cookies with `sameSite=Lax` (or `Strict`) instead of `None`.

### Phase B — Session & cookie robustness

5. **Session invalidation (C2)**  
   - Document current behavior and add a short comment in code; optionally add a “persist invalidation” path (e.g. rewrite `sessions.jsonl` or a sidecar blocklist).

6. **Cookie encoding (C3)**  
   - In `getCookieHeader`, percent-encode cookie values (or at least `;`, `=`, and control chars) so header parsing is safe.

7. **Identity cookie centralization (L1)**  
   - Keep a single definition of cookie names and setters in `local_identity.nim`; use them from `local.nim` and remove duplication.

### Phase C — UX and clarity

8. **Theme in Settings (U2)**  
   - Add a theme dropdown/select in the preferences view and wire it to the existing `theme` pref.

9. **Session file error (B2)**  
   - Improve message and exit behavior when `sessions.jsonl` is missing (e.g. point to README or setup script).

10. **Local route order (L2)**  
    - In `/f/lists/@id/members/@fmt`, check `collection.id.len == 0` first and return 404 before computing members; clean up dead branch.

### Phase D — Optional hardening

11. **Empty cookie session (C4)**  
    - Treat empty `authToken`/`ct0` as bad session (e.g. invalidate and raise `BadClientError` or a dedicated type) instead of `rateLimitError`.

12. **Exception handling (B3)**  
    - Replace bare `except` with specific exception types where possible; avoid `discard` for unexpected errors.

13. **Error copy (E2)**  
    - Differentiate CSRF vs network in BadClientError handler with safe, short messages.

14. **applyUrlPrefs / cfg (U3)**  
    - Add a short comment that `cfg` must be in scope where `applyUrlPrefs` is used; consider passing `cfg` explicitly if you refactor the before filter.

---

## 5. Summary Table

| Category     | High | Medium | Low | Info |
|-------------|------|--------|-----|------|
| UI/Theme    | 1    | 2      | 0   | 0    |
| Cookies/Session | 0 | 2 | 2 | 0 |
| Backend/Config | 0 | 2 | 2 | 0 |
| Errors/Security | 1 | 0 | 1 | 0 |
| Local/Routes | 0 | 1 | 2 | 0 |
| Docs        | 0    | 0      | 0   | 2    |

**Suggested order of work:** A1 → A2 → A3 → A4, then B5–B7, then C8–C10, then D11–D14 as capacity allows. This addresses the single high-severity UI bug (theme), the high-severity security concern (error XSS), and the most impactful config and cookie issues before refining session behavior and UX.

---

## 6. Files to Touch (Checklist)

| Change | File(s) |
|--------|--------|
| Theme from prefs | `src/views/general.nim` |
| Escape error in renderError | `src/views/general.nim` |
| localDataPath default | `src/config.nim`, `nitter.example.conf` |
| sameSite when !https | `src/routes/router_utils.nim` |
| Session invalidation comment/docs | `src/auth.nim`, README or docs |
| getCookieHeader encoding | `src/apiutils.nim` |
| Identity cookie centralization | `src/local_identity.nim`, `src/routes/local.nim` |
| Theme control in Settings | `src/views/preferences.nim`, prefs_impl if needed |
| sessions.jsonl error message | `src/auth.nim` |
| Local route 404 order | `src/routes/local.nim` |

If you want, the next step can be concrete patches for Phase A (theme, error escaping, config default, sameSite) in the listed files.
