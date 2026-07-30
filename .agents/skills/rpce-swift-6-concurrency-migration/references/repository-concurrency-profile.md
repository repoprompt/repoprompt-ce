# RepoPrompt CE concurrency profile

Reverify these facts before a migration phase; line numbers and target composition can change.

## Current configuration

- Root `Package.swift` and `Packages/RepoPromptAgentProviders/Package.swift` declare tools version 6.2.
- Both manifests currently set `swiftLanguageModes: [.v5]`.
- No manifest currently enables complete strict-concurrency checking, default actor isolation, `NonisolatedNonsendingByDefault`, or `InferIsolatedConformances`.
- The root app settings enable `BareSlashRegexLiterals`; that is not a concurrency setting.
- Tools version 6.2 permits SwiftPM 6.2 APIs but does not opt sources into Swift 6 language mode.

## Package and target boundaries

The root package contains materially different concurrency domains:

- `RepoPromptApp`: app composition, UI, feature/runtime code, and an Objective-C bridging header.
- `RepoPrompt`: one-file executable entry shell.
- `RepoPromptMCP`: MCP executable and transport/process flows.
- `RepoPromptShared`: app/CLI protocol code.
- `RepoPromptWorkspaceCore`: headless workspace logic.
- `RepoPromptMCPServerCore`: headless server core.
- Root tests for app, MCP server core, and workspace core.

`Packages/RepoPromptAgentProviders` is a separate Swift package and validation boundary. Do not use one default-isolation policy for all targets without target-specific ownership analysis.

## Existing concurrency substrate

Reusable primitives live in `Sources/RepoPrompt/Infrastructure/Concurrency`:

- `AsyncMutex.swift`
- `AsyncScope.swift`
- `BoundedOrderedConcurrentMap.swift`
- `TaskSemaphore.swift`

Inspect each implementation and its tests before reuse. Their existence is not permission to bypass structured concurrency or cancellation analysis.

## High-scrutiny patterns

The repository already contains detached and escaping tasks, checked continuations, cancellation handlers, unsafe sendability/isolation annotations, runtime main-actor assertions, lock/queue protected state, and C/Objective-C interoperability.

For each one, identify:

1. protected state;
2. owning actor, task, lock, queue, or immutability invariant;
3. cancellation and lifetime behavior;
4. public API or imported-code constraints;
5. an audit or removal condition.

## Repository-specific risks

- Agent Mode and MCP work can be long-lived; cancellation and observability are correctness requirements.
- Indexing, persistence, file access, and process execution need bounded concurrency and must avoid blocking Swift executors.
- UI publication should use immutable or `Sendable` snapshots at explicit main-actor synchronization points.
- Actor state read before `await` may be stale after resumption.
- Continuation bridges must handle synchronous completion, cancellation races, and exactly-once resumption.
- Dependency annotations and mixed Swift language modes can produce module-boundary diagnostics; distinguish dependency limits from first-party ownership defects.
