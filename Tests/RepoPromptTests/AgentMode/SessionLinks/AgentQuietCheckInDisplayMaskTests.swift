import Combine
import Foundation
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

@MainActor
final class AgentQuietCheckInDisplayMaskTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1)

    private func projection(
        _ rows: [AgentChatItem],
        tier: AgentTranscriptRetentionTier = .condensed,
        turnID: UUID = UUID(),
        spanID: UUID = UUID(),
        conclusionID: UUID? = nil,
        summary: AgentTranscriptTurnSummary? = nil
    ) -> AgentTranscriptProjection {
        let span = AgentTranscriptProviderResponseSpan(
            id: spanID,
            lifecycle: .completed,
            startedAt: date,
            completedAt: date,
            activities: rows.map { AgentTranscriptActivity(from: $0, toolExecution: AgentTranscriptToolNormalizer.toolExecution(for: $0)) }
        )
        let turn = AgentTranscriptTurn(
            id: turnID,
            responseSpans: [span],
            conclusionActivityID: conclusionID,
            retentionTier: tier,
            summary: summary,
            terminalState: .completed,
            startedAt: date,
            completedAt: date
        )
        return AgentTranscriptProjectionBuilder.build(from: AgentTranscript(turns: [turn]))
    }

    private func presentation(_ projection: AgentTranscriptProjection) -> AgentTranscriptPresentationSnapshot {
        .init(
            revision: 7,
            visibleBlocks: projection.workingBlocks,
            workingBlocks: projection.workingBlocks,
            visibleRows: projection.workingRows,
            workingRows: projection.workingRows,
            rowAnchorIndex: projection.rowAnchorIndex,
            anchorBlockIndex: projection.anchorBlockIndex
        )
    }

    func testCondensedSameMaskNowPreservesDistinctSourceKindsAndNarrationWithoutRawRows() throws {
        let turnID = UUID(), spanID = UUID(), firstID = UUID(), quietID = UUID()
        let assignments: [(AgentChatItemKind, AgentChatItemKind)] = [(.assistant, .thinking), (.thinking, .assistant)]
        var originalNormalBlock: AgentTranscriptRenderBlock?
        for (firstKind, quietKind) in assignments {
            let rows = [
                AgentChatItem(id: firstID, timestamp: date, kind: firstKind, text: "[ack]", sequenceIndex: 0),
                AgentChatItem(id: quietID, timestamp: date, kind: quietKind, text: "[ack]", sequenceIndex: 1)
            ]
            let base = projection(rows, turnID: turnID, spanID: spanID)
            let before = try XCTUnwrap(base.workingBlocks.first)
            XCTAssertTrue(before.rows.isEmpty)
            XCTAssertTrue(before.groupedHistory?.sections.isEmpty == true)
            var normal = before
            normal.displaySummaryInputs = []
            if let originalNormalBlock { XCTAssertEqual(normal, originalNormalBlock, "Original same-input A/B counterexample") }
            originalNormalBlock = normal
            let masked = AgentTranscriptProjectionBuilder.maskForLocalDisplay(presentation(base), archivedBlocks: base.workingBlocks, hiddenSourceIDs: [quietID])
            let block = try XCTUnwrap(masked.presentation.visibleBlocks.first)
            let summary = try XCTUnwrap(block.groupedHistory?.summary)
            XCTAssertEqual(summary.hiddenAssistantCount, firstKind == .assistant ? 1 : 0)
            XCTAssertEqual(summary.hiddenProgressCount, firstKind == .thinking ? 1 : 0)
            XCTAssertEqual(summary.toolSummary?.shortNarration, "[ack]")
            XCTAssertEqual(block.activityIDs, [firstID])
            XCTAssertEqual(block.anchorActivityID, firstID)
            XCTAssertNil(masked.presentation.rowAnchorIndex[quietID])
            XCTAssertEqual(masked.archivedBlocks, masked.presentation.visibleBlocks)
            XCTAssertEqual(base.workingBlocks.first?.activityIDs, [firstID, quietID], "Canonical/base projection was not changed")
            XCTAssertEqual(masked.presentation.revision, 7)
        }
    }

    func testCondensedRebuildPreservesLastBlankThinkingNarrationPolicy() throws {
        let older = AgentChatItem.thinking("older ordinary thought", sequenceIndex: 0)
        let blank = AgentChatItem.thinking(" \n", sequenceIndex: 1)
        let quiet = AgentChatItem.assistant("[ack]", sequenceIndex: 2)
        let base = projection([older, blank, quiet])
        let surviving = projection([older, blank])
        XCTAssertNil(surviving.workingBlocks.first?.groupedHistory?.summary.toolSummary?.shortNarration)
        let result = AgentTranscriptProjectionBuilder.maskForLocalDisplay(presentation(base), archivedBlocks: [], hiddenSourceIDs: [quiet.id])
        let summary = try XCTUnwrap(result.presentation.visibleBlocks.first?.groupedHistory?.summary)
        XCTAssertNil(summary.toolSummary?.shortNarration, "Rebuild uses the existing LAST thinking row, not an older nonblank thought")
        XCTAssertEqual(summary.hiddenProgressCount, 2)
    }

    func testHiddenAnchorCannotDropOrdinarySiblingAndEmptyGroupShellsDisappear() {
        let first = AgentChatItem(kind: .thinking, text: "quiet", sequenceIndex: 0)
        let ordinary = AgentChatItem(kind: .assistant, text: "ordinary", sequenceIndex: 1)
        let base = projection([first, ordinary])
        let masked = AgentTranscriptProjectionBuilder.maskForLocalDisplay(presentation(base), archivedBlocks: [], hiddenSourceIDs: [first.id])
        XCTAssertEqual(masked.presentation.visibleBlocks.count, 1)
        XCTAssertEqual(masked.presentation.visibleBlocks.first?.anchorActivityID, ordinary.id)
        XCTAssertEqual(masked.presentation.visibleBlocks.first?.groupedHistory?.summary.toolSummary?.shortNarration, "ordinary")
        let empty = AgentTranscriptProjectionBuilder.maskForLocalDisplay(presentation(base), archivedBlocks: base.workingBlocks, hiddenSourceIDs: [first.id, ordinary.id])
        XCTAssertTrue(empty.presentation.visibleBlocks.isEmpty)
        XCTAssertTrue(empty.presentation.workingBlocks.isEmpty)
        XCTAssertTrue(empty.archivedBlocks.isEmpty)
        XCTAssertTrue(empty.presentation.rowAnchorIndex.isEmpty)
        XCTAssertTrue(empty.presentation.anchorBlockIndex.isEmpty)
        XCTAssertFalse(empty.presentation.archivedHistoryState.hasArchivedHistory)
    }

    func testSyntheticConclusionUsesOriginalSourceAnchorInBlocksFlatRowsAndBothIndexes() throws {
        let sourceID = UUID(), turnID = UUID()
        let summary = AgentTranscriptTurnSummary(
            requestText: nil,
            conclusionText: "[ack]",
            compactConclusionText: "[ack]",
            middleSummaryText: nil,
            toolCount: 0,
            notableToolNames: [],
            keyPaths: [],
            compactedActivityCount: 0,
            hadWarning: false,
            hadError: false
        )
        let base = projection([], tier: .archived, turnID: turnID, conclusionID: sourceID, summary: summary)
        let row = try XCTUnwrap(base.archivedRows.first)
        XCTAssertNotEqual(row.id, sourceID)
        let snapshot = AgentTranscriptPresentationSnapshot(
            revision: 9,
            visibleBlocks: base.archivedBlocks,
            workingBlocks: base.archivedBlocks,
            visibleRows: base.archivedRows,
            workingRows: base.archivedRows,
            rowAnchorIndex: base.rowAnchorIndex,
            anchorBlockIndex: base.anchorBlockIndex
        )
        let masked = AgentTranscriptProjectionBuilder.maskForLocalDisplay(snapshot, archivedBlocks: base.archivedBlocks, hiddenSourceIDs: [sourceID])
        XCTAssertTrue(masked.presentation.visibleBlocks.isEmpty)
        XCTAssertTrue(masked.presentation.visibleRows.isEmpty)
        XCTAssertTrue(masked.presentation.workingRows.isEmpty)
        XCTAssertTrue(masked.presentation.rowAnchorIndex.isEmpty)
        XCTAssertTrue(masked.presentation.anchorBlockIndex.isEmpty)
        XCTAssertTrue(masked.archivedBlocks.isEmpty)
        XCTAssertEqual(base.archivedRows.first?.text, "[ack]", "Raw archived source remains visible to canonical readers")
    }

    func testNarrationOwnsBoundedSanitizedUnicodeCopyAndDoesNotPinSourceBody() throws {
        let text = String(repeating: "👩🏽‍💻", count: 20000)
        let row = AgentChatItem(kind: .thinking, text: text, sequenceIndex: 0)
        let base = projection([row])
        let narration = try XCTUnwrap(base.workingBlocks.first?.displaySummaryInputs.first?.rows.first?.narration)
        XCTAssertEqual(narration.count, 121)
        XCTAssertGreaterThan(narration.utf8.count, 121, "The character policy is not a byte cap")
        XCTAssertEqual(narration, String(text.prefix(120)) + "…")
        var source = text
        var retained = narration
        source.withUTF8 { sourceBytes in
            retained.withUTF8 { retainedBytes in XCTAssertNotEqual(sourceBytes.baseAddress, retainedBytes.baseAddress) }
        }
        print("QUIET_C5_NARRATION bytes=\(narration.utf8.count) characters=\(narration.count) sourceBytes=\(text.utf8.count)")
        // Exact old sanitizer→120-character formatter, including NUL-induced grapheme joins.
        let boundaries = [
            "", "  ", String(repeating: "\0", count: 500),
            String(repeating: "a", count: 120), String(repeating: "a", count: 121),
            String(repeating: "a", count: 122) + "\0\u{0301}",
            String(repeating: "e\0\u{0301}", count: 180),
            String(repeating: "\0", count: 200) + String(repeating: "x", count: 200),
            " \n" + String(repeating: "👩🏽‍💻\0🇬🇧", count: 150) + " \n",
            String(repeating: "a", count: 119) + "e\0\u{0301}" + String(repeating: "z", count: 200)
        ]
        for body in boundaries {
            let sanitized = body.trimmingCharacters(in: .whitespacesAndNewlines).sanitizedForDisplay
            let expected: String? = sanitized.isEmpty ? nil : sanitized.count > 120 ? String(sanitized.prefix(120)) + "…" : sanitized
            let built = projection([AgentChatItem.thinking(body)])
            let actual = built.workingBlocks.flatMap(\.displaySummaryInputs).flatMap(\.rows).first?.narration
            XCTAssertEqual(actual, expected, "Prefix optimization must not invent a new truncation/sanitization policy")
        }
    }

    func testOldToolHeavyCondensedCacheRetainsOnlySummaryMetadataAfterRealCanonicalTrim() throws {
        var source: AgentTranscript? = AgentTranscript(turns: (0 ..< 8).map { _ in AgentQuietCheckInReplay.toolHeavyTurn(date: date) })
        let old = try AgentTranscriptProjectionBuilder.buildWithCaches(from: XCTUnwrap(source), protection: .none, turnCaches: [:])
        let compacted = try AgentTranscriptCompactor.compact(XCTUnwrap(source))
        source = nil
        XCTAssertTrue(compacted.allActivities.isEmpty)
        let inputs = old.updatedTurnCaches.values.flatMap(\.workingBlocks).flatMap(\.displaySummaryInputs)
        let rows = inputs.flatMap(\.rows)
        XCTAssertEqual(rows.count, 400)
        let narrationBytes = rows.reduce(0) { $0 + ($1.narration?.utf8.count ?? 0) }
        XCTAssertEqual(narrationBytes, 16 * (120 + "…".utf8.count))
        XCTAssertTrue(rows.allSatisfy { ($0.narration?.count ?? 0) <= 121 })
        let masked = AgentTranscriptProjectionBuilder.maskForLocalDisplay(
            presentation(old.projection),
            archivedBlocks: [],
            hiddenSourceIDs: Set(rows.filter { $0.kind == .thinking }.map(\.id))
        )
        XCTAssertTrue(masked.presentation.visibleBlocks.allSatisfy { $0.groupedHistory?.summary.hiddenToolCardCount == 24 })
        XCTAssertTrue(masked.presentation.visibleBlocks.allSatisfy { $0.groupedHistory?.summary.toolSummary?.shortNarration == String(String(repeating: "ordinary explanation ", count: 800).prefix(120)) + "…" })
        let replacement = AgentTranscriptProjectionBuilder.buildWithCaches(from: compacted, protection: .none, turnCaches: old.updatedTurnCaches)
        XCTAssertTrue(replacement.projection.workingBlocks.flatMap(\.displaySummaryInputs).isEmpty)
        let blockIDBytes = inputs.reduce(0) { $0 + $1.blockID.utf8.count }
        let identityArrayBytes = inputs.reduce(0) { $0 + $1.activityIDs.count * MemoryLayout<UUID>.stride }
        let valueElementBytes = inputs.count * MemoryLayout<AgentTranscriptDisplaySummaryInput>.stride + rows.count * MemoryLayout<AgentTranscriptDisplaySummaryInput.Row>.stride
        print("QUIET_C5_SUMMARY_RETENTION turns=8 tools=192 inputBlocks=\(inputs.count) inputRows=\(rows.count) narrationUTF8Bytes=\(narrationBytes) blockIDUTF8Bytes=\(blockIDBytes) activityIDElementBytes=\(identityArrayBytes) valueElementBytes=\(valueElementBytes) retainedRawPayloadBytes=0 postTrimCanonicalActivities=0 replacementInputRows=0")
    }

    func testMixedFullFrozenSummaryRebuildPreservesToolsAndOrdinaryNarration() throws {
        let turnID = UUID(), spanID = UUID()
        let ordinary = AgentChatItem.assistant("ordinary explanation", sequenceIndex: 0)
        let quiet = AgentChatItem.thinking("quiet private thought", sequenceIndex: 1)
        var rows = [ordinary, quiet]
        for index in 0 ..< 20 {
            rows.append(.init(kind: .toolResult, text: "source \(index)", toolName: "read_file", toolInvocationID: UUID(), toolResultJSON: "{}", sequenceIndex: rows.count))
        }
        let span = AgentTranscriptProviderResponseSpan(id: spanID, lifecycle: .completed, startedAt: date, completedAt: date, activities: rows.map { .init(from: $0, toolExecution: AgentTranscriptToolNormalizer.toolExecution(for: $0)) })
        let turn = AgentTranscriptTurn(id: turnID, responseSpans: [span], retentionTier: .full, terminalState: .completed, startedAt: date, completedAt: date)
        let frozen = AgentTranscriptProjectionBuilder.refreshCompletedFullTurnGroupedHistoryCaches(in: .init(turns: [turn]))
        XCTAssertNotNil(frozen.turns.first?.responseSpans.first?.fullRenderGroupedHistoryCache)
        let base = AgentTranscriptProjectionBuilder.build(from: frozen)
        let normal = try XCTUnwrap(base.workingBlocks.first(where: { $0.kind == .groupedHistory }))
        XCTAssertFalse(try XCTUnwrap(normal.groupedHistory).sections.isEmpty)
        XCTAssertTrue(normal.displaySummaryInputs.isEmpty, "Full materialization reuses existing sections, not duplicate raw children")
        let result = AgentTranscriptProjectionBuilder.maskForLocalDisplay(presentation(base), archivedBlocks: base.workingBlocks, hiddenSourceIDs: [quiet.id])
        let group = try XCTUnwrap(result.presentation.visibleBlocks.first(where: { $0.kind == .groupedHistory })?.groupedHistory)
        XCTAssertEqual(group.summary.hiddenProgressCount, 0)
        XCTAssertEqual(group.summary.hiddenAssistantCount, 1)
        XCTAssertEqual(group.summary.hiddenToolCardCount, normal.groupedHistory?.summary.hiddenToolCardCount)
        XCTAssertEqual(group.summary.toolSummary?.shortNarration, "ordinary explanation")
        XCTAssertFalse(group.sections.flatMap(\.childBlocks).flatMap(\.rows).contains(where: { $0.id == quiet.id }))
        XCTAssertEqual(base.workingBlocks.first(where: { $0.kind == .groupedHistory }), normal)
        XCTAssertEqual(result.archivedBlocks, result.presentation.visibleBlocks)
    }

    private func liveFixture() throws -> (AgentSessionLinkRunnerHarness, WorkspaceManagerViewModel, AgentTabSession) {
        let harness = AgentSessionLinkRunnerHarness(headlessProviderFactory: { _, _ in AgentSessionLinkCapturingHeadlessProvider() }, replayTranscript: true)
        let tabID = UUID()
        let manager = AgentSessionLinkEndpointTestSupport.installWorkspace(on: harness.host, tabID: tabID, name: "Quiet display fixture")
        let session = harness.host.session(for: tabID)
        session.selectedAgent = .claudeCode
        session.hasLoadedPersistedState = true
        _ = try XCTUnwrap(harness.host.test_installPersistentSessionBinding(sessionID: UUID(), on: session, updateWorkspaceMetadata: true))
        session.recordRestorationAuthoritative(.persistedPayloadApplied)
        session.installRunID(UUID())
        return (harness, manager, session)
    }

    func testSameRevisionHydrationRefreshesMaskedAndEmptyDisplayAndRestoreSignalWithoutGetterWork() async throws {
        for hasMask in [false, true] {
            let (h, manager, session) = try liveFixture()
            defer { withExtendedLifetime(manager) {} }
            let ordinary = AgentChatItem.assistant("ordinary context")
            session.appendItem(ordinary)
            var quietRowID: UUID?
            if hasMask {
                session.runState = .running
                let owner = session.beginRunAttempt(source: "quiet-display-hydration")
                session.quietLedger.markRoutineWake(owner: owner, wakeID: UUID())
                let ack = AgentChatItem.assistant("[ack]")
                quietRowID = ack.id
                session.appendItem(ack)
                let revision = await AgentRunTerminalCommitBarrier().commit(.init(
                    binding: h.hooks.bindTerminalSession(session), ownership: owner, expectedRunID: session.runID,
                    terminalState: .completed, source: "quiet-display-hydration", attachmentDisposition: .deleteFiles,
                    finalizeNonCodexUsage: false, supportsFollowUp: false, notifyTurnComplete: false, classifiesQuietCheckIn: true
                ))
                XCTAssertNotNil(revision)
                XCTAssertTrue(session.quietLedger.hiddenSourceIDs.contains(ack.id))
            }
            session.clearCurrentBindingHydration()
            h.host.refreshDerivedTranscriptState(for: session, publishActivePresentation: false)
            _ = h.host.test_publishTranscriptPresentation(tabID: session.tabID)
            h.host.syncTranscriptUIState()
            let before = h.host.ui.transcript.snapshot
            let warm = try XCTUnwrap(session.quietTranscriptDisplayCache)
            XCTAssertFalse(before.isHydrated)
            XCTAssertFalse(warm.result.presentation.bindingsHydrated)
            XCTAssertNil(warm.result.presentation.hydratedPersistentBinding)
            XCTAssertNil(warm.result.presentation.hydratedBindingTransitionGeneration)
            let hidden = session.quietLedger.hiddenSourceIDs
            XCTAssertEqual(hidden.isEmpty, !hasMask)
            let baseRevision = h.host.activeTranscriptPresentation.revision
            let maskRevision = session.quietLedger.displayMaskRevision

            // The only transition is the existing hydration setter: no presentation republish.
            h.host.test_setActiveSessionBindingsAreHydrated(true)
            let after = h.host.ui.transcript.snapshot
            XCTAssertTrue(after.isHydrated)
            XCTAssertEqual(after.presentationRevision, baseRevision)
            XCTAssertEqual(after.displayMaskRevision, maskRevision)
            XCTAssertTrue(after.presentation.bindingsHydrated, "mask=\(hasMask): cache must expose hydration at the same revision")
            XCTAssertEqual(after.presentation.hydratedPersistentBinding, session.authoritativeHydratedBinding)
            XCTAssertEqual(after.presentation.hydratedBindingTransitionGeneration, session.authoritativeHydratedBindingTransitionGeneration)
            XCTAssertEqual(session.quietLedger.hiddenSourceIDs, hidden)
            XCTAssertTrue(after.presentation.visibleRows.contains(where: { $0.id == ordinary.id }))
            if let quietRowID {
                XCTAssertFalse(after.presentation.visibleRows.contains(where: { $0.id == quietRowID }))
                XCTAssertTrue(session.items.contains(where: { $0.id == quietRowID }))
            }
            func restoreSignal(_ snapshot: AgentTranscriptUISnapshot) -> AgentTranscriptRestoreSignal {
                .init(
                    tabID: snapshot.presentation.tabID,
                    bindingsHydrated: snapshot.presentation.bindingsHydrated,
                    presentationRevision: snapshot.presentation.revision
                )
            }
            XCTAssertEqual(AgentTranscriptActivationRepaintRemountPolicy.remountKey(
                oldSignal: restoreSignal(before), newSignal: restoreSignal(after), currentTabID: session.tabID,
                rehydratePhase: .awaitingHydration(tabID: session.tabID, target: .liveBottom),
                lastRemountKey: nil, remountCount: 0, layoutPassToken: 42
            ), .init(tabID: session.tabID, presentationRevision: baseRevision, layoutPassToken: 42))
            let hydrated = try XCTUnwrap(session.quietTranscriptDisplayCache)
            XCTAssertEqual(hydrated.key, warm.key, "no new key state/revision is needed")
            var publications = 0
            let updates = h.host.ui.transcript.$snapshot.dropFirst().sink { _ in publications += 1 }
            for _ in 0 ..< 100 {
                _ = h.host.makeTranscriptUISnapshot()
                h.host.syncTranscriptUIState()
                hydrated.result.presentation.visibleBlocks.withUnsafeBufferPointer { old in
                    session.quietTranscriptDisplayCache?.result.presentation.visibleBlocks.withUnsafeBufferPointer { current in
                        XCTAssertEqual(old.baseAddress, current.baseAddress)
                    }
                }
            }
            XCTAssertEqual(publications, 0, "unchanged sync/getters reuse without publication")
            updates.cancel()

            // Real binding application suppresses intermediate UI sync. Its performance-only
            // assignment keeps the same revision, but must invalidate BEFORE the suppression guard.
            session.transcriptPerformanceSnapshot.projectionPublishCount += 1
            session.transcriptAutoFollowArmingState = h.host.activeTranscriptFollowBindingState.armingState == .armed
                ? .disarmedAfterManualDetach : .armed
            var observedSuppressedPublication = false
            let follow = h.host.$activeTranscriptFollowBindingState.dropFirst().sink { _ in
                observedSuppressedPublication = true
                XCTAssertTrue(h.host.isRestoringState, "observation is inside real suppressed binding application")
                XCTAssertNil(session.quietTranscriptDisplayCache, "presentation assignment invalidates even while UI sync is suppressed")
            }
            h.host.applySessionToBindings(session)
            follow.cancel()
            XCTAssertTrue(observedSuppressedPublication)
            XCTAssertEqual(h.host.activeTranscriptPresentation.revision, baseRevision)
            XCTAssertEqual(session.quietLedger.displayMaskRevision, maskRevision)
            let final = try XCTUnwrap(session.quietTranscriptDisplayCache)
            XCTAssertEqual(final.key, hydrated.key)
            XCTAssertEqual(final.result.presentation.performanceSnapshot, h.host.activeTranscriptPresentation.performanceSnapshot)
            XCTAssertTrue(final.result.presentation.bindingsHydrated)
            XCTAssertEqual(session.quietLedger.hiddenSourceIDs, hidden)
            if let quietRowID { XCTAssertFalse(final.result.presentation.visibleRows.contains(where: { $0.id == quietRowID })) }
            print("QUIET_A3_HYDRATION mask=\(hasMask) sameBaseRevision=true sameMaskRevision=true getterSyncIterations=100 unchangedPublications=\(publications) suppressedPublicationObserved=\(observedSuppressedPublication) blockVisits=\(final.result.blockVisits) rowVisits=\(final.result.rowVisits) anchorVisits=\(final.result.anchorVisits)")
        }
    }

    func testRealBarrierDefersDisplayBuildThenPublishesMaskRevisionAndReusesCacheWithoutGetterWork() async throws {
        let (h, manager, session) = try liveFixture()
        defer { withExtendedLifetime(manager) {} }
        session.runState = .running
        let owner = session.beginRunAttempt(source: "quiet-display")
        let wakeID = UUID()
        session.quietLedger.markRoutineWake(owner: owner, wakeID: wakeID)
        let row = AgentChatItem.assistant("[ack]")
        session.appendItem(row)
        h.host.refreshDerivedTranscriptState(for: session, publishActivePresentation: false)
        _ = h.host.test_publishTranscriptPresentation(tabID: session.tabID)
        h.host.syncTranscriptUIState()
        let unmasked = h.host.ui.transcript.snapshot
        XCTAssertTrue(unmasked.presentation.visibleRows.contains(where: { $0.id == row.id }))
        var publications = 0
        let subscription = h.host.ui.transcript.$snapshot.dropFirst().sink { _ in publications += 1 }
        var barrierSyncAttempted = false
        session.onRunStateChanged = { s in
            guard s.terminalCommitInProgress else { return }
            barrierSyncAttempted = true
            XCTAssertNil(s.quietTranscriptDisplayCache)
            XCTAssertFalse(h.host.prepareQuietTranscriptDisplay())
            h.host.syncTranscriptUIState()
            XCTAssertNil(s.quietTranscriptDisplayCache, "No mask traversal or cache on barrier stack")
            XCTAssertEqual(h.host.ui.transcript.snapshot.displayMaskRevision, unmasked.displayMaskRevision)
        }
        let revision = await AgentRunTerminalCommitBarrier().commit(.init(
            binding: h.hooks.bindTerminalSession(session), ownership: owner, expectedRunID: session.runID,
            terminalState: .completed, source: "quiet-display", attachmentDisposition: .deleteFiles,
            finalizeNonCodexUsage: false, supportsFollowUp: false, notifyTurnComplete: true, classifiesQuietCheckIn: true
        ))
        XCTAssertNotNil(revision)
        XCTAssertTrue(barrierSyncAttempted)
        h.host.syncTranscriptUIState()
        let masked = h.host.ui.transcript.snapshot
        XCTAssertGreaterThan(masked.displayMaskRevision, unmasked.displayMaskRevision)
        XCTAssertEqual(masked.presentationRevision, unmasked.presentationRevision, "Mask is not a forged base presentation mutation")
        XCTAssertFalse(masked.presentation.visibleRows.contains(where: { $0.id == row.id }))
        XCTAssertTrue(session.items.contains(where: { $0.id == row.id }), "Canonical source remains")
        let cache = try XCTUnwrap(session.quietTranscriptDisplayCache)
        let before = publications
        for _ in 0 ..< 100 {
            _ = h.host.makeTranscriptUISnapshot()
            h.host.syncTranscriptUIState()
            XCTAssertEqual(session.quietTranscriptDisplayCache?.key, cache.key)
            cache.result.presentation.visibleBlocks.withUnsafeBufferPointer { lhs in
                session.quietTranscriptDisplayCache?.result.presentation.visibleBlocks.withUnsafeBufferPointer { rhs in XCTAssertEqual(lhs.baseAddress, rhs.baseAddress) }
            }
        }
        XCTAssertEqual(publications, before, "Unchanged owner sync/getters do not publish")
        subscription.cancel()
    }

    func testActualSyntheticAnchorInstallThenRemoveAndHydrateLosesMaterializedMaskButNotPendingWake() throws {
        let (h, manager, session) = try liveFixture()
        defer { withExtendedLifetime(manager) {} }
        let owner = session.beginRunAttempt(source: "quiet-anchor")
        let wake = UUID()
        session.quietLedger.markRoutineWake(owner: owner, wakeID: wake)
        let row = AgentChatItem.assistant("[ack]")
        session.appendItem(row)
        session.sealQuietCheckIn(owner: owner, terminalState: .completed, normal: true, hasSuccessor: false)
        XCTAssertTrue(session.endRunAttempt(ifCurrent: owner, source: "quiet-anchor"))
        let turnID = UUID()
        let summary = AgentTranscriptTurnSummary(requestText: nil, conclusionText: "[ack]", compactConclusionText: "[ack]", middleSummaryText: nil, toolCount: 0, notableToolNames: [], keyPaths: [], compactedActivityCount: 0, hadWarning: false, hadError: false)
        let transcript = AgentTranscript(turns: [.init(id: turnID, conclusionActivityID: row.id, retentionTier: .archived, summary: summary, terminalState: .completed, startedAt: date, completedAt: date)])
        h.host.applyTranscriptPresentation(transcript, to: session)
        XCTAssertFalse(session.fullTranscriptProjection.archivedBlocks.isEmpty)
        _ = h.host.test_publishTranscriptPresentation(tabID: session.tabID)
        h.host.syncTranscriptUIState()
        let hiddenArchive = try XCTUnwrap(session.quietTranscriptDisplayCache)
        XCTAssertTrue(hiddenArchive.result.archivedBlocks.isEmpty, "Separate archived conclusion is masked at actual UI sync")
        XCTAssertEqual(h.host.ui.transcript.snapshot.presentation.archivedHistoryState.blockCount, 0)
        h.host.setCompressedHistoryVisibility(tabID: session.tabID, isRevealed: true)
        h.host.syncTranscriptUIState()
        let revealed = try XCTUnwrap(session.quietTranscriptDisplayCache)
        XCTAssertNotEqual(revealed.key.presentationRevision, hiddenArchive.key.presentationRevision)
        XCTAssertTrue(h.host.ui.transcript.snapshot.archivedBlocks.isEmpty)
        h.host.setTranscriptWindowExpanded(tabID: session.tabID, isExpanded: true)
        h.host.syncTranscriptUIState()
        XCTAssertNotEqual(session.quietTranscriptDisplayCache?.key.presentationRevision, revealed.key.presentationRevision)
        XCTAssertTrue(h.host.ui.transcript.snapshot.presentation.visibleRows.isEmpty, "Existing archive/window paging paths cannot resurface hidden synthetic rows")
        _ = session.removeItem(at: 0)
        session.reconcileQuietSourceIDs(previousLiveIDs: [row.id])
        XCTAssertTrue(session.quietLedger.hiddenSourceIDs.contains(row.id), "Materialized synthetic conclusion retains exact source proof")
        XCTAssertNotNil(session.fullTranscriptProjection.rowAnchorIndex[row.id], "Retained source is indexed by its existing anchor owner")
        session.clearDerivedTranscriptCaches()
        h.host.applyTranscriptPresentation(.empty, to: session)
        XCTAssertFalse(session.quietLedger.hiddenSourceIDs.contains(row.id), "Actual source-anchor retirement loses materialized proof")
        XCTAssertTrue(session.quietLedger.hiddenSourceIDs.contains(wake), "Still-admissible unmaterialized wake is different")
        session.setItemsSilently([row], reason: .persistedSessionHydration)
        h.host.refreshDerivedTranscriptState(for: session, publishActivePresentation: false)
        _ = h.host.test_publishTranscriptPresentation(tabID: session.tabID)
        h.host.syncTranscriptUIState()
        XCTAssertTrue(h.host.ui.transcript.snapshot.presentation.visibleRows.contains(where: { $0.id == row.id }), "B8 rehydration is visible, not a pending marker")
        XCTAssertTrue(session.quietLedger.hiddenSourceIDs.contains(wake))
    }

    func testInactiveActivationArchiveWriterAndHelperOnlyChangesInvalidateExactCache() throws {
        let (h, manager, session) = try liveFixture()
        defer { withExtendedLifetime(manager) {} }
        let first = AgentChatItem.assistant("[ack]", sequenceIndex: 0)
        let quiet = AgentChatItem.thinking("[ack]", sequenceIndex: 1)
        let turnID = UUID(), spanID = UUID()
        func transcript(_ rows: [AgentChatItem]) -> AgentTranscript {
            .init(turns: [.init(id: turnID, responseSpans: [.init(id: spanID, lifecycle: .completed, startedAt: date, completedAt: date, activities: rows.map { .init(from: $0) })], retentionTier: .condensed, terminalState: .completed, startedAt: date, completedAt: date)])
        }
        session.setItemsSilently([first], reason: .testOverride)
        let owner = session.beginRunAttempt(source: "inactive")
        // Use the real ledger classifier over a separate exact quiet suffix.
        let ack = AgentChatItem.assistant("[ack]")
        session.quietLedger.markRoutineWake(owner: owner, wakeID: UUID())
        session.appendItem(quiet)
        session.appendItem(ack)
        session.sealQuietCheckIn(owner: owner, terminalState: .completed, normal: true, hasSuccessor: false)
        XCTAssertTrue(session.endRunAttempt(ifCurrent: owner, source: "inactive"))
        h.host.test_setCurrentTabIDOverride(UUID())
        h.host.applyTranscriptPresentation(transcript(session.items), to: session)
        XCTAssertNil(session.quietTranscriptDisplayCache, "Inactive install does no mask work")
        h.host.test_setCurrentTabIDOverride(session.tabID)
        _ = h.host.test_publishTranscriptPresentation(tabID: session.tabID)
        h.host.syncTranscriptUIState()
        let installed = try XCTUnwrap(session.quietTranscriptDisplayCache)
        let originalNormalBlocks = h.host.activeTranscriptPresentation.visibleBlocks
        XCTAssertFalse(installed.result.presentation.visibleBlocks.flatMap(\.activityIDs).contains(ack.id))
        // Actual archive install owner clears the cache even with an unchanged mask.
        let revision = session.quietLedger.displayMaskRevision
        let sourceIDs = session.quietLedger.hiddenSourceIDs
        session.mutateItem(at: 0) { $0.kind = .thinking }
        session.mutateItem(at: 1) { $0.kind = .assistant }
        // Existing cache reset/install owns a canonical rebuild. Live source IDs still prove both
        // hidden rows; this is not persisted hydration, which would intentionally discard proof.
        session.clearDerivedTranscriptCaches()
        let next = transcript(session.items)
        let changed = h.host.applyTranscriptPresentation(next, to: session)
        XCTAssertNil(session.quietTranscriptDisplayCache)
        XCTAssertEqual(session.quietLedger.displayMaskRevision, revision)
        XCTAssertEqual(session.quietLedger.hiddenSourceIDs, sourceIDs)
        var before = originalNormalBlocks
        var after = changed.projection.workingBlocks
        for index in before.indices {
            before[index].displaySummaryInputs = []
        }
        for index in after.indices {
            after[index].displaySummaryInputs = []
        }
        XCTAssertEqual(before, after, "Only the lossless helper differs in the ordinary display value")
        _ = h.host.test_publishTranscriptPresentation(tabID: session.tabID)
        h.host.syncTranscriptUIState()
        let rebuilt = try XCTUnwrap(session.quietTranscriptDisplayCache)
        XCTAssertNotEqual(rebuilt.key.presentationRevision, installed.key.presentationRevision)
        XCTAssertEqual(rebuilt.result.presentation.visibleBlocks.first?.groupedHistory?.summary.hiddenAssistantCount, 0)
        XCTAssertEqual(rebuilt.result.presentation.visibleBlocks.first?.groupedHistory?.summary.hiddenProgressCount, 1)
        session.clearDerivedTranscriptCaches()
        XCTAssertNil(session.quietTranscriptDisplayCache, "Actual archive reset owner also invalidates")
    }

    func testFullBufferedLeadingQuietNarrationDoesNotSurviveInFrozenToolsSummary() throws {
        let quiet = AgentChatItem.assistant("[ack]", sequenceIndex: 0)
        var rows = [quiet]
        for index in 0 ..< 20 {
            rows.append(.init(kind: .toolResult, text: "source \(index)", toolName: "read_file", toolInvocationID: UUID(), toolResultJSON: "{}", sequenceIndex: rows.count))
        }
        let turn = AgentTranscriptTurn(responseSpans: [.init(lifecycle: .completed, startedAt: date, completedAt: date, activities: rows.map { .init(from: $0, toolExecution: AgentTranscriptToolNormalizer.toolExecution(for: $0)) })], retentionTier: .full, terminalState: .completed, startedAt: date, completedAt: date)
        let frozen = AgentTranscriptProjectionBuilder.refreshCompletedFullTurnGroupedHistoryCaches(in: .init(turns: [turn]))
        let base = AgentTranscriptProjectionBuilder.build(from: frozen)
        let original = try XCTUnwrap(base.workingBlocks.first(where: { $0.kind == .groupedHistory }))
        XCTAssertEqual(base.workingBlocks.first?.rows.first?.id, quiet.id, "Real leading-assistant buffering, outside group sections")
        XCTAssertEqual(original.groupedHistory?.summary.toolSummary?.shortNarration, "[ack]")
        XCTAssertFalse(try XCTUnwrap(original.groupedHistory).sections.flatMap(\.childBlocks).flatMap(\.rows).contains(where: { $0.id == quiet.id }))
        let result = AgentTranscriptProjectionBuilder.maskForLocalDisplay(presentation(base), archivedBlocks: base.workingBlocks, hiddenSourceIDs: [quiet.id])
        let masked = try XCTUnwrap(result.presentation.visibleBlocks.first(where: { $0.kind == .groupedHistory }))
        XCTAssertNil(masked.groupedHistory?.summary.toolSummary?.shortNarration, "Hidden buffered source cannot remain as narration in frozen summary")
        XCTAssertEqual(masked.groupedHistory?.summary.hiddenToolCardCount, original.groupedHistory?.summary.hiddenToolCardCount)
        XCTAssertEqual(result.archivedBlocks, result.presentation.visibleBlocks)
    }

    func testDisplayOwnerHardwareSamplesAndFrozenSummaryStorageReuse() throws {
        let (h, manager, session) = try liveFixture()
        defer { withExtendedLifetime(manager) {} }
        let transcript = AgentTranscript(turns: (0 ..< 8).map { _ in AgentQuietCheckInReplay.toolHeavyTurn(date: date) })
        let built = AgentTranscriptProjectionBuilder.buildWithCaches(from: transcript, protection: .none, turnCaches: [:])
        var sharedInputBuffers = 0
        for _ in 0 ..< 20 {
            let reused = AgentTranscriptProjectionBuilder.buildWithCaches(from: transcript, protection: .none, turnCaches: built.updatedTurnCaches)
            for (id, old) in built.updatedTurnCaches {
                let current = try XCTUnwrap(reused.updatedTurnCaches[id])
                let oldBlock = try XCTUnwrap(old.workingBlocks.first)
                let currentBlock = try XCTUnwrap(current.workingBlocks.first)
                oldBlock.displaySummaryInputs.withUnsafeBufferPointer { first in
                    currentBlock.displaySummaryInputs.withUnsafeBufferPointer { second in
                        XCTAssertEqual(first.baseAddress, second.baseAddress)
                        sharedInputBuffers += 1
                    }
                }
            }
        }
        XCTAssertEqual(sharedInputBuffers, 160)
        var compacted = AgentTranscriptCompactor.compact(transcript)
        for index in compacted.turns.indices {
            compacted.turns[index].retentionTier = .archived
        }
        h.host.applyTranscriptPresentation(compacted, to: session)
        _ = h.host.test_publishTranscriptPresentation(tabID: session.tabID)
        h.host.syncTranscriptUIState()
        var sealMS: [Double] = [], ownerMS: [Double] = [], hitMS: [Double] = []
        var measuredCacheBuilds = 0
        var workTotals = (blocks: 0, rows: 0, anchors: 0)
        var workMax = (blocks: 0, rows: 0, anchors: 0)
        func ms(_ duration: Duration) -> Double {
            Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        }
        for _ in 0 ..< 100 {
            let owner = session.beginRunAttempt(source: "quiet-display-hardware")
            let wake = UUID()
            session.quietLedger.recordPhysicalDispatch(owner: owner, wakeID: wake, routineQuietCheckIn: true, alreadyAcquired: false)
            session.appendItem(.assistant("[ack]"))
            let start = ContinuousClock.now
            session.sealQuietCheckIn(owner: owner, terminalState: .completed, normal: true, hasSuccessor: false)
            sealMS.append(ms(start.duration(to: .now)))
            XCTAssertNil(session.quietTranscriptDisplayCache, "Seal only invalidates membership/cache")
            let syncStart = ContinuousClock.now
            h.host.syncTranscriptUIState()
            ownerMS.append(ms(syncStart.duration(to: .now)))
            let cache = try XCTUnwrap(session.quietTranscriptDisplayCache)
            XCTAssertFalse(cache.result.archivedBlocks.isEmpty, "Separate archived materialization is part of the owning UI measurement")
            measuredCacheBuilds += 1
            workTotals.blocks += cache.result.blockVisits
            workTotals.rows += cache.result.rowVisits
            workTotals.anchors += cache.result.anchorVisits
            workMax.blocks = max(workMax.blocks, cache.result.blockVisits)
            workMax.rows = max(workMax.rows, cache.result.rowVisits)
            workMax.anchors = max(workMax.anchors, cache.result.anchorVisits)
            let hitStart = ContinuousClock.now
            for _ in 0 ..< 10 {
                _ = h.host.makeTranscriptUISnapshot()
            }
            hitMS.append(ms(hitStart.duration(to: .now)) / 10)
            cache.result.archivedBlocks.withUnsafeBufferPointer { old in
                session.quietTranscriptDisplayCache?.result.archivedBlocks.withUnsafeBufferPointer { current in XCTAssertEqual(old.baseAddress, current.baseAddress) }
            }
            XCTAssertTrue(session.endRunAttempt(ifCurrent: owner, source: "quiet-display-hardware"))
            session.retireQuietUnmaterializedWake(wake)
            h.host.syncTranscriptUIState()
        }
        func p99(_ samples: [Double]) -> Double {
            samples.sorted()[Int(Double(samples.count - 1) * 0.99)]
        }
        print("QUIET_C5_UI_HARDWARE samples=100 getters=1000 positivelyRoutineRowsPerSeal=1 sealP99MS=\(p99(sealMS)) ownerSyncP99MS=\(p99(ownerMS)) ownerSyncMaxMS=\(ownerMS.max()!) getterP99MS=\(p99(hitMS)) archiveBlocks=\(session.archivedTranscriptSnapshot.blocks.count) frozenCacheInputBufferMatches=\(sharedInputBuffers) observedNewHelperBuffersOnReuse=0 helperRowStride=\(MemoryLayout<AgentTranscriptDisplaySummaryInput.Row>.stride) helperInputStride=\(MemoryLayout<AgentTranscriptDisplaySummaryInput>.stride)")
        print("QUIET_A3_DISPLAY_WORK measuredCacheBuilds=\(measuredCacheBuilds) blocksTotal=\(workTotals.blocks) rowsTotal=\(workTotals.rows) anchorsTotal=\(workTotals.anchors) blocksMax=\(workMax.blocks) rowsMax=\(workMax.rows) anchorsMax=\(workMax.anchors)")
    }

    func testEmptyLocalMaskRetiresOnlyDisplayMetadataNotHydrationOrCanonicalFollowScope() {
        let row = AgentChatItem.assistant("[ack]", sequenceIndex: 0)
        let projected = projection([row], tier: .full)
        let turnID = projected.workingBlocks[0].turnID
        let base = AgentTranscriptPresentationSnapshot(
            tabID: UUID(), revision: 17, visibleBlocks: projected.workingBlocks, workingBlocks: projected.workingBlocks,
            visibleRows: projected.workingRows, workingRows: projected.workingRows,
            rowAnchorIndex: projected.rowAnchorIndex, anchorBlockIndex: projected.anchorBlockIndex,
            bindingsHydrated: true,
            metadata: .init(latestTurnID: turnID, dynamicSummaryLockTargetTurnID: turnID, recentAssistantItemIDs: [row.id])
        )
        let result = AgentTranscriptProjectionBuilder.maskForLocalDisplay(base, archivedBlocks: [], hiddenSourceIDs: [row.id]).presentation
        XCTAssertNil(result.metadata.latestTurnID)
        XCTAssertNil(result.metadata.dynamicSummaryLockTargetTurnID)
        XCTAssertTrue(result.metadata.recentAssistantItemIDs.isEmpty)
        XCTAssertEqual(result.tabID, base.tabID)
        XCTAssertEqual(result.revision, 17)
        XCTAssertTrue(result.bindingsHydrated)
        XCTAssertEqual(base.metadata.dynamicSummaryLockTargetTurnID, turnID)
    }

    func testNoRemovalPreservesExactWindowedMetadataAndPartialTurnSurvival() {
        let quiet = AgentChatItem.assistant("[ack]", sequenceIndex: 0)
        let ordinary = AgentChatItem.assistant("ordinary", sequenceIndex: 1)
        let projected = projection([quiet, ordinary], tier: .full)
        let turnID = projected.workingBlocks[0].turnID
        let outsideWindow = UUID()
        for target in [turnID, outsideWindow] {
            let base = AgentTranscriptPresentationSnapshot(
                revision: 31, workingBlocks: projected.workingBlocks, workingRows: projected.workingRows,
                rowAnchorIndex: projected.rowAnchorIndex, anchorBlockIndex: projected.anchorBlockIndex,
                archivedHistoryState: .init(hasArchivedHistory: true, presentedRowCount: 71, blockCount: 19),
                metadata: .init(latestTurnID: target, dynamicSummaryLockTargetTurnID: target)
            )
            let unchanged = AgentTranscriptProjectionBuilder.maskForLocalDisplay(base, archivedBlocks: [], hiddenSourceIDs: [UUID()])
            XCTAssertEqual(unchanged.presentation, base, "No removal is exactly the caller's windowed presentation")
            XCTAssertEqual(unchanged.anchorVisits, 0, "No-op masking does not rebuild the anchor indexes")
            let partial = AgentTranscriptProjectionBuilder.maskForLocalDisplay(base, archivedBlocks: [], hiddenSourceIDs: [quiet.id])
            XCTAssertEqual(partial.presentation.metadata, base.metadata, "Partial loss or an out-of-window reference is not full turn loss")
            XCTAssertEqual(partial.presentation.archivedHistoryState, base.archivedHistoryState, "An untouched archive keeps its caller metadata")
            XCTAssertTrue(partial.presentation.workingRows.contains(where: { $0.id == ordinary.id }))
            let full = AgentTranscriptProjectionBuilder.maskForLocalDisplay(base, archivedBlocks: [], hiddenSourceIDs: [quiet.id, ordinary.id])
            XCTAssertEqual(full.presentation.metadata.latestTurnID, target == turnID ? nil : target)
            XCTAssertEqual(full.presentation.metadata.dynamicSummaryLockTargetTurnID, target == turnID ? nil : target)
        }
    }

    func testStableArchiveAcrossRealStreamingBasePublicationsReusesBufferAndDoesNoArchiveWork() throws {
        let (h, manager, session) = try liveFixture()
        defer { withExtendedLifetime(manager) {} }
        let history = AgentTranscript(turns: (0 ..< 2000).map { index in
            let sourceID = UUID()
            return AgentTranscriptTurn(
                conclusionActivityID: sourceID, retentionTier: .archived,
                summary: .init(requestText: nil, conclusionText: "ordinary history \(index)", compactConclusionText: "ordinary history \(index)", middleSummaryText: nil, toolCount: 0, notableToolNames: [], keyPaths: [], compactedActivityCount: 0, hadWarning: false, hadError: false),
                terminalState: .completed, startedAt: date, completedAt: date
            )
        })
        h.host.applyTranscriptPresentation(history, to: session)
        let wake = UUID()
        let owner = session.beginRunAttempt(source: "quiet-archive-stream")
        session.quietLedger.markRoutineWake(owner: owner, wakeID: wake)
        session.sealQuietCheckIn(owner: owner, terminalState: .completed, normal: true, hasSuccessor: false)
        XCTAssertTrue(session.endRunAttempt(ifCurrent: owner, source: "quiet-archive-stream"))
        let installedArchive = session.archivedTranscriptSnapshot
        session.archivedTranscriptSnapshot = installedArchive
        _ = h.host.test_publishTranscriptPresentation(tabID: session.tabID, forceRevision: true)
        h.host.syncTranscriptUIState()
        let first = try XCTUnwrap(session.quietTranscriptDisplayCache)
        XCTAssertGreaterThanOrEqual(session.archivedTranscriptSnapshot.rows.count, 2000)
        XCTAssertGreaterThanOrEqual(first.result.rowVisits, 2000, "The initial archive projection is counted")
        XCTAssertEqual(session.quietLedger.hiddenSourceIDs, [wake], "Hidden source is absent from every materialized region")
        var samples: [Double] = []
        var work: [Int] = []
        for index in 0 ..< 100 {
            // Same archive and mask; ordinary live content changes at the existing presentation owner.
            let live = projection([.assistant("ordinary stream \(index)")], tier: .full)
            session.transcriptProjection = live
            session.workingTranscriptProjection = live
            let previousRevision = h.host.activeTranscriptPresentation.revision
            let start = ContinuousClock.now
            _ = h.host.test_publishTranscriptPresentation(tabID: session.tabID, forceRevision: true)
            h.host.syncTranscriptUIState()
            let elapsed = start.duration(to: .now)
            samples.append(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
            let base = h.host.activeTranscriptPresentation
            let cache = try XCTUnwrap(session.quietTranscriptDisplayCache)
            XCTAssertGreaterThan(base.revision, previousRevision, "Exercises the actual didSet and owner UI sync")
            XCTAssertEqual(cache.result.presentation, base)
            XCTAssertEqual(cache.result.presentation.metadata, base.metadata)
            XCTAssertEqual(cache.result.presentation.archivedHistoryState, base.archivedHistoryState)
            XCTAssertEqual(cache.result.anchorVisits, 0)
            XCTAssertEqual(cache.result.blockVisits, 2, "Only the live visible/working blocks; no archive ID/count pass")
            XCTAssertLessThanOrEqual(cache.result.rowVisits, 4, "Only visible/working live rows, never the stable 2000-row archive")
            work.append(cache.result.rowVisits)
            first.result.archivedBlocks.withUnsafeBufferPointer { old in
                cache.result.archivedBlocks.withUnsafeBufferPointer { current in XCTAssertEqual(old.baseAddress, current.baseAddress) }
            }
            session.archivedTranscriptSnapshot.blocks.withUnsafeBufferPointer { caller in
                cache.result.archivedBlocks.withUnsafeBufferPointer { current in XCTAssertEqual(caller.baseAddress, current.baseAddress, "No-op preserves caller archive buffer") }
            }
        }
        print("QUIET_F2_STREAM samplesMS=\(samples) totalRowVisits=\(work) p99MS=\(samples.sorted()[98]) maxMS=\(samples.max()!) quantile=nearestRankCeil0.99Nminus1 archiveRows=2000 baseAssignments=100")
        // An equal-value archive assignment is still a real writer/invalidation boundary.
        let snapshot = session.archivedTranscriptSnapshot
        session.archivedTranscriptSnapshot = snapshot
        XCTAssertNil(session.quietTranscriptDisplayCache)
        h.host.syncTranscriptUIState()
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(session.quietTranscriptDisplayCache).result.rowVisits, 2000)
        session.retireQuietUnmaterializedWake(wake)
        h.host.syncTranscriptUIState()
        XCTAssertEqual(session.quietLedger.hiddenSourceIDs, [])
        XCTAssertEqual(session.quietTranscriptDisplayCache?.result.presentation, h.host.activeTranscriptPresentation)
    }

    func testSourceDrivenLiveRefreshReusesQuietArchiveForUnmaterializedWake() throws {
        try assertSourceDrivenLiveRefreshReusesQuietArchive(archivedQuietSource: false)
    }

    func testSourceDrivenLiveRefreshReusesQuietArchiveForArchivedSyntheticAlias() throws {
        try assertSourceDrivenLiveRefreshReusesQuietArchive(archivedQuietSource: true)
    }

    private func assertSourceDrivenLiveRefreshReusesQuietArchive(archivedQuietSource: Bool) throws {
        let (h, manager, session) = try liveFixture()
        defer { withExtendedLifetime(manager) {} }
        let wake = UUID()
        let quiet = AgentChatItem.assistant("[ack]", sequenceIndex: 0)
        let owner = session.beginRunAttempt(source: "quiet-source-archive")
        session.quietLedger.markRoutineWake(owner: owner, wakeID: wake)
        if archivedQuietSource { session.appendItem(quiet) }
        session.sealQuietCheckIn(owner: owner, terminalState: .completed, normal: true, hasSuccessor: false)
        XCTAssertTrue(session.endRunAttempt(ifCurrent: owner, source: "quiet-source-archive"))
        session.runState = .running
        let request = AgentChatItem.user("ordinary live request", sequenceIndex: 10000)
        let stream = AgentChatItem.assistant("ordinary live stream", sequenceIndex: 10001)
        let live = AgentTranscriptIO.buildTranscript(from: [request, stream], terminalState: .running, compact: false)
        let history = (0 ..< 2000).map { index in
            let text = archivedQuietSource && index == 0 ? "[ack]" : "ordinary history \(index)"
            return AgentTranscriptTurn(
                conclusionActivityID: archivedQuietSource && index == 0 ? quiet.id : UUID(), retentionTier: .archived,
                summary: .init(requestText: nil, conclusionText: text, compactConclusionText: text, middleSummaryText: nil, toolCount: 0, notableToolNames: [], keyPaths: [], compactedActivityCount: 0, hadWarning: false, hadError: false),
                terminalState: .completed, startedAt: date, completedAt: date
            )
        }
        let transcript = AgentTranscriptCompactor.compact(AgentTranscript(turns: history + live.turns))
        h.host.applyTranscriptPresentation(transcript, to: session)
        // Retention movement preserves the archived source's proof; source mutations below use
        // the ordinary session callback, not direct base/projection assignment.
        session.setItemsSilently([request, stream], reason: .retentionCompaction)
        _ = h.host.test_publishTranscriptPresentation(tabID: session.tabID, forceRevision: true)
        h.host.syncTranscriptUIState()
        let initial = try XCTUnwrap(session.quietTranscriptDisplayCache)
        let installedArchive = session.archivedTranscriptSnapshot
        XCTAssertEqual(installedArchive.rows.count, 2000)
        XCTAssertEqual(initial.result.archiveBlockVisits, 2000)
        XCTAssertEqual(initial.result.archiveRowVisits, 2000)
        XCTAssertTrue(session.quietLedger.hiddenSourceIDs.contains(archivedQuietSource ? quiet.id : wake))
        let alias = try XCTUnwrap(installedArchive.rows.first)
        if archivedQuietSource {
            XCTAssertNotEqual(alias.id, quiet.id)
            XCTAssertTrue(session.quietTranscriptArchiveDisplayCache?.region.removedRowIDs.contains(alias.id) == true)
            XCTAssertFalse(initial.result.archivedBlocks.contains { $0.rows.contains { $0.id == alias.id } })
        }
        let expectedArchiveCount = archivedQuietSource ? 1999 : 2000
        XCTAssertEqual(initial.result.archivedBlocks.count, expectedArchiveCount)
        h.host.test_setAllowsScheduledDerivedTranscriptRefreshWithoutPromptManager(true)
        defer { h.host.test_setAllowsScheduledDerivedTranscriptRefreshWithoutPromptManager(false) }
        var quietMS: [Double] = [], builderMS: [Double] = [], refreshMS: [Double] = [], inclusiveMS: [Double] = [], archiveSnapshotMS: [Double] = []
        var quietArchiveBlocks: [Int] = [], quietArchiveRows: [Int] = []
        func ms(_ from: ContinuousClock.Instant, _ to: ContinuousClock.Instant) -> Double {
            let elapsed = from.duration(to: to)
            return Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        }
        for index in 0 ..< 100 {
            let oldSourceRevision = session.sourceItemsRevision
            let oldBuildCount = session.transcriptPerformanceSnapshot.projectionBuildCount
            let oldPresentationRevision = h.host.activeTranscriptPresentation.revision
            let start = ContinuousClock.now
            session.mutateItem(at: 1) { $0.text = "ordinary streamed text \(index)"
                $0.isStreaming = true
            }
            // Drain the real scheduled source refresh synchronously, separating existing builder
            // cost from publication + didSet-owned quiet display preparation. No projection helper.
            h.host.refreshDerivedTranscriptState(for: session, reason: .liveMutation, publishActivePresentation: false)
            let refreshed = ContinuousClock.now
            let publishStart = ContinuousClock.now
            _ = h.host.test_publishTranscriptPresentation(tabID: session.tabID, forceRevision: true)
            h.host.syncTranscriptUIState()
            let end = ContinuousClock.now
            quietMS.append(ms(publishStart, end))
            refreshMS.append(ms(start, refreshed))
            inclusiveMS.append(ms(start, end))
            try builderMS.append(XCTUnwrap(session.transcriptPerformanceSnapshot.lastProjectionBuildDurationMS))
            let cache = try XCTUnwrap(session.quietTranscriptDisplayCache)
            let base = h.host.activeTranscriptPresentation
            XCTAssertGreaterThan(session.sourceItemsRevision, oldSourceRevision)
            XCTAssertEqual(session.transcriptPerformanceSnapshot.projectionBuildCount, oldBuildCount + 1)
            XCTAssertGreaterThan(base.revision, oldPresentationRevision)
            XCTAssertEqual(session.transcriptPerformanceSnapshot.lastSanitizeReusedTurnCount, 2000)
            XCTAssertTrue(cache.result.presentation.visibleRows.contains { $0.id == stream.id && $0.text == "ordinary streamed text \(index)" })
            XCTAssertEqual(cache.result.presentation.visibleRows, base.visibleRows)
            XCTAssertEqual(cache.result.presentation.workingRows, base.workingRows)
            XCTAssertEqual(cache.result.presentation.visibleBlocks, base.visibleBlocks)
            XCTAssertEqual(cache.result.presentation.workingBlocks, base.workingBlocks)
            XCTAssertEqual(cache.result.presentation.metadata, base.metadata)
            XCTAssertEqual(cache.result.presentation.rowAnchorIndex, base.rowAnchorIndex)
            XCTAssertEqual(cache.result.presentation.anchorBlockIndex, base.anchorBlockIndex)
            XCTAssertEqual(cache.result.presentation.archivedHistoryState, .init(hasArchivedHistory: true, presentedRowCount: expectedArchiveCount, blockCount: expectedArchiveCount))
            XCTAssertEqual(cache.result.archiveBlockVisits, 0, "No repeated QUIET MASK archive traversal; existing builder work is separate")
            XCTAssertEqual(cache.result.archiveRowVisits, 0)
            XCTAssertEqual(cache.result.archivedBlocks.count, expectedArchiveCount)
            quietArchiveBlocks.append(cache.result.archiveBlockVisits)
            quietArchiveRows.append(cache.result.archiveRowVisits)
            initial.result.archivedBlocks.withUnsafeBufferPointer { old in
                cache.result.archivedBlocks.withUnsafeBufferPointer { current in XCTAssertEqual(old.baseAddress, current.baseAddress, "Masked archive storage survives the BUILT installation") }
            }
            installedArchive.blocks.withUnsafeBufferPointer { old in
                session.archivedTranscriptSnapshot.blocks.withUnsafeBufferPointer { current in XCTAssertEqual(old.baseAddress, current.baseAddress, "Unchanged archive is not reinstalled") }
            }
            // Diagnostic-only repetition of the unchanged production archive snapshot/count/index
            // routine on this SAME fixture, outside both timed real paths. This is a subcost,
            // not the entire builder cost, and is not additional production quiet-mask work.
            let archiveStart = ContinuousClock.now
            let measuredArchive = AgentTranscriptProjectionBuilder.archivedSnapshot(from: session.fullTranscriptProjection)
            archiveSnapshotMS.append(ms(archiveStart, .now))
            XCTAssertEqual(measuredArchive.rows.count, 2000)
        }
        func measurements(_ samples: [Double]) -> [String: Any] {
            ["samplesMS": samples, "p99MS": samples.sorted()[Int(ceil(0.99 * Double(samples.count))) - 1], "maxMS": samples.max()!]
        }
        let measurements: [String: Any] = [
            "scenario": archivedQuietSource ? "archived-synthetic-alias" : "unmaterialized-wake", "n": 100,
            "quantile": "sort(samples)[ceil(0.99*N)-1]", "archiveRows": 2000,
            "quietPublicationAndOwnerSync": measurements(quietMS), "existingBuilderTotal": measurements(builderMS),
            "sourceAndDerivedRefresh": measurements(refreshMS), "inclusiveSourceThroughUISync": measurements(inclusiveMS),
            "separateArchiveSnapshotSubcost": measurements(archiveSnapshotMS),
            "quietArchiveBlockVisits": quietArchiveBlocks, "quietArchiveRowVisits": quietArchiveRows,
            "builderStatus": "pre-existing, unchanged; current measurement, not a pristine-baseline measurement"
        ]
        try print("QUIET_F2_SOURCE_STREAM " + String(decoding: JSONSerialization.data(withJSONObject: measurements, options: [.sortedKeys]), as: UTF8.self))
        // A real archive replacement runs through the built installer and MUST retire both caches.
        var changed = session.transcript
        changed.turns[10].conclusionActivityID = UUID()
        changed.turns[10].summary?.conclusionText = "changed archived conclusion"
        changed.turns[10].summary?.compactConclusionText = "changed archived conclusion"
        h.host.applyTranscriptPresentation(changed, to: session)
        XCTAssertNil(session.quietTranscriptArchiveDisplayCache)
        XCTAssertNil(session.quietTranscriptDisplayCache)
        _ = h.host.test_publishTranscriptPresentation(tabID: session.tabID, forceRevision: true)
        h.host.syncTranscriptUIState()
        let replaced = try XCTUnwrap(session.quietTranscriptDisplayCache)
        XCTAssertEqual(replaced.result.archiveBlockVisits, 2000)
        XCTAssertEqual(replaced.result.archiveRowVisits, 2000)
        XCTAssertTrue(replaced.result.archivedBlocks.contains { $0.rows.contains { $0.text == "changed archived conclusion" } })
        XCTAssertEqual(replaced.result.archivedBlocks.count, expectedArchiveCount)
        // Explicit same-content apply/hydration remains an invalidating writer, never a live reuse.
        h.host.applyTranscriptPresentation(session.transcript, to: session)
        XCTAssertNil(session.quietTranscriptArchiveDisplayCache)
    }

    func testReusedArchiveRetainsSyntheticAliasContributionAcrossWindowedBaseAssignments() throws {
        let (h, manager, session) = try liveFixture()
        defer { withExtendedLifetime(manager) {} }
        let row = AgentChatItem.assistant("[ack]")
        let owner = session.beginRunAttempt(source: "quiet-archive-alias")
        session.quietLedger.markRoutineWake(owner: owner, wakeID: UUID())
        session.appendItem(row)
        session.sealQuietCheckIn(owner: owner, terminalState: .completed, normal: true, hasSuccessor: false)
        XCTAssertTrue(session.endRunAttempt(ifCurrent: owner, source: "quiet-archive-alias"))
        let archived = projection([], tier: .archived, conclusionID: row.id, summary: .init(
            requestText: nil, conclusionText: "[ack]", compactConclusionText: "[ack]", middleSummaryText: nil,
            toolCount: 0, notableToolNames: [], keyPaths: [], compactedActivityCount: 0, hadWarning: false, hadError: false
        ))
        session.archivedTranscriptSnapshot = AgentTranscriptProjectionBuilder.archivedSnapshot(from: archived)
        let synthetic = try XCTUnwrap(archived.archivedRows.first)
        XCTAssertNotEqual(synthetic.id, row.id)
        for index in 0 ..< 3 {
            // The archive carries the source anchor. Windowed flat rows can overlap it without
            // carrying that block/anchor themselves; archive removedRowIDs must still contribute.
            let windowed = AgentTranscriptProjection(workingRows: [synthetic], anchorBlockIndex: archived.anchorBlockIndex)
            session.transcriptProjection = windowed
            session.workingTranscriptProjection = windowed
            _ = h.host.test_publishTranscriptPresentation(tabID: session.tabID, forceRevision: true)
            h.host.syncTranscriptUIState()
            let result = try XCTUnwrap(session.quietTranscriptDisplayCache).result
            XCTAssertTrue(result.archivedBlocks.isEmpty)
            XCTAssertTrue(result.presentation.visibleRows.isEmpty)
            XCTAssertTrue(result.presentation.workingRows.isEmpty)
            XCTAssertTrue(result.presentation.anchorBlockIndex.isEmpty)
            if index > 0 { XCTAssertEqual(result.rowVisits, 2, "Only the two flat aliases are visited; no cached archive scan") }
        }
    }

    func testStructuralRekeyAndRetentionIndexOwnerWorkCadence() {
        let session = AgentTabSession(tabID: UUID())
        for _ in 0 ..< 12 {
            let owner = session.beginRunAttempt(source: "quiet-retained-source")
            let wake = UUID()
            session.quietLedger.recordPhysicalDispatch(owner: owner, wakeID: wake, routineQuietCheckIn: true, alreadyAcquired: false)
            session.appendItem(.assistant("[ack]"))
            session.sealQuietCheckIn(owner: owner, terminalState: .completed, normal: true, hasSuccessor: false)
            XCTAssertTrue(session.endRunAttempt(ifCurrent: owner, source: "quiet-retained-source"))
            session.retireQuietUnmaterializedWake(wake)
        }
        let identities = session.liveItemIDs
        XCTAssertEqual(session.quietLedger.hiddenSourceIDs, identities)
        let maskRevision = session.quietLedger.displayMaskRevision
        let original = session.quietLedger.facts
        let scansBefore = session.test_fullRetentionPayloadMapScannedItemCount
        var samples: [Double] = []
        for _ in 0 ..< 32 {
            let start = ContinuousClock.now
            let next = session.nextSequenceIndex
            session.mutateItem(at: 0) { $0.sequenceIndex = next }
            session.setItemsSilentlyForRetentionCompaction(session.items)
            let elapsed = start.duration(to: .now)
            samples.append(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
            XCTAssertEqual(session.liveItemIDs, identities)
            XCTAssertEqual(session.quietLedger.facts, original)
            XCTAssertEqual(session.quietLedger.hiddenSourceIDs, identities)
            XCTAssertEqual(session.quietLedger.displayMaskRevision, maskRevision, "Structural source proof survives without a fake membership change")
        }
        XCTAssertEqual(session.items.count, 12)
        print("QUIET_C5_STRUCTURAL samples=32 retainedSuffixRows=12 rekeyRetentionP99MS=\(samples.sorted()[31]) retentionPayloadItemsScanned=\(session.test_fullRetentionPayloadMapScannedItemCount - scansBefore) hiddenMembership=\(session.quietLedger.hiddenSourceIDs.count) newQuietAddressIndexes=0")
    }
}
