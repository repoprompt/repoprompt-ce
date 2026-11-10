import Foundation

/// State of an agent run within a session
public enum AgentSessionRunState: String, Codable, Sendable, Equatable {
    case idle
    case running
    case waitingForUser
    case waitingForQuestion
    case waitingForApproval
    case completed
    case cancelled
    case failed

    public var isActive: Bool {
        switch self {
        case .running, .waitingForUser, .waitingForQuestion, .waitingForApproval:
            true
        case .idle, .completed, .cancelled, .failed:
            false
        }
    }
}
