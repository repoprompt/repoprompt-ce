import Foundation
import RepoPromptShared

/// Refused at the destructive commit point: the caller's authority no longer holds.
struct AgentSessionDestructiveCommitRefused: Error, Equatable {}

extension AgentSessionDataService {
    /// Caller-supplied authority fence evaluated at the destructive commit point, after admission
    /// and writer draining and immediately before the file is removed. A delete authorized earlier
    /// (for example under Overseer full access) must not proceed if that authority ended meanwhile.
    nonisolated static let destructiveCommitFence = BoxedTaskLocal<(@Sendable () async -> Bool)?>(nil)
}
