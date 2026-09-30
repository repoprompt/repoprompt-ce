@testable import RepoPromptApp

/// An explicit, isolated graph for tests that do not exercise production AppDelegate ownership.
@MainActor
enum FigmaMCPTestGraph {
    static func make(
        figmaCoordinator: FigmaMCPIntegrationCoordinator? = nil,
        registry: ExternalMCPAdapterRegistry? = nil,
        providerConnectionCoordinator: FigmaMCPProviderConnectionCoordinator? = nil,
        terminalSessionController: FigmaMCPProviderTerminalHandoff.SessionController = .init(closeRunner: { _ in }),
        cursorToolSurfaceObserver: any CursorFigmaMCPToolSurfaceObserving = CursorFigmaMCPSettingsToolSurfaceObserver()
    ) -> AppExternalMCPComposition {
        AppExternalMCPComposition(
            figmaCoordinator: figmaCoordinator ?? FigmaMCPIntegrationCoordinator(
                runtimeAvailability: FigmaMCPRuntimeAvailabilityAuthority()
            ),
            terminalSessionController: terminalSessionController,
            cursorToolSurfaceObserver: cursorToolSurfaceObserver,
            registry: registry,
            providerConnectionCoordinator: providerConnectionCoordinator
        )
    }
}
