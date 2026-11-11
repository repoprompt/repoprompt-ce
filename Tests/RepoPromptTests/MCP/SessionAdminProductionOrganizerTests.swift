import Combine
import Foundation
import MCP
@_spi(TestSupport) @testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptSecureStorage
import RepoPromptWorkspaceContext
import XCTest

// MARK: - Delegation placement persistence

@MainActor
final class DelegationPlacementPersistenceTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let dataService: AgentSessionDataService
        let manager: WorkspaceManagerViewModel
        let viewModel: AgentModeViewModel
        let session: AgentModeViewModel.TabSession
        let sessionID: UUID
        let workspace: WorkspaceModel
    }

    private func makeFixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DelegationPlacement-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dataService = AgentSessionDataService()
        await dataService.test_setWorkspaceRootOverride(root)
        let tabID = UUID()
        let files = WorkspaceFilesViewModel()
        let keys = KeyManager(secureService: SecureKeysService(secureStorage: TestSecureStorageBackend()))
        let api = APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keys), keyManager: keys, loadStoredDataOnInit: false
        )
        let prompt = PromptViewModel(
            fileManager: files, apiSettingsViewModel: api, windowID: -1,
            settingsManager: WindowSettingsManager(windowID: -1)
        )
        let manager = WorkspaceManagerViewModel(
            fileManager: files, promptViewModel: prompt, performInitialWorkspaceActivation: false
        )
        let workspace = WorkspaceModel(
            name: "Placement target", repoPaths: [], ephemeralFlag: true,
            composeTabs: [ComposeTabState(id: tabID)], activeComposeTabID: tabID
        )
        manager.workspaces = [workspace]
        manager.activeWorkspace = workspace
        let viewModel = AgentModeViewModel(
            testWindowID: 1, testWorkspacePath: root.path,
            codexControllerFactory: { _, _, _, _, _, _ in
                preconditionFailure("Placement tests must not start a provider")
            },
            connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
            mcpServerEnabler: { true }
        )
        viewModel.workspaceManager = manager
        viewModel.test_setCurrentTabIDOverride(tabID)
        viewModel.test_setAgentSessionSaver { session, workspace, count in
            try await dataService.saveAgentSession(
                session, for: workspace, preparation: .alreadyCanonicalTranscript,
                trustedCanonicalItemCount: count
            )
        }
        let session = viewModel.session(for: tabID)
        session.selectedAgent = .claudeCode
        session.hasLoadedPersistedState = true
        // Placement operates on an existing restored owner, not a provisional creation claim.
        let sessionID = UUID()
        _ = try XCTUnwrap(viewModel.test_installPersistentSessionBinding(
            sessionID: sessionID, on: session, updateWorkspaceMetadata: true
        ))
        session.recordRestorationAuthoritative(.persistedPayloadApplied)
        XCTAssertTrue(session.permitsBoundOperationAndSave)
        XCTAssertNil(session.restorationAdmissionFailureMessage)
        addTeardownBlock { @MainActor in
            session.saveDebounceTask?.cancel()
            viewModel.test_setCurrentTabIDOverride(nil)
            _ = manager
            try? FileManager.default.removeItem(at: root)
        }
        return Fixture(
            root: root, dataService: dataService, manager: manager, viewModel: viewModel,
            session: session, sessionID: sessionID, workspace: workspace
        )
    }

    /// A fresh owner reads the actual JSON after the production commit acknowledgement. No test
    /// flush participates: the commit itself must drive and await the ordinary durable save.
    private func reopen(_ fixture: Fixture) async throws -> AgentSession? {
        let reopened = AgentSessionDataService()
        await reopened.test_setWorkspaceRootOverride(fixture.root)
        return try await reopened.loadAgentSession(id: fixture.sessionID, for: fixture.workspace)
    }

    func testLivePlacementAcknowledgementSurvivesReopen() async throws {
        let fixture = try await makeFixture()
        let parent = UUID(), scope = UUID(), spawnParent = UUID()
        fixture.session.parentSessionID = spawnParent
        let commit = try XCTUnwrap(fixture.viewModel.commitDelegationPlacement(
            sessionID: fixture.sessionID, organizationalParentID: parent, delegationScopeID: scope
        ))
        try await commit.persisted()
        XCTAssertFalse(fixture.session.isDirty)
        let restored = try await reopen(fixture)
        XCTAssertEqual(restored?.organizationalParentID, parent)
        XCTAssertEqual(restored?.delegationScopeID, scope)
        XCTAssertEqual(restored?.parentSessionID, spawnParent, "Placement must preserve spawn provenance")
        XCTAssertEqual(restored?.id, fixture.sessionID)
    }

    func testLivePlacementSaveFailureKeepsMemoryChangeAndRejectsDurableAcknowledgement() async throws {
        struct SaveFailure: Error {}
        let fixture = try await makeFixture()
        let priorParent = UUID(), nextParent = UUID()
        var original = AgentSession(id: fixture.sessionID, name: "Original")
        original.organizationalParentID = priorParent
        _ = try await fixture.dataService.saveAgentSession(original, for: fixture.workspace)
        var saveAttempts = 0
        fixture.viewModel.test_setAgentSessionSaver { _, _, _ in
            saveAttempts += 1
            throw SaveFailure()
        }
        let commit = try XCTUnwrap(fixture.viewModel.commitDelegationPlacement(
            sessionID: fixture.sessionID, organizationalParentID: nextParent, delegationScopeID: UUID()
        ))
        do {
            try await commit.persisted()
            XCTFail("A failed save cannot acknowledge durable placement")
        } catch DelegationPlacementPersistenceError.saveFailed {
            // Expected: the caller can return applied-in-memory with persistence failure.
        }
        XCTAssertEqual(saveAttempts, 1, "The durable acknowledgement must reach the injected failing saver")
        XCTAssertEqual(fixture.session.organizationalParentID, nextParent)
        XCTAssertTrue(fixture.session.isDirty, "The failed owner remains dirty for recovery")
        let restored = try await reopen(fixture)
        XCTAssertEqual(restored?.organizationalParentID, priorParent)
    }

    func testNewerPlacementCannotAcknowledgeOlderQueuedPlacement() async throws {
        let fixture = try await makeFixture()
        let firstParent = UUID(), secondParent = UUID(), scope = UUID()
        // Both commits apply synchronously before either queued persistence task can start.
        let first = try XCTUnwrap(fixture.viewModel.commitDelegationPlacement(
            sessionID: fixture.sessionID, organizationalParentID: firstParent, delegationScopeID: scope
        ))
        let second = try XCTUnwrap(fixture.viewModel.commitDelegationPlacement(
            sessionID: fixture.sessionID, organizationalParentID: secondParent, delegationScopeID: scope
        ))
        do {
            try await first.persisted()
            XCTFail("Saving a successor must not acknowledge the superseded placement")
        } catch DelegationPlacementPersistenceError.superseded {}
        try await second.persisted()
        let restored = try await reopen(fixture)
        XCTAssertEqual(restored?.organizationalParentID, secondParent)
        XCTAssertEqual(restored?.delegationScopeID, scope)
    }

    func testUnloadedPlacementCannotRewriteSavedPayloadWithoutAWriter() async throws {
        let fixture = try await makeFixture()
        let originalParent = UUID(), scope = UUID(), creator = UUID()
        fixture.session.createdByOverseerSessionID = creator
        let initial = try XCTUnwrap(fixture.viewModel.commitDelegationPlacement(
            sessionID: fixture.sessionID, organizationalParentID: originalParent, delegationScopeID: scope
        ))
        try await initial.persisted()
        fixture.viewModel.test_removeSession(tabID: fixture.session.tabID)
        XCTAssertNil(try fixture.viewModel.commitDelegationPlacement(
            sessionID: fixture.sessionID, organizationalParentID: UUID(), delegationScopeID: UUID()
        ), "Saved metadata cannot bypass preparation and writer admission")
        let restored = try await reopen(fixture)
        XCTAssertEqual(restored?.organizationalParentID, originalParent)
        XCTAssertEqual(restored?.delegationScopeID, scope)
        XCTAssertEqual(restored?.createdByOverseerSessionID, creator)
    }

    func testRetirementAfterPlacementCommitStillAcknowledgesOriginatingWriter() async throws {
        let fixture = try await makeFixture()
        let command = try XCTUnwrap(fixture.viewModel.runtimeCommand(sessionID: fixture.sessionID))
        let parent = UUID()
        let commit = try XCTUnwrap(fixture.viewModel.commitDelegationPlacement(
            sessionID: fixture.sessionID, organizationalParentID: parent, delegationScopeID: UUID()
        ))
        command.writer.scope.beginRetirement()
        XCTAssertFalse(command.isCurrent)
        try await commit.persisted()
        let restored = try await reopen(fixture)
        XCTAssertEqual(restored?.organizationalParentID, parent)
        XCTAssertTrue(command.writer.isCurrent)
    }
}

// MARK: - SessionAdminProductionOrganizerJourneyTests regressions

/// Exercises the app's real organizing registration, workspace mutations and sidebar projection.
/// Run only through dev-test's disposable HOME/TMPDIR harness; no provider or visible window opens.
@MainActor
final class SessionAdminProductionOrganizerJourneyTests: XCTestCase {
    /// Exercise production cancellation with value-only carriers after initialization settles.
    /// No provider is started and the test harness's session-persistence suppression stays enabled.
    private func withStopCarrierWindows(
        count: Int,
        _ body: ([WindowState], WorkspaceModel, ComposeTabState, UUID) async throws -> Void
    ) async throws {
        var windows: [WindowState] = []
        for _ in 0 ..< count {
            let window = WindowState()
            windows.append(window)
            await window.workspaceManager.awaitInitialized()
        }
        let target = UUID()
        let tab = ComposeTabState(name: "Stop carrier", activeAgentSessionID: target)
        let workspace = WorkspaceModel(
            name: "Stop carrier workspace", repoPaths: [], ephemeralFlag: true,
            composeTabs: [tab], activeComposeTabID: tab.id
        )
        for window in windows {
            window.workspaceManager.workspaces = [workspace]
            window.workspaceManager.activeWorkspace = workspace
            window.promptManager.loadComposeTabsFromWorkspace(workspace)
            let viewModel = window.agentModeViewModel
            for tabID in Array(viewModel.sessions.keys) {
                viewModel.test_removeSession(tabID: tabID)
            }
            let owner = AgentModeViewModel.SessionIndexOwner(workspaceID: workspace.id, activationEpoch: 1)
            let entry = AgentSessionIndexEntry(
                id: target, tabID: tab.id, name: tab.name, savedAt: Date(timeIntervalSince1970: 0),
                itemCount: 0, autoEditEnabled: false, hasUnknownConversationContent: false,
                isMCPOriginated: false, worktreeBindingSummaries: [], activeWorktreeMergeSummaries: []
            )
            viewModel.test_installSessionIndexSnapshot(
                [target: entry], owner: owner, latestOwner: owner, activeWorkspace: workspace
            )
        }
        do { try await body(windows, workspace, tab, target) } catch {
            for window in windows.reversed() {
                window.agentModeViewModel.runService.testBeforeCancellationCommit = nil
                await window.tearDown()
            }
            throw error
        }
        for window in windows.reversed() {
            window.agentModeViewModel.runService.testBeforeCancellationCommit = nil
            await window.tearDown()
        }
    }

    private func installStopRun(
        in window: WindowState, tabID: UUID, sessionID: UUID, injectConflictingWriter: Bool = false
    ) throws -> AgentModeViewModel.TabSession {
        let session = AgentModeViewModel.TabSession(tabID: tabID)
        session.selectedAgent = .claudeCode
        session.hasLoadedPersistedState = true
        window.agentModeViewModel.test_installLiveSession(session)
        if injectConflictingWriter {
            XCTAssertEqual(window.agentModeViewModel.runtimeSessionStore.bindingRejection(sessionID, on: session), .conflictingWriter)
            XCTAssertNil(window.agentModeViewModel.test_installPersistentSessionBinding(
                sessionID: sessionID, on: session
            ))
            XCTAssertNil(session.persistentSessionBindingIdentity)
            // Deliberately inject corrupt legacy state to exercise the resolver's defensive
            // conflict path. Ordinary writer admission above must refuse this second claim.
            _ = session.beginPersistentBindingTransition()
            try session.installPersistentSessionBinding(.init(
                tabID: tabID, sessionID: sessionID, workspaceID: XCTUnwrap(window.workspaceManager.activeWorkspaceID)
            ))
        } else {
            _ = try XCTUnwrap(window.agentModeViewModel.test_installPersistentSessionBinding(
                sessionID: sessionID, on: session
            ))
        }
        XCTAssertEqual(session.persistentSessionBindingIdentity?.workspaceID, window.workspaceManager.activeWorkspaceID)
        session.recordRestorationAuthoritative(.persistedPayloadApplied)
        session.runState = .running
        session.installRunID(UUID())
        _ = session.beginRunAttempt(source: "session-admin-stop-integration")
        return session
    }

    func testPlacementRechecksRevokedLeaseAfterPreparationAndReleasesHold() async throws {
        let fixture = SessionAdminStructureTests.Fixture()
        let root = UUID(), target = UUID(), destination = UUID()
        fixture.provenance.add(root, parent: nil)
        fixture.provenance.add(target, parent: root)
        fixture.provenance.add(destination, parent: root)
        let grant = try fixture.grant(root)
        var preparations = 0
        let host = SessionAdminWindowsStructureHost(preparation: { id, isStillAuthorized in
            XCTAssertEqual(id, target)
            XCTAssertTrue(isStillAuthorized())
            preparations += 1
            fixture.runtime.revoke(scopeID: grant.id)
            XCTAssertFalse(isStillAuthorized())
            return .ready
        })
        let context = SessionAdminHandlerContext(scopes: fixture.runtime, projector: fixture.projector)
        fixture.core.register(SessionAdminRestructureHandler(context: context, host: host))
        let reply = try await fixture.value(
            .adminReparent, caller: root, targets: [target],
            args: ["parent_session_id": .string(destination.uuidString)]
        )
        XCTAssertEqual(preparations, 1)
        XCTAssertEqual(reply["changed_count"], .int(0))
        let item = try XCTUnwrap(reply["items"]?.arrayValue?.first?.objectValue)
        XCTAssertEqual(item["code"], .string("scope_revoked"))
        XCTAssertNil(fixture.provenance.sessions[target]?.organizationalParentID)
        XCTAssertNil(WindowStatesManager.shared.preparedOversightPreparationInFlight[target])
        guard case .unavailable(.absent) = AgentSessionRuntimeStore.shared.resolveWriter(sessionID: target) else {
            return XCTFail("Preparation refusal must not install a writer")
        }
    }

    func testForkUsesCanonicalWriterWithAgreeingReplicaAndAcknowledgesSavedDestination() async throws {
        try await MCPSharedServerTestLease.shared.withLease { _ in
            let fixture = try await Fixture.make(isolated: true)
            let mirror = try await fixture.addReplica()
            do {
                let viewModel = fixture.window.agentModeViewModel
                let sourceID = try XCTUnwrap(fixture.targetTab.activeAgentSessionID)
                let source = viewModel.session(for: fixture.targetTab.id)
                _ = try XCTUnwrap(viewModel.test_installPersistentSessionBinding(
                    sessionID: sourceID, on: source, updateWorkspaceMetadata: true
                ))
                source.recordRestorationAuthoritative(.persistedPayloadApplied)
                source.hasLoadedPersistedState = true
                source.replaceItems([.user("Fork source", sequenceIndex: 0)])
                let command = try XCTUnwrap(SessionAdminWindows.command(for: sourceID))
                XCTAssertTrue(command.writer.session === source)
                var preparations = 0
                let host = SessionAdminWindowsStructureHost(preparation: { _, _ in
                    preparations += 1
                    return .changed
                })
                var authorized = true
                var acknowledgements = 0
                viewModel.test_afterConfiguredCreationAcknowledgement = { _ in
                    acknowledgements += 1
                    authorized = false
                    withUnsafeCurrentTask { $0?.cancel() }
                }
                defer { viewModel.test_afterConfiguredCreationAcknowledgement = nil }
                let fork = Task { @MainActor in
                    try await host.fork(sessionID: sourceID, upToItemID: nil, isStillAuthorized: { authorized })
                }
                let destinationID = try await fork.value
                XCTAssertTrue(fork.isCancelled)
                XCTAssertEqual(acknowledgements, 1)
                XCTAssertEqual(preparations, 0, "An agreeing UI witness must not trigger a second writer")
                XCTAssertNotEqual(destinationID, sourceID)
                let destinationCommand = try XCTUnwrap(SessionAdminWindows.command(for: destinationID))
                XCTAssertFalse(destinationCommand.writer.session.isDirty)
                let workspace = try fixture.workspace()
                let saved = try await AgentSessionDataService.shared.loadAgentSession(id: destinationID, for: workspace)
                XCTAssertEqual(saved?.id, destinationID, "Success must acknowledge the configured first save without a test flush")
                XCTAssertEqual(saved?.items.count(where: { $0.kind == .user }), 1)
                XCTAssertEqual(fixture.window.promptManager.activeComposeTabID, fixture.callerTab.id)
                XCTAssertEqual(mirror.promptManager.activeComposeTabID, fixture.callerTab.id)
                XCTAssertNil(WindowStatesManager.shared.preparedOversightPreparationInFlight[sourceID])
            } catch {
                await fixture.removeReplica(mirror)
                await fixture.cleanup()
                throw error
            }
            await fixture.removeReplica(mirror)
            await fixture.cleanup()
        }
    }

    func testForkPreparesBoundUnrestoredSourceThroughRealSavedTargetPath() async throws {
        try await MCPSharedServerTestLease.shared.withLease { _ in
            let fixture = try await Fixture.make(isolated: true)
            do {
                let sourceID = try XCTUnwrap(fixture.targetTab.activeAgentSessionID)
                let workspace = try fixture.workspace()
                _ = try await AgentSessionDataService.shared.saveAgentSession(
                    AgentSession(
                        id: sourceID, workspaceID: workspace.id, composeTabID: fixture.targetTab.id,
                        name: "Saved source", items: [AgentChatItemPersist(from: .user("Saved fork source", sequenceIndex: 0))]
                    ), for: workspace
                )
                let source = fixture.window.agentModeViewModel.session(for: fixture.targetTab.id)
                _ = try XCTUnwrap(fixture.window.agentModeViewModel.test_installPersistentSessionBinding(
                    sessionID: sourceID, on: source, updateWorkspaceMetadata: true
                ))
                XCTAssertFalse(source.hasLoadedPersistedState)
                XCTAssertFalse(source.permitsBoundOperationAndSave)
                var preparations = 0
                let host = SessionAdminWindowsStructureHost(preparation: { id, authorized in
                    preparations += 1
                    XCTAssertEqual(id, sourceID)
                    XCTAssertEqual(WindowStatesManager.shared.preparedOversightPreparationInFlight[id], 1)
                    return await SessionAdminWindowsStructureHost.savedTargetPreparation(id, authorized)
                })
                let destinationID = try await host.fork(sessionID: sourceID, upToItemID: nil, isStillAuthorized: { true })
                XCTAssertEqual(preparations, 1)
                XCTAssertTrue(source.hasLoadedPersistedState)
                let saved = try await AgentSessionDataService.shared.loadAgentSession(id: destinationID, for: workspace)
                XCTAssertEqual(saved?.items.first(where: { $0.kind == .user })?.text, "Saved fork source")
                XCTAssertEqual(fixture.window.promptManager.activeComposeTabID, fixture.callerTab.id)
                XCTAssertNil(WindowStatesManager.shared.preparedOversightPreparationInFlight[sourceID])
            } catch {
                await fixture.cleanup()
                throw error
            }
            await fixture.cleanup()
        }
    }

    func testFirstPlacementAcrossColdReplicasUsesOnePreparedWriterAndProjectsEveryWitness() async throws {
        try await MCPSharedServerTestLease.shared.withLease { _ in
            let originalFullAccess = OverseerGlobalAutoApprove.isEnabled
            OverseerGlobalAutoApprove.isEnabled = { false }
            defer { OverseerGlobalAutoApprove.isEnabled = originalFullAccess }
            let fixture = try await Fixture.make(isolated: true)
            let mirror = try await fixture.addReplica()
            let manager = WindowStatesManager.shared
            let target = try XCTUnwrap(fixture.targetTab.activeAgentSessionID)
            let workspace = try fixture.workspace()
            let originalRegistry = AgentSessionCarrierResolver.preparedSessionRuntimes
            let originalFactory = manager.test_preparedOversightOwnerFactory
            // Keep the prepared adapter available for post-transaction witness inspection.
            // This hold creates no writer; the production transaction must acquire/release its own.
            manager.beginPreparedOversightPreparation(target)
            defer { manager.endPreparedOversightPreparation(target) }
            var preparations = 0
            var observingProductionPlacement = false
            var productionSaveHoldCounts: [Int] = []
            AgentSessionCarrierResolver.preparedSessionRuntimes = manager
            manager.test_preparedOversightOwnerFactory = { workspace, source in
                preparations += 1
                let owner = WindowState.makePreparedSessionOwner(workspace: workspace, borrowing: source)
                owner.agentModeViewModel.test_setAgentSessionSaver { payload, workspace, count in
                    if observingProductionPlacement {
                        productionSaveHoldCounts.append(manager.preparedOversightPreparationInFlight[target, default: 0])
                    }
                    return try await AgentSessionDataService.shared.saveAgentSession(
                        payload, for: workspace, preparation: .alreadyCanonicalTranscript, trustedCanonicalItemCount: count
                    )
                }
                return owner
            }
            @MainActor func cleanup() async {
                if let owner = manager.preparedOversightWindows.removeValue(forKey: target) {
                    owner.beginClose()
                    let retired = await owner.tearDownPreparedSessionOwner()
                    XCTAssertTrue(retired)
                }
                manager.preparedOversightRunObservations.removeValue(forKey: target)?.invalidate()
                manager.preparedOversightCarrierSubscriptions.removeValue(forKey: target)
                manager.preparedOversightOwnerLocations.removeValue(forKey: target)
                manager.preparedOversightLocations.removeValue(forKey: target)
                manager.test_preparedOversightOwnerFactory = originalFactory
                AgentSessionCarrierResolver.preparedSessionRuntimes = originalRegistry
                await fixture.removeReplica(mirror)
                await fixture.cleanup()
            }
            do {
                _ = try await AgentSessionDataService.shared.saveAgentSession(
                    AgentSession(id: target, workspaceID: workspace.id, composeTabID: fixture.targetTab.id, name: "Saved target", items: []),
                    for: workspace
                )
                guard case .unavailable(.absent) = AgentSessionRuntimeStore.shared.resolveWriter(sessionID: target) else {
                    throw SessionAdminHostError.invalid("The target must start cold")
                }
                fixture.frontDoor.registerStructureHandlers(scopes: fixture.scopes, worktreeOwnership: fixture.ownership)
                let caller = try XCTUnwrap(fixture.callerTab.activeAgentSessionID)
                let requested = try fixture.scopes.requestScope(
                    requesterSessionID: caller, requesterTabID: fixture.callerTab.id,
                    kind: .workspace(workspaceID: workspace.id), capabilities: [.observe, .restructure],
                    guardrails: .init(), reason: nil, idempotencyKey: nil
                ).get()
                let granted = try fixture.scopes.approve(requestID: requested.id).get()
                let fields: [String: Value] = [
                    "scope_id": .string(granted.id.uuidString), "parent_session_id": .string(caller.uuidString)
                ]
                var previewFields = fields
                previewFields["preview"] = .bool(true)
                let preview = try await fixture.call("reparent", previewFields)
                XCTAssertEqual(preview["result"], .string("preview"))
                XCTAssertEqual(preparations, 0, "Preview must not elect or hydrate a writer")
                // Exercise the real MCP caller resolution, authorization and scope transaction,
                // not just the host's lower-level preparation/commit methods.
                observingProductionPlacement = true
                let reply = try await fixture.call("reparent", fields)
                observingProductionPlacement = false
                XCTAssertFalse(productionSaveHoldCounts.isEmpty)
                XCTAssertTrue(productionSaveHoldCounts.allSatisfy { $0 == 2 }, "The production hold must cover the actual save")
                XCTAssertEqual(reply["changed_count"], .int(1), "\(reply)")
                let item = try XCTUnwrap(reply["items"]?.arrayValue?.first?.objectValue)
                XCTAssertEqual(item["result"], .string("moved"))
                XCTAssertNil(item["persist_failed"])
                XCTAssertEqual(preparations, 1)
                let firstReopen = try await AgentSessionDataService().loadAgentSession(id: target, for: workspace)
                XCTAssertEqual(firstReopen?.organizationalParentID, caller)
                for window in [fixture.window, mirror] {
                    XCTAssertEqual(window.agentModeViewModel.ownerValidatedSessionIndex[target]?.organizationalParentID, caller)
                    XCTAssertNil(window.agentModeViewModel.sessions[fixture.targetTab.id])
                }
                XCTAssertEqual(manager.preparedOversightLocations[target]?.isCurrent, true)
                XCTAssertEqual(manager.preparedOversightOwnerLocations[target]?.entry.organizationalParentID, caller)
                let preparedOwner = try XCTUnwrap(manager.preparedOversightWindows[target])
                guard case let .unique(firstWriter) = AgentSessionRuntimeStore.shared.resolveWriter(sessionID: target) else {
                    throw SessionAdminHostError.invalid("The production transaction must leave one exact writer")
                }
                XCTAssertTrue(firstWriter.session === preparedOwner.agentModeViewModel.sessions[fixture.targetTab.id])
                XCTAssertEqual(manager.preparedOversightPreparationInFlight[target], 1, "Only the test's inspection hold may remain after the transaction")
                let host = SessionAdminWindowsStructureHost()
                let hold = try await host.prepareOrganizationalPlacement(sessionID: target, isStillAuthorized: { true })
                defer { hold.release() }
                let parent = UUID(), scope = UUID()
                let commit = try XCTUnwrap(host.commitOrganizationalPlacement(sessionID: target, parentID: parent, delegationScopeID: scope))
                let owner = try XCTUnwrap(manager.preparedOversightWindows[target])
                XCTAssertFalse(owner === fixture.window || owner === mirror)
                // A private runtime has no published sidebar snapshot; project the existing UI
                // indexes, while its exact session owns the payload mutation.
                for window in [fixture.window, mirror] {
                    XCTAssertEqual(window.agentModeViewModel.ownerValidatedSessionIndex[target]?.organizationalParentID, parent)
                    XCTAssertEqual(window.agentModeViewModel.ownerValidatedSessionIndex[target]?.delegationScopeID, scope)
                }
                let liveSession = try XCTUnwrap(owner.agentModeViewModel.sessions[fixture.targetTab.id])
                XCTAssertEqual(liveSession.organizationalParentID, parent)
                XCTAssertEqual(liveSession.delegationScopeID, scope)
                XCTAssertEqual(manager.preparedOversightLocations[target]?.entry.organizationalParentID, parent)
                XCTAssertEqual(manager.preparedOversightOwnerLocations[target]?.entry.organizationalParentID, parent)
                XCTAssertEqual(manager.preparedOversightLocations[target]?.isCurrent, true)
                try await commit.persisted()
                let reopened = try await AgentSessionDataService().loadAgentSession(id: target, for: workspace)
                XCTAssertEqual(reopened?.organizationalParentID, parent)
                let again = try await host.prepareOrganizationalPlacement(sessionID: target, isStillAuthorized: { true })
                again.release()
                XCTAssertEqual(preparations, 1)
                XCTAssertNil(fixture.window.agentModeViewModel.sessions[fixture.targetTab.id])
                XCTAssertNil(mirror.agentModeViewModel.sessions[fixture.targetTab.id])
                await cleanup()
            } catch {
                await cleanup()
                throw error
            }
        }
    }

    func testStopSelectsTheExactRunningObjectAcrossColdCanonicalReplicasInEitherOrder() async throws {
        try await MCPSharedServerTestLease.shared.withLease { _ in
            for liveFirst in [false, true] {
                try await withStopCarrierWindows(count: 2) { windows, _, tab, target in
                    let cold = windows[0]
                    let live = windows[1]
                    let session = try installStopRun(in: live, tabID: tab.id, sessionID: target)
                    var cancelledObjects: [ObjectIdentifier] = []
                    live.agentModeViewModel.runService.testBeforeCancellationCommit = { candidate in
                        cancelledObjects.append(ObjectIdentifier(candidate))
                    }
                    let ordered = liveFirst ? [live, cold] : [cold, live]
                    let organizer = OpenWindowsAgentSessionOrganizer(windows: { ordered })
                    let outcome = await organizer.stopRun(target, isStillAuthorized: { true })
                    XCTAssertTrue(outcome.initiatedCancellation, "liveFirst=\(liveFirst)")
                    XCTAssertTrue(outcome.stopped, "liveFirst=\(liveFirst)")
                    XCTAssertEqual(cancelledObjects, [ObjectIdentifier(session)])
                    XCTAssertEqual(session.lastTerminalCommitRevision?.terminalState, .cancelled)
                    XCTAssertNil(cold.agentModeViewModel.sessions[tab.id], "Stop must not hydrate a cold replica")
                    for window in windows {
                        XCTAssertEqual(window.workspaceManager.activeWorkspace?.activeComposeTabID, tab.id)
                        XCTAssertEqual(window.promptManager.activeComposeTabID, tab.id)
                    }
                }
            }
        }
    }

    func testStopRejectsDistinctLiveObjectsAtTheSameCanonicalAddress() async throws {
        try await MCPSharedServerTestLease.shared.withLease { _ in
            try await withStopCarrierWindows(count: 2) { windows, _, tab, target in
                let sessions = try windows.enumerated().map {
                    try installStopRun(in: $0.element, tabID: tab.id, sessionID: target, injectConflictingWriter: $0.offset > 0)
                }
                let generations = sessions.map(\.stopState.cancellationGeneration)
                let runIDs = sessions.map(\.runID)
                var cancellationCommits = 0
                for window in windows {
                    window.agentModeViewModel.runService.testBeforeCancellationCommit = { _ in cancellationCommits += 1 }
                }
                for ordered in [windows, Array(windows.reversed())] {
                    let organizer = OpenWindowsAgentSessionOrganizer(windows: { ordered })
                    let outcome = await organizer.stopRun(target, isStillAuthorized: { true })
                    XCTAssertFalse(outcome.initiatedCancellation)
                    XCTAssertFalse(outcome.stopped)
                    XCTAssertEqual(sessions.map(\.runState), [.running, .running])
                    XCTAssertEqual(sessions.map(\.runID), runIDs)
                    XCTAssertEqual(sessions.map(\.stopState.cancellationGeneration), generations)
                    XCTAssertEqual(cancellationCommits, 0)
                }
            }
        }
    }

    func testStopRechecksAuthorizationAndCarrierIdentityBeforeCancellationClaim() async throws {
        try await MCPSharedServerTestLease.shared.withLease { _ in
            for change in ["revoked", "rebound", "duplicate_carrier"] {
                try await withStopCarrierWindows(count: 1) { windows, _, tab, target in
                    let window = windows[0]
                    let session = try installStopRun(in: window, tabID: tab.id, sessionID: target)
                    let generation = session.stopState.cancellationGeneration
                    let runID = session.runID
                    var cancellationCommits = 0
                    var authorityChecked = false
                    window.agentModeViewModel.runService.testBeforeCancellationCommit = { _ in cancellationCommits += 1 }
                    let organizer = OpenWindowsAgentSessionOrganizer(windows: { windows })
                    let outcome = await organizer.stopRun(target, isStillAuthorized: {
                        // This callback runs after the target was captured, immediately before claim.
                        if !authorityChecked {
                            authorityChecked = true
                            if change == "rebound" {
                                session.testInstallPersistentSessionBinding(sessionID: UUID())
                            } else if change == "duplicate_carrier" {
                                window.workspaceManager.workspaces[0].composeTabs.append(
                                    ComposeTabState(name: "Conflicting carrier", activeAgentSessionID: target)
                                )
                            }
                        }
                        return change != "revoked"
                    })
                    XCTAssertTrue(authorityChecked, change)
                    XCTAssertFalse(outcome.initiatedCancellation, change)
                    XCTAssertFalse(outcome.stopped, change)
                    XCTAssertEqual(cancellationCommits, 0, change)
                    XCTAssertEqual(session.stopState.cancellationGeneration, generation, change)
                    XCTAssertEqual(session.runID, runID, change)
                    XCTAssertEqual(session.runState, .running, change)
                    XCTAssertNil(session.lastTerminalCommitRevision, change)
                }
            }
        }
    }

    func testStopReportsInitiationWithoutClaimingNaturallyCompletedRunWasStopped() async throws {
        try await MCPSharedServerTestLease.shared.withLease { _ in
            try await withStopCarrierWindows(count: 1) { windows, _, tab, target in
                let window = windows[0]
                let viewModel = window.agentModeViewModel
                let session = try installStopRun(in: window, tabID: tab.id, sessionID: target)
                var completedObjects: [ObjectIdentifier] = []
                viewModel.runService.testBeforeCancellationCommit = { candidate in
                    completedObjects.append(ObjectIdentifier(candidate))
                    await viewModel.runService.test_publishNaturalCompletion(candidate)
                }
                let organizer = OpenWindowsAgentSessionOrganizer(windows: { windows })
                let outcome = await organizer.stopRun(target, isStillAuthorized: { true })
                XCTAssertTrue(outcome.initiatedCancellation)
                XCTAssertFalse(outcome.stopped)
                XCTAssertEqual(completedObjects, [ObjectIdentifier(session)])
                XCTAssertEqual(session.lastTerminalCommitRevision?.terminalState, .completed)
                XCTAssertEqual(session.runState, .completed)
            }
        }
    }

    func testGroupsAcrossLoadedWorkspacesUseProductionFrontDoorAndRealFullAccessSetting() async throws {
        try await MCPSharedServerTestLease.shared.withLease { _ in
            // Override in memory; tests must never write the user's real setting.
            let previousFullAccess = OverseerGlobalAutoApprove.isEnabled
            defer { OverseerGlobalAutoApprove.isEnabled = previousFullAccess }
            for enabled in [false, true] {
                OverseerGlobalAutoApprove.isEnabled = { enabled }
                let caller = try await Fixture.make(isolated: true)
                let destination = try await Fixture.make(isolated: true)
                do {
                    let callerID = caller.callerTab.activeAgentSessionID!
                    let ids = [destination.callerTab.activeAgentSessionID!, destination.targetTab.activeAgentSessionID!]
                    var scope: UUID?
                    if !enabled {
                        let request = try caller.scopes.requestScope(
                            requesterSessionID: callerID, requesterTabID: caller.callerTab.id,
                            kind: .workspace(workspaceID: destination.workspaceID), capabilities: [.observe, .organize],
                            guardrails: .init(bulkConfirmationThreshold: 1), reason: nil, idempotencyKey: nil
                        ).get()
                        scope = try caller.scopes.approve(requestID: request.id).get().id
                    }
                    @MainActor func perform(_ operation: DomainAgentSessionTargetOperation, targets: [UUID] = [], arguments: [String: Value], key: String) async throws -> [String: Value] {
                        let result = try await caller.frontDoor.perform(.init(
                            operation: operation, caller: .agentSession(callerID), callerTabID: caller.callerTab.id,
                            scopeID: scope, targetSessionIDs: targets, idempotencyKey: key, arguments: arguments
                        ))
                        switch result {
                        case let .completed(value): return try XCTUnwrap(value.objectValue)
                        case let .pendingConfirmation(card, _):
                            XCTAssertFalse(enabled, "ON must never raise a card")
                            let before = try destination.workspace()
                            if key == "set" { XCTAssertTrue(before.composeTabs.allSatisfy { $0.sidebarGroup == nil }) }
                            await caller.frontDoor.approveAndApply(
                                confirmationID: card.id, presentedTabID: caller.callerTab.id, presentedSessionID: callerID
                            )
                            return try XCTUnwrap(caller.frontDoor.appliedResult(forConfirmation: card.id)?.objectValue)
                        default: XCTFail("Unexpected authorization outcome for \(operation) (full access \(enabled)): \(result)")
                            return [:]
                        }
                    }
                    let set = try await perform(.adminSetGroup, targets: ids, arguments: ["group": .string("Alpha")], key: "set")
                    XCTAssertEqual(set["result"], .string("applied"))
                    if enabled { XCTAssertTrue(caller.scopes.confirmations.confirmations.isEmpty) }
                    else { XCTAssertFalse(caller.scopes.confirmations.confirmations.isEmpty, "OFF must use a real batch card") }
                    let changed = try await perform(.adminSetGroup, targets: [ids[1]], arguments: ["group": .string("Beta")], key: "change")
                    XCTAssertEqual(changed["changed_count"], .int(1))
                    var reorder: [String: Value] = [
                        "workspace": .string(destination.workspaceID.uuidString),
                        "order": .array([.string("Beta"), .string("Alpha")]),
                        "expected_order": .array([.string("Beta"), .string("Alpha")])
                    ]
                    let conflict = try await perform(.adminReorderGroups, arguments: reorder, key: "stale")
                    XCTAssertEqual(conflict["result"], .string("order_conflict"))
                    for key in ["code", "subreason", "detail", "next_call", "retryable"] {
                        XCTAssertNotNil(conflict[key], key)
                    }
                    reorder["expected_order"] = .array([.string("Alpha"), .string("Beta")])
                    let ordered = try await perform(.adminReorderGroups, arguments: reorder, key: "order")
                    XCTAssertEqual(ordered["group_order"], .array([.string("Beta"), .string("Alpha")]))
                    let cleared = try await perform(.adminSetGroup, targets: ids, arguments: ["group": .string("")], key: "clear")
                    XCTAssertEqual(cleared["changed_count"], .int(2))
                    XCTAssertTrue(try destination.workspace().composeTabs.allSatisfy { $0.sidebarGroup == nil && $0.sidebarGroupOrder == nil })
                    XCTAssertTrue(try caller.workspace().composeTabs.allSatisfy { $0.sidebarGroup == nil }, "Do not mutate the caller's workspace")
                    // Reordering groups that no session carries any more names what does exist.
                    reorder["expected_order"] = .array([.string("Beta"), .string("Alpha")])
                    let gone = try await perform(.adminReorderGroups, arguments: reorder, key: "gone")
                    XCTAssertEqual(gone["result"], .string("groups_not_found"))
                    XCTAssertEqual(gone["current_groups"], .array([]))
                    XCTAssertNotNil(gone["detail"])
                    let emptyRecovery = try XCTUnwrap(gone["next_call"]?.objectValue?["arguments"]?.objectValue)
                    XCTAssertEqual(emptyRecovery["order"], .array([]))
                    XCTAssertEqual(emptyRecovery["expected_order"], .array([]))
                    let emptyResult = try await perform(.adminReorderGroups, arguments: emptyRecovery, key: "empty-recovery")
                    XCTAssertEqual(emptyResult["result"], .string("no_matching_sessions"), "an empty recovery must not claim a write")
                    let noOrder = try await perform(.adminReorderGroups, arguments: ["workspace": .string(destination.workspaceID.uuidString)], key: "no-order")
                    XCTAssertEqual(noOrder["result"], .string("order_required"))
                    XCTAssertNotNil(noOrder["current_groups"])
                    await destination.cleanup()
                    await caller.cleanup()
                } catch {
                    await destination.cleanup()
                    await caller.cleanup()
                    throw error
                }
            }
        }
    }

    func testReorderGroupsMCPRecoveryAndApplyUseOneWriterForAgreeingReplicas() async throws {
        try await MCPSharedServerTestLease.shared.withLease { _ in
            let previous = OverseerGlobalAutoApprove.isEnabled
            defer { OverseerGlobalAutoApprove.isEnabled = previous }
            for (fullAccess, namedRestrictedScope) in [(false, false), (true, false), (true, true)] {
                OverseerGlobalAutoApprove.isEnabled = { fullAccess }
                let caller = try await Fixture.make(isolated: true)
                let destination = try await Fixture.make(isolated: true)
                var replica: WindowState?
                do {
                    try await caller.enableCanonicalHost()
                    destination.installGroups()
                    let mirror = try await destination.addReplica()
                    replica = mirror
                    let ids = Set([destination.callerTab.activeAgentSessionID!, destination.targetTab.activeAgentSessionID!])
                    let proof = AgentSessionCarrierResolver.capture(windows: [destination.window, mirror], sessionIDs: ids)
                    XCTAssertEqual(proof.replicatedSessionIDs, ids)
                    XCTAssertTrue(proof.ambiguousSessionIDs.isEmpty)
                    XCTAssertTrue(
                        caller.scopes.allLiveScopes().isEmpty || !fullAccess,
                        "The first full-access MCP call must materialize its own scope"
                    )
                    var arguments: [String: Value] = ["workspace": .string(destination.workspaceID.uuidString)]
                    if !fullAccess || namedRestrictedScope {
                        let request = try caller.scopes.requestScope(
                            requesterSessionID: caller.callerTab.activeAgentSessionID!, requesterTabID: caller.callerTab.id,
                            kind: .workspace(workspaceID: namedRestrictedScope ? caller.workspaceID : destination.workspaceID),
                            capabilities: namedRestrictedScope ? [.observe] : [.observe, .organize],
                            guardrails: .init(), reason: nil, idempotencyKey: nil
                        ).get()
                        let granted = try caller.scopes.approve(requestID: request.id).get()
                        arguments["scope_id"] = .string(granted.id.uuidString)
                    }
                    destination.window.promptManager.promptText = "Writer's unsaved user draft"
                    destination.window.promptManager.testSetDirtyTabIDs([destination.callerTab.id])
                    mirror.promptManager.promptText = "Peer's independent unsaved user draft"
                    mirror.promptManager.testSetDirtyTabIDs([destination.callerTab.id])
                    let discovery = try await caller.call("reorder_groups", arguments)
                    XCTAssertEqual(discovery["result"], .string("order_required"))
                    XCTAssertEqual(discovery["current_groups"], .array([.string("Alpha"), .string("Beta")]))
                    let preview = try await caller.call("reorder_groups", arguments.merging(["preview": .bool(true)]) { _, new in new })
                    XCTAssertEqual(preview["result"], .string("order_required"), "Preview must return executable discovery, not an incomplete mutation plan")
                    let previewNext = try XCTUnwrap(preview["next_call"]?.objectValue)
                    XCTAssertEqual(previewNext["tool"], .string("session_admin"))
                    let previewRecovery = try XCTUnwrap(previewNext["arguments"]?.objectValue)
                    XCTAssertEqual(previewRecovery["preview"], .bool(true), "Recovery must preserve the caller's non-mutating preview intent")
                    let previewed = try await caller.call("reorder_groups", previewRecovery)
                    XCTAssertEqual(previewed["result"], .string("preview"))
                    XCTAssertEqual(destination.window.workspaceManager.activeWorkspace?.composeTabs.map(\.sidebarGroupOrder), [4, 9])
                    XCTAssertEqual(mirror.workspaceManager.activeWorkspace?.composeTabs.map(\.sidebarGroupOrder), [4, 9])
                    XCTAssertTrue(caller.scopes.confirmations.confirmations.isEmpty, "Incomplete order arguments must never mint a batch card")
                    let next = try XCTUnwrap(discovery["next_call"]?.objectValue)
                    XCTAssertEqual(next["tool"], .string("session_admin"))
                    var followup = try XCTUnwrap(next["arguments"]?.objectValue)
                    XCTAssertNil(followup["session_id"], "Workspace discovery must not borrow the caller or an arbitrary target")
                    XCTAssertNil(followup["targets"])
                    XCTAssertEqual(followup["expected_order"], discovery["current_order"])
                    let unchanged = try await caller.call("reorder_groups", followup)
                    XCTAssertEqual(unchanged["result"], .string("applied"), "The exact advertised next call must satisfy the requested order")
                    XCTAssertEqual(unchanged["state_satisfied"], .bool(true))
                    XCTAssertEqual(unchanged["changed_count"], .int(0))
                    XCTAssertEqual(unchanged["group_order"], discovery["current_order"])
                    XCTAssertEqual(Set(unchanged["items"]?.arrayValue?.compactMap { $0.objectValue?["status"]?.stringValue } ?? []), ["unchanged"])
                    XCTAssertNil(unchanged["code"])
                    XCTAssertNil(unchanged["next_call"])
                    XCTAssertNil(unchanged["undo_token"])
                    XCTAssertEqual(destination.window.workspaceManager.activeWorkspace?.composeTabs.map(\.sidebarGroupOrder), [4, 9])
                    XCTAssertEqual(mirror.workspaceManager.activeWorkspace?.composeTabs.map(\.sidebarGroupOrder), [4, 9])
                    followup["order"] = .array([.string("Beta"), .string("Alpha")])
                    followup["idempotency_key"] = .string(UUID().uuidString)
                    let applied = try await caller.call("reorder_groups", followup)
                    XCTAssertEqual(applied["result"], .string("applied"))
                    XCTAssertEqual(applied["changed_count"], .int(2))
                    for window in [destination.window, mirror] {
                        XCTAssertEqual(window.workspaceManager.activeWorkspace?.composeTabs.map(\.sidebarGroupOrder), [9, 4])
                        XCTAssertEqual(window.promptManager.currentComposeTabs.map(\.sidebarGroupOrder), [9, 4])
                        XCTAssertEqual(window.workspaceManager.activeWorkspace?.activeComposeTabID, destination.callerTab.id)
                        XCTAssertEqual(window.promptManager.activeComposeTabID, destination.callerTab.id)
                    }
                    XCTAssertEqual(destination.window.promptManager.promptText, "Writer's unsaved user draft")
                    XCTAssertEqual(mirror.promptManager.promptText, "Peer's independent unsaved user draft")
                    let undo = try await caller.undo(applied)
                    XCTAssertEqual(undo["result"], .string("undone"))
                    for window in [destination.window, mirror] {
                        XCTAssertEqual(window.workspaceManager.activeWorkspace?.composeTabs.map(\.sidebarGroupOrder), [4, 9])
                    }
                    // The original recovery expectation is compared again on every new call.
                    destination.installGroups(alphaOrder: 9, betaOrder: 4)
                    destination.installGroups(in: mirror, alphaOrder: 9, betaOrder: 4)
                    let stale = try await caller.call("reorder_groups", followup.merging([
                        "idempotency_key": .string(UUID().uuidString)
                    ]) { _, new in new })
                    XCTAssertEqual(stale["result"], .string("order_conflict"))
                    await destination.removeReplica(mirror)
                    replica = nil
                    await destination.cleanup()
                    await caller.cleanup()
                } catch {
                    if let replica { await destination.removeReplica(replica) }
                    await destination.cleanup()
                    await caller.cleanup()
                    throw error
                }
            }
        }
    }

    func testReorderGroupsReportsCommittedSaveWhenAuthorityOrReplicaIdentityChangesDuringSave() async throws {
        try await MCPSharedServerTestLease.shared.withLease { _ in
            let previous = OverseerGlobalAutoApprove.isEnabled
            defer { OverseerGlobalAutoApprove.isEnabled = previous }
            OverseerGlobalAutoApprove.isEnabled = { false }
            for change in ["scope", "identity"] {
                let caller = try await Fixture.make(isolated: true)
                let destination = try await Fixture.make(ephemeral: false, runtimeBacked: true)
                var replica: WindowState?
                let manager = destination.window.workspaceManager
                do {
                    try await caller.enableCanonicalHost()
                    destination.installGroups()
                    let mirror = try await destination.addReplica()
                    replica = mirror
                    let carrierIDs = Set([destination.callerTab.activeAgentSessionID!, destination.targetTab.activeAgentSessionID!])
                    for window in [destination.window, mirror] {
                        XCTAssertEqual(
                            Set(window.agentModeViewModel.ownerValidatedSessionIndex.keys), carrierIDs,
                            "Every replica needs owner-valid placement metadata before membership can be proven"
                        )
                    }
                    let request = try caller.scopes.requestScope(
                        requesterSessionID: caller.callerTab.activeAgentSessionID!, requesterTabID: caller.callerTab.id,
                        kind: .workspace(workspaceID: destination.workspaceID), capabilities: [.observe, .organize],
                        guardrails: .init(), reason: nil, idempotencyKey: nil
                    ).get()
                    let granted = try caller.scopes.approve(requestID: request.id).get()
                    XCTAssertTrue(manager.canCommitComposeTabPresentation(workspaceID: destination.workspaceID))
                    let evidence = GroupOrderSaveEvidence()
                    let replacement = UUID()
                    manager.setWorkspaceSavePreparationDidFinishHandlerForTesting { workspaceID, _, _ in
                        await MainActor.run {
                            guard workspaceID == destination.workspaceID, !evidence.didSuspend else { return }
                            evidence.didSuspend = true
                            if change == "scope" { caller.scopes.revoke(scopeID: granted.id) }
                            else {
                                let session = mirror.agentModeViewModel.session(for: destination.targetTab.id)
                                session.hasLoadedPersistedState = true
                                _ = mirror.agentModeViewModel.test_installPersistentSessionBinding(
                                    sessionID: replacement, on: session, updateWorkspaceMetadata: true
                                )
                            }
                        }
                    }
                    let reply = try await caller.call("reorder_groups", [
                        "workspace": .string(destination.workspaceID.uuidString), "scope_id": .string(granted.id.uuidString),
                        "order": .array([.string("Beta"), .string("Alpha")]),
                        "expected_order": .array([.string("Alpha"), .string("Beta")])
                    ])
                    manager.setWorkspaceSavePreparationDidFinishHandlerForTesting(nil)
                    XCTAssertTrue(evidence.didSuspend, "The production persistence suspension must be exercised")
                    XCTAssertEqual(reply["result"], .string("partial"), change)
                    XCTAssertEqual(reply[AgentSessionAdminRendering.committedChangesKey], .bool(true), change)
                    XCTAssertEqual(reply["changed_count"], .int(0), "An incomplete operation cannot claim fully applied targets")
                    let durableReadback = await manager.durableWorkspaceForMutationReadback(workspaceID: destination.workspaceID)
                    let durable = try XCTUnwrap(durableReadback)
                    XCTAssertEqual(durable.composeTabs.map(\.sidebarGroupOrder), [9, 4], "Never roll back the acknowledged canonical edit")
                    if change == "identity" {
                        XCTAssertEqual(mirror.agentModeViewModel.explicitActiveSessionID(for: destination.targetTab.id), replacement)
                        XCTAssertEqual(mirror.workspaceManager.activeWorkspace?.composeTabs.first { $0.id == destination.targetTab.id }?.sidebarGroupOrder, 9)
                        XCTAssertNil(reply["next_call"], "A changed carrier is not repaired by requesting scope")
                    }
                    await destination.removeReplica(mirror)
                    replica = nil
                    await destination.cleanup()
                    await caller.cleanup()
                } catch {
                    manager.setWorkspaceSavePreparationDidFinishHandlerForTesting(nil)
                    if let replica { await destination.removeReplica(replica) }
                    await destination.cleanup()
                    await caller.cleanup()
                    throw error
                }
            }
        }
    }

    func testConsolidatedRecoveryCopiesDoNotOwnSessionCarriersOrBlockOrganization() async throws {
        try await MCPSharedServerTestLease.shared.withLease { _ in
            let fixture = try await Fixture.make(isolated: true)
            do {
                let manager = fixture.window.workspaceManager
                let targetID = try XCTUnwrap(fixture.targetTab.activeAgentSessionID)
                let canonical = try fixture.workspace()
                // Exercise both persisted carrier collections with the same tab/session IDs.
                let recovery = WorkspaceModel(
                    name: "Consolidated recovery", repoPaths: canonical.repoPaths, ephemeralFlag: true,
                    isHiddenInMenus: true, consolidatedIntoWorkspaceID: canonical.id,
                    composeTabs: [fixture.targetTab], activeComposeTabID: fixture.targetTab.id,
                    stashedTabs: [StashedTab(tab: fixture.targetTab)]
                )
                manager.workspaces.insert(recovery, at: 0)

                @MainActor func assertCanonicalOwner(archived: Bool = false) {
                    let capture = AgentSessionCarrierResolver.capture(windows: [fixture.window], sessionIDs: [targetID])
                    XCTAssertTrue(capture.ambiguousSessionIDs.isEmpty)
                    XCTAssertTrue(capture.placementConflictSessionIDs.isEmpty)
                    XCTAssertEqual(capture.claimedWorkspaceIDs[targetID], [canonical.id])
                    XCTAssertEqual(capture.uniqueLocations[targetID]?.workspaceID, canonical.id)
                    XCTAssertEqual(manager.agentSessionLifecycleWorkspaceID(tabID: fixture.targetTab.id, sessionID: targetID), archived ? nil : canonical.id)
                    XCTAssertEqual(manager.sessionCarriers(sessionIDs: [targetID]).count, 1)
                }
                assertCanonicalOwner()
                // The structural delta path must not reinsert a recovery copy into the indexes.
                XCTAssertTrue(manager.replaceComposeTabCarriers(
                    workspaceID: recovery.id, composeTabs: recovery.composeTabs,
                    stashedTabs: recovery.stashedTabs + [StashedTab(tab: ComposeTabState(name: "Unrelated recovery tab", activeAgentSessionID: UUID()))]
                ))
                assertCanonicalOwner()
                let savedRecovery = try XCTUnwrap(manager.workspace(withID: recovery.id))
                try await fixture.assertReadTarget(name: "Target", pinned: false, loadedOnly: true)
                let rename = try await fixture.call("rename", ["name": .string("Recovered lane")])
                let pin = try await fixture.call("set_pin", ["pinned": .bool(true)])
                let group = try await fixture.call("set_group", ["group": .string("Recovered")])
                for reply in [rename, pin, group] {
                    XCTAssertEqual(reply["result"], .string("applied"))
                }
                try fixture.assertTarget(name: "Recovered lane", pinned: true, group: "Recovered")
                try await fixture.assertReadTarget(name: "Recovered lane", pinned: true, loadedOnly: true)
                let inventory = try await fixture.call("inventory", ["filter": .object(["pinned": .bool(true), "loaded": .bool(true)])])
                let row = try XCTUnwrap(inventory["sessions"]?.arrayValue?.compactMap(\.objectValue).first {
                    $0["session_id"] == .string(targetID.uuidString)
                })
                XCTAssertEqual(row["group"], .string("Recovered"))
                XCTAssertNil(inventory["unresolved_sessions"])
                let archive = try await fixture.call("archive", [:])
                XCTAssertEqual(archive["result"], .string("applied"))
                try await fixture.assertReadTarget(name: "Recovered lane", pinned: true, archived: true, loadedOnly: true)
                assertCanonicalOwner(archived: true)
                XCTAssertEqual(manager.workspace(withID: recovery.id), savedRecovery, "Organization must not mutate recovery data")
                await fixture.cleanup()
            } catch {
                await fixture.cleanup()
                throw error
            }
        }
    }

    func testResumeUsesCanonicalBindingDespiteConsolidatedRecoveryCopy() async throws {
        try await MCPSharedServerTestLease.shared.withLease { _ in
            let fixture = try await Fixture.make(isolated: true)
            do {
                let window = fixture.window
                let viewModel = window.agentModeViewModel
                let sessionID = try XCTUnwrap(fixture.targetTab.activeAgentSessionID)
                let session = viewModel.session(for: fixture.targetTab.id)
                session.hasLoadedPersistedState = true
                _ = try XCTUnwrap(viewModel.test_installPersistentSessionBinding(
                    sessionID: sessionID, on: session, updateWorkspaceMetadata: true
                ))
                session.recordRestorationAuthoritative(.persistedPayloadApplied)
                let canonical = try fixture.workspace()
                let recovery = WorkspaceModel(
                    name: "Resume recovery", repoPaths: [], ephemeralFlag: true,
                    isHiddenInMenus: true, consolidatedIntoWorkspaceID: canonical.id,
                    composeTabs: [fixture.targetTab], activeComposeTabID: fixture.targetTab.id
                )
                window.workspaceManager.workspaces.insert(recovery, at: 0)
                let service = AgentManageMCPToolService(
                    toolName: MCPWindowToolName.agentManage,
                    captureRequestMetadata: { .init(connectionID: UUID(), clientName: "recovery-resume", windowID: window.windowID) },
                    requireTargetWindow: { window }, resolveSpawnSourceTabID: { _ in nil },
                    resolveSpawnParentSessionID: { _, _ in nil }, bindCurrentRequestToTab: { _, _ in },
                    restrictDiscoveryToRoleLabels: { _ in false }
                )
                let reply = try await service.execute(args: ["op": .string("resume_session"), "session_id": .string(sessionID.uuidString)])
                XCTAssertEqual(reply.objectValue?["session_id"], .string(sessionID.uuidString))
                XCTAssertTrue(viewModel.session(for: fixture.targetTab.id, createIfNeeded: false) === session)
                XCTAssertEqual(session.mcpControlContext?.sessionID, sessionID)
                XCTAssertEqual(window.workspaceManager.workspace(withID: recovery.id), recovery)
                await fixture.cleanup()
            } catch {
                await fixture.cleanup()
                throw error
            }
        }
    }

    func testRealConflictsNameCarriersOnlyToCallersAllowedToSeeUnresolvedSessions() async throws {
        try await MCPSharedServerTestLease.shared.withLease { _ in
            let previousFullAccess = OverseerGlobalAutoApprove.isEnabled
            defer { OverseerGlobalAutoApprove.isEnabled = previousFullAccess }
            for sameSessionID in [true, false] {
                OverseerGlobalAutoApprove.isEnabled = { false }
                let fixture = try await Fixture.make(isolated: true)
                do {
                    let canonical = try fixture.workspace()
                    var duplicate = WorkspaceModel(
                        name: "Hidden conflicting workspace", repoPaths: canonical.repoPaths, ephemeralFlag: true,
                        isHiddenInMenus: true, composeTabs: [fixture.targetTab]
                    )
                    if !sameSessionID { duplicate.composeTabs[0].activeAgentSessionID = UUID() }
                    fixture.window.workspaceManager.workspaces.append(duplicate)
                    OverseerGlobalAutoApprove.isEnabled = { true }
                    let inventory = try await fixture.call("inventory", ["filter": .object(["loaded": .bool(true)])])
                    let unresolved = try XCTUnwrap(inventory["unresolved_sessions"]?.arrayValue?.first?.objectValue)
                    for reply in try await [
                        unresolved,
                        fixture.call("get", [:]),
                        fixture.call("set_pin", ["pinned": .bool(true), "preview": .bool(true)]),
                        fixture.call("rename", ["name": .string("Must not apply")])
                    ] {
                        XCTAssertEqual(reply["code"], .string("ambiguous_binding"))
                        let detail = try XCTUnwrap(reply["detail"]?.stringValue)
                        XCTAssertTrue(detail.contains(duplicate.name), detail)
                        XCTAssertTrue(detail.contains(canonical.id.uuidString), detail)
                        XCTAssertTrue(detail.contains(duplicate.id.uuidString), detail)
                        XCTAssertTrue(detail.contains(fixture.targetTab.id.uuidString), detail)
                    }
                    let unchanged = try fixture.workspace()
                    XCTAssertEqual(unchanged.composeTabs.first { $0.id == fixture.targetTab.id }, canonical.composeTabs.first { $0.id == fixture.targetTab.id })
                    XCTAssertEqual(unchanged.activeComposeTabID, canonical.activeComposeTabID)
                    XCTAssertEqual(fixture.window.workspaceManager.workspace(withID: duplicate.id), duplicate)
                    // Ambiguous workspace placement cannot authorize disclosure to a workspace scope.
                    OverseerGlobalAutoApprove.isEnabled = { false }
                    do {
                        _ = try await fixture.call("get", [:])
                        XCTFail("A restricted scope must not learn competing workspace identities")
                    } catch {
                        XCTAssertTrue("\(error)".contains("not available to this caller's scope"), "\(error)")
                        XCTAssertFalse("\(error)".contains(duplicate.name))
                    }
                    await fixture.cleanup()
                } catch {
                    await fixture.cleanup()
                    throw error
                }
            }
        }
    }

    func testRecoveryMarkerChangesRebuildOwnershipAndPreserveGenuineConflicts() async throws {
        try await withStopCarrierWindows(count: 1) { windows, canonical, tab, target in
            let window = try XCTUnwrap(windows.first)
            let manager = window.workspaceManager
            // Hidden alone does not revoke ownership.
            let duplicate = WorkspaceModel(
                name: "Real duplicate", repoPaths: canonical.repoPaths, ephemeralFlag: true,
                isHiddenInMenus: true, composeTabs: canonical.composeTabs, activeComposeTabID: canonical.activeComposeTabID
            )
            manager.workspaces.insert(duplicate, at: 0)
            @MainActor func capture() -> AgentSessionCarrierResolver.Snapshot {
                AgentSessionCarrierResolver.capture(windows: windows, sessionIDs: [target])
            }
            XCTAssertTrue(capture().ambiguousSessionIDs.contains(target))
            let index = try XCTUnwrap(manager.workspaces.firstIndex { $0.id == duplicate.id })
            manager.workspaces[index].consolidatedIntoWorkspaceID = canonical.id
            XCTAssertTrue(capture().ambiguousSessionIDs.isEmpty)
            XCTAssertEqual(capture().uniqueLocations[target]?.workspaceID, canonical.id)
            XCTAssertEqual(manager.agentSessionLifecycleWorkspaceID(tabID: tab.id, sessionID: target), canonical.id)
            manager.workspaces[index].consolidatedIntoWorkspaceID = nil
            XCTAssertTrue(capture().ambiguousSessionIDs.contains(target), "Restoring a copy restores its real conflict evidence")
            manager.workspaces[index].consolidatedIntoWorkspaceID = UUID() // Missing destination is still recovery provenance.
            manager.workspaces.removeAll { $0.id == canonical.id }
            XCTAssertTrue(manager.sessionCarriers(sessionIDs: [target], tabIDs: [tab.id]).isEmpty)
            XCTAssertNil(manager.agentSessionLifecycleWorkspaceID(tabID: tab.id, sessionID: target))
            XCTAssertNil(capture().uniqueLocations[target])
        }
    }

    func testRenamePinGroupAndUndoReachWorkspaceAndSidebarWithoutChangingSelection() async throws {
        try await MCPSharedServerTestLease.shared.withLease { _ in
            let fixture = try await Fixture.make()
            do {
                let rename = try await fixture.call("rename", ["name": .string("Organized lane")])
                try fixture.assertTarget(name: "Organized lane", pinned: false, group: nil)
                XCTAssertEqual(rename["result"], .string("applied"))
                let pin = try await fixture.call("set_pin", ["pinned": .bool(true)])
                let group = try await fixture.call("set_group", ["group": .string("Review")])
                try fixture.assertTarget(name: "Organized lane", pinned: true, group: "Review")

                // The actual workspace persistence payload must carry the same metadata, not just
                // a successful handler reply or an independently updated sidebar mock.
                let url = fixture.directory.appendingPathComponent("workspace.json")
                try JSONEncoder().encode(fixture.workspace()).write(to: url)
                let saved = try JSONDecoder().decode(WorkspaceModel.self, from: Data(contentsOf: url))
                let savedTab = try XCTUnwrap(saved.composeTabs.first { $0.id == fixture.targetTab.id })
                XCTAssertEqual(savedTab.name, "Organized lane")
                XCTAssertTrue(savedTab.isPinned)
                XCTAssertEqual(savedTab.sidebarGroup, "Review")

                _ = try await fixture.undo(group)
                _ = try await fixture.undo(pin)
                _ = try await fixture.undo(rename)
                try fixture.assertTarget(name: "Target", pinned: false, group: nil)
                await fixture.cleanup()
            } catch {
                await fixture.cleanup()
                throw error
            }
        }
    }

    func testRenameUndoPreservesLaterSidebarEditInsteadOfClobberingIt() async throws {
        try await MCPSharedServerTestLease.shared.withLease { _ in
            let fixture = try await Fixture.make()
            do {
                let rename = try await fixture.call("rename", ["name": .string("Agent title")])
                fixture.window.agentModeViewModel.renameSession(tabID: fixture.targetTab.id, to: "User title")
                let undo = try await fixture.undo(rename)
                let item = try XCTUnwrap(undo["items"]?.arrayValue?.first?.objectValue)
                XCTAssertEqual(item["status"], .string("skipped"))
                XCTAssertEqual(item["reason"], .string("changed_since"))
                XCTAssertEqual(undo["changed_count"], .int(0))
                XCTAssertEqual(undo["result"], .string("not_undone"))
                try fixture.assertTarget(name: "User title", pinned: false, group: nil)
                await fixture.cleanup()
            } catch {
                await fixture.cleanup()
                throw error
            }
        }
    }

    func testRenameOnlyAndRenameThenPinSurviveRealPersistenceReloadAndUndo() async throws {
        try await MCPSharedServerTestLease.shared.withLease { _ in
            for selectedTarget in [false, true] {
                for pinAfterRename in [false, true] {
                    let fixture = try await Fixture.make(ephemeral: false)
                    do {
                        let targetSession = fixture.window.agentModeViewModel.session(for: fixture.targetTab.id)
                        targetSession.hasLoadedPersistedState = true
                        _ = try XCTUnwrap(fixture.window.agentModeViewModel.test_installPersistentSessionBinding(
                            sessionID: fixture.targetTab.activeAgentSessionID, on: targetSession, updateWorkspaceMetadata: true
                        ))
                        var independent = ComposeTabState(name: "Independent user lane")
                        independent.promptText = "Unrelated user payload"
                        independent.isPinned = true
                        independent.sidebarGroup = "User group"
                        independent.sidebarGroupOrder = 7
                        let manager = fixture.window.workspaceManager
                        let index = try XCTUnwrap(manager.workspaces.firstIndex { $0.id == fixture.workspaceID })
                        manager.workspaces[index].composeTabs.append(independent)
                        try fixture.window.promptManager.loadComposeTabsFromWorkspace(fixture.workspace())
                        if selectedTarget { await fixture.window.promptManager.switchComposeTab(fixture.targetTab.id) }
                        let selectedID = selectedTarget ? fixture.targetTab.id : fixture.callerTab.id
                        XCTAssertEqual(fixture.window.promptManager.activeComposeTabID, selectedID)
                        let title = "Sequence renamed target"
                        let rename = try await fixture.call("rename", ["name": .string(title)])
                        XCTAssertEqual(rename["changed_count"], .int(1))
                        try fixture.assertTarget(name: title, pinned: false, group: nil, selectedTabID: selectedID)
                        // No sleep or save drain between the two commands: exercise the immediate
                        // rename→pin sequence before settling the actual workspace writer.
                        let pin = pinAfterRename ? try await fixture.call("set_pin", ["pinned": .bool(true)]) : nil
                        if let pin { XCTAssertEqual(pin["changed_count"], .int(1)) }
                        try fixture.assertTarget(name: title, pinned: pinAfterRename, group: nil, selectedTabID: selectedID)
                        // Read only after the immediate pair, so this does not hide a write race
                        // by inserting an inventory await between rename and pin.
                        try await fixture.assertReadTarget(name: title, pinned: pinAfterRename)
                        await manager.debugDrainScheduledSaves()
                        let persistence = await manager.pollAndSaveStateWithOutcomeAsync()
                        if case .rejected = persistence {
                            XCTFail("The persistent sequence must not reject its save, got \(persistence)")
                            await fixture.cleanup()
                            continue
                        }
                        // notRequired is legitimate after the queued save already committed. The
                        // attempt counter and decoded real file below prove this was not merely an
                        // ephemeral/manual JSON roundtrip.
                        XCTAssertGreaterThan(manager.workspaceSaveDiagnosticsForTesting(workspaceID: fixture.workspaceID).attemptCount, 0)
                        let url = try manager.workspaceFileURL(for: fixture.workspace())
                        let saved = try JSONDecoder().decode(WorkspaceModel.self, from: Data(contentsOf: url))
                        let savedTarget = try XCTUnwrap(saved.composeTabs.first { $0.id == fixture.targetTab.id })
                        XCTAssertEqual(savedTarget.name, title)
                        XCTAssertEqual(savedTarget.isPinned, pinAfterRename)
                        XCTAssertEqual(saved.composeTabs.first { $0.id == independent.id }, independent)
                        let currentIndex = try XCTUnwrap(manager.workspaces.firstIndex { $0.id == saved.id })
                        manager.workspaces[currentIndex] = saved
                        fixture.window.promptManager.loadComposeTabsFromWorkspace(saved, syncPromptText: true)
                        try fixture.assertTarget(name: title, pinned: pinAfterRename, group: nil, selectedTabID: selectedID)
                        try await fixture.assertReadTarget(name: title, pinned: pinAfterRename)
                        if let pin {
                            let undoPin = try await fixture.undo(pin)
                            XCTAssertEqual(undoPin["changed_count"], .int(1))
                            try fixture.assertTarget(name: title, pinned: false, group: nil, selectedTabID: selectedID)
                            try await fixture.assertReadTarget(name: title, pinned: false)
                        }
                        let undoRename = try await fixture.undo(rename)
                        XCTAssertEqual(undoRename["result"], .string("undone"))
                        XCTAssertEqual(undoRename["changed_count"], .int(1))
                        try fixture.assertTarget(name: "Target", pinned: false, group: nil, selectedTabID: selectedID)
                        try await fixture.assertReadTarget(name: "Target", pinned: false)
                        // A rendered row is insufficient: selecting the real runtime target and
                        // switching back must not republish the title/pin that was just undone.
                        await fixture.window.promptManager.switchComposeTab(fixture.targetTab.id)
                        try fixture.assertTarget(name: "Target", pinned: false, group: nil, selectedTabID: fixture.targetTab.id)
                        try await fixture.assertReadTarget(name: "Target", pinned: false)
                        if selectedID != fixture.targetTab.id {
                            await fixture.window.promptManager.switchComposeTab(selectedID)
                            try fixture.assertTarget(name: "Target", pinned: false, group: nil, selectedTabID: selectedID)
                            try await fixture.assertReadTarget(name: "Target", pinned: false)
                        }
                        XCTAssertEqual(try fixture.workspace().composeTabs.first { $0.id == independent.id }, independent)
                        await manager.debugDrainScheduledSaves()
                        // Scheduled saves finish at enqueue; the actual writer may still be
                        // coalescing that payload. Join durability before reading real bytes.
                        await WorkspaceDiskWriterComposition.processWriter.flush(url: url)
                        let final = try JSONDecoder().decode(WorkspaceModel.self, from: Data(contentsOf: url))
                        XCTAssertEqual(final.composeTabs.first { $0.id == fixture.targetTab.id }?.name, "Target")
                        XCTAssertEqual(final.composeTabs.first { $0.id == independent.id }, independent)
                        await fixture.cleanup()
                    } catch {
                        await fixture.cleanup()
                        throw error
                    }
                }
            }
        }
    }

    func testArchiveAndUndoMaintainOnlyTheAddressedWorkspaceCarrierIndexes() async throws {
        try await MCPSharedServerTestLease.shared.withLease { _ in
            var archiveVisits: [Int] = []
            var restoreVisits: [Int] = []
            for unrelatedCount in [0, 4000] {
                let fixture = try await Fixture.make()
                let manager = fixture.window.workspaceManager
                do {
                    let unrelated = WorkspaceModel(
                        name: "Unrelated retained carrier catalog", repoPaths: [], ephemeralFlag: true,
                        composeTabs: (0 ..< unrelatedCount).map {
                            ComposeTabState(name: "Unrelated \($0)", activeAgentSessionID: UUID())
                        }
                    )
                    manager.workspaces.append(unrelated)
                    // Fixture installation changes the active tab after workspace activation.
                    // Complete the real Chat owner before measuring archive; joining workspace
                    // saves alone does not join Oracle's queued active-tab initialization.
                    let oracle = fixture.window.oracleViewModel
                    XCTAssertEqual(fixture.window.promptManager.activeComposeTabID, fixture.callerTab.id)
                    let ensuredChatID = await oracle.ensureActiveSessionForCurrentTab(createIfMissing: true)
                    let callerChatID = try XCTUnwrap(ensuredChatID)
                    await manager.debugDrainScheduledSaves()
                    let callerChat = try XCTUnwrap(oracle.sessions.first { $0.id == callerChatID })
                    XCTAssertEqual(callerChat.workspaceID, fixture.workspaceID)
                    XCTAssertEqual(callerChat.composeTabID, fixture.callerTab.id)
                    XCTAssertEqual(oracle.currentSessionID, callerChatID)
                    XCTAssertEqual(fixture.window.promptManager.activeComposeTabID, fixture.callerTab.id)
                    let storedCaller = try XCTUnwrap(try fixture.workspace().composeTabs.first { $0.id == fixture.callerTab.id })
                    XCTAssertEqual(storedCaller.activeChatSessionID, callerChatID)
                    let rebuilds = manager.test_sessionCarrierIndexRebuildCount
                    manager.test_sessionCarrierIndexMaintenanceRowsVisited = 0
                    let archived = try await fixture.call("archive", [:])
                    XCTAssertEqual(archived["changed_count"], .int(1))
                    XCTAssertEqual(try fixture.workspace().stashedTabs.map(\.tab.id), [fixture.targetTab.id])
                    XCTAssertEqual(manager.activeChatSessionID(forTabID: fixture.callerTab.id), callerChatID)
                    XCTAssertEqual(manager.test_sessionCarrierIndexRebuildCount, rebuilds)
                    archiveVisits.append(manager.test_sessionCarrierIndexMaintenanceRowsVisited)
                    XCTAssertGreaterThan(archiveVisits.last ?? 0, 0, "Count actual index maintenance, not only an outer call")

                    manager.test_sessionCarrierIndexMaintenanceRowsVisited = 0
                    let restored = try await fixture.undo(archived)
                    XCTAssertEqual(restored["result"], .string("undone"))
                    XCTAssertEqual(restored["changed_count"], .int(1))
                    XCTAssertTrue(try fixture.workspace().stashedTabs.isEmpty)
                    try fixture.assertTarget(name: "Target", pinned: false, group: nil)
                    XCTAssertEqual(manager.activeChatSessionID(forTabID: fixture.callerTab.id), callerChatID)
                    XCTAssertEqual(manager.test_sessionCarrierIndexRebuildCount, rebuilds)
                    restoreVisits.append(manager.test_sessionCarrierIndexMaintenanceRowsVisited)
                    XCTAssertGreaterThan(restoreVisits.last ?? 0, 0)
                    XCTAssertEqual(manager.workspaces.first { $0.id == unrelated.id }, unrelated)
                    await fixture.cleanup()
                } catch {
                    await fixture.cleanup()
                    throw error
                }
            }
            XCTAssertEqual(archiveVisits.count, 2)
            XCTAssertEqual(restoreVisits.count, 2)
            XCTAssertEqual(archiveVisits.first, archiveVisits.last, "Unrelated retained tabs must not enter archive index maintenance")
            XCTAssertEqual(restoreVisits.first, restoreVisits.last, "Unrelated retained tabs must not enter unarchive index maintenance")
        }
    }

    func testWorkspaceCarrierDeltaMatchesFullRebuildForDuplicatesAndLifecycleFirstMatch() async throws {
        let window = WindowState()
        await window.workspaceManager.awaitInitialized()
        let manager = window.workspaceManager
        let target = ComposeTabState(name: "First exact claim", activeAgentSessionID: UUID())
        let firstDuplicate = ComposeTabState(name: "Duplicate tab A", activeAgentSessionID: UUID())
        var secondDuplicate = firstDuplicate
        secondDuplicate.activeAgentSessionID = UUID()
        secondDuplicate.name = "Duplicate tab B"
        let owner = WorkspaceModel(
            name: "Addressed owner", repoPaths: [], ephemeralFlag: true,
            composeTabs: [target, firstDuplicate, secondDuplicate], activeComposeTabID: firstDuplicate.id
        )
        let other = WorkspaceModel(
            name: "Later exact claim", repoPaths: [], ephemeralFlag: true,
            composeTabs: [target]
        )
        manager.workspaces = [owner, other]
        manager.activeWorkspace = owner
        let ids = Set([target, firstDuplicate, secondDuplicate].compactMap(\.activeAgentSessionID))
        let tabIDs = Set([target.id, firstDuplicate.id])
        let bindings = [target, firstDuplicate, secondDuplicate]
        let targetID = try XCTUnwrap(target.activeAgentSessionID)
        let stash = StashedTab(tab: target)
        XCTAssertTrue(manager.replaceComposeTabCarriers(
            workspaceID: owner.id, composeTabs: [firstDuplicate, secondDuplicate], stashedTabs: [stash]
        ))
        XCTAssertNil(manager.modelRoutingTab(workspaceID: owner.id, tabID: firstDuplicate.id))
        XCTAssertEqual(manager.sessionCarriers(sessionIDs: [targetID]).count, 2)
        XCTAssertEqual(manager.agentSessionLifecycleWorkspaceID(tabID: target.id, sessionID: targetID), other.id)
        assertCarrierIndexesMatchFullRebuild(manager, sessionIDs: ids, tabIDs: tabIDs, bindings: bindings)

        XCTAssertTrue(manager.replaceComposeTabCarriers(
            workspaceID: owner.id, composeTabs: [target, firstDuplicate, secondDuplicate], stashedTabs: []
        ))
        XCTAssertEqual(manager.agentSessionLifecycleWorkspaceID(tabID: target.id, sessionID: targetID), owner.id)
        assertCarrierIndexesMatchFullRebuild(manager, sessionIDs: ids, tabIDs: tabIDs, bindings: bindings)

        // Empty routing dictionaries require an explicit uniqueness check; absence of a fast
        // proof must not skip publication or silently retain stale positions.
        XCTAssertTrue(manager.replaceComposeTabCarriers(workspaceID: owner.id, composeTabs: [], stashedTabs: [stash]))
        let beforeEmptyRestore = manager.test_sessionCarrierIndexRebuildCount
        XCTAssertTrue(manager.replaceComposeTabCarriers(workspaceID: owner.id, composeTabs: [target], stashedTabs: []))
        XCTAssertEqual(manager.test_sessionCarrierIndexRebuildCount, beforeEmptyRestore)
        assertCarrierIndexesMatchFullRebuild(manager, sessionIDs: ids, tabIDs: tabIDs, bindings: bindings)

        var duplicateOwner = owner
        duplicateOwner.name = "Conflicting workspace identity"
        manager.workspaces.append(duplicateOwner)
        let beforeRefusal = manager.workspaces
        XCTAssertFalse(manager.replaceComposeTabCarriers(workspaceID: owner.id, composeTabs: [], stashedTabs: []))
        XCTAssertEqual(manager.workspaces, beforeRefusal)
        assertCarrierIndexesMatchFullRebuild(manager, sessionIDs: ids, tabIDs: tabIDs, bindings: bindings)
        await window.tearDown()
    }

    func testPublishedSubscriberReentryCannotBorrowCarrierPublicationProof() async {
        for outerMutation in ["carriers", "presentation", "selection", "storedOnly"] {
            let window = WindowState()
            await window.workspaceManager.awaitInitialized()
            let manager = window.workspaceManager
            let target = ComposeTabState(name: "Target", activeAgentSessionID: UUID())
            let sibling = ComposeTabState(name: "Sibling", activeAgentSessionID: UUID())
            let workspace = WorkspaceModel(
                name: "Publication owner", repoPaths: [], ephemeralFlag: true,
                composeTabs: [target, sibling], activeComposeTabID: target.id
            )
            let injected = ComposeTabState(name: "Nested generic claim", activeAgentSessionID: target.activeAgentSessionID)
            let replacement = WorkspaceModel(
                name: "Nested generic owner", repoPaths: [], ephemeralFlag: true,
                composeTabs: [injected]
            )
            manager.workspaces = [workspace]
            manager.activeWorkspace = workspace
            let rebuilds = manager.test_sessionCarrierIndexRebuildCount
            var armed = false
            var reentered = false
            // @Published sends synchronously before storage is installed, earlier than didSet
            // and the owner's manual notifications. This specifically exercises that boundary.
            let subscription = manager.$workspaces.sink { models in
                guard armed, !reentered else { return }
                reentered = true
                manager.workspaces = models + [replacement]
            }
            armed = true
            switch outerMutation {
            case "carriers":
                XCTAssertTrue(manager.replaceComposeTabCarriers(
                    workspaceID: workspace.id, composeTabs: [sibling], stashedTabs: [StashedTab(tab: target)]
                ))
            case "presentation":
                XCTAssertEqual(manager.updateComposeTabPresentation(workspaceID: workspace.id, tabIDs: [target.id]) { _, value in
                    value.name = "Renamed"
                }, [target.id])
            case "storedOnly":
                var updated = target
                updated.selection = StoredSelection(selectedPaths: ["/nested-selection"])
                XCTAssertTrue(manager.updateComposeTabStoredOnly(updated, inWorkspaceID: workspace.id))
            default:
                XCTAssertTrue(manager.updateActiveComposeTabSelection(workspaceID: workspace.id, activeComposeTabID: sibling.id))
            }
            subscription.cancel()
            XCTAssertTrue(reentered, outerMutation)
            XCTAssertGreaterThan(manager.test_sessionCarrierIndexRebuildCount, rebuilds, "A reentrant replacement requires the generic rebuild")
            assertCarrierIndexesMatchFullRebuild(
                manager, sessionIDs: Set([target, sibling].compactMap(\.activeAgentSessionID)),
                tabIDs: [target.id, sibling.id, injected.id], bindings: [target, sibling, injected]
            )
            await window.tearDown()
        }

        for reentry in ["tabReorder", "workspaceAndTabReorder", "removedTab", "removedWorkspace"] {
            let window = WindowState(automaticProviderModelDiscoveryEnabled: false)
            await window.workspaceManager.awaitInitialized()
            let manager = window.workspaceManager
            let target = ComposeTabState(name: "Revision target", activeAgentSessionID: UUID())
            let sibling = ComposeTabState(name: "Unchanged sibling", activeAgentSessionID: UUID())
            let workspace = WorkspaceModel(
                name: "Revision owner", repoPaths: [], ephemeralFlag: true,
                composeTabs: [target, sibling], activeComposeTabID: target.id
            )
            let otherTab = ComposeTabState(name: "Other workspace tab")
            let other = WorkspaceModel(name: "Other owner", repoPaths: [], ephemeralFlag: true, composeTabs: [otherTab])
            manager.workspaces = [workspace, other]
            manager.activeWorkspace = workspace
            let targetIdentity = WorkspaceSelectionIdentity(workspaceID: workspace.id, tabID: target.id)
            let siblingIdentity = WorkspaceSelectionIdentity(workspaceID: workspace.id, tabID: sibling.id)
            let targetRevision = manager.committedSelectionRevision(for: targetIdentity)
            let siblingRevision = manager.committedSelectionRevision(for: siblingIdentity)
            let otherRevision = manager.selectionRevisionForMCP(workspaceID: other.id, tabID: otherTab.id)
            var reentered = false
            // Chooser delivery runs after workspaces storage is installed, but before the
            // stored update records its selection revision. Reordering here must persist.
            let subscription = manager.$workspaceChooserPresentation.dropFirst().sink { _ in
                guard !reentered else { return }
                reentered = true
                var models = manager.workspaces
                switch reentry {
                case "tabReorder":
                    models[0].composeTabs.reverse()
                case "workspaceAndTabReorder":
                    models[0].composeTabs.reverse()
                    models.reverse()
                case "removedTab":
                    models[0].composeTabs.removeAll { $0.id == target.id }
                default:
                    models.removeAll { $0.id == workspace.id }
                }
                manager.workspaces = models
            }
            var updated = target
            updated.selection = StoredSelection(selectedPaths: ["/reentrant-selection"])
            XCTAssertTrue(manager.updateComposeTabStoredOnly(updated, inWorkspaceID: workspace.id), reentry)
            subscription.cancel()
            XCTAssertTrue(reentered, reentry)
            if reentry == "tabReorder" || reentry == "workspaceAndTabReorder" {
                XCTAssertEqual(manager.workspaces.first { $0.id == workspace.id }?.composeTabs.map(\.id), [sibling.id, target.id], reentry)
                if reentry == "workspaceAndTabReorder" {
                    XCTAssertEqual(manager.workspaces.map(\.id), [other.id, workspace.id], reentry)
                }
                XCTAssertGreaterThan(manager.committedSelectionRevision(for: targetIdentity), targetRevision, reentry)
                XCTAssertEqual(manager.composeTab(for: targetIdentity)?.selection, updated.selection, reentry)
                XCTAssertEqual(manager.composeTab(for: siblingIdentity)?.selection, sibling.selection, reentry)
            } else {
                XCTAssertNil(manager.composeTab(for: targetIdentity), reentry)
                XCTAssertEqual(manager.committedSelectionRevision(for: targetIdentity), targetRevision, reentry)
            }
            XCTAssertEqual(manager.committedSelectionRevision(for: siblingIdentity), siblingRevision, reentry)
            XCTAssertEqual(manager.selectionRevisionForMCP(workspaceID: other.id, tabID: otherTab.id), otherRevision, reentry)
            await window.tearDown()
        }
    }

    private struct CarrierIndexRow: Equatable {
        let workspaceID: UUID
        let tab: ComposeTabState
        let stashedTabID: UUID?
    }

    private struct CarrierIndexEvidence: Equatable {
        let carriers: [CarrierIndexRow]
        let routed: [UUID: ComposeTabState]
        let lifecycleWorkspaces: [UUID?]
        let lifecycleTabs: [[ComposeTabState]]
    }

    private func assertCarrierIndexesMatchFullRebuild(
        _ manager: WorkspaceManagerViewModel, sessionIDs: Set<UUID>, tabIDs: Set<UUID>, bindings: [ComposeTabState],
        file: StaticString = #filePath, line: UInt = #line
    ) {
        func capture() -> CarrierIndexEvidence {
            let workspaceID = manager.activeWorkspaceID!
            return CarrierIndexEvidence(
                carriers: manager.sessionCarriers(sessionIDs: sessionIDs, tabIDs: tabIDs).map {
                    CarrierIndexRow(workspaceID: $0.workspaceID, tab: $0.tab, stashedTabID: $0.stashedTabID)
                },
                routed: Dictionary(uniqueKeysWithValues: tabIDs.compactMap { id in
                    manager.modelRoutingTab(workspaceID: workspaceID, tabID: id).map { (id, $0) }
                }),
                lifecycleWorkspaces: bindings.map { tab in
                    tab.activeAgentSessionID.flatMap { manager.agentSessionLifecycleWorkspaceID(tabID: tab.id, sessionID: $0) }
                },
                lifecycleTabs: sessionIDs.sorted { $0.uuidString < $1.uuidString }.map {
                    manager.agentSessionLifecycleTabs(workspaceID: workspaceID, sessionID: $0)
                }
            )
        }
        let incremental = capture()
        let unchangedModels = manager.workspaces
        manager.workspaces = unchangedModels
        XCTAssertEqual(capture(), incremental, "Incremental indexes must preserve every full-rebuild claim and duplicate rule", file: file, line: line)
    }

    func testArchiveUndoRestoresSidebarCarrierWithoutSelectingTheTarget() async throws {
        try await MCPSharedServerTestLease.shared.withLease { _ in
            let fixture = try await Fixture.make(ephemeral: false)
            let manager = fixture.window.workspaceManager
            let gate = UnarchiveSaveGate()
            defer {
                gate.resume()
                manager.setWorkspaceSavePreparationDidFinishHandlerForTesting(nil)
            }
            do {
                let archived = try await fixture.call("archive", [:])
                XCTAssertEqual(archived["changed_count"], .int(1))
                let workspace = try fixture.workspace()
                XCTAssertFalse(workspace.composeTabs.contains { $0.id == fixture.targetTab.id })
                XCTAssertEqual(workspace.stashedTabs.map(\.tab.id), [fixture.targetTab.id])
                XCTAssertFalse(
                    fixture.window.agentModeViewModel.sidebarSessions(for: fixture.window.promptManager.currentComposeTabs)
                        .contains { $0.sessionID == fixture.targetTab.activeAgentSessionID }
                )
                XCTAssertEqual(workspace.activeComposeTabID, fixture.callerTab.id)
                try await fixture.assertReadTarget(name: "Target", pinned: false, archived: true)
                manager.setWorkspaceSavePreparationDidFinishHandlerForTesting { workspaceID, _, _ in
                    let restoring = await MainActor.run {
                        workspaceID == fixture.workspaceID
                            && manager.modelRoutingTab(workspaceID: workspaceID, tabID: fixture.targetTab.id) != nil
                    }
                    if restoring { await gate.hold() }
                }
                var completed = false
                let undoTask = Task { @MainActor in
                    defer { completed = true }
                    return try await fixture.undo(archived)
                }
                await fulfillment(of: [gate.entered], timeout: 10)
                XCTAssertFalse(completed, "A local sidebar restore must not complete its reply while the owning save is held")
                XCTAssertTrue(try fixture.workspace().composeTabs.contains { $0.id == fixture.targetTab.id })
                gate.resume()
                let undone = try await undoTask.value
                manager.setWorkspaceSavePreparationDidFinishHandlerForTesting(nil)
                XCTAssertEqual(undone["result"], .string("undone"))
                XCTAssertEqual(undone["changed_count"], .int(1))
                XCTAssertTrue(try fixture.workspace().stashedTabs.isEmpty)
                try fixture.assertTarget(name: "Target", pinned: false, group: nil)
                // The public reply itself is the completion fence: no caller poll or queue drain
                // may be required before this first read of the durable workspace and exact get.
                let url = try manager.workspaceFileURL(for: fixture.workspace())
                let saved = try JSONDecoder().decode(WorkspaceModel.self, from: Data(contentsOf: url))
                XCTAssertTrue(saved.composeTabs.contains { $0.id == fixture.targetTab.id })
                XCTAssertFalse(saved.stashedTabs.contains { $0.tab.id == fixture.targetTab.id })
                try await fixture.assertReadTarget(name: "Target", pinned: false)
                await manager.debugDrainScheduledSaves()
                let afterPending = try JSONDecoder().decode(WorkspaceModel.self, from: Data(contentsOf: url))
                XCTAssertTrue(afterPending.composeTabs.contains { $0.id == fixture.targetTab.id })
                XCTAssertFalse(afterPending.stashedTabs.contains { $0.tab.id == fixture.targetTab.id })
                try await fixture.assertReadTarget(name: "Target", pinned: false)
                await fixture.cleanup()
            } catch {
                gate.resume()
                manager.setWorkspaceSavePreparationDidFinishHandlerForTesting(nil)
                await fixture.cleanup()
                throw error
            }
        }
    }

    func testArchiveUndoReportsLocalRestoreWithoutClaimingPersistenceAfterSaveRejection() async throws {
        try await MCPSharedServerTestLease.shared.withLease { _ in
            let fixture = try await Fixture.make(ephemeral: false)
            let manager = fixture.window.workspaceManager
            defer { manager.setWorkspacePersistenceOutcomeOverrideForTesting(nil) }
            do {
                let archived = try await fixture.call("archive", [:])
                XCTAssertEqual(archived["changed_count"], .int(1))
                manager.setWorkspacePersistenceOutcomeOverrideForTesting(.rejected(reason: "unarchive_fixture_disk_failure"))
                let undone = try await fixture.undo(archived)
                // The tab is restored on screen, so "not_undone" would wrongly say it is still
                // archived. The local effect is reported; persistence is explicitly not claimed.
                XCTAssertEqual(undone["result"], .string("partially_undone"))
                XCTAssertEqual(undone["changed_count"], .int(0))
                XCTAssertEqual(undone["local_changes"], .bool(true))
                XCTAssertNotEqual(undone[AgentSessionAdminRendering.committedChangesKey], .bool(true))
                let item = try XCTUnwrap(undone["items"]?.arrayValue?.first?.objectValue)
                XCTAssertEqual(item["status"], .string("failed"))
                XCTAssertEqual(item["reason"], .string("persistence_rejected"))
                XCTAssertEqual(item["local_changes"], .bool(true))
                XCTAssertEqual(item["persistence_confirmed"], .bool(false))
                XCTAssertTrue(try fixture.workspace().composeTabs.contains { $0.id == fixture.targetTab.id }, "Do not roll back a local effect after losing persistence proof")
                manager.setWorkspacePersistenceOutcomeOverrideForTesting(nil)
                await fixture.cleanup()
            } catch {
                manager.setWorkspacePersistenceOutcomeOverrideForTesting(nil)
                await fixture.cleanup()
                throw error
            }
        }
    }

    func testUnarchiveDoesNotClaimSuccessWhenBeforeSaveRestashesTheCarrier() async throws {
        try await MCPSharedServerTestLease.shared.withLease { _ in
            let fixture = try await Fixture.make(ephemeral: false)
            let manager = fixture.window.workspaceManager
            var listenerID: UUID?
            do {
                let archived = try await fixture.call("archive", [:])
                XCTAssertEqual(archived["changed_count"], .int(1))
                let stash = try XCTUnwrap(fixture.workspace().stashedTabs.first { $0.tab.id == fixture.targetTab.id })
                var restashed = false
                listenerID = manager.addBeforeSaveListener { workspace in
                    guard !restashed, workspace.id == fixture.workspaceID,
                          workspace.composeTabs.contains(where: { $0.id == fixture.targetTab.id }),
                          let index = manager.workspaces.firstIndex(where: { $0.id == workspace.id })
                    else { return }
                    restashed = true
                    manager.workspaces[index].composeTabs.removeAll { $0.id == fixture.targetTab.id }
                    manager.workspaces[index].stashedTabs.append(stash)
                    fixture.window.promptManager.loadComposeTabsFromWorkspace(manager.workspaces[index])
                    manager.markWorkspaceDirty()
                }
                let reply = try await fixture.call("unarchive", [:])
                XCTAssertTrue(restashed)
                XCTAssertEqual(reply["result"], .string("partial"))
                XCTAssertEqual(reply["changed_count"], .int(0))
                XCTAssertNil(reply["undo_token"], "An unconfirmed restore must not issue an inverse archive token")
                let item = try XCTUnwrap(reply["items"]?.arrayValue?.first?.objectValue)
                XCTAssertEqual(item["reason"], .string("persistence_unconfirmed"))
                XCTAssertEqual(item["local_changes"], .bool(true))
                XCTAssertEqual(item["persistence_confirmed"], .bool(false))
                try await fixture.assertReadTarget(name: "Target", pinned: false, archived: true)
                if let listenerID { manager.removeBeforeSaveListener(listenerID) }
                await fixture.cleanup()
            } catch {
                if let listenerID { manager.removeBeforeSaveListener(listenerID) }
                await fixture.cleanup()
                throw error
            }
        }
    }

    func testArchiveUndoPreservesCommittedRestoreReceiptWhenScopeExpiresDuringSave() async throws {
        try await MCPSharedServerTestLease.shared.withLease { _ in
            let fixture = try await Fixture.make(ephemeral: false)
            let manager = fixture.window.workspaceManager
            defer { manager.setWorkspaceSavePreparationDidFinishHandlerForTesting(nil) }
            do {
                let archived = try await fixture.call("archive", [:])
                XCTAssertEqual(archived["changed_count"], .int(1))
                let scopeIDs = fixture.scopes.liveScopes(grantedTo: fixture.callerTab.activeAgentSessionID!).map(\.id)
                XCTAssertFalse(scopeIDs.isEmpty)
                manager.setWorkspaceSavePreparationDidFinishHandlerForTesting { workspaceID, _, _ in
                    await MainActor.run {
                        guard workspaceID == fixture.workspaceID,
                              manager.modelRoutingTab(workspaceID: workspaceID, tabID: fixture.targetTab.id) != nil
                        else { return }
                        for id in scopeIDs where fixture.scopes.record(id: id)?.isActive == true {
                            fixture.scopes.revoke(scopeID: id)
                        }
                    }
                }
                let reply = try await fixture.undo(archived)
                manager.setWorkspaceSavePreparationDidFinishHandlerForTesting(nil)
                XCTAssertTrue(scopeIDs.allSatisfy { fixture.scopes.record(id: $0)?.state == .revoked })
                XCTAssertEqual(reply["result"], .string("partially_undone"))
                XCTAssertEqual(reply["changed_count"], .int(0))
                XCTAssertEqual(reply[AgentSessionAdminRendering.committedChangesKey], .bool(true))
                let item = try XCTUnwrap(reply["items"]?.arrayValue?.first?.objectValue)
                XCTAssertEqual(item["reason"], .string("scope_no_longer_current"))
                XCTAssertEqual(item["persistence_confirmed"], .bool(true))
                try fixture.assertTarget(name: "Target", pinned: false, group: nil)
                let durable = await manager.durableWorkspaceForMutationReadback(workspaceID: fixture.workspaceID)
                XCTAssertTrue(try XCTUnwrap(durable).composeTabs.contains { $0.id == fixture.targetTab.id })
                await fixture.cleanup()
            } catch {
                manager.setWorkspaceSavePreparationDidFinishHandlerForTesting(nil)
                await fixture.cleanup()
                throw error
            }
        }
    }

    @MainActor
    private final class UnarchiveSaveGate {
        let entered = XCTestExpectation(description: "unarchive owner save is held")
        private var didEnter = false
        private var released = false
        private var continuations: [CheckedContinuation<Void, Never>] = []

        func hold() async {
            guard !released else { return }
            if !didEnter {
                didEnter = true
                entered.fulfill()
            }
            await withCheckedContinuation { continuations.append($0) }
        }

        func resume() {
            released = true
            let pending = continuations
            continuations.removeAll()
            for continuation in pending {
                continuation.resume()
            }
        }
    }

    func testArchiveCannotStashAReplacementBoundToTheCapturedTabDuringPreflight() async throws {
        try await MCPSharedServerTestLease.shared.withLease { _ in
            let fixture = try await Fixture.make()
            do {
                let replacement = UUID()
                var prepared = false
                let token = fixture.window.promptManager.setComposeTabsRemovalPreflight { tabs, _, workspaceID in
                    XCTAssertEqual(tabs, [fixture.targetTab.id])
                    XCTAssertEqual(workspaceID, fixture.workspaceID)
                    guard let workspaceIndex = fixture.window.workspaceManager.workspaces.firstIndex(where: { $0.id == workspaceID }),
                          let tabIndex = fixture.window.workspaceManager.workspaces[workspaceIndex].composeTabs.firstIndex(where: { $0.id == fixture.targetTab.id })
                    else { return .proceed }
                    // The target is unloaded: no live TabSession claim can protect this carrier.
                    fixture.window.workspaceManager.workspaces[workspaceIndex].composeTabs[tabIndex].activeAgentSessionID = replacement
                    prepared = true
                    await Task.yield()
                    return .proceed
                }
                let reply = try await fixture.call("archive", [:])
                fixture.window.promptManager.removeComposeTabsRemovalPreflight(token)
                XCTAssertTrue(prepared)
                XCTAssertEqual(reply["changed_count"], .int(0))
                let workspace = try fixture.workspace()
                XCTAssertTrue(workspace.stashedTabs.isEmpty)
                XCTAssertEqual(workspace.composeTabs.first { $0.id == fixture.targetTab.id }?.activeAgentSessionID, replacement)
                XCTAssertEqual(workspace.activeComposeTabID, fixture.callerTab.id)
                await fixture.cleanup()
            } catch {
                await fixture.cleanup()
                throw error
            }
        }
    }

    func testGroupAndUnarchiveOnAnotherTabPreserveAndCaptureTheActiveUserDraft() async throws {
        try await MCPSharedServerTestLease.shared.withLease { _ in
            for op in ["set_group", "unarchive"] {
                let fixture = try await Fixture.make()
                var listenerID: UUID?
                var flushObserver: NSObjectProtocol?
                do {
                    if op == "unarchive" { _ = try await fixture.call("archive", [:]) }
                    let old = try XCTUnwrap(fixture.workspace().composeTabs.first { $0.id == fixture.callerTab.id })
                    let draft = "Unsaved user draft during \(op)"
                    fixture.window.promptManager.promptText = draft
                    fixture.window.promptManager.testSetDirtyTabIDs([fixture.callerTab.id])
                    XCTAssertNotEqual(old.promptText, draft)
                    let evidence = DraftCaptureEvidence()
                    // Both are synchronous pre-capture boundaries. A direct UI flush may capture
                    // the draft before a later save clears dirty state; neither path may erase it.
                    flushObserver = NotificationCenter.default.addObserver(
                        forName: .willSwitchComposeTab, object: nil, queue: nil
                    ) { notification in
                        MainActor.assumeIsolated {
                            guard notification.userInfo?["windowID"] as? Int == fixture.window.windowID else { return }
                            if fixture.window.promptManager.promptText == draft,
                               fixture.window.promptManager.isTabDirty(fixture.callerTab),
                               fixture.window.promptManager.activeComposeTabID == fixture.callerTab.id
                            {
                                evidence.observedDirtyDraftBeforeCapture = true
                            }
                        }
                    }
                    listenerID = fixture.window.workspaceManager.addBeforeSaveListener { workspace in
                        guard workspace.id == fixture.workspaceID else { return }
                        if fixture.window.promptManager.promptText == draft,
                           fixture.window.promptManager.isTabDirty(fixture.callerTab),
                           fixture.window.promptManager.activeComposeTabID == fixture.callerTab.id
                        {
                            evidence.observedDirtyDraftBeforeCapture = true
                        }
                    }
                    fixture.beforeCallerResolution = {
                        XCTAssertEqual(
                            fixture.window.promptManager.promptText,
                            draft,
                            "The live draft must reach the command entry before any organizer mutation"
                        )
                        XCTAssertEqual(fixture.window.promptManager.activeComposeTabID, fixture.callerTab.id)
                    }
                    let reply = try await fixture.call(op, op == "set_group" ? ["group": .string("Draft-safe")] : [:])
                    XCTAssertEqual(reply["result"], .string("applied"), op)
                    XCTAssertEqual(reply["changed_count"], .int(1), op)
                    XCTAssertTrue(evidence.observedDirtyDraftBeforeCapture, "\(op) must not erase dirty state before editor/save capture")
                    XCTAssertEqual(fixture.window.promptManager.promptText, draft, op)
                    let workspace = try fixture.workspace()
                    XCTAssertEqual(workspace.activeComposeTabID, fixture.callerTab.id, op)
                    XCTAssertEqual(fixture.window.promptManager.activeComposeTabID, fixture.callerTab.id, op)
                    XCTAssertEqual(workspace.composeTabs.first { $0.id == fixture.callerTab.id }?.promptText, draft, op)
                    let encoded = try JSONEncoder().encode(workspace)
                    let saved = try JSONDecoder().decode(WorkspaceModel.self, from: encoded)
                    XCTAssertEqual(saved.composeTabs.first { $0.id == fixture.callerTab.id }?.promptText, draft, op)
                    // A subsequent normal dirty-state update may clear the flag once the draft has
                    // been captured. Its earlier preservation, not perpetual dirtiness, is required.
                    if let listenerID { fixture.window.workspaceManager.removeBeforeSaveListener(listenerID) }
                    if let flushObserver { NotificationCenter.default.removeObserver(flushObserver) }
                    await fixture.cleanup()
                } catch {
                    if let listenerID { fixture.window.workspaceManager.removeBeforeSaveListener(listenerID) }
                    if let flushObserver { NotificationCenter.default.removeObserver(flushObserver) }
                    await fixture.cleanup()
                    throw error
                }
            }
        }
    }

    @MainActor
    private final class GroupOrderSaveEvidence {
        var didSuspend = false
    }

    @MainActor
    private final class DraftCaptureEvidence {
        var observedDirtyDraftBeforeCapture = false
    }

    @MainActor
    private final class Fixture {
        let window: WindowState
        let directory: URL
        let runtime: MCPDomainRuntime?
        let callerTab = ComposeTabState(name: "Overseer", activeAgentSessionID: UUID())
        let targetTab = ComposeTabState(name: "Target", activeAgentSessionID: UUID())
        let scopes = DelegationScopeRuntime(persistenceMode: .ephemeral)
        let ownership = WorktreeOwnershipStore()
        var workspaceID: UUID!
        var frontDoor: AgentSessionAdministrationFrontDoor!
        var beforeCallerResolution: (@MainActor () -> Void)?
        var ingress: SessionContractHost?

        func enableCanonicalHost() async throws {
            let host = SessionContractHost(windowID: window.windowID)
            ingress = host
            try await host.start([
                MCPDomainToolBinding(definition: MCPDomainSessionAdminToolDefinition.definition) { arguments in
                    try await self.execute(arguments)
                }
            ])
        }

        private init(window: WindowState, directory: URL, runtime: MCPDomainRuntime? = nil) {
            self.window = window
            self.directory = directory
            self.runtime = runtime
        }

        static func make(ephemeral: Bool = true, isolated: Bool = false, runtimeBacked: Bool = false) async throws -> Fixture {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("session-admin-production-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let runtime: MCPDomainRuntime?
            if runtimeBacked {
                let authority = MCPDomainRuntime(configuration: .init(
                    mode: .app, profileIdentifier: "group-order",
                    storageDirectory: directory.appendingPathComponent("authority", isDirectory: true),
                    workspaceStorageDirectory: directory.appendingPathComponent("storage", isDirectory: true),
                    eventDirectory: directory.appendingPathComponent("events", isDirectory: true),
                    temporaryDirectory: directory.appendingPathComponent("tmp", isDirectory: true),
                    externalReloadInterval: nil
                ))
                try await authority.start()
                runtime = authority
            } else { runtime = nil }
            let window = runtime.map { WindowState(domainRuntime: $0) } ?? WindowState()
            let fixture = Fixture(window: window, directory: directory, runtime: runtime)
            WindowStatesManager.shared.registerWindowState(window)
            do {
                await window.workspaceManager.awaitInitialized()
                var workspace = isolated || runtimeBacked
                    ? WorkspaceModel(name: "Isolated organizer journey", repoPaths: [], ephemeralFlag: isolated || ephemeral)
                    : window.workspaceManager.createWorkspace(name: "Organizer journey", repoPaths: [], ephemeral: ephemeral)
                workspace.customStoragePath = directory
                workspace.composeTabs = [fixture.callerTab, fixture.targetTab]
                workspace.activeComposeTabID = fixture.callerTab.id
                fixture.workspaceID = workspace.id
                if let runtime {
                    // Establish the exact path and carrier document in the real authority before
                    // adopting it. A local assignment or a learned revision is not a write witness.
                    let client = DomainWorkspaceAuthorityClient(store: runtime.workspaceStore, windowID: window.windowID)
                    let created = try await client.create(workspace, fileURL: window.workspaceManager.workspaceFileURL(for: workspace))
                    XCTAssertEqual(created.disposition, .applied)
                    let bridge = try XCTUnwrap(window.domainWorkspacePresentationBridgeForTesting)
                    let refreshed = await bridge.refreshForAgentAdmission()
                    XCTAssertTrue(refreshed)
                    let canonical = try XCTUnwrap(window.workspaceManager.workspace(withID: workspace.id))
                    _ = await window.workspaceManager.switchWorkspace(to: canonical, saveState: false, reason: "groupOrderAuthorityFixture")
                    // The switch starts a disk session-list refresh for this owner. Let it settle before the
                    // synthetic index below is installed, or its empty on-disk result replaces those entries
                    // and every carrier correctly fails closed as unproven placement.
                    await window.agentModeViewModel.test_waitForSessionListCacheRefresh()
                    XCTAssertEqual(window.workspaceManager.activeWorkspaceID, workspace.id)
                    XCTAssertTrue(window.workspaceManager.canCommitComposeTabPresentation(workspaceID: workspace.id))
                } else if isolated {
                    window.workspaceManager.workspaces = [workspace]
                    window.workspaceManager.activeWorkspace = workspace
                } else {
                    let switched = await window.workspaceManager.reactivateWorkspaceAfterReplacement(
                        workspace, reason: "sessionAdminProductionJourney"
                    )
                    XCTAssertEqual(switched, .switched)
                }
                // Activation resolves the manager's canonical workspace, not every field of the
                // caller's local replacement. Install the actual carriers only after it settles.
                var current = try fixture.workspace()
                XCTAssertEqual(current.id, workspace.id)
                current.customStoragePath = directory
                current.composeTabs = [fixture.callerTab, fixture.targetTab]
                current.stashedTabs = []
                current.activeComposeTabID = fixture.callerTab.id
                let position = try XCTUnwrap(window.workspaceManager.workspaces.firstIndex { $0.id == current.id })
                window.workspaceManager.workspaces[position] = current
                let installed = try fixture.workspace()
                XCTAssertEqual(installed.composeTabs.map(\.id), [fixture.callerTab.id, fixture.targetTab.id])
                XCTAssertEqual(
                    installed.composeTabs.map(\.activeAgentSessionID),
                    [fixture.callerTab.activeAgentSessionID, fixture.targetTab.activeAgentSessionID]
                )
                XCTAssertTrue(installed.stashedTabs.isEmpty)
                XCTAssertEqual(installed.activeComposeTabID, fixture.callerTab.id)
                window.promptManager.loadComposeTabsFromWorkspace(installed, syncPromptText: true)
                XCTAssertEqual(window.promptManager.currentComposeTabs.map(\.id), [fixture.callerTab.id, fixture.targetTab.id])
                XCTAssertEqual(window.promptManager.activeComposeTabID, fixture.callerTab.id)
                let owner = AgentModeViewModel.SessionIndexOwner(workspaceID: workspace.id, activationEpoch: 1)
                let entries = [fixture.callerTab, fixture.targetTab].map { tab in
                    AgentSessionIndexEntry(
                        id: tab.activeAgentSessionID!, tabID: tab.id, name: tab.name,
                        savedAt: Date(timeIntervalSince1970: 0), itemCount: 0, autoEditEnabled: false,
                        hasUnknownConversationContent: false, isMCPOriginated: false,
                        worktreeBindingSummaries: [], activeWorktreeMergeSummaries: []
                    )
                }
                try window.agentModeViewModel.test_installSessionIndexSnapshot(
                    Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) }),
                    owner: owner, latestOwner: owner, activeWorkspace: fixture.workspace()
                )
                let caller = window.agentModeViewModel.session(for: fixture.callerTab.id)
                caller.hasLoadedPersistedState = true
                _ = try XCTUnwrap(window.agentModeViewModel.test_installPersistentSessionBinding(
                    sessionID: fixture.callerTab.activeAgentSessionID, on: caller, updateWorkspaceMetadata: true
                ))
                _ = try AgentSessionLinkEndpointTestSupport.endpoint(window.agentModeViewModel, tabID: fixture.callerTab.id)
                let ready = try fixture.workspace()
                for expected in [fixture.callerTab, fixture.targetTab] {
                    let carrier = try XCTUnwrap(ready.composeTabs.first { $0.id == expected.id })
                    XCTAssertEqual(carrier.activeAgentSessionID, expected.activeAgentSessionID)
                }
                XCTAssertEqual(ready.activeComposeTabID, fixture.callerTab.id)
                XCTAssertEqual(
                    window.agentModeViewModel.explicitActiveSessionID(for: fixture.callerTab.id),
                    fixture.callerTab.activeAgentSessionID
                )
                let core = AgentSessionAdministrationCore.makeProduction(scopes: fixture.scopes, worktreeOwnership: fixture.ownership)
                // This fixture owns one custom storage directory, including its ephemeral form.
                // Do not introduce a global runtime into the production organizer journey.
                let location = HistoryWorkspaceLocation(
                    runtimeID: UUID(), workspaceID: ready.id, name: ready.name, directory: directory
                )
                let locations = HistoryWorkspaceLocationResolver(resolve: { selector in
                    switch selector {
                    case let .id(id) where id == location.workspaceID:
                        .matched(location)
                    case let .exactName(name) where name == location.name:
                        .matched(location)
                    default:
                        .notRegistered
                    }
                })
                fixture.frontDoor = AgentSessionAdministrationFrontDoor.production(
                    core: core, scopes: fixture.scopes, workspaceLocations: locations
                )
                if !OverseerGlobalAutoApprove.isEnabled() {
                    let requested = try fixture.scopes.requestScope(
                        requesterSessionID: fixture.callerTab.activeAgentSessionID!, requesterTabID: fixture.callerTab.id,
                        kind: .workspace(workspaceID: workspace.id), capabilities: [.observe, .organize],
                        guardrails: .init(), reason: nil, idempotencyKey: nil
                    ).get()
                    _ = try fixture.scopes.approve(requestID: requested.id).get()
                }
                return fixture
            } catch {
                await fixture.cleanup()
                throw error
            }
        }

        func workspace() throws -> WorkspaceModel {
            try XCTUnwrap(window.workspaceManager.activeWorkspace)
        }

        func installGroups(in targetWindow: WindowState? = nil, alphaOrder: Int = 4, betaOrder: Int = 9) {
            let targetWindow = targetWindow ?? window
            _ = targetWindow.workspaceManager.updateComposeTabPresentation(
                workspaceID: workspaceID, tabIDs: [callerTab.id, targetTab.id]
            ) { id, tab in
                tab.sidebarGroup = id == self.callerTab.id ? "Alpha" : "Beta"
                tab.sidebarGroupOrder = id == self.callerTab.id ? alphaOrder : betaOrder
            }
            if let workspace = targetWindow.workspaceManager.activeWorkspace { targetWindow.promptManager.loadComposeTabsFromWorkspace(workspace) }
        }

        func addReplica() async throws -> WindowState {
            let replica = WindowState()
            await replica.workspaceManager.awaitInitialized()
            let workspace = try workspace()
            replica.workspaceManager.workspaces = [workspace]
            replica.workspaceManager.activeWorkspace = workspace
            replica.promptManager.loadComposeTabsFromWorkspace(workspace)
            for tabID in Array(replica.agentModeViewModel.sessions.keys) {
                replica.agentModeViewModel.test_removeSession(tabID: tabID)
            }
            let owner = AgentModeViewModel.SessionIndexOwner(workspaceID: workspace.id, activationEpoch: 1)
            replica.agentModeViewModel.test_installSessionIndexSnapshot(
                window.agentModeViewModel.ownerValidatedSessionIndex, owner: owner, latestOwner: owner, activeWorkspace: workspace
            )
            WindowStatesManager.shared.registerWindowState(replica)
            return replica
        }

        func removeReplica(_ replica: WindowState) async {
            WindowStatesManager.shared.unregisterWindowState(replica)
            await replica.tearDown()
        }

        private func execute(_ arguments: [String: Value]) async throws -> Value {
            let service = SessionAdminMCPToolService(
                captureRequestMetadata: {
                    self.beforeCallerResolution?()
                    return .init(connectionID: UUID(), clientName: "organizer-journey", windowID: self.window.windowID)
                },
                requireTargetWindow: { self.window },
                resolveObserverEndpoint: { _, _ in
                    self.window.agentModeViewModel.agentSessionLinkObserverEndpoint(tabID: self.callerTab.id)
                },
                scopes: { self.scopes }, administration: { self.frontDoor }, isToolEnabled: { true }
            )
            return try await service.execute(args: arguments)
        }

        func call(_ op: String, _ fields: [String: Value]) async throws -> [String: Value] {
            var arguments = fields
            arguments["op"] = .string(op)
            if op != "undo", op != "inventory", op != "reorder_groups" {
                arguments["session_id"] = .string(targetTab.activeAgentSessionID!.uuidString)
            }
            if let ingress { return try await ingress.call("session_admin", arguments) }
            let reply = try await execute(arguments)
            return try XCTUnwrap(reply.objectValue)
        }

        func assertReadTarget(name: String, pinned: Bool, archived: Bool = false, loadedOnly: Bool = false) async throws {
            let get = try await call("get", [:])
            XCTAssertEqual(get["result"], .string("ok"))
            let exact = try XCTUnwrap(get["session"]?.objectValue)
            var fields: [String: Value] = ["limit": .int(500)]
            if loadedOnly { fields["filter"] = .object(["loaded": .bool(true)]) }
            let inventory = try await call("inventory", fields)
            XCTAssertEqual(inventory["result"], .string("ok"))
            let listed = try XCTUnwrap(inventory["sessions"]?.arrayValue?.compactMap(\.objectValue).first {
                $0["session_id"] == .string(targetTab.activeAgentSessionID!.uuidString)
            })
            for row in [exact, listed] {
                XCTAssertEqual(row["name"], .string(name))
                XCTAssertEqual(row["pinned"], .bool(pinned))
                XCTAssertEqual(row["archived"], .bool(archived))
                XCTAssertEqual(row["loaded"], .bool(true))
                XCTAssertEqual(row["workspace_id"], .string(workspaceID.uuidString))
            }
        }

        func undo(_ reply: [String: Value]) async throws -> [String: Value] {
            let token = try XCTUnwrap(reply["undo_token"]?.stringValue)
            return try await call("undo", ["undo_token": .string(token)])
        }

        func assertTarget(name: String, pinned: Bool, group: String?, selectedTabID: UUID? = nil) throws {
            let workspace = try workspace()
            let tab = try XCTUnwrap(workspace.composeTabs.first { $0.id == targetTab.id })
            let row = try XCTUnwrap(
                window.agentModeViewModel.sidebarSessions(for: window.promptManager.currentComposeTabs)
                    .first { $0.sessionID == targetTab.activeAgentSessionID }
            )
            let projectedTab = try XCTUnwrap(window.promptManager.currentComposeTabs.first { $0.id == targetTab.id })
            let indexed = try XCTUnwrap(window.agentModeViewModel.ownerValidatedSessionIndex[targetTab.activeAgentSessionID!])
            XCTAssertEqual(tab.name, name)
            XCTAssertEqual(projectedTab.name, name)
            XCTAssertEqual(indexed.name, name)
            XCTAssertEqual(indexed.tabID, targetTab.id)
            XCTAssertEqual(row.title, name)
            XCTAssertEqual(tab.isPinned, pinned)
            XCTAssertEqual(projectedTab.isPinned, pinned)
            XCTAssertEqual(projectedTab.activeAgentSessionID, targetTab.activeAgentSessionID)
            XCTAssertEqual(row.isPinned, pinned)
            XCTAssertEqual(tab.sidebarGroup, group)
            XCTAssertEqual(window.workspaceManager.activeWorkspaceID, workspaceID)
            XCTAssertEqual(workspace.activeComposeTabID, selectedTabID ?? callerTab.id)
            XCTAssertEqual(window.promptManager.activeComposeTabID, selectedTabID ?? callerTab.id)
        }

        func cleanup() async {
            await ingress?.cleanup()
            ingress = nil
            WindowStatesManager.shared.unregisterWindowState(window)
            if runtime != nil {
                window.beginClose()
                await window.joinDomainWorkspaceBridgeForTesting()
            }
            await window.tearDown()
            if let runtime { await runtime.shutdown() }
            try? FileManager.default.removeItem(at: directory)
        }
    }
}

@MainActor
final class AgentSessionInventoryScalingTests: XCTestCase {
    func testTwoHundredFiftyTargetsShareCarrierAndLivenessCensusAndSeeFreshChanges() async {
        let window = WindowState()
        addTeardownBlock { @MainActor in await window.tearDown() }
        await window.workspaceManager.awaitInitialized()
        let ids = (0 ..< 250).map { _ in UUID() }
        var tabs = (0 ..< 1500).map { ComposeTabState(name: "Tab \($0)") }
        for index in 0 ..< 200 {
            tabs[index].activeAgentSessionID = ids[index]
        }
        tabs[1250].activeAgentSessionID = ids[0] // Duplicate persisted carrier must stay ambiguous.
        let stashes = (200 ..< 250).map { StashedTab(tab: ComposeTabState(name: "Stash \($0)")) }
        var workspace = WorkspaceModel(name: "Scale", repoPaths: [], composeTabs: tabs, activeComposeTabID: tabs[0].id)
        workspace.isEphemeral = true
        workspace.stashedTabs = stashes
        window.workspaceManager.workspaces = [workspace]
        window.workspaceManager.activeWorkspace = workspace
        window.promptManager.loadComposeTabsFromWorkspace(workspace)
        let entries = ids.enumerated().map { index, id in
            AgentSessionIndexEntry(
                id: id, tabID: index < 200 ? tabs[index].id : stashes[index - 200].tab.id,
                name: "Indexed \(index)", savedAt: Date(timeIntervalSince1970: 0), itemCount: 1,
                autoEditEnabled: false, hasUnknownConversationContent: false, isMCPOriginated: false,
                worktreeBindingSummaries: [], activeWorktreeMergeSummaries: []
            )
        }
        let owner = AgentModeViewModel.SessionIndexOwner(workspaceID: workspace.id, activationEpoch: 1)
        let vm = window.agentModeViewModel
        vm.test_installSessionIndexSnapshot(Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) }), owner: owner, latestOwner: owner, activeWorkspace: workspace)
        var windowReads = 0
        let organizer = OpenWindowsAgentSessionOrganizer(windows: { windowReads += 1
            return [window]
        })
        vm.test_resetPersistentBindingResolutionSnapshotBuildCount()
        let states = organizer.states(of: ids)
        XCTAssertEqual(Set(states.keys), Set(ids.dropFirst()))
        XCTAssertEqual(states.values.count(where: \.isArchived), 50)
        XCTAssertNil(states[ids[0]], "Ambiguous carriers must not supply an actionable presentation")
        XCTAssertEqual(states[ids[1]]?.runState, .idle)
        XCTAssertEqual(windowReads, 1, "Do not rediscover windows/carriers per target")
        XCTAssertEqual(vm.test_persistentBindingResolutionBuildCount, 1)
        XCTAssertLessThanOrEqual(vm.test_sidebarSessionRowsBuildCount, 1)

        windowReads = 0
        let changed = organizer.setGroup("Grouped", order: 3, sessionIDs: ids)
        let writableIDs = Set(ids[1 ..< 200])
        XCTAssertEqual(changed, writableIDs)
        XCTAssertEqual(windowReads, 1, "One carrier census per synchronous mutation region")
        for tabID in [tabs[0].id, tabs[1250].id] {
            let tab = window.workspaceManager.activeWorkspace?.composeTabs.first { $0.id == tabID }
            XCTAssertNotNil(tab)
            XCTAssertNil(tab?.sidebarGroup, "Neither duplicate carrier may be mutated")
            XCTAssertNil(tab?.sidebarGroupOrder)
        }
        let fresh = organizer.states(of: ids)
        XCTAssertEqual(fresh[ids[1]]?.sidebarGroup, "Grouped")
        XCTAssertNil(fresh[ids[249]]?.sidebarGroup, "Nil-bound stashes must not be mistaken for active tabs")

        windowReads = 0
        let restoredGroups = Dictionary(uniqueKeysWithValues: ids.prefix(200).map { ($0, (name: String?.none, order: Int?.none)) })
        XCTAssertEqual(organizer.setGroups(restoredGroups), writableIDs)
        XCTAssertEqual(windowReads, 1, "Distinct undo group values must share one carrier census")
        windowReads = 0
        let unarchived = await organizer.unarchive(Array(ids.suffix(50)), isAuthorized: { _ in true })
        XCTAssertEqual(unarchived.restored, Set(ids.suffix(50)))
        XCTAssertTrue(unarchived.failures.isEmpty)
        XCTAssertEqual(windowReads, 3, "One indexed capture before grouping, after draft flush, and after persistence; never one per target")
        XCTAssertTrue(window.workspaceManager.activeWorkspace?.stashedTabs.isEmpty == true)
        XCTAssertEqual(window.workspaceManager.activeWorkspace?.composeTabs.suffix(50).map(\.id), stashes.map(\.tab.id))
        XCTAssertEqual(organizer.states(of: ids).values.count(where: \.isArchived), 0)
        XCTAssertEqual(organizer.loadedSessionIDs().count, 250)
    }

    func testChainMembershipAndUsageReuseOneFreshSynchronousCensus() {
        let ids = (0 ..< 250).map { _ in UUID() }
        let workspace = UUID()
        let rows = ids.enumerated().map { index, id in
            DelegationSessionProvenance(sessionID: id, workspaceID: workspace, parentSessionID: index == 0 ? nil : ids[index - 1], createdByOverseerSessionID: nil, isLive: true, worktreeCount: 1, runState: .idle)
        }
        let source = CountingSource(rows: rows)
        var lookups = 0
        let projector = SpawnProvenanceDelegationMembershipProjector(source: source, onAncestryLookup: { _ in lookups += 1 })
        let scope = DomainDelegationScopeGrant(id: UUID(), granteeSessionID: ids[0], kind: .tree(rootSessionID: ids[0]), capabilities: [.observe], guardrails: .init(), origin: .user, grantedAt: Date(timeIntervalSince1970: 0))
        projector.withSynchronousCensus { census in
            for id in ids {
                let members = census.members(of: scope)
                XCTAssertEqual(members.count, ids.count)
                XCTAssertEqual(Set(members), Set(ids))
                XCTAssertEqual(census.usage(of: scope, spawnParentSessionID: id).liveSessionCount, 250)
                XCTAssertEqual(census.membershipProof(for: id, in: scope)?.treeDepth, ids.firstIndex(of: id))
            }
        }
        XCTAssertEqual(source.censusReads, 1)
        XCTAssertEqual(source.individualReads, 0)
        XCTAssertEqual(lookups, 249_498, "Members, usage and parent depth share bounded scalar ancestry lookups")
        source.rows = [rows[0]]
        XCTAssertEqual(projector.members(of: scope), [ids[0]], "A later region must not reuse stale membership")
        XCTAssertEqual(source.censusReads, 2)
    }

    private final class CountingSource: DelegationProvenanceSource {
        var rows: [DelegationSessionProvenance]
        var censusReads = 0
        var individualReads = 0
        init(rows: [DelegationSessionProvenance]) {
            self.rows = rows
        }

        func provenance(for id: UUID) -> DelegationSessionProvenance? {
            individualReads += 1
            return rows.first { $0.sessionID == id }
        }

        func allKnownSessions() -> [DelegationSessionProvenance] {
            censusReads += 1
            return rows
        }
    }
}
