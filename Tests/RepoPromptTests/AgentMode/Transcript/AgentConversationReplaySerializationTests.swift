import Foundation
@testable import RepoPromptApp
import RepoPromptInstrumentation
import XCTest

final class AgentConversationReplaySerializationTests: XCTestCase {
    private final class ReplayPerfRecorder: AgentModePerfRecording, @unchecked Sendable {
        private let lock = NSLock()
        private let fallback = NoopAgentModePerfRecorder()
        private var replayEvent: AgentPerfConversationReplayEvent?
        private var selectedEvent: (String, [String: String])?

        var isEnabled: Bool {
            true
        }

        func timestampMSIfEnabled() -> Double? {
            1
        }

        func timestampMS() -> Double {
            fallback.timestampMS()
        }

        func elapsedMS(since startMS: Double) -> Double {
            fallback.elapsedMS(since: startMS)
        }

        func formatMS(_ value: Double) -> String {
            fallback.formatMS(value)
        }

        func formatElapsedMS(since startMS: Double) -> String {
            fallback.formatElapsedMS(since: startMS)
        }

        func shortID(_ id: UUID?) -> String {
            fallback.shortID(id)
        }

        func counterKey(_ base: String, source: String?) -> String {
            fallback.counterKey(base, source: source)
        }

        func increment(_: String, tabID _: UUID?, by _: Int) {}
        func event(_ name: String, tabID _: UUID?, fields: [String: String]) {
            lock.lock()
            selectedEvent = (name, fields)
            lock.unlock()
        }

        func durationEvent(_: String, startMS _: Double?, tabID _: UUID?, fields _: [String: String]) {}
        func recordStoreUpdate(_: String, published _: Bool, details _: [String: String]) {}
        func recordConversationReplay(_ event: AgentPerfConversationReplayEvent, startMS _: Double?) {
            lock.lock()
            replayEvent = event
            lock.unlock()
        }

        func beginSidebarDelete(_: AgentPerfSidebarDeleteBeginContext) -> UUID {
            UUID()
        }

        func markSidebarDeleteVisibleRemoved(tabID _: UUID, source _: String, fields _: [String: String]) {}
        func markSidebarDeleteAgentCleanupComplete(tabID _: UUID, source _: String, fields _: [String: String]) {}
        func markSidebarDeleteFullCleanupComplete(tabID _: UUID, source _: String, fields _: [String: String]) {}
        func cancelSidebarDeleteTracking(tabID _: UUID, source _: String, fields _: [String: String]) {}
        func recordSessionSnapshot(tabID _: UUID, fields _: [String: AgentPerfSnapshotValue]) {}
        func recordCodexLifecyclePhase(
            _: AgentPerfCodexLifecyclePhase,
            outcome _: AgentPerfCodexLifecycleOutcome,
            startMS _: Double?,
            tabID _: UUID,
            transportGeneration _: UInt64?
        ) {}

        func snapshot() -> (AgentPerfConversationReplayEvent?, (String, [String: String])?) {
            lock.lock()
            defer { lock.unlock() }
            return (replayEvent, selectedEvent)
        }
    }

    func testEquivalentModeMatchesLegacyBytesAndCategoryMetrics() throws {
        let invocationID = try XCTUnwrap(UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"))
        let items: [AgentChatItem] = [
            .user("  hello 🌍\nnext  ", sequenceIndex: 0),
            .assistant("\n  working  \n", sequenceIndex: 1),
            .toolCall(
                name: "read_file",
                invocationID: invocationID,
                argsJSON: #"{"path":"Sources/Ünicode.swift"}"#,
                sequenceIndex: 2
            ),
            .toolResult(
                name: "read_file",
                invocationID: invocationID,
                resultJSON: #"{"content":"ignored by replay"}"#,
                isError: false,
                sequenceIndex: 3
            ),
            .system(" system context ", sequenceIndex: 4),
            .error(" error context ", sequenceIndex: 5),
            .thinking("hidden reasoning", sequenceIndex: 6),
            .assistant("\nfinal answer\n", sequenceIndex: 7)
        ]
        let transcript = AgentTranscriptIO.importLegacyItems(items)

        let serialization = AgentTranscriptIO.serializeConversationHistory(from: transcript)
        let expected = [
            "<user>  hello 🌍\nnext  </user>",
            "<assistant>working</assistant>",
            #"<tool_call name="read_file">{"path":"Sources/Ünicode.swift"}</tool_call>"#,
            #"<tool_result name="read_file"/>"#,
            "<system> system context </system>",
            "<error> error context </error>",
            "<assistant>final answer</assistant>"
        ].joined(separator: "\n")

        XCTAssertEqual(serialization.text, expected)
        XCTAssertEqual(Array(serialization.text.utf8), Array(expected.utf8))
        XCTAssertEqual(AgentTranscriptIO.buildConversationHistory(from: transcript), expected)
        let recorder = ReplayPerfRecorder()
        XCTAssertEqual(AgentTranscriptIO.buildConversationHistory(from: transcript, perfRecorder: recorder), expected)
        let replay = try XCTUnwrap(recorder.snapshot().0)
        XCTAssertEqual(replay.mode, "equivalent")
        XCTAssertEqual(replay.fields["toolResult.emitted"], "1")
        XCTAssertEqual(replay.fields["truncatedToolCallCount"], "0")
        XCTAssertFalse(replay.fields.values.contains { $0.contains("ignored by replay") || $0.contains("Sources/Ünicode.swift") })
        AgentSelectedFilesDiagnostics(perfRecorder: recorder).event("test.aggregate", fields: ["count": "1"])
        let selected = try XCTUnwrap(recorder.snapshot().1)
        XCTAssertEqual(selected.0, "selectedFiles.test.aggregate")
        XCTAssertEqual(selected.1, ["count": "1"])
        XCTAssertEqual(serialization.metrics.mode, .equivalent)
        XCTAssertEqual(serialization.metrics.outputUTF8Bytes, expected.utf8.count)
        XCTAssertEqual(serialization.metrics.unboundedOutputUTF8Bytes, expected.utf8.count)
        XCTAssertEqual(serialization.metrics.userAuthoredUTF8Bytes, "  hello 🌍\nnext  ".utf8.count)
        XCTAssertEqual(serialization.metrics.categories[.user]?.examinedCount, 1)
        XCTAssertEqual(serialization.metrics.categories[.user]?.emittedCount, 1)
        XCTAssertEqual(serialization.metrics.categories[.assistant]?.emittedCount, 2)
        XCTAssertEqual(serialization.metrics.categories[.toolCall]?.emittedCount, 1)
        XCTAssertEqual(serialization.metrics.categories[.toolResult]?.emittedCount, 1)
        XCTAssertEqual(serialization.metrics.categories[.system]?.emittedCount, 1)
        XCTAssertEqual(serialization.metrics.categories[.error]?.emittedCount, 1)
        XCTAssertEqual(serialization.metrics.omittedRowCount, 0)
        XCTAssertEqual(serialization.metrics.truncatedToolCallCount, 0)
    }

    func testEquivalentModeHandlesEmptyAndSelfClosingToolCallBytes() {
        let empty = AgentTranscriptIO.serializeConversationHistory(
            from: AgentTranscriptIO.importLegacyItems([])
        )
        XCTAssertEqual(empty.text, "")
        XCTAssertEqual(empty.metrics.outputUTF8Bytes, 0)

        let transcript = AgentTranscriptIO.importLegacyItems([
            .user("inspect", sequenceIndex: 0),
            .toolCall(name: "read_file", argsJSON: nil, sequenceIndex: 1),
            .assistant("done", sequenceIndex: 2)
        ])
        let expected = "<user>inspect</user>\n<tool_call name=\"read_file\"/>\n<assistant>done</assistant>"

        let serialization = AgentTranscriptIO.serializeConversationHistory(from: transcript)

        XCTAssertEqual(Array(serialization.text.utf8), Array(expected.utf8))
        XCTAssertEqual(serialization.metrics.outputUTF8Bytes, expected.utf8.count)
    }

    func testEquivalentModePreservesCustomRenderedUserTextExactly() {
        let transcript = AgentTranscriptIO.importLegacyItems([
            .user("original", sequenceIndex: 0),
            .assistant("done", sequenceIndex: 1)
        ])
        let renderedUserText = "  rendered attachment block\n\n@file.swift  "

        let serialization = AgentTranscriptIO.serializeConversationHistory(
            from: transcript,
            renderUserMessage: { _ in renderedUserText }
        )

        XCTAssertEqual(
            serialization.text,
            "<user>\(renderedUserText)</user>\n<assistant>done</assistant>"
        )
        XCTAssertEqual(serialization.metrics.userAuthoredUTF8Bytes, renderedUserText.utf8.count)
    }

    func testEquivalentModeRetainsCompactedPrefixAuthority() {
        var items: [AgentChatItem] = []
        for turn in 0 ..< 30 {
            let base = turn * 3
            items.append(.user("user \(turn)", sequenceIndex: base))
            items.append(.assistant("progress \(turn)", sequenceIndex: base + 1))
            items.append(.assistant("final \(turn)", sequenceIndex: base + 2))
        }
        let compacted = AgentTranscriptCompactor.compact(
            AgentTranscriptIO.importLegacyItems(items)
        )

        let serialization = AgentTranscriptIO.serializeConversationHistory(from: compacted)

        XCTAssertTrue(serialization.text.contains("<user>user 0</user>"))
        XCTAssertTrue(serialization.text.contains("final 0"))
        XCTAssertTrue(serialization.text.contains("<user>user 29</user>"))
        XCTAssertTrue(serialization.text.contains("<assistant>final 29</assistant>"))
        XCTAssertEqual(serialization.metrics.turnCount, compacted.turns.count)
    }

    func testBoundedModeTruncatesToolArgumentsOnCharacterBoundaryWithMarker() {
        let args = "😀éabc"
        let transcript = AgentTranscriptIO.importLegacyItems([
            .user("keep user", sequenceIndex: 0),
            .toolCall(name: "read_file", argsJSON: args, sequenceIndex: 1),
            .assistant("done", sequenceIndex: 2)
        ])

        let serialization = AgentTranscriptIO.serializeConversationHistory(
            from: transcript,
            policy: .bounded(AgentConversationReplayBudget(
                maxOutputUTF8Bytes: 10000,
                maxToolArgumentCharacters: 2
            ))
        )

        XCTAssertTrue(serialization.text.contains("<user>keep user</user>"))
        XCTAssertTrue(serialization.text.contains("😀é[replay_tool_arguments_truncated omitted_characters=3]"))
        XCTAssertFalse(serialization.text.contains("😀éabc</tool_call>"))
        XCTAssertEqual(serialization.metrics.originalToolArgumentCharacters, 5)
        XCTAssertEqual(serialization.metrics.emittedToolArgumentCharacters, 2)
        XCTAssertEqual(serialization.metrics.truncatedToolCallCount, 1)
        XCTAssertEqual(serialization.metrics.omittedRowCount, 0)
        XCTAssertEqual(serialization.metrics.mode, .bounded)
    }

    func testBoundedModeDropsToolResultBeforeHigherPriorityRows() {
        let toolName = String(repeating: "long_tool_name_", count: 10)
        let userLine = "<user>keep-user</user>"
        let intermediateLine = "<assistant>intermediate</assistant>"
        let toolCallLine = "<tool_call name=\"\(toolName)\">{}</tool_call>"
        let conclusionLine = "<assistant>final</assistant>"
        let omissionLine = "<system>[replay_rows_omitted count=1]</system>"
        let targetOutput = [
            userLine,
            intermediateLine,
            toolCallLine,
            conclusionLine,
            omissionLine
        ].joined(separator: "\n")
        let transcript = AgentTranscriptIO.importLegacyItems([
            .user("keep-user", sequenceIndex: 0),
            .assistant("intermediate", sequenceIndex: 1),
            .toolCall(name: toolName, argsJSON: "{}", sequenceIndex: 2),
            .toolResult(name: toolName, resultJSON: "{}", sequenceIndex: 3),
            .assistant("final", sequenceIndex: 4)
        ])

        let serialization = AgentTranscriptIO.serializeConversationHistory(
            from: transcript,
            policy: .bounded(AgentConversationReplayBudget(
                maxOutputUTF8Bytes: targetOutput.utf8.count,
                maxToolArgumentCharacters: 100
            ))
        )

        XCTAssertEqual(serialization.text, targetOutput)
        XCTAssertFalse(serialization.text.contains("<tool_result"))
        XCTAssertTrue(serialization.text.contains(toolCallLine))
        XCTAssertTrue(serialization.text.contains(intermediateLine))
        XCTAssertTrue(serialization.text.contains(conclusionLine))
        XCTAssertEqual(serialization.metrics.omittedRowCount, 1)
        XCTAssertEqual(serialization.metrics.categories[.toolResult]?.omittedCount, 1)
        XCTAssertEqual(serialization.metrics.categories[.toolCall]?.omittedCount, 0)
        XCTAssertEqual(serialization.metrics.categories[.assistant]?.omittedCount, 0)
        XCTAssertLessThanOrEqual(serialization.metrics.outputUTF8Bytes, targetOutput.utf8.count)
    }

    func testBoundedModeDoesNotCountTruncationForAnOmittedToolCall() {
        let userLine = "<user>keep-user</user>"
        let omissionLine = "<system>[replay_rows_omitted count=1]</system>"
        let expected = [userLine, omissionLine].joined(separator: "\n")
        let transcript = AgentTranscriptIO.importLegacyItems([
            .user("keep-user", sequenceIndex: 0),
            .toolCall(
                name: "read_file",
                argsJSON: String(repeating: "argument", count: 50),
                sequenceIndex: 1
            )
        ])

        let serialization = AgentTranscriptIO.serializeConversationHistory(
            from: transcript,
            policy: .bounded(AgentConversationReplayBudget(
                maxOutputUTF8Bytes: expected.utf8.count,
                maxToolArgumentCharacters: 1
            ))
        )

        XCTAssertEqual(serialization.text, expected)
        XCTAssertEqual(serialization.metrics.categories[.toolCall]?.omittedCount, 1)
        XCTAssertEqual(serialization.metrics.truncatedToolCallCount, 0)
        XCTAssertEqual(serialization.metrics.emittedToolArgumentCharacters, 0)
    }

    func testBoundedModePreservesUserTextAndReportsEssentialOverflow() {
        let userText = "user-authored-" + String(repeating: "内容", count: 40)
        let userLine = "<user>\(userText)</user>"
        let transcript = AgentTranscriptIO.importLegacyItems([
            .user(userText, sequenceIndex: 0),
            .assistant("discardable conclusion", sequenceIndex: 1)
        ])
        let budget = max(1, userLine.utf8.count / 2)

        let serialization = AgentTranscriptIO.serializeConversationHistory(
            from: transcript,
            policy: .bounded(AgentConversationReplayBudget(
                maxOutputUTF8Bytes: budget,
                maxToolArgumentCharacters: 10
            ))
        )

        XCTAssertTrue(serialization.text.contains(userLine))
        XCTAssertFalse(serialization.text.contains("discardable conclusion"))
        XCTAssertTrue(serialization.text.contains("[replay_rows_omitted count=1]"))
        XCTAssertTrue(serialization.text.contains("[replay_budget_exceeded_by_user_text user_text_preserved=true]"))
        XCTAssertEqual(serialization.metrics.userAuthoredUTF8Bytes, userText.utf8.count)
        XCTAssertGreaterThan(serialization.metrics.essentialOverflowUTF8Bytes, 0)
        XCTAssertGreaterThan(serialization.metrics.finalOverBudgetUTF8Bytes, 0)
        XCTAssertEqual(serialization.metrics.categories[.user]?.omittedCount, 0)
        XCTAssertEqual(serialization.metrics.categories[.user]?.emittedCount, 1)
    }
}

/// `updatedTurnCaches(for:projection:...)` must produce the same per-turn slices as the
/// historical per-turn `filter` implementation: blocks and rows scoped to the turn in
/// projection order, anchor maps keyed by the anchor's owning turn, and the loop's
/// retention rules (incomplete turns evict, protected turns keep their existing cache,
/// foreign turns are dropped) unchanged.
final class AgentTranscriptTurnCacheGroupingTests: XCTestCase {
    // MARK: - Fixtures

    private func makeFullTurn(
        index: Int,
        id: UUID = UUID(),
        retentionTier: AgentTranscriptRetentionTier = .full
    ) -> AgentTranscriptTurn {
        let startedAt = Date(timeIntervalSince1970: TimeInterval(index * 10))
        let user = AgentChatItem.user("request \(index)", sequenceIndex: index * 3)
        let thinking = AgentChatItem.thinking("thinking \(index)", sequenceIndex: index * 3 + 1)
        let assistant = AgentChatItem.assistant("response \(index)", sequenceIndex: index * 3 + 2)
        return AgentTranscriptTurn(
            id: id,
            request: AgentTranscriptRequestAnchor(from: user),
            responseSpans: [
                AgentTranscriptProviderResponseSpan(
                    lifecycle: .completed,
                    startedAt: startedAt,
                    lastActivityAt: startedAt.addingTimeInterval(1),
                    completedAt: startedAt.addingTimeInterval(1),
                    activities: [
                        AgentTranscriptActivity(from: thinking),
                        AgentTranscriptActivity(from: assistant)
                    ]
                )
            ],
            retentionTier: retentionTier,
            terminalState: .completed,
            startedAt: startedAt,
            lastActivityAt: startedAt.addingTimeInterval(1),
            completedAt: startedAt.addingTimeInterval(1)
        )
    }

    private func makeActiveTurn(index: Int) -> AgentTranscriptTurn {
        let startedAt = Date(timeIntervalSince1970: TimeInterval(index * 10))
        let user = AgentChatItem.user("active request \(index)", sequenceIndex: index * 3)
        let assistant = AgentChatItem.assistant("partial \(index)", sequenceIndex: index * 3 + 1)
        return AgentTranscriptTurn(
            id: UUID(),
            request: AgentTranscriptRequestAnchor(from: user),
            responseSpans: [
                AgentTranscriptProviderResponseSpan(
                    lifecycle: .open,
                    startedAt: startedAt,
                    lastActivityAt: startedAt,
                    activities: [AgentTranscriptActivity(from: assistant)]
                )
            ],
            retentionTier: .full,
            terminalState: .running,
            startedAt: startedAt,
            lastActivityAt: startedAt
        )
    }

    private func makeEmptyCompletedTurn(index: Int) -> AgentTranscriptTurn {
        let startedAt = Date(timeIntervalSince1970: TimeInterval(index * 10))
        return AgentTranscriptTurn(
            id: UUID(),
            request: nil,
            responseSpans: [],
            retentionTier: .full,
            terminalState: .completed,
            startedAt: startedAt,
            lastActivityAt: startedAt,
            completedAt: startedAt
        )
    }

    private func makeCache(turnID: UUID) -> AgentTranscriptTurnProjectionCache {
        AgentTranscriptTurnProjectionCache(
            token: .init(
                turnID: turnID,
                retentionTier: .full,
                isCompleted: true,
                responseSpanCount: 0,
                activityCount: 0,
                conclusionActivityID: nil,
                frozenDetailedToolTailLimit: nil
            ),
            workingBlocks: [],
            archivedBlocks: [],
            workingRows: [],
            archivedRows: [],
            rowAnchorIndex: [:],
            anchorBlockIndex: [:]
        )
    }

    private func anchorTurnID(_ anchor: AgentTranscriptAnchor) -> UUID {
        switch anchor {
        case let .request(turnID), let .summary(turnID), let .groupedHistory(turnID, _):
            turnID
        case let .activity(turnID, _, _), let .conclusion(turnID, _):
            turnID
        }
    }

    // MARK: - Per-turn slicing

    /// Same-process, interleaved benchmark: fixture construction and assertions stay
    /// outside timing. Five samples follow one warm-up of each implementation. The
    /// time budget is deliberately generous for debug/headless CI; exact equality is
    /// the correctness gate, not a load-sensitive relative timing assertion.
    func testLargeProjectionGroupingMatchesHistoricalSlicesWithinBudget() {
        let turnCount = 1000
        let transcript = AgentTranscript(
            turns: (0 ..< turnCount).map {
                makeFullTurn(index: $0, retentionTier: $0.isMultiple(of: 5) ? .archived : .full)
            },
            nextSequenceIndex: turnCount * 3
        )
        let projection = AgentTranscriptProjectionBuilder.build(from: transcript)
        XCTAssertFalse(projection.workingBlocks.isEmpty)
        XCTAssertFalse(projection.archivedBlocks.isEmpty)
        XCTAssertGreaterThanOrEqual(projection.rowAnchorIndex.count, turnCount)
        let reference = historicalTurnCaches(transcript, projection: projection)
        let warm = AgentTranscriptProjectionBuilder.updatedTurnCaches(for: transcript, projection: projection)
        XCTAssertEqual(warm, reference)
        XCTAssertEqual(
            AgentTranscriptProjectionBuilder.buildWithCaches(from: transcript, turnCaches: warm).projection,
            projection,
            "Grouped caches must reproduce every displayed row, block and anchor"
        )

        var baselineSeconds: [Double] = []
        var groupedSeconds: [Double] = []
        for sample in 0 ..< 5 {
            func baselineSample() {
                let start = ProcessInfo.processInfo.systemUptime
                let result = historicalTurnCaches(transcript, projection: projection)
                baselineSeconds.append(ProcessInfo.processInfo.systemUptime - start)
                XCTAssertEqual(result, reference)
            }
            func groupedSample() {
                let start = ProcessInfo.processInfo.systemUptime
                let result = AgentTranscriptProjectionBuilder.updatedTurnCaches(for: transcript, projection: projection)
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                groupedSeconds.append(elapsed)
                XCTAssertLessThan(elapsed, 5, "1,000-turn grouped cache refresh exceeded its 5-second budget")
                XCTAssertEqual(result, reference)
            }
            if sample.isMultiple(of: 2) {
                baselineSample()
                groupedSample()
            } else {
                groupedSample()
                baselineSample()
            }
        }
        print("TRANSCRIPT_GROUPING_PERF turns=\(turnCount) blocks=\(projection.workingBlocks.count + projection.archivedBlocks.count) rowAnchors=\(projection.rowAnchorIndex.count) blockAnchors=\(projection.anchorBlockIndex.count) baselineMedianSeconds=\(baselineSeconds.sorted()[2]) groupedMedianSeconds=\(groupedSeconds.sorted()[2]) samples=5")
    }

    /// Frozen copy of the pre-optimization per-turn filtering algorithm, including
    /// projected-row suppression. Independent of the grouping implementation.
    private func historicalTurnCaches(
        _ transcript: AgentTranscript,
        projection: AgentTranscriptProjection
    ) -> [UUID: AgentTranscriptTurnProjectionCache] {
        var caches: [UUID: AgentTranscriptTurnProjectionCache] = [:]
        for turn in transcript.turns where turn.isCompleted {
            let working = projection.workingBlocks.filter { $0.turnID == turn.id }
            let archived = projection.archivedBlocks.filter { $0.turnID == turn.id }
            caches[turn.id] = AgentTranscriptTurnProjectionCache(
                token: AgentTranscriptProjectionBuilder.validationToken(for: turn),
                workingBlocks: working,
                archivedBlocks: archived,
                workingRows: working.filter { $0.kind != .groupedHistory && $0.kind != .collapsedHistoryRange }.flatMap(\.rows),
                archivedRows: archived.filter { $0.kind != .groupedHistory && $0.kind != .collapsedHistoryRange }.flatMap(\.rows),
                rowAnchorIndex: projection.rowAnchorIndex.filter { anchorTurnID($0.value) == turn.id },
                anchorBlockIndex: projection.anchorBlockIndex.filter { anchorTurnID($0.key) == turn.id }
            )
        }
        return caches
    }

    func testCachesSliceBlocksRowsAndAnchorsPerTurn() throws {
        let turn0 = makeFullTurn(index: 0)
        let turn1 = makeFullTurn(index: 1)
        let archivedTurn = makeFullTurn(index: 2, retentionTier: .archived)
        let transcript = AgentTranscript(turns: [turn0, turn1, archivedTurn], nextSequenceIndex: 9)
        let projection = AgentTranscriptProjectionBuilder.build(from: transcript)

        let caches = AgentTranscriptProjectionBuilder.updatedTurnCaches(
            for: transcript,
            projection: projection
        )

        XCTAssertEqual(Set(caches.keys), [turn0.id, turn1.id, archivedTurn.id])
        for turn in [turn0, turn1, archivedTurn] {
            let cache = try XCTUnwrap(caches[turn.id])
            XCTAssertEqual(
                cache.workingBlocks,
                projection.workingBlocks.filter { $0.turnID == turn.id }
            )
            XCTAssertEqual(
                cache.archivedBlocks,
                projection.archivedBlocks.filter { $0.turnID == turn.id }
            )
            // Rows are reconstructed from the turn's blocks in block order; grouped and
            // collapsed blocks contribute no rows.
            let expectedRows = cache.workingBlocks
                .filter { $0.kind != .groupedHistory && $0.kind != .collapsedHistoryRange }
                .flatMap(\.rows)
            XCTAssertEqual(cache.workingRows, expectedRows)
            let expectedArchivedRows = cache.archivedBlocks
                .filter { $0.kind != .groupedHistory && $0.kind != .collapsedHistoryRange }
                .flatMap(\.rows)
            XCTAssertEqual(cache.archivedRows, expectedArchivedRows)
            // Anchor maps equal the projection maps filtered by owning turn, in full.
            XCTAssertEqual(
                cache.rowAnchorIndex,
                projection.rowAnchorIndex.filter { anchorTurnID($0.value) == turn.id }
            )
            XCTAssertEqual(
                cache.anchorBlockIndex,
                projection.anchorBlockIndex.filter { anchorTurnID($0.key) == turn.id }
            )
            XCTAssertEqual(cache.token.turnID, turn.id)
        }
        // The archived-tier turn produced real archived blocks, so the archived slicing
        // assertions above are not vacuous.
        XCTAssertFalse(caches[archivedTurn.id]?.archivedBlocks.isEmpty ?? true)
    }

    func testCompletedTurnWithNoBlocksStillGetsAnEmptyCache() throws {
        let emptyTurn = makeEmptyCompletedTurn(index: 0)
        let transcript = AgentTranscript(turns: [emptyTurn], nextSequenceIndex: 0)
        let projection = AgentTranscriptProjectionBuilder.build(from: transcript)

        let caches = AgentTranscriptProjectionBuilder.updatedTurnCaches(
            for: transcript,
            projection: projection
        )

        let cache = try XCTUnwrap(caches[emptyTurn.id])
        XCTAssertTrue(cache.workingBlocks.isEmpty)
        XCTAssertTrue(cache.archivedBlocks.isEmpty)
        XCTAssertTrue(cache.workingRows.isEmpty)
        XCTAssertTrue(cache.archivedRows.isEmpty)
        XCTAssertTrue(cache.rowAnchorIndex.isEmpty)
        XCTAssertTrue(cache.anchorBlockIndex.isEmpty)
    }

    // MARK: - Retention rules

    func testIncompleteTurnDropsItsExistingCache() {
        let activeTurn = makeActiveTurn(index: 0)
        let transcript = AgentTranscript(turns: [activeTurn], nextSequenceIndex: 3)
        let projection = AgentTranscriptProjectionBuilder.build(from: transcript)

        let caches = AgentTranscriptProjectionBuilder.updatedTurnCaches(
            for: transcript,
            projection: projection,
            existingTurnCaches: [activeTurn.id: makeCache(turnID: activeTurn.id)]
        )

        XCTAssertNil(caches[activeTurn.id])
    }

    func testProtectedTurnKeepsItsExistingCacheVerbatim() {
        let protected = makeFullTurn(index: 0)
        let other = makeFullTurn(index: 1)
        let transcript = AgentTranscript(turns: [protected, other], nextSequenceIndex: 6)
        let projection = AgentTranscriptProjectionBuilder.build(from: transcript)
        let existing = makeCache(turnID: protected.id)

        let caches = AgentTranscriptProjectionBuilder.updatedTurnCaches(
            for: transcript,
            projection: projection,
            protection: .protectedTurn(protected.id),
            existingTurnCaches: [protected.id: existing]
        )

        XCTAssertEqual(caches[protected.id], existing)
        XCTAssertNotNil(caches[other.id])
    }

    func testCachesForTurnsAbsentFromTranscriptAreDropped() {
        let turn = makeFullTurn(index: 0)
        let transcript = AgentTranscript(turns: [turn], nextSequenceIndex: 3)
        let projection = AgentTranscriptProjectionBuilder.build(from: transcript)
        let foreignID = UUID()

        let caches = AgentTranscriptProjectionBuilder.updatedTurnCaches(
            for: transcript,
            projection: projection,
            existingTurnCaches: [
                turn.id: makeCache(turnID: turn.id),
                foreignID: makeCache(turnID: foreignID)
            ]
        )

        XCTAssertNil(caches[foreignID])
        XCTAssertNotNil(caches[turn.id])
        // The kept turn's cache is rebuilt from the projection, not retained verbatim.
        XCTAssertEqual(
            caches[turn.id]?.token,
            AgentTranscriptProjectionBuilder.validationToken(for: turn)
        )
    }

    func testDuplicateTurnIDsProduceOneCacheWithAllMatchingBlocks() throws {
        let sharedID = UUID()
        let first = makeFullTurn(index: 0, id: sharedID)
        let second = makeFullTurn(index: 1, id: sharedID)
        let transcript = AgentTranscript(turns: [first, second], nextSequenceIndex: 6)
        let projection = AgentTranscriptProjectionBuilder.build(from: transcript)

        let caches = AgentTranscriptProjectionBuilder.updatedTurnCaches(
            for: transcript,
            projection: projection
        )

        let cache = try XCTUnwrap(caches[sharedID])
        // Both occurrences slice the same projection, so the surviving cache contains
        // every block bearing the shared turn ID — identical to the old filter behavior.
        XCTAssertEqual(
            cache.workingBlocks,
            projection.workingBlocks.filter { $0.turnID == sharedID }
        )
    }
}

/// `sanitizeTranscriptForPersistenceWithMetrics` uses a fresh per-pass
/// `AgentToolResultProcessingContext` for JSON-parse memoization, but its item-ID-keyed
/// execution cache is disabled: a later activity that shares an earlier activity's ID
/// must be normalized from its own content, never from a cached execution — including
/// one already transformed by this same pass. These tests pin equivalence to the
/// `context: nil` baseline for exactly that input shape.
final class AgentToolResultPersistenceContextTests: XCTestCase {
    private func makeToolCallActivity(
        id: UUID,
        sequenceIndex: Int,
        toolExecution: AgentTranscriptToolExecution?
    ) -> AgentTranscriptActivity {
        AgentTranscriptActivity(
            id: id,
            timestamp: Date(timeIntervalSince1970: TimeInterval(sequenceIndex)),
            sequenceIndex: sequenceIndex,
            role: .assistant,
            itemKind: .toolCall,
            text: "",
            toolExecution: toolExecution
        )
    }

    private func makeExecution(name: String, resultJSON: String?) -> AgentTranscriptToolExecution {
        AgentTranscriptToolExecution(
            stableExecutionID: "exec-\(name)",
            toolName: name,
            invocationID: UUID(),
            argsJSON: nil,
            resultJSON: resultJSON,
            toolIsError: false,
            status: .success
        )
    }

    private func makeTranscript(activities: [AgentTranscriptActivity]) -> AgentTranscript {
        let startedAt = Date(timeIntervalSince1970: 0)
        let user = AgentChatItem.user("request", sequenceIndex: 0)
        return AgentTranscript(
            turns: [
                AgentTranscriptTurn(
                    id: UUID(),
                    request: AgentTranscriptRequestAnchor(from: user),
                    responseSpans: [
                        AgentTranscriptProviderResponseSpan(
                            lifecycle: .completed,
                            startedAt: startedAt,
                            lastActivityAt: startedAt.addingTimeInterval(1),
                            completedAt: startedAt.addingTimeInterval(1),
                            activities: activities
                        )
                    ],
                    retentionTier: .full,
                    terminalState: .completed,
                    startedAt: startedAt,
                    lastActivityAt: startedAt.addingTimeInterval(1),
                    completedAt: startedAt.addingTimeInterval(1)
                )
            ],
            nextSequenceIndex: activities.count + 1
        )
    }

    private func baseline(_ transcript: AgentTranscript) -> AgentTranscript {
        AgentToolResultPersistencePolicy.sanitizeTranscriptWithMetrics(
            transcript,
            context: nil,
            purpose: .persistentStorage
        ).transcript
    }

    func testLargePersistencePassMatchesBaselineAndDeduplicatesParsingWithinBudget() throws {
        let sharedID = UUID()
        let payloads = try (0 ..< 16).map { index in
            let data = try JSONSerialization.data(withJSONObject: [
                "content": [["type": "text", "text": "payload \(index): " + String(repeating: "λ-data ", count: 500)]]
            ], options: .sortedKeys)
            return String(decoding: data, as: UTF8.self)
        }
        var activities = (0 ..< 4000).map { index in
            makeToolCallActivity(
                id: index.isMultiple(of: 13) ? sharedID : UUID(),
                sequenceIndex: index + 1,
                toolExecution: index.isMultiple(of: 19) ? nil : makeExecution(
                    name: "read_file", resultJSON: payloads[index % payloads.count]
                )
            )
        }
        // Exercise the bounded cache beyond 128 distinct entries, invalid JSON, and
        // payloads above the 16-KiB cache limit, not just a repeated-payload best case.
        for index in 0 ..< 140 {
            activities.append(makeToolCallActivity(
                id: UUID(), sequenceIndex: activities.count + 1,
                toolExecution: makeExecution(name: "read_file", resultJSON: "{\"unique\":\(index)}")
            ))
        }
        for payload in ["not json", "{\"text\":\"" + String(repeating: "x", count: 17000) + "\"}"] {
            for _ in 0 ..< 8 {
                activities.append(makeToolCallActivity(
                    id: sharedID, sequenceIndex: activities.count + 1,
                    toolExecution: makeExecution(name: "read_file", resultJSON: payload)
                ))
            }
        }
        for index in activities.indices {
            activities[index].itemKind = .toolResult
        }
        let transcript = makeTranscript(activities: activities)
        let reference = baseline(transcript)
        let context = AgentToolResultProcessingContext(cachesToolExecutions: false)
        let observed = AgentToolResultPersistencePolicy.sanitizeTranscriptForPersistenceWithMetrics(
            transcript, context: context
        ).transcript
        XCTAssertEqual(observed, reference)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        XCTAssertEqual(try encoder.encode(observed), try encoder.encode(reference), "Saved content must be byte-identical")
        let metrics = context.snapshotMetrics()
        #if DEBUG || EDIT_FLOW_PERF
            XCTAssertGreaterThan(metrics.jsonParseCacheHitCount, 1000)
            XCTAssertLessThan(metrics.jsonParseCacheMissCount, metrics.jsonParseAttemptCount / 4)
            XCTAssertEqual(metrics.toolExecutionCacheHitCount, 0, "Repeated IDs must never share executions")
        #endif

        // Warm both paths, then alternate order in five samples in the same process.
        XCTAssertEqual(AgentToolResultPersistencePolicy.sanitizeTranscriptForPersistence(transcript), reference)
        var baselineSeconds: [Double] = []
        var memoizedSeconds: [Double] = []
        for sample in 0 ..< 5 {
            func baselineSample() {
                let start = ProcessInfo.processInfo.systemUptime
                let result = baseline(transcript)
                baselineSeconds.append(ProcessInfo.processInfo.systemUptime - start)
                XCTAssertEqual(result, reference)
            }
            func memoizedSample() {
                let start = ProcessInfo.processInfo.systemUptime
                let result = AgentToolResultPersistencePolicy.sanitizeTranscriptForPersistence(transcript)
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                memoizedSeconds.append(elapsed)
                XCTAssertLessThan(elapsed, 15, "4,156-activity persistence pass exceeded its 15-second budget")
                XCTAssertEqual(result, reference)
            }
            if sample.isMultiple(of: 2) {
                baselineSample()
                memoizedSample()
            } else {
                memoizedSample()
                baselineSample()
            }
        }
        print("TRANSCRIPT_PERSISTENCE_PERF activities=\(activities.count) parseAttempts=\(metrics.jsonParseAttemptCount) parseHits=\(metrics.jsonParseCacheHitCount) parseMisses=\(metrics.jsonParseCacheMissCount) baselineMedianSeconds=\(baselineSeconds.sorted()[2]) memoizedMedianSeconds=\(memoizedSeconds.sorted()[2]) samples=5")
    }

    func testRepeatedActivityIDWithMissingExecutionMatchesNilContextBaseline() {
        let sharedID = UUID()
        let transcript = makeTranscript(activities: [
            makeToolCallActivity(
                id: sharedID,
                sequenceIndex: 1,
                toolExecution: makeExecution(name: "read_file", resultJSON: "{\"ok\":true}")
            ),
            makeToolCallActivity(id: sharedID, sequenceIndex: 2, toolExecution: nil)
        ])

        let optimized = AgentToolResultPersistencePolicy
            .sanitizeTranscriptForPersistenceWithMetrics(transcript).transcript

        XCTAssertEqual(optimized, baseline(transcript))
    }

    func testRepeatedActivityIDWithDistinctExecutionsMatchesNilContextBaseline() {
        let sharedID = UUID()
        let transcript = makeTranscript(activities: [
            makeToolCallActivity(
                id: sharedID,
                sequenceIndex: 1,
                toolExecution: makeExecution(name: "read_file", resultJSON: "{\"a\":1}")
            ),
            makeToolCallActivity(
                id: sharedID,
                sequenceIndex: 2,
                toolExecution: makeExecution(name: "write_file", resultJSON: "{\"b\":2}")
            )
        ])

        let optimized = AgentToolResultPersistencePolicy
            .sanitizeTranscriptForPersistenceWithMetrics(transcript).transcript

        XCTAssertEqual(optimized, baseline(transcript))
    }

    /// Non-vacuity guard: with the fully-caching context the missing-execution fixture
    /// *does* diverge from the nil-context baseline (the second activity inherits the
    /// first's transformed execution), proving the fixtures exercise the hazard the
    /// disabled cache exists to prevent.
    func testFullyCachingContextWouldDivergeOnMissingExecutionFixture() {
        let sharedID = UUID()
        let transcript = makeTranscript(activities: [
            makeToolCallActivity(
                id: sharedID,
                sequenceIndex: 1,
                toolExecution: makeExecution(name: "read_file", resultJSON: "{\"ok\":true}")
            ),
            makeToolCallActivity(id: sharedID, sequenceIndex: 2, toolExecution: nil)
        ])

        let cached = AgentToolResultPersistencePolicy.sanitizeTranscriptWithMetrics(
            transcript,
            context: AgentToolResultProcessingContext(),
            purpose: .persistentStorage
        ).transcript

        XCTAssertNotEqual(cached, baseline(transcript))
    }
}
