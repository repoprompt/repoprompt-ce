import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

/// The link snapshot's `context` load is the usage the target's context ring already shows, for the
/// providers whose usage RepoPrompt actually records, and only the figures the current provider's own
/// live usage report produced. Everything else is unknown (`nil`).
@MainActor
final class AgentSessionLinkContextLoadTests: XCTestCase {
    private func makeCandidate(tabID: UUID) -> AgentSessionLinkEndpointCandidate {
        AgentSessionLinkEndpointCandidate(
            windowID: 1,
            workspaceID: UUID(),
            tabID: tabID,
            sessionID: UUID(),
            persistentBindingGeneration: UUID(),
            bindingTransitionGeneration: 1,
            isTopLevel: true,
            hasLoadedPersistedState: true,
            bindingTransitionInProgress: false,
            isClosing: false,
            isMCPControlled: false,
            isMCPOriginated: false,
            roleAllowsOutboundMonitoring: true,
            displayName: "Worker",
            providerDisplayName: "Claude Code",
            locationLabel: "worktree/main"
        )
    }

    private func makeViewModel() -> AgentModeViewModel {
        AgentModeViewModel(
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in
                preconditionFailure("Context-load tests must not start a Codex session")
            }
        )
    }

    private func usage(
        _ used: Int?,
        _ window: Int?,
        confidence: ContextUsageSnapshotConfidence = .exact,
        source: ContextUsageSnapshotSource = .claudeUsageEvent
    ) -> ContextUsageSnapshot {
        ContextUsageSnapshot(used: used, window: window, confidence: confidence, source: source, compactedAt: nil)
    }

    /// A session whose `usage` was just produced by a live report from `agent` carrying both figures,
    /// unless `liveReport` is false (for example figures restored at launch).
    private func snapshot(
        agent: AgentProviderKind,
        usage: ContextUsageSnapshot?,
        liveReport: Bool = true
    ) -> DomainAgentSessionObservationSnapshot {
        let tabID = UUID()
        let session = AgentModeViewModel.TabSession(tabID: tabID)
        session.selectedAgent = agent
        session.contextUsageSnapshot = usage
        if liveReport {
            session.noteLiveContextUsageReport(
                contextUsedTokens: usage?.used,
                promptTokens: nil,
                modelContextWindow: usage?.window
            )
        }
        return AgentModeViewModel.observationSnapshot(for: session, candidate: makeCandidate(tabID: tabID))
    }

    func testClaudeSessionWithKnownUsagePublishesExactContextLoad() throws {
        let context = try XCTUnwrap(snapshot(agent: .claudeCode, usage: usage(175_000, 200_000)).context)
        XCTAssertEqual(context.usedTokens, 175_000)
        XCTAssertEqual(context.windowTokens, 200_000)
        XCTAssertEqual(context.confidence, .exact)
        XCTAssertEqual(context.usedPercent, 87.5)
    }

    func testFallbackAndInferredUsageKeepTheirConfidenceLabels() throws {
        let partial = try XCTUnwrap(
            snapshot(agent: .claudeCode, usage: usage(40000, nil, confidence: .bestEffort)).context
        )
        XCTAssertEqual(partial.confidence, .bestEffort)
        XCTAssertEqual(partial.usedTokens, 40000)
        XCTAssertNil(partial.windowTokens)
        XCTAssertNil(partial.usedPercent, "A percentage needs both figures")

        let inferred = snapshot(agent: .claudeCodeGLM, usage: usage(120_000, 1_000_000, confidence: .inferred))
        XCTAssertEqual(inferred.context?.confidence, .inferred)
    }

    func testNoRecordedUsageIsUnknownNotZero() {
        XCTAssertNil(snapshot(agent: .claudeCode, usage: nil).context)
        XCTAssertNil(snapshot(agent: .codexExec, usage: nil).context)
        XCTAssertNil(
            snapshot(agent: .claudeCode, usage: usage(nil, nil, confidence: .bestEffort, source: .compactionSignal))
                .context
        )
    }

    /// Restored figures may belong to another provider or predate a compaction, so a relaunched
    /// target reports unknown until its provider reports live usage again.
    func testRestoredFiguresWithoutALiveReportAreUnknown() {
        let restored = snapshot(
            agent: .claudeCode,
            usage: usage(120_000, 200_000, confidence: .bestEffort, source: .persistedTurns),
            liveReport: false
        )
        XCTAssertNil(restored.context)
    }

    /// After a compaction signal the recorded count still predates the compaction, so only the
    /// window is reported until the next usage report.
    func testCompactionSignalReportsTheWindowButNotThePreCompactionCount() throws {
        let context = try XCTUnwrap(
            snapshot(
                agent: .claudeCode,
                usage: usage(190_000, 200_000, confidence: .bestEffort, source: .compactionSignal)
            ).context
        )
        XCTAssertNil(context.usedTokens)
        XCTAssertEqual(context.windowTokens, 200_000)
        XCTAssertNil(context.usedPercent)
    }

    /// Through the real usage handler: after Claude Code -> Kimi, Kimi's window-less first report is
    /// judged against Claude's window and rejected, so the estimator carries Claude's count forward.
    /// Neither that count nor Claude's window may be reported as Kimi's load.
    func testProviderSwitchNeverRelabelsThePreviousProvidersFigures() {
        let viewModel = makeViewModel()
        let tabID = UUID()
        let session = AgentModeViewModel.TabSession(tabID: tabID)
        let candidate = makeCandidate(tabID: tabID)
        func reported() -> DomainAgentSessionContextLoad? {
            AgentModeViewModel.observationSnapshot(for: session, candidate: candidate).context
        }
        session.selectedAgent = .claudeCode
        XCTAssertTrue(viewModel.ingestNonCodexUsageReport(
            promptTokens: nil, completionTokens: nil, contextUsedTokens: 180_000,
            modelContextWindow: 200_000, session: session
        ))
        XCTAssertEqual(reported()?.usedTokens, 180_000)
        XCTAssertEqual(reported()?.windowTokens, 200_000)

        session.selectedAgent = .kimiCode
        XCTAssertNotNil(session.contextUsageSnapshot, "The ring's value is left alone")
        XCTAssertNil(reported())

        // 250k exceeds Claude's inherited 200k window, so the estimator keeps Claude's 180k.
        _ = viewModel.ingestNonCodexUsageReport(
            promptTokens: nil, completionTokens: nil, contextUsedTokens: 250_000,
            modelContextWindow: nil, session: session
        )
        XCTAssertEqual(session.contextUsageSnapshot?.used, 180_000, "Precondition: the carried-forward count")
        XCTAssertNil(reported(), "Claude's count and window are never reported as Kimi's")

        // Kimi's own billed prompt count is Kimi's figure (labelled best effort), still without a window.
        _ = viewModel.ingestNonCodexUsageReport(
            promptTokens: 240_000, completionTokens: nil, contextUsedTokens: nil,
            modelContextWindow: nil, session: session
        )
        XCTAssertEqual(reported()?.usedTokens, 240_000)
        XCTAssertEqual(reported()?.confidence, .bestEffort)
        XCTAssertNil(reported()?.windowTokens, "Claude's window is not Kimi's")

        // Kimi reports its own window.
        _ = viewModel.ingestNonCodexUsageReport(
            promptTokens: 245_000, completionTokens: nil, contextUsedTokens: nil,
            modelContextWindow: 262_144, session: session
        )
        XCTAssertEqual(reported()?.usedTokens, 245_000)
        XCTAssertEqual(reported()?.windowTokens, 262_144)

        session.selectedAgent = .claudeCode
        XCTAssertNil(reported(), "Switching back does not revive figures from before the switch")
    }

    func testCompactionAndClearingInvalidateTheCountUntilTheNextReport() {
        let viewModel = makeViewModel()
        let tabID = UUID()
        let session = AgentModeViewModel.TabSession(tabID: tabID)
        let candidate = makeCandidate(tabID: tabID)
        func reported() -> DomainAgentSessionContextLoad? {
            AgentModeViewModel.observationSnapshot(for: session, candidate: candidate).context
        }
        session.selectedAgent = .claudeCode
        _ = viewModel.ingestNonCodexUsageReport(
            promptTokens: nil, completionTokens: nil, contextUsedTokens: 190_000,
            modelContextWindow: 200_000, session: session
        )
        XCTAssertEqual(reported()?.usedTokens, 190_000)

        session.contextCompactedAt = Date(timeIntervalSince1970: 100)
        XCTAssertNil(reported()?.usedTokens, "A compaction invalidates the pre-compaction count")
        XCTAssertEqual(reported()?.windowTokens, 200_000, "The window is unchanged by a compaction")

        // Output-only usage carries no new count, so the carried-forward count stays unvouched.
        _ = viewModel.ingestNonCodexUsageReport(
            promptTokens: nil, completionTokens: 500, contextUsedTokens: nil,
            modelContextWindow: nil, session: session
        )
        XCTAssertNil(reported()?.usedTokens)

        _ = viewModel.ingestNonCodexUsageReport(
            promptTokens: nil, completionTokens: nil, contextUsedTokens: 9000,
            modelContextWindow: nil, session: session
        )
        XCTAssertEqual(reported()?.usedTokens, 9000)
        XCTAssertEqual(reported()?.usedPercent, 4.5)

        session.contextUsageSnapshot = nil
        session.contextUsageSnapshot = usage(50000, 200_000)
        XCTAssertNil(reported(), "Clearing the usage clears what the provider vouched for")
    }

    /// A same-provider report that conflicts with the stored count (here one the estimator rejects
    /// against the known window and replaces with the carried-forward count) withdraws the count, and
    /// any later write with a different value is not vouched for either.
    func testConflictingReportsAndUnvouchedWritesAreNotReported() {
        let viewModel = makeViewModel()
        let tabID = UUID()
        let session = AgentModeViewModel.TabSession(tabID: tabID)
        let candidate = makeCandidate(tabID: tabID)
        func reported() -> DomainAgentSessionContextLoad? {
            AgentModeViewModel.observationSnapshot(for: session, candidate: candidate).context
        }
        session.selectedAgent = .claudeCode
        _ = viewModel.ingestNonCodexUsageReport(
            promptTokens: nil, completionTokens: nil, contextUsedTokens: 180_000,
            modelContextWindow: 200_000, session: session
        )
        XCTAssertEqual(reported()?.usedTokens, 180_000)

        _ = viewModel.ingestNonCodexUsageReport(
            promptTokens: nil, completionTokens: nil, contextUsedTokens: 250_000,
            modelContextWindow: nil, session: session
        )
        XCTAssertEqual(session.contextUsageSnapshot?.used, 180_000, "Precondition: the carried-forward count")
        XCTAssertNil(reported()?.usedTokens, "A conflicting report withdraws the count")
        XCTAssertEqual(reported()?.windowTokens, 200_000)

        _ = viewModel.ingestNonCodexUsageReport(
            promptTokens: nil, completionTokens: nil, contextUsedTokens: 150_000,
            modelContextWindow: nil, session: session
        )
        XCTAssertEqual(reported()?.usedTokens, 150_000)
        session.contextUsageSnapshot = usage(160_000, 200_000)
        XCTAssertNil(reported()?.usedTokens, "A write the provider did not report is not vouched for")
        XCTAssertEqual(reported()?.windowTokens, 200_000, "The unchanged window keeps its vouch")
    }

    /// The Claude translator's real event shapes: stream `usage` events carry the live context count
    /// but no window; `message_stop` carries the window from `result.modelUsage` plus the aggregate
    /// billed prompt count and no context count. Together they report the full load, and the billed
    /// aggregate never becomes the context count.
    func testClaudeStreamCountAndMessageStopWindowTogetherReportTheLoad() throws {
        let viewModel = makeViewModel()
        let tabID = UUID()
        let session = AgentModeViewModel.TabSession(tabID: tabID)
        let candidate = makeCandidate(tabID: tabID)
        func reported() -> DomainAgentSessionContextLoad? {
            AgentModeViewModel.observationSnapshot(for: session, candidate: candidate).context
        }
        session.selectedAgent = .claudeCode
        session.activeNonCodexTurnTokenAccumulator = AgentModeViewModel.NonCodexTurnTokenAccumulator()

        _ = viewModel.ingestNonCodexUsageReport(
            promptTokens: 3, completionTokens: nil, contextUsedTokens: 150_000,
            modelContextWindow: nil, session: session
        )
        XCTAssertEqual(reported()?.usedTokens, 150_000)
        XCTAssertNil(reported()?.windowTokens, "Stream usage carries no window")

        viewModel.ingestNonCodexTurnFinalization(
            promptTokens: 2_400_000, completionTokens: 8000, contextUsedTokens: nil,
            modelContextWindow: 200_000, session: session
        )
        let context = try XCTUnwrap(reported())
        XCTAssertEqual(context.windowTokens, 200_000)
        XCTAssertEqual(context.usedTokens, 150_000, "The billed aggregate never becomes the context count")
        XCTAssertEqual(context.usedPercent, 75.0)
    }

    /// Every live report re-evaluates provenance, even one that leaves the stored snapshot
    /// byte-identical, and a rejected context count is never replaced by the smaller prompt count.
    func testEveryReportReevaluatesProvenanceAndRejectedCountsAreNotBackfilled() {
        let viewModel = makeViewModel()
        let tabID = UUID()
        let session = AgentModeViewModel.TabSession(tabID: tabID)
        let candidate = makeCandidate(tabID: tabID)
        func reported() -> DomainAgentSessionContextLoad? {
            AgentModeViewModel.observationSnapshot(for: session, candidate: candidate).context
        }
        session.selectedAgent = .claudeCode
        _ = viewModel.ingestNonCodexUsageReport(
            promptTokens: 150_000, completionTokens: nil, contextUsedTokens: nil,
            modelContextWindow: 200_000, session: session
        )
        XCTAssertEqual(reported()?.usedTokens, 150_000)

        // Rejected against the window; the estimator keeps an identical snapshot, yet the
        // conflicting report still withdraws the count.
        XCTAssertFalse(viewModel.ingestNonCodexUsageReport(
            promptTokens: nil, completionTokens: nil, contextUsedTokens: 250_000,
            modelContextWindow: nil, session: session
        ), "Precondition: the snapshot is unchanged")
        XCTAssertNil(reported()?.usedTokens)

        // An identical report from a newly selected provider vouches for its own figure.
        session.selectedAgent = .kimiCode
        XCTAssertNil(reported())
        XCTAssertFalse(viewModel.ingestNonCodexUsageReport(
            promptTokens: 150_000, completionTokens: nil, contextUsedTokens: nil,
            modelContextWindow: nil, session: session
        ), "Precondition: the snapshot is unchanged")
        XCTAssertEqual(reported()?.usedTokens, 150_000)

        // An over-window context count falls back to the input-only prompt count in the estimator;
        // that undercount is not reported as the context.
        _ = viewModel.ingestNonCodexUsageReport(
            promptTokens: 2000, completionTokens: nil, contextUsedTokens: 250_000,
            modelContextWindow: nil, session: session
        )
        XCTAssertEqual(session.contextUsageSnapshot?.used, 2000, "Precondition: the estimator's fallback")
        XCTAssertNil(reported()?.usedTokens)
    }

    func testModelChangeAndLateCodexReportsAreNotReportedAsCurrentLoad() {
        let viewModel = makeViewModel()
        let tabID = UUID()
        let session = AgentModeViewModel.TabSession(tabID: tabID)
        let candidate = makeCandidate(tabID: tabID)
        func reported() -> DomainAgentSessionContextLoad? {
            AgentModeViewModel.observationSnapshot(for: session, candidate: candidate).context
        }
        session.selectedAgent = .claudeCode
        _ = viewModel.ingestNonCodexUsageReport(
            promptTokens: nil, completionTokens: nil, contextUsedTokens: 120_000,
            modelContextWindow: 200_000, session: session
        )
        XCTAssertNotNil(reported())
        session.selectedModelRaw = session.selectedModelRaw + "-other"
        XCTAssertNil(reported(), "A different model can have a different window")

        viewModel.applyCodexNativeContextUsage(
            AgentContextUsage(modelContextWindow: 1_000_000, lastTotalTokens: 400_000, totalTotalTokens: 400_000),
            session: session
        )
        XCTAssertNil(reported(), "A Codex report on a Claude tab is not Claude's load")
    }

    /// Codex's live `thread/tokenUsage` path vouches for its figures; a compaction does not.
    func testCodexNativeUsageIsReportedAndCompactionDropsTheCount() throws {
        let viewModel = makeViewModel()
        let tabID = UUID()
        let session = AgentModeViewModel.TabSession(tabID: tabID)
        session.selectedAgent = .codexExec
        let candidate = makeCandidate(tabID: tabID)

        viewModel.applyCodexNativeContextUsage(
            AgentContextUsage(modelContextWindow: 1_000_000, lastTotalTokens: 400_000, totalTotalTokens: 900_000),
            session: session
        )
        let context = try XCTUnwrap(AgentModeViewModel.observationSnapshot(for: session, candidate: candidate).context)
        XCTAssertEqual(context.usedTokens, 400_000, "The last request's context, never the cumulative total")
        XCTAssertEqual(context.windowTokens, 1_000_000)
        XCTAssertEqual(context.usedPercent, 40.0)
        XCTAssertEqual(context.confidence, .exact)

        // What `markCodexContextCompacted` does: stamp the compaction, then re-derive the snapshot
        // from the pre-compaction figures.
        session.contextCompactedAt = Date()
        viewModel.refreshCodexContextUsageSnapshot(for: session)
        let compacted = AgentModeViewModel.observationSnapshot(for: session, candidate: candidate).context
        XCTAssertNil(compacted?.usedTokens)
        XCTAssertEqual(compacted?.windowTokens, 1_000_000)
    }

    /// ACP-backed providers have no context estimator yet, so any usage value on their tab is not
    /// theirs to report (for example a value restored from a different provider) and stays unknown.
    func testACPProvidersStayUnknownEvenWithAStoredUsageValue() {
        for agent in [AgentProviderKind.openCode, .cursor, .devin, .grokBuild, .antigravity] {
            XCTAssertNil(snapshot(agent: agent, usage: usage(90000, 200_000)).context, "\(agent)")
        }
    }
}
