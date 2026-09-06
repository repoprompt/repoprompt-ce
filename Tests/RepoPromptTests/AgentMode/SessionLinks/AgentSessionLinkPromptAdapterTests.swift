import Foundation
@_spi(TestSupport) @testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

// MARK: - Shared support

private actor CatalogAuthorityGate {
    private var entered = false
    private var isOpen = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var openWaiters: [CheckedContinuation<Bool, Never>] = []

    func requirement() async -> Bool {
        if !entered {
            entered = true
            let waiters = entryWaiters
            entryWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }
        if isOpen {
            return true
        }
        return await withCheckedContinuation { continuation in
            openWaiters.append(continuation)
        }
    }

    func waitUntilEntered() async {
        if entered {
            return
        }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let waiters = openWaiters
        openWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: true)
        }
    }
}

/// Assertions shared by every adapter suite.
///
/// The whole point of these suites is that they inspect the string that actually crossed a provider
/// boundary — `startUserTurn`, `steerUserTurn`, `sendUserMessage`, `streamAgentMessage`,
/// `session/prompt`, or a resumed continuation — rather than a value a test handed to itself.
enum MonitorSupplementAssertions {
    static let openTag = "<\(AgentSessionLinkPrompts.envelopeTag) "

    static func fragmentCount(in text: String) -> Int {
        text.components(separatedBy: openTag).count - 1
    }

    /// Exactly one supplement, appended after the user-controlled content.
    static func assertCarriesExactlyOneSupplement(
        _ text: String,
        userContent: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(fragmentCount(in: text), 1, "expected exactly one supplement", file: file, line: line)
        XCTAssertTrue(text.contains(userContent), "user content must survive", file: file, line: line)
        let supplementStart = try? XCTUnwrap(text.range(of: openTag), file: file, line: line)
        let contentStart = try? XCTUnwrap(text.range(of: userContent), file: file, line: line)
        if let supplementStart, let contentStart {
            XCTAssertTrue(
                contentStart.lowerBound < supplementStart.lowerBound,
                "the supplement must be the final RepoPrompt envelope, after user content",
                file: file,
                line: line
            )
        }
    }

    static func assertCarriesNoSupplement(
        _ text: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(fragmentCount(in: text), 0, "expected no supplement", file: file, line: line)
    }

    /// The supplement must never become user-authored transcript or persisted queue state.
    @MainActor
    static func assertNotPersisted(
        in session: AgentModeViewModel.TabSession,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for item in session.items {
            XCTAssertFalse(
                item.text.contains(AgentSessionLinkPrompts.envelopeTag),
                "transcript row must never carry the supplement",
                file: file,
                line: line
            )
        }
        for instruction in session.pendingInstructions {
            XCTAssertFalse(instruction.contains(AgentSessionLinkPrompts.envelopeTag), file: file, line: line)
        }
        for instruction in session.pendingACPSteeringInstructions {
            XCTAssertFalse(
                instruction.providerText.contains(AgentSessionLinkPrompts.envelopeTag),
                file: file,
                line: line
            )
        }
        for entry in session.codexFallbackQueue {
            XCTAssertFalse(
                entry.providerText.contains(AgentSessionLinkPrompts.envelopeTag),
                "a queued entry must persist undecorated provider text",
                file: file,
                line: line
            )
        }
        XCTAssertFalse(
            session.codexPendingAuthRetryTurn?.text.contains(AgentSessionLinkPrompts.envelopeTag) ?? false,
            "the auth-retry buffer must persist undecorated provider text",
            file: file,
            line: line
        )
    }
}

/// Publishes a real inventory onto a live view model and advances membership like the bridge does.
///
/// Publication is addressed to the tab's exact live incarnation, exactly as the bridge addresses it,
/// so a suite cannot accidentally hand an inventory to a session UUID that no longer resolves.
@MainActor
final class MonitorInventoryPublisher {
    let viewModel: AgentModeViewModel
    let observerSessionID: UUID
    let tabID: UUID

    private var targetCount = 0
    private var publishedCatalogRunWindowIDs: [UUID: Int] = [:]

    init(viewModel: AgentModeViewModel, observerSessionID: UUID, tabID: UUID) {
        self.viewModel = viewModel
        self.observerSessionID = observerSessionID
        self.tabID = tabID
    }

    func publish(revision: UInt64, targetCount: Int) {
        self.targetCount = targetCount
        guard let endpoint = viewModel.agentSessionLinkObserverEndpoint(tabID: tabID) else {
            let live = viewModel.sessions[tabID]?.activeAgentSessionID?.uuidString ?? "nil"
            let claimed = viewModel.workspaceManager?.workspaces
                .flatMap(\.composeTabs)
                .first { $0.id == tabID }?
                .activeAgentSessionID?.uuidString ?? "nil"
            let tabCount = viewModel.workspaceManager?.workspaces.flatMap(\.composeTabs).count ?? -1
            return XCTFail(
                """
                expected a resolvable oversight endpoint for the publishing tab \
                (liveSession=\(live) workspaceClaim=\(claimed) workspaceTabs=\(tabCount))
                """
            )
        }
        #if DEBUG
            if viewModel.sessions[tabID]?.selectedAgent.usesClaudeNativeRuntime == true {
                viewModel.test_agentSessionLinkHasActiveOutboundLink = { _ in targetCount > 0 }
            }
        #endif
        if targetCount > 0, let session = viewModel.sessions[tabID] {
            if session.runID == nil {
                session.installRunID(UUID())
            }
            if let runID = session.runID {
                let routeToken = AgentSessionLinkRunCatalogRouteToken(
                    runID: runID,
                    observerEndpoint: endpoint,
                    connectionID: UUID(),
                    routingAuthorityGeneration: 1,
                    connectionLifecycleGeneration: 1
                )
                #if DEBUG
                    if session.selectedAgent.usesClaudeNativeRuntime {
                        viewModel.test_agentSessionLinkAuthoritativeRunCatalogRouteToken = {
                            requestedRunID,
                            requestedWindowID,
                            requestedTabID in
                            guard requestedRunID == routeToken.runID,
                                  requestedWindowID == routeToken.observerEndpoint.windowID,
                                  requestedTabID == routeToken.observerEndpoint.tabID
                            else { return nil }
                            return routeToken
                        }
                        viewModel.test_agentSessionLinkCurrentRunCatalogRouteToken = { candidate, requestedTabID in
                            candidate == routeToken && requestedTabID == routeToken.observerEndpoint.tabID
                        }
                    }
                #endif
                viewModel.agentSessionLinkPublishRunCatalogProjection(
                    AgentSessionLinkRunCatalogProjection(
                        runID: runID,
                        routeToken: routeToken,
                        projectionRevision: revision,
                        hasAgentSessionLink: true
                    ),
                    to: endpoint
                )
            }
        }
        viewModel.agentSessionLinkPublishPromptInventory(
            AgentSessionLinkPromptInventory(
                observerSessionID: observerSessionID,
                linkSetRevision: revision,
                items: (0 ..< targetCount).map { index in
                    AgentSessionLinkPromptInventoryItem(
                        targetSessionID: UUID(
                            uuidString: String(format: "0000000%d-0000-0000-0000-00000000BEEF", index)
                        )!,
                        displayName: "Target \(index)",
                        capabilityNames: ["poll", "read", "send_when_idle", "wait"]
                    )
                }
            ),
            to: endpoint
        )
    }

    func publishCodex(revision: UInt64, targetCount: Int) async {
        #if DEBUG
            viewModel.test_agentSessionLinkHasActiveOutboundLink = { _ in targetCount > 0 }
        #endif
        publish(revision: revision, targetCount: targetCount)
        await republishCurrentCodexCatalog()
    }

    func republishCurrentCodexCatalog() async {
        #if DEBUG
            guard let endpoint = viewModel.agentSessionLinkObserverEndpoint(tabID: tabID),
                  let session = viewModel.sessions[tabID]
            else {
                return XCTFail("expected a live Codex catalog publication endpoint")
            }
            if session.runID == nil {
                session.installRunID(UUID())
            }
            guard let runID = session.runID else {
                return XCTFail("expected a Codex run ID before catalog publication")
            }
            let routeToken = AgentSessionLinkRunCatalogRouteToken(
                runID: runID,
                observerEndpoint: endpoint,
                connectionID: UUID(),
                routingAuthorityGeneration: 1,
                connectionLifecycleGeneration: 1
            )
            viewModel.test_agentSessionLinkAuthoritativeRunCatalogRouteToken = {
                requestedRunID,
                requestedWindowID,
                requestedTabID in
                guard requestedRunID == routeToken.runID,
                      requestedWindowID == routeToken.observerEndpoint.windowID,
                      requestedTabID == routeToken.observerEndpoint.tabID
                else { return nil }
                return routeToken
            }
            viewModel.test_agentSessionLinkCurrentRunCatalogRouteToken = { candidate, requestedTabID in
                candidate == routeToken && requestedTabID == routeToken.observerEndpoint.tabID
            }
            let projection = await ServerNetworkManager.shared.debugPublishRunCatalogObservation(
                routeToken: routeToken,
                hasAgentSessionLink: targetCount > 0
            )
            viewModel.agentSessionLinkPublishRunCatalogProjection(projection, to: endpoint)
            publishedCatalogRunWindowIDs[runID] = endpoint.windowID
        #endif
    }

    func cleanupCodexCatalogPublications() async {
        #if DEBUG
            for (runID, windowID) in publishedCatalogRunWindowIDs {
                await ServerNetworkManager.shared.cleanupRunRoutingState(for: runID, windowID: windowID)
            }
            publishedCatalogRunWindowIDs.removeAll()
        #endif
    }
}

// MARK: - Codex adapters

/// Codex dispatch adapters, driven through the real `CodexAgentModeCoordinator`.
///
/// Every assertion reads the text the fake controller actually received, so a regression that stops
/// composing, composes at the wrong point, or double-composes is caught at the provider boundary.
@MainActor
final class AgentSessionLinkCodexPromptAdapterTests: XCTestCase {
    private var retained: [AgentModeViewModel] = []
    private var inventories: [MonitorInventoryPublisher] = []

    override func tearDown() async throws {
        for inventory in inventories {
            await inventory.cleanupCodexCatalogPublications()
        }
        inventories.removeAll()
        retained.removeAll()
        try await super.tearDown()
    }

    private struct Fixture {
        let viewModel: AgentModeViewModel
        let coordinator: CodexAgentModeCoordinator
        let controller: MonitorFakeCodexController
        let session: AgentModeViewModel.TabSession
        let sessionID: UUID
        let tabID: UUID
        let inventory: MonitorInventoryPublisher
        let authRecovery: MonitorStubCodexAuthRecovery
        /// Retained: the view model holds its workspace manager weakly.
        let workspaceManager: WorkspaceManagerViewModel
    }

    private func makeFixture() throws -> Fixture {
        let controller = MonitorFakeCodexController()
        let authRecovery = MonitorStubCodexAuthRecovery()
        let tabID = UUID()
        let viewModel = AgentModeViewModel(
            testWindowID: 1,
            testWorkspacePath: FileManager.default.temporaryDirectory.path,
            codexControllerFactory: { _, _, _, _, _, _ in controller },
            connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
            mcpServerEnabler: { true },
            testCodexManagedAuthRecovery: authRecovery
        )
        retained.append(viewModel)
        // The supplement is scoped to an exact incarnation, so the tab needs a real workspace
        // binding rather than a bare `session(for:)` tab.
        let workspaceManager = AgentSessionLinkEndpointTestSupport.installWorkspace(
            on: viewModel,
            tabID: tabID,
            name: "Oversee Codex adapters"
        )
        let session = viewModel.session(for: tabID)
        session.selectedAgent = .codexExec
        session.hasLoadedPersistedState = true
        let sessionID = try XCTUnwrap(viewModel.test_ensureSessionBoundToTab(session))
        let inventory = MonitorInventoryPublisher(
            viewModel: viewModel,
            observerSessionID: sessionID,
            tabID: tabID
        )
        inventories.append(inventory)
        controller.setStartOrResumeHook { [weak inventory] in
            await inventory?.republishCurrentCodexCatalog()
        }
        return Fixture(
            viewModel: viewModel,
            coordinator: viewModel.test_codexCoordinator,
            controller: controller,
            session: session,
            sessionID: sessionID,
            tabID: tabID,
            inventory: inventory,
            authRecovery: authRecovery,
            workspaceManager: workspaceManager
        )
    }

    private func prepareAutoWake(_ fixture: Fixture) throws -> UUID {
        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
            fixture.viewModel,
            tabID: fixture.tabID
        )
        let targetSessionID = UUID(uuidString: "00000000-0000-0000-0000-00000000BEEF")!
        let reference = DomainAgentSessionLinkReference(linkID: UUID(), generation: 1)
        let targetEndpoint = DomainAgentSessionLinkEndpointIdentity(
            windowID: 2,
            workspaceID: UUID(),
            tabID: UUID(),
            sessionID: targetSessionID,
            persistentBindingGeneration: UUID(),
            bindingTransitionGeneration: 1
        )
        let queueEpoch = UUID()
        let snapshot = AgentSessionLinkPassiveStatusNotices.Snapshot(
            observerEndpoint: endpoint,
            queueEpoch: queueEpoch,
            queueRevision: 1,
            linkSetRevision: 1,
            isEnabled: true,
            isDeliverable: true,
            entries: [AgentSessionLinkPassiveStatusNotices.PendingEntry(
                reference: reference,
                targetEndpoint: targetEndpoint,
                targetSessionID: targetSessionID,
                displayName: "Target 0",
                fromStatus: .running,
                toStatus: .idle,
                idleForSend: true,
                latestVisibleAssistantPreview: "Done.",
                changeSequence: 1
            )],
            unacknowledgedOverflowCount: 0,
            overflowProduced: 0,
            autoWakeLanes: [AgentSessionLinkPassiveStatusNotices.AutoWakeLane(
                reference: reference,
                targetEndpoint: targetEndpoint,
                targetSessionID: targetSessionID,
                isEffectivelySelected: true
            )]
        )
        fixture.viewModel.agentSessionLinkPublishPassiveStatusNotices(snapshot, to: endpoint)
        fixture.session.oversight.autoWakeOnUpdates = true
        let wakeID = UUID()
        fixture.session.oversight.pendingAutoWake = AgentSessionLinkAutoWakeAttempt(
            wakeID: wakeID,
            observerEndpoint: endpoint,
            queueEpoch: queueEpoch,
            queueRevision: 1,
            wakeFingerprint: snapshot.wakeEligibilityFingerprint,
            attemptedFingerprint: nil,
            physicalOutcome: .notAttempted,
            phase: .preparingDispatch,
            task: nil
        )
        return wakeID
    }

    func testManualCatalogReadinessTimeoutRestoresExactOptimisticSubmission() async throws {
        #if DEBUG
            let fixture = try makeFixture()
            fixture.viewModel.test_setCurrentTabIDOverride(fixture.tabID)
            defer { fixture.viewModel.test_setCurrentTabIDOverride(nil) }
            fixture.viewModel.test_agentSessionLinkHasActiveOutboundLink = { _ in true }
            fixture.inventory.publish(revision: 1, targetCount: 1)

            let runID = try XCTUnwrap(fixture.session.runID)
            fixture.session.beginRunAttempt(source: "test.catalog-timeout.manual")
            _ = try await fixture.controller.startOrResume(
                existing: nil,
                baseInstructions: "test",
                model: nil,
                reasoningEffort: nil,
                serviceTier: nil
            )
            fixture.session.runState = .running
            fixture.session.codexController = fixture.controller
            fixture.session.codexControllerPermissionProfile = fixture.session.permissionProfile
            fixture.session.codexControllerTaskLabelKind = fixture.session.mcpControlContext?.taskLabelKind
            fixture.session.codexControllerWorkspacePaths = .uniform(FileManager.default.temporaryDirectory.path)
            fixture.session.codexControllerFeatureState = .init(
                computerUseEnabled: false,
                goalSupportEnabled: CodexGoalSupport.isEnabled,
                reasoningSummariesEnabled: CodexReasoningSummaries.isEnabled,
                memoriesEnabled: CodexMemories.isEnabled
            )
            fixture.session.codexConversationID = "monitor-thread"
            fixture.session.codexAuthoritativeActiveTurn = try .init(
                threadID: "monitor-thread",
                turnID: "active-turn",
                turnKind: .user,
                controllerInstanceID: ObjectIdentifier(fixture.controller),
                controllerGeneration: fixture.session.codexControllerGeneration,
                runID: runID,
                runAttemptID: XCTUnwrap(fixture.session.activeRunAttemptID)
            )
            fixture.session.codexRoutingObservedTurnID = "active-turn"

            let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
                fixture.viewModel,
                tabID: fixture.tabID
            )
            let routeToken = AgentSessionLinkRunCatalogRouteToken(
                runID: runID,
                observerEndpoint: endpoint,
                connectionID: UUID(),
                routingAuthorityGeneration: 1,
                connectionLifecycleGeneration: 1
            )
            let manager = ServerNetworkManager.shared
            let unready = await manager.debugPublishRunCatalogObservation(
                routeToken: routeToken,
                hasAgentSessionLink: nil
            )
            fixture.viewModel.agentSessionLinkPublishRunCatalogProjection(unready, to: endpoint)

            let existing = AgentChatItem.user("confirmed", sequenceIndex: fixture.session.nextSequenceIndex)
            fixture.session.appendItem(existing)
            let rawDraft = "  restore exact manual input  "
            fixture.viewModel.storeDraftText(for: fixture.tabID, rawDraft)
            XCTAssertEqual(
                fixture.viewModel.submitUserTurn(
                    text: rawDraft.trimmingCharacters(in: .whitespacesAndNewlines),
                    tabID: fixture.tabID,
                    rawDraftText: rawDraft
                ),
                .submitted
            )
            fixture.viewModel.storeDraftText(for: fixture.tabID, "")

            try await AsyncTestWait.waitUntil("manual readiness timeout rollback") {
                await MainActor.run {
                    fixture.viewModel.draftRestorationEvent?.text == rawDraft
                }
            }
            XCTAssertEqual(fixture.session.items.filter { $0.kind == .user }.map(\.id), [existing.id])
            XCTAssertEqual(fixture.viewModel.retrieveDraftText(for: fixture.tabID), rawDraft)
            XCTAssertTrue(
                fixture.viewModel.draftRestorationEvent?.message.contains("catalog readiness timed out") == true,
                "unexpected restoration message: \(fixture.viewModel.draftRestorationEvent?.message ?? "nil")"
            )
            XCTAssertTrue(fixture.controller.steeredTurns.isEmpty)
            XCTAssertNil(fixture.session.codexPendingAuthRetryTurn)
            await manager.cleanupRunRoutingState(for: runID, windowID: endpoint.windowID)
        #else
            throw XCTSkip("Catalog observation diagnostics require DEBUG helpers.")
        #endif
    }

    func testManualParkedCatalogWaiterSupersessionRestoresExactOptimisticSubmission() async throws {
        #if DEBUG
            let fixture = try makeFixture()
            fixture.viewModel.test_setCurrentTabIDOverride(fixture.tabID)
            defer { fixture.viewModel.test_setCurrentTabIDOverride(nil) }
            let authorityGate = CatalogAuthorityGate()
            fixture.viewModel.test_agentSessionLinkHasActiveOutboundLink = { _ in
                await authorityGate.requirement()
            }
            fixture.inventory.publish(revision: 1, targetCount: 1)

            let runID = try XCTUnwrap(fixture.session.runID)
            fixture.session.beginRunAttempt(source: "test.catalog-superseded.manual")
            _ = try await fixture.controller.startOrResume(
                existing: nil,
                baseInstructions: "test",
                model: nil,
                reasoningEffort: nil,
                serviceTier: nil
            )
            fixture.session.runState = .running
            fixture.session.codexController = fixture.controller
            fixture.session.codexControllerPermissionProfile = fixture.session.permissionProfile
            fixture.session.codexControllerTaskLabelKind = fixture.session.mcpControlContext?.taskLabelKind
            fixture.session.codexControllerWorkspacePaths = .uniform(FileManager.default.temporaryDirectory.path)
            fixture.session.codexControllerFeatureState = .init(
                computerUseEnabled: false,
                goalSupportEnabled: CodexGoalSupport.isEnabled,
                reasoningSummariesEnabled: CodexReasoningSummaries.isEnabled,
                memoriesEnabled: CodexMemories.isEnabled
            )
            fixture.session.codexConversationID = "monitor-thread"
            fixture.session.codexAuthoritativeActiveTurn = try .init(
                threadID: "monitor-thread",
                turnID: "active-turn",
                turnKind: .user,
                controllerInstanceID: ObjectIdentifier(fixture.controller),
                controllerGeneration: fixture.session.codexControllerGeneration,
                runID: runID,
                runAttemptID: XCTUnwrap(fixture.session.activeRunAttemptID)
            )
            fixture.session.codexRoutingObservedTurnID = "active-turn"

            let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
                fixture.viewModel,
                tabID: fixture.tabID
            )
            let routeToken = AgentSessionLinkRunCatalogRouteToken(
                runID: runID,
                observerEndpoint: endpoint,
                connectionID: UUID(),
                routingAuthorityGeneration: 1,
                connectionLifecycleGeneration: 1
            )
            let manager = ServerNetworkManager.shared
            let unready = await manager.debugPublishRunCatalogObservation(
                routeToken: routeToken,
                hasAgentSessionLink: nil
            )
            fixture.viewModel.agentSessionLinkPublishRunCatalogProjection(unready, to: endpoint)

            let existing = AgentChatItem.user("confirmed", sequenceIndex: fixture.session.nextSequenceIndex)
            fixture.session.appendItem(existing)
            let image = AgentImageAttachment(
                source: .localFile(path: "/tmp/superseded-catalog-image.png"),
                title: "superseded-catalog-image.png"
            )
            let taggedFile = AgentTaggedFileAttachment(
                relativePath: "Sources/Feature/Superseded.swift",
                displayName: "Superseded.swift"
            )
            let workflow = AgentWorkflowDefinition(
                customID: UUID(),
                displayName: "Superseded Workflow",
                template: "Wrapped: $ARGUMENTS"
            )
            fixture.session.pendingImageAttachments = [image]
            fixture.session.pendingTaggedFileAttachments = [taggedFile]
            fixture.session.selectedWorkflow = workflow
            let rawDraft = "  restore exact superseded input  "
            fixture.viewModel.storeDraftText(for: fixture.tabID, rawDraft)
            XCTAssertEqual(
                fixture.viewModel.submitUserTurn(
                    text: rawDraft.trimmingCharacters(in: .whitespacesAndNewlines),
                    tabID: fixture.tabID,
                    rawDraftText: rawDraft
                ),
                .submitted
            )
            fixture.viewModel.storeDraftText(for: fixture.tabID, "")

            await authorityGate.waitUntilEntered()
            await manager.cleanupRunRoutingState(for: runID, windowID: endpoint.windowID)
            await authorityGate.open()
            try await AsyncTestWait.waitUntil("catalog waiter to park") {
                await manager.debugHasRunCatalogState(for: runID)
            }
            await manager.cleanupRunRoutingState(for: runID, windowID: endpoint.windowID)

            try await AsyncTestWait.waitUntil("manual readiness supersession rollback") {
                await MainActor.run {
                    fixture.viewModel.draftRestorationEvent?.text == rawDraft
                }
            }
            XCTAssertEqual(fixture.session.items.filter { $0.kind == .user }.map(\.id), [existing.id])
            XCTAssertEqual(fixture.viewModel.retrieveDraftText(for: fixture.tabID), rawDraft)
            XCTAssertEqual(fixture.session.pendingImageAttachments, [image])
            XCTAssertEqual(fixture.session.pendingTaggedFileAttachments, [taggedFile])
            XCTAssertEqual(fixture.session.selectedWorkflow, workflow)
            XCTAssertEqual(fixture.viewModel.selectedWorkflow, workflow)
            XCTAssertTrue(
                fixture.viewModel.draftRestorationEvent?.message.contains("catalog readiness was superseded") == true,
                "unexpected restoration message: \(fixture.viewModel.draftRestorationEvent?.message ?? "nil")"
            )
            XCTAssertTrue(fixture.controller.startedTurns.isEmpty)
            XCTAssertTrue(fixture.controller.steeredTurns.isEmpty)
            XCTAssertNil(fixture.session.codexPendingAuthRetryTurn)
        #else
            throw XCTSkip("Catalog observation diagnostics require DEBUG helpers.")
        #endif
    }

    func testCodexManualDispatchRestoresExactDraftWhenCatalogRouteChangesAfterReadiness() async throws {
        #if DEBUG
            let fixture = try makeFixture()
            fixture.viewModel.test_setCurrentTabIDOverride(fixture.tabID)
            defer { fixture.viewModel.test_setCurrentTabIDOverride(nil) }
            await fixture.inventory.publishCodex(revision: 1, targetCount: 1)

            let runID = try XCTUnwrap(fixture.session.runID)
            fixture.session.beginRunAttempt(source: "test.catalog-route-fence.manual")
            _ = try await fixture.controller.startOrResume(
                existing: nil,
                baseInstructions: "test",
                model: nil,
                reasoningEffort: nil,
                serviceTier: nil
            )
            fixture.session.runState = .running
            fixture.session.codexController = fixture.controller
            fixture.session.codexControllerPermissionProfile = fixture.session.permissionProfile
            fixture.session.codexControllerTaskLabelKind = fixture.session.mcpControlContext?.taskLabelKind
            fixture.session.codexControllerWorkspacePaths = .uniform(FileManager.default.temporaryDirectory.path)
            fixture.session.codexControllerFeatureState = .init(
                computerUseEnabled: false,
                goalSupportEnabled: CodexGoalSupport.isEnabled,
                reasoningSummariesEnabled: CodexReasoningSummaries.isEnabled,
                memoriesEnabled: CodexMemories.isEnabled
            )
            fixture.session.codexConversationID = "monitor-thread"
            fixture.session.codexAuthoritativeActiveTurn = try .init(
                threadID: "monitor-thread",
                turnID: "active-turn",
                turnKind: .user,
                controllerInstanceID: ObjectIdentifier(fixture.controller),
                controllerGeneration: fixture.session.codexControllerGeneration,
                runID: runID,
                runAttemptID: XCTUnwrap(fixture.session.activeRunAttemptID)
            )
            fixture.session.codexRoutingObservedTurnID = "active-turn"

            let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
                fixture.viewModel,
                tabID: fixture.tabID
            )
            let expectedRouteToken = try XCTUnwrap(
                fixture.viewModel.agentSessionLinkRunCatalogProjectionByEndpoint[endpoint]?.routeToken
            )
            var routeIsCurrent = true
            fixture.viewModel.test_agentSessionLinkCurrentRunCatalogRouteToken = { candidate, requestedTabID in
                routeIsCurrent && candidate == expectedRouteToken && requestedTabID == fixture.tabID
            }
            let afterReadinessGate = CatalogAuthorityGate()
            fixture.viewModel.test_agentSessionLinkAfterProviderInputCatalogReadiness = {
                _ = await afterReadinessGate.requirement()
            }
            addTeardownBlock { @MainActor in
                await afterReadinessGate.open()
                fixture.viewModel.test_agentSessionLinkAfterProviderInputCatalogReadiness = nil
            }

            let existing = AgentChatItem.user("confirmed", sequenceIndex: fixture.session.nextSequenceIndex)
            fixture.session.appendItem(existing)
            let rawDraft = "  restore exact route-fenced input  "
            fixture.viewModel.storeDraftText(for: fixture.tabID, rawDraft)
            XCTAssertEqual(
                fixture.viewModel.submitUserTurn(
                    text: rawDraft.trimmingCharacters(in: .whitespacesAndNewlines),
                    tabID: fixture.tabID,
                    rawDraftText: rawDraft
                ),
                .submitted
            )
            fixture.viewModel.storeDraftText(for: fixture.tabID, "")

            await afterReadinessGate.waitUntilEntered()
            routeIsCurrent = false
            await afterReadinessGate.open()

            try await AsyncTestWait.waitUntil("manual route-fence rollback") {
                await MainActor.run {
                    fixture.viewModel.draftRestorationEvent?.text == rawDraft
                }
            }
            XCTAssertEqual(fixture.session.items.filter { $0.kind == .user }.map(\.id), [existing.id])
            XCTAssertEqual(fixture.viewModel.retrieveDraftText(for: fixture.tabID), rawDraft)
            XCTAssertTrue(
                fixture.viewModel.draftRestorationEvent?.message.contains("catalog route changed") == true,
                "unexpected restoration message: \(fixture.viewModel.draftRestorationEvent?.message ?? "nil")"
            )
            XCTAssertTrue(fixture.controller.startedTurns.isEmpty)
            XCTAssertTrue(fixture.controller.steeredTurns.isEmpty)
            XCTAssertNil(fixture.session.codexPendingAuthRetryTurn)
        #else
            throw XCTSkip("Catalog observation diagnostics require DEBUG helpers.")
        #endif
    }

    func testFreshStartRouteLossTerminalizesEmptyRun() async throws {
        #if DEBUG
            let fixture = try makeFixture()
            let authorityGate = CatalogAuthorityGate()
            fixture.viewModel.test_agentSessionLinkHasActiveOutboundLink = { _ in
                await authorityGate.requirement()
            }
            fixture.inventory.publish(revision: 1, targetCount: 1)

            let send = Task { @MainActor in
                await fixture.viewModel.startAgentRun(
                    tabID: fixture.tabID,
                    initialMessage: "fresh rejected turn"
                )
            }
            await authorityGate.waitUntilEntered()
            let ownership = try XCTUnwrap(fixture.session.activeRunOwnership)
            fixture.session.codexController = nil
            await authorityGate.open()

            guard case let .preDispatchRejected(message)? = await send.value else {
                return XCTFail("Expected a definite fresh-start pre-dispatch rejection")
            }
            XCTAssertTrue(message.contains("Your message was restored"))
            XCTAssertTrue(fixture.controller.startedTurns.isEmpty)
            XCTAssertTrue(fixture.controller.steeredTurns.isEmpty)
            XCTAssertNil(fixture.session.codexPendingAuthRetryTurn)
            XCTAssertEqual(fixture.session.runState, .failed)
            XCTAssertNil(fixture.session.activeRunOwnership)
            XCTAssertEqual(fixture.session.lastTerminalCommitRevision?.ownership, ownership)
            XCTAssertEqual(fixture.session.lastTerminalCommitRevision?.terminalState, .failed)
            XCTAssertFalse(fixture.viewModel.tabsWithActiveAgentRun.contains(fixture.tabID))
        #else
            throw XCTSkip("Catalog observation diagnostics require DEBUG helpers.")
        #endif
    }

    // MARK: Start

    func testInitialStartCarriesExactlyOneSupplementThenGoesQuiet() async throws {
        let fixture = try makeFixture()
        await fixture.inventory.publishCodex(revision: 1, targetCount: 2)
        fixture.session.beginRunAttempt(source: "test.codex.start")

        _ = await fixture.coordinator.sendCodexNativeMessage(
            session: fixture.session,
            text: "first turn",
            attachments: []
        )

        let first = try XCTUnwrap(fixture.controller.startedTurns.first)
        MonitorSupplementAssertions.assertCarriesExactlyOneSupplement(first, userContent: "first turn")
        XCTAssertTrue(
            first.contains("mcp__\(MCPIntegrationHelper.repoPromptMCPServerName)__agent_session_link"),
            "Codex sessions must see the namespace-qualified tool reference"
        )

        fixture.session.runState = .idle
        fixture.session.beginRunAttempt(source: "test.codex.start.second")
        _ = await fixture.coordinator.sendCodexNativeMessage(
            session: fixture.session,
            text: "second turn",
            attachments: []
        )

        let second = try XCTUnwrap(fixture.controller.startedTurns.last)
        MonitorSupplementAssertions.assertCarriesNoSupplement(second)
        MonitorSupplementAssertions.assertNotPersisted(in: fixture.session)
    }

    func testMembershipChangeReopensTheSupplementOnTheNextStart() async throws {
        let fixture = try makeFixture()
        await fixture.inventory.publishCodex(revision: 1, targetCount: 1)
        fixture.session.beginRunAttempt(source: "test.codex.rev1")
        _ = await fixture.coordinator.sendCodexNativeMessage(
            session: fixture.session,
            text: "turn one",
            attachments: []
        )

        await fixture.inventory.publishCodex(revision: 2, targetCount: 2)
        fixture.session.runState = .idle
        fixture.session.beginRunAttempt(source: "test.codex.rev2")
        _ = await fixture.coordinator.sendCodexNativeMessage(
            session: fixture.session,
            text: "turn two",
            attachments: []
        )

        let second = try XCTUnwrap(fixture.controller.startedTurns.last)
        MonitorSupplementAssertions.assertCarriesExactlyOneSupplement(second, userContent: "turn two")
        XCTAssertTrue(second.contains("count=\"2\""))
    }

    func testLastLinkRevocationDeliversOneClosingNoticeThenSilence() async throws {
        let fixture = try makeFixture()
        await fixture.inventory.publishCodex(revision: 1, targetCount: 1)
        fixture.session.beginRunAttempt(source: "test.codex.linked")
        _ = await fixture.coordinator.sendCodexNativeMessage(
            session: fixture.session,
            text: "linked turn",
            attachments: []
        )

        await fixture.inventory.publishCodex(revision: 2, targetCount: 0)
        fixture.session.runState = .idle
        fixture.session.beginRunAttempt(source: "test.codex.revoked")
        _ = await fixture.coordinator.sendCodexNativeMessage(
            session: fixture.session,
            text: "after revoke",
            attachments: []
        )
        let closing = try XCTUnwrap(fixture.controller.startedTurns.last)
        MonitorSupplementAssertions.assertCarriesExactlyOneSupplement(closing, userContent: "after revoke")
        XCTAssertTrue(closing.contains("status=\"ended\""))

        fixture.session.runState = .idle
        fixture.session.beginRunAttempt(source: "test.codex.after-revoked")
        _ = await fixture.coordinator.sendCodexNativeMessage(
            session: fixture.session,
            text: "silent turn",
            attachments: []
        )
        try MonitorSupplementAssertions.assertCarriesNoSupplement(
            XCTUnwrap(fixture.controller.startedTurns.last)
        )
    }

    // MARK: Steer

    func testSteerDispatchCarriesTheSupplement() async throws {
        let fixture = try makeFixture()
        await fixture.inventory.publishCodex(revision: 1, targetCount: 1)
        fixture.session.beginRunAttempt(source: "test.codex.steer.seed")
        _ = await fixture.coordinator.sendCodexNativeMessage(
            session: fixture.session,
            text: "seed turn",
            attachments: []
        )
        // The seed consumed revision 1; a membership change makes the steer owe a fresh supplement.
        await fixture.inventory.publishCodex(revision: 2, targetCount: 1)

        // Reach a steerable state the same way the runtime does: the provider reports the turn it
        // started, which installs the authoritative turn identity `codexTurnDispatchPlan` requires.
        fixture.controller.markActiveTurn(id: "turn-1")
        await fixture.coordinator.test_handleCodexNativeEvent(
            .turnStarted(turnID: "turn-1"),
            session: fixture.session,
            sourceController: fixture.controller
        )
        XCTAssertEqual(
            fixture.session.codexAuthoritativeActiveTurn?.turnID,
            "turn-1",
            "the next send must resolve to a steer, not another start"
        )
        XCTAssertTrue(fixture.session.runState.isActive)

        _ = await fixture.coordinator.sendCodexNativeMessage(
            session: fixture.session,
            text: "steered instruction",
            attachments: []
        )

        let steered = try XCTUnwrap(fixture.controller.steeredTurns.last)
        MonitorSupplementAssertions.assertCarriesExactlyOneSupplement(
            steered,
            userContent: "steered instruction"
        )
        MonitorSupplementAssertions.assertNotPersisted(in: fixture.session)
    }

    // MARK: Queued fallback

    func testQueuedFallbackComposesAtDrainTimeWithCurrentMembership() async throws {
        let fixture = try makeFixture()
        await fixture.inventory.publishCodex(revision: 1, targetCount: 1)
        fixture.session.beginRunAttempt(source: "test.codex.fallback.seed")
        _ = await fixture.coordinator.sendCodexNativeMessage(
            session: fixture.session,
            text: "seed turn",
            attachments: []
        )
        await fixture.coordinator.test_handleCodexNativeEvent(
            .turnStarted(turnID: "turn-1"),
            session: fixture.session,
            sourceController: fixture.controller
        )

        // Hold the thread non-idle *before* anything is queued. The pump starts the moment the entry
        // lands and drains on the first idle snapshot it sees, so without this the drain races the
        // membership change below — and a drain that wins composes against the revision the seed turn
        // already acknowledged, which owes no supplement at all. That is a race in the test, not in
        // the product, and anchoring the wait cannot fix it because the bare turn matches the anchor.
        fixture.controller.threadRuntimeStatus = .active(activeFlags: ["turn"])

        // The provider rejects the steer with "no active turn", which is exactly how a turn lands in
        // the fallback queue. Membership changes while it sits there.
        fixture.controller.steerFailure = .noActiveTurn(
            CodexAppServerClient.RequestFailure(
                method: "turn/steer",
                code: nil,
                message: "no active turn",
                data: nil
            )
        )
        let outcome = await fixture.coordinator.sendCodexNativeMessage(
            session: fixture.session,
            text: "queued instruction",
            attachments: []
        )
        guard case .queuedFallback = outcome else {
            return XCTFail("expected the steer rejection to queue a fallback, got \(outcome)")
        }
        MonitorSupplementAssertions.assertNotPersisted(in: fixture.session)

        fixture.controller.steerFailure = nil
        await fixture.inventory.publishCodex(revision: 2, targetCount: 3)
        // Only now may the head drain, so "drain time" provably means "after revision 2".
        fixture.controller.threadRuntimeStatus = .idle

        // The pump drains the head once the thread reports idle.
        //
        // Both the wait and the selection below are anchored with `hasPrefix`, not `contains`: the
        // supplement is always appended *after* the provider text, so a dispatch of this entry is
        // exactly a turn that starts with it. A substring match instead reads the guidance prose,
        // which itself talks about "draining a queued instruction" — so the *seed* turn's supplement
        // satisfied it, the wait returned before the queue had drained at all, and the assertions
        // then ran against the seed turn (one supplement, but ahead of "queued instruction" in the
        // guidance text, and at the enqueue-time revision). Whether the drain happened to land first
        // decided whether the suite passed, which is what made this read as a timing flake.
        try await AsyncTestWait.waitUntil("the queued Codex fallback entry to dispatch", timeout: 5) {
            await MainActor.run {
                fixture.controller.startedTurns.contains { $0.hasPrefix("queued instruction") }
            }
        }

        let dispatched = try XCTUnwrap(
            fixture.controller.startedTurns.last { $0.hasPrefix("queued instruction") }
        )
        MonitorSupplementAssertions.assertCarriesExactlyOneSupplement(
            dispatched,
            userContent: "queued instruction"
        )
        XCTAssertTrue(
            dispatched.contains("count=\"3\""),
            "a queued entry must render membership at drain time, not at enqueue time"
        )
        MonitorSupplementAssertions.assertNotPersisted(in: fixture.session)
    }

    // MARK: Auto-wake dispatch identity

    /// The Auto-wake dispatch identity is exactly one canonical UUID after the reserved prefix.
    func testAutoWakeDispatchIDRendersAndRoundTripsAWakeIDOnly() {
        let wakeID = UUID()
        let dispatchID = AgentSessionLinkPromptDispatchID.autoWake(wakeID: wakeID)

        XCTAssertEqual(dispatchID.rawValue, "lane.autowake:\(wakeID.uuidString)")
        XCTAssertTrue(dispatchID.isAutoWakeFamily)
        XCTAssertEqual(dispatchID.autoWakeID, wakeID)
    }

    /// Ordinary provider dispatch IDs stay ordinary: they are outside the reserved family, so they
    /// take the pass-through path at the physical fence and require no lane batch.
    func testOrdinaryProviderDispatchIDsAreNotAutoWakeFamily() {
        for dispatchID in [
            AgentSessionLinkPromptDispatchID.claudeNativeSend(UUID()),
            .headlessRun(runID: UUID()),
            .acpPromptTurn(runAttemptID: UUID()),
            .acpActiveSteering(runAttemptID: UUID()),
            .waitingContinuation(waitID: UUID())
        ] {
            XCTAssertFalse(dispatchID.isAutoWakeFamily, dispatchID.rawValue)
            XCTAssertNil(dispatchID.autoWakeID, dispatchID.rawValue)
        }
    }

    /// A reserved-family value that does not parse is **malformed, not ordinary**.
    ///
    /// This is the fail-closed rule the whole atomic ID change depends on. If a constructor and the
    /// parser ever disagreed — the historical `lane.autowake:<UUID>:<epoch>` form is the concrete
    /// example — a `nil` identity that also read as "not a wake" would let the physical fence take
    /// its ordinary-dispatch early return and wave an unfenced, unclaimed lane update straight to a
    /// provider. Classifying by prefix first makes that impossible: the value is refused instead.
    func testMalformedReservedFamilyDispatchIDsAreRefusedRatherThanTreatedAsOrdinary() throws {
        let malformed = [
            "lane.autowake:\(UUID().uuidString):7",
            "lane.autowake:\(UUID().uuidString):0",
            "lane.autowake:not-a-uuid",
            "lane.autowake:"
        ]
        let fixture = try makeFixture()

        for raw in malformed {
            let dispatchID = AgentSessionLinkPromptDispatchID(rawValue: raw)
            XCTAssertTrue(dispatchID.isAutoWakeFamily, raw)
            XCTAssertNil(dispatchID.autoWakeID, "\(raw) must not parse as a current wake identity")
            XCTAssertFalse(
                fixture.viewModel.agentSessionLinkAcquirePhysicalDispatch(
                    for: fixture.session,
                    dispatchID: dispatchID
                ),
                "\(raw) must never acquire the physical dispatch boundary"
            )
            XCTAssertTrue(
                AgentModeViewModel.dispatchRequiresLaneBatch(fixture.session, dispatchID),
                "\(raw) must never bypass the lane-batch requirement"
            )
            // The claim store is the authoritative lane-batch fence, and it must classify the same
            // way. Reporting `.nothingOwed` here would tell every provider family "send undecorated"
            // for what is really a lane update — an empty, unjustified turn with no batch at all.
            XCTAssertEqual(
                fixture.viewModel.agentSessionLinkPromptClaimOutcome(
                    for: fixture.session,
                    dispatchID: dispatchID
                ),
                .requiredLaneBatchUnavailable,
                "\(raw) must refuse rather than report nothing owed"
            )
        }
    }

    /// The rewrite seam substitutes the in-flight wake's identity for an *ordinary* provider ID, and
    /// preserves the exact wake ID across preparation, tombstone, and dispatching.
    func testEffectiveDispatchIDPreservesTheExactWakeIDAcrossEveryOwnedPhase() throws {
        let fixture = try makeFixture()
        let wakeID = try prepareAutoWake(fixture)
        let providerID = AgentSessionLinkPromptDispatchID.claudeNativeSend(UUID())

        for phase in [
            AgentSessionLinkAutoWakeAttempt.Phase.preparingDispatch,
            .cancelledBeforeDispatch,
            .dispatching
        ] {
            var attempt = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
            attempt.phase = phase
            fixture.session.oversight.pendingAutoWake = attempt

            let effective = fixture.viewModel.agentSessionLinkEffectiveDispatchID(
                for: fixture.session,
                dispatchID: providerID
            )
            XCTAssertEqual(effective.autoWakeID, wakeID, "\(phase)")
            XCTAssertEqual(effective.rawValue, "lane.autowake:\(wakeID.uuidString)", "\(phase)")
        }
    }

    /// A malformed reserved-family value is left alone by the rewrite: handing it the current wake's
    /// identity would launder a dispatch that never legitimately held one.
    func testEffectiveDispatchIDDoesNotRewriteMalformedReservedFamilyValues() throws {
        let fixture = try makeFixture()
        _ = try prepareAutoWake(fixture)
        let raw = "lane.autowake:\(UUID().uuidString):7"

        let effective = fixture.viewModel.agentSessionLinkEffectiveDispatchID(
            for: fixture.session,
            dispatchID: AgentSessionLinkPromptDispatchID(rawValue: raw)
        )

        XCTAssertEqual(effective.rawValue, raw)
        XCTAssertNil(effective.autoWakeID)
    }

    // MARK: Managed-auth recovery replay

    func testAuthRecoveryReplayOfSettledAutoWakeUsesExactAcceptedEnvelope() async throws {
        let fixture = try makeFixture()
        await fixture.inventory.publishCodex(revision: 1, targetCount: 1)
        let wakeID = try prepareAutoWake(fixture)
        fixture.session.beginRunAttempt(source: "test.codex.auth.autowake")
        _ = await fixture.coordinator.sendCodexNativeMessage(
            session: fixture.session,
            text: "",
            attachments: []
        )

        let original = try XCTUnwrap(fixture.controller.startedTurns.last)
        XCTAssertFalse(original.isEmpty)
        XCTAssertEqual(MonitorSupplementAssertions.fragmentCount(in: original), 1)
        XCTAssertNil(fixture.session.oversight.pendingAutoWake, "the accepted wake must be settled")
        XCTAssertEqual(
            fixture.session.codexPendingAuthRetryTurn?.monitoringDispatchID?.autoWakeID,
            wakeID
        )

        await fixture.coordinator.test_handleCodexNativeEvent(
            .errorNotification(.init(
                message: "external auth is active",
                willRetry: false,
                threadID: nil,
                turnID: nil,
                itemID: nil
            )),
            session: fixture.session,
            sourceController: fixture.controller
        )

        XCTAssertEqual(fixture.controller.startedTurns.count, 2)
        let replay = try XCTUnwrap(fixture.controller.startedTurns.last)
        XCTAssertFalse(replay.isEmpty)
        XCTAssertEqual(replay, original, "the settled wake must replay its exact accepted envelope")
    }

    func testAuthRecoveryReplayOfSettledAutoWakeRefusesWhenPromptContextIsWithheld() async throws {
        let fixture = try makeFixture()
        await fixture.inventory.publishCodex(revision: 1, targetCount: 1)
        _ = try prepareAutoWake(fixture)
        fixture.session.beginRunAttempt(source: "test.codex.auth.autowake.withheld")
        _ = await fixture.coordinator.sendCodexNativeMessage(
            session: fixture.session,
            text: "",
            attachments: []
        )
        XCTAssertEqual(fixture.controller.startedTurns.count, 1)

        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
            fixture.viewModel,
            tabID: fixture.tabID
        )
        _ = fixture.viewModel.agentSessionLinkWithholdPromptInventory(for: endpoint)
        await fixture.inventory.publishCodex(revision: 2, targetCount: 0)

        await fixture.coordinator.test_handleCodexNativeEvent(
            .errorNotification(.init(
                message: "external auth is active",
                willRetry: false,
                threadID: nil,
                turnID: nil,
                itemID: nil
            )),
            session: fixture.session,
            sourceController: fixture.controller
        )

        let didRefresh = await fixture.authRecovery.didRefresh
        XCTAssertTrue(didRefresh, "managed-auth recovery must reach its replay fence")
        XCTAssertEqual(
            fixture.controller.startedTurns.count,
            1,
            "invalid AutoWake authority must not make a second provider call"
        )
    }

    func testAuthRecoveryReplayPreservesTheAlreadyAcknowledgedSupplement() async throws {
        let fixture = try makeFixture()
        await fixture.inventory.publishCodex(revision: 1, targetCount: 1)
        fixture.session.beginRunAttempt(source: "test.codex.auth")
        _ = await fixture.coordinator.sendCodexNativeMessage(
            session: fixture.session,
            text: "auth turn",
            attachments: []
        )
        let original = try XCTUnwrap(fixture.controller.startedTurns.last)
        MonitorSupplementAssertions.assertCarriesExactlyOneSupplement(original, userContent: "auth turn")

        // The provider accepted the dispatch, then failed it with an auth-classified error. Managed
        // recovery replays the same turn; without the acknowledged claim it would ship bare text and
        // the revision would be lost forever, because no later turn owes it again.
        await fixture.coordinator.test_handleCodexNativeEvent(
            .errorNotification(.init(
                message: "stream error: unexpected status 401 Unauthorized from api.openai.com/v1/responses",
                willRetry: false,
                threadID: nil,
                turnID: nil,
                itemID: nil
            )),
            session: fixture.session,
            sourceController: fixture.controller
        )

        let didRefresh = await fixture.authRecovery.didRefresh
        XCTAssertTrue(didRefresh, "the recovery path must have run")
        XCTAssertEqual(fixture.controller.startedTurns.count, 2, "the turn must have been replayed")
        let replay = try XCTUnwrap(fixture.controller.startedTurns.last)
        XCTAssertEqual(replay, original, "the replay must be byte-identical to the accepted dispatch")
        MonitorSupplementAssertions.assertCarriesExactlyOneSupplement(replay, userContent: "auth turn")
        MonitorSupplementAssertions.assertNotPersisted(in: fixture.session)
    }

    func testAuthRecoveryReplayDoesNotResurrectAcceptedInventoryWhilePromptContextIsWithheld() async throws {
        let fixture = try makeFixture()
        await fixture.inventory.publishCodex(revision: 1, targetCount: 1)
        fixture.session.beginRunAttempt(source: "test.codex.auth.withheld")
        _ = await fixture.coordinator.sendCodexNativeMessage(
            session: fixture.session,
            text: "withheld turn",
            attachments: []
        )
        try MonitorSupplementAssertions.assertCarriesExactlyOneSupplement(
            XCTUnwrap(fixture.controller.startedTurns.last),
            userContent: "withheld turn"
        )

        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
            fixture.viewModel,
            tabID: fixture.tabID
        )
        let hold = fixture.viewModel.agentSessionLinkWithholdPromptInventory(for: endpoint)
        await fixture.inventory.publishCodex(revision: 2, targetCount: 0)

        await fixture.coordinator.test_handleCodexNativeEvent(
            .errorNotification(.init(
                message: "external auth is active",
                willRetry: false,
                threadID: nil,
                turnID: nil,
                itemID: nil
            )),
            session: fixture.session,
            sourceController: fixture.controller
        )

        XCTAssertEqual(fixture.controller.startedTurns.count, 2, "the turn must have been replayed")
        let replay = try XCTUnwrap(fixture.controller.startedTurns.last)
        XCTAssertEqual(replay, "withheld turn")
        MonitorSupplementAssertions.assertCarriesNoSupplement(replay)

        fixture.viewModel.agentSessionLinkReleasePromptInventoryHold(
            hold,
            for: endpoint,
            publishing: AgentSessionLinkPromptInventory(
                observerSessionID: fixture.sessionID,
                linkSetRevision: 2,
                items: []
            )
        )
        fixture.session.runState = .idle
        fixture.session.beginRunAttempt(source: "test.codex.auth.withheld.after")
        _ = await fixture.coordinator.sendCodexNativeMessage(
            session: fixture.session,
            text: "later turn",
            attachments: []
        )
        let later = try XCTUnwrap(fixture.controller.startedTurns.last)
        MonitorSupplementAssertions.assertCarriesExactlyOneSupplement(later, userContent: "later turn")
        XCTAssertTrue(later.contains("status=\"ended\""), "the closing notice must remain owed")
    }

    func testAuthRecoveryReplayViaServerRequestIssuePreservesTheSupplement() async throws {
        let fixture = try makeFixture()
        await fixture.inventory.publishCodex(revision: 1, targetCount: 1)
        fixture.session.beginRunAttempt(source: "test.codex.auth.issue")
        _ = await fixture.coordinator.sendCodexNativeMessage(
            session: fixture.session,
            text: "issue turn",
            attachments: []
        )
        let original = try XCTUnwrap(fixture.controller.startedTurns.last)

        await fixture.coordinator.test_handleCodexNativeEvent(
            .serverRequestIssue(.init(
                requestID: .string("req-1"),
                method: "account/chatgptAuthTokens/refresh",
                kind: .authTokensRefreshFailed,
                message: "account/chatgptAuthTokens/refresh failed"
            )),
            session: fixture.session,
            sourceController: fixture.controller
        )

        let didRefresh = await fixture.authRecovery.didRefresh
        XCTAssertTrue(didRefresh)
        XCTAssertEqual(fixture.controller.startedTurns.count, 2)
        XCTAssertEqual(try XCTUnwrap(fixture.controller.startedTurns.last), original)
        try MonitorSupplementAssertions.assertCarriesExactlyOneSupplement(
            XCTUnwrap(fixture.controller.startedTurns.last),
            userContent: "issue turn"
        )
    }

    func testAuthRecoveryReplayShipsCurrentMembershipWhenLinksChangedMidRecovery() async throws {
        let fixture = try makeFixture()
        await fixture.inventory.publishCodex(revision: 1, targetCount: 1)
        fixture.session.beginRunAttempt(source: "test.codex.auth.churn")
        _ = await fixture.coordinator.sendCodexNativeMessage(
            session: fixture.session,
            text: "churn turn",
            attachments: []
        )
        XCTAssertTrue(try XCTUnwrap(fixture.controller.startedTurns.last).contains("count=\"1\""))

        // A monitor is added while the failed turn is being recovered.
        await fixture.inventory.publishCodex(revision: 2, targetCount: 3)
        await fixture.coordinator.test_handleCodexNativeEvent(
            .errorNotification(.init(
                message: "external auth is active",
                willRetry: false,
                threadID: nil,
                turnID: nil,
                itemID: nil
            )),
            session: fixture.session,
            sourceController: fixture.controller
        )

        let replay = try XCTUnwrap(fixture.controller.startedTurns.last)
        MonitorSupplementAssertions.assertCarriesExactlyOneSupplement(replay, userContent: "churn turn")
        XCTAssertTrue(replay.contains("count=\"3\""), "the replay must ship the current membership")

        // Revision 2 is now acknowledged, so an ordinary later turn is quiet.
        fixture.session.runState = .idle
        fixture.session.beginRunAttempt(source: "test.codex.auth.after")
        _ = await fixture.coordinator.sendCodexNativeMessage(
            session: fixture.session,
            text: "later turn",
            attachments: []
        )
        try MonitorSupplementAssertions.assertCarriesNoSupplement(
            XCTUnwrap(fixture.controller.startedTurns.last)
        )
    }

    /// Regression: managed-auth replay classifies by reserved dispatch-ID *family*, never by a parsed
    /// wake.
    ///
    /// `lane.autowake:<UUID>:<epoch>` is the historical spelling: reserved family, no parseable wake.
    /// If this branch asked `autoWakeID != nil` instead of `isAutoWakeFamily`, that value would read
    /// as an ordinary dispatch and fall into the ordinary replay — the one branch that may mint a
    /// fresh lane claim or ship raw stored text. A settled wake is already spent; the only thing it
    /// may ever replay is the exact fragment that was accepted, and an identity that cannot be matched
    /// to that fragment must refuse instead of composing a new turn.
    ///
    /// Membership churns mid-recovery on purpose: the ordinary branch would then have something to
    /// say, so reaching the provider at all is the failure this pins down.
    func testAuthRecoveryReplayRefusesAMalformedReservedFamilyMonitoringIdentity() async throws {
        let fixture = try makeFixture()
        await fixture.inventory.publishCodex(revision: 1, targetCount: 1)
        let wakeID = try prepareAutoWake(fixture)
        fixture.session.beginRunAttempt(source: "test.codex.auth.autowake.malformed")
        _ = await fixture.coordinator.sendCodexNativeMessage(
            session: fixture.session,
            text: "",
            attachments: []
        )
        let accepted = try XCTUnwrap(fixture.controller.startedTurns.last)
        XCTAssertEqual(fixture.controller.startedTurns.count, 1)
        XCTAssertNil(fixture.session.oversight.pendingAutoWake, "the accepted wake must be settled")
        XCTAssertEqual(
            fixture.viewModel.agentSessionLinkPromptClaimStore
                .test_lastAcceptedRevision(observerSessionID: fixture.sessionID),
            1
        )

        // Only the stored replay identity is corrupted. The accepted claim itself stays valid, so the
        // refusal can only come from the identity no longer matching it.
        let malformed = AgentSessionLinkPromptDispatchID(
            rawValue: "lane.autowake:\(wakeID.uuidString):3"
        )
        XCTAssertTrue(malformed.isAutoWakeFamily)
        XCTAssertNil(malformed.autoWakeID, "the fixture must be malformed, not a current wake identity")
        var replayTurn = try XCTUnwrap(fixture.session.codexPendingAuthRetryTurn)
        replayTurn.monitoringDispatchID = malformed
        fixture.session.codexPendingAuthRetryTurn = replayTurn

        await fixture.inventory.publishCodex(revision: 2, targetCount: 3)
        await fixture.coordinator.test_handleCodexNativeEvent(
            .errorNotification(.init(
                message: "external auth is active",
                willRetry: false,
                threadID: nil,
                turnID: nil,
                itemID: nil
            )),
            session: fixture.session,
            sourceController: fixture.controller
        )

        let didRefresh = await fixture.authRecovery.didRefresh
        XCTAssertTrue(didRefresh, "recovery must reach the replay fence rather than stopping before it")
        XCTAssertEqual(
            fixture.controller.startedTurns,
            [accepted],
            "a malformed reserved-family identity must make no second provider call and ship no raw text"
        )
        XCTAssertEqual(
            fixture.viewModel.agentSessionLinkPromptClaimStore
                .test_pendingClaimCount(observerSessionID: fixture.sessionID),
            0,
            "the refused replay must not mint a fresh lane claim"
        )
        XCTAssertEqual(
            fixture.viewModel.agentSessionLinkPromptClaimStore
                .test_lastAcceptedRevision(observerSessionID: fixture.sessionID),
            1,
            "the refused replay must not acknowledge the membership it never delivered"
        )
        XCTAssertNil(
            fixture.session.oversight.pendingAutoWake,
            "a refusal must not resurrect wake state either"
        )
        // Recovery reports refusal rather than success, so the status a dispatched replay would have
        // installed is never reached. The run's terminal handling belongs to the caller and is
        // deliberately not asserted here.
        XCTAssertNotEqual(
            fixture.session.runningStatusText,
            "Waiting for response\u{2026}",
            "a refused replay must not report the success status a dispatched one sets"
        )
    }
}

// MARK: - Claude native, headless, and continuation adapters

/// Non-Codex dispatch adapters driven through the real runners.
@MainActor
final class AgentSessionLinkNativeAndHeadlessPromptAdapterTests: XCTestCase {
    private var retained: [AgentModeViewModel] = []

    override func tearDown() {
        retained.removeAll()
        super.tearDown()
    }

    private struct Fixture {
        let viewModel: AgentModeViewModel
        let session: AgentModeViewModel.TabSession
        let sessionID: UUID
        let tabID: UUID
        let inventory: MonitorInventoryPublisher
        /// Retained: the view model holds its workspace manager weakly.
        let workspaceManager: WorkspaceManagerViewModel
    }

    private func makeFixture(
        agent: AgentProviderKind,
        claudeController: MonitorFakeNativeController? = nil
    ) throws -> Fixture {
        let tabID = UUID()
        // A real run resolves its workspace before it reaches a provider, so the runner-level suites
        // need the same live workspace wiring the cross-session send suite uses.
        let workspaceFiles = WorkspaceFilesViewModel()
        let keyManager = KeyManager(
            secureService: SecureKeysService(secureStorage: TestSecureStorageBackend())
        )
        let apiSettings = APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keyManager),
            keyManager: keyManager,
            loadStoredDataOnInit: false
        )
        let prompt = PromptViewModel(
            fileManager: workspaceFiles,
            apiSettingsViewModel: apiSettings,
            windowID: -1,
            settingsManager: WindowSettingsManager(windowID: -1)
        )
        let manager = WorkspaceManagerViewModel(
            fileManager: workspaceFiles,
            promptViewModel: prompt,
            performInitialWorkspaceActivation: false
        )
        let workspace = WorkspaceModel(
            name: "Oversee prompt adapters",
            repoPaths: [],
            ephemeralFlag: true,
            composeTabs: [ComposeTabState(id: tabID)],
            activeComposeTabID: tabID
        )
        manager.workspaces = [workspace]
        manager.activeWorkspace = workspace

        let viewModel = AgentModeViewModel(
            testWindowID: 1,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in
                LifecycleNoopCodexController(recorder: LifecycleRecorder())
            },
            claudeControllerFactory: claudeController.map { controller in
                { _, _, _, _ in controller }
            },
            connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
            mcpServerEnabler: { true }
        )
        retained.append(viewModel)
        viewModel.workspaceManager = manager
        viewModel.test_setCurrentTabIDOverride(tabID)
        viewModel.test_setAgentSessionSaver { _, _, _ in
            URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("\(UUID().uuidString).json")
        }
        let session = viewModel.session(for: tabID)
        session.selectedAgent = agent
        session.hasLoadedPersistedState = true
        let sessionID = try XCTUnwrap(viewModel.test_ensureSessionBoundToTab(session))
        return Fixture(
            viewModel: viewModel,
            session: session,
            sessionID: sessionID,
            tabID: tabID,
            inventory: MonitorInventoryPublisher(
                viewModel: viewModel,
                observerSessionID: sessionID,
                tabID: tabID
            ),
            workspaceManager: manager
        )
    }

    private func cancelWaitingInstructionForTest(_ session: AgentModeViewModel.TabSession) {
        session.instructionTimeoutTask?.cancel()
        session.instructionTimeoutTask = nil
        let continuation = session.instructionContinuation
        session.instructionContinuation = nil
        session.instructionWaitID = nil
        session.waitingPrompt = nil
        continuation?.resume(throwing: CancellationError())
    }

    private func claudeRunIntent(
        for session: AgentModeViewModel.TabSession,
        source: String
    ) throws -> ClaudeAgentModeCoordinator.NativeSessionIntent {
        let runID = try XCTUnwrap(session.runID)
        session.runState = .running
        let ownership = session.beginRunAttempt(source: source)
        return .runAttempt(ownership: ownership, runID: runID)
    }

    // MARK: Claude native

    func testClaudeNativeSendCarriesExactlyOneSupplementThenGoesQuiet() async throws {
        let controller = MonitorFakeNativeController()
        let fixture = try makeFixture(agent: .claudeCode, claudeController: controller)
        fixture.inventory.publish(revision: 1, targetCount: 2)
        fixture.session.claudeController = controller
        let intent = try claudeRunIntent(
            for: fixture.session,
            source: "test.claude.native.supplement"
        )

        _ = await fixture.viewModel.test_claudeCoordinator.sendClaudeNativeMessage(
            session: fixture.session,
            text: "claude turn",
            attachments: [],
            intent: intent,
            allowsCatalogRouteControllerRecovery: false
        )

        let sent = await controller.sentMessages
        let first = try XCTUnwrap(sent.first)
        MonitorSupplementAssertions.assertCarriesExactlyOneSupplement(first, userContent: "claude turn")
        XCTAssertTrue(
            first.contains("mcp__\(MCPIntegrationHelper.repoPromptMCPServerName)__agent_session_link"),
            "Claude-compatible runtimes resolve RepoPrompt tools by their server-qualified name"
        )
        MonitorSupplementAssertions.assertNotPersisted(in: fixture.session)

        _ = await fixture.viewModel.test_claudeCoordinator.sendClaudeNativeMessage(
            session: fixture.session,
            text: "second turn",
            attachments: [],
            intent: intent,
            allowsCatalogRouteControllerRecovery: false
        )
        let after = await controller.sentMessages
        try MonitorSupplementAssertions.assertCarriesNoSupplement(XCTUnwrap(after.last))
    }

    func testClaudeNativeRevocationDeliversOneClosingNotice() async throws {
        let controller = MonitorFakeNativeController()
        let fixture = try makeFixture(agent: .claudeCode, claudeController: controller)
        fixture.inventory.publish(revision: 1, targetCount: 1)
        fixture.session.claudeController = controller
        let intent = try claudeRunIntent(
            for: fixture.session,
            source: "test.claude.native.revocation"
        )
        _ = await fixture.viewModel.test_claudeCoordinator.sendClaudeNativeMessage(
            session: fixture.session,
            text: "linked",
            attachments: [],
            intent: intent,
            allowsCatalogRouteControllerRecovery: false
        )

        fixture.inventory.publish(revision: 2, targetCount: 0)
        _ = await fixture.viewModel.test_claudeCoordinator.sendClaudeNativeMessage(
            session: fixture.session,
            text: "after revoke",
            attachments: [],
            intent: intent,
            allowsCatalogRouteControllerRecovery: false
        )

        let sent = await controller.sentMessages
        let closing = try XCTUnwrap(sent.last)
        MonitorSupplementAssertions.assertCarriesExactlyOneSupplement(closing, userContent: "after revoke")
        XCTAssertTrue(closing.contains("status=\"ended\""))
    }

    func testClaudeNativeLostCatalogRouteRecyclesControllerBeforeDispatch() async throws {
        try await assertClaudeNativeLostCatalogRouteRecovery(
            readiness: [.timedOut, .ready],
            finalRoutePresence: [true]
        )
    }

    func testClaudeNativeFinalCatalogFenceLossRecyclesControllerBeforeDispatch() async throws {
        try await assertClaudeNativeLostCatalogRouteRecovery(
            readiness: [.ready, .ready],
            finalRoutePresence: [false, true]
        )
    }

    func testClaudeNativeActiveSteeringFailsClosedWithoutRecyclingOwnedEventStream() async {
        let controller = MonitorFakeNativeController()
        var factoryCalls = 0
        let coordinator = ClaudeAgentModeCoordinator(
            windowID: 1,
            workspacePathProvider: { _ in nil },
            claudeControllerFactory: { _, _, _, _ in
                factoryCalls += 1
                return controller
            }
        )
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        session.selectedAgent = .claudeCode
        session.hasLoadedPersistedState = true
        session.testInstallPersistentSessionBinding(sessionID: UUID())
        let runID = UUID()
        session.installRunID(runID)
        session.runState = .running
        let ownership = session.beginRunAttempt(source: "test.claude.active-steering-route-loss")
        let intent = ClaudeAgentModeCoordinator.NativeSessionIntent.runAttempt(
            ownership: ownership,
            runID: runID
        )

        var physicalDispatchNotAttemptedCount = 0
        coordinator.installHostCapabilities(
            .init(
                isSessionCurrent: { candidate in candidate === session },
                requestUIRefresh: { _, _ in },
                scheduleSave: { _ in },
                stageClaudeResumeRecoveryHandoff: { _ in },
                prependPendingHandoff: { text, _ in text },
                ensureAgentSessionLinkProviderInputCatalogReady: { _ in .timedOut },
                hasCurrentAgentSessionLinkProviderInputCatalogRoute: { _ in false },
                decorateAgentSessionLinkPrompt: { text, _, _ in
                    .init(text: text, claim: nil, mustAbortDispatch: false)
                },
                acquireAgentSessionLinkPhysicalDispatch: { _, _ in true },
                recordAgentSessionLinkPhysicalDispatchNotAttempted: { _, _ in
                    physicalDispatchNotAttemptedCount += 1
                },
                recordAgentSessionLinkPhysicalDispatchFailure: { _, _ in },
                acceptAgentSessionLinkPromptClaim: { _ in }
            ),
            providerBindingService: AgentModeProviderBindingService()
        )
        let initialSessionOutcome = await coordinator.ensureClaudeNativeSession(
            session: session,
            intent: intent
        )
        XCTAssertEqual(initialSessionOutcome, .ready)

        let outcome = await coordinator.sendClaudeNativeMessage(
            session: session,
            text: "steer active run",
            attachments: [],
            intent: intent,
            allowsCatalogRouteControllerRecovery: false
        )
        let shutdownCount = await controller.shutdownCount
        let sentCount = await controller.sentCount

        guard case let .failed(message) = outcome else {
            return XCTFail("expected route loss to fail closed, got \(outcome)")
        }
        XCTAssertTrue(message.contains("could not verify the exact RepoPrompt MCP route"))
        XCTAssertEqual(factoryCalls, 1)
        XCTAssertEqual(physicalDispatchNotAttemptedCount, 1)
        XCTAssertEqual(shutdownCount, 0)
        XCTAssertEqual(sentCount, 0)
        XCTAssertTrue(session.claudeController === controller)
    }

    private func assertClaudeNativeLostCatalogRouteRecovery(
        readiness: [AgentModeViewModel.ProviderInputCatalogReadiness],
        finalRoutePresence: [Bool]
    ) async throws {
        let firstController = MonitorFakeNativeController()
        let replacementController = MonitorFakeNativeController()
        var controllers = [firstController, replacementController]
        let coordinator = ClaudeAgentModeCoordinator(
            windowID: 1,
            workspacePathProvider: { _ in nil },
            claudeControllerFactory: { _, _, _, _ in
                controllers.removeFirst()
            }
        )
        let providerBindingService = AgentModeProviderBindingService()
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        session.selectedAgent = .claudeCode
        session.hasLoadedPersistedState = true
        session.testInstallPersistentSessionBinding(sessionID: UUID())
        let runID = UUID()
        session.installRunID(runID)
        session.runState = .running
        let ownership = session.beginRunAttempt(source: "test.claude.catalog-route-recovery")

        var pendingReadiness = readiness
        var pendingFinalRoutePresence = finalRoutePresence
        var physicalDispatchNotAttemptedCount = 0
        coordinator.installHostCapabilities(
            .init(
                isSessionCurrent: { candidate in candidate === session },
                requestUIRefresh: { _, _ in },
                scheduleSave: { _ in },
                stageClaudeResumeRecoveryHandoff: { _ in },
                prependPendingHandoff: { text, _ in text },
                ensureAgentSessionLinkProviderInputCatalogReady: { _ in
                    pendingReadiness.removeFirst()
                },
                hasCurrentAgentSessionLinkProviderInputCatalogRoute: { _ in
                    pendingFinalRoutePresence.removeFirst()
                },
                decorateAgentSessionLinkPrompt: { text, _, _ in
                    .init(text: text, claim: nil, mustAbortDispatch: false)
                },
                acquireAgentSessionLinkPhysicalDispatch: { _, _ in true },
                recordAgentSessionLinkPhysicalDispatchNotAttempted: { _, _ in
                    physicalDispatchNotAttemptedCount += 1
                },
                recordAgentSessionLinkPhysicalDispatchFailure: { _, _ in },
                acceptAgentSessionLinkPromptClaim: { _ in }
            ),
            providerBindingService: providerBindingService
        )

        let outcome = await coordinator.sendClaudeNativeMessage(
            session: session,
            text: "continue oversight",
            attachments: [],
            intent: .runAttempt(ownership: ownership, runID: runID),
            allowsCatalogRouteControllerRecovery: true
        )
        let firstSentCount = await firstController.sentCount
        let firstShutdownCount = await firstController.shutdownCount
        let firstResumeIDs = await firstController.startOrResumeExistingSessionIDs
        let replacementMessages = await replacementController.sentMessages
        let replacementResumeIDs = await replacementController.startOrResumeExistingSessionIDs

        XCTAssertEqual(outcome, .sent)
        XCTAssertTrue(pendingReadiness.isEmpty)
        XCTAssertTrue(pendingFinalRoutePresence.isEmpty)
        XCTAssertEqual(physicalDispatchNotAttemptedCount, 0)
        XCTAssertEqual(firstSentCount, 0)
        XCTAssertEqual(firstShutdownCount, 1)
        XCTAssertEqual(firstResumeIDs.count, 1)
        XCTAssertNil(firstResumeIDs[0])
        XCTAssertEqual(replacementResumeIDs, ["monitor-native-session"])
        XCTAssertEqual(replacementMessages, ["continue oversight"])
        XCTAssertEqual(session.runID, runID, "route recovery preserves the logical process run")
    }

    func testClaudeNativeCatalogReadinessUsesExactReadyRoute() async throws {
        #if DEBUG
            let fixture = try makeFixture(agent: .claudeCode)
            fixture.session.installRunID(UUID())
            let runID = try XCTUnwrap(fixture.session.runID)
            let endpoint = try XCTUnwrap(
                fixture.viewModel.agentSessionLinkObserverEndpoint(tabID: fixture.tabID)
            )
            let routeToken = AgentSessionLinkRunCatalogRouteToken(
                runID: runID,
                observerEndpoint: endpoint,
                connectionID: UUID(),
                routingAuthorityGeneration: 1,
                connectionLifecycleGeneration: 1
            )
            fixture.viewModel.test_agentSessionLinkHasActiveOutboundLink = { candidate in
                candidate == endpoint
            }
            fixture.viewModel.test_agentSessionLinkAuthoritativeRunCatalogRouteToken = {
                requestedRunID,
                requestedWindowID,
                requestedTabID in
                guard requestedRunID == runID,
                      requestedWindowID == endpoint.windowID,
                      requestedTabID == endpoint.tabID
                else { return nil }
                return routeToken
            }
            fixture.viewModel.test_agentSessionLinkCurrentRunCatalogRouteToken = { candidate, requestedTabID in
                candidate == routeToken && requestedTabID == endpoint.tabID
            }
            fixture.viewModel.agentSessionLinkPublishRunCatalogProjection(
                AgentSessionLinkRunCatalogProjection(
                    runID: runID,
                    routeToken: routeToken,
                    projectionRevision: 1,
                    hasAgentSessionLink: true
                ),
                to: endpoint
            )

            let readiness = await fixture.viewModel.ensureProviderInputCatalogReady(for: fixture.session)
            XCTAssertEqual(readiness, .ready)
            XCTAssertTrue(
                fixture.viewModel.agentSessionLinkHasCurrentProviderInputCatalogRoute(for: fixture.session)
            )
        #else
            throw XCTSkip("Catalog route seams require DEBUG helpers.")
        #endif
    }

    func testClaudeNativeCatalogReadinessIsNotRequiredWithoutActiveOutboundLink() async throws {
        #if DEBUG
            let fixture = try makeFixture(agent: .claudeCode)
            fixture.session.installRunID(UUID())
            _ = try XCTUnwrap(
                fixture.viewModel.agentSessionLinkObserverEndpoint(tabID: fixture.tabID)
            )
            fixture.viewModel.test_agentSessionLinkHasActiveOutboundLink = { _ in false }

            let readiness = await fixture.viewModel.ensureProviderInputCatalogReady(for: fixture.session)
            XCTAssertEqual(readiness, .notRequired)
        #else
            throw XCTSkip("Catalog route seams require DEBUG helpers.")
        #endif
    }

    func testClaudeNativeFinalCatalogFenceRejectsStaleRouteToken() async throws {
        #if DEBUG
            let fixture = try makeFixture(agent: .claudeCode)
            fixture.session.installRunID(UUID())
            let runID = try XCTUnwrap(fixture.session.runID)
            let endpoint = try XCTUnwrap(
                fixture.viewModel.agentSessionLinkObserverEndpoint(tabID: fixture.tabID)
            )
            let routeToken = AgentSessionLinkRunCatalogRouteToken(
                runID: runID,
                observerEndpoint: endpoint,
                connectionID: UUID(),
                routingAuthorityGeneration: 1,
                connectionLifecycleGeneration: 1
            )
            fixture.viewModel.test_agentSessionLinkHasActiveOutboundLink = { _ in true }
            fixture.viewModel.test_agentSessionLinkAuthoritativeRunCatalogRouteToken = { _, _, _ in
                routeToken
            }
            fixture.viewModel.test_agentSessionLinkCurrentRunCatalogRouteToken = { _, _ in false }
            fixture.viewModel.agentSessionLinkPublishRunCatalogProjection(
                AgentSessionLinkRunCatalogProjection(
                    runID: runID,
                    routeToken: routeToken,
                    projectionRevision: 1,
                    hasAgentSessionLink: true
                ),
                to: endpoint
            )

            let readiness = await fixture.viewModel.ensureProviderInputCatalogReady(for: fixture.session)
            XCTAssertEqual(readiness, .ready)
            XCTAssertFalse(
                fixture.viewModel.agentSessionLinkHasCurrentProviderInputCatalogRoute(for: fixture.session)
            )
        #else
            throw XCTSkip("Catalog route seams require DEBUG helpers.")
        #endif
    }

    // MARK: Waiting-instruction continuations

    func testQueuedContinuationComposesAtDrainTimeWithCurrentMembership() async throws {
        let fixture = try makeFixture(agent: .claudeCode)
        // The instruction was queued before any monitor existed; membership is read at drain time.
        fixture.session.pendingInstructions = ["queued instruction"]
        fixture.inventory.publish(revision: 1, targetCount: 2)

        let response = try await fixture.viewModel.waitForNextUserInstruction(tabID: fixture.tabID)

        let text = try XCTUnwrap(response.text)
        MonitorSupplementAssertions.assertCarriesExactlyOneSupplement(
            text,
            userContent: "queued instruction"
        )
        XCTAssertTrue(text.contains("count=\"2\""))
        MonitorSupplementAssertions.assertNotPersisted(in: fixture.session)
    }

    func testCatalogReadinessRejectsAppliedProjectionWithoutAuthoritativeRouteToken() async throws {
        #if DEBUG
            let fixture = try makeFixture(agent: .codexExec)
            fixture.viewModel.test_agentSessionLinkHasActiveOutboundLink = { _ in true }
            fixture.session.installRunID(UUID())
            let runID = try XCTUnwrap(fixture.session.runID)
            let endpoint = try XCTUnwrap(
                fixture.viewModel.agentSessionLinkObserverEndpoint(tabID: fixture.tabID)
            )
            XCTAssertNil(
                fixture.viewModel.agentSessionLinkPromptInventoryBySessionID[fixture.sessionID],
                "prompt inventory is intentionally withheld"
            )
            let routeToken = AgentSessionLinkRunCatalogRouteToken(
                runID: runID,
                observerEndpoint: endpoint,
                connectionID: UUID(),
                routingAuthorityGeneration: 1,
                connectionLifecycleGeneration: 1
            )
            let manager = ServerNetworkManager.shared
            let unready = await manager.debugPublishRunCatalogObservation(
                routeToken: routeToken,
                hasAgentSessionLink: nil
            )
            fixture.viewModel.agentSessionLinkPublishRunCatalogProjection(unready, to: endpoint)

            let readiness = Task { @MainActor in
                await fixture.viewModel.ensureProviderInputCatalogReady(for: fixture.session)
            }
            let readyProjection = AgentSessionLinkRunCatalogProjection(
                runID: runID,
                routeToken: routeToken,
                projectionRevision: unready.projectionRevision + 1,
                hasAgentSessionLink: true
            )
            fixture.viewModel.agentSessionLinkPublishRunCatalogProjection(readyProjection, to: endpoint)
            let published = await manager.debugPublishRunCatalogObservation(
                routeToken: routeToken,
                hasAgentSessionLink: true
            )
            XCTAssertEqual(published, readyProjection)
            let readinessOutcome = await readiness.value
            XCTAssertEqual(
                readinessOutcome,
                .unavailable,
                "an applied same-run/endpoint projection cannot prove the server's authoritative connection token"
            )
            await manager.cleanupRunRoutingState(for: runID, windowID: endpoint.windowID)
        #else
            throw XCTSkip("Catalog observation diagnostics require DEBUG helpers.")
        #endif
    }

    func testCodexContinuationCatalogTimeoutRestoresInstructionWithoutResumingProvider() async throws {
        #if DEBUG
            let fixture = try makeFixture(agent: .codexExec)
            fixture.viewModel.test_agentSessionLinkHasActiveOutboundLink = { _ in true }
            fixture.inventory.publish(revision: 1, targetCount: 1)
            let runID = try XCTUnwrap(fixture.session.runID)
            let endpoint = try XCTUnwrap(
                fixture.viewModel.agentSessionLinkObserverEndpoint(tabID: fixture.tabID)
            )
            let routeToken = AgentSessionLinkRunCatalogRouteToken(
                runID: runID,
                observerEndpoint: endpoint,
                connectionID: UUID(),
                routingAuthorityGeneration: 1,
                connectionLifecycleGeneration: 1
            )
            let manager = ServerNetworkManager.shared
            let unready = await manager.debugPublishRunCatalogObservation(
                routeToken: routeToken,
                hasAgentSessionLink: nil
            )
            fixture.viewModel.agentSessionLinkPublishRunCatalogProjection(unready, to: endpoint)

            let controller = LifecycleNoopCodexController(recorder: LifecycleRecorder())
            fixture.session.codexController = controller
            let waiting = Task { @MainActor in
                try await fixture.viewModel.waitForNextUserInstruction(
                    tabID: fixture.tabID,
                    timeoutSeconds: 30
                )
            }
            defer { cancelWaitingInstructionForTest(fixture.session) }
            try await AsyncTestWait.waitUntil("the timeout continuation to install") {
                await MainActor.run { fixture.session.instructionContinuation != nil }
            }
            let waitID = fixture.session.instructionWaitID
            let rawDraft = "  recover this waiting instruction  "
            XCTAssertEqual(
                fixture.viewModel.submitUserTurn(
                    text: rawDraft.trimmingCharacters(in: .whitespacesAndNewlines),
                    tabID: fixture.tabID,
                    rawDraftText: rawDraft
                ),
                .submitted
            )
            fixture.viewModel.storeDraftText(for: fixture.tabID, "")

            try await AsyncTestWait.waitUntil(
                "continuation readiness timeout rollback",
                timeout: 15
            ) {
                await MainActor.run { fixture.viewModel.draftRestorationEvent?.text == rawDraft }
            }
            XCTAssertNotNil(fixture.session.instructionContinuation)
            XCTAssertEqual(fixture.session.instructionWaitID, waitID)
            XCTAssertEqual(fixture.session.runState, .waitingForUser)
            XCTAssertTrue(fixture.session.items.allSatisfy { $0.kind != .user })
            XCTAssertEqual(fixture.viewModel.retrieveDraftText(for: fixture.tabID), rawDraft)
            XCTAssertTrue(
                fixture.viewModel.draftRestorationEvent?.message.contains("catalog readiness timed out") == true
            )

            cancelWaitingInstructionForTest(fixture.session)
            _ = try? await waiting.value
            await manager.cleanupRunRoutingState(for: runID, windowID: endpoint.windowID)
            withExtendedLifetime(controller) {}
        #else
            throw XCTSkip("Catalog observation diagnostics require DEBUG helpers.")
        #endif
    }

    func testRapidCodexContinuationSubmissionsSerializeAndRestoreUnconsumedSecondInstruction() async throws {
        #if DEBUG
            let fixture = try makeFixture(agent: .codexExec)
            let authorityGate = CatalogAuthorityGate()
            fixture.viewModel.test_agentSessionLinkHasActiveOutboundLink = { _ in
                await authorityGate.requirement()
            }
            fixture.inventory.publish(revision: 1, targetCount: 1)
            let runID = try XCTUnwrap(fixture.session.runID)
            let endpoint = try XCTUnwrap(
                fixture.viewModel.agentSessionLinkObserverEndpoint(tabID: fixture.tabID)
            )
            let routeToken = AgentSessionLinkRunCatalogRouteToken(
                runID: runID,
                observerEndpoint: endpoint,
                connectionID: UUID(),
                routingAuthorityGeneration: 1,
                connectionLifecycleGeneration: 1
            )
            fixture.viewModel.test_agentSessionLinkAuthoritativeRunCatalogRouteToken = {
                requestedRunID,
                requestedWindowID,
                requestedTabID in
                guard requestedRunID == routeToken.runID,
                      requestedWindowID == routeToken.observerEndpoint.windowID,
                      requestedTabID == routeToken.observerEndpoint.tabID
                else { return nil }
                return routeToken
            }
            let manager = ServerNetworkManager.shared
            let unready = await manager.debugPublishRunCatalogObservation(
                routeToken: routeToken,
                hasAgentSessionLink: nil
            )
            fixture.viewModel.agentSessionLinkPublishRunCatalogProjection(unready, to: endpoint)

            let controller = LifecycleNoopCodexController(recorder: LifecycleRecorder())
            fixture.session.codexController = controller
            let waiting = Task { @MainActor in
                try await fixture.viewModel.waitForNextUserInstruction(
                    tabID: fixture.tabID,
                    timeoutSeconds: 10
                )
            }
            try await AsyncTestWait.waitUntil("the rapid-submit continuation to install") {
                await MainActor.run { fixture.session.instructionContinuation != nil }
            }

            XCTAssertEqual(fixture.viewModel.submitUserTurn(text: "first instruction", tabID: fixture.tabID), .submitted)
            await authorityGate.waitUntilEntered()
            let secondDraft = "second instruction"
            XCTAssertEqual(
                fixture.viewModel.submitUserTurn(
                    text: secondDraft,
                    tabID: fixture.tabID,
                    rawDraftText: secondDraft
                ),
                .submitted
            )
            fixture.viewModel.storeDraftText(for: fixture.tabID, "")

            await authorityGate.open()
            let readyProjection = AgentSessionLinkRunCatalogProjection(
                runID: runID,
                routeToken: routeToken,
                projectionRevision: unready.projectionRevision + 1,
                hasAgentSessionLink: true
            )
            fixture.viewModel.agentSessionLinkPublishRunCatalogProjection(readyProjection, to: endpoint)
            _ = await manager.debugPublishRunCatalogObservation(
                routeToken: routeToken,
                hasAgentSessionLink: true
            )

            let response = try await waiting.value
            XCTAssertTrue(try XCTUnwrap(response.text).contains("first instruction"))
            try await AsyncTestWait.waitUntil("the queued second instruction to restore") {
                await MainActor.run { fixture.viewModel.draftRestorationEvent?.text == secondDraft }
            }
            XCTAssertEqual(
                fixture.session.items.filter { $0.kind == .user }.map(\.text),
                ["first instruction"]
            )
            XCTAssertEqual(fixture.viewModel.retrieveDraftText(for: fixture.tabID), secondDraft)
            XCTAssertNil(fixture.session.instructionContinuation)
            await manager.cleanupRunRoutingState(for: runID, windowID: endpoint.windowID)
            withExtendedLifetime(controller) {}
        #else
            throw XCTSkip("Catalog observation diagnostics require DEBUG helpers.")
        #endif
    }

    func testCodexResumedContinuationWaitsForServerObservedCatalogReadiness() async throws {
        #if DEBUG
            let fixture = try makeFixture(agent: .codexExec)
            let authorityGate = CatalogAuthorityGate()
            fixture.viewModel.test_agentSessionLinkHasActiveOutboundLink = { _ in
                await authorityGate.requirement()
            }
            fixture.inventory.publish(revision: 1, targetCount: 1)
            let runID = try XCTUnwrap(fixture.session.runID)
            let endpoint = try XCTUnwrap(
                fixture.viewModel.agentSessionLinkObserverEndpoint(tabID: fixture.tabID)
            )
            let routeToken = AgentSessionLinkRunCatalogRouteToken(
                runID: runID,
                observerEndpoint: endpoint,
                connectionID: UUID(),
                routingAuthorityGeneration: 1,
                connectionLifecycleGeneration: 1
            )
            fixture.viewModel.test_agentSessionLinkAuthoritativeRunCatalogRouteToken = {
                requestedRunID,
                requestedWindowID,
                requestedTabID in
                guard requestedRunID == routeToken.runID,
                      requestedWindowID == routeToken.observerEndpoint.windowID,
                      requestedTabID == routeToken.observerEndpoint.tabID
                else { return nil }
                return routeToken
            }
            let manager = ServerNetworkManager.shared
            let unready = await manager.debugPublishRunCatalogObservation(
                routeToken: routeToken,
                hasAgentSessionLink: nil
            )
            fixture.viewModel.agentSessionLinkPublishRunCatalogProjection(unready, to: endpoint)

            let controller = LifecycleNoopCodexController(recorder: LifecycleRecorder())
            fixture.session.codexController = controller
            defer { withExtendedLifetime(controller) {} }
            let waiting = Task { @MainActor in
                try await fixture.viewModel.waitForNextUserInstruction(tabID: fixture.tabID)
            }
            try await AsyncTestWait.waitUntil("the Codex continuation to install") {
                await MainActor.run { fixture.session.instructionContinuation != nil }
            }
            let expectedWaitID = fixture.session.instructionWaitID
            let expectedControllerID = fixture.session.codexController.map(ObjectIdentifier.init)
            let submission = fixture.viewModel.submitUserTurn(text: "resumed instruction")
            XCTAssertEqual(submission, .submitted)

            await authorityGate.waitUntilEntered()
            XCTAssertNotNil(
                fixture.session.instructionContinuation,
                "active-link input must remain suspended while the exact catalog is unready"
            )
            XCTAssertEqual(fixture.session.instructionWaitID, expectedWaitID)
            XCTAssertEqual(fixture.session.codexController.map(ObjectIdentifier.init), expectedControllerID)
            await authorityGate.open()

            let expectedReady = AgentSessionLinkRunCatalogProjection(
                runID: runID,
                routeToken: routeToken,
                projectionRevision: unready.projectionRevision + 1,
                hasAgentSessionLink: true
            )
            fixture.viewModel.agentSessionLinkPublishRunCatalogProjection(expectedReady, to: endpoint)
            let ready = await manager.debugPublishRunCatalogObservation(
                routeToken: routeToken,
                hasAgentSessionLink: true
            )
            XCTAssertEqual(ready, expectedReady)
            let readiness = await fixture.viewModel.ensureProviderInputCatalogReady(for: fixture.session)
            XCTAssertEqual(readiness, .ready)
            try? await AsyncTestWait.waitUntil(
                "exact readiness to resume the continuation"
            ) {
                await MainActor.run { fixture.session.instructionContinuation == nil }
            }
            guard fixture.session.instructionContinuation == nil else {
                cancelWaitingInstructionForTest(fixture.session)
                _ = try? await waiting.value
                return XCTFail("exact readiness did not resume the waiting continuation")
            }
            let response = try await waiting.value
            try MonitorSupplementAssertions.assertCarriesExactlyOneSupplement(
                XCTUnwrap(response.text),
                userContent: "resumed instruction"
            )
            XCTAssertNil(fixture.session.instructionContinuation)
            await manager.cleanupRunRoutingState(for: runID, windowID: endpoint.windowID)
        #else
            throw XCTSkip("Catalog observation diagnostics require DEBUG helpers.")
        #endif
    }

    func testResumedContinuationCarriesExactlyOneSupplementAndConsumesItOnce() async throws {
        let fixture = try makeFixture(agent: .claudeCode)
        fixture.inventory.publish(revision: 1, targetCount: 1)

        let waiting = Task { @MainActor in
            try await fixture.viewModel.waitForNextUserInstruction(tabID: fixture.tabID)
        }
        try await AsyncTestWait.waitUntil("the waiting continuation to install") {
            await MainActor.run { fixture.session.instructionContinuation != nil }
        }

        _ = fixture.viewModel.submitUserTurn(text: "resumed instruction")

        let response = try await waiting.value
        let text = try XCTUnwrap(response.text)
        MonitorSupplementAssertions.assertCarriesExactlyOneSupplement(
            text,
            userContent: "resumed instruction"
        )
        MonitorSupplementAssertions.assertNotPersisted(in: fixture.session)

        // The revision is consumed: a later queued continuation at the same membership is quiet.
        fixture.session.runState = .idle
        fixture.session.pendingInstructions = ["later instruction"]
        let later = try await fixture.viewModel.waitForNextUserInstruction(tabID: fixture.tabID)
        try MonitorSupplementAssertions.assertCarriesNoSupplement(XCTUnwrap(later.text))
    }
}

// MARK: - Non-Codex fakes

actor MonitorFakeNativeController: NativeAgentRuntimeControlling {
    private(set) var sentMessages: [String] = []
    private(set) var shutdownCount = 0
    private(set) var startOrResumeExistingSessionIDs: [String?] = []
    private var stream: AsyncStream<NativeAgentRuntimeEvent>?
    private var continuation: AsyncStream<NativeAgentRuntimeEvent>.Continuation?

    var sentCount: Int {
        sentMessages.count
    }

    var hasActiveSession: Bool {
        true
    }

    var hasTurnInFlight: Bool {
        false
    }

    var events: AsyncStream<NativeAgentRuntimeEvent> {
        if let stream {
            return stream
        }
        let created = AsyncStream<NativeAgentRuntimeEvent> { continuation in
            self.continuation = continuation
        }
        stream = created
        return created
    }

    func ensureEventsStreamReady() async {}
    func resetEventsStreamForNewRun() async {}

    func startOrResume(
        existingSessionID: String?,
        model _: String?,
        effortLevel _: NativeAgentRuntimeEffortLevel?,
        systemPromptOverride _: String?
    ) async throws -> NativeAgentRuntimeSessionRef {
        startOrResumeExistingSessionIDs.append(existingSessionID)
        return NativeAgentRuntimeSessionRef(sessionID: existingSessionID ?? "monitor-native-session")
    }

    func currentSessionRef() async -> NativeAgentRuntimeSessionRef {
        NativeAgentRuntimeSessionRef(sessionID: "monitor-native-session")
    }

    func applyModelAndEffort(model _: String?, effortLevel _: NativeAgentRuntimeEffortLevel?) async throws {}

    func sendUserMessage(_ text: String) async throws -> UUID {
        sentMessages.append(text)
        return UUID()
    }

    func interruptTurn(reason _: String) async -> NativeAgentRuntimeInterruptOutcome {
        .noTurnInFlight
    }

    func shutdown() async {
        shutdownCount += 1
        continuation?.finish()
    }

    func respondToPermissionRequest(id _: String, decision _: AgentApprovalDecision) async {}
}

// MARK: - Codex fakes

final class MonitorFakeCodexController: CodexSessionControllerPassiveStubDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var started: [String] = []
    private var steered: [String] = []
    private var activeTurnID: String?
    private var threadStarted = false
    private var startOrResumeHook: (@Sendable () async -> Void)?
    /// When set, `steerUserTurn` throws it instead of accepting, which is how the runtime lands in
    /// the queued-fallback path.
    var steerFailure: CodexTurnSteerError?
    /// Runtime status the queued-fallback pump reads. Idle unless a test deliberately holds it.
    var threadRuntimeStatus: CodexNativeSessionController.ThreadSnapshot.RuntimeStatus {
        get { lock.withLock { runtimeStatus } }
        set { lock.withLock { runtimeStatus = newValue } }
    }

    private var runtimeStatus: CodexNativeSessionController.ThreadSnapshot.RuntimeStatus = .idle
    private let continuation: AsyncStream<CodexNativeSessionController.Event>.Continuation
    private let stream: AsyncStream<CodexNativeSessionController.Event>

    init() {
        var storedContinuation: AsyncStream<CodexNativeSessionController.Event>.Continuation!
        stream = AsyncStream { storedContinuation = $0 }
        continuation = storedContinuation
    }

    var startedTurns: [String] {
        lock.lock()
        defer { lock.unlock() }
        return started
    }

    var steeredTurns: [String] {
        lock.lock()
        defer { lock.unlock() }
        return steered
    }

    func markActiveTurn(id: String) {
        lock.lock()
        activeTurnID = id
        lock.unlock()
    }

    func setStartOrResumeHook(_ hook: (@Sendable () async -> Void)?) {
        lock.lock()
        startOrResumeHook = hook
        lock.unlock()
    }

    /// False until `startOrResume` runs, exactly like the real controller.
    ///
    /// A fake that reports an active thread from construction makes `ensureCodexNativeSession`
    /// short-circuit, so the session never receives a conversation ID and can never reach a steerable
    /// authoritative turn.
    var hasActiveThread: Bool {
        lock.lock()
        defer { lock.unlock() }
        return threadStarted
    }

    var events: AsyncStream<CodexNativeSessionController.Event> {
        stream
    }

    func startOrResume(
        existing _: CodexNativeSessionController.SessionRef?,
        baseInstructions _: String,
        model: String?,
        reasoningEffort: String?,
        serviceTier _: String?
    ) async throws -> CodexNativeSessionController.SessionRef {
        let hook = lock.withLock {
            threadStarted = true
            return startOrResumeHook
        }
        await hook?()
        return CodexNativeSessionController.SessionRef(
            conversationID: "monitor-thread",
            rolloutPath: nil,
            model: model,
            reasoningEffort: reasoningEffort
        )
    }

    func startUserTurn(
        text: String,
        images _: [AgentImageAttachment],
        model _: String?,
        reasoningEffort _: String?,
        serviceTier _: String?
    ) async throws -> CodexTurnStartReceipt {
        lock.lock()
        started.append(text)
        lock.unlock()
        return CodexTurnStartReceipt(provisionalSubmissionID: "sub-\(started.count)")
    }

    func steerUserTurn(
        text: String,
        images _: [AgentImageAttachment],
        expectedTurnID: String
    ) async throws -> CodexTurnSteerReceipt {
        if let steerFailure {
            throw steerFailure
        }
        lock.lock()
        steered.append(text)
        lock.unlock()
        return CodexTurnSteerReceipt(acceptedTurnID: expectedTurnID)
    }

    /// Reports an idle thread by default, so the queued-fallback pump can claim its head.
    ///
    /// `threadRuntimeStatus` exists because "the pump may drain at any moment" is exactly what makes
    /// a drain-time assertion racy: a test that changes state *after* queueing has no way to be sure
    /// the drain has not already happened. Holding the thread non-idle is the seam that lets one test
    /// order the two, and the default keeps every other suite drainable exactly as before.
    func readThreadSnapshot(
        includeTurns _: Bool,
        timeout _: TimeInterval?
    ) async throws -> CodexNativeSessionController.ThreadSnapshot {
        CodexNativeSessionController.ThreadSnapshot(
            conversationID: "monitor-thread",
            rolloutPath: nil,
            model: nil,
            reasoningEffort: nil,
            runtimeStatus: threadRuntimeStatus,
            currentTurnID: nil,
            activeTurnIDs: [],
            latestTurnStatus: nil
        )
    }

    func prepareLifecycleAuthorityReconciliationAfterAcceptedMismatch(
        expectedCurrentTurnID _: String,
        acceptedDispatchTurnID _: String
    ) async -> Bool {
        true
    }

    func reconcileAndInterruptCurrentTurn() async throws -> CodexTurnInterruptReceipt {
        CodexTurnInterruptReceipt(interruptedTurnID: activeTurnID ?? "turn")
    }

    func pendingTurnFailure(turnID _: String?) async -> CodexNativeSessionController.TurnFailure? {
        nil
    }

    func acknowledgePendingTurnFailure(
        turnID _: String?,
        failure _: CodexNativeSessionController.TurnFailure
    ) async {}

    func shutdown() async {
        continuation.finish()
    }
}

actor MonitorStubCodexAuthRecovery: CodexManagedAuthRecovering {
    private(set) var didRefresh = false

    func refreshManagedAccount() async -> CodexManagedAuthRefreshResult {
        didRefresh = true
        return .recovered(account: nil)
    }

    func managedAccountSnapshot() async -> CodexManagedAccount? {
        nil
    }

    func startManagedChatgptLogin(
        openURL _: @MainActor @escaping @Sendable (URL) -> Void
    ) async -> CodexManagedChatgptLoginResult {
        .failed(message: "unused")
    }

    func startManagedChatgptDeviceCodeLogin(
        presentDeviceCode _: @MainActor @escaping @Sendable (CodexManagedChatgptDeviceCode, Bool) -> Void
    ) async -> CodexManagedChatgptLoginResult {
        .failed(message: "unused")
    }

    func logoutManagedAccount() async -> CodexManagedAuthLogoutResult {
        .signedOut
    }
}
