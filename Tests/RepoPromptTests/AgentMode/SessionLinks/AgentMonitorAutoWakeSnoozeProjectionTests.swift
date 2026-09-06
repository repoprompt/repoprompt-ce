import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

/// Outbound monitor projection of observer-local Auto-wake policy, and the architecture that keeps
/// it a projection.
///
/// The rows the dashboard renders come from the link authority, but snooze and effective selection
/// live on the exact observer session. This suite pins where the two are joined, that the join reads
/// without mutating, and that the row-action ownership the monitor already had was reused rather
/// than duplicated into a second dispatcher on the way.
@MainActor
final class AgentMonitorAutoWakeSnoozeProjectionTests: XCTestCase {
    private var retained: [AgentModeViewModel] = []
    private var retainedWorkspaces: [WorkspaceManagerViewModel] = []

    override func tearDown() {
        retained.removeAll()
        retainedWorkspaces.removeAll()
        super.tearDown()
    }

    private struct Fixture {
        let viewModel: AgentModeViewModel
        let session: AgentModeViewModel.TabSession
        let tabID: UUID
        let endpoint: DomainAgentSessionLinkEndpointIdentity
        let targetSessionID: UUID
        let reference: DomainAgentSessionLinkReference
        let clock: AgentSessionLinkAutoWakeSnoozeTestClock
    }

    private func makeFixture() throws -> Fixture {
        let tabID = UUID()
        let viewModel = AgentModeViewModel(
            testWindowID: 1,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in
                LifecycleNoopCodexController(recorder: LifecycleRecorder())
            },
            connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
            mcpServerEnabler: { true }
        )
        retained.append(viewModel)
        retainedWorkspaces.append(AgentSessionLinkEndpointTestSupport.installWorkspace(
            on: viewModel,
            tabID: tabID,
            name: "Oversee snooze projection"
        ))
        let session = viewModel.session(for: tabID)
        session.selectedAgent = .claudeCode
        session.hasLoadedPersistedState = true
        // This suite exercises the projection transition from master-off to granular/master-on;
        // keep that baseline explicit now that fresh live sessions default Auto-wake on.
        session.oversight.autoWakeOnUpdates = false
        _ = try XCTUnwrap(
            viewModel.test_ensureSessionBoundToTab(session),
            "expected a durable persistent binding"
        )
        let clock = AgentSessionLinkAutoWakeSnoozeTestClock()
        session.oversight.snoozeClock = clock.clock
        return try Fixture(
            viewModel: viewModel,
            session: session,
            tabID: tabID,
            endpoint: AgentSessionLinkEndpointTestSupport.endpoint(viewModel, tabID: tabID),
            targetSessionID: UUID(),
            reference: DomainAgentSessionLinkReference(linkID: UUID(), generation: 4),
            clock: clock
        )
    }

    private func props(_ fixture: Fixture) -> AgentMonitorPillProps {
        AgentMonitorPillProps(
            sessionID: fixture.endpoint.sessionID,
            sidebarOversightMenu: nil,
            outbound: [AgentMonitorPillProps.Outbound(
                linkID: fixture.reference.linkID,
                generation: fixture.reference.generation,
                targetSessionID: fixture.targetSessionID,
                targetEndpoint: AgentSessionLinkIdentityTestSupport.endpoint(
                    sessionID: fixture.targetSessionID
                ),
                displayName: "Build API",
                providerDisplayName: "Codex CLI",
                locationLabel: "worktree/feature",
                status: .idle
            )],
            inbound: [],
            recentNotices: [],
            canAddReason: nil
        )
    }

    /// Installs one record the way the coordinator would, without going through a mutation: this
    /// suite is about the read, not about the policy.
    private func installSnooze(
        _ fixture: Fixture,
        seconds: Int,
        origin: AgentSessionLinkAutoWakeSnoozeOrigin = .user
    ) {
        let key = AgentSessionLinkAutoWakeSnoozeKey(
            observerEndpoint: fixture.endpoint,
            reference: fixture.reference
        )
        fixture.session.oversight.autoWakeSnoozes[key] = AgentSessionLinkAutoWakeSnoozeRecord(
            key: key,
            deadline: fixture.clock.instant.advanced(by: .seconds(seconds)),
            origin: origin
        )
    }

    private func publishedRow(_ fixture: Fixture) throws -> AgentMonitorPillProps.Outbound {
        fixture.viewModel.agentSessionLinkPublishProjection(props(fixture), to: fixture.endpoint)
        let published = try XCTUnwrap(
            fixture.viewModel.monitorPillPropsByEndpoint[fixture.endpoint],
            "the exact incarnation must receive its own projection"
        )
        return try XCTUnwrap(published.outbound.first)
    }

    // MARK: - Projection

    func testPublishedRowsCarryTheObserversSnoozeAndItsSetter() throws {
        let fixture = try makeFixture()
        installSnooze(fixture, seconds: 540, origin: .agent)

        let row = try publishedRow(fixture)
        let snooze = try XCTUnwrap(row.autoWakeSnooze)
        XCTAssertEqual(snooze.origin, .agent)
        XCTAssertEqual(snooze.remainingMinutes(now: fixture.clock.wallNow), 9)
        // Derived from wall time plus the monotonic remainder, and quantized, so republishing the
        // same policy produces an equal value rather than repainting the dashboard every pass.
        XCTAssertEqual(row.autoWakeSnooze, try publishedRow(fixture).autoWakeSnooze)
    }

    /// Effective selection is the master setting or this lane's own granular selection, read live.
    func testEffectiveSelectionFollowsTheMasterSettingAndTheGranularSelection() throws {
        let fixture = try makeFixture()
        XCTAssertFalse(
            try publishedRow(fixture).isAutoWakeEffectivelySelected,
            "master Auto-wake off plus no granular lane selection leaves the lane unable to admit"
        )

        fixture.session.oversight.autoWakeTargetSessionIDs = [fixture.targetSessionID]
        XCTAssertTrue(try publishedRow(fixture).isAutoWakeEffectivelySelected)

        fixture.session.oversight.autoWakeTargetSessionIDs = []
        fixture.session.oversight.autoWakeOnUpdates = true
        XCTAssertTrue(
            try publishedRow(fixture).isAutoWakeEffectivelySelected,
            "the master setting covers every lane"
        )
    }

    /// A deselected lane keeps its snooze in the projection, because Clear must stay reachable.
    func testDeselectionHidesNothingAboutAnActiveSnooze() throws {
        let fixture = try makeFixture()
        installSnooze(fixture, seconds: 600)
        let row = try publishedRow(fixture)
        XCTAssertNotNil(row.autoWakeSnooze)
        XCTAssertFalse(row.isAutoWakeEffectivelySelected)
    }

    /// An elapsed record is inactive for the projection too, and reading it changes nothing.
    func testElapsedRecordProjectsNothingAndTheReadRemovesNothing() throws {
        let fixture = try makeFixture()
        installSnooze(fixture, seconds: 600)
        XCTAssertNotNil(try publishedRow(fixture).autoWakeSnooze)

        // Elapsed, but nothing has cleaned it up yet: the delayed-timer state.
        fixture.clock.advanceWithoutFiring(seconds: 601)
        XCTAssertNil(
            try publishedRow(fixture).autoWakeSnooze,
            "expiry is decided by the deadline, not by whether bookkeeping caught up"
        )
        XCTAssertEqual(
            fixture.session.oversight.autoWakeSnoozes.count,
            1,
            "a projection read must not remove records"
        )
        XCTAssertEqual(
            fixture.clock.registeredSleepCount,
            0,
            "a projection read must not arm a deadline task"
        )
        XCTAssertNil(fixture.session.oversight.snoozeTaskToken)
        XCTAssertNil(fixture.session.oversight.pendingAutoWake, "a read must not re-drive the pipeline")
    }

    /// A record filed under another incarnation is never inherited by the one that replaced it.
    func testASupersededIncarnationsRecordIsNotProjected() throws {
        let fixture = try makeFixture()
        let superseded = DomainAgentSessionLinkEndpointIdentity(
            windowID: fixture.endpoint.windowID,
            workspaceID: fixture.endpoint.workspaceID,
            tabID: fixture.endpoint.tabID,
            sessionID: fixture.endpoint.sessionID,
            persistentBindingGeneration: fixture.endpoint.persistentBindingGeneration,
            bindingTransitionGeneration: fixture.endpoint.bindingTransitionGeneration &+ 1
        )
        let key = AgentSessionLinkAutoWakeSnoozeKey(
            observerEndpoint: superseded,
            reference: fixture.reference
        )
        fixture.session.oversight.autoWakeSnoozes[key] = AgentSessionLinkAutoWakeSnoozeRecord(
            key: key,
            deadline: fixture.clock.instant.advanced(by: .seconds(600)),
            origin: .user
        )
        XCTAssertNil(try publishedRow(fixture).autoWakeSnooze)
    }

    /// A superseded link generation is a different lane, so its record never renders on the current
    /// row.
    func testAStaleLinkGenerationIsNotProjectedOntoTheCurrentRow() throws {
        let fixture = try makeFixture()
        let stale = DomainAgentSessionLinkReference(
            linkID: fixture.reference.linkID,
            generation: fixture.reference.generation &- 1
        )
        let key = AgentSessionLinkAutoWakeSnoozeKey(
            observerEndpoint: fixture.endpoint,
            reference: stale
        )
        fixture.session.oversight.autoWakeSnoozes[key] = AgentSessionLinkAutoWakeSnoozeRecord(
            key: key,
            deadline: fixture.clock.instant.advanced(by: .seconds(600)),
            origin: .user
        )
        XCTAssertNil(try publishedRow(fixture).autoWakeSnooze)
    }

    // MARK: - Action ownership

    /// The monitor already had exactly one row-action architecture, and the snooze had to reuse it.
    ///
    /// These are source-shape assertions because what is protected is an ownership boundary rather
    /// than a value: a second dispatcher, action closures carried in props, or an optimistic local
    /// copy of authoritative state would all behave correctly in a unit test and still be the defect.
    func testMonitorActionOwnershipStaysWithTheViewAndPropsStayDeclarative() throws {
        let projection = try source(
            "Sources/RepoPrompt/Features/AgentMode/Runtime/SessionLinks/AgentModeViewModel+SessionLinks.swift"
        )
        // Projection only: it reads the pure snooze projection and writes props, and it neither
        // mutates policy nor grows an action vocabulary of its own.
        XCTAssertTrue(projection.contains("agentSessionLinkAutoWakeSnoozeProjection("))
        XCTAssertFalse(projection.contains("MutateAutoWakeSnooze"))
        XCTAssertFalse(projection.contains("mutateAutoWakeSnooze"))
        for owned in ["busyRowKeys", "rowFeedbackByRowKey", "AgentMonitorRowAction"] {
            XCTAssertFalse(projection.contains(owned), owned)
        }

        let view = try source(
            "Sources/RepoPrompt/Features/AgentMode/Views/Components/AgentMonitorPill.swift"
        )
        // The view owns the action, builds the exact generation-qualified reference itself, and calls
        // the bridge directly — the same pattern Seen and Unlink already use.
        XCTAssertTrue(view.contains("AgentSessionLinkRuntimeBridge.shared.mutateAutoWakeSnooze("))
        XCTAssertTrue(view.contains("origin: .user"))
        XCTAssertTrue(view.contains("linkID: row.linkID,\n            generation: row.generation"))
        // Row-local action state is keyed by the generation-qualified row, so an action that outlives
        // a relink settles against the retired row instead of the replacement that reused its ID.
        XCTAssertTrue(view.contains("busyRowKeys.insert"))
        XCTAssertTrue(view.contains("rowFeedbackByRowKey"))
        XCTAssertFalse(view.contains("busyLinkIDs"))
        XCTAssertFalse(view.contains("actionFailureByLinkID"))

        let models = try source(
            "Sources/RepoPrompt/Features/AgentMode/ViewModels/UI/AgentMonitorPillModels.swift"
        )
        // Props carry state, not behaviour: no closure, no busy flag, no error, no dispatcher.
        let outboundStart = try XCTUnwrap(models.range(of: "struct Outbound: Equatable, Identifiable {"))
        let outbound = String(models[outboundStart.lowerBound...].prefix(4000))
        for forbidden in ["() -> Void", "@escaping", "isBusy", "errorMessage", "dispatcher"] {
            XCTAssertFalse(outbound.contains(forbidden), forbidden)
        }
    }

    /// The snooze a row displays is overlaid when monitor props are *published*, and nothing observes
    /// an observer's own session — observations are installed per overseen target. So a snooze change
    /// that does not republish leaves the row asserting a policy that no longer exists, which is what
    /// made deadline expiry display "snooze expired" indefinitely.
    ///
    /// A source-shape assertion because what is protected is an ownership property rather than a
    /// value: every writer must reach the repaint, and it must have exactly one owner. Routing it
    /// from the bridge mutation instead covers set/extend and silently misses clear, expiry and
    /// pruning.
    func testEverySnoozeWriteRepaintsThroughTheSingleMapCommit() throws {
        let coordinator = try source(
            "Sources/RepoPrompt/Features/AgentMode/Runtime/SessionLinks/AgentModeViewModel+SessionLinkAutoWake.swift"
        )
        XCTAssertEqual(
            coordinator.components(separatedBy: "session.oversight.autoWakeSnoozes = ").count - 1,
            1,
            "the map must have exactly one assignment site for the repaint to be unmissable"
        )
        XCTAssertEqual(
            coordinator.components(separatedBy: "requestObserverLocalPolicyRepaint(").count - 1,
            1,
            "and that site must be the only thing asking for the repaint"
        )
        // Counting the single owner is only half the invariant: a writer that stops routing through
        // the commit keeps both counts at 1 and still reintroduces the stale row. Pin the callers too
        // — the mutation, the reconcile/expiry boundary, and the incarnation prune.
        XCTAssertGreaterThanOrEqual(
            coordinator.components(separatedBy: "agentSessionLinkCommitAutoWakeSnoozes(").count - 1,
            4,
            "every snooze writer must reach the map commit, not assign around it"
        )
        for writer in [
            "func agentSessionLinkMutateAutoWakeSnooze(",
            "func agentSessionLinkReconcileAutoWakeSnoozes(",
            "func agentSessionLinkPruneAutoWakeSnoozeState("
        ] {
            XCTAssertTrue(
                Self.body(of: writer, in: coordinator)?.contains("agentSessionLinkCommitAutoWakeSnoozes(")
                    ?? false,
                writer
            )
        }

        let bridge = try source(
            "Sources/RepoPrompt/Features/AgentMode/Runtime/SessionLinks/AgentSessionLinkRuntimeBridge.swift"
        )
        XCTAssertFalse(
            try XCTUnwrap(Self.body(of: "func mutateAutoWakeSnooze(", in: bridge))
                .contains("requestMonitorProjectionRefresh"),
            "the bridge mutation must not own a second repaint: it covers only set and extend"
        )
    }

    /// One declaration's text, bounded by the next declaration rather than by a byte count, so the
    /// assertions above cannot quietly stop covering a function that grew.
    private static func body(of declaration: String, in source: String) -> String? {
        guard let start = source.range(of: declaration) else { return nil }
        let rest = source[start.upperBound...]
        // The *earliest* terminator, and `private func` is one of them. Taking the first that merely
        // exists would run past a private successor to some later plain `func`, and the assertions
        // above would then be satisfied by a callee's own declaration text instead of by a call in
        // the function under test.
        let terminator = ["\n    func ", "\n    private func ", "\n}"]
            .compactMap { rest.range(of: $0)?.lowerBound }
            .min()
        guard let terminator else { return String(rest) }
        return String(rest[..<terminator])
    }

    private func source(_ relativePath: String, file: StaticString = #filePath) throws -> String {
        var directory = URL(fileURLWithPath: "\(file)")
        while directory.pathComponents.count > 1 {
            directory.deleteLastPathComponent()
            let candidate = directory.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
        }
        throw XCTSkip("source file not found: \(relativePath)")
    }
}
