import Foundation

/// Per-window intent router. The shared data service, not this object, allocates revisions.
@MainActor
final class AgentSessionTitleCoordinator {
    static let didPublish = Notification.Name("AgentSessionTitleCoordinator.didPublish")
    struct Publication {
        let workspaceID: UUID
        let sessionID: UUID
        let snapshot: AgentSessionTitleSnapshot
    }

    private weak var viewModel: AgentModeViewModel?
    init(viewModel: AgentModeViewModel) {
        self.viewModel = viewModel
    }

    @discardableResult
    func apply(
        _ command: AgentSessionTitleCommand,
        tabID: UUID,
        expectedRevision: UInt64? = nil,
        isAuthorized: @escaping @MainActor () -> Bool = { true }
    ) async throws -> AgentSessionTitleSnapshot {
        guard let viewModel else { throw AgentSessionTitleError.denied("session_no_longer_available") }
        return try await viewModel.commitSessionTitle(
            command,
            tabID: tabID,
            expectedRevision: expectedRevision,
            isAuthorized: isAuthorized
        )
    }
}
