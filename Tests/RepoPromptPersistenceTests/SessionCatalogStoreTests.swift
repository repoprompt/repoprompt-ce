import Darwin
import Foundation
@testable import RepoPromptPersistence
import XCTest

final class SessionCatalogStoreTests: XCTestCase {
    func testOverseerRowTransactionsReceiptsAndPermanentTerminalIdentities() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Overseer-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("private/state.sqlite")
        let first = OverseerContinuityStore(databaseURL: url, profile: "test")
        let second = OverseerContinuityStore(databaseURL: url, profile: "test")
        XCTAssertEqual(try first.engineSettings(), ["journal_mode": "delete", "synchronous": "3", "fullfsync": "1", "foreign_keys": "1"])
        let parent = OverseerContinuityRow(kind: .scope, id: "parent", payload: Data("parent".utf8))
        let child = OverseerContinuityRow(kind: .scope, id: "child", parentID: "parent", payload: Data("child".utf8))
        let unrelated = OverseerContinuityRow(kind: .scope, id: "other", payload: Data("other".utf8))
        let operation = UUID()
        let receipt = try first.commit(operationID: operation, origin: "user-owner", mutations: [.grant(parent)])
        XCTAssertEqual(try second.receipt(operationID: operation), receipt)
        XCTAssertTrue(try second.commit(operationID: operation, origin: "user-owner", mutations: [.grant(parent)]).replayed)
        XCTAssertThrowsError(try first.commit(operationID: operation, origin: "user-owner", mutations: [.grant(unrelated)]))
        _ = try second.commit(operationID: UUID(), origin: "other-owner", mutations: [.grant(unrelated), .grant(child)])
        XCTAssertEqual(try first.rows(kind: .scope).count, 3, "An old owner must not replace another owner's rows")
        let revoked = try first.commit(operationID: UUID(), origin: "user-owner", mutations: [.revokeScope("parent")])
        XCTAssertEqual(Set(revoked.affectedIDs), ["parent", "child"])
        XCTAssertThrowsError(try second.commit(operationID: UUID(), origin: "stale-import", mutations: [.grant(parent)]))
        XCTAssertThrowsError(try second.commit(operationID: UUID(), origin: "late-child", mutations: [.grant(.init(kind: .scope, id: "late", parentID: "parent", payload: Data()))]))
        let tombstones = (0 ..< 1050).map { OverseerContinuityMutation.revokeScope("old-\($0)") }
        _ = try first.commit(operationID: UUID(), origin: "terminal-history", mutations: tombstones)
        XCTAssertEqual(try second.rows(kind: .scope).filter(\.terminal).count, 1052)
        XCTAssertEqual(try second.rows(kind: .scope).filter { !$0.terminal }.map(\.id), ["other"])
    }

    func testOverseerConcurrentFirstOpenSerializesSchemaAndIndependentRows() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OverseerConcurrent-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("private/state.sqlite")
        let operationIDs = (0 ..< 12).map { _ in UUID() }
        // Every handle shares one bounded process-local admission. A contender that loses that bound
        // while a durable holder is slow gets the documented retryable `writerBusy`; any other error
        // (schema, profile, SQLite, transition) fails the test from inside the group.
        let outcomes = try await withThrowingTaskGroup(of: (Int, OverseerContinuityReceipt?).self) { group in
            for (index, operationID) in operationIDs.enumerated() {
                group.addTask {
                    let store = OverseerContinuityStore(databaseURL: url, profile: "test")
                    do {
                        return try (index, store.commit(operationID: operationID, origin: "parallel-owner", mutations: [Self.parallelGrant(index)]))
                    } catch OverseerContinuityError.writerBusy {
                        return (index, nil)
                    }
                }
            }
            var outcomes: [Int: OverseerContinuityReceipt?] = [:]
            for try await (index, receipt) in group {
                outcomes[index] = receipt
            }
            return outcomes
        }
        // Every contended operation has settled; the remaining checks are uncontended.
        XCTAssertEqual(outcomes.count, 12)
        XCTAssertTrue(outcomes.values.contains { $0 != nil }, "The first opener must create the schema and commit")
        let store = OverseerContinuityStore(databaseURL: url, profile: "test")
        for (index, operationID) in operationIDs.enumerated() {
            if let committed = outcomes[index] ?? nil {
                XCTAssertFalse(committed.replayed)
                XCTAssertEqual(try store.receipt(operationID: operationID), committed)
                var replay = committed
                replay.replayed = true
                XCTAssertEqual(
                    try store.commit(operationID: operationID, origin: "parallel-owner", mutations: [Self.parallelGrant(index)]),
                    replay, "A committed operation replays its exact receipt"
                )
            } else {
                XCTAssertNil(try store.receipt(operationID: operationID), "A bounded busy failure must not leave a receipt")
                let recovered = try store.commit(operationID: operationID, origin: "parallel-owner", mutations: [Self.parallelGrant(index)])
                XCTAssertFalse(recovered.replayed, "The uncontended retry of a busy operation is its first commit")
                XCTAssertEqual(try store.receipt(operationID: operationID), recovered)
            }
        }
        let rows = try store.rows(kind: .scope)
        XCTAssertEqual(rows.map(\.id).sorted(), (0 ..< 12).map { "row-\($0)" }.sorted())
        XCTAssertTrue(rows.allSatisfy { !$0.terminal })
        XCTAssertEqual(try store.engineSettings(), ["journal_mode": "delete", "synchronous": "3", "fullfsync": "1", "foreign_keys": "1"])
        let schema = try Self.overseerSchemaState(url)
        XCTAssertEqual(schema.userVersion, 1)
        XCTAssertEqual(schema.profiles, 1, "Concurrent first opens create exactly one profile row")
        XCTAssertEqual(schema.operations, 12, "Each operation is recorded once; replays and busy failures add none")
        _ = try store.rows(kind: .scope)
        XCTAssertEqual(try Self.overseerSchemaState(url).epoch, schema.epoch, "A reopen must not reinitialize the schema")
        for error in [OverseerContinuityError.terminalIdentity, .revisionConflict, .operationConflict] {
            XCTAssertTrue(error.isPermanentTransitionFailure)
        }
        XCTAssertFalse(OverseerContinuityError.writerBusy.isPermanentTransitionFailure)
    }

    #if DEBUG
        func testOverseerAccessHeldPastBudgetFailsRetryablyWithoutReceiptThenCommitsOnce() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("OverseerHeldAccess-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let url = root.appendingPathComponent("private/state.sqlite")
            let holderStore = OverseerContinuityStore(databaseURL: url, profile: "test")
            _ = try holderStore.engineSettings()
            let acquired = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            let finished = DispatchSemaphore(value: 0)
            let holderFailure = HolderFailure()
            // A dedicated thread holds the real access ordering, as a slow durable holder would. Its own
            // wait is bounded, and every exit path below releases and joins it.
            let holder = Thread {
                defer { finished.signal() }
                do {
                    try holderStore.withAccessHeldForTesting {
                        acquired.signal()
                        _ = release.wait(timeout: .now() + 30)
                    }
                } catch {
                    holderFailure.error = error
                }
            }
            holder.start()
            var joined = false
            func releaseAndJoin() {
                guard !joined else { return }
                joined = true
                release.signal()
                XCTAssertEqual(finished.wait(timeout: .now() + 30), .success, "The access holder must exit")
            }
            defer { releaseAndJoin() }
            XCTAssertEqual(acquired.wait(timeout: .now() + 30), .success, "The holder must acquire uncontended access")

            let contender = OverseerContinuityStore(databaseURL: url, profile: "test")
            let operationID = UUID()
            let mutation = OverseerContinuityMutation.grant(.init(kind: .scope, id: "live", payload: Data()))
            XCTAssertThrowsError(try contender.commit(operationID: operationID, origin: "user", mutations: [mutation])) { error in
                XCTAssertEqual(error as? OverseerContinuityError, .writerBusy)
            }

            releaseAndJoin()
            XCTAssertNil(holderFailure.error)
            XCTAssertNil(try contender.receipt(operationID: operationID), "A bounded busy failure must not leave a receipt")
            XCTAssertEqual(try contender.rows(kind: .scope), [])
            let receipt = try contender.commit(operationID: operationID, origin: "user", mutations: [mutation])
            XCTAssertFalse(receipt.replayed)
            XCTAssertEqual(try holderStore.receipt(operationID: operationID), receipt)
            var replay = receipt
            replay.replayed = true
            XCTAssertEqual(try holderStore.commit(operationID: operationID, origin: "user", mutations: [mutation]), replay)
            XCTAssertEqual(try holderStore.rows(kind: .scope).map(\.id), ["live"])
        }
    #endif

    private final class HolderFailure: @unchecked Sendable {
        var error: Error?
    }

    private static func parallelGrant(_ index: Int) -> OverseerContinuityMutation {
        .grant(.init(kind: .scope, id: "row-\(index)", payload: Data()))
    }

    private static func overseerSchemaState(_ url: URL) throws -> (userVersion: Int64?, profiles: Int64?, operations: Int64?, epoch: String?) {
        let db = try SessionCatalogDatabase(url: url, readOnly: true)
        return try (
            db.integer("PRAGMA user_version"),
            db.integer("SELECT count(*) FROM profile_state"),
            db.integer("SELECT count(*) FROM operations"),
            db.rows("SELECT epoch FROM profile_state WHERE singleton=1") { try SessionCatalogDatabase.string($0) }.first
        )
    }

    func testOverseerBusyFailureIsRetryableAndHasNoFalseReceipt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OverseerBusy-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("private/state.sqlite")
        let store = OverseerContinuityStore(databaseURL: url, profile: "test")
        _ = try store.engineSettings()
        let child = Process(), ready = Pipe(), release = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-c", "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute('BEGIN IMMEDIATE'); print('locked',flush=True); sys.stdin.readline(); c.rollback()", url.path]
        child.standardOutput = ready
        child.standardInput = release
        try child.run()
        defer { if child.isRunning { child.terminate()
            child.waitUntilExit()
        } }
        XCTAssertEqual(String(data: ready.fileHandleForReading.availableData, encoding: .utf8), "locked\n")
        let operation = UUID(), mutation = OverseerContinuityMutation.grant(.init(kind: .scope, id: "live", payload: Data()))
        XCTAssertThrowsError(try store.commit(operationID: operation, origin: "user", mutations: [mutation]))
        XCTAssertNil(try store.receipt(operationID: operation), "No committed receipt may be invented on busy failure")
        release.fileHandleForWriting.write(Data("release\n".utf8))
        child.waitUntilExit()
        let receipt = try store.commit(operationID: operation, origin: "user", mutations: [mutation])
        XCTAssertEqual(try store.receipt(operationID: operation), receipt)
        XCTAssertEqual(try store.rows(kind: .scope).map(\.id), ["live"])
    }

    func testOverseerMigrationRetainsBytesRejectedRowsAndDestinationWins() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OverseerImport-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OverseerContinuityStore(databaseURL: root.appendingPathComponent("private/state.sqlite"), profile: "test")
        let bytes = Data("original mixed source including an undecodable row".utf8)
        let source = OverseerLegacySource(id: "source", path: "/read-only/source.json", digest: OverseerContinuityStore.digest(bytes), bytes: bytes, reason: "user_review_required")
        let grant = OverseerContinuityRow(kind: .scope, id: "already-revoked", payload: Data("old permission".utf8))
        try store.archive(source, rows: [.init(ordinal: 0, raw: bytes, mutation: .grant(grant), outcome: "review"), .init(ordinal: 1, raw: Data("invalid".utf8), mutation: nil, outcome: "rejected_unknown_capability")])
        _ = try store.commit(operationID: UUID(), origin: "user", mutations: [.revokeScope(grant.id)])
        let receipt = try store.activateLegacy(sourceID: source.id, operationID: UUID(), origin: "explicit-recovery")
        XCTAssertTrue(receipt.affectedIDs.isEmpty)
        XCTAssertEqual(try store.legacySources(), [source])
        XCTAssertTrue(try store.rows(kind: .scope).first?.terminal == true)
        XCTAssertThrowsError(try OverseerContinuityStore(databaseURL: store.databaseURL, profile: "another-profile").rows(kind: .scope))
    }

    func testOverseerDeletedAnchorsFenceLateImportsAndFutureDatabaseRemainsUntouched() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OverseerDeletion-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("private/state.sqlite")
        let store = OverseerContinuityStore(databaseURL: url, profile: "test")
        _ = try store.commit(operationID: UUID(), origin: "user-deletion", mutations: [.deletedSession("gone")])
        XCTAssertThrowsError(try store.commit(operationID: UUID(), origin: "late-import", mutations: [
            .grant(.init(kind: .scope, id: "unknown-saved-grant", ownerID: "gone", payload: Data()))
        ]))
        XCTAssertThrowsError(try store.commit(operationID: UUID(), origin: "late-link", mutations: [
            .put(.init(kind: .link, id: "pair", ownerID: "gone", anchorID: "target", payload: Data()), expectedRevision: nil)
        ]))
        do { let db = try SessionCatalogDatabase(url: url)
            try db.execute("PRAGMA user_version=999")
        }
        let before = try Data(contentsOf: url)
        XCTAssertThrowsError(try store.engineSettings())
        XCTAssertEqual(try Data(contentsOf: url), before, "An unknown database must never be reset, migrated or rewritten")
    }

    func testOverseerRollbackJournalRecoversAfterAnotherProcessDiesMidTransaction() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OverseerCrash-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("private/state.sqlite")
        let store = OverseerContinuityStore(databaseURL: url, profile: "test")
        let operation = UUID()
        _ = try store.commit(operationID: operation, origin: "user", mutations: [.grant(.init(kind: .scope, id: "kept", payload: Data()))])
        let child = Process(), ready = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-c", """
        import sqlite3,sys,time
        c=sqlite3.connect(sys.argv[1])
        c.execute('PRAGMA cache_size=10')
        c.execute('BEGIN IMMEDIATE')
        c.execute("UPDATE continuity_rows SET terminal=1 WHERE id='kept'")
        for i in range(128):
            c.execute("INSERT INTO continuity_rows(kind,id,capabilities,payload,terminal,revision) VALUES ('worktree',?,'[]',zeroblob(65536),0,99)", ('uncommitted-'+str(i),))
        print('spilled',flush=True)
        time.sleep(60)
        """, url.path]
        child.standardOutput = ready
        try child.run()
        defer { if child.isRunning { child.terminate()
            child.waitUntilExit()
        } }
        XCTAssertEqual(String(data: ready.fileHandleForReading.availableData, encoding: .utf8), "spilled\n")
        // SIGKILL is deliberately confined to this test-owned child and temporary SQLite file.
        XCTAssertEqual(kill(child.processIdentifier, SIGKILL), 0)
        child.waitUntilExit()
        XCTAssertFalse(try XCTUnwrap(store.rows(kind: .scope).first).terminal, "The interrupted revoke was never committed")
        XCTAssertTrue(try store.rows(kind: .worktree).isEmpty, "Cache-spilled uncommitted rows must roll back")
        XCTAssertNotNil(try store.receipt(operationID: operation), "Earlier committed continuity survives without a clean exit")
        _ = try store.commit(operationID: UUID(), origin: "user", mutations: [.revokeScope("kept")])
        XCTAssertTrue(try XCTUnwrap(OverseerContinuityStore(databaseURL: url, profile: "test").rows(kind: .scope).first).terminal)
    }

    private func fixture() throws -> (URL, URL, SessionCatalogStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SessionCatalogTests-\(UUID().uuidString)", isDirectory: true)
        let databaseURL = root.appendingPathComponent("catalog.sqlite")
        return try (root, databaseURL, SessionCatalogStore(databaseURL: databaseURL))
    }

    private func workspace(_ root: URL, name: String = "Target") -> SessionCatalogWorkspace {
        SessionCatalogWorkspace(id: UUID(), name: name, directory: root.appendingPathComponent(name), coverage: .complete)
    }

    private func session(_ workspaceID: UUID, parent: UUID? = nil, time: Double = 1) -> SessionCatalogRecord {
        let id = UUID()
        return SessionCatalogRecord(
            id: id, workspaceID: workspaceID, filename: "AgentSession-\(id.uuidString).json",
            name: "Session", activityAt: Date(timeIntervalSinceReferenceDate: time), parentID: parent,
            metadata: Data("owner metadata".utf8)
        )
    }

    func testParentAliasIsAllowedButDatabaseSymlinkIsRejected() async throws {
        let (root, databaseURL, catalog) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let alias = root.appendingPathComponent("alias.sqlite")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: databaseURL)
        do {
            _ = try SessionCatalogStore(databaseURL: alias)
            XCTFail("Canonicalizing the parent must not follow the final database symlink")
        } catch {
            guard let catalogError = error as? SessionCatalogError, case .database = catalogError else {
                return XCTFail("Expected a SQLite no-follow failure, got \(error)")
            }
        }
        let generation = try await catalog.currentGeneration()
        XCTAssertEqual(generation, 0)
    }

    private enum OwnerTestError: Error { case revoked, incoherentSnapshot }

    @MainActor
    func testOwnerCommitRevalidatesEvenForReplayAndDenialChangesNothing() async throws {
        let (root, _, catalog) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = workspace(root)
        let record = session(workspace.id)
        let mutations: [SessionCatalogMutation] = [.workspace(workspace, expected: .absent), .session(record, expected: .absent)]
        let operationID = UUID()
        var live = true
        var checks = 0
        let revalidate: @MainActor () throws -> Void = {
            checks += 1
            guard live else { throw OwnerTestError.revoked }
        }
        let first = try catalog.commitFromOwner(operationID: operationID, mutations: mutations, revalidate: revalidate)
        live = false
        do {
            _ = try catalog.commitFromOwner(operationID: operationID, mutations: mutations, revalidate: revalidate)
            XCTFail("A persisted replay receipt cannot replace live owner authorization")
        } catch {
            guard case OwnerTestError.revoked = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(checks, 2)
        let unchanged = try await catalog.session(id: record.id)
        let generation = try await catalog.currentGeneration()
        XCTAssertEqual(unchanged?.revision, first.generation)
        XCTAssertEqual(generation, first.generation)
    }

    @MainActor
    func testOwnerPointWritesStayConstantAndReaderSnapshotsRemainCoherent() async throws {
        let (root, _, catalog) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = workspace(root)
        var target = session(workspace.id)
        let targetID = target.id
        let others = (0 ..< 249).map { session(workspace.id, time: Double($0)) }
        _ = try await catalog.commit(operationID: UUID(), mutations: [
            .workspace(workspace, expected: .absent), .session(target, expected: .absent)
        ] + others.map { .session($0, expected: .absent) })
        await catalog.resetWriteCounters()
        let snapshots = Task.detached(priority: .utility) {
            for _ in 0 ..< 25 {
                let page = try await catalog.sessions(workspaceID: workspace.id, limit: 1000)
                guard page.totalKnown == 250, page.records.count == 250,
                      page.records.first(where: { $0.id == targetID })?.revision == page.generation
                else { throw OwnerTestError.incoherentSnapshot }
            }
        }
        var checks = 0
        for index in 0 ..< 100 {
            target.name = "Renamed-\(index)"
            _ = try catalog.commitFromOwner(
                operationID: UUID(), mutations: [.session(target, expected: .revision(Int64(index + 1)))],
                revalidate: { checks += 1 }
            )
        }
        try await snapshots.value
        let counters = await catalog.writeCounters()
        let renamed = try await catalog.session(id: targetID)
        XCTAssertEqual(checks, 100)
        XCTAssertEqual(renamed?.name, "Renamed-99")
        XCTAssertEqual(renamed?.revision, 101)
        // Eleven indexed statements and at most four rows per write, regardless of the other 249
        // sessions. Concurrent reader work is on a separate read-only connection, not this lock.
        XCTAssertLessThanOrEqual(counters.statements, 100 * 11)
        XCTAssertLessThanOrEqual(counters.returnedRows, 100 * 4)
    }

    func testDurableTransactionReplayAndConflict() async throws {
        let (root, databaseURL, catalog) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = workspace(root)
        let session = session(workspace.id)
        let mutations: [SessionCatalogMutation] = [.workspace(workspace, expected: .absent), .session(session, expected: .absent)]
        let operationID = UUID()
        let committed = try await catalog.commit(operationID: operationID, mutations: mutations)
        let replay = try await catalog.commit(operationID: operationID, mutations: mutations)
        XCTAssertEqual(committed, SessionCatalogCommit(generation: 1, replayed: false))
        XCTAssertEqual(replay, SessionCatalogCommit(generation: 1, replayed: true))
        let reopened = try SessionCatalogStore(databaseURL: databaseURL)
        let reopenedReplay = try await reopened.commit(operationID: operationID, mutations: mutations)
        XCTAssertEqual(reopenedReplay, replay)
        let restored = try await reopened.session(id: session.id)
        XCTAssertEqual(restored?.revision, 1)
        XCTAssertEqual(restored?.metadata, session.metadata)
        do {
            _ = try await catalog.commit(operationID: operationID, mutations: [])
            XCTFail("An operation ID cannot authorize a different transaction")
        } catch { XCTAssertEqual(error as? SessionCatalogError, .operationConflict) }
    }

    func testFailureRollsBackRowsCountsAndGeneration() async throws {
        let (root, _, catalog) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = workspace(root)
        let invalid = session(UUID())
        do {
            _ = try await catalog.commit(
                operationID: UUID(), mutations: [.workspace(workspace, expected: .absent), .session(invalid, expected: .absent)]
            )
            XCTFail("Missing workspace foreign key must fail")
        } catch { XCTAssertEqual(error as? SessionCatalogError, .unknownWorkspace) }
        let workspaceAfter = try await catalog.workspace(id: workspace.id)
        let generation = try await catalog.currentGeneration()
        let page = try await catalog.sessions()
        XCTAssertNil(workspaceAfter)
        XCTAssertEqual(generation, 0)
        XCTAssertEqual(page.totalKnown, 0)
        XCTAssertFalse(page.authoritativeEmpty)
    }

    func testMoveUpdatesMaintainedCountsAndAncestry() async throws {
        let (root, _, catalog) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = workspace(root)
        let destination = workspace(root, name: "Destination")
        let parent = session(destination.id)
        var child = session(source.id)
        _ = try await catalog.commit(operationID: UUID(), mutations: [
            .workspace(source, expected: .absent), .workspace(destination, expected: .absent),
            .session(parent, expected: .absent), .session(child, expected: .absent),
            .coverage(workspaceID: source.id, state: .complete), .coverage(workspaceID: destination.id, state: .complete)
        ])
        child.workspaceID = destination.id
        child.organizationalParentID = parent.id
        _ = try await catalog.commit(operationID: UUID(), mutations: [.session(child, expected: .revision(1))])
        let old = try await catalog.sessions(workspaceID: source.id)
        let new = try await catalog.sessions(workspaceID: destination.id)
        let all = try await catalog.sessions()
        let children = try await catalog.children(of: parent.id)
        XCTAssertTrue(old.authoritativeEmpty)
        XCTAssertEqual(new.totalKnown, 2)
        XCTAssertEqual(all.totalKnown, 2)
        XCTAssertEqual(children.map(\.id), [child.id])
        do {
            _ = try await catalog.commit(operationID: UUID(), mutations: [.session(child, expected: .revision(1))])
            XCTFail("Stale reconciliation must not overwrite a moved row")
        } catch { XCTAssertEqual(error as? SessionCatalogError, .revisionConflict) }
    }

    func testDeletionTombstoneSurvivesRestartAndBlocksReimport() async throws {
        let (root, databaseURL, catalog) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = workspace(root)
        let session = session(workspace.id)
        _ = try await catalog.commit(operationID: UUID(), mutations: [.workspace(workspace, expected: .absent), .session(session, expected: .absent)])
        _ = try await catalog.commit(operationID: UUID(), mutations: [.deleteWorkspace(workspace.id, expected: .revision(1))])
        let reopened = try SessionCatalogStore(databaseURL: databaseURL)
        do {
            _ = try await reopened.commit(operationID: UUID(), mutations: [.session(session, expected: .absent)])
            XCTFail("Legacy/import files must not resurrect a deleted identity")
        } catch { XCTAssertEqual(error as? SessionCatalogError, .deletedIdentity) }
        let rows = try await reopened.sessions()
        XCTAssertEqual(rows.totalKnown, 0)
        XCTAssertFalse(rows.authoritativeEmpty)
    }

    func testIncompleteEmptyAndPerWorkspaceReadinessAreDistinct() async throws {
        let (root, _, catalog) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = workspace(root)
        _ = try await catalog.commit(operationID: UUID(), mutations: [.workspace(workspace, expected: .absent), .coverage(workspaceID: workspace.id, state: .complete)])
        let scoped = try await catalog.sessions(workspaceID: workspace.id)
        let global = try await catalog.sessions()
        XCTAssertTrue(scoped.authoritativeEmpty)
        XCTAssertFalse(global.authoritativeEmpty)
        _ = try await catalog.commit(operationID: UUID(), mutations: [.coverage(workspaceID: nil, state: .complete)])
        let complete = try await catalog.sessions()
        XCTAssertTrue(complete.authoritativeEmpty)
        _ = try await catalog.commit(operationID: UUID(), mutations: [.coverage(workspaceID: workspace.id, state: .degraded)])
        let degraded = try await catalog.sessions(workspaceID: workspace.id)
        XCTAssertFalse(degraded.authoritativeEmpty)
    }

    func testCatalogIsPrivateAndWorkspaceRegistrationCannotClaimCompleteness() async throws {
        let (root, databaseURL, catalog) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let mode = try FileManager.default.attributesOfItem(atPath: databaseURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        _ = try await catalog.commit(operationID: UUID(), mutations: [.coverage(workspaceID: nil, state: .complete)])
        let workspace = workspace(root)
        _ = try await catalog.commit(operationID: UUID(), mutations: [.workspace(workspace, expected: .absent)])
        let page = try await catalog.sessions(workspaceID: workspace.id)
        let global = try await catalog.sessions()
        XCTAssertEqual(page.coverage, .pending)
        XCTAssertEqual(global.coverage, .pending)
        XCTAssertFalse(page.authoritativeEmpty)
        XCTAssertFalse(global.authoritativeEmpty)
    }

    func testResumableProgressAndClassificationsAreGenerationFenced() async throws {
        let (root, databaseURL, catalog) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let progress = SessionCatalogReconciliation(generation: 1, phase: "classification", cursor: "page:7", processed: 5001)
        try await catalog.saveReconciliation(progress, expectedGeneration: nil)
        try await catalog.classify(path: "junk", signature: "stable", classification: "not_a_workspace", reconciliationGeneration: 1)
        let reopened = try SessionCatalogStore(databaseURL: databaseURL)
        let resumed = try await reopened.reconciliation()
        let classification = try await reopened.classification(path: "junk", signature: "stable")
        XCTAssertEqual(resumed, progress)
        XCTAssertEqual(classification, "not_a_workspace")
        do {
            try await reopened.saveReconciliation(.init(generation: 1, phase: "classification", processed: 1), expectedGeneration: 1)
            XCTFail("A stale worker cannot rewind progress")
        } catch { XCTAssertEqual(error as? SessionCatalogError, .staleGeneration) }
    }

    func testPointReadsDoNotDependOnDecoyDirectoriesOrUnrelatedRows() async throws {
        let (root, databaseURL, catalog) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = workspace(root)
        let other = workspace(root, name: "Other")
        let wanted = session(target.id)
        var mutations: [SessionCatalogMutation] = [.workspace(target, expected: .absent), .workspace(other, expected: .absent), .session(wanted, expected: .absent)]
        for index in 0 ..< 250 {
            mutations.append(.session(session(other.id, time: Double(index)), expected: .absent))
        }
        _ = try await catalog.commit(operationID: UUID(), mutations: mutations)
        // No fake directory provider: keep >5,000 actual sibling directories on disk.
        for index in 0 ..< 5001 {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("decoy-\(index)"), withIntermediateDirectories: false)
        }
        let reopened = try SessionCatalogStore(databaseURL: databaseURL)
        await reopened.resetReadCounters()
        let found = try await reopened.session(id: wanted.id)
        let named = try await reopened.workspaces(named: target.name)
        let scoped = try await reopened.sessions(workspaceID: target.id)
        let counters = await reopened.readCounters()
        XCTAssertEqual(found?.id, wanted.id)
        XCTAssertEqual(named.map(\.id), [target.id])
        XCTAssertEqual(scoped.records.map(\.id), [wanted.id])
        XCTAssertEqual(scoped.totalKnown, 1)
        XCTAssertLessThanOrEqual(counters.returnedRows, 7)
        XCTAssertLessThanOrEqual(counters.statements, 7)
    }

    func testKeysetPaginationIsCompleteAndRejectsMovedGeneration() async throws {
        let (root, _, catalog) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = workspace(root)
        let records = (0 ..< 7).map { session(workspace.id, time: Double($0)) }
        _ = try await catalog.commit(operationID: UUID(), mutations: [.workspace(workspace, expected: .absent)] + records.map { .session($0, expected: .absent) })
        var seen: [UUID] = []
        var cursor: SessionCatalogCursor?
        repeat {
            let page = try await catalog.sessions(limit: 2, after: cursor)
            XCTAssertEqual(page.totalKnown, 7)
            seen += page.records.map(\.id)
            cursor = page.nextCursor
        } while cursor != nil
        XCTAssertEqual(seen, records.reversed().map(\.id))
        let first = try await catalog.sessions(limit: 1)
        _ = try await catalog.commit(operationID: UUID(), mutations: [.coverage(workspaceID: workspace.id, state: .complete)])
        do {
            _ = try await catalog.sessions(limit: 1, after: first.nextCursor)
            XCTFail("An old page cursor must not silently mix catalog generations")
        } catch { XCTAssertEqual(error as? SessionCatalogError, .staleGeneration) }
    }

    func testUnknownWorkspaceNeverInheritsGlobalCompleteness() async throws {
        let (root, _, catalog) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await catalog.commit(operationID: UUID(), mutations: [.coverage(workspaceID: nil, state: .complete)])
        let unknown = try await catalog.sessions(workspaceID: UUID())
        XCTAssertEqual(unknown.coverage, .pending)
        XCTAssertFalse(unknown.authoritativeEmpty)
    }

    func testCoverageCannotClobberOwnerRevisionOrBeClobberedByOwnerWrite() async throws {
        let (root, _, catalog) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var workspace = workspace(root)
        _ = try await catalog.commit(operationID: UUID(), mutations: [.workspace(workspace, expected: .absent), .coverage(workspaceID: workspace.id, state: .complete)])
        _ = try await catalog.commit(operationID: UUID(), mutations: [.coverage(workspaceID: nil, state: .complete)])
        _ = try await catalog.commit(operationID: UUID(), mutations: [.coverage(workspaceID: workspace.id, state: .degraded)])
        let degraded = try await catalog.workspace(id: workspace.id)
        XCTAssertEqual(degraded?.revision, 1)
        workspace.name = "Renamed"
        _ = try await catalog.commit(operationID: UUID(), mutations: [.workspace(workspace, expected: .revision(1))])
        let renamed = try await catalog.workspace(id: workspace.id)
        let global = try await catalog.sessions()
        XCTAssertEqual(renamed?.coverage, .degraded)
        XCTAssertFalse(global.authoritativeEmpty)
        do {
            _ = try await catalog.commit(operationID: UUID(), mutations: [.coverage(workspaceID: nil, state: .complete)])
            XCTFail("Global readiness cannot hide a degraded workspace")
        } catch { XCTAssertEqual(error as? SessionCatalogError, .invalidRecord) }
    }

    func testClassificationDoesNotInvalidateCursorAndScopeMismatchFailsClosed() async throws {
        let (root, _, catalog) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = workspace(root)
        _ = try await catalog.commit(operationID: UUID(), mutations: [
            .workspace(workspace, expected: .absent),
            .session(session(workspace.id, time: 1), expected: .absent),
            .session(session(workspace.id, time: 2), expected: .absent)
        ])
        let first = try await catalog.sessions(workspaceID: workspace.id, limit: 1)
        try await catalog.classify(path: "junk", signature: "one", classification: "not_a_workspace", reconciliationGeneration: 1)
        let next = try await catalog.sessions(workspaceID: workspace.id, limit: 1, after: first.nextCursor)
        XCTAssertEqual(next.generation, first.generation)
        XCTAssertEqual(next.records.count, 1)
        do {
            _ = try await catalog.sessions(limit: 1, after: first.nextCursor)
            XCTFail("Workspace cursors cannot page a different scope")
        } catch { XCTAssertEqual(error as? SessionCatalogError, .invalidRecord) }
    }

    func testSelfParentAndOversizedMetadataAreRejected() async throws {
        let (root, _, catalog) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = workspace(root)
        _ = try await catalog.commit(operationID: UUID(), mutations: [.workspace(workspace, expected: .absent)])
        var record = session(workspace.id)
        record.parentID = record.id
        do {
            _ = try await catalog.commit(operationID: UUID(), mutations: [.session(record, expected: .absent)])
            XCTFail("Self-parent must not become a discoverable cycle")
        } catch { XCTAssertEqual(error as? SessionCatalogError, .invalidRecord) }
        record.parentID = nil
        record.metadata = Data(repeating: 0, count: 65537)
        do {
            _ = try await catalog.commit(operationID: UUID(), mutations: [.session(record, expected: .absent)])
            XCTFail("Discovery metadata must have a bounded per-row footprint")
        } catch { XCTAssertEqual(error as? SessionCatalogError, .invalidRecord) }
    }

    func testFutureSchemaIsNotReset() throws {
        let (root, databaseURL, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try SessionCatalogDatabase(url: databaseURL)
        try database.execute("PRAGMA user_version = 900")
        XCTAssertThrowsError(try SessionCatalogStore(databaseURL: databaseURL)) { error in
            XCTAssertEqual(error as? SessionCatalogError, .futureSchema(900))
        }
        XCTAssertEqual(try database.integer("PRAGMA user_version"), 900)
    }
}
