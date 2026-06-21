import Foundation
import RepoPromptCore

@MainActor
final class WorkspaceSessionCommandClient {
    let sessionID: WorkspaceSessionID
    let ingress: any WorkspaceSessionCommandIngress

    private(set) var snapshot: WorkspaceSessionSnapshot?
    private(set) var admissionToken: WorkspaceSessionAdmissionToken?
    private var projectionWaiter: (@MainActor (UInt64) async -> Void)?
    private var trackedTasks: [UUID: Task<WorkspaceSessionCommandResult, Never>] = [:]
    private var commandTail: Task<Void, Never>?

    init(sessionID: WorkspaceSessionID, ingress: any WorkspaceSessionCommandIngress) {
        self.sessionID = sessionID
        self.ingress = ingress
    }

    func bindProjectionWaiter(_ waiter: @escaping @MainActor (UInt64) async -> Void) {
        precondition(projectionWaiter == nil, "workspace projection waiter may be bound only once")
        projectionWaiter = waiter
    }

    @discardableResult
    func applyAuthoritativeSnapshot(_ snapshot: WorkspaceSessionSnapshot) -> Bool {
        guard snapshot.sessionID == sessionID else { return false }
        guard self.snapshot.map({ snapshot.snapshotSequence >= $0.snapshotSequence }) ?? true else { return false }
        self.snapshot = snapshot
        switch snapshot.availability {
        case .active, .switching:
            break
        case .created, .hydrating, .awaitingActivation, .failed, .closing, .closed:
            admissionToken = nil
        }
        return true
    }

    func acquireAdmission() async -> WorkspaceSessionAdmissionResult {
        let result = await ingress.admit()
        if case let .admitted(token) = result {
            admissionToken = token
        }
        return result
    }

    func execute(
        _ command: WorkspaceSessionCommand,
        source: WorkspaceSessionCommandSource,
        exactAdmissionToken: WorkspaceSessionAdmissionToken? = nil,
        expectedGeneration: UInt64? = nil
    ) async -> WorkspaceSessionCommandResult {
        await commandTail?.value
        return await executeNow(
            command,
            source: source,
            exactAdmissionToken: exactAdmissionToken,
            expectedGeneration: expectedGeneration
        )
    }

    private func executeNow(
        _ command: WorkspaceSessionCommand,
        source: WorkspaceSessionCommandSource,
        exactAdmissionToken: WorkspaceSessionAdmissionToken?,
        expectedGeneration: UInt64?
    ) async -> WorkspaceSessionCommandResult {
        guard let snapshot, let token = exactAdmissionToken ?? admissionToken else {
            return .notReady(snapshot?.availability ?? .created)
        }
        guard token.sessionID == sessionID else { return .rejected(.foreignSession) }
        let envelope = WorkspaceSessionCommandEnvelope(
            admissionToken: token,
            expectedGeneration: expectedGeneration ?? snapshot.stateGeneration,
            command: command,
            source: source
        )
        let result = await ingress.execute(envelope)
        absorb(result)
        switch result {
        case let .committed(receipt), let .unchanged(receipt):
            guard receipt.sessionID == sessionID,
                  receipt.activationID == token.activationID
            else { return .rejected(.expiredActivation) }
            await projectionWaiter?(receipt.snapshotSequence)
        default:
            break
        }
        return result
    }

    func replaceSelection(
        workspaceID: UUID,
        tabID: UUID,
        selection: StoredSelection,
        expectedRevision: UInt64,
        source: WorkspaceSessionCommandSource,
        exactAdmissionToken: WorkspaceSessionAdmissionToken? = nil,
        expectedGeneration: UInt64? = nil
    ) async -> WorkspaceSessionCommandResult {
        await execute(
            .selection(
                WorkspaceSelectionCommand(
                    workspaceID: workspaceID,
                    tabID: tabID,
                    expectedRevision: expectedRevision,
                    selection: selection
                )
            ),
            source: source,
            exactAdmissionToken: exactAdmissionToken,
            expectedGeneration: expectedGeneration
        )
    }

    /// Tracks compatibility tasks created by synchronous SwiftUI actions. The task is retained,
    /// observable through `flushTrackedTasks`, and failures are never discarded silently.
    @discardableResult
    func submitTracked(
        _ command: WorkspaceSessionCommand,
        source: WorkspaceSessionCommandSource,
        onResult: @escaping @MainActor (WorkspaceSessionCommandResult) -> Void
    ) -> UUID {
        let id = UUID()
        let predecessor = commandTail
        let task = Task<WorkspaceSessionCommandResult, Never> { [weak self] in
            await predecessor?.value
            guard let self else { return .notReady(.closed) }
            let result = await executeNow(
                command,
                source: source,
                exactAdmissionToken: nil,
                expectedGeneration: nil
            )
            onResult(result)
            trackedTasks.removeValue(forKey: id)
            return result
        }
        trackedTasks[id] = task
        commandTail = Task { _ = await task.value }
        return id
    }

    func flushTrackedTasks() async -> [WorkspaceSessionCommandResult] {
        let tasks = Array(trackedTasks.values)
        return await withTaskGroup(of: WorkspaceSessionCommandResult.self) { group in
            tasks.forEach { task in group.addTask { await task.value } }
            var results: [WorkspaceSessionCommandResult] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
    }

    private func absorb(_ result: WorkspaceSessionCommandResult) {
        if case let .stale(latestSnapshot, _) = result {
            applyAuthoritativeSnapshot(latestSnapshot)
        }
    }
}
