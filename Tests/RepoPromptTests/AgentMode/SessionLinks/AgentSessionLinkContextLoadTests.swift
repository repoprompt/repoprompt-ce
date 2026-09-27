import Combine
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

    /// The exported label says how the report that vouched the count obtained it: a prompt-count
    /// fallback is `best_effort`, a reported occupancy count is `exact` even when it re-confirms a
    /// figure the ring shows as rebuilt, and a rebuilt figure no live report confirmed is not exported.
    func testTheExportedLabelDescribesTheVouchingReport() throws {
        let tabID = UUID()
        let fallback = AgentModeViewModel.TabSession(tabID: tabID)
        fallback.selectedAgent = .claudeCode
        fallback.contextUsageSnapshot = usage(40000, nil, confidence: .bestEffort)
        fallback.noteLiveContextUsageReport(contextUsedTokens: nil, promptTokens: 40000, modelContextWindow: nil)
        let partial = try XCTUnwrap(
            AgentModeViewModel.observationSnapshot(for: fallback, candidate: makeCandidate(tabID: tabID)).context
        )
        XCTAssertEqual(partial.confidence, .bestEffort)
        XCTAssertEqual(partial.usedTokens, 40000)
        XCTAssertNil(partial.windowTokens)
        XCTAssertNil(partial.usedPercent, "A percentage needs both figures")

        let reconfirmed = snapshot(agent: .claudeCodeGLM, usage: usage(120_000, 1_000_000, confidence: .inferred))
        XCTAssertEqual(reconfirmed.context?.usedTokens, 120_000)
        XCTAssertEqual(reconfirmed.context?.confidence, .exact)

        let rebuiltOnly = snapshot(
            agent: .claudeCodeGLM,
            usage: usage(120_000, 1_000_000, confidence: .inferred),
            liveReport: false
        )
        XCTAssertNil(rebuiltOnly.context?.usedTokens)
        XCTAssertNil(rebuiltOnly.context?.confidence)
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

    /// A stored ACP figure is reported only while the current provider's own live report vouches
    /// for it. A restored or carried-forward value with no live report stays unknown.
    func testACPProvidersReportOnlyLiveVouchedUsage() {
        for agent in [AgentProviderKind.openCode, .cursor, .devin, .grokBuild, .antigravity] {
            XCTAssertNil(
                snapshot(agent: agent, usage: usage(90000, 200_000), liveReport: false).context,
                "\(agent): an unvouched stored figure is not reported"
            )
        }
    }

    /// An ACP `usage_update` (`used` = occupancy, `size` = window) is the provider's own occupancy
    /// report, so it is exported as `exact`. It also populates the context ring's store.
    func testACPUsageUpdateReportsExactContextLoad() {
        for agent in [AgentProviderKind.openCode, .cursor, .devin, .grokBuild, .antigravity] {
            let viewModel = makeViewModel()
            let tabID = UUID()
            let session = AgentModeViewModel.TabSession(tabID: tabID)
            session.selectedAgent = agent

            XCTAssertTrue(viewModel.ingestNonCodexUsageReport(
                promptTokens: nil, completionTokens: nil, contextUsedTokens: 90000,
                modelContextWindow: 200_000, session: session
            ), "\(agent): the usage update should produce a snapshot")
            XCTAssertEqual(session.codexContextUsage?.lastTotalTokens, 90000, "\(agent): the ring's store")
            XCTAssertEqual(session.codexContextUsage?.modelContextWindow, 200_000, "\(agent): the ring's window")

            let context = AgentModeViewModel.observationSnapshot(
                for: session, candidate: makeCandidate(tabID: tabID)
            ).context
            XCTAssertEqual(context?.usedTokens, 90000, "\(agent)")
            XCTAssertEqual(context?.windowTokens, 200_000, "\(agent)")
            XCTAssertEqual(context?.confidence, .exact, "\(agent)")
            XCTAssertEqual(context?.usedPercent, 45.0, "\(agent)")
        }
    }

    /// A `usage_update` carrying only a window reports the window alone.
    func testACPWindowOnlyUsageUpdateReportsTheWindow() throws {
        let viewModel = makeViewModel()
        let tabID = UUID()
        let session = AgentModeViewModel.TabSession(tabID: tabID)
        session.selectedAgent = .openCode

        _ = viewModel.ingestNonCodexUsageReport(
            promptTokens: nil, completionTokens: nil, contextUsedTokens: nil,
            modelContextWindow: 272_000, session: session
        )
        let context = try XCTUnwrap(
            AgentModeViewModel.observationSnapshot(for: session, candidate: makeCandidate(tabID: tabID)).context
        )
        XCTAssertNil(context.usedTokens)
        XCTAssertEqual(context.windowTokens, 272_000)
        XCTAssertNil(context.usedPercent)
        XCTAssertNil(context.confidence, "A confidence label describes the count, and there is none")
    }

    /// Prompt-response usage is billed per-call input (possibly a per-turn total), not a sampled
    /// occupancy: the ring shows it as `best_effort`, but oversight never exports it as the count.
    func testACPTurnFinalizationKeepsBilledCountsInTheRingOnly() {
        let viewModel = makeViewModel()
        let tabID = UUID()
        let session = AgentModeViewModel.TabSession(tabID: tabID)
        let candidate = makeCandidate(tabID: tabID)
        func reported() -> DomainAgentSessionContextLoad? {
            AgentModeViewModel.observationSnapshot(for: session, candidate: candidate).context
        }
        session.selectedAgent = .grokBuild

        viewModel.ingestNonCodexTurnFinalization(
            promptTokens: 95000, completionTokens: 4000, contextUsedTokens: 95000,
            modelContextWindow: nil, session: session
        )
        // The ring keeps the billed figure; oversight never exports an ACP billed count.
        XCTAssertEqual(session.contextUsageSnapshot?.used, 95000)
        XCTAssertEqual(session.contextUsageSnapshot?.confidence, .bestEffort)
        XCTAssertNil(reported()?.usedTokens)
        XCTAssertNil(reported()?.confidence)
        XCTAssertNil(reported()?.windowTokens, "Prompt-response usage carries no window")
    }

    /// A billed prompt-call count can be cumulative across the turn's internal requests, so it
    /// never replaces a same-turn `usage_update` occupancy figure. The declined billed report is
    /// a different quantity, not a contradiction, so the vouched occupancy figure stays exported
    /// through the idle period after the turn — exactly when an overseer polls.
    func testACPBilledCountNeverReplacesASameTurnOccupancyReport() {
        let viewModel = makeViewModel()
        let tabID = UUID()
        let session = AgentModeViewModel.TabSession(tabID: tabID)
        let candidate = makeCandidate(tabID: tabID)
        func reported() -> DomainAgentSessionContextLoad? {
            AgentModeViewModel.observationSnapshot(for: session, candidate: candidate).context
        }
        session.selectedAgent = .devin

        _ = viewModel.ingestNonCodexUsageReport(
            promptTokens: nil, completionTokens: nil, contextUsedTokens: 180_000,
            modelContextWindow: 200_000, session: session
        )
        XCTAssertEqual(reported()?.usedTokens, 180_000)
        XCTAssertEqual(reported()?.confidence, .exact)

        viewModel.ingestNonCodexTurnFinalization(
            promptTokens: 95000, completionTokens: 4000, contextUsedTokens: 95000,
            modelContextWindow: nil, session: session
        )
        XCTAssertEqual(
            session.contextUsageSnapshot?.used, 180_000,
            "Occupancy is kept and the ring keeps showing it"
        )
        XCTAssertEqual(session.contextUsageSnapshot?.confidence, .exact)
        XCTAssertEqual(session.contextUsageSnapshot?.source, .acpUsageEvent)
        XCTAssertEqual(reported()?.usedTokens, 180_000, "The declined billed report keeps the vouch")
        XCTAssertEqual(reported()?.windowTokens, 200_000)
        XCTAssertEqual(reported()?.confidence, .exact, "The exact label is not downgraded")
    }

    /// A billed count above the known window is provably cumulative, so it is not stored as the
    /// context count at all. With no `usage_update` this turn, the declined report stands alone:
    /// it cannot vouch the kept occupancy figure, so the count leaves the export until the next
    /// occupancy report.
    func testACPOverWindowBilledCountIsNotStoredAsContext() {
        let viewModel = makeViewModel()
        let tabID = UUID()
        let session = AgentModeViewModel.TabSession(tabID: tabID)
        let candidate = makeCandidate(tabID: tabID)
        func reported() -> DomainAgentSessionContextLoad? {
            AgentModeViewModel.observationSnapshot(for: session, candidate: candidate).context
        }
        session.selectedAgent = .devin

        _ = viewModel.ingestNonCodexUsageReport(
            promptTokens: nil, completionTokens: nil, contextUsedTokens: 180_000,
            modelContextWindow: 200_000, session: session
        )
        // A new turn clears the same-turn occupancy protection, so this billed count is evaluated
        // on its own — and rejected against the window.
        viewModel.startNonCodexTurnAccountingIfNeeded(for: session, initialMessage: "next")
        viewModel.ingestNonCodexTurnFinalization(
            promptTokens: 340_000, completionTokens: 9000, contextUsedTokens: 340_000,
            modelContextWindow: nil, session: session
        )
        XCTAssertEqual(session.contextUsageSnapshot?.used, 180_000, "The ring keeps the count")
        XCTAssertNil(reported()?.usedTokens, "No live report this turn can vouch the kept count")
        XCTAssertEqual(reported()?.windowTokens, 200_000)
    }

    /// A rejected billed count also discredits a stored count from the same billed series: once a
    /// billed report provably exceeds the window, the earlier billed figure was cumulative too.
    func testACPDiscreditedBilledSeriesDropsTheStoredBilledCount() {
        let viewModel = makeViewModel()
        let tabID = UUID()
        let session = AgentModeViewModel.TabSession(tabID: tabID)
        let candidate = makeCandidate(tabID: tabID)
        func reported() -> DomainAgentSessionContextLoad? {
            AgentModeViewModel.observationSnapshot(for: session, candidate: candidate).context
        }
        session.selectedAgent = .grokBuild

        // A window-only `usage_update` gives a bound without an occupancy claim.
        _ = viewModel.ingestNonCodexUsageReport(
            promptTokens: nil, completionTokens: nil, contextUsedTokens: nil,
            modelContextWindow: 200_000, session: session
        )
        viewModel.ingestNonCodexTurnFinalization(
            promptTokens: 95000, completionTokens: 4000, contextUsedTokens: 95000,
            modelContextWindow: nil, session: session
        )
        // The ring keeps the billed figure; oversight never exports an ACP billed count.
        XCTAssertEqual(session.contextUsageSnapshot?.used, 95000)
        XCTAssertEqual(session.contextUsageSnapshot?.confidence, .bestEffort)
        XCTAssertNil(reported()?.usedTokens)
        XCTAssertNil(reported()?.confidence)

        // A size-only update carries the billed count forward without relabelling it.
        _ = viewModel.ingestNonCodexUsageReport(
            promptTokens: nil, completionTokens: nil, contextUsedTokens: nil,
            modelContextWindow: 200_000, session: session
        )
        XCTAssertEqual(session.contextUsageSnapshot?.source, .turnFinalization)

        viewModel.startNonCodexTurnAccountingIfNeeded(for: session, initialMessage: "next")
        viewModel.ingestNonCodexTurnFinalization(
            promptTokens: 340_000, completionTokens: 9000, contextUsedTokens: 340_000,
            modelContextWindow: nil, session: session
        )
        XCTAssertNil(session.contextUsageSnapshot?.used, "The earlier billed count was cumulative too")
        XCTAssertEqual(reported()?.windowTokens, 200_000)
        XCTAssertNil(reported()?.usedTokens)
    }

    /// Occupancy protection is per-turn: once a new turn begins, a billed count is the best
    /// available figure again and is reported as `best_effort`.
    func testACPBilledCountAcceptedAgainAfterANewTurnBegins() {
        let viewModel = makeViewModel()
        let tabID = UUID()
        let session = AgentModeViewModel.TabSession(tabID: tabID)
        let candidate = makeCandidate(tabID: tabID)
        func reported() -> DomainAgentSessionContextLoad? {
            AgentModeViewModel.observationSnapshot(for: session, candidate: candidate).context
        }
        session.selectedAgent = .devin

        _ = viewModel.ingestNonCodexUsageReport(
            promptTokens: nil, completionTokens: nil, contextUsedTokens: 180_000,
            modelContextWindow: 200_000, session: session
        )
        XCTAssertEqual(reported()?.confidence, .exact)

        viewModel.startNonCodexTurnAccountingIfNeeded(for: session, initialMessage: "next")
        viewModel.ingestNonCodexTurnFinalization(
            promptTokens: 95000, completionTokens: 4000, contextUsedTokens: 95000,
            modelContextWindow: nil, session: session
        )
        // The ring keeps the billed figure; oversight never exports an ACP billed count.
        XCTAssertEqual(session.contextUsageSnapshot?.used, 95000)
        XCTAssertEqual(session.contextUsageSnapshot?.confidence, .bestEffort)
        XCTAssertNil(reported()?.usedTokens)
        XCTAssertNil(reported()?.confidence)
        XCTAssertEqual(reported()?.windowTokens, 200_000)
    }

    /// Occupancy protection is consumed by the finalization that ends the turn, so a steering
    /// prompt inside the same run — a second turn without a `beginTurn` call — evaluates its own
    /// billed count normally rather than inheriting the previous prompt's occupancy claim.
    func testACPBilledCountAcceptedOnASteeringTurnAfterFinalization() {
        let viewModel = makeViewModel()
        let tabID = UUID()
        let session = AgentModeViewModel.TabSession(tabID: tabID)
        let candidate = makeCandidate(tabID: tabID)
        func reported() -> DomainAgentSessionContextLoad? {
            AgentModeViewModel.observationSnapshot(for: session, candidate: candidate).context
        }
        session.selectedAgent = .devin

        _ = viewModel.ingestNonCodexUsageReport(
            promptTokens: nil, completionTokens: nil, contextUsedTokens: 180_000,
            modelContextWindow: 200_000, session: session
        )
        viewModel.ingestNonCodexTurnFinalization(
            promptTokens: 95000, completionTokens: 4000, contextUsedTokens: 95000,
            modelContextWindow: nil, session: session
        )
        XCTAssertEqual(reported()?.usedTokens, 180_000, "Same-turn billed count stays suppressed")

        viewModel.ingestNonCodexTurnFinalization(
            promptTokens: 60000, completionTokens: 4000, contextUsedTokens: 60000,
            modelContextWindow: nil, session: session
        )
        // The ring keeps the billed figure; oversight never exports an ACP billed count.
        XCTAssertEqual(session.contextUsageSnapshot?.used, 60000)
        XCTAssertEqual(session.contextUsageSnapshot?.confidence, .bestEffort)
        XCTAssertNil(reported()?.usedTokens)
        XCTAssertNil(reported()?.confidence)
    }

    /// A fresh window reported inside a finalization bounds a held occupancy figure too: a
    /// count that no longer fits is dropped rather than exported over 100%.
    func testACPShrinkingWindowInFinalizationDropsTheHeldCount() {
        let viewModel = makeViewModel()
        let tabID = UUID()
        let session = AgentModeViewModel.TabSession(tabID: tabID)
        let candidate = makeCandidate(tabID: tabID)
        func reported() -> DomainAgentSessionContextLoad? {
            AgentModeViewModel.observationSnapshot(for: session, candidate: candidate).context
        }
        session.selectedAgent = .devin

        _ = viewModel.ingestNonCodexUsageReport(
            promptTokens: nil, completionTokens: nil, contextUsedTokens: 150_000,
            modelContextWindow: 200_000, session: session
        )
        viewModel.ingestNonCodexTurnFinalization(
            promptTokens: nil, completionTokens: nil, contextUsedTokens: nil,
            modelContextWindow: 100_000, session: session
        )
        XCTAssertNil(session.contextUsageSnapshot?.used, "150k in a 100k window is not current")
        XCTAssertNil(session.codexContextUsage?.totalTotalTokens)
        XCTAssertNil(reported()?.usedTokens)
        XCTAssertEqual(reported()?.windowTokens, 100_000)
    }

    /// A window-only `usage_update` carries no occupancy claim, so the turn's hold survives it:
    /// the billed count stays suppressed and the earlier occupancy figure keeps its vouch. The ring
    /// relabels it best_effort, but oversight keeps `exact`: nothing refuted the reported occupancy.
    func testACPWindowOnlyUpdateKeepsTheOccupancyHold() {
        let viewModel = makeViewModel()
        let tabID = UUID()
        let session = AgentModeViewModel.TabSession(tabID: tabID)
        let candidate = makeCandidate(tabID: tabID)
        func reported() -> DomainAgentSessionContextLoad? {
            AgentModeViewModel.observationSnapshot(for: session, candidate: candidate).context
        }
        session.selectedAgent = .devin

        _ = viewModel.ingestNonCodexUsageReport(
            promptTokens: nil, completionTokens: nil, contextUsedTokens: 180_000,
            modelContextWindow: 200_000, session: session
        )
        _ = viewModel.ingestNonCodexUsageReport(
            promptTokens: nil, completionTokens: nil, contextUsedTokens: nil,
            modelContextWindow: 200_000, session: session
        )
        viewModel.ingestNonCodexTurnFinalization(
            promptTokens: 95000, completionTokens: 4000, contextUsedTokens: 95000,
            modelContextWindow: nil, session: session
        )
        XCTAssertEqual(reported()?.usedTokens, 180_000, "The held occupancy stays exported")
        XCTAssertEqual(session.contextUsageSnapshot?.confidence, .bestEffort)
        XCTAssertEqual(reported()?.confidence, .exact)
        XCTAssertEqual(reported()?.windowTokens, 200_000)
    }

    /// The occupancy marker is stamped with the epoch that resets the session's vouches, so a
    /// figure reported under one model can never be re-vouched under another selection.
    func testACPModelSwitchCannotReuseThePreviousModelsOccupancy() {
        let viewModel = makeViewModel()
        let tabID = UUID()
        let session = AgentModeViewModel.TabSession(tabID: tabID)
        let candidate = makeCandidate(tabID: tabID)
        func reported() -> DomainAgentSessionContextLoad? {
            AgentModeViewModel.observationSnapshot(for: session, candidate: candidate).context
        }
        session.selectedAgent = .devin

        _ = viewModel.ingestNonCodexUsageReport(
            promptTokens: nil, completionTokens: nil, contextUsedTokens: 90000,
            modelContextWindow: 200_000, session: session
        )
        XCTAssertEqual(reported()?.usedTokens, 90000)

        session.selectedModelRaw = "other-model"
        viewModel.ingestNonCodexTurnFinalization(
            promptTokens: nil, completionTokens: nil, contextUsedTokens: nil,
            modelContextWindow: nil, session: session
        )
        XCTAssertNil(reported()?.usedTokens, "Model A's occupancy is never Model B's")
        XCTAssertNil(reported()?.windowTokens)
    }

    /// An occupancy-carrying `usage_update` that reports no usable count — including an explicit
    /// `used: 0` — releases the turn's hold, so the billed count evaluates on its own.
    func testACPZeroOccupancyUpdateReleasesTheOccupancyHold() {
        let viewModel = makeViewModel()
        let tabID = UUID()
        let session = AgentModeViewModel.TabSession(tabID: tabID)
        let candidate = makeCandidate(tabID: tabID)
        func reported() -> DomainAgentSessionContextLoad? {
            AgentModeViewModel.observationSnapshot(for: session, candidate: candidate).context
        }
        session.selectedAgent = .devin

        _ = viewModel.ingestNonCodexUsageReport(
            promptTokens: nil, completionTokens: nil, contextUsedTokens: 180_000,
            modelContextWindow: 200_000, session: session
        )
        _ = viewModel.ingestNonCodexUsageReport(
            promptTokens: nil, completionTokens: nil, contextUsedTokens: 0,
            modelContextWindow: nil, session: session
        )
        viewModel.ingestNonCodexTurnFinalization(
            promptTokens: 95000, completionTokens: 4000, contextUsedTokens: 95000,
            modelContextWindow: nil, session: session
        )
        // The ring keeps the billed figure; oversight never exports an ACP billed count.
        XCTAssertEqual(session.contextUsageSnapshot?.used, 95000)
        XCTAssertEqual(session.contextUsageSnapshot?.confidence, .bestEffort)
        XCTAssertNil(reported()?.usedTokens)
        XCTAssertNil(reported()?.confidence)
    }

    /// A finalization carrying no usable figure must not relabel a better snapshot.
    func testACPNoInfoTurnFinalizationKeepsTheExactLabel() {
        let viewModel = makeViewModel()
        let tabID = UUID()
        let session = AgentModeViewModel.TabSession(tabID: tabID)
        let candidate = makeCandidate(tabID: tabID)
        func reported() -> DomainAgentSessionContextLoad? {
            AgentModeViewModel.observationSnapshot(for: session, candidate: candidate).context
        }
        session.selectedAgent = .openCode

        _ = viewModel.ingestNonCodexUsageReport(
            promptTokens: nil, completionTokens: nil, contextUsedTokens: 180_000,
            modelContextWindow: 200_000, session: session
        )
        viewModel.ingestNonCodexTurnFinalization(
            promptTokens: nil, completionTokens: nil, contextUsedTokens: nil,
            modelContextWindow: nil, session: session
        )
        XCTAssertEqual(session.contextUsageSnapshot?.source, .acpUsageEvent)
        XCTAssertEqual(reported()?.usedTokens, 180_000)
        XCTAssertEqual(reported()?.confidence, .exact)
    }

    /// A fresh `usage_update` window that no longer fits the carried count drops the count rather
    /// than reporting impossible occupancy.
    func testACPFreshWindowDropsAnOversizedCarriedCount() {
        let viewModel = makeViewModel()
        let tabID = UUID()
        let session = AgentModeViewModel.TabSession(tabID: tabID)
        let candidate = makeCandidate(tabID: tabID)
        func reported() -> DomainAgentSessionContextLoad? {
            AgentModeViewModel.observationSnapshot(for: session, candidate: candidate).context
        }
        session.selectedAgent = .openCode

        _ = viewModel.ingestNonCodexUsageReport(
            promptTokens: nil, completionTokens: nil, contextUsedTokens: 150_000,
            modelContextWindow: 200_000, session: session
        )
        XCTAssertEqual(reported()?.usedTokens, 150_000)

        _ = viewModel.ingestNonCodexUsageReport(
            promptTokens: nil, completionTokens: nil, contextUsedTokens: nil,
            modelContextWindow: 128_000, session: session
        )
        XCTAssertNil(reported()?.usedTokens, "150k in a 128k window is not current")
        XCTAssertEqual(reported()?.windowTokens, 128_000)
        XCTAssertNil(reported()?.usedPercent)
        XCTAssertNil(
            session.codexContextUsage?.totalTotalTokens,
            "The mirrored total must drop too — the ring falls back to it when the count is absent"
        )
    }

    /// An ACP tab that never receives usage reports stays unknown rather than reporting a fallback.
    func testACPSessionWithoutUsageReportsStaysUnknown() {
        let viewModel = makeViewModel()
        let tabID = UUID()
        let session = AgentModeViewModel.TabSession(tabID: tabID)
        session.selectedAgent = .cursor
        XCTAssertNil(
            AgentModeViewModel.observationSnapshot(for: session, candidate: makeCandidate(tabID: tabID)).context
        )
        XCTAssertNil(session.contextUsageSnapshot)
        XCTAssertNil(session.codexContextUsage)
    }

    /// A provider switch to an ACP kind cannot inherit the previous provider's figures; the ACP
    /// provider's own first report is what gets reported.
    func testACPSwitchRequiresTheACPProvidersOwnReport() {
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

        session.selectedAgent = .openCode
        XCTAssertNil(reported(), "Claude's figures are never OpenCode's")

        // A window-only ACP report carries the foreign count forward in the store, but nothing
        // vouches it, so only the new window is exported.
        _ = viewModel.ingestNonCodexUsageReport(
            promptTokens: nil, completionTokens: nil, contextUsedTokens: nil,
            modelContextWindow: 256_000, session: session
        )
        XCTAssertNil(reported()?.usedTokens, "Claude's count is not vouched for OpenCode")
        XCTAssertEqual(reported()?.windowTokens, 256_000)

        // A declined billed count cannot vouch the carried foreign figure either.
        viewModel.ingestNonCodexTurnFinalization(
            promptTokens: 300_000, completionTokens: 9000, contextUsedTokens: 300_000,
            modelContextWindow: nil, session: session
        )
        XCTAssertNil(reported()?.usedTokens, "A declined report cannot vouch a foreign count")

        // A plausible billed count becomes the best-effort figure.
        viewModel.ingestNonCodexTurnFinalization(
            promptTokens: 95000, completionTokens: 4000, contextUsedTokens: 95000,
            modelContextWindow: nil, session: session
        )
        // The ring keeps the billed figure; oversight never exports an ACP billed count.
        XCTAssertEqual(session.contextUsageSnapshot?.used, 95000)
        XCTAssertEqual(session.contextUsageSnapshot?.confidence, .bestEffort)
        XCTAssertNil(reported()?.usedTokens)
        XCTAssertNil(reported()?.confidence)

        _ = viewModel.ingestNonCodexUsageReport(
            promptTokens: nil, completionTokens: nil, contextUsedTokens: 40000,
            modelContextWindow: 256_000, session: session
        )
        XCTAssertEqual(reported()?.usedTokens, 40000)
        XCTAssertEqual(reported()?.windowTokens, 256_000)
        XCTAssertEqual(reported()?.confidence, .exact)
    }

    /// ACP usage capture is telemetry-only: it must not write persisted per-turn usage rows or
    /// consume the pending user-token queue (no accounting estimator for ACP providers).
    func testACPUsageCaptureDoesNotPersistTurnRows() {
        let viewModel = makeViewModel()
        let tabID = UUID()
        let session = AgentModeViewModel.TabSession(tabID: tabID)
        session.selectedAgent = .openCode

        _ = viewModel.ingestNonCodexUsageReport(
            promptTokens: nil, completionTokens: nil, contextUsedTokens: 90000,
            modelContextWindow: 200_000, session: session
        )
        viewModel.ingestNonCodexTurnFinalization(
            promptTokens: 95000, completionTokens: 4000, contextUsedTokens: 95000,
            modelContextWindow: nil, session: session
        )
        XCTAssertTrue(session.providerTokenUsageByTurn.isEmpty)
        XCTAssertTrue(session.pendingNonCodexUserInputTokenQueue.isEmpty)
        XCTAssertNil(session.activeNonCodexTurnTokenAccumulator)
    }

    // MARK: - Review follow-ups (#1077)

    /// Claude's end-of-turn rebuild relabels the snapshot `bestEffort` without changing its figures;
    /// oversight keeps the label the count was vouched with, so an idle target still reads `exact`.
    func testClaudeIdleCountKeepsTheLabelItWasVouchedWith() throws {
        let viewModel = makeViewModel()
        let tabID = UUID()
        let session = AgentModeViewModel.TabSession(tabID: tabID)
        session.selectedAgent = .claudeCode
        session.activeNonCodexTurnTokenAccumulator = AgentModeViewModel.NonCodexTurnTokenAccumulator()

        _ = viewModel.ingestNonCodexUsageReport(
            promptTokens: 3, completionTokens: nil, contextUsedTokens: 152_500,
            modelContextWindow: nil, session: session
        )
        viewModel.ingestNonCodexTurnFinalization(
            promptTokens: 2_400_000, completionTokens: 8000, contextUsedTokens: nil,
            modelContextWindow: 200_000, session: session
        )

        let context = try XCTUnwrap(
            AgentModeViewModel.observationSnapshot(for: session, candidate: makeCandidate(tabID: tabID)).context
        )
        XCTAssertEqual(context.usedTokens, 152_500)
        XCTAssertEqual(context.windowTokens, 200_000)
        XCTAssertEqual(context.confidence, .exact)
    }

    /// `used` is required in `usage_update`, so `used: 0` is a real report: the previous count is no
    /// longer current in the ring or in oversight.
    func testACPExplicitZeroOccupancyDropsThePreviousCount() throws {
        let viewModel = makeViewModel()
        let tabID = UUID()
        let session = AgentModeViewModel.TabSession(tabID: tabID)
        session.selectedAgent = .openCode

        _ = viewModel.ingestNonCodexUsageReport(
            promptTokens: nil, completionTokens: nil, contextUsedTokens: 180_000,
            modelContextWindow: 200_000, session: session
        )
        _ = viewModel.ingestNonCodexUsageReport(
            promptTokens: nil, completionTokens: nil, contextUsedTokens: 0,
            modelContextWindow: 200_000, session: session
        )

        XCTAssertNil(session.contextUsageSnapshot?.used)
        XCTAssertNil(session.vouchedContextCount)
        let context = try XCTUnwrap(
            AgentModeViewModel.observationSnapshot(for: session, candidate: makeCandidate(tabID: tabID)).context
        )
        XCTAssertNil(context.usedTokens)
        XCTAssertEqual(context.windowTokens, 200_000)
        XCTAssertNil(context.confidence)

        // Also without a window in the same report.
        _ = viewModel.ingestNonCodexUsageReport(
            promptTokens: nil, completionTokens: nil, contextUsedTokens: 150_000,
            modelContextWindow: nil, session: session
        )
        XCTAssertEqual(session.contextUsageSnapshot?.used, 150_000)
        _ = viewModel.ingestNonCodexUsageReport(
            promptTokens: nil, completionTokens: nil, contextUsedTokens: 0,
            modelContextWindow: nil, session: session
        )
        XCTAssertNil(session.contextUsageSnapshot?.used)
    }

    /// A vouch appearing or disappearing changes the export even on an otherwise idle target, so it
    /// republishes, once per change; a vouch moving between figures rides the report that wrote them.
    func testVouchPresenceChangesRepublishTheSnapshotOnce() {
        let viewModel = makeViewModel()
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        session.selectedAgent = .claudeCode
        var signals = 0
        let subscription = session.monitorObservationSignal.sink { signals += 1 }
        defer { subscription.cancel() }

        _ = viewModel.ingestNonCodexUsageReport(
            promptTokens: nil, completionTokens: nil, contextUsedTokens: 90000,
            modelContextWindow: nil, session: session
        )
        XCTAssertNotNil(session.vouchedContextCount)
        XCTAssertEqual(signals, 1, "Establishing a vouch republishes")

        _ = viewModel.ingestNonCodexUsageReport(
            promptTokens: nil, completionTokens: nil, contextUsedTokens: 95000,
            modelContextWindow: nil, session: session
        )
        XCTAssertEqual(session.vouchedContextCount?.tokens, 95000)
        XCTAssertEqual(signals, 1, "A vouch moving to a new figure needs no extra signal")

        session.selectedModelRaw = "a-different-model"
        XCTAssertNil(session.vouchedContextCount)
        XCTAssertEqual(signals, 2, "A model switch on an idle target republishes the withdrawn load")

        session.contextCompactedAt = Date()
        XCTAssertEqual(signals, 2, "Nothing left to withdraw, nothing to republish")
    }

    /// The same figure re-vouched by a different kind of report changes only the exported label, and
    /// that alone republishes.
    func testALabelOnlyChangeRepublishes() throws {
        let tabID = UUID()
        let session = AgentModeViewModel.TabSession(tabID: tabID)
        session.selectedAgent = .claudeCode
        session.contextUsageSnapshot = usage(40000, nil, confidence: .bestEffort)
        session.noteLiveContextUsageReport(contextUsedTokens: nil, promptTokens: 40000, modelContextWindow: nil)
        var signals = 0
        let subscription = session.monitorObservationSignal.sink { signals += 1 }
        defer { subscription.cancel() }

        session.noteLiveContextUsageReport(contextUsedTokens: 40000, promptTokens: nil, modelContextWindow: nil)

        let context = try XCTUnwrap(
            AgentModeViewModel.observationSnapshot(for: session, candidate: makeCandidate(tabID: tabID)).context
        )
        XCTAssertEqual(context.confidence, .exact)
        XCTAssertEqual(signals, 1)
    }

    /// A figure restored at launch is not current; a live report confirming the identical figure
    /// leaves the stored snapshot unchanged but makes it current, and that alone republishes.
    func testReconfirmingAnUnchangedRestoredFigureRepublishes() {
        let viewModel = makeViewModel()
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        session.selectedAgent = .codexExec
        session.contextUsageSnapshot = usage(400_000, 1_000_000, source: .codexNativeUsage)
        XCTAssertNil(session.vouchedContextCount)
        var signals = 0
        let subscription = session.monitorObservationSignal.sink { signals += 1 }
        defer { subscription.cancel() }

        session.noteLiveContextUsageReport(contextUsedTokens: 400_000, promptTokens: nil, modelContextWindow: 1_000_000)

        XCTAssertNotNil(session.vouchedContextCount)
        XCTAssertNotNil(session.vouchedContextWindow)
        XCTAssertEqual(signals, 1, "Count and window established together republish once")
    }

    func testClearingBothVouchesRepublishesOnce() {
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        session.selectedAgent = .claudeCode
        session.contextUsageSnapshot = usage(90000, 200_000)
        session.noteLiveContextUsageReport(contextUsedTokens: 90000, promptTokens: nil, modelContextWindow: 200_000)
        var signals = 0
        let subscription = session.monitorObservationSignal.sink { signals += 1 }
        defer { subscription.cancel() }

        session.contextUsageSnapshot = nil

        XCTAssertNil(session.vouchedContextCount)
        XCTAssertNil(session.vouchedContextWindow)
        XCTAssertEqual(signals, 1)
    }

    /// A window-only `usage_update` relabels the ring's carried count `best_effort`; the occupancy the
    /// provider reported is still what oversight exports, as `exact`.
    func testACPWindowOnlyUpdateCannotDowngradeTheExportedOccupancyLabel() throws {
        let viewModel = makeViewModel()
        let tabID = UUID()
        let session = AgentModeViewModel.TabSession(tabID: tabID)
        session.selectedAgent = .devin
        viewModel.acpContextUsageEstimator.beginTurn(session: session, initialMessage: "turn")

        _ = viewModel.ingestNonCodexUsageReport(
            promptTokens: nil, completionTokens: nil, contextUsedTokens: 100_000,
            modelContextWindow: 200_000, session: session
        )
        _ = viewModel.ingestNonCodexUsageReport(
            promptTokens: nil, completionTokens: nil, contextUsedTokens: nil,
            modelContextWindow: 250_000, session: session
        )
        viewModel.ingestNonCodexTurnFinalization(
            promptTokens: 120_000, completionTokens: 900, contextUsedTokens: 120_000,
            modelContextWindow: nil, session: session
        )

        let context = try XCTUnwrap(
            AgentModeViewModel.observationSnapshot(for: session, candidate: makeCandidate(tabID: tabID)).context
        )
        XCTAssertEqual(context.usedTokens, 100_000)
        XCTAssertEqual(context.confidence, .exact)
    }

    /// The same figure can move between a ring-only billed count and an exported occupancy count
    /// without the stored snapshot's number changing; either move republishes.
    func testASameFigureMovingBetweenBilledAndOccupancyRepublishes() {
        let viewModel = makeViewModel()
        let tabID = UUID()
        let session = AgentModeViewModel.TabSession(tabID: tabID)
        let candidate = makeCandidate(tabID: tabID)
        func reported() -> DomainAgentSessionContextLoad? {
            AgentModeViewModel.observationSnapshot(for: session, candidate: candidate).context
        }
        session.selectedAgent = .grokBuild
        var signals = 0
        let subscription = session.monitorObservationSignal.sink { signals += 1 }
        defer { subscription.cancel() }

        viewModel.acpContextUsageEstimator.beginTurn(session: session, initialMessage: "one")
        viewModel.ingestNonCodexTurnFinalization(
            promptTokens: 95000, completionTokens: 400, contextUsedTokens: 95000,
            modelContextWindow: nil, session: session
        )
        XCTAssertEqual(session.contextUsageSnapshot?.used, 95000)
        XCTAssertNil(session.vouchedContextCount, "A billed count never takes a vouch")
        XCTAssertNil(reported()?.usedTokens)
        let afterBilled = signals

        _ = viewModel.ingestNonCodexUsageReport(
            promptTokens: nil, completionTokens: nil, contextUsedTokens: 95000,
            modelContextWindow: nil, session: session
        )
        XCTAssertEqual(reported()?.usedTokens, 95000)
        XCTAssertEqual(reported()?.confidence, .exact)
        XCTAssertEqual(signals, afterBilled + 1, "Occupancy confirming the same figure republishes")

        viewModel.acpContextUsageEstimator.beginTurn(session: session, initialMessage: "two")
        viewModel.ingestNonCodexTurnFinalization(
            promptTokens: 95000, completionTokens: 400, contextUsedTokens: 95000,
            modelContextWindow: nil, session: session
        )
        XCTAssertEqual(session.contextUsageSnapshot?.source, .turnFinalization)
        XCTAssertNil(reported()?.usedTokens)
        XCTAssertEqual(signals, afterBilled + 2, "A billed count replacing occupancy republishes")
    }

    /// The per-turn ACP occupancy marker lives on the session, so a new session object can never
    /// inherit another's hold.
    func testACPOccupancyMarkerBelongsToItsSession() {
        let viewModel = makeViewModel()
        let first = AgentModeViewModel.TabSession(tabID: UUID())
        first.selectedAgent = .devin
        _ = viewModel.ingestNonCodexUsageReport(
            promptTokens: nil, completionTokens: nil, contextUsedTokens: 120_000,
            modelContextWindow: 200_000, session: first
        )
        XCTAssertNotNil(first.acpOccupancyReportThisTurn)

        let second = AgentModeViewModel.TabSession(tabID: UUID())
        second.selectedAgent = .devin
        XCTAssertNil(second.acpOccupancyReportThisTurn)
        XCTAssertFalse(viewModel.acpContextUsageEstimator.hasOccupancyReportThisTurn(session: second))

        viewModel.acpContextUsageEstimator.beginTurn(session: first, initialMessage: "next")
        XCTAssertNil(first.acpOccupancyReportThisTurn)
    }

    func testConfidenceIsNullWheneverNoCountIsKnown() {
        XCTAssertNil(DomainAgentSessionContextLoad(usedTokens: nil, windowTokens: 200_000, confidence: .inferred)?.confidence)
        XCTAssertEqual(
            DomainAgentSessionContextLoad(usedTokens: 1, windowTokens: nil, confidence: .inferred)?.confidence,
            .inferred
        )
        let rendered = AgentSessionLinkResponseRenderer.contextLoadValue(
            DomainAgentSessionContextLoad(usedTokens: nil, windowTokens: 200_000, confidence: .exact)
        )
        guard case .null? = rendered.objectValue?["confidence"] else {
            return XCTFail("confidence must render as null without a count")
        }
    }
}
