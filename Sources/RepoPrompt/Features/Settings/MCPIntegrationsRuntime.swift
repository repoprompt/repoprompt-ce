/// Compatibility façade for phase-1 callers. It never owns an independent operation or
/// authorization source; callers must supply the app-owned composition explicitly.
@MainActor
enum MCPIntegrationsRuntime {
    private static var registeredCoordinators: [WeakCoordinator] = []

    private final class WeakCoordinator {
        weak var value: FigmaMCPIntegrationCoordinator?

        init(_ value: FigmaMCPIntegrationCoordinator) {
            self.value = value
        }
    }

    static func register(_ coordinator: FigmaMCPIntegrationCoordinator) {
        registeredCoordinators = registeredCoordinators.filter { $0.value != nil }
        guard !registeredCoordinators.contains(where: { $0.value === coordinator }) else { return }
        registeredCoordinators.append(WeakCoordinator(coordinator))
    }

    static func coordinator(
        for settingsStore: GlobalSettingsStore,
        service: any FigmaMCPIntegrationManaging,
        runtimeAvailability: FigmaMCPRuntimeAvailabilityAuthority?,
        externalMCPComposition: AppExternalMCPComposition
    ) -> FigmaMCPIntegrationCoordinator {
        coordinator(
            externalMCPComposition: externalMCPComposition,
            settingsStore: settingsStore,
            service: service,
            runtimeAvailability: runtimeAvailability
        )
    }

    static func coordinator(
        externalMCPComposition: AppExternalMCPComposition,
        settingsStore: GlobalSettingsStore? = nil,
        service: (any FigmaMCPIntegrationManaging)? = nil,
        runtimeAvailability: FigmaMCPRuntimeAvailabilityAuthority? = nil
    ) -> FigmaMCPIntegrationCoordinator {
        let shared = externalMCPComposition.figmaCoordinator
        let resolvedSettingsStore = settingsStore ?? shared.settingsStore
        let resolvedService = service ?? shared.service
        let resolvedRuntimeAvailability = runtimeAvailability ?? shared.runtimeAvailabilityAuthority
        let sameService = ObjectIdentifier(resolvedService as AnyObject) == ObjectIdentifier(shared.service as AnyObject)
        if resolvedSettingsStore === shared.settingsStore,
           sameService,
           resolvedRuntimeAvailability === shared.runtimeAvailabilityAuthority
        {
            return shared
        }
        let existing = registeredCoordinators.compactMap(\.value).first { candidate in
            candidate.settingsStore === resolvedSettingsStore
                && ObjectIdentifier(candidate.service as AnyObject) == ObjectIdentifier(resolvedService as AnyObject)
                && candidate.runtimeAvailabilityAuthority === resolvedRuntimeAvailability
        }
        if let existing { return existing }
        let injected = FigmaMCPIntegrationCoordinator(
            settingsStore: resolvedSettingsStore,
            service: resolvedService,
            runtimeAvailability: resolvedRuntimeAvailability
        )
        register(injected)
        return injected
    }
}
