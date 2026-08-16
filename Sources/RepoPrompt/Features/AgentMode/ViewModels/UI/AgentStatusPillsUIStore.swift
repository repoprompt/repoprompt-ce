import Combine
import Foundation

struct AgentExecutionLocationProps: Equatable {
    let tabID: UUID
    let selection: AgentModeViewModel.InitialStartLocation
    let indicator: AgentWorktreeIndicator?
    let isInitialSelection: Bool
    let isEnabled: Bool
    let isOperationInProgress: Bool
    let requiresActiveRunConfirmation: Bool
    let disabledReason: String?
}

/// Immutable UI projection of the active Agent session's canonical worktree bindings.
/// Identity checks fail closed so a stale render snapshot can never attach bindings to
/// a different tab or session. Core routing remains the authority that hydrates and
/// mutates the `TabSession`; SwiftUI only consumes this projection.
struct AgentContextWorktreeBindingsProjection: Equatable {
    let tabID: UUID?
    let activeAgentSessionID: UUID?
    let bindings: [AgentSessionWorktreeBinding]

    static let empty = AgentContextWorktreeBindingsProjection(
        tabID: nil,
        activeAgentSessionID: nil,
        bindings: []
    )

    func bindings(for sessionID: UUID, tabID requestedTabID: UUID?) -> [AgentSessionWorktreeBinding] {
        guard activeAgentSessionID == sessionID,
              tabID == requestedTabID
        else { return [] }
        return bindings
    }
}

struct AgentStatusPillsSnapshot: Equatable {
    let currentTabID: UUID?
    let selectedWorkflow: AgentWorkflowDefinition?
    let stagedSlashCommand: AgentStagedSlashCommandProps?
    let selectedAgent: AgentProviderKind
    let autoEditPermissionGuidance: AgentModeViewModel.AutoEditPermissionGuidance?
    let runState: AgentSessionRunState
    let autoEditEnabled: Bool
    let interviewFirst: Bool
    let executionLocation: AgentExecutionLocationProps?
    let activeAgentSessionID: UUID?
    let contextWorktreeBindings: AgentContextWorktreeBindingsProjection
    let activeRunID: UUID?

    static let empty = AgentStatusPillsSnapshot(
        currentTabID: nil,
        selectedWorkflow: nil,
        stagedSlashCommand: nil,
        selectedAgent: .claudeCode,
        autoEditPermissionGuidance: nil,
        runState: .idle,
        autoEditEnabled: ApplyEditsApprovalStore.globalDefaultAutoEditEnabled(),
        interviewFirst: false,
        executionLocation: nil,
        activeAgentSessionID: nil,
        contextWorktreeBindings: .empty,
        activeRunID: nil
    )
}

@MainActor
final class AgentStatusPillsUIStore: ObservableObject {
    @Published private(set) var snapshot: AgentStatusPillsSnapshot
    @Published private(set) var revision: UInt64 = 0

    init(snapshot: AgentStatusPillsSnapshot = .empty) {
        self.snapshot = snapshot
    }

    func update(_ nextSnapshot: AgentStatusPillsSnapshot) {
        guard snapshot != nextSnapshot else {
            #if DEBUG
                AgentModePerfDiagnostics.recordStoreUpdate("statusPills", published: false)
            #endif
            return
        }
        snapshot = nextSnapshot
        revision &+= 1
        #if DEBUG
            AgentModePerfDiagnostics.recordStoreUpdate(
                "statusPills",
                published: true,
                details: [
                    "revision": String(revision),
                    "runState": String(describing: snapshot.runState),
                    "tabID": AgentModePerfDiagnostics.shortID(snapshot.currentTabID)
                ]
            )
        #endif
    }
}
