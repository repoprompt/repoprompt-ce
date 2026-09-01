import AppKit
import Foundation

@MainActor
final class AppDeepLinkRouter {
    private struct WorkspaceCandidateRepresentation {
        let workspace: WorkspaceModel
        let targetWindow: WindowState
    }

    static let shared = AppDeepLinkRouter()

    private let windowStatesManager: WindowStatesManager

    private init() {
        windowStatesManager = WindowStatesManager.shared
    }

    init(windowStatesManager: WindowStatesManager) {
        self.windowStatesManager = windowStatesManager
    }

    func route(url: URL) async {
        await route(url: url, preferredLegacyWindow: nil)
    }

    func route(url: URL, preferredLegacyWindow: WindowState?) async {
        switch AppDeepLinkRoute.parse(url: url) {
        case let .route(.legacyURL(legacyURL)):
            routeLegacyURL(legacyURL, preferredWindow: preferredLegacyWindow)
        case let .route(.agentSession(route)):
            await routeAgentSession(route, sourceURL: url)
        case .invalidScopedRoute:
            NSApp.activate(ignoringOtherApps: true)
        case .unsupported:
            return
        }
    }

    func route(notificationUserInfo userInfo: [AnyHashable: Any]) async {
        guard let route = AppDeepLinkRoute.parse(notificationUserInfo: userInfo) else {
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        switch route {
        case let .agentSession(agentRoute):
            await self.route(notificationRoute: agentRoute)
        case .legacyURL:
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func route(notificationRoute route: AgentSessionDeepLinkRoute?) async {
        guard let route else {
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        _ = await self.route(agentSession: route)
    }

    func route(agentSession route: AgentSessionDeepLinkRoute) async -> AgentSessionRouteResult {
        await routeAgentSession(route, sourceURL: nil)
    }

    private func routeLegacyURL(_ url: URL, preferredWindow: WindowState?) {
        let targetWindow: WindowState? = if let preferredWindow, !preferredWindow.isClosing {
            preferredWindow
        } else {
            legacyTargetWindow(for: url)
        }

        guard let targetWindow else {
            windowStatesManager.pendingURLs.append(url)
            return
        }
        guard let command = targetWindow.decodeOpenCommand(from: url) else {
            targetWindow.handleIncomingURL(url)
            return
        }
        routeOpenCommand(command, receivingWindow: targetWindow)
    }

    private func routeOpenCommand(_ command: AppCommand, receivingWindow: WindowState) {
        guard let folderPath = command.folderPath, !folderPath.isEmpty else {
            receivingWindow.enqueueCommand(command)
            return
        }

        let liveWindows = windowStatesManager.allWindows.filter { !$0.isClosing }
        var candidateRepresentations: [UUID: WorkspaceCandidateRepresentation] = [:]

        // The receiving catalog is the persistent workspace authority for this route. Active
        // windows supplement catalog-missing IDs so ephemeral and not-yet-projected workspaces
        // remain reusable without letting unrelated activity timestamps override root state.
        for workspace in receivingWindow.workspaceManager.workspaces {
            candidateRepresentations[workspace.id] = WorkspaceCandidateRepresentation(
                workspace: workspace,
                targetWindow: receivingWindow
            )
        }
        for window in liveWindows {
            if let activeWorkspace = window.workspaceManager.activeWorkspace,
               candidateRepresentations[activeWorkspace.id] == nil
            {
                candidateRepresentations[activeWorkspace.id] = WorkspaceCandidateRepresentation(
                    workspace: activeWorkspace,
                    targetWindow: window
                )
            }
        }

        let candidates = candidateRepresentations.values.map(\.workspace)
        let admitsEphemeral = command.ephemeral == true || command.persist == false
        guard let winner = WorkspaceFolderOpenResolver.bestEligibleMatch(
            forFolderPath: folderPath,
            in: candidates,
            admittingEphemeral: admitsEphemeral
        ),
            let winningRepresentation = candidateRepresentations[winner.id]
        else {
            receivingWindow.enqueueCommand(command)
            return
        }

        winningRepresentation.targetWindow.enqueueCommand(
            command,
            resolvedFolderWorkspaceID: winner.id
        )
    }

    private func legacyTargetWindow(for url: URL) -> WindowState? {
        switch Self.legacyWindowPreference(for: url) {
        case .earliest:
            windowStatesManager.allWindows.first
        case .latest:
            windowStatesManager.latestWindowState
        }
    }

    @discardableResult
    private func routeAgentSession(_ route: AgentSessionDeepLinkRoute, sourceURL: URL?) async -> AgentSessionRouteResult {
        let liveWindows = windowStatesManager.allWindows.filter { !$0.isClosing }
        if let app = NSApp {
            app.activate(ignoringOtherApps: true)
        }
        guard !liveWindows.isEmpty else {
            if let sourceURL {
                windowStatesManager.pendingURLs.append(sourceURL)
            }
            return .workspaceUnavailable
        }
        var attemptedWindowIDs = Set<Int>()
        var latestResult: AgentSessionRouteResult = .workspaceUnavailable

        for candidate in Self.agentSessionPreferredExistingWindows(for: route, in: liveWindows) {
            attemptedWindowIDs.insert(candidate.windowID)
            let result = await routeAgentSession(route, on: candidate)
            latestResult = result
            if result == .routed || !Self.shouldTryNextAgentSessionWindow(after: result) {
                return result
            }
        }

        for candidate in Self.agentSessionFallbackExistingWindows(for: route, in: liveWindows)
            where !attemptedWindowIDs.contains(candidate.windowID)
        {
            let result = await routeAgentSession(route, on: candidate)
            latestResult = result
            if result == .routed || !Self.shouldTryNextAgentSessionWindow(after: result) {
                return result
            }
        }
        return latestResult
    }

    private func routeAgentSession(_ route: AgentSessionDeepLinkRoute, on targetWindow: WindowState) async -> AgentSessionRouteResult {
        if let window = targetWindow.nsWindow {
            window.makeKeyAndOrderFront(nil)
        } else {
            targetWindow.focusWindowIfPossible()
        }

        return await targetWindow.routeToAgentSession(route)
    }

    @MainActor
    static func agentSessionPreferredExistingWindows(for route: AgentSessionDeepLinkRoute, in liveWindows: [WindowState]) -> [WindowState] {
        var ordered: [WindowState] = []
        var seenWindowIDs = Set<Int>()

        if let windowID = route.windowID,
           let sourceWindow = liveWindows.first(where: { $0.windowID == windowID })
        {
            ordered.append(sourceWindow)
            seenWindowIDs.insert(sourceWindow.windowID)
        }

        for window in liveWindows where window.workspaceManager.activeWorkspace?.id == route.workspaceID {
            guard !seenWindowIDs.contains(window.windowID) else { continue }
            ordered.append(window)
            seenWindowIDs.insert(window.windowID)
        }

        return ordered
    }

    @MainActor
    static func agentSessionPreferredExistingWindow(for route: AgentSessionDeepLinkRoute, in liveWindows: [WindowState]) -> WindowState? {
        agentSessionPreferredExistingWindows(for: route, in: liveWindows).first
    }

    @MainActor
    static func agentSessionFallbackExistingWindows(for route: AgentSessionDeepLinkRoute, in liveWindows: [WindowState]) -> [WindowState] {
        liveWindows.filter { window in
            window.workspaceManager.workspace(withID: route.workspaceID) != nil
        }
    }

    @MainActor
    static func agentSessionFallbackExistingWindow(for route: AgentSessionDeepLinkRoute, in liveWindows: [WindowState]) -> WindowState? {
        agentSessionFallbackExistingWindows(for: route, in: liveWindows).first
    }

    nonisolated static func shouldTryNextAgentSessionWindow(after result: AgentSessionRouteResult) -> Bool {
        switch result {
        case .workspaceUnavailable, .workspaceSwitchBlocked, .tabUnavailable:
            true
        case .routed, .sessionUnavailable, .sessionMismatch, .blockedByActiveDifferentSession:
            false
        }
    }

    nonisolated static func legacyWindowPreference(for url: URL) -> LegacyWindowPreference {
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           components.host?.lowercased() == "prompt"
        {
            return .earliest
        }
        return .latest
    }

    enum LegacyWindowPreference: Equatable {
        case earliest
        case latest
    }
}
