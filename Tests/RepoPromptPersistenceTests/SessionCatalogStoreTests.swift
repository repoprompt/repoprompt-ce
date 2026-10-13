import Foundation
@testable import RepoPromptPersistence
import XCTest

final class SessionCatalogStoreTests: XCTestCase {
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
