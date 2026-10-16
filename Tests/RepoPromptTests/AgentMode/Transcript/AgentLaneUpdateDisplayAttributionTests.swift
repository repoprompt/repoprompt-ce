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
        reference overrideReference: DomainAgentSessionLinkReference? = nil,
        from fromStatus: AgentSessionLinkPassiveStatusNotices.Status = .running,
        to toStatus: AgentSessionLinkPassiveStatusNotices.Status = .idle,
        targetSessionID: UUID = UUID(),
        preview: String? = nil
    ) -> AgentSessionLinkPassiveStatusNotices.PendingEntry {
        AgentSessionLinkPassiveStatusNotices.PendingEntry(
            reference: overrideReference ?? reference(index),
            targetEndpoint: endpoint(),
            targetSessionID: targetSessionID,
            displayName: name,
            fromStatus: fromStatus,
            toStatus: toStatus,
            latestVisibleAssistantPreview: preview,
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
            "\(opening) an update for overseen lane \u{201C}Build API\u{201D} (now idle)."
        )
    }

    func testOneNamedLaneWithOneUnnamedLaneUsesTheSingularOtherPhrase() throws {
        XCTAssertEqual(
            try sentence(names: ["Build API", nil]),
            "\(opening) updates for overseen lane \u{201C}Build API\u{201D} (now idle) and 1 other overseen lane."
        )
    }

    func testOneNamedLaneWithSeveralUnnamedLanesUsesThePluralOtherPhrase() throws {
        XCTAssertEqual(
            try sentence(names: ["Build API", nil, nil, nil]),
            "\(opening) updates for overseen lane \u{201C}Build API\u{201D} (now idle) and 3 other overseen lanes."
        )
    }

    func testTwoNamedLanesAreJoinedWithAnd() throws {
        XCTAssertEqual(
            try sentence(names: ["Build API", "Docs"]),
            "\(opening) updates for overseen lanes \u{201C}Build API\u{201D} (now idle) and \u{201C}Docs\u{201D} (now idle)."
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
            "\(opening) updates for overseen lanes \u{201C}kidfriendly-nova: Build API\u{201D} (now idle) "
                + "and \u{201C}RepoPrompt (main): Docs\u{201D} (now idle)."
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
            "\(opening) updates for overseen lanes \u{201C}Build API\u{201D} (now idle), \u{201C}Docs\u{201D} (now idle), and 1 other overseen lane."
        )
    }

    func testTwoNamedLanesWithSeveralOtherLanesUseThePluralSerialForm() throws {
        XCTAssertEqual(
            try sentence(names: ["Build API", "Docs", "Infra", "Release"]),
            "\(opening) updates for overseen lanes \u{201C}Build API\u{201D} (now idle), \u{201C}Docs\u{201D} (now idle), and 2 other overseen lanes."
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
            "\(opening) updates for overseen lane \u{201C}Build API\u{201D} (now idle) and 1 other overseen lane."
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
            "\(opening) an update for overseen lane \u{201C}Build API\u{201D} (now idle). "
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
            "\(opening) updates for overseen lanes \u{201C}Build API\u{201D} (now idle) and \u{201C}Docs\u{201D} (now idle)."
        )
    }

    /// The default keeps the factory source-compatible and the generic row constructible.
    func testAcceptedRowWithoutAttributionRendersTheGenericRawText() {
        let row = AgentChatItem.laneUpdateAutoWake(wakeID: UUID(), acceptedAt: Date())
        XCTAssertNil(row.laneUpdateDisplayAttribution)
        XCTAssertNil(AgentLaneUpdateDisplayAttribution.richDisplayText(for: row))
    }

    // MARK: - Claim-time lane status

    private typealias Change = AgentLaneUpdateDisplayAttribution.LaneStatusChange

    /// Which linked session did what: each named lane carries the change of the exact rendered entry
    /// that supplied its label, in rendered order.
    func testEachLabelCarriesItsOwnRenderedEntryStatus() throws {
        let built = try XCTUnwrap(AgentLaneUpdateDisplayAttribution.make(
            renderedEntries: [
                entry(0, name: "Alpha", from: .running, to: .waiting),
                entry(1, name: "Beta", from: .running, to: .idle),
                entry(2, name: "Gamma", from: .waiting, to: .idle)
            ],
            includesUnattributedOverflow: false
        ))

        XCTAssertEqual(built.labels, ["Alpha", "Beta"])
        XCTAssertEqual(built.labelStatusChanges, [
            Change(from: .running, to: .waiting),
            Change(from: .running, to: .idle)
        ])
        XCTAssertEqual(
            AgentLaneUpdateDisplayAttribution.richDisplayText(
                rawText: AgentLaneUpdateDisplayAttribution.canonicalSystemText,
                attribution: built
            ),
            "\(opening) updates for overseen lanes \u{201C}Alpha\u{201D} (waiting for input), "
                + "\u{201C}Beta\u{201D} (now idle), and 1 other overseen lane."
        )
    }

    /// An unnamed lane and a duplicate-named lane are skipped for labels, and must be skipped for
    /// statuses too — otherwise a later lane's change would be attached to an earlier lane's name.
    func testSkippedLanesNeverShiftStatusesOntoOtherLabels() throws {
        let built = try XCTUnwrap(AgentLaneUpdateDisplayAttribution.make(
            renderedEntries: [
                entry(0, name: nil, from: .running, to: .waiting),
                entry(1, name: "Alpha", from: .running, to: .idle),
                entry(2, name: "Alpha", from: .running, to: .waiting),
                entry(3, name: "Beta", from: .idle, to: .waiting)
            ],
            includesUnattributedOverflow: false
        ))

        XCTAssertEqual(built.labels, ["Alpha", "Beta"])
        XCTAssertEqual(built.labelStatusChanges, [
            Change(from: .running, to: .idle),
            Change(from: .idle, to: .waiting)
        ])
        XCTAssertEqual(built.attributedLaneCount, 4)
    }

    /// RepoPrompt observed that a target stopped, not that its work succeeded.
    func testNoStatusPhraseClaimsSuccess() {
        XCTAssertEqual(AgentLaneUpdateDisplayAttribution.LaneStatus.idle.currentStatePhrase, "now idle")
        XCTAssertEqual(
            AgentLaneUpdateDisplayAttribution.LaneStatus.waiting.currentStatePhrase,
            "waiting for input"
        )
        for status in AgentLaneUpdateDisplayAttribution.LaneStatus.allCases {
            let phrases = [
                status.currentStatePhrase,
                status.title,
                Change(from: .running, to: status).changeDescription
            ].map { $0.lowercased() }
            for phrase in phrases {
                for claim in ["done", "success", "succeed", "complete", "finish", "passed"] {
                    XCTAssertFalse(phrase.contains(claim), "\(status): \(phrase)")
                }
            }
        }
    }

    func testReducerStatusVocabularyMapsOneToOne() {
        for status in AgentSessionLinkPassiveStatusNotices.Status.allCases {
            XCTAssertEqual(
                AgentLaneUpdateDisplayAttribution.LaneStatus(status).rawValue,
                status.rawValue
            )
        }
    }

    /// Only the coarse enum pair is persisted alongside the labels.
    func testStatusesRoundTripAsTheCoarsePairOnly() throws {
        let built = try XCTUnwrap(AgentLaneUpdateDisplayAttribution.make(
            renderedEntries: [
                entry(0, name: "Alpha", from: .running, to: .waiting, preview: "SECRET PREVIEW")
            ],
            includesUnattributedOverflow: false
        ))
        let data = try JSONEncoder().encode(built)
        XCTAssertEqual(try JSONDecoder().decode(AgentLaneUpdateDisplayAttribution.self, from: data), built)

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let changes = try XCTUnwrap(object["labelStatusChanges"] as? [[String: Any]])
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(Set(changes[0].keys), ["from", "to"])
        XCTAssertEqual(changes[0]["from"] as? String, "running")
        XCTAssertEqual(changes[0]["to"] as? String, "waiting")
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("SECRET PREVIEW"))
    }

    /// Rows written before statuses were captured keep their labels and simply show no status.
    func testLegacyLabelsOnlyPayloadStaysValidWithoutStatuses() throws {
        let legacy = try JSONDecoder().decode(
            AgentLaneUpdateDisplayAttribution.self,
            from: Data(#"{"labels":["Alpha","Beta"],"attributedLaneCount":5}"#.utf8)
        )
        XCTAssertTrue(legacy.isValid)
        XCTAssertNil(legacy.labelStatusChanges)

        let presentation = try XCTUnwrap(AgentLaneUpdateDisplayAttribution.rowPresentation(
            rawText: AgentLaneUpdateDisplayAttribution.canonicalSystemText,
            attribution: legacy
        ))
        XCTAssertEqual(presentation.lanes.map(\.label), ["Alpha", "Beta"])
        XCTAssertEqual(presentation.lanes.map(\.statusChange), [nil, nil])
        XCTAssertEqual(presentation.additionalLanesText, "+3 more overseen lanes")
        XCTAssertEqual(
            presentation.accessibilityLabel,
            "Lane update. RepoPrompt auto-woke this session for 5 overseen lanes. "
                + "\u{201C}Alpha\u{201D}, status not recorded. "
                + "\u{201C}Beta\u{201D}, status not recorded. "
                + "Plus 3 more overseen lanes."
        )
    }

    /// A bad status array is decoration gone wrong, not a reason to lose exact labels — and it must
    /// never pair a lane with a status it may not have had.
    func testMalformedStatusesDegradeToLabelsOnly() throws {
        let payloads = [
            #"{"labels":["Alpha"],"attributedLaneCount":1,"labelStatusChanges":"idle"}"#,
            #"{"labels":["Alpha"],"attributedLaneCount":1,"labelStatusChanges":[{"from":"running","to":"done"}]}"#,
            #"{"labels":["Alpha"],"attributedLaneCount":1,"labelStatusChanges":[{"from":"running"}]}"#,
            #"{"labels":["Alpha"],"attributedLaneCount":1,"labelStatusChanges":[]}"#,
            #"{"labels":["Alpha"],"attributedLaneCount":2,"labelStatusChanges":[{"from":"running","to":"idle"},{"from":"running","to":"waiting"}]}"#
        ]
        for payload in payloads {
            let decoded = try JSONDecoder().decode(
                AgentLaneUpdateDisplayAttribution.self,
                from: Data(payload.utf8)
            )
            XCTAssertTrue(decoded.isValid, payload)
            XCTAssertEqual(decoded.labels, ["Alpha"], payload)
            XCTAssertNil(decoded.labelStatusChanges, payload)

            let reencoded = try XCTUnwrap(
                JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any]
            )
            XCTAssertNil(reencoded["labelStatusChanges"], "a dropped array must not be resaved: \(payload)")
        }
    }

    // MARK: - Row presentation

    func testRowPresentationListsEachLaneWithItsStatusAndATruthfulPlusTail() throws {
        let built = try XCTUnwrap(AgentLaneUpdateDisplayAttribution.make(
            renderedEntries: [
                entry(0, name: "Alpha", from: .running, to: .waiting),
                entry(1, name: "Beta", from: .running, to: .idle),
                entry(2, name: "Gamma"),
                entry(3, name: nil),
                entry(4, name: "Delta")
            ],
            includesUnattributedOverflow: true,
            locationLabelsByReference: [reference(1): "kidfriendly-nova"]
        ))
        let presentation = try XCTUnwrap(AgentLaneUpdateDisplayAttribution.rowPresentation(
            rawText: AgentLaneUpdateDisplayAttribution.canonicalSystemText,
            attribution: built
        ))

        XCTAssertEqual(AgentLaneUpdateDisplayAttribution.RowPresentation.title, "Lane update")
        XCTAssertEqual(presentation.summary, "RepoPrompt auto-woke this session for 5 overseen lanes.")
        XCTAssertEqual(presentation.lanes.map(\.quotedLabel), [
            "\u{201C}Alpha\u{201D}",
            "\u{201C}kidfriendly-nova: Beta\u{201D}"
        ])
        XCTAssertEqual(
            presentation.lanes.map { $0.statusChange?.to.currentStatePhrase },
            ["waiting for input", "now idle"]
        )
        XCTAssertEqual(presentation.additionalLaneCount, 3)
        XCTAssertEqual(presentation.additionalLanesText, "+3 more overseen lanes")
        XCTAssertEqual(
            presentation.overflowNote,
            AgentLaneUpdateDisplayAttribution.unattributedOverflowSentence
        )
        XCTAssertEqual(
            presentation.accessibilityLabel,
            "Lane update. RepoPrompt auto-woke this session for 5 overseen lanes. "
                + "\u{201C}Alpha\u{201D} changed from Running to Waiting for input. "
                + "\u{201C}kidfriendly-nova: Beta\u{201D} changed from Running to Idle. "
                + "Plus 3 more overseen lanes. "
                + AgentLaneUpdateDisplayAttribution.unattributedOverflowSentence
        )
    }

    func testSingleExtraLaneUsesTheSingularPlusTail() throws {
        let presentation = try XCTUnwrap(AgentLaneUpdateDisplayAttribution.rowPresentation(
            rawText: AgentLaneUpdateDisplayAttribution.canonicalSystemText,
            attribution: attribution(names: ["Alpha", "Beta", "Gamma"])
        ))
        XCTAssertEqual(presentation.additionalLanesText, "+1 more overseen lane")
        XCTAssertNil(presentation.overflowNote)
    }

    /// With nothing named, the summary already states the whole count; a `+N` would be additional
    /// to nothing.
    func testUnnamedOnlyBatchStatesTheCountWithoutAPlusTail() throws {
        let presentation = try XCTUnwrap(AgentLaneUpdateDisplayAttribution.rowPresentation(
            rawText: AgentLaneUpdateDisplayAttribution.canonicalSystemText,
            attribution: attribution(names: [nil, nil, nil])
        ))
        XCTAssertEqual(presentation.summary, "RepoPrompt auto-woke this session for 3 overseen lanes.")
        XCTAssertTrue(presentation.lanes.isEmpty)
        XCTAssertNil(presentation.additionalLanesText)

        let single = try XCTUnwrap(AgentLaneUpdateDisplayAttribution.rowPresentation(
            rawText: AgentLaneUpdateDisplayAttribution.canonicalSystemText,
            attribution: attribution(names: [nil])
        ))
        XCTAssertEqual(single.summary, "RepoPrompt auto-woke this session for 1 overseen lane.")
    }

    /// Legacy, malformed, and overflow-only rows still get the system row, with the generic body that
    /// was already the whole truth for them.
    func testCanonicalRowsWithoutPresentableMetadataUseTheGenericBody() throws {
        let malformed = try JSONDecoder().decode(
            AgentLaneUpdateDisplayAttribution.self,
            from: Data(#"{"labels":["A","A"],"attributedLaneCount":2}"#.utf8)
        )
        let overflowOnly = try XCTUnwrap(AgentLaneUpdateDisplayAttribution.make(
            renderedEntries: [],
            includesUnattributedOverflow: true
        ))
        for candidate in [nil, malformed, overflowOnly] {
            let presentation = try XCTUnwrap(AgentLaneUpdateDisplayAttribution.rowPresentation(
                rawText: AgentLaneUpdateDisplayAttribution.canonicalSystemText,
                attribution: candidate
            ))
            XCTAssertEqual(presentation.summary, AgentLaneUpdateDisplayAttribution.genericRowSummary)
            XCTAssertTrue(presentation.lanes.isEmpty)
            XCTAssertNil(presentation.additionalLanesText)
            XCTAssertNil(presentation.overflowNote)
            XCTAssertEqual(
                presentation.accessibilityLabel,
                "Lane update. " + AgentLaneUpdateDisplayAttribution.genericRowSummary
            )
        }
    }

    // MARK: - Accessibility reading

    /// VoiceOver hears a readable event, never the raw provider-facing marker, for every shape of row.
    func testAccessibilityLabelNeverSpeaksTheRawMarker() throws {
        let candidates: [AgentLaneUpdateDisplayAttribution?] = [
            nil,
            attribution(names: [nil, nil]),
            attribution(names: ["Alpha"], overflow: true),
            attribution(names: ["Alpha", "Beta", "Gamma"])
        ]
        for candidate in candidates {
            let presentation = try XCTUnwrap(AgentLaneUpdateDisplayAttribution.rowPresentation(
                rawText: AgentLaneUpdateDisplayAttribution.canonicalSystemText,
                attribution: candidate
            ))
            XCTAssertTrue(presentation.accessibilityLabel.hasPrefix("Lane update. "))
            XCTAssertFalse(presentation.accessibilityLabel.contains("[lane-update]"))
            XCTAssertFalse(presentation.accessibilityLabel.contains("["))
        }
    }

    /// The spoken reading carries the full from→to transition that sighted users get on hover, in
    /// the past tense, so an old transcript never sounds like it describes the lane's current state.
    func testAccessibilityLabelSpeaksPastTenseTransitionsNotCurrentState() throws {
        let built = try XCTUnwrap(AgentLaneUpdateDisplayAttribution.make(
            renderedEntries: [
                entry(0, name: "Alpha", from: .waiting, to: .idle),
                entry(1, name: "Beta", from: .idle, to: .waiting)
            ],
            includesUnattributedOverflow: false
        ))
        let label = try XCTUnwrap(AgentLaneUpdateDisplayAttribution.rowPresentation(
            rawText: AgentLaneUpdateDisplayAttribution.canonicalSystemText,
            attribution: built
        )).accessibilityLabel

        XCTAssertEqual(
            label,
            "Lane update. RepoPrompt auto-woke this session for 2 overseen lanes. "
                + "\u{201C}Alpha\u{201D} changed from Waiting for input to Idle. "
                + "\u{201C}Beta\u{201D} changed from Idle to Waiting for input."
        )
        for status in AgentLaneUpdateDisplayAttribution.LaneStatus.allCases {
            XCTAssertFalse(
                label.contains(status.currentStatePhrase),
                "current-state phrasing must not be spoken: \(status.currentStatePhrase)"
            )
        }
    }

    func testAccessibilityLabelUsesSingularPlusTail() throws {
        let label = try XCTUnwrap(AgentLaneUpdateDisplayAttribution.rowPresentation(
            rawText: AgentLaneUpdateDisplayAttribution.canonicalSystemText,
            attribution: attribution(names: ["Alpha", nil])
        )).accessibilityLabel
        XCTAssertTrue(label.hasSuffix(
            "\u{201C}Alpha\u{201D} changed from Running to Idle. Plus 1 more overseen lane."
        ))
    }

    /// Delivery time is spoken with date context, from the same formatter the visible stamp uses.
    func testAccessibilityDeliveryValueIncludesDateContext() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let locale = Locale(identifier: "en_US_POSIX")
        let delivered = Date(timeIntervalSince1970: 1_790_000_000)

        let sameDay = MessageTimestampFormatter.string(
            from: delivered,
            includeDateContext: true,
            now: delivered.addingTimeInterval(60),
            calendar: calendar,
            locale: locale
        )
        let earlier = MessageTimestampFormatter.string(
            from: delivered,
            includeDateContext: true,
            now: delivered.addingTimeInterval(60 * 60 * 24 * 40),
            calendar: calendar,
            locale: locale
        )
        XCTAssertNotEqual(sameDay, earlier, "an older delivery must carry its date")
        XCTAssertEqual(
            AgentLaneUpdateDisplayAttribution.RowPresentation
                .accessibilityDeliveryValue(timestamp: sameDay),
            "Delivered \(sameDay)"
        )
        XCTAssertEqual(
            AgentLaneUpdateDisplayAttribution.RowPresentation
                .accessibilityDeliveryValue(timestamp: earlier),
            "Delivered \(earlier)"
        )
    }

    func testRowPresentationIsDeclinedForOtherRows() throws {
        let built = try XCTUnwrap(attribution(names: ["Alpha"]))
        XCTAssertNil(AgentLaneUpdateDisplayAttribution.rowPresentation(
            rawText: "[lane-update] something a different build wrote.",
            attribution: built
        ))
        XCTAssertNil(AgentLaneUpdateDisplayAttribution.rowPresentation(
            for: AgentChatItem.system("Context compacted.")
        ))
        var assistantRow = AgentChatItem.assistant(
            AgentLaneUpdateDisplayAttribution.canonicalSystemText
        )
        assistantRow.laneUpdateDisplayAttribution = built
        XCTAssertNil(AgentLaneUpdateDisplayAttribution.rowPresentation(for: assistantRow))

        let accepted = AgentChatItem.laneUpdateAutoWake(
            wakeID: UUID(),
            acceptedAt: Date(),
            displayAttribution: built
        )
        XCTAssertEqual(
            AgentLaneUpdateDisplayAttribution.rowPresentation(for: accepted)?.lanes.map(\.label),
            ["Alpha"]
        )
    }

    /// Nothing that identifies a target beyond its sanitized label reaches any displayed string.
    func testRowPresentationCarriesNoIdentityOrPreview() throws {
        let targetSessionID = UUID()
        let built = try XCTUnwrap(AgentLaneUpdateDisplayAttribution.make(
            renderedEntries: [
                entry(
                    0,
                    name: "Alpha",
                    from: .running,
                    to: .waiting,
                    targetSessionID: targetSessionID,
                    preview: "SECRET PREVIEW /Users/local/private.swift"
                )
            ],
            includesUnattributedOverflow: false
        ))
        let presentation = try XCTUnwrap(AgentLaneUpdateDisplayAttribution.rowPresentation(
            rawText: AgentLaneUpdateDisplayAttribution.canonicalSystemText,
            attribution: built
        ))
        let displayed = [presentation.summary, presentation.accessibilityLabel]
            + presentation.lanes.flatMap { [$0.quotedLabel, $0.statusChange?.changeDescription ?? ""] }
        for string in displayed {
            for forbidden in [
                targetSessionID.uuidString,
                reference(0).linkID.uuidString,
                "SECRET PREVIEW",
                "/Users/"
            ] {
                XCTAssertFalse(string.contains(forbidden), "\(forbidden) leaked into \(string)")
            }
        }
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
            "now idle",
            "labelStatusChanges",
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
