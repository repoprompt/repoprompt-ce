#if DEBUG
    import Foundation
    import XCTest
    @_spi(TestSupport) @testable import RepoPrompt

    @MainActor
    final class AgentTranscriptCrawlRefreshBenchmarkTests: XCTestCase {
        func testPermitCorrelatedToolCompletionWorkCountDoesNotScaleWithTranscriptLength() throws {
            let shortInvocation = try codexCompletionAttributionSample(priorTurnCount: 1, includeInvocationID: true)
            let longInvocation = try codexCompletionAttributionSample(priorTurnCount: 2000, includeInvocationID: true)
            let shortSignature = try codexCompletionAttributionSample(priorTurnCount: 1, includeInvocationID: false)
            let longSignature = try codexCompletionAttributionSample(priorTurnCount: 2000, includeInvocationID: false)

            XCTAssertEqual(shortInvocation.correlationPath, "invocation_id")
            XCTAssertEqual(longInvocation.correlationPath, "invocation_id")
            XCTAssertEqual(shortInvocation.scannedItemCount, 1)
            XCTAssertEqual(longInvocation.scannedItemCount, 1)
            XCTAssertEqual(shortSignature.correlationPath, "signature")
            XCTAssertEqual(longSignature.correlationPath, "signature")
            XCTAssertEqual(shortSignature.scannedItemCount, 1)
            XCTAssertEqual(longSignature.scannedItemCount, 1)
        }

        private func codexCompletionAttributionSample(
            priorTurnCount: Int,
            includeInvocationID: Bool
        ) throws -> MCPToolObserverAttribution {
            let viewModel = makeViewModel()
            let session = AgentModeViewModel.TabSession(tabID: UUID())
            var items: [AgentChatItem] = []
            items.reserveCapacity(priorTurnCount * 2 + 2)
            var sequenceIndex = 0
            for turn in 0 ..< priorTurnCount {
                items.append(.user("historical user \(turn)", sequenceIndex: sequenceIndex))
                sequenceIndex += 1
                items.append(.assistant("historical assistant \(turn)", sequenceIndex: sequenceIndex))
                sequenceIndex += 1
            }
            items.append(.user("active user", sequenceIndex: sequenceIndex))
            sequenceIndex += 1
            let invocationID = includeInvocationID ? UUID() : nil
            items.append(.toolCall(
                name: "read_file",
                invocationID: invocationID,
                argsJSON: nil,
                sequenceIndex: sequenceIndex
            ))
            session.setItemsSilently(items, reason: .testOverride)

            let recorder = MCPToolObserverAttributionRecorder()
            MCPToolObserverAttributionContext.$recorder.withValue(recorder) {
                viewModel.test_codexCoordinator.testSimulateRepoPromptToolResult(
                    invocationID: invocationID,
                    toolName: "read_file",
                    args: nil,
                    resultJSON: #"{"content":"ok"}"#,
                    isError: false,
                    session: session
                )
            }

            XCTAssertEqual(session.items.last?.kind, .toolResult)
            return try XCTUnwrap(recorder.snapshot())
        }

        func testLongActiveCrawlFinalTurnRefreshBenchmarkReport() async throws {
            try XCTSkipUnless(
                ProcessInfo.processInfo.environment["RP_RUN_TRANSCRIPT_METRICS"] == "1"
                    || ProcessInfo.processInfo.environment["RP_CE_TRANSCRIPT_CRAWL_REFRESH_REPORT_PATH"] != nil
                    || FileManager.default.fileExists(atPath: crawlTranscriptRefreshOptInFlagURL().path),
                "CE crawl transcript refresh benchmark is opt-in. Set RP_RUN_TRANSCRIPT_METRICS=1, RP_CE_TRANSCRIPT_CRAWL_REFRESH_REPORT_PATH, or create /tmp/RepoPromptCE-crawl-transcript-refresh-opt-in."
            )

            let recorder = TranscriptInstrumentationRecorder()
            AgentTranscriptDebugInstrumentation.reset()
            AgentTranscriptDebugInstrumentation.isEnabled = true
            AgentTranscriptDebugInstrumentation.protectedTailScanHandler = { recorder.record($0) }
            AgentTranscriptDebugInstrumentation.compactionHandler = { recorder.record($0) }
            AgentTranscriptDebugInstrumentation.workingSourceItemsHandler = { recorder.record($0) }
            AgentTranscriptDebugInstrumentation.rebuildHandler = { recorder.record($0) }
            AgentTranscriptDebugInstrumentation.projectionBuildHandler = { recorder.record($0) }
            AgentTranscriptDebugInstrumentation.refreshAttemptHandler = { recorder.record($0) }
            AgentTranscriptDebugInstrumentation.presentationPublishHandler = { recorder.record($0) }
            AgentTranscriptDebugInstrumentation.sessionItemsReplacementHandler = { recorder.record($0) }
            AgentTranscriptDebugInstrumentation.projectionIdentityHandler = { recorder.record($0) }
            defer { AgentTranscriptDebugInstrumentation.reset() }

            let config = CrawlRefreshScenarioConfig()
            let aggregate = try await runCrawlRefreshBenchmark(config: config, recorder: recorder)
            let reportURL = crawlTranscriptRefreshReportURL()
            let benchmarkJSON = try crawlRefreshBenchmarkJSON(aggregate, reportURL: reportURL)
            let reportText = formatCrawlRefreshBenchmarkReport(aggregate, reportURL: reportURL, benchmarkJSON: benchmarkJSON)

            try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try reportText.write(to: reportURL, atomically: true, encoding: .utf8)
            print(reportText)
            print("REPOPROMPT_CE_CRAWL_TRANSCRIPT_REFRESH_BENCHMARK_JSON=\(benchmarkJSON)")
        }

        private struct CrawlRefreshScenarioConfig {
            let scenarioName = "long_active_final_turn_replace_tail_40x24KiB_raw_tools"
            let toolResultPairCount = 40
            let minimumPayloadBytes = 24 * 1024
            let measuredSampleCount = 9
            let warmupSampleCount = 1
        }

        private struct CrawlRefreshSeed {
            let items: [AgentChatItem]
            let representativeToolResultID: UUID
            let representativeMarker: String
        }

        private struct CrawlRefreshBenchmarkSample {
            let ordinal: Int
            let phase: String
            let mutationWallClockMS: Double
            let refreshMS: Double
            let importMS: Double?
            let incrementalImportMS: Double?
            let sanitizeMS: Double?
            let projectionMS: Double?
            let payloadCaptureMS: Double?
            let sanitizedActivityCount: Int?
            let sourceItemsRevision: Int
            let itemCount: Int
            let transcriptTurnCount: Int
            let rawToolResultBytesInItems: Int
            let ephemeralPayloadBytes: Int
            let retainedPayloadEntryCount: Int
            let retainedPayloadBytesFromSnapshot: Int
            let toolProcessingMetrics: AgentToolResultProcessingMetrics
            let incrementalImportAttempts: Int
            let incrementalImportSuccesses: Int
            let incrementalImportFallbacks: Int
            let refreshAttemptCount: Int
            let rebuildCount: Int
            let projectionBuildCount: Int
            let sessionItemReplacementCount: Int
            let compactionCount: Int
            let presentationPublishCount: Int
        }

        private struct CrawlRefreshBenchmarkAggregate {
            let scenario: String
            let config: CrawlRefreshScenarioConfig
            let warmup: CrawlRefreshBenchmarkSample
            let measured: [CrawlRefreshBenchmarkSample]
            let trimmedRefreshMS: [Double]
            let trimmedMedianRefreshMS: Double
            let trimmedP95RefreshMS: Double
            let trimmedMutationMedianMS: Double
            let trimmedMutationP95MS: Double
        }

        private struct TranscriptPerformanceDelta {
            let incrementalImportAttemptCount: Int
            let incrementalImportSuccessCount: Int
            let incrementalImportFallbackCount: Int
        }

        @MainActor
        private func runCrawlRefreshBenchmark(
            config: CrawlRefreshScenarioConfig,
            recorder: TranscriptInstrumentationRecorder
        ) async throws -> CrawlRefreshBenchmarkAggregate {
            let viewModel = makeViewModel()
            let tabID = UUID()
            viewModel.test_setCurrentTabIDOverride(tabID)
            defer { viewModel.test_setCurrentTabIDOverride(nil) }

            let session = await viewModel.ensureSessionReady(tabID: tabID)
            let seed = try makeLongActiveCrawlFinalTurnItems(config: config)
            defer {
                session.saveDebounceTask?.cancel()
                session.saveDebounceTask = nil
                session.derivedTranscriptRefreshTask?.cancel()
                session.derivedTranscriptRefreshTask = nil
            }

            session.selectedAgent = .codexExec
            session.runState = .running
            session.setItemsSilently(seed.items, reason: .testOverride)
            viewModel.refreshDerivedTranscriptState(for: session)
            viewModel.applySessionToBindings(session)
            await viewModel.test_drainScheduledDerivedTranscriptRefresh(tabID: tabID)

            XCTAssertEqual(session.runState, .running)
            XCTAssertEqual(session.items.count, seed.items.count)
            XCTAssertFalse(session.transcriptProjection.workingRows.isEmpty)
            let initialRawPayload = try XCTUnwrap(viewModel.rawToolResultPayloadForRendering(tabID: tabID, itemID: seed.representativeToolResultID))
            XCTAssertTrue(initialRawPayload.contains(seed.representativeMarker))
            let representativeSourceItem = try XCTUnwrap(session.items.first(where: { $0.id == seed.representativeToolResultID }))
            XCTAssertTrue(AgentTranscriptToolNormalizer.isSummaryOnly(raw: representativeSourceItem.toolResultJSON ?? ""))

            let presentationMark = recorder.mark()
            let fullBindingSyncCount = viewModel.test_updateBindingsCallCount
            viewModel.enqueueAssistantDelta("\nCE_CRAWL_PRESENTATION_ONLY_PREFLIGHT", session: session)
            viewModel.flushPendingAssistantDelta(session)
            viewModel.test_flushPendingUIRefresh()
            let presentationMetrics = recorder.slice(since: presentationMark)
            XCTAssertEqual(presentationMetrics.presentationPublishes.count, 1)
            XCTAssertEqual(viewModel.test_updateBindingsCallCount, fullBindingSyncCount)

            session.setItemsSilently(seed.items, reason: .testOverride)
            viewModel.refreshDerivedTranscriptState(for: session)
            viewModel.applySessionToBindings(session)
            await viewModel.test_drainScheduledDerivedTranscriptRefresh(tabID: tabID)

            var warmups: [CrawlRefreshBenchmarkSample] = []
            for ordinal in 1 ... config.warmupSampleCount {
                try await warmups.append(runCrawlRefreshBenchmarkSample(
                    viewModel: viewModel,
                    session: session,
                    seed: seed,
                    expectedItemCount: seed.items.count,
                    ordinal: ordinal,
                    phase: "warmup",
                    recorder: recorder
                ))
            }

            var measured: [CrawlRefreshBenchmarkSample] = []
            for ordinal in 1 ... config.measuredSampleCount {
                try await measured.append(runCrawlRefreshBenchmarkSample(
                    viewModel: viewModel,
                    session: session,
                    seed: seed,
                    expectedItemCount: seed.items.count,
                    ordinal: ordinal,
                    phase: "measured",
                    recorder: recorder
                ))
            }

            let trimmedSamples = trimmedRefreshSamples(measured)
            let trimmedRefreshMS = trimmedSamples.map(\.refreshMS)
            let trimmedMutationMS = trimmedSamples.map(\.mutationWallClockMS)
            return try CrawlRefreshBenchmarkAggregate(
                scenario: config.scenarioName,
                config: config,
                warmup: XCTUnwrap(warmups.first),
                measured: measured,
                trimmedRefreshMS: trimmedRefreshMS,
                trimmedMedianRefreshMS: median(trimmedRefreshMS),
                trimmedP95RefreshMS: nearestRankP95(trimmedRefreshMS),
                trimmedMutationMedianMS: median(trimmedMutationMS),
                trimmedMutationP95MS: nearestRankP95(trimmedMutationMS)
            )
        }

        @MainActor
        private func runCrawlRefreshBenchmarkSample(
            viewModel: AgentModeViewModel,
            session: AgentModeViewModel.TabSession,
            seed: CrawlRefreshSeed,
            expectedItemCount: Int,
            ordinal: Int,
            phase: String,
            recorder: TranscriptInstrumentationRecorder
        ) async throws -> CrawlRefreshBenchmarkSample {
            let trailingIndex = expectedItemCount - 1
            let previousAssistant = try XCTUnwrap(session.items.indices.contains(trailingIndex) ? session.items[trailingIndex] : nil)
            let replacementText = "CE_CRAWL_REFRESH_REPLACEMENT_\(phase)_\(ordinal)"
            let replacement = AgentChatItem(
                id: previousAssistant.id,
                timestamp: previousAssistant.timestamp,
                kind: .assistant,
                text: replacementText,
                sequenceIndex: previousAssistant.sequenceIndex
            )
            let beforePerformance = session.transcriptPerformanceSnapshot
            let mark = recorder.mark()
            let start = DispatchTime.now().uptimeNanoseconds
            session.replaceItem(at: trailingIndex, with: replacement)
            await viewModel.test_drainScheduledDerivedTranscriptRefresh(tabID: session.tabID)
            let elapsedMS = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            let metrics = recorder.slice(since: mark)
            let snapshot = session.transcriptPerformanceSnapshot
            let refreshMS = try XCTUnwrap(snapshot.lastRefreshTotalDurationMS)

            XCTAssertEqual(session.runState, .running)
            XCTAssertEqual(session.items.count, expectedItemCount)
            XCTAssertTrue(session.transcriptProjection.workingRows.contains { $0.id == replacement.id && $0.text.contains(replacementText) })
            let rawPayload = try XCTUnwrap(viewModel.rawToolResultPayloadForRendering(tabID: session.tabID, itemID: seed.representativeToolResultID))
            XCTAssertTrue(rawPayload.contains(seed.representativeMarker))
            XCTAssertNil(session.derivedTranscriptRefreshTask)
            XCTAssertFalse(session.transcriptProjection.workingRows.isEmpty)

            let representativeSourceItem = try XCTUnwrap(session.items.first(where: { $0.id == seed.representativeToolResultID }))
            XCTAssertTrue(AgentTranscriptToolNormalizer.isSummaryOnly(raw: representativeSourceItem.toolResultJSON ?? ""))
            XCTAssertFalse(representativeSourceItem.toolResultJSON?.contains(seed.representativeMarker) ?? false)

            let delta = performanceDelta(from: beforePerformance, to: snapshot)
            return CrawlRefreshBenchmarkSample(
                ordinal: ordinal,
                phase: phase,
                mutationWallClockMS: elapsedMS,
                refreshMS: refreshMS,
                importMS: snapshot.lastImportDurationMS,
                incrementalImportMS: snapshot.lastIncrementalImportDurationMS,
                sanitizeMS: snapshot.lastSanitizeDurationMS,
                projectionMS: snapshot.lastProjectionBuildDurationMS,
                payloadCaptureMS: snapshot.lastPayloadCaptureDurationMS,
                sanitizedActivityCount: snapshot.lastSanitizedActivityCount,
                sourceItemsRevision: session.sourceItemsRevision,
                itemCount: session.items.count,
                transcriptTurnCount: session.transcript.turns.count,
                rawToolResultBytesInItems: rawToolResultBytes(in: session.items),
                ephemeralPayloadBytes: ephemeralPayloadBytes(in: session),
                retainedPayloadEntryCount: snapshot.retainedRawPayloadEntryCount,
                retainedPayloadBytesFromSnapshot: snapshot.retainedRawPayloadTotalBytes,
                toolProcessingMetrics: snapshot.lastToolProcessingMetrics,
                incrementalImportAttempts: delta.incrementalImportAttemptCount,
                incrementalImportSuccesses: delta.incrementalImportSuccessCount,
                incrementalImportFallbacks: delta.incrementalImportFallbackCount,
                refreshAttemptCount: metrics.refreshAttempts.count,
                rebuildCount: metrics.rebuilds.count,
                projectionBuildCount: metrics.projectionBuilds.count,
                sessionItemReplacementCount: metrics.sessionItemsReplacements.count,
                compactionCount: metrics.compactions.count,
                presentationPublishCount: metrics.presentationPublishes.count
            )
        }

        private func makeLongActiveCrawlFinalTurnItems(config: CrawlRefreshScenarioConfig) throws -> CrawlRefreshSeed {
            var sequenceIndex = 0
            var items: [AgentChatItem] = [AgentChatItem.user("Run a long active crawl and keep refreshing the transcript.", sequenceIndex: sequenceIndex)]
            sequenceIndex += 1
            let toolCycle = ["apply_patch", "apply_edits", "bash"]
            var representativeID: UUID?
            var representativeMarker: String?
            for ordinal in 0 ..< config.toolResultPairCount {
                let toolName = toolCycle[ordinal % toolCycle.count]
                let marker = "CE_CRAWL_REFRESH_RAW_PAYLOAD_MARKER_\(ordinal)"
                let invocationID = UUID()
                items.append(AgentChatItem.toolCall(
                    name: toolName,
                    invocationID: invocationID,
                    argsJSON: crawlRefreshToolArgsJSON(toolName: toolName, ordinal: ordinal),
                    sequenceIndex: sequenceIndex
                ))
                sequenceIndex += 1
                let payload = try crawlRefreshToolResultJSON(
                    toolName: toolName,
                    ordinal: ordinal,
                    marker: marker,
                    minimumPayloadBytes: config.minimumPayloadBytes
                )
                let result = AgentChatItem.toolResult(
                    name: toolName,
                    invocationID: invocationID,
                    resultJSON: payload,
                    isError: false,
                    sequenceIndex: sequenceIndex
                )
                if representativeID == nil {
                    representativeID = result.id
                    representativeMarker = marker
                }
                items.append(result)
                sequenceIndex += 1
            }
            items.append(AgentChatItem.assistant("CE_CRAWL_REFRESH_INITIAL_TAIL", sequenceIndex: sequenceIndex))
            return try CrawlRefreshSeed(
                items: items,
                representativeToolResultID: XCTUnwrap(representativeID),
                representativeMarker: XCTUnwrap(representativeMarker)
            )
        }

        private func crawlRefreshToolArgsJSON(toolName: String, ordinal: Int) -> String {
            switch toolName {
            case "apply_patch":
                #"{"patch":"*** Begin Patch\n*** Update File: Crawl.swift\n@@\n- old\n+ new\n*** End Patch"}"#
            case "apply_edits":
                #"{"path":"Crawl.swift","edits":[{"search":"old","replace":"new"}]}"#
            case "bash":
                #"{"cmd":"printf crawl-refresh"}"#
            default:
                #"{"ordinal":\#(ordinal)}"#
            }
        }

        private func crawlRefreshToolResultJSON(
            toolName: String,
            ordinal: Int,
            marker: String,
            minimumPayloadBytes: Int
        ) throws -> String {
            let diff = "@@ -1,3 +1,3 @@\n- old crawl line \(ordinal)\n+ new crawl line \(ordinal) \(marker)\n"
            var payload: [String: Any] = switch toolName {
            case "apply_patch":
                ["status": "success", "marker": marker, "changes": [["path": "Sources/Crawl\(ordinal).swift", "diff": diff]]]
            case "apply_edits":
                ["status": "success", "marker": marker, "path": "Sources/Crawl\(ordinal).swift", "card_unified_diff": diff, "edits": [["path": "Sources/Crawl\(ordinal).swift", "card_unified_diff": diff]]]
            case "bash":
                ["status": "success", "marker": marker, "stdout": "crawl bash output \(marker)\n", "stderr": "", "metadata": ["exit_code": 0, "duration_ms": 12, "command": "printf crawl-refresh"]]
            default:
                ["status": "success", "marker": marker]
            }
            var paddingBytes = minimumPayloadBytes
            while true {
                payload["padding"] = String(repeating: "\(marker)-payload-line-\(ordinal)\n", count: max(1, paddingBytes / 48))
                let json = try jsonString(payload)
                if json.utf8.count >= minimumPayloadBytes {
                    return json
                }
                paddingBytes += minimumPayloadBytes / 2
            }
        }

        @MainActor
        private func makeViewModel() -> AgentModeViewModel {
            let viewModel = AgentModeViewModel(
                testWindowID: 1,
                testWorkspacePath: FileManager.default.currentDirectoryPath,
                codexControllerFactory: { _, _, _, _, _, _ in CrawlRefreshFakeCodexController() }
            )
            viewModel.test_setAllowsScheduledDerivedTranscriptRefreshWithoutPromptManager(true)
            return viewModel
        }

        private func jsonString(_ payload: [String: Any]) throws -> String {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            return String(data: data, encoding: .utf8) ?? "{}"
        }

        private func rawToolResultBytes(in items: [AgentChatItem]) -> Int {
            items.reduce(0) { partial, item in
                guard item.kind == .toolResult else { return partial }
                return partial + (item.toolResultJSON?.utf8.count ?? 0)
            }
        }

        @MainActor
        private func ephemeralPayloadBytes(in session: AgentModeViewModel.TabSession) -> Int {
            session.ephemeralToolResultPayloadByItemID.values.reduce(0) { $0 + $1.utf8.count }
        }

        private func trimmedRefreshSamples(_ samples: [CrawlRefreshBenchmarkSample]) -> [CrawlRefreshBenchmarkSample] {
            let sorted = samples.sorted { $0.refreshMS < $1.refreshMS }
            guard sorted.count > 2 else { return sorted }
            return Array(sorted.dropFirst().dropLast())
        }

        private func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { return 0 }
            let midpoint = sorted.count / 2
            if sorted.count.isMultiple(of: 2) {
                return (sorted[midpoint - 1] + sorted[midpoint]) / 2
            }
            return sorted[midpoint]
        }

        private func nearestRankP95(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { return 0 }
            let rank = max(1, Int(ceil(Double(sorted.count) * 0.95)))
            return sorted[min(sorted.count - 1, rank - 1)]
        }

        private func performanceDelta(
            from before: AgentTranscriptPerformanceSnapshot,
            to after: AgentTranscriptPerformanceSnapshot
        ) -> TranscriptPerformanceDelta {
            TranscriptPerformanceDelta(
                incrementalImportAttemptCount: after.incrementalImportAttemptCount - before.incrementalImportAttemptCount,
                incrementalImportSuccessCount: after.incrementalImportSuccessCount - before.incrementalImportSuccessCount,
                incrementalImportFallbackCount: after.incrementalImportFallbackCount - before.incrementalImportFallbackCount
            )
        }

        private func formatMS(_ value: Double?) -> String {
            guard let value else { return "nil" }
            return String(format: "%.3f", value)
        }

        private func formatCrawlRefreshBenchmarkReport(
            _ aggregate: CrawlRefreshBenchmarkAggregate,
            reportURL: URL,
            benchmarkJSON: String
        ) -> String {
            var lines = [
                "REPOPROMPT_CE_CRAWL_TRANSCRIPT_REFRESH_BENCHMARK_BEGIN",
                "scenario=\(aggregate.scenario)",
                "reportPath=\(reportURL.path)",
                "shape=toolPairs:\(aggregate.config.toolResultPairCount) minPayloadBytes:\(aggregate.config.minimumPayloadBytes) warmup:\(aggregate.config.warmupSampleCount) measured:\(aggregate.config.measuredSampleCount)",
                "trimmedRefreshMS=\(aggregate.trimmedRefreshMS.map { formatMS($0) }.joined(separator: ","))",
                "trimmedMedianRefreshMS=\(formatMS(aggregate.trimmedMedianRefreshMS)) trimmedP95RefreshMS=\(formatMS(aggregate.trimmedP95RefreshMS)) trimmedMutationMedianMS=\(formatMS(aggregate.trimmedMutationMedianMS)) trimmedMutationP95MS=\(formatMS(aggregate.trimmedMutationP95MS))",
                "",
                "| Phase | Sample | Refresh ms | Mutation wall ms | Import ms | Sanitize ms | Projection ms | Payload ms | Raw item bytes | Ephemeral bytes | JSON parse bytes | JSON misses | Regex calls | Incremental a/s/f | Refresh/Rebuild/Projection |",
                "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | --- |"
            ]
            lines.append(formatCrawlRefreshSampleRow(aggregate.warmup))
            lines.append(contentsOf: aggregate.measured.map(formatCrawlRefreshSampleRow))
            lines.append(contentsOf: [
                "",
                "REPOPROMPT_CE_CRAWL_TRANSCRIPT_REFRESH_BENCHMARK_JSON=\(benchmarkJSON)",
                "REPOPROMPT_CE_CRAWL_TRANSCRIPT_REFRESH_BENCHMARK_END"
            ])
            return lines.joined(separator: "\n")
        }

        private func formatCrawlRefreshSampleRow(_ sample: CrawlRefreshBenchmarkSample) -> String {
            let metrics = sample.toolProcessingMetrics
            return [
                "| \(sample.phase)",
                "\(sample.ordinal)",
                formatMS(sample.refreshMS),
                formatMS(sample.mutationWallClockMS),
                formatMS(sample.importMS),
                formatMS(sample.sanitizeMS),
                formatMS(sample.projectionMS),
                formatMS(sample.payloadCaptureMS),
                "\(sample.rawToolResultBytesInItems)",
                "\(sample.ephemeralPayloadBytes)",
                "\(metrics.jsonParseByteCount)",
                "\(metrics.jsonParseCacheMissCount)",
                "\(metrics.regexCaptureCallCount)",
                "\(sample.incrementalImportAttempts)/\(sample.incrementalImportSuccesses)/\(sample.incrementalImportFallbacks)",
                "\(sample.refreshAttemptCount)/\(sample.rebuildCount)/\(sample.projectionBuildCount) |"
            ].joined(separator: " | ")
        }

        private func crawlRefreshBenchmarkJSON(_ aggregate: CrawlRefreshBenchmarkAggregate, reportURL: URL) throws -> String {
            let payload: [String: Any] = [
                "scenario": aggregate.scenario,
                "reportPath": reportURL.path,
                "toolResultPairCount": aggregate.config.toolResultPairCount,
                "minimumPayloadBytes": aggregate.config.minimumPayloadBytes,
                "warmupSampleCount": aggregate.config.warmupSampleCount,
                "measuredSampleCount": aggregate.config.measuredSampleCount,
                "rawMeasuredRefreshMS": aggregate.measured.map(\.refreshMS),
                "trimmedRefreshMS": aggregate.trimmedRefreshMS,
                "trimmedMedianRefreshMS": aggregate.trimmedMedianRefreshMS,
                "trimmedP95RefreshMS": aggregate.trimmedP95RefreshMS,
                "trimmedMutationMedianMS": aggregate.trimmedMutationMedianMS,
                "trimmedMutationP95MS": aggregate.trimmedMutationP95MS,
                "warmup": crawlRefreshSampleDictionary(aggregate.warmup),
                "measured": aggregate.measured.map(crawlRefreshSampleDictionary),
                "correctnessStatus": "passed"
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            return String(data: data, encoding: .utf8) ?? "{}"
        }

        private func crawlRefreshSampleDictionary(_ sample: CrawlRefreshBenchmarkSample) -> [String: Any] {
            let metrics = sample.toolProcessingMetrics
            return [
                "ordinal": sample.ordinal,
                "phase": sample.phase,
                "mutationWallClockMS": sample.mutationWallClockMS,
                "refreshMS": sample.refreshMS,
                "importMS": optionalJSONValue(sample.importMS),
                "incrementalImportMS": optionalJSONValue(sample.incrementalImportMS),
                "sanitizeMS": optionalJSONValue(sample.sanitizeMS),
                "projectionMS": optionalJSONValue(sample.projectionMS),
                "payloadCaptureMS": optionalJSONValue(sample.payloadCaptureMS),
                "sanitizedActivityCount": optionalJSONValue(sample.sanitizedActivityCount),
                "sourceItemsRevision": sample.sourceItemsRevision,
                "itemCount": sample.itemCount,
                "transcriptTurnCount": sample.transcriptTurnCount,
                "rawToolResultBytesInItems": sample.rawToolResultBytesInItems,
                "ephemeralPayloadBytes": sample.ephemeralPayloadBytes,
                "retainedPayloadEntryCount": sample.retainedPayloadEntryCount,
                "retainedPayloadBytesFromSnapshot": sample.retainedPayloadBytesFromSnapshot,
                "incrementalImportAttempts": sample.incrementalImportAttempts,
                "incrementalImportSuccesses": sample.incrementalImportSuccesses,
                "incrementalImportFallbacks": sample.incrementalImportFallbacks,
                "refreshAttemptCount": sample.refreshAttemptCount,
                "rebuildCount": sample.rebuildCount,
                "projectionBuildCount": sample.projectionBuildCount,
                "sessionItemReplacementCount": sample.sessionItemReplacementCount,
                "compactionCount": sample.compactionCount,
                "presentationPublishCount": sample.presentationPublishCount,
                "toolProcessingMetrics": [
                    "jsonParseAttemptCount": metrics.jsonParseAttemptCount,
                    "jsonParseCacheHitCount": metrics.jsonParseCacheHitCount,
                    "jsonParseCacheMissCount": metrics.jsonParseCacheMissCount,
                    "jsonParseSuccessCount": metrics.jsonParseSuccessCount,
                    "jsonParseFailureCount": metrics.jsonParseFailureCount,
                    "jsonParseByteCount": metrics.jsonParseByteCount,
                    "toolExecutionCacheHitCount": metrics.toolExecutionCacheHitCount,
                    "toolExecutionCacheMissCount": metrics.toolExecutionCacheMissCount,
                    "bashMetadataCacheHitCount": metrics.bashMetadataCacheHitCount,
                    "bashMetadataCacheMissCount": metrics.bashMetadataCacheMissCount,
                    "regexCaptureCallCount": metrics.regexCaptureCallCount
                ]
            ]
        }

        private func optionalJSONValue(_ value: Double?) -> Any {
            value ?? NSNull()
        }

        private func optionalJSONValue(_ value: Int?) -> Any {
            value ?? NSNull()
        }

        private func crawlTranscriptRefreshReportURL() -> URL {
            if let overridePath = ProcessInfo.processInfo.environment["RP_CE_TRANSCRIPT_CRAWL_REFRESH_REPORT_PATH"], !overridePath.isEmpty {
                return URL(fileURLWithPath: overridePath)
            }
            if let overridePath = try? String(contentsOf: crawlTranscriptRefreshReportPathFlagURL(), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !overridePath.isEmpty
            {
                return URL(fileURLWithPath: overridePath)
            }
            return FileManager.default.temporaryDirectory.appendingPathComponent("RepoPromptCE-crawl-transcript-refresh-latest.md")
        }

        private func crawlTranscriptRefreshOptInFlagURL() -> URL {
            URL(fileURLWithPath: "/tmp/RepoPromptCE-crawl-transcript-refresh-opt-in")
        }

        private func crawlTranscriptRefreshReportPathFlagURL() -> URL {
            URL(fileURLWithPath: "/tmp/RepoPromptCE-crawl-transcript-refresh-report-path")
        }
    }

    private struct TranscriptInstrumentationMark {
        let protectedTailScanCount: Int
        let compactionCount: Int
        let workingSourceItemsCount: Int
        let rebuildCount: Int
        let projectionBuildCount: Int
        let refreshAttemptCount: Int
        let presentationPublishCount: Int
        let sessionItemsReplacementCount: Int
        let projectionIdentityCount: Int
    }

    private struct TranscriptInstrumentationSlice {
        let protectedTailScans: [AgentTranscriptProtectedTailScanMetrics]
        let compactions: [AgentTranscriptCompactionMetrics]
        let workingSourceItems: [AgentTranscriptWorkingSourceItemsMetrics]
        let rebuilds: [AgentTranscriptRebuildMetrics]
        let projectionBuilds: [AgentTranscriptProjectionBuildMetrics]
        let refreshAttempts: [AgentTranscriptRefreshAttemptMetrics]
        let presentationPublishes: [AgentTranscriptPresentationPublishMetrics]
        let sessionItemsReplacements: [AgentTranscriptSessionItemsReplacementMetrics]
        let projectionIdentities: [AgentTranscriptProjectionIdentityMetrics]
    }

    private final class TranscriptInstrumentationRecorder {
        private let lock = NSLock()
        private var protectedTailScans: [AgentTranscriptProtectedTailScanMetrics] = []
        private var compactions: [AgentTranscriptCompactionMetrics] = []
        private var workingSourceItems: [AgentTranscriptWorkingSourceItemsMetrics] = []
        private var rebuilds: [AgentTranscriptRebuildMetrics] = []
        private var projectionBuilds: [AgentTranscriptProjectionBuildMetrics] = []
        private var refreshAttempts: [AgentTranscriptRefreshAttemptMetrics] = []
        private var presentationPublishes: [AgentTranscriptPresentationPublishMetrics] = []
        private var sessionItemsReplacements: [AgentTranscriptSessionItemsReplacementMetrics] = []
        private var projectionIdentities: [AgentTranscriptProjectionIdentityMetrics] = []

        func record(_ metrics: AgentTranscriptProtectedTailScanMetrics) {
            append(metrics, to: &protectedTailScans)
        }

        func record(_ metrics: AgentTranscriptCompactionMetrics) {
            append(metrics, to: &compactions)
        }

        func record(_ metrics: AgentTranscriptWorkingSourceItemsMetrics) {
            append(metrics, to: &workingSourceItems)
        }

        func record(_ metrics: AgentTranscriptRebuildMetrics) {
            append(metrics, to: &rebuilds)
        }

        func record(_ metrics: AgentTranscriptProjectionBuildMetrics) {
            append(metrics, to: &projectionBuilds)
        }

        func record(_ metrics: AgentTranscriptRefreshAttemptMetrics) {
            append(metrics, to: &refreshAttempts)
        }

        func record(_ metrics: AgentTranscriptPresentationPublishMetrics) {
            append(metrics, to: &presentationPublishes)
        }

        func record(_ metrics: AgentTranscriptSessionItemsReplacementMetrics) {
            append(metrics, to: &sessionItemsReplacements)
        }

        func record(_ metrics: AgentTranscriptProjectionIdentityMetrics) {
            append(metrics, to: &projectionIdentities)
        }

        func mark() -> TranscriptInstrumentationMark {
            lock.lock()
            defer { lock.unlock() }
            return .init(
                protectedTailScanCount: protectedTailScans.count,
                compactionCount: compactions.count,
                workingSourceItemsCount: workingSourceItems.count,
                rebuildCount: rebuilds.count,
                projectionBuildCount: projectionBuilds.count,
                refreshAttemptCount: refreshAttempts.count,
                presentationPublishCount: presentationPublishes.count,
                sessionItemsReplacementCount: sessionItemsReplacements.count,
                projectionIdentityCount: projectionIdentities.count
            )
        }

        func slice(since mark: TranscriptInstrumentationMark) -> TranscriptInstrumentationSlice {
            lock.lock()
            defer { lock.unlock() }
            return .init(
                protectedTailScans: Array(protectedTailScans.dropFirst(mark.protectedTailScanCount)),
                compactions: Array(compactions.dropFirst(mark.compactionCount)),
                workingSourceItems: Array(workingSourceItems.dropFirst(mark.workingSourceItemsCount)),
                rebuilds: Array(rebuilds.dropFirst(mark.rebuildCount)),
                projectionBuilds: Array(projectionBuilds.dropFirst(mark.projectionBuildCount)),
                refreshAttempts: Array(refreshAttempts.dropFirst(mark.refreshAttemptCount)),
                presentationPublishes: Array(presentationPublishes.dropFirst(mark.presentationPublishCount)),
                sessionItemsReplacements: Array(sessionItemsReplacements.dropFirst(mark.sessionItemsReplacementCount)),
                projectionIdentities: Array(projectionIdentities.dropFirst(mark.projectionIdentityCount))
            )
        }

        private func append<T>(_ value: T, to array: inout [T]) {
            lock.lock()
            array.append(value)
            lock.unlock()
        }
    }

    private final class CrawlRefreshFakeCodexController: CodexSessionControllerTurnDispatchTestDefaults {
        var hasActiveThread = false
        var events: AsyncStream<CodexNativeSessionController.Event> {
            AsyncStream { continuation in continuation.finish() }
        }

        func ensureEventsStreamReady() {}

        func startOrResume(existing _: CodexNativeSessionController.SessionRef?, baseInstructions _: String) async throws -> CodexNativeSessionController.SessionRef {
            hasActiveThread = true
            return CodexNativeSessionController.SessionRef(conversationID: "ce-crawl-refresh", rolloutPath: nil, model: nil, reasoningEffort: nil)
        }

        func startOrResume(existing _: CodexNativeSessionController.SessionRef?, baseInstructions _: String, model: String?, reasoningEffort: String?) async throws -> CodexNativeSessionController.SessionRef {
            hasActiveThread = true
            return CodexNativeSessionController.SessionRef(conversationID: "ce-crawl-refresh", rolloutPath: nil, model: model, reasoningEffort: reasoningEffort)
        }

        func startOrResume(existing _: CodexNativeSessionController.SessionRef?, baseInstructions _: String, model: String?, reasoningEffort: String?, serviceTier _: String?) async throws -> CodexNativeSessionController.SessionRef {
            hasActiveThread = true
            return CodexNativeSessionController.SessionRef(conversationID: "ce-crawl-refresh", rolloutPath: nil, model: model, reasoningEffort: reasoningEffort)
        }

        func readThreadSnapshot(includeTurns _: Bool, timeout _: TimeInterval?) async throws -> CodexNativeSessionController.ThreadSnapshot {
            CodexNativeSessionController.ThreadSnapshot(
                conversationID: "ce-crawl-refresh",
                rolloutPath: nil,
                model: nil,
                reasoningEffort: nil,
                runtimeStatus: .idle,
                currentTurnID: nil,
                activeTurnIDs: [],
                latestTurnStatus: nil
            )
        }

        func setThreadName(_: String, threadID _: String?) async throws {}
        func compactThread() async throws {}
        func getThreadGoal() async throws -> CodexNativeSessionController.ThreadGoal? {
            nil
        }

        func setThreadGoalObjective(_: String) async throws -> CodexNativeSessionController.ThreadGoal {
            throw CancellationError()
        }

        func setThreadGoalStatus(_: CodexNativeSessionController.ThreadGoalStatus) async throws -> CodexNativeSessionController.ThreadGoal {
            throw CancellationError()
        }

        func clearThreadGoal() async throws -> Bool {
            false
        }

        func cancelCurrentTurn() async {}
        func shutdown() async {
            hasActiveThread = false
        }

        func respondToServerRequest(id _: CodexAppServerRequestID, result _: [String: Any]) async {}
    }
#endif
