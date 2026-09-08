import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

/// Presentation-only projection refresh exercised through execution-location invalidation.
///
/// Location is UI-only and lives on observer-side outbound rows alone, so the authoritative
/// projection path cannot carry it: a worktree, branch, or workspace-name edit produces no authority
/// event, and the equal location-free target snapshot deduplicates. These tests pin the two halves
/// that make the dedicated path safe — the effective-label delta that triggers it, and its complete
/// absence of authority, prompt, snapshot, and advertisement side effects.
@MainActor
final class AgentSessionLinkLocationPresentationRefreshTests: XCTestCase {
    // MARK: - Fake host

    /// Endpoint host reduced to what a projection repaint needs. Every other conformance requirement
    /// fails closed, so a test that accidentally reached a send, read, or observation path would not
    /// silently pass.
    private final class FakeEndpointHost: AgentSessionLinkEndpointHost {
        var candidates: [AgentSessionLinkEndpointCandidate] = []
        var publishedPropsByEndpoint: [DomainAgentSessionLinkEndpointIdentity: AgentMonitorPillProps] = [:]
        var publishedInventoriesByEndpoint:
            [DomainAgentSessionLinkEndpointIdentity: AgentSessionLinkPromptInventory] = [:]
        private(set) var inventoryPublicationCount = 0
        private(set) var passiveNoticePublicationCount = 0
        private(set) var observationSnapshotCount = 0

        func agentSessionLinkCandidates() -> [AgentSessionLinkEndpointCandidate] {
            candidates
        }

        func agentSessionLinkObservationSnapshot(
            for candidate: AgentSessionLinkEndpointCandidate
        ) -> DomainAgentSessionObservationSnapshot {
            observationSnapshotCount += 1
            return DomainAgentSessionObservationSnapshot(
                sessionID: candidate.sessionID,
                displayName: candidate.displayName,
                providerDisplayName: candidate.providerDisplayName,
                status: .idle,
                idleForSend: true,
                pendingInteractionKind: nil,
                latestVisibleAssistantPreview: "seeded",
                visibleRowCount: 1,
                lastActivityAt: Date(timeIntervalSince1970: 100)
            )
        }

        func agentSessionLinkStatusProjection(
            for _: AgentSessionLinkEndpointCandidate
        ) -> AgentSessionLinkStatusProjection? {
            AgentSessionLinkStatusProjection(status: .idle, pendingInteractionKind: nil)
        }

        func agentSessionLinkInstallObservation(
            for _: AgentSessionLinkEndpointCandidate,
            onChange _: @escaping @MainActor () -> Void
        ) -> AgentSessionLinkObservationToken? {
            AgentSessionLinkObservationToken {}
        }

        func agentSessionLinkPublishProjection(
            _ props: AgentMonitorPillProps,
            to endpoint: DomainAgentSessionLinkEndpointIdentity
        ) {
            publishedPropsByEndpoint[endpoint] = props
        }

        func agentSessionLinkPublishPromptInventory(
            _ inventory: AgentSessionLinkPromptInventory,
            to endpoint: DomainAgentSessionLinkEndpointIdentity
        ) {
            inventoryPublicationCount += 1
            publishedInventoriesByEndpoint[endpoint] = inventory
        }

        /// Counted for the same reason the inventory is: the presentation-only repaint must publish
        /// rows and nothing an agent could be told.
        func agentSessionLinkPublishPassiveStatusNotices(
            _: AgentSessionLinkPassiveStatusNotices.Snapshot,
            to _: DomainAgentSessionLinkEndpointIdentity
        ) {
            passiveNoticePublicationCount += 1
        }

        func agentSessionLinkWithholdPromptInventory(
            for _: DomainAgentSessionLinkEndpointIdentity
        ) -> UInt64? {
            nil
        }

        func agentSessionLinkReleasePromptInventoryHold(
            _: UInt64?,
            for _: DomainAgentSessionLinkEndpointIdentity,
            publishing _: AgentSessionLinkPromptInventory?
        ) {}

        func agentSessionLinkTranscriptPage(
            for _: AgentSessionLinkEndpointCandidate,
            anchor _: AgentSessionLinkTranscriptAnchor?,
            direction _: AgentSessionLinkReadDirectionInput,
            maxItems _: Int,
            maxOutputBytes _: Int,
            readerSessionID _: UUID?
        ) async -> Result<AgentSessionLinkTranscriptPage, AgentSessionLinkReadUnavailableReason> {
            .failure(.targetLoading)
        }

        func agentSessionLinkSendLiveness(
            observer: DomainAgentSessionLinkEndpointIdentity,
            target: DomainAgentSessionLinkEndpointIdentity
        ) -> AgentSessionLinkSendLiveness {
            let live = candidates.map(\.domainEndpoint)
            return AgentSessionLinkSendLiveness(
                observerEndpointIsLive: live.contains(observer),
                targetEndpointIsLive: live.contains(target),
                targetWindowIsClosing: false
            )
        }

        func agentSessionLinkPerformSend(
            to _: AgentSessionLinkEndpointCandidate,
            request _: AgentSessionLinkSendRequest,
            liveness _: @escaping AgentSessionLinkSendLivenessProbe,
            commitAuthorization _: @MainActor () async -> AgentSessionLinkSendCommitOutcome
        ) async -> AgentSessionLinkSendTransactionOutcome {
            .blocked(.targetNotIdle)
        }
    }

    /// Records the sessions the bridge asks to re-advertise `agent_session_link` for.
    private actor ToolAdvertisementRecorder {
        private(set) var invalidatedSessionIDs: [UUID] = []

        func record(_ sessionID: UUID) {
            invalidatedSessionIDs.append(sessionID)
        }

        func count() -> Int {
            invalidatedSessionIDs.count
        }
    }

    // MARK: - Fixtures

    private var retained: [AgentModeViewModel] = []
    private var retainedManagers: [WorkspaceManagerViewModel] = []
    private var previousExactSink: ((Set<DomainAgentSessionLinkEndpointIdentity>) -> Void)?
    private var previousObservedSink: ((UUID?) -> Void)?

    override func setUp() {
        super.setUp()
        previousExactSink = AgentSessionLinkLocationInvalidationSink.refreshExactTargets
        previousObservedSink = AgentSessionLinkLocationInvalidationSink.refreshObservedTargets
    }

    override func tearDown() {
        // Process-wide seam: a leaked recorder would fire inside every later suite that renames a
        // workspace or commits a worktree binding.
        AgentSessionLinkLocationInvalidationSink.refreshExactTargets = previousExactSink
        AgentSessionLinkLocationInvalidationSink.refreshObservedTargets = previousObservedSink
        retained.removeAll()
        retainedManagers.removeAll()
        super.tearDown()
    }

    private struct BridgeFixture {
        let authority: DomainAgentSessionLinkAuthority
        let host: FakeEndpointHost
        let bridge: AgentSessionLinkRuntimeBridge
        let observer: AgentSessionLinkEndpointCandidate
        let target: AgentSessionLinkEndpointCandidate
        let advertisement: ToolAdvertisementRecorder
    }

    private func makeCandidate(
        windowID: Int,
        displayName: String,
        locationLabel: String
    ) -> AgentSessionLinkEndpointCandidate {
        AgentSessionLinkEndpointCandidate(
            windowID: windowID,
            workspaceID: UUID(),
            tabID: UUID(),
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
            displayName: displayName,
            providerDisplayName: "Codex CLI",
            locationLabel: locationLabel
        )
    }

    /// The same incarnation with a new effective location label, which is exactly what a worktree,
    /// branch, workspace-rename, or global-label edit produces in the target's own window.
    private func relabeled(
        _ candidate: AgentSessionLinkEndpointCandidate,
        locationLabel: String
    ) -> AgentSessionLinkEndpointCandidate {
        AgentSessionLinkEndpointCandidate(
            windowID: candidate.windowID,
            workspaceID: candidate.workspaceID,
            tabID: candidate.tabID,
            sessionID: candidate.sessionID,
            persistentBindingGeneration: candidate.persistentBindingGeneration,
            bindingTransitionGeneration: candidate.bindingTransitionGeneration,
            isTopLevel: candidate.isTopLevel,
            hasLoadedPersistedState: candidate.hasLoadedPersistedState,
            bindingTransitionInProgress: candidate.bindingTransitionInProgress,
            isClosing: candidate.isClosing,
            isMCPControlled: candidate.isMCPControlled,
            isMCPOriginated: candidate.isMCPOriginated,
            roleAllowsOutboundMonitoring: candidate.roleAllowsOutboundMonitoring,
            displayName: candidate.displayName,
            providerDisplayName: candidate.providerDisplayName,
            locationLabel: locationLabel
        )
    }

    private func makeBridgeFixture() async -> BridgeFixture {
        let authority = DomainAgentSessionLinkAuthority(
            identity: DomainRuntimeIdentity(
                runtimeID: UUID(),
                lifecycleGeneration: 1,
                processID: 1,
                mode: .app,
                createdAt: Date(timeIntervalSince1970: 0)
            ),
            now: { Date(timeIntervalSince1970: 1000) }
        )
        let host = FakeEndpointHost()
        let observer = makeCandidate(windowID: 1, displayName: "Planning", locationLabel: "planning")
        let target = makeCandidate(windowID: 2, displayName: "Build API", locationLabel: "feature-219")
        host.candidates = [observer, target]
        let advertisement = ToolAdvertisementRecorder()
        let bridge = AgentSessionLinkRuntimeBridge(
            authority: authority,
            host: host,
            toolAdvertisementInvalidator: { sessionID in await advertisement.record(sessionID) }
        )
        let outcome = await bridge.addMonitorLink(
            observerSessionID: observer.sessionID,
            rawTargetSessionID: target.sessionID.uuidString
        )
        if case .added = outcome {} else {
            XCTFail("expected added, got \(outcome)")
        }
        await bridge.test_settleProjections()
        return BridgeFixture(
            authority: authority,
            host: host,
            bridge: bridge,
            observer: observer,
            target: target,
            advertisement: advertisement
        )
    }

    private func makeLiveViewModel(tabID: UUID, workspaceName: String) throws -> AgentModeViewModel {
        let viewModel = AgentModeViewModel(
            testWindowID: 91,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in
                LifecycleNoopCodexController(recorder: LifecycleRecorder())
            },
            connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
            mcpServerEnabler: { true }
        )
        retained.append(viewModel)
        retainedManagers.append(
            AgentSessionLinkEndpointTestSupport.installWorkspace(
                on: viewModel,
                tabID: tabID,
                name: workspaceName
            )
        )
        let session = viewModel.session(for: tabID)
        session.hasLoadedPersistedState = true
        _ = try XCTUnwrap(
            viewModel.test_ensureSessionBoundToTab(session),
            "expected a durable persistent binding"
        )
        return viewModel
    }

    private func binding(
        worktreeName: String? = nil,
        branch: String? = nil,
        visualLabel: String? = nil,
        visualColorHex: String? = nil
    ) -> AgentSessionWorktreeBinding {
        AgentSessionWorktreeBinding(
            id: "location-binding",
            repositoryID: "location-repository",
            repoKey: "location-repo",
            // Matches the view model's fallback workspace path, which is what makes this the
            // session's *primary execution* binding and therefore its rendered location.
            logicalRootPath: FileManager.default.currentDirectoryPath,
            logicalRootName: "location-repo",
            worktreeID: "location-worktree",
            worktreeRootPath: FileManager.default.currentDirectoryPath,
            worktreeName: worktreeName,
            branch: branch,
            head: nil,
            visualLabel: visualLabel,
            visualColorHex: visualColorHex,
            boundAt: Date(timeIntervalSince1970: 1),
            source: "test"
        )
    }

    // MARK: - Effective label delta

    /// The trigger contract: worktree label, branch fallback, and workspace-name fallback all change
    /// what an observer renders, and a change that cannot alter the rendered label repaints nothing.
    func testEffectiveLabelDeltaDrivesTheExactTargetSink() throws {
        var notified: [Set<DomainAgentSessionLinkEndpointIdentity>] = []
        AgentSessionLinkLocationInvalidationSink.refreshExactTargets = { notified.append($0) }

        let tabID = UUID()
        let viewModel = try makeLiveViewModel(tabID: tabID, workspaceName: "Oversight")
        let manager = try XCTUnwrap(viewModel.workspaceManager)
        let session = viewModel.session(for: tabID)
        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(viewModel, tabID: tabID)

        // Workspace fallback: an unbound session names its workspace, qualified so it cannot read as
        // a worktree that does not exist.
        XCTAssertEqual(
            viewModel.agentSessionLinkLocationProjection(forTabID: tabID)?.label,
            "Oversight (main)"
        )

        var baseline = viewModel.agentSessionLinkLocationProjection(forTabID: tabID)
        var workspace = manager.workspaces[0]
        workspace.name = "Quarry"
        manager.workspaces = [workspace]
        manager.activeWorkspace = workspace
        viewModel.notifyAgentSessionLinkLocationChange(forTabID: tabID, from: baseline)
        XCTAssertEqual(
            viewModel.agentSessionLinkLocationProjection(forTabID: tabID)?.label,
            "Quarry (main)"
        )
        XCTAssertEqual(notified, [[endpoint]])

        // Branch fallback: a binding with no visual label and no worktree name is named by its branch.
        baseline = viewModel.agentSessionLinkLocationProjection(forTabID: tabID)
        session.worktreeBindings = [binding(branch: "release-42")]
        viewModel.notifyAgentSessionLinkLocationChange(forTabID: tabID, from: baseline)
        XCTAssertEqual(viewModel.agentSessionLinkLocationProjection(forTabID: tabID)?.label, "release-42")
        XCTAssertEqual(notified.count, 2)
        XCTAssertEqual(notified.last, [endpoint])

        // Worktree label: the strongest input wins over the branch.
        baseline = viewModel.agentSessionLinkLocationProjection(forTabID: tabID)
        session.worktreeBindings = [binding(branch: "release-42", visualLabel: "feature-219")]
        viewModel.notifyAgentSessionLinkLocationChange(forTabID: tabID, from: baseline)
        XCTAssertEqual(viewModel.agentSessionLinkLocationProjection(forTabID: tabID)?.label, "feature-219")
        XCTAssertEqual(notified.count, 3)

        // Color-only edit: the binding changed, the rendered label did not, so nothing repaints.
        baseline = viewModel.agentSessionLinkLocationProjection(forTabID: tabID)
        session.worktreeBindings = [
            binding(branch: "release-42", visualLabel: "feature-219", visualColorHex: "#2563EB")
        ]
        viewModel.notifyAgentSessionLinkLocationChange(forTabID: tabID, from: baseline)
        XCTAssertEqual(notified.count, 3, "a change that cannot alter the label must not repaint")
    }

    // MARK: - Production mutation sites

    /// The delta rule is only half the contract.
    ///
    /// A mutation site that computes the right effective-label delta but never calls the sink
    /// repaints nothing, and no assertion about `notifyAgentSessionLinkLocationChange` itself can
    /// catch that. These drive the owning production entry points instead.
    ///
    /// `WorkspaceManagerViewModel.renameWorkspace` is deliberately not driven end-to-end: its
    /// canonical assignment is followed by a workspace save and a *global* workspace-index rebuild,
    /// so exercising it from a unit test would rewrite the developer's real workspace index. Its
    /// decision — the normalized `(main)` fallback comparison — is pinned below instead.
    func testProductionMutationSitesDriveTheLocationSinks() throws {
        var exact: [Set<DomainAgentSessionLinkEndpointIdentity>] = []
        var observed: [UUID?] = []
        AgentSessionLinkLocationInvalidationSink.refreshExactTargets = { exact.append($0) }
        AgentSessionLinkLocationInvalidationSink.refreshObservedTargets = { observed.append($0) }

        let tabID = UUID()
        let viewModel = try makeLiveViewModel(tabID: tabID, workspaceName: "Oversight")
        let session = viewModel.session(for: tabID)
        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(viewModel, tabID: tabID)
        let rootPath = FileManager.default.currentDirectoryPath

        // 1. `commitWorktreeBindings` — the single mutation point for a session's worktree bindings.
        viewModel.test_commitWorktreeBindings([binding(branch: "old-branch")], to: session)
        XCTAssertEqual(exact, [[endpoint]])
        XCTAssertEqual(
            viewModel.agentSessionLinkLocationProjection(forTabID: tabID)?.label,
            "old-branch"
        )

        // The same site must stay silent for a binding edit that cannot change the rendered label.
        viewModel.test_commitWorktreeBindings(
            [binding(branch: "old-branch", visualColorHex: "#2563EB")],
            to: session
        )
        XCTAssertEqual(exact.count, 1, "A color-only binding edit changes no rendered label.")

        // 2. In-app Git branch switch, which becomes the label when nothing stronger names the
        //    checkout.
        viewModel.test_recordSuccessfulInAppGitBranchSwitch(
            row: AgentWorkspaceRootRow(
                id: UUID(),
                name: "location-repo",
                fullPath: rootPath,
                isPrimary: true,
                canMoveUp: false,
                canMoveDown: false
            ),
            result: GitBranchSwitchResult(
                rootPath: rootPath,
                repoRootPath: rootPath,
                previousBranch: "old-branch",
                previousHead: "aaaa111",
                newBranch: "release-77",
                newHead: "bbbb222",
                didSwitch: true
            ),
            currentTabID: tabID
        )
        XCTAssertEqual(exact.count, 2)
        XCTAssertEqual(exact.last, [endpoint])
        XCTAssertEqual(
            viewModel.agentSessionLinkLocationProjection(forTabID: tabID)?.label,
            "release-77"
        )

        // 3. Global worktree visual identity — label only. Scoped to identifiers no other suite uses,
        //    and uncommitted, so nothing here touches the user's settings file.
        let repositoryID = "oversight-repo-\(UUID().uuidString)"
        let worktreeID = "oversight-worktree-\(UUID().uuidString)"
        try GlobalSettingsStore.shared.setWorktreeVisualIdentity(
            WorktreeVisualIdentity(label: "Feature 219", colorHex: "#2563EB"),
            repositoryID: repositoryID,
            worktreeID: worktreeID,
            commit: false
        )
        XCTAssertEqual(observed.count, 1)
        XCTAssertNil(observed.last ?? nil, "A global label edit names no tab, so the scan is process-wide.")

        try GlobalSettingsStore.shared.setWorktreeVisualIdentity(
            WorktreeVisualIdentity(label: "Feature 219", colorHex: "#DC2626", iconName: "square.fill"),
            repositoryID: repositoryID,
            worktreeID: worktreeID,
            commit: false
        )
        XCTAssertEqual(
            observed.count,
            1,
            "Color, icon, marker, and timestamp cannot change any rendered location label."
        )

        // 4. The workspace-rename decision, through the same normalized fallback the row renders.
        XCTAssertEqual(
            AgentMonitorLocationLabelFormatter.label(worktreeLabel: nil, workspaceName: "Oversight"),
            AgentMonitorLocationLabelFormatter.label(worktreeLabel: nil, workspaceName: "  Oversight  "),
            "A rename that normalizes to the same label must not schedule a repaint."
        )
        XCTAssertNotEqual(
            AgentMonitorLocationLabelFormatter.label(worktreeLabel: nil, workspaceName: "Oversight"),
            AgentMonitorLocationLabelFormatter.label(worktreeLabel: nil, workspaceName: "Quarry")
        )
    }

    // MARK: - Repaint scope

    func testTargetLocationRefreshRepaintsObserverOutboundRowsOnly() async throws {
        let fixture = await makeBridgeFixture()
        let observerEndpoint = fixture.observer.domainEndpoint
        let targetEndpoint = fixture.target.domainEndpoint
        XCTAssertEqual(
            fixture.host.publishedPropsByEndpoint[observerEndpoint]?.outbound.first?.locationLabel,
            "feature-219"
        )
        let targetPropsBefore = try XCTUnwrap(fixture.host.publishedPropsByEndpoint[targetEndpoint])
        XCTAssertEqual(targetPropsBefore.inbound.count, 1)

        fixture.host.candidates = [
            fixture.observer,
            relabeled(fixture.target, locationLabel: "Quarry (main)")
        ]
        fixture.bridge.requestMonitorLocationRefresh(forExactTargetEndpoints: [targetEndpoint])
        await fixture.bridge.test_settleMonitorProjectionRefresh()

        XCTAssertEqual(
            fixture.host.publishedPropsByEndpoint[observerEndpoint]?.outbound.first?.locationLabel,
            "Quarry (main)"
        )
        // The target's own projection carries inbound observers, which are location-free by design
        // and have no reason to be rebuilt by a location edit.
        XCTAssertEqual(fixture.host.publishedPropsByEndpoint[targetEndpoint], targetPropsBefore)
    }

    // MARK: - No side effects

    func testLocationRefreshTouchesNoAuthorityPromptOrAdvertisementState() async throws {
        let fixture = await makeBridgeFixture()
        let targetEndpoint = fixture.target.domainEndpoint
        let revisionBefore = await fixture.authority.snapshot().authorityRevision
        let observerLinkSetRevisionBefore = await fixture.authority
            .observerLinkSetRevision(fixture.observer.sessionID)
        let lease = await fixture.authority.authorize(
            operation: .monitorPoll,
            observerEndpoint: fixture.observer.domainEndpoint,
            targetSessionID: fixture.target.sessionID
        )
        guard case let .success(lease) = lease else { return XCTFail("expected an authorized lease") }
        let rawStateBefore = await fixture.authority.targetState(for: lease)
        let stateBefore = try XCTUnwrap(rawStateBefore)
        let inventoryPublicationsBefore = fixture.host.inventoryPublicationCount
        let observationSnapshotsBefore = fixture.host.observationSnapshotCount
        let advertisementsBefore = await fixture.advertisement.count()

        fixture.host.candidates = [
            fixture.observer,
            relabeled(fixture.target, locationLabel: "release-42")
        ]
        fixture.bridge.requestMonitorLocationRefresh(forExactTargetEndpoints: [targetEndpoint])
        await fixture.bridge.test_settleMonitorProjectionRefresh()

        let rawStateAfter = await fixture.authority.targetState(for: lease)
        let stateAfter = try XCTUnwrap(rawStateAfter)
        XCTAssertEqual(stateAfter.changeSequence, stateBefore.changeSequence)
        XCTAssertEqual(stateAfter.snapshot, stateBefore.snapshot)
        let revisionAfter = await fixture.authority.snapshot().authorityRevision
        XCTAssertEqual(revisionAfter, revisionBefore)
        let observerLinkSetRevisionAfter = await fixture.authority
            .observerLinkSetRevision(fixture.observer.sessionID)
        XCTAssertEqual(observerLinkSetRevisionAfter, observerLinkSetRevisionBefore)
        XCTAssertEqual(fixture.host.inventoryPublicationCount, inventoryPublicationsBefore)
        XCTAssertEqual(fixture.host.observationSnapshotCount, observationSnapshotsBefore)
        let advertisementsAfter = await fixture.advertisement.count()
        XCTAssertEqual(advertisementsAfter, advertisementsBefore)
        // The repaint itself still happened; the assertions above are about what it did *not* do.
        XCTAssertEqual(
            fixture.host.publishedPropsByEndpoint[fixture.observer.domainEndpoint]?
                .outbound.first?.locationLabel,
            "release-42"
        )

        // Termination drops the queue: a presentation repaint has no durable or agent-visible
        // consequence, so quitting must never wait for one.
        fixture.bridge.freezeForTermination()
        fixture.host.candidates = [
            fixture.observer,
            relabeled(fixture.target, locationLabel: "dropped")
        ]
        fixture.bridge.requestMonitorLocationRefresh(forExactTargetEndpoints: [targetEndpoint])
        await fixture.bridge.test_settleMonitorProjectionRefresh()
        XCTAssertEqual(
            fixture.host.publishedPropsByEndpoint[fixture.observer.domainEndpoint]?
                .outbound.first?.locationLabel,
            "release-42"
        )
    }
}
