import Foundation

package struct MCPDomainConnectionCallAdmissionEntry: Sendable {
    package let limiters: MCPDomainConnectionCallLimiters
    package let replacementGeneration: UInt64
}

/// Protocol-neutral owner for per-connection lane bundles and their replacement generations.
/// Transport shells may keep connection identity and admission policy, but all lane bundle
/// publication, lookup, replacement, and removal crosses this synchronized owner.
package final class MCPDomainConnectionCallAdmissionRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [UUID: MCPDomainConnectionCallAdmissionEntry] = [:]
    private var nextReplacementGenerationByConnectionID: [UUID: UInt64] = [:]

    package init() {}

    package subscript(connectionID: UUID) -> MCPDomainConnectionCallLimiters? {
        get { lock.withLock { entries[connectionID]?.limiters } }
        set {
            lock.withLock {
                guard let newValue else {
                    entries.removeValue(forKey: connectionID)
                    return
                }
                let generation = nextReplacementGenerationByConnectionID[connectionID, default: 0] &+ 1
                nextReplacementGenerationByConnectionID[connectionID] = generation
                entries[connectionID] = MCPDomainConnectionCallAdmissionEntry(
                    limiters: newValue,
                    replacementGeneration: generation
                )
            }
        }
    }

    @discardableResult
    package func removeValue(forKey connectionID: UUID) -> MCPDomainConnectionCallLimiters? {
        lock.withLock { entries.removeValue(forKey: connectionID)?.limiters }
    }

    package func snapshot() -> [UUID: MCPDomainConnectionCallLimiters] {
        lock.withLock { entries.mapValues(\.limiters) }
    }

    package func entry(for connectionID: UUID) -> MCPDomainConnectionCallAdmissionEntry? {
        lock.withLock { entries[connectionID] }
    }

    package func removeAll() {
        lock.withLock { entries.removeAll(keepingCapacity: true) }
    }
}

package enum MCPDomainConnectionCallLane: String, CaseIterable, Sendable {
    case ordinary
    case control
    case smallRead = "small_read"
    case fileRead = "file_read"
    case gitRead = "git_read"
    case fileSearch = "file_search"
}

package struct MCPDomainConnectionCallLimiterWatchdogDiagnostics: Sendable {
    package let admittedCallCount: Int
}

package actor MCPDomainConnectionCallLimiters {
    package struct AdmissionRejected: Error {}

    private enum AdmissionCloseState {
        case open
        case tentative
        case restored(MCPDomainConnectionCallLimiters)
        case committed
    }

    private let ordinary: MCPDomainAsyncLimiter
    private let control: MCPDomainAsyncLimiter
    private let smallRead: MCPDomainAsyncLimiter
    private let fileRead: MCPDomainAsyncLimiter
    private let gitRead: MCPDomainAsyncLimiter
    private let fileSearch: MCPDomainAsyncLimiter
    private var admittedCallCount = 0
    private var admissionCloseState: AdmissionCloseState = .open
    private var admissionRetryWaiters: [UUID: CheckedContinuation<MCPDomainConnectionCallLimiters?, Never>] = [:]

    #if DEBUG
        package init(
            limit: Int,
            controlLimit: Int,
            smallReadLimit: Int,
            fileReadLimit: Int,
            gitReadLimit: Int,
            fileSearchLimit: Int,
            idleWaitSleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
                try await Task.sleep(for: duration)
            }
        ) {
            ordinary = MCPDomainAsyncLimiter(limit: limit, idleWaitSleep: idleWaitSleep)
            control = MCPDomainAsyncLimiter(limit: controlLimit, idleWaitSleep: idleWaitSleep)
            smallRead = MCPDomainAsyncLimiter(limit: smallReadLimit, idleWaitSleep: idleWaitSleep)
            fileRead = MCPDomainAsyncLimiter(limit: fileReadLimit, idleWaitSleep: idleWaitSleep)
            gitRead = MCPDomainAsyncLimiter(limit: gitReadLimit, idleWaitSleep: idleWaitSleep)
            fileSearch = MCPDomainAsyncLimiter(limit: fileSearchLimit, idleWaitSleep: idleWaitSleep)
        }
    #else
        package init(limit: Int, controlLimit: Int, smallReadLimit: Int, fileReadLimit: Int, gitReadLimit: Int, fileSearchLimit: Int) {
            ordinary = MCPDomainAsyncLimiter(limit: limit)
            control = MCPDomainAsyncLimiter(limit: controlLimit)
            smallRead = MCPDomainAsyncLimiter(limit: smallReadLimit)
            fileRead = MCPDomainAsyncLimiter(limit: fileReadLimit)
            gitRead = MCPDomainAsyncLimiter(limit: gitReadLimit)
            fileSearch = MCPDomainAsyncLimiter(limit: fileSearchLimit)
        }
    #endif

    package func withPermit<T: Sendable>(
        lane: MCPDomainConnectionCallLane,
        cancellationResult: @Sendable () -> T,
        _ operation: @Sendable () async -> T
    ) async -> T {
        guard case .open = admissionCloseState else { return cancellationResult() }
        admittedCallCount += 1
        defer { admittedCallCount -= 1 }
        return await limiter(for: lane).withPermit(
            cancellationResult: cancellationResult,
            operation
        )
    }

    package func withPermit<T: Sendable>(
        lane: MCPDomainConnectionCallLane,
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        guard case .open = admissionCloseState else { throw AdmissionRejected() }
        admittedCallCount += 1
        defer { admittedCallCount -= 1 }
        return try await limiter(for: lane).withPermit(operation)
    }

    package func hasInFlightCalls() -> Bool {
        admittedCallCount > 0
    }

    package func executionWatchdogDiagnostics() -> MCPDomainConnectionCallLimiterWatchdogDiagnostics {
        MCPDomainConnectionCallLimiterWatchdogDiagnostics(admittedCallCount: admittedCallCount)
    }

    package func admissionRetryReplacement() async -> MCPDomainConnectionCallLimiters? {
        guard !Task.isCancelled else { return nil }
        switch admissionCloseState {
        case .open, .committed:
            return nil
        case let .restored(replacement):
            return replacement
        case .tentative:
            return await waitForAdmissionCloseOutcome()
        }
    }

    package func markTentativeCloseRestored(by replacement: MCPDomainConnectionCallLimiters) {
        guard case .tentative = admissionCloseState else { return }
        admissionCloseState = .restored(replacement)
        resumeAdmissionRetryWaiters(with: replacement)
    }

    package func markTentativeCloseCommitted() {
        guard case .tentative = admissionCloseState else { return }
        admissionCloseState = .committed
        resumeAdmissionRetryWaiters(with: nil)
    }

    package func cancelAll() async {
        switch admissionCloseState {
        case .open, .tentative:
            admissionCloseState = .committed
            resumeAdmissionRetryWaiters(with: nil)
        case .restored, .committed:
            break
        }
        await closeLanes()
    }

    #if DEBUG
        package func closeIfIdle(
            afterClosingBegan: (@Sendable () async -> Void)? = nil
        ) async -> Bool {
            guard case .open = admissionCloseState, admittedCallCount == 0 else { return false }
            admissionCloseState = .tentative
            if let afterClosingBegan {
                await afterClosingBegan()
            }
            await closeLanes()
            return true
        }
    #else
        package func closeIfIdle() async -> Bool {
            guard case .open = admissionCloseState, admittedCallCount == 0 else { return false }
            admissionCloseState = .tentative
            await closeLanes()
            return true
        }
    #endif

    package func waitUntilIdle(timeout: Duration) async -> [(MCPDomainConnectionCallLane, Bool)] {
        await withTaskGroup(of: (MCPDomainConnectionCallLane, Bool).self) { group in
            for (lane, limiter) in lanes {
                group.addTask {
                    await (lane, limiter.waitUntilIdle(timeout: timeout))
                }
            }
            var results: [(MCPDomainConnectionCallLane, Bool)] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
    }

    #if DEBUG
        package func limiterForTesting(_ lane: MCPDomainConnectionCallLane) -> MCPDomainAsyncLimiter {
            limiter(for: lane)
        }

        package func diagnosticsSnapshot() async -> MCPDomainConnectionCallLimiterDebugSnapshot {
            async let ordinarySnapshot = ordinary.debugSnapshot()
            async let controlSnapshot = control.debugSnapshot()
            async let smallReadSnapshot = smallRead.debugSnapshot()
            async let fileReadSnapshot = fileRead.debugSnapshot()
            async let gitReadSnapshot = gitRead.debugSnapshot()
            async let fileSearchSnapshot = fileSearch.debugSnapshot()
            return await MCPDomainConnectionCallLimiterDebugSnapshot(
                ordinary: ordinarySnapshot,
                control: controlSnapshot,
                smallRead: smallReadSnapshot,
                fileRead: fileReadSnapshot,
                gitRead: gitReadSnapshot,
                fileSearch: fileSearchSnapshot
            )
        }

        package func diagnosticsSnapshot(for lane: MCPDomainConnectionCallLane) async -> MCPDomainAsyncLimiter.DebugSnapshot {
            await limiter(for: lane).debugSnapshot()
        }

        package func admissionRetryWaiterCountForTesting() -> Int {
            admissionRetryWaiters.count
        }
    #endif

    private func waitForAdmissionCloseOutcome() async -> MCPDomainConnectionCallLimiters? {
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                switch admissionCloseState {
                case .open, .committed:
                    continuation.resume(returning: nil)
                case let .restored(replacement):
                    continuation.resume(returning: replacement)
                case .tentative:
                    admissionRetryWaiters[waiterID] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelAdmissionRetryWaiter(waiterID) }
        }
    }

    private func cancelAdmissionRetryWaiter(_ waiterID: UUID) {
        admissionRetryWaiters.removeValue(forKey: waiterID)?.resume(returning: nil)
    }

    private func resumeAdmissionRetryWaiters(with replacement: MCPDomainConnectionCallLimiters?) {
        let waiters = Array(admissionRetryWaiters.values)
        admissionRetryWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: replacement)
        }
    }

    private func closeLanes() async {
        async let cancelOrdinary: Void = ordinary.cancelAll()
        async let cancelControl: Void = control.cancelAll()
        async let cancelSmallRead: Void = smallRead.cancelAll()
        async let cancelFileRead: Void = fileRead.cancelAll()
        async let cancelGitRead: Void = gitRead.cancelAll()
        async let cancelFileSearch: Void = fileSearch.cancelAll()
        _ = await (cancelOrdinary, cancelControl, cancelSmallRead, cancelFileRead, cancelGitRead, cancelFileSearch)
    }

    private func limiter(for lane: MCPDomainConnectionCallLane) -> MCPDomainAsyncLimiter {
        switch lane {
        case .ordinary:
            ordinary
        case .control:
            control
        case .smallRead:
            smallRead
        case .fileRead:
            fileRead
        case .gitRead:
            gitRead
        case .fileSearch:
            fileSearch
        }
    }

    private var lanes: [(MCPDomainConnectionCallLane, MCPDomainAsyncLimiter)] {
        [
            (.ordinary, ordinary),
            (.control, control),
            (.smallRead, smallRead),
            (.fileRead, fileRead),
            (.gitRead, gitRead),
            (.fileSearch, fileSearch)
        ]
    }
}


#if DEBUG
package struct MCPDomainConnectionCallLimiterDebugSnapshot: Equatable, Sendable {
    package let ordinary: MCPDomainAsyncLimiter.DebugSnapshot
    package let control: MCPDomainAsyncLimiter.DebugSnapshot
    package let smallRead: MCPDomainAsyncLimiter.DebugSnapshot
    package let fileRead: MCPDomainAsyncLimiter.DebugSnapshot
    package let gitRead: MCPDomainAsyncLimiter.DebugSnapshot
    package let fileSearch: MCPDomainAsyncLimiter.DebugSnapshot

    package var laneCount: Int {
        MCPDomainConnectionCallLane.allCases.count
    }

    package var limit: Int {
        ordinary.limit + control.limit + smallRead.limit + fileRead.limit + gitRead.limit + fileSearch.limit
    }

    package var permits: Int {
        ordinary.permits + control.permits + smallRead.permits + fileRead.permits + gitRead.permits + fileSearch.permits
    }

    package var activePermitCount: Int {
        ordinary.activePermitCount + control.activePermitCount + smallRead.activePermitCount + fileRead.activePermitCount + gitRead.activePermitCount + fileSearch.activePermitCount
    }

    package var waiterCount: Int {
        ordinary.waiterCount + control.waiterCount + smallRead.waiterCount + fileRead.waiterCount + gitRead.waiterCount + fileSearch.waiterCount
    }

    package var inFlight: Int {
        ordinary.inFlight + control.inFlight + smallRead.inFlight + fileRead.inFlight + gitRead.inFlight + fileSearch.inFlight
    }

    package var oldestWaiterAgeMilliseconds: UInt64? {
        [
            ordinary.oldestWaiterAgeMilliseconds,
            control.oldestWaiterAgeMilliseconds,
            smallRead.oldestWaiterAgeMilliseconds,
            fileRead.oldestWaiterAgeMilliseconds,
            gitRead.oldestWaiterAgeMilliseconds,
            fileSearch.oldestWaiterAgeMilliseconds
        ]
        .compactMap(\.self)
        .max()
    }

    package var cancelledWaiterCount: Int {
        ordinary.cancelledWaiterCount + control.cancelledWaiterCount + smallRead.cancelledWaiterCount + fileRead.cancelledWaiterCount + gitRead.cancelledWaiterCount + fileSearch.cancelledWaiterCount
    }

    package var isClosed: Bool {
        ordinary.isClosed && control.isClosed && smallRead.isClosed && fileRead.isClosed && gitRead.isClosed && fileSearch.isClosed
    }

    package var isIdle: Bool {
        ordinary.isIdle && control.isIdle && smallRead.isIdle && fileRead.isIdle && gitRead.isIdle && fileSearch.isIdle
    }
}
#endif

/// Cancellation-aware async semaphore used to serialize calls per connection.
package actor MCPDomainAsyncLimiter {
private struct Waiter {
    let id: UUID
    let continuation: CheckedContinuation<Void, Error>
    let enqueuedAtNanoseconds: UInt64
    var previousID: UUID?
    var nextID: UUID?
}

private let limit: Int
private var permits: Int
private var activePermitCount = 0
private var inFlight = 0
private var isClosed = false
private var waiterByID: [UUID: Waiter] = [:]
private var firstWaiterID: UUID?
private var lastWaiterID: UUID?
private var idleWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
private var cancelledWaiterCount = 0
private let idleWaitSleep: @Sendable (Duration) async throws -> Void

#if DEBUG
    package struct DebugSnapshot: Equatable, Sendable {
        package let limit: Int
        package let permits: Int
        package let activePermitCount: Int
        package let waiterCount: Int
        package let inFlight: Int
        package let oldestWaiterAgeMilliseconds: UInt64?
        package let cancelledWaiterCount: Int
        package let isClosed: Bool
        package let isIdle: Bool

        package init(
            limit: Int,
            permits: Int,
            activePermitCount: Int,
            waiterCount: Int,
            inFlight: Int,
            oldestWaiterAgeMilliseconds: UInt64?,
            cancelledWaiterCount: Int,
            isClosed: Bool,
            isIdle: Bool
        ) {
            self.limit = limit
            self.permits = permits
            self.activePermitCount = activePermitCount
            self.waiterCount = waiterCount
            self.inFlight = inFlight
            self.oldestWaiterAgeMilliseconds = oldestWaiterAgeMilliseconds
            self.cancelledWaiterCount = cancelledWaiterCount
            self.isClosed = isClosed
            self.isIdle = isIdle
        }
    }

    private let debugNowNanoseconds: @Sendable () -> UInt64
    private var debugStateObserver: ((DebugSnapshot) -> Void)?
    private var debugQueuedPermitHandoffHandler: (@Sendable () async -> Void)?
#endif

#if DEBUG
    package init(
        limit: Int,
        debugNowNanoseconds: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        idleWaitSleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        self.limit = max(1, limit)
        permits = max(1, limit)
        self.debugNowNanoseconds = debugNowNanoseconds
        self.idleWaitSleep = idleWaitSleep
    }
#else
    package init(limit: Int) {
        self.limit = max(1, limit)
        permits = max(1, limit)
        idleWaitSleep = { duration in
            try await Task.sleep(for: duration)
        }
    }
#endif

private func acquirePermit() async throws {
    try Task.checkCancellation()
    guard !isClosed else { throw CancellationError() }

    if permits > 0 {
        permits -= 1
        activePermitCount += 1
        notifyDebugStateChanged()
        return
    }

    let waiterID = UUID()
    try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            guard !isClosed else {
                continuation.resume(throwing: CancellationError())
                return
            }
            appendWaiter(Waiter(
                id: waiterID,
                continuation: continuation,
                enqueuedAtNanoseconds: currentDebugNanoseconds(),
                previousID: lastWaiterID,
                nextID: nil
            ))
            notifyDebugStateChanged()
        }
    } onCancel: {
        Task { await self.cancelWaiter(waiterID) }
    }

    #if DEBUG
        if let debugQueuedPermitHandoffHandler {
            await debugQueuedPermitHandoffHandler()
        }
    #endif
    guard !isClosed else {
        releasePermit()
        throw CancellationError()
    }
}

private func appendWaiter(_ waiter: Waiter) {
    if let lastWaiterID, var lastWaiter = waiterByID[lastWaiterID] {
        lastWaiter.nextID = waiter.id
        waiterByID[lastWaiterID] = lastWaiter
    } else {
        firstWaiterID = waiter.id
    }
    waiterByID[waiter.id] = waiter
    lastWaiterID = waiter.id
}

@discardableResult
private func removeWaiter(_ waiterID: UUID) -> Waiter? {
    guard let waiter = waiterByID.removeValue(forKey: waiterID) else { return nil }
    if let previousID = waiter.previousID, var previous = waiterByID[previousID] {
        previous.nextID = waiter.nextID
        waiterByID[previousID] = previous
    } else {
        firstWaiterID = waiter.nextID
    }
    if let nextID = waiter.nextID, var next = waiterByID[nextID] {
        next.previousID = waiter.previousID
        waiterByID[nextID] = next
    } else {
        lastWaiterID = waiter.previousID
    }
    return waiter
}

private func popFirstWaiter() -> Waiter? {
    guard let firstWaiterID else { return nil }
    return removeWaiter(firstWaiterID)
}

private func cancelWaiter(_ waiterID: UUID) {
    guard let waiter = removeWaiter(waiterID) else { return }
    cancelledWaiterCount += 1
    waiter.continuation.resume(throwing: CancellationError())
    notifyDebugStateChanged()
}

private func releasePermit() {
    if let waiter = popFirstWaiter() {
        waiter.continuation.resume()
    } else {
        activePermitCount = max(0, activePermitCount - 1)
        permits = min(permits + 1, limit)
    }
    notifyDebugStateChanged()
}

/// Rejects new acquisitions and promptly cancels every queued waiter.
package func cancelAll() {
    isClosed = true
    while let waiter = popFirstWaiter() {
        cancelledWaiterCount += 1
        waiter.continuation.resume(throwing: CancellationError())
    }
    notifyDebugStateChanged()
    resumeIdleWaitersIfNeeded()
}

/// Waits until active owners and cancelled queued callers have left `withPermit`.
/// Returns `false` when the caller cancels its join; active owners are never force-released.
package func waitUntilIdle() async -> Bool {
    guard !Task.isCancelled else { return false }
    guard !isIdle else { return true }
    let waiterID = UUID()
    return await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
            guard !Task.isCancelled else {
                continuation.resume(returning: false)
                return
            }
            guard !isIdle else {
                continuation.resume(returning: true)
                return
            }
            idleWaiters[waiterID] = continuation
        }
    } onCancel: {
        Task { await self.cancelIdleWaiter(waiterID) }
    }
}

/// Gives active owners a bounded cooperative cleanup grace. A timed-out owner remains
/// attached only to this closed limiter and may settle later without blocking teardown.
package func waitUntilIdle(timeout: Duration) async -> Bool {
    guard !Task.isCancelled else { return false }
    guard !isIdle else { return true }
    let sleep = idleWaitSleep
    return await withTaskGroup(of: Bool?.self) { group in
        group.addTask { [weak self] in
            guard let self else { return true }
            return await waitUntilIdle()
        }
        group.addTask {
            do {
                try await sleep(timeout)
                return false
            } catch {
                return nil
            }
        }
        let first = await group.next() ?? false
        group.cancelAll()
        return first ?? false
    }
}

/// Number of active and queued operations (0 means idle).
package func activeCount() -> Int {
    inFlight
}

private var isIdle: Bool {
    inFlight == 0 && activePermitCount == 0 && waiterByID.isEmpty
}

private func cancelIdleWaiter(_ waiterID: UUID) {
    idleWaiters.removeValue(forKey: waiterID)?.resume(returning: false)
}

private func resumeIdleWaitersIfNeeded() {
    guard isIdle, !idleWaiters.isEmpty else { return }
    let continuations = Array(idleWaiters.values)
    idleWaiters.removeAll()
    for continuation in continuations {
        continuation.resume(returning: true)
    }
}

#if DEBUG
    package func debugSnapshot() -> DebugSnapshot {
        makeDebugSnapshot()
    }

    package func setDebugStateObserver(
        _ observer: ((DebugSnapshot) -> Void)?
    ) {
        debugStateObserver = observer
        observer?(makeDebugSnapshot())
    }

    package func setDebugQueuedPermitHandoffHandler(
        _ handler: (@Sendable () async -> Void)?
    ) {
        debugQueuedPermitHandoffHandler = handler
    }

    private func makeDebugSnapshot() -> DebugSnapshot {
        let now = debugNowNanoseconds()
        let oldestWaiterAgeMilliseconds = firstWaiterID
            .flatMap { waiterByID[$0] }
            .map { Self.elapsedMilliseconds(since: $0.enqueuedAtNanoseconds, now: now) }
        return DebugSnapshot(
            limit: limit,
            permits: permits,
            activePermitCount: activePermitCount,
            waiterCount: waiterByID.count,
            inFlight: inFlight,
            oldestWaiterAgeMilliseconds: oldestWaiterAgeMilliseconds,
            cancelledWaiterCount: cancelledWaiterCount,
            isClosed: isClosed,
            isIdle: isIdle
        )
    }

    private static func elapsedMilliseconds(since start: UInt64, now: UInt64) -> UInt64 {
        guard now >= start else { return 0 }
        return (now - start) / 1_000_000
    }

    private func currentDebugNanoseconds() -> UInt64 {
        debugNowNanoseconds()
    }

    private func notifyDebugStateChanged() {
        debugStateObserver?(makeDebugSnapshot())
    }
#else
    private func currentDebugNanoseconds() -> UInt64 {
        0
    }

    private func notifyDebugStateChanged() {}
#endif

/// Executes an operation with a permit, limiting concurrency.
package func withPermit<T: Sendable>(
    _ op: @Sendable () async throws -> T
) async throws -> T {
    inFlight += 1
    notifyDebugStateChanged()
    defer {
        inFlight -= 1
        notifyDebugStateChanged()
        resumeIdleWaitersIfNeeded()
    }

    try await acquirePermit()
    defer { releasePermit() }
    try Task.checkCancellation()
    return try await op()
}

package func withPermit<T: Sendable>(
    cancellationResult: @Sendable () -> T,
    _ op: @Sendable () async -> T
) async -> T {
    do {
        return try await withPermit {
            await op()
        }
    } catch {
        return cancellationResult()
    }
}
}
