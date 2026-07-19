# Isolation and Sendable repair samples

Use these patterns after tracing the actual ownership boundary. Each sample states the invariant that makes the repair valid.

## Main-actor publication

### Isolate the real owner

If a view model is created, mutated, and observed by UI code, isolate the type rather than scattering hops:

```swift
@MainActor
final class SearchViewModel: ObservableObject {
    @Published private(set) var results: [SearchResult] = []

    func search(query: String, service: SearchService) async throws {
        let snapshot = try await service.search(query)
        results = snapshot
    }
}
```

Invariant: all mutable UI state is accessed on the main actor.

Avoid wrapping every property assignment in `MainActor.run`; that hides an actor-owned type behind call-site patches.

### Hop only at a callback boundary

When a legacy API calls back from a documented arbitrary queue:

```swift
final class ImportCoordinator {
    private let importer: LegacyImporter

    init(importer: LegacyImporter) {
        self.importer = importer
    }

    func start(onProgress: @escaping @MainActor @Sendable (Double) -> Void) {
        importer.start { progress in
            Task { @MainActor in
                onProgress(progress)
            }
        }
    }
}
```

Invariant: the importer owns callback scheduling; UI publication is explicitly transferred to the main actor.

## Transfer immutable snapshots

Do not send an actor-owned mutable reference to another domain. Extract the minimum immutable state:

```swift
actor WorkspaceIndex {
    private var entries: [Path: Entry] = [:]
    private var revision: UInt64 = 0

    struct Snapshot: Sendable {
        let entries: [Path: EntrySummary]
        let revision: UInt64
    }

    func snapshot() -> Snapshot {
        Snapshot(
            entries: entries.mapValues(EntrySummary.init),
            revision: revision
        )
    }
}

@concurrent
func rank(_ snapshot: WorkspaceIndex.Snapshot) async -> [RankedEntry] {
    rankEntries(snapshot.entries)
}
```

Invariant: `Snapshot`, `Path`, `EntrySummary`, and `RankedEntry` are value-semantic and `Sendable`.

Prefer purpose-built snapshots over adding `Sendable` to a reference graph whose members remain mutable.

## Global and static mutable state

### Actor-owned registry

```swift
protocol Provider: Sendable {}

actor ProviderRegistry {
    static let shared = ProviderRegistry()

    private var providers: [ProviderID: any Provider] = [:]

    func register(_ provider: any Provider, id: ProviderID) {
        providers[id] = provider
    }

    func provider(for id: ProviderID) -> (any Provider)? {
        providers[id]
    }
}
```

Use when operations are naturally asynchronous and callers can await.

### Main-actor application state

```swift
@MainActor
enum AppSession {
    static var activeWorkspaceID: WorkspaceID?
}
```

Use only when the state is genuinely app/UI-owned. Do not move headless MCP state to `MainActor`.

### Lock-backed synchronous state

Use the lock pattern in `synchronization-interop-samples.md` when access must remain synchronous and the critical section is short.

## Isolated protocol conformance

Make the restriction visible on the conformance:

```swift
protocol CommandSource {
    var commands: [Command] { get }
}

@MainActor
final class MenuCommandModel {
    var commands: [Command] = []
}

extension MenuCommandModel: @MainActor CommandSource {}
```

If a nonisolated consumer needs the data, cross with a snapshot instead of weakening the witness:

```swift
struct CommandCatalog: Sendable {
    let commands: [CommandDescriptor]
}

@MainActor
extension MenuCommandModel {
    func catalog() -> CommandCatalog {
        CommandCatalog(commands: commands.map(CommandDescriptor.init))
    }
}
```

Invariant: the conformance remains main-actor-only; the snapshot contains no actor-owned references.

## Actor reentrancy after suspension

Actor isolation prevents simultaneous access, but another task can mutate state while a method is suspended.

Fragile:

```swift
actor IndexCoordinator {
    private var workspace: WorkspaceID?

    func rebuild() async throws {
        guard let workspace else { return }
        let index = try await buildIndex(for: workspace)
        // workspace may have changed while suspended.
        publish(index, for: workspace)
    }
}
```

Validate a generation after the await:

```swift
actor IndexCoordinator {
    private var workspace: WorkspaceID?
    private var generation: UInt64 = 0

    func select(_ id: WorkspaceID?) {
        workspace = id
        generation &+= 1
    }

    func rebuild() async throws {
        guard let workspace else { return }
        let expectedGeneration = generation

        let index = try await buildIndex(for: workspace)

        guard generation == expectedGeneration,
              self.workspace == workspace
        else {
            return
        }

        publish(index, for: workspace)
    }
}
```

Invariant: results are published only for the selection generation that requested them.

For strict ordering, an owned task may also cancel stale work, but cancellation does not replace the post-await generation check.

## Checked and unchecked Sendable

A value type whose stored properties are all `Sendable` can state the contract directly:

```swift
struct ToolInvocation: Sendable {
    let id: UUID
    let arguments: [String: String]
}
```

A mutable reference type should not receive conformance just because compiler access happens to be serialized today:

```swift
// Avoid without a documented synchronization invariant.
final class InvocationCache: @unchecked Sendable {
    var values: [UUID: ToolInvocation] = [:]
}
```

If `@unchecked Sendable` is unavoidable, encapsulate all state and synchronization as shown in `synchronization-interop-samples.md`.

## Escape-hatch ledger sample

Record enough information for a later reviewer to re-prove or remove the escape hatch:

```markdown
| ID | Location | Escape hatch | Protected state | Invariant | Verification | Audit/removal trigger |
|---|---|---|---|---|---|---|
| C-014 | Sources/.../CallbackBox.swift:18 | @unchecked Sendable | continuation + terminal state | One lock guards every access; terminal transition happens once; callback runs after unlock | cancellation/success race test | Replace when dependency exposes async API |
```

An acceptable ledger entry names the state, authority, and invalid interleaving it prevents. “Compiler cannot prove this” is not an invariant.

## Review checklist

- Is the actor annotation on the owner rather than only the failing call?
- Is every transferred value genuinely `Sendable`, immutable, or disconnected?
- Can state change during an `await`, and is it revalidated?
- Does a global/static variable have one explicit synchronization authority?
- Is an isolated conformance usable at every generic/existential call site?
- Does an escape hatch have a focused behavioral test and removal trigger?
