import Foundation
import RepoPromptDomainRuntime

/// The same identity checks and revision-fenced writes apply to recovery started by
/// a workspace presenter and by a canonical execution host.
enum WorkspaceAgentAdmissionDocument {
    enum RecoveryMutation: Hashable {
        case removeTab
        case clearBinding
    }

    enum RecoveryProjection {
        case absent(WorkspaceModel)
        case removed(WorkspaceModel)
        case conflict

        var containsIdentity: Bool {
            if case .removed = self {
                return true
            }
            return false
        }
    }

    static func recoveryProjection(
        in workspace: WorkspaceModel,
        identity: AgentProvisionalAdmissionIdentity,
        mutation: RecoveryMutation = .removeTab,
        modificationDate: Date = Date()
    ) -> RecoveryProjection {
        guard workspace.id == identity.workspaceID else { return .conflict }
        let matchingTabIndices = workspace.composeTabs.indices.filter {
            workspace.composeTabs[$0].id == identity.tabID
        }
        guard matchingTabIndices.count <= 1 else { return .conflict }
        guard !workspace.stashedTabs.contains(where: {
            $0.tab.id == identity.tabID || $0.tab.activeAgentSessionID == identity.sessionID
        }) else { return .conflict }

        guard let tabIndex = matchingTabIndices.first else {
            guard !workspace.composeTabs.contains(where: {
                $0.activeAgentSessionID == identity.sessionID
            }) else { return .conflict }
            return mutation == .removeTab ? .absent(workspace) : .conflict
        }
        if mutation == .clearBinding,
           workspace.composeTabs[tabIndex].activeAgentSessionID == nil,
           !workspace.composeTabs.enumerated().contains(where: { index, tab in
               index != tabIndex && tab.activeAgentSessionID == identity.sessionID
           })
        {
            return .absent(workspace)
        }
        guard workspace.composeTabs[tabIndex].activeAgentSessionID == identity.sessionID,
              !workspace.composeTabs.enumerated().contains(where: { index, tab in
                  index != tabIndex && tab.activeAgentSessionID == identity.sessionID
              })
        else { return .conflict }

        var recovered = workspace
        switch mutation {
        case .removeTab:
            let removedWasActive = recovered.activeComposeTabID == identity.tabID
            recovered.composeTabs.remove(at: tabIndex)
            if recovered.composeTabs.isEmpty {
                let replacement = ComposeTabState(id: identity.replacementTabID)
                recovered.composeTabs = [replacement]
                recovered.activeComposeTabID = replacement.id
            } else if removedWasActive {
                let fallbackIndex = min(tabIndex, recovered.composeTabs.count - 1)
                recovered.activeComposeTabID = recovered.composeTabs[fallbackIndex].id
            }
        case .clearBinding:
            recovered.composeTabs[tabIndex].activeAgentSessionID = nil
            recovered.composeTabs[tabIndex].lastModified = modificationDate
        }
        recovered.dateModified = modificationDate

        var structuralExpectation = workspace
        structuralExpectation.composeTabs = recovered.composeTabs
        structuralExpectation.activeComposeTabID = recovered.activeComposeTabID
        structuralExpectation.dateModified = recovered.dateModified
        guard structuralExpectation == recovered else { return .conflict }
        return .removed(recovered)
    }

    static func encode(_ workspace: WorkspaceModel, fileURL: URL) throws -> DomainWorkspaceDocument {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(workspace)
        return try DomainWorkspaceDocument.decode(documentBytes: bytes, fileURL: fileURL)
    }

    /// The caller establishes ownership of the captured revision (and, on recovery,
    /// its exact digest). A save does not replace the working bytes. A retry uses the
    /// same operation ID and may not replay over an unrelated durable winner.
    static func execute(
        _ command: DomainWorkspaceCommand,
        store: DomainWorkspaceStore,
        origin: DomainCommandOrigin,
        expectedRevision: UInt64,
        operationID: UUID = UUID()
    ) async -> DomainCommandOutcome {
        let envelope = DomainWorkspaceCommandEnvelope(
            operationID: operationID,
            expectedWorkspaceRevision: expectedRevision,
            conflictRecoveryPolicy: .failClosed,
            origin: origin,
            command: command
        )
        let first = await store.execute(envelope)
        guard first.disposition == .failed,
              first.errorCode == .lockTimedOut || first.errorCode == .cancelled,
              !Task.isCancelled
        else { return first }
        await Task.yield()
        return await store.execute(envelope)
    }
}
