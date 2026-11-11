import Foundation
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

final class AgentTranscriptReplyPresentationTests: XCTestCase {
    private func fixture(interrupted: Bool) -> (AgentTranscript, [UUID]) {
        var items: [AgentChatItem] = [.user("question", sequenceIndex: 0)]
        var sequence = 1
        var replyIDs: [UUID] = []
        for text in interrupted ? ["late", "answer"] : ["answer"] {
            let item = AgentChatItem.assistant(text, sequenceIndex: sequence)
            items.append(item)
            replyIDs.append(item.id)
            sequence += 1
        }
        for _ in 0 ..< 10 {
            let id = UUID()
            items.append(.toolCall(name: "Bash", invocationID: id, argsJSON: "{}", sequenceIndex: sequence))
            sequence += 1
            items.append(.toolResult(name: "Bash", invocationID: id, resultJSON: "{}", isError: false, sequenceIndex: sequence))
            sequence += 1
        }
        return (AgentTranscriptIO.importLegacyItems(items), replyIDs)
    }

    private func assertVisible(_ transcript: AgentTranscript, ids: [UUID], file: StaticString = #filePath, line: UInt = #line) {
        let presentation = AgentTranscriptProjectionBuilder.buildWithCaches(from: transcript, turnCaches: [:], replyPresentation: true).projection
        let blocks = presentation.workingBlocks
        for id in ids {
            XCTAssertTrue(blocks.contains { $0.kind == .standaloneAssistant && $0.activityIDs.contains(id) }, file: file, line: line)
        }
        XCTAssertTrue(blocks.contains { $0.kind == .groupedHistory }, file: file, line: line)
        XCTAssertEqual(Set(blocks.map(\.id)).count, blocks.count, file: file, line: line)
    }

    func testRequestReplyAndTools() {
        let (transcript, ids) = fixture(interrupted: false)
        assertVisible(transcript, ids: ids)
    }

    func testLateTextAndAnswerRemainVisible() {
        let (transcript, ids) = fixture(interrupted: true)
        assertVisible(transcript, ids: ids)
    }

    func testHistoricalOutputsUnaffectedByPresentation() throws {
        let transcript = AgentTranscriptIO.importLegacyItems([.user("question", sequenceIndex: 0), .assistant("answer", sequenceIndex: 1)])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let cutoff = try XCTUnwrap(AgentTranscriptIO.flattenFullTranscript(transcript).last?.id)
        let handoffBefore = try encoder.encode(AgentTranscriptIO.buildHandoffTranscriptItems(from: transcript, upToRowID: cutoff))
        let rowsBefore = try encoder.encode(AgentTranscriptIO.flattenFullTranscript(transcript))
        let projection = AgentTranscriptProjectionBuilder.build(from: transcript)
        _ = AgentTranscriptProjectionBuilder.buildWithCaches(from: transcript, turnCaches: [:], replyPresentation: true)
        XCTAssertEqual(handoffBefore, try encoder.encode(AgentTranscriptIO.buildHandoffTranscriptItems(from: transcript, upToRowID: cutoff)))
        XCTAssertEqual(rowsBefore, try encoder.encode(AgentTranscriptIO.flattenFullTranscript(transcript)))
        XCTAssertEqual(projection, AgentTranscriptProjectionBuilder.build(from: transcript))
    }

    func testOnlyChangedTurnIsReclassified() {
        var turns: [AgentTranscriptTurn] = []
        for _ in 0 ..< 50 {
            turns.append(contentsOf: fixture(interrupted: true).0.turns)
        }
        let transcript = AgentTranscript(version: 3, turns: turns, nextSequenceIndex: 10000)
        var classified: [UUID] = []
        let first = AgentTranscriptProjectionBuilder.buildWithCaches(
            from: transcript, turnCaches: [:], replyPresentation: true,
            onReplyClassification: { classified.append($0) }
        )
        XCTAssertEqual(classified.count, 50)
        var changed = transcript
        changed.turns[25].responseSpans[0].activities.append(changed.turns[25].responseSpans[0].activities[0])
        classified.removeAll()
        _ = AgentTranscriptProjectionBuilder.buildWithCaches(
            from: changed, turnCaches: first.updatedTurnCaches, replyPresentation: true,
            onReplyClassification: { classified.append($0) }
        )
        XCTAssertEqual(classified, [changed.turns[25].id])
    }

    func testSplitAnchorStableAcrossCachedRefresh() throws {
        let (transcript, _) = fixture(interrupted: true)
        let first = AgentTranscriptProjectionBuilder.buildWithCaches(from: transcript, turnCaches: [:], replyPresentation: true)
        let group = try XCTUnwrap(first.projection.workingBlocks.first { $0.kind == .groupedHistory })
        XCTAssertNotNil(group.primaryAnchor)
        let second = AgentTranscriptProjectionBuilder.buildWithCaches(from: transcript, turnCaches: first.updatedTurnCaches, replyPresentation: true)
        XCTAssertEqual(try second.projection.anchorBlockIndex[XCTUnwrap(group.primaryAnchor)], group.id)
    }

    func testSameCountActivityMutationsInvalidatePresentationCache() throws {
        var (transcript, ids) = fixture(interrupted: true)
        let first = AgentTranscriptProjectionBuilder.buildWithCaches(from: transcript, turnCaches: [:], replyPresentation: true)
        let index = try XCTUnwrap(transcript.turns[0].responseSpans[0].activities.firstIndex { $0.id == ids[1] })
        transcript.turns[0].responseSpans[0].activities[index].text = "updated answer"
        var classified: [UUID] = []
        let second = AgentTranscriptProjectionBuilder.buildWithCaches(
            from: transcript, turnCaches: first.updatedTurnCaches, replyPresentation: true,
            onReplyClassification: { classified.append($0) }
        )
        XCTAssertEqual(classified, [transcript.turns[0].id])
        XCTAssertTrue(second.projection.workingBlocks.flatMap(\.rows).contains { $0.id == ids[1] && $0.text == "updated answer" })
        transcript.turns[0].responseSpans[0].activities[index].itemKind = .thinking
        classified.removeAll()
        let third = AgentTranscriptProjectionBuilder.buildWithCaches(
            from: transcript, turnCaches: second.updatedTurnCaches, replyPresentation: true,
            onReplyClassification: { classified.append($0) }
        )
        XCTAssertEqual(classified, [transcript.turns[0].id])
        XCTAssertFalse(third.projection.workingBlocks.contains { $0.kind == .standaloneAssistant && $0.activityIDs.contains(ids[1]) })
    }

    func testStreamingWritebackRebuildsOnlyChangedTurnSummary() {
        var turns: [AgentTranscriptTurn] = []
        for _ in 0 ..< 50 {
            turns.append(contentsOf: fixture(interrupted: true).0.turns)
        }
        let original = AgentTranscript(version: 3, turns: turns, nextSequenceIndex: 10000)
        var rebuilt: [UUID] = []
        let cached = AgentTranscriptProjectionBuilder.refreshCompletedFullTurnGroupedHistoryCaches(
            in: original, onSummaryRebuild: { rebuilt.append($0) }
        )
        XCTAssertEqual(rebuilt.count, 50)
        var changed = cached
        changed.turns[25].responseSpans[0].activities[0].text = "streaming update"
        rebuilt.removeAll()
        _ = AgentTranscriptProjectionBuilder.refreshCompletedFullTurnGroupedHistoryCaches(
            in: changed, reusablePrefixTurnCount: 50, onSummaryRebuild: { rebuilt.append($0) }
        )
        XCTAssertEqual(rebuilt, [changed.turns[25].id])
    }

    func testDescriptorsCarryReplyFlagsOnlyWhenRequested() throws {
        let (transcript, ids) = fixture(interrupted: true)
        let turn = try XCTUnwrap(transcript.turns.first)
        let span = try XCTUnwrap(turn.responseSpans.first)
        var emitted = Set<UUID>()
        let historical = AgentTranscriptProjectionBuilder.fullSpanLeafDescriptors(
            for: span, in: turn, emittedConclusionActivityIDs: &emitted
        )
        XCTAssertFalse(historical.contains { $0.isReply })
        emitted.removeAll()
        let presentation = AgentTranscriptProjectionBuilder.fullSpanLeafDescriptors(
            for: span, in: turn, emittedConclusionActivityIDs: &emitted, replyIDs: Set(ids)
        )
        XCTAssertEqual(presentation.filter(\.isReply).count, 2)
    }

    func testPresentationCountAndProbeMatchSplitAndUnsplit() throws {
        for interrupted in [false, true] {
            let (transcript, _) = fixture(interrupted: interrupted)
            let turn = try XCTUnwrap(transcript.turns.first)
            let projection = AgentTranscriptProjectionBuilder.buildWithCaches(
                from: transcript, turnCaches: [:], replyPresentation: true
            ).projection
            let count = AgentTranscriptProjectionBuilder.fullTurnVisibleRowCount(
                for: turn, detailedToolTailLimit: 8, replyPresentation: true
            )
            let renderedCount = projection.workingBlocks.reduce(0) { total, block in
                total + ((block.kind == .groupedHistory || block.kind == .activityCluster) ? 1 : block.rows.count)
            }
            XCTAssertEqual(count, renderedCount)
            XCTAssertEqual(
                AgentTranscriptProjectionBuilder.groupedHistoryWouldCollapse(in: turn, detailedToolTailLimit: 8, replyPresentation: true),
                projection.workingBlocks.contains { $0.kind == .groupedHistory }
            )
        }
    }

    func testMixedTranscriptStress() {
        var items: [AgentChatItem] = [.user("question", sequenceIndex: 0)]
        var sequence = 1
        for index in 0 ..< 300 {
            if index % 3 == 0 {
                items.append(.assistant("message \(index)", sequenceIndex: sequence))
                sequence += 1
            }
            let id = UUID()
            items.append(.toolCall(name: "Bash", invocationID: id, argsJSON: "{}", sequenceIndex: sequence))
            sequence += 1
            items.append(.toolResult(name: "Bash", invocationID: id, resultJSON: "{}", isError: false, sequenceIndex: sequence))
            sequence += 1
        }
        let transcript = AgentTranscriptIO.importLegacyItems(items)
        _ = AgentTranscriptProjectionBuilder.buildWithCaches(from: transcript, turnCaches: [:], replyPresentation: true)
        let start = Date.timeIntervalSinceReferenceDate
        let projection = AgentTranscriptProjectionBuilder.buildWithCaches(from: transcript, turnCaches: [:], replyPresentation: true).projection
        let elapsed = Date.timeIntervalSinceReferenceDate - start
        print("REPLY_PRESENTATION_STRESS_SECONDS=\(elapsed)")
        XCTAssertLessThan(elapsed, 0.15, "Warmed baseline: 0.074 seconds")
        let blocks = projection.workingBlocks
        XCTAssertEqual(Set(blocks.map(\.id)).count, blocks.count)
        let groups = blocks.filter { $0.kind == .groupedHistory }
        let anchors = groups.compactMap(\.primaryAnchor)
        XCTAssertEqual(Set(anchors).count, anchors.count)
    }

    func testReplyAndGroupIdentityAcrossCompletion() {
        let (completed, ids) = fixture(interrupted: true)
        var active = completed
        active.turns[0].completedAt = nil
        active.turns[0].terminalState = .running
        XCTAssertFalse(active.turns[0].isCompleted)
        active.turns[0].responseSpans[0].lifecycle = .open
        active.turns[0].responseSpans[0].completedAt = nil
        let liveBuild = AgentTranscriptProjectionBuilder.buildWithCaches(from: active, turnCaches: [:], replyPresentation: true)
        let live = liveBuild.projection
        let done = AgentTranscriptProjectionBuilder.buildWithCaches(from: completed, turnCaches: liveBuild.updatedTurnCaches, replyPresentation: true).projection
        for projection in [live, done] {
            for id in ids {
                XCTAssertTrue(projection.workingBlocks.contains { $0.kind == .standaloneAssistant && $0.activityIDs.contains(id) })
                XCTAssertFalse(projection.workingBlocks.filter { $0.kind == .groupedHistory }.contains { $0.activityIDs.contains(id) })
            }
        }
        let liveGroups = live.workingBlocks.filter { $0.kind == .groupedHistory }
        let doneGroups = done.workingBlocks.filter { $0.kind == .groupedHistory }
        XCTAssertFalse(liveGroups.isEmpty)
        XCTAssertEqual(liveGroups.map(\.id), doneGroups.map(\.id))
        XCTAssertEqual(liveGroups.map(\.primaryAnchor), doneGroups.map(\.primaryAnchor))
    }

    func testReplyStateCarriesAcrossSpans() throws {
        func make(_ replyInFirstSpan: Bool) throws -> (AgentTranscript, UUID, UUID) {
            var (transcript, ids) = fixture(interrupted: true)
            let original = transcript.turns[0].responseSpans[0]
            let a = try XCTUnwrap(original.activities.first { $0.id == ids[0] })
            let b = try XCTUnwrap(original.activities.first { $0.id == ids[1] })
            let tools = original.activities.filter { $0.itemKind == .toolCall || $0.itemKind == .toolResult }
            var first = original
            var second = AgentTranscriptProviderResponseSpan(startedAt: original.startedAt)
            first.lifecycle = .completed
            second.lifecycle = .completed
            if replyInFirstSpan {
                first.activities = [a] + Array(tools.prefix(2))
                second.activities = Array(tools[2 ..< 4]) + [b] + Array(tools.dropFirst(4))
                let extra = UUID()
                let call = AgentChatItem.toolCall(name: "Bash", invocationID: extra, argsJSON: "{}", sequenceIndex: 100)
                let result = AgentChatItem.toolResult(name: "Bash", invocationID: extra, resultJSON: "{}", isError: false, sequenceIndex: 101)
                let extraTranscript = AgentTranscriptIO.importLegacyItems([.user("extra", sequenceIndex: 99), call, result])
                second.activities += extraTranscript.turns[0].responseSpans[0].activities
            } else {
                first.activities = Array(tools.prefix(2))
                second.activities = [a] + Array(tools.dropFirst(2))
            }
            for index in first.activities.indices {
                first.activities[index].sequenceIndex = index + 1
            }
            for index in second.activities.indices {
                second.activities[index].sequenceIndex = first.activities.count + index + 1
            }
            transcript.turns[0].responseSpans = [first, second]
            transcript.turns[0].conclusionActivityID = nil
            return (transcript, a.id, b.id)
        }
        let (checkFirst, answer, _) = try make(false)
        let checkProjection = AgentTranscriptProjectionBuilder.buildWithCaches(from: checkFirst, turnCaches: [:], replyPresentation: true).projection
        XCTAssertTrue(checkProjection.workingBlocks.contains { $0.kind == .standaloneAssistant && $0.activityIDs.contains(answer) })
        let (answeredFirst, firstAnswer, narration) = try make(true)
        let answeredProjection = AgentTranscriptProjectionBuilder.buildWithCaches(from: answeredFirst, turnCaches: [:], replyPresentation: true).projection
        XCTAssertTrue(answeredProjection.workingBlocks.contains { $0.kind == .standaloneAssistant && $0.activityIDs.contains(firstAnswer) })
        XCTAssertTrue(answeredProjection.workingBlocks.contains { $0.kind == .groupedHistory && $0.activityIDs.contains(narration) })
    }

    func testPresentationCountWithoutRequestMatchesRenderedRows() {
        var (transcript, _) = fixture(interrupted: true)
        transcript.turns[0].request = nil
        let turn = transcript.turns[0]
        let projection = AgentTranscriptProjectionBuilder.buildWithCaches(from: transcript, turnCaches: [:], replyPresentation: true).projection
        let actual = projection.workingBlocks.reduce(0) { $0 + (($1.kind == .groupedHistory || $1.kind == .activityCluster) ? 1 : $1.rows.count) }
        XCTAssertEqual(AgentTranscriptProjectionBuilder.fullTurnVisibleRowCount(for: turn, detailedToolTailLimit: 8, replyPresentation: true), actual)
    }

    func testInterleavedSpansKeepBothRepliesInChronologicalOrder() throws {
        var (transcript, ids) = fixture(interrupted: true)
        let original = transcript.turns[0].responseSpans[0]
        var a = try XCTUnwrap(original.activities.first { $0.id == ids[0] })
        var b = try XCTUnwrap(original.activities.first { $0.id == ids[1] })
        var tools = original.activities.filter { $0.itemKind == .toolCall || $0.itemKind == .toolResult }
        a.sequenceIndex = 1
        b.sequenceIndex = 3
        for i in tools.indices {
            tools[i].sequenceIndex = 10 + i
        }
        var first = original
        first.activities = [a, tools[0], tools[1]]
        first.activities[1].sequenceIndex = 5
        first.activities[2].sequenceIndex = 6
        var second = AgentTranscriptProviderResponseSpan(startedAt: original.startedAt)
        second.lifecycle = .completed
        second.activities = [b] + Array(tools.dropFirst(2))
        transcript.turns[0].responseSpans = [first, second]
        transcript.turns[0].conclusionActivityID = nil
        let blocks = AgentTranscriptProjectionBuilder.buildWithCaches(from: transcript, turnCaches: [:], replyPresentation: true).projection.workingBlocks
        let replyBlocks = blocks.filter { $0.kind == .standaloneAssistant && !Set($0.activityIDs).isDisjoint(with: Set(ids)) }
        XCTAssertEqual(replyBlocks.flatMap(\.activityIDs), ids)
    }

    func testStartedAtChangeInvalidatesCompletedTurnCache() {
        var (transcript, _) = fixture(interrupted: false)
        transcript.turns[0].terminalState = .completed
        transcript.turns[0].completedAt = nil
        transcript.turns[0].lastActivityAt = nil
        transcript.turns[0].conclusionActivityID = nil
        transcript.turns[0].summary = AgentTranscriptTurnSummary(requestText: nil, conclusionText: "synthetic conclusion", compactConclusionText: nil, middleSummaryText: nil, toolCount: 0, notableToolNames: [], keyPaths: [], compactedActivityCount: 0, hadWarning: false, hadError: false)
        let initial = AgentTranscriptProjectionBuilder.buildWithCaches(from: transcript, turnCaches: [:], replyPresentation: true)
        transcript.turns[0].startedAt = transcript.turns[0].startedAt.addingTimeInterval(120)
        let reused = AgentTranscriptProjectionBuilder.buildWithCaches(from: transcript, turnCaches: initial.updatedTurnCaches, replyPresentation: true)
        let fresh = AgentTranscriptProjectionBuilder.buildWithCaches(from: transcript, turnCaches: [:], replyPresentation: true)
        XCTAssertEqual(reused.projection, fresh.projection)
        XCTAssertEqual(reused.projection.workingBlocks.flatMap(\.rows).first { $0.text == "synthetic conclusion" }?.timestamp, transcript.turns[0].startedAt)
    }

    func testQuietConclusionUsesLocalAnswerForCount() {
        let answer = AgentChatItem.assistant("ordinary answer", sequenceIndex: 1)
        let quiet = AgentChatItem.assistant("quiet", sequenceIndex: 2)
        var transcript = AgentTranscriptIO.importLegacyItems([.user("question", sequenceIndex: 0), answer, quiet])
        transcript.turns[0].responseSpans[0].activities[1].quietCheckInWakeID = UUID()
        transcript.turns[0].conclusionActivityID = quiet.id
        transcript.turns[0].quietLocal = AgentTranscriptQuietLocalTurn(summary: nil, conclusionActivityID: answer.id, completedAt: Date(timeIntervalSince1970: 1))
        let turn = transcript.turns[0]
        let projection = AgentTranscriptProjectionBuilder.buildWithCaches(from: transcript, turnCaches: [:], excludingQuiet: true, replyPresentation: true).projection
        let count = AgentTranscriptProjectionBuilder.fullTurnVisibleRowCount(for: turn, detailedToolTailLimit: 8, replyPresentation: true, excludingQuiet: true)
        XCTAssertEqual(count, 2)
        XCTAssertEqual(projection.workingBlocks.flatMap(\.rows).count, 2)
    }

    func testBothSplitGroupsRetainUniqueAnchors() throws {
        var (transcript, ids) = fixture(interrupted: false)
        let span = transcript.turns[0].responseSpans[0]
        var answer = try XCTUnwrap(span.activities.first { $0.id == ids[0] })
        var tools = span.activities.filter { $0.itemKind == .toolCall || $0.itemKind == .toolResult }
        answer.sequenceIndex = 3
        for i in tools.indices {
            tools[i].sequenceIndex = i < 2 ? i + 1 : i + 2
        }
        transcript.turns[0].responseSpans[0].activities = Array(tools.prefix(2)) + [answer] + Array(tools.dropFirst(2))
        transcript.turns[0].conclusionActivityID = nil
        let projection = AgentTranscriptProjectionBuilder.buildWithCaches(from: transcript, turnCaches: [:], replyPresentation: true).projection
        let groups = projection.workingBlocks.filter { $0.kind == .groupedHistory }
        XCTAssertEqual(groups.count, 2)
        XCTAssertNotEqual(groups[0].id, groups[1].id)
        let spanAnchor = AgentTranscriptAnchor.groupedHistory(turnID: transcript.turns[0].id, spanID: span.id)
        XCTAssertEqual(projection.anchorBlockIndex[spanAnchor], groups[0].id)
        for group in groups {
            for id in group.activityIDs {
                let anchor = try XCTUnwrap(projection.rowAnchorIndex[id])
                XCTAssertEqual(projection.anchorBlockIndex[anchor], group.id)
            }
        }
    }

    func testInterleavedReplySplitsAnotherSpansCollapsedGroup() throws {
        var (transcript, ids) = fixture(interrupted: false)
        let original = transcript.turns[0].responseSpans[0]
        var answer = try XCTUnwrap(original.activities.first { $0.id == ids[0] })
        answer.sequenceIndex = 3
        var tools = original.activities.filter { $0.itemKind == .toolCall || $0.itemKind == .toolResult }
        for i in tools.indices {
            tools[i].sequenceIndex = i < 2 ? i + 1 : i < 4 ? i + 2 : i + 6
        }
        var first = original
        first.activities = tools
        var second = AgentTranscriptProviderResponseSpan(startedAt: original.startedAt)
        second.lifecycle = .completed
        second.activities = [answer]
        transcript.turns[0].responseSpans = [first, second]
        transcript.turns[0].conclusionActivityID = nil
        let projection = AgentTranscriptProjectionBuilder.buildWithCaches(from: transcript, turnCaches: [:], replyPresentation: true).projection
        let blocks = projection.workingBlocks.filter { $0.kind == .groupedHistory || ($0.kind == .standaloneAssistant && $0.activityIDs.contains(answer.id)) }
        XCTAssertEqual(blocks.map(\.kind), [.groupedHistory, .standaloneAssistant, .groupedHistory])
        XCTAssertTrue(blocks[0].activityIDs.contains(tools[0].id))
        XCTAssertFalse(blocks[0].activityIDs.contains(tools[2].id))
        XCTAssertTrue(blocks[2].activityIDs.contains(tools[2].id))
        let actual = projection.workingBlocks.reduce(0) { $0 + (($1.kind == .groupedHistory || $1.kind == .activityCluster) ? 1 : $1.rows.count) }
        XCTAssertEqual(AgentTranscriptProjectionBuilder.fullTurnVisibleRowCount(for: transcript.turns[0], detailedToolTailLimit: 8, replyPresentation: true), actual)
    }

    func testFrozenPrefixReuseInvalidatesQuietSpanSummary() throws {
        let (fixtureTranscript, _) = fixture(interrupted: false)
        var prefix = fixtureTranscript.turns[0]
        prefix.retentionTier = .summary
        var suffix = fixture(interrupted: false).0.turns[0]
        suffix.retentionTier = .condensed
        suffix.terminalState = .completed
        let summary = AgentTranscriptTurnSummary(requestText: nil, conclusionText: "done", compactConclusionText: nil, middleSummaryText: nil, toolCount: 0, notableToolNames: [], keyPaths: [], compactedActivityCount: 0, hadWarning: false, hadError: false)
        suffix.summary = summary
        suffix.quietLocal = AgentTranscriptQuietLocalTurn(summary: summary, conclusionActivityID: suffix.conclusionActivityID, completedAt: Date(timeIntervalSince1970: 1))
        suffix.responseSpans[0].quietLocal = AgentTranscriptQuietLocalSpan(collapsedSummary: nil)
        var emptySpan = AgentTranscriptProviderResponseSpan(startedAt: suffix.startedAt)
        emptySpan.lifecycle = .completed
        let card = AgentTranscriptGroupedHistorySummary(hiddenToolCardCount: 1, hiddenAssistantCount: 0, hiddenProgressCount: 0, hiddenNoteCount: 0, toolSummary: nil)
        emptySpan.quietLocal = AgentTranscriptQuietLocalSpan(collapsedSummary: card)
        suffix.responseSpans.append(emptySpan)
        var original = AgentTranscript(version: 3, turns: [prefix, suffix], nextSequenceIndex: 100)
        original.compactionFrontier = AgentTranscriptCompactionFrontier(frozenPrefixTurnCount: 1, lastFrozenTurnID: prefix.id)
        let first = AgentTranscriptProjectionBuilder.buildWithCaches(from: original, turnCaches: [:], excludingQuiet: true, replyPresentation: true)
        var changed = original
        changed.turns[1].responseSpans[1].quietLocal = AgentTranscriptQuietLocalSpan(collapsedSummary: nil)
        let reused = try XCTUnwrap(AgentTranscriptProjectionBuilder.buildReusingFrozenPrefix(from: changed, previousTranscript: original, previousProjection: first.projection, previousProtection: .none, previousExcludingQuiet: true, previousReplyPresentation: true, reusableFrozenPrefixTurnCount: 1, turnCaches: first.updatedTurnCaches, excludingQuiet: true, replyPresentation: true))
        let fresh = AgentTranscriptProjectionBuilder.buildWithCaches(from: changed, turnCaches: [:], excludingQuiet: true, replyPresentation: true)
        let wrongMode = AgentTranscriptProjectionBuilder.buildReusingFrozenPrefix(from: changed, previousTranscript: original, previousProjection: first.projection, previousProtection: .none, previousExcludingQuiet: false, previousReplyPresentation: true, reusableFrozenPrefixTurnCount: 1, turnCaches: first.updatedTurnCaches, excludingQuiet: true, replyPresentation: true)
        XCTAssertNil(wrongMode)
        XCTAssertEqual(reused.projection, fresh.projection)
        XCTAssertGreaterThan(first.projection.workingBlocks.count, reused.projection.workingBlocks.count)
    }

    func testInterleavedExecutionAndCompanionPreserveEightToolSlots() throws {
        for companion in [false, true] {
            var items: [AgentChatItem] = [.user("request", sequenceIndex: 0)]
            let reply = AgentChatItem.assistant("reply", sequenceIndex: 100)
            var sequence = 1
            let count = companion ? 9 : 8
            for index in 0 ..< count {
                let id = UUID()
                let name = companion && index < 2 ? "mcp__computer-use__click" : "Bash"
                items.append(.toolCall(name: name, invocationID: id, argsJSON: "{}", sequenceIndex: sequence))
                sequence += 1
                items.append(.toolResult(name: name, invocationID: id, resultJSON: "{}", isError: false, sequenceIndex: sequence))
                sequence += 1
            }
            items.append(reply)
            var transcript = AgentTranscriptIO.importLegacyItems(items)
            let original = transcript.turns[0].responseSpans[0]
            var tools = original.activities.filter { $0.itemKind == .toolCall || $0.itemKind == .toolResult }
            for index in tools.indices {
                tools[index].sequenceIndex = companion ? (index < 2 ? index + 1 : index + 2) : (index == 0 ? 1 : index + 2)
            }
            var a = try XCTUnwrap(original.activities.first { $0.id == reply.id })
            a.sequenceIndex = companion ? 3 : 2
            var first = original
            first.activities = tools
            var second = AgentTranscriptProviderResponseSpan(startedAt: original.startedAt)
            second.activities = [a]
            second.lifecycle = .completed
            transcript.turns[0].responseSpans = [first, second]
            transcript.turns[0].conclusionActivityID = nil
            let projection = AgentTranscriptProjectionBuilder.buildWithCaches(from: transcript, turnCaches: [:], replyPresentation: true).projection
            XCTAssertFalse(projection.workingBlocks.contains { $0.kind == .groupedHistory }, "companion=\(companion)")
            XCTAssertFalse(AgentTranscriptProjectionBuilder.groupedHistoryWouldCollapse(in: transcript.turns[0], detailedToolTailLimit: 8, replyPresentation: true))
            for activity in tools.prefix(companion ? 4 : 2) {
                XCTAssertTrue(projection.workingBlocks.contains { ($0.kind == .standaloneTool || $0.kind == .activityCluster) && $0.activityIDs.contains(activity.id) })
            }
            let renderedCount = projection.workingBlocks.reduce(0) { $0 + (($1.kind == .groupedHistory || $1.kind == .activityCluster) ? 1 : $1.rows.count) }
            XCTAssertEqual(AgentTranscriptProjectionBuilder.fullTurnVisibleRowCount(for: transcript.turns[0], detailedToolTailLimit: 8, replyPresentation: true), renderedCount)
        }
    }

    func testSingleSpanConclusionSplitsToolGroupAndCount() throws {
        var (transcript, ids) = fixture(interrupted: false)
        var activities = transcript.turns[0].responseSpans[0].activities
        let answerIndex = try XCTUnwrap(activities.firstIndex { $0.id == ids[0] })
        activities[answerIndex].sequenceIndex = 3
        var index = 0
        for i in activities.indices where i != answerIndex {
            activities[i].sequenceIndex = index < 2 ? index + 1 : index + 2
            index += 1
        }
        transcript.turns[0].responseSpans[0].activities = activities
        transcript.turns[0].conclusionActivityID = ids[0]
        let projection = AgentTranscriptProjectionBuilder.buildWithCaches(from: transcript, turnCaches: [:], replyPresentation: true).projection
        let renderedCount = projection.workingBlocks.reduce(0) { $0 + (($1.kind == .groupedHistory || $1.kind == .activityCluster) ? 1 : $1.rows.count) }
        XCTAssertEqual(AgentTranscriptProjectionBuilder.fullTurnVisibleRowCount(for: transcript.turns[0], detailedToolTailLimit: 8, replyPresentation: true), renderedCount)
        XCTAssertEqual(renderedCount, 20)
        let split = projection.workingBlocks.filter { $0.kind == .groupedHistory || $0.kind == .conclusion }
        XCTAssertEqual(split.map(\.kind), [.groupedHistory, .conclusion, .groupedHistory])
        let orderedTools = activities.filter { $0.itemKind == .toolCall || $0.itemKind == .toolResult }.sorted { $0.sequenceIndex < $1.sequenceIndex }
        XCTAssertTrue(split[0].activityIDs.contains(orderedTools[0].id))
        XCTAssertFalse(split[0].activityIDs.contains(orderedTools[2].id))
        XCTAssertTrue(split[2].activityIDs.contains(orderedTools[2].id))
    }

    func testFrozenPrefixHistoricalModeRebuildsSuffixMetadata() throws {
        var prefix = fixture(interrupted: false).0.turns[0]
        prefix.retentionTier = .summary
        var suffix = fixture(interrupted: false).0.turns[0]
        suffix.terminalState = .completed
        suffix.completedAt = nil
        suffix.lastActivityAt = nil
        suffix.conclusionActivityID = nil
        suffix.summary = AgentTranscriptTurnSummary(requestText: nil, conclusionText: "synthetic", compactConclusionText: nil, middleSummaryText: nil, toolCount: 0, notableToolNames: [], keyPaths: [], compactedActivityCount: 0, hadWarning: false, hadError: false)
        var original = AgentTranscript(version: 3, turns: [prefix, suffix], nextSequenceIndex: 100)
        original.compactionFrontier = AgentTranscriptCompactionFrontier(frozenPrefixTurnCount: 1, lastFrozenTurnID: prefix.id)
        let before = AgentTranscriptProjectionBuilder.buildWithCaches(from: original, turnCaches: [:])
        var changed = original
        changed.turns[1].startedAt = changed.turns[1].startedAt.addingTimeInterval(300)
        let reused = try XCTUnwrap(AgentTranscriptProjectionBuilder.buildReusingFrozenPrefix(from: changed, previousTranscript: original, previousProjection: before.projection, previousProtection: .none, reusableFrozenPrefixTurnCount: 1, turnCaches: before.updatedTurnCaches))
        let fresh = AgentTranscriptProjectionBuilder.buildWithCaches(from: changed, turnCaches: [:])
        XCTAssertEqual(reused.projection, fresh.projection)
        XCTAssertEqual(reused.projection.workingBlocks.flatMap(\.rows).first { $0.text == "synthetic" }?.timestamp, changed.turns[1].startedAt)
    }

    func testInterleavedExactTiePreservesConclusionBeforeTool() throws {
        var (transcript, ids) = fixture(interrupted: false)
        let original = transcript.turns[0].responseSpans[0]
        var conclusion = try XCTUnwrap(original.activities.first { $0.id == ids[0] })
        var tools = original.activities.filter { $0.itemKind == .toolCall || $0.itemKind == .toolResult }
        conclusion.sequenceIndex = 1
        tools[0].sequenceIndex = 1
        tools[0].timestamp = conclusion.timestamp
        tools[1].sequenceIndex = 2
        var first = original
        first.activities = [conclusion, tools[0], tools[1]]
        var second = AgentTranscriptProviderResponseSpan(startedAt: original.startedAt)
        second.lifecycle = .completed
        second.activities = Array(tools[2 ..< 4])
        for i in second.activities.indices {
            second.activities[i].sequenceIndex = i + 10
        }
        transcript.turns[0].responseSpans = [first, second]
        transcript.turns[0].conclusionActivityID = conclusion.id
        let blocks = AgentTranscriptProjectionBuilder.buildWithCaches(from: transcript, turnCaches: [:], replyPresentation: true).projection.workingBlocks
        let conclusionIndex = try XCTUnwrap(blocks.firstIndex { $0.activityIDs.contains(conclusion.id) })
        let toolIndex = try XCTUnwrap(blocks.firstIndex { $0.activityIDs.contains(tools[0].id) })
        XCTAssertLessThan(conclusionIndex, toolIndex)
    }

    func testInterleavedConclusionSplitsToolExecution() throws {
        var (transcript, ids) = fixture(interrupted: true)
        let original = transcript.turns[0].responseSpans[0]
        var a = try XCTUnwrap(original.activities.first { $0.id == ids[0] })
        var conclusion = try XCTUnwrap(original.activities.first { $0.id == ids[1] })
        var tools = Array(original.activities.filter { $0.itemKind == .toolCall || $0.itemKind == .toolResult }.prefix(2))
        a.sequenceIndex = 1
        tools[0].sequenceIndex = 2
        conclusion.sequenceIndex = 3
        tools[1].sequenceIndex = 4
        var first = original
        first.activities = [a, conclusion]
        var second = AgentTranscriptProviderResponseSpan(startedAt: original.startedAt)
        second.lifecycle = .completed
        second.activities = tools
        transcript.turns[0].responseSpans = [first, second]
        transcript.turns[0].conclusionActivityID = conclusion.id
        let blocks = AgentTranscriptProjectionBuilder.buildWithCaches(from: transcript, turnCaches: [:], replyPresentation: true).projection.workingBlocks
        let ordered = blocks.flatMap(\.activityIDs).filter { Set([a.id, conclusion.id, tools[0].id, tools[1].id]).contains($0) }
        XCTAssertEqual(ordered, [a.id, tools[0].id, conclusion.id, tools[1].id])
    }

    func testProbeRejectsIncompleteQuietBaselineLikeRenderer() throws {
        var (transcript, _) = fixture(interrupted: false)
        let original = transcript.turns[0].responseSpans[0]
        var tools = Array(original.activities.filter { $0.itemKind == .toolCall || $0.itemKind == .toolResult }.prefix(16))
        var quiet = try XCTUnwrap(original.activities.first { $0.itemKind == .assistant })
        quiet.quietCheckInWakeID = UUID()
        quiet.sequenceIndex = 2
        for i in tools.indices {
            tools[i].sequenceIndex = i == 0 ? 1 : i + 2
        }
        transcript.turns[0].responseSpans[0].activities = [tools[0], quiet] + Array(tools.dropFirst())
        transcript.turns[0].conclusionActivityID = nil
        transcript.turns[0].quietLocal = AgentTranscriptQuietLocalTurn(summary: nil, conclusionActivityID: nil, completedAt: nil)
        let projection = AgentTranscriptProjectionBuilder.buildWithCaches(from: transcript, turnCaches: [:], excludingQuiet: true, replyPresentation: true).projection
        XCTAssertTrue(projection.workingBlocks.contains { $0.kind == .groupedHistory })
        XCTAssertTrue(AgentTranscriptProjectionBuilder.groupedHistoryWouldCollapse(in: transcript.turns[0], detailedToolTailLimit: 8, excludingQuiet: true, replyPresentation: true))
    }

    func testMultiSpanGrowthRemainsBounded() {
        func make(_ count: Int) -> AgentTranscript {
            var items: [AgentChatItem] = [.user("question", sequenceIndex: 0)]
            for i in 0 ..< count {
                let id = UUID()
                items.append(.toolCall(name: "Bash", invocationID: id, argsJSON: "{}", sequenceIndex: i * 2 + 2))
                items.append(.toolResult(name: "Bash", invocationID: id, resultJSON: "{}", isError: false, sequenceIndex: i * 2 + 3))
            }
            let answer = AgentChatItem.assistant("reply", sequenceIndex: 1)
            items.append(answer)
            var transcript = AgentTranscriptIO.importLegacyItems(items)
            var span = transcript.turns[0].responseSpans[0]
            let reply = span.activities.first { $0.id == answer.id }!
            span.activities.removeAll { $0.id == answer.id }
            var second = AgentTranscriptProviderResponseSpan(startedAt: span.startedAt)
            second.activities = [reply]
            transcript.turns[0].responseSpans = [span, second]
            transcript.turns[0].conclusionActivityID = nil
            return transcript
        }
        func elapsed(_ transcript: AgentTranscript) -> TimeInterval {
            let start = Date.timeIntervalSinceReferenceDate
            _ = AgentTranscriptProjectionBuilder.buildWithCaches(from: transcript, turnCaches: [:], replyPresentation: true)
            return Date.timeIntervalSinceReferenceDate - start
        }
        let small = make(150), large = make(300)
        _ = elapsed(small)
        _ = elapsed(large)
        let t1 = elapsed(small), t2 = elapsed(large)
        print("MULTISPAN_GROWTH_SECONDS=\(t1),\(t2)")
        XCTAssertLessThan(t2, t1 * 4 + 0.1)
    }

    func testRequestlessBufferedAssistantSurvivesCrossSpanConclusionSplit() throws {
        var (transcript, ids) = fixture(interrupted: false)
        let original = transcript.turns[0].responseSpans[0]
        var leading = try XCTUnwrap(original.activities.first { $0.id == ids[0] })
        leading.sequenceIndex = 1
        var tools = original.activities.filter { $0.itemKind == .toolCall || $0.itemKind == .toolResult }
        for i in tools.indices {
            tools[i].sequenceIndex = i < 2 ? i + 2 : i < 4 ? i + 3 : i + 7
        }
        var first = original
        first.activities = [leading] + tools
        let item = AgentChatItem.assistant("conclusion", sequenceIndex: 4)
        var extra = AgentTranscriptIO.importLegacyItems([.user("q", sequenceIndex: 0), item]).turns[0].responseSpans[0]
        extra.lifecycle = .completed
        transcript.turns[0].request = nil
        transcript.turns[0].responseSpans = [first, extra]
        transcript.turns[0].conclusionActivityID = item.id
        let projection = AgentTranscriptProjectionBuilder.buildWithCaches(from: transcript, turnCaches: [:], replyPresentation: true).projection
        XCTAssertTrue(projection.workingBlocks.contains { $0.kind == .standaloneAssistant && $0.activityIDs.contains(leading.id) })
        let groups = projection.workingBlocks.filter { $0.kind == .groupedHistory }
        XCTAssertEqual(groups.count, 2)
        XCTAssertFalse(groups.contains { $0.activityIDs.contains(leading.id) })
        XCTAssertTrue(groups[0].activityIDs.contains(tools[0].id))
        XCTAssertTrue(groups[1].activityIDs.contains(tools[2].id))
        let count = projection.workingBlocks.reduce(0) { $0 + (($1.kind == .groupedHistory || $1.kind == .activityCluster) ? 1 : $1.rows.count) }
        XCTAssertEqual(AgentTranscriptProjectionBuilder.fullTurnVisibleRowCount(for: transcript.turns[0], detailedToolTailLimit: 8, replyPresentation: true), count)
    }

    func testMovingConclusionInDetailedTailPreservesHistorySummary() throws {
        var (transcript, _) = fixture(interrupted: false)
        transcript.turns[0].request = nil
        for i in transcript.turns[0].responseSpans[0].activities.indices {
            transcript.turns[0].responseSpans[0].activities[i].sequenceIndex *= 2
        }
        let item = AgentChatItem.assistant("conclusion", sequenceIndex: 100)
        let conclusion = AgentTranscriptIO.importLegacyItems([.user("q", sequenceIndex: 0), item]).turns[0].responseSpans[0].activities[0]
        transcript.turns[0].responseSpans[0].activities.append(conclusion)
        transcript.turns[0].conclusionActivityID = item.id
        let before = AgentTranscriptProjectionBuilder.buildWithCaches(from: transcript, turnCaches: [:], replyPresentation: true).projection
        let original = try XCTUnwrap(before.workingBlocks.first { $0.kind == .groupedHistory })
        let index = try XCTUnwrap(transcript.turns[0].responseSpans[0].activities.firstIndex { $0.id == item.id })
        transcript.turns[0].responseSpans[0].activities[index].sequenceIndex = 39
        let after = AgentTranscriptProjectionBuilder.buildWithCaches(from: transcript, turnCaches: [:], replyPresentation: true).projection
        let moved = try XCTUnwrap(after.workingBlocks.first { $0.kind == .groupedHistory })
        XCTAssertEqual(original.groupedHistory?.summary, moved.groupedHistory?.summary)
        XCTAssertEqual(original.displaySummaryInputs, moved.displaySummaryInputs)
        let conclusionIndex = try XCTUnwrap(after.workingBlocks.firstIndex { $0.activityIDs.contains(item.id) })
        XCTAssertTrue(after.workingBlocks.dropFirst(conclusionIndex + 1).contains { $0.kind == .standaloneTool })
    }

    func testRequestlessBufferedAssistantSplitsOtherSpanTool() throws {
        var (transcript, ids) = fixture(interrupted: false)
        let original = transcript.turns[0].responseSpans[0]
        var assistant = try XCTUnwrap(original.activities.first { $0.id == ids[0] })
        assistant.sequenceIndex = 2
        var tools = original.activities.filter { $0.itemKind == .toolCall || $0.itemKind == .toolResult }
        for i in tools.indices {
            tools[i].sequenceIndex = i < 2 ? i + 4 : i < 4 ? i + 5 : i + 9
        }
        var first = original
        first.activities = [assistant] + tools
        let invocation = UUID()
        let call = AgentChatItem.toolCall(name: "Bash", invocationID: invocation, argsJSON: "{}", sequenceIndex: 1)
        let result = AgentChatItem.toolResult(name: "Bash", invocationID: invocation, resultJSON: "{}", isError: false, sequenceIndex: 3)
        let conclusion = AgentChatItem.assistant("conclusion", sequenceIndex: 6)
        var second = AgentTranscriptIO.importLegacyItems([.user("q", sequenceIndex: 0), call, result, conclusion]).turns[0].responseSpans[0]
        second.lifecycle = .completed
        transcript.turns[0].request = nil
        transcript.turns[0].responseSpans = [first, second]
        transcript.turns[0].conclusionActivityID = conclusion.id
        let blocks = AgentTranscriptProjectionBuilder.buildWithCaches(from: transcript, turnCaches: [:], replyPresentation: true).projection.workingBlocks
        let targetIDs = Set([call.id, assistant.id, result.id])
        XCTAssertEqual(blocks.flatMap(\.activityIDs).filter { targetIDs.contains($0) }, [call.id, assistant.id, result.id])
    }

    func testRequestlessBufferedAssistantAfterLeadingConclusionIsBoundary() throws {
        var (transcript, ids) = fixture(interrupted: false)
        let original = transcript.turns[0].responseSpans[0]
        var assistant = try XCTUnwrap(original.activities.first { $0.id == ids[0] })
        assistant.sequenceIndex = 3
        var tools = original.activities.filter { $0.itemKind == .toolCall || $0.itemKind == .toolResult }
        for i in tools.indices {
            tools[i].sequenceIndex = i + 5
        }
        let conclusion = AgentChatItem.assistant("conclusion", sequenceIndex: 1)
        let conclusionActivity = AgentTranscriptIO.importLegacyItems([.user("q", sequenceIndex: 0), conclusion]).turns[0].responseSpans[0].activities[0]
        var first = original
        first.activities = [conclusionActivity, assistant] + tools
        let invocation = UUID()
        let call = AgentChatItem.toolCall(name: "Bash", invocationID: invocation, argsJSON: "{}", sequenceIndex: 2)
        let result = AgentChatItem.toolResult(name: "Bash", invocationID: invocation, resultJSON: "{}", isError: false, sequenceIndex: 4)
        let second = AgentTranscriptIO.importLegacyItems([.user("q", sequenceIndex: 0), call, result]).turns[0].responseSpans[0]
        transcript.turns[0].request = nil
        transcript.turns[0].responseSpans = [first, second]
        transcript.turns[0].conclusionActivityID = conclusion.id
        let target = Set([conclusion.id, call.id, assistant.id, result.id])
        for count in [8, 9, 10] {
            transcript.turns[0].responseSpans[0].activities = [conclusionActivity, assistant] + Array(tools.prefix(count * 2))
            let blocks = AgentTranscriptProjectionBuilder.buildWithCaches(from: transcript, turnCaches: [:], replyPresentation: true).projection.workingBlocks
            XCTAssertEqual(blocks.flatMap(\.activityIDs).filter { target.contains($0) }, [conclusion.id, call.id, assistant.id, result.id], "tools=\(count)")
        }
    }

    func testUnrelatedSpanPreservesBufferedHistorySummary() throws {
        var (transcript, _) = fixture(interrupted: false)
        transcript.turns[0].request = nil
        let conclusion = AgentChatItem.assistant("conclusion", sequenceIndex: 100)
        let activity = AgentTranscriptIO.importLegacyItems([.user("q", sequenceIndex: 0), conclusion]).turns[0].responseSpans[0].activities[0]
        transcript.turns[0].responseSpans[0].activities.append(activity)
        transcript.turns[0].conclusionActivityID = conclusion.id
        let before = AgentTranscriptProjectionBuilder.buildWithCaches(from: transcript, turnCaches: [:], replyPresentation: true).projection
        let original = try XCTUnwrap(before.workingBlocks.first { $0.kind == .groupedHistory })
        let note = AgentChatItem.system("later note", sequenceIndex: 101)
        let second = AgentTranscriptIO.importLegacyItems([.user("q", sequenceIndex: 0), note]).turns[0].responseSpans[0]
        transcript.turns[0].responseSpans.append(second)
        let after = AgentTranscriptProjectionBuilder.buildWithCaches(from: transcript, turnCaches: [:], replyPresentation: true).projection
        let moved = try XCTUnwrap(after.workingBlocks.first { $0.kind == .groupedHistory })
        XCTAssertEqual(original.activityIDs, moved.activityIDs)
        XCTAssertEqual(original.groupedHistory?.summary, moved.groupedHistory?.summary)
        XCTAssertEqual(original.displaySummaryInputs, moved.displaySummaryInputs)
    }

    func testConclusionSpanOwnershipDoesNotChangeBufferedSummary() throws {
        var (transcript, _) = fixture(interrupted: false)
        transcript.turns[0].request = nil
        for i in transcript.turns[0].responseSpans[0].activities.indices {
            if transcript.turns[0].responseSpans[0].activities[i].itemKind != .assistant { transcript.turns[0].responseSpans[0].activities[i].sequenceIndex += 1 }
        }
        let conclusion = AgentChatItem.assistant("conclusion", sequenceIndex: 2)
        let activity = AgentTranscriptIO.importLegacyItems([.user("q", sequenceIndex: 0), conclusion]).turns[0].responseSpans[0].activities[0]
        let note = AgentChatItem.system("later note", sequenceIndex: 100)
        var second = AgentTranscriptIO.importLegacyItems([.user("q", sequenceIndex: 0), note]).turns[0].responseSpans[0]
        second.activities.insert(activity, at: 0)
        transcript.turns[0].responseSpans.append(second)
        transcript.turns[0].conclusionActivityID = conclusion.id
        let before = AgentTranscriptProjectionBuilder.buildWithCaches(from: transcript, turnCaches: [:], replyPresentation: true).projection
        let original = try XCTUnwrap(before.workingBlocks.first { $0.kind == .groupedHistory })
        transcript.turns[0].responseSpans[1].activities.removeAll { $0.id == conclusion.id }
        transcript.turns[0].responseSpans[0].activities.append(activity)
        let after = AgentTranscriptProjectionBuilder.buildWithCaches(from: transcript, turnCaches: [:], replyPresentation: true).projection
        let moved = try XCTUnwrap(after.workingBlocks.first { $0.kind == .groupedHistory })
        XCTAssertEqual(original.activityIDs, moved.activityIDs)
        XCTAssertEqual(original.groupedHistory?.summary, moved.groupedHistory?.summary)
        XCTAssertEqual(original.displaySummaryInputs, moved.displaySummaryInputs)
    }

    func testSuppressedToolEndsReplyInSingleAndInterleavedSpans() throws {
        for multiple in [false, true] {
            var (transcript, ids) = fixture(interrupted: true)
            let original = transcript.turns[0].responseSpans[0]
            var answer = try XCTUnwrap(original.activities.first { $0.id == ids[0] })
            var narration = try XCTUnwrap(original.activities.first { $0.id == ids[1] })
            answer.sequenceIndex = 1
            narration.sequenceIndex = 3
            let item = AgentChatItem.toolCall(name: "tool", invocationID: UUID(), argsJSON: "{}", sequenceIndex: 2)
            let execution = AgentTranscriptToolExecution(stableExecutionID: "placeholder", toolName: "tool", invocationID: item.toolInvocationID, argsJSON: "{}", resultJSON: nil, toolIsError: nil, status: .unknown)
            var suppressed = AgentTranscriptActivity(from: item, toolExecution: execution)
            suppressed.text = ""
            XCTAssertTrue(AgentTranscriptToolVisibilityPolicy.shouldSuppressActivity(suppressed))
            var tools = original.activities.filter { $0.itemKind == .toolCall || $0.itemKind == .toolResult }
            for i in tools.indices {
                tools[i].sequenceIndex = i + 4
            }
            var first = original
            if multiple {
                first.activities = [answer, suppressed]
                var second = AgentTranscriptProviderResponseSpan(startedAt: original.startedAt)
                second.activities = [narration] + tools
                transcript.turns[0].responseSpans = [first, second]
            } else {
                first.activities = [answer, suppressed, narration] + tools
                transcript.turns[0].responseSpans = [first]
            }
            transcript.turns[0].conclusionActivityID = nil
            let blocks = AgentTranscriptProjectionBuilder.buildWithCaches(from: transcript, turnCaches: [:], replyPresentation: true).projection.workingBlocks
            XCTAssertTrue(blocks.contains { $0.kind == .standaloneAssistant && $0.activityIDs.contains(answer.id) })
            XCTAssertFalse(blocks.contains { $0.kind == .standaloneAssistant && $0.activityIDs.contains(narration.id) })
            XCTAssertTrue(blocks.contains { $0.kind == .groupedHistory && $0.activityIDs.contains(narration.id) })
        }
    }

    func testDetailedNarrationSeparatesInterleavedToolRows() throws {
        var (transcript, ids) = fixture(interrupted: true)
        let original = transcript.turns[0].responseSpans[0]
        var answer = try XCTUnwrap(original.activities.first { $0.id == ids[0] })
        var narration = try XCTUnwrap(original.activities.first { $0.id == ids[1] })
        var tools = Array(original.activities.filter { $0.itemKind == .toolCall || $0.itemKind == .toolResult }.prefix(2))
        answer.sequenceIndex = 1
        tools[0].sequenceIndex = 2
        narration.sequenceIndex = 3
        tools[1].sequenceIndex = 4
        var first = original
        first.activities = [answer] + tools
        var second = AgentTranscriptProviderResponseSpan(startedAt: original.startedAt)
        second.activities = [narration]
        transcript.turns[0].responseSpans = [first, second]
        transcript.turns[0].conclusionActivityID = nil
        let blocks = AgentTranscriptProjectionBuilder.buildWithCaches(from: transcript, turnCaches: [:], replyPresentation: true).projection.workingBlocks
        let target = Set([answer.id, tools[0].id, narration.id, tools[1].id])
        XCTAssertEqual(blocks.flatMap(\.activityIDs).filter { target.contains($0) }, [answer.id, tools[0].id, narration.id, tools[1].id])
    }

    func testRetainedReplyRemainsVisibleAcrossCompactedTiers() throws {
        for tier in [AgentTranscriptRetentionTier.condensed, .summary, .archived] {
            var (transcript, ids) = fixture(interrupted: false)
            let span = transcript.turns[0].responseSpans[0]
            var answer = try XCTUnwrap(span.activities.first { $0.id == ids[0] })
            var tools = span.activities.filter { $0.itemKind == .toolCall || $0.itemKind == .toolResult }
            answer.sequenceIndex = 3
            for i in tools.indices {
                tools[i].sequenceIndex = i < 2 ? i + 1 : i + 2
            }
            transcript.turns[0].responseSpans[0].activities = Array(tools.prefix(2)) + [answer] + Array(tools.dropFirst(2))
            transcript.turns[0].retentionTier = tier
            transcript.turns[0].conclusionActivityID = nil
            let before = AgentTranscriptProjectionBuilder.build(from: transcript)
            let presentation = AgentTranscriptProjectionBuilder.buildWithCaches(from: transcript, turnCaches: [:], replyPresentation: true).projection
            let blocks = tier == .archived ? presentation.archivedBlocks : presentation.workingBlocks
            let answerBlock = try XCTUnwrap(blocks.first { $0.kind == .standaloneAssistant && $0.activityIDs.contains(answer.id) }, "tier=\(tier)")
            let groups = blocks.filter { $0.kind == .groupedHistory }
            if tier != .archived {
                XCTAssertEqual(groups.count, 2, "tier=\(tier)")
                XCTAssertEqual(Set(groups.map(\.id)).count, 2)
            }
            let anchor = try XCTUnwrap(presentation.rowAnchorIndex[answer.id])
            XCTAssertEqual(presentation.anchorBlockIndex[anchor], answerBlock.id)
            XCTAssertEqual(AgentTranscriptProjectionBuilder.build(from: transcript), before)
        }
    }

    func testCompactedRepliesPreserveRetainedSummariesAndAnchors() throws {
        for tier in [AgentTranscriptRetentionTier.condensed, .summary, .archived] {
            for hasReply in [false, true] {
                var (transcript, ids) = fixture(interrupted: true)
                let span = transcript.turns[0].responseSpans[0]
                let reply = try XCTUnwrap(span.activities.first { $0.id == ids[0] })
                let conclusion = try XCTUnwrap(span.activities.first { $0.id == ids[1] })
                transcript.turns[0].retentionTier = tier
                transcript.turns[0].conclusionActivityID = conclusion.id
                transcript.turns[0].responseSpans[0].activities = hasReply ? [reply, conclusion] : [conclusion]
                transcript.turns[0].summary = AgentTranscriptTurnSummary(requestText: nil, conclusionText: "done", compactConclusionText: nil, middleSummaryText: "prior work", toolCount: 4, notableToolNames: ["bash"], keyPaths: [], compactedActivityCount: 4, hadWarning: false, hadError: false)
                let frozen = AgentTranscriptGroupedHistorySummary(hiddenToolCardCount: 4, hiddenAssistantCount: 0, hiddenProgressCount: 0, hiddenNoteCount: 0, toolSummary: nil)
                transcript.turns[0].responseSpans[0].collapsedSummary = frozen
                let first = AgentTranscriptProjectionBuilder.buildWithCaches(from: transcript, turnCaches: [:], replyPresentation: true)
                let warm = AgentTranscriptProjectionBuilder.buildWithCaches(from: transcript, turnCaches: first.updatedTurnCaches, replyPresentation: true)
                XCTAssertEqual(first.projection, warm.projection)
                let blocks = tier == .archived ? first.projection.archivedBlocks : first.projection.workingBlocks
                if hasReply { XCTAssertTrue(blocks.contains { $0.kind == .standaloneAssistant && $0.activityIDs.contains(reply.id) }, "tier=\(tier)") }
                if tier == .archived {
                    let summary = try XCTUnwrap(blocks.first { $0.kind == .middleSummary })
                    XCTAssertEqual(first.projection.anchorBlockIndex[.summary(turnID: transcript.turns[0].id)], summary.id)
                } else {
                    let group = try XCTUnwrap(blocks.first { $0.kind == .groupedHistory })
                    XCTAssertEqual(group.groupedHistory?.summary.hiddenToolCardCount, 4)
                    XCTAssertEqual(first.projection.anchorBlockIndex[.groupedHistory(turnID: transcript.turns[0].id, spanID: span.id)], group.id)
                    for projection in [first.projection, warm.projection] {
                        let ordered = projection.workingBlocks
                        let groupIndex = try XCTUnwrap(ordered.firstIndex { $0.id == group.id })
                        let conclusionIndex = try XCTUnwrap(ordered.firstIndex { $0.kind == .conclusion })
                        XCTAssertLessThan(groupIndex, conclusionIndex)
                        if hasReply {
                            let replyIndex = try XCTUnwrap(ordered.firstIndex { $0.kind == .standaloneAssistant && $0.activityIDs.contains(reply.id) })
                            XCTAssertLessThan(replyIndex, groupIndex)
                        }
                    }
                }
            }
        }
    }
}
