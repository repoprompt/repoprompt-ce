import Foundation
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

final class GrokBuildACPModelPollingServiceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AgentACPModelRegistry.shared.test_reset(providerID: .grokBuild)
    }

    override func tearDown() {
        AgentACPModelRegistry.shared.test_reset(providerID: .grokBuild)
        super.tearDown()
    }

    func testControllerDiscoveryReusesVerifiedSessionAcrossWorkspacesInNeutralDirectory() async throws {
        let agentModeProvider = try await ACPAgentProviderFactory.makeProvider(
            for: .grokBuild, modelString: nil, grokAPIKeyProvider: { nil }
        )
        let agentModeEnvironment = try XCTUnwrap(agentModeProvider as? GrokBuildACPAgentProvider)
            .test_config.backgroundFeatureEnvironment
        let contextBuilderEnvironment = try XCTUnwrap(
            AgentRuntimeProviderService.shared.makeProvider(for: .grokBuild) as? GrokBuildACPHeadlessAgentProvider
        ).test_config.backgroundFeatureEnvironment
        let managedEnvironment = [
            "GROK_MEMORY": "0", "GROK_SUBAGENTS": "0", "GROK_WORKFLOWS": "0", "GROK_AUTO_WAKE": "0"
        ]
        let neutralPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoPromptGrokBuildACPDiscovery", isDirectory: true)
            .standardizedFileURL.path
        let fixtureDirectory = try makeTestDirectory()
        let scriptURL = try AgentSessionLinkACPServerScript.write(to: fixtureDirectory)
        let fixtureProvider = AgentSessionLinkCapturingACPProvider(
            providerID: .grokBuild, commandPath: scriptURL.path, environment: ["ACP_LOAD": "1"]
        )
        let initialRequest = ACPRunRequest(
            agentKind: .grokBuild,
            modelString: nil,
            workspacePath: neutralPath,
            resumeSessionID: nil,
            attachments: [],
            taskLabelKind: nil
        )
        // Keep the first real controller observable after discovery shuts down its process.
        let firstController = try ACPAgentSessionController(
            provider: fixtureProvider, runRequest: initialRequest, allowsProviderProcessLaunchForTesting: true
        )
        let resumeIDs = LifecycleRecorder()
        let client = GrokBuildACPControllerModelDiscoveryClient(
            providerFactory: { config in
                XCTAssertFalse(config.includeRepoPromptMCPServer)
                XCTAssertNil(config.apiKey)
                for (usage, environment, expected) in [
                    ("Agent Mode", agentModeEnvironment, managedEnvironment),
                    ("model polling", config.backgroundFeatureEnvironment, managedEnvironment),
                    ("Context Builder", contextBuilderEnvironment, managedEnvironment)
                ] {
                    XCTAssertEqual(environment, expected, "Background-feature policy for \(usage)")
                }
                return fixtureProvider
            },
            controllerFactory: { provider, request in
                XCTAssertEqual(request.workspacePath, neutralPath)
                resumeIDs.record(request.resumeSessionID ?? "<new>")
                if resumeIDs.events.count == 1 {
                    return firstController
                }
                return try ACPAgentSessionController(
                    provider: provider, runRequest: request, allowsProviderProcessLaunchForTesting: true
                )
            }
        )
        let service = GrokBuildACPModelPollingService(client: client)
        do {
            _ = try await service.discoverOnce(workspacePath: "/unused/grok-project-a")
            let identity = await firstController.currentProviderSessionIdentity()
            XCTAssertEqual(identity.loadSessionIDConfidence, .verified)
            let verifiedID = try XCTUnwrap(identity.loadSessionID)
            XCTAssertFalse(verifiedID.isEmpty)
            XCTAssertEqual(resumeIDs.events, ["<new>"])

            _ = try await service.discoverOnce(workspacePath: "/unused/grok-project-b")
            XCTAssertEqual(resumeIDs.events, ["<new>", verifiedID])
        } catch {
            await service.shutdown()
            throw error
        }
        await service.shutdown()
    }

    private struct StubDiscoveryClient: GrokBuildACPModelDiscoveryClient {
        let models: ACPDiscoveredSessionModels?
        let failure: (any Error)?

        func discoverModels(workspacePath _: String?) async throws -> ACPDiscoveredSessionModels? {
            if let failure {
                throw failure
            }
            return models
        }
    }

    private func makeModels(_ raws: [String]) -> ACPDiscoveredSessionModels {
        ACPDiscoveredSessionModels(
            options: raws.map {
                AgentModelOption(
                    rawValue: $0,
                    displayName: $0,
                    description: nil,
                    isPlaceholderDefault: false,
                    isProviderDefault: false
                )
            },
            currentModelRaw: raws.first
        )
    }

    func testDiscoverOncePublishesLiveSnapshot() async throws {
        let service = GrokBuildACPModelPollingService(
            client: StubDiscoveryClient(models: makeModels(["grok-4.6", "grok-4.5"]), failure: nil)
        )
        let snapshot = try await service.discoverOnce(workspacePath: nil)
        // The registry canonicalizes ordering; membership is the contract.
        XCTAssertEqual(Set(snapshot?.models.options.map(\.rawValue) ?? []), ["grok-4.6", "grok-4.5"])
        XCTAssertEqual(snapshot?.isLiveDiscovery, true)
        await service.shutdown()
    }

    func testFailedRefreshRetainsLastGoodSnapshot() async throws {
        let service = GrokBuildACPModelPollingService(
            client: StubDiscoveryClient(models: makeModels(["grok-4.6"]), failure: nil)
        )
        _ = try await service.discoverOnce(workspacePath: nil)
        await service.shutdown()

        // A service whose client fails keeps reporting the previously published registry data
        // (warmed from the persisted store) instead of clearing it.
        let failing = GrokBuildACPModelPollingService(
            client: StubDiscoveryClient(models: nil, failure: AIProviderError.invalidConfiguration(detail: "boom"))
        )
        let refreshed = await failing.refreshNow(workspacePath: nil)
        XCTAssertFalse(refreshed)
        let latest = await failing.latestSnapshot()
        XCTAssertEqual(latest?.models.options.map(\.rawValue), ["grok-4.6"])
        XCTAssertEqual(latest?.isLiveDiscovery, false)
        await failing.shutdown()
    }

    func testEmptyDiscoveryDoesNotPersistFakeDefaultSnapshot() async throws {
        let service = GrokBuildACPModelPollingService(
            client: StubDiscoveryClient(models: ACPDiscoveredSessionModels(options: [], currentModelRaw: nil), failure: nil)
        )
        let snapshot = try await service.discoverOnce(workspacePath: nil)
        XCTAssertEqual(snapshot?.models.options.count ?? 0, 0)
        // Nothing may be written to the shared registry for an empty discovery.
        XCTAssertNil(AgentACPModelRegistry.shared.currentSnapshot(for: .grokBuild))
        await service.shutdown()
    }
}

final class GrokBuildAgentToolPreferencesTests: XCTestCase {
    func testManagedDefaultIsDefaultForFreshState() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "GrokBuildAgentToolPreferencesTests-\(UUID().uuidString)"))
        XCTAssertEqual(GrokBuildAgentToolPreferences.permissionLevel(defaults: defaults, secureStore: nil), .managedDefault)
    }

    func testFullAccessRoundTripsThroughCustomDefaults() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "GrokBuildAgentToolPreferencesTests-\(UUID().uuidString)"))
        GrokBuildAgentToolPreferences.setPermissionLevel(.fullAccess, defaults: defaults, secureStore: nil)
        XCTAssertEqual(GrokBuildAgentToolPreferences.permissionLevel(defaults: defaults, secureStore: nil), .fullAccess)
    }

    func testUnknownRawValueNormalizesToManagedDefault() {
        XCTAssertEqual(GrokBuildAgentToolPreferences.PermissionLevel.from(rawValue: "bogus"), .managedDefault)
        XCTAssertEqual(GrokBuildAgentToolPreferences.PermissionLevel.from(rawValue: nil), .managedDefault)
        XCTAssertEqual(GrokBuildAgentToolPreferences.PermissionLevel.from(rawValue: "  fullAccess "), .fullAccess)
    }

    func testSecureDocumentRoundTrip() {
        var document = SecureGrokBuildPermissionDocument()
        document.permissionLevelRaw = GrokBuildAgentToolPreferences.PermissionLevel.fullAccess.rawValue
        XCTAssertEqual(document.permissionLevel(), .fullAccess)
        let failClosed = SecureGrokBuildPermissionDocument.failClosedDocument()
        XCTAssertEqual(failClosed.permissionLevel(), .managedDefault)
    }
}

final class GrokBuildPermissionDisclosureTests: XCTestCase {
    func testDisclosureFollowsEffectivePermissionLevel() throws {
        let suiteName = "GrokBuildPermissionDisclosureTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let defaultDetail = GrokBuildAgentToolPreferences.PermissionLevel.managedDefault.detailText
        for fragment in [
            "defaultMode",
            "can allow",
            "without asking RepoPrompt",
            "many requests (`bypassPermissions`)",
            "edit tools such as `write` (`acceptEdits`)"
        ] {
            XCTAssertTrue(defaultDetail.contains(fragment), "Default detail must disclose \(fragment)")
        }

        let cases: [(
            name: String,
            profile: AgentProviderPermissionProfile,
            storedLevel: GrokBuildAgentToolPreferences.PermissionLevel,
            expectsDefault: Bool
        )] = [
            ("Direct Default", .userConfigured, .managedDefault, true),
            ("Safe Managed with stored Full Access", .mcpSafeDefaults, .fullAccess, true),
            ("Direct Full Access", .userConfigured, .fullAccess, false)
        ]
        let builder = AgentPermissionCapabilitySummaryBuilder(defaults: defaults)
        let availability = AgentModelCatalog.AvailabilityContext(grokBuildAvailable: true)
        for testCase in cases {
            GrokBuildAgentToolPreferences.setPermissionLevel(testCase.storedLevel, defaults: defaults)
            let summary = builder.summary(for: .grokBuild, profile: testCase.profile, availability: availability)
            if testCase.expectsDefault {
                XCTAssertEqual(
                    summary.fileMutation,
                    "Always-approve launch: off; Grok's rules can still allow requests",
                    testCase.name
                )
                XCTAssertTrue(summary.warnings.isEmpty, testCase.name)
            } else {
                XCTAssertEqual(summary.fileMutation, "Always-approve launch: on", testCase.name)
                XCTAssertEqual(
                    summary.warnings,
                    ["Grok Build launches with `--always-approve` — its tools run without per-request confirmation."],
                    testCase.name
                )
            }
        }
    }
}
