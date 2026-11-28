import AppKit
import Foundation
import RepoPromptRemoteProtocol

/// Opens and closes saved workspaces through the existing Mac window lifecycle.
@MainActor
final class RemoteWorkspacePresentationController {
    enum OpenSource {
        case picker
        case voice

        enum Destination: Equatable {
            case reuseWindow(Int)
            case newWindow
            case needsPicker
        }

        func destination(welcomeWindowID: Int?, voiceWindowID: Int?) -> Destination {
            switch self {
            case .picker:
                welcomeWindowID.map(Destination.reuseWindow) ?? .newWindow
            case .voice:
                (voiceWindowID ?? welcomeWindowID).map(Destination.reuseWindow) ?? .needsPicker
            }
        }
    }

    private var isChanging = false
    private var voiceWindow: (windowID: Int, workspaceID: UUID)?

    static func supportsControl(for workspace: WorkspaceModel) -> Bool {
        !workspace.isSystemWorkspace && !workspace.isEphemeral && workspace.consolidatedIntoWorkspaceID == nil
    }

    static func windows(showing workspaceID: UUID, in manager: WindowStatesManager) -> [WindowState] {
        manager.allWindows.filter { !$0.isClosing && $0.workspaceManager.activeWorkspaceID == workspaceID }
    }

    func set(
        _ request: RemoteWorkspacePresentation,
        source: OpenSource = .picker,
        in manager: WindowStatesManager,
        isVoiceActive: (UUID) -> Bool,
        authorizeDispatch: RemoteDispatchAuthorization
    ) async throws {
        func requireAccess() throws {
            try Task.checkCancellation()
            try authorizeDispatch()
            guard !manager.isTerminating else {
                throw RemoteAgentControlServiceError.commandRejected("RepoPrompt is closing on the Mac.")
            }
        }

        try requireAccess()
        guard !isChanging else {
            throw RemoteAgentControlServiceError.commandRejected("The Mac is already changing workspaces. Try again in a moment.")
        }
        isChanging = true
        defer { isChanging = false }

        let workspaceID = request.workspaceID
        await manager.waitForWindowRestoreBeforeWorkspaceLink(workspaceID: workspaceID)
        try requireAccess()
        let windows = manager.allWindows.filter { !$0.isClosing }
        guard !windows.isEmpty else {
            throw RemoteAgentControlServiceError.commandRejected("Open a RepoPrompt window on the Mac and try again.")
        }
        guard let workspace = windows.lazy.compactMap({ $0.workspaceManager.workspace(withID: workspaceID) }).first else {
            throw RemoteAgentControlServiceError.workspaceNotFound
        }
        guard Self.supportsControl(for: workspace) else {
            throw RemoteAgentControlServiceError.commandRejected("This workspace can only be managed on the Mac.")
        }

        let showing = Self.windows(showing: workspaceID, in: manager)
        if request.isOpen {
            if !showing.isEmpty {
                if source == .picker, voiceWindow?.workspaceID == workspaceID { voiceWindow = nil }
                return
            }
            try await open(
                workspaceID, source: source, windows: windows, manager: manager,
                isVoiceActive: isVoiceActive, authorizeDispatch: requireAccess
            )
        } else {
            guard !showing.isEmpty else { return }
            guard !isVoiceActive(workspaceID) else { throw RemoteWorkspaceVoiceError.busy }
            guard showing.allSatisfy({ $0.nsWindow != nil && isIdle($0) }) else { throw activeWorkError }
            for window in showing {
                try requireAccess()
                guard !window.isClosing, window.workspaceManager.activeWorkspaceID == workspaceID else { continue }
                guard !isVoiceActive(workspaceID) else { throw RemoteWorkspaceVoiceError.busy }
                guard window.nsWindow != nil, isIdle(window) else { throw activeWorkError }
                try await close(workspaceID, in: window, manager: manager)
            }
        }

        try requireAccess()
        let isOpen = !Self.windows(showing: workspaceID, in: manager).isEmpty
        guard isOpen == request.isOpen else {
            throw RemoteAgentControlServiceError.commandRejected("The workspace changed on the Mac. Check its status and try again.")
        }
    }

    private func open(
        _ workspaceID: UUID,
        source: OpenSource,
        windows: [WindowState],
        manager: WindowStatesManager,
        isVoiceActive: (UUID) -> Bool,
        authorizeDispatch: RemoteDispatchAuthorization
    ) async throws {
        let candidates = windows.filter { window in
            guard isIdle(window),
                  window.workspaceManager.activeWorkspaceID.map(isVoiceActive) != true,
                  let target = window.workspaceManager.workspace(withID: workspaceID)
            else { return false }
            return Self.supportsControl(for: target)
        }
        let welcomeWindowID = candidates.first(where: isWelcomeWindow)?.windowID
        let voiceWindowID = candidates.first { window in
            guard let voiceWindow else { return false }
            return window.windowID == voiceWindow.windowID && window.workspaceManager.activeWorkspaceID == voiceWindow.workspaceID
        }?.windowID

        try authorizeDispatch()
        switch source.destination(welcomeWindowID: welcomeWindowID, voiceWindowID: voiceWindowID) {
        case let .reuseWindow(windowID):
            guard let window = candidates.first(where: { $0.windowID == windowID }),
                  let target = window.workspaceManager.workspace(withID: workspaceID)
            else { throw RemoteAgentControlServiceError.workspaceNotFound }
            try await switchWorkspace(in: window, to: target)
            if source == .voice { voiceWindow = (windowID, workspaceID) }
        case .newWindow:
            try await openInNewWindow(workspaceID, manager: manager, authorizeDispatch: authorizeDispatch)
        case .needsPicker:
            throw RemoteAgentControlServiceError.commandRejected("Turn on this workspace in Remote’s workspace picker, then start Voice.")
        }
    }

    private func openInNewWindow(
        _ workspaceID: UUID, manager: WindowStatesManager, authorizeDispatch: RemoteDispatchAuthorization
    ) async throws {
        let window = try await manager.openNewMainWindow(
            deferringInitialAgentSystemWorkspaceRefresh: true, matchingRestoreWorkspaceID: workspaceID
        )
        defer {
            if !manager.isTerminating, window.nsWindow != nil, isIdle(window), isWelcomeWindow(window),
               canCloseWindow(window, in: manager)
            {
                window.requestClose()
            }
            window.agentModeViewModel.finishInitialSystemWorkspaceSessionListRefreshDeferral(refreshIfStillSystem: !window.isClosing)
        }
        await window.workspaceManager.awaitInitialized()
        await manager.waitForWindowRestoreBeforeWorkspaceLink(workspaceID: workspaceID, openedWindowID: window.windowID)
        try authorizeDispatch()
        if !Self.windows(showing: workspaceID, in: manager).isEmpty { return }
        guard manager.window(withID: window.windowID) === window, isIdle(window), isWelcomeWindow(window) else {
            throw RemoteAgentControlServiceError.commandRejected("The new Mac window is already in use. Try opening the workspace again.")
        }
        guard let target = window.workspaceManager.workspace(withID: workspaceID) else {
            throw RemoteAgentControlServiceError.workspaceNotFound
        }
        guard Self.supportsControl(for: target) else {
            throw RemoteAgentControlServiceError.commandRejected("This workspace can only be managed on the Mac.")
        }
        try await switchWorkspace(in: window, to: target)
    }

    private func canCloseWindow(_ window: WindowState, in manager: WindowStatesManager) -> Bool {
        // Keep a window for the Remote gateway and honor the normal Mac close policy.
        manager.allWindows.contains(where: { !$0.isClosing && $0 !== window })
            && WindowCloseCoordinator.decide(snapshot: window.makeCloseImpactSnapshot(), authorization: nil) == .allow
    }

    private func close(_ workspaceID: UUID, in window: WindowState, manager: WindowStatesManager) async throws {
        if canCloseWindow(window, in: manager) {
            window.requestClose()
            if window.isClosing { return }
            throw RemoteAgentControlServiceError.commandRejected("The Mac window could not be closed.")
        }

        let fallback = window.workspaceManager.getOrCreateSystemWorkspace()
        guard fallback.id != workspaceID, fallback.repoPaths.isEmpty else {
            throw RemoteAgentControlServiceError.commandRejected("The Mac could not return to its welcome workspace.")
        }
        try await switchWorkspace(in: window, to: fallback)
    }

    private func switchWorkspace(in window: WindowState, to workspace: WorkspaceModel) async throws {
        let result = await window.workspaceManager.requestWorkspaceSwitch(
            to: workspace, saveState: true, reason: "remote_workspace_presentation", silent: true
        )
        guard !window.isClosing, window.workspaceManager.activeWorkspaceID == workspace.id else {
            throw RemoteAgentControlServiceError.commandRejected(result.message ?? "The Mac could not switch workspaces.")
        }
    }

    private func isWelcomeWindow(_ window: WindowState) -> Bool {
        let manager = window.workspaceManager
        if manager.activeWorkspaceID == nil { return true }
        guard let workspace = manager.activeWorkspace else { return false }
        return workspace.isSystemWorkspace && workspace.repoPaths.isEmpty
    }

    private func isIdle(_ window: WindowState) -> Bool {
        let workspace = window.workspaceManager
        return !window.isClosing && !window.hasUnfinishedRestoreExecution
            && window.nsWindow?.attachedSheet == nil
            && workspace.isInitialized && workspace.activeWorkspaceSwitch == nil
            && !workspace.isSwitchingWorkspace && !workspace.isRefreshing && !workspace.isChatBusy
            && !workspace.activeSessionSnapshot().hasActiveSessions
    }

    private var activeWorkError: RemoteAgentControlServiceError {
        .commandRejected("This workspace is in use on the Mac. Try again when it’s idle.")
    }
}
