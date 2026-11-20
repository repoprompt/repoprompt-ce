import Foundation
@testable import RepoPromptACPProviders
import RepoPromptAIContracts
import XCTest

final class AgentACPModelRegistryInjectionTests: XCTestCase {
    private func snapshot(_ raw: String) -> ACPDiscoveredSessionModels {
        let option = AgentModelOption(
            rawValue: raw, displayName: raw, description: nil,
            isPlaceholderDefault: false, isProviderDefault: false
        )
        return ACPDiscoveredSessionModels(options: [option], currentModelRaw: raw)
    }

    func testInjectedStoreRoutingAndResetFences() {
        let store = ACPRegistryMemoryStore()
        let registry = AgentACPModelRegistry(dependencies: store.dependencies)
        let value = snapshot("model-one")
        store.seed(value, provider: .openCode)

        XCTAssertEqual(registry.resolvedSnapshotIncludingStandardStore(for: .openCode)?.currentModelRaw, "model-one")
        XCTAssertNil(registry.resolvedSnapshot(for: .openCode), "Fallback must not install or warm")
        XCTAssertEqual(store.counts.load, 1)
        XCTAssertTrue(registry.updateDiscoveredModels(value, for: .openCode))
        XCTAssertFalse(registry.updateDiscoveredModels(value, for: .openCode))
        XCTAssertEqual(store.counts.save, 1)
        XCTAssertEqual(store.invalidated, [.openCode])
        registry.test_clearMemoryPreservingStore(providerID: .openCode)
        XCTAssertEqual(store.counts.remove, 0)
        XCTAssertEqual(store.invalidated, [.openCode, .openCode, .openCode])
        XCTAssertEqual(registry.resolvedSnapshotIncludingStandardStore(for: .openCode)?.currentModelRaw, "model-one")
        registry.test_reset(providerID: .openCode)
        XCTAssertEqual(store.counts.remove, 1)
        XCTAssertEqual(store.invalidated, [.openCode, .openCode, .openCode, .openCode, .openCode])
        XCTAssertNil(registry.resolvedSnapshotIncludingStandardStore(for: .openCode))
    }

    @MainActor
    func testSharedWarmKeepsLiveSnapshotAndInvalidatesOnlyOnce() async {
        let store = ACPRegistryMemoryStore()
        store.seed(snapshot("stored"), provider: .openCode)
        let registry = AgentACPModelRegistry(dependencies: store.dependencies)
        let firstGate = ACPWarmCompletionGate()
        let secondGate = ACPWarmCompletionGate()
        let firstParked = expectation(description: "first warm loaded")
        let secondParked = expectation(description: "second warm shared load")
        let first = Task {
            await registry.warmStandardStoreIfNeeded(beforeCompleting: {
                firstParked.fulfill()
                await firstGate.wait()
            })
        }
        await fulfillment(of: [firstParked], timeout: 5)
        let second = Task {
            await registry.warmStandardStoreIfNeeded(beforeCompleting: {
                secondParked.fulfill()
                await secondGate.wait()
            })
        }
        await fulfillment(of: [secondParked], timeout: 5)
        XCTAssertEqual(store.counts.loadAll, 1)
        XCTAssertTrue(registry.updateDiscoveredModels(snapshot("live"), for: .openCode))
        await firstGate.open()
        await first.value
        XCTAssertEqual(registry.resolvedSnapshot(for: .openCode)?.currentModelRaw, "live")
        let invalidations = store.invalidated.count
        await secondGate.open()
        await second.value
        XCTAssertEqual(store.invalidated.count, invalidations)
        XCTAssertEqual(store.counts.loadAll, 1)
    }

    func testInvalidatorCanReadAnotherRegistryWithoutSharedGuardState() {
        let firstStore = ACPRegistryMemoryStore()
        let otherStore = ACPRegistryMemoryStore()
        let other = AgentACPModelRegistry(dependencies: otherStore.dependencies)
        let firstDependencies = firstStore.dependencies
        var invalidated = false
        let first = AgentACPModelRegistry(dependencies: .init(
            loadAll: firstDependencies.loadAll,
            load: firstDependencies.load,
            save: firstDependencies.save,
            remove: firstDependencies.remove,
            invalidate: { _ in
                XCTAssertNil(other.resolvedSnapshot(for: .openCode))
                invalidated = true
            }
        ))
        XCTAssertTrue(first.updateDiscoveredModels(snapshot("first"), for: .openCode))
        XCTAssertTrue(invalidated)
        XCTAssertEqual(first.resolvedSnapshot(for: .openCode)?.currentModelRaw, "first")
    }

    @MainActor
    func testResetGenerationRejectsParkedWarmCompletion() async {
        let store = ACPRegistryMemoryStore()
        store.seed(snapshot("old"), provider: .openCode)
        let registry = AgentACPModelRegistry(dependencies: store.dependencies)
        let gate = ACPWarmCompletionGate()
        let parked = expectation(description: "warm loaded before reset")
        let warm = Task {
            await registry.warmStandardStoreIfNeeded(beforeCompleting: {
                parked.fulfill()
                await gate.wait()
            })
        }
        await fulfillment(of: [parked], timeout: 5)
        registry.test_reset(providerID: .openCode)
        XCTAssertEqual(store.invalidated, [.openCode, .openCode])
        await gate.open()
        await warm.value
        XCTAssertNil(registry.resolvedSnapshot(for: .openCode))
        XCTAssertEqual(store.invalidated, [.openCode, .openCode])
        XCTAssertEqual(store.counts.remove, 1)
    }
}

private final class ACPRegistryMemoryStore: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ACPProviderID: ACPDiscoveredSessionModels] = [:]
    private var recordedInvalidations: [AgentProviderKind] = []
    private var operations = (loadAll: 0, load: 0, save: 0, remove: 0)

    var counts: (loadAll: Int, load: Int, save: Int, remove: Int) {
        lock.withLock { operations }
    }

    var invalidated: [AgentProviderKind] {
        lock.withLock { recordedInvalidations }
    }

    func seed(_ snapshot: ACPDiscoveredSessionModels, provider: ACPProviderID) {
        lock.withLock { values[provider] = snapshot }
    }

    var dependencies: AgentACPModelRegistry.Dependencies {
        .init(
            loadAll: { [self] in lock.withLock { operations.loadAll += 1
                return values
            } },
            load: { [self] provider in lock.withLock { operations.load += 1
                return values[provider]
            } },
            save: { [self] snapshot, provider in lock.withLock { operations.save += 1
                values[provider] = snapshot
            } },
            remove: { [self] provider in lock.withLock { operations.remove += 1
                values.removeValue(forKey: provider)
            } },
            invalidate: { [self] agent in lock.withLock { recordedInvalidations.append(agent) } }
        )
    }
}

private actor ACPWarmCompletionGate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}
