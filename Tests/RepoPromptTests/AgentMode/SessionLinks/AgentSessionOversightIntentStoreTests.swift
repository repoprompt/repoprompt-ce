import Foundation
@testable import RepoPromptApp
import RepoPromptPersistence
import XCTest

/// Live intent tokens remain usable independently of continuity saving. SQLite receipts describe
/// only committed row transitions; stale owners cannot erase another owner's unrelated rows.
final class AgentSessionOversightIntentStoreTests: XCTestCase {
    private final class FailureGate: @unchecked Sendable {
        private let lock = NSLock()
        private var failing = false
        func setFailing(_ value: Bool) {
            lock.withLock { failing = value }
        }

        func check() throws {
            if lock.withLock({ failing }) { throw CocoaError(.fileWriteOutOfSpace) }
        }
    }

    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("oversight-intent-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
    }

    private var fileURL: URL {
        directory.appendingPathComponent(AgentSessionOversightIntentStore.filename)
    }

    private var databaseURL: URL {
        directory.appendingPathComponent("Overseer/continuity.sqlite")
    }

    private var database: OverseerContinuityStore {
        .init(databaseURL: databaseURL, profile: "temporary-overseer")
    }

    private func makeStore(
        mode: AgentSessionOversightPersistenceMode = .enabled,
        beforeCommit: @escaping @Sendable () throws -> Void = {}
    ) -> AgentSessionOversightIntentStore {
        .init(fileURL: fileURL, backupsDirectoryURL: directory.appendingPathComponent("Backups"), mode: mode, beforeCommit: beforeCommit)
    }

    private func pair() -> AgentSessionOversightIntent {
        .init(observerSessionID: UUID(), targetSessionID: UUID())
    }

    private func activeSavedPairs() throws -> Set<AgentSessionOversightIntent> {
        try Set(database.rows(kind: .link).filter { !$0.terminal }.map { try JSONDecoder().decode(AgentSessionOversightIntent.self, from: $0.payload) })
    }

    func testLegacyRowsAreMigratedWithoutRewritingSourceOrRestoringSelfPairs() async throws {
        let existing = pair()
        let selfPair = AgentSessionOversightIntent(observerSessionID: existing.observerSessionID, targetSessionID: existing.observerSessionID)
        let original = try JSONEncoder().encode(AgentSessionOversightIntentDocument(links: [existing, existing, selfPair]))
        try original.write(to: fileURL)
        let store = makeStore()
        guard case let .ready(load) = await store.loadForLaunch() else { return XCTFail("Expected continuity restore") }
        XCTAssertEqual(load.pairs, [existing])
        XCTAssertEqual(try Data(contentsOf: fileURL), original)
        XCTAssertEqual(try activeSavedPairs(), [existing])
        XCTAssertEqual(try database.legacySources().first?.bytes, original)
    }

    func testMalformedAndFutureSourcesRemainRecoverableAndDoNotVetoLiveLinks() async throws {
        for bytes in [Data("{invalid json".utf8), Data(#"{"version":99,"links":[]}"#.utf8)] {
            try bytes.write(to: fileURL)
            let store = makeStore()
            _ = await store.loadForLaunch()
            let value = pair()
            let receipt = await store.insert(value)
            XCTAssertEqual(receipt.outcome, .applied)
            XCTAssertFalse(receipt.isDurable, "Returning a live token is not a durable write acknowledgement")
            await store.serializationBarrier()
            XCTAssertNotNil(try database.receipt(operationID: XCTUnwrap(receipt.operationID)))
            XCTAssertTrue(try activeSavedPairs().contains(value))
            XCTAssertEqual(try Data(contentsOf: fileURL), bytes)
            XCTAssertTrue(try database.legacySources().contains { $0.bytes == bytes })
        }
    }

    func testFailedSavingKeepsLiveInsertAndRemoveAndRetriesSameOperations() async throws {
        let gate = FailureGate()
        gate.setFailing(true)
        let store = makeStore(beforeCommit: { try gate.check() })
        _ = await store.loadForLaunch()
        let value = pair()
        let inserted = await store.insert(value)
        let token = try XCTUnwrap(inserted.token(for: value))
        await store.serializationBarrier()
        let current = await store.isCurrent(token)
        let failed = await store.saveState
        XCTAssertTrue(current)
        XCTAssertEqual(failed, "failed")
        XCTAssertNil(try database.receipt(operationID: XCTUnwrap(inserted.operationID)))
        let removed = await store.remove(value, ifCurrent: token)
        await store.serializationBarrier()
        XCTAssertEqual(removed.outcome, .applied)
        let afterRemoval = await store.token(for: value)
        XCTAssertNil(afterRemoval, "A failed save cannot undo a current live revocation")
        gate.setFailing(false)
        await store.retrySaving()
        let saved = await store.saveState
        XCTAssertEqual(saved, "saved")
        XCTAssertNotNil(try database.receipt(operationID: XCTUnwrap(inserted.operationID)))
        XCTAssertNotNil(try database.receipt(operationID: XCTUnwrap(removed.operationID)))
        XCTAssertTrue(try database.rows(kind: .link).first { $0.id == value.continuityID }?.terminal == true)
        guard case let .ready(reloaded) = await makeStore().loadForLaunch() else { return XCTFail("Expected restore") }
        XCTAssertFalse(reloaded.pairs.contains(value))
    }

    func testFailedFirstOpenRecoversItsBaselineWithoutReplacingTheLiveDecision() async throws {
        let value = pair()
        let original = makeStore()
        _ = await original.loadForLaunch()
        _ = await original.insert(value)
        await original.serializationBarrier()
        let privateDirectory = databaseURL.deletingLastPathComponent()
        let parked = directory.appendingPathComponent("parked")
        try FileManager.default.moveItem(at: privateDirectory, to: parked)
        try Data("not a directory".utf8).write(to: privateDirectory)
        let recovering = makeStore()
        guard case .blocked = await recovering.loadForLaunch() else { return XCTFail("Expected failed open") }
        let reasserted = await recovering.insert(value)
        await recovering.serializationBarrier()
        let token = try XCTUnwrap(reasserted.token(for: value))
        let current = await recovering.isCurrent(token)
        XCTAssertTrue(current, "An unavailable store cannot veto a current explicit live link")
        try FileManager.default.removeItem(at: privateDirectory)
        try FileManager.default.moveItem(at: parked, to: privateDirectory)
        await recovering.retrySaving()
        let state = await recovering.saveState
        XCTAssertEqual(state, "saved")
        XCTAssertNotNil(try database.receipt(operationID: XCTUnwrap(reasserted.operationID)))
        let after = await recovering.token(for: value)
        XCTAssertEqual(after, token, "Restoration must not substitute an older live token")
    }

    func testStaleTokenAndSameTokenStaleAssertionCannotRemoveReassertedLink() async throws {
        let store = makeStore()
        _ = await store.loadForLaunch()
        let value = pair()
        let first = await store.insert(value)
        let token = try XCTUnwrap(first.token(for: value))
        let reassertion = await store.insert(value)
        let staleAssertion = await store.remove(value, ifCurrent: token, assertedAt: first.assertionGeneration)
        XCTAssertEqual(staleAssertion.outcome, .tokenMismatch)
        let removed = await store.remove(value, ifCurrent: token, assertedAt: reassertion.assertionGeneration)
        XCTAssertEqual(removed.outcome, .applied)
        let readded = await store.insert(value)
        XCTAssertNotEqual(readded.token(for: value), token)
        let staleToken = await store.remove(value, ifCurrent: token)
        XCTAssertEqual(staleToken.outcome, .tokenMismatch)
        await store.serializationBarrier()
        XCTAssertTrue(try activeSavedPairs().contains(value))
    }

    func testIndependentOwnersDoNotOverwriteUnrelatedRowsAndStaleSameRowSaveFails() async throws {
        let first = makeStore(), second = makeStore()
        _ = await first.loadForLaunch()
        _ = await second.loadForLaunch()
        let a = pair(), b = pair()
        _ = await first.insert(a)
        await first.serializationBarrier()
        _ = await second.insert(b)
        await second.serializationBarrier()
        XCTAssertEqual(try activeSavedPairs(), [a, b])
        let stale = await second.insert(a)
        await second.serializationBarrier()
        let current = await second.token(for: a)
        let status = await second.saveState
        XCTAssertNotNil(current, "Explicit current-process intent still applies")
        XCTAssertEqual(status, "failed", "A stale base must not be reported as saved")
        XCTAssertNil(try database.receipt(operationID: XCTUnwrap(stale.operationID)))
        XCTAssertEqual(try activeSavedPairs(), [a, b])
        let bToken = await second.token(for: b)
        let removed = try await second.remove(b, ifCurrent: XCTUnwrap(bToken))
        await second.serializationBarrier()
        XCTAssertNotNil(try database.receipt(operationID: XCTUnwrap(removed.operationID)), "An impossible stale insert cannot strand a later removal")
        XCTAssertEqual(try activeSavedPairs(), [a])
        let finalState = await second.saveState
        XCTAssertEqual(finalState, "failed", "The rejected row is not falsely reported as saved")
    }

    func testBulkRemoveIsLiveAtomicAndLeavesUnrelatedPairsSaved() async throws {
        let store = makeStore()
        _ = await store.loadForLaunch()
        let removedID = UUID()
        let a = AgentSessionOversightIntent(observerSessionID: removedID, targetSessionID: UUID())
        let b = AgentSessionOversightIntent(observerSessionID: UUID(), targetSessionID: removedID)
        let c = pair()
        _ = await store.insert(a)
        _ = await store.insert(b)
        _ = await store.insert(c)
        await store.serializationBarrier()
        let removed = await store.removeAll(containing: removedID)
        XCTAssertEqual(removed.outcome, .applied)
        XCTAssertEqual(Set(removed.transitions.map(\.pair)), [a, b])
        let live = await store.allIntents()
        XCTAssertEqual(live, [c])
        await store.serializationBarrier()
        XCTAssertEqual(try activeSavedPairs(), [c])
    }

    func testSuppressedContinuityAcceptsOnlyLocalIntentAndPerformsNoFileIO() async {
        let store = makeStore(mode: .suppressed)
        let load = await store.loadForLaunch()
        let receipt = await store.insert(pair())
        XCTAssertEqual(load, .suppressed)
        XCTAssertEqual(receipt.outcome, .applied)
        XCTAssertEqual(receipt.saveState, "not_persisted")
        XCTAssertFalse(receipt.isDurable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testDormantContinuitySavesButDoesNotAutomaticallyRestoreAndSuppressionWins() async throws {
        let store = makeStore(mode: .dormant)
        _ = await store.loadForLaunch()
        let value = pair()
        _ = await store.insert(value)
        await store.serializationBarrier()
        XCTAssertEqual(try activeSavedPairs(), [value])
        XCTAssertFalse(AgentSessionOversightPersistenceMode.dormant.allowsAutomaticRestore)
        XCTAssertTrue(AgentSessionOversightPersistenceMode.dormant.performsProductionFileIO)
        XCTAssertEqual(AppLaunchConfiguration.agentSessionOversightPersistenceMode(suppressesOversightPersistence: false, autoRestoreWorkspacesEnabled: true), .enabled)
        XCTAssertEqual(AppLaunchConfiguration.agentSessionOversightPersistenceMode(suppressesOversightPersistence: false, autoRestoreWorkspacesEnabled: false), .dormant)
        XCTAssertEqual(AppLaunchConfiguration.agentSessionOversightPersistenceMode(suppressesOversightPersistence: true, autoRestoreWorkspacesEnabled: true), .suppressed)
    }
}
