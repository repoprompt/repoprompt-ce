# Phase 7 — Runtime Lifecycle Identity and Weak UI Adapters

**Date:** 2026-06-21
**Implementation base:** `397a9b70`
**Status:** complete
**Disposition:** **GO**

## Scope

Phase 7 separates strong, actor-owned Core runtime lifecycle identity from weak
MainActor app compatibility adapters. It preserves external `window_id`, logical
context priority/errors, and the existing `repoprompt-mcp` app-proxy identity.
Standalone headless routing, transport, packaging, and Phase 8/9 cleanup are not
implemented.

## Lifecycle and admission contract

| State | New admission | Existing admitted work | Exit |
| --- | --- | --- | --- |
| `created` | reject | none | exact Phase 5 activation token → `active` |
| `active` | admit exact epoch and increment | execute with captured strong handle | close/replacement → `draining` |
| `draining` | reject | runtime-capable/mixed runtime stage may finish; UI stage needs exact ticket | count zero → exactly-once shutdown → `removed` |
| `removed` | reject | none | diagnostics tombstone may be purged |

Every token carries runtime ID, lifecycle epoch, unique admission ID, and the
exact Phase 5 session admission. Release is exactly once; duplicate or foreign
release never decrements the count. Admission rechecks state/epoch after the
session actor suspension. The restricted admitted handle exposes neither
`admit` nor `shutdown` and rewrites command envelopes to the captured session
token.

## Runtime/UI identity boundary

- `RepoPromptAppCoreContainer` allocates runtime IDs and constructs the lifecycle
  registry only for the immutable `lifecycleRegistry` routing selection.
- Core and legacy workspace backends both supply the same strong runtime facade.
- The adapter registry stores weak adapter/window/server references and immutable
  logical workspace/tab/root snapshots. Snapshot/ticket generation is monotonic.
- Runtime registration precedes hydration. Runtime activation and adapter/catalog
  publication occur only after the first authoritative snapshot is applied.
- Resolver matches are built from one immutable routing-table snapshot and carry
  runtime ID plus mapping generation. Existing resolver order and error strings
  remain unchanged.
- Common dispatch admits the exact resolved runtime before committing sticky or
  live-run mappings. Catalog dispatch must match window ID, runtime ID, and mapping
  generation. Runtime-capable work does not revalidate UI object identity.
- UI/mixed work uses the exact weak adapter ticket. Closing or replacement cannot
  exchange it for the new adapter.

## Tool lifetime classification

The exhaustive catalog covers all 26 canonical advertised tools and rejects
unknown future tools or reviewed operation variants before admission.

| Class | Tools / operations | Close behavior |
| --- | --- | --- |
| Runtime-capable | `get_code_structure` explicit paths; non-selected `get_file_tree`; `bind_context list/status`; `manage_workspaces list` immutable inventory | admitted work may finish on the old runtime |
| Mixed | all `manage_selection`; `read_file`/`file_search` with optional UI auto-selection tail; `workspace_context` snapshot/export; workspace and tab mutations; `bind_context bind` | exact adapter at policy/commit boundary; committed runtime result is never rolled back or retargeted |
| UI-required | file mutation/apply-edits; prompt mutation/preset/clipboard presentation; Oracle, Git/worktree, Context Builder, Ask User, agent/session control, app settings | exact adapter required; active UI-only invocation is cancelled on close |

## Teardown and termination

`WindowState.beginClose` synchronously closes adapter/catalog publication before
UI cleanup. Teardown then stops observation/activation and asks the registry to
drain; session shutdown occurs only at count zero. Removed mappings and Core
tombstones are purged after drain. App termination closes every adapter, stops
agent/UI and MCP publication, drains all runtimes, then invokes host safety
shutdown. No MainActor lock is held while awaiting Core removal.

## Deterministic tests

- `WorkspaceRuntimeLifecycleRegistryTests`: transition table, strong handle,
  suspension/drain race, count balance, duplicate/foreign release, cancellation,
  exactly-once shutdown, restricted handle, tombstone retention, real host path.
- `MCPAppRuntimeAdapterRegistryTests`: staged publication, immutable updates,
  weak lifetime, replacement ordering, mapping generations, old-ticket no-retarget.
- `MCPRuntimeLifecycleTests`: admitted old-runtime drain through replacement and
  UI admission failure after adapter loss without count mutation.
- `MCPToolLifetimeCatalogTests`: exhaustive canonical and operation classification.
- `TabContextRoutingTests` and `WorkspaceAuthorityCutoverTests`: exact runtime/
  mapping identity, unchanged resolver behavior, activation ordering, rollback.

Exact authoritative IDs and curated-ledger rows are recorded only from the
implementation-time list commands; no source-derived census is accepted.

## Structural and compatibility guards

`core_isolation_guardrails.py` now rejects window/UI concepts in Core runtime
files, strong adapter retention, admission/shutdown escalation through restricted
handles, UI models in retained request context, routing selection outside the
composition root, app-registry construction in headless, and app runtime routing
inside the `RepoPromptMCP` proxy product. Negative fixtures cover these failures.

`Package.swift` adds no target or dependency edge. `RepoPromptMCP` transport and
packaging sources are unchanged. Phase 8 headless sources are not imported or
constructed by app routing.

## Rollback

`coreIsolation.runtimeRoutingBackend=legacyWindowBound` is next-launch only and
independent of `coreIsolation.workspaceBackend`. The inactive registry/adapter
implementation is not constructed. A live draining admission is never migrated.

## Evidence

| Lane | Ticket / result |
| --- | --- |
| Core lifecycle focused | `ded00351-5072-466a-989e-99d521d79c57` — 8 pass; final full Core lane `4e8a0323-c536-4b04-8bf7-743c1b8616a0` passed |
| Weak adapter focused | final `ffc3fcad` — 4 pass |
| App lifecycle focused | final `5b8ff019` — 2 pass |
| Route freshness/fencing | `0570e2a9` — 11 pass after the one-off full-root freshness failure |
| Full root | `d26418cb-237f-4004-9a05-8cf3494460dd` — pass |
| Platform roots | CoreMacOS `e33c2942-ede1-40c4-8d8d-855f597738bf`; POSIX `26a29173-0ce2-41b5-8a77-c71fea005ad8`; provider `33ac889a-52ab-45d4-aaab-91e140dce6ab` — pass |
| Products | app `9b960e1f`; all products `5106820c-e364-40a1-9fcd-59b9ca5aacef` — pass |
| Signed non-launching package | `32072cc7-14ce-4440-b6f8-993bbafa739e` — pass |
| Style | format `9fb3ed15`; strict lint `83d382e9` — pass, zero violations |
| Structural guards | 25 negative fixtures and the full live guard ladder — pass |
| Xcode | generator 23/23 and generated-workspace validation — pass |
| Curated ledger | 1,938 exact methods / 2,563 scenarios; Core 257/344, CoreMacOS 34/34, POSIX 3/3, provider 7/16, root 1,637/2,166 — exact verification pass |
| Performance | `71a6ec09-90d1-4de8-867e-12b424611d00`, `368fe409-e8ad-4129-b909-c56eb7c7259d`, `43bfacc5-822e-4ef7-a987-33b4035c65a9` — 2/2 lifecycle tests in 0.002 s each; median/range 0.002 s |
| Packaged live | launch/smoke `a71a5cc8-9355-4c32-97b3-64381a109046`; final non-disruptive smoke `d8aed424-56a8-4b1d-98ee-2e5f5ad00947` — pass |
| Stop proof | stop `bff9ef43-1b52-4a08-989a-35a7ff6a6f12`; status `24de62db-d5b3-470f-8608-335cd9bd16d4`; zero processes at either exact debug executable |

## Closure audit and review

The closure audit repaired production fail-open routing, publication-sequence
retargeting across the limiter, replacement-before-drain ordering, late
activation after close, strong UI retention in tool dependencies, legacy-runtime
termination, weak-adapter loss cleanup, and the admitted-handle execution proof.
The final catalog is bound to the exact runtime and immutable mapping generation.

Curated Git review artifacts were published. The live CE review tab continued to
remap its selection preview to the main checkout after one explicit exact-worktree
bind/select/replace attempt, so that transport was not retried. The current agent
transport was also unavailable; the existing Oracle review chat
`new-chat-BD4B19` was preserved and continued with the actual bound-worktree
production source inline. The review's only repeated recommendations assumed the
Phase 5 workspace-session token was a counted lease requiring release. It is an
immutable validation value with no release/refcount API; the Phase 7 runtime
admission is the counted lease and is released exactly once. No corrective code
change was applicable.

## Live evidence

The signed packaged debug app exercised the existing `repoprompt-mcp` proxy via
windows, workspace switch, tree roots, worktree listing, and agent-role discovery.
The final smoke passed without retargeting or proxy-identity drift. Coordinated
stop then confirmed the matching app stopped, and an exact executable scan found
zero processes for both the installed CE debug app and worktree package paths.
The temporary review context file was removed and the planning-model override was
restored before stop.

## Gate

**Final disposition: GO.** All Phase 7 deterministic, exact-ledger, structural,
style, product/Xcode, signed-package, performance, bounded independent-review,
live app-proxy, and stopped-process gates are green. No retarget, count leak, UI
retention, resolver/proxy identity drift, headless coupling, or running debug app
remains. Changes are intentionally uncommitted. Phase 8/9 and standalone headless
routing remain excluded.
