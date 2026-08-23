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
        let firstCompleted = expectation(description: "initial bootstrap completed")
        let secondCompleted = expectation(description: "joined bootstrap completed")
        let releaseLoad = TestGate()
        let events = EventRecorder()
        let results = TestResultRecorder<DomainSettingValue>()
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
            case .loadPublished:
                break
            }
        }

        let first = Task {
            let result = await readCleanupGuidance(from: store)
            await results.record(result, for: "first")
            firstCompleted.fulfill()
        }
        guard await waitForCompletion(of: [loadStarted]) else {
            await releaseLoad.open()
            first.cancel()
            return
        }
        let second = Task {
            let result = await readCleanupGuidance(from: store)
            await results.record(result, for: "second")
            secondCompleted.fulfill()
        }
        guard await waitForCompletion(of: [waiterJoined]) else {
            await releaseLoad.open()
            first.cancel()
            second.cancel()
            return
        }
        await releaseLoad.open()
        guard await waitForCompletion(of: [firstCompleted, secondCompleted]) else {
            first.cancel()
            second.cancel()
            return
        }

        let recordedResults = await results.values()
        XCTAssertEqual(recordedResults["first"], .success(.bool(false)))
        XCTAssertEqual(recordedResults["second"], .success(.bool(false)))
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
        let firstCompleted = expectation(description: "initial bootstrap completed")
        let secondCompleted = expectation(description: "joined write completed")
        let releaseLoad = TestGate()
        let events = EventRecorder()
        let results = TestResultRecorder<UInt64>()
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
            case .loadPublished:
                break
            }
        }

        let first = Task {
            await store.bootstrap()
            firstCompleted.fulfill()
        }
        guard await waitForCompletion(of: [loadStarted]) else {
            await releaseLoad.open()
            first.cancel()
            return
        }
        let second = Task {
            let result: TestTaskResult<UInt64>
            do {
                await store.bootstrap()
                result = try await .success(store.set(
                    key: "agent_mode.show_built_in_workflow_cleanup_guidance",
                    value: .bool(true)
                ))
            } catch {
                result = .failure(String(describing: error))
            }
            await results.record(result, for: "second")
            secondCompleted.fulfill()
        }
        guard await waitForCompletion(of: [waiterJoined]) else {
            await releaseLoad.open()
            first.cancel()
            second.cancel()
            return
        }
        await releaseLoad.open()
        guard await waitForCompletion(of: [firstCompleted, secondCompleted]) else {
            first.cancel()
            second.cancel()
            return
        }

        let recordedResults = await results.values()
        XCTAssertEqual(recordedResults["second"], .success(2))
        let recordedEvents = await events.values()
        XCTAssertEqual(
            recordedEvents,
            [.loadStarted, .waiterJoined, .loadPublished]
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
            [.loadStarted, .loadPublished]
        )
    }

    private func waitForCompletion(
        of expectations: [XCTestExpectation],
        timeout: TimeInterval = 1
    ) async -> Bool {
        let result = await XCTWaiter.fulfillment(of: expectations, timeout: timeout)
        guard result == .completed else {
            XCTFail("Timed out waiting for task completion: \(result)")
            return false
        }
        return true
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

private func readCleanupGuidance(
    from store: DomainDirectSettingsStore
) async -> TestTaskResult<DomainSettingValue> {
    do {
        await store.bootstrap()
        return try await .success(store.effectiveValue(
            for: "agent_mode.show_built_in_workflow_cleanup_guidance"
        ))
    } catch {
        return .failure(String(describing: error))
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

private enum TestTaskResult<Value: Equatable & Sendable>: Equatable {
    case success(Value)
    case failure(String)
}

private actor TestResultRecorder<Value: Equatable & Sendable> {
    private var recorded: [String: TestTaskResult<Value>] = [:]

    func record(_ result: TestTaskResult<Value>, for key: String) {
        recorded[key] = result
    }

    func values() -> [String: TestTaskResult<Value>] {
        recorded
    }
}
