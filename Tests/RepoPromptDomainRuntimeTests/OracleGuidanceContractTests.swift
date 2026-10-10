import Foundation
@testable import RepoPromptDomainRuntime
import XCTest

final class OracleGuidanceContractTests: XCTestCase {
    func testDefaultPreambleRemainsByteForByteIdenticalIncludingFixedFraming() throws {
        for count in 2 ... 5 {
            let lanes = (0 ..< count).map { lane($0) }
            let manifest = (0 ..< count).map { index in
                "- \(index == 0 ? "Oracle" : "Oracle \(index + 1)") — `model-\(index)` — Completed — chat ID `chat-\(index)`"
            }.joined(separator: "\n")
            // Pre-change caller-facing bytes. This detects inadvertent framing or policy edits.
            let expected = """
            **Reconciling these Oracle lanes**
            \(count) independent answers to the same request follow. Lane order is not a ranking; the first lane supplies the top-level continuation handle, and a successful follow-up through any lane's chat ID re-runs every lane.
            - Read every lane through the end-of-group marker (`End of Oracle group: \(count) lanes above.`). If the marker or a lane is missing, page the export or try the read-only `oracle_chat_log` with that lane's chat ID. Logs may be scoped or clipped; report any remaining gap. Do not start a follow-up just to retrieve prior text.
            - Reconcile by evidence, not lane order, answer length, or model identity: check material single-lane and conflicting claims against the code, and report unresolved disagreements. A failed or partial lane is incomplete evidence.
            - Before synthesizing, inventory every material claim from every lane, including single-lane claims. Merge only exact duplicates, retaining all source lanes. Begin your answer with `**Oracle reconciliation**`, state how many lanes completed and name any that did not. For every inventory item, give its source lanes, checked evidence, and exactly one disposition: `accepted`, `rejected`, or `unresolved`. Never silently omit an item.

            Lanes (\(count)):
            \(manifest)
            """
            for override in [nil, "", " \t\r\n"] {
                let actual = try XCTUnwrap(OracleGroupDeliveryContract.preamble(lanes: lanes, reconciliationGuidance: override))
                XCTAssertEqual(Data(actual.utf8), Data(expected.utf8))
            }
        }
    }

    func testCustomGuidanceReplacesOnlyBehaviorPreservingVerbatimTextAndOrderedManifest() throws {
        let lanes = [
            OracleGroupDeliveryContract.Lane(laneIndex: 1, modelID: "same", chatID: "second", status: "Failed", response: nil, partialResponse: "partial"),
            OracleGroupDeliveryContract.Lane(laneIndex: 0, modelID: "same", chatID: "first", status: "Completed", response: "answer")
        ]
        let custom = "  Check disputed facts.\nKeep unmatched claims visible.  \n"
        let original = try XCTUnwrap(OracleGroupDeliveryContract.preamble(lanes: lanes))
        let actual = try XCTUnwrap(OracleGroupDeliveryContract.preamble(lanes: lanes, reconciliationGuidance: custom))
        XCTAssertEqual(actual, original.replacingOccurrences(of: OracleGroupDeliveryContract.defaultReconciliationGuidance, with: custom))
        XCTAssertTrue(actual.hasSuffix("- Oracle — `same` — Completed — chat ID `first`\n- Oracle 2 — `same` — Failed (partial) — chat ID `second`"))
    }

    func testSingleLaneAndEmptyGroupsStaySilentEvenWithCustomGuidance() {
        for lanes in [[], [lane(0)]] {
            XCTAssertNil(OracleGroupDeliveryContract.preamble(lanes: lanes, reconciliationGuidance: "custom"))
        }
    }

    private func lane(_ index: Int) -> OracleGroupDeliveryContract.Lane {
        .init(laneIndex: index, modelID: "model-\(index)", chatID: "chat-\(index)", status: "Completed", response: "answer")
    }
}
