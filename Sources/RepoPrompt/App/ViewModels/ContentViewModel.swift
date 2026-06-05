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

        // Sync workspace changes to drive routing
        state.workspaceManager.workspaceObservation.$activeWorkspaceID
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.syncRouteWithWorkspaceState()
            }
            .store(in: &cancellables)
    }

    // MARK: - Route Management

    /// Whether the active workspace is the system fallback (i.e. no real workspace selected).
    var isInSystemFallback: Bool {
        guard let ws = state.workspaceManager.activeWorkspace else { return true }
        return ws.isSystemWorkspace
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
        if AppLaunchConfiguration.current.forcedRootRoute == .main {
            rootRoute = .main
            return
        }
        if isInSystemFallback {
            if rootRoute != .workspaceEntry {
                rootRoute = .workspaceEntry
                workspaceEntryTab = .workspaces
            }
        } else {
            if rootRoute == .workspaceEntry {
                rootRoute = .main
            }
        }
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

    /// Lazily creates the onboarding view model if needed.
    func ensureOnboardingViewModel() {
        guard onboardingViewModel == nil else { return }
        let engine = AutoRecommendationEngine(
            settingsStore: GlobalSettingsStore.shared,
            apiSettingsViewModel: apiSettingsViewModel
        )
        onboardingViewModel = AgentOnboardingWizardViewModel(
            engine: engine,
            apiSettingsViewModel: apiSettingsViewModel
        )
    }
}
