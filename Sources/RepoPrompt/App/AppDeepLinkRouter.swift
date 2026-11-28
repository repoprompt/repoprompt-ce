import AppKit
import Foundation
import RepoPromptDomainRuntime
import RepoPromptWorkspaceCore

@MainActor
final class AppDeepLinkRouter {
    private struct WorkspaceCandidateRepresentation {
        enum Source {
            case authority
            case pendingPersistentPublication(PendingPersistentWorkspacePublication)
            case ephemeralLiveWindow
        }

        let workspace: WorkspaceModel
        let targetWindow: WindowState
        let source: Source
    }

    static let shared = AppDeepLinkRouter()

    private let windowStatesManager: WindowStatesManager
    private var workspaceRoutesInFlight: Set<UUID> = []

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
        case let .route(.workspace(route)):
            await routeWorkspace(route, sourceURL: url)
        case .invalidWorkspaceRoute, .unsupported:
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
        case .workspace:
            return
        case .legacyURL:
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Notification click routing. Unlike in-app `route(agentSession:)`, a click that arrives before any
    /// window is live (cold launch from the notification, or MCP background mode) queues the route URL;
    /// `WindowStatesManager.registerWindowState` drains it once a window registers.
    func route(notificationRoute route: AgentSessionDeepLinkRoute?) async {
        guard let route else {
            NSApp?.activate(ignoringOtherApps: true)
            return
        }
        let liveWindows = windowStatesManager.allWindows.filter { !$0.isClosing }
        guard !liveWindows.isEmpty else {
            windowStatesManager.pendingURLs.append(route.url)
            NSApp?.activate(ignoringOtherApps: true)
            if MCPBackgroundModeCoordinator.shared.isBackgrounded {
                MCPBackgroundModeCoordinator.shared.restore()
            }
            return
        }
        _ = await self.route(agentSession: route)
    }

    func route(agentSession route: AgentSessionDeepLinkRoute) async -> AgentSessionRouteResult {
        await routeAgentSession(route, sourceURL: nil)
    }

    func routeLoadedAgentSession(sessionID: UUID) async {
        await Self.routeLoadedAgentSession(sessionID: sessionID, resolve: { sessionID in
            self.windowStatesManager.agentSessionLinkCandidates(
                forSessionIDs: [sessionID], includeLocation: false
            )[sessionID] ?? []
        }, isAvailable: { candidate in
            guard let window = self.windowStatesManager.allWindows.first(where: {
                $0.windowID == candidate.windowID && !$0.isClosing
            }), window.workspaceManager.isInitialized,
            let workspace = window.workspaceManager.activeWorkspace,
            workspace.id == candidate.workspaceID else { return false }
            return workspace.composeTabs.contains {
                $0.id == candidate.tabID && $0.activeAgentSessionID == sessionID
            }
        }, prepareNavigation: { route in
            guard let window = self.windowStatesManager.allWindows.first(where: {
                $0.windowID == route.windowID && !$0.isClosing
            }) else { return }
            if window.promptManager.activeComposeTabID != route.tabID {
                await window.promptManager.switchComposeTab(route.tabID)
            }
        }, navigate: { route in
            guard let window = self.windowStatesManager.allWindows.first(where: {
                $0.windowID == route.windowID && !$0.isClosing
            }), window.promptManager.activeComposeTabID == route.tabID else { return }
            NSApp?.activate(ignoringOtherApps: true)
            window.focusWindowIfPossible()
        })
    }

    static func routeLoadedAgentSession(
        sessionID: UUID,
        resolve: (UUID) -> [AgentSessionLinkEndpointCandidate],
        isAvailable: (AgentSessionLinkEndpointCandidate) -> Bool,
        prepareNavigation: (AgentSessionDeepLinkRoute) async -> Void = { _ in },
        navigate: (AgentSessionDeepLinkRoute) -> Void
    ) async {
        let matches = resolve(sessionID)
        guard matches.count == 1, let candidate = matches.first, candidate.sessionID == sessionID,
              !candidate.isClosing, !candidate.isDeletionInProgress,
              candidate.eligibilityInput.hasLoadedPersistedState, !candidate.bindingTransitionInProgress,
              isAvailable(candidate) else { return }
        let route = AgentSessionDeepLinkRoute(
            windowID: candidate.windowID, workspaceID: candidate.workspaceID,
            tabID: candidate.tabID, sessionID: sessionID
        )
        await prepareNavigation(route)
        // Switching tabs suspends. Never let an older badge click restore a binding replaced
        // during that suspension; the final check and focus have no intervening actor hop.
        let refreshed = resolve(sessionID)
        guard refreshed.count == 1, let current = refreshed.first,
              current.windowID == candidate.windowID, current.workspaceID == candidate.workspaceID,
              current.tabID == candidate.tabID, current.sessionID == candidate.sessionID,
              current.persistentBindingGeneration == candidate.persistentBindingGeneration,
              current.bindingTransitionGeneration == candidate.bindingTransitionGeneration,
              current.restorationReadiness == candidate.restorationReadiness,
              !current.isClosing, !current.isDeletionInProgress,
              current.eligibilityInput.hasLoadedPersistedState, !current.bindingTransitionInProgress,
              isAvailable(current) else { return }
        navigate(route)
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
        guard let routingCatalog else {
            receivingWindow.enqueueCommand(
                command,
                folderRoute: .unresolved(
                    expectedRoot: WorkspaceRootSetKey(paths: [folderPath])
                )
            )
            return
        }
        let expectedRoot = WorkspaceRootSetKey(paths: [folderPath])
        let admitsEphemeral = command.ephemeral == true || command.persist == false
        var candidateRepresentations: [UUID: WorkspaceCandidateRepresentation] = [:]

        // Persistent candidates come from one runtime-owned catalog snapshot. An authority-absent
        // persistent model is visible only while its exact creation task has a retained publication
        // token; live-window supplementation is otherwise restricted to ephemeral workspaces.
        for workspace in routingCatalog {
            candidateRepresentations[workspace.id] = WorkspaceCandidateRepresentation(
                workspace: workspace,
                targetWindow: receivingWindow,
                source: .authority
            )
        }
        for window in liveWindows {
            for workspace in window.workspaceManager.workspaces
                where !workspace.isEphemeral && candidateRepresentations[workspace.id] == nil
            {
                guard let publication = window.workspaceManager.pendingPersistentWorkspacePublication(
                    workspaceID: workspace.id,
                    exactRoot: expectedRoot
                ) else { continue }
                candidateRepresentations[workspace.id] = WorkspaceCandidateRepresentation(
                    workspace: workspace,
                    targetWindow: window,
                    source: .pendingPersistentPublication(publication)
                )
            }
            if admitsEphemeral,
               let activeWorkspace = window.workspaceManager.activeWorkspace,
               activeWorkspace.isEphemeral,
               candidateRepresentations[activeWorkspace.id] == nil
            {
                candidateRepresentations[activeWorkspace.id] = WorkspaceCandidateRepresentation(
                    workspace: activeWorkspace,
                    targetWindow: window,
                    source: .ephemeralLiveWindow
                )
            }
        }

        let candidates = candidateRepresentations.values.map(\.workspace)
        guard let winner = WorkspaceFolderOpenResolver.bestEligibleMatch(
            forFolderPath: folderPath,
            in: candidates,
            admittingEphemeral: admitsEphemeral
        ),
            let winningRepresentation = candidateRepresentations[winner.id]
        else {
            receivingWindow.enqueueCommand(
                command,
                folderRoute: .unresolved(
                    expectedRoot: WorkspaceRootSetKey(paths: [folderPath])
                )
            )
            return
        }

        let targetWindow: WindowState = if case .pendingPersistentPublication = winningRepresentation.source {
            winningRepresentation.targetWindow
        } else if command.focus == true,
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
        let folderRoute: FolderRouteState = switch winningRepresentation.source {
        case .authority:
            .authorityExactRoot(expectedRoot: expectedRoot)
        case let .pendingPersistentPublication(publication):
            .pendingPersistentPublication(publication)
        case .ephemeralLiveWindow:
            .ephemeralLiveWindowSupplement(
                workspaceID: winner.id,
                expectedRoot: expectedRoot
            )
        }
        targetWindow.enqueueCommand(command, folderRoute: folderRoute)
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

    private func routeWorkspace(_ route: WorkspaceDeepLinkRoute, sourceURL: URL) async {
        let id = route.workspaceID
        guard !windowStatesManager.isTerminating, !Task.isCancelled else { return }
        guard windowStatesManager.allWindows.contains(where: { !$0.isClosing }) else {
            windowStatesManager.pendingURLs.append(sourceURL)
            return
        }
        guard workspaceRoutesInFlight.insert(id).inserted else { return }
        defer { workspaceRoutesInFlight.remove(id) }

        func isShowing(_ window: WindowState) -> Bool {
            !window.isClosing && window.workspaceManager.isInitialized && !window.workspaceManager.isSwitchingWorkspace
                && window.workspaceManager.activeWorkspaceSwitch == nil && window.workspaceManager.activeWorkspaceID == id
        }
        func matchingWindow() -> WindowState? {
            guard !windowStatesManager.isLoadingWindowRestoreSnapshot else { return nil }
            let ordered = NSApp?.orderedWindows ?? []
            var positions: [ObjectIdentifier: Int] = [:]
            for (index, window) in ordered.enumerated() {
                let key = ObjectIdentifier(window.sheetParent ?? window)
                if positions[key] == nil { positions[key] = index }
            }
            return Self.preferredWorkspaceWindow(windowStatesManager.allWindows) { window in
                guard isShowing(window), !window.hasUnfinishedRestoreExecution, let native = window.nsWindow else { return nil }
                let displaysHint = route.tabID.map { tab in
                    window.promptManager.activeComposeTabID == tab && (
                        route.sessionID == nil
                            || window.agentModeViewModel.isAgentSessionDisplayed(tabID: tab, sessionID: route.sessionID)
                    )
                } ?? false
                return (displaysHint ? 0 : 1, positions[ObjectIdentifier(native)] ?? Int.max, window.windowID)
            }
        }

        await Self.routeWorkspaceTarget(resolve: { () -> WorkspaceModel? in
            let store = AppDomainRuntimeComposition.shared.runtime.workspaceStore
            guard let snapshot = await store.canonicalWorkspaceSnapshot(id), snapshot.health.acceptsMutations,
                  let workspace = try? WorkspaceManagerViewModel.decodeDomainWorkspaceProjection(
                      documentBytes: snapshot.document.documentBytes, fileURL: snapshot.document.fileURL
                  ), workspace.id == id, !workspace.isEphemeral, workspace.consolidatedIntoWorkspaceID == nil,
                  !self.windowStatesManager.isTerminating, !Task.isCancelled else { return nil }
            return workspace
        }, matchingWindow: matchingWindow, waitForRestore: {
            await windowStatesManager.waitForWindowRestoreBeforeWorkspaceLink(workspaceID: id)
        }, open: { (workspace: WorkspaceModel) -> WindowState? in
            guard !windowStatesManager.isTerminating, let opened = try? await windowStatesManager.openNewMainWindow(
                deferringInitialAgentSystemWorkspaceRefresh: true, matchingRestoreWorkspaceID: id
            ) else { return nil }
            defer { opened.agentModeViewModel.finishInitialSystemWorkspaceSessionListRefreshDeferral() }
            await opened.workspaceManager.awaitInitialized()
            await windowStatesManager.waitForWindowRestoreBeforeWorkspaceLink(workspaceID: id, openedWindowID: opened.windowID)
            guard !windowStatesManager.isTerminating, !Task.isCancelled, !opened.isClosing,
                  windowStatesManager.allWindows.contains(where: { $0 === opened }) else { return nil }
            if let existing = matchingWindow() { return existing }
            if !isShowing(opened) {
                if let current = opened.workspaceManager.activeWorkspace, !current.isSystemWorkspace || !current.repoPaths.isEmpty {
                    return nil
                }
                guard await (opened.workspaceManager.requestWorkspaceSwitch(
                    to: workspace, saveState: true, reason: "workspaceDeepLink", silent: true
                )).didSwitch else { return nil }
            }
            return opened
        }, show: { target in
            guard isShowing(target), !windowStatesManager.isTerminating, !Task.isCancelled else { return }
            if let tabID = route.tabID {
                _ = await target.navigateAgentDeepLinkTab(tabID, sessionID: route.sessionID, workspaceID: id, workspaceLink: true)
            }
            guard isShowing(target), windowStatesManager.allWindows.contains(where: { $0 === target }),
                  !windowStatesManager.isTerminating, !Task.isCancelled else { return }
            if MCPBackgroundModeCoordinator.shared.backgroundedWindowID == target.windowID {
                MCPBackgroundModeCoordinator.shared.restore()
                return
            }
            if target.nsWindow?.isMiniaturized == true { target.nsWindow?.deminiaturize(nil) }
            target.focusWindowIfPossible()
        })
    }

    static func preferredWorkspaceWindow<Window>(
        _ windows: [Window], rank: (Window) -> (Int, Int, Int)?
    ) -> Window? {
        var best: (Window, (Int, Int, Int))?
        for window in windows {
            guard let score = rank(window), best.map({ score < $0.1 }) ?? true else { continue }
            best = (window, score)
        }
        return best?.0
    }

    static func routeWorkspaceTarget<Workspace, Window>(
        resolve: () async -> Workspace?, matchingWindow: () -> Window?,
        waitForRestore: () async -> Bool = { false },
        open: (Workspace) async -> Window?, show: (Window) async -> Void
    ) async {
        guard let workspace = await resolve(), !Task.isCancelled else { return }
        var existing = matchingWindow()
        if existing == nil, await waitForRestore() {
            existing = matchingWindow()
        }
        guard !Task.isCancelled else { return }
        if let existing {
            await show(existing)
        } else if let opened = await open(workspace), !Task.isCancelled {
            await show(opened)
        }
    }

    @discardableResult
    private func routeAgentSession(_ route: AgentSessionDeepLinkRoute, sourceURL: URL?) async -> AgentSessionRouteResult {
        let liveWindows = windowStatesManager.allWindows.filter { !$0.isClosing }
        guard !liveWindows.isEmpty else {
            if let sourceURL {
                windowStatesManager.pendingURLs.append(sourceURL)
                NSApp?.activate(ignoringOtherApps: true)
            }
            return .workspaceUnavailable
        }
        // Cold-launch URLs may drain as soon as a window registers.
        for window in liveWindows where !window.isClosing && !window.workspaceManager.isInitialized {
            guard !Task.isCancelled, !windowStatesManager.isTerminating else { return .workspaceUnavailable }
            await window.workspaceManager.awaitInitialized()
        }
        await windowStatesManager.waitForWindowRestoreBeforeWorkspaceLink(workspaceID: route.workspaceID)
        return await Self.routeAgentSessionTarget(route, candidates: { () -> [AgentSessionCandidate<WindowState>] in
            guard !self.windowStatesManager.isTerminating else { return [] }
            let windows = self.windowStatesManager.allWindows.filter { !$0.isClosing }
            let preferred = windows.first { $0.windowID == route.windowID }
            let ordered = preferred.map { [$0] } ?? []
            return (ordered + windows.filter { $0 !== preferred }).compactMap { window in
                let manager = window.workspaceManager
                let showingTarget = manager.activeWorkspaceID == route.workspaceID
                guard manager.isInitialized, !manager.isSwitchingWorkspace, manager.activeWorkspaceSwitch == nil,
                      !window.hasUnfinishedRestoreExecution
                else { return showingTarget ? .unready : nil }
                if showingTarget {
                    guard let workspace = manager.activeWorkspace, workspace.id == route.workspaceID else { return .unready }
                    return .showing(window, workspace)
                }
                guard let workspace = manager.workspace(withID: route.workspaceID) else { return nil }
                return .canSwitch(window, localEphemeralWorkspace: workspace.isEphemeral ? workspace : nil)
            }
        }, resolveWorkspace: {
            let store = AppDomainRuntimeComposition.shared.runtime.workspaceStore
            guard let snapshot = await store.canonicalWorkspaceSnapshot(route.workspaceID), snapshot.health.acceptsMutations else { return nil }
            return try? WorkspaceManagerViewModel.decodeDomainWorkspaceProjection(
                documentBytes: snapshot.document.documentBytes,
                fileURL: snapshot.document.fileURL,
                preserveUnreadableDocument: false
            )
        }, navigate: { window, workspace in
            await window.routeToAgentSession(route, validatedWorkspace: workspace)
        })
    }

    enum AgentSessionCandidate<Window> {
        case showing(Window, WorkspaceModel)
        case canSwitch(Window, localEphemeralWorkspace: WorkspaceModel? = nil)
        case unready
    }

    static func containsAgentDeepLinkTab(_ tabID: UUID, in workspace: WorkspaceModel) -> Bool {
        workspace.composeTabs.contains { $0.id == tabID } || workspace.stashedTabs.contains { $0.tab.id == tabID }
    }

    static func routeAgentSessionTarget<Window>(
        _ route: AgentSessionDeepLinkRoute,
        candidates: () -> [AgentSessionCandidate<Window>],
        resolveWorkspace: () async -> WorkspaceModel?,
        navigate: (Window, WorkspaceModel) async -> AgentSessionRouteResult
    ) async -> AgentSessionRouteResult {
        var snapshot = candidates()
        var readWorkspace = false
        var workspace: WorkspaceModel?
        while !Task.isCancelled {
            var hasActiveCopy = false
            var hasUnreadyCopy = false
            var switchTarget: (window: Window, localEphemeralWorkspace: WorkspaceModel?)?
            for candidate in snapshot {
                switch candidate {
                case let .showing(window, activeWorkspace):
                    hasActiveCopy = true
                    if activeWorkspace.composeTabsDecodeWasLossy {
                        hasUnreadyCopy = true
                    } else if containsAgentDeepLinkTab(route.tabID, in: activeWorkspace) {
                        return await navigate(window, activeWorkspace)
                    }
                case let .canSwitch(window, localEphemeralWorkspace):
                    if switchTarget == nil { switchTarget = (window, localEphemeralWorkspace) }
                case .unready:
                    hasUnreadyCopy = true
                }
            }
            if hasUnreadyCopy { return .workspaceUnavailable }
            if hasActiveCopy { return .tabUnavailable }
            guard let switchTarget else { return .workspaceUnavailable }
            let destination = switchTarget.localEphemeralWorkspace ?? workspace
            if switchTarget.localEphemeralWorkspace != nil || readWorkspace {
                guard let destination, destination.id == route.workspaceID,
                      !destination.composeTabsDecodeWasLossy else { return .workspaceUnavailable }
                guard containsAgentDeepLinkTab(route.tabID, in: destination) else { return .tabUnavailable }
                return await navigate(switchTarget.window, destination)
            }
            workspace = await resolveWorkspace()
            readWorkspace = true
            snapshot = candidates()
        }
        return .workspaceUnavailable
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
