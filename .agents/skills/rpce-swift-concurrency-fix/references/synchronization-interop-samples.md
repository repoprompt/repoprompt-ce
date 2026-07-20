# Synchronization and interoperability repair samples

Use these patterns only after identifying the boundary's real thread, queue, actor, and lifetime contract.

## Lock-backed reference type

A lock can justify `@unchecked Sendable` when every access to mutable state is encapsulated and the critical sections are synchronous and bounded:

```swift
protocol CancellableRequest: Sendable {
    func cancel()
}

final class RequestRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [RequestID: any CancellableRequest] = [:]

    func insert(_ request: CancellableRequest, for id: RequestID) {
        let replaced = lock.withLock {
            requests.updateValue(request, forKey: id)
        }
        replaced?.cancel()
    }

    func remove(_ id: RequestID) -> (any CancellableRequest)? {
        lock.withLock {
            requests.removeValue(forKey: id)
        }
    }

    func cancelAll() {
        let pending = lock.withLock {
            let values = Array(requests.values)
            requests.removeAll()
            return values
        }
        pending.forEach { $0.cancel() }
    }
}
```

Invariant:

- `requests` is private;
- the same lock guards every read and write;
- no callback, cancellation, I/O, or suspension occurs while locked;
- stored request handles are `Sendable`, so values removed from the registry can be used after unlocking;
- methods do not expose mutable storage aliases.

Document this invariant next to `@unchecked Sendable` and in the migration ledger.

## Never call unknown code under a lock

Fragile:

```swift
lock.withLock {
    observers.forEach { $0.didChange(snapshot) }
}
```

An observer can re-enter, block, or acquire locks in the opposite order.

Copy under the lock and invoke afterward:

```swift
let callbacks = lock.withLock {
    Array(observers.values)
}

for callback in callbacks {
    callback.didChange(snapshot)
}
```

Apply the same rule to:

- continuation resume;
- task cancellation;
- delegate methods;
- notification posting;
- logging hooks that can call custom handlers;
- file/network I/O.

Never hold a synchronous lock across `await`.

## Queue-confined state

If existing code uses a serial queue as its authority, preserve that model unless it is defective:

```swift
final class Cache<Key: Hashable & Sendable, Value: Sendable>: @unchecked Sendable {
    private let queue = DispatchQueue(label: "RepoPrompt.Cache")
    private var values: [Key: Value] = [:]

    func value(for key: Key) -> Value? {
        queue.sync { values[key] }
    }

    func store(_ value: Value, for key: Key) {
        queue.sync { values[key] = value }
    }
}
```

Required review:

- every access uses the same queue;
- no method synchronously re-enters the queue;
- captured `Key` and `Value` semantics are understood;
- callbacks are dispatched after leaving the queue;
- queue confinement is documented as the reason for `@unchecked Sendable`.

Do not mechanically replace a proven queue with an actor in a bounded diagnostic fix; executor and ordering behavior can change.

## Objective-C or delegate callback to MainActor

When the imported protocol cannot express actor isolation, keep the bridge at the conformance boundary:

```swift
@MainActor
final class DownloadDelegate: NSObject, LegacyDownloadDelegate {
    weak var owner: DownloadOwner?

    nonisolated func downloadDidProgress(_ progress: Double) {
        Task { @MainActor [weak self] in
            self?.owner?.updateProgress(progress)
        }
    }
}

@MainActor
protocol DownloadOwner: AnyObject {
    func updateProgress(_ progress: Double)
}
```

Invariant: the imported callback may arrive on any thread; the only use of the UI owner occurs on the main actor.

Confirm whether the Objective-C framework already guarantees main-thread callbacks. Even when it does, a static actor bridge is preferable if the protocol shape permits it.

## Runtime isolation assertion

`MainActor.assumeIsolated` does not perform a hop. Use it only when an external synchronous contract guarantees main-actor execution but the type system cannot express it:

```swift
nonisolated func applicationDidActivate(_ notification: Notification) {
    precondition(Thread.isMainThread)

    MainActor.assumeIsolated {
        model.handleActivation(notification)
    }
}
```

This is a narrow interoperability escape hatch, not a general replacement for `await MainActor.run`.

Ledger requirements:

- cite the framework/thread guarantee;
- explain why the callback must remain synchronous;
- keep the assertion at the imported boundary;
- add a test or precondition that fails when the guarantee is violated;
- name the condition under which the assertion can be removed.

Main-thread execution and main-actor isolation are related in app code but not universally interchangeable; revalidate for each callback contract.

## `@preconcurrency` import boundary

Use `@preconcurrency import` only for a module whose annotations are incomplete and outside this change's control:

```swift
@preconcurrency import LegacySDK
```

It suppresses or defers some checking at the import boundary; it does not make imported values thread-safe.

Before adding it:

1. identify the exact imported declarations producing diagnostics;
2. check whether a newer dependency version supplies concurrency annotations;
3. wrap the smallest API surface behind an actor, lock, or immutable snapshot;
4. record the dependency/version and removal trigger;
5. add focused behavior coverage for the wrapper.

Avoid applying `@preconcurrency` to first-party modules that can express the real contract.

## Callback-to-async bridge ownership

Keep a non-Sendable SDK object confined inside a wrapper and export `Sendable` values:

```swift
actor CredentialService {
    private let sdk: LegacyCredentialSDK

    init(sdk: LegacyCredentialSDK) {
        self.sdk = sdk
    }

    func credential() async throws -> CredentialSnapshot {
        let raw = try await loadRawCredential()
        return CredentialSnapshot(
            token: raw.token,
            expiration: raw.expiration
        )
    }

    private func loadRawCredential() async throws -> LegacyCredential {
        try await withCheckedThrowingContinuation { continuation in
            sdk.loadCredential { result in
                continuation.resume(with: result)
            }
        }
    }
}

struct CredentialSnapshot: Sendable {
    let token: String
    let expiration: Date
}
```

This simple bridge is valid only if the SDK guarantees exactly one callback and needs no cancellation. Otherwise use the state-machine pattern in `tasks-cancellation-continuations-samples.md`.

## C and opaque pointer boundaries

Do not mark a raw or opaque pointer `Sendable` merely because its numeric address can be copied.

Choose an ownership model:

- actor-confine the entire C object lifecycle;
- keep access behind one serial queue;
- wrap a library-documented thread-safe handle with a lock-backed invariant;
- copy bytes into a `Sendable` value before crossing.

Example actor confinement:

```swift
actor ParserHandle {
    private var raw: OpaquePointer?

    init() throws {
        raw = try createParser()
    }

    deinit {
        if let raw {
            destroyParser(raw)
        }
    }

    func parse(_ bytes: [UInt8]) throws -> ParseSummary {
        guard let raw else { throw ParserError.closed }
        return try parseBytes(raw, bytes)
    }
}
```

Verify the C library's lifecycle and thread-safety documentation. Actor confinement cannot repair an API that invokes callbacks concurrently into unmanaged shared state.

## Synchronization review checklist

- What exact state is protected?
- Is there one authority for every access?
- Can the critical section call arbitrary code, resume a continuation, cancel work, perform I/O, or suspend?
- Can lock/queue acquisition re-enter or invert another lock order?
- Is `@unchecked Sendable` documented beside the invariant?
- Is a runtime actor assertion backed by a synchronous external guarantee?
- Does `@preconcurrency` have a dependency/version-specific removal trigger?
- Are Objective-C/C callbacks and handle lifetimes tested at success, failure, cancellation, and teardown boundaries?
