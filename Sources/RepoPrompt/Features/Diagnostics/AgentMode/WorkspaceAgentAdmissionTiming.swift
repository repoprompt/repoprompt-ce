import Foundation
import OSLog

/// Release-enabled, per-call diagnostics; see docs/architecture/source-layout.md.
/// Explicit propagation avoids sharing a mutable phase stack with unstructured tasks.
/// Durations are exclusive; hold is an aggregate. Executor contention is not separable.
@MainActor
final class WorkspaceAgentAdmissionTiming {
    enum Kind: String {
        case freshTab = "fresh_tab", existingTab = "existing_tab", recovery, discard
    }

    enum Outcome: String {
        case committed, rejected, cancelled, threw
    }

    enum Phase: Int, CaseIterable {
        case queueWait, refresh, catalogRefresh, save, other

        var name: String {
            switch self {
            case .queueWait: "queue_wait"
            case .refresh: "refresh"
            case .catalogRefresh: "catalog_refresh"
            case .save: "save"
            case .other: "other"
            }
        }
    }

    struct Context: Equatable {
        let workspaceKey: String
        let correlationKey: String
        let kind: Kind
    }

    struct Report: Equatable {
        let context: Context
        let outcome: Outcome
        let milliseconds: [Double]
        let counts: [Int]
        let saveAttempts: Int
        let totalMilliseconds: Double
        let holdMilliseconds: Double
        let slowestPhase: Phase

        /// Same hashed identities as coordinator events; otherwise only fixed enums and numbers.
        var logMessage: String {
            let phases = Phase.allCases.map { phase in
                "\(phase.name)MS=\(String(format: "%.3f", milliseconds[phase.rawValue])) \(phase.name)Count=\(counts[phase.rawValue])"
            }.joined(separator: " ")
            return "event=agentAdmission.slow workspace=\(context.workspaceKey) correlation=\(context.correlationKey) kind=\(context.kind.rawValue) outcome=\(outcome.rawValue) totalMS=\(String(format: "%.3f", totalMilliseconds)) holdMS=\(String(format: "%.3f", holdMilliseconds)) slowest=\(slowestPhase.name) saveAttempts=\(saveAttempts) \(phases)"
        }
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "RepoPrompt",
        category: "WorkspaceAgentAdmission"
    )

    private let now: () -> Duration
    private let slowThreshold: Duration
    private let emit: (Report) -> Void
    private var context: Context?
    private var lastMark: Duration
    private var stack: [Phase] = [.queueWait]
    private var durations = Array(repeating: Duration.zero, count: Phase.allCases.count)
    private var counts = Array(repeating: 0, count: Phase.allCases.count)
    private var saveAttempts = 0
    private var finished = false

    init(
        now: (() -> Duration)? = nil,
        slowThreshold: Duration = .seconds(5),
        emit: ((Report) -> Void)? = nil
    ) {
        // Like the coordinator's DispatchTime uptime clock, this excludes machine sleep.
        let clock = SuspendingClock()
        let origin = clock.now
        let readClock = now ?? { origin.duration(to: clock.now) }
        self.now = readClock
        self.slowThreshold = slowThreshold
        self.emit = emit ?? { report in
            Self.logger.notice("\(report.logMessage, privacy: .public)")
        }
        counts[Phase.queueWait.rawValue] = 1
        lastMark = readClock()
    }

    func configure(workspaceID: UUID, admissionID: UUID, kind: Kind) {
        context = Context(
            workspaceKey: WorkspaceAgentAdmissionCoordinator.redactedID(workspaceID),
            correlationKey: WorkspaceAgentAdmissionCoordinator.redactedID(admissionID),
            kind: kind
        )
    }

    func acquired() {
        guard !finished else { return }
        mark()
        stack = [.other]
        counts[Phase.other.rawValue] += 1
    }

    func begin(_ phase: Phase) {
        guard !finished else { return }
        mark()
        // Recursive refresh scopes are one entry, not additional refresh operations.
        if !stack.contains(phase) { counts[phase.rawValue] += 1 }
        stack.append(phase)
    }

    func end() {
        guard !finished else { return }
        mark()
        _ = stack.popLast()
    }

    func recordSaveAttempt() {
        guard !finished else { return }
        saveAttempts += 1
    }

    /// Defer calls this after lease release on success, rejection, cancellation, and throws.
    func finish(outcome: Outcome) {
        guard !finished else { return }
        mark()
        finished = true
        let total = durations.reduce(.zero, +)
        guard total >= slowThreshold, let context else { return }
        let slowest = Phase.allCases.reduce(Phase.queueWait) { previous, phase in
            durations[phase.rawValue] > durations[previous.rawValue] ? phase : previous
        }
        let milliseconds = durations.map(Self.milliseconds)
        emit(Report(
            context: context,
            outcome: outcome,
            milliseconds: milliseconds,
            counts: counts,
            saveAttempts: saveAttempts,
            totalMilliseconds: Self.milliseconds(total),
            holdMilliseconds: Self.milliseconds(total - durations[Phase.queueWait.rawValue]),
            slowestPhase: slowest
        ))
    }

    private func mark() {
        let current = now()
        if let phase = stack.last {
            durations[phase.rawValue] += max(.zero, current - lastMark)
        }
        lastMark = current
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
    }
}
