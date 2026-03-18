# Finch Phase 0 Inventory

## Status

Finch is currently a forked working tree created from the Nitter source zip.

Reference code for comparison lives in:

- `../finch_work/xscrape`

## Immediate Finding

The provided cookie session does not currently pass a real authenticated smoke test through the unofficial API code. Current result:

- `auth_failed`

This means session-sensitive battle testing is blocked until we get a working account session.

It does **not** block repository restructuring, architecture work, route planning, or most of the integration work.

## What We Are Keeping From Nitter

### Product-facing strengths

- route grammar
- profile/post/search/list URL structure
- HTML rendering model
- RSS routes and general feed approach
- preference and formatting model

### Internal strengths

- richer domain types for users, tweets, cards, media, polls, lists
- session pool concepts
- per-endpoint rate-limit tracking
- bounded concurrency ideas
- Redis-backed caching hooks
- query-building concepts

## What We Are Porting From The Unofficial API Work

- dynamic query ID discovery
- article scraping and article resolution
- stronger search-builder ideas
- admin and capacity visibility concepts
- some fallback strategy ideas, but only where clearly labeled

## What We Are Replacing

### Nitter weaknesses to replace

- hardcoded GraphQL query IDs
- weak article handling
- any stale parser logic that no longer matches current X payloads

### Unofficial API weaknesses to replace

- simplistic token rotation logic
- day-only date normalization
- lossy parsed tweet model
- fake or approximation-heavy endpoint claims
- machine outputs that are just raw dumps

## What We Are Removing Or Downgrading

Unless rebuilt properly, the following should not survive as headline features:

- fake notifications
- fake verified notifications
- config-backed webhook rules
- config-backed stream monitor surfaces
- fake WOEID trends
- topic feeds that are just search aliases
- broad-search fallbacks mislabeled as real feeds

## Locked Product Decisions

- temporary name: `Finch`
- separate product, not xrss
- search-first homepage
- bookmarks: no
- communities: no
- followers/following: yes, secondary
- viewer/relationship data: yes, private-only
- write-back to X lists: not core
- UI: redesigned, but still simple and fast
- hosting: local first, then plain VPS
- private admin: single-user for now

## Core Product Objects

The product will be built around:

- profiles
- posts
- searches
- lists
- articles

Secondary/private objects:

- viewer/account state
- relationship state
- local lists
- saved searches

## Phase 0 Exit Criteria

Phase 0 is complete when:

- base repository choice is final
- keep/port/replace/remove inventory is explicit
- repo restructuring plan is written
- session test state is known
- no architectural ambiguity remains
