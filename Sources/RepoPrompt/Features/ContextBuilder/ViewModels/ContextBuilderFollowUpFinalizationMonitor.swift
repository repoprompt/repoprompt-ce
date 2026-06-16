import Foundation

struct ContextBuilderFollowUpFinalizationConfiguration: Equatable {
    let overallTimeout: TimeInterval
    let inactivityTimeout: TimeInterval
    let checkInterval: TimeInterval

    static let production = ContextBuilderFollowUpFinalizationConfiguration(
        overallTimeout: 4 * 60 * 60,
        inactivityTimeout: 10 * 60,
        checkInterval: 5
    )
}

struct ContextBuilderFollowUpTimeoutSnapshot: Equatable {
    enum Kind: String {
        case inactivity
        case overall
    }

    let kind: Kind
    let elapsed: TimeInterval
    let inactiveFor: TimeInterval
    let lastKnownSubphase: String
    let lastEvent: String

    var message: String {
        switch kind {
        case .inactivity:
            "Follow-up response stalled for \(Self.format(inactiveFor)) with no streaming/finalization activity during \(lastKnownSubphase). Last event: \(lastEvent)."
        case .overall:
            "Follow-up response exceeded the overall \(Self.format(elapsed)) ceiling during \(lastKnownSubphase). Last event: \(lastEvent)."
        }
    }

    private static func format(_ interval: TimeInterval) -> String {
        String(format: "%.1fs", max(0, interval))
    }
}

actor ContextBuilderFollowUpFinalizationState {
    struct ActivityUpdate: Equatable {
        let phase: ContextBuilderMCPProgressPhase
        let message: String
        let shouldTransitionToFinalization: Bool
    }

    private let startedAt: TimeInterval
    private var lastMeaningfulActivityAt: TimeInterval
    private var lastKnownSubphase = ContextBuilderMCPProgressPhase.streaming.displayName
    private var lastEvent = "waiting for Oracle stream activity"
    private var hasEnteredFinalization = false

    init(startedAt: TimeInterval) {
        self.startedAt = startedAt
        lastMeaningfulActivityAt = startedAt
    }

    func record(
        _ event: OracleMessageLifecycleActivityEvent,
        at now: TimeInterval
    ) -> ActivityUpdate {
        if event.resetsInactivityTimeout {
            lastMeaningfulActivityAt = now
        }

        let shouldTransition = event.entersFinalization && !hasEnteredFinalization
        if event.entersFinalization {
            hasEnteredFinalization = true
        }
        let phase: ContextBuilderMCPProgressPhase = hasEnteredFinalization ? .messageFinalization : .streaming
        lastKnownSubphase = phase.displayName
        lastEvent = event.message

        return ActivityUpdate(
            phase: phase,
            message: event.message,
            shouldTransitionToFinalization: shouldTransition
        )
    }

    func claimFinalizationTransitionOnCompletion() -> Bool {
        guard !hasEnteredFinalization else { return false }
        hasEnteredFinalization = true
        lastKnownSubphase = ContextBuilderMCPProgressPhase.messageFinalization.displayName
        lastEvent = "Oracle message finalization completed"
        return true
    }

    func timeoutSnapshot(
        at now: TimeInterval,
        configuration: ContextBuilderFollowUpFinalizationConfiguration
    ) -> ContextBuilderFollowUpTimeoutSnapshot? {
        let elapsed = max(0, now - startedAt)
        let inactiveFor = max(0, now - lastMeaningfulActivityAt)
        if elapsed >= configuration.overallTimeout {
            return ContextBuilderFollowUpTimeoutSnapshot(
                kind: .overall,
                elapsed: elapsed,
                inactiveFor: inactiveFor,
                lastKnownSubphase: lastKnownSubphase,
                lastEvent: lastEvent
            )
        }
        if inactiveFor >= configuration.inactivityTimeout {
            return ContextBuilderFollowUpTimeoutSnapshot(
                kind: .inactivity,
                elapsed: elapsed,
                inactiveFor: inactiveFor,
                lastKnownSubphase: lastKnownSubphase,
                lastEvent: lastEvent
            )
        }
        return nil
    }
}

enum ContextBuilderFollowUpFinalizationMonitor {
    typealias Clock = @Sendable () -> TimeInterval
    typealias Sleep = @Sendable (_ seconds: TimeInterval) async throws -> Void
    typealias WaitForFinalization = @Sendable () async throws -> Void
    typealias CancelStreaming = @Sendable () async -> Void
    typealias ReportPhase = @Sendable (_ phase: ContextBuilderMCPProgressPhase) async -> Void
    typealias ReportActivity = @Sendable (
        _ phase: ContextBuilderMCPProgressPhase,
        _ message: String
    ) async -> Void

    private enum MonitorResult {
        case finalised
        case timedOut(ContextBuilderFollowUpTimeoutSnapshot)
        case failed(String)
        case cancelled
        case observerEnded
    }

    static func wait(
        activityEvents: AsyncStream<OracleMessageLifecycleActivityEvent>,
        configuration: ContextBuilderFollowUpFinalizationConfiguration = .production,
        clock: @escaping Clock = { ProcessInfo.processInfo.systemUptime },
        sleep: @escaping Sleep = { seconds in
            try await Task.sleep(for: .seconds(seconds))
        },
        waitForFinalization: @escaping WaitForFinalization,
        cancelStreaming: @escaping CancelStreaming,
        reportPhase: ReportPhase? = nil,
        reportActivity: ReportActivity? = nil
    ) async throws {
        let state = ContextBuilderFollowUpFinalizationState(startedAt: clock())
        let result = await withTaskGroup(of: MonitorResult.self) { group in
            group.addTask {
                do {
                    try await waitForFinalization()
                    return .finalised
                } catch is CancellationError {
                    return .cancelled
                } catch {
                    return .failed(error.localizedDescription)
                }
            }
            group.addTask {
                for await event in activityEvents {
                    if Task.isCancelled { return .cancelled }
                    let update = await state.record(event, at: clock())
                    if update.shouldTransitionToFinalization {
                        await reportPhase?(.messageFinalization)
                    }
                    await reportActivity?(update.phase, update.message)
                }
                return .observerEnded
            }
            group.addTask {
                do {
                    while !Task.isCancelled {
                        try await sleep(configuration.checkInterval)
                        try Task.checkCancellation()
                        if let timeout = await state.timeoutSnapshot(
                            at: clock(),
                            configuration: configuration
                        ) {
                            return .timedOut(timeout)
                        }
                    }
                    return .cancelled
                } catch is CancellationError {
                    return .cancelled
                } catch {
                    return .failed(error.localizedDescription)
                }
            }

            while let next = await group.next() {
                if case .observerEnded = next {
                    continue
                }
                group.cancelAll()
                return next
            }
            return .cancelled
        }

        switch result {
        case .finalised:
            if await state.claimFinalizationTransitionOnCompletion() {
                await reportPhase?(.messageFinalization)
            }
            return
        case let .timedOut(timeout):
            // The timeout outcome is already fixed before cancellation can trigger finalization.
            await cancelStreaming()
            throw ChatToolError.internalError(timeout.message)
        case let .failed(message):
            throw ChatToolError.internalError("Follow-up finalization monitoring failed: \(message)")
        case .cancelled, .observerEnded:
            throw CancellationError()
        }
    }
}
