import Foundation
@testable import RepoPromptApp
import XCTest

/// Durable oversight intent: exact load classification, token-versioned mutation receipts,
/// preservation of files this build must not rewrite, and the derived launch policy.
///
/// These are the contracts the whole restart-persistence feature stands on. If a stale token can
/// delete a re-added pair, or a blocked file can be silently overwritten, every layer above is
/// reasoning about durable state that is not actually there.
final class AgentSessionOversightIntentStoreTests: XCTestCase {
    private final class WriteFailureGate: @unchecked Sendable {
        private let lock = NSLock()
        private var failing = false

        func setFailing(_ value: Bool) {
            lock.withLock { failing = value }
        }

        func write(_ data: Data, to url: URL) throws {
            if lock.withLock({ failing }) { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url, options: .atomic)
        }
    }

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("oversight-intent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    private var fileURL: URL {
        directory.appendingPathComponent(AgentSessionOversightIntentStore.filename)
    }

    private var backupsURL: URL {
        directory.appendingPathComponent(AgentSessionOversightIntentStore.backupsDirectoryName, isDirectory: true)
    }

    private func makeStore(
        mode: AgentSessionOversightPersistenceMode = .enabled,
        writer: (@Sendable (Data, URL) throws -> Void)? = nil,
        maxFileByteCount: Int = AgentSessionOversightIntentStore.maxFileByteCount,
        maxDecodedRowCount: Int = AgentSessionOversightIntentStore.maxDecodedRowCount
    ) -> AgentSessionOversightIntentStore {
        AgentSessionOversightIntentStore(
            fileURL: fileURL,
            backupsDirectoryURL: backupsURL,
            mode: mode,
            writer: writer ?? { data, url in try data.write(to: url, options: .atomic) },
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            maxFileByteCount: maxFileByteCount,
            maxDecodedRowCount: maxDecodedRowCount
        )
    }

    private func pair(_ observer: UUID = UUID(), _ target: UUID = UUID()) -> AgentSessionOversightIntent {
        AgentSessionOversightIntent(observerSessionID: observer, targetSessionID: target)
    }

    private func writeRawDocument(_ json: String) throws {
        try Data(json.utf8).write(to: fileURL, options: .atomic)
    }

    private func decodedLinks() throws -> [AgentSessionOversightIntent] {
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(AgentSessionOversightIntentDocument.self, from: data).links
    }

    // MARK: - Load

    func testLoadDeduplicatesAndDropsSelfPairsWithoutRewritingTheFile() async throws {
        let observer = UUID()
        let target = UUID()
        let duplicate = AgentSessionOversightIntent(observerSessionID: observer, targetSessionID: target)
        let document = AgentSessionOversightIntentDocument(links: [
            duplicate,
            duplicate,
            AgentSessionOversightIntent(observerSessionID: observer, targetSessionID: observer)
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(document).write(to: fileURL, options: .atomic)
        let modifiedBefore = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date

        let store = makeStore()
        guard case let .ready(load) = await store.loadForLaunch() else {
            return XCTFail("Expected a ready load")
        }

        XCTAssertEqual(load.source, .loaded)
        XCTAssertEqual(load.pairs, [duplicate], "A self-pair can never be granted, so it must not survive load.")
        let modifiedAfter = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date
        XCTAssertEqual(modifiedBefore, modifiedAfter, "Normalization is in-memory; loading must not write.")
    }

    func testMissingFileLoadsEmptyAndWritable() async throws {
        let store = makeStore()
        guard case let .ready(load) = await store.loadForLaunch() else {
            return XCTFail("Expected a ready load")
        }
        XCTAssertEqual(load.source, .missing)
        XCTAssertTrue(load.pairs.isEmpty)

        let inserted = pair()
        let receipt = await store.insert(inserted)
        XCTAssertEqual(receipt.outcome, .applied)
        XCTAssertEqual(try decodedLinks(), [inserted])
    }

    /// Add, Stop, and the presentation surface all call `loadForLaunch()`, so the classification has
    /// to be the launch's settled answer rather than "whatever the second caller would have found".
    /// Relabelling a quarantine as an ordinary load would silently drop the one notice telling the
    /// user their saved links were moved aside.
    func testRepeatLoadReportsTheSettledClassificationRatherThanRelabellingIt() async throws {
        try writeRawDocument("{ this is not json")
        let quarantining = makeStore()
        let firstQuarantined = await quarantining.loadForLaunch()
        let secondQuarantined = await quarantining.loadForLaunch()
        XCTAssertEqual(firstQuarantined, secondQuarantined)
        guard case let .ready(repeatedQuarantine) = secondQuarantined else {
            return XCTFail("Expected a ready load")
        }
        XCTAssertEqual(repeatedQuarantine.source, .quarantined)

        try FileManager.default.removeItem(at: backupsURL)
        let missing = makeStore()
        _ = await missing.loadForLaunch()
        guard case let .ready(repeatedMissing) = await missing.loadForLaunch() else {
            return XCTFail("Expected a ready load")
        }
        XCTAssertEqual(repeatedMissing.source, .missing)
    }

    // MARK: - Insert / remove

    func testInsertIsIdempotentAndNeitherWritesNorAdvancesRevision() async throws {
        let store = makeStore()
        _ = await store.loadForLaunch()
        let intent = pair()

        let first = await store.insert(intent)
        XCTAssertEqual(first.outcome, .applied)
        XCTAssertTrue(first.wroteFile)
        let token = try XCTUnwrap(first.token(for: intent))
        let firstAssertion = try XCTUnwrap(first.assertionGeneration)

        let modifiedAfterFirst = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date
        let second = await store.insert(intent)

        XCTAssertEqual(second.outcome, .unchanged)
        XCTAssertFalse(second.wroteFile)
        XCTAssertEqual(second.storeRevisionBefore, second.storeRevisionAfter)
        XCTAssertEqual(second.token(for: intent), token, "A re-add of a live pair must reuse its token, not supersede it.")
        let secondAssertion = try XCTUnwrap(second.assertionGeneration)
        XCTAssertGreaterThan(secondAssertion, firstAssertion)
        let staleCleanup = await store.remove(intent, ifCurrent: token, assertedAt: firstAssertion)
        XCTAssertEqual(staleCleanup.outcome, .tokenMismatch)
        let tokenAfterStaleCleanup = await store.token(for: intent)
        XCTAssertEqual(tokenAfterStaleCleanup, token)
        let modifiedAfterSecond = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date
        XCTAssertEqual(modifiedAfterFirst, modifiedAfterSecond)
    }

    func testStaleTokenCannotRemoveAReAddedPair() async throws {
        let store = makeStore()
        _ = await store.loadForLaunch()
        let intent = pair()

        let insertedA = await store.insert(intent)
        let tokenA = try XCTUnwrap(insertedA.token(for: intent))
        let removedA = await store.remove(intent, ifCurrent: tokenA)
        XCTAssertEqual(removedA.outcome, .applied)
        let insertedB = await store.insert(intent)
        let tokenB = try XCTUnwrap(insertedB.token(for: intent))
        XCTAssertNotEqual(tokenA, tokenB)

        // This is the compensation/lifecycle race: work captured against token A finishes late and
        // tries to clean up, long after the user reasserted the same pair.
        let stale = await store.remove(intent, ifCurrent: tokenA)
        let tokenBIsStillCurrent = await store.isCurrent(tokenB)
        XCTAssertEqual(stale.outcome, .tokenMismatch)
        XCTAssertFalse(stale.wroteFile)
        XCTAssertTrue(tokenBIsStillCurrent)
        XCTAssertEqual(try decodedLinks(), [intent])
    }

    /// The guards are mutation-time, not just load-time.
    ///
    /// A manifest sitting exactly at a limit must not accept one more row, write it successfully, and
    /// then refuse to load itself on the next launch — which would preserve the file while making
    /// every saved link in it unchangeable, because of a write this process reported as a success.
    func testInsertAtTheRowLimitIsBlockedAndLeavesDiskAndMemoryLoadable() async throws {
        let store = makeStore(maxDecodedRowCount: 1)
        _ = await store.loadForLaunch()
        let first = pair()
        let seeded = await store.insert(first)
        XCTAssertEqual(seeded.outcome, .applied)

        let overflow = await store.insert(pair())

        XCTAssertEqual(overflow.outcome, .blocked)
        XCTAssertFalse(overflow.wroteFile)
        XCTAssertEqual(try decodedLinks(), [first], "The on-disk document must be preserved exactly.")
        let survivingToken = await store.token(for: first)
        XCTAssertNotNil(survivingToken, "Existing tokens survive a blocked mutation.")

        // The decisive assertion: the file this process wrote is still one the next launch accepts.
        let relaunched = makeStore(maxDecodedRowCount: 1)
        guard case let .ready(load) = await relaunched.loadForLaunch() else {
            return XCTFail("expected the preserved manifest to load")
        }
        XCTAssertEqual(load.pairs, [first])
    }

    func testInsertExceedingTheByteGuardIsBlockedAndWritesNothing() async {
        // Small enough that even one encoded row exceeds it.
        let store = makeStore(maxFileByteCount: 32)
        _ = await store.loadForLaunch()

        let receipt = await store.insert(pair())

        XCTAssertEqual(receipt.outcome, .blocked)
        XCTAssertFalse(receipt.wroteFile)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fileURL.path),
            "An over-cap document must never reach disk, not even partially."
        )
    }

    func testRemoveOfAbsentPairReportsAbsentWithoutWriting() async throws {
        let store = makeStore()
        _ = await store.loadForLaunch()
        let intent = pair()
        let inserted = await store.insert(intent)
        let token = try XCTUnwrap(inserted.token(for: intent))
        let removed = await store.remove(intent, ifCurrent: token)
        XCTAssertEqual(removed.outcome, .applied)

        let repeated = await store.remove(intent, ifCurrent: token)
        XCTAssertEqual(repeated.outcome, .absent)
        XCTAssertFalse(repeated.wroteFile)
        XCTAssertEqual(try decodedLinks(), [], "The last removal keeps an empty versioned document.")
    }

    // MARK: - Compatibility and preservation

    func testFutureSchemaIsPreservedAndBlocksMutation() async throws {
        try writeRawDocument(#"{"version":99,"links":[]}"#)
        let store = makeStore()

        guard case let .blocked(reason) = await store.loadForLaunch() else {
            return XCTFail("Expected a blocked load")
        }
        let blockedInsert = await store.insert(pair())
        XCTAssertEqual(
            reason,
            .unsupportedFutureSchema(onDiskVersion: 99, supportedVersion: AgentSessionOversightIntentDocument.currentVersion)
        )
        XCTAssertEqual(blockedInsert.outcome, .blocked)
        XCTAssertEqual(
            try String(data: Data(contentsOf: fileURL), encoding: .utf8),
            #"{"version":99,"links":[]}"#,
            "A file this build did not write must be preserved byte-for-byte."
        )
    }

    func testMalformedDocumentIsQuarantinedIntactAndTheStoreStartsWritable() async throws {
        try writeRawDocument("{ this is not json")
        let store = makeStore()

        guard case let .ready(load) = await store.loadForLaunch() else {
            return XCTFail("Expected a ready load after quarantine")
        }
        XCTAssertEqual(load.source, .quarantined)
        XCTAssertTrue(load.pairs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))

        let backups = try FileManager.default.contentsOfDirectory(atPath: backupsURL.path)
        XCTAssertEqual(backups.count, 1)
        let backup = try XCTUnwrap(backups.first)
        XCTAssertTrue(backup.hasPrefix("agentSessionOversightLinks.corrupt."))
        XCTAssertEqual(
            try String(contentsOf: backupsURL.appendingPathComponent(backup), encoding: .utf8),
            "{ this is not json",
            "The backup must be the original bytes, not a salvaged rewrite."
        )

        let intent = pair()
        let inserted = await store.insert(intent)
        XCTAssertEqual(inserted.outcome, .applied)
        XCTAssertEqual(try decodedLinks(), [intent])
    }

    /// The store bootstraps independently of window-session restore, so it cannot assume some other
    /// component already created `Application Support/RepoPrompt CE`. Without its own container
    /// creation the very first Add on a fresh install fails its atomic replace and is reported to
    /// the user as a save failure.
    func testFirstWriteCreatesItsOwnContainerDirectory() async throws {
        let container = directory.appendingPathComponent("RepoPrompt CE", isDirectory: true)
        let store = AgentSessionOversightIntentStore(
            fileURL: container.appendingPathComponent(AgentSessionOversightIntentStore.filename),
            backupsDirectoryURL: container.appendingPathComponent(
                AgentSessionOversightIntentStore.backupsDirectoryName,
                isDirectory: true
            ),
            mode: .enabled
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: container.path))

        guard case let .ready(load) = await store.loadForLaunch() else {
            return XCTFail("Expected a ready load")
        }
        let intent = pair()
        let receipt = await store.insert(intent)

        XCTAssertEqual(load.source, .missing, "Reading a missing file must not create anything.")
        XCTAssertEqual(receipt.outcome, .applied)
        let data = try Data(contentsOf: container.appendingPathComponent(AgentSessionOversightIntentStore.filename))
        XCTAssertEqual(try JSONDecoder().decode(AgentSessionOversightIntentDocument.self, from: data).links, [intent])
    }

    // MARK: - Write failure and cancellation

    func testWriteFailurePreservesDiskMemoryAndTokens() async {
        let store = makeStore(writer: { _, _ in
            throw CocoaError(.fileWriteOutOfSpace)
        })
        _ = await store.loadForLaunch()
        let intent = pair()

        let receipt = await store.insert(intent)
        XCTAssertEqual(receipt.outcome, .writeFailed)
        XCTAssertFalse(receipt.wroteFile)
        XCTAssertEqual(receipt.storeRevisionBefore, receipt.storeRevisionAfter)
        XCTAssertTrue(receipt.transitions.isEmpty)
        let token = await store.token(for: intent)
        XCTAssertNil(token, "A failed write must not mint a token.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testFailedRemoveAllReportsEveryAttemptedCurrentRowAtomically() async throws {
        let gate = WriteFailureGate()
        let store = makeStore(writer: { data, url in try gate.write(data, to: url) })
        _ = await store.loadForLaunch()
        let deletedSessionID = UUID()
        let outbound = pair(deletedSessionID, UUID())
        let inbound = pair(UUID(), deletedSessionID)
        let unrelated = pair()
        let outboundReceipt = await store.insert(outbound)
        let inboundReceipt = await store.insert(inbound)
        _ = await store.insert(unrelated)
        let outboundToken = try XCTUnwrap(outboundReceipt.token(for: outbound))
        let inboundToken = try XCTUnwrap(inboundReceipt.token(for: inbound))
        let outboundAssertion = try XCTUnwrap(outboundReceipt.assertionGeneration)
        let inboundAssertion = try XCTUnwrap(inboundReceipt.assertionGeneration)
        gate.setFailing(true)

        let receipt = await store.removeAll(containing: deletedSessionID)

        XCTAssertEqual(receipt.outcome, .writeFailed)
        XCTAssertTrue(receipt.transitions.isEmpty, "Failed writes commit no before/after transitions.")
        XCTAssertEqual(
            receipt.attemptedCurrentByPair,
            [
                outbound: .init(token: outboundToken, assertionGeneration: outboundAssertion),
                inbound: .init(token: inboundToken, assertionGeneration: inboundAssertion)
            ]
        )
        XCTAssertNil(receipt.attemptedCurrentByPair[unrelated])
        let outboundAfterFailure = await store.token(for: outbound)
        let inboundAfterFailure = await store.token(for: inbound)
        XCTAssertEqual(outboundAfterFailure, outboundToken)
        XCTAssertEqual(inboundAfterFailure, inboundToken)
    }

    /// The store deliberately has no cancellation check inside its critical section, so a caller
    /// cancelled before or during the call still gets a fully committed mutation rather than a disk
    /// write with no matching in-memory token (or the reverse).
    func testCancelledCallerStillCommitsDiskAndMemoryTogether() async throws {
        let store = makeStore()
        _ = await store.loadForLaunch()
        let intent = pair()

        let task = Task { () -> AgentSessionOversightIntentMutationReceipt in
            while !Task.isCancelled {
                await Task.yield()
            }
            return await store.insert(intent)
        }
        task.cancel()
        let receipt = await task.value

        XCTAssertEqual(receipt.outcome, .applied)
        let token = try XCTUnwrap(receipt.token(for: intent))
        let isCurrent = await store.isCurrent(token)
        XCTAssertTrue(isCurrent)
        XCTAssertEqual(try decodedLinks(), [intent])
    }

    // MARK: - Launch policy

    func testSuppressedLaunchPerformsNoProductionFileIOAndBlocksMutation() async throws {
        try writeRawDocument(#"{"version":1,"links":[]}"#)
        let store = makeStore(mode: .suppressed)

        let load = await store.loadForLaunch()
        let insert = await store.insert(pair())
        let removeAll = await store.removeAll(containing: UUID())
        XCTAssertEqual(load, .suppressed)
        XCTAssertEqual(insert.outcome, .blocked)
        XCTAssertEqual(removeAll.outcome, .blocked)
        XCTAssertEqual(
            try String(data: Data(contentsOf: fileURL), encoding: .utf8),
            #"{"version":1,"links":[]}"#
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupsURL.path))
    }

    func testDormantLaunchStillReadsAndMutatesButDisallowsAutomaticRestore() async {
        let store = makeStore(mode: .dormant)
        guard case let .ready(load) = await store.loadForLaunch() else {
            return XCTFail("Expected a ready load")
        }
        let inserted = await store.insert(pair())
        XCTAssertEqual(load.source, .missing)
        XCTAssertEqual(inserted.outcome, .applied)
        XCTAssertFalse(AgentSessionOversightPersistenceMode.dormant.allowsAutomaticRestore)
        XCTAssertTrue(AgentSessionOversightPersistenceMode.dormant.performsProductionFileIO)
    }

    func testDerivedLaunchPolicyCoversAllThreeModes() {
        XCTAssertEqual(
            AppLaunchConfiguration.agentSessionOversightPersistenceMode(
                suppressesOversightPersistence: false,
                autoRestoreWorkspacesEnabled: true
            ),
            .enabled
        )
        XCTAssertEqual(
            AppLaunchConfiguration.agentSessionOversightPersistenceMode(
                suppressesOversightPersistence: false,
                autoRestoreWorkspacesEnabled: false
            ),
            .dormant
        )
        // Suppression wins over the preference: turning restore back on must never make a
        // deterministic launch touch the production file.
        XCTAssertEqual(
            AppLaunchConfiguration.agentSessionOversightPersistenceMode(
                suppressesOversightPersistence: true,
                autoRestoreWorkspacesEnabled: true
            ),
            .suppressed
        )
    }
}
