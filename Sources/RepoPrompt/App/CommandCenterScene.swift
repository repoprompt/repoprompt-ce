import AppKit
import Combine
import RepoPromptSettingsCore
import SwiftUI

/// Scene opening and exact existing-owner composition live here. Command Center itself creates no
/// WindowState and never registers a workspace window, restore claim, or routing endpoint.
@MainActor
final class CommandCenterWindowOpener {
    private let isEnabled: @MainActor () -> Bool
    private var open: (() -> Void)?
    private var pending = false

    init(isEnabled: @escaping @MainActor () -> Bool = { GlobalSettingsStore.shared.experimentalCommandCenter() }) {
        self.isEnabled = isEnabled
    }

    func install(_ open: @escaping () -> Void) {
        self.open = open
        if pending {
            pending = false
            if isEnabled() { open() }
        }
    }

    func show() {
        guard isEnabled() else { pending = false
            return
        }
        guard let open else { pending = true
            return
        }
        open()
    }
}

struct CommandCenterCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var display = GlobalKeyboardShortcutsCoordinator.shared.bindingDisplay
    @ObservedObject private var settings = GlobalSettingsStore.shared

    var body: some Commands {
        CommandGroup(before: .windowList) {
            if settings.experimentalCommandCenter() {
                Button(display.title("Command Center", for: .showCommandCenter)) {
                    guard settings.experimentalCommandCenter() else { return }
                    openWindow(id: "command-center")
                }
            }
        }
    }
}

/// Explicit selected-session loading, independent of every workspace window's selection. No new
/// view model, runtime, writer, observer identity or oversight link is constructed for presentation.
@MainActor
enum CommandCenterConversationHost {
    static func load(_ row: CommandCenterSessionRow) async -> CommandCenterConversationModel.LoadResult {
        await load(row, isEnabled: { GlobalSettingsStore.shared.experimentalCommandCenter() })
    }

    static func load(
        _ row: CommandCenterSessionRow, isEnabled: @escaping @MainActor () -> Bool
    ) async -> CommandCenterConversationModel.LoadResult {
        let manager = WindowStatesManager.shared
        guard isEnabled(), !Task.isCancelled, !manager.isTerminating else {
            return .unavailable("Command Center is disabled or the application is closing.")
        }
        let census = AgentSessionCarrierResolver.capture(
            windows: manager.sessionRuntimeWindows, sessionIDs: [row.sessionID], includeRuntimeOwners: true
        )
        guard !census.ambiguousSessionIDs.contains(row.sessionID), !census.replicatedSessionIDs.contains(row.sessionID) else {
            return .unavailable("This session has ambiguous owners. Open its workspace to resolve the duplicate.")
        }
        if let owner = census.uniqueRuntimeOwners[row.sessionID], owner.location.workspaceID == row.workspaceID {
            return .ready(source(for: owner, isEnabled: isEnabled))
        }
        // Only the canonical active-workspace carrier can load an unmaterialized session here.
        // Historical/rebound/stashed/cold carriers use explicit Open, not an owner factory or an
        // oversight preparation whose retention/handoff lifetime belongs to a different feature.
        guard !manager.hasPreparedRuntime(row.sessionID), let location = census.uniqueLocations[row.sessionID],
              census.isCurrent(), location.workspaceID == row.workspaceID,
              location.tab.id == row.tabID, location.stashedTabID == nil,
              location.tab.activeAgentSessionID == row.sessionID,
              location.window.workspaceManager.activeWorkspaceID == row.workspaceID
        else {
            return .unavailable("Open this session in its workspace to load the conversation. Its saved metadata remains listed here.")
        }
        let window = location.window
        _ = await window.agentModeViewModel.ensureSessionReady(tabID: location.tab.id, reconnectActiveProviders: false)
        guard isEnabled(), !Task.isCancelled,
              let current = SessionAdminWindows.runtimeOwner(for: row.sessionID),
              current.location.window === window, current.location.workspaceID == row.workspaceID,
              current.location.tab.id == location.tab.id
        else {
            return .unavailable("The session changed or could not be loaded. Open its workspace to continue.")
        }
        return .ready(source(for: current, isEnabled: isEnabled))
    }

    static func source(
        for owner: AgentSessionCarrierResolver.RuntimeOwner,
        isEnabled: @escaping @MainActor () -> Bool = { GlobalSettingsStore.shared.experimentalCommandCenter() }
    ) -> CommandCenterConversationModel.Source {
        let window = owner.location.window
        let session = owner.session
        let isCurrent: @MainActor () -> Bool = {
            isEnabled() && !WindowStatesManager.shared.isTerminating && !window.isClosing
                && SessionAdminWindows.isCurrent(owner)
                && session.currentRestorationBindingToken == owner.binding
                && session.permitsBoundOperationAndSave
        }
        return CommandCenterConversationModel.Source(
            isCurrent: isCurrent,
            snapshot: { limit in
                guard isCurrent(), !session.terminalCommitInProgress else { return nil }
                let display = CommandCenterConversationRows.build(
                    transcript: session.transcript, working: session.items,
                    hiddenIDs: session.quietLedger.hiddenSourceIDs, limit: limit
                )
                return .init(
                    windowID: window.windowID, workspaceID: owner.location.workspaceID,
                    tabID: session.tabID, title: window.workspaceManager.workspace(withID: owner.location.workspaceID)?
                        .composeTabs.first(where: { $0.id == session.tabID && $0.activeAgentSessionID == owner.location.sessionID })?.name ?? owner.location.tab.name,
                    provider: "\(session.selectedAgent.displayName) · \(session.selectedModelRaw)",
                    runState: session.runState.rawValue,
                    rows: display.rows, hasEarlierRows: display.hasEarlier,
                    hasPendingInteraction: session.hasPendingQuestionUI || session.pendingApproval != nil
                        || session.pendingPermissionsRequest != nil || session.pendingApplyEditsReview != nil
                        || session.pendingWorktreeMergeReview != nil || session.pendingCodexHookReview != nil
                )
            },
            changes: session.objectWillChange.map { _ in () }
                .merge(with: session.monitorReadinessChangePublisher).eraseToAnyPublisher()
        )
    }
}

@MainActor
enum CommandCenterNavigation {
    /// Explicit Open & Send only. This creates a NEW visible window; it never switches an
    /// existing window, follows a first-window fallback, or allocates a hidden runtime owner.
    static func openNewDestination(workspaceID: UUID) async throws -> WindowState {
        let manager = WindowStatesManager.shared
        guard GlobalSettingsStore.shared.experimentalCommandCenter(), !manager.isTerminating, !Task.isCancelled else { throw CancellationError() }
        let target = try await manager.openNewMainWindow(deferringInitialAgentSystemWorkspaceRefresh: true)
        defer { target.agentModeViewModel.finishInitialSystemWorkspaceSessionListRefreshDeferral() }
        await target.workspaceManager.awaitInitialized()
        guard !Task.isCancelled, GlobalSettingsStore.shared.experimentalCommandCenter(), !target.isClosing,
              manager.window(withID: target.windowID) === target,
              let workspace = target.workspaceManager.workspace(withID: workspaceID) else { throw AgentSessionLaneDestinationFailure.destinationChanged }
        let result = await target.workspaceManager.requestWorkspaceSwitch(to: workspace, saveState: true)
        guard result.didSwitch, !Task.isCancelled, !target.isClosing, target.workspaceManager.activeWorkspaceID == workspaceID else { throw AgentSessionLaneDestinationFailure.destinationChanged }
        return target
    }

    static func open(workspaceID: UUID, session: CommandCenterSessionRow? = nil) async -> String? {
        let manager = WindowStatesManager.shared
        guard !Task.isCancelled, GlobalSettingsStore.shared.experimentalCommandCenter() else { return "Command Center is disabled" }
        guard !manager.isTerminating else { return "Application is shutting down" }
        let catalog = await AppDomainRuntimeComposition.shared.runtime.workspaceStore.snapshot()
        guard !Task.isCancelled, GlobalSettingsStore.shared.experimentalCommandCenter() else { return "Command Center is disabled" }
        guard catalog.workspaces.contains(where: { $0.document.workspaceID == workspaceID }),
              !catalog.unavailableWorkspaceIDs.contains(workspaceID)
        else { return "Workspace is unavailable" }
        do {
            let target: WindowState
            let exactOwner = (session.flatMap { CommandCenterSubmissionHost.owner($0.id) }?.location.window).flatMap { window in
                manager.allWindows.contains(where: { $0 === window }) && !window.isClosing
                    && window.workspaceManager.activeWorkspaceID == workspaceID ? window : nil
            }
            let destinations = CommandCenterSubmissionHost.destinations(projectID: workspaceID)
            if let exactOwner {
                target = exactOwner
            } else if destinations.count == 1 {
                target = destinations[0]
            } else if destinations.count > 1 {
                return "More than one window has this project open. Open the desired workspace window explicitly; no window was selected."
            } else {
                target = try await manager.openNewMainWindow(deferringInitialAgentSystemWorkspaceRefresh: true)
                defer { target.agentModeViewModel.finishInitialSystemWorkspaceSessionListRefreshDeferral() }
                await target.workspaceManager.awaitInitialized()
                guard !Task.isCancelled, GlobalSettingsStore.shared.experimentalCommandCenter() else { return "Command Center is disabled" }
                guard !target.isClosing, let workspace = target.workspaceManager.workspace(withID: workspaceID) else {
                    return "Workspace could not be loaded; no other workspace was selected"
                }
                let result = await target.workspaceManager.requestWorkspaceSwitch(to: workspace, saveState: true)
                guard result.didSwitch else { return result.message ?? "Workspace switch refused" }
            }
            guard !Task.isCancelled, GlobalSettingsStore.shared.experimentalCommandCenter() else { return "Command Center is disabled" }
            guard !target.isClosing else { return "Workspace window closed" }
            if let session {
                guard let tabID = session.tabID else { return "Session has no saved context; open it from workspace history" }
                let result = await AppDeepLinkRouter.shared.route(agentSession: AgentSessionDeepLinkRoute(
                    windowID: target.windowID, workspaceID: workspaceID, tabID: tabID, sessionID: session.sessionID
                ))
                return result == .routed ? nil : "Session could not be revealed: \(result)"
            }
            target.focusWindowIfPossible()
            NSApp?.activate(ignoringOtherApps: true)
            return nil
        } catch {
            return "Could not open workspace: \(error.localizedDescription)"
        }
    }
}
