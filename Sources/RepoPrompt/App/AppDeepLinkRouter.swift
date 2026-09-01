import AppKit
import Foundation

@MainActor
final class AppDeepLinkRouter {
    private struct WorkspaceCandidateRepresentation {
        let workspace: WorkspaceModel
        let targetWindow: WindowState
        let isAuthorityOwned: Bool
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
            await routeLegacyURL(legacyURL, preferredWindow: preferredLegacyWindow)
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

    private func routeLegacyURL(_ url: URL, preferredWindow: WindowState?) async {
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
        await routeOpenCommand(
            command,
            sourceURL: url,
            receivingWindow: targetWindow,
            attemptedWindowIDs: [targetWindow.windowID]
        )
    }

    private func routeOpenCommand(
        _ command: AppCommand,
        sourceURL: URL,
        receivingWindow: WindowState,
        attemptedWindowIDs: Set<Int>
    ) async {
        guard let folderPath = command.folderPath, !folderPath.isEmpty else {
            receivingWindow.enqueueCommand(command)
            return
        }

        let routingCatalog = await receivingWindow.workspaceManager.workspaceRoutingCatalogSnapshot()
        let liveWindows = windowStatesManager.allWindows.filter { !$0.isClosing }
        guard liveWindows.contains(where: { $0 === receivingWindow }) else {
            await rerouteOpenCommand(
                command,
                sourceURL: sourceURL,
                attemptedWindowIDs: attemptedWindowIDs
            )
            return
        }
        guard let routingCatalog else { return }
        var candidateRepresentations: [UUID: WorkspaceCandidateRepresentation] = [:]

        // Persistent candidates come from one runtime-owned catalog snapshot in production.
        // Active windows supplement authority-missing IDs so ephemeral and not-yet-published
        // workspaces remain reusable without turning per-window projections into authority.
        for workspace in routingCatalog {
            candidateRepresentations[workspace.id] = WorkspaceCandidateRepresentation(
                workspace: workspace,
                targetWindow: receivingWindow,
                isAuthorityOwned: true
            )
        }
        for window in liveWindows {
            if let activeWorkspace = window.workspaceManager.activeWorkspace,
               candidateRepresentations[activeWorkspace.id] == nil
            {
                candidateRepresentations[activeWorkspace.id] = WorkspaceCandidateRepresentation(
                    workspace: activeWorkspace,
                    targetWindow: window,
                    isAuthorityOwned: false
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

        let targetWindow: WindowState = if command.focus == true,
                                           let activeWindow = liveWindows.first(where: { window in
                                               guard let activeWorkspace = window.workspaceManager.activeWorkspace,
                                                     activeWorkspace.id == winner.id
                                               else { return false }
                                               return WorkspaceFolderOpenResolver.containsExactRoot(
                                                   folderPath,
                                                   in: activeWorkspace
                                               )
                                           })
        {
            activeWindow
        } else {
            winningRepresentation.targetWindow
        }

        guard !targetWindow.isClosing else {
            await rerouteOpenCommand(
                command,
                sourceURL: sourceURL,
                attemptedWindowIDs: attemptedWindowIDs.union([targetWindow.windowID])
            )
            return
        }
        targetWindow.enqueueCommand(
            command,
            resolvedFolderWorkspaceID: winner.id,
            expectedFolderRootKey: WorkspaceRootSetKey(paths: [folderPath]),
            allowsLocalWorkspaceFallback: !winningRepresentation.isAuthorityOwned
        )
    }

    private func rerouteOpenCommand(
        _ command: AppCommand,
        sourceURL: URL,
        attemptedWindowIDs: Set<Int>
    ) async {
        guard let retryWindow = legacyTargetWindow(
            for: sourceURL,
            excluding: attemptedWindowIDs
        ) else {
            windowStatesManager.pendingURLs.append(sourceURL)
            return
        }
        await routeOpenCommand(
            command,
            sourceURL: sourceURL,
            receivingWindow: retryWindow,
            attemptedWindowIDs: attemptedWindowIDs.union([retryWindow.windowID])
        )
    }

    private func legacyTargetWindow(
        for url: URL,
        excluding attemptedWindowIDs: Set<Int> = []
    ) -> WindowState? {
        let liveWindows = windowStatesManager.allWindows.filter {
            !$0.isClosing && !attemptedWindowIDs.contains($0.windowID)
        }
        switch Self.legacyWindowPreference(for: url) {
        case .earliest:
            return liveWindows.first
        case .latest:
            return liveWindows.last
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
