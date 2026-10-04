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

    private enum DiscoveryProbeError: Error {
        case finished, unexpectedProviderCall
    }

    /// Stops before bootstrap: this test observes routing without launching a process.
    private struct DiscoveryProbeProvider: ACPAgentProvider {
        var providerID: ACPProviderID {
            .grokBuild
        }

        func support(for _: ACPRunRequest) async -> ACPSupportResult {
            .supported
        }

        func makeLaunchConfiguration(for _: ACPRunRequest) throws -> ACPLaunchConfiguration {
            throw DiscoveryProbeError.unexpectedProviderCall
        }

        func makeSessionConfiguration(
            for _: ACPRunRequest,
            mcpServer _: RepoPromptMCPServerConfiguration
        ) throws -> ACPSessionConfiguration {
            throw DiscoveryProbeError.unexpectedProviderCall
        }

        func buildPromptBlocks(for _: AgentMessage, request _: ACPRunRequest) throws -> [[String: Any]] {
            throw DiscoveryProbeError.unexpectedProviderCall
        }

        func normalizeSessionUpdate(_: [String: Any], sessionID _: String) -> [NormalizedAgentRuntimeEvent] {
            []
        }

        func normalizeError(_ error: Error) -> Error {
            error
        }
    }

    func testControllerDiscoveryUsesNeutralDirectoryAndIsolatedPurpose() async throws {
        let neutralPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoPromptGrokBuildACPDiscovery", isDirectory: true)
            .standardizedFileURL.path
        let client = GrokBuildACPControllerModelDiscoveryClient(
            providerFactory: { config in
                XCTAssertEqual(config.launchPurpose, .modelDiscovery)
                XCTAssertFalse(config.includeRepoPromptMCPServer)
                return DiscoveryProbeProvider()
            },
            controllerFactory: { _, request in
                XCTAssertEqual(request.workspacePath, neutralPath)
                XCTAssertNil(request.resumeSessionID)
                throw DiscoveryProbeError.finished
            }
        )
        for workspacePath in [nil, "/unused/grok-project-a", "/unused/grok-project-b"] as [String?] {
            do {
                _ = try await client.discoverModels(workspacePath: workspacePath)
                XCTFail("Expected the probe to stop before bootstrap")
            } catch DiscoveryProbeError.finished {
                // Request and provider config were checked at the real construction boundary.
            }
        }
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
