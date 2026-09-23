@testable import RepoPromptApp
import XCTest

@MainActor
final class RouterSettingsViewModelTests: XCTestCase {
    func testAutomaticFrontierIgnoresLegacyRoleAndProviderSelections() async throws {
        let fixture = try makeFixture()
        fixture.store.setModelRouterCandidateRoles([])
        fixture.store.setModelRouterAllowedProviders([])

        await fixture.viewModel.refresh()

        XCTAssertTrue(fixture.viewModel.policyCanBuildCandidates)
        XCTAssertGreaterThan(fixture.viewModel.distinctTargetCount, 1)
        XCTAssertTrue(fixture.viewModel.availableProviders.contains(.codexExec))
        XCTAssertTrue(fixture.viewModel.availableProviders.contains(.claudeCode))
    }

    func testSelectingBackendImmediatelyClearsOldReadinessAndPreservesConsent() async throws {
        let fixture = try makeFixture()
        await fixture.viewModel.refresh()
        XCTAssertTrue(fixture.viewModel.readiness.isReady)
        fixture.viewModel.setProviderLimit(.claudeCode, scope: .subagent)

        fixture.viewModel.selectBackend(.init(rawValue: "uninstalled"))
        XCTAssertEqual(fixture.viewModel.selectedBackendID?.rawValue, "uninstalled")
        XCTAssertFalse(fixture.viewModel.canEnable)
        XCTAssertNil(fixture.viewModel.backendSettingsPresentation)
        XCTAssertEqual(fixture.viewModel.providerLimit(for: .subagent), .claudeCode)
        await fixture.viewModel.refresh()
        guard case .temporarilyUnavailable = fixture.viewModel.readiness else {
            return XCTFail("Unknown backend must remain unavailable")
        }
    }

    func testReselectingSameBackendDoesNotInvalidateValidatedConfiguration() async throws {
        let fixture = try makeFixture()
        await fixture.viewModel.refresh()
        let configuration = fixture.viewModel.configuration
        try fixture.viewModel.selectBackend(XCTUnwrap(configuration.selectedBackendID))
        XCTAssertEqual(fixture.store.modelRouterConfiguration(), configuration)
        XCTAssertTrue(fixture.viewModel.readiness.isReady)
    }

    func testSavedKeyVerificationPublishesExplicitSuccessFeedback() async throws {
        let controller = SettingsTestController(result: .succeeded("Key verified. Jev is ready."))
        let fixture = try makeFixture(settingsController: controller)
        await fixture.viewModel.refresh()

        let succeeded = await fixture.viewModel.performBackendAction(.revalidateStoredSecret)

        XCTAssertTrue(succeeded)
        XCTAssertEqual(
            fixture.viewModel.backendOperationFeedback,
            .succeeded("Key verified. Jev is ready.")
        )
    }

    func testFailedBackendActionReturnsFalseAndPublishesFeedback() async throws {
        let controller = SettingsTestController(result: .failed("Authentication failed."))
        let fixture = try makeFixture(settingsController: controller)
        await fixture.viewModel.refresh()

        let succeeded = await fixture.viewModel.performBackendAction(.validateAndSaveSecret("candidate"))

        XCTAssertFalse(succeeded)
        XCTAssertEqual(fixture.viewModel.backendOperationFeedback, .failed("Authentication failed."))
    }

    func testUnavailableSettingsControllerClearsBackendOperationProgress() async throws {
        let fixture = try makeFixture()
        await fixture.viewModel.refresh()

        await fixture.viewModel.performBackendAction(.revalidateStoredSecret)

        XCTAssertFalse(fixture.viewModel.isPerformingBackendOperation)
        XCTAssertEqual(fixture.viewModel.backendOperationFeedback, .idle)
    }

    func testScopedProviderLimitsAndCustomGuidancePersistThroughViewModel() throws {
        let fixture = try makeFixture()
        fixture.store.setModelRouterAllowedProviders([.codexExec, .claudeCode])

        fixture.viewModel.setProviderLimit(.codexExec, scope: .primarySession)
        fixture.viewModel.setProviderLimit(.claudeCode, scope: .subagent)
        XCTAssertTrue(fixture.viewModel.setCustomInstructions("  Prefer Claude Opus for execution.  "))

        let configuration = fixture.store.modelRouterConfiguration()
        XCTAssertEqual(configuration.primaryProvider, .codexExec)
        XCTAssertEqual(configuration.subagentProvider, .claudeCode)
        XCTAssertEqual(configuration.customInstructions, "Prefer Claude Opus for execution.")
        XCTAssertEqual(fixture.viewModel.providerLimit(for: .primarySession), .codexExec)
        XCTAssertEqual(fixture.viewModel.providerLimit(for: .subagent), .claudeCode)
    }

    func testCompletedProviderValidationWithNoAuthenticatedTargetsDisablesRouter() async throws {
        let fixture = try makeFixture(
            availability: .none,
            verifiedProviders: []
        )
        fixture.store.enableModelRouterWithCurrentPolicy(
            backendID: .jev,
            roles: Set(AgentModelCatalog.TaskLabelKind.allCases),
            providers: [.claudeCode, .codexExec]
        )

        await fixture.viewModel.refresh()

        XCTAssertFalse(fixture.store.modelRouterConfiguration().enabled)
        XCTAssertFalse(fixture.viewModel.configuration.enabled)
        XCTAssertFalse(fixture.viewModel.canEnable)
    }

    func testUnavailableSubagentPreferenceDoesNotBlockAuthenticatedCodex() async throws {
        let fixture = try makeFixture(
            availability: AgentModelCatalog.AvailabilityContext(
                claudeCodeAvailable: false,
                codexAvailable: true,
                openCodeAvailable: false
            ),
            verifiedProviders: [.codexExec]
        )
        fixture.store.enableModelRouterWithCurrentPolicy(
            backendID: .jev,
            roles: Set(AgentModelCatalog.TaskLabelKind.allCases),
            providers: [.claudeCode, .codexExec]
        )
        fixture.viewModel.setProviderLimit(.codexExec, scope: .primarySession)
        fixture.viewModel.setProviderLimit(.claudeCode, scope: .subagent)

        await fixture.viewModel.refresh()

        XCTAssertTrue(fixture.store.modelRouterConfiguration().enabled)
        XCTAssertTrue(fixture.viewModel.canEnable)
        XCTAssertEqual(fixture.viewModel.availableProviders, [.codexExec])
        XCTAssertEqual(
            fixture.viewModel.unavailableProviderPreferences,
            [.init(scope: .subagent, provider: .claudeCode)]
        )
    }

    private struct Fixture {
        let store: GlobalSettingsStore
        let viewModel: RouterSettingsViewModel
        let workspace: WorkspaceManagerViewModel
    }

    private func makeFixture(
        policyUnavailable: Bool = false,
        settingsController: (any AgentTaskRouterBackendSettingsController)? = nil,
        availability: AgentModelCatalog.AvailabilityContext = .current,
        verifiedProviders: Set<AgentProviderKind>? = nil
    ) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RouterSettings-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let suite = "RouterSettings.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let store = GlobalSettingsStore(defaults: defaults, fileStore: GlobalSettingsFileStore(fileURL: root.appendingPathComponent("settings.json")))
        let backend = SettingsTestBackend(policyUnavailable: policyUnavailable)
        store.setModelRouterBackend(backend.id)
        let keyManager = KeyManager(secureService: SecureKeysService(secureStorage: TestSecureStorageBackend()))
        let api = APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keyManager), keyManager: keyManager, loadStoredDataOnInit: false
        )
        if let verifiedProviders {
            api.test_completeContextBuilderProviderValidation(verifiedProviders: verifiedProviders)
        }
        addTeardownBlock { @MainActor in api.prepareForWindowClose() }
        let files = WorkspaceFilesViewModel()
        let prompt = PromptViewModel(
            fileManager: files, apiSettingsViewModel: api, windowID: -1919,
            settingsManager: WindowSettingsManager(windowID: -1919)
        )
        let workspace = WorkspaceManagerViewModel(fileManager: files, promptViewModel: prompt, performInitialWorkspaceActivation: false)
        let credentials = JevRouterCredentialService(secureKeys: SecureKeysService(secureStorage: TestSecureStorageBackend()))
        let settings = settingsController.map {
            AgentTaskRouterBackendSettingsRegistration(
                presentation: .init(
                    title: "Jev by TypeSafe",
                    configurationDetail: "Test settings",
                    secretFieldLabel: "TypeSafe API key",
                    links: []
                ),
                controller: $0
            )
        } ?? (policyUnavailable ? JevTaskRouterBackend.settingsRegistration(controller: credentials) : nil)
        let runtime = try AgentTaskRouterRuntime(registrations: [
            .init(backend: backend, settings: settings)
        ])
        let viewModel = RouterSettingsViewModel(
            settingsStore: store,
            runtime: runtime,
            apiSettingsViewModel: api,
            workspaceManager: workspace,
            availabilityProvider: { availability }
        )
        return Fixture(store: store, viewModel: viewModel, workspace: workspace)
    }
}

private actor SettingsTestController: AgentTaskRouterBackendSettingsController {
    let result: AgentTaskRouterBackendSettingsActionResult

    init(result: AgentTaskRouterBackendSettingsActionResult) {
        self.result = result
    }

    func readinessSnapshot() -> AgentTaskRouterBackendReadiness {
        .ready(generation: 1, policyVersion: "test-v1")
    }

    func readinessUpdates() -> AsyncStream<AgentTaskRouterBackendReadiness> {
        AsyncStream { continuation in
            continuation.yield(.ready(generation: 1, policyVersion: "test-v1"))
            continuation.finish()
        }
    }

    func perform(_ action: AgentTaskRouterBackendSettingsAction) -> AgentTaskRouterBackendSettingsActionResult {
        result
    }

    func bootstrapStoredConfigurationIfNeeded() {}
    func cancelAndAdvanceGeneration() {}
}

private struct SettingsTestBackend: AgentTaskRouterBackend {
    let policyUnavailable: Bool
    let id = AgentTaskRouterBackendID.jev
    let displayName = "Jev"

    func readinessSnapshot() async -> AgentTaskRouterBackendReadiness {
        policyUnavailable
            ? .policyUnavailable(generation: 0, reason: "Test backend is unavailable.")
            : .ready(generation: 1, policyVersion: "test-v1")
    }

    func route(_ request: AgentTaskRoutingRequest) async -> AgentTaskRoutingBackendOutcome {
        .cancelled
    }
}
