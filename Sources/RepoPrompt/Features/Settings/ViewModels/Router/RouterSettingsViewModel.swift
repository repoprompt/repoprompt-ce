import Combine
import Foundation
import RepoPromptSettingsCore

@MainActor
final class RouterSettingsViewModel: ObservableObject {
    enum BackendOperationFeedback: Equatable {
        case idle
        case running(String)
        case succeeded(String)
        case failed(String)

        var message: String? {
            switch self {
            case .idle: nil
            case let .running(message), let .succeeded(message), let .failed(message): message
            }
        }
    }

    struct BackendOption: Identifiable, Equatable {
        let id: DecisionServiceID
        let displayName: String
    }

    struct ServiceRow: Identifiable, Equatable {
        let id: DecisionServiceID
        let displayName: String
        let isModelRouterEligible: Bool
        let isAutoEffortEligible: Bool
        let displayOrder: Int
        let presentation: DecisionServiceSettingsPresentation?
    }

    struct ServiceState: Equatable {
        var readiness: DecisionReadiness
        var operationToken: UUID?
        var feedback: BackendOperationFeedback
    }

    struct TargetPreview: Identifiable, Equatable {
        let utilityTier: String
        let provider: AgentProviderKind
        let displayName: String
        let familyDisplayName: String?
        let target: AgentRoutingExecutableTarget

        init(
            utilityTier: String,
            provider: AgentProviderKind,
            displayName: String,
            familyDisplayName: String? = nil,
            target: AgentRoutingExecutableTarget
        ) {
            self.utilityTier = utilityTier
            self.provider = provider
            self.displayName = displayName
            self.familyDisplayName = familyDisplayName
            self.target = target
        }

        var id: String {
            "\(provider.rawValue):\(target.modelRaw)"
        }
    }

    struct UnavailableTargetPreview: Identifiable, Equatable {
        let id: String
        let displayName: String
        let provider: AgentProviderKind
        let reason: String
    }

    private struct ActiveCredentialOperation {
        let token: UUID
        let backendID: DecisionServiceID
        let capturedSelectedBackendID: DecisionServiceID?
        let capturedRouterRevision: UInt64
        let actionKind: DecisionServiceSettingsCredentialActionKind
    }

    @Published private(set) var serviceRows: [ServiceRow] = []
    @Published private var credentialStatesByID: [DecisionServiceID: ServiceState] = [:]
    var serviceStatesByID: [DecisionServiceID: ServiceState] {
        let readinessByID = runtime.decisionServiceReadinessByID
        return Dictionary(uniqueKeysWithValues: serviceRows.map { row in
            (
                row.id,
                Self.projectedServiceState(
                    for: row,
                    readiness: readinessByID[row.id],
                    credentialState: credentialStatesByID[row.id]
                )
            )
        })
    }

    @Published private(set) var configuration: AgentTaskRouterConfiguration
    @Published private(set) var autoEffortConfiguration: AutoEffortConfiguration
    @Published private(set) var targetPreviews: [TargetPreview] = []
    @Published private(set) var unavailableTargetPreviews: [UnavailableTargetPreview] = []
    @Published private(set) var policyCanBuildCandidates = false

    private let settingsStore: GlobalSettingsStore
    private let runtime: AgentTaskRouterRuntime
    private let apiSettingsViewModel: APISettingsViewModel
    private let availabilityProvider: @MainActor () -> AgentModelCatalog.AvailabilityContext
    private let targetPreviewBuilder: @MainActor (AgentModelCatalog.AvailabilityContext) throws -> [TargetPreview]
    private let unavailableTargetPreviewBuilder: @MainActor (AgentModelCatalog.AvailabilityContext) -> [UnavailableTargetPreview]
    private let refreshCompletionObserver: (@MainActor (AgentTaskRouterConfiguration) -> Void)?
    private weak var workspaceManager: WorkspaceManagerViewModel?
    private struct VerifiedProviderValidationSnapshot: Equatable {
        let providers: Set<AgentProviderKind>
        let isValidationComplete: Bool
    }

    private var lastObservedRouterConfiguration: AgentTaskRouterConfiguration
    private var lastObservedAutoEffortConfiguration: AutoEffortConfiguration
    private var lastForwardedReadinessByID: [DecisionServiceID: DecisionReadiness]
    private var targetPreviewAvailability: AgentModelCatalog.AvailabilityContext?
    private var refreshTask: Task<Void, Never>?
    private var refreshRequested = false
    private var activeCredentialOperation: ActiveCredentialOperation?
    private var cancellables = Set<AnyCancellable>()

    init(
        settingsStore: GlobalSettingsStore,
        runtime: AgentTaskRouterRuntime,
        apiSettingsViewModel: APISettingsViewModel,
        workspaceManager: WorkspaceManagerViewModel,
        availabilityProvider: (@MainActor () -> AgentModelCatalog.AvailabilityContext)? = nil,
        targetPreviewBuilder: (@MainActor (AgentModelCatalog.AvailabilityContext) throws -> [TargetPreview])? = nil,
        unavailableTargetPreviewBuilder: (@MainActor (AgentModelCatalog.AvailabilityContext) -> [UnavailableTargetPreview])? = nil,
        refreshCompletionObserver: (@MainActor (AgentTaskRouterConfiguration) -> Void)? = nil
    ) {
        self.settingsStore = settingsStore
        self.runtime = runtime
        self.apiSettingsViewModel = apiSettingsViewModel
        self.availabilityProvider = availabilityProvider ?? { apiSettingsViewModel.modelRouterAvailabilityContext }
        self.targetPreviewBuilder = targetPreviewBuilder ?? { availability in
            try Self.buildTargetPreviews(availability: availability)
        }
        self.unavailableTargetPreviewBuilder = unavailableTargetPreviewBuilder ?? { availability in
            Self.buildUnavailableTargetPreviews(availability: availability)
        }
        self.refreshCompletionObserver = refreshCompletionObserver
        self.workspaceManager = workspaceManager
        let initialRouterConfiguration = settingsStore.modelRouterConfiguration()
        let initialAutoEffortConfiguration = settingsStore.autoEffortConfiguration()
        configuration = initialRouterConfiguration
        autoEffortConfiguration = initialAutoEffortConfiguration
        lastObservedRouterConfiguration = initialRouterConfiguration
        lastObservedAutoEffortConfiguration = initialAutoEffortConfiguration
        lastForwardedReadinessByID = runtime.decisionServiceReadinessByID
        settingsStore.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.settingsStoreDidChange() }
            .store(in: &cancellables)
        runtime.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.forwardReadinessChangeIfNeeded() }
            .store(in: &cancellables)
        apiSettingsViewModel.$directConnectedCLIProviders
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &cancellables)
        apiSettingsViewModel.$agentAvailability
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &cancellables)
        apiSettingsViewModel.$availableCodexModels
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in _ = self?.agentExecutionCatalogDidChange() }
            .store(in: &cancellables)
        Publishers.CombineLatest(
            apiSettingsViewModel.$contextBuilderVerifiedCLIProviders,
            apiSettingsViewModel.$isContextBuilderProviderValidationComplete
        )
        .map { providers, isComplete in
            VerifiedProviderValidationSnapshot(providers: providers, isValidationComplete: isComplete)
        }
        .removeDuplicates()
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in self?.scheduleRefresh() }
        .store(in: &cancellables)
        workspaceManager.$activeWorkspaceID
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &cancellables)
        scheduleRefresh()
    }

    var backendOptions: [BackendOption] {
        serviceRows.compactMap { row in
            row.isModelRouterEligible ? BackendOption(id: row.id, displayName: row.displayName) : nil
        }
    }

    var selectedBackendID: DecisionServiceID? {
        configuration.selectedBackendID
    }

    var autoEffortBackendOptions: [BackendOption] {
        serviceRows.compactMap { row in
            row.isAutoEffortEligible ? BackendOption(id: row.id, displayName: row.displayName) : nil
        }
    }

    var selectedAutoEffortBackendID: DecisionServiceID? {
        autoEffortConfiguration.selectedBackendID
    }

    var autoEffortReadiness: DecisionReadiness {
        if let id = selectedAutoEffortBackendID,
           autoEffortBackendOptions.contains(where: { $0.id == id }),
           let readiness = runtime.backendReadiness(id)
        { return readiness }
        if let raw = autoEffortConfiguration.selectedBackendRawValue {
            return .temporarilyUnavailable(generation: 0, reason: "Auto Effort service '\(raw)' is unavailable in this build.")
        }
        return .needsConfiguration(generation: 0, reason: "Configure an Auto Effort service.")
    }

    var readiness: DecisionReadiness {
        if let selectedBackendID, let readiness = runtime.backendReadiness(selectedBackendID) {
            return readiness
        }
        if let raw = configuration.selectedBackendRawValue, !raw.isEmpty {
            return .temporarilyUnavailable(
                generation: 0,
                reason: "Router backend '\(raw)' is not available in this build."
            )
        }
        return .needsConfiguration(generation: 0, reason: "Choose a routing backend.")
    }

    var isPerformingBackendOperation: Bool {
        activeCredentialOperation != nil
    }

    var canEnable: Bool {
        readiness.isReady && policyCanBuildCandidates
    }

    var autoEffortEnabled: Bool {
        autoEffortConfiguration.enabled
    }

    var canEnableAutoEffort: Bool {
        autoEffortReadiness.isReady
    }

    var availableProviders: Set<AgentProviderKind> {
        Set(targetPreviews.map(\.provider))
    }

    var distinctTargetCount: Int {
        Set(targetPreviews.map(\.target)).count
    }

    var modelTagPreviews: [TargetPreview] {
        targetPreviews
    }

    func serviceState(for backendID: DecisionServiceID) -> ServiceState? {
        Self.serviceState(
            for: backendID,
            in: serviceRows,
            readinessForID: runtime.backendReadiness,
            credentialStatesByID: credentialStatesByID
        )
    }

    static func serviceState(
        for backendID: DecisionServiceID,
        in serviceRows: [ServiceRow],
        readinessForID: (DecisionServiceID) -> DecisionReadiness?,
        credentialStatesByID: [DecisionServiceID: ServiceState]
    ) -> ServiceState? {
        guard let row = serviceRows.first(where: { $0.id == backendID }) else { return nil }
        return projectedServiceState(
            for: row,
            readiness: readinessForID(backendID),
            credentialState: credentialStatesByID[backendID]
        )
    }

    func backendOperationFeedback(for backendID: DecisionServiceID) -> BackendOperationFeedback {
        credentialStatesByID[backendID]?.feedback ?? .idle
    }

    func selectBackend(_ id: DecisionServiceID) {
        guard settingsStore.modelRouterConfiguration().selectedBackendID != id else { return }
        settingsStore.setModelRouterBackend(id)
        synchronizeConfiguration()
    }

    @discardableResult
    func setCustomInstructions(_ instructions: String) -> Bool {
        guard settingsStore.setModelRouterCustomInstructions(instructions) else { return false }
        synchronizeConfiguration()
        return true
    }

    func setEnabled(_ enabled: Bool) {
        synchronizeConfiguration()
        guard !enabled || canEnable else { return }
        settingsStore.setModelRouterEnabled(enabled)
        synchronizeConfiguration()
    }

    var claudeUsageConnected: Bool {
        let grant = settingsStore.claudeCLIUsageGrant()
        return grant?.isReady == true && grant?.applies(toProfileID: ClaudeUsageCredentialProfile.current().id) == true
    }

    var claudeBackgroundRefreshEnabled: Bool {
        claudeUsageConnected && settingsStore.scalarPreferences.agentMode?.claudeBalancingRefreshGrant?.applies(toProfileID: ClaudeUsageCredentialProfile.current().id) == true
    }

    var usageBalancingStatus: String {
        if !configuration.usageBalancing.enabled { return "Shift new tasks between Claude and Codex. No decision-service key required." }
        if !claudeUsageConnected, !settingsStore.codexUsageQuotaEnabled() { return "Connect plan usage in Models & Providers to use fresh readings." }
        return "Works independently, or alongside Model Router. Stale or missing usage keeps the starting choice."
    }

    func setUsageBalancingEnabled(_ enabled: Bool) {
        settingsStore.setUsageBalancingEnabled(enabled)
        synchronizeConfiguration()
    }

    func setUsageBalancingPreset(_ preset: AgentUsageBalancingPreset) {
        settingsStore.setUsageBalancingPreset(preset)
        synchronizeConfiguration()
    }

    func setAllowPaidFastRouting(_ enabled: Bool) {
        settingsStore.setAllowPaidFastRouting(enabled)
        synchronizeConfiguration()
    }

    /// This setter is only reachable from the explicit UI disclosure, never MCP settings.
    func setClaudeBackgroundRefreshEnabled(_ enabled: Bool) {
        guard !enabled || claudeUsageConnected else { return }
        settingsStore.setClaudeBalancingRefreshGrant(enabled ? ClaudeCLIUsageGrant(credentialProfileID: ClaudeUsageCredentialProfile.current().id, grantedAt: Date()) : nil)
        synchronizeConfiguration()
    }

    func setAutoEffortEnabled(_ enabled: Bool) {
        guard !enabled || canEnableAutoEffort else { return }
        settingsStore.setAutoEffortEnabled(enabled)
        synchronizeConfiguration()
    }

    func selectAutoEffortBackend(_ id: DecisionServiceID) {
        guard autoEffortConfiguration.selectedBackendRawValue != id.rawValue else { return }
        settingsStore.setAutoEffortBackend(id)
        synchronizeConfiguration()
    }

    @discardableResult
    func performBackendAction(
        _ action: DecisionServiceSettingsAction,
        backendID: DecisionServiceID
    ) async -> Bool {
        guard activeCredentialOperation == nil else { return false }

        let capturedConfiguration = settingsStore.modelRouterConfiguration()
        let token = UUID()
        let operation = ActiveCredentialOperation(
            token: token,
            backendID: backendID,
            capturedSelectedBackendID: capturedConfiguration.selectedBackendID,
            capturedRouterRevision: capturedConfiguration.revision,
            actionKind: action.kind
        )
        activeCredentialOperation = operation
        updateServiceState(backendID) { state in
            state.operationToken = token
            state.feedback = .running(Self.progressMessage(for: action.kind))
        }
        defer {
            if activeCredentialOperation?.token == token {
                objectWillChange.send()
                activeCredentialOperation = nil
                updateServiceState(backendID) { state in
                    guard state.operationToken == token else { return }
                    state.operationToken = nil
                    if case .running = state.feedback {
                        state.feedback = .idle
                    }
                }
            }
        }

        guard ownsConfiguration(operation), !Task.isCancelled else { return false }
        guard let registration = await runtime.registry.registration(for: backendID),
              let settings = registration.configuration,
              settings.presentation.supportedCredentialActions.contains(action.kind),
              ownsConfiguration(operation),
              !Task.isCancelled
        else { return false }
        let result = await settings.controller.perform(action)
        guard ownsConfiguration(operation) else { return false }

        let succeeded: Bool
        if case .succeeded = result {
            succeeded = true
            if case .removeStoredSecret = action,
               backendID == operation.capturedSelectedBackendID,
               backendID == settingsStore.modelRouterConfiguration().selectedBackendID
            {
                settingsStore.setModelRouterEnabled(false)
                synchronizeConfiguration(preservingOperationToken: token)
            }
        } else {
            succeeded = false
        }

        updateServiceState(backendID) { state in
            guard state.operationToken == token else { return }
            state.feedback = switch result {
            case let .succeeded(message): .succeeded(message)
            case let .missingSecret(message), let .superseded(message), let .failed(message): .failed(message)
            }
        }
        // No await after the ownership check and optional durable disable: a newer
        // configuration cannot interleave with feedback publication or the return value.
        scheduleRefresh()
        return succeeded
    }

    func refresh() async {
        refreshRequested = true
        if let refreshTask {
            await refreshTask.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await runRefreshLoop()
        }
        refreshTask = task
        await task.value
    }

    private func runRefreshLoop() async {
        while refreshRequested {
            refreshRequested = false
            await performRefresh()
        }
        refreshTask = nil
    }

    private func performRefresh() async {
        defer { refreshCompletionObserver?(configuration) }
        synchronizeConfiguration()
        var capturedConfiguration = configuration
        await runtime.waitForReadinessObservation()
        let registrations = await runtime.registry.registrations()
        guard settingsStore.modelRouterConfiguration() == capturedConfiguration else { return }
        if configuration.selectedBackendRawValue == nil, let defaultID = runtime.defaultBackendID,
           registrations.contains(where: { $0.id == defaultID })
        {
            settingsStore.materializeModelRouterDefaultIfAbsent(defaultID)
            synchronizeConfiguration()
            capturedConfiguration = configuration
        } else if runtime.defaultBackendID == nil, configuration.selectedBackendRawValue == nil,
                  registrations.count == 1, let onlyBackend = registrations.first
        {
            settingsStore.setModelRouterBackend(onlyBackend.id)
            synchronizeConfiguration()
            capturedConfiguration = configuration
        }

        let orderedRegistrations = registrations.sorted {
            if $0.displayOrder != $1.displayOrder {
                return $0.displayOrder < $1.displayOrder
            }
            return $0.id < $1.id
        }
        let rows = orderedRegistrations.map {
            ServiceRow(
                id: $0.id,
                displayName: $0.displayName,
                isModelRouterEligible: ModelRouterDecisionPolicy.supports($0.capabilities),
                isAutoEffortEligible: AutoEffortDecisionPolicy.supports($0.capabilities),
                displayOrder: $0.displayOrder,
                presentation: $0.configuration?.presentation
            )
        }
        if serviceRows != rows {
            serviceRows = rows
        }
        let registeredIDs = Set(orderedRegistrations.map(\.id))
        let filteredCredentialStates = credentialStatesByID.filter { registeredIDs.contains($0.key) }
        if credentialStatesByID != filteredCredentialStates {
            credentialStatesByID = filteredCredentialStates
        }
        guard settingsStore.modelRouterConfiguration() == capturedConfiguration else { return }
        rebuildTargetPreviews()
    }

    private func synchronizeConfiguration(preservingOperationToken: UUID? = nil) {
        let current = settingsStore.modelRouterConfiguration()
        let configurationChanged = current.revision != configuration.revision
            || current.selectedBackendID != configuration.selectedBackendID
        if configurationChanged, let operation = activeCredentialOperation,
           operation.token != preservingOperationToken
        {
            updateServiceState(operation.backendID) { state in
                guard state.operationToken == operation.token else { return }
                state.operationToken = nil
                state.feedback = .idle
            }
        }
        if configuration != current {
            configuration = current
        }
        let currentAutoEffortConfiguration = settingsStore.autoEffortConfiguration()
        if autoEffortConfiguration != currentAutoEffortConfiguration {
            autoEffortConfiguration = currentAutoEffortConfiguration
        }
        rebuildTargetPreviews()
    }

    private func ownsConfiguration(_ operation: ActiveCredentialOperation) -> Bool {
        let current = settingsStore.modelRouterConfiguration()
        return activeCredentialOperation?.token == operation.token
            && current.selectedBackendID == operation.capturedSelectedBackendID
            && current.revision == operation.capturedRouterRevision
    }

    private func updateServiceState(
        _ backendID: DecisionServiceID,
        update: (inout ServiceState) -> Void
    ) {
        var state = credentialStatesByID[backendID] ?? ServiceState(
            readiness: .needsConfiguration(generation: 0, reason: "Checking the routing service…"),
            operationToken: nil,
            feedback: .idle
        )
        let previous = state
        update(&state)
        guard state != previous || credentialStatesByID[backendID] == nil else { return }
        credentialStatesByID[backendID] = state
    }

    private static func projectedServiceState(
        for row: ServiceRow,
        readiness: DecisionReadiness?,
        credentialState: ServiceState?
    ) -> ServiceState {
        ServiceState(
            readiness: readiness ?? .needsConfiguration(
                generation: 0, reason: "Checking \(row.displayName)…"
            ),
            operationToken: credentialState?.operationToken,
            feedback: credentialState?.feedback ?? .idle
        )
    }

    private static func progressMessage(
        for actionKind: DecisionServiceSettingsCredentialActionKind
    ) -> String {
        switch actionKind {
        case .validateAndSaveSecret: "Verifying and saving the key…"
        case .revalidateStoredSecret: "Checking the saved key…"
        case .removeStoredSecret: "Removing the saved key…"
        }
    }

    private func settingsStoreDidChange() {
        let currentRouterConfiguration = settingsStore.modelRouterConfiguration()
        let currentAutoEffortConfiguration = settingsStore.autoEffortConfiguration()
        let changed = currentRouterConfiguration != lastObservedRouterConfiguration
            || currentAutoEffortConfiguration != lastObservedAutoEffortConfiguration
        lastObservedRouterConfiguration = currentRouterConfiguration
        lastObservedAutoEffortConfiguration = currentAutoEffortConfiguration
        if changed {
            scheduleRefresh()
        }
    }

    private func forwardReadinessChangeIfNeeded() {
        let current = runtime.decisionServiceReadinessByID
        guard current != lastForwardedReadinessByID else { return }
        lastForwardedReadinessByID = current
        objectWillChange.send()
    }

    @discardableResult
    private func scheduleRefresh() -> Task<Void, Never> {
        Task { [weak self] in
            await Task.yield()
            guard let self else { return }
            await refresh()
        }
    }

    func agentExecutionCatalogDidChange() -> Task<Void, Never> {
        targetPreviewAvailability = nil
        return scheduleRefresh()
    }

    private func rebuildTargetPreviews() {
        let availability = availabilityProvider()
        guard targetPreviewAvailability != availability else {
            updatePolicyCanBuildCandidates()
            return
        }
        let unavailablePreviews = unavailableTargetPreviewBuilder(availability)
        if unavailableTargetPreviews != unavailablePreviews {
            unavailableTargetPreviews = unavailablePreviews
        }
        let previews: [TargetPreview]
        do {
            previews = try targetPreviewBuilder(availability)
        } catch {
            targetPreviewAvailability = nil
            if !targetPreviews.isEmpty {
                targetPreviews = []
            }
            if policyCanBuildCandidates {
                policyCanBuildCandidates = false
            }
            return
        }

        targetPreviewAvailability = availability
        if targetPreviews != previews {
            targetPreviews = previews
        }
        updatePolicyCanBuildCandidates()
    }

    private func updatePolicyCanBuildCandidates() {
        let canBuildCandidates = !targetPreviews.isEmpty
        if policyCanBuildCandidates != canBuildCandidates {
            policyCanBuildCandidates = canBuildCandidates
        }
    }

    private static func buildTargetPreviews(
        availability: AgentModelCatalog.AvailabilityContext
    ) throws -> [TargetPreview] {
        var optionsByProvider: [AgentProviderKind: [AgentModelOption]] = [:]
        let modelOptions: @MainActor (AgentProviderKind, AgentModelCatalog.AvailabilityContext) -> [AgentModelOption] = { provider, context in
            if let options = optionsByProvider[provider] {
                return options
            }
            let options = AgentModelCatalog.options(for: provider, availability: context)
            optionsByProvider[provider] = options
            return options
        }
        let builder = AgentTaskRoutingCandidateBuilder(modelOptions: modelOptions)
        let families = builder.modelFamilyAvailability(availability: availability)
        let providers = AgentTaskRoutingCandidateBuilder.availableProviders(
            availability: availability,
            modelOptions: modelOptions
        )
        let candidates = try builder.build(
            allowedProviders: providers,
            availability: availability
        )
        return candidates.compactMap { candidate in
            guard let provider = AgentProviderKind(rawValue: candidate.target.agentRaw) else { return nil }
            let familyDisplayName = families.first {
                $0.provider == provider && $0.model?.baseTarget == candidate.target
            }?.displayName
            return TargetPreview(
                utilityTier: candidate.utilityTier,
                provider: provider,
                displayName: AgentModelCatalog.displayName(
                    for: candidate.target.modelRaw,
                    agentKind: provider,
                    availability: availability
                ),
                familyDisplayName: familyDisplayName,
                target: candidate.target
            )
        }
    }

    private static func buildUnavailableTargetPreviews(
        availability: AgentModelCatalog.AvailabilityContext
    ) -> [UnavailableTargetPreview] {
        AgentTaskRoutingCandidateBuilder().modelFamilyAvailability(availability: availability).compactMap { family in
            guard let reason = family.unavailableReason else { return nil }
            return .init(
                id: family.id,
                displayName: family.displayName,
                provider: family.provider,
                reason: reason
            )
        }
    }

    static func effectiveRoles(
        _ configuration: AgentTaskRouterConfiguration
    ) -> Set<AgentModelCatalog.TaskLabelKind> {
        configuration.candidateRolesMaterialized
            ? Set(configuration.candidateRoles)
            : Set(AgentModelCatalog.TaskLabelKind.allCases)
    }

    static func effectiveProviders(
        _ configuration: AgentTaskRouterConfiguration,
        available: Set<AgentProviderKind>
    ) -> Set<AgentProviderKind> {
        configuration.allowedProvidersMaterialized ? configuration.allowedProviders : available
    }
}
