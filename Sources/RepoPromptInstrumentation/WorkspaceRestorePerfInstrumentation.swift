import Foundation

/// Synchronous, opt-in restore timing and structured event contract.
/// Consumers provide only the same bounded diagnostic fields as the app logger;
/// a missing app composition is intentionally silent.
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
