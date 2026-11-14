import AppKit
import Combine
import RepoPromptDomainRuntime
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

    /// Scene entry uses the process app catalog. A bounded runtime fixture can supply its
    /// own catalog; this never substitutes for the canonical live-owner validation below.
    static func load(
        _ row: CommandCenterSessionRow, isEnabled: @escaping @MainActor () -> Bool,
        workspaceStore: DomainWorkspaceStore? = nil
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
        guard census.uniqueRuntimeOwners[row.sessionID] == nil, !manager.hasPreparedRuntime(row.sessionID) else {
            return .unavailable("This session's runtime moved or is being prepared. Select it again after the transition completes.")
        }
        // Browsing history must not materialize a runtime, even when its workspace is open.
        return await loadSaved(row, isEnabled: isEnabled, store: workspaceStore ?? AppDomainRuntimeComposition.shared.runtime.workspaceStore)
    }

    private static func loadSaved(
        _ row: CommandCenterSessionRow, isEnabled: @escaping @MainActor () -> Bool, store: DomainWorkspaceStore
    ) async -> CommandCenterConversationModel.LoadResult {
        let catalog = await store.snapshot()
        guard isEnabled(), !Task.isCancelled, !WindowStatesManager.shared.isTerminating,
              !catalog.unavailableWorkspaceIDs.contains(row.workspaceID),
              let document = catalog.workspaces.first(where: { $0.document.workspaceID == row.workspaceID })?.document
        else { return .unavailable("This project's saved history is unavailable.") }
        do {
            guard let session = try await AgentSessionDataService.shared.readSavedConversation(
                id: row.sessionID, workspaceID: row.workspaceID, directory: document.fileURL.deletingLastPathComponent()
            ) else { return .unavailable("This saved conversation no longer exists.") }
            let current = await store.snapshot()
            guard isEnabled(), !Task.isCancelled, !WindowStatesManager.shared.isTerminating,
                  !current.unavailableWorkspaceIDs.contains(row.workspaceID),
                  current.workspaces.first(where: { $0.document.workspaceID == row.workspaceID })?.document.fileURL == document.fileURL
            else { return .unavailable("The project changed while loading. Select the session again.") }
            // A live owner may have appeared while disk I/O was suspended. Never show a saved
            // frame in place of its newer canonical state or silently select an ambiguous owner.
            let census = AgentSessionCarrierResolver.capture(
                windows: WindowStatesManager.shared.sessionRuntimeWindows,
                sessionIDs: [row.sessionID], includeRuntimeOwners: true
            )
            guard !census.ambiguousSessionIDs.contains(row.sessionID), !census.replicatedSessionIDs.contains(row.sessionID) else {
                return .unavailable("This session has ambiguous owners. Open its workspace to resolve the duplicate.")
            }
            if let owner = census.uniqueRuntimeOwners[row.sessionID], owner.location.workspaceID == row.workspaceID {
                return .ready(source(for: owner, isEnabled: isEnabled))
            }
            guard census.uniqueRuntimeOwners[row.sessionID] == nil,
                  !WindowStatesManager.shared.hasPreparedRuntime(row.sessionID)
            else { return .unavailable("This session's runtime moved or is being prepared. Select it again after the transition completes.") }
            return .saved(session, isCurrent: {
                let manager = WindowStatesManager.shared
                let current = AgentSessionCarrierResolver.capture(
                    windows: manager.sessionRuntimeWindows, sessionIDs: [row.sessionID], includeRuntimeOwners: true
                )
                return !manager.hasPreparedRuntime(row.sessionID)
                    && current.uniqueRuntimeOwners[row.sessionID] == nil
                    && !current.ambiguousSessionIDs.contains(row.sessionID)
                    && !current.replicatedSessionIDs.contains(row.sessionID)
            })
        } catch is CancellationError {
            return .unavailable("Conversation loading cancelled.")
        } catch {
            return .unavailable("The saved conversation could not be read. No files were changed.")
        }
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
