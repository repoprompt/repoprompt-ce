import Foundation
@testable import RepoPromptApp
import XCTest

/// Cross-session attribution is additive metadata on a user row, and the badge is only as good as
/// the weakest carrier it survives.
///
/// Several layers rebuild an `AgentChatItem` field-by-field rather than retaining the original —
/// the persisted DTO, the transcript activity carrier, and the request anchor that archived,
/// condensed, and summarized turns reconstruct their user row from. A field added to
/// `AgentChatItem` alone would silently vanish the moment a turn left the full-retention tier, so
/// every reconstruction path is asserted here rather than only the model.
final class AgentSessionLinkAttributionPersistenceTests: XCTestCase {
    private let attribution = AgentCrossSessionAttribution(
        sourceSessionID: UUID(uuidString: "04CFAAAA-BBBB-CCCC-DDDD-EEEEFFFF771A")!,
        sourceName: "Planning",
        linkID: UUID(uuidString: "8B91AAAA-BBBB-CCCC-DDDD-EEEEFFFFE572")!
    )

    private func attributedUserItem() -> AgentChatItem {
        AgentChatItem.user(
            "Please rerun the failing test.",
            sequenceIndex: 7,
            crossSessionAttribution: attribution
        )
    }

    // MARK: - Model Codable

    func testAgentChatItemRoundTripsAttribution() throws {
        let item = attributedUserItem()
        let decoded = try JSONDecoder().decode(
            AgentChatItem.self,
            from: JSONEncoder().encode(item)
        )
        XCTAssertEqual(decoded.crossSessionAttribution, attribution)
        XCTAssertEqual(decoded.text, item.text)
    }

    /// Sessions written before oversight existed must keep loading. Rollback safety is the same
    /// property viewed from the other side: a build without the key ignores it.
    func testItemWrittenBeforeMonitoringDecodesWithNilAttribution() throws {
        let legacy = """
        {"id":"\(UUID().uuidString)","timestamp":0,"kind":"user","text":"hello","sequenceIndex":1}
        """
        let decoded = try JSONDecoder().decode(AgentChatItem.self, from: Data(legacy.utf8))
        XCTAssertNil(decoded.crossSessionAttribution)
        XCTAssertEqual(decoded.text, "hello")
    }

    func testReplacingIDPreservesAttribution() {
        let replaced = attributedUserItem().replacingID(UUID())
        XCTAssertEqual(replaced.crossSessionAttribution, attribution)
    }

    // MARK: - Persisted DTO

    func testPersistedItemRoundTripsAttributionThroughCodableAndBack() throws {
        let persisted = AgentChatItemPersist(from: attributedUserItem())
        XCTAssertEqual(persisted.crossSessionAttribution, attribution)

        let decoded = try JSONDecoder().decode(
            AgentChatItemPersist.self,
            from: JSONEncoder().encode(persisted)
        )
        XCTAssertEqual(decoded.crossSessionAttribution, attribution)
        XCTAssertEqual(decoded.toItem().crossSessionAttribution, attribution)
    }

    func testPersistedItemWrittenBeforeMonitoringDecodesWithNilAttribution() throws {
        let legacy = """
        {"id":"\(UUID().uuidString)","timestamp":0,"kind":"user","text":"hello","sequenceIndex":1}
        """
        let decoded = try JSONDecoder().decode(AgentChatItemPersist.self, from: Data(legacy.utf8))
        XCTAssertNil(decoded.crossSessionAttribution)
        XCTAssertNil(decoded.toItem().crossSessionAttribution)
    }

    // MARK: - Transcript carriers

    func testTranscriptActivityCarrierPreservesAttribution() throws {
        let activity = AgentTranscriptActivity(from: attributedUserItem())
        XCTAssertEqual(activity.crossSessionAttribution, attribution)
        XCTAssertEqual(activity.toItem().crossSessionAttribution, attribution)

        let decoded = try JSONDecoder().decode(
            AgentTranscriptActivity.self,
            from: JSONEncoder().encode(activity)
        )
        XCTAssertEqual(decoded.crossSessionAttribution, attribution)
    }

    func testRequestAnchorPreservesAttribution() throws {
        let anchor = AgentTranscriptRequestAnchor(from: attributedUserItem())
        XCTAssertEqual(anchor.crossSessionAttribution, attribution)
        XCTAssertEqual(anchor.toItem().crossSessionAttribution, attribution)

        let decoded = try JSONDecoder().decode(
            AgentTranscriptRequestAnchor.self,
            from: JSONEncoder().encode(anchor)
        )
        XCTAssertEqual(decoded.crossSessionAttribution, attribution)
    }

    // MARK: - Whole-transcript reconstruction

    /// The end-to-end path that matters: items → canonical transcript → flattened rows. The user row
    /// is rebuilt from its request anchor here, which is precisely where an anchor-only field gap
    /// would drop the badge.
    func testAttributionSurvivesCanonicalTranscriptReconstruction() {
        let items = [
            attributedUserItem(),
            AgentChatItem.assistant("Rerunning now.", sequenceIndex: 8)
        ]
        let transcript = AgentTranscriptIO.buildTranscript(from: items)
        let rows = AgentTranscriptIO.flattenFullTranscript(transcript)
        let userRow = rows.first { $0.kind == .user }
        XCTAssertEqual(userRow?.crossSessionAttribution, attribution)
    }

    /// The monitor projection an observer reads is built from the same canonical rows, so a
    /// previously delivered cross-session row must still be classifiable by its reader.
    func testCanonicalMonitorProjectionRetainsAttributionForOriginClassification() throws {
        let items = [
            attributedUserItem(),
            AgentChatItem.assistant("Rerunning now.", sequenceIndex: 8)
        ]
        let transcript = AgentTranscriptIO.buildTranscript(from: items)
        let canonical = AgentModeViewModel.canonicalTranscript(
            from: transcript,
            sourceItemsRevision: 1
        )
        let candidateRow = canonical.rows.first { $0.kind == .user }
        let userRow = try XCTUnwrap(candidateRow, "expected a canonical user row")
        XCTAssertEqual(userRow.crossSessionAttribution, attribution)
        XCTAssertEqual(
            AgentSessionLinkTranscriptSanitizer.crossSessionOrigin(
                for: userRow,
                readerSessionID: attribution.sourceSessionID
            ),
            .thisSession
        )
        XCTAssertEqual(
            AgentSessionLinkTranscriptSanitizer.crossSessionOrigin(
                for: userRow,
                readerSessionID: UUID()
            ),
            .otherSession
        )
    }
}
