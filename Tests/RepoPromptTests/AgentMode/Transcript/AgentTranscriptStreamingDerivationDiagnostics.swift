#if DEBUG
    import Foundation
    @testable import RepoPromptApp
    import XCTest

    /// Opt-in fake benchmark with advisory budgets, never an XCTest latency gate.
    /// The direct synchronous consumer differs from the scheduled A/B driver recorded in
    /// prompt-exports/optimize-streaming-transcript-runs.md.
    @MainActor
    final class AgentTranscriptStreamingDerivationDiagnostics: XCTestCase {
        private enum FixtureError: Error, Equatable { case drainLimit, missingRefresh, debugInstrumentationEnabled }
        private var ownedFixtures: [Fixture] = []

        override func tearDown() async throws {
            for fixture in ownedFixtures {
                await fixture.close()
            }
            ownedFixtures = []
            try await super.tearDown()
        }

        private func close(_ fixture: Fixture) async {
            await fixture.close()
            ownedFixtures.removeAll { $0 === fixture }
        }

        private static func id(_ value: Int) -> UUID {
            UUID(uuidString: String(format: "00000000-0000-4000-8000-%012x", value))!
        }

        private static func item(_ ordinal: Int, stream: Int, kind: AgentChatItemKind, call: Int = 0, tool: String? = nil) -> AgentChatItem {
            let names = ["read_file", "file_search", "apply_edits", "bash"]
            let name = tool ?? names[call % names.count]
            return AgentChatItem(
                id: id(100_000 + stream * 10000 + ordinal),
                timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(ordinal)),
                kind: kind, text: kind == .user ? "Fixture request \(ordinal)" : (kind == .assistant ? "Fixture answer \(ordinal)" : ""),
                toolName: kind == .toolCall || kind == .toolResult ? name : nil,
                toolInvocationID: kind == .toolCall || kind == .toolResult ? id(20_000_000 + stream * 10000 + call) : nil,
                toolArgsJSON: kind == .toolCall ? "{\"path\":\"Sources/Fixture\(call).swift\",\"limit\":40}" : nil,
                toolResultJSON: kind == .toolResult ? "{\"path\":\"Sources/Fixture\(call).swift\",\"content\":\"\(String(repeating: "fixture line;", count: 64))\"}" : nil,
                toolIsError: kind == .toolResult ? false : nil, sequenceIndex: ordinal
            )
        }

        @MainActor
        private final class Fixture {
            let vm: AgentModeViewModel
            let tabs: [ComposeTabState]
            let streams: [AgentModeViewModel.TabSession]
            let parent: AgentModeViewModel.TabSession?
            let children: [AgentModeViewModel.TabSession]

            init(sidebarCount: Int, streamCount: Int, childCount: Int, seedTurns: Int = 3, background: Bool = false, indexOnly: Bool = false) {
                vm = AgentModeViewModel(
                    testWindowID: -9917,
                    attachmentPersistenceIsSuppressed: { true },
                    codexControllerFactory: { _, _, _, _, _, _ in preconditionFailure("Fake benchmark cannot launch Codex") },
                    claudeControllerFactory: { _, _, _, _ in preconditionFailure("Fake benchmark cannot launch Claude") },
                    headlessProviderFactory: { _, _ in preconditionFailure("Fake benchmark cannot launch a provider") },
                    acpProviderFactory: { _, _ in preconditionFailure("Fake benchmark cannot launch ACP") },
                    acpControllerFactory: { _, _ in preconditionFailure("Fake benchmark cannot construct ACP") },
                    connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in preconditionFailure("No MCP policy work") },
                    mcpRunRoutingCleaner: { _, _, _ in }, mcpServerEnabler: { false }
                )
                vm.test_setSuppressesAgentSessionPersistence(true)
                vm.test_setAllowsScheduledDerivedTranscriptRefreshWithoutPromptManager(true)
                let ordinaryCount = max(sidebarCount, streamCount)
                let total = ordinaryCount + (childCount > 0 ? childCount + 1 : 0)
                tabs = (0 ..< total).map {
                    var tab = ComposeTabState(id: id(1 + $0), name: "Fixture \($0)", activeAgentSessionID: id(10000 + $0))
                    tab.lastModified = Date(timeIntervalSince1970: 1_700_000_000)
                    return tab
                }
                if indexOnly {
                    let workspace = WorkspaceModel(name: "Index fixture", repoPaths: [], ephemeralFlag: true, composeTabs: tabs)
                    let owner = AgentModeViewModel.SessionIndexOwner(workspaceID: workspace.id, activationEpoch: 1)
                    let entries = tabs.enumerated().map { index, tab in
                        AgentSessionIndexEntry(
                            id: tab.activeAgentSessionID!, tabID: tab.id, name: tab.name,
                            lastUserMessageAt: nil, savedAt: tab.lastModified, lastRunStateRaw: nil,
                            itemCount: 1, agentKindRaw: nil, agentModelRaw: nil, agentReasoningEffortRaw: nil,
                            autoEditEnabled: false, parentSessionID: index > ordinaryCount ? id(10000 + ordinaryCount) : nil,
                            hasUnknownConversationContent: false, isMCPOriginated: false,
                            worktreeBindingSummaries: [], activeWorktreeMergeSummaries: []
                        )
                    }
                    vm.test_installSessionIndexSnapshot(
                        Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) }),
                        owner: owner, latestOwner: owner, activeWorkspace: workspace
                    )
                }
                var live: [AgentModeViewModel.TabSession] = []
                for (index, tab) in tabs.enumerated() {
                    if indexOnly, index != ordinaryCount { continue }
                    let session = vm.session(for: tab.id)
                    _ = vm.test_installPersistentSessionBinding(sessionID: tab.activeAgentSessionID, on: session)
                    session.hasLoadedPersistedState = true
                    session.lastActivityAt = tab.lastModified
                    if index > ordinaryCount, childCount > 0 { session.parentSessionID = id(10000 + ordinaryCount) }
                    live.append(session)
                }
                streams = Array(live.prefix(streamCount))
                parent = childCount > 0 ? live[indexOnly ? 0 : ordinaryCount] : nil
                children = childCount > 0 && !indexOnly ? Array(live.suffix(childCount)) : []
                vm.test_setCurrentTabIDOverride(background ? id(99999) : tabs[0].id)
                for (stream, session) in streams.enumerated() {
                    var source: [AgentChatItem] = []
                    for turn in 0 ..< seedTurns {
                        source.append(item(source.count, stream: stream, kind: .user))
                        for call in 0 ..< 4 {
                            source.append(item(source.count, stream: stream, kind: .toolCall, call: turn * 4 + call))
                            source.append(item(source.count, stream: stream, kind: .toolResult, call: turn * 4 + call))
                        }
                        source.append(item(source.count, stream: stream, kind: .assistant))
                    }
                    source.append(item(source.count, stream: stream, kind: .user))
                    session.setItemsSilently(source, reason: .persistedSessionHydration)
                    session.runState = .running
                    vm.refreshDerivedTranscriptState(for: session, reason: .coldLoad)
                }
                if let parent {
                    parent.setItemsSilently([item(0, stream: 9, kind: .user)], reason: .persistedSessionHydration)
                    parent.runState = .running
                    vm.refreshDerivedTranscriptState(for: parent, reason: .coldLoad)
                }
                vm.syncSidebarUIState(refresh: true, reason: .runState, sidebarTabs: tabs)
            }

            func projection() -> AgentModeViewModel.SidebarListProjection {
                vm.sidebarListProjection(
                    workspaceID: nil, composeTabs: tabs, stashedTabs: [], currentTabID: vm.currentTabID,
                    sidebarSnapshot: vm.ui.sessionSidebar.snapshot, archivedSessionsExpanded: false,
                    showComposeTabsWithoutAgentSessions: true
                )
            }

            func close() async {
                await vm.prepareForWindowClose()
            }
        }

        private struct Samples {
            var mutationMS: [Double] = []
            var refreshMS: [Double] = []
            var sidebarLookupMS = 0.0
            var importMS = 0.0
            var incrementalMS = 0.0
            var payloadMS = 0.0
            var sanitizeMS = 0.0
            var projectionPrefixMS = 0.0
            var snapshotRefreshMS = 0.0
            var requests = 0
            var executed = 0
            var coalesced = 0
            var immediate = 0
            var attempts = 0
            var successes = 0
            var fallbacks = 0
            var frontierSuccesses = 0
            var frontierFallbacks = 0
            var maxYields = 0
        }

        private func elapsed(_ work: () -> Void) -> Double {
            XCTAssertTrue(Thread.isMainThread)
            let start = DispatchTime.now().uptimeNanoseconds
            work()
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        }

        private func drain(_ session: AgentModeViewModel.TabSession) async throws -> Int {
            for yields in 0 ..< 10000 {
                if session.derivedTranscriptRefreshTask == nil {
                    XCTAssertNil(session.pendingDerivedTranscriptRefreshReason)
                    XCTAssertNil(session.pendingSourceItemsMutationSummary)
                    return yields
                }
                await Task.yield()
            }
            XCTFail("Deterministic refresh drain exhausted")
            throw FixtureError.drainLimit
        }

        private func requireTranscriptInstrumentationDisabled() throws {
            guard !AgentTranscriptDebugInstrumentation.isEnabled else {
                throw FixtureError.debugInstrumentationEnabled
            }
        }

        private func drive(_ fixture: Fixture, calls: [Int], parent: Bool = false) async throws -> Samples {
            try requireTranscriptInstrumentationDisabled()
            var samples = Samples()
            let sessions = try parent ? [XCTUnwrap(fixture.parent)] : fixture.streams
            for call in 0 ..< (calls.max() ?? 0) {
                for (stream, session) in sessions.enumerated() where call < calls[stream] {
                    for kind in [AgentChatItemKind.toolCall, .toolResult, .assistant] {
                        let before = session.transcriptPerformanceSnapshot
                        let row = Self.item(session.nextSequenceIndex, stream: parent ? 9 : stream, kind: kind, call: 100 + call, tool: parent ? "agent_run" : nil)
                        samples.mutationMS.append(elapsed { session.appendItem(row) })
                        guard let scheduled = session.derivedTranscriptRefreshTask else {
                            throw FixtureError.missingRefresh
                        }
                        // Consume the pending mutation synchronously using the existing refresh seam.
                        // Waiting for the cancelled scheduled task is outside both measured intervals.
                        samples.refreshMS.append(elapsed {
                            fixture.vm.refreshDerivedTranscriptState(for: session, reason: .liveMutation)
                        })
                        await scheduled.value
                        samples.maxYields = try await max(samples.maxYields, drain(session))
                        XCTAssertNil(session.saveDebounceTask)
                        let after = session.transcriptPerformanceSnapshot
                        guard after.projectionBuildCount == before.projectionBuildCount + 1 else {
                            throw FixtureError.missingRefresh
                        }
                        samples.requests += after.refreshRequestCount - before.refreshRequestCount
                        samples.executed += after.projectionBuildCount - before.projectionBuildCount
                        samples.coalesced += after.refreshCoalescedCount - before.refreshCoalescedCount
                        samples.immediate += after.refreshImmediateCount - before.refreshImmediateCount
                        samples.attempts += after.incrementalImportAttemptCount - before.incrementalImportAttemptCount
                        samples.successes += after.incrementalImportSuccessCount - before.incrementalImportSuccessCount
                        samples.fallbacks += after.incrementalImportFallbackCount - before.incrementalImportFallbackCount
                        samples.frontierSuccesses += after.frontierReuseSuccessCount - before.frontierReuseSuccessCount
                        samples.frontierFallbacks += after.frontierReuseFallbackCount - before.frontierReuseFallbackCount
                        samples.importMS += after.lastImportDurationMS ?? 0
                        samples.incrementalMS += after.lastIncrementalImportDurationMS ?? 0
                        samples.payloadMS += after.lastPayloadCaptureDurationMS ?? 0
                        samples.sanitizeMS += after.lastSanitizeDurationMS ?? 0
                        samples.projectionPrefixMS += after.lastProjectionBuildDurationMS ?? 0
                        samples.snapshotRefreshMS += after.lastRefreshTotalDurationMS ?? 0
                        samples.sidebarLookupMS += elapsed { _ = fixture.projection() }
                    }
                }
            }
            XCTAssertEqual(samples.requests, samples.mutationMS.count)
            XCTAssertEqual(samples.executed, samples.mutationMS.count)
            XCTAssertEqual(samples.coalesced, 0)
            XCTAssertEqual(samples.immediate, 0)
            XCTAssertEqual(samples.successes + samples.fallbacks, samples.attempts)
            XCTAssertEqual(samples.attempts, samples.executed)
            return samples
        }

        private func quantile(_ values: [Double], _ p: Double) -> Double {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { return 0 }
            let index = Double(sorted.count - 1) * p
            let low = Int(index)
            return sorted[low] + (sorted[min(low + 1, sorted.count - 1)] - sorted[low]) * (index - Double(low))
        }

        private func number(_ value: Double) -> String {
            String(format: "%.6f", value)
        }

        private func report(_ samples: Samples, scenario: String, round: Int, rows: Int, rowBuilds: Int, listBuilds: Int) throws {
            try requireTranscriptInstrumentationDisabled()
            let count = samples.mutationMS.count
            let perItem = zip(samples.mutationMS, samples.refreshMS).map(+)
            let syncMS = perItem.reduce(0, +)
            print("STREAM_BASELINE driver=synchronous-consumer scenario=\(scenario) round=\(round) warmup=\(round == 0 ? 1 : 0) rows=\(rows) items=\(count) requests=\(samples.requests) executed=\(samples.executed) coalesced=\(samples.coalesced) immediate=\(samples.immediate) attempts=\(samples.attempts) success=\(samples.successes) fallback=\(samples.fallbacks) frontier_success=\(samples.frontierSuccesses) frontier_fallback=\(samples.frontierFallbacks) max_yields=\(samples.maxYields) sync_ms=\(number(syncMS)) ms_item=\(number(syncMS / Double(count))) item_p50=\(number(quantile(perItem, 0.5))) item_p90=\(number(quantile(perItem, 0.9))) item_iqr=\(number(quantile(perItem, 0.75) - quantile(perItem, 0.25))) mutation_ms=\(number(samples.mutationMS.reduce(0, +))) refresh_ms=\(number(samples.refreshMS.reduce(0, +))) snapshot_refresh_ms=\(number(samples.snapshotRefreshMS)) import_ms=\(number(samples.importMS)) incremental_ms=\(number(samples.incrementalMS)) payload_ms=\(number(samples.payloadMS)) sanitize_ms=\(number(samples.sanitizeMS)) projection_prefix_ms=\(number(samples.projectionPrefixMS)) sidebar_lookup_ms=\(number(samples.sidebarLookupMS)) row_builds=\(rowBuilds) list_builds=\(listBuilds) save_suppressed=1 handlers=0")
        }

        /// Advisory wall time includes awaits; the per-item metric above includes synchronous work only.
        private func reportBudget(scope: String, start: UInt64, budgetMS: Double) {
            let wallMS = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            print("STREAM_BUDGET scope=\(scope) wall_ms=\(number(wallMS)) budget_ms=\(number(budgetMS)) advisory_overrun=\(wallMS > budgetMS ? 1 : 0)")
        }

        func testStreamingBaseline() async throws {
            try XCTSkipUnless(ProcessInfo.processInfo.environment["RPCE_RUN_SCALE_TESTS"] == "1", "Opt-in fake benchmark")
            let invocationStart = DispatchTime.now().uptimeNanoseconds
            defer { reportBudget(scope: "eight-invocation", start: invocationStart, budgetMS: 900_000) }
            for round in 0 ... 5 {
                let roundStart = DispatchTime.now().uptimeNanoseconds
                let fixture = Fixture(sidebarCount: 300, streamCount: 8, childCount: 0)
                ownedFixtures.append(fixture)
                _ = fixture.projection()
                let rows = fixture.vm.test_sidebarSessionRowsBuildCount
                let lists = fixture.vm.test_sidebarListProjectionBuildCount
                let revision = fixture.vm.ui.sessionSidebar.snapshot.rowContentRevision
                let samples = try await drive(fixture, calls: [50, 64, 78, 92, 106, 120, 134, 150])
                try report(
                    samples,
                    scenario: "eight_streams",
                    round: round,
                    rows: fixture.tabs.count,
                    rowBuilds: fixture.vm.test_sidebarSessionRowsBuildCount - rows,
                    listBuilds: fixture.vm.test_sidebarListProjectionBuildCount - lists
                )
                print("STREAM_FIXTURE round=\(round) row_revision_delta=\(fixture.vm.ui.sessionSidebar.snapshot.rowContentRevision - revision) source_items=\(fixture.streams.map(\.items.count)) turns=\(fixture.streams.map(\.transcript.turns.count)) frozen=\(fixture.streams.map { $0.transcript.compactionFrontier?.frozenPrefixTurnCount ?? 0 })")
                await close(fixture)
                reportBudget(scope: "eight-round-\(round)", start: roundStart, budgetMS: 120_000)
            }
        }

        func testParentChildrenBaseline() async throws {
            try XCTSkipUnless(ProcessInfo.processInfo.environment["RPCE_RUN_SCALE_TESTS"] == "1", "Opt-in fake benchmark")
            let invocationStart = DispatchTime.now().uptimeNanoseconds
            defer { reportBudget(scope: "parent-invocation", start: invocationStart, budgetMS: 900_000) }
            for round in 0 ... 5 {
                let roundStart = DispatchTime.now().uptimeNanoseconds
                for indexOnly in [false, true] {
                    let fixture = Fixture(sidebarCount: 300, streamCount: 0, childCount: 750, indexOnly: indexOnly)
                    ownedFixtures.append(fixture)
                    let parent = try XCTUnwrap(fixture.parent)
                    fixture.vm.test_setCurrentTabIDOverride(parent.tabID)
                    let key = AgentSidebarThreadKey.key(sessionID: parent.activeAgentSessionID, tabID: parent.tabID)
                    let store = fixture.vm.ui.sessionSidebar
                    store.setThreadCollapsed(false, for: key)
                    let coldProjectionMS = elapsed { _ = fixture.projection() }
                    let warmProjectionMS = elapsed { _ = fixture.projection() }
                    let collapseAllFirstMS = elapsed {
                        _ = fixture.vm.sidebarCollapseAllState(for: fixture.tabs, currentTabID: parent.tabID, searchText: "")
                    }
                    let collapseAllRepeatMS = elapsed {
                        _ = fixture.vm.sidebarCollapseAllState(for: fixture.tabs, currentTabID: parent.tabID, searchText: "")
                    }
                    XCTAssertEqual(fixture.vm.sessions.count, indexOnly ? 1 : 1051)
                    if indexOnly { XCTAssertEqual(fixture.vm.test_ownerValidatedSessionIndex.count, 1051) }
                    let rowRevision = store.snapshot.rowContentRevision
                    let rowBuilds = fixture.vm.test_sidebarSessionRowsBuildCount
                    let listBuilds = fixture.vm.test_sidebarListProjectionBuildCount
                    var collapsed: AgentModeViewModel.SidebarListProjection!
                    let collapseMS = elapsed {
                        store.setThreadCollapsed(true, for: key)
                        collapsed = fixture.projection()
                    }
                    let parentRow = try XCTUnwrap(collapsed.filteredSessions.first { $0.tabID == parent.tabID })
                    XCTAssertEqual(parentRow.hiddenThreadDescendantCount, 750)
                    XCTAssertEqual(parentRow.hiddenThreadDescendantAttentionCount, 0)
                    var expanded: AgentModeViewModel.SidebarListProjection!
                    let expandMS = elapsed {
                        store.setThreadCollapsed(false, for: key)
                        expanded = fixture.projection()
                    }
                    XCTAssertEqual(expanded.filteredSessions.count, 1051)
                    XCTAssertEqual(fixture.vm.test_sidebarSessionRowsBuildCount, rowBuilds)
                    XCTAssertEqual(fixture.vm.test_sidebarListProjectionBuildCount - listBuilds, 2)
                    let censusMS = elapsed { fixture.vm.rebuildAgentSessionLinkSubagentCensus() }
                    let searchMS = elapsed { _ = fixture.vm.sidebarSearchFields(for: expanded.filteredSessions) }
                    let warmSearchMS = elapsed { _ = fixture.vm.sidebarSearchFields(for: expanded.filteredSessions) }
                    print("CHILD_BASELINE round=\(round) warmup=\(round == 0 ? 1 : 0) index_only=\(indexOnly ? 1 : 0) live_sessions=\(fixture.vm.sessions.count) children=750 rows=1051 cold_projection_ms=\(number(coldProjectionMS)) warm_projection_ms=\(number(warmProjectionMS)) collapse_all_first_ms=\(number(collapseAllFirstMS)) collapse_all_repeat_ms=\(number(collapseAllRepeatMS)) row_revision_delta=\(store.snapshot.rowContentRevision - rowRevision) warm_search_ms=\(number(warmSearchMS)) collapsed_rows=\(collapsed.filteredSessions.count) expanded_rows=\(expanded.filteredSessions.count) collapse_ms=\(number(collapseMS)) expand_ms=\(number(expandMS)) census_ms=\(number(censusMS)) search_materialize_ms=\(number(searchMS)) row_builds=0 list_builds=2 badge=\(parentRow.hiddenThreadDescendantCount)")
                    if indexOnly {
                        await close(fixture)
                        continue
                    }
                    var source = [Self.item(0, stream: 9, kind: .user)]
                    for call in 0 ..< 750 {
                        for kind in [AgentChatItemKind.toolCall, .toolResult, .assistant] {
                            source.append(Self.item(source.count, stream: 9, kind: kind, call: 1000 + call, tool: "agent_run"))
                        }
                    }
                    parent.setItemsSilently(source, reason: .persistedSessionHydration)
                    let coldParentMS = elapsed {
                        fixture.vm.refreshDerivedTranscriptState(for: parent, reason: .coldLoad)
                    }
                    print("PARENT_FIXTURE round=\(round) warmup=\(round == 0 ? 1 : 0) seed_calls=750 seed_items=\(source.count) cold_derivation_ms=\(number(coldParentMS)) turns=\(parent.transcript.turns.count) frozen=\(parent.transcript.compactionFrontier?.frozenPrefixTurnCount ?? 0)")
                    let rows = fixture.vm.test_sidebarSessionRowsBuildCount
                    let lists = fixture.vm.test_sidebarListProjectionBuildCount
                    let samples = try await drive(fixture, calls: [1], parent: true)
                    try report(
                        samples,
                        scenario: "parent_child_items",
                        round: round,
                        rows: fixture.tabs.count,
                        rowBuilds: fixture.vm.test_sidebarSessionRowsBuildCount - rows,
                        listBuilds: fixture.vm.test_sidebarListProjectionBuildCount - lists
                    )
                    XCTAssertEqual(parent.transcript.turns.count, 1)
                    await close(fixture)
                }
                reportBudget(scope: "parent-round-\(round)", start: roundStart, budgetMS: 120_000)
            }
        }

        func testReportingRejectsEnabledTranscriptInstrumentationWithoutResettingIt() {
            AgentTranscriptDebugInstrumentation.configure(.init())
            defer { AgentTranscriptDebugInstrumentation.reset() }
            XCTAssertThrowsError(try report(Samples(), scenario: "invalid", round: 0, rows: 0, rowBuilds: 0, listBuilds: 0)) {
                XCTAssertEqual($0 as? FixtureError, .debugInstrumentationEnabled)
            }
            XCTAssertTrue(AgentTranscriptDebugInstrumentation.isEnabled)
        }

        func testHarnessWorkBounds() async throws {
            let fixture = Fixture(sidebarCount: 8, streamCount: 8, childCount: 0, seedTurns: 0)
            ownedFixtures.append(fixture)
            let samples = try await drive(fixture, calls: Array(repeating: 2, count: 8))
            XCTAssertEqual(samples.executed, 48)
            XCTAssertEqual(samples.successes, 48)
            XCTAssertEqual(samples.fallbacks, 0)
            XCTAssertEqual(fixture.streams.map(\.transcript.turns.count), Array(repeating: 1, count: 8))
            await close(fixture)
        }

        func testDescendantBadgeAndIndependentChildMutation() async throws {
            let fixture = Fixture(sidebarCount: 1, streamCount: 0, childCount: 4)
            ownedFixtures.append(fixture)
            let parent = try XCTUnwrap(fixture.parent)
            let children = fixture.children
            children[3].parentSessionID = children[0].activeAgentSessionID
            fixture.vm.test_setCurrentTabIDOverride(parent.tabID)
            fixture.vm.syncSidebarUIState(refresh: true, reason: .runState, sidebarTabs: fixture.tabs)
            let store = fixture.vm.ui.sessionSidebar
            let key = AgentSidebarThreadKey.key(sessionID: parent.activeAgentSessionID, tabID: parent.tabID)
            store.setThreadCollapsed(true, for: key)
            XCTAssertTrue(store.markRunStateAttention(tabID: children[3].tabID, state: .completed))
            XCTAssertTrue(store.markRunStateAttention(tabID: parent.tabID, state: .completed))
            let row = try XCTUnwrap(fixture.projection().filteredSessions.first { $0.tabID == parent.tabID })
            XCTAssertEqual(row.hiddenThreadDescendantCount, 4)
            XCTAssertEqual(row.hiddenThreadDescendantAttentionCount, 1)
            let parentItems = parent.items
            let parentBuilds = parent.transcriptPerformanceSnapshot.projectionBuildCount
            let child = children[0]
            let childBuilds = child.transcriptPerformanceSnapshot.projectionBuildCount
            let appended = Self.item(child.nextSequenceIndex, stream: 10, kind: .assistant)
            child.appendItem(appended)
            _ = try await drain(child)
            XCTAssertEqual(child.transcriptPerformanceSnapshot.projectionBuildCount, childBuilds + 1)
            let activity = try XCTUnwrap(child.transcript.turns.flatMap(\.allActivities).first { $0.id == appended.id })
            XCTAssertEqual(activity.text, appended.text)
            XCTAssertEqual(activity.itemKind, appended.kind)
            XCTAssertEqual(parent.items, parentItems)
            XCTAssertEqual(parent.transcriptPerformanceSnapshot.projectionBuildCount, parentBuilds)
            await close(fixture)
        }
    }
#endif
