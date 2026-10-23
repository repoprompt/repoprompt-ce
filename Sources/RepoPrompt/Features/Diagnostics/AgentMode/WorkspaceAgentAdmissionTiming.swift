import Foundation
import OSLog

/// Per-call, MainActor-confined diagnostics. Explicit propagation avoids sharing a mutable
/// phase stack with unstructured tasks. Durations are exclusive; hold is an aggregate.
@MainActor
final class WorkspaceAgentAdmissionTiming {
    enum Phase: Int, CaseIterable {
        case queueWait, refresh, save, other

        var name: String {
            switch self {
            case .queueWait: "queue_wait"
            case .refresh: "refresh"
            case .save: "save"
            case .other: "other"
            }
        }
    }

    struct Report: Equatable {
        let milliseconds: [Double]
        let counts: [Int]
        let totalMilliseconds: Double
        let holdMilliseconds: Double
        let slowestPhase: Phase

        /// Only fixed phase names, numeric durations and invocation counts; no user data.
        var logMessage: String {
            let phases = Phase.allCases.map { phase in
                "\(phase.name)MS=\(String(format: "%.3f", milliseconds[phase.rawValue])) \(phase.name)Count=\(counts[phase.rawValue])"
            }.joined(separator: " ")
            return "event=agentAdmission.slow totalMS=\(String(format: "%.3f", totalMilliseconds)) holdMS=\(String(format: "%.3f", holdMilliseconds)) slowest=\(slowestPhase.name) \(phases)"
        }
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "RepoPrompt",
        category: "WorkspaceAgentAdmission"
    )

    private let now: () -> Duration
    private let slowThreshold: Duration
    private let emit: (Report) -> Void
    private var lastMark: Duration
    private var stack: [Phase] = [.queueWait]
    private var durations = Array(repeating: Duration.zero, count: Phase.allCases.count)
    private var counts = [1, 0, 0, 0]
    private var finished = false

    init(
        now: (() -> Duration)? = nil,
        slowThreshold: Duration = .seconds(5),
        emit: ((Report) -> Void)? = nil
    ) {
        let clock = ContinuousClock()
        let origin = clock.now
        let readClock = now ?? { origin.duration(to: clock.now) }
        self.now = readClock
        self.slowThreshold = slowThreshold
        self.emit = emit ?? { report in
            Self.logger.notice("\(report.logMessage, privacy: .public)")
        }
        lastMark = readClock()
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
        stack.append(phase)
        counts[phase.rawValue] += 1
    }

    func end() {
        guard !finished else { return }
        mark()
        _ = stack.popLast()
    }

    /// Called by defer on success, rejection, cancellation, and thrown failures alike.
    /// The fixed-size summary and threshold check never inspect workspace/session records.
    func finish() {
        guard !finished else { return }
        mark()
        finished = true
        let total = durations.reduce(.zero, +)
        guard total >= slowThreshold else { return }
        let slowest = Phase.allCases.reduce(Phase.queueWait) { previous, phase in
            durations[phase.rawValue] > durations[previous.rawValue] ? phase : previous
        }
        let milliseconds = durations.map(Self.milliseconds)
        emit(Report(
            milliseconds: milliseconds,
            counts: counts,
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
