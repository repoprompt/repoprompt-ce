import Foundation

package enum WorkspaceRestoreStartupPhase: String, Sendable {
    case oversightIntentLoad, oversightLaunchSeed, oversightRestoreAdmission
    case oversightDiscoveryAdoption, oversightDiscoveryCompletion, oversightDiscoveryBarrier
}

package enum WorkspaceRestoreOversightOutcome: String, Sendable {
    case restored, blocked, terminal
    case endpointUnresolved = "endpoint_unresolved"
}

package enum WorkspaceRestoreLaneAddFailureBranch: String, Sendable {
    case targetBindingOrProvenance = "target_binding_or_provenance"
    case restorationProof = "restoration_proof"
    case addFailed = "add_failed"
    case addRejected = "add_rejected"
}

/// Synchronous restore diagnostics. Timing is opt-in; startup and Add-failure records are always on.
/// Consumers provide bounded identifiers, counters and enum raw values.
/// A missing app composition is silent.
package protocol WorkspaceRestorePerfRecording: Sendable {
    var isEnabled: Bool { get }
    func timestampMSIfEnabled() -> Double?
    func timestampMS() -> Double
    func elapsedMS(since startMS: Double) -> Double
    func formatMS(_ value: Double) -> String
    func formatElapsedMS(since startMS: Double) -> String
    func shortID(_ id: UUID?) -> String
    @MainActor func nextAgentActivationTrueCount() -> Int
    func log(_ message: @autoclosure () -> String)
    func event(_ name: String, fields: [String: String])
    func recordStartupPhase(_ phase: WorkspaceRestoreStartupPhase, debug: Bool, window: Int?, fields: [String: Int])
    func recordOversightRestoreAttempt(observer: UUID, target: UUID, outcome: WorkspaceRestoreOversightOutcome, reason: String?)
    func recordLaneCreationAddFailure(branch: WorkspaceRestoreLaneAddFailureBranch, reason: String?)
}

package extension WorkspaceRestorePerfRecording {
    /// Always-on startup records use closed phases, identifiers and counters. Reasons are enum raw values.
    func recordStartupPhase(_: WorkspaceRestoreStartupPhase, debug _: Bool, window _: Int?, fields _: [String: Int]) {}
    func recordOversightRestoreAttempt(observer _: UUID, target _: UUID, outcome _: WorkspaceRestoreOversightOutcome, reason _: String?) {}
    func recordLaneCreationAddFailure(branch _: WorkspaceRestoreLaneAddFailureBranch, reason _: String?) {}

    func startupPhase(_ phase: WorkspaceRestoreStartupPhase, debug: Bool = false, window: Int? = nil, fields: [String: Int] = [:]) {
        recordStartupPhase(phase, debug: debug, window: window, fields: fields)
    }

    func oversightRestoreAttempt(observer: UUID, target: UUID, outcome: WorkspaceRestoreOversightOutcome, reason: String? = nil) {
        recordOversightRestoreAttempt(observer: observer, target: target, outcome: outcome, reason: reason)
    }

    func laneCreationAddFailed(branch: WorkspaceRestoreLaneAddFailureBranch, reason: String? = nil) {
        recordLaneCreationAddFailure(branch: branch, reason: reason)
    }
}

package struct NoopWorkspaceRestorePerfRecorder: WorkspaceRestorePerfRecording {
    package init() {}

    package var isEnabled: Bool { false }
    package func timestampMSIfEnabled() -> Double? { nil }
    package func timestampMS() -> Double { CFAbsoluteTimeGetCurrent() * 1000 }
    package func elapsedMS(since startMS: Double) -> Double { timestampMS() - startMS }
    package func formatMS(_ value: Double) -> String { String(format: "%.1fms", value) }
    package func formatElapsedMS(since startMS: Double) -> String { formatMS(elapsedMS(since: startMS)) }
    package func shortID(_ id: UUID?) -> String { id?.uuidString.prefix(8).description ?? "nil" }
    @MainActor package func nextAgentActivationTrueCount() -> Int { 0 }
    package func log(_: @autoclosure () -> String) {}
    package func event(_: String, fields _: [String: String] = [:]) {}
}

/// Per-owner synchronous installation slot for actor owners composed before async work starts.
package final class WorkspaceRestorePerfRecorderBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: any WorkspaceRestorePerfRecording = NoopWorkspaceRestorePerfRecorder()

    package init() {}

    package func install(_ recorder: any WorkspaceRestorePerfRecording) {
        lock.lock()
        value = recorder
        lock.unlock()
    }

    package func snapshot() -> any WorkspaceRestorePerfRecording {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
