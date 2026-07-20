# Swift 6.2 concurrency semantics samples

Use this file to reason about execution and isolation changes without reopening external documentation. The examples are intentionally small; adapt the ownership contract, not the names.

## Contents

- Caller-actor execution
- Explicit off-actor work with `@concurrent`
- Default actor isolation
- Isolated conformances
- Unstructured task inheritance
- Adoption checklist

## Caller-actor execution

With `NonisolatedNonsendingByDefault`, an ordinary nonisolated async function stays on the caller's actor unless its declaration explicitly requests concurrent execution.

This is useful when an actor-owned object is not `Sendable`:

```swift
final class RequestEncoder {
    private var scratch = Data()

    func encode(_ request: Request) async throws -> Data {
        scratch.removeAll(keepingCapacity: true)
        scratch.append(try JSONEncoder().encode(request))
        return scratch
    }
}

@MainActor
final class ComposerModel {
    private let encoder = RequestEncoder()

    func submit(_ request: Request) async throws {
        let body = try await encoder.encode(request)
        // publish UI state
    }
}
```

Under caller-actor semantics, `encode` can execute on the main actor for this call. That removes an unnecessary non-Sendable crossing, but it does **not** make CPU-heavy work appropriate for the main actor.

The explicit declaration spelling is useful at an API boundary:

```swift
nonisolated(nonsending)
func resolveSelection(_ input: SelectionInput) async throws -> SelectionResult {
    // Runs on the caller's actor.
}
```

Use it when caller-actor execution is part of the API contract, even if a target setting currently supplies the default.

### Review questions

- Does this function mutate or access a non-Sendable object owned by the caller?
- Could it block, parse a large input, scan the filesystem, or run expensive regex work?
- Did its prior behavior accidentally provide off-actor execution?
- Are tests asserting results only, or also relying on scheduling and responsiveness?

## Explicit off-actor work with `@concurrent`

Use `@concurrent` when an async operation is intentionally independent of the caller's actor:

```swift
struct ScanInput: Sendable {
    let bytes: [UInt8]
    let language: LanguageIdentifier
}

struct ScanSummary: Sendable {
    let declarationCount: Int
    let elapsedNanoseconds: UInt64
}

@concurrent
func scan(_ input: ScanInput) async throws -> ScanSummary {
    try Task.checkCancellation()
    return try performCPUHeavyScan(input)
}
```

The parameters and result must be safe to cross the isolation boundary. Build immutable snapshots before calling rather than passing an actor-owned parser, mutable cache, or UI model.

Avoid using `@concurrent` as a diagnostic eraser:

```swift
// Avoid: mutableCache is shared reference state with no ownership contract.
@concurrent
func lookup(_ key: String) async -> Value? {
    mutableCache[key]
}
```

If offloading is necessary, isolate the cache behind an actor/lock or copy the input required for the calculation.

## Default actor isolation

A target with `.defaultIsolation(MainActor.self)` treats eligible unannotated declarations as main-actor isolated. That can reduce UI annotation noise, but it also changes APIs that look neutral.

Suitable shape:

```swift
// In a UI-only target whose manifest selects default MainActor isolation.
final class SettingsPaneModel: ObservableObject {
    @Published private(set) var status: Status = .idle

    func refresh() async {
        status = await service.loadStatus()
    }
}
```

Explicitly opt reusable data and headless helpers out when the target genuinely needs them to remain nonisolated:

```swift
nonisolated
struct WorkspaceIdentifier: Hashable, Codable, Sendable {
    let rawValue: String
}

nonisolated
func normalizePathComponents(_ components: [String]) -> [String] {
    components.filter { !$0.isEmpty }
}
```

Do not enable default `MainActor` for a mixed target merely to reduce diagnostics. It can actor-isolate protocol witnesses, initializers, static members, and helpers consumed by MCP or background services.

## Isolated conformances

When a type and its protocol witness are main-actor owned, express that restriction on the conformance:

```swift
protocol StatusPresenting {
    var statusText: String { get }
}

@MainActor
final class StatusViewModel {
    var statusText = "Idle"
}

extension StatusViewModel: @MainActor StatusPresenting {}
```

The conformance can then be used only where the main-actor requirement is satisfied:

```swift
@MainActor
func renderStatus(_ value: some StatusPresenting) -> String {
    value.statusText
}
```

A generic nonisolated consumer cannot assume access:

```swift
// This API is too broad for an actor-isolated conformance.
func serialize<T: StatusPresenting>(_ value: T) -> String {
    value.statusText
}
```

Choose one of these contracts deliberately:

1. isolate the consumer;
2. pass a `Sendable` snapshot such as `StatusSnapshot(text:)`;
3. redesign the protocol so the witness does not read isolated state.

Do not mark the witness `nonisolated` while it still touches actor-owned storage.

## Unstructured task inheritance

Caller-actor async semantics do not mean every nested unstructured task inherits the caller's actor. In particular, a `Task` created from a nonisolated function needs its own explicit ownership analysis.

Prefer direct structured work:

```swift
nonisolated(nonsending)
func refresh(using client: Client) async throws -> Snapshot {
    try await client.fetchSnapshot()
}
```

If work must outlive the call, give the task a named owner and make the capture boundary explicit:

```swift
@MainActor
final class RefreshController {
    private var refreshTask: Task<Void, Never>?

    func start(client: SendableClient) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self, client] in
            let result: Result<Snapshot, Error>
            do {
                result = .success(try await client.fetchSnapshot())
            } catch {
                result = .failure(error)
            }
            guard !Task.isCancelled else { return }
            self?.publish(result)
        }
    }

    deinit {
        refreshTask?.cancel()
    }

    private func publish(_ result: Result<Snapshot, Error>) {
        // Main-actor publication.
    }
}
```

Verify the compiler's inferred isolation at the actual creation site. Do not infer it from the surrounding function's spelling alone.

## Adoption checklist

For each target or API:

1. Record whether the behavior comes from Swift 6 mode, an upcoming feature, or explicit source syntax.
2. Inventory ordinary nonisolated async functions.
3. Classify each as caller-owned work, actor-independent CPU/blocking work, or an external callback bridge.
4. Keep caller-owned work nonsending; mark only intentional independent work `@concurrent`.
5. Review every value crossing to `@concurrent`.
6. Review isolated conformances at generic and existential use sites.
7. Profile UI responsiveness and long-running operations.
8. Add behavior tests for cancellation, ordering, publication, and actor reentrancy where the contract changed.

## Provenance

These examples are original RepoPrompt-oriented material derived from:

- [SE-0461: Caller-actor execution and `@concurrent`](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0461-async-function-isolation.md)
- [SE-0466: Default actor isolation](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0466-control-default-actor-isolation.md)
- [SE-0470: Isolated conformances](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0470-isolated-conformances.md)
- Apple's locally installed `Swift-Concurrency-Updates.md`; see `official-swift-6-2.md` for the inspected Xcode build and checksum.
