import Foundation
import MCP
@_spi(TestSupport) @testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptSettingsCore
import RepoPromptVCS
import XCTest

@MainActor
final class SessionAdminWorktreeRecoveryTests: XCTestCase {
    func testUnopenedLaneModelAndEffortUseItsWriterDespiteEarlierWorkspaceReplica() async throws {
        for fullAccess in [true, false] {
            try await withFixture(fullAccess: fullAccess) { fixture in
                let settings = GlobalSettingsStore.shared
                let originalProfile = settings.globalAgentModelsProfile()
                defer {
                    settings.setGlobalAgentModelsProfile(originalProfile, contextBuilderWriteIntent: .preserveExistingOwnership)
                    AgentAdvertisedModelCatalog.shared.invalidate(.claudeCode)
                }
                var profile = originalProfile
                profile.mcpAgentRoleOverrides = ["explore": "claudeCode:sonnet:medium"]
                profile.mcpAgentRoleModelParameters = [:]
                settings.setGlobalAgentModelsProfile(profile, contextBuilderWriteIntent: .preserveExistingOwnership)
                fixture.window.apiSettingsViewModel.isClaudeCodeConnected = true
                try await AsyncTestWait.waitUntil("model writer availability") {
                    fixture.window.apiSettingsViewModel.agentAvailability.claudeCodeAvailable
                }
                AgentAdvertisedModelCatalog.shared.record([
                    AgentModelOption(
                        rawValue: "sonnet:medium", displayName: "Sonnet", description: nil,
                        isPlaceholderDefault: false, isProviderDefault: false
                    )
                ], for: .claudeCode, generation: AgentAdvertisedModelCatalog.shared.productionGeneration(for: .claudeCode))
                let binding = fixture.session.persistentSessionBindingIdentity
                let peerWorkspace = fixture.replica.workspaceManager.activeWorkspace
                let peerIndex = fixture.replica.agentModeViewModel.ownerValidatedSessionIndex
                let modelRequest: [String: Value] = [
                    "op": .string("set_model"), "session_id": .string(fixture.sessionID.uuidString),
                    "model_id": .string("explore")
                ]
                let model = try await fixture.call(modelRequest)
                XCTAssertEqual(model["result"], .string("applied"), String(describing: model))
                XCTAssertEqual(fixture.session.selectedModelRaw, "sonnet:medium")
                let repeatedModel = try await fixture.call(modelRequest)
                XCTAssertEqual(repeatedModel["result"], .string("applied"), String(describing: repeatedModel))
                XCTAssertEqual(repeatedModel["changed_count"], .int(0))
                XCTAssertEqual(repeatedModel["state_satisfied"], .bool(true))
                let effortRequest: [String: Value] = [
                    "op": .string("set_effort"), "session_id": .string(fixture.sessionID.uuidString),
                    "effort": .string("high")
                ]
                let effort = try await fixture.call(effortRequest)
                XCTAssertEqual(effort["result"], .string("applied"), String(describing: effort))
                XCTAssertEqual(fixture.session.selectedClaudeEffortRaw, "high")
                let repeatedEffort = try await fixture.call(effortRequest)
                XCTAssertEqual(repeatedEffort["result"], .string("applied"), String(describing: repeatedEffort))
                XCTAssertEqual(repeatedEffort["changed_count"], .int(0))
                XCTAssertEqual(repeatedEffort["state_satisfied"], .bool(true))
                try await fixture.window.agentModeViewModel.flushSaveRequired(
                    for: fixture.session.tabID, workspaceID: fixture.workspaceID
                ).get()
                let saved = try await fixture.savedSession()
                let persisted = try XCTUnwrap(saved)
                XCTAssertEqual(persisted.agentKind, AgentProviderKind.claudeCode.rawValue)
                XCTAssertEqual(persisted.agentModel, "sonnet:medium")
                XCTAssertEqual(persisted.agentReasoningEffort, "high")
                XCTAssertEqual(fixture.session.persistentSessionBindingIdentity, binding)
                XCTAssertNil(fixture.session.runID)
                XCTAssertTrue(fixture.session.items.isEmpty)
                XCTAssertNil(fixture.replica.agentModeViewModel.sessions[fixture.session.tabID])
                XCTAssertEqual(fixture.replica.workspaceManager.activeWorkspace, peerWorkspace)
                XCTAssertEqual(fixture.replica.agentModeViewModel.ownerValidatedSessionIndex, peerIndex)
                fixture.assertForegroundUnchanged()
            }
        }
    }

    func testExistingCheckoutRecoveryReplaysThroughToolBindAndRelease() async throws {
        try await withFixture { fixture in
            let checkout = fixture.git.sandbox.appendingPathComponent("existing-checkout")
            try fixture.git.runGit(["worktree", "add", "-b", "e2e/recovery", checkout.path, "HEAD"], at: fixture.repository)
            let before = try fixture.git.runGit(["worktree", "list", "--porcelain"], at: fixture.repository)
            let refused = try await fixture.call([
                "op": .string("worktree_create"), "session_id": .string(fixture.sessionID.uuidString),
                "branch": .string("e2e/recovery"), "idempotency_key": .string("existing-checkout")
            ])
            XCTAssertEqual(refused["code"], .string("branch_exists"))
            XCTAssertEqual(try fixture.git.runGit(["worktree", "list", "--porcelain"], at: fixture.repository), before)
            XCTAssertTrue(fixture.session.worktreeBindings.isEmpty)
            let next = try XCTUnwrap(refused["next_call"]?.objectValue)
            XCTAssertEqual(next["tool"], .string("session_admin"))
            let arguments = try XCTUnwrap(next["arguments"]?.objectValue)
            XCTAssertEqual(arguments["op"], .string("worktree_bind"))
            XCTAssertEqual(arguments["session_id"], .string(fixture.sessionID.uuidString))
            let recoveryPath = try XCTUnwrap(arguments["worktree"]?.stringValue)
            XCTAssertEqual(GitRepoRootAuthorization.canonicalPath(recoveryPath), GitRepoRootAuthorization.canonicalPath(checkout.path))

            // Replay the returned public call verbatim, without supplying missing target or scope
            // arguments. The production host resolves Git identity and durably binds the session.
            let bound = try await fixture.call(arguments)
            XCTAssertEqual(bound["result"], .string("applied"))
            let binding = try XCTUnwrap(fixture.session.worktreeBindings.first)
            XCTAssertEqual(GitRepoRootAuthorization.canonicalPath(binding.worktreeRootPath), GitRepoRootAuthorization.canonicalPath(checkout.path))
            let savedBound = try await fixture.savedSession()
            let persistedBound = try XCTUnwrap(savedBound)
            XCTAssertEqual(persistedBound.worktreeBindings.map(\.worktreeID), [binding.worktreeID])

            let released = try await fixture.call([
                "op": .string("worktree_release"), "worktree_id": .string(binding.worktreeID)
            ])
            XCTAssertEqual(released["result"], .string("applied"))
            XCTAssertTrue(fixture.session.worktreeBindings.isEmpty)
            let savedReleased = try await fixture.savedSession()
            let persistedReleased = try XCTUnwrap(savedReleased)
            XCTAssertTrue(persistedReleased.worktreeBindings.isEmpty)
            XCTAssertNotNil(fixture.ownership.record(worktreeID: binding.worktreeID)?.releasedAt)
            XCTAssertTrue(FileManager.default.fileExists(atPath: checkout.appendingPathComponent("README.md").path))
            XCTAssertEqual(
                try fixture.git.runGit(["worktree", "list", "--porcelain"], at: fixture.repository),
                before,
                "Release leaves the checkout and Git registration for human cleanup"
            )
            XCTAssertNil(fixture.replica.agentModeViewModel.sessions[fixture.session.tabID])
            fixture.assertForegroundUnchanged()
        }
    }

    func testExistingBranchWithoutCheckoutDoesNotInventBindRecovery() async throws {
        try await withFixture { fixture in
            try fixture.git.runGit(["branch", "e2e/no-checkout"], at: fixture.repository)
            let before = try fixture.git.runGit(["worktree", "list", "--porcelain"], at: fixture.repository)
            let refused = try await fixture.call([
                "op": .string("worktree_create"), "session_id": .string(fixture.sessionID.uuidString),
                "branch": .string("e2e/no-checkout"), "idempotency_key": .string("existing-branch")
            ])
            XCTAssertEqual(refused["code"], .string("branch_exists"))
            XCTAssertNil(refused["next_call"], "A branch with no checkout supplies no path that can be bound")
            XCTAssertTrue(refused["detail"]?.stringValue?.contains("new branch name") == true)
            XCTAssertEqual(try fixture.git.runGit(["worktree", "list", "--porcelain"], at: fixture.repository), before)
            XCTAssertTrue(fixture.session.worktreeBindings.isEmpty)
            XCTAssertTrue(fixture.ownership.records.isEmpty)
        }
    }

    func testCompetingBoundWritersCannotMutateConfigurationOrCreateWorktree() async throws {
        for peerReady in [true, false] {
            try await withFixture { fixture in
                let originalOwner = try XCTUnwrap(SessionAdminWindows.runtimeOwner(for: fixture.sessionID))
                XCTAssertTrue(SessionAdminWindows.isCurrent(originalOwner))
                let peer = fixture.replica.agentModeViewModel.session(for: fixture.session.tabID)
                peer.selectedAgent = .claudeCode
                peer.selectedModelRaw = "haiku"
                peer.selectedClaudeEffortRaw = "low"
                peer.parentSessionID = fixture.session.parentSessionID
                peer.createdByOverseerSessionID = fixture.session.createdByOverseerSessionID
                peer.hasLoadedPersistedState = peerReady
                _ = try XCTUnwrap(fixture.replica.agentModeViewModel.test_installPersistentSessionBinding(
                    sessionID: fixture.sessionID, on: peer
                ))
                if peerReady { peer.recordRestorationAuthoritative(.persistedPayloadApplied) }
                XCTAssertEqual(peer.permitsBoundOperationAndSave, peerReady)
                XCTAssertTrue(try fixture.replica.agentModeViewModel.authoritativeLiveSession(for: fixture.sessionID) === peer)
                let source = OpenWindowsDelegationProvenanceSource()
                XCTAssertEqual(source.resolutionState(for: fixture.sessionID), .replicated)
                XCTAssertEqual(source.provenance(for: fixture.sessionID)?.hasUniqueRuntimeOwner, false)
                XCTAssertNil(SessionAdminWindows.runtimeOwner(for: fixture.sessionID))
                XCTAssertFalse(SessionAdminWindows.isCurrent(originalOwner), "A second bound object invalidates prior owner proof before it finishes loading")
                let before = try fixture.git.runGit(["worktree", "list", "--porcelain"], at: fixture.repository)
                let ownerSaveGeneration = fixture.session.saveRequestGeneration
                let peerSaveGeneration = peer.saveRequestGeneration
                for arguments: [String: Value] in [
                    ["op": .string("set_model"), "model_id": .string("explore")],
                    ["op": .string("set_effort"), "effort": .string("high")],
                    ["op": .string("worktree_create"), "branch": .string("e2e/competing-writers"), "idempotency_key": .string("competing-writers")]
                ] {
                    var request = arguments
                    request["session_id"] = .string(fixture.sessionID.uuidString)
                    let refused = try await fixture.call(request)
                    XCTAssertEqual(refused["code"], .string("mutation_owner_unavailable"), String(describing: refused))
                    XCTAssertEqual(refused["subreason"], .string("replicated_binding"))
                }
                XCTAssertEqual(fixture.session.selectedModelRaw, "haiku")
                XCTAssertEqual(peer.selectedModelRaw, "haiku")
                XCTAssertEqual(fixture.session.selectedClaudeEffortRaw, "low")
                XCTAssertEqual(peer.selectedClaudeEffortRaw, "low")
                XCTAssertEqual(fixture.session.saveRequestGeneration, ownerSaveGeneration)
                XCTAssertEqual(peer.saveRequestGeneration, peerSaveGeneration)
                XCTAssertTrue(fixture.session.worktreeBindings.isEmpty)
                XCTAssertTrue(peer.worktreeBindings.isEmpty)
                XCTAssertTrue(fixture.ownership.records.isEmpty)
                XCTAssertEqual(try fixture.git.runGit(["worktree", "list", "--porcelain"], at: fixture.repository), before)
                fixture.assertForegroundUnchanged()
            }
        }
    }

    @MainActor
    private struct Fixture {
        let git: ReviewGitRepositoryFixture
        let repository: URL
        let window: WindowState
        let replica: WindowState
        let session: AgentTabSession
        let sessionID: UUID
        let workspaceID: UUID
        let foregroundTabID: UUID
        let dataService: AgentSessionDataService
        let ownership: WorktreeOwnershipStore
        let service: SessionAdminMCPToolService

        func call(_ arguments: [String: Value]) async throws -> [String: Value] {
            let result = try await service.execute(args: arguments)
            return try XCTUnwrap(result.objectValue)
        }

        func savedSession() async throws -> AgentSession? {
            let workspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
            return try await dataService.loadAgentSession(id: sessionID, for: workspace)
        }

        func assertForegroundUnchanged() {
            XCTAssertEqual(window.promptManager.activeComposeTabID, foregroundTabID)
            XCTAssertEqual(replica.promptManager.activeComposeTabID, foregroundTabID)
            XCTAssertEqual(window.promptManager.promptText, "Owner draft")
            XCTAssertEqual(replica.promptManager.promptText, "Replica draft")
            XCTAssertNotEqual(window.agentModeViewModel.currentTabID, session.tabID)
            XCTAssertNotEqual(replica.agentModeViewModel.currentTabID, session.tabID)
        }
    }

    /// The passive replica is registered first and shares the physical tab and owner-valid index.
    /// Only the second window binds the background payload. Production provenance, caller binding,
    /// authorization and hosts must distinguish those facts without selecting either target tab.
    private func withFixture(fullAccess: Bool = true, _ body: (Fixture) async throws -> Void) async throws {
        let git = try ReviewGitRepositoryFixture(name: "SessionAdminWorktreeRecovery")
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let replica = WindowState()
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(replica)
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        let previousFullAccess = OverseerGlobalAutoApprove.isEnabled
        OverseerGlobalAutoApprove.isEnabled = { fullAccess }
        let cleanup: @MainActor () async -> Void = {
            window.beginClose()
            replica.beginClose()
            await window.tearDown()
            await replica.tearDown()
            WindowStatesManager.shared.unregisterWindowState(window)
            WindowStatesManager.shared.unregisterWindowState(replica)
            OverseerGlobalAutoApprove.isEnabled = previousFullAccess
            git.cleanup()
        }
        do {
            let repository = try git.makeRepository(named: "repository", files: ["README.md": "fixture\n"])
            await replica.workspaceManager.awaitInitialized()
            await window.workspaceManager.awaitInitialized()
            let created = window.workspaceManager.createWorkspace(name: "Worktree recovery", repoPaths: [repository.path], ephemeral: true)
            await window.workspaceManager.switchWorkspace(to: created, saveState: false, reason: "worktreeRecoveryTest")
            _ = try await window.promptManager.workspaceFileContextStore.loadRoot(path: repository.path)
            var workspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
            let foregroundTabID = try XCTUnwrap(workspace.activeComposeTabID)
            let sessionID = UUID(), callerID = UUID()
            let foregroundIndex = try XCTUnwrap(workspace.composeTabs.firstIndex { $0.id == foregroundTabID })
            workspace.composeTabs[foregroundIndex].activeAgentSessionID = callerID
            let targetTab = ComposeTabState(name: "Background target", activeAgentSessionID: sessionID)
            workspace.composeTabs.append(targetTab)
            let workspaceIndex = try XCTUnwrap(window.workspaceManager.workspaces.firstIndex { $0.id == workspace.id })
            window.workspaceManager.workspaces[workspaceIndex] = workspace
            window.promptManager.loadComposeTabsFromWorkspace(workspace, syncPromptText: true)
            let viewModel = window.agentModeViewModel
            let caller = viewModel.session(for: foregroundTabID)
            _ = try XCTUnwrap(viewModel.test_installPersistentSessionBinding(sessionID: callerID, on: caller))
            caller.hasLoadedPersistedState = true
            caller.recordRestorationAuthoritative(.persistedPayloadApplied)
            let session = viewModel.session(for: targetTab.id)
            _ = try XCTUnwrap(viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session))
            session.selectedAgent = .claudeCode
            session.selectedModelRaw = "haiku"
            session.selectedReasoningEffortRaw = "low"
            session.selectedClaudeEffortRaw = "low"
            session.parentSessionID = callerID
            session.createdByOverseerSessionID = callerID
            session.hasLoadedPersistedState = true
            session.recordRestorationAuthoritative(.persistedPayloadApplied)
            let owner = AgentModeViewModel.SessionIndexOwner(workspaceID: workspace.id, activationEpoch: 1)
            var entry = AgentSessionIndexEntry(
                id: sessionID, tabID: targetTab.id, name: targetTab.name, savedAt: Date(), itemCount: 0,
                autoEditEnabled: false, hasUnknownConversationContent: false, isMCPOriginated: false,
                worktreeBindingSummaries: [], activeWorktreeMergeSummaries: []
            )
            entry.lastRunStateRaw = "idle"
            entry.parentSessionID = callerID
            entry.createdByOverseerSessionID = callerID
            let callerEntry = AgentSessionIndexEntry(
                id: callerID, tabID: foregroundTabID, name: "Overseer", savedAt: Date(), itemCount: 0,
                autoEditEnabled: false, hasUnknownConversationContent: false, isMCPOriginated: false,
                worktreeBindingSummaries: [], activeWorktreeMergeSummaries: []
            )
            viewModel.test_installSessionIndexSnapshot(
                [sessionID: entry, callerID: callerEntry], owner: owner, latestOwner: owner, activeWorkspace: workspace
            )
            let dataService = AgentSessionDataService()
            await dataService.test_setWorkspaceRootOverride(git.sandbox.appendingPathComponent("sessions"))
            viewModel.test_setAgentSessionSaver { payload, workspace, count in
                try await dataService.saveAgentSession(payload, for: workspace, preparation: .alreadyCanonicalTranscript, trustedCanonicalItemCount: count)
            }
            session.isDirty = true
            try await viewModel.flushSaveRequired(for: targetTab.id, workspaceID: workspace.id).get()
            XCTAssertTrue(try viewModel.authoritativeLiveSession(for: sessionID) === session)
            workspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
            replica.workspaceManager.workspaces = [workspace]
            replica.workspaceManager.activeWorkspace = workspace
            replica.promptManager.loadComposeTabsFromWorkspace(workspace, syncPromptText: true)
            for tabID in Array(replica.agentModeViewModel.sessions.keys) {
                replica.agentModeViewModel.test_removeSession(tabID: tabID)
            }
            replica.agentModeViewModel.test_installSessionIndexSnapshot(
                viewModel.ownerValidatedSessionIndex, owner: owner, latestOwner: owner, activeWorkspace: workspace
            )
            window.promptManager.promptText = "Owner draft"
            replica.promptManager.promptText = "Replica draft"
            // Draft publication is asynchronous. Capture the no-peer-mutation baseline only
            // after fixture setup has reached both workspace projections.
            try await AsyncTestWait.waitUntil("foreground drafts published") {
                window.workspaceManager.activeWorkspace?.composeTabs.first { $0.id == foregroundTabID }?.promptText == "Owner draft"
                    && replica.workspaceManager.activeWorkspace?.composeTabs.first { $0.id == foregroundTabID }?.promptText == "Replica draft"
            }
            let source = OpenWindowsDelegationProvenanceSource()
            XCTAssertEqual(source.resolutionState(for: sessionID), .replicated)
            XCTAssertEqual(source.censusSnapshot().states[sessionID], .replicated)
            XCTAssertEqual(source.placement(for: sessionID)?.workspaceID, workspace.id)
            XCTAssertEqual(source.provenance(for: sessionID)?.hasUniqueRuntimeOwner, true)
            let runtimeOwner = try XCTUnwrap(SessionAdminWindows.runtimeOwner(for: sessionID))
            XCTAssertTrue(runtimeOwner.location.window === window)
            XCTAssertTrue(runtimeOwner.session === session)
            XCTAssertEqual(runtimeOwner.binding, session.currentRestorationBindingToken)
            let metadataPresenters = WindowStatesManager.shared.allWindows.filter {
                $0.agentModeViewModel.ownerValidatedSessionIndex[sessionID] != nil
            }
            XCTAssertTrue(metadataPresenters.first === replica, "Metadata order must not select the passive replica as writer")
            XCTAssertEqual(metadataPresenters.count, 2)
            XCTAssertNil(replica.agentModeViewModel.sessions[targetTab.id])
            let scopes = DelegationScopeRuntime(persistenceMode: .ephemeral, notifyCatalogChanged: { _ in })
            if !fullAccess {
                let request = try scopes.requestScope(
                    requesterSessionID: callerID, requesterTabID: nil,
                    kind: .session(targetSessionID: sessionID), capabilities: [.control],
                    guardrails: .init(), reason: nil, idempotencyKey: nil
                ).get()
                let grant = try scopes.approve(requestID: request.id).get()
                XCTAssertEqual(grant.grant.kind, .session(targetSessionID: sessionID))
                XCTAssertEqual(grant.grant.capabilities, [.control])
            }
            let ownership = WorktreeOwnershipStore()
            let core = AgentSessionAdministrationCore.makeProduction(scopes: scopes, worktreeOwnership: ownership)
            let location = HistoryWorkspaceLocation(
                runtimeID: UUID(), workspaceID: workspace.id, name: workspace.name,
                directory: WorkspaceSessionSidecarMigration.workspaceDirectory(
                    for: workspace, root: git.sandbox.appendingPathComponent("sessions")
                )
            )
            let locations = HistoryWorkspaceLocationResolver(resolve: { selector in
                switch selector {
                case let .id(id) where id == location.workspaceID: .matched(location)
                case let .exactName(name) where name == location.name: .matched(location)
                default: .notRegistered
                }
            })
            let door = AgentSessionAdministrationFrontDoor.production(core: core, scopes: scopes, workspaceLocations: locations)
            door.registerStructureHandlers(scopes: scopes, worktreeOwnership: ownership)
            var service = SessionAdminMCPToolService(
                captureRequestMetadata: { .init(connectionID: UUID(), clientName: "worktree-recovery-test", windowID: window.windowID) },
                requireTargetWindow: { window },
                resolveObserverEndpoint: { _, _ in viewModel.agentSessionLinkObserverEndpoint(tabID: foregroundTabID) },
                scopes: { scopes }, administration: { door }
            )
            service.isToolEnabled = { true }
            try await body(.init(
                git: git, repository: repository, window: window, replica: replica, session: session, sessionID: sessionID,
                workspaceID: workspace.id, foregroundTabID: foregroundTabID, dataService: dataService,
                ownership: ownership, service: service
            ))
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }
}
