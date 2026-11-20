import Foundation
import RepoPromptACPProviders
import RepoPromptAIContracts
import XCTest

final class OpenCodeACPModelPollingOwnerTests: XCTestCase {
    private struct RefreshClient: OpenCodeACPModelDiscoveryClient {
        let result: ACPDiscoveredSessionModels?
        let failure: (any Error)?

        func discoverModels(workspacePath _: String?, modelRaw _: String?) async throws -> OpenCodeACPModelDiscoveryResult? {
            if let failure { throw failure }
            guard let result else { return nil }
            return OpenCodeACPModelDiscoveryResult(catalog: result, parameterState: nil)
        }
    }

    func testInjectedRegistryWarmsAndPublishesNormalizedCatalog() async {
        final class RegistryBox {
            var snapshot: ACPDiscoveredSessionModels?
            var warmCount = 0
            var updateCount = 0
        }
        let box = RegistryBox()
        let input = ACPDiscoveredSessionModels(
            options: [.init(rawValue: "input", displayName: "Input", description: nil, isPlaceholderDefault: false, isProviderDefault: false)],
            currentModelRaw: "input"
        )
        let normalized = ACPDiscoveredSessionModels(
            options: [.init(rawValue: "normalized", displayName: "Normalized", description: nil, isPlaceholderDefault: false, isProviderDefault: false)],
            currentModelRaw: "normalized"
        )
        let registry = OpenCodeACPModelPollingService.Registry(
            update: { _ in box.updateCount += 1
                box.snapshot = normalized
                return true
            },
            snapshot: { box.snapshot },
            snapshotAfterWarm: { box.warmCount += 1
                return box.snapshot
            }
        )
        let service = OpenCodeACPModelPollingService(client: RefreshClient(result: input, failure: nil), registry: registry)
        let before = await service.latestSnapshot()
        XCTAssertNil(before)
        XCTAssertEqual(box.warmCount, 1)
        let result = await service.refreshNow(workspacePath: nil)
        XCTAssertEqual(result, .updated)
        let snapshot = await service.latestSnapshot()
        XCTAssertEqual(snapshot?.models, normalized)
        XCTAssertEqual(snapshot?.isLiveDiscovery, true)
        XCTAssertEqual(box.updateCount, 1)
        await service.shutdown()
    }
}
