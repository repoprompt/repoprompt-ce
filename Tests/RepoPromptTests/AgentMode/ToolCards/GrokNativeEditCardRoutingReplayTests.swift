#if DEBUG
    import Foundation
    @testable import RepoPromptApp
    import XCTest

    @MainActor
    final class GrokNativeEditCardRoutingReplayTests: XCTestCase {
        /// See GrokBuild1062NativeEditFixtures for recording provenance and sanitization.
        func testRecorded1062NativeEditsRemainDiffCapableAfterSaveLoad() async throws {
            let viewModel = AgentModeViewModel(
                testWindowID: -997,
                testWorkspacePath: FileManager.default.currentDirectoryPath,
                codexControllerFactory: { _, _, _, _, _, _ in
                    preconditionFailure("Recorded replay must not start a provider")
                },
                connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
                mcpServerEnabler: { true }
            )
            let session = AgentModeViewModel.TabSession(tabID: UUID())
            session.selectedAgent = .grokBuild
            session.runState = .running
            let runID = UUID()
            let attemptID = UUID()
            session.installRunID(runID)
            session.beginRunAttempt(source: "recorded-native-edit-replay", attemptID: attemptID)

            let fixtures = [
                RecordedEdit(
                    name: "search_replace-completed", jsonl: GrokBuild1062NativeEditFixtures.searchReplaceCompleted,
                    path: "/private/fixtures/grok-native-edit/fixture/probe.txt",
                    removed: ["N7_BEFORE_MARKER"], added: ["N7_AFTER_MARKER"],
                    removedLineNumbers: [7], addedLineNumbers: [7], failed: false
                ),
                RecordedEdit(
                    name: "write-completed", jsonl: GrokBuild1062NativeEditFixtures.writeCompleted,
                    path: "/fixtures/grok-native-edit/fixture/new_file.txt",
                    removed: [], added: ["alpha", "beta", "gamma"],
                    removedLineNumbers: [], addedLineNumbers: [1, 2, 3], failed: false
                ),
                RecordedEdit(
                    name: "search_replace-failed", jsonl: GrokBuild1062NativeEditFixtures.searchReplaceFailed,
                    path: nil, removed: [], added: [], removedLineNumbers: [], addedLineNumbers: [], failed: true
                )
            ]
            var liveRows: [AgentChatItem] = []
            for fixture in fixtures {
                let updates = try recordedUpdates(from: fixture.jsonl)
                XCTAssertEqual(updates.count, 3, fixture.name)
                let callID = try XCTUnwrap(updates.first?["toolCallId"] as? String)
                let invocationID = ACPRuntimeEventParsing.stableInvocationUUID(rawValue: callID)
                var rowID: UUID?
                for (index, update) in updates.enumerated() {
                    let events = GrokBuildACPEventNormalizer.normalize(update)
                    if index == 1 {
                        XCTAssertTrue(events.isEmpty, "\(fixture.name): status-less proposed Diff must not complete or create a row")
                    }
                    for event in events {
                        guard case let .stream(result) = event else {
                            XCTFail("\(fixture.name): expected a normalized stream event")
                            continue
                        }
                        await viewModel.test_handleStreamResult(
                            result, session: session, runID: runID, runAttemptID: attemptID
                        )
                    }
                    let rows = session.items.filter { $0.toolInvocationID == invocationID }
                    XCTAssertEqual(rows.count, 1, "\(fixture.name): one row per invocation at update \(index)")
                    let row = try XCTUnwrap(rows.first)
                    if index == 0 {
                        rowID = row.id
                        XCTAssertEqual(row.toolName, "edit", "\(fixture.name): initial call must already be classified as edit")
                        let args = try XCTUnwrap(ToolJSON.rawObject(from: row.toolArgsJSON))
                        let originalArgs = try XCTUnwrap(update["rawInput"] as? [String: Any])
                        XCTAssertEqual(args as NSDictionary, originalArgs as NSDictionary, fixture.name)
                    }
                    XCTAssertEqual(row.id, rowID, "\(fixture.name): merge must retain the initial row")
                    XCTAssertEqual(row.kind, index == 2 ? .toolResult : .toolCall, fixture.name)
                    if index < 2 {
                        XCTAssertNil(row.toolResultJSON, "\(fixture.name): proposed Diff is not an applied result")
                    } else {
                        assertPresentation(row, expected: fixture, phase: "live")
                        liveRows.append(row)
                    }
                }
            }
            XCTAssertEqual(session.items.count, 3, "all three recorded invocations must merge without duplicate rows")
            session.runState = .completed

            let storage = FileManager.default.temporaryDirectory.appendingPathComponent("GrokNativeEditReplay-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: storage) }
            let workspace = WorkspaceModel(name: "Grok native edit replay", repoPaths: [], customStoragePath: storage)
            let timestamp = Date(timeIntervalSince1970: 1_792_453_700)
            let activities = liveRows.map {
                AgentTranscriptActivity(from: $0, toolExecution: AgentTranscriptToolNormalizer.toolExecution(for: $0))
            }
            let saved = AgentSession(
                workspaceID: workspace.id, composeTabID: session.tabID, name: "Recorded native edits",
                transcript: AgentTranscript(turns: [AgentTranscriptTurn(
                    responseSpans: [AgentTranscriptProviderResponseSpan(
                        lifecycle: .completed, startedAt: timestamp, completedAt: timestamp, activities: activities
                    )],
                    terminalState: .completed, startedAt: timestamp, completedAt: timestamp
                )], nextSequenceIndex: 3), lastRunState: "completed"
            )
            // Real storage, then a fresh service and restoration projection: no live
            // row or retained raw-result store is available to supply the diff.
            let fileURL = try await AgentSessionDataService().saveAgentSession(saved, for: workspace)
            let onDisk = try JSONDecoder().decode(AgentSession.self, from: Data(contentsOf: fileURL))
            let storedActivities = try XCTUnwrap(onDisk.transcript).turns.flatMap(\.allActivities)
            XCTAssertEqual(storedActivities.count, 3)
            for row in liveRows {
                let activity = try XCTUnwrap(storedActivities.first { $0.id == row.id })
                let json = try XCTUnwrap(activity.toolExecution?.resultJSON)
                XCTAssertLessThanOrEqual(json.utf8.count, AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes)
                let object = try XCTUnwrap(ToolJSON.rawObject(from: json))
                assertNoRawDiffText(in: object)
            }
            let loaded = try await AgentSessionDataService().loadAgentSession(from: fileURL)
            let transcript = try XCTUnwrap(loaded.transcript)
            XCTAssertEqual(transcript.turns.first?.terminalState, .completed)
            let presentation = AgentSessionRestoreSupport.buildTranscriptPresentation(
                from: transcript, sourceItems: loaded.items.map { $0.toItem() }, selectedAgent: .grokBuild,
                previousPerformanceSnapshot: .init(), projectionProtection: .none,
                isCompressedHistoryRevealed: true, isColdLoad: true
            )
            let restoredRows = presentation.fullProjection.workingRows + presentation.fullProjection.archivedRows
            for (fixture, live) in zip(fixtures, liveRows) {
                let matches = restoredRows.filter { $0.toolInvocationID == live.toolInvocationID }
                XCTAssertEqual(matches.count, 1, "\(fixture.name): fresh load must retain one invocation row")
                let restored = try XCTUnwrap(matches.first)
                XCTAssertEqual(restored.id, live.id, fixture.name)
                XCTAssertTrue(toolResultIsSummaryOnly(restored), "\(fixture.name): preview must work from the bounded summary alone")
                assertPresentation(restored, expected: fixture, phase: "fresh load")
            }
        }

        private struct RecordedEdit {
            let name: String
            let jsonl: String
            let path: String?
            let removed: [String]
            let added: [String]
            let removedLineNumbers: [Int]
            let addedLineNumbers: [Int]
            let failed: Bool
        }

        private func recordedUpdates(from text: String) throws -> [[String: Any]] {
            try text.split(separator: "\n").compactMap { line in
                let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
                // Same method guard as the ACP controller: x.ai interaction notices
                // are not session updates and must not enter this normalizer.
                guard envelope["method"] as? String == "session/update" else { return nil }
                let params = try XCTUnwrap(envelope["params"] as? [String: Any])
                return try XCTUnwrap(params["update"] as? [String: Any])
            }
        }

        private func assertPresentation(_ row: AgentChatItem, expected: RecordedEdit, phase: String) {
            let label = "\(expected.name) \(phase)"
            // This is the selector used by ToolCardRouter.resultView, paired with
            // the edit card's production presentation (not private AnyView storage).
            XCTAssertEqual(normalizedToolCardName(row.toolName), "edit", "\(label): route must select the edit card")
            XCTAssertEqual(row.toolIsError, expected.failed, "\(label): preserve terminal failure")
            let presentation = CursorNativeEditResultPresentation.build(for: row)
            XCTAssertEqual(presentation.status, expected.failed ? .failure : .success, label)
            XCTAssertEqual(presentation.diffs.count, expected.failed ? 0 : 1, "\(label): only applied edits have a diff")
            guard !expected.failed else { return }
            XCTAssertTrue(presentation.isExpandable, "\(label): diff must remain expandable")
            XCTAssertEqual(presentation.renderMode, .diffPreview, label)
            guard let diff = presentation.diffs.first else { return }
            XCTAssertEqual(diff.path, expected.path, "\(label): retain the recorded terminal path")
            XCTAssertFalse(diff.isTruncated, "\(label): recorded small diff fits the existing budget")
            let lines = diff.diff.split(separator: "\n").map(String.init)
            let removed = lines.filter { $0.hasPrefix("-") && !$0.hasPrefix("---") }.map { String($0.dropFirst()) }
            let added = lines.filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }.map { String($0.dropFirst()) }
            XCTAssertEqual(removed, expected.removed, "\(label): exact removed lines (empty for a new file)")
            XCTAssertEqual(added, expected.added, "\(label): exact added lines")
            let document = UnifiedDiffCardRendering.parse(diff.diff)
            XCTAssertEqual(
                document.lines.filter { $0.kind == .deletion }.compactMap(\.oldLineNumber),
                expected.removedLineNumbers, "\(label): removed lines retain file coordinates"
            )
            XCTAssertEqual(
                document.lines.filter { $0.kind == .addition }.compactMap(\.newLineNumber),
                expected.addedLineNumbers, "\(label): added lines retain file coordinates"
            )
        }

        private func assertNoRawDiffText(in value: Any) {
            if let object = value as? [String: Any] {
                for key in ["oldText", "newText", "old_text", "new_text", "old_string", "new_string"] {
                    XCTAssertNil(object[key], "saved summary must not retain raw \(key) fields")
                }
                for child in object.values {
                    assertNoRawDiffText(in: child)
                }
            } else if let array = value as? [Any] {
                for child in array {
                    assertNoRawDiffText(in: child)
                }
            }
        }
    }
#endif
