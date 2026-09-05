import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

/// Where accepted lane attribution comes from, and where it does not.
///
/// The immutable `RenderedPassiveBatch.entries` of the claim is the only permitted source of lane
/// identity, order, and task. That array is what actually entered the provider fragment, so it
/// naturally includes hitchhikers — a lane that did not admit the wake, one the observer never
/// selected, one a later snooze will suppress. An optional UI location joins by exact reference at
/// claim construction; both inputs are then frozen before a rename, unlink, or rebind can rewrite
/// what the delivered turn claimed to have delivered.
@MainActor
final class AgentSessionLinkAcceptedAttributionTests: XCTestCase {
    private let observerSessionID = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!

    private lazy var endpoint = DomainAgentSessionLinkEndpointIdentity(
        windowID: 1,
        workspaceID: UUID(),
        tabID: UUID(),
        sessionID: observerSessionID,
        persistentBindingGeneration: UUID(),
        bindingTransitionGeneration: 1
    )

    private lazy var epoch = AgentSessionLinkPromptEpoch(endpoint: endpoint, allowsSupplement: true)

    // MARK: - Fixtures

    private func targetSessionID(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "0000000%X-0000-0000-0000-00000000ABCD", index))!
    }

    private func reference(
        _ index: Int,
        generation: UInt64 = 1
    ) -> DomainAgentSessionLinkReference {
        DomainAgentSessionLinkReference(
            linkID: UUID(
                uuidString: String(format: "0000000%X-0000-0000-0000-000000001111", index)
            )!,
            generation: generation
        )
    }

    private func inventory(
        revision: UInt64 = 1,
        targetCount: Int,
        namePrefix: String = "Inventory name"
    ) -> AgentSessionLinkPromptInventory {
        AgentSessionLinkPromptInventory(
            observerSessionID: observerSessionID,
            linkSetRevision: revision,
            items: (0 ..< targetCount).map { index in
                AgentSessionLinkPromptInventoryItem(
                    targetSessionID: targetSessionID(index),
                    displayName: "\(namePrefix) \(index)",
                    capabilityNames: ["poll", "read", "send_when_idle", "wait"]
                )
            }
        )
    }

    private func entry(
        _ index: Int,
        name: String?,
        reference overrideReference: DomainAgentSessionLinkReference? = nil
    ) -> AgentSessionLinkPassiveStatusNotices.PendingEntry {
        AgentSessionLinkPassiveStatusNotices.PendingEntry(
            reference: overrideReference ?? reference(index),
            targetEndpoint: DomainAgentSessionLinkEndpointIdentity(
                windowID: 2,
                workspaceID: UUID(),
                tabID: UUID(),
                sessionID: targetSessionID(index),
                persistentBindingGeneration: UUID(),
                bindingTransitionGeneration: 1
            ),
            targetSessionID: targetSessionID(index),
            displayName: name,
            fromStatus: .running,
            toStatus: .idle,
            changeSequence: UInt64(index + 1)
        )
    }

    private func snapshot(
        linkSetRevision: UInt64 = 1,
        queueRevision: UInt64 = 1,
        entries: [AgentSessionLinkPassiveStatusNotices.PendingEntry],
        overflow: UInt64 = 0,
        overflowProduced: UInt64? = nil
    ) -> AgentSessionLinkPassiveStatusNotices.Snapshot {
        AgentSessionLinkPassiveStatusNotices.Snapshot(
            observerEndpoint: endpoint,
            queueEpoch: UUID(uuidString: "0000000F-0000-0000-0000-00000000BEEF")!,
            queueRevision: queueRevision,
            linkSetRevision: linkSetRevision,
            isEnabled: true,
            isDeliverable: true,
            entries: entries,
            unacknowledgedOverflowCount: overflow,
            overflowProduced: overflowProduced ?? overflow
        )
    }

    private func claim(
        entries: [AgentSessionLinkPassiveStatusNotices.PendingEntry],
        overflow: UInt64 = 0,
        overflowProduced: UInt64? = nil,
        inventoryTargetCount: Int? = nil,
        locationLabelsByReference: [DomainAgentSessionLinkReference: String] = [:]
    ) throws -> AgentSessionLinkOutboundPromptClaim {
        let store = AgentSessionLinkOutboundPromptClaimStore()
        let live = inventory(targetCount: inventoryTargetCount ?? max(entries.count, 1))
        let claimed = store.claim(
            dispatchID: .claudeNativeSend(UUID()),
            epoch: epoch,
            inventory: live,
            passiveNotices: snapshot(
                entries: entries,
                overflow: overflow,
                overflowProduced: overflowProduced
            ),
            locationLabelsByReference: locationLabelsByReference,
            render: AgentSessionLinkPrompts.rendered
        )
        return try XCTUnwrap(claimed)
    }

    // MARK: - Capture from the rendered batch

    /// Order and count come from the rendered array, and the labels come from the *entry* names the
    /// envelope actually carried — never from the membership inventory, which is a different
    /// projection that can disagree with the batch.
    func testClaimCapturesLabelsFromRenderedEntriesInRenderedOrder() throws {
        let claimed = try claim(entries: [
            entry(0, name: "Build API"),
            entry(1, name: "Docs"),
            entry(2, name: "Infra")
        ])

        let attribution = try XCTUnwrap(claimed.passive?.displayAttribution)
        XCTAssertEqual(attribution.labels, ["Build API", "Docs"])
        XCTAssertEqual(attribution.attributedLaneCount, 3)
        XCTAssertFalse(attribution.includesUnattributedOverflow)
        XCTAssertFalse(
            attribution.labels.contains(where: { $0.hasPrefix("Inventory name") }),
            "attribution must read the delivered batch, not the membership inventory"
        )
    }

    func testClaimPrefixesLocationsOnlyForExactRenderedReferences() throws {
        let claimed = try claim(
            entries: [
                entry(0, name: "Build API"),
                entry(1, name: "Docs")
            ],
            locationLabelsByReference: [
                reference(0): "kidfriendly-nova",
                reference(1): "RepoPrompt (main)"
            ]
        )

        let attribution = try XCTUnwrap(claimed.passive?.displayAttribution)
        XCTAssertEqual(attribution.labels, [
            "kidfriendly-nova: Build API",
            "RepoPrompt (main): Docs"
        ])
        XCTAssertEqual(attribution.attributedLaneCount, 2)
    }

    func testOversizedLocationPrefixesCannotCollapseDistinctClaimedTasks() throws {
        let location = String(repeating: "L", count: 100)
        let firstTask = String(repeating: "T", count: 99) + "A"
        let secondTask = String(repeating: "T", count: 99) + "B"
        let claimed = try claim(
            entries: [
                entry(0, name: firstTask),
                entry(1, name: secondTask)
            ],
            locationLabelsByReference: [
                reference(0): location,
                reference(1): location
            ]
        )

        let attribution = try XCTUnwrap(claimed.passive?.displayAttribution)
        XCTAssertEqual(attribution.labels, [firstTask, secondTask])
        XCTAssertEqual(attribution.attributedLaneCount, 2)
    }

    func testMissingAndGenerationMismatchedLocationsFallBackWithoutSuppressingTasks() throws {
        let claimed = try claim(
            entries: [
                entry(0, name: "Build API"),
                entry(1, name: "Docs")
            ],
            locationLabelsByReference: [
                reference(0, generation: 2): "replacement-worktree"
            ]
        )

        let attribution = try XCTUnwrap(claimed.passive?.displayAttribution)
        XCTAssertEqual(attribution.labels, ["Build API", "Docs"])
        XCTAssertEqual(attribution.attributedLaneCount, 2)
    }

    /// The snapshot carries no Auto-wake lane membership at all here, so every entry is an
    /// unselected hitchhiker — and every one of them is still attributed, because attribution
    /// describes what was delivered rather than what caused admission. A snoozed lane reaches this
    /// same path for the same reason: the canonical batch is never filtered.
    func testUnselectedHitchhikersAreAttributedBecauseTheyWereRendered() throws {
        let claimed = try claim(entries: [
            entry(0, name: "Build API"),
            entry(1, name: "Docs")
        ])

        XCTAssertTrue(
            snapshot(entries: []).autoWakeLanes.isEmpty,
            "fixture premise: no lane in this batch is an effectively selected wake lane"
        )
        let attribution = try XCTUnwrap(claimed.passive?.displayAttribution)
        XCTAssertEqual(attribution.attributedLaneCount, 2)
        XCTAssertEqual(attribution.labels, ["Build API", "Docs"])
    }

    func testUnnamedAndDuplicateNamedLanesAreCountedWithoutBeingNamed() throws {
        let claimed = try claim(entries: [
            entry(0, name: "Build API"),
            entry(1, name: "Build API"),
            entry(2, name: nil)
        ])

        let attribution = try XCTUnwrap(claimed.passive?.displayAttribution)
        XCTAssertEqual(attribution.labels, ["Build API"])
        XCTAssertEqual(attribution.attributedLaneCount, 3)
        XCTAssertEqual(
            AgentLaneUpdateDisplayAttribution.richDisplayText(
                rawText: AgentLaneUpdateDisplayAttribution.canonicalSystemText,
                attribution: attribution
            ),
            "[lane-update] RepoPrompt auto-woke this session and delivered updates for overseen lane "
                + "\u{201C}Build API\u{201D} and 2 other overseen lanes."
        )
    }

    // MARK: - Overflow

    /// An overflow-only envelope has no lane to name, so the metadata records the omission and the
    /// row still renders its generic raw text.
    func testOverflowOnlyClaimRecordsTheOmissionAndKeepsTheGenericRow() throws {
        let claimed = try claim(
            entries: [],
            overflow: 2,
            overflowProduced: 5,
            inventoryTargetCount: 1
        )

        let attribution = try XCTUnwrap(claimed.passive?.displayAttribution)
        XCTAssertEqual(attribution.attributedLaneCount, 0)
        XCTAssertTrue(attribution.labels.isEmpty)
        XCTAssertTrue(attribution.includesUnattributedOverflow)
        XCTAssertNil(AgentLaneUpdateDisplayAttribution.richDisplayText(
            rawText: AgentLaneUpdateDisplayAttribution.canonicalSystemText,
            attribution: attribution
        ))
    }

    func testMixedOverflowClaimAppendsTheDisclosureSentence() throws {
        let claimed = try claim(
            entries: [entry(0, name: "Build API")],
            overflow: 3,
            overflowProduced: 9
        )

        let attribution = try XCTUnwrap(claimed.passive?.displayAttribution)
        XCTAssertEqual(attribution.attributedLaneCount, 1)
        XCTAssertTrue(attribution.includesUnattributedOverflow)
        XCTAssertEqual(
            AgentLaneUpdateDisplayAttribution.richDisplayText(
                rawText: AgentLaneUpdateDisplayAttribution.canonicalSystemText,
                attribution: attribution
            ),
            "[lane-update] RepoPrompt auto-woke this session and delivered an update for overseen "
                + "lane \u{201C}Build API\u{201D}. "
                + AgentLaneUpdateDisplayAttribution.unattributedOverflowSentence
        )
    }

    /// The disclosure flag and the receipt watermark answer different questions, and this is the
    /// case that separates them: overflow was produced long ago and already acknowledged, so the
    /// watermark is nonzero while *this* envelope disclosed nothing.
    func testAcknowledgedOverflowIsNotDisclosedEvenThoughTheWatermarkIsNonzero() throws {
        let rendered = AgentSessionLinkPrompts.rendered(
            AgentSessionLinkPromptRenderRequest(
                membershipKind: nil,
                inventory: inventory(targetCount: 1),
                passiveNotices: snapshot(
                    entries: [entry(0, name: "Build API")],
                    overflow: 0,
                    overflowProduced: 5
                )
            )
        )

        let batch = try XCTUnwrap(rendered.passiveBatch)
        XCTAssertEqual(batch.overflowProducedThrough, 5)
        XCTAssertFalse(
            batch.includesUnattributedOverflow,
            "the envelope displayed omitted=\"0\", so the row must not claim changes were dropped"
        )
        XCTAssertTrue(rendered.fragment.contains("omitted=\"0\""))
        let attribution = try XCTUnwrap(AgentLaneUpdateDisplayAttribution.make(
            renderedEntries: batch.entries,
            includesUnattributedOverflow: batch.includesUnattributedOverflow
        ))
        XCTAssertFalse(attribution.includesUnattributedOverflow)
    }

    func testRenderedBatchReportsDisclosedOverflow() throws {
        let rendered = AgentSessionLinkPrompts.rendered(
            AgentSessionLinkPromptRenderRequest(
                membershipKind: nil,
                inventory: inventory(targetCount: 1),
                passiveNotices: snapshot(
                    entries: [entry(0, name: "Build API")],
                    overflow: 2,
                    overflowProduced: 7
                )
            )
        )

        let batch = try XCTUnwrap(rendered.passiveBatch)
        XCTAssertTrue(batch.includesUnattributedOverflow)
        XCTAssertEqual(batch.overflowProducedThrough, 7)
        XCTAssertTrue(rendered.fragment.contains("omitted=\"2\""))
    }

    // MARK: - Immutability and separation from the receipt

    /// The claim is a value captured at construction. Nothing that happens to the queue, the
    /// inventory, or the target afterwards can reach back into it.
    func testLaterRenamesAndQueueChangesCannotRewriteACapturedClaim() throws {
        let store = AgentSessionLinkOutboundPromptClaimStore()
        let dispatchID = AgentSessionLinkPromptDispatchID.claudeNativeSend(UUID())
        let live = inventory(targetCount: 2)
        let claimed = try XCTUnwrap(store.claim(
            dispatchID: dispatchID,
            epoch: epoch,
            inventory: live,
            passiveNotices: snapshot(entries: [
                entry(0, name: "Build API"),
                entry(1, name: "Docs")
            ]),
            render: AgentSessionLinkPrompts.rendered
        ))
        let captured = try XCTUnwrap(claimed.passive?.displayAttribution)

        // The same targets, renamed, on a newer queue revision.
        _ = store.claim(
            dispatchID: .codexNativeSend(UUID()),
            epoch: epoch,
            inventory: live,
            passiveNotices: snapshot(
                queueRevision: 9,
                entries: [
                    entry(0, name: "Renamed away"),
                    entry(1, name: "Also renamed")
                ]
            ),
            render: AgentSessionLinkPrompts.rendered
        )

        XCTAssertEqual(claimed.passive?.displayAttribution, captured)
        XCTAssertEqual(captured.labels, ["Build API", "Docs"])
    }

    func testRetryKeepsItsLocationWhileANewDispatchUsesTheCurrentClaimTimeSnapshot() throws {
        let store = AgentSessionLinkOutboundPromptClaimStore()
        let dispatchID = AgentSessionLinkPromptDispatchID.claudeNativeSend(UUID())
        let live = inventory(targetCount: 1)
        let passive = snapshot(entries: [entry(0, name: "Build API")])
        var renderCount = 0
        let render: (AgentSessionLinkPromptRenderRequest) -> AgentSessionLinkPromptRenderResult = {
            renderCount += 1
            return AgentSessionLinkPrompts.rendered($0)
        }

        let original = try XCTUnwrap(store.claim(
            dispatchID: dispatchID,
            epoch: epoch,
            inventory: live,
            passiveNotices: passive,
            locationLabelsByReference: [reference(0): "kidfriendly-nova"],
            render: render
        ))
        let retry = try XCTUnwrap(store.claim(
            dispatchID: dispatchID,
            epoch: epoch,
            inventory: live,
            passiveNotices: passive,
            locationLabelsByReference: [reference(0): "repainted-location"],
            render: render
        ))
        let nextDispatch = try XCTUnwrap(store.claim(
            dispatchID: .codexNativeSend(UUID()),
            epoch: epoch,
            inventory: live,
            passiveNotices: passive,
            locationLabelsByReference: [reference(0): "repainted-location"],
            render: render
        ))

        XCTAssertEqual(original, retry, "a transport retry must reuse immutable claim provenance")
        XCTAssertEqual(original.passive?.displayAttribution?.labels, ["kidfriendly-nova: Build API"])
        XCTAssertEqual(
            nextDispatch.passive?.displayAttribution?.labels,
            ["repainted-location: Build API"]
        )
        XCTAssertEqual(original.passive?.receipt, nextDispatch.passive?.receipt)
        XCTAssertEqual(renderCount, 1, "location must not enter the provider render fingerprint")
    }

    /// Display data must not migrate into the queue receipt: the receipt is authority the reducer
    /// settles against, and it stays exactly the delivered statuses plus the absolute watermark.
    func testReceiptCarriesNoDisplayDataAndIsUnchangedByAttribution() throws {
        let claimed = try claim(
            entries: [entry(0, name: "Build API")],
            overflow: 2,
            overflowProduced: 5,
            locationLabelsByReference: [reference(0): "kidfriendly-nova"]
        )

        let passive = try XCTUnwrap(claimed.passive)
        XCTAssertEqual(passive.receipt.deliveredStatuses.count, 1)
        XCTAssertEqual(passive.receipt.overflowProducedThrough, 5)
        XCTAssertEqual(passive.receipt.queueRevision, 1)
        XCTAssertEqual(passive.displayAttribution?.labels, ["kidfriendly-nova: Build API"])
        XCTAssertEqual(
            passive.receipt,
            AgentSessionLinkPassiveStatusNotices.Receipt(
                queueEpoch: passive.receipt.queueEpoch,
                queueRevision: 1,
                deliveredStatuses: passive.receipt.deliveredStatuses,
                overflowProducedThrough: 5
            )
        )
    }

    /// A crowded inventory now yields rows to the passive batch rather than crowding it out. UI
    /// attribution follows exactly the subset that was rendered and receipted.
    func testCrowdedInventoryStillAttributesTheRenderedPassiveSubset() throws {
        let store = AgentSessionLinkOutboundPromptClaimStore()
        let crowded = AgentSessionLinkPromptInventory(
            observerSessionID: observerSessionID,
            linkSetRevision: 1,
            items: (0 ..< 400).map { index in
                AgentSessionLinkPromptInventoryItem(
                    targetSessionID: UUID(
                        uuidString: String(format: "00000%03X-0000-0000-0000-00000000ABCD", index)
                    ) ?? targetSessionID(0),
                    displayName: "Target \(index)",
                    capabilityNames: ["poll", "read", "send_when_idle", "wait"]
                )
            }
        )
        let claimed = try XCTUnwrap(store.claim(
            dispatchID: .claudeNativeSend(UUID()),
            epoch: epoch,
            inventory: crowded,
            passiveNotices: snapshot(entries: [entry(0, name: "Build API")]),
            render: AgentSessionLinkPrompts.rendered
        ))

        let passive = try XCTUnwrap(claimed.passive)
        XCTAssertEqual(passive.receipt.deliveredStatuses.count, 1)
        XCTAssertEqual(passive.displayAttribution?.labels, ["Build API"])
        XCTAssertTrue(claimed.fragment.contains("omitted_link_count="))
        XCTAssertTrue(claimed.fragment.contains(AgentSessionLinkPrompts.statusChangeEnvelopeTag))
    }

    // MARK: - The row an acceptance will append

    /// The seam the acceptance path consumes: `claim.passive?.displayAttribution` straight into the
    /// transcript factory, with the raw text still generic.
    func testAcceptedRowBuiltFromTheClaimNamesTheDeliveredLanes() throws {
        let claimed = try claim(
            entries: [
                entry(0, name: "Build API"),
                entry(1, name: "Docs")
            ],
            locationLabelsByReference: [
                reference(0): "kidfriendly-nova",
                reference(1): "RepoPrompt (main)"
            ]
        )
        let wakeID = UUID()
        let row = AgentChatItem.laneUpdateAutoWake(
            wakeID: wakeID,
            acceptedAt: Date(timeIntervalSince1970: 100),
            sequenceIndex: 3,
            displayAttribution: claimed.passive?.displayAttribution
        )

        XCTAssertEqual(row.id, wakeID)
        XCTAssertEqual(row.text, AgentLaneUpdateDisplayAttribution.canonicalSystemText)
        XCTAssertEqual(
            AgentLaneUpdateDisplayAttribution.richDisplayText(for: row),
            "[lane-update] RepoPrompt auto-woke this session and delivered updates for overseen "
                + "lanes \u{201C}kidfriendly-nova: Build API\u{201D} and "
                + "\u{201C}RepoPrompt (main): Docs\u{201D}."
        )
    }
}
