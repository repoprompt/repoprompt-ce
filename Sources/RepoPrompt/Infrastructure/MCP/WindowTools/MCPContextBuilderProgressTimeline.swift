import Foundation

enum ContextBuilderMCPProgressPhase: String, CaseIterable {
    case readFileAutoSelectionFinish = "read_file_auto_selection_finish"
    case tabContextCommit = "tab_context_commit"
    case statePersistence = "state_persistence"
    case childConnectionTermination = "child_connection_termination"
    case childConnectionTerminationJoin = "child_connection_termination_join"
    case runFinalization = "run_finalization"
    case modelResolution = "model_resolution"
    case payloadPackaging = "payload_packaging"
    case sessionCreationAndPersist = "session_creation_and_persist"
    case messageSend = "message_send"
    case activeQueryAcquisition = "active_query_acquisition"
    case streaming
    case messageFinalization = "message_finalization"

    var stage: String {
        switch self {
        case .childConnectionTermination,
             .readFileAutoSelectionFinish,
             .tabContextCommit,
             .statePersistence,
             .childConnectionTerminationJoin,
             .runFinalization:
            "discovering"
        case .modelResolution,
             .payloadPackaging,
             .sessionCreationAndPersist,
             .messageSend,
             .activeQueryAcquisition,
             .streaming,
             .messageFinalization:
            "generating"
        }
    }

    var displayName: String {
        switch self {
        case .childConnectionTermination:
            "child MCP connection termination request"
        case .readFileAutoSelectionFinish:
            "read-file auto-selection finish"
        case .tabContextCommit:
            "tab-context commit"
        case .statePersistence:
            "workspace state persistence"
        case .childConnectionTerminationJoin:
            "child MCP connection termination join"
        case .runFinalization:
            "Context Builder run finalization"
        case .modelResolution:
            "follow-up model resolution"
        case .payloadPackaging:
            "follow-up payload packaging"
        case .sessionCreationAndPersist:
            "Oracle session creation/persist"
        case .messageSend:
            "Oracle message send"
        case .activeQueryAcquisition:
            "active-query acquisition"
        case .streaming:
            "Oracle response streaming"
        case .messageFinalization:
            "Oracle message finalization"
        }
    }

    /// Diagnostic-only threshold. Exceeding this bound reports progress but does not fail the run.
    var softBoundSeconds: TimeInterval? {
        switch self {
        case .childConnectionTermination:
            1
        case .readFileAutoSelectionFinish:
            30
        case .tabContextCommit:
            15
        case .statePersistence:
            30
        case .childConnectionTerminationJoin:
            10
        case .runFinalization:
            5
        case .modelResolution:
            2
        case .payloadPackaging:
            5
        case .sessionCreationAndPersist:
            30
        case .messageSend:
            10
        case .activeQueryAcquisition:
            5
        case .streaming, .messageFinalization:
            nil
        }
    }
}

typealias ContextBuilderMCPProgressReporter = @MainActor @Sendable (
    _ phase: ContextBuilderMCPProgressPhase
) async -> Void

typealias ContextBuilderMCPActivityReporter = @MainActor @Sendable (
    _ phase: ContextBuilderMCPProgressPhase,
    _ message: String
) async -> Void

struct ContextBuilderMCPProgressEvent: Equatable {
    enum Kind: String {
        case started
        case completed
        case heartbeat
        case activity
        case softBoundExceeded = "soft_bound_exceeded"
    }

    let kind: Kind
    let phase: ContextBuilderMCPProgressPhase
    let stage: String
    let message: String
    let timestamp: TimeInterval
    let phaseElapsed: TimeInterval
    let totalElapsed: TimeInterval
}

actor ContextBuilderMCPProgressTimeline {
    typealias Clock = @Sendable () -> TimeInterval
    typealias Sleep = @Sendable (_ seconds: TimeInterval) async throws -> Void
    typealias Sink = @Sendable (ContextBuilderMCPProgressEvent) async -> Void

    private let clock: Clock
    private let sleep: Sleep
    private let sink: Sink
    private let startedAt: TimeInterval
    private var currentPhase: ContextBuilderMCPProgressPhase?
    private var currentPhaseStartedAt: TimeInterval?
    private var phaseGeneration = 0
    private var didReportSoftBound = false
    private var softBoundTask: Task<Void, Never>?
    private var pendingEvents: [ContextBuilderMCPProgressEvent] = []
    private var eventDeliveryTask: Task<Void, Never>?

    init(
        clock: @escaping Clock = { ProcessInfo.processInfo.systemUptime },
        sleep: @escaping Sleep = { seconds in
            try await Task.sleep(for: .seconds(seconds))
        },
        sink: @escaping Sink
    ) {
        self.clock = clock
        self.sleep = sleep
        self.sink = sink
        startedAt = clock()
    }

    func transition(to phase: ContextBuilderMCPProgressPhase) async {
        let now = clock()
        let completion = completionEvent(at: now)

        // Commit actor state and enqueue the old completion/new start as one ordered batch
        // before the sink can suspend. Reentrant transitions append behind this batch, so a
        // phase completion can never overtake or suppress its corresponding start.
        cancelSoftBoundTask()
        phaseGeneration += 1
        let generation = phaseGeneration
        currentPhase = phase
        currentPhaseStartedAt = now
        didReportSoftBound = false
        let started = event(
            kind: .started,
            phase: phase,
            at: now,
            phaseElapsed: 0,
            message: "\(phase.displayName) started (total \(Self.format(now - startedAt)))"
        )
        scheduleSoftBoundCheck(for: phase, generation: generation)

        var events: [ContextBuilderMCPProgressEvent] = []
        if let completion {
            events.append(completion)
        }
        events.append(started)
        if let deliveryTask = enqueueForDelivery(events) {
            await deliveryTask.value
        }
    }

    func finishCurrentPhase() async {
        let now = clock()
        let completion = completionEvent(at: now)
        cancelSoftBoundTask()
        phaseGeneration += 1
        currentPhase = nil
        currentPhaseStartedAt = nil
        didReportSoftBound = false
        if let completion,
           let deliveryTask = enqueueForDelivery([completion])
        {
            await deliveryTask.value
        }
    }

    func reportActivity(
        phase: ContextBuilderMCPProgressPhase,
        message: String
    ) async {
        let now = clock()
        let phaseStartedAt = currentPhase == phase ? currentPhaseStartedAt : nil
        let activity = event(
            kind: .activity,
            phase: phase,
            at: now,
            phaseElapsed: phaseStartedAt.map { max(0, now - $0) } ?? 0,
            message: "\(message) (total \(Self.format(now - startedAt)))"
        )
        if let deliveryTask = enqueueForDelivery([activity]) {
            await deliveryTask.value
        }
    }

    func flush() async {
        while let eventDeliveryTask {
            await eventDeliveryTask.value
        }
    }

    func heartbeat(
        fallbackStage: String,
        fallbackMessage: String
    ) -> (stage: String, message: String) {
        guard let phase = currentPhase,
              let phaseStartedAt = currentPhaseStartedAt
        else {
            return (fallbackStage, fallbackMessage)
        }

        let now = clock()
        return (
            phase.stage,
            "Still in \(phase.displayName) (phase \(Self.format(now - phaseStartedAt)), total \(Self.format(now - startedAt)))"
        )
    }

    /// Exposed for deterministic injected-clock tests; production also schedules this automatically.
    func checkSoftBound() async {
        guard let phase = currentPhase,
              let phaseStartedAt = currentPhaseStartedAt,
              let bound = phase.softBoundSeconds,
              !didReportSoftBound
        else {
            return
        }
        let now = clock()
        let phaseElapsed = max(0, now - phaseStartedAt)
        guard phaseElapsed >= bound else { return }

        didReportSoftBound = true
        let exceeded = event(
            kind: .softBoundExceeded,
            phase: phase,
            at: now,
            phaseElapsed: phaseElapsed,
            message: "\(phase.displayName) exceeded soft bound \(Self.format(bound)); still running at \(Self.format(phaseElapsed)) (total \(Self.format(now - startedAt)))"
        )
        if let deliveryTask = enqueueForDelivery([exceeded]) {
            await deliveryTask.value
        }
    }

    private func scheduleSoftBoundCheck(
        for phase: ContextBuilderMCPProgressPhase,
        generation: Int
    ) {
        guard let bound = phase.softBoundSeconds else { return }
        let sleep = sleep
        softBoundTask = Task { [weak self] in
            do {
                try await sleep(bound)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            await reportSoftBoundIfCurrent(phase: phase, generation: generation)
        }
    }

    private func reportSoftBoundIfCurrent(
        phase: ContextBuilderMCPProgressPhase,
        generation: Int
    ) async {
        guard phaseGeneration == generation, currentPhase == phase else { return }
        await checkSoftBound()
    }

    private func cancelSoftBoundTask() {
        softBoundTask?.cancel()
        softBoundTask = nil
    }

    private func enqueueForDelivery(
        _ events: [ContextBuilderMCPProgressEvent]
    ) -> Task<Void, Never>? {
        guard !events.isEmpty else { return nil }
        pendingEvents.append(contentsOf: events)
        guard eventDeliveryTask == nil else { return nil }

        let task = Task { [weak self] in
            guard let self else { return }
            await drainPendingEvents()
        }
        eventDeliveryTask = task
        return task
    }

    private func drainPendingEvents() async {
        while !pendingEvents.isEmpty {
            let event = pendingEvents.removeFirst()
            await sink(event)
        }
        eventDeliveryTask = nil
    }

    private func completionEvent(at now: TimeInterval) -> ContextBuilderMCPProgressEvent? {
        guard let phase = currentPhase,
              let phaseStartedAt = currentPhaseStartedAt
        else {
            return nil
        }
        let phaseElapsed = max(0, now - phaseStartedAt)
        return event(
            kind: .completed,
            phase: phase,
            at: now,
            phaseElapsed: phaseElapsed,
            message: "\(phase.displayName) completed in \(Self.format(phaseElapsed)) (total \(Self.format(now - startedAt)))"
        )
    }

    private func event(
        kind: ContextBuilderMCPProgressEvent.Kind,
        phase: ContextBuilderMCPProgressPhase,
        at timestamp: TimeInterval,
        phaseElapsed: TimeInterval,
        message: String
    ) -> ContextBuilderMCPProgressEvent {
        ContextBuilderMCPProgressEvent(
            kind: kind,
            phase: phase,
            stage: phase.stage,
            message: message,
            timestamp: timestamp,
            phaseElapsed: max(0, phaseElapsed),
            totalElapsed: max(0, timestamp - startedAt)
        )
    }

    private static func format(_ interval: TimeInterval) -> String {
        String(format: "%.3fs", max(0, interval))
    }
}
