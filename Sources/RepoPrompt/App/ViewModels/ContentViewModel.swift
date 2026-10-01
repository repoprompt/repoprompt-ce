import Combine
import SwiftUI

// MARK: - App Root Route

/// Top-level routing: workspace entry flow vs main app content.
enum AppRootRoute: Equatable {
    /// Full-window workspace chooser + optional setup guide.
    case workspaceEntry
    /// Normal app content.
    case main
}

/// Tabs within the workspace entry flow.
enum WorkspaceEntryTab: Equatable {
    case workspaces
    case setupGuide
}

// MARK: - ContentViewModel

@MainActor
class ContentViewModel: ObservableObject {
    // App-level routing
    @Published var rootRoute: AppRootRoute = .main
    @Published var workspaceEntryTab: WorkspaceEntryTab = .workspaces
    @Published var onboardingViewModel: AgentOnboardingWizardViewModel?

    /// Using Combine for notification handling
    private var cancellables = Set<AnyCancellable>()

    #if DEBUG
        private var workspaceRouteConsumptionHandlerForTesting: ((UUID?) -> Void)?

        func setWorkspaceRouteConsumptionHandlerForTesting(_ handler: ((UUID?) -> Void)?) {
            precondition(
                workspaceRouteConsumptionHandlerForTesting == nil || handler == nil,
                "Workspace route consumption supports only one test recorder"
            )
            workspaceRouteConsumptionHandlerForTesting = handler
        }
    #endif

    /// Instead of storing each manager individually, store a reference to the whole window's state.
    let state: WindowState

    /// Shortcut properties
    var promptManager: PromptViewModel {
        state.promptManager
    }

    var apiSettingsViewModel: APISettingsViewModel {
        state.apiSettingsViewModel
    }

    var workspaceManager: WorkspaceManagerViewModel {
        state.workspaceManager
    }

    init(state: WindowState) {
        self.state = state

        // Sync workspace changes to drive routing. The consumer deliberately rereads current
        // manager state after scheduling rather than trusting the emitted ID.
        state.workspaceManager.$activeWorkspaceID
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                didConsumeWorkspaceRoute(synchronizeRouteWithCapturedSelection())
            }
            .store(in: &cancellables)

        // The root shell reads approval state through this model. Forward only
        // presentation changes so a request can appear without unrelated root
        // navigation, without invalidating the root for every MCP dashboard update.
        state.mcpServer.$pendingClientID
            .combineLatest(state.mcpServer.$isApprovalOverlayVisible)
            .removeDuplicates { $0.0 == $1.0 && $0.1 == $1.1 }
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    /// Passive observation only: direct route synchronization is not a publisher consumption.
    private func didConsumeWorkspaceRoute(_ readID: UUID?) {
        #if DEBUG
            workspaceRouteConsumptionHandlerForTesting?(readID)
        #endif
    }

    // MARK: - Route Management

    /// Whether the active workspace is the system fallback (i.e. no real workspace selected).
    var isInSystemFallback: Bool {
        capturedSelectionRouteState().isSystemFallback
    }

    /// Reads the active ID exactly once and resolves that same ID, so one evaluation cannot
    /// mix two different selections.
    private func capturedSelectionRouteState() -> (activeID: UUID?, isSystemFallback: Bool) {
        let activeID = state.workspaceManager.activeWorkspaceID
        guard let workspace = state.workspaceManager.workspace(withID: activeID) else {
            return (activeID, true)
        }
        return (activeID, workspace.isSystemWorkspace)
    }

    /// Called on first appear to determine initial route and optionally show onboarding.
    func evaluateInitialRouteIfNeeded() {
        if AppLaunchConfiguration.current.forcedRootRoute == .main {
            rootRoute = .main
            return
        }
        if isInSystemFallback {
            rootRoute = .workspaceEntry

            // Check if onboarding should auto-show
            let shouldShow = AgentOnboardingGate.shouldShow()
            if shouldShow, AgentOnboardingPresentationCoordinator.shared.claimPresentationSlot() {
                ensureOnboardingViewModel()
                workspaceEntryTab = .setupGuide
            } else {
                workspaceEntryTab = .workspaces
            }
        } else {
            rootRoute = .main
        }
    }

    /// Keeps route in sync when workspace changes (e.g. exit to fallback, or open workspace).
    func syncRouteWithWorkspaceState() {
        synchronizeRouteWithCapturedSelection()
    }

    /// Shared route body; returns the active ID it actually evaluated.
    @discardableResult
    private func synchronizeRouteWithCapturedSelection() -> UUID? {
        let selection = capturedSelectionRouteState()
        if AppLaunchConfiguration.current.forcedRootRoute == .main {
            rootRoute = .main
            return selection.activeID
        }
        if selection.isSystemFallback {
            if rootRoute != .workspaceEntry {
                rootRoute = .workspaceEntry
                workspaceEntryTab = .workspaces
            }
        } else {
            if rootRoute == .workspaceEntry {
                rootRoute = .main
            }
        }
        return selection.activeID
    }

    /// Shows the workspace entry flow with the setup guide tab (user-invoked from Help menu / notification).
    func presentSetupGuide() {
        ensureOnboardingViewModel()
        onboardingViewModel?.resetToStart()
        workspaceEntryTab = .setupGuide
        rootRoute = .workspaceEntry
    }

    /// Dismiss workspace entry if the user explicitly invoked it (not forced by system fallback).
    func dismissWorkspaceEntryIfAllowed() {
        if AppLaunchConfiguration.current.forcedRootRoute == .main {
            rootRoute = .main
            return
        }
        if !isInSystemFallback {
            rootRoute = .main
        }
    }

    /// Completes onboarding from either first launch or the manually opened setup guide.
    ///
    /// First launch starts in the system fallback workspace, so there is no main workspace
    /// to continue into yet. In that case, leave the setup guide and show the workspace
    /// chooser. If a real workspace is already active, return to the main app.
    func continueFromOnboarding() {
        if AppLaunchConfiguration.current.forcedRootRoute == .main {
            rootRoute = .main
            return
        }
        if isInSystemFallback {
            rootRoute = .workspaceEntry
            workspaceEntryTab = .workspaces
        } else {
            rootRoute = .main
        }
    }

    /// Lazily creates the onboarding view model if needed.
    func ensureOnboardingViewModel() {
        guard onboardingViewModel == nil else { return }
        let engine = AutoRecommendationEngine(
            settingsStore: GlobalSettingsStore.shared,
            profileSettingsManager: GlobalSettingsStore.shared,
            apiSettingsViewModel: apiSettingsViewModel
        )
        onboardingViewModel = AgentOnboardingWizardViewModel(
            engine: engine,
            apiSettingsViewModel: apiSettingsViewModel
        )
    }
}
