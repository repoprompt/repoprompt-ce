import Foundation
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

final class AgentQuietCheckInClassifierTests: XCTestCase {
    @MainActor
    func testFinishedReplyGrammarAndByteLimit() {
        let allowed = ["", "[ack]", "[ACK].", " [aCk] \r\n", String(repeating: " ", count: 251) + "[ack]"]
            + [0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20].map {
                String(UnicodeScalar($0)!) + "[ack]." + String(UnicodeScalar($0)!)
            }
        let rejected = [
            "ack", "ACK.", "[ack]..", "[ack] .", "`[ack]`", "**[ack]**", "done [ack]",
            "[ack]\u{00A0}", "\u{2003}[ack]", "[аck]", "[ack]\u{200B}", "\u{0000}[ack]",
            String(repeating: " ", count: 252) + "[ack]", String(repeating: "é", count: 128)
        ]
        for (texts, expected) in [(allowed, true), (rejected, false)] {
            for text in texts {
                var fixture = AgentQuietCheckInFixture()
                fixture.begin()
                XCTAssertEqual(fixture.seal(fixture.rows([text]))?.isQuiet, expected, text.debugDescription)
            }
        }
    }

    @MainActor
    func testMessageBoundariesIncludingBlankAndByteSeparators() {
        for (messages, expected) in [
            (["[ack]", "[ack]"], false), (["[ac", "k]"], false), (["prose", "[ack]"], false),
            (["", "[ack]", ""], true), (["", ""], true),
            ([String(repeating: " ", count: 250), "[ack]"], true),
            ([String(repeating: " ", count: 251), "[ack]"], false)
        ] {
            var fixture = AgentQuietCheckInFixture()
            fixture.begin()
            XCTAssertEqual(fixture.seal(fixture.rows(messages))?.isQuiet, expected, "\(messages)")
        }
    }

    @MainActor
    func testOnlyAuthoritativeFinishedReplacementDecides() {
        var fixture = AgentQuietCheckInFixture()
        fixture.begin()
        var row = fixture.rows(["I may do some work."])[0]
        row.isStreaming = true
        // Provider final replacement preserves the source identity but not the discarded text.
        row.text = "[ack]"
        row.isStreaming = false
        XCTAssertEqual(fixture.seal([row])?.isQuiet, true)
        XCTAssertTrue(fixture.ledger.hiddenSourceIDs.contains(row.id))
    }

    @MainActor
    func testSilenceReasoningAndInlineAcrossExactSupportedProviders() {
        for provider in AgentSessionLinkPromptProviderContext.allCases {
            for kind in [AgentChatItemKind.assistantInline, .thinking] {
                var fixture = AgentQuietCheckInFixture()
                fixture.begin(provider: provider)
                let row = fixture.rows([kind == .thinking ? "private reasoning" : "[ack]"], kind: kind)
                let supported = [.codexExec, .claudeCode].contains(provider)
                XCTAssertEqual(fixture.seal(row)?.isQuiet, supported, provider.rawValue)
                var silent = AgentQuietCheckInFixture()
                silent.begin(provider: provider)
                XCTAssertEqual(silent.seal()?.isQuiet, supported, provider.rawValue)
            }
        }
    }

    @MainActor
    func testNonReplyKindsAndIncompleteStreamsAreOrdinary() {
        for kind in [AgentChatItemKind.user, .toolCall, .toolResult, .system, .error] {
            var fixture = AgentQuietCheckInFixture()
            fixture.begin()
            XCTAssertEqual(fixture.seal(fixture.rows(["[ack]"], kind: kind))?.isQuiet, false)
            XCTAssertTrue(fixture.ledger.hiddenSourceIDs.isEmpty)
        }
        for kind in [AgentChatItemKind.assistant, .assistantInline, .thinking] {
            var fixture = AgentQuietCheckInFixture()
            fixture.begin()
            var rows = fixture.rows(["[ack]"], kind: kind)
            rows[0].isStreaming = true
            XCTAssertEqual(fixture.seal(rows)?.isQuiet, false)
        }
    }

    @MainActor
    func testRangeRequiresCompleteOrderedUniqueAllocatedRows() {
        let fixture = AgentQuietCheckInFixture()
        let first = fixture.rows(["[ack]"])[0]
        var second = first
        second.sequenceIndex += 1
        let cases: [(String, [AgentChatItem], Int, Int, Bool)] = [
            ("missing proof", [first], 10, 10, false), ("lost tail", [first], 10, 11, true),
            ("lost all", [], 10, 10, true), ("lost prefix", [second], 10, 11, true),
            ("reordered", [second, first], 10, 11, true), ("duplicate ID", [first, second], 10, 11, true),
            ("duplicate key", [first, first], 10, 10, true), ("old row", [first], 11, 11, true),
            ("future row", [second], 10, 10, true), ("invalid bound", [], -1, -2, true)
        ]
        for (label, rows, start, end, complete) in cases {
            XCTAssertEqual(AgentQuietCheckInClassifier.classify(
                rows: rows, startKey: start, endKey: end, rangeIsComplete: complete,
                routineWakeID: fixture.wakeID, hostMarkerIDs: []
            ), .ordinary, label)
        }
        let maxRow = AgentChatItem.assistant("[ack]", sequenceIndex: Int.max)
        XCTAssertEqual(AgentQuietCheckInClassifier.classify(
            rows: [maxRow], startKey: Int.max, endKey: Int.max, rangeIsComplete: true,
            routineWakeID: fixture.wakeID, hostMarkerIDs: []
        ), .quiet(hiddenSourceIDs: [maxRow.id, fixture.wakeID]))
    }

    @MainActor
    func testPositiveOwnAndForeignHostProvenanceNeverHidesForeignRows() {
        for oldWasQuiet in [false, true] {
            var fixture = AgentQuietCheckInFixture()
            let oldOwner = AgentRunOwnership(binding: fixture.owner.binding)
            let oldWake = UUID()
            fixture.ledger.begin(owner: oldOwner, startKey: 0, provider: .claudeCode)
            if oldWasQuiet { fixture.ledger.markRoutineWake(owner: oldOwner, wakeID: oldWake) }
            _ = fixture.ledger.settle(
                owner: oldOwner, terminalState: .completed, classifiesQuietCheckIn: true,
                endKey: -1, rangeIsComplete: true, rows: [AgentChatItem]()
            )
            _ = fixture.ledger.end(owner: oldOwner, authoritativeOwner: oldOwner)
            fixture.begin()
            let foreign = AgentChatItem.laneUpdateAutoWake(wakeID: oldWake, acceptedAt: Date(timeIntervalSince1970: 0), sequenceIndex: 10)
            let own = AgentChatItem.laneUpdateAutoWake(wakeID: fixture.wakeID, acceptedAt: Date(timeIntervalSince1970: 0), sequenceIndex: 11)
            XCTAssertTrue(fixture.ledger.registerHostMarker(foreign))
            XCTAssertTrue(fixture.ledger.registerHostMarker(own))
            let result = fixture.seal([foreign, own])
            XCTAssertEqual(result?.isQuiet, true)
            XCTAssertEqual(fixture.ledger.hiddenSourceIDs.contains(oldWake), oldWasQuiet)
            XCTAssertTrue(fixture.ledger.hiddenSourceIDs.contains(fixture.wakeID))
        }
    }

    @MainActor
    func testCanonicalTextAndPositiveRegistrationAreBothRequired() {
        for variant in 0 ..< 4 {
            var fixture = AgentQuietCheckInFixture()
            fixture.begin()
            var marker = AgentChatItem.laneUpdateAutoWake(wakeID: fixture.wakeID, acceptedAt: Date(timeIntervalSince1970: 0), sequenceIndex: 10)
            if variant != 0 { XCTAssertTrue(fixture.ledger.registerHostMarker(marker)) }
            if variant == 1 { marker.text += " changed" }
            if variant == 2 { marker.kind = .user }
            if variant == 3 { marker = AgentChatItem(kind: .system, text: marker.text, sequenceIndex: marker.sequenceIndex) }
            XCTAssertEqual(fixture.seal([marker])?.isQuiet, false)
        }
        var ledger = AgentRunQuietLedger()
        XCTAssertFalse(ledger.registerHostMarker(.system("not a host marker")))
    }
}
