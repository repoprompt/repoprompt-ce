import Foundation
@testable import RepoPromptACPProviders
import RepoPromptAIContracts
import XCTest

final class CursorACPModelPollingOwnerTests: XCTestCase {
    func testInjectedRegistryWarmsAndPublishesNormalizedSnapshot() async {
        final class RegistryBox {
            var snapshot: ACPDiscoveredSessionModels?
            var warmCount = 0
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
        let registry = CursorACPModelPollingService.Registry(
            update: { _ in box.snapshot = normalized
                return true
            },
            snapshot: { box.snapshot },
            snapshotAfterWarm: { box.warmCount += 1
                return box.snapshot
            }
        )
        let service = CursorACPModelPollingService(client: RetryingCursorDiscoveryClient(snapshot: input), registry: registry)
        let initial = await service.latestSnapshot()
        XCTAssertNil(initial)
        XCTAssertEqual(box.warmCount, 1)
        _ = await service.refreshCatalog(workspacePath: nil) // first attempt fails
        _ = await service.refreshCatalog(workspacePath: nil)
        let result = await service.latestSnapshot()
        XCTAssertEqual(result?.models, normalized)
        XCTAssertEqual(result?.isLiveDiscovery, true)
        await service.shutdown()
    }
}

private actor RetryingCursorDiscoveryClient: CursorACPModelDiscoveryClient {
    let snapshot: ACPDiscoveredSessionModels
    private var calls = 0

    init(snapshot: ACPDiscoveredSessionModels) {
        self.snapshot = snapshot
    }

    func discoverModels(workspacePath _: String?) async throws -> ACPDiscoveredSessionModels? {
        calls += 1
        if calls == 1 {
            throw NSError(domain: "CursorPollingOwnerTests", code: 1)
        }
        return snapshot
    }
}
