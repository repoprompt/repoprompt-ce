import Foundation
import RepoPromptHeadlessRuntime
import RepoPromptServiceProtocol

/// Starts provider dispatch after a submission receipt has been durably accepted.
///
/// HTTP callers only wait for the submission to enter this queue. Provider
/// preparation and launch continue independently, matching the desktop client’s
/// accept-first interaction while preserving the coordinator’s recovery record.
public actor AgentSubmissionDispatchQueue {
    public typealias Operation = @Sendable (AcceptedAgentSubmission, ExternalActor, String) async -> Void

    private let operation: Operation
    private var tasks: [UUID: Task<Void, Never>] = [:]

    public init(authority: RepoPromptHeadlessAuthority, coordinator: AgentSubmissionCoordinator) {
        operation = { accepted, actor, requestDigest in
            do {
                try await authority.dispatchAcceptedFollowup(accepted, actor: actor, requestDigest: requestDigest)
                try await coordinator.markDispatched(submissionID: accepted.receipt.submissionID)
            } catch {
                try? await coordinator.markLaunchFailed(
                    submissionID: accepted.receipt.submissionID,
                    message: String(describing: error)
                )
            }
        }
    }

    public init(operation: @escaping Operation) {
        self.operation = operation
    }

    public func enqueue(_ accepted: AcceptedAgentSubmission, actor: ExternalActor, requestDigest: String) {
        guard !accepted.replayed, tasks[accepted.receipt.submissionID] == nil else { return }
        let submissionID = accepted.receipt.submissionID
        let operation = self.operation
        tasks[submissionID] = Task { [weak self] in
            await operation(accepted, actor, requestDigest)
            await self?.finished(submissionID)
        }
    }

    public func waitForIdle() async {
        while !tasks.isEmpty {
            let activeTasks = Array(tasks.values)
            for task in activeTasks {
                await task.value
            }
        }
    }

    private func finished(_ submissionID: UUID) {
        tasks[submissionID] = nil
    }
}
