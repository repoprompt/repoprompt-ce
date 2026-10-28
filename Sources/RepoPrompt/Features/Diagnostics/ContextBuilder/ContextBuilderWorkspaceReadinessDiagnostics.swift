import Foundation
import RepoPromptShared

/// Summary-only readiness telemetry. Its value surface cannot carry paths or arbitrary errors.
struct ContextBuilderWorkspaceReadinessDiagnosticEvent: Equatable, CustomStringConvertible {
    enum Phase: String {
        case admission, resolved, startupRevalidation, launchRevalidation
    }

    enum Outcome: String {
        case ready, rejected, cancelled
    }

    let phase: Phase
    let outcome: Outcome
    let workspaceID: UUID?
    let tabID: UUID
    let runID: UUID?
    let activationGeneration: UInt64?
    let rootIntentGeneration: UInt64?
    let expectedCount: Int
    let loadedCount: Int
    let missingCount: Int
    let reason: WorkspaceRootReadinessFailure.Reason?
    let retryable: Bool?

    var description: String {
        var fields = [
            "phase=\(phase.rawValue)", "outcome=\(outcome.rawValue)",
            "tab_id=\(tabID.uuidString)", "expected_count=\(expectedCount)",
            "loaded_count=\(loadedCount)", "missing_count=\(missingCount)"
        ]
        if let workspaceID { fields.append("workspace_id=\(workspaceID.uuidString)") }
        if let runID { fields.append("run_id=\(runID.uuidString)") }
        if let activationGeneration { fields.append("activation_generation=\(activationGeneration)") }
        if let rootIntentGeneration { fields.append("root_intent_generation=\(rootIntentGeneration)") }
        if let reason { fields.append("reason=\(reason.contextBuilderCategoryCode)") }
        if case let .rootsUnavailable(availability) = reason { fields.append("subreason=\(availability.rawValue)") }
        if let retryable { fields.append("retryable=\(retryable)") }
        return fields.joined(separator: " ")
    }
}

typealias ContextBuilderWorkspaceReadinessDiagnosticSink = @Sendable (ContextBuilderWorkspaceReadinessDiagnosticEvent) -> Void

enum ContextBuilderWorkspaceReadinessDiagnosticTracer {
    private static var tracingEnabled: Bool {
        #if DEBUG
            ProcessInfo.processInfo.environment["REPOPROMPT_CONTEXT_BUILDER_READINESS_TRACE"] == "1"
                || MCPToolExecutionTracer.successTracingEnabled
        #else
            UserDefaults.standard.bool(forKey: "enableMCPToolExecutionTrace")
        #endif
    }

    static func emit(_ event: ContextBuilderWorkspaceReadinessDiagnosticEvent) {
        guard tracingEnabled,
              let data = "[ContextBuilderReadiness] \(event)\n".data(using: .utf8)
        else { return }
        BestEffortStderrWriter.write(data)
    }
}
