import Combine
import Foundation
import MCP
@_spi(TestSupport) @testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptSecureStorage
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

    func testUnloadedPlacementReportsMissingFileAndPersistsExistingProvenance() async throws {
        let fixture = try await makeFixture()
        let parent = UUID(), scope = UUID(), creator = UUID()
        do {
            try await fixture.dataService.updateDelegationPlacement(
                id: fixture.sessionID, organizationalParentID: parent, delegationScopeID: scope,
                for: fixture.workspace
            )
            XCTFail("A missing file is a failed commit, not a successful no-op")
        } catch DelegationPlacementPersistenceError.sessionFileMissing {}
        var original = AgentSession(id: fixture.sessionID, name: "Unloaded")
        original.createdByOverseerSessionID = creator
        _ = try await fixture.dataService.saveAgentSession(original, for: fixture.workspace)
        try await fixture.dataService.updateDelegationPlacement(
            id: fixture.sessionID, organizationalParentID: parent, delegationScopeID: scope,
            for: fixture.workspace
        )
        let restored = try await reopen(fixture)
        XCTAssertEqual(restored?.organizationalParentID, parent)
        XCTAssertEqual(restored?.delegationScopeID, scope)
        XCTAssertEqual(restored?.createdByOverseerSessionID, creator)
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
                window.agentModeViewModel.test_setBeforeCancellationCommit(nil)
                await window.tearDown()
            }
            throw error
        }
        for window in windows.reversed() {
            window.agentModeViewModel.test_setBeforeCancellationCommit(nil)
            await window.tearDown()
        }
    }

    private func installStopRun(
        in window: WindowState, tabID: UUID, sessionID: UUID
    ) -> AgentModeViewModel.TabSession {
        let session = AgentModeViewModel.TabSession(tabID: tabID)
        session.selectedAgent = .claudeCode
        session.hasLoadedPersistedState = true
        session.testInstallPersistentSessionBinding(sessionID: sessionID)
        session.runState = .running
        session.installRunID(UUID())
        _ = session.beginRunAttempt(source: "session-admin-stop-integration")
        window.agentModeViewModel.test_installLiveSession(session)
        return session
    }

    func testStopSelectsTheExactRunningObjectAcrossColdCanonicalReplicasInEitherOrder() async throws {
        try await MCPSharedServerTestLease.shared.withLease { _ in
            for liveFirst in [false, true] {
                try await withStopCarrierWindows(count: 2) { windows, _, tab, target in
                    let cold = windows[0]
                    let live = windows[1]
                    let session = installStopRun(in: live, tabID: tab.id, sessionID: target)
                    var cancelledObjects: [ObjectIdentifier] = []
                    live.agentModeViewModel.test_setBeforeCancellationCommit { candidate in
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
                let sessions = windows.map { installStopRun(in: $0, tabID: tab.id, sessionID: target) }
                let generations = sessions.map(\.stopState.cancellationGeneration)
                let runIDs = sessions.map(\.runID)
                var cancellationCommits = 0
                for window in windows {
                    window.agentModeViewModel.test_setBeforeCancellationCommit { _ in cancellationCommits += 1 }
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
                    let session = installStopRun(in: window, tabID: tab.id, sessionID: target)
                    let generation = session.stopState.cancellationGeneration
                    let runID = session.runID
                    var cancellationCommits = 0
                    var authorityChecked = false
                    window.agentModeViewModel.test_setBeforeCancellationCommit { _ in cancellationCommits += 1 }
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
                let session = installStopRun(in: window, tabID: tab.id, sessionID: target)
                var completedObjects: [ObjectIdentifier] = []
                viewModel.test_setBeforeCancellationCommit { candidate in
                    completedObjects.append(ObjectIdentifier(candidate))
                    await viewModel.test_publishNaturalCompletion(candidate)
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
        for outerMutation in ["carriers", "presentation", "selection"] {
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
                XCTAssertEqual(undone["result"], .string("not_undone"))
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
                XCTAssertEqual(reply["result"], .string("failed"))
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
    private final class DraftCaptureEvidence {
        var observedDirtyDraftBeforeCapture = false
    }

    @MainActor
    private final class Fixture {
        let window: WindowState
        let directory: URL
        let callerTab = ComposeTabState(name: "Overseer", activeAgentSessionID: UUID())
        let targetTab = ComposeTabState(name: "Target", activeAgentSessionID: UUID())
        let scopes = DelegationScopeRuntime(persistenceMode: .ephemeral)
        let ownership = WorktreeOwnershipStore()
        var workspaceID: UUID!
        var frontDoor: AgentSessionAdministrationFrontDoor!
        var beforeCallerResolution: (@MainActor () -> Void)?

        private init(window: WindowState, directory: URL) {
            self.window = window
            self.directory = directory
        }

        static func make(ephemeral: Bool = true) async throws -> Fixture {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("session-admin-production-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let window = WindowState()
            let fixture = Fixture(window: window, directory: directory)
            WindowStatesManager.shared.registerWindowState(window)
            do {
                await window.workspaceManager.awaitInitialized()
                var workspace = window.workspaceManager.createWorkspace(
                    name: "Organizer journey", repoPaths: [], ephemeral: ephemeral
                )
                workspace.customStoragePath = directory
                workspace.composeTabs = [fixture.callerTab, fixture.targetTab]
                workspace.activeComposeTabID = fixture.callerTab.id
                fixture.workspaceID = workspace.id
                let switched = await window.workspaceManager.reactivateWorkspaceAfterReplacement(
                    workspace, reason: "sessionAdminProductionJourney"
                )
                XCTAssertEqual(switched, .switched)
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
                let requested = try fixture.scopes.requestScope(
                    requesterSessionID: fixture.callerTab.activeAgentSessionID!, requesterTabID: fixture.callerTab.id,
                    kind: .workspace(workspaceID: workspace.id), capabilities: [.observe, .organize],
                    guardrails: .init(), reason: nil, idempotencyKey: nil
                ).get()
                _ = try fixture.scopes.approve(requestID: requested.id).get()
                return fixture
            } catch {
                await fixture.cleanup()
                throw error
            }
        }

        func workspace() throws -> WorkspaceModel {
            try XCTUnwrap(window.workspaceManager.activeWorkspace)
        }

        func call(_ op: String, _ fields: [String: Value]) async throws -> [String: Value] {
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
            var arguments = fields
            arguments["op"] = .string(op)
            if op != "undo", op != "inventory" { arguments["session_id"] = .string(targetTab.activeAgentSessionID!.uuidString) }
            let reply = try await service.execute(args: arguments)
            return try XCTUnwrap(reply.objectValue)
        }

        func assertReadTarget(name: String, pinned: Bool, archived: Bool = false) async throws {
            let get = try await call("get", [:])
            XCTAssertEqual(get["result"], .string("ok"))
            let exact = try XCTUnwrap(get["session"]?.objectValue)
            let inventory = try await call("inventory", ["limit": .int(500)])
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
            WindowStatesManager.shared.unregisterWindowState(window)
            await window.tearDown()
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
