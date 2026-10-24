import Foundation
@testable import RepoPromptDomainRuntime
import XCTest

final class DomainAgentSessionInventoryScalingTests: XCTestCase {
    func testChainAndDenseLinksBuildIndexesOnceAndRestrictedViewRedactsPeers() {
        let ids = (0 ..< 250).map { _ in UUID() }
        let records = ids.enumerated().map { index, id in
            DomainAgentSessionInventoryRecord(sessionID: id, name: "Session", workspaceID: nil, isLoaded: true, runState: .idle, parentSessionID: index == 0 ? nil : ids[index - 1], lastActivityAt: Date(timeIntervalSince1970: 0))
        }
        let pairs = ids.flatMap { observer in ids.filter { $0 != observer }.map { (observer, $0) } }
        let edges = DomainAgentSessionInventoryEdge.merge(live: [], persisted: pairs)
        let snapshot = DomainAgentSessionInventorySnapshot(records: records, edges: edges, isComplete: true)
        XCTAssertEqual(snapshot.ancestryBuildEdgeVisitsForTesting, 249)
        var lookups = 0
        for (rootIndex, root) in ids.enumerated() {
            for (targetIndex, target) in ids.enumerated() {
                XCTAssertEqual(snapshot.isInTree(target, rootSessionID: root, onAncestryLookup: { _ in lookups += 1 }), targetIndex >= rootIndex)
            }
            XCTAssertEqual(snapshot.edges(touching: root).count, 498)
            XCTAssertEqual(snapshot.roles(of: root), Set([DomainAgentSessionInventoryRole.overseer, .overseen]))
            XCTAssertEqual(snapshot.orphanReasons(for: root), [])
        }
        XCTAssertEqual(lookups, 186_750, "250x250 queries use two or four scalar lookups, never per-target parent walks")
        let restricted = snapshot.restricted(to: Set(ids.suffix(10)))
        XCTAssertEqual(restricted.edges.count, 90)
        XCTAssertEqual(restricted.records.count, 10)
        for id in ids.suffix(10) {
            XCTAssertEqual(restricted.edges(touching: id).count, 18)
            XCTAssertFalse(restricted.isInTree(id, rootSessionID: ids[0]), "Hidden intermediate ancestry must not grant membership in a restricted view")
            XCTAssertFalse(restricted.isMissing(ids[0]), "Hidden is not deleted")
        }
    }

    func testIndexedAncestryMatchesBoundedWalkForCyclesMissingEndpointsAndDeepChains() {
        let ids = (0 ..< 270).map { _ in UUID() }
        var parents = Dictionary(uniqueKeysWithValues: (1 ..< ids.count).map { (ids[$0], ids[$0 - 1]) })
        let cycle = (0 ..< 3).map { _ in UUID() }
        for index in cycle.indices {
            parents[cycle[index]] = cycle[(index + 1) % cycle.count]
        }
        parents[UUID()] = cycle[1]
        parents[UUID()] = UUID() // Missing endpoint is still a valid root to reach.
        let ancestry = DomainAgentSessionAncestryIndex(parents: parents)
        XCTAssertEqual(ancestry.buildEdgeVisits, parents.count)
        let nodes = Set(parents.keys).union(parents.values)
        for target in nodes {
            for root in nodes {
                var cursor: UUID? = target
                var seen: Set<UUID> = []
                var distance: Int?
                while let node = cursor, seen.insert(node).inserted {
                    if node == root { distance = seen.count - 1
                        break
                    }
                    cursor = parents[node]
                }
                XCTAssertEqual(ancestry.distance(from: target, to: root), distance)
            }
        }
        XCTAssertEqual(ancestry.distance(from: ids[255], to: ids[0]), 255)
        XCTAssertEqual(ancestry.distance(from: ids[256], to: ids[0]), 256)
    }
}
