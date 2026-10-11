import Foundation

/// Typed acquisition failures carry no transport bodies, credentials, or account identifiers.
package enum ProviderQuotaReadError: Error, Equatable {
    case signInRequired
    case insufficientScope
    case needsConsent
    case rateLimited(until: Date)
    case invalidResponse
    case accountInvalidated(retryAt: Date?)
    case transport
    case cliUnavailable

    package var message: String {
        switch self {
        case .signInRequired: "Sign in to the provider, then refresh usage."
        case .insufficientScope: "This sign-in cannot read usage limits. Sign in through the provider CLI."
        case .needsConsent: "Connect account usage to allow read-only access."
        case .rateLimited: "Usage requests are temporarily rate limited. Try again later."
        case .invalidResponse: "The provider did not report readable usage limits."
        case .accountInvalidated: "Usage is not available for the current account. Refresh to try again."
        case .transport: "Usage limits are not available right now."
        case .cliUnavailable: "Claude Code is not ready to read usage. Check installation, sign-in, and helper-folder trust, then refresh."
        }
    }
}

package struct ProviderQuotaReadContext {
    package let userInitiated: Bool
    package let expectedAccount: ProviderAccountKey?
    package init(userInitiated: Bool, expectedAccount: ProviderAccountKey? = nil) {
        self.userInitiated = userInitiated
        self.expectedAccount = expectedAccount
    }
}

/// Reusable snapshot-read coordinator. It owns admission, single-flight, backoff, publication,
/// and generation fencing; the injected source owns all concrete IO. Automatic reads exist
/// only during explicit observer demand, at the conservative provider floor.
package actor ProviderAccountQuotaService: ProviderQuotaObserving {
    package typealias Read = @Sendable (ProviderQuotaReadContext) async throws -> ProviderQuotaSnapshot
    private let read: Read
    private let now: @Sendable () -> Date
    private let automaticInterval: TimeInterval
    private let manualInterval: TimeInterval
    private let periodicReads: Bool
    private let cachedRead: (@Sendable () async -> ProviderQuotaSnapshot?)?
    private var hydration: Task<ProviderQuotaSnapshot?, Never>?
    private var automaticConsumed = false
    private var enabled = false
    private var generation: UInt64 = 0
    private var status: ProviderQuotaStatus = .disabled
    private var snapshot: ProviderQuotaSnapshot?
    private var observers: [UUID: AsyncStream<ProviderQuotaStatus>.Continuation] = [:]
    private var inFlight: (id: UUID, task: Task<Void, Never>)?
    private var lastAttempt: Date?
    private var blockedUntil: Date?
    private var failureCount = 0
    private var cadenceTask: Task<Void, Never>?
    private var advisoryAdmissionPending: UUID?
    private var advisoryRead: (requestID: UUID, readID: UUID)?

    package init(
        automaticInterval: TimeInterval = 900,
        manualInterval: TimeInterval = 60,
        periodicReads: Bool = true,
        cachedRead: (@Sendable () async -> ProviderQuotaSnapshot?)? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        read: @escaping Read
    ) {
        self.automaticInterval = automaticInterval
        self.manualInterval = manualInterval
        self.periodicReads = periodicReads
        self.cachedRead = cachedRead
        self.now = now
        self.read = read
    }

    package func latestSnapshot() async -> ProviderQuotaSnapshot? {
        snapshot
    }

    package func setEnabled(_ enabled: Bool) {
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        invalidate()
        if enabled, !observers.isEmpty { scheduleAutomaticRead()
            startCadenceIfNeeded()
        }
    }

    package func invalidate() {
        generation &+= 1
        advisoryAdmissionPending = nil
        advisoryRead = nil
        hydration?.cancel()
        hydration = nil
        automaticConsumed = false
        cadenceTask?.cancel()
        cadenceTask = nil
        inFlight?.task.cancel()
        inFlight = nil
        snapshot = nil
        lastAttempt = nil
        blockedUntil = nil
        failureCount = 0
        publish(enabled ? .idle : .disabled)
        if enabled, !observers.isEmpty { scheduleAutomaticRead()
            startCadenceIfNeeded()
        }
    }

    package func shutdown() {
        setEnabled(false)
    }

    package func subscribe() -> AsyncStream<ProviderQuotaStatus> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<ProviderQuotaStatus>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[id] = continuation
        continuation.yield(status)
        continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        if enabled { scheduleAutomaticRead()
            startCadenceIfNeeded()
        }
        return stream
    }

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
        guard observers.isEmpty else { return }
        generation &+= 1
        advisoryAdmissionPending = nil
        advisoryRead = nil
        hydration?.cancel()
        hydration = nil
        cadenceTask?.cancel()
        cadenceTask = nil
        inFlight?.task.cancel()
        inFlight = nil
        // Preserve cached readings and admission gates across brief view/window transitions.
        publish(snapshot.map(ProviderQuotaStatus.loaded) ?? (enabled ? .idle : .disabled))
    }

    private func scheduleAutomaticRead() {
        Task { await performRead(userInitiated: false) }
    }

    private func startCadenceIfNeeded() {
        guard periodicReads, cadenceTask == nil, enabled, !observers.isEmpty else { return }
        cadenceTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let delay = await self?.automaticReadDelay() else { return }
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                await performRead(userInitiated: false)
            }
        }
    }

    private func automaticReadDelay() -> TimeInterval {
        Self.nextAutomaticDelay(lastAttempt: lastAttempt, blockedUntil: blockedUntil, now: now(), interval: automaticInterval)
    }

    /// Schedule against the admission deadline, not a second independently-started interval.
    /// A slightly early tick sleeps only the remaining gap rather than skipping a whole cycle.
    /// The 15-minute read floor is preserved, not weakened to compensate for timer ordering.
    package nonisolated static func nextAutomaticDelay(lastAttempt: Date?, blockedUntil: Date?, now: Date, interval: TimeInterval) -> TimeInterval {
        var deadline = lastAttempt?.addingTimeInterval(interval) ?? now.addingTimeInterval(interval)
        if let blockedUntil { deadline = max(deadline, blockedUntil) }
        return max(1, deadline.timeIntervalSince(now))
    }

    package func refreshNow() async {
        await performRead(userInitiated: true)
    }

    package func refreshOnForeground() async {
        await performRead(userInitiated: false)
    }

    /// Display-driven refresh of a reading the caller judged stale. It is the only automatic
    /// trigger allowed past the one-startup-read latch of a `periodicReads: false` source, and
    /// it keeps every other automatic gate: live observer, single flight (joins an in-flight
    /// read), failure backoff, and the `automaticInterval` gap since the last attempt of any
    /// kind (15 minutes by default).
    package func refreshAutomatically(didStart: (@Sendable () async -> Void)?) async {
        await performRead(userInitiated: false, bypassStartupLatch: true, didStart: didStart)
    }

    /// Activity-driven refresh, independent of the one-startup-read latch. Admission is
    /// durable and provided by the consumer; ordinary single-flight/backoff still wins.
    package func refreshForAdvisory(requestID: UUID = UUID(), admission: @Sendable () async -> Bool) async {
        guard enabled, !observers.isEmpty, inFlight == nil, advisoryAdmissionPending == nil,
              blockedUntil.map({ now() >= $0 }) ?? true,
              lastAttempt.map({ now().timeIntervalSince($0) >= automaticInterval }) ?? true else { return }
        let expected = generation
        advisoryAdmissionPending = requestID
        let admitted = await admission()
        guard advisoryAdmissionPending == requestID else { return }
        advisoryAdmissionPending = nil
        guard admitted, generation == expected, !Task.isCancelled else { return }
        await performRead(userInitiated: false, advisoryRequestID: requestID)
    }

    package func cancelAdvisoryRefresh(requestID: UUID) {
        if advisoryAdmissionPending == requestID { advisoryAdmissionPending = nil }
        guard let advisoryRead, advisoryRead.requestID == requestID, inFlight?.id == advisoryRead.readID else { return }
        generation &+= 1
        inFlight?.task.cancel()
        inFlight = nil
        self.advisoryRead = nil
        publish(snapshot.map(ProviderQuotaStatus.loaded) ?? (enabled ? .idle : .disabled))
    }

    private func hydrateIfNeeded() async {
        guard enabled, !observers.isEmpty, snapshot == nil, let cachedRead else { return }
        let expected = generation
        let task: Task<ProviderQuotaSnapshot?, Never>
        if let hydration { task = hydration }
        else {
            task = Task { await cachedRead() }
            hydration = task
        }
        let value = await task.value
        guard generation == expected, enabled, !observers.isEmpty, !Task.isCancelled else { return }
        hydration = nil
        if snapshot == nil, let value, value.source != .claudeSDKEvent {
            snapshot = value
            publish(.loaded(value))
        }
    }

    private func performRead(
        userInitiated: Bool,
        advisoryRequestID: UUID? = nil,
        bypassStartupLatch: Bool = false,
        didStart: (@Sendable () async -> Void)? = nil
    ) async {
        await hydrateIfNeeded()
        guard enabled, !observers.isEmpty, !Task.isCancelled else { return }
        if !userInitiated, advisoryRequestID == nil, !bypassStartupLatch, !periodicReads, automaticConsumed { return }
        if let inFlight { await inFlight.task.value
            return
        }
        let currentTime = now()
        if let blockedUntil, currentTime < blockedUntil { return }
        let interval = userInitiated ? manualInterval : automaticInterval
        if let lastAttempt, currentTime.timeIntervalSince(lastAttempt) < interval { return }
        lastAttempt = currentTime
        if snapshot == nil { publish(.loading) }
        let expectedGeneration = generation
        let id = UUID()
        advisoryRead = advisoryRequestID.map { (requestID: $0, readID: id) }
        let expectedAccount = snapshot?.accountKey
        let task = Task { [weak self, read] in
            do {
                let value = try await read(ProviderQuotaReadContext(userInitiated: userInitiated, expectedAccount: expectedAccount))
                try Task.checkCancellation()
                await self?.finish(value, generation: expectedGeneration)
            } catch is CancellationError {
                // Cancellation is teardown, not evidence of provider failure.
            } catch {
                await self?.fail(error as? ProviderQuotaReadError ?? .transport, generation: expectedGeneration)
            }
        }
        inFlight = (id, task)
        // Registered as in flight first, so a reentrant caller during this hop joins it.
        await didStart?()
        await task.value
        if inFlight?.id == id { inFlight = nil }
    }

    private func finish(_ value: ProviderQuotaSnapshot, generation expected: UInt64) {
        guard enabled, generation == expected, !observers.isEmpty else { return }
        // Account reads are full replacements. Never merge different profiles/accounts or SDK telemetry.
        guard value.source != .claudeSDKEvent else {
            fail(.invalidResponse, generation: expected)
            return
        }
        if !periodicReads { automaticConsumed = true }
        snapshot = value
        failureCount = 0
        blockedUntil = nil
        // Concrete IO has completed. Release admission before publishing a terminal status,
        // so a subscriber's next explicit action cannot coalesce with a finished request.
        inFlight = nil
        advisoryRead = nil
        publish(.loaded(value))
    }

    private func fail(_ error: ProviderQuotaReadError, generation expected: UInt64) {
        guard enabled, generation == expected, !observers.isEmpty else { return }
        if !periodicReads { automaticConsumed = true }
        failureCount = min(failureCount + 1, 6)
        let fallback = now().addingTimeInterval(min(60 * pow(2, Double(failureCount - 1)), 1800))
        switch error {
        case let .rateLimited(until): blockedUntil = max(until, fallback)
        case let .accountInvalidated(retryAt): blockedUntil = max(retryAt ?? fallback, fallback)
        default: blockedUntil = fallback
        }
        switch error {
        case .signInRequired, .insufficientScope, .needsConsent, .accountInvalidated:
            snapshot = nil
        default: break
        }
        inFlight = nil
        advisoryRead = nil
        publish(.failed(reason: error.message, previous: snapshot))
    }

    private func publish(_ value: ProviderQuotaStatus) {
        guard status != value else { return }
        status = value
        for observer in observers.values {
            observer.yield(value)
        }
    }
}
