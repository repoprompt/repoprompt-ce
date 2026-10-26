# Tasks, cancellation, continuations, and stream samples

Use these samples for lifetime and exactly-once diagnostics. Preserve existing behavior unless the compiler exposed a real ownership defect.

## Structured child tasks

Prefer child tasks when work belongs to the current operation:

```swift
func loadWorkspace(_ id: WorkspaceID) async throws -> WorkspaceSnapshot {
    async let files = fileService.listFiles(id)
    async let metadata = metadataService.load(id)

    let resolved = try await (files, metadata)
    return WorkspaceSnapshot(
        files: resolved.0,
        metadata: resolved.1
    )
}
```

The parent awaits both children. Cancellation and task-local values propagate without a stored handle.

For a bounded dynamic fan-out:

```swift
func inspect(_ paths: [Path]) async throws -> [Inspection] {
    try await withThrowingTaskGroup(of: Inspection.self) { group in
        for path in paths {
            group.addTask {
                try Task.checkCancellation()
                return try await inspect(path)
            }
        }

        var output: [Inspection] = []
        for try await result in group {
            output.append(result)
        }
        return output
    }
}
```

Do not use a task group for unbounded input without a concurrency limit.

## Owned unstructured task

Use an unstructured task only when its lifetime intentionally extends beyond the initiating call:

```swift
@MainActor
final class SearchController {
    private var searchTask: Task<Void, Never>?

    func search(_ query: String, service: SendableSearchService) {
        searchTask?.cancel()

        searchTask = Task { [weak self, service, query] in
            do {
                let results = try await service.search(query)
                try Task.checkCancellation()
                self?.results = results
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.errorMessage = String(describing: error)
            }
        }
    }

    func stop() {
        searchTask?.cancel()
        searchTask = nil
    }

    deinit {
        searchTask?.cancel()
    }

    private var results: [SearchResult] = []
    private var errorMessage: String?
}
```

Invariant: the controller owns the handle, cancels replacement and teardown, captures itself weakly, and publishes on the inherited main actor.

Check whether priority, task-local values, and actor inheritance are part of the existing behavior before replacing `Task {}`.

## Detached work

`Task.detached` is appropriate only when the work is intentionally independent of actor context, task-local values, priority inheritance, and structured cancellation.

```swift
struct ArchiveInput: Sendable {
    let source: URL
    let destination: URL
}

final class ArchiveJob: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<URL, Error>?

    func start(_ input: ArchiveInput) -> Task<URL, Error> {
        let newTask = Task.detached {
            try Task.checkCancellation()
            return try createArchive(input)
        }

        let previous = lock.withLock {
            let previous = task
            task = newTask
            return previous
        }
        previous?.cancel()
        return newTask
    }

    func cancel() {
        let pending = lock.withLock {
            let pending = task
            task = nil
            return pending
        }
        pending?.cancel()
    }
}
```

This sketch requires the lock-backed `@unchecked Sendable` invariant to be documented and verified. Prefer `Task {}` or structured work when detached semantics are not required.

Never detach while capturing a mutable actor-owned object merely to satisfy a capture diagnostic.

## Exactly-once continuation bridge

A callback bridge must handle all terminal paths: synchronous callback, later callback, duplicate callback, cancellation before installation, and cancellation racing completion.

Centralize the state transition:

```swift
private final class RequestState<Value: Sendable>: @unchecked Sendable {
    typealias Continuation = CheckedContinuation<Value, Error>

    private let lock = NSLock()
    private var continuation: Continuation?
    private var request: CancellableRequest?
    private var terminalResult: Result<Value, Error>?

    func install(
        continuation: Continuation,
        request: CancellableRequest
    ) {
        var resultToResume: Result<Value, Error>?
        var requestToCancel: CancellableRequest?

        lock.lock()
        if let terminalResult {
            resultToResume = terminalResult
            requestToCancel = request
        } else {
            self.continuation = continuation
            self.request = request
        }
        lock.unlock()

        requestToCancel?.cancel()
        resultToResume.map { continuation.resume(with: $0) }
    }

    func finish(_ result: Result<Value, Error>) {
        let continuationToResume: Continuation?

        lock.lock()
        guard terminalResult == nil else {
            lock.unlock()
            return
        }
        terminalResult = result
        continuationToResume = continuation
        continuation = nil
        request = nil
        lock.unlock()

        continuationToResume?.resume(with: result)
    }

    func cancel() {
        let continuationToResume: Continuation?
        let requestToCancel: CancellableRequest?

        lock.lock()
        guard terminalResult == nil else {
            lock.unlock()
            return
        }
        terminalResult = .failure(CancellationError())
        continuationToResume = continuation
        requestToCancel = request
        continuation = nil
        request = nil
        lock.unlock()

        requestToCancel?.cancel()
        continuationToResume?.resume(throwing: CancellationError())
    }
}
```

Use it at the boundary:

```swift
func response(for request: Request) async throws -> Response {
    let state = RequestState<Response>()

    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            let handle = legacyClient.start(request) { result in
                state.finish(result)
            }
            state.install(continuation: continuation, request: handle)
        }
    } onCancel: {
        state.cancel()
    }
}
```

Required invariants:

- one lock guards every state transition;
- the first terminal result wins;
- continuation resume, cancellation, and arbitrary callbacks happen after unlocking;
- late installation observes cancellation/completion;
- the legacy request handle is cancelled when cancellation wins.

Adapt this to the dependency's real synchronous-callback behavior. If `start` can invoke completion before returning its handle, test that exact interleaving.

## AsyncStream ownership and termination

Bound the buffer and connect consumer termination to producer cancellation:

```swift
func events() -> AsyncStream<Event> {
    AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
        let subscription = source.subscribe { event in
            switch continuation.yield(event) {
            case .enqueued:
                break
            case .dropped:
                metrics.recordDroppedEvent()
            case .terminated:
                break
            @unknown default:
                break
            }
        }

        continuation.onTermination = { @Sendable _ in
            subscription.cancel()
        }
    }
}
```

Review:

- Is loss acceptable? If not, choose a producer that supports backpressure rather than an unbounded buffer.
- Is the subscription safe to capture in a `@Sendable` termination closure?
- Can termination race subscription setup?
- Does the source retain the callback, producing a cycle?
- Must terminal errors use `AsyncThrowingStream`?

## Deterministic race tests

Coordinate interleavings with gates, not sleeps:

```swift
actor TestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}
```

Example test shape:

```swift
func testStaleRebuildDoesNotPublish() async throws {
    let started = TestGate()
    let release = TestGate()
    let builder = ControlledBuilder(
        onStart: { await started.open() },
        waitBeforeReturn: { await release.wait() }
    )
    let coordinator = IndexCoordinator(builder: builder)

    let task = Task { try await coordinator.rebuild() }
    await started.wait()
    await coordinator.select(.other)
    await release.open()
    try await task.value

    let published = await coordinator.publishedWorkspace
    XCTAssertNotEqual(published, .original)
}
```

A focused test should force the relevant ordering and assert the observable invariant. Avoid asserting a specific executor thread unless the API contract explicitly requires it.

## Review checklist

- Can structured concurrency own this work?
- If not, who stores and cancels the task handle?
- Does the task intentionally inherit actor, priority, and task-local context?
- Can every continuation complete exactly once under cancellation races?
- Does any lock remain held while resuming, invoking user code, cancelling external work, or awaiting?
- Is stream buffering bounded and termination wired to producer cleanup?
- Does the test force the race deterministically rather than waiting for it probabilistically?
