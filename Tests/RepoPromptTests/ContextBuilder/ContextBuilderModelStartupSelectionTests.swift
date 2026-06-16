import Foundation
import XCTest
@_spi(TestSupport) @testable import RepoPrompt

@MainActor
final class ContextBuilderModelStartupSelectionTests: XCTestCase {
    func testValidPersistedSelectionSurvivesStoreReloadAndStartupResolution() throws {
        let fixture = try makeStoreFixture()
        fixture.store.setGlobalContextBuilderAgentSelection(
            agentRaw: AgentProviderKind.codexExec.rawValue,
            modelRaw: AgentModel.gpt55CodexLow.rawValue,
            markUserDefined: true
        )

        let reloadedStore = GlobalSettingsStore(defaults: fixture.defaults, fileStore: fixture.fileStore)
        let persisted = reloadedStore.persistedGlobalContextBuilderAgentSelection()
        let resolved = try XCTUnwrap(AutoRecommendationEngine.resolveContextBuilderSelection(
            persistedAgentRaw: persisted.agentRaw,
            persistedModelRaw: persisted.modelRaw,
            availability: .init(
                claudeCodeAvailable: false,
                codexAvailable: true,
                openCodeAvailable: false,
                cursorAvailable: false
            )
        ))

        XCTAssertEqual(resolved.agent, .codexExec)
        XCTAssertEqual(resolved.modelRaw, AgentModel.gpt55CodexLow.rawValue)
    }

    func testUnavailablePersistedSelectionFallsBackToRecommendedAvailableProvider() throws {
        let resolved = try XCTUnwrap(AutoRecommendationEngine.resolveContextBuilderSelection(
            persistedAgentRaw: AgentProviderKind.claudeCode.rawValue,
            persistedModelRaw: AgentModel.claudeOpus.rawValue,
            availability: .init(
                claudeCodeAvailable: false,
                codexAvailable: true,
                openCodeAvailable: true,
                cursorAvailable: true
            )
        ))

        XCTAssertEqual(resolved.agent, .codexExec)
        XCTAssertEqual(resolved.modelRaw, AgentModel.gpt55CodexLow.rawValue)
    }

    func testUnconfiguredClaudeCodeCannotBecomeEffectiveStartupSelection() throws {
        let resolved = try XCTUnwrap(AutoRecommendationEngine.resolveContextBuilderSelection(
            persistedAgentRaw: nil,
            persistedModelRaw: nil,
            availability: .init(
                claudeCodeAvailable: false,
                codexAvailable: true,
                openCodeAvailable: false,
                cursorAvailable: false
            )
        ))

        XCTAssertNotEqual(resolved.agent, .claudeCode)
        XCTAssertNotEqual(resolved.modelRaw, AgentModel.claudeOpus.rawValue)
        XCTAssertTrue(AgentModelCatalog.isValid(
            rawModel: resolved.modelRaw,
            for: resolved.agent,
            availability: .init(
                claudeCodeAvailable: false,
                codexAvailable: true,
                openCodeAvailable: false,
                cursorAvailable: false
            )
        ))
    }

    func testFallbackUsesWizardRecommendationProviderFilter() throws {
        let resolved = try XCTUnwrap(AutoRecommendationEngine.resolveContextBuilderSelection(
            persistedAgentRaw: AgentProviderKind.openCode.rawValue,
            persistedModelRaw: "removed/model",
            availability: .init(
                claudeCodeAvailable: true,
                codexAvailable: true,
                openCodeAvailable: false,
                cursorAvailable: false
            ),
            enabledRecommendationProviders: [.claudeCode]
        ))

        XCTAssertEqual(resolved.agent, .claudeCode)
        XCTAssertEqual(resolved.modelRaw, AgentModel.claudeSonnet.rawValue)
    }

    func testFilteredRecommendationProvidersDoNotReappearThroughGenericFallback() throws {
        let resolved = try XCTUnwrap(AutoRecommendationEngine.resolveContextBuilderSelection(
            persistedAgentRaw: nil,
            persistedModelRaw: nil,
            availability: .init(
                claudeCodeAvailable: false,
                codexAvailable: true,
                openCodeAvailable: true,
                cursorAvailable: false
            ),
            enabledRecommendationProviders: [.claudeCode]
        ))

        XCTAssertEqual(resolved.agent, .openCode)
        XCTAssertEqual(resolved.modelRaw, AgentModel.defaultModel.rawValue)
    }

    func testStaticOpenCodeDefaultSurvivesAfterACPDiscovery() throws {
        let providerID = ACPProviderID.openCode
        AgentACPModelRegistry.shared.test_reset(providerID: providerID)
        addTeardownBlock {
            AgentACPModelRegistry.shared.test_reset(providerID: providerID)
        }

        let preferredModelRaw = "openai/gpt-dynamic"
        XCTAssertTrue(AgentACPModelRegistry.shared.updateDiscoveredModels(
            ACPDiscoveredSessionModels(
                options: [AgentModelOption(
                    rawValue: preferredModelRaw,
                    displayName: "GPT Dynamic",
                    description: nil,
                    isPlaceholderDefault: false,
                    isProviderDefault: true
                )],
                currentModelRaw: preferredModelRaw
            ),
            for: providerID
        ))

        let resolved = try XCTUnwrap(AutoRecommendationEngine.resolveContextBuilderSelection(
            persistedAgentRaw: AgentProviderKind.openCode.rawValue,
            persistedModelRaw: AgentModel.defaultModel.rawValue,
            availability: .init(
                claudeCodeAvailable: false,
                codexAvailable: true,
                openCodeAvailable: true,
                cursorAvailable: false
            )
        ))

        XCTAssertEqual(resolved.agent, .openCode)
        XCTAssertEqual(resolved.modelRaw, preferredModelRaw)
    }

    func testDynamicPersistedSelectionSurvivesAfterACPDiscovery() throws {
        let providerID = ACPProviderID.openCode
        AgentACPModelRegistry.shared.test_reset(providerID: providerID)
        addTeardownBlock {
            AgentACPModelRegistry.shared.test_reset(providerID: providerID)
        }

        let dynamicModelRaw = "openai/gpt-dynamic"
        XCTAssertTrue(AgentACPModelRegistry.shared.updateDiscoveredModels(
            ACPDiscoveredSessionModels(
                options: [AgentModelOption(
                    rawValue: dynamicModelRaw,
                    displayName: "GPT Dynamic",
                    description: nil,
                    isPlaceholderDefault: false,
                    isProviderDefault: true
                )],
                currentModelRaw: dynamicModelRaw
            ),
            for: providerID
        ))

        let resolved = try XCTUnwrap(AutoRecommendationEngine.resolveContextBuilderSelection(
            persistedAgentRaw: AgentProviderKind.openCode.rawValue,
            persistedModelRaw: dynamicModelRaw,
            availability: .init(
                claudeCodeAvailable: false,
                codexAvailable: true,
                openCodeAvailable: true,
                cursorAvailable: false
            )
        ))

        XCTAssertEqual(resolved.agent, .openCode)
        XCTAssertEqual(resolved.modelRaw, dynamicModelRaw)
    }

    func testPersistedDynamicSelectionSurvivesStandardCatalogWarmup() async throws {
        let providerID = ACPProviderID.openCode
        AgentACPModelRegistry.shared.test_reset(providerID: providerID)
        addTeardownBlock {
            AgentACPModelRegistry.shared.test_reset(providerID: providerID)
        }

        let dynamicModelRaw = "openai/gpt-persisted"
        XCTAssertTrue(AgentACPModelRegistry.shared.updateDiscoveredModels(
            ACPDiscoveredSessionModels(
                options: [AgentModelOption(
                    rawValue: dynamicModelRaw,
                    displayName: "GPT Persisted",
                    description: nil,
                    isPlaceholderDefault: false,
                    isProviderDefault: true
                )],
                currentModelRaw: dynamicModelRaw
            ),
            for: providerID
        ))
        AgentACPModelRegistry.shared.test_clearMemoryPreservingStore(providerID: providerID)
        XCTAssertNil(AgentACPModelRegistry.shared.test_snapshot(providerID: providerID))

        await AgentACPModelRegistry.shared.test_warmStandardStore()

        let resolved = try XCTUnwrap(AutoRecommendationEngine.resolveContextBuilderSelection(
            persistedAgentRaw: AgentProviderKind.openCode.rawValue,
            persistedModelRaw: dynamicModelRaw,
            availability: .init(
                claudeCodeAvailable: false,
                codexAvailable: false,
                openCodeAvailable: true,
                cursorAvailable: false
            )
        ))
        XCTAssertEqual(resolved.agent, .openCode)
        XCTAssertEqual(resolved.modelRaw, dynamicModelRaw)
    }

    func testOpenCodeStartupReadinessJoinsRunningPollAndEmitsLiveSnapshot() async throws {
        let providerID = ACPProviderID.openCode
        AgentACPModelRegistry.shared.test_reset(providerID: providerID)
        addTeardownBlock {
            AgentACPModelRegistry.shared.test_reset(providerID: providerID)
        }

        let dynamicModelRaw = "openai/gpt-live"
        let discovered = ACPDiscoveredSessionModels(
            options: [AgentModelOption(
                rawValue: dynamicModelRaw,
                displayName: "GPT Live",
                description: nil,
                isPlaceholderDefault: false,
                isProviderDefault: true
            )],
            currentModelRaw: dynamicModelRaw
        )
        let client = DelayedOpenCodeDiscoveryClient(result: discovered)
        let service = OpenCodeACPModelPollingService(client: client, intervalNanos: 60_000_000_000)
        let stream = await service.subscribe(workspacePath: nil)
        await client.waitUntilCalled()

        async let readiness = service.refreshNow(workspacePath: nil)
        var iterator = stream.makeAsyncIterator()
        let emittedSnapshot = await iterator.next()
        let snapshot = try XCTUnwrap(emittedSnapshot)
        let isReady = await readiness
        let discoveryCallCount = await client.callCount()

        XCTAssertTrue(isReady)
        XCTAssertTrue(snapshot.isLiveDiscovery)
        XCTAssertEqual(snapshot.models.currentModelRaw, dynamicModelRaw)
        XCTAssertEqual(discoveryCallCount, 1)
        await service.shutdown()
    }

    func testCursorStartupReadinessJoinsRunningPollWithoutDynamicMetadata() async {
        let client = DelayedCursorDiscoveryClient(result: nil)
        let service = CursorACPModelPollingService(client: client, intervalNanos: 60_000_000_000)
        let stream = await service.subscribe(workspacePath: nil)
        await client.waitUntilCalled()

        async let readiness = service.refreshNow(workspacePath: nil)
        var iterator = stream.makeAsyncIterator()
        var liveSnapshot: CursorACPModelPollingService.Snapshot?
        while liveSnapshot == nil, let snapshot = await iterator.next() {
            if snapshot.isLiveDiscovery {
                liveSnapshot = snapshot
            }
        }
        let isReady = await readiness
        let discoveryCallCount = await client.callCount()

        XCTAssertTrue(isReady)
        XCTAssertEqual(liveSnapshot?.isLiveDiscovery, true)
        XCTAssertEqual(discoveryCallCount, 1)
        await service.shutdown()
    }

    func testTransientFallbackResolutionDoesNotMutatePersistedSelection() throws {
        let fixture = try makeStoreFixture()
        fixture.store.setGlobalContextBuilderAgentSelection(
            agentRaw: AgentProviderKind.openCode.rawValue,
            modelRaw: "openai/gpt-dynamic",
            markUserDefined: true
        )
        let before = fixture.store.persistedGlobalContextBuilderAgentSelection()

        let fallback = try XCTUnwrap(AutoRecommendationEngine.resolveContextBuilderSelection(
            persistedAgentRaw: before.agentRaw,
            persistedModelRaw: before.modelRaw,
            availability: .init(
                claudeCodeAvailable: false,
                codexAvailable: true,
                openCodeAvailable: false,
                cursorAvailable: false
            )
        ))

        XCTAssertEqual(fallback.agent, .codexExec)
        XCTAssertEqual(fixture.store.persistedGlobalContextBuilderAgentSelection().agentRaw, before.agentRaw)
        XCTAssertEqual(fixture.store.persistedGlobalContextBuilderAgentSelection().modelRaw, before.modelRaw)
    }

    func testCachedCLIFlagIsNotReadyUntilCurrentProcessVerification() {
        let keys = ["ClaudeCodeConnected", "CodexCLIConnected", "OpenCodeCLIConnected", "CursorCLIConnected"]
        let previous = Dictionary(uniqueKeysWithValues: keys.map { ($0, UserDefaults.standard.object(forKey: $0)) })
        defer {
            for (key, value) in previous {
                if let value {
                    UserDefaults.standard.set(value, forKey: key)
                } else {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
        }

        UserDefaults.standard.set(true, forKey: "ClaudeCodeConnected")
        UserDefaults.standard.set(false, forKey: "CodexCLIConnected")
        UserDefaults.standard.set(false, forKey: "OpenCodeCLIConnected")
        UserDefaults.standard.set(false, forKey: "CursorCLIConnected")

        let keyManager = KeyManager(secureService: SecureKeysService(secureStorage: TestSecureStorageBackend()))
        let viewModel = APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keyManager),
            keyManager: keyManager,
            loadStoredDataOnInit: false
        )

        XCTAssertEqual(viewModel.recommendationProviderStatusSnapshot.claudeCodeCLI, .configured)
        XCTAssertFalse(viewModel.contextBuilderRestorationAvailabilityContext.claudeCodeAvailable)

        viewModel.test_completeContextBuilderProviderValidation(verifiedProviders: [])
        XCTAssertEqual(viewModel.recommendationProviderStatusSnapshot.claudeCodeCLI, .notConfigured)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "ClaudeCodeConnected"))

        viewModel.test_completeContextBuilderProviderValidation(verifiedProviders: [.claudeCode])
        XCTAssertEqual(viewModel.recommendationProviderStatusSnapshot.claudeCodeCLI, .ready)
        XCTAssertTrue(viewModel.contextBuilderRestorationAvailabilityContext.claudeCodeAvailable)
    }

    private func makeStoreFixture() throws -> (
        store: GlobalSettingsStore,
        defaults: UserDefaults,
        fileStore: GlobalSettingsFileStore
    ) {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContextBuilderModelStartupSelectionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: temp)
        }

        let suiteName = "ContextBuilderModelStartupSelectionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let fileStore = GlobalSettingsFileStore(
            fileURL: temp.appendingPathComponent("Settings/globalSettings.json")
        )
        return (GlobalSettingsStore(defaults: defaults, fileStore: fileStore), defaults, fileStore)
    }
}

private actor DelayedOpenCodeDiscoveryClient: OpenCodeACPModelDiscoveryClient {
    private let result: ACPDiscoveredSessionModels?
    private var calls = 0

    init(result: ACPDiscoveredSessionModels?) {
        self.result = result
    }

    func discoverModels(workspacePath _: String?) async throws -> ACPDiscoveredSessionModels? {
        calls += 1
        try await Task.sleep(nanoseconds: 100_000_000)
        return result
    }

    func waitUntilCalled() async {
        while calls == 0 {
            await Task.yield()
        }
    }

    func callCount() -> Int {
        calls
    }
}

private actor DelayedCursorDiscoveryClient: CursorACPModelDiscoveryClient {
    private let result: ACPDiscoveredSessionModels?
    private var calls = 0

    init(result: ACPDiscoveredSessionModels?) {
        self.result = result
    }

    func discoverModels(workspacePath _: String?) async throws -> ACPDiscoveredSessionModels? {
        calls += 1
        try await Task.sleep(nanoseconds: 100_000_000)
        return result
    }

    func waitUntilCalled() async {
        while calls == 0 {
            await Task.yield()
        }
    }

    func callCount() -> Int {
        calls
    }
}
