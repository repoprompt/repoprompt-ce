import Foundation
import RepoPromptDomainRuntime
import RepoPromptSettingsCore

/// Exact registered human destination. This gate does not focus, switch, restore, or create windows.
extension WindowStatesManager {
    func commandCenterCreateSession(
        destinationWindowID: Int,
        workspaceID: UUID,
        selection: AgentSessionLanePolicy.RoleSelection, humanDraft: AgentComposerDraftState? = nil
    ) async throws -> AgentModeViewModel.MCPOversightLaneCreationOutcome {
        guard GlobalSettingsStore.shared.experimentalCommandCenter(), !isTerminating,
              let destination = window(withID: destinationWindowID), !destination.isClosing,
              destination.workspaceManager.activeWorkspaceID == workspaceID,
              destination.workspaceManager.activeWorkspace?.id == workspaceID
        else {
            throw AgentSessionLaneDestinationFailure.destinationChanged
        }
        return try await destination.agentModeViewModel.createHumanSessionWithoutActivation(
            sessionName: nil, selection: selection, expectedWorkspaceID: workspaceID, humanDraft: humanDraft
        )
    }
}

@MainActor
enum CommandCenterSubmissionHost {
    static func destinations(projectID: UUID) -> [WindowState] {
        let manager = WindowStatesManager.shared
        guard !manager.isTerminating else { return [] }
        return manager.allWindows.filter {
            !$0.isClosing && $0.workspaceManager.activeWorkspaceID == projectID
                && manager.window(withID: $0.windowID) === $0
        }.sorted { $0.windowID < $1.windowID }
    }

    static func owner(_ id: CommandCenterSessionRow.ID) -> AgentSessionCarrierResolver.RuntimeOwner? {
        let census = AgentSessionCarrierResolver.capture(
            windows: WindowStatesManager.shared.sessionRuntimeWindows, sessionIDs: [id.sessionID], includeRuntimeOwners: true
        )
        guard !census.ambiguousSessionIDs.contains(id.sessionID), !census.replicatedSessionIDs.contains(id.sessionID),
              census.isCurrent(), let owner = census.uniqueRuntimeOwners[id.sessionID],
              owner.location.workspaceID == id.workspaceID, SessionAdminWindows.isCurrent(owner) else { return nil }
        return owner
    }

    enum SidebarEdit { case togglePin, rename(String) }

    /// Cheap render-time eligibility; activation performs the full unique-owner census again.
    static func canEdit(_ row: CommandCenterSessionRow) -> Bool {
        guard GlobalSettingsStore.shared.experimentalCommandCenter(),
              case let .live(endpoint, _, _) = row.provenance,
              let window = WindowStatesManager.shared.window(withID: endpoint.windowID),
              !window.isClosing, window.workspaceManager.activeWorkspaceID == row.workspaceID,
              window.agentModeViewModel.canPerformDirectSidebarCommand(workspaceID: row.workspaceID)
        else { return false }
        return window.agentModeViewModel.linkExecutionRuntime.agentSessionLinkObserverEndpoint(tabID: endpoint.tabID) == endpoint
    }

    @discardableResult
    static func edit(_ row: CommandCenterSessionRow, _ edit: SidebarEdit) -> Bool {
        guard canEdit(row), case let .live(endpoint, _, _) = row.provenance,
              let owner = owner(row.id), owner.location.window.windowID == endpoint.windowID,
              owner.location.window.agentModeViewModel.linkExecutionRuntime.agentSessionLinkObserverEndpoint(tabID: endpoint.tabID) == endpoint,
              CommandCenterConversationHost.source(for: owner).isCurrent()
        else { return false }
        let prompt = owner.location.window.promptManager
        switch edit {
        case .togglePin: prompt.toggleComposeTabPinned(endpoint.tabID)
        case let .rename(name): prompt.renameComposeTab(endpoint.tabID, to: name)
        }
        return true
    }

    static func endpoint(_ owner: AgentSessionCarrierResolver.RuntimeOwner) -> CommandCenterSendCoordinator.Endpoint {
        let window = owner.location.window
        let vm = window.agentModeViewModel
        let session = owner.session
        let id = CommandCenterSessionRow.ID(workspaceID: owner.location.workspaceID, sessionID: owner.location.sessionID)
        let current = CommandCenterConversationHost.source(for: owner).isCurrent
        return .init(id: id, isCurrent: current, submit: { text in
            guard current(), let target = vm.makeComposerSubmitTarget(tabID: session.tabID, session: session),
                  target.route == .existingAgentSession else { return .blocked(message: "The session changed before Send.") }
            // This existing human submit overload claims the exact writer without active-tab
            // ownership. A nil creator closes its only activating fallback; no noncomposer bypass.
            return await vm.submitUserTurnCreatingSessionIfNeeded(text: text, target: target, createAndActivateSessionTab: { nil })
        })
    }

    private static func create(projectID: UUID, windowID: Int, selection: AgentSessionLanePolicy.RoleSelection, urls: [URL], draft: AgentComposerDraftState?) async throws -> CommandCenterSendCoordinator.Creation {
        let outcome = try await WindowStatesManager.shared.commandCenterCreateSession(
            destinationWindowID: windowID, workspaceID: projectID, selection: selection, humanDraft: draft
        )
        switch outcome {
        case let .creationIncomplete(sessionID, _): return .incomplete(.init(workspaceID: projectID, sessionID: sessionID))
        case let .created(sessionID, tabID, binding):
            let id = CommandCenterSessionRow.ID(workspaceID: projectID, sessionID: sessionID)
            guard let owner = owner(id), owner.location.window.windowID == windowID,
                  owner.session.tabID == tabID, owner.binding == binding else { return .incomplete(id) }
            let source = endpoint(owner)
            let vm = owner.location.window.agentModeViewModel
            guard source.isCurrent() else { return .incomplete(id) }
            if let draft {
                guard let write = vm.runtimeSessionStore.interactions(routeID: owner.location.window.windowID, approvalStore: vm.applyEditsApprovalStore).setAutoEditEnabled(draft.autoEdit, for: owner.session) else { return .incomplete(id) }
                await write.value
                guard source.isCurrent() else { return .incomplete(id) }
            }
            // CC retains the submitted snapshot until its receipt. Do not overwrite a
            // draft a human may have typed in the newly visible background tab.
            if !urls.isEmpty {
                guard vm.imageAttachmentBlockReason(tabID: tabID) == nil else { return .incomplete(id) }
                var imported = false
                await vm.attachFiles(tabID: tabID, urls: urls, completion: { imported = $0 }, admission: source.isCurrent).value
                guard source.isCurrent(), imported else { return .incomplete(id) }
            }
            return .ready(source)
        }
    }

    static func coordinator() -> CommandCenterSendCoordinator {
        var environment = CommandCenterSendCoordinator.Environment(
            isEnabled: { GlobalSettingsStore.shared.experimentalCommandCenter() },
            resolve: { owner($0).map(endpoint) }, destinations: { destinations(projectID: $0).map(\.windowID) },
            create: { project, window, selection, urls, _ in try await create(projectID: project, windowID: window, selection: selection, urls: urls, draft: nil) }
        )
        environment.openDestination = { try await CommandCenterNavigation.openNewDestination(workspaceID: $0).windowID }
        environment.createConfigured = { project, window, selection, urls, _, draft in try await create(projectID: project, windowID: window, selection: selection, urls: urls, draft: draft) }
        return CommandCenterSendCoordinator(environment: environment)
    }
}
