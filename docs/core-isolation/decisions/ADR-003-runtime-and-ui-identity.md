# ADR-003: Runtime lifecycle identity and weak UI compatibility identity

- **Status:** Accepted
- **Date:** 2026-06-21
- **Decision owners:** Core runtime and app MCP owners
- **Implementation base:** `397a9b70`

## Context

External app-proxy clients address windows and tabs with compatibility `window_id`
and `context_id` values. Those values are routing aliases, not ownership of the
selected workspace runtime. A window can close or be replaced while an admitted
request is suspended. Re-resolving the alias after suspension could silently
retarget work to a replacement session, while retaining UI view models as runtime
authority would prevent deterministic draining.

## Decision

- `WorkspaceRuntimeID` and one lifecycle epoch identify a selected runtime in
  Core. They contain no window or UI concept.
- `WorkspaceRuntimeLifecycleRegistry` strongly retains a narrow backend-neutral
  session handle and owns `created → active → draining → removed`, exact request
  admissions, counts, duplicate/foreign release diagnostics, and exactly-once
  shutdown.
- An admitted handle can query and execute with its captured Phase 5 session
  token. It cannot admit again or shut down the runtime.
- `MCPAppRuntimeAdapterRegistry` is `@MainActor`. It weakly maps compatibility
  window IDs to runtime IDs and publishes immutable, sequence-fenced logical
  routing snapshots. Its tickets contain values only and never discover a
  replacement adapter.
- Resolution preserves the existing `MCPBindingResolver` priority and error
  contract. Sticky mappings commit only after exact Core runtime admission.
- Runtime-capable admitted work may complete against its original draining
  runtime. UI-required work requires the exact weak adapter ticket. Mixed work
  freezes UI policy before its runtime stage and never rolls back or retargets a
  committed Core result if later presentation is unavailable.
- `coreIsolation.runtimeRoutingBackend` is selected once by
  `RepoPromptAppCoreContainer`. `lifecycleRegistry` is the default;
  `legacyWindowBound` remains a next-launch rollback through Phase 8. The two
  routing implementations are never live-migrated.
- Existing `repoprompt-mcp` socket, filesystem, bundle/helper, retry, correlation,
  kill-signal, watchdog, and socket-owner identities are unchanged.

## Consequences

Window close removes adapter/catalog publication before draining. New admissions
fail, while old counted admissions determine shutdown. Compatibility active-tool
scopes and connection cleanup do not own the Core count. Unexpected weak-adapter
loss closes only its exact mapping and requests drain of its exact runtime.

Standalone headless routing and convergence onto this app registry are explicitly
outside this ADR and remain Phase 8/9 work.
