import Foundation
import OSLog

/// The single retained record for a command, including across window transfers.
/// Window queues schedule this reference; they do not copy or settle its bookkeeping.
@MainActor
final class AppCommandLifetime {
    private enum Phase {
        case queued(windowID: Int)
        case executing(windowID: Int)
        case finished
    }

    private struct DurableCreationCommit {
        let workspaceID: UUID
        let expectedRoot: WorkspaceRootSetKey
        let operationID: UUID
    }

    let id = UUID()
    let command: AppCommand
    private(set) var folderRoute: FolderRouteState
    private var phase: Phase
    private var hasRetried = false
    private var hasForwarded = false
    private var attemptedWindowIDs: Set<Int>
    private var persistentResolution: PersistentFolderOpenProvenance?
    private var durableCreationCommit: DurableCreationCommit?
    private var completion: AppCommandCompletion?

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.repoprompt.RepoPrompt",
        category: "AppCommandQueue"
    )

    init(
        command: AppCommand,
        folderRoute: FolderRouteState,
        windowID: Int,
        completion: AppCommandCompletion? = nil
    ) {
        self.command = command
        self.folderRoute = folderRoute
        phase = .queued(windowID: windowID)
        attemptedWindowIDs = [windowID]
        persistentResolution = folderRoute.routedPersistentResolution
        self.completion = completion
    }

    func beginExecution(in windowID: Int) -> Bool {
        guard case let .queued(ownerID) = phase, ownerID == windowID else { return false }
        phase = .executing(windowID: windowID)
        return true
    }

    func isExecuting(in windowID: Int) -> Bool {
        if case let .executing(ownerID) = phase, ownerID == windowID { return true }
        return false
    }

    /// Close must not settle an executing command: an awaited result may still
    /// reveal a durable creation. Its execution will report the interruption.
    func windowClosed(in windowID: Int) {
        guard case let .queued(ownerID) = phase, ownerID == windowID else { return }
        finish(.failed(.windowClosed), in: windowID)
    }

    /// Returns whether the same lifetime should be scheduled for another attempt.
    /// Rejection settles here, after the scheduler has detached the entry.
    func retry(
        expectedRoot: WorkspaceRootSetKey,
        failure: AppCommandExecutionFailure,
        in windowID: Int
    ) -> Bool {
        guard isExecuting(in: windowID) else { return false }
        guard !hasRetried else {
            finish(.failed(failure), in: windowID)
            return false
        }
        hasRetried = true
        folderRoute = .authorityExactRoot(expectedRoot: expectedRoot)
        phase = .queued(windowID: windowID)
        return true
    }

    func canForward(to windowID: Int) -> Bool {
        guard case .executing = phase else { return false }
        return !hasForwarded && !attemptedWindowIDs.contains(windowID)
    }

    /// Transfer the completion obligation, not a new copy of the command.
    /// The destination's enqueue path handles rejection by an already-closed window.
    func transfer(to windowID: Int, route: FolderRouteState, from ownerID: Int) -> Bool {
        guard isExecuting(in: ownerID) else { return false }
        guard canForward(to: windowID) else {
            finish(.failed(.routeChangedAfterRetry), in: ownerID)
            return false
        }
        hasForwarded = true
        attemptedWindowIDs.insert(windowID)
        folderRoute = route
        phase = .queued(windowID: windowID)
        return true
    }

    /// Keep the await and retention together so callers cannot observe interruption
    /// between a successful persistence result and accounting for its committed work.
    func resolvePersistentFolder(
        expectedRoot: WorkspaceRootSetKey,
        using resolve: () async throws -> PersistentFolderOpenResolutionDetails
    ) async throws -> PersistentFolderOpenResolutionDetails {
        let resolution = try await resolve()
        recordProvenance(resolution.provenance)
        if durableCreationCommit == nil,
           resolution.provenance == .created,
           resolution.creationCommitted
        {
            durableCreationCommit = DurableCreationCommit(
                workspaceID: resolution.workspace.id,
                expectedRoot: expectedRoot,
                operationID: resolution.operationID
            )
        }
        return resolution
    }

    func recordPendingPublicationReuse() {
        recordProvenance(.reused)
    }

    private func recordProvenance(_ provenance: PersistentFolderOpenProvenance) {
        if provenance == .created || persistentResolution == nil {
            persistentResolution = provenance
        }
    }

    /// Call only after detaching the terminal entry from its scheduling queue.
    /// Clear the obligation before invoking arbitrary, potentially reentrant code.
    func finish(_ result: AppCommandExecutionResult, in windowID: Int) {
        switch phase {
        case let .queued(ownerID), let .executing(ownerID):
            guard ownerID == windowID else { return }
        default:
            return
        }
        phase = .finished
        let completion = completion
        self.completion = nil
        let reportedResult = accountingForCreation(result)
        log(reportedResult)
        completion?(reportedResult)
    }

    private func accountingForCreation(_ result: AppCommandExecutionResult) -> AppCommandExecutionResult {
        guard let durableCreationCommit else { return result }
        return switch result {
        case .completed, .partialSuccess:
            result
        case .cancelled:
            .partialSuccess(workspaceID: durableCreationCommit.workspaceID, reason: .cancelled)
        case let .failed(failure):
            .partialSuccess(workspaceID: durableCreationCommit.workspaceID, reason: .failed(failure))
        }
    }

    private func log(_ result: AppCommandExecutionResult) {
        let routeLabel = folderRoute.logLabel
        let resolutionLabel = switch persistentResolution {
        case .created: "created"
        case .reused: "reused"
        case nil: "none"
        }
        switch result {
        case let .failed(failure):
            Self.logger.error(
                "App command failed route=\(routeLabel, privacy: .public) resolution=\(resolutionLabel, privacy: .public) reason=\(failure.rawValue, privacy: .public)"
            )
        case let .partialSuccess(workspaceID, reason):
            let reasonLabel = switch reason {
            case .cancelled: "cancelled"
            case let .failed(failure): failure.rawValue
            }
            Self.logger.warning(
                "App command partially succeeded route=\(routeLabel, privacy: .public) resolution=\(resolutionLabel, privacy: .public) workspaceID=\(workspaceID.uuidString, privacy: .public) reason=\(reasonLabel, privacy: .public)"
            )
        case .completed, .cancelled:
            break
        }
    }
}
