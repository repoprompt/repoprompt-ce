#if DEBUG
    import Foundation
    @testable import RepoPromptApp
    import XCTest

    final class AgentTranscriptSpanAssemblyParityTests: XCTestCase {
        private struct Case {
            let name: String
            let items: [AgentChatItem]
            let terminal: AgentSessionRunState
            var quiet: [UUID: AgentTranscriptQuietLocalTurn] = [:]
        }

        private func id(_ value: Int) -> UUID {
            UUID(uuidString: String(format: "00000000-0000-4000-8000-%012x", value))!
        }

        private func row(_ index: Int, kind: AgentChatItemKind, text: String = "", name: String? = nil, call: Int? = nil, args: String? = nil, result: String? = nil, error: Bool? = nil) -> AgentChatItem {
            AgentChatItem(
                id: id(1000 + index), timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
                kind: kind, text: text, toolName: name, toolInvocationID: call.map { id(2000 + $0) },
                toolArgsJSON: args, toolResultJSON: result, toolIsError: error, sequenceIndex: index
            )
        }

        private func cases() -> [Case] {
            var tools = [row(0, kind: .user, text: "Inspect the fixture")]
            for call in 0 ..< 12 {
                let name = ["read_file", "file_search", "apply_edits", "bash"][call % 4]
                // Unnamed calls exercise the legacy tool-name correlation stack.
                let invocation = call < 2 ? nil : call
                tools.append(row(tools.count, kind: .toolCall, name: name, call: invocation, args: "{\"path\":\"File\(call).swift\"}"))
                tools.append(row(
                    tools.count,
                    kind: .toolResult,
                    name: name,
                    call: invocation,
                    result: name == "bash" ? "{\"stdout\":\"fixture\",\"exitCode\":0}" : "{\"path\":\"File\(call).swift\",\"content\":\"fixture\"}",
                    error: call == 6
                ))
                tools.append(row(tools.count, kind: .assistant, text: "Checked file \(call)."))
            }
            var edited = tools
            edited[10].toolArgsJSON = "{\"path\":\"Changed.swift\"}"
            edited[11].toolResultJSON = "{\"path\":\"Changed.swift\",\"content\":\"revised\"}"
            edited[12].text = "Revised middle narration."
            var quiet = tools
            for index in 34 ..< 37 {
                quiet[index].quietCheckInWakeID = id(9000)
            }
            let baseline = AgentTranscriptQuietLocalTurn(
                summary: nil, conclusionActivityID: tools[33].id, completedAt: tools[33].timestamp
            )
            var prelude = row(100, kind: .assistant, text: "Orphan prelude")
            prelude.sequenceIndex = -1
            var multiple = [prelude]
            multiple.append(contentsOf: tools)
            multiple.append(row(101, kind: .user, text: "Next request"))
            multiple.append(row(102, kind: .thinking, text: "Working"))
            multiple.append(row(103, kind: .assistant, text: "Next answer"))
            return [
                Case(name: "empty", items: [], terminal: .running),
                Case(name: "request_only", items: [tools[0]], terminal: .completed),
                Case(name: "tools_running", items: tools, terminal: .running),
                Case(name: "mid_turn_edit", items: edited, terminal: .running),
                Case(name: "terminal_completed", items: edited, terminal: .completed),
                Case(name: "quiet_running", items: quiet, terminal: .running, quiet: [tools[0].id: baseline]),
                Case(name: "quiet_completed", items: quiet, terminal: .completed, quiet: [tools[0].id: baseline]),
                Case(name: "turn_boundaries", items: multiple, terminal: .completed)
            ]
        }

        private func imported(_ fixture: Case) -> AgentTranscript {
            AgentTranscriptIO.importLegacyItems(
                fixture.items, terminalState: fixture.terminal, quietLocalBaselines: fixture.quiet
            )
        }

        /// Captured from the unmodified importer at 064be9b6c; transient revisions are not Codable.
        private func references() throws -> [String: AgentTranscript] {
            let path = try XCTUnwrap(Bundle.module.url(forResource: "AgentTranscriptSpanAssemblyReference", withExtension: "json"))
            return try JSONDecoder().decode([String: AgentTranscript].self, from: Data(contentsOf: path))
        }

        func testImportedSpansMatchPreBufferReference() throws {
            defer { AgentTranscriptDebugInstrumentation.reset() }
            let reference = try references()
            XCTAssertEqual(Set(reference.keys), Set(cases().map(\.name)))
            for fixture in cases() {
                var traversals: [AgentTranscriptSummaryTraversalMetrics] = []
                AgentTranscriptDebugInstrumentation.configure(.init(summaryTraversalHandler: { traversals.append($0) }))
                let actual = imported(fixture)
                AgentTranscriptDebugInstrumentation.reset()
                let expected = try XCTUnwrap(reference[fixture.name])
                XCTAssertEqual(actual, expected, fixture.name)
                XCTAssertEqual(actual.turns.flatMap(\.allActivities), expected.turns.flatMap(\.allActivities), fixture.name)
                for excludingQuiet in [false, true] {
                    let projection = AgentTranscriptProjectionBuilder.buildWithCaches(
                        from: actual, turnCaches: [:], excludingQuiet: excludingQuiet, replyPresentation: true
                    ).projection
                    let historical = AgentTranscriptProjectionBuilder.buildWithCaches(
                        from: expected, turnCaches: [:], excludingQuiet: excludingQuiet, replyPresentation: true
                    ).projection
                    XCTAssertEqual(projection, historical, fixture.name)
                }
                let spans = actual.turns.flatMap(\.responseSpans)
                XCTAssertEqual(traversals.count(where: { $0.phase == "span-summary" }), spans.count, fixture.name)
                XCTAssertEqual(traversals.count(where: { $0.phase == "turn-summary" }), actual.turns.count, fixture.name)
                for phase in ["span-summary", "turn-summary"] {
                    XCTAssertEqual(
                        traversals.filter { $0.phase == phase }.reduce(0) { $0 + $1.activityCount },
                        spans.reduce(0) { $0 + $1.activities.count },
                        fixture.name
                    )
                }
                if fixture.name.hasPrefix("quiet") {
                    XCTAssertEqual(actual.turns[0].summary?.toolCount, 12)
                    XCTAssertEqual(actual.turns[0].quietLocal?.summary?.toolCount, 11)
                }
            }
        }

        func testConsecutiveEmptyTurnsKeepActivitiesAndLifecyclesIsolated() throws {
            let groups = [
                [row(200, kind: .user, text: "user A"), row(201, kind: .assistant, text: "assistant A")],
                [row(202, kind: .user, text: "user B")],
                [row(203, kind: .user, text: "user C"), row(204, kind: .assistant, text: "assistant C")],
                [row(205, kind: .user, text: "user D")]
            ]
            for terminal in [AgentSessionRunState.running, .completed] {
                let transcript = AgentTranscriptIO.importLegacyItems(groups.flatMap(\.self), terminalState: terminal)
                // Independent imports cannot leak an activity buffer from one turn into another.
                let isolated = groups.enumerated().flatMap { index, items in
                    AgentTranscriptIO.importLegacyItems(items, terminalState: index == 3 ? terminal : nil).turns
                }
                XCTAssertEqual(transcript.turns, isolated)
                XCTAssertEqual(transcript.turns.count, 4)
                XCTAssertEqual(transcript.turns.map { $0.request?.id }, groups.map { $0[0].id })
                XCTAssertEqual(transcript.turns.map { $0.allActivities.map(\.id) }, [
                    [groups[0][1].id], [], [groups[2][1].id], []
                ])
                for (index, pair) in zip(groups, transcript.turns).enumerated() {
                    let (group, turn) = pair
                    XCTAssertEqual(turn.responseSpans.count, 1)
                    let span = try XCTUnwrap(turn.responseSpans.first)
                    let isCompleted = index < 3 || terminal == .completed
                    XCTAssertEqual(span.lifecycle, isCompleted ? .completed : .open)
                    let lastActivity = group.last(where: { $0.kind != .user })
                    XCTAssertEqual(span.activities.map(\.id), lastActivity.map { [$0.id] } ?? [])
                    XCTAssertEqual(span.lastActivityAt, lastActivity?.timestamp)
                    let completedAt = isCompleted ? (lastActivity?.timestamp ?? group[0].timestamp) : nil
                    XCTAssertEqual(span.completedAt, completedAt)
                    XCTAssertEqual(turn.completedAt, completedAt)
                    XCTAssertEqual(turn.terminalState, index == 3 ? terminal : nil)
                }
            }
        }

        func testIncrementalMidTurnEditsAndTerminalTransitionsMatchReference() throws {
            let reference = try references()
            for fixture in cases().filter({ ["mid_turn_edit", "terminal_completed", "quiet_completed"].contains($0.name) }) {
                let priorName = fixture.name == "quiet_completed" ? "quiet_running" : "tools_running"
                let prior = try AgentTranscriptCompactor.compact(XCTUnwrap(reference[priorName]))
                let actual = try XCTUnwrap(AgentTranscriptIO.incrementallyUpdatedTranscriptForFinalTurn(
                    existingTranscript: prior, items: fixture.items, earliestChangedIndex: 10,
                    terminalState: fixture.terminal, nextSequenceIndex: fixture.items.count
                ))
                let expected = try AgentTranscriptCompactor.compact(XCTUnwrap(reference[fixture.name]))
                XCTAssertEqual(actual, expected, fixture.name)
            }
        }

        func testIncrementalUpdatesKeepCompletedPrefixRevisionsAndCaches() throws {
            let fixture = try XCTUnwrap(cases().first { $0.name == "turn_boundaries" })
            let prior = AgentTranscriptIO.buildTranscript(from: fixture.items, terminalState: .running)
            let initial = AgentTranscriptProjectionBuilder.buildWithCaches(
                from: prior, turnCaches: [:], replyPresentation: true
            )
            var edited = fixture.items
            edited[edited.count - 1].text = "Updated final answer"
            let next = try XCTUnwrap(AgentTranscriptIO.incrementallyUpdatedTranscriptForFinalTurn(
                existingTranscript: prior, items: edited, earliestChangedIndex: edited.count - 1,
                terminalState: .running, nextSequenceIndex: 104
            ))
            XCTAssertEqual(Array(next.turns.dropLast()), Array(prior.turns.dropLast()))
            for (old, updated) in zip(prior.turns.dropLast(), next.turns.dropLast()) {
                XCTAssertEqual(old.responseSpans.map(\.activityRevision), updated.responseSpans.map(\.activityRevision))
            }
            var classified: [UUID] = []
            let warm = AgentTranscriptProjectionBuilder.buildWithCaches(
                from: next, turnCaches: initial.updatedTurnCaches, replyPresentation: true,
                onReplyClassification: { classified.append($0) }
            )
            let cold = AgentTranscriptProjectionBuilder.buildWithCaches(from: next, turnCaches: [:], replyPresentation: true)
            XCTAssertEqual(warm.projection, cold.projection)
            XCTAssertEqual(classified, try [XCTUnwrap(next.turns.last?.id)])
        }

        func testFreshImportsInvalidateRevisionCachesAndStableSnapshotsReuseThem() throws {
            let fixture = try XCTUnwrap(cases().first { $0.name == "terminal_completed" })
            var rebuilds: [UUID] = []
            let first = AgentTranscriptProjectionBuilder.refreshCompletedFullTurnGroupedHistoryCaches(
                in: imported(fixture), onSummaryRebuild: { rebuilds.append($0) }
            )
            let span = try XCTUnwrap(first.turns.first?.responseSpans.first)
            XCTAssertNotNil(span.fullRenderGroupedHistoryCache)
            XCTAssertEqual(rebuilds, [first.turns[0].id])
            rebuilds = []
            let stable = AgentTranscriptProjectionBuilder.refreshCompletedFullTurnGroupedHistoryCaches(
                in: first, reusablePrefixTurnCount: 1, onSummaryRebuild: { rebuilds.append($0) }
            )
            XCTAssertTrue(rebuilds.isEmpty)
            XCTAssertEqual(stable.turns[0].responseSpans[0].activityRevision, span.activityRevision)
            var fresh = imported(fixture)
            XCTAssertNotEqual(fresh.turns[0].responseSpans[0].activityRevision, span.activityRevision)
            // Equal durable content and digest, but a revision from another import is stale.
            fresh.turns[0].responseSpans[0].fullRenderGroupedHistoryCache = span.fullRenderGroupedHistoryCache
            let refreshed = AgentTranscriptProjectionBuilder.refreshCompletedFullTurnGroupedHistoryCaches(
                in: fresh, reusablePrefixTurnCount: 1, onSummaryRebuild: { rebuilds.append($0) }
            )
            XCTAssertEqual(rebuilds, [first.turns[0].id])
            XCTAssertEqual(
                refreshed.turns[0].responseSpans[0].fullRenderGroupedHistoryCache?.activityRevision,
                fresh.turns[0].responseSpans[0].activityRevision
            )
            let prior = AgentTranscriptProjectionBuilder.buildWithCaches(from: first, turnCaches: [:], excludingQuiet: true, replyPresentation: true)
            for variant in cases().filter({ ["tools_running", "mid_turn_edit", "terminal_completed", "quiet_completed"].contains($0.name) }) {
                let next = imported(variant)
                var classified: [UUID] = []
                let warm = AgentTranscriptProjectionBuilder.buildWithCaches(
                    from: next, turnCaches: prior.updatedTurnCaches, excludingQuiet: true, replyPresentation: true,
                    onReplyClassification: { classified.append($0) }
                )
                let cold = AgentTranscriptProjectionBuilder.buildWithCaches(
                    from: next, turnCaches: [:], excludingQuiet: true, replyPresentation: true
                )
                XCTAssertEqual(warm.projection, cold.projection, variant.name)
                XCTAssertEqual(classified, [next.turns[0].id], variant.name)
                classified = []
                let reused = AgentTranscriptProjectionBuilder.buildWithCaches(
                    from: next, turnCaches: warm.updatedTurnCaches, excludingQuiet: true, replyPresentation: true,
                    onReplyClassification: { classified.append($0) }
                )
                XCTAssertEqual(reused.projection, cold.projection, variant.name)
                XCTAssertEqual(classified, next.turns[0].isCompleted ? [] : [next.turns[0].id], variant.name)
            }
        }
    }
#endif
