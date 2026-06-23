# Core Isolation Reconstruction Plan

Date: 2026-06-20
Status: Architecture map and implementation plan; no implementation started
Target: `repoprompt-ce-release` `dev`
Reference implementation: `repoprompt-ce-parallel` feature history

## Purpose

Reconstruct the core-isolation architecture developed in the parallel checkout on top of the latest `dev` implementation.

This must be an extraction of current code into explicit package and runtime boundaries. It must not restore the older feature snapshot wholesale or create a second mutable workspace authority.

## Reference history

The checked-out `repoprompt-ce-parallel/main` does not contain the core-isolation implementation. The useful references are:

- `f86746c8` — squashed feature snapshot, **Isolate core runtime and add headless foundation**
- `origin/feature/core-isolation-headless-foundation` — feature snapshot plus CI guardrail follow-up
- `origin/core_split` — linear development history
- `pr/118-rebase`
  - `444c599c` — rebased feature snapshot
  - `21b5603f` — **Harden headless foundation review findings**

The unrelated uncommitted MCP late-bridge/parallel-launch experiment in the parallel checkout is outside this plan.

The feature and current release branch share base `2544c836`. At the time of this investigation, `release/dev` is 313 commits ahead of that base while the feature snapshot is one squashed aggregate commit. Direct cherry-picking would overwrite newer workspace, worktree, search, prompt, and MCP behavior.

Useful linear archaeology from `origin/core_split`:

| Commit | Architectural contribution |
| --- | --- |
| `e96ba90d` | Initial core/headless isolation checkpoint |
| `081f42e1` | Reusable core session graph |
| `b8c1ada2` | macOS implementations behind injected platform contracts |
| `f1961fcb` | Enforced Core, CoreMacOS, POSIX, and syntax-bridge targets |
| `a7b00bb9` | Standalone direct-stdio headless foundation |
| `a7879434` | Safe read-oriented headless tool profile |
| `55f7cf30` | Headless packaging/install/smoke lane |
| `487cd71d` | Headless state and file-security hardening |
| `68776b1a` | Workspace authority moved into Core |
| `de21a1ee` | File-context runtime moved into Core |
| `461ce932` | Prompt assembly moved into Core |
| `4ff4492d` | Prompt accounting moved into Core |
| `5b4a5ada` | Factual prompt rendering moved into Core |
| `648000e4`–`5c06bf80` | Selection, token, code-structure, and context projections |
| `5b8bc9da` | Standard app prompt assembly migrated to Core |

## Architecture map

### Package boundary

The feature snapshot introduced this package graph:

```text
                           RepoPromptShared
                    protocol DTOs and wire contracts
                                  │
                    ┌─────────────┴─────────────┐
                    │                           │
              RepoPromptCore             RepoPromptCoreMacOS
       workspace/session runtime       FSEvents, POSIX, Keychain,
       filesystem, search, prompt      signing, macOS adapters
                    │                           │
        ┌───────────┴──────────┐       ┌────────┴─────────┐
        │                      │       │                  │
   RepoPrompt.app       repoprompt-headless        repoprompt-mcp
   AppKit/SwiftUI          direct stdio MCP       existing app proxy
```

Reserved targets and responsibilities:

| Target | Responsibility |
| --- | --- |
| `RepoPromptCore` | Neutral workspace/session authority, filesystem catalog, path lookup, search, selection, slices, token accounting, codemap, syntax, and factual prompt projections |
| `RepoPromptCoreMacOS` | FSEvents, directory/content access, POSIX/process adapters, Keychain, signing, and macOS-specific implementations |
| `RepoPromptPOSIXSupport` | Narrow descriptor and socket helpers shared by POSIX importers |
| `RepoPromptSyntaxCBridge` | Narrow Tree-sitter declarations and grammar/scanner linkage without an app-wide bridging header |
| `RepoPrompt` | App/UI shell, composition root, product policy, observation, mutation authorization, diagnostics, and adapters |
| `RepoPromptMCP` | Existing app-proxy CLI and transport |
| `RepoPromptHeadless` | Independently packaged direct-stdio host with separate state, roots, secrets, and permissions |

The feature package also split tests into app, Core, CoreMacOS, POSIX, and headless targets.

### Runtime/session boundary

The core runtime is window-independent, but the app projects one routing session onto each window.

The feature composition flow is:

```text
RepoPromptAppCoreContainer
  └─ RepoPromptCoreHost
       └─ RepoPromptCoreSessionHandle
            └─ RepoPromptCoreSession
                 ├─ WorkspaceSessionController
                 ├─ WorkspaceFileContextStore
                 ├─ WorkspaceSearchService
                 ├─ WorkspaceSelectionController
                 └─ SelectionSliceCoordinator
```

Key implementation locations in the feature snapshot:

- `Sources/RepoPrompt/App/RepoPromptAppCoreContainer.swift`
- `Sources/RepoPrompt/Infrastructure/Core/RepoPromptCoreHost.swift`
- `Sources/RepoPrompt/App/RepoPromptEmbeddedWorkspaceRuntimeFactory.swift`
- `Sources/RepoPrompt/App/WindowStateComposition.swift`
- `Sources/RepoPromptCore/Workspaces/WorkspaceSessionController.swift`
- `Sources/RepoPromptCore/WorkspaceContext/WorkspaceFileContextStore.swift`

Important transitional detail: the reusable services and canonical workspace controller were physically moved into `RepoPromptCore`, but `RepoPromptCoreHost`, `RepoPromptCoreSession`, and the MCP runtime registry remained app-target types. The feature established a strong package seam but did not complete every intended ownership move.

### Canonical authority

`WorkspaceSessionController` is the sole mutable workspace authority. It owns:

- ordered workspaces;
- active workspace identity;
- immutable snapshots and snapshot generation;
- dirty/saved generations;
- repository baselines;
- selection revisions;
- mutation transactions and persistence coordination.

The app adapts snapshots through `WorkspaceSessionObservationBridge`. App view models may retain presentation state, but must not retain another independently writable workspace graph.

### File-context isolation

Each core session owns its own `WorkspaceFileContextStore` actor and associated search, selection, and slice services.

Platform behavior is injected through `WorkspaceRuntimeDependencies`:

- watcher factory;
- directory-listing backend;
- content-snapshot reader;
- mutation backend;
- partition/cache roots;
- runtime configuration;
- diagnostics sink.

`RepoPromptEmbeddedWorkspaceRuntimeFactory` is the sole production factory. The app supplies CoreMacOS implementations plus app mutation, diagnostics, cache-root, and settings policy.

### MCP routing isolation

The feature separates two registries:

- `MCPRuntimeSessionRegistry`: runtime lifecycle and routing eligibility
- `RepoPromptAppSessionAdapterRegistry`: weak lookup of UI/AppKit adapters

A missing UI adapter must not destroy runtime identity or silently retarget work.

The compatibility lifecycle is:

```text
created → active → draining → removed
```

Existing `window_id` contracts remain compatibility identifiers, but internally map to routing sessions rather than owning reusable state.

### Prompt boundary

Core owns deterministic factual work:

- workspace selection projection;
- token projection;
- code-structure projection;
- workspace-context projection;
- prompt accounting;
- factual file/codemap/diff rendering.

The app retains policy:

- prompt and preset choice;
- review mode and Git inclusion;
- authoritative diff artifact creation;
- logical checkout labels;
- live view-model conversion;
- chat/clipboard/Context Builder/MCP envelopes.

### Standalone headless boundary

The feature packages `repoprompt-headless` independently from the app proxy:

- direct newline-delimited JSON-RPC over stdin/stdout;
- separate Application Support directory;
- separate secure-storage namespace;
- fail-closed configured roots;
- owner-only state directories/files;
- read-oriented tool allowlist;
- mutation, VCS writes, agent launch, and external export disabled by default.

Although the feature target depends on Core/CoreMacOS, headless v1 still owns a parallel runtime and does not construct the shared app session graph. Full convergence was explicitly deferred.

## Core invariants

1. There is exactly one canonical writable workspace/session graph per routing session.
2. App view models project immutable Core snapshots and forward commands.
3. Validated worktree scopes fail closed when physical roots disappear.
4. Search readiness, catalog generations, path indexes, and root lifetimes survive extraction unchanged.
5. Selection propagation is revision-fenced and cannot feed published state back as a new write.
6. Core does not import `AppKit`, `SwiftUI`, `Security`, `Darwin`, `OSLog`, or `os`.
7. Embedded-app policy—Application Support paths, UserDefaults, approvals, visible lifecycle, and diagnostics—stays in the app.
8. macOS callbacks and resources are owned by CoreMacOS adapters and terminate with their session.
9. MCP routing eligibility does not depend on the continued existence of a UI adapter.
10. Headless never implicitly inherits app workspaces, secrets, mutation permissions, or app-proxy routing.

## Current `dev` delta

Current `dev` has only the `RepoPrompt` and `repoprompt-mcp` executable products. Workspace, platform, syntax, prompt, and security dependencies remain in the app target, including the target-wide Objective-C bridging header.

The latest code contains behavior absent from the old feature snapshot and must be moved forward rather than replaced:

- `WorkspaceLookupRootScope.validatedSessionBoundWorkspace`
- typed unavailable worktree scope results
- logical/physical `WorkspaceRootRef` validation
- search-readiness tickets and supersession
- immutable catalog-generation leases and path indexes
- newer watcher/root lifetime fencing
- selection propagation and mirror revisions
- worktree-aware frozen review contexts
- current MCP ownership, routing, and replacement semantics
- generated Xcode workspace support

The primary conflict is `WorkspaceManagerViewModel`, which currently owns:

- writable workspace arrays;
- active workspace identity;
- dirty/saved versions;
- selection revisions;
- selection mirror state;
- readiness publication.

Introducing a Core controller without removing these write paths would create dual authority.

## Reconstruction plan

### Phase 0 — Characterization and move inventory

Before production changes:

- inventory every declaration to move and its current dependencies;
- characterize persistence encoding and normalization;
- characterize validated root/worktree failure behavior;
- characterize watcher lifecycle, readiness, catalog generations, and search results;
- characterize selection revisions and propagation;
- characterize prompt rendering, review authority, and token accounting;
- characterize MCP routing priority and session teardown;
- lock the headless wire, tool, error, state, and security contracts from the reviewed feature branch.

Gate: no production behavior change; current builds and tests remain green.

### Phase 1 — Package and guardrail scaffolding

Add empty compilable targets and test targets:

- `RepoPromptCore`
- `RepoPromptCoreMacOS`
- `RepoPromptPOSIXSupport`
- `RepoPromptSyntaxCBridge`
- `RepoPromptCoreTests`
- `RepoPromptCoreMacOSTests`
- `RepoPromptPOSIXSupportTests`

Also:

- document target ownership;
- add forbidden-import and dependency-direction guardrails;
- update source-layout guardrails;
- teach the generated Xcode workspace about the new targets;
- introduce uniquely scoped POSIX and syntax bridge symbols.

Gate: all products build with no runtime ownership change.

### Phase 2 — Neutral leaf extraction

Move the current release implementations of:

- workspace/root and persistence values;
- catalog/search/readiness models;
- path lookup and index events;
- selection and slice values;
- prompt/codemap projection values;
- neutral utilities and regex helpers.

Use temporary app-side typealiases or forwarding adapters. There must never be two concrete declarations for the same model.

Gate:

- persistence round trips remain byte-compatible;
- equality/default behavior is unchanged;
- validated scopes and catalog snapshots match current behavior;
- source guardrails prove a single canonical owner.

### Phase 3 — Platform seams

Define neutral Core protocols for:

- filesystem watching;
- directory/content access;
- process and descriptor operations;
- secure storage;
- diagnostics.

Move macOS implementations into CoreMacOS and C declarations into the narrow bridge targets.

Keep in the app:

- Application Support and cache-root policy;
- UserDefaults;
- mutation authorization;
- app diagnostics/signposts;
- visible lifecycle and approvals.

Gate: focused watcher teardown, cancellation, descriptor cleanup, Keychain/signing, and syntax-linkage tests.

### Phase 4 — Workspace/file-context engine extraction

Move the latest implementations of:

- `WorkspaceFileContextStore`;
- filesystem/catalog/path/search services;
- selection and slices;
- codemap and neutral syntax;
- token accounting;
- prompt context capture/projection.

Preserve:

- accepted-ingress and watermark barriers;
- watcher lifecycle epochs;
- root detachment before teardown;
- search admission/backpressure;
- immutable generation leases;
- path indexes;
- deterministic ordering and cancellation.

Gate: Core tests match current app characterization and performance baselines.

### Phase 5 — Atomic workspace-authority cutover

Introduce the reusable session graph and make `WorkspaceSessionController` canonical.

In the same landing:

1. load existing persisted workspaces and selections;
2. construct the Core graph;
3. hydrate Core once;
4. subscribe app adapters to the first immutable snapshot;
5. enable commands and routing;
6. convert `WorkspaceManagerViewModel` mutations into Core commands;
7. remove writable mirror state and selection writeback.

Rollback may use a construction-time backend switch for one stabilization cycle. It must choose exactly one writable backend before session creation. Debug shadow comparison may read immutable snapshots but may not dual-write.

Gate:

- runtime assertions prove one writable authority;
- stale revisions fail deterministically;
- persistence receipts/generations remain exact;
- session teardown releases watchers and worktree ownership once.

### Phase 6 — Prompt and review integration

Route prompt accounting and factual rendering through the Core session.

Keep review authorization and product policy app-owned. Core consumes already-authorized, frozen inputs and must not rediscover Git authority.

Gate:

- golden equality for file maps, selected contents, codemap placement, and diffs;
- token-count parity;
- no physical worktree path leakage;
- current frozen review behavior remains unchanged.

### Phase 7 — MCP runtime/UI registry split

Add or reconstruct:

- runtime session registry;
- weak app adapter registry;
- lifecycle-bound request admission;
- created/active/draining/removed transitions.

Update routing and tool admission atomically. Requests admitted to a draining/removed session must not be retargeted to a replacement session.

Gate:

- lifecycle race tests;
- UI-adapter disappearance tests;
- multi-session routing tests;
- existing app-proxy behavior and compatibility ordering remain unchanged.

### Phase 8 — Standalone headless v1

Add the independent direct-stdio executable and separate validation lane.

Requirements:

- separate state, roots, and secrets;
- no app socket or bundle dependency;
- safe read-oriented tool profile;
- default-deny mutation and automation;
- direct-stdio lifecycle and framing fixtures;
- independent package/install/smoke scripts.

Headless v1 may remain a parallel runtime initially. Do not claim shared-runtime convergence until a later characterized migration removes its duplicate mutable stores.

### Phase 9 — Compatibility cleanup and later convergence

After stabilization:

- remove the legacy backend and construction switch;
- delete compatibility aliases and obsolete app implementations;
- make target ownership permanent in guardrails;
- separately plan headless adoption of Core;
- separately plan any deferred MCP provider/catalog/DTO/formatter/dispatch extraction.

## P0 hazards

1. **Dual authority:** Core and `WorkspaceManagerViewModel` both accept writes.
2. **Fail-open worktree lookup:** missing physical roots fall back to visible or all-loaded roots.
3. **Generation loss:** readiness tickets, path indexes, root lifetimes, or catalog leases disappear during moves.
4. **Selection loops:** adapter publication is written back without revision fencing.
5. **MCP retargeting:** draining work resolves against a replacement session.
6. **Path leakage:** physical worktree paths appear in prompts or tool output.
7. **Review regression:** Core recreates or accepts unauthorized Git artifacts.
8. **Watcher-after-release races:** stale callbacks mutate replacement sessions.
9. **Dependency cycles:** Core imports app/platform policy through diagnostics or helper extensions.
10. **C symbol collisions:** new POSIX/syntax bridges overlap existing targets.
11. **Headless privilege bleed:** app roots, secrets, routing state, or mutable tools leak into standalone mode.
12. **Performance regression:** batching, backpressure, immutable indexes, or lazy materialization are lost.

## Validation strategy

Each phase should use the smallest coordinated lane first, then broaden:

- targeted Core/CoreMacOS/POSIX/headless tests;
- affected current app characterization tests;
- `make dev-swift-build PRODUCT=RepoPrompt`;
- `make dev-swift-build PRODUCT=repoprompt-mcp`;
- coordinated headless build/smoke targets once added;
- `make guardrails`;
- `make dev-lint`;
- generated Xcode workspace regeneration and validation;
- packaging validation without launching the visible app;
- full test lanes after focused ownership and lifecycle tests pass.

Required permanent guardrails:

- forbidden imports and dependency directions;
- single canonical owner per moved declaration;
- sole production runtime factory;
- no app-packaging references to standalone commands;
- frozen headless security/wire contracts;
- app-proxy and standalone transport separation;
- no reintroduction of removed app-side canonical workspace/file-context implementations.

## Non-goals

This plan does not:

- cherry-pick `f86746c8` or `444c599c`;
- port the unrelated MCP late-bridge timeout experiment;
- change persisted workspace schemas;
- claim Linux/Windows support;
- make `repoprompt-mcp` the standalone host;
- converge headless onto Core in its first reconstructed release;
- move app policy, UI, approvals, or visible lifecycle into Core.
