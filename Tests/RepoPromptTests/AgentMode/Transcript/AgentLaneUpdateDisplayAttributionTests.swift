import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

/// Local-display attribution for an accepted lane-update row.
///
/// Two properties are load-bearing and are asserted separately here. The first is that the sentence
/// is a deterministic function of the immutable rendered batch: the same batch always produces the
/// same words, unnamed and duplicate-named lanes are counted rather than invented or repeated, and
/// nothing about the sentence depends on live links, selection, or a lookup performed after
/// acceptance. The second is that none of it leaves the machine — the row's raw text stays the
/// generic canonical marker, which is the only thing provider replay and every cross-session
/// projection serialize.
final class AgentLaneUpdateDisplayAttributionTests: XCTestCase {
    // MARK: - Fixtures

    private func reference(_ index: Int) -> DomainAgentSessionLinkReference {
        DomainAgentSessionLinkReference(
            linkID: UUID(
                uuidString: String(format: "0000000%X-0000-0000-0000-000000001111", index)
            )!,
            generation: 1
        )
    }

    private func endpoint(_ sessionID: UUID = UUID()) -> DomainAgentSessionLinkEndpointIdentity {
        DomainAgentSessionLinkEndpointIdentity(
            windowID: 2,
            workspaceID: UUID(),
            tabID: UUID(),
            sessionID: sessionID,
            persistentBindingGeneration: UUID(),
            bindingTransitionGeneration: 1
        )
    }

    private func entry(
        _ index: Int,
        name: String?,
        reference overrideReference: DomainAgentSessionLinkReference? = nil
    ) -> AgentSessionLinkPassiveStatusNotices.PendingEntry {
        AgentSessionLinkPassiveStatusNotices.PendingEntry(
            reference: overrideReference ?? reference(index),
            targetEndpoint: endpoint(),
            targetSessionID: UUID(),
            displayName: name,
            fromStatus: .running,
            toStatus: .idle,
            changeSequence: UInt64(index + 1)
        )
    }

    private func attribution(
        names: [String?],
        overflow: Bool = false,
        locationLabelsByReference: [DomainAgentSessionLinkReference: String] = [:]
    ) -> AgentLaneUpdateDisplayAttribution? {
        AgentLaneUpdateDisplayAttribution.make(
            renderedEntries: names.enumerated().map { entry($0.offset, name: $0.element) },
            includesUnattributedOverflow: overflow,
            locationLabelsByReference: locationLabelsByReference
        )
    }

    private func sentence(
        names: [String?],
        overflow: Bool = false,
        locationLabelsByReference: [DomainAgentSessionLinkReference: String] = [:]
    ) throws -> String {
        let built = try XCTUnwrap(attribution(
            names: names,
            overflow: overflow,
            locationLabelsByReference: locationLabelsByReference
        ))
        return try XCTUnwrap(AgentLaneUpdateDisplayAttribution.richDisplayText(
            rawText: AgentLaneUpdateDisplayAttribution.canonicalSystemText,
            attribution: built
        ))
    }

    private let opening = "[lane-update] RepoPrompt auto-woke this session and delivered"

    // MARK: - Deterministic grammar

    func testOneUnnamedLaneRendersTheSingularGenericSentence() throws {
        XCTAssertEqual(
            try sentence(names: [nil]),
            "\(opening) an update for an overseen lane."
        )
    }

    func testSeveralUnnamedLanesRenderACountedGenericSentence() throws {
        XCTAssertEqual(
            try sentence(names: [nil, nil, nil]),
            "\(opening) updates for 3 overseen lanes."
        )
    }

    func testOneNamedLaneRendersTheSingularNamedSentence() throws {
        XCTAssertEqual(
            try sentence(names: ["Build API"]),
            "\(opening) an update for overseen lane \u{201C}Build API\u{201D}."
        )
    }

    func testOneNamedLaneWithOneUnnamedLaneUsesTheSingularOtherPhrase() throws {
        XCTAssertEqual(
            try sentence(names: ["Build API", nil]),
            "\(opening) updates for overseen lane \u{201C}Build API\u{201D} and 1 other overseen lane."
        )
    }

    func testOneNamedLaneWithSeveralUnnamedLanesUsesThePluralOtherPhrase() throws {
        XCTAssertEqual(
            try sentence(names: ["Build API", nil, nil, nil]),
            "\(opening) updates for overseen lane \u{201C}Build API\u{201D} and 3 other overseen lanes."
        )
    }

    func testTwoNamedLanesAreJoinedWithAnd() throws {
        XCTAssertEqual(
            try sentence(names: ["Build API", "Docs"]),
            "\(opening) updates for overseen lanes \u{201C}Build API\u{201D} and \u{201C}Docs\u{201D}."
        )
    }

    func testExactReferenceLocationsPrefixTaskLabelsAtClaimBoundary() throws {
        let locations = [
            reference(0): "kidfriendly-nova",
            reference(1): "RepoPrompt (main)"
        ]
        let built = try XCTUnwrap(attribution(
            names: ["Build API", "Docs"],
            locationLabelsByReference: locations
        ))

        XCTAssertEqual(built.labels, [
            "kidfriendly-nova: Build API",
            "RepoPrompt (main): Docs"
        ])
        XCTAssertEqual(built.attributedLaneCount, 2)
        XCTAssertEqual(
            try sentence(
                names: ["Build API", "Docs"],
                locationLabelsByReference: locations
            ),
            "\(opening) updates for overseen lanes \u{201C}kidfriendly-nova: Build API\u{201D} "
                + "and \u{201C}RepoPrompt (main): Docs\u{201D}."
        )
    }

    func testMissingInvalidAndMismatchedLocationsFallBackToTaskOnly() throws {
        let exact = reference(0)
        let mismatchedGeneration = DomainAgentSessionLinkReference(
            linkID: exact.linkID,
            generation: exact.generation + 1
        )
        let locationMaps: [[DomainAgentSessionLinkReference: String]] = [
            [:],
            [exact: "   \n  "],
            [exact: "\u{200B}\u{202E}\u{FEFF}"],
            [mismatchedGeneration: "replacement-worktree"]
        ]

        for locations in locationMaps {
            let built = try XCTUnwrap(attribution(
                names: ["Build API"],
                locationLabelsByReference: locations
            ))
            XCTAssertEqual(built.labels, ["Build API"])
        }

        let unnamed = try XCTUnwrap(attribution(
            names: [nil],
            locationLabelsByReference: [exact: "kidfriendly-nova"]
        ))
        XCTAssertTrue(unnamed.labels.isEmpty, "a location must not invent a missing task label")
        XCTAssertEqual(unnamed.attributedLaneCount, 1)
    }

    func testTwoNamedLanesWithOneOtherLaneUseTheSerialForm() throws {
        XCTAssertEqual(
            try sentence(names: ["Build API", "Docs", nil]),
            "\(opening) updates for overseen lanes \u{201C}Build API\u{201D}, \u{201C}Docs\u{201D}, and 1 other overseen lane."
        )
    }

    func testTwoNamedLanesWithSeveralOtherLanesUseThePluralSerialForm() throws {
        XCTAssertEqual(
            try sentence(names: ["Build API", "Docs", "Infra", "Release"]),
            "\(opening) updates for overseen lanes \u{201C}Build API\u{201D}, \u{201C}Docs\u{201D}, and 2 other overseen lanes."
        )
    }

    /// Two lanes that happen to share a name are two lanes. Repeating the label would read as one
    /// session changing twice, and inventing a disambiguator would be a claim RepoPrompt cannot make.
    func testDuplicateLabelsCollapseIntoTheOtherOverseenLanePhrase() throws {
        let built = try XCTUnwrap(attribution(names: ["Build API", "Build API"]))
        XCTAssertEqual(built.labels, ["Build API"])
        XCTAssertEqual(built.attributedLaneCount, 2)
        XCTAssertEqual(
            try sentence(names: ["Build API", "Build API"]),
            "\(opening) updates for overseen lane \u{201C}Build API\u{201D} and 1 other overseen lane."
        )
    }

    /// A name made entirely of invisible scalars is not a name. It is counted, never rendered as an
    /// empty pair of quotes.
    func testALaneWhoseWholeNameIsInvisibleIsCountedButNotNamed() throws {
        let built = try XCTUnwrap(attribution(names: ["\u{200B}\u{202E}\u{FEFF}", "Docs"]))
        XCTAssertEqual(built.labels, ["Docs"])
        XCTAssertEqual(built.attributedLaneCount, 2)
    }

    func testLabelsFollowRenderedOrderAndStopAtTwo() throws {
        let built = try XCTUnwrap(attribution(names: ["Alpha", "Beta", "Gamma", "Delta"]))
        XCTAssertEqual(built.labels, ["Alpha", "Beta"])
        XCTAssertEqual(built.attributedLaneCount, 4)
        XCTAssertLessThanOrEqual(
            built.labels.count,
            AgentLaneUpdateDisplayAttribution.maximumLabelCount
        )
    }

    // MARK: - Overflow

    /// Overflow with no surviving lane has nothing to attribute, so the generic row is already the
    /// whole truth and the richer sentence is declined outright.
    func testOverflowOnlyBatchKeepsTheGenericRawRow() throws {
        let built = try XCTUnwrap(AgentLaneUpdateDisplayAttribution.make(
            renderedEntries: [],
            includesUnattributedOverflow: true
        ))
        XCTAssertEqual(built.attributedLaneCount, 0)
        XCTAssertTrue(built.labels.isEmpty)
        XCTAssertTrue(built.isValid)
        XCTAssertNil(AgentLaneUpdateDisplayAttribution.richDisplayText(
            rawText: AgentLaneUpdateDisplayAttribution.canonicalSystemText,
            attribution: built
        ))
    }

    func testMixedOverflowAppendsExactlyTheDisclosureSentence() throws {
        XCTAssertEqual(
            try sentence(names: ["Build API"], overflow: true),
            "\(opening) an update for overseen lane \u{201C}Build API\u{201D}. "
                + AgentLaneUpdateDisplayAttribution.unattributedOverflowSentence
        )
    }

    /// Nothing delivered and nothing dropped describes nothing at all.
    func testAnEmptyBatchWithoutOverflowProducesNoAttribution() {
        XCTAssertNil(AgentLaneUpdateDisplayAttribution.make(
            renderedEntries: [],
            includesUnattributedOverflow: false
        ))
    }

    // MARK: - Bounds and sanitization

    /// The reducer's attributed-lane bound is the authority. A batch that somehow exceeded it is a
    /// broken invariant, and omitting attribution keeps the truthful generic row rather than
    /// clamping into a count that never happened.
    func testABatchBeyondTheReducerBoundProducesNoAttribution() {
        let bound = AgentSessionLinkPassiveStatusNotices.maximumPendingTargetCount
        let oversized = (0 ... bound).map {
            entry(
                $0,
                name: "Target \($0)",
                reference: DomainAgentSessionLinkReference(linkID: UUID(), generation: 1)
            )
        }
        XCTAssertEqual(oversized.count, bound + 1)
        XCTAssertNil(AgentLaneUpdateDisplayAttribution.make(
            renderedEntries: oversized,
            includesUnattributedOverflow: false
        ))
    }

    /// Reference identity, not name or session UUID, is what makes a lane distinct — and the same
    /// reference rendered twice is still one lane.
    func testDuplicateReferencesCountOnce() throws {
        let shared = DomainAgentSessionLinkReference(linkID: UUID(), generation: 1)
        let built = try XCTUnwrap(AgentLaneUpdateDisplayAttribution.make(
            renderedEntries: [
                entry(0, name: "Build API", reference: shared),
                entry(1, name: "Docs", reference: shared)
            ],
            includesUnattributedOverflow: false
        ))
        XCTAssertEqual(built.attributedLaneCount, 1)
        XCTAssertEqual(built.labels, ["Build API"])
    }

    /// Format, bidi, and zero-width scalars are the narrow defense this layer adds: a name can
    /// otherwise reorder the sentence around it or hide characters from the reader entirely.
    func testFormatAndBidiScalarsAreStrippedFromLabels() throws {
        let hostile = "Bui\u{200B}ld\u{202E} A\u{2069}PI\u{FEFF}\u{00AD}"
        let built = try XCTUnwrap(attribution(names: [hostile]))
        XCTAssertEqual(built.labels, ["Build API"])
        let rendered = try sentence(names: [hostile])
        for scalar in ["\u{200B}", "\u{202E}", "\u{2069}", "\u{FEFF}", "\u{00AD}"] {
            XCTAssertFalse(
                rendered.contains(scalar),
                "an invisible scalar must never survive into the rendered sentence"
            )
        }
    }

    /// A label may not close the quote span the sentence grammar opened around it.
    ///
    /// Without this the sentence is forgeable by a target's own display name: the label is untrusted
    /// data rendered inside trusted RepoPrompt prose, so a name carrying the closing delimiter can
    /// read as though the quoted span ended and the rest is RepoPrompt speaking.
    func testCurlyQuoteDelimitersInsideLabelsCannotCloseTheQuotedSpan() throws {
        let forged = "Build\u{201D} and 9 other overseen lanes\u{201C}"
        let built = try XCTUnwrap(attribution(names: [forged]))
        let label = try XCTUnwrap(built.labels.first)
        XCTAssertFalse(label.contains("\u{201C}"))
        XCTAssertFalse(label.contains("\u{201D}"))
        XCTAssertEqual(label, "Build\" and 9 other overseen lanes\"")

        let rendered = try sentence(names: [forged])
        XCTAssertEqual(
            rendered.components(separatedBy: "\u{201C}").count - 1,
            1,
            "exactly one opening delimiter, and it belongs to the grammar"
        )
        XCTAssertEqual(
            rendered.components(separatedBy: "\u{201D}").count - 1,
            1,
            "exactly one closing delimiter, and it belongs to the grammar"
        )
    }

    func testHostileLocationAndTaskAreSanitizedAsOneLabel() throws {
        let location = "kid\u{200B}friendly\u{202E}-nova\u{201D}"
        let task = "Build\u{2069} API\u{201C}"
        let built = try XCTUnwrap(attribution(
            names: [task],
            locationLabelsByReference: [reference(0): location]
        ))

        XCTAssertEqual(built.labels, ["kidfriendly-nova\": Build API\""])
        for scalar in ["\u{200B}", "\u{202E}", "\u{2069}", "\u{201C}", "\u{201D}"] {
            XCTAssertFalse(try XCTUnwrap(built.labels.first).contains(scalar))
        }
    }

    func testLocationPrefixIsAllOrNothingWithinExistingSingleLabelByteCap() throws {
        let task = String(repeating: "T", count: 100)
        let fittingLocation = String(repeating: "L", count: 18)
        let oversizedLocation = fittingLocation + "L"

        let fitting = try XCTUnwrap(attribution(
            names: [task],
            locationLabelsByReference: [reference(0): fittingLocation]
        ))
        let oversized = try XCTUnwrap(attribution(
            names: [task],
            locationLabelsByReference: [reference(0): oversizedLocation]
        ))

        XCTAssertEqual(
            try XCTUnwrap(fitting.labels.first).utf8.count,
            DomainAgentSessionLinkTextBudget.displayNameMaxBytes
        )
        XCTAssertEqual(fitting.labels, ["\(fittingLocation): \(task)"])
        XCTAssertEqual(
            oversized.labels,
            [task],
            "presentation context must be omitted rather than truncate the identifying task"
        )
    }

    /// The existing normalization and byte cap stay authoritative: no second per-label budget is
    /// introduced here, so a long name is capped exactly where the link text budget caps it.
    func testExistingDisplayNameNormalizationAndByteCapRemainAuthoritative() throws {
        let long = String(repeating: "A", count: 400)
        let built = try XCTUnwrap(attribution(names: [long]))
        let label = try XCTUnwrap(built.labels.first)
        XCTAssertEqual(
            label.utf8.count,
            DomainAgentSessionLinkTextBudget.displayNameMaxBytes
        )
        XCTAssertEqual(
            label,
            DomainAgentSessionLinkTextBudget.normalized(
                long,
                maxBytes: DomainAgentSessionLinkTextBudget.displayNameMaxBytes
            )
        )
    }

    /// Sanitization has to be a fixed point, because decode validation re-derives the canonical form
    /// and rejects any label that does not already equal it.
    func testSanitizationIsIdempotent() throws {
        let once = try XCTUnwrap(AgentLaneUpdateDisplayAttribution.sanitizedLabel(
            "  Build\u{200B}   API\n "
        ))
        XCTAssertEqual(AgentLaneUpdateDisplayAttribution.sanitizedLabel(once), once)
        XCTAssertEqual(once, "Build API")
    }

    // MARK: - Rich display gating

    func testRichDisplayIsDeclinedForNonCanonicalTextAndNonSystemRows() throws {
        let built = try XCTUnwrap(attribution(names: ["Build API"]))
        XCTAssertNil(AgentLaneUpdateDisplayAttribution.richDisplayText(
            rawText: "[lane-update] something a different build wrote.",
            attribution: built
        ))
        var assistantRow = AgentChatItem.assistant(
            AgentLaneUpdateDisplayAttribution.canonicalSystemText
        )
        assistantRow.laneUpdateDisplayAttribution = built
        XCTAssertNil(AgentLaneUpdateDisplayAttribution.richDisplayText(for: assistantRow))
    }

    func testRichDisplayIsDeclinedWithoutMetadata() {
        XCTAssertNil(AgentLaneUpdateDisplayAttribution.richDisplayText(
            rawText: AgentLaneUpdateDisplayAttribution.canonicalSystemText,
            attribution: nil
        ))
    }

    func testAcceptedRowKeepsTheCanonicalRawTextAndCarriesTheMetadata() throws {
        let built = try XCTUnwrap(attribution(names: ["Build API", "Docs"]))
        let wakeID = UUID()
        let row = AgentChatItem.laneUpdateAutoWake(
            wakeID: wakeID,
            acceptedAt: Date(timeIntervalSince1970: 100),
            sequenceIndex: 4,
            displayAttribution: built
        )
        XCTAssertEqual(row.id, wakeID)
        XCTAssertEqual(row.kind, .system)
        XCTAssertEqual(row.text, AgentLaneUpdateDisplayAttribution.canonicalSystemText)
        XCTAssertEqual(row.laneUpdateDisplayAttribution, built)
        XCTAssertEqual(
            AgentLaneUpdateDisplayAttribution.richDisplayText(for: row),
            "\(opening) updates for overseen lanes \u{201C}Build API\u{201D} and \u{201C}Docs\u{201D}."
        )
    }

    /// The default keeps the factory source-compatible and the generic row constructible.
    func testAcceptedRowWithoutAttributionRendersTheGenericRawText() {
        let row = AgentChatItem.laneUpdateAutoWake(wakeID: UUID(), acceptedAt: Date())
        XCTAssertNil(row.laneUpdateDisplayAttribution)
        XCTAssertNil(AgentLaneUpdateDisplayAttribution.richDisplayText(for: row))
    }

    // MARK: - Malformed metadata

    /// Every one of these is a payload a rollback, a hand-edit, or a future format change could
    /// produce. None of them may take the enclosing transcript row down with them.
    func testMalformedMetadataDecodesToNilWithoutFailingTheEnclosingItem() throws {
        let payloads = [
            #""not-an-object""#,
            "[]",
            #"{"labels":5,"attributedLaneCount":1}"#,
            #"{"labels":["A"],"attributedLaneCount":"one"}"#,
            #"{"attributedLaneCount":1}"#,
            #"{"labels":["A","A"],"attributedLaneCount":2}"#,
            #"{"labels":["A","B","C"],"attributedLaneCount":3}"#,
            #"{"labels":[""],"attributedLaneCount":1}"#,
            #"{"labels":["A","B"],"attributedLaneCount":1}"#,
            #"{"labels":[],"attributedLaneCount":17}"#,
            #"{"labels":[],"attributedLaneCount":-1}"#,
            #"{"labels":["A"],"attributedLaneCount":0}"#,
            #"{"labels":[],"attributedLaneCount":0,"includesUnattributedOverflow":false}"#,
            "{\"labels\":[\"Build\u{200B}API\"],\"attributedLaneCount\":1}",
            #"{"labels":["  padded  "],"attributedLaneCount":1}"#
        ]
        for payload in payloads {
            let json = """
            {"id":"\(UUID().uuidString)","timestamp":0,"kind":"system",\
            "text":"\(AgentLaneUpdateDisplayAttribution.canonicalSystemText)",\
            "sequenceIndex":1,"laneUpdateDisplayAttribution":\(payload)}
            """
            let item = try JSONDecoder().decode(AgentChatItem.self, from: Data(json.utf8))
            XCTAssertNil(
                item.laneUpdateDisplayAttribution,
                "malformed metadata must be dropped: \(payload)"
            )
            XCTAssertEqual(item.text, AgentLaneUpdateDisplayAttribution.canonicalSystemText)
            XCTAssertNil(AgentLaneUpdateDisplayAttribution.richDisplayText(for: item))

            let persisted = try JSONDecoder().decode(
                AgentChatItemPersist.self,
                from: Data(json.utf8)
            )
            XCTAssertNil(
                persisted.laneUpdateDisplayAttribution,
                "malformed persisted metadata must be dropped: \(payload)"
            )
        }
    }

    /// Rows written before this field existed keep loading, which is also the rollback story viewed
    /// from the other side.
    func testLegacyLaneUpdateRowDecodesWithNilAttribution() throws {
        let json = """
        {"id":"\(UUID().uuidString)","timestamp":0,"kind":"system",\
        "text":"\(AgentLaneUpdateDisplayAttribution.canonicalSystemText)","sequenceIndex":1}
        """
        let item = try JSONDecoder().decode(AgentChatItem.self, from: Data(json.utf8))
        XCTAssertNil(item.laneUpdateDisplayAttribution)
        XCTAssertEqual(item.text, AgentLaneUpdateDisplayAttribution.canonicalSystemText)
    }

    /// A carrier that holds an activity wholesale would otherwise write malformed labels straight
    /// back out on the next save.
    func testInvalidMetadataIsNotReEncoded() throws {
        let invalid = try JSONDecoder().decode(
            AgentLaneUpdateDisplayAttribution.self,
            from: Data("{\"labels\":[\"Bad\u{200B}Label\"],\"attributedLaneCount\":1}".utf8)
        )
        XCTAssertFalse(invalid.isValid)
        XCTAssertNil(invalid.validated)

        let reencoded = try JSONEncoder().encode(invalid)
        XCTAssertEqual(String(decoding: reencoded, as: UTF8.self), "{}")
    }

    // MARK: - Persistence carriers

    /// The same carriers cross-session attribution had to be threaded through: a field on
    /// `AgentChatItem` alone disappears the moment a turn is persisted or rebuilt.
    func testAttributionSurvivesEveryReconstructionCarrier() throws {
        let built = try XCTUnwrap(attribution(
            names: ["Build API", "Docs", nil],
            locationLabelsByReference: [
                reference(0): "kidfriendly-nova",
                reference(1): "RepoPrompt (main)"
            ]
        ))
        let row = AgentChatItem.laneUpdateAutoWake(
            wakeID: UUID(),
            acceptedAt: Date(timeIntervalSince1970: 100),
            sequenceIndex: 2,
            displayAttribution: built
        )

        let decodedItem = try JSONDecoder().decode(
            AgentChatItem.self,
            from: JSONEncoder().encode(row)
        )
        XCTAssertEqual(decodedItem.laneUpdateDisplayAttribution, built)
        XCTAssertEqual(row.replacingID(UUID()).laneUpdateDisplayAttribution, built)

        let persisted = AgentChatItemPersist(from: row)
        XCTAssertEqual(persisted.laneUpdateDisplayAttribution, built)
        let decodedPersist = try JSONDecoder().decode(
            AgentChatItemPersist.self,
            from: JSONEncoder().encode(persisted)
        )
        XCTAssertEqual(decodedPersist.laneUpdateDisplayAttribution, built)
        XCTAssertEqual(decodedPersist.toItem().laneUpdateDisplayAttribution, built)

        let activity = AgentTranscriptActivity(from: row)
        XCTAssertEqual(activity.laneUpdateDisplayAttribution, built)
        XCTAssertEqual(activity.toItem().laneUpdateDisplayAttribution, built)
        let decodedActivity = try JSONDecoder().decode(
            AgentTranscriptActivity.self,
            from: JSONEncoder().encode(activity)
        )
        XCTAssertEqual(decodedActivity.laneUpdateDisplayAttribution, built)
    }

    /// Whole-transcript reconstruction is where an omitted carrier field actually shows up.
    func testAttributionSurvivesCanonicalTranscriptReconstruction() throws {
        let built = try XCTUnwrap(attribution(names: ["Build API"]))
        let items = [
            AgentChatItem.laneUpdateAutoWake(
                wakeID: UUID(),
                acceptedAt: Date(timeIntervalSince1970: 100),
                sequenceIndex: 0,
                displayAttribution: built
            ),
            AgentChatItem.assistant("Noted.", sequenceIndex: 1)
        ]
        let transcript = AgentTranscriptIO.buildTranscript(from: items)
        let rows = AgentTranscriptIO.flattenFullTranscript(transcript)
        let systemRow = rows.first { $0.kind == .system }
        XCTAssertEqual(systemRow?.laneUpdateDisplayAttribution, built)
    }

    // MARK: - Replay and cross-session privacy

    /// The whole point of keeping the raw text generic: what the model is replayed, and what any
    /// other session or export can read, says nothing about which lanes changed.
    func testProviderReplaySerializesOnlyTheGenericRawRow() throws {
        let built = try XCTUnwrap(attribution(
            names: ["Build API", "Docs"],
            overflow: true,
            locationLabelsByReference: [
                reference(0): "kidfriendly-nova",
                reference(1): "RepoPrompt (main)"
            ]
        ))
        let items = [
            AgentChatItem.user("go", sequenceIndex: 0),
            AgentChatItem.laneUpdateAutoWake(
                wakeID: UUID(),
                acceptedAt: Date(timeIntervalSince1970: 100),
                sequenceIndex: 1,
                displayAttribution: built
            )
        ]
        let transcript = AgentTranscriptIO.importLegacyItems(items)
        let replay = AgentTranscriptIO.buildConversationHistory(from: transcript)

        XCTAssertTrue(replay.contains(
            "<system>\(AgentLaneUpdateDisplayAttribution.canonicalSystemText)</system>"
        ))
        for forbidden in [
            "Build API",
            "Docs",
            "kidfriendly-nova",
            "RepoPrompt (main)",
            "overseen lane",
            "overseen lanes",
            AgentLaneUpdateDisplayAttribution.unattributedOverflowSentence
        ] {
            XCTAssertFalse(
                replay.contains(forbidden),
                "provider replay must not carry local display attribution: \(forbidden)"
            )
        }
        XCTAssertEqual(
            AgentTranscriptIO.serializeConversationHistory(from: transcript).text,
            replay
        )
    }

    func testCrossSessionProjectionEmitsOnlyTheCanonicalRawRow() throws {
        let built = try XCTUnwrap(attribution(
            names: ["Build API"],
            locationLabelsByReference: [reference(0): "kidfriendly-nova"]
        ))
        let row = AgentChatItem.laneUpdateAutoWake(
            wakeID: UUID(),
            acceptedAt: Date(timeIntervalSince1970: 100),
            displayAttribution: built
        )

        let projected = try XCTUnwrap(AgentSessionLinkTranscriptSanitizer.sanitize(
            row: row,
            homeDirectory: "/Users/local"
        ))
        XCTAssertEqual(projected.role, .system)
        XCTAssertEqual(projected.text, AgentLaneUpdateDisplayAttribution.canonicalSystemText)
        XCTAssertFalse(projected.text?.contains("kidfriendly-nova") == true)
        XCTAssertFalse(projected.text?.contains("Build API") == true)
    }

    /// The encoded session file may carry the labels, because that file is the local transcript.
    /// Nothing derived from `text` may.
    func testEncodedRowCarriesLabelsOnlyInTheLocalDisplayFieldAndNeverInText() throws {
        let built = try XCTUnwrap(attribution(
            names: ["Build API"],
            locationLabelsByReference: [reference(0): "kidfriendly-nova"]
        ))
        let row = AgentChatItem.laneUpdateAutoWake(
            wakeID: UUID(),
            acceptedAt: Date(timeIntervalSince1970: 100),
            displayAttribution: built
        )
        let encoded = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(row)
        ) as? [String: Any]
        let object = try XCTUnwrap(encoded)
        XCTAssertEqual(
            object["text"] as? String,
            AgentLaneUpdateDisplayAttribution.canonicalSystemText
        )
        let metadata = try XCTUnwrap(object["laneUpdateDisplayAttribution"] as? [String: Any])
        XCTAssertEqual(metadata["labels"] as? [String], ["kidfriendly-nova: Build API"])
        XCTAssertEqual(metadata["attributedLaneCount"] as? Int, 1)
        // No identity of any kind travels with the labels.
        for forbidden in [
            "reference",
            "linkID",
            "sessionID",
            "endpoint",
            "targetSessionID",
            "location",
            "locationLabel",
            "locationLabelsByReference"
        ] {
            XCTAssertNil(metadata[forbidden], "attribution must not persist \(forbidden)")
        }
    }
}
