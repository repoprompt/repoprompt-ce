import Foundation
@testable import RepoPromptDomainRuntime
import XCTest

/// Pure inventory, orphan, ordering, and ledger rules behind `session_admin` organizing ops.
final class DomainAgentSessionInventoryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func record(
        _ id: UUID,
        parent: UUID? = nil,
        creator: UUID? = nil,
        workspace: UUID? = nil,
        archived: Bool = false,
        pinned: Bool = false,
        group: String? = nil,
        state: DomainAgentSessionInventoryRunState = .idle,
        createdAt: Date? = nil,
        idleDays: Double = 0,
        loaded: Bool = true
    ) -> DomainAgentSessionInventoryRecord {
        DomainAgentSessionInventoryRecord(
            sessionID: id, name: "S-\(id.uuidString.prefix(4))", workspaceID: workspace, isLoaded: loaded,
            isArchived: archived, isPinned: pinned, sidebarGroup: group, runState: state,
            parentSessionID: parent, createdByOverseerSessionID: creator, createdAt: createdAt,
            lastActivityAt: now.addingTimeInterval(-idleDays * 86400)
        )
    }

    // MARK: - Orphans

    func testOrphanReasonsCoverMissingIntentEndpointArchivedObserverParentAndCreator() {
        let root = UUID()
        let archivedObserver = UUID()
        let target = UUID()
        let ghost = UUID()
        let child = UUID()
        let lane = UUID()
        let edges = DomainAgentSessionInventoryEdge.merge(
            live: [(archivedObserver, target, UUID(), 1)],
            persisted: [(ghost, root)]
        )
        let snapshot = DomainAgentSessionInventorySnapshot(
            records: [
                record(root),
                record(archivedObserver, archived: true),
                record(target),
                record(child, parent: ghost),
                record(lane, creator: ghost)
            ],
            edges: edges,
            isComplete: true
        )
        XCTAssertEqual(snapshot.orphanReasons(for: root), [.linkIntentMissingSession, .observerArchivedOrDeleted])
        XCTAssertEqual(snapshot.orphanReasons(for: target), [.observerArchivedOrDeleted])
        XCTAssertEqual(snapshot.orphanReasons(for: child), [.parentMissing])
        XCTAssertEqual(snapshot.orphanReasons(for: lane), [.laneCreatorMissing])
        XCTAssertEqual(snapshot.orphanReasons(for: archivedObserver), [], "an archived observer itself is not orphaned")

        // An incomplete history scan cannot tell "deleted" from "not scanned".
        let partial = DomainAgentSessionInventorySnapshot(records: Array(snapshot.records.values), edges: edges, isComplete: false)
        XCTAssertEqual(partial.orphanReasons(for: child), [])
        XCTAssertEqual(partial.orphanReasons(for: root), [], "missing-session reasons need a complete scan")
        XCTAssertEqual(partial.orphanReasons(for: target), [.observerArchivedOrDeleted], "archival is a positive fact")
    }

    func testEdgeMergeUnifiesLiveLinksAndPersistedIntents() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let linkID = UUID()
        let edges = DomainAgentSessionInventoryEdge.merge(live: [(a, b, linkID, 7)], persisted: [(a, b), (a, c)])
        XCTAssertEqual(edges.count, 2)
        let ab = try? XCTUnwrap(edges.first { $0.targetSessionID == b })
        XCTAssertEqual(ab?.isLive, true)
        XCTAssertEqual(ab?.isPersisted, true)
        XCTAssertEqual(ab?.linkID, linkID)
        XCTAssertEqual(edges.first { $0.targetSessionID == c }?.isLive, false)
    }

    // MARK: - Filters

    func testStructuredFiltersMatchEveryDimension() {
        let workspace = UUID()
        let root = UUID()
        let child = UUID()
        let stranger = UUID()
        let snapshot = DomainAgentSessionInventorySnapshot(
            records: [
                record(
                    root,
                    workspace: workspace,
                    pinned: true,
                    group: "Lanes",
                    state: .running,
                    createdAt: now.addingTimeInterval(-10 * 86400),
                    idleDays: 1
                ),
                record(
                    child,
                    parent: root,
                    workspace: workspace,
                    archived: true,
                    state: .waiting,
                    createdAt: now.addingTimeInterval(-2 * 86400),
                    idleDays: 9
                ),
                record(stranger, workspace: UUID(), state: .completed, idleDays: 30, loaded: false)
            ],
            edges: DomainAgentSessionInventoryEdge.merge(live: [(root, child, UUID(), 1)], persisted: []),
            isComplete: true
        )
        func matching(_ filter: DomainAgentSessionInventoryFilter) -> Set<UUID> {
            Set(snapshot.records.values.filter { filter.matchesStructured($0, in: snapshot, now: now) }.map(\.sessionID))
        }
        XCTAssertEqual(matching(.init(workspaceID: workspace)), [root, child])
        XCTAssertEqual(matching(.init(rootOverseerSessionID: root)), [root, child])
        XCTAssertEqual(matching(.init(states: DomainAgentSessionInventoryRunState.parseFilter("active"))), [root, child])
        XCTAssertEqual(matching(.init(pinned: true)), [root])
        XCTAssertEqual(matching(.init(group: .named("lanes"))), [root], "group match is case-insensitive")
        XCTAssertEqual(matching(.init(group: DomainAgentSessionInventoryFilter.GroupMatch.none)), [child, stranger])
        XCTAssertEqual(matching(.init(idleDaysGreaterThan: 8)), [child, stranger])
        XCTAssertEqual(matching(.init(createdBefore: now.addingTimeInterval(-5 * 86400))), [root])
        XCTAssertEqual(
            matching(.init(createdAfter: now.addingTimeInterval(-5 * 86400))),
            [child],
            "a record with no creation date never matches a creation bound"
        )
        XCTAssertEqual(matching(.init(hasLinks: false)), [stranger])
        XCTAssertEqual(matching(.init(role: .overseer)), [root])
        XCTAssertEqual(matching(.init(role: .overseen)), [child])
        XCTAssertEqual(matching(.init(archived: true)), [child])
        XCTAssertEqual(matching(.init(loaded: false)), [stranger])
        XCTAssertEqual(matching(.init(orphaned: false)), [root, child, stranger])
        XCTAssertNil(DomainAgentSessionInventoryRunState.parseFilter("sleeping"))
        XCTAssertEqual(DomainAgentSessionInventoryRunState.classify(rawValue: "waitingForApproval"), .waiting)
    }

    func testTreeMembershipFollowsOrganizationalThenSpawnThenCreatorAndSurvivesCycles() {
        let root = UUID()
        let viaCreator = UUID()
        let grandchild = UUID()
        let cycleA = UUID()
        let cycleB = UUID()
        let snapshot = DomainAgentSessionInventorySnapshot(
            records: [
                record(root),
                record(viaCreator, creator: root),
                record(grandchild, parent: viaCreator),
                record(cycleA, parent: cycleB),
                record(cycleB, parent: cycleA)
            ],
            edges: [],
            isComplete: true
        )
        XCTAssertTrue(snapshot.isInTree(grandchild, rootSessionID: root))
        XCTAssertTrue(snapshot.isInTree(root, rootSessionID: root))
        XCTAssertFalse(snapshot.isInTree(cycleA, rootSessionID: root))
    }

    // MARK: - Ordering

    func testPermuteReordersOnlyNamedItemsWithinTheirSlots() {
        let ids = (0 ..< 5).map { _ in UUID() }
        let current = ids
        // Reorder items 1 and 3 among themselves; 0, 2, 4 stay put.
        let result = DomainAgentSessionOrdering.permute(
            current: current, expected: [ids[1], ids[3]], desired: [ids[3], ids[1]], describe: \.uuidString
        )
        XCTAssertEqual(try result.get(), [ids[0], ids[3], ids[2], ids[1], ids[4]])
    }

    func testPermuteCASConflictReportsTheCurrentOrder() {
        let ids = (0 ..< 3).map { _ in UUID() }
        let result = DomainAgentSessionOrdering.permute(
            current: ids, expected: [ids[1], ids[0]], desired: [ids[0], ids[1]], describe: \.uuidString
        )
        XCTAssertEqual(result, .failure(.expectedOrderMismatch(current: [ids[0].uuidString, ids[1].uuidString])))
        XCTAssertEqual(
            DomainAgentSessionOrdering.permute(current: ids, expected: [ids[0]], desired: [ids[1]], describe: \.uuidString),
            .failure(.orderSetMismatch)
        )
        XCTAssertEqual(
            DomainAgentSessionOrdering.permute(current: ["a", "b"], expected: ["c"], desired: ["c"], describe: { $0 }),
            .failure(.unknownItem)
        )
        XCTAssertEqual(
            DomainAgentSessionOrdering.permute(current: ["a", "b"], expected: ["a", "a"], desired: ["a", "a"], describe: { $0 }),
            .failure(.orderSetMismatch)
        )
    }

    func testGroupNamesAndOrders() {
        XCTAssertEqual(DomainAgentSessionSidebarGroup.normalizedName("  Lanes "), "Lanes")
        XCTAssertNil(DomainAgentSessionSidebarGroup.normalizedName("   "))
        XCTAssertNil(DomainAgentSessionSidebarGroup.normalizedName("a\nb"))
        XCTAssertNil(DomainAgentSessionSidebarGroup.normalizedName(String(repeating: "x", count: 65)))
        let entries: [(group: String, order: Int?)] = [("B", 1), ("A", 0), ("B", 1), ("C", nil)]
        XCTAssertEqual(DomainAgentSessionSidebarGroup.orderedGroups(entries), ["A", "B", "C"])
        XCTAssertEqual(DomainAgentSessionSidebarGroup.order(for: "B", existing: entries), 1)
        XCTAssertEqual(DomainAgentSessionSidebarGroup.order(for: "New", existing: entries), 2, "max + 1, not a position")
        XCTAssertEqual(DomainAgentSessionSidebarGroup.order(for: "C", existing: entries), 2, "a group with no value gets max + 1")
        XCTAssertEqual(DomainAgentSessionSidebarGroup.order(for: "X", existing: []), 0)
        XCTAssertEqual(DomainAgentSessionSidebarGroup.order(for: "B", existing: [("B", 9), ("A", 3)]), 9)
    }

    func testGroupReorderRedistributesOnlyTheNamedGroupsValues() {
        let entries: [(group: String, order: Int?)] = [("A", 2), ("B", 5), ("C", 7), ("A", 2)]
        XCTAssertEqual(
            DomainAgentSessionSidebarGroup.redistributedOrders(desired: ["C", "A"], entries: entries),
            ["C": 2, "A": 7],
            "C and A swap their own values; B keeps 5"
        )
        // Named groups without distinct values get fresh values after every value in use.
        let legacy: [(group: String, order: Int?)] = [("A", nil), ("B", 5), ("C", nil)]
        XCTAssertEqual(
            DomainAgentSessionSidebarGroup.redistributedOrders(desired: ["C", "A"], entries: legacy),
            ["C": 6, "A": 7]
        )
    }

    func testPinRanksSwapAmongNamedPinsAndMaterializeOnlyWhenNeeded() {
        let a = UUID()
        let x = UUID()
        let b = UUID()
        let swapped = DomainAgentSessionPinRanks.reordered(current: [(a, 0), (x, 4), (b, 9)], desired: [b, a])
        XCTAssertFalse(swapped.materialized)
        XCTAssertEqual(swapped.ranks, [b: 0, x: 4, a: 9], "x keeps its rank; a and b swap theirs")

        let legacy = DomainAgentSessionPinRanks.reordered(current: [(a, nil), (x, nil), (b, 3)], desired: [b, a])
        XCTAssertTrue(legacy.materialized)
        XCTAssertEqual(legacy.ranks, [b: 0, x: 1, a: 2], "materialized in displayed order, so x does not move")
    }

    func testRestrictedSnapshotHidesOutsideSessionsWithoutMarkingThemMissing() {
        let member = UUID()
        let outsider = UUID()
        let ghost = UUID()
        let child = UUID()
        let full = DomainAgentSessionInventorySnapshot(
            records: [record(member), record(outsider), record(child, parent: outsider)],
            edges: DomainAgentSessionInventoryEdge.merge(
                live: [(outsider, member, UUID(), 1)],
                persisted: [(ghost, member)]
            ),
            isComplete: true
        )
        let view = full.restricted(to: [member, child])
        XCTAssertNil(view.records[outsider])
        XCTAssertEqual(view.edges.map(\.observerSessionID), [ghost], "edges to outside sessions are dropped")
        XCTAssertEqual(view.edges(touching: member).count, 1)
        XCTAssertFalse(view.isMissing(outsider), "hidden is not missing")
        XCTAssertTrue(view.isMissing(ghost))
        XCTAssertEqual(view.orphanReasons(for: child), [], "a hidden parent is not a missing parent")
        XCTAssertEqual(view.orphanReasons(for: member), [.linkIntentMissingSession, .observerArchivedOrDeleted])
    }

    // MARK: - Ledgers

    func testIdempotencyLedgerReplaysConflictsAndIsPerGrantee() {
        var ledger = DomainAgentSessionAdministrationIdempotencyLedger<String>(capacity: 2)
        let grantee = UUID()
        XCTAssertEqual(ledger.lookup(granteeSessionID: grantee, idempotencyKey: "k", fingerprint: "f").label, "miss")
        ledger.record(granteeSessionID: grantee, idempotencyKey: "k", fingerprint: "f", result: "r1")
        XCTAssertEqual(ledger.lookup(granteeSessionID: grantee, idempotencyKey: "k", fingerprint: "f").label, "replay:r1")
        XCTAssertEqual(ledger.lookup(granteeSessionID: grantee, idempotencyKey: "k", fingerprint: "g").label, "conflict")
        XCTAssertEqual(ledger.lookup(granteeSessionID: UUID(), idempotencyKey: "k", fingerprint: "g").label, "miss")
        ledger.record(granteeSessionID: grantee, idempotencyKey: "k2", fingerprint: "f", result: "r2")
        ledger.record(granteeSessionID: grantee, idempotencyKey: "k3", fingerprint: "f", result: "r3")
        XCTAssertEqual(ledger.count, 2)
        XCTAssertEqual(ledger.lookup(granteeSessionID: grantee, idempotencyKey: "k", fingerprint: "f").label, "miss", "oldest evicted")
    }

    func testUndoLedgerIsSingleUseGranteeBoundAndExpires() {
        var ledger = DomainAgentSessionAdministrationUndoLedger<Int>(lifetime: 60)
        let grantee = UUID()
        _ = ledger.issue(
            token: "t",
            granteeSessionID: grantee,
            scopeID: UUID(),
            scopeGeneration: 1,
            operation: .adminSetPin,
            targetSessionIDs: [UUID()],
            payload: 1,
            now: now
        )
        guard case .unavailable = ledger.redeem(token: "t", granteeSessionID: UUID(), now: now) else {
            return XCTFail("another grantee cannot redeem")
        }
        guard case let .redeemed(entry) = ledger.redeem(token: "t", granteeSessionID: grantee, now: now) else {
            return XCTFail("the grantee redeems once")
        }
        XCTAssertEqual(entry.payload, 1)
        guard case .unavailable = ledger.redeem(token: "t", granteeSessionID: grantee, now: now) else {
            return XCTFail("tokens are single use")
        }
        _ = ledger.issue(
            token: "late",
            granteeSessionID: grantee,
            scopeID: UUID(),
            scopeGeneration: 1,
            operation: .adminSetPin,
            targetSessionIDs: [],
            payload: 2,
            now: now
        )
        guard case .expired = ledger.redeem(token: "late", granteeSessionID: grantee, now: now.addingTimeInterval(61)) else {
            return XCTFail("tokens expire")
        }
    }
}

private extension DomainAgentSessionAdministrationIdempotencyLedger.Lookup where Result == String {
    var label: String {
        switch self {
        case .miss: "miss"
        case let .replay(value): "replay:\(value)"
        case .conflict: "conflict"
        }
    }
}
