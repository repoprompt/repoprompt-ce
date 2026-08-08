import Foundation
@testable import RepoPromptDomainRuntime
import XCTest

final class DomainDirectSettingsStoreTests: XCTestCase {
    func testConcurrentColdStartBootstrapWaitsForPersistedSettingsLoad() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DomainDirectSettingsStoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = "concurrent-cold-start"
        let persistence = makePersistence(root: root, profile: profile)
        let writer = DomainDirectSettingsStore(
            persistence: persistence,
            profileIdentifier: profile
        )
        await writer.bootstrap()
        _ = try await writer.set(
            key: "agent_mode.show_built_in_workflow_cleanup_guidance",
            value: .bool(false)
        )

        let twoCallersEntered = TestGate(targetCount: 2)
        let releaseLoad = TestGate(targetCount: 1)
        let store = DomainDirectSettingsStore(
            persistence: persistence,
            profileIdentifier: profile
        )
        await store.test_setBootstrapDidEnter {
            await twoCallersEntered.arrive()
        }
        await store.test_setBootstrapBeforeLoad {
            await releaseLoad.wait()
        }

        let first = Task {
            await store.bootstrap()
            return try await store.effectiveValue(
                for: "agent_mode.show_built_in_workflow_cleanup_guidance"
            )
        }
        let second = Task {
            await store.bootstrap()
            return try await store.effectiveValue(
                for: "agent_mode.show_built_in_workflow_cleanup_guidance"
            )
        }
        await twoCallersEntered.wait()
        await releaseLoad.arrive()

        let values = try await [first.value, second.value]
        XCTAssertEqual(values, [.bool(false), .bool(false)])
    }

    func testConcurrentColdStartWriteWaitsForPersistedDigest() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DomainDirectSettingsStoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = "concurrent-cold-start-write"
        let persistence = makePersistence(root: root, profile: profile)
        let writer = DomainDirectSettingsStore(
            persistence: persistence,
            profileIdentifier: profile
        )
        await writer.bootstrap()
        _ = try await writer.set(
            key: "agent_mode.show_built_in_workflow_cleanup_guidance",
            value: .bool(false)
        )

        let twoCallersEntered = TestGate(targetCount: 2)
        let releaseLoad = TestGate(targetCount: 1)
        let store = DomainDirectSettingsStore(
            persistence: persistence,
            profileIdentifier: profile
        )
        await store.test_setBootstrapDidEnter {
            await twoCallersEntered.arrive()
        }
        await store.test_setBootstrapBeforeLoad {
            await releaseLoad.wait()
        }

        let first = Task { await store.bootstrap() }
        let second = Task {
            await store.bootstrap()
            return try await store.set(
                key: "agent_mode.show_built_in_workflow_cleanup_guidance",
                value: .bool(true)
            )
        }
        await twoCallersEntered.wait()
        await releaseLoad.arrive()

        await first.value
        let revision = try await second.value
        XCTAssertEqual(revision, 2)

        let verifier = DomainDirectSettingsStore(
            persistence: persistence,
            profileIdentifier: profile
        )
        await verifier.bootstrap()
        let persisted = try await verifier.effectiveValue(
            for: "agent_mode.show_built_in_workflow_cleanup_guidance"
        )
        XCTAssertEqual(persisted, .bool(true))
    }

    private func makePersistence(root: URL, profile: String) -> DomainPersistenceCoordinator {
        let identity = DomainRuntimeIdentity(
            runtimeID: UUID(),
            lifecycleGeneration: 1,
            processID: 42,
            mode: .standalone,
            createdAt: Date()
        )
        let configuration = DomainRuntimeConfiguration(
            mode: identity.mode,
            profileIdentifier: profile,
            storageDirectory: root,
            eventDirectory: root.appendingPathComponent("Events"),
            temporaryDirectory: root.appendingPathComponent("Temporary"),
            externalReloadInterval: nil
        )
        return DomainPersistenceCoordinator(configuration: configuration, identity: identity)
    }
}

private actor TestGate {
    private let targetCount: Int
    private var count = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(targetCount: Int) {
        self.targetCount = targetCount
    }

    func arrive() {
        count += 1
        resumeIfReady()
    }

    func wait() async {
        guard count < targetCount else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func resumeIfReady() {
        guard count >= targetCount else { return }
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}
