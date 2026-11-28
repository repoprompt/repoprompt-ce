import AppKit
import Foundation
import RepoPromptRemoteProtocol

/// Opens and closes saved workspaces through the existing Mac window lifecycle.
@MainActor
final class RemoteWorkspacePresentationController {
    private var isChanging = false
    private var lastReusedWindowID: Int?

    static func supportsControl(for workspace: WorkspaceModel) -> Bool {
        !workspace.isSystemWorkspace && !workspace.isEphemeral && workspace.consolidatedIntoWorkspaceID == nil
    }

    static func windows(showing workspaceID: UUID, in manager: WindowStatesManager) -> [WindowState] {
        manager.allWindows.filter { !$0.isClosing && $0.workspaceManager.activeWorkspaceID == workspaceID }
    }

    func set(
        _ request: RemoteWorkspacePresentation,
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
            guard showing.isEmpty else { return }
            try await open(workspaceID, in: windows, isVoiceActive: isVoiceActive)
        } else {
            guard !showing.isEmpty else { return }
            guard !isVoiceActive(workspaceID) else { throw RemoteWorkspaceVoiceError.busy }
            guard showing.allSatisfy(isIdle) else { throw activeWorkError }
            for window in showing {
                try requireAccess()
                guard !window.isClosing, window.workspaceManager.activeWorkspaceID == workspaceID else { continue }
                guard !isVoiceActive(workspaceID) else { throw RemoteWorkspaceVoiceError.busy }
                guard isIdle(window) else { throw activeWorkError }
                try await close(workspaceID, in: window, manager: manager)
            }
        }

        try requireAccess()
        let isOpen = !Self.windows(showing: workspaceID, in: manager).isEmpty
        guard isOpen == request.isOpen else {
            throw RemoteAgentControlServiceError.commandRejected("The workspace changed on the Mac. Check its status and try again.")
        }
    }

    private func open(_ workspaceID: UUID, in windows: [WindowState], isVoiceActive: (UUID) -> Bool) async throws {
        let candidates = windows.filter { window in
            guard isIdle(window), let current = window.workspaceManager.activeWorkspace,
                  !current.isEphemeral, !isVoiceActive(current.id),
                  let target = window.workspaceManager.workspace(withID: workspaceID) else { return false }
            return Self.supportsControl(for: target)
        }
        let window = candidates.first {
            $0.workspaceManager.activeWorkspace?.isSystemWorkspace == true
                && $0.workspaceManager.activeWorkspace?.repoPaths.isEmpty == true
        } ?? candidates.first { $0.windowID == lastReusedWindowID }
            ?? candidates.first { !$0.isCurrentlyFocused }
            ?? candidates.first

        guard let window, let target = window.workspaceManager.workspace(withID: workspaceID) else {
            throw RemoteAgentControlServiceError.commandRejected("No idle workspace window is available on the Mac. Try again when a window is idle.")
        }
        try await switchWorkspace(in: window, to: target)
        lastReusedWindowID = window.windowID
    }

    private func close(_ workspaceID: UUID, in window: WindowState, manager: WindowStatesManager) async throws {
        // Keep a window for the Remote gateway and honor the normal Mac close policy.
        if manager.allWindows.contains(where: { !$0.isClosing && $0 !== window }),
           WindowCloseCoordinator.decide(snapshot: window.makeCloseImpactSnapshot(), authorization: nil) == .allow
        {
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

    private func isIdle(_ window: WindowState) -> Bool {
        let workspace = window.workspaceManager
        return !window.isClosing && !window.hasUnfinishedRestoreExecution
            && window.nsWindow != nil && window.nsWindow?.attachedSheet == nil
            && workspace.isInitialized && workspace.activeWorkspaceSwitch == nil
            && !workspace.isSwitchingWorkspace && !workspace.isRefreshing && !workspace.isChatBusy
            && !workspace.activeSessionSnapshot().hasActiveSessions
    }

    private var activeWorkError: RemoteAgentControlServiceError {
        .commandRejected("This workspace is in use on the Mac. Try again when it’s idle.")
    }
}
