# Finch Phased Ship Plan

## Why This Exists

We have enough working code now that "the whole final vision" is too loose to use as the daily execution model.

This file breaks Finch into discrete ship phases with:

- a clear purpose
- a bounded scope
- a definition of done
- a current status

This is the operating plan from here.

## Current Overall State

Estimated total shipped versus the full proposal:

- overall: 20-25%
- foundation/runtime: 85%
- public read exports: 60%
- public feature completeness: 15%
- UI/product surface: 20%
- engine modernization: 10-15%
- admin/observability: 25%
- production readiness: 10%

## Phase 1: Foundation

### Purpose

Make Finch a real local working product instead of a proposal.

### Scope

- extract and stand up the codebase locally
- make Finch build
- make Finch boot
- restore broken asset generation
- verify one working authenticated session
- add initial private runtime endpoints

### Done

- Finch runs locally on `127.0.0.1:8080`
- CSS and markdown assets build correctly
- Redis runtime works
- authenticated upstream fetch works
- private runtime endpoints exist

### Status

Shipped.

## Phase 2: Public Export Surface

### Purpose

Turn Finch into a machine-usable read product, not only an HTML clone.

### Scope

- compact `json` / `md` / `txt` for post pages
- compact `json` / `md` / `txt` for search
- compact `json` / `md` / `txt` for profiles
- compact `json` / `md` / `txt` for lists
- compact `json` / `md` / `txt` for list members
- remove replies from export payloads
- reduce duplicated JSON payloads

### Done

- post export routes work
- search export routes work
- profile export routes work
- list export routes work
- list member export routes work
- replies are not included in export payloads
- repeated author payloads are normalized into top-level `users`

### Status

Shipped, but still needs schema cleanup during later phases.

## Phase 3: Output Contract Hardening

### Purpose

Make exported Finch responses stable, predictable, and intentionally designed.

### Scope

- audit every JSON surface for field consistency
- standardize naming across status/search/profile/list outputs
- remove remaining legacy/Nitter-shaped weirdness
- define route semantics clearly:
  - status
  - profile
  - search
  - list
  - list members
- make machine outputs feel like one product, not several ad hoc serializers

### Definition of Done

- every export surface follows the same style rules
- field names are consistent
- no accidental legacy payload baggage
- no route returns unexpectedly shaped JSON
- markdown/text outputs follow consistent section structure

### Status

Current phase.

## Phase 4: Public Feature Completion

### Purpose

Finish the actual Finch public product surface that was part of the proposal, not just the raw export layer.

### Scope

- article support
- article extraction/rendering/export where possible
- stronger list experience as a real public feature
- UI for every public feature we add
- search UI refinements for new public capabilities
- post/profile/list/search route completeness
- output affordances in the UI where appropriate
- close major gaps between "route exists" and "feature feels real"

### Important Rule

If a feature is public-facing and part of the Finch product, it should not exist only as a backend route.

That means:

- list features need UI
- article features need UI
- new public search/list/post/profile capabilities need UI
- only private/admin/dev functionality is allowed to remain UI-less

### Definition of Done

- articles are handled intentionally instead of silently degrading
- lists feel like first-class Finch features
- public features that exist in backend also exist in UI
- product-level gaps are reduced substantially

### Status

Pending.

## Phase 5: Engine Hardening

### Purpose

Stop relying on fragile inherited behavior and make Finch materially more stable than stock Nitter.

### Scope

- session pool improvements
- request budgeting and rate-limit awareness
- better search/list failure handling
- clearer upstream execution boundaries
- reduce dependence on opaque inherited code paths
- begin separating canonical Finch export logic from Nitter internals

### Definition of Done

- repeated testing does not collapse quickly under one or two search/list calls
- private health reflects meaningful session/runtime state
- upstream failure modes are cleaner
- exported routes fail more predictably and recover better

### Status

Pending.

## Phase 6: Finch Data Core

### Purpose

Replace inherited Nitter assumptions with Finch-owned data contracts and execution logic.

### Scope

- canonical Finch post model
- canonical Finch profile model
- canonical Finch list model
- canonical Finch search result model
- begin query-id modernization strategy
- start absorbing the useful parts of `x-api-ship` carefully

### Definition of Done

- Finch outputs are driven by clearly owned internal models
- route behavior is no longer tightly coupled to Nitter-only assumptions
- data flow is easier to reason about and extend

### Status

Pending.

## Phase 7: Product Surface Refinement

### Purpose

Make Finch feel like a finished product without bloating it.

### Scope

- refine homepage
- refine profile/search/post/list UI
- refine article UI
- preserve Nitter simplicity
- remove remaining visible Nitter identity leaks
- improve navigation and public product coherence

### Definition of Done

- UI feels intentionally Finch
- UI stays light, clear, fast, and minimal
- public product surfaces look coherent

### Status

Pending.

## Phase 8: Private Admin Surface

### Purpose

Turn private runtime/admin into an actual operating surface instead of raw debug JSON only.

### Scope

- session health page
- request/rate-limit visibility
- cache/runtime visibility
- clearer diagnostics

### Definition of Done

- admin is usable without reading raw JSON blobs
- runtime problems are visible quickly

### Status

Pending.

## Phase 9: Productionization

### Purpose

Prepare Finch for real deployment and sustained operation.

### Scope

- production config cleanup
- deployment scripts
- service/restart strategy
- persistent runtime decisions
- operational notes
- battle testing with more than one session

### Definition of Done

- Finch can be deployed cleanly
- failures are understandable
- runtime behavior is predictable

### Status

Pending.

## What Is Already Shipped Right Now

- local Finch repo and runtime
- working authenticated session
- asset pipeline fixed
- private admin JSON endpoints
- lightweight Finch homepage instead of raw stock root
- post exports
- search exports
- profile exports
- list exports
- list members exports
- no replies in export payloads
- normalized user dedup in JSON

## What We Should Do Next

Immediate execution target:

- Phase 3: Output Contract Hardening

Reason:

- it is the cleanest next unit of work
- it improves every shipped export surface
- it avoids UI thrash
- it avoids jumping too early into deep engine rewrites

## Important Missing Areas That Are Not Yet Shipped

These are explicitly part of Finch scope and must not be forgotten:

- article handling
- article rendering and export strategy
- stronger public list UI
- public UI for new features, not only backend routes
- deeper search capability improvements
- better public product completeness beyond raw route availability

## Rule For Future Work

We ship phases in order.

We do not mix:

- major UI redesign
- deep engine work
- schema cleanup
- deployment hardening

inside the same phase unless there is a direct blocker.
