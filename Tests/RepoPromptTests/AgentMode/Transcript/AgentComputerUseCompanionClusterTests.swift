import Foundation
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

final class AgentComputerUseCompanionClusterTests: XCTestCase {
    private func pairs(_ name: String, _ id: UUID?, _ seq: inout Int) -> [AgentChatItem] {
        defer { seq += 2 }
        return [
            .toolCall(name: name, invocationID: id, argsJSON: "{}", sequenceIndex: seq),
            .toolResult(name: name, invocationID: id, resultJSON: "{}", isError: false, sequenceIndex: seq + 1)
        ]
    }

    private func companion(_ tool: String, _ seq: inout Int) -> [AgentChatItem] {
        pairs("mcp__computer-use__\(tool)", UUID(), &seq)
    }

    private func blocks(for items: [AgentChatItem]) -> [AgentTranscriptRenderBlock] {
        AgentTranscriptProjectionBuilder.build(from: AgentTranscriptIO.importLegacyItems(items)).workingBlocks
    }

    func testConsecutiveCompanionCallsCollapseIntoOneCluster() throws {
        var seq = 1
        var items: [AgentChatItem] = [.user("drive", sequenceIndex: 0)]
        items += companion("click", &seq) + companion("key_press", &seq) + companion("screenshot", &seq)
        let clusters = blocks(for: items).filter { $0.kind == .activityCluster }
        XCTAssertEqual(clusters.count, 1)
        let cluster = try XCTUnwrap(clusters.first)
        XCTAssertEqual(cluster.rows.count, 6)
        XCTAssertEqual(cluster.clusterSummary?.toolCount, 3)
        XCTAssertEqual(cluster.clusterSummary?.collapsedDisplay?.title, "Computer Use · 3 actions")
        XCTAssertNil(cluster.clusterSummary?.collapsedDisplay?.count)
        XCTAssertEqual(cluster.defaultPresentation, .collapsed)

        // Restored transcripts re-derive the identical cluster: derivation is from items only.
        let transcript = AgentTranscriptIO.importLegacyItems(items)
        let rebuilt = AgentTranscriptIO.importLegacyItems(AgentTranscriptIO.flattenFullTranscript(transcript))
        let rebuiltClusters = AgentTranscriptProjectionBuilder.build(from: rebuilt).workingBlocks
            .filter { $0.kind == .activityCluster }
        XCTAssertEqual(rebuiltClusters.map(\.rows.count), [6])
    }

    func testSingleCompanionCallStaysStandalone() {
        var seq = 1
        var items: [AgentChatItem] = [.user("drive", sequenceIndex: 0)]
        items += companion("click", &seq)
        let kinds = blocks(for: items).map(\.kind)
        XCTAssertEqual(kinds.count(where: { $0 == .standaloneTool }), 1)
        XCTAssertFalse(kinds.contains(.activityCluster))
    }

    func testNonCompanionCallBreaksRun() {
        var seq = 1
        var items: [AgentChatItem] = [.user("drive", sequenceIndex: 0)]
        items += companion("click", &seq) + companion("click", &seq)
        items += pairs("read_file", UUID(), &seq)
        items += companion("screenshot", &seq) + companion("screenshot", &seq)
        let kinds = blocks(for: items).map(\.kind)
        XCTAssertEqual(
            kinds.filter { $0 == .activityCluster || $0 == .standaloneTool },
            [.activityCluster, .standaloneTool, .activityCluster]
        )
    }

    func testBareAndForeignToolNamesNeverCluster() {
        var seq = 1
        var items: [AgentChatItem] = [.user("drive", sequenceIndex: 0)]
        items += pairs("click", UUID(), &seq) + pairs("mcp__other__click", UUID(), &seq)
        let kinds = blocks(for: items).map(\.kind)
        XCTAssertEqual(kinds.count(where: { $0 == .standaloneTool }), 2)
        XCTAssertFalse(kinds.contains(.activityCluster))
    }

    func testInvocationlessPairsCountAsLogicalCalls() throws {
        var seq = 1
        var items: [AgentChatItem] = [.user("drive", sequenceIndex: 0)]
        // No invocationID: import pairs call/result by name into one execution each.
        // The label must still count calls (2), not re-derived row identities (4).
        items += pairs("mcp__computer-use__click", nil, &seq)
        items += pairs("mcp__computer-use__screenshot", nil, &seq)
        let cluster = try XCTUnwrap(blocks(for: items).first { $0.kind == .activityCluster })
        XCTAssertEqual(cluster.clusterSummary?.toolCount, 2)
        XCTAssertEqual(cluster.clusterSummary?.collapsedDisplay?.title, "Computer Use · 2 actions")
    }

    func testContinuationFragmentAfterBoundaryDoesNotMerge() {
        var seq = 1
        let callA = UUID(), callB = UUID(), foreign = UUID()
        var items: [AgentChatItem] = [.user("drive", sequenceIndex: 0)]
        // Execution A's call/result is split by a foreign call; its trailing fragment
        // must not re-join a run with B — one call can never be counted twice.
        items.append(.toolCall(name: "mcp__computer-use__click", invocationID: callA, argsJSON: "{}", sequenceIndex: seq))
        seq += 1
        items += pairs("read_file", foreign, &seq)
        items.append(.toolResult(name: "mcp__computer-use__click", invocationID: callA, resultJSON: "{}", isError: false, sequenceIndex: seq))
        seq += 1
        items += pairs("mcp__computer-use__screenshot", callB, &seq)
        let kinds = blocks(for: items).map(\.kind)
        XCTAssertEqual(kinds.count(where: { $0 == .standaloneTool }), 4)
        XCTAssertFalse(kinds.contains(.activityCluster))
    }

    func testLeafDescriptorAndKindsPathsMirrorMerge() {
        var seq = 1
        var items: [AgentChatItem] = [.user("drive", sequenceIndex: 0)]
        items += companion("click", &seq) + companion("click", &seq)
        items += pairs("bash", UUID(), &seq)
        items += companion("screenshot", &seq)
        let transcript = AgentTranscriptIO.importLegacyItems(items)
        let turn = transcript.turns[0]
        let span = turn.responseSpans[0]
        var emitted = Set<UUID>()
        XCTAssertEqual(
            AgentTranscriptProjectionBuilder.fullSpanLeafBlockKinds(
                for: span, in: turn, emittedConclusionActivityIDs: &emitted
            ),
            [.activityCluster, .standaloneTool, .standaloneTool]
        )
        var emittedDescriptors = Set<UUID>()
        let descriptors = AgentTranscriptProjectionBuilder.fullSpanLeafDescriptors(
            for: span, in: turn, emittedConclusionActivityIDs: &emittedDescriptors
        )
        XCTAssertEqual(descriptors.map(\.kind), [.activityCluster, .standaloneTool, .standaloneTool])
        // A visible cluster presents one row, matching presentedItemCount.
        XCTAssertEqual(descriptors.map(\.rowCount), [1, 2, 2])
    }

    func testCompanionRunsBypassDetailedToolTailBudget() throws {
        var seq = 1
        var items: [AgentChatItem] = [.user("drive", sequenceIndex: 0)]
        for _ in 0 ..< 10 {
            items += companion("click", &seq)
        }
        let toolBlocks = blocks(for: items).filter {
            $0.kind == .activityCluster || $0.kind == .standaloneTool || $0.kind == .groupedHistory
        }
        XCTAssertEqual(toolBlocks.map(\.kind), [.activityCluster])
        XCTAssertEqual(try XCTUnwrap(toolBlocks.first).clusterSummary?.toolCount, 10)
    }

    func testClusterCountsAsOneTailLeafWithinBudget() {
        var seq = 1
        var items: [AgentChatItem] = [.user("drive", sequenceIndex: 0)]
        items += companion("click", &seq) + companion("click", &seq)
        for _ in 0 ..< 7 {
            items += pairs("read_file", UUID(), &seq)
        }
        // The cluster plus seven tools is exactly the detailed-tail budget: no grouping.
        let kinds = blocks(for: items).map(\.kind).filter { $0 != .request }
        XCTAssertEqual(kinds, [.activityCluster] + Array(repeating: .standaloneTool, count: 7))
    }

    func testCompanionOnlyGroupedHistoryKeepsGenericLabel() throws {
        var seq = 1
        var items: [AgentChatItem] = [.user("drive", sequenceIndex: 0)]
        // Nine note-separated singletons exceed the tail budget; the collapsed group is
        // generic history, not a companion cluster, so it must not claim the label.
        for index in 0 ..< 9 {
            items += companion("click", &seq)
            if index < 8 {
                items.append(.assistant("step", sequenceIndex: seq))
                seq += 1
            }
        }
        let grouped = try XCTUnwrap(blocks(for: items).first { $0.kind == .groupedHistory })
        let display = grouped.groupedHistory?.summary.collapsedDisplay
        XCTAssertFalse(display?.title.hasPrefix("Computer Use") ?? true)
        XCTAssertNotNil(display?.count)
    }

    func testNestedClusterInsideGroupedHistoryKeepsGenericLabels() throws {
        var seq = 1
        var items: [AgentChatItem] = [.user("drive", sequenceIndex: 0)]
        items += companion("click", &seq) + companion("click", &seq)
        for _ in 0 ..< 9 {
            items += pairs("read_file", UUID(), &seq)
        }
        // The cluster sits beyond the detailed tail, so it nests inside grouped history;
        // neither the outer row nor the nested tool summary may reuse the companion label.
        let grouped = try XCTUnwrap(blocks(for: items).first { $0.kind == .groupedHistory })
        XCTAssertFalse(
            grouped.groupedHistory?.summary.collapsedDisplay?.title.hasPrefix("Computer Use") ?? true
        )
        XCTAssertFalse(
            grouped.groupedHistory?.summary.toolSummary?.collapsedDisplay?.title.hasPrefix("Computer Use") ?? true
        )
    }

    func testProbeWithZeroTailLimitCollapsesAllToolLeaves() {
        var seq = 1
        var items: [AgentChatItem] = [.user("drive", sequenceIndex: 0)]
        items += companion("click", &seq) + companion("click", &seq)
        let turn = AgentTranscriptIO.importLegacyItems(items).turns[0]
        XCTAssertTrue(AgentTranscriptProjectionBuilder.groupedHistoryWouldCollapse(
            in: turn,
            detailedToolTailLimit: 0
        ))
        let emptyTurn = AgentTranscriptIO.importLegacyItems([.user("drive", sequenceIndex: 0)]).turns[0]
        XCTAssertFalse(AgentTranscriptProjectionBuilder.groupedHistoryWouldCollapse(
            in: emptyTurn,
            detailedToolTailLimit: 0
        ))
    }

    func testProjectionRealScaleWithinBudget() {
        var seq = 1
        var items: [AgentChatItem] = [.user("drive", sequenceIndex: 0)]
        for index in 0 ..< 1500 {
            switch index % 5 {
            case 4:
                items.append(.assistant("step \(index)", sequenceIndex: seq))
                seq += 1
            default:
                items += companion(index % 10 == 0 ? "screenshot" : "click", &seq)
            }
        }
        // ~2400 companion rows (~1200 executions) + ~300 assistant rows.
        let transcript = AgentTranscriptIO.importLegacyItems(items)
        let start = Date()
        _ = AgentTranscriptProjectionBuilder.build(from: transcript)
        let elapsed = Date().timeIntervalSince(start)
        print("CU-COLLAPSE-SCALE-MS \(Int(elapsed * 1000))")
        // ~300ms on base, ~380ms with the merge (cluster summaries are the real cost);
        // the budget keeps 5x headroom for slower hosts.
        XCTAssertLessThan(elapsed, 2.0, "leaf post-pass must stay linear")
    }
}
