import Foundation
import RepoPromptShared

struct ContextBuilderReviewDiagnosticEvent: Equatable, CustomStringConvertible {
    enum Phase: String {
        case initialElection = "initial_election"
        case finalElection = "final_election"
        case revalidation
    }

    enum Outcome: String {
        case resolved
        case noCandidate = "no_candidate"
        case blocked
        case staleAuthority = "stale_authority"
    }

    let phase: Phase
    let outcome: Outcome
    let workspaceID: UUID
    let tabID: UUID
    let sessionID: UUID?
    let rootID: UUID?
    let ownershipGeneration: UInt64?
    let lifetimeID: UUID?
    let candidateCount: Int
    let resolvedCount: Int
    let unresolvedCount: Int
    let mismatch: WorkspaceSessionRootAuthorizationMismatch?

    var description: String {
        var fields = [
            "phase=\(phase.rawValue)",
            "outcome=\(outcome.rawValue)",
            "workspace_id=\(workspaceID.uuidString)",
            "tab_id=\(tabID.uuidString)",
            "candidate_count=\(candidateCount)",
            "resolved_count=\(resolvedCount)",
            "unresolved_count=\(unresolvedCount)"
        ]
        if let sessionID { fields.append("session_id=\(sessionID.uuidString)") }
        if let rootID { fields.append("root_id=\(rootID.uuidString)") }
        if let ownershipGeneration { fields.append("ownership_generation=\(ownershipGeneration)") }
        if let lifetimeID { fields.append("lifetime_id=\(lifetimeID.uuidString)") }
        if let mismatch { fields.append("mismatch=\(mismatch.rawValue)") }
        return fields.joined(separator: " ")
    }
}

typealias ContextBuilderReviewDiagnosticSink = @Sendable (ContextBuilderReviewDiagnosticEvent) -> Void

enum ContextBuilderReviewDiagnosticTracer {
    private static var tracingEnabled: Bool {
        #if DEBUG
            ProcessInfo.processInfo.environment["REPOPROMPT_CONTEXT_BUILDER_REVIEW_TRACE"] == "1"
                || MCPToolExecutionTracer.successTracingEnabled
        #else
            UserDefaults.standard.bool(forKey: "enableMCPToolExecutionTrace")
        #endif
    }

    static func emit(_ event: ContextBuilderReviewDiagnosticEvent) {
        guard tracingEnabled,
              let data = "[ContextBuilderReview] \(event)\n".data(using: .utf8)
        else { return }
        BestEffortStderrWriter.write(data)
    }
}
