import Foundation
import XCTest

// MARK: - Defaults

/// Shared timeout budgets for hang-hardened test fences.
/// Prefer these over ad-hoc 2s / 10s / 30s literals so suites stay consistent.
enum TestFenceDefaults {
    /// Waiting for a producer to mark "entered" / "started".
    static let enterWait: TimeInterval = 10
    /// Waiting for an explicit `release()` while parked in enter/block.
    static let releaseWait: TimeInterval = 30

    static let enterWaitDuration: Duration = .seconds(10)
    static let releaseWaitDuration: Duration = .seconds(30)

    static func timeInterval(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}

// MARK: - Async release fence

/// Hang-hardened async enter/release fence.
///
/// Guarantees:
/// - sticky cancel (cancel-before-register cannot park forever)
/// - synchronous `onCancel` via lock-backed state (no `Task { await }` hop)
/// - multi-waiter release parks (intentional; double-enter parks both until one `release()`)
/// - **cooperative** async `waitUntilEntered` (never blocks the calling executor)
/// - optional sync `waitUntilEntered` for true sync call sites only
///
/// Prefer this over local `AsyncGate` / `*ReleaseGate` clones.
final class TestReleaseFence: @unchecked Sendable {
    private let name: String
    private let condition = NSCondition()
    private var entered = false
    private var released = false
    private var continuations: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var cancelledWaiters = Set<UUID>()
    private var timedOutWaiters = Set<UUID>()

    init(name: String = "test release fence") {
        self.name = name
    }

    /// Mark entered, then park until `release()` (or sticky cancel / already released).
    func enterAndWait() async {
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                register(continuation, waiterID: waiterID)
            }
        } onCancel: {
            cancel(waiterID: waiterID)
        }
    }

    /// Mark entered, then park until `release()` while ignoring task cancellation.
    ///
    /// Use this only for tests whose contract is that a cancelled owner does not
    /// release the underlying body/resource until the test explicitly releases it.
    /// A retained/cancelled timeout fails open so a missed release cannot wedge the suite.
    func enterAndWaitIgnoringCancellationUntilRelease(
        timeout: TimeInterval = TestFenceDefaults.releaseWait
    ) async {
        let waiterID = UUID()
        let timeoutTask = Task.detached { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, timeout)))
            guard !Task.isCancelled else { return }
            self?.timeout(waiterID: waiterID, timeout: timeout)
        }
        await withCheckedContinuation { continuation in
            registerIgnoringCancellation(continuation, waiterID: waiterID)
        }
        timeoutTask.cancel()
        await timeoutTask.value
    }

    /// Alias used by older engine call sites (`EngineBuildGate.enter`).
    /// Multi-waiter: a second concurrent enter parks another waiter until `release()`.
    func enter() async {
        await enterAndWait()
    }

    /// Park without flipping entered (for multi-phase fences that mark entered separately).
    func waitUnlessReleased() async {
        guard !Task.isCancelled else { return }
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                registerParkOnly(continuation, waiterID: waiterID)
            }
        } onCancel: {
            cancel(waiterID: waiterID)
        }
    }

    /// Synchronous enter wait for **true sync call sites only**
    /// (e.g. from a DispatchQueue callback or another non-async context).
    /// Do **not** call this from an `async` function that also needs the enter producer
    /// on the same serial executor — use `await waitUntilEntered(...)` instead.
    @discardableResult
    func waitUntilEnteredBlocking(
        timeout: TimeInterval = TestFenceDefaults.enterWait,
        failOnTimeout: Bool = true
    ) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while !entered {
            guard condition.wait(until: deadline) else {
                if failOnTimeout {
                    XCTFail("Timed out waiting for \(name) to enter after \(String(format: "%.1f", timeout))s")
                }
                return false
            }
        }
        return true
    }

    /// Cooperative async enter wait — does **not** block the calling executor.
    @discardableResult
    func waitUntilEntered(
        timeout: TimeInterval,
        failOnTimeout: Bool = true
    ) async -> Bool {
        if hasEntered { return true }
        do {
            try await AsyncTestWait.waitUntil(
                "\(name) entered",
                timeout: timeout
            ) {
                self.hasEntered
            }
            return true
        } catch {
            if failOnTimeout {
                XCTFail(error.localizedDescription)
            }
            return hasEntered
        }
    }

    @discardableResult
    func waitUntilEntered(
        timeout: Duration = TestFenceDefaults.enterWaitDuration,
        failOnTimeout: Bool = true
    ) async -> Bool {
        await waitUntilEntered(
            timeout: TestFenceDefaults.timeInterval(timeout),
            failOnTimeout: failOnTimeout
        )
    }

    func release() {
        condition.lock()
        released = true
        let pending = Array(continuations.values)
        continuations.removeAll()
        cancelledWaiters.removeAll()
        timedOutWaiters.removeAll()
        condition.broadcast()
        condition.unlock()
        for continuation in pending {
            continuation.resume()
        }
    }

    var hasEntered: Bool {
        condition.lock()
        defer { condition.unlock() }
        return entered
    }

    var isReleased: Bool {
        condition.lock()
        defer { condition.unlock() }
        return released
    }

    // MARK: Private

    private func register(_ continuation: CheckedContinuation<Void, Never>, waiterID: UUID) {
        condition.lock()
        entered = true
        condition.broadcast()
        if released || Task.isCancelled || cancelledWaiters.remove(waiterID) != nil {
            condition.unlock()
            continuation.resume()
        } else {
            continuations[waiterID] = continuation
            condition.unlock()
        }
    }

    private func registerIgnoringCancellation(_ continuation: CheckedContinuation<Void, Never>, waiterID: UUID) {
        condition.lock()
        entered = true
        condition.broadcast()
        if released || timedOutWaiters.remove(waiterID) != nil {
            condition.unlock()
            continuation.resume()
        } else {
            continuations[waiterID] = continuation
            condition.unlock()
        }
    }

    private func registerParkOnly(_ continuation: CheckedContinuation<Void, Never>, waiterID: UUID) {
        condition.lock()
        if released || Task.isCancelled || cancelledWaiters.remove(waiterID) != nil {
            condition.unlock()
            continuation.resume()
        } else {
            continuations[waiterID] = continuation
            condition.unlock()
        }
    }

    private func cancel(waiterID: UUID) {
        condition.lock()
        let continuation = continuations.removeValue(forKey: waiterID)
        if continuation == nil {
            cancelledWaiters.insert(waiterID)
        }
        condition.broadcast()
        condition.unlock()
        continuation?.resume()
    }

    private func timeout(waiterID: UUID, timeout: TimeInterval) {
        condition.lock()
        let continuation = continuations.removeValue(forKey: waiterID)
        let shouldFail = continuation != nil || !released
        if continuation == nil, !released {
            timedOutWaiters.insert(waiterID)
        }
        condition.unlock()
        guard shouldFail else { return }
        XCTFail("Timed out waiting for \(name) release after \(String(format: "%.1f", timeout))s")
        continuation?.resume()
    }
}

// MARK: - Sync blocking fence

/// Hang-hardened synchronous enter/release fence (`NSCondition`).
///
/// Guarantees:
/// - bounded wait for `release()`
/// - XCTFail + fail-open on timeout so a missed `release()` cannot wedge the process
/// - `waitUntilEntered` defaults to XCTFail on timeout (aligned with `TestReleaseFence`)
final class TestBlockingFence: @unchecked Sendable {
    private let name: String
    private let condition = NSCondition()
    private var entered = false
    private var released = false

    init(name: String = "test blocking fence") {
        self.name = name
    }

    func enterAndWait(timeout: TimeInterval = TestFenceDefaults.releaseWait) {
        condition.lock()
        entered = true
        condition.broadcast()
        let deadline = Date().addingTimeInterval(timeout)
        while !released {
            guard condition.wait(until: deadline) else {
                XCTFail(
                    "Timed out waiting for \(name) release after \(String(format: "%.1f", timeout))s"
                )
                // Fail open: unblock the waiter so a missed release cannot hang later tests.
                released = true
                condition.broadcast()
                break
            }
        }
        condition.unlock()
    }

    @discardableResult
    func waitUntilEntered(
        timeout: TimeInterval = TestFenceDefaults.enterWait,
        failOnTimeout: Bool = true
    ) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while !entered {
            guard condition.wait(until: deadline) else {
                if failOnTimeout {
                    XCTFail(
                        "Timed out waiting for \(name) to enter after \(String(format: "%.1f", timeout))s"
                    )
                }
                return false
            }
        }
        return true
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

// MARK: - Cancellation probe gate

/// Hang-hardened cancellation handshake for tests that cancel cooperative work mid-flight.
///
/// Guarantees:
/// - sticky cancel (cancel-before-register fails closed with `CancellationError`)
/// - synchronous `onCancel` via lock-backed state (no `Task { await }` hop)
/// - multi-waiter support (each waiter has its own sticky id)
/// - always marks entered before cancel branching so `waitUntilEntered` cannot hang
/// - bounded cooperative `waitUntilEntered`
/// - `forceCancel()` for teardown / observation
final class TestCancellationGate: @unchecked Sendable {
    private let name: String
    private let lock = NSLock()
    private var entered = false
    private var cancelled = false
    private var storedCancellationCount = 0
    private var continuations: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var cancelledWaiters = Set<UUID>()

    init(name: String = "test cancellation gate") {
        self.name = name
    }

    var cancellationCount: Int {
        lock.withLock { storedCancellationCount }
    }

    /// Test/debug entry visibility for wrappers that rethrow typed timeout errors.
    var hasEnteredForTesting: Bool {
        lock.withLock { entered }
    }

    func waitUntilCancelled() async throws {
        try Task.checkCancellation()
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // Registration only fails closed (CancellationError) or parks; never .success.
                var failError: Error?
                lock.lock()
                entered = true
                if cancelled || Task.isCancelled || cancelledWaiters.remove(waiterID) != nil {
                    failError = CancellationError()
                } else {
                    continuations[waiterID] = continuation
                }
                lock.unlock()

                if let failError {
                    continuation.resume(throwing: failError)
                }
            }
        } onCancel: {
            cancel(waiterID: waiterID)
        }
    }

    @discardableResult
    func waitUntilEntered(
        timeout: TimeInterval = TestFenceDefaults.enterWait,
        failOnTimeout: Bool = true
    ) async -> Bool {
        if hasEnteredForTesting { return true }
        do {
            try await AsyncTestWait.waitUntil(
                "\(name) entered",
                timeout: timeout
            ) {
                self.hasEnteredForTesting
            }
            return true
        } catch {
            if failOnTimeout {
                XCTFail(error.localizedDescription)
            }
            return hasEnteredForTesting
        }
    }

    /// Explicit cancel for cleanup paths that are not driven by `Task.cancel()`.
    /// Cancels all parked waiters and stamps sticky cancel for late registrants.
    func forceCancel() {
        lock.lock()
        let alreadyCancelled = cancelled
        cancelled = true
        if !alreadyCancelled {
            storedCancellationCount += 1
        }
        let pending = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()
        for continuation in pending {
            continuation.resume(throwing: CancellationError())
        }
    }

    // MARK: Private

    private func cancel(waiterID: UUID) {
        lock.lock()
        let alreadyCancelled = cancelled
        cancelled = true
        if !alreadyCancelled {
            storedCancellationCount += 1
        }
        let continuation = continuations.removeValue(forKey: waiterID)
        if continuation == nil {
            cancelledWaiters.insert(waiterID)
        }
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
    }
}
