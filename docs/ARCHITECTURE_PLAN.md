# Finch Architecture Plan

## Goal

Turn the Nitter-derived codebase into a single coherent product with:

- one routing system
- one auth/session subsystem
- one upstream query execution subsystem
- one parser/model subsystem
- one rendering/export subsystem
- one private admin/control subsystem

## Intended Top-Level Modules

### `src/routes`

Responsibility:

- public HTML routes
- public RSS routes
- public machine output routes
- private admin and control routes

Notes:

- keep route grammar familiar to Nitter
- add explicit private namespace for non-public surfaces

### `src/auth`

Responsibility:

- session ingestion
- session pool
- health state
- invalidation
- concurrency control
- endpoint-aware rate-limit tracking

Rules:

- this becomes a first-class operational subsystem
- not just a helper file

### `src/upstream`

Responsibility:

- query ID discovery
- query ID refresh and cache
- upstream endpoint registry
- header generation
- request execution
- retry and fallback policy

Rules:

- no hardcoded permanent query-ID dependence
- explicit operation naming in logs and metrics

### `src/model`

Responsibility:

- canonical user model
- canonical post model
- canonical list model
- canonical article model
- canonical search result model

Rules:

- all outputs consume these models
- no separate UI-only and API-only models

### `src/parser`

Responsibility:

- translate upstream payloads into canonical models
- preserve rich structures where helpful
- normalize timestamps fully

Rules:

- no lossy “simplify now, regret later” parsing

### `src/render`

Responsibility:

- HTML rendering
- RSS rendering
- JSON rendering
- Markdown rendering
- text rendering

Rules:

- HTML can remain SSR-first and low-JS
- Markdown/text must be human-usable
- JSON must be stable and explicit

### `src/local`

Responsibility:

- local list objects
- saved search objects
- local metadata storage
- imports from X-native lists

Rules:

- this is where Finch becomes its own product

### `src/admin`

Responsibility:

- private-only admin screens and endpoints
- session diagnostics
- cache diagnostics
- fallback diagnostics
- import diagnostics

Rules:

- no public leakage of operational complexity

## Public Surface

Primary object families:

- profiles
- posts
- searches
- X-native lists
- local lists
- saved searches

Output modes:

- HTML
- RSS
- JSON
- Markdown
- text

## Private Surface

Private-only features:

- account/session health
- viewer/relationship data
- local list CRUD
- saved-search CRUD
- import tools
- operational diagnostics

## Technical Priorities

### Priority 1

Auth/session integrity.

### Priority 2

Canonical model quality.

### Priority 3

Search quality.

### Priority 4

Article quality.

### Priority 5

UI refinement.

## Things We Must Not Do

- keep permanent two-app architecture
- keep fake surfaces because they look impressive
- design around x.com/home
- let admin/private features pollute the public product
- allow renderers to drift away from canonical models

## Current Blocker

We need at least one working authenticated session for live smoke tests and battle tests.

Until then:

- architecture work proceeds
- repo restructuring proceeds
- route/model planning proceeds
- real upstream validation remains limited
