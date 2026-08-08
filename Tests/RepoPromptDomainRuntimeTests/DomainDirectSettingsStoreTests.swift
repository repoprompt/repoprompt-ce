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

        let loadStarted = expectation(description: "initial settings load started")
        let waiterJoined = expectation(description: "concurrent bootstrap joined shared load")
        let releaseLoad = TestGate()
        let events = EventRecorder()
        let store = DomainDirectSettingsStore(
            persistence: persistence,
            profileIdentifier: profile
        )
        await store.test_setBootstrapEventHandler { event in
            await events.record(event)
            switch event {
            case .loadStarted:
                loadStarted.fulfill()
                await releaseLoad.wait()
            case .waiterJoined:
                waiterJoined.fulfill()
            case .loadPublished, .willCompareAndSwap:
                break
            }
        }

        let first = Task {
            await store.bootstrap()
            return try await store.effectiveValue(
                for: "agent_mode.show_built_in_workflow_cleanup_guidance"
            )
        }
        await fulfillment(of: [loadStarted], timeout: 1)
        let second = Task {
            await store.bootstrap()
            return try await store.effectiveValue(
                for: "agent_mode.show_built_in_workflow_cleanup_guidance"
            )
        }
        await fulfillment(of: [waiterJoined], timeout: 1)
        await releaseLoad.open()

        let values = try await [first.value, second.value]
        XCTAssertEqual(values, [.bool(false), .bool(false)])
        let recordedEvents = await events.values()
        XCTAssertEqual(recordedEvents, [.loadStarted, .waiterJoined, .loadPublished])
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

        let loadStarted = expectation(description: "initial settings load started")
        let waiterJoined = expectation(description: "concurrent write joined shared load")
        let releaseLoad = TestGate()
        let events = EventRecorder()
        let store = DomainDirectSettingsStore(
            persistence: persistence,
            profileIdentifier: profile
        )
        await store.test_setBootstrapEventHandler { event in
            await events.record(event)
            switch event {
            case .loadStarted:
                loadStarted.fulfill()
                await releaseLoad.wait()
            case .waiterJoined:
                waiterJoined.fulfill()
            case .loadPublished, .willCompareAndSwap:
                break
            }
        }

        let first = Task { await store.bootstrap() }
        await fulfillment(of: [loadStarted], timeout: 1)
        let second = Task {
            await store.bootstrap()
            return try await store.set(
                key: "agent_mode.show_built_in_workflow_cleanup_guidance",
                value: .bool(true)
            )
        }
        await fulfillment(of: [waiterJoined], timeout: 1)
        await releaseLoad.open()

        await first.value
        let revision = try await second.value
        XCTAssertEqual(revision, 2)
        let recordedEvents = await events.values()
        XCTAssertEqual(
            recordedEvents,
            [.loadStarted, .waiterJoined, .loadPublished, .willCompareAndSwap]
        )

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

    func testEmptyProfileBootstrapCompletesOnceAndFirstWriteUsesNilDigest() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DomainDirectSettingsStoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = "empty-profile"
        let events = EventRecorder()
        let store = DomainDirectSettingsStore(
            persistence: makePersistence(root: root, profile: profile),
            profileIdentifier: profile
        )
        await store.test_setBootstrapEventHandler { event in
            await events.record(event)
        }

        await store.bootstrap()
        await store.bootstrap()
        let revision = try await store.set(
            key: "agent_mode.show_built_in_workflow_cleanup_guidance",
            value: .bool(false)
        )

        XCTAssertEqual(revision, 1)
        let recordedEvents = await events.values()
        XCTAssertEqual(
            recordedEvents,
            [.loadStarted, .loadPublished, .willCompareAndSwap]
        )
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
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor EventRecorder {
    private var recorded: [DomainDirectSettingsBootstrapEvent] = []

    func record(_ event: DomainDirectSettingsBootstrapEvent) {
        recorded.append(event)
    }

    func values() -> [DomainDirectSettingsBootstrapEvent] {
        recorded
    }
}
