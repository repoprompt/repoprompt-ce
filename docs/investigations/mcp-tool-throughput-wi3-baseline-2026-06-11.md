# MCP tool throughput WI-3 baseline — 2026-06-11

## Scope and provenance

This is the Phase 0 / WI-3 baseline for the five WI-2 workload matrices. It records the current scheduling topology and deterministic work counts before any Phase 1 optimization.

- Checkout commit: `6f8fcbb` (`main`), with the shared WI-1/WI-2 working tree changes present.
- Build: DEBUG SwiftPM macOS app target.
- Capture surfaces: `mcp_read_search_runtime_snapshot`, the WI-2 correlated request timeline, and the DEBUG WI-3 work-count histories.
- Live CE app status at capture: not running. No app was launched or relaunched, so live wall-clock median/P95 and end-to-end transport samples are deferred rather than inferred.
- Validation fixtures are temporary local Git repositories and temporary workspace roots; no network or provider credentials are involved.

## Current admission and ownership baseline

| Resource | Current behavior |
|---|---|
| Per-connection ordinary MCP lane | Capacity 1; ordinary calls are FIFO/serialized. |
| Per-connection `file_search` lane | Capacity 4, separate from the ordinary lane. |
| Per-store search lane | Capacity 4; shared by connections targeting the same window/store. |
| Window ownership | Each window owns its own store, search service, projection, crawl, watcher, and freshness-flight state. |
| Git execution | One `/usr/bin/git` process per command; no process queue, so recorded process-queue wait is currently zero. |
| `read_file` content reuse | No interactive decoded-content cache; successful reads report `cache_hit=false` and read/decode the full file before returning a range. |

## WI-2 workload matrices

These rows are the reproducible pre-optimization baseline. Live latency columns remain deferred until a CE debug app is already running; the work-count and concurrency expectations are enforced by source/runtime guard tests.

| Matrix | Baseline concurrency/duplication | Expected diagnostic signature | Live latency |
|---|---|---|---|
| Same connection, ordinary burst | One active ordinary request; remaining requests queue FIFO on that connection. | `ordinary.limit=1`; permit queue/acquire/release events share the request identity; no ordinary overlap. | Deferred — no running app. |
| Same connection, mixed ordinary/search | Up to one ordinary request and four `file_search` requests can be admitted independently. | Separate `ordinary` and `file_search` limiter timelines; store search lane caps active search leases at four. | Deferred — no running app. |
| Distinct connections, one window | Each connection has its own 1+4 limiter, while all searches converge on one window/store search lane of four. | Distinct connection identities; one window ID/store; aggregate store admission remains four. | Deferred — no running app. |
| Distinct windows on one physical root | Each window independently crawls, watches, indexes, invalidates, and runs freshness flights for the same root. | `physical_root_duplication` reports `window_count=N`, watcher count up to N, cumulative crawl count at least N, and per-window freshness-flight counters. | Deferred — no running app. |
| Short versus long Agent Mode transcript | Tool admission is unchanged, but observer correlation reports scanned-item counts and callback durations, exposing transcript-length-dependent permit-held work. | Same request identity across provider, observer, result, terminal barrier, encode, write, and proxy commit; compare observer scan/duration fields between transcript sizes. | Deferred — no provider-backed running app. |

## Deterministic Git process-count baseline

Fixture: one repository on `main`, no upstream, one modified tracked file, and one untracked file (`U=1`). Counts include every Git process executed inside one captured invocation.

| Operation | Current command count | Assertion |
|---|---:|---|
| Warm status prelude (`branch` + upstream probe + porcelain status) | 3 | Exact |
| Uncommitted summary diff inputs | 6 | Exact |
| Quick artifact publication | 7 | Exact |
| Standard artifact publication | 15 (`14+U`) | Exact |
| Deep artifact publication | 15 (`14+U`) | Exact |

The standard/deep count is intentionally redundant: six commands build summary inputs, `7+U` build full inputs, and one builds the commit graph. WI-5/WI-9 are expected to update these assertions deliberately.

## Invalidation, rebuild, freshness, and duplication baseline

The DEBUG runtime snapshot now records current behavior without narrowing invalidation or changing rebuild policy:

- Typed catalog invalidations: reason, affected root IDs/kinds, and exact cached scopes evicted.
- Catalog rebuild totals: filter, sort, materialization, total duration, roots, and files.
- Search rebuild totals: ordering, path-map materialization, C-index build, debounce cancellations, and stale discarded completions.
- UI projection index rebuild totals: duration, traversal duration, and visited folder/file counts.
- Freshness: flush calls, no-op flushes, debounce cancellations, watcher batch counts/sizes, joins, pending successors, coalesced successors, and per-root wait totals/maxima.
- Cross-window duplication: physical root, window IDs/count, root kinds, watchers, crawls, current freshness flights, and cumulative freshness-flight launches.

Current invalidation remains deliberately global for WI-3: a topology invalidation clears every cached search-catalog scope and the full path-match cache. Selective eviction and duplicate-clear removal remain Phase 1 / WI-4 work.

## `read_file` work baseline

The DEBUG invocation history records source, full read bytes, returned bytes/lines, decode time, cache hit, request identity, and outcome.

A deterministic test fixture with `first\nsecond\nthird\n` verifies:

- full disk bytes read: 19;
- returned range: 7 bytes / 1 line (`second\n`);
- cache hit: false;
- decode timing present.

Always-readable external files use the same counters across their detached I/O path. Repeated ranged reads remain full-file reads with zero cache hits until WI-7.

## Validation record

Passed on 2026-06-11:

- `make dev-swift-build PRODUCT=RepoPrompt`
- `make dev-test FILTER=GitCommandWorkCountDiagnosticsTests`
- `make dev-test FILTER=WorkspaceFileContextStoreTests`
- `make dev-test FILTER=MCPReadSearchLatencyDiagnosticsGuardTests`
- `make dev-lint`

Live `make dev-smoke` counter sanity: deferred because no CE debug app was running, and this work item was constrained not to launch or relaunch the visible app.
