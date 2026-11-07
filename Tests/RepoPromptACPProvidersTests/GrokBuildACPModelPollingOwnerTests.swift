import Foundation
@testable import RepoPromptACPProviders
import RepoPromptAIContracts
import XCTest

final class GrokBuildACPModelPollingOwnerTests: XCTestCase {
    private lazy var registry = AgentACPModelRegistry(dependencies: .init(
        loadAll: { [:] }, load: { _ in nil }, save: { _, _ in }, remove: { _ in }, invalidate: { _ in }
    ))

    private func makePollingService(client: any GrokBuildACPModelDiscoveryClient) -> GrokBuildACPModelPollingService {
        GrokBuildACPModelPollingService(client: client, registry: registry, logFailure: { _ in })
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
        let service = makePollingService(
            client: StubDiscoveryClient(models: makeModels(["grok-4.6", "grok-4.5"]), failure: nil)
        )
        let snapshot = try await service.discoverOnce(workspacePath: nil)
        // The registry canonicalizes ordering; membership is the contract.
        XCTAssertEqual(Set(snapshot?.models.options.map(\.rawValue) ?? []), ["grok-4.6", "grok-4.5"])
        XCTAssertEqual(snapshot?.isLiveDiscovery, true)
        await service.shutdown()
    }

    func testFailedRefreshRetainsLastGoodSnapshot() async throws {
        let service = makePollingService(
            client: StubDiscoveryClient(models: makeModels(["grok-4.6"]), failure: nil)
        )
        _ = try await service.discoverOnce(workspacePath: nil)
        await service.shutdown()

        // A service whose client fails keeps reporting previously published registry data
        // instead of clearing it.
        let failing = makePollingService(
            client: StubDiscoveryClient(models: nil, failure: NSError(domain: "GrokPollingOwnerTests", code: 1))
        )
        let refreshed = await failing.refreshNow(workspacePath: nil)
        XCTAssertEqual(refreshed, .failed)
        let latest = await failing.latestSnapshot()
        XCTAssertEqual(latest?.models.options.map(\.rawValue), ["grok-4.6"])
        XCTAssertEqual(latest?.isLiveDiscovery, false)
        await failing.shutdown()
    }

    func testRefreshOutcomesDistinguishUpdatedUnchangedAndNoModels() async {
        let service = makePollingService(
            client: StubDiscoveryClient(models: makeModels(["grok-4.6"]), failure: nil)
        )
        let first = await service.refreshNow(workspacePath: nil)
        let second = await service.refreshNow(workspacePath: nil)
        XCTAssertEqual(first, .updated)
        XCTAssertEqual(second, .unchanged)
        await service.shutdown()

        let empty = makePollingService(
            client: StubDiscoveryClient(
                models: ACPDiscoveredSessionModels(options: [], currentModelRaw: nil),
                failure: nil
            )
        )
        let emptyOutcome = await empty.refreshNow(workspacePath: nil)
        XCTAssertEqual(emptyOutcome, .noModelsAdvertised)
        await empty.shutdown()
    }

    func testEmptyDiscoveryDoesNotPersistFakeDefaultSnapshot() async throws {
        let service = makePollingService(
            client: StubDiscoveryClient(models: ACPDiscoveredSessionModels(options: [], currentModelRaw: nil), failure: nil)
        )
        let snapshot = try await service.discoverOnce(workspacePath: nil)
        XCTAssertEqual(snapshot?.models.options.count ?? 0, 0)
        // Nothing may be written to the shared registry for an empty discovery.
        XCTAssertNil(registry.currentSnapshot(for: .grokBuild))
        await service.shutdown()
    }
}
