import Foundation
import MCP
import RepoPromptSecureStorage
import RepoPromptShared
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
            XCTAssertFalse(instruction.providerText.contains(AgentSessionLinkPrompts.envelopeTag), file: file, line: line)
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
                        hasAgentSessionLink: true,
                        hasAnyActiveLink: true
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
        let dispatches: MonitorCodexDispatchRecorder
        let session: AgentModeViewModel.TabSession
        let sessionID: UUID
        let tabID: UUID
        let inventory: MonitorInventoryPublisher
        let authRecovery: MonitorStubCodexAuthRecovery
        /// Retained: the view model holds its workspace manager weakly.
        let workspaceManager: WorkspaceManagerViewModel

        var startedTurns: [String] {
            dispatches.startedTurns
        }
    }

    private func makeFixture() throws -> Fixture {
        let dispatches = MonitorCodexDispatchRecorder()
        let controller = MonitorFakeCodexController(dispatches: dispatches)
        var initialController: MonitorFakeCodexController? = controller
        var startOrResumeHook: (@Sendable () async -> Void)?
        let authRecovery = MonitorStubCodexAuthRecovery()
        let tabID = UUID()
        let viewModel = AgentModeViewModel(
            testWindowID: 1,
            testWorkspacePath: FileManager.default.temporaryDirectory.path,
            codexControllerFactory: { _, _, _, _, _, _ in
                // Controllers are single-use: shutdown permanently finishes their event stream.
                let next = initialController ?? MonitorFakeCodexController(dispatches: dispatches)
                initialController = nil
                next.setStartOrResumeHook(startOrResumeHook)
                return next
            },
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
        // Provider dispatch exercises an existing restored session, not first-save preparation.
        let sessionID = UUID()
        _ = try XCTUnwrap(viewModel.test_installPersistentSessionBinding(
            sessionID: sessionID, on: session, updateWorkspaceMetadata: true
        ))
        session.recordRestorationAuthoritative(.persistedPayloadApplied)
        _ = try XCTUnwrap(
            session.permitsBoundOperationAndSave ? session.currentRestorationBindingToken : nil,
            "The fixture must establish restoration before exercising provider dispatch."
        )
        let inventory = MonitorInventoryPublisher(
            viewModel: viewModel,
            observerSessionID: sessionID,
            tabID: tabID
        )
        inventories.append(inventory)
        startOrResumeHook = { [weak inventory] in
            await inventory?.republishCurrentCodexCatalog()
        }
        controller.setStartOrResumeHook(startOrResumeHook)
        return Fixture(
            viewModel: viewModel,
            coordinator: viewModel.test_codexCoordinator,
            controller: controller,
            dispatches: dispatches,
            session: session,
            sessionID: sessionID,
            tabID: tabID,
            inventory: inventory,
            authRecovery: authRecovery,
            workspaceManager: workspaceManager
        )
    }

    private func assertReplayUsedFreshController(
        _ fixture: Fixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let replacement = try XCTUnwrap(
            fixture.session.codexController as? MonitorFakeCodexController,
            file: file,
            line: line
        )
        XCTAssertFalse(replacement === fixture.controller, file: file, line: line)
        XCTAssertEqual(fixture.controller.startedTurns.count, 1, file: file, line: line)
        XCTAssertEqual(replacement.startedTurns.count, 1, file: file, line: line)
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
            admissionBasis: .routineStatusOrOverflow,
            attemptedFingerprint: nil,
            physicalOutcome: .notAttempted,
            phase: .preparingDispatch,
            task: nil
        )
        return wakeID
    }

    func testManualMissingRouteRestoresExactOptimisticSubmission() async throws {
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
            fixture.viewModel.test_agentSessionLinkAuthoritativeRunCatalogRouteToken = { _, _, _ in nil }

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

            try await AsyncTestWait.waitUntil("manual route refusal rollback") {
                await MainActor.run {
                    fixture.viewModel.draftRestorationEvent?.text == rawDraft
                }
            }
            XCTAssertEqual(fixture.session.items.filter { $0.kind == .user }.map(\.id), [existing.id])
            XCTAssertEqual(fixture.viewModel.retrieveDraftText(for: fixture.tabID), rawDraft)
            XCTAssertTrue(
                fixture.viewModel.draftRestorationEvent?.message.contains("route qualification was unavailable") == true,
                "unexpected restoration message: \(fixture.viewModel.draftRestorationEvent?.message ?? "nil")"
            )
            XCTAssertTrue(fixture.controller.steeredTurns.isEmpty)
            XCTAssertNil(fixture.session.codexPendingAuthRetryTurn)
            await manager.cleanupRunRoutingState(for: runID, windowID: endpoint.windowID)
        #else
            throw XCTSkip("Catalog observation diagnostics require DEBUG helpers.")
        #endif
    }

    func testManualRouteQualificationSupersessionRestoresExactOptimisticSubmission() async throws {
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
            // Rebind the process run while qualification is suspended. No catalog event is needed.
            fixture.session.installRunID(UUID())
            await authorityGate.open()

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
                fixture.viewModel.draftRestorationEvent?.message.contains("route qualification was superseded") == true,
                "unexpected restoration message: \(fixture.viewModel.draftRestorationEvent?.message ?? "nil")"
            )
            XCTAssertTrue(fixture.startedTurns.isEmpty)
            XCTAssertTrue(fixture.controller.steeredTurns.isEmpty)
            XCTAssertNil(fixture.session.codexPendingAuthRetryTurn)
            await manager.cleanupRunRoutingState(for: runID, windowID: endpoint.windowID)
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
            fixture.viewModel.test_agentSessionLinkAfterProviderInputRouteReadiness = {
                _ = await afterReadinessGate.requirement()
            }
            addTeardownBlock { @MainActor in
                await afterReadinessGate.open()
                fixture.viewModel.test_agentSessionLinkAfterProviderInputRouteReadiness = nil
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
                fixture.viewModel.draftRestorationEvent?.message.contains("MCP route changed") == true,
                "unexpected restoration message: \(fixture.viewModel.draftRestorationEvent?.message ?? "nil")"
            )
            XCTAssertTrue(fixture.startedTurns.isEmpty)
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
            XCTAssertTrue(fixture.startedTurns.isEmpty)
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

    func testCodexDedicatedContinuationNoteUsesDirectTurnAndExactProviderBytes() async throws {
        let fixture = try makeFixture()
        fixture.session.beginRunAttempt(source: "test.codex.prime")
        _ = await fixture.coordinator.sendCodexNativeMessage(
            session: fixture.session, text: "prime", attachments: []
        )
        fixture.session.runState = .idle
        fixture.session.beginRunAttempt(source: "test.codex.selfNote")
        let binding = try XCTUnwrap(fixture.session.persistentSessionBindingIdentity)
        let owner = try AgentSelfCompactOwner(
            windowID: 1, workspaceID: UUID(), tabID: fixture.tabID,
            sessionID: binding.sessionID, persistentBindingGeneration: binding.generation,
            bindingTransitionGeneration: fixture.session.bindingTransitionGeneration,
            runID: XCTUnwrap(fixture.session.runID),
            runAttemptID: XCTUnwrap(fixture.session.activeRunAttemptID)
        )
        let note = "resume βeta\nwithout edits"
        var state = AgentSelfCompactState()
        _ = state.reserve(note: note, idempotencyKey: "codex-native-note", maximumNoteUTF8Bytes: AgentSessionSelfCompactNotePolicy.fallbackMaximumUTF8Bytes, owner: owner)
        state.active?.phase = .dispatchingNote
        state.active?.compactProviderConversation = fixture.session.codexConversationID
        let dispatchID = try AgentSelfCompactionDispatchID(
            requestID: XCTUnwrap(state.active?.id), stage: .note
        )
        fixture.session.selfCompactState = state
        let declaration = try XCTUnwrap(
            DomainAgentSessionWaitingOn(summary: "CI artifact", declaredAt: Date(timeIntervalSince1970: 50))
        )
        let handoff = AgentModeViewModel.PendingHandoffState(
            payload: "keep staged handoff",
            createdAt: Date(timeIntervalSince1970: 7),
            sourceItemID: UUID()
        )
        let workflow = AgentWorkflowDefinition(
            customID: UUID(), displayName: "Keep workflow", template: "keep"
        )
        let attachment = AgentImageAttachment(
            source: .localFile(path: "/tmp/self-compact-keep.png"),
            title: "self-compact-keep.png"
        )
        fixture.session.oversight.waitingOn = declaration
        fixture.session.pendingHandoff = handoff
        fixture.session.lastUserMessageAt = Date(timeIntervalSince1970: 9)
        fixture.session.draftText = "unsent draft"
        fixture.session.selectedWorkflow = workflow
        fixture.session.pendingImageAttachments = [attachment]
        await fixture.inventory.publishCodex(revision: 1, targetCount: 1)

        let outcome = await fixture.coordinator.sendCodexNativeMessage(
            session: fixture.session,
            text: AgentSelfCompactNoteEnvelope.frame(note),
            attachments: [],
            selfCompactDispatchID: dispatchID
        )
        XCTAssertEqual(outcome, .sent)
        XCTAssertEqual(fixture.startedTurns.last, AgentSelfCompactNoteEnvelope.frame(note))
        XCTAssertTrue(fixture.controller.steeredTurns.isEmpty)
        XCTAssertEqual(fixture.session.selfCompactState.latest?.outcome, .noteAccepted)
        XCTAssertEqual(fixture.session.oversight.waitingOn, declaration)
        XCTAssertEqual(fixture.session.pendingHandoff, handoff)
        XCTAssertEqual(fixture.session.lastUserMessageAt, Date(timeIntervalSince1970: 9))
        XCTAssertEqual(fixture.session.draftText, "unsent draft")
        XCTAssertEqual(fixture.session.selectedWorkflow, workflow)
        XCTAssertEqual(fixture.session.pendingImageAttachments, [attachment])
        XCTAssertFalse(fixture.startedTurns.contains { $0.contains("keep staged handoff") })
    }

    func testLocalInputCodexLateReadRefusalKeepsBaselineAndStopOrCancellationPreventsHandoff() async throws {
        for mode in ["revoked", "stop", "cancel", "computerUse"] {
            let fixture = try makeFixture()
            await fixture.inventory.publishCodex(revision: 1, targetCount: 1)
            fixture.session.beginRunAttempt(source: "test.codex.localInput.\(mode)")
            let gate = TestReleaseFence(name: "Codex final optional Read \(mode)")
            var baseline: String?
            fixture.viewModel.test_agentSessionLinkLocalInputDecoration = { rendered in
                baseline = rendered.fragment
                return .init(fragment: rendered.fragment + "\n<user_input>must not escape</user_input>", markupDeltaBytes: 49, requirements: [])
            }
            fixture.viewModel.test_agentSessionLinkLocalInputReadProof = { _ in
                await gate.enterAndWait()
                return false
            }
            let send = Task { @MainActor in
                await fixture.coordinator.sendCodexNativeMessage(session: fixture.session, text: "existing task", attachments: [])
            }
            defer { gate.release()
                send.cancel()
            }
            let entered = await gate.waitUntilEntered()
            XCTAssertTrue(entered)
            XCTAssertTrue(fixture.startedTurns.isEmpty, "Read proof precedes physical input")
            if mode == "stop" { fixture.session.stopState.invalidateScheduledStarts() }
            if mode == "cancel" { send.cancel() }
            let featureState = fixture.session.codexControllerFeatureState
            if mode == "computerUse" {
                fixture.session.codexControllerFeatureState?.computerUseEnabled = true
                XCTAssertEqual(fixture.session.codexControllerFeatureState?.computerUseEnabled, true)
            }
            gate.release()
            _ = await send.value
            fixture.session.codexControllerFeatureState = featureState
            if mode == "revoked" {
                let text = try XCTUnwrap(fixture.startedTurns.first)
                XCTAssertEqual(fixture.startedTurns.count, 1)
                XCTAssertEqual(text, try AgentSessionLinkPromptComposer.decorated("existing task", fragment: XCTUnwrap(baseline)))
                XCTAssertFalse(text.contains("must not escape"))
            } else {
                XCTAssertTrue(fixture.startedTurns.isEmpty, "existing final Stop/task/Computer Use fence wins during proof")
            }
        }
    }

    func testLocalInputCodexReadCancellationKeepsParkedNoteAndDisclosureForLaterStartAndSteer() async throws {
        for steer in [false, true] {
            let fixture = try makeFixture()
            await fixture.inventory.publishCodex(revision: 1, targetCount: 1)
            fixture.session.beginRunAttempt(source: "test.localInput.parked.prime")
            _ = await fixture.coordinator.sendCodexNativeMessage(session: fixture.session, text: "prime", attachments: [])
            if steer {
                fixture.controller.markActiveTurn(id: "turn-1")
                await fixture.coordinator.test_handleCodexNativeEvent(.turnStarted(turnID: "turn-1"), session: fixture.session, sourceController: fixture.controller)
            } else {
                fixture.session.runState = .idle
                fixture.session.beginRunAttempt(source: "test.localInput.parked.start")
            }
            let input = try await AgentSessionLinkTransportLocalInputFixture.install(on: fixture.viewModel, session: fixture.session)
            addTeardownBlock { @MainActor in await input.cleanup() }
            await input.correction("PARKED-READ-CORRECTION")
            let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(fixture.viewModel, tabID: fixture.tabID)
            let owner = try AgentSelfCompactOwner(
                windowID: endpoint.windowID, workspaceID: endpoint.workspaceID, tabID: endpoint.tabID,
                sessionID: endpoint.sessionID, persistentBindingGeneration: XCTUnwrap(endpoint.persistentBindingGeneration),
                bindingTransitionGeneration: endpoint.bindingTransitionGeneration,
                runID: XCTUnwrap(fixture.session.runID), runAttemptID: UUID()
            )
            var state = AgentSelfCompactState()
            _ = state.reserve(note: "preserve parked continuation", idempotencyKey: "parked-read-cancellation", maximumNoteUTF8Bytes: AgentSessionSelfCompactNotePolicy.fallbackMaximumUTF8Bytes, owner: owner)
            state.active?.compactTurnSucceeded = true
            state.active?.phase = .parked
            fixture.session.selfCompactState = state
            let parked = try XCTUnwrap(state.parkedNote)
            let startsBefore = fixture.startedTurns.count
            let steersBefore = fixture.controller.steeredTurns.count
            let gate = TestReleaseFence(name: "parked Codex optional Read cancellation")
            fixture.viewModel.test_agentSessionLinkLocalInputReadProof = { decoration in
                await gate.enterAndWait()
                return await input.bridge.proveLocalInputRead(decoration, observer: input.observer)
            }
            let send = Task { @MainActor in
                await fixture.coordinator.sendCodexNativeMessage(session: fixture.session, text: "ordinary task", attachments: [])
            }
            defer { gate.release()
                send.cancel()
            }
            let entered = await gate.waitUntilEntered()
            XCTAssertTrue(entered)
            send.cancel()
            gate.release()
            _ = await send.value
            XCTAssertEqual(fixture.startedTurns.count, startsBefore)
            XCTAssertEqual(fixture.controller.steeredTurns.count, steersBefore)
            XCTAssertEqual(fixture.session.selfCompactState.parkedNote?.dispatchID, parked.dispatchID)
            XCTAssertEqual(fixture.session.selfCompactState.active?.noteDispatchStarted, false)
            XCTAssertNil(fixture.session.selfCompactState.latest)
            let inventory = try XCTUnwrap(input.host.publishedPromptInventories[input.observer.sessionID])
            let snapshot = try XCTUnwrap(input.host.publishedPassiveNoticesByEndpoint[input.observer])
            let baseline = AgentSessionLinkPrompts.rendered(.init(membershipKind: nil, inventory: inventory, passiveNotices: snapshot))
            XCTAssertNotNil(input.bridge.localInputDecoration(observer: input.observer, inventory: inventory, baseline: baseline))
            fixture.viewModel.test_agentSessionLinkLocalInputReadProof = nil
            if !steer {
                fixture.session.runState = .idle
                fixture.session.beginRunAttempt(source: "test.localInput.parked.retryStart")
            }
            let retried = await fixture.coordinator.sendCodexNativeMessage(session: fixture.session, text: "later valid task", attachments: [])
            XCTAssertEqual(retried, .sent)
            let text = try XCTUnwrap(steer ? fixture.controller.steeredTurns.last : fixture.startedTurns.last)
            XCTAssertTrue(text.hasPrefix(parked.frame + "\n\n"))
            XCTAssertEqual(text.components(separatedBy: parked.frame).count - 1, 1)
            XCTAssertTrue(text.contains("PARKED-READ-CORRECTION"))
            XCTAssertEqual(fixture.session.selfCompactState.latest?.outcome, .noteAccepted)
            XCTAssertEqual(fixture.session.selfCompactState.latest?.noteDelivery, .prepended)
            XCTAssertNil(fixture.session.selfCompactState.parkedNote)
            try input.assertConsumed()
        }
    }

    func testLocalInputRealAuthorityCodexStartAndSteerPhysicalTransports() async throws {
        let fixture = try makeFixture()
        await fixture.inventory.publishCodex(revision: 1, targetCount: 1)
        let input = try await AgentSessionLinkTransportLocalInputFixture.install(on: fixture.viewModel, session: fixture.session)
        addTeardownBlock { @MainActor in await input.cleanup() }
        await input.correction("CODEX-START-CORRECTION")
        fixture.session.beginRunAttempt(source: "test.localInput.codex.start")
        _ = await fixture.coordinator.sendCodexNativeMessage(session: fixture.session, text: "existing task", attachments: [])
        XCTAssertTrue(try XCTUnwrap(fixture.startedTurns.last).contains("CODEX-START-CORRECTION"))
        try input.assertConsumed()
        fixture.controller.markActiveTurn(id: "turn-1")
        await fixture.coordinator.test_handleCodexNativeEvent(.turnStarted(turnID: "turn-1"), session: fixture.session, sourceController: fixture.controller)
        await input.correction("CODEX-STEER-CORRECTION")
        _ = await fixture.coordinator.sendCodexNativeMessage(session: fixture.session, text: "existing steering", attachments: [])
        let steered = try XCTUnwrap(fixture.controller.steeredTurns.last)
        XCTAssertTrue(steered.contains("<user_input at="))
        XCTAssertTrue(steered.contains("CODEX-STEER-CORRECTION"))
        XCTAssertFalse(steered.contains("CODEX-START-CORRECTION"))
        try input.assertConsumed()
        MonitorSupplementAssertions.assertNotPersisted(in: fixture.session)
    }

    func testLocalInputCodexExpectedTurnRetryUsesBaselineWithoutHarvestingNewCorrection() async throws {
        let fixture = try makeFixture()
        await fixture.inventory.publishCodex(revision: 1, targetCount: 1)
        fixture.session.beginRunAttempt(source: "test.codex.mismatch.prime")
        _ = await fixture.coordinator.sendCodexNativeMessage(session: fixture.session, text: "prime", attachments: [])
        fixture.controller.markActiveTurn(id: "turn-1")
        await fixture.coordinator.test_handleCodexNativeEvent(.turnStarted(turnID: "turn-1"), session: fixture.session, sourceController: fixture.controller)
        let input = try await AgentSessionLinkTransportLocalInputFixture.install(on: fixture.viewModel, session: fixture.session)
        addTeardownBlock { @MainActor in await input.cleanup() }
        await input.correction("FIRST-HANDOFF-CORRECTION")
        var proofCalls = 0
        var baselineFragment: String?
        fixture.viewModel.test_agentSessionLinkLocalInputReadProof = { decoration in
            proofCalls += 1
            return await input.bridge.proveLocalInputRead(decoration, observer: input.observer)
        }
        fixture.viewModel.test_agentSessionLinkLocalInputDecoration = { rendered in
            baselineFragment = rendered.fragment
            let inventory = input.host.publishedPromptInventories[input.observer.sessionID]!
            return input.bridge.localInputDecoration(observer: input.observer, inventory: inventory, baseline: rendered)
        }
        var attempts: [String] = []
        fixture.controller.steerHandler = { @MainActor text, expectedTurnID in
            attempts.append(text)
            if attempts.count == 1 {
                await input.correction("NEW-DURING-RETRY-CORRECTION")
                throw CodexTurnSteerError.expectedTurnMismatch(
                    expectedTurnID: expectedTurnID, actualTurnID: "turn-2",
                    failure: .init(method: "turn/steer", code: nil, message: "expected turn mismatch", data: nil)
                )
            }
            return CodexTurnSteerReceipt(acceptedTurnID: expectedTurnID)
        }
        let outcome = await fixture.coordinator.sendCodexNativeMessage(session: fixture.session, text: "existing steering", attachments: [])
        XCTAssertEqual(outcome, .sent)
        XCTAssertEqual(attempts.count, 2)
        XCTAssertTrue(try XCTUnwrap(attempts.first).contains("FIRST-HANDOFF-CORRECTION"))
        let retry = try XCTUnwrap(attempts.last)
        XCTAssertEqual(Array(retry.utf8), try Array(AgentSessionLinkPromptComposer.decorated("existing steering", fragment: XCTUnwrap(baselineFragment)).utf8))
        XCTAssertFalse(retry.contains("<user_input"))
        XCTAssertFalse(retry.contains("NEW-DURING-RETRY-CORRECTION"))
        XCTAssertEqual(proofCalls, 1)
        fixture.controller.steerHandler = nil
        fixture.viewModel.test_agentSessionLinkLocalInputDecoration = nil
        fixture.session.runState = .idle
        fixture.session.beginRunAttempt(source: "test.codex.mismatch.fresh")
        _ = await fixture.coordinator.sendCodexNativeMessage(session: fixture.session, text: "independently permitted fresh turn", attachments: [])
        let fresh = try XCTUnwrap(fixture.startedTurns.last)
        XCTAssertTrue(fresh.contains("NEW-DURING-RETRY-CORRECTION"))
        XCTAssertFalse(fresh.contains("FIRST-HANDOFF-CORRECTION"))
        XCTAssertEqual(proofCalls, 2)
        try input.assertConsumed()
    }

    func testLocalInputRealAuthorityCodexFallbackHarvestsOnlyAtPhysicalDrain() async throws {
        let fixture = try makeFixture()
        await fixture.inventory.publishCodex(revision: 1, targetCount: 1)
        let input = try await AgentSessionLinkTransportLocalInputFixture.install(on: fixture.viewModel, session: fixture.session)
        addTeardownBlock { @MainActor in await input.cleanup() }
        fixture.session.beginRunAttempt(source: "test.localInput.codex.fallback")
        _ = await fixture.coordinator.sendCodexNativeMessage(session: fixture.session, text: "seed task", attachments: [])
        await fixture.coordinator.test_handleCodexNativeEvent(.turnStarted(turnID: "turn-1"), session: fixture.session, sourceController: fixture.controller)
        fixture.controller.threadRuntimeStatus = .active(activeFlags: ["turn"])
        fixture.controller.steerFailure = .noActiveTurn(.init(method: "turn/steer", code: nil, message: "no active turn", data: nil))
        let queued = await fixture.coordinator.sendCodexNativeMessage(session: fixture.session, text: "queued existing task", attachments: [])
        guard case .queuedFallback = queued else { return XCTFail("expected fallback queue") }
        await input.correction("CODEX-DRAIN-CORRECTION")
        fixture.controller.steerFailure = nil
        fixture.controller.threadRuntimeStatus = .idle
        try await AsyncTestWait.waitUntil("positive Read fallback transport", timeout: 5) {
            await MainActor.run { fixture.startedTurns.contains { $0.hasPrefix("queued existing task") } }
        }
        let drained = try XCTUnwrap(fixture.startedTurns.last { $0.hasPrefix("queued existing task") })
        XCTAssertTrue(drained.contains("<user_input at="))
        XCTAssertTrue(drained.contains("CODEX-DRAIN-CORRECTION"))
        try input.assertConsumed()
        MonitorSupplementAssertions.assertNotPersisted(in: fixture.session)
    }

    func testInitialStartCarriesExactlyOneSupplementThenGoesQuiet() async throws {
        let fixture = try makeFixture()
        await fixture.inventory.publishCodex(revision: 1, targetCount: 2)
        fixture.session.beginRunAttempt(source: "test.codex.start")

        _ = await fixture.coordinator.sendCodexNativeMessage(
            session: fixture.session,
            text: "first turn",
            attachments: []
        )

        let first = try XCTUnwrap(fixture.startedTurns.first)
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

        let second = try XCTUnwrap(fixture.startedTurns.last)
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

        let second = try XCTUnwrap(fixture.startedTurns.last)
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
        let closing = try XCTUnwrap(fixture.startedTurns.last)
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
            XCTUnwrap(fixture.startedTurns.last)
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
        let endpoint = try XCTUnwrap(fixture.viewModel.agentSessionLinkObserverEndpoint(tabID: fixture.tabID))
        let catalog = try XCTUnwrap(fixture.viewModel.agentSessionLinkRunCatalogProjectionByEndpoint[endpoint])
        fixture.viewModel.agentSessionLinkPublishRunCatalogProjection(
            .init(
                runID: catalog.runID,
                routeToken: catalog.routeToken,
                projectionRevision: catalog.projectionRevision + 1,
                hasAgentSessionLink: false,
                hasAnyActiveLink: true
            ),
            to: endpoint
        )
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
                fixture.startedTurns.contains { $0.hasPrefix("queued instruction") }
            }
        }

        let dispatched = try XCTUnwrap(
            fixture.startedTurns.last { $0.hasPrefix("queued instruction") }
        )
        MonitorSupplementAssertions.assertCarriesExactlyOneSupplement(
            dispatched,
            userContent: "queued instruction"
        )
        XCTAssertTrue(
            dispatched.contains("count=\"3\""),
            "a queued entry must render membership at drain time, not at enqueue time"
        )
        XCTAssertEqual(fixture.startedTurns.count(where: { $0.hasPrefix("queued instruction") }), 1)
        MonitorSupplementAssertions.assertNotPersisted(in: fixture.session)
    }

    func testQueuedFallbackMissingRouteRefusesWithoutStartingAnotherTurn() async throws {
        #if DEBUG
            let fixture = try makeFixture()
            await fixture.inventory.publishCodex(revision: 1, targetCount: 1)
            fixture.session.beginRunAttempt(source: "test.codex.fallback.route-refusal")
            _ = await fixture.coordinator.sendCodexNativeMessage(
                session: fixture.session, text: "seed turn", attachments: []
            )
            await fixture.coordinator.test_handleCodexNativeEvent(
                .turnStarted(turnID: "turn-1"), session: fixture.session, sourceController: fixture.controller
            )
            fixture.controller.threadRuntimeStatus = .active(activeFlags: ["turn"])
            fixture.controller.steerFailure = .noActiveTurn(
                CodexAppServerClient.RequestFailure(method: "turn/steer", code: nil, message: "no active turn", data: nil)
            )
            let outcome = await fixture.coordinator.sendCodexNativeMessage(
                session: fixture.session, text: "queued route refusal", attachments: []
            )
            guard case .queuedFallback = outcome else { return XCTFail("expected fallback, got \(outcome)") }
            fixture.controller.steerFailure = nil
            fixture.viewModel.test_agentSessionLinkAuthoritativeRunCatalogRouteToken = { _, _, _ in nil }
            fixture.controller.threadRuntimeStatus = .idle
            try await AsyncTestWait.waitUntil("the fallback route refusal to settle") {
                await MainActor.run {
                    fixture.session.codexFallbackQueue.isEmpty && fixture.session.codexFallbackDispatchInFlight == nil
                }
            }
            XCTAssertEqual(fixture.startedTurns.count, 1, "only the seed physically dispatched")
            XCTAssertFalse(fixture.startedTurns.contains { $0.hasPrefix("queued route refusal") })
        #else
            throw XCTSkip("Route authority seam requires DEBUG helpers.")
        #endif
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

        let original = try XCTUnwrap(fixture.startedTurns.last)
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

        XCTAssertEqual(fixture.startedTurns.count, 2)
        let replay = try XCTUnwrap(fixture.startedTurns.last)
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
        XCTAssertEqual(fixture.startedTurns.count, 1)

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
            fixture.startedTurns.count,
            1,
            "invalid AutoWake authority must not make a second provider call"
        )
    }

    func testAuthRecoveryAcceptedBaselineReplayLeavesNewCorrectionOwedForFreshTurn() async throws {
        let fixture = try makeFixture()
        await fixture.inventory.publishCodex(revision: 1, targetCount: 1)
        let input = try await AgentSessionLinkTransportLocalInputFixture.install(on: fixture.viewModel, session: fixture.session)
        addTeardownBlock { @MainActor in await input.cleanup() }
        var proofCalls = 0
        fixture.viewModel.test_agentSessionLinkLocalInputReadProof = { decoration in
            proofCalls += 1
            return await input.bridge.proveLocalInputRead(decoration, observer: input.observer)
        }
        fixture.session.beginRunAttempt(source: "test.auth.acceptedBaseline")
        _ = await fixture.coordinator.sendCodexNativeMessage(session: fixture.session, text: "BASELINE-ONLY", attachments: [])
        let original = try XCTUnwrap(fixture.startedTurns.last)
        XCTAssertFalse(original.contains("<user_input"))
        XCTAssertNil(fixture.session.codexPendingAuthRetryTurn?.monitoringClaim?.localInput)
        let acceptedProofCalls = proofCalls

        // This is new retained composer input AFTER acceptance, not the already-consumed offer.
        await input.correction("FRESH-OWED-CORRECTION")
        let inventory = try XCTUnwrap(input.host.publishedPromptInventories[input.observer.sessionID])
        let snapshot = try XCTUnwrap(input.host.publishedPassiveNoticesByEndpoint[input.observer])
        let baseline = AgentSessionLinkPrompts.rendered(.init(membershipKind: nil, inventory: inventory, passiveNotices: snapshot))
        let owed = try XCTUnwrap(input.bridge.localInputDecoration(observer: input.observer, inventory: inventory, baseline: baseline))
        let range = try XCTUnwrap(owed.requirements.first?.offer.range)
        XCTAssertEqual(range.capturedFrontier, 0)
        XCTAssertEqual(range.throughOrdinal, 1)

        await fixture.coordinator.test_handleCodexNativeEvent(
            .errorNotification(.init(message: "external auth is active", willRetry: false, threadID: nil, turnID: nil, itemID: nil)),
            session: fixture.session, sourceController: fixture.controller
        )
        XCTAssertEqual(fixture.startedTurns.count, 2)
        try assertReplayUsedFreshController(fixture)
        let replay = try XCTUnwrap(fixture.startedTurns.last)
        XCTAssertEqual(Array(replay.utf8), Array(original.utf8), "accepted replay must use the original baseline bytes")
        XCTAssertFalse(replay.contains("FRESH-OWED-CORRECTION"))
        XCTAssertEqual(proofCalls, acceptedProofCalls, "accepted replay must not perform another Read proof")
        XCTAssertEqual(fixture.viewModel.agentSessionLinkPromptClaimStore.test_pendingClaimCount(observerSessionID: fixture.sessionID), 0, "accepted replay must not mint a fresh claim")
        let stillOwed = input.bridge.localInputDecoration(observer: input.observer, inventory: inventory, baseline: baseline)
        XCTAssertEqual(stillOwed?.requirements.first?.offer.range, range, "accepted replay must not advance the disclosure frontier")
        let replayFrontier = stillOwed?.requirements.first?.offer.range.capturedFrontier
        print("OVERSIGHT_ACCEPTED_REPLAY baselineBytes=\(original.utf8.count) replayBytes=\(replay.utf8.count) readProofs=\(acceptedProofCalls)->\(proofCalls) frontier=\(range.capturedFrontier)->\(String(describing: replayFrontier)) through=\(range.throughOrdinal)")

        fixture.session.runState = .idle
        fixture.session.beginRunAttempt(source: "test.auth.independentFreshTurn")
        _ = await fixture.coordinator.sendCodexNativeMessage(session: fixture.session, text: "independently permitted fresh turn", attachments: [])
        let fresh = try XCTUnwrap(fixture.startedTurns.last)
        XCTAssertTrue(fresh.contains("FRESH-OWED-CORRECTION"))
        XCTAssertEqual(proofCalls, acceptedProofCalls + 1)
        try input.assertConsumed()
        fixture.session.runState = .idle
        fixture.session.beginRunAttempt(source: "test.auth.afterFreshTurn")
        _ = await fixture.coordinator.sendCodexNativeMessage(session: fixture.session, text: "later permitted turn", attachments: [])
        XCTAssertFalse(try XCTUnwrap(fixture.startedTurns.last).contains("FRESH-OWED-CORRECTION"))
        XCTAssertEqual(proofCalls, acceptedProofCalls + 1)
    }

    func testAuthRecoveryReplayDoesNotUpgradeFreshOwedLocalInput() async throws {
        let fixture = try makeFixture()
        await fixture.inventory.publishCodex(revision: 1, targetCount: 1)
        let input = try await AgentSessionLinkTransportLocalInputFixture.install(on: fixture.viewModel, session: fixture.session)
        addTeardownBlock { @MainActor in await input.cleanup() }
        var proofCalls = 0
        fixture.viewModel.test_agentSessionLinkLocalInputReadProof = { decoration in
            proofCalls += 1
            return await input.bridge.proveLocalInputRead(decoration, observer: input.observer)
        }
        await input.correction("ORIGINAL-ACCEPTED-CORRECTION")
        fixture.session.beginRunAttempt(source: "test.codex.auth.freshLocalInput")
        _ = await fixture.coordinator.sendCodexNativeMessage(session: fixture.session, text: "auth turn", attachments: [])
        let original = try XCTUnwrap(fixture.startedTurns.last)
        XCTAssertEqual(fixture.startedTurns.count, 1)
        XCTAssertTrue(original.contains("ORIGINAL-ACCEPTED-CORRECTION"))
        XCTAssertEqual(proofCalls, 1)
        let accepted = try XCTUnwrap(fixture.session.codexPendingAuthRetryTurn?.monitoringClaim)
        XCTAssertNil(accepted.localInput)
        let baseline = AgentSessionLinkPromptComposer.decorated("auth turn", with: accepted)
        try input.assertConsumed()
        await input.correction("FRESH-OWED-CORRECTION")
        await fixture.coordinator.test_handleCodexNativeEvent(
            .errorNotification(.init(
                message: "stream error: unexpected status 401 Unauthorized from api.openai.com/v1/responses",
                willRetry: false,
                threadID: nil,
                turnID: nil,
                itemID: nil
            )),
            session: fixture.session, sourceController: fixture.controller
        )
        let didRefresh = await fixture.authRecovery.didRefresh
        XCTAssertTrue(didRefresh)
        XCTAssertEqual(fixture.startedTurns.count, 2)
        try assertReplayUsedFreshController(fixture)
        let replay = try XCTUnwrap(fixture.startedTurns.last)
        XCTAssertEqual(replay, baseline, "accepted auth replay must retain its exact baseline only")
        XCTAssertEqual(Array(replay.utf8), Array(baseline.utf8))
        XCTAssertFalse(replay.contains("ORIGINAL-ACCEPTED-CORRECTION"))
        XCTAssertFalse(replay.contains("FRESH-OWED-CORRECTION"))
        XCTAssertEqual(proofCalls, 1, "accepted replay must not prove or upgrade a fresh optional offer")
        MonitorSupplementAssertions.assertNotPersisted(in: fixture.session)
        print("OVERSIGHT_VERA_REPLAY originalBytes=\(original.utf8.count) acceptedBaselineBytes=\(baseline.utf8.count) replayBytes=\(replay.utf8.count) readProofs=1->\(proofCalls)")
    }

    func testAuthRecoveryReplayPreservesTheAlreadyAcknowledgedSupplement() async throws {
        let fixture = try makeFixture()
        await fixture.inventory.publishCodex(revision: 1, targetCount: 1)
        fixture.session.beginRunAttempt(source: "test.codex.auth")
        var proofCalls = 0
        fixture.viewModel.test_agentSessionLinkLocalInputDecoration = { rendered in
            .init(fragment: rendered.fragment + "\n<user_input>withheld optional text</user_input>", markupDeltaBytes: 49, requirements: [])
        }
        fixture.viewModel.test_agentSessionLinkLocalInputReadProof = { _ in
            proofCalls += 1
            return false
        }
        _ = await fixture.coordinator.sendCodexNativeMessage(
            session: fixture.session,
            text: "auth turn",
            attachments: []
        )
        let original = try XCTUnwrap(fixture.startedTurns.last)
        MonitorSupplementAssertions.assertCarriesExactlyOneSupplement(original, userContent: "auth turn")
        XCTAssertEqual(proofCalls, 1)
        XCTAssertFalse(original.contains("withheld optional text"))
        XCTAssertNil(fixture.session.codexPendingAuthRetryTurn?.monitoringClaim?.localInput)

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
        XCTAssertEqual(fixture.startedTurns.count, 2, "the turn must have been replayed")
        try assertReplayUsedFreshController(fixture)
        let replay = try XCTUnwrap(fixture.startedTurns.last)
        XCTAssertEqual(replay, original, "the replay must be byte-identical to the accepted dispatch")
        XCTAssertEqual(proofCalls, 1, "accepted baseline replay never proves or upgrades optional data")
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
            XCTUnwrap(fixture.startedTurns.last),
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

        XCTAssertEqual(fixture.startedTurns.count, 2, "the turn must have been replayed")
        let replay = try XCTUnwrap(fixture.startedTurns.last)
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
        let later = try XCTUnwrap(fixture.startedTurns.last)
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
        let original = try XCTUnwrap(fixture.startedTurns.last)

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
        XCTAssertEqual(fixture.startedTurns.count, 2)
        try assertReplayUsedFreshController(fixture)
        XCTAssertEqual(try XCTUnwrap(fixture.startedTurns.last), original)
        try MonitorSupplementAssertions.assertCarriesExactlyOneSupplement(
            XCTUnwrap(fixture.startedTurns.last),
            userContent: "issue turn"
        )
    }

    func testAuthRecoveryReplayLeavesChangedMembershipOwedForFreshTurn() async throws {
        let fixture = try makeFixture()
        await fixture.inventory.publishCodex(revision: 1, targetCount: 1)
        fixture.session.beginRunAttempt(source: "test.codex.auth.churn")
        _ = await fixture.coordinator.sendCodexNativeMessage(
            session: fixture.session,
            text: "churn turn",
            attachments: []
        )
        XCTAssertTrue(try XCTUnwrap(fixture.startedTurns.last).contains("count=\"1\""))

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

        XCTAssertEqual(fixture.startedTurns.count, 2)
        try assertReplayUsedFreshController(fixture)
        let replay = try XCTUnwrap(fixture.startedTurns.last)
        XCTAssertEqual(replay, "churn turn", "changed authority must not resurrect the accepted fragment or mint a fresh claim")
        MonitorSupplementAssertions.assertCarriesNoSupplement(replay)
        XCTAssertEqual(fixture.viewModel.agentSessionLinkPromptClaimStore.test_pendingClaimCount(observerSessionID: fixture.sessionID), 0)
        XCTAssertEqual(fixture.viewModel.agentSessionLinkPromptClaimStore.test_lastAcceptedRevision(observerSessionID: fixture.sessionID), 1)

        // Recovery cannot acknowledge a new revision; a separately permitted fresh turn owns it.
        fixture.session.runState = .idle
        fixture.session.beginRunAttempt(source: "test.codex.auth.after")
        _ = await fixture.coordinator.sendCodexNativeMessage(
            session: fixture.session,
            text: "later turn",
            attachments: []
        )
        let fresh = try XCTUnwrap(fixture.startedTurns.last)
        MonitorSupplementAssertions.assertCarriesExactlyOneSupplement(fresh, userContent: "later turn")
        XCTAssertTrue(fresh.contains("count=\"3\""))
    }

    /// Regression: managed-auth replay classifies by reserved dispatch-ID *family*, never by a parsed
    /// wake.
    ///
    /// `lane.autowake:<UUID>:<epoch>` is the historical spelling: reserved family, no parseable wake.
    /// If this branch asked `autoWakeID != nil` instead of `isAutoWakeFamily`, that value would read
    /// as an ordinary dispatch and fall into the ordinary replay branch that may ship raw stored text.
    /// A settled wake is already spent; the only thing it
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
        let accepted = try XCTUnwrap(fixture.startedTurns.last)
        XCTAssertEqual(fixture.startedTurns.count, 1)
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
            fixture.startedTurns,
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
        let mcpServer: MCPServerViewModel?
    }

    private func makeFixture(
        agent: AgentProviderKind,
        claudeController: MonitorFakeNativeController? = nil,
        codexController: MonitorFakeCodexController? = nil,
        withMCPServer: Bool = false
    ) throws -> Fixture {
        let tabID = UUID()
        // A real run resolves its workspace before it reaches a provider, so the runner-level suites
        // need the same live workspace wiring the cross-session send suite uses.
        let workspaceFiles = WorkspaceFilesViewModel()
        let keyManager = KeyManager(
            secureService: SecureKeysService(secureStorage: TestSecureStorageBackend())
        )
        let aiQueriesService = AIQueriesService(keyManager: keyManager)
        let apiSettings = APISettingsViewModel(
            aiQueriesService: aiQueriesService,
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

        let mcpServer: MCPServerViewModel? = if withMCPServer {
            MCPServerViewModel(
                service: MCPService(
                    hostBootstrapOperation: {},
                    controllerStartOperation: {},
                    controllerFullShutdownOperation: {}
                ),
                promptVM: prompt,
                oracleVM: OracleViewModel(
                    aiQueriesService: aiQueriesService,
                    promptViewModel: prompt,
                    workspaceManager: manager,
                    chatData: ChatDataService()
                ),
                workspaceManager: manager,
                windowID: 1,
                workspaceSearch: { _, _, _, _, _, _, _, _, _, _, _, _, _, _ in
                    throw MCPError.internalError("search is not used by route removal tests")
                },
                ensureGitDataRootLoaded: { _, _ in
                    throw MCPError.internalError("Git-data loading is not used by route removal tests")
                }
            )
        } else {
            nil
        }

        let viewModel = AgentModeViewModel(
            testWindowID: 1,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in
                if let codexController { return codexController }
                return LifecycleNoopCodexController(recorder: LifecycleRecorder())
            },
            // A session may recycle a pre-seeded fake when its launch metadata is absent.
            // Never let that replacement fall through to the real provider factory.
            claudeControllerFactory: { _, _, _, _ in
                claudeController ?? MonitorFakeNativeController()
            },
            connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
            mcpServerEnabler: { true },
            testMCPServer: mcpServer
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
        // Provider dispatch exercises an existing restored session, not first-save preparation.
        let sessionID = UUID()
        _ = try XCTUnwrap(viewModel.test_installPersistentSessionBinding(
            sessionID: sessionID, on: session, updateWorkspaceMetadata: true
        ))
        session.recordRestorationAuthoritative(.persistedPayloadApplied)
        _ = try XCTUnwrap(
            session.permitsBoundOperationAndSave ? session.currentRestorationBindingToken : nil,
            "The fixture must establish restoration before exercising provider dispatch."
        )
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
            workspaceManager: manager,
            mcpServer: mcpServer
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

    func testLocalInputClaudeLateReadRefusalKeepsBaselineAndSupersessionOrCancellationPreventsHandoff() async throws {
        for mode in ["revoked", "superseded", "cancel"] {
            let controller = MonitorFakeNativeController()
            let fixture = try makeFixture(agent: .claudeCode, claudeController: controller)
            fixture.inventory.publish(revision: 1, targetCount: 1)
            let intent = try claudeRunIntent(for: fixture.session, source: "test.claude.localInput.\(mode)")
            let startup = await fixture.viewModel.test_claudeCoordinator.ensureClaudeNativeSession(session: fixture.session, intent: intent)
            XCTAssertEqual(startup, .ready)
            let gate = TestReleaseFence(name: "Claude final optional Read \(mode)")
            var baseline: String?
            fixture.viewModel.test_agentSessionLinkLocalInputDecoration = { rendered in
                baseline = rendered.fragment
                return .init(fragment: rendered.fragment + "\n<user_input>must not escape</user_input>", markupDeltaBytes: 49, requirements: [])
            }
            fixture.viewModel.test_agentSessionLinkLocalInputReadProof = { _ in
                await gate.enterAndWait()
                return false
            }
            let send = Task { @MainActor in
                await fixture.viewModel.test_claudeCoordinator.sendClaudeNativeMessage(
                    session: fixture.session, text: "existing task", attachments: [], intent: intent,
                    allowsCatalogRouteControllerRecovery: false
                )
            }
            defer { gate.release()
                send.cancel()
            }
            let entered = await gate.waitUntilEntered()
            XCTAssertTrue(entered)
            let before = await controller.sentMessages
            XCTAssertTrue(before.isEmpty)
            if mode == "superseded" { fixture.session.beginRunAttempt(source: "test.claude.successor") }
            if mode == "cancel" { send.cancel() }
            gate.release()
            _ = await send.value
            let sent = await controller.sentMessages
            if mode == "revoked" {
                let text = try XCTUnwrap(sent.first)
                XCTAssertEqual(sent.count, 1)
                XCTAssertTrue(try text.hasSuffix(XCTUnwrap(baseline)), "exact baseline survives failed optional Read")
                XCTAssertTrue(text.contains("existing task"))
                XCTAssertFalse(text.contains("must not escape"))
            } else {
                XCTAssertTrue(sent.isEmpty, "existing intent/task fence wins during proof")
            }
        }
    }

    func testLocalInputClaudeNativeAcceptanceAndRetainedSendFailureSettleProducerOnce() async throws {
        for fails in [false, true] {
            let controller = MonitorFakeNativeController()
            await controller.setFailSendAfterRecord(fails)
            await controller.setFinishEventsAfterSend(true)
            let fixture = try makeFixture(agent: .claudeCode, claudeController: controller)
            let session = fixture.session
            session.installLocalInputSeed(.init())
            let item = AgentChatItem.user("Retained native composer input", sequenceIndex: session.nextSequenceIndex)
            session.appendItem(item)
            let token = session.registerLocalComposerCandidate(itemID: item.id, at: session.items.count - 1)
            let harness = AgentSessionLinkRunnerHarness(
                headlessProviderFactory: { _, _ in AgentSessionLinkCapturingHeadlessProvider() }, sessionLinkHost: fixture.viewModel
            )
            let runner = ClaudeIntegratedAgentModeRunner(
                claudeCoordinator: fixture.viewModel.test_claudeCoordinator, hooks: harness.hooks,
                terminalCommitBarrier: AgentRunTerminalCommitBarrier()
            )
            await runner.startRun(
                tabID: fixture.tabID, session: session, initialUserMessage: item.text,
                initialMessageForRun: item.text, attachments: [],
                makeLease: { runID in harness.makeLease(runID: runID, tabID: fixture.tabID) },
                localComposerCandidate: token
            )
            await session.agentTask?.value
            let sent = await controller.sentMessages
            XCTAssertEqual(sent.count, 1)
            XCTAssertEqual(session.items.first(where: { $0.id == item.id })?.userInputOrigin, .localComposer)
            XCTAssertEqual(session.localInputIndex.producedThrough, 1)
            XCTAssertEqual(session.test_unsettledLocalComposerCandidateCount, 0)
            XCTAssertFalse(session.settleLocalComposerOrigin(token, disposition: .retained))
        }
    }

    func testLocalComposerCodexTargetRetentionCompactionReachesClaudeCodeObserverOnce() async throws {
        let controller = MonitorFakeNativeController()
        let observer = try makeFixture(agent: .claudeCode, claudeController: controller)
        observer.session.oversight.autoWakeOnUpdates = false
        observer.inventory.publish(revision: 1, targetCount: 1)
        let intent = try claudeRunIntent(for: observer.session, source: "test.retention.claude.observer")
        let startup = await observer.viewModel.test_claudeCoordinator.ensureClaudeNativeSession(session: observer.session, intent: intent)
        XCTAssertEqual(startup, .ready)

        let codex = MonitorFakeCodexController(dispatches: MonitorCodexDispatchRecorder())
        let target = try makeFixture(agent: .codexExec, codexController: codex)
        target.session.oversight.autoWakeOnUpdates = false
        // A real long transcript, not a large independent retained-input index. Hydration is over
        // before the grant baseline; validated composer refresh prunes the suffix during ingress.
        let history = (0 ..< 500).flatMap { turn in
            [
                AgentChatItem.user("Historical request \(turn)", sequenceIndex: turn * 2),
                AgentChatItem.assistant("Historical answer \(turn)", sequenceIndex: turn * 2 + 1)
            ]
        }
        XCTAssertGreaterThanOrEqual(history.count, 900)
        target.session.replaceItems(history)
        target.viewModel.refreshDerivedTranscriptState(for: target.session, publishActivePresentation: false)
        target.viewModel.refreshDerivedTranscriptState(for: target.session, publishActivePresentation: false)
        XCTAssertEqual(target.session.transcript.turns.count, 500)
        XCTAssertLessThan(target.session.items.count, history.count, "actual initial working-suffix pruning")
        let targetEndpoint = try XCTUnwrap(target.viewModel.agentSessionLinkObserverEndpoint(tabID: target.tabID))
        let observerEndpoint = try XCTUnwrap(observer.viewModel.agentSessionLinkObserverEndpoint(tabID: observer.tabID))
        let host = AgentSessionLinkRuntimeBridgeTests.FakeEndpointHost()
        func candidate(_ endpoint: DomainAgentSessionLinkEndpointIdentity, provider: String) -> AgentSessionLinkEndpointCandidate {
            let readiness: AgentSessionRestorationReadiness
            if let generation = endpoint.persistentBindingGeneration {
                let token = AgentSessionRestorationBindingToken(
                    bindingIdentity: AgentPersistentSessionBindingIdentity(
                        tabID: endpoint.tabID, sessionID: endpoint.sessionID, generation: generation
                    ),
                    bindingTransitionGeneration: endpoint.bindingTransitionGeneration
                )
                readiness = .authoritative(token, .persistedPayloadApplied)
            } else {
                readiness = .unbound
            }
            return .init(
                windowID: endpoint.windowID,
                workspaceID: endpoint.workspaceID,
                tabID: endpoint.tabID,
                sessionID: endpoint.sessionID,
                persistentBindingGeneration: endpoint.persistentBindingGeneration,
                bindingTransitionGeneration: endpoint.bindingTransitionGeneration,
                isTopLevel: true,
                hasLoadedPersistedState: true,
                bindingTransitionInProgress: false,
                isClosing: false,
                isMCPControlled: false,
                isMCPOriginated: false,
                roleAllowsOutboundMonitoring: true,
                displayName: provider,
                providerDisplayName: provider,
                locationLabel: nil,
                restorationReadiness: readiness
            )
        }
        host.candidates = [candidate(observerEndpoint, provider: "Claude Code"), candidate(targetEndpoint, provider: "Codex CLI")]
        host.promptViewModel = observer.viewModel
        host.localInputSnapshotOverride = { endpoint, includeRecords in
            guard endpoint == targetEndpoint else { return nil }
            return target.viewModel.agentSessionLinkLocalInputSnapshot(for: endpoint, includeRecords: includeRecords)
        }
        let bridge = AgentSessionLinkRuntimeBridge.shared
        bridge.attach(host: host)
        addTeardownBlock { @MainActor in
            let links = await AppDomainRuntimeComposition.shared.runtime.agentSessionLinkAuthority.links(forObserver: observerEndpoint.sessionID)
            for link in links.items {
                await bridge.revokeLink(linkID: link.linkID, generation: link.generation)
            }
            target.session.agentTask?.cancel()
            target.session.codexEventTask?.cancel()
            await codex.shutdown()
            WindowStatesManager.shared.attachAgentSessionLinkBridge()
            await bridge.test_settleProjections()
        }
        var tick: TimeInterval = 1000
        func status(_ value: DomainAgentSessionLinkStatus) async {
            tick += 1
            host.snapshotOverrides[target.sessionID] = .init(
                sessionID: target.sessionID, displayName: "Codex target", providerDisplayName: "Codex CLI",
                status: value, board: .empty, idleForSend: value == .idle, pendingInteractionKind: nil,
                latestVisibleAssistantPreview: "Completed.", visibleRowCount: Int(tick), lastActivityAt: Date(timeIntervalSince1970: tick)
            )
            host.fireObservation(for: target.sessionID)
            await bridge.test_settleProjections()
        }
        guard case .added = await bridge.addMonitorLink(observerSessionID: observer.sessionID, rawTargetSessionID: target.sessionID.uuidString)
        else { return XCTFail("exact Read grant must precede local input") }
        await status(.running)
        let initialSnapshot = try XCTUnwrap(target.viewModel.agentSessionLinkLocalInputSnapshot(for: targetEndpoint, includeRecords: true))
        XCTAssertEqual(initialSnapshot.producedThrough, 0)

        let workingBefore = Set(target.session.items.map(\.id))
        let marker = "LOCAL-COMPOSER-RETENTION-CORRECTION"
        let submitTarget = try XCTUnwrap(target.viewModel.makeComposerSubmitTarget(tabID: target.tabID, session: target.session))
        let attempt = AgentComposerSubmitAttempt(id: UUID(), target: submitTarget, inputRevision: 0, noticeRevision: 0, rawDraftSnapshot: marker)
        guard case let .claimed(claim) = target.viewModel.claimComposerSubmitAttempt(attempt, requireActiveTabOwnership: false)
        else { return XCTFail("validated local composer must own ingress") }
        let submitted = await target.viewModel.executeComposerSubmitAttempt(text: marker, claim: claim, createAndActivateSessionTab: { nil })
        XCTAssertEqual(submitted, .submitted)
        try await AsyncTestWait.waitUntil("authentic Codex producer retained origin", timeout: 5) {
            target.session.items.contains { $0.text == marker && $0.userInputOrigin == .localComposer }
        }
        XCTAssertEqual(codex.startedTurns.count, 1, "actual native Codex physical start")
        let row = try XCTUnwrap(target.session.items.first { $0.text == marker })
        XCTAssertEqual(row.userInputOrigin, .localComposer)
        let after = try XCTUnwrap(target.viewModel.agentSessionLinkLocalInputSnapshot(for: targetEndpoint, includeRecords: true))
        let record = try XCTUnwrap(after.records.first { $0.itemID == row.id })
        XCTAssertEqual(record.ordinal, 1)
        let workingAfter = Set(target.session.items.map(\.id))
        let pruned = workingBefore.subtracting(workingAfter)
        XCTAssertFalse(pruned.isEmpty, "validated composer refresh must actually prune old mutable rows")
        // Working-source pruning is not canonical deletion: the previous request survives, too.
        let requests = target.session.transcript.turns.compactMap(\.request)
        XCTAssertTrue(requests.contains { pruned.contains($0.id) })
        let retained = try XCTUnwrap(requests.first { $0.id == row.id })
        XCTAssertEqual(retained.userInputOrigin, .localComposer)
        XCTAssertEqual(retained.text, marker)
        XCTAssertEqual(after.epoch, initialSnapshot.epoch, "ordinary retention must preserve the grant's index incarnation")
        XCTAssertEqual(after.producedThrough, initialSnapshot.producedThrough + 1)
        await status(.idle)
        let inventory = try XCTUnwrap(host.publishedPromptInventories[observer.sessionID])
        let passive = try XCTUnwrap(host.publishedPassiveNoticesByEndpoint[observerEndpoint])
        let baseline = AgentSessionLinkPrompts.rendered(.init(membershipKind: nil, inventory: inventory, passiveNotices: passive))
        let offered = bridge.localInputDecoration(observer: observerEndpoint, inventory: inventory, baseline: baseline)
        // Do not unwrap here: the known-bad retention reset loses the offer, but the regression
        // must continue all the way through the actual Claude Code physical-send boundary.
        XCTAssertEqual(offered?.requirements.first?.offer.range.indexEpoch, initialSnapshot.epoch)
        XCTAssertEqual(offered?.requirements.first?.offer.range.capturedFrontier, 0)
        XCTAssertEqual(offered?.requirements.first?.offer.range.throughOrdinal, 1)
        XCTAssertEqual(offered?.requirements.first?.renderedRecords.first?.contentVersion, record.contentVersion)
        print("LOCAL_INPUT_RETENTION history_rows=\(history.count) pruned_rows=\(pruned.count) canonical_origin=\(retained.userInputOrigin?.rawValue ?? "nil") epoch_preserved=\(after.epoch == initialSnapshot.epoch) produced_before=\(initialSnapshot.producedThrough) produced_after=\(after.producedThrough) offered_after=\(offered?.requirements.count ?? 0)")

        var readCalls = 0
        observer.viewModel.test_agentSessionLinkLocalInputReadProof = { decoration in
            readCalls += 1
            return await bridge.proveLocalInputRead(decoration, observer: observerEndpoint)
        }
        _ = await observer.viewModel.test_claudeCoordinator.sendClaudeNativeMessage(
            session: observer.session, text: "existing observer task", attachments: [], intent: intent,
            allowsCatalogRouteControllerRecovery: false
        )
        let messages = await controller.sentMessages
        XCTAssertEqual(messages.count, 1)
        let sent = try XCTUnwrap(messages.first)
        XCTAssertTrue(sent.contains("<user_input at="))
        XCTAssertTrue(sent.contains(marker))
        XCTAssertFalse(sent.contains("user_inputs_omitted="))
        XCTAssertEqual(readCalls, 1, "real exact Read proof at physical Claude Code boundary")
        XCTAssertNil(bridge.localInputDecoration(observer: observerEndpoint, inventory: inventory, baseline: baseline), "frozen owed range consumed, not vacuous receipt removal")
        _ = await observer.viewModel.test_claudeCoordinator.sendClaudeNativeMessage(
            session: observer.session, text: "next independent observer task", attachments: [], intent: intent,
            allowsCatalogRouteControllerRecovery: false
        )
        let later = await controller.sentMessages
        XCTAssertEqual(later.count, 2)
        XCTAssertFalse(try XCTUnwrap(later.last).contains(marker))
        XCTAssertEqual(readCalls, 1)
        MonitorSupplementAssertions.assertNotPersisted(in: observer.session)
        print("LOCAL_INPUT_RETENTION_TRANSPORT sends=\(later.count) read_proofs=\(readCalls) first_contains_input=\(sent.contains(marker)) second_contains_input=\(later.last?.contains(marker) ?? false)")

        // Genuine history replacement remains a new incarnation: a typed retained copy is not
        // a new composer event and cannot be caught up through the still-live Read grant.
        target.session.replaceItems([retained.toItem()])
        target.viewModel.refreshDerivedTranscriptState(for: target.session, publishActivePresentation: false)
        XCTAssertNotEqual(target.session.localInputIndex.epoch, after.epoch)
        await status(.running)
        await status(.idle)
        let replacementPassive = try XCTUnwrap(host.publishedPassiveNoticesByEndpoint[observerEndpoint])
        let replacementBaseline = AgentSessionLinkPrompts.rendered(.init(membershipKind: nil, inventory: inventory, passiveNotices: replacementPassive))
        XCTAssertNil(bridge.localInputDecoration(observer: observerEndpoint, inventory: inventory, baseline: replacementBaseline))
        _ = await observer.viewModel.test_claudeCoordinator.sendClaudeNativeMessage(
            session: observer.session, text: "after genuine history replacement", attachments: [], intent: intent,
            allowsCatalogRouteControllerRecovery: false
        )
        let replacementMessages = await controller.sentMessages
        XCTAssertEqual(replacementMessages.count, 3)
        XCTAssertFalse(try XCTUnwrap(replacementMessages.last).contains(marker))
        XCTAssertEqual(readCalls, 1)
    }

    func testRetentionPreservesCanonicalOnlyRecordsAndExactPendingProducerTokens() throws {
        let fixture = try makeFixture(agent: .codexExec)
        let session = fixture.session
        session.installLocalInputSeed(.init())
        let history = (0 ..< 500).flatMap { turn in
            [
                AgentChatItem.user("Older request \(turn)", sequenceIndex: turn * 2),
                AgentChatItem.assistant("Older answer \(turn)", sequenceIndex: turn * 2 + 1)
            ]
        }
        let a = AgentChatItem.user("canonical retained A", sequenceIndex: 1000)
        let b = AgentChatItem.user("pending retained B", sequenceIndex: 1001)
        session.appendItem(a)
        let tokenA = session.registerLocalComposerCandidate(itemID: a.id, at: 0)
        XCTAssertTrue(session.settleLocalComposerOrigin(tokenA, disposition: .retained))
        session.appendItem(b)
        let tokenB = session.registerLocalComposerCandidate(itemID: b.id, at: 1)
        session.transcript = AgentTranscriptIO.rebuiltTranscriptPreservingCompactedPrefix(
            existingTranscript: .empty, workingItems: history + session.items, terminalState: .idle,
            nextSequenceIndex: session.nextSequenceIndex,
            policy: .liveSession(hidePendingQuestionToolCall: false), protection: .none
        )
        var seed = AgentSessionLinkRetainedLocalInputIndex.Seed(trackedIDs: [a.id])
        for request in session.transcript.turns.compactMap(\.request) {
            seed.append(request.toItem())
        }
        session.installLocalInputSeed(seed)
        let before = try XCTUnwrap(session.localInputIndex.snapshot)
        let original = try XCTUnwrap(before.records.first)
        session.setItemsSilentlyForRetentionCompaction([])
        XCTAssertTrue(session.items.isEmpty)
        XCTAssertTrue(Set(session.transcript.turns.compactMap(\.request).map(\.id)).isSuperset(of: [a.id, b.id]))
        let after = try XCTUnwrap(session.localInputIndex.snapshot)
        XCTAssertEqual(after.epoch, before.epoch)
        XCTAssertEqual(after.producedThrough, before.producedThrough)
        XCTAssertEqual(after.records.first?.ordinal, original.ordinal)
        XCTAssertEqual(after.records.first?.contentVersion, original.contentVersion)
        XCTAssertEqual(after.records.first?.content, original.content)
        XCTAssertNil(after.records.first?.sourcePosition)
        XCTAssertTrue(session.settleLocalComposerOrigin(tokenB, disposition: .retained))
        XCTAssertEqual(session.transcript.turns.first { $0.request?.id == b.id }?.request?.userInputOrigin, .localComposer)
        XCTAssertEqual(session.localInputIndex.producedThrough, 2)
        XCTAssertEqual(session.localInputIndex.records.map(\.itemID), [a.id, b.id])
        let settled = try XCTUnwrap(session.localInputIndex.snapshot)
        // Follow the production structural notification through an actual canonical refresh:
        // a genuinely compacted request must retain provenance and its original event identity.
        fixture.viewModel.refreshDerivedTranscriptState(for: session, publishActivePresentation: false)
        let compacted = try XCTUnwrap(session.transcript.turns.first { $0.request?.id == a.id })
        XCTAssertNotEqual(compacted.retentionTier, .full)
        XCTAssertEqual(compacted.request?.userInputOrigin, .localComposer)
        XCTAssertEqual(session.transcript.turns.first { $0.request?.id == b.id }?.request?.userInputOrigin, .localComposer)
        XCTAssertEqual(session.localInputIndex.epoch, settled.epoch)
        XCTAssertEqual(session.localInputIndex.producedThrough, settled.producedThrough)
        XCTAssertEqual(session.localInputIndex.records.map(\.ordinal), settled.records.map(\.ordinal))
        XCTAssertEqual(session.localInputIndex.records.map(\.contentVersion), settled.records.map(\.contentVersion))
        XCTAssertFalse(session.settleLocalComposerOrigin(tokenB, disposition: .retained))
        XCTAssertEqual(session.test_unsettledLocalComposerCandidateCount, 0)
    }

    func testCanonicalOnlyProducerRefusalsRetireTokenWithoutProducingInput() {
        for mode in ["pending", "missing", "rolledBack"] {
            let session = AgentTabSession(tabID: UUID())
            let item = AgentChatItem.user("exact pending producer", sequenceIndex: 0)
            session.appendItem(item)
            let token = session.registerLocalComposerCandidate(itemID: item.id, at: 0)
            session.transcript = AgentTranscriptIO.rebuiltTranscriptPreservingCompactedPrefix(
                existingTranscript: .empty, workingItems: session.items, terminalState: .idle,
                nextSequenceIndex: session.nextSequenceIndex,
                policy: .liveSession(hidePendingQuestionToolCall: false), protection: .none
            )
            session.installLocalInputSeed(.init())
            session.setItemsSilentlyForRetentionCompaction([])
            if mode == "pending" {
                session.transcript.turns[0].request?.text = "uncommitted canonical edit"
            } else if mode == "missing" {
                session.transcript.turns.removeAll()
                session.installLocalInputSeed(.init())
            }
            XCTAssertFalse(session.settleLocalComposerOrigin(token, disposition: mode == "rolledBack" ? .rolledBack : .retained), mode)
            XCTAssertEqual(session.localInputIndex.producedThrough, 0, mode)
            XCTAssertTrue(session.localInputIndex.records.isEmpty, mode)
            XCTAssertNil(session.transcript.turns.first?.request?.userInputOrigin, mode)
            session.installLocalInputSeed(.init())
            XCTAssertFalse(session.settleLocalComposerOrigin(token, disposition: .retained), "refusal retires token: \(mode)")
            XCTAssertEqual(session.test_unsettledLocalComposerCandidateCount, 0, mode)
        }
    }

    func testCanonicalDeleteAndEditInvalidateRetainedContentWhileHydrationRetiresTokens() throws {
        let session = AgentTabSession(tabID: UUID())
        let a = AgentChatItem.user("delete A", sequenceIndex: 0)
        let b = AgentChatItem.user("survive B", sequenceIndex: 1)
        for item in [a, b] {
            session.appendItem(item)
            let token = session.registerLocalComposerCandidate(itemID: item.id, at: session.items.count - 1)
            XCTAssertTrue(session.settleLocalComposerOrigin(token, disposition: .retained))
        }
        session.transcript = AgentTranscriptIO.rebuiltTranscriptPreservingCompactedPrefix(
            existingTranscript: .empty, workingItems: session.items, terminalState: .idle,
            nextSequenceIndex: session.nextSequenceIndex,
            policy: .liveSession(hidePendingQuestionToolCall: false), protection: .none
        )
        func installCanonicalSeed() {
            var seed = AgentSessionLinkRetainedLocalInputIndex.Seed(trackedIDs: Set(session.localInputIndex.records.map(\.itemID)))
            for request in session.transcript.turns.compactMap(\.request) {
                seed.append(request.toItem())
            }
            session.installLocalInputSeed(seed)
        }
        installCanonicalSeed()
        let before = try XCTUnwrap(session.localInputIndex.snapshot)
        let survivor = try XCTUnwrap(before.records.first { $0.itemID == b.id })
        session.setItemsSilentlyForRetentionCompaction([])
        session.transcript.turns.removeAll { $0.request?.id == a.id }
        installCanonicalSeed()
        XCTAssertEqual(session.localInputIndex.epoch, before.epoch)
        XCTAssertEqual(session.localInputIndex.producedThrough, 2)
        XCTAssertNil(session.localInputIndex.records.first { $0.itemID == a.id }?.content, "only actual canonical absence invalidates retained disclosure")
        XCTAssertEqual(session.localInputIndex.records.first { $0.itemID == b.id }?.contentVersion, survivor.contentVersion)
        session.transcript.turns[0].request?.text = "edited B"
        installCanonicalSeed()
        let edited = try XCTUnwrap(session.localInputIndex.records.first { $0.itemID == b.id })
        XCTAssertEqual(edited.ordinal, survivor.ordinal)
        XCTAssertNotEqual(edited.contentVersion, survivor.contentVersion, "frozen content proof cannot release an edited row")
        XCTAssertEqual(edited.content?.text, "edited B")
        let c = AgentChatItem.user("pending before hydration", sequenceIndex: 2)
        session.appendItem(c)
        let stale = session.registerLocalComposerCandidate(itemID: c.id, at: 0)
        session.setItemsSilently([c], reason: .persistedSessionHydration)
        XCTAssertNotEqual(session.localInputIndex.epoch, before.epoch)
        XCTAssertNil(session.localInputIndex.snapshot)
        XCTAssertFalse(session.settleLocalComposerOrigin(stale, disposition: .retained))
        XCTAssertNil(session.items[0].userInputOrigin)
    }

    func testClaudeNativeSendCarriesExactlyOneSupplementThenGoesQuiet() async throws {
        let controller = MonitorFakeNativeController()
        let fixture = try makeFixture(agent: .claudeCode, claudeController: controller)
        fixture.inventory.publish(revision: 1, targetCount: 2)
        let intent = try claudeRunIntent(
            for: fixture.session,
            source: "test.claude.native.supplement"
        )
        let startup = await fixture.viewModel.test_claudeCoordinator.ensureClaudeNativeSession(
            session: fixture.session,
            intent: intent
        )
        XCTAssertEqual(startup, .ready)

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

    func testClaudeNativeStaleCatalogSendsOnceWithoutRecyclingController() async throws {
        let controller = MonitorFakeNativeController()
        let fixture = try makeFixture(agent: .claudeCode, claudeController: controller)
        fixture.inventory.publish(revision: 0, targetCount: 0)
        fixture.session.installRunID(UUID())
        fixture.session.claudeController = controller
        let intent = try claudeRunIntent(for: fixture.session, source: "test.claude.stale-catalog")
        // Establish ordinary launch settings before measuring catalog-triggered recycling.
        let seed = await fixture.viewModel.test_claudeCoordinator.sendClaudeNativeMessage(
            session: fixture.session, text: "seed", attachments: [],
            intent: intent, allowsCatalogRouteControllerRecovery: false
        )
        XCTAssertEqual(seed, .sent)
        let initialShutdownCount = await controller.shutdownCount
        fixture.inventory.publish(revision: 1, targetCount: 1)
        let endpoint = try XCTUnwrap(fixture.viewModel.agentSessionLinkObserverEndpoint(tabID: fixture.tabID))
        let projection = try XCTUnwrap(fixture.viewModel.agentSessionLinkRunCatalogProjectionByEndpoint[endpoint])
        fixture.viewModel.agentSessionLinkPublishRunCatalogProjection(
            .init(
                runID: projection.runID,
                routeToken: projection.routeToken,
                projectionRevision: projection.projectionRevision + 1,
                hasAgentSessionLink: false,
                hasAnyActiveLink: true
            ),
            to: endpoint
        )
        let outcome = await fixture.viewModel.test_claudeCoordinator.sendClaudeNativeMessage(
            session: fixture.session, text: "oversight despite stale tools", attachments: [],
            intent: intent, allowsCatalogRouteControllerRecovery: true
        )
        XCTAssertEqual(outcome, .sent)
        let sent = await controller.sentMessages
        XCTAssertEqual(sent.count, 2)
        try MonitorSupplementAssertions.assertCarriesExactlyOneSupplement(
            XCTUnwrap(sent.last), userContent: "oversight despite stale tools"
        )
        let shutdownCount = await controller.shutdownCount
        XCTAssertEqual(shutdownCount, initialShutdownCount)
        XCTAssertTrue(fixture.session.claudeController === controller)
        let next = fixture.viewModel.agentSessionLinkDecoratedProviderText(
            "next turn", session: fixture.session,
            dispatchID: .claudeNativeSend(projection.runID)
        )
        MonitorSupplementAssertions.assertCarriesNoSupplement(next.text)
    }

    func testClaudeConnectionRemovalDuringConfigurationRefusesAndPreservesMessage() async throws {
        try await assertClaudeClosedConnectionDuringConfiguration(pauseTermination: false)
    }

    func testClaudeTerminalConnectionDuringConfigurationRefusesAndPreservesMessage() async throws {
        try await assertClaudeClosedConnectionDuringConfiguration(pauseTermination: true)
    }

    private func assertClaudeClosedConnectionDuringConfiguration(pauseTermination: Bool) async throws {
        #if DEBUG
            let controller = MonitorFakeNativeController()
            let fixture = try makeFixture(agent: .claudeCode, claudeController: controller, withMCPServer: true)
            let server = try XCTUnwrap(fixture.mcpServer)
            fixture.inventory.publish(revision: 0, targetCount: 0)
            fixture.session.installRunID(UUID())
            fixture.session.claudeController = controller
            let intent = try claudeRunIntent(for: fixture.session, source: "test.claude.removing-route")
            let seed = await fixture.viewModel.test_claudeCoordinator.sendClaudeNativeMessage(
                session: fixture.session, text: "seed", attachments: [],
                intent: intent, allowsCatalogRouteControllerRecovery: false
            )
            XCTAssertEqual(seed, .sent)
            fixture.inventory.publish(revision: 1, targetCount: 1)
            let runID = try XCTUnwrap(fixture.session.runID)
            let endpoint = try XCTUnwrap(fixture.viewModel.agentSessionLinkObserverEndpoint(tabID: fixture.tabID))
            let connectionID = UUID()
            let manager = ServerNetworkManager.shared
            let transportBaseline = await manager.debugTransportState()
            // Direct admission starts the shared manager even without a listener. Removing
            // only the connection leaves that owner active for later routed-runtime tests.
            // Register first so the gate/connection teardown below runs before restoration.
            addTeardownBlock {
                if !transportBaseline.isRunning { await manager.stop() }
                await manager.setEnabled(transportBaseline.isEnabled)
                let restored = await manager.debugTransportState()
                XCTAssertEqual(restored, transportBaseline, "Fixture must restore its shared transport ownership")
            }
            let removalGate = CatalogAuthorityGate()
            await manager.debugInstallDirectAdmissionConnectionForTesting(
                connectionID: connectionID,
                connection: MonitorRemovalConnection(gate: removalGate, pauseTermination: pauseTermination)
            )
            let state = await manager.debugDirectAdmissionStateForTesting(connectionID: connectionID)
            let token = try AgentSessionLinkRunCatalogRouteToken(
                runID: runID, observerEndpoint: endpoint, connectionID: connectionID,
                routingAuthorityGeneration: 1,
                connectionLifecycleGeneration: XCTUnwrap(state.connectionLifecycleGeneration)
            )
            try server.bindTabForConnection(
                connectionID: connectionID, clientName: nil, tabID: fixture.tabID,
                workspaceID: XCTUnwrap(fixture.workspaceManager.activeWorkspaceID),
                windowID: endpoint.windowID, runID: runID
            )
            fixture.viewModel.test_agentSessionLinkAuthoritativeRunCatalogRouteToken = { _, _, _ in token }
            // Exercise the production final fence, not a simulated route-current boolean.
            fixture.viewModel.test_agentSessionLinkCurrentRunCatalogRouteToken = { candidate, tabID in
                server.hasCurrentRunCatalogRouteToken(candidate, expectedTabID: tabID)
            }
            XCTAssertTrue(server.hasCurrentRunCatalogRouteToken(token, expectedTabID: fixture.tabID))
            let configurationGate = CatalogAuthorityGate()
            await controller.setConfigurationGate(configurationGate)
            addTeardownBlock { @MainActor in
                await configurationGate.open()
                await removalGate.open()
                await manager.debugRemoveConnection(connectionID)
            }
            let confirmed = AgentChatItem.user("confirmed", sequenceIndex: fixture.session.nextSequenceIndex)
            fixture.session.appendItem(confirmed)
            let rawDraft = "preserve removing-route input"
            fixture.viewModel.storeDraftText(for: fixture.tabID, rawDraft)
            XCTAssertEqual(
                fixture.viewModel.submitUserTurn(
                    text: rawDraft.trimmingCharacters(in: .whitespacesAndNewlines),
                    tabID: fixture.tabID, rawDraftText: rawDraft
                ),
                .submitted
            )
            fixture.viewModel.storeDraftText(for: fixture.tabID, "")
            await configurationGate.waitUntilEntered()
            let removal = Task {
                if pauseTermination {
                    await manager.terminateConnection(connectionID, reason: .runCompleted)
                } else {
                    await manager.removeConnection(connectionID)
                }
            }
            // Hold either terminal commitment BEFORE removal, or removal BEFORE mapping cleanup.
            await removalGate.waitUntilEntered()
            let removalHasBegun = await manager.debugHasConnectionRemovalOperation(for: connectionID)
            XCTAssertEqual(removalHasBegun, !pauseTermination)
            XCTAssertTrue(server.hasCurrentRunRouteMapping(
                runID: runID, connectionID: connectionID, expectedTabID: fixture.tabID
            ), "retained mappings must reproduce the unsafe cleanup interval")
            XCTAssertFalse(server.hasCurrentRunCatalogRouteToken(token, expectedTabID: fixture.tabID))
            await configurationGate.open()
            try await AsyncTestWait.waitUntil("removing-route refusal or physical send") {
                let refused = await MainActor.run {
                    fixture.session.items.contains {
                        $0.kind == .error && $0.text.contains("[route:configuration-fence]")
                    }
                }
                if refused { return true }
                return await controller.sentCount > 1
            }
            let sent = await controller.sentMessages
            XCTAssertEqual(sent, ["seed"], "removal must cause definite no-call, not an uncertain write")
            XCTAssertEqual(
                fixture.session.items.filter { $0.kind == .user }.map(\.text),
                [confirmed.text, rawDraft],
                "native refusal preserves the unsent message in the transcript for retry"
            )
            XCTAssertTrue(fixture.session.items.contains {
                $0.kind == .error && $0.text.contains("No provider message was sent")
            })
            XCTAssertNil(fixture.viewModel.agentSessionLinkPromptClaimStore.test_lastAcceptedRevision(
                observerSessionID: fixture.sessionID
            ))
            await removalGate.open()
            await removal.value
        #else
            throw XCTSkip("Connection lifecycle diagnostics require DEBUG helpers.")
        #endif
    }

    func testClaudeFirstLinkDuringConfigurationRequiresCurrentRoute() async throws {
        let controller = MonitorFakeNativeController()
        let fixture = try makeFixture(agent: .claudeCode, claudeController: controller)
        fixture.inventory.publish(revision: 0, targetCount: 0)
        fixture.session.installRunID(UUID())
        fixture.session.claudeController = controller
        let intent = try claudeRunIntent(for: fixture.session, source: "test.claude.late-link")
        let gate = CatalogAuthorityGate()
        await controller.setConfigurationGate(gate)
        addTeardownBlock { await gate.open() }
        let send = Task { @MainActor in
            await fixture.viewModel.test_claudeCoordinator.sendClaudeNativeMessage(
                session: fixture.session, text: "late first link", attachments: [],
                intent: intent, allowsCatalogRouteControllerRecovery: false
            )
        }
        await gate.waitUntilEntered()
        fixture.inventory.publish(revision: 1, targetCount: 1)
        fixture.viewModel.test_agentSessionLinkAuthoritativeRunCatalogRouteToken = { _, _, _ in nil }
        await gate.open()
        let outcome = await send.value
        guard case .failed = outcome else { return XCTFail("Expected a real route refusal") }
        let sent = await controller.sentMessages
        XCTAssertTrue(sent.isEmpty, "a stale link-less qualification cannot send a new supplement")
    }

    func testClaudeFirstLinkDuringConfigurationRequalifiesWithoutCatalogRefresh() async throws {
        let controller = MonitorFakeNativeController()
        let fixture = try makeFixture(agent: .claudeCode, claudeController: controller)
        fixture.inventory.publish(revision: 0, targetCount: 0)
        fixture.session.installRunID(UUID())
        fixture.session.claudeController = controller
        let intent = try claudeRunIntent(for: fixture.session, source: "test.claude.late-link.valid")
        let gate = CatalogAuthorityGate()
        await controller.setConfigurationGate(gate)
        addTeardownBlock { await gate.open() }
        let send = Task { @MainActor in
            await fixture.viewModel.test_claudeCoordinator.sendClaudeNativeMessage(
                session: fixture.session, text: "late linked turn", attachments: [],
                intent: intent, allowsCatalogRouteControllerRecovery: false
            )
        }
        await gate.waitUntilEntered()
        fixture.inventory.publish(revision: 1, targetCount: 1)
        let endpoint = try XCTUnwrap(fixture.viewModel.agentSessionLinkObserverEndpoint(tabID: fixture.tabID))
        let projection = try XCTUnwrap(fixture.viewModel.agentSessionLinkRunCatalogProjectionByEndpoint[endpoint])
        fixture.viewModel.agentSessionLinkPublishRunCatalogProjection(
            .init(
                runID: projection.runID,
                routeToken: projection.routeToken,
                projectionRevision: projection.projectionRevision + 1,
                hasAgentSessionLink: false,
                hasAnyActiveLink: true
            ), to: endpoint
        )
        await gate.open()
        let outcome = await send.value
        XCTAssertEqual(outcome, .sent)
        let sent = await controller.sentMessages
        XCTAssertEqual(sent.count, 1)
        try MonitorSupplementAssertions.assertCarriesExactlyOneSupplement(
            XCTUnwrap(sent.first), userContent: "late linked turn"
        )
    }

    func testClaudeNativeRevocationDeliversOneClosingNotice() async throws {
        let controller = MonitorFakeNativeController()
        let fixture = try makeFixture(agent: .claudeCode, claudeController: controller)
        fixture.inventory.publish(revision: 1, targetCount: 1)
        let intent = try claudeRunIntent(
            for: fixture.session,
            source: "test.claude.native.revocation"
        )
        let startup = await fixture.viewModel.test_claudeCoordinator.ensureClaudeNativeSession(
            session: fixture.session,
            intent: intent
        )
        XCTAssertEqual(startup, .ready)
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

    func testClaudeNativeLosingPreseededFakeRefusesRealProviderReplacement() async throws {
        let fake = MonitorFakeNativeController()
        // Intentionally use the production factory to reproduce a fixture that loses its fake.
        let coordinator = ClaudeAgentModeCoordinator(windowID: 1, workspacePathProvider: { _ in nil })
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        session.selectedAgent = .claudeCode
        session.hasLoadedPersistedState = true
        session.testInstallPersistentSessionBinding(sessionID: UUID())
        session.recordRestorationAuthoritative(.persistedPayloadApplied)
        _ = try XCTUnwrap(
            session.permitsBoundOperationAndSave ? session.currentRestorationBindingToken : nil,
            "The fixture must establish restoration before exercising provider dispatch."
        )
        session.installRunID(UUID())
        session.claudeController = fake
        let intent = try claudeRunIntent(for: session, source: "test.claude.lost-fake-refusal")

        let outcome = await coordinator.ensureClaudeNativeSession(session: session, intent: intent)

        guard case let .failed(message) = outcome else {
            return XCTFail("Losing a fake must refuse real provider launch, got \(outcome)")
        }
        XCTAssertTrue(message.contains("Provider process launch refused under XCTest"), message)
        let shutdowns = await fake.shutdownCount
        let sends = await fake.sentCount
        XCTAssertEqual(shutdowns, 1, "Missing launch metadata must reproduce fake retirement")
        XCTAssertEqual(sends, 0)
        XCTAssertFalse(session.claudeController === fake)
        await session.claudeController?.shutdown()
    }

    func testClaudeNativeMissingRouteRecoversBeforeDispatch() async throws {
        try await assertClaudeNativeLostRouteRecovery(
            readiness: [false, true],
            finalRoutePresence: [true]
        )
    }

    func testClaudeNativeFinalRouteFenceLossRecoversBeforeDispatch() async throws {
        try await assertClaudeNativeLostRouteRecovery(
            readiness: [true, true],
            finalRoutePresence: [false, true]
        )
    }

    func testClaudeNativeActiveSteeringFailsClosedWithoutRecyclingOwnedEventStream() async throws {
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
        session.recordRestorationAuthoritative(.persistedPayloadApplied)
        _ = try XCTUnwrap(
            session.permitsBoundOperationAndSave ? session.currentRestorationBindingToken : nil,
            "The fixture must establish restoration before exercising provider dispatch."
        )
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
                qualifyAgentSessionLinkProviderInputRoute: { _ in .unavailable },
                hasCurrentAgentSessionLinkProviderInputRoute: { _, _ in false },
                decorateAgentSessionLinkPrompt: { text, _, _ in
                    .init(text: text, claim: nil, mustAbortDispatch: false)
                },
                acquireAgentSessionLinkPhysicalDispatch: { _, _ in true },
                recordAgentSessionLinkPhysicalDispatchNotAttempted: { _, _ in
                    physicalDispatchNotAttemptedCount += 1
                },
                recordAgentSessionLinkPhysicalDispatchFailure: { _, _ in },
                acceptAgentSessionLinkPromptClaim: { _, _, _ in }
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

    private func assertClaudeNativeLostRouteRecovery(
        readiness: [Bool],
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
        session.recordRestorationAuthoritative(.persistedPayloadApplied)
        _ = try XCTUnwrap(
            session.permitsBoundOperationAndSave ? session.currentRestorationBindingToken : nil,
            "The fixture must establish restoration before exercising provider dispatch."
        )
        let runID = UUID()
        session.installRunID(runID)
        session.runState = .running
        let ownership = session.beginRunAttempt(source: "test.claude.catalog-route-recovery")

        let endpoint = try DomainAgentSessionLinkEndpointIdentity(
            windowID: 1, workspaceID: UUID(), tabID: session.tabID,
            sessionID: XCTUnwrap(session.activeAgentSessionID),
            persistentBindingGeneration: UUID(), bindingTransitionGeneration: 0
        )
        let routeToken = AgentSessionLinkRunCatalogRouteToken(
            runID: runID, observerEndpoint: endpoint, connectionID: UUID(),
            routingAuthorityGeneration: 1, connectionLifecycleGeneration: 1
        )
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
                qualifyAgentSessionLinkProviderInputRoute: { _ in
                    pendingReadiness.removeFirst() ? .ready(routeToken) : .unavailable
                },
                hasCurrentAgentSessionLinkProviderInputRoute: { _, _ in
                    // Route state persists through the additional post-configuration proof fence.
                    pendingFinalRoutePresence.isEmpty ? finalRoutePresence.last == true : pendingFinalRoutePresence.removeFirst()
                },
                decorateAgentSessionLinkPrompt: { text, _, _ in
                    .init(text: text, claim: nil, mustAbortDispatch: false)
                },
                acquireAgentSessionLinkPhysicalDispatch: { _, _ in true },
                recordAgentSessionLinkPhysicalDispatchNotAttempted: { _, _ in
                    physicalDispatchNotAttemptedCount += 1
                },
                recordAgentSessionLinkPhysicalDispatchFailure: { _, _ in },
                acceptAgentSessionLinkPromptClaim: { _, _, _ in }
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
        let firstResumeID = try XCTUnwrap(firstResumeIDs.first)
        XCTAssertNil(firstResumeID)
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
                    hasAgentSessionLink: true,
                    hasAnyActiveLink: true
                ),
                to: endpoint
            )

            let readiness = await fixture.viewModel.qualifyProviderInputRoute(for: fixture.session)
            XCTAssertEqual(readiness, .ready(routeToken))
            XCTAssertTrue(
                fixture.viewModel.agentSessionLinkHasCurrentProviderInputRoute(for: fixture.session, qualification: readiness)
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

            let readiness = await fixture.viewModel.qualifyProviderInputRoute(for: fixture.session)
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
                    hasAgentSessionLink: true,
                    hasAnyActiveLink: true
                ),
                to: endpoint
            )

            let readiness = await fixture.viewModel.qualifyProviderInputRoute(for: fixture.session)
            XCTAssertEqual(readiness, .ready(routeToken))
            XCTAssertFalse(
                fixture.viewModel.agentSessionLinkHasCurrentProviderInputRoute(for: fixture.session, qualification: readiness)
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
                await fixture.viewModel.qualifyProviderInputRoute(for: fixture.session)
            }
            let readyProjection = AgentSessionLinkRunCatalogProjection(
                runID: runID,
                routeToken: routeToken,
                projectionRevision: unready.projectionRevision + 1,
                hasAgentSessionLink: true,
                hasAnyActiveLink: true
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

    func testCodexContinuationMissingRouteRestoresInstructionWithoutResumingProvider() async throws {
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
            fixture.viewModel.test_agentSessionLinkAuthoritativeRunCatalogRouteToken = { _, _, _ in nil }

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
                "continuation route refusal rollback",
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
                fixture.viewModel.draftRestorationEvent?.message.contains("route qualification was unavailable") == true
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
            // Both submissions raced under an unknown catalog; do not heal it to resume.
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

    func testCodexResumedContinuationProceedsWithoutCatalogRefresh() async throws {
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
                "active-link input remains suspended until exact route qualification finishes"
            )
            XCTAssertEqual(fixture.session.instructionWaitID, expectedWaitID)
            XCTAssertEqual(fixture.session.codexController.map(ObjectIdentifier.init), expectedControllerID)
            await authorityGate.open()

            // Never publish a ready catalog: the route, not tools/list, admits this continuation.
            let readiness = await fixture.viewModel.qualifyProviderInputRoute(for: fixture.session)
            XCTAssertEqual(readiness, .ready(routeToken))
            try? await AsyncTestWait.waitUntil(
                "exact route qualification to resume the continuation"
            ) {
                await MainActor.run { fixture.session.instructionContinuation == nil }
            }
            guard fixture.session.instructionContinuation == nil else {
                cancelWaitingInstructionForTest(fixture.session)
                _ = try? await waiting.value
                return XCTFail("exact route qualification did not resume the waiting continuation")
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

    func testLocalInputDequeuedInstructionDuringReadProofRecoversQueueOrStoppedDraftExactlyOnce() async throws {
        for stopped in [false, true] {
            let fixture = try makeFixture(agent: .claudeCode)
            let input = try await AgentSessionLinkTransportLocalInputFixture.install(on: fixture.viewModel, session: fixture.session)
            addTeardownBlock { @MainActor in await input.cleanup() }
            await input.correction("QUEUE-RECOVERY-CORRECTION")
            let queued = AgentTabSession.PendingInstruction(providerText: "provider queued input", localDraftText: "distinct local draft")
            fixture.session.pendingInstructions = [queued]
            let gate = TestReleaseFence(name: "dequeued instruction optional Read cancellation")
            fixture.viewModel.test_agentSessionLinkLocalInputReadProof = { decoration in
                await gate.enterAndWait()
                return await input.bridge.proveLocalInputRead(decoration, observer: input.observer)
            }
            let waiting = Task { @MainActor in try await fixture.viewModel.waitForNextUserInstruction(tabID: fixture.tabID) }
            defer { gate.release()
                waiting.cancel()
            }
            let entered = await gate.waitUntilEntered()
            XCTAssertTrue(entered)
            XCTAssertTrue(fixture.session.pendingInstructions.isEmpty)
            if stopped { fixture.session.stopState.invalidateScheduledStarts() }
            waiting.cancel()
            gate.release()
            do {
                _ = try await waiting.value
                XCTFail("cancelled queued input must never return to the provider")
            } catch is CancellationError {} catch { XCTFail("unexpected error: \(error)") }
            if stopped {
                XCTAssertTrue(fixture.session.pendingInstructions.isEmpty)
                XCTAssertEqual(fixture.viewModel.retrieveDraftText(for: fixture.tabID), "distinct local draft")
            } else {
                XCTAssertEqual(fixture.session.pendingInstructions, [queued])
                XCTAssertEqual(fixture.viewModel.retrieveDraftText(for: fixture.tabID), "")
            }
            let snapshot = try XCTUnwrap(input.host.publishedPassiveNoticesByEndpoint[input.observer])
            let inventory = try XCTUnwrap(input.host.publishedPromptInventories[input.observer.sessionID])
            let baseline = AgentSessionLinkPrompts.rendered(.init(membershipKind: nil, inventory: inventory, passiveNotices: snapshot))
            XCTAssertNotNil(input.bridge.localInputDecoration(observer: input.observer, inventory: inventory, baseline: baseline))
            if !stopped {
                fixture.viewModel.test_agentSessionLinkLocalInputReadProof = nil
                let response = try await fixture.viewModel.waitForNextUserInstruction(tabID: fixture.tabID)
                let acceptedText = try XCTUnwrap(response.text)
                XCTAssertTrue(acceptedText.contains("provider queued input"))
                XCTAssertTrue(acceptedText.contains("QUEUE-RECOVERY-CORRECTION"))
                try input.assertConsumed()
                XCTAssertTrue(fixture.session.pendingInstructions.isEmpty)
            }
        }
    }

    func testLocalInputRealAuthorityWaitingContinuationPhysicalResume() async throws {
        let fixture = try makeFixture(agent: .claudeCode)
        fixture.inventory.publish(revision: 1, targetCount: 1)
        let input = try await AgentSessionLinkTransportLocalInputFixture.install(on: fixture.viewModel, session: fixture.session)
        addTeardownBlock { @MainActor in await input.cleanup() }
        await input.correction("WAITING-AUTHORITY-CORRECTION")
        let waiting = Task { @MainActor in try await fixture.viewModel.waitForNextUserInstruction(tabID: fixture.tabID) }
        try await AsyncTestWait.waitUntil("positive Read waiting continuation") {
            await MainActor.run { fixture.session.instructionContinuation != nil }
        }
        _ = fixture.viewModel.submitUserTurn(text: "existing resumed instruction")
        let response = try await waiting.value
        let text = try XCTUnwrap(response.text)
        XCTAssertTrue(text.contains("<user_input at="))
        XCTAssertTrue(text.contains("WAITING-AUTHORITY-CORRECTION"))
        try input.assertConsumed()
        MonitorSupplementAssertions.assertNotPersisted(in: fixture.session)
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

private actor MonitorRemovalConnection: MCPServerConnection {
    let gate: CatalogAuthorityGate
    let pauseTermination: Bool

    init(gate: CatalogAuthorityGate, pauseTermination: Bool) {
        self.gate = gate
        self.pauseTermination = pauseTermination
    }

    nonisolated var isFilesystemBacked: Bool {
        false
    }

    nonisolated var connectionFolderURL: URL? {
        nil
    }

    nonisolated var capabilityToken: String? {
        nil
    }

    func start(approvalHandler _: @escaping (MCP.Client.Info) async -> Bool) async throws {}
    func stop() async {}
    func abortForExecutionWatchdog(context _: MCPExecutionWatchdogTerminalContext) async {}
    func notifyToolListChanged() async {}
    func connectionState() -> ConnectionStateSnapshot {
        .ready
    }

    func isViableForRetention() -> Bool {
        true
    }

    func secondsSinceLastActivity() async -> TimeInterval {
        0
    }

    func transportIngressSnapshot() async -> MCPTransportIngressSnapshot? {
        nil
    }

    func responseDeliverySnapshot() async -> MCPResponseDeliverySnapshot? {
        if !pauseTermination { _ = await gate.requirement() }
        return nil
    }

    func terminate(reason _: TerminationReason, message _: String?) async {
        if pauseTermination { _ = await gate.requirement() }
    }

    func sendProgress(tool _: String, kind _: RepoPromptProgressKind, stage _: String, message _: String) async {}
}

actor MonitorFakeNativeController: NativeAgentRuntimeControlling {
    private var configuration = SessionLinkNativeConfigurationFixture()
    private(set) var sentMessages: [String] = []
    private var lastSentTurnID: UUID?

    func completeLastTurn(text: String? = nil, status: NativeAgentRuntimeTurnStatus = .completed) {
        guard let lastSentTurnID else { return }
        _ = events // Buffer an immediate reply even if the real runner has not subscribed yet.
        if let text { continuation?.yield(.stream(.init(type: "content", text: text))) }
        continuation?.yield(.turnCompleted(turnID: lastSentTurnID, status: status))
        self.lastSentTurnID = nil
    }

    private(set) var shutdownCount = 0
    private(set) var startOrResumeExistingSessionIDs: [String?] = []
    private var rejectResume = false
    private var turnInFlight = false
    private var failSendAfterRecord = false
    private var finishEventsAfterSend = false

    func setFinishEventsAfterSend(_ value: Bool) {
        finishEventsAfterSend = value
    }

    func setTurnInFlight(_ value: Bool) {
        turnInFlight = value
    }

    func setRejectResume(_ value: Bool) {
        rejectResume = value
    }

    func setFailSendAfterRecord(_ value: Bool) {
        failSendAfterRecord = value
    }

    private var stream: AsyncStream<NativeAgentRuntimeEvent>?
    private var continuation: AsyncStream<NativeAgentRuntimeEvent>.Continuation?

    var sentCount: Int {
        sentMessages.count
    }

    var hasActiveSession: Bool {
        true
    }

    var hasTurnInFlight: Bool {
        turnInFlight
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
        configuration.replaceProcess()
        startOrResumeExistingSessionIDs.append(existingSessionID)
        if rejectResume, existingSessionID != nil { throw NativeAgentRuntimeControllerError.processNotRunning }
        return NativeAgentRuntimeSessionRef(sessionID: existingSessionID ?? "monitor-native-session")
    }

    func currentSessionRef() async -> NativeAgentRuntimeSessionRef {
        NativeAgentRuntimeSessionRef(sessionID: "monitor-native-session")
    }

    func applyModelAndEffort(model _: String?, effortLevel _: NativeAgentRuntimeEffortLevel?) async throws {
        _ = configuration.apply()
    }

    private var configurationGate: CatalogAuthorityGate?

    fileprivate func setConfigurationGate(_ gate: CatalogAuthorityGate?) {
        configurationGate = gate
    }

    func applyModelAndEffortWithProof(model _: String?, effortLevel _: NativeAgentRuntimeEffortLevel?) async throws -> NativeAgentRuntimeConfigurationApplication {
        if let configurationGate {
            _ = await configurationGate.requirement()
        }
        return configuration.apply()
    }

    func sendUserMessage(_ text: String, configuration proof: NativeAgentRuntimeConfigurationProof) async throws -> UUID {
        try configuration.validate(proof)
        sentMessages.append(text)
        if failSendAfterRecord { throw NativeAgentRuntimeControllerError.processNotRunning }
        let turnID = UUID()
        lastSentTurnID = turnID
        if finishEventsAfterSend {
            _ = events
            continuation?.finish()
        }
        return turnID
    }

    func sendUserMessage(_ text: String) async throws -> UUID {
        sentMessages.append(text)
        if failSendAfterRecord { throw NativeAgentRuntimeControllerError.processNotRunning }
        let turnID = UUID()
        lastSentTurnID = turnID
        if finishEventsAfterSend {
            _ = events
            continuation?.finish()
        }
        return turnID
    }

    func interruptTurn(reason _: String) async -> NativeAgentRuntimeInterruptOutcome {
        .noTurnInFlight
    }

    func shutdown() async {
        configuration.replaceProcess()
        shutdownCount += 1
        continuation?.finish()
    }

    func respondToPermissionRequest(id _: String, decision _: AgentApprovalDecision) async {}
}

// MARK: - Codex fakes

/// Provider calls span controller lifetimes, while each fake keeps its own connection state.
final class MonitorCodexDispatchRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var started: [String] = []

    var startedTurns: [String] {
        lock.withLock { started }
    }

    func recordStart(_ text: String) -> Int {
        lock.withLock {
            started.append(text)
            return started.count
        }
    }
}

final class MonitorFakeCodexController: CodexSessionControllerPassiveStubDefaults, @unchecked Sendable {
    private let dispatches: MonitorCodexDispatchRecorder
    private let lock = NSLock()
    private var started: [String] = []
    private var steered: [String] = []
    private var activeTurnID: String?
    private var threadStarted = false
    private var startOrResumeHook: (@Sendable () async -> Void)?
    /// When set, `steerUserTurn` throws it instead of accepting, which is how the runtime lands in
    /// the queued-fallback path.
    var steerFailure: CodexTurnSteerError?
    /// Intercepts each physical steer attempt to drive the actual bounded transport retry.
    var steerHandler: (@MainActor @Sendable (String, String) async throws -> CodexTurnSteerReceipt)?
    /// Runtime status the queued-fallback pump reads. Idle unless a test deliberately holds it.
    var threadRuntimeStatus: CodexNativeSessionController.ThreadSnapshot.RuntimeStatus {
        get { lock.withLock { runtimeStatus } }
        set { lock.withLock { runtimeStatus = newValue } }
    }

    private var runtimeStatus: CodexNativeSessionController.ThreadSnapshot.RuntimeStatus = .idle
    private let continuation: AsyncStream<CodexNativeSessionController.Event>.Continuation
    private let stream: AsyncStream<CodexNativeSessionController.Event>

    init(dispatches: MonitorCodexDispatchRecorder) {
        self.dispatches = dispatches
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
        let submissionNumber = dispatches.recordStart(text)
        return CodexTurnStartReceipt(provisionalSubmissionID: "sub-\(submissionNumber)")
    }

    func steerUserTurn(
        text: String,
        images _: [AgentImageAttachment],
        expectedTurnID: String
    ) async throws -> CodexTurnSteerReceipt {
        if let steerHandler {
            return try await steerHandler(text, expectedTurnID)
        }
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
