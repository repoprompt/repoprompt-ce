import Foundation
import MCP
@_spi(TestSupport) @testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptPersistence
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

    // MARK: - Target default repository election (#1431)

    // Declared [alpha, beta, gamma] is installed [beta, gamma, alpha], so a first-loaded default (beta) can never
    // pass by accident. The caller's own bindings differ from the target's, so a caller-routed default fails too.

    func testTargetWithoutBindingsCreatesInDeclaredPrimaryNotCallerOrFirstLoadedRoot() async throws {
        try await withFixture(election: true) { fixture in
            let repos = try XCTUnwrap(fixture.election)
            fixture.callerSession.worktreeBindings = try [
                fixture.binding(logical: repos.alpha, worktree: repos.alphaPrime),
                fixture.binding(logical: repos.beta, worktree: repos.betaPrime)
            ]
            let callerBindings = fixture.callerSession.worktreeBindings
            let created = try await fixture.call([
                "op": .string("worktree_create"), "session_id": .string(fixture.sessionID.uuidString),
                "branch": .string("e2e/target-primary"), "idempotency_key": .string("target-primary")
            ])
            XCTAssertEqual(created["result"], .string("created"), Self.json(created))
            let worktree = try XCTUnwrap(created["worktree"]?.objectValue, Self.json(created))
            let path = try URL(fileURLWithPath: XCTUnwrap(worktree["path"]?.stringValue))
            XCTAssertEqual(fixture.repositoryID(path), fixture.repositoryID(repos.alpha), "created in declared PRIMARY")
            XCTAssertEqual(try fixture.head(path), try fixture.head(repos.alpha))
            XCTAssertEqual(
                fixture.targetBindingMap(), try [Self.canonical(repos.alpha): XCTUnwrap(worktree["worktree_id"]?.stringValue)],
                "bound under the elected logical root"
            )
            XCTAssertEqual(fixture.callerSession.worktreeBindings, callerBindings)
        }
    }

    func testTargetSoleSecondaryBindingIsTheDefaultRatherThanCallerBindingOrCanonicalCheckout() async throws {
        try await withFixture(election: true) { fixture in
            let repos = try XCTUnwrap(fixture.election)
            fixture.callerSession.worktreeBindings = try [fixture.binding(logical: repos.alpha, worktree: repos.alphaPrime)]
            fixture.session.worktreeBindings = try [fixture.binding(logical: repos.beta, worktree: repos.betaPrime)]
            let callerBindings = fixture.callerSession.worktreeBindings
            let targetBindings = fixture.session.worktreeBindings
            let betaPrimeID = try fixture.worktreeID(repos.betaPrime)

            let current = try await fixture.call([
                "op": .string("worktree_bind"), "session_id": .string(fixture.sessionID.uuidString),
                "worktree": .string("@current"), "idempotency_key": .string("sole-secondary-current")
            ])
            let item = try XCTUnwrap(current["items"]?.arrayValue?.first?.objectValue, Self.json(current))
            XCTAssertEqual(item["result"], .string("bound"), Self.json(current))
            XCTAssertEqual(item["worktree"]?.objectValue?["worktree_id"], .string(betaPrimeID))
            // `@current` of the elected checkout keeps the same binding identity; the host only refreshes its metadata.
            XCTAssertEqual(fixture.targetBindingMap(), [Self.canonical(repos.beta): betaPrimeID])
            XCTAssertEqual(fixture.session.worktreeBindings.map(\.id), targetBindings.map(\.id))
            let boundBindings = fixture.session.worktreeBindings

            let created = try await fixture.call([
                "op": .string("worktree_create"), "session_id": .string(fixture.sessionID.uuidString),
                "branch": .string("e2e/sole-secondary"), "bind": .bool(false), "idempotency_key": .string("sole-secondary")
            ])
            XCTAssertEqual(created["result"], .string("created"), Self.json(created))
            let worktree = try XCTUnwrap(created["worktree"]?.objectValue, Self.json(created))
            let path = try URL(fileURLWithPath: XCTUnwrap(worktree["path"]?.stringValue))
            XCTAssertEqual(fixture.repositoryID(path), fixture.repositoryID(repos.beta))
            XCTAssertEqual(try fixture.head(path), try fixture.head(repos.betaPrime), "created from the bound checkout, not canonical beta")
            XCTAssertEqual(
                worktree["repo_root"]?.stringValue.map(Self.canonical), Self.canonical(repos.beta),
                "the reported repository stays the canonical root so the next_call replays"
            )
            XCTAssertEqual(fixture.session.worktreeBindings, boundBindings)

            // The receipt's next_call replays verbatim and replaces the sole binding under its logical root.
            let next = try XCTUnwrap(created["next_call"]?.objectValue?["arguments"]?.objectValue, Self.json(created))
            let replayed = try await fixture.call(next)
            XCTAssertEqual(replayed["items"]?.arrayValue?.first?.objectValue?["result"], .string("bound"), Self.json(replayed))
            XCTAssertEqual(fixture.targetBindingMap(), try [Self.canonical(repos.beta): XCTUnwrap(worktree["worktree_id"]?.stringValue)])
            XCTAssertEqual(fixture.callerSession.worktreeBindings, callerBindings)
        }
    }

    func testTargetMultipleBindingsRefuseRelativeDefaultsButIdentifyingSelectorsStillBind() async throws {
        try await withFixture(election: true) { fixture in
            let repos = try XCTUnwrap(fixture.election)
            fixture.session.worktreeBindings = try [
                fixture.binding(logical: repos.alpha, worktree: repos.alphaPrime),
                fixture.binding(logical: repos.beta, worktree: repos.betaPrime)
            ]
            let original = fixture.session.worktreeBindings
            let registrations = try fixture.registrations()

            let refusedCreate = try await fixture.call([
                "op": .string("worktree_create"), "session_id": .string(fixture.sessionID.uuidString),
                "branch": .string("e2e/ambiguous"), "idempotency_key": .string("ambiguous-create")
            ])
            XCTAssertEqual(refusedCreate["code"], .string("invalid_request"), Self.json(refusedCreate))
            fixture.assertMultipleBindingRefusal(refusedCreate["detail"]?.stringValue)
            XCTAssertEqual(try fixture.registrations(), registrations, "refused before any checkout is registered")
            XCTAssertTrue(fixture.ownership.records.isEmpty)

            for selector in ["@current", "@main:\(ElectionRepositories.topicBranch)"] {
                let refused = try await fixture.call([
                    "op": .string("worktree_bind"), "session_id": .string(fixture.sessionID.uuidString),
                    "worktree": .string(selector), "idempotency_key": .string("ambiguous-\(selector)")
                ])
                let item = try XCTUnwrap(refused["items"]?.arrayValue?.first?.objectValue, Self.json(refused))
                XCTAssertEqual(item["result"], .string("not_applied"), Self.json(refused))
                fixture.assertMultipleBindingRefusal(item["detail"]?.stringValue)
                XCTAssertEqual(fixture.session.worktreeBindings, original)
            }

            // An identifying selector names its own repository and logical root; the unrelated binding stays.
            let topicID = try fixture.worktreeID(repos.alphaTopic)
            let bound = try await fixture.call([
                "op": .string("worktree_bind"), "session_id": .string(fixture.sessionID.uuidString),
                "worktree": .string("@id:\(topicID)"), "idempotency_key": .string("identified-topic")
            ])
            XCTAssertEqual(bound["items"]?.arrayValue?.first?.objectValue?["result"], .string("bound"), Self.json(bound))
            XCTAssertEqual(fixture.targetBindingMap(), try [
                Self.canonical(repos.alpha): topicID,
                Self.canonical(repos.beta): fixture.worktreeID(repos.betaPrime)
            ])

            let explicit = try await fixture.call([
                "op": .string("worktree_create"), "session_id": .string(fixture.sessionID.uuidString),
                "repo_root": .string(repos.gamma.path), "branch": .string("e2e/explicit-gamma"), "bind": .bool(false),
                "idempotency_key": .string("explicit-gamma")
            ])
            XCTAssertEqual(explicit["result"], .string("created"), Self.json(explicit))
            let explicitPath = try URL(fileURLWithPath: XCTUnwrap(explicit["worktree"]?.objectValue?["path"]?.stringValue))
            XCTAssertEqual(fixture.repositoryID(explicitPath), fixture.repositoryID(repos.gamma))
        }
    }

    func testDeferredRelativeBindResolvesTheTargetDefaultAtTheIdleBoundary() async throws {
        try await withFixture(election: true) { fixture in
            let repos = try XCTUnwrap(fixture.election)
            fixture.session.mcpFollowUpRunPending = true
            let queued = try await fixture.call([
                "op": .string("worktree_bind"), "session_id": .string(fixture.sessionID.uuidString),
                "worktree": .string("@main:\(ElectionRepositories.topicBranch)"), "apply": .string("next_boundary"),
                "idempotency_key": .string("deferred-topic")
            ])
            XCTAssertEqual(queued["items"]?.arrayValue?.first?.objectValue?["result"], .string("queued"), Self.json(queued))
            // Caller state changes while queued; the stored request has no repo_root and must not follow it.
            fixture.callerSession.worktreeBindings = try [fixture.binding(logical: repos.beta, worktree: repos.betaPrime)]
            let callerBindings = fixture.callerSession.worktreeBindings
            fixture.session.mcpFollowUpRunPending = false

            let outcome = try await fixture.deferredOutcome()
            let topicID = try fixture.worktreeID(repos.alphaTopic)
            XCTAssertEqual(outcome["result"], .string("applied"), Self.json(.object(outcome)))
            XCTAssertEqual(outcome["worktree_id"], .string(topicID), "relative to the target's declared PRIMARY")
            XCTAssertEqual(fixture.targetBindingMap(), [Self.canonical(repos.alpha): topicID])
            let saved = try await fixture.savedSession()
            let persisted = try XCTUnwrap(saved)
            XCTAssertEqual(persisted.worktreeBindings.map(\.worktreeID), [topicID])
            XCTAssertEqual(persisted.worktreeBindings.map { Self.canonical($0.logicalRootPath) }, [Self.canonical(repos.alpha)])
            XCTAssertEqual(fixture.callerSession.worktreeBindings, callerBindings)
        }
    }

    func testDeferredRelativeBindRecapturesTargetBindingsChangedWhileQueued() async throws {
        try await withFixture(election: true) { fixture in
            let repos = try XCTUnwrap(fixture.election)
            fixture.session.worktreeBindings = try [fixture.binding(logical: repos.beta, worktree: repos.betaPrime)]
            fixture.session.mcpFollowUpRunPending = true
            let queued = try await fixture.call([
                "op": .string("worktree_bind"), "session_id": .string(fixture.sessionID.uuidString),
                "worktree": .string("@main:\(ElectionRepositories.topicBranch)"), "apply": .string("next_boundary"),
                "idempotency_key": .string("deferred-recapture")
            ])
            XCTAssertEqual(queued["items"]?.arrayValue?.first?.objectValue?["result"], .string("queued"), Self.json(queued))
            // The default at queue time (beta') is not pinned: the attempt captures the target as it is then.
            fixture.session.worktreeBindings = try [fixture.binding(logical: repos.alpha, worktree: repos.alphaPrime)]
            fixture.session.mcpFollowUpRunPending = false

            let outcome = try await fixture.deferredOutcome()
            let topicID = try fixture.worktreeID(repos.alphaTopic)
            XCTAssertEqual(outcome["result"], .string("applied"), Self.json(.object(outcome)))
            XCTAssertEqual(outcome["worktree_id"], .string(topicID))
            XCTAssertEqual(fixture.targetBindingMap(), [Self.canonical(repos.alpha): topicID])
        }
    }

    func testExplicitCanonicalRepoRootKeepsCanonicalCheckoutWhileOmittedDefaultUsesBoundCheckout() async throws {
        try await withFixture(election: true) { fixture in
            let repos = try XCTUnwrap(fixture.election)
            fixture.session.worktreeBindings = try [fixture.binding(logical: repos.alpha, worktree: repos.alphaPrime)]

            let explicit = try await fixture.call([
                "op": .string("worktree_create"), "session_id": .string(fixture.sessionID.uuidString),
                "repo_root": .string(repos.alpha.path), "branch": .string("e2e/explicit-canonical"), "bind": .bool(false),
                "idempotency_key": .string("explicit-canonical")
            ])
            XCTAssertEqual(explicit["result"], .string("created"), Self.json(explicit))
            let explicitPath = try URL(fileURLWithPath: XCTUnwrap(explicit["worktree"]?.objectValue?["path"]?.stringValue))
            XCTAssertEqual(try fixture.head(explicitPath), try fixture.head(repos.alpha), "an explicit canonical path is not projected")

            let elected = try await fixture.call([
                "op": .string("worktree_create"), "session_id": .string(fixture.sessionID.uuidString),
                "branch": .string("e2e/elected-default"), "bind": .bool(false), "idempotency_key": .string("elected-default")
            ])
            XCTAssertEqual(elected["result"], .string("created"), Self.json(elected))
            let electedPath = try URL(fileURLWithPath: XCTUnwrap(elected["worktree"]?.objectValue?["path"]?.stringValue))
            XCTAssertEqual(try fixture.head(electedPath), try fixture.head(repos.alphaPrime), "the omitted default uses the bound checkout")

            // A repository outside the target's workspace stays unauthorized.
            let outsider = try fixture.git.makeRepository(named: "outsider", files: ["outsider.txt": "outsider\n"])
            let before = try fixture.git.runGit(["worktree", "list", "--porcelain"], at: outsider)
            let refused = try await fixture.call([
                "op": .string("worktree_create"), "session_id": .string(fixture.sessionID.uuidString),
                "repo_root": .string(outsider.path), "branch": .string("e2e/outsider"), "idempotency_key": .string("outsider")
            ])
            XCTAssertEqual(refused["code"], .string("invalid_request"), Self.json(refused))
            XCTAssertEqual(try fixture.git.runGit(["worktree", "list", "--porcelain"], at: outsider), before)
        }
    }

    func testHeldResolutionAbortsWhenTargetBindingsOrDeclaredOrderChangeBeforeCommit() async throws {
        for change in ["bindings", "declared_order"] {
            let hold = DiscoveryHold()
            let live = GitRepoTargetResolver.Dependencies.live
            let resolver = GitRepoTargetResolver(dependencies: .init(
                resolveRepo: live.resolveRepo,
                listWorktrees: { repo in
                    await hold.pass()
                    return try await live.listWorktrees(repo)
                }
            ))
            try await withFixture(election: true, resolver: resolver) { fixture in
                let repos = try XCTUnwrap(fixture.election)
                let topicID = try fixture.worktreeID(repos.alphaTopic)
                await hold.arm()
                let request = Task { @MainActor in
                    try await fixture.call([
                        "op": .string("worktree_bind"), "session_id": .string(fixture.sessionID.uuidString),
                        "worktree": .string("@id:\(topicID)"), "idempotency_key": .string("held-\(change)")
                    ])
                }
                await hold.waitUntilHeld()
                switch change {
                case "bindings":
                    fixture.session.worktreeBindings = try [fixture.binding(logical: repos.beta, worktree: repos.betaPrime)]
                default:
                    let index = try XCTUnwrap(fixture.window.workspaceManager.workspaces.firstIndex { $0.id == fixture.workspaceID })
                    fixture.window.workspaceManager.workspaces[index].repoPaths = [repos.beta, repos.alpha, repos.gamma].map(\.path)
                }
                let expected = fixture.session.worktreeBindings
                await hold.release()
                let reply = try await request.value
                let item = try XCTUnwrap(reply["items"]?.arrayValue?.first?.objectValue, Self.json(reply))
                XCTAssertEqual(item["code"], .string("scope_revoked"), "\(change): \(Self.json(reply))")
                XCTAssertEqual(fixture.session.worktreeBindings, expected, change)
            }
        }
    }

    func testMergeApplyWithMultipleBindingsUsesSavedEndpointsNotDefaultElection() async throws {
        try await withFixture(election: true, replicaHoldsTarget: false) { fixture in
            let repos = try XCTUnwrap(fixture.election)
            fixture.session.worktreeBindings = try [
                fixture.binding(logical: repos.alpha, worktree: repos.alphaPrime),
                fixture.binding(logical: repos.beta, worktree: repos.betaPrime)
            ]
            // A non-previewed saved operation fails only inside the saved-endpoint apply, after the host's
            // capture-only admission; default election would refuse earlier with an ambiguity. Both endpoints sit
            // inside workspace roots: the host admits a linked endpoint only when its own checkout root is a
            // workspace repository, which is separate from #1431.
            let operation = try Self.savedMergeOperation(source: repos.gamma, target: repos.alpha, status: .cancelled)
            fixture.session.worktreeMergeOperations = [operation]
            let text: String
            do {
                text = try await Self.json(.object(fixture.call([
                    "op": .string("merge_apply"), "session_id": .string(fixture.sessionID.uuidString),
                    "operation_id": .string(operation.id), "idempotency_key": .string("merge-apply-saved")
                ])))
            } catch {
                text = "\(error) \(error.localizedDescription)"
            }
            XCTAssertTrue(text.contains("apply is only valid for a previewed worktree merge operation"), text)
            XCTAssertFalse(text.contains("worktree bindings"), text)
        }
    }

    func testIdentityReleaseRecoversUnavailableCheckoutDespiteMultipleBindings() async throws {
        try await withFixture(election: true) { fixture in
            let repos = try XCTUnwrap(fixture.election)
            fixture.session.worktreeBindings = try [
                fixture.binding(logical: repos.alpha, worktree: repos.alphaPrime),
                fixture.binding(logical: repos.beta, worktree: repos.betaPrime)
            ]
            let betaPrimeID = try fixture.worktreeID(repos.betaPrime)
            try FileManager.default.removeItem(at: repos.betaPrime)
            let released = try await fixture.call([
                "op": .string("worktree_release"), "session_id": .string(fixture.sessionID.uuidString),
                "worktree_id": .string(betaPrimeID)
            ])
            XCTAssertEqual(released["result"], .string("applied"), Self.json(released))
            XCTAssertEqual(fixture.targetBindingMap(), try [Self.canonical(repos.alpha): fixture.worktreeID(repos.alphaPrime)])
        }
    }

    func testCreateFollowedByBusyBindKeepsOwnershipAndPartialReceiptInElectedRepository() async throws {
        try await withFixture(election: true) { fixture in
            let repos = try XCTUnwrap(fixture.election)
            fixture.session.mcpFollowUpRunPending = true
            let reply = try await fixture.call([
                "op": .string("worktree_create"), "session_id": .string(fixture.sessionID.uuidString),
                "branch": .string("e2e/partial"), "idempotency_key": .string("partial-create")
            ])
            XCTAssertEqual(reply["result"], .string("partial"), Self.json(reply))
            let worktree = try XCTUnwrap(reply["worktree"]?.objectValue, Self.json(reply))
            let worktreeID = try XCTUnwrap(worktree["worktree_id"]?.stringValue)
            let path = try URL(fileURLWithPath: XCTUnwrap(worktree["path"]?.stringValue))
            XCTAssertEqual(fixture.repositoryID(path), fixture.repositoryID(repos.alpha))
            XCTAssertNotNil(fixture.ownership.record(worktreeID: worktreeID), "committed creation keeps its ownership")
            XCTAssertEqual(reply["affected"]?.objectValue?["worktree_ids"], .array([.string(worktreeID)]))
            XCTAssertTrue(fixture.session.worktreeBindings.isEmpty)

            fixture.session.mcpFollowUpRunPending = false
            let next = try XCTUnwrap(reply["next_call"]?.objectValue?["arguments"]?.objectValue, Self.json(reply))
            let replayed = try await fixture.call(next)
            XCTAssertEqual(replayed["items"]?.arrayValue?.first?.objectValue?["result"], .string("bound"), Self.json(replayed))
            XCTAssertEqual(fixture.targetBindingMap(), [Self.canonical(repos.alpha): worktreeID])
        }
    }

    // MARK: - Two checkouts of one repository (#1431)

    // The workspace declares alpha (PRIMARY, the main checkout) and alpha' (a linked checkout of the same repository).
    // A new alpha worktree is not a loaded root and both declared checkouts own it, so an unqualified `@id:` is
    // ambiguous; a creation's bind and its recovery calls carry the root that creation elected instead.

    private static func sameRepositoryRoots(primaryInstalledFirst: Bool) -> ElectionRoots {
        { repos in
            (
                declared: [repos.alpha, repos.alphaPrime],
                installed: primaryInstalledFirst ? [repos.alpha, repos.alphaPrime] : [repos.alphaPrime, repos.alpha]
            )
        }
    }

    func testCreateDefaultBindUsesTheElectedRootWhenTwoCheckoutsShareItsRepository() async throws {
        for primaryInstalledFirst in [true, false] {
            let order = primaryInstalledFirst ? "alpha installed first" : "alpha' installed first"
            try await withFixture(election: true, electionRoots: Self.sameRepositoryRoots(primaryInstalledFirst: primaryInstalledFirst)) { fixture in
                let repos = try XCTUnwrap(fixture.election)
                let checkouts = try fixture.worktreeCount(repos.alpha)
                let created = try await fixture.call([
                    "op": .string("worktree_create"), "session_id": .string(fixture.sessionID.uuidString),
                    "branch": .string("e2e/shared-default"), "idempotency_key": .string("shared-default")
                ])
                XCTAssertEqual(created["result"], .string("created"), "\(order): \(Self.json(created))")
                XCTAssertEqual(created["bound"], .bool(true), order)
                let worktreeID = try XCTUnwrap(created["worktree"]?.objectValue?["worktree_id"]?.stringValue, Self.json(created))
                XCTAssertEqual(try fixture.worktreeCount(repos.alpha), checkouts + 1, "\(order): exactly one new checkout")
                XCTAssertEqual(fixture.targetBindingMap(), [Self.canonical(repos.alpha): worktreeID], order)
                let saved = try await fixture.savedSession()
                let persisted = try XCTUnwrap(saved, order)
                XCTAssertEqual(persisted.worktreeBindings.map(\.worktreeID), [worktreeID], order)
                XCTAssertEqual(persisted.worktreeBindings.map { Self.canonical($0.logicalRootPath) }, [Self.canonical(repos.alpha)], order)
            }
        }
    }

    func testDeferredCreateBindAppliesTheSameCheckoutUnderTheElectedRootWhenTwoCheckoutsShareItsRepository() async throws {
        try await withFixture(election: true, electionRoots: Self.sameRepositoryRoots(primaryInstalledFirst: false)) { fixture in
            let repos = try XCTUnwrap(fixture.election)
            let checkouts = try fixture.worktreeCount(repos.alpha)
            fixture.session.mcpFollowUpRunPending = true
            let created = try await fixture.call([
                "op": .string("worktree_create"), "session_id": .string(fixture.sessionID.uuidString),
                "branch": .string("e2e/shared-deferred"), "apply": .string("next_boundary"),
                "idempotency_key": .string("shared-deferred")
            ])
            XCTAssertEqual(created["result"], .string("created"), Self.json(created))
            XCTAssertEqual(created["binding"]?.objectValue?["result"], .string("queued"), Self.json(created))
            let worktreeID = try XCTUnwrap(created["worktree"]?.objectValue?["worktree_id"]?.stringValue, Self.json(created))
            fixture.session.mcpFollowUpRunPending = false

            let outcome = try await fixture.deferredOutcome()
            XCTAssertEqual(outcome["result"], .string("applied"), Self.json(.object(outcome)))
            XCTAssertNil(outcome["subreason"], Self.json(.object(outcome)))
            XCTAssertEqual(outcome["worktree_id"], .string(worktreeID))
            XCTAssertEqual(fixture.targetBindingMap(), [Self.canonical(repos.alpha): worktreeID])
            XCTAssertEqual(try fixture.worktreeCount(repos.alpha), checkouts + 1, "no second creation")
            XCTAssertEqual(Array(fixture.ownership.records.keys), [worktreeID])
            let saved = try await fixture.savedSession()
            let persisted = try XCTUnwrap(saved)
            XCTAssertEqual(persisted.worktreeBindings.map { Self.canonical($0.logicalRootPath) }, [Self.canonical(repos.alpha)])
        }
    }

    func testBusyCreateBindRecoveryCallCarriesTheElectedRootWhenTwoCheckoutsShareItsRepository() async throws {
        try await withFixture(election: true, electionRoots: Self.sameRepositoryRoots(primaryInstalledFirst: false)) { fixture in
            let repos = try XCTUnwrap(fixture.election)
            fixture.session.mcpFollowUpRunPending = true
            let created = try await fixture.call([
                "op": .string("worktree_create"), "session_id": .string(fixture.sessionID.uuidString),
                "branch": .string("e2e/shared-busy"), "idempotency_key": .string("shared-busy")
            ])
            XCTAssertEqual(created["result"], .string("partial"), Self.json(created))
            let worktreeID = try XCTUnwrap(created["worktree"]?.objectValue?["worktree_id"]?.stringValue, Self.json(created))
            let binding = try XCTUnwrap(created["binding"]?.objectValue, Self.json(created))
            XCTAssertEqual(binding["code"], .string("target_busy"), Self.json(created))
            let next = try XCTUnwrap(binding["next_call"]?.objectValue?["arguments"]?.objectValue, Self.json(created))
            let reported = try XCTUnwrap(created["worktree"]?.objectValue?["repo_root"]?.stringValue, Self.json(created))
            XCTAssertEqual(Self.canonical(reported), Self.canonical(repos.alpha))
            XCTAssertEqual(next["repo_root"], .string("\(reported)@current"))
            fixture.session.mcpFollowUpRunPending = false

            let replayed = try await fixture.call(next)
            XCTAssertEqual(replayed["items"]?.arrayValue?.first?.objectValue?["result"], .string("bound"), Self.json(replayed))
            XCTAssertEqual(fixture.targetBindingMap(), [Self.canonical(repos.alpha): worktreeID])
        }
    }

    func testStandaloneIdentifyingBindStillRefusesTwoOwningCheckoutsWithoutRepoRoot() async throws {
        try await withFixture(election: true, electionRoots: Self.sameRepositoryRoots(primaryInstalledFirst: true)) { fixture in
            let repos = try XCTUnwrap(fixture.election)
            let topicID = try fixture.worktreeID(repos.alphaTopic)
            let original = fixture.session.worktreeBindings
            let savedBefore = try await fixture.savedSession()?.worktreeBindings

            let refused = try await fixture.call([
                "op": .string("worktree_bind"), "session_id": .string(fixture.sessionID.uuidString),
                "worktree": .string("@id:\(topicID)"), "idempotency_key": .string("shared-ambiguous-id")
            ])
            let item = try XCTUnwrap(refused["items"]?.arrayValue?.first?.objectValue, Self.json(refused))
            XCTAssertEqual(item["result"], .string("not_applied"), Self.json(refused))
            XCTAssertEqual(item[AgentSessionAdminRendering.committedChangesKey], .bool(false), Self.json(refused))
            let detail = item["detail"]?.stringValue ?? ""
            XCTAssertTrue(detail.contains("2 checkouts in the target's workspace") && detail.contains("Pass repo_root"), detail)
            XCTAssertEqual(fixture.session.worktreeBindings, original)
            let savedAfter = try await fixture.savedSession()?.worktreeBindings
            XCTAssertEqual(savedAfter, savedBefore)

            // Naming a root binds the same selector under that root, even the non-PRIMARY one.
            let qualified = try await fixture.call([
                "op": .string("worktree_bind"), "session_id": .string(fixture.sessionID.uuidString),
                "worktree": .string("@id:\(topicID)"), "repo_root": .string(repos.alphaPrime.path),
                "idempotency_key": .string("shared-qualified-id")
            ])
            XCTAssertEqual(qualified["items"]?.arrayValue?.first?.objectValue?["result"], .string("bound"), Self.json(qualified))
            XCTAssertEqual(fixture.targetBindingMap(), [Self.canonical(repos.alphaPrime): topicID])
        }
    }

    /// Two workspace roots in one checkout, alpha and its subdirectory lib (declared PRIMARY, installed second). A
    /// repository path names only alpha's first installed root, so a creation's explicit relative `repo_root` is kept
    /// for its bind and still attributes the binding to the logical root it elects.
    func testCreateWithExplicitRelativeRepoRootBindsUnderTheElectedSubdirectoryRoot() async throws {
        let roots: ElectionRoots = { repos in
            let lib = repos.alpha.appendingPathComponent("lib", isDirectory: true)
            try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
            try Data("lib\n".utf8).write(to: lib.appendingPathComponent("README.md"))
            return (declared: [lib, repos.alpha], installed: [repos.alpha, lib])
        }
        try await withFixture(election: true, electionRoots: roots) { fixture in
            let repos = try XCTUnwrap(fixture.election)
            let primary = repos.declared[0]
            let created = try await fixture.call([
                "op": .string("worktree_create"), "session_id": .string(fixture.sessionID.uuidString),
                "repo_root": .string("@current"), "branch": .string("e2e/subdirectory-current"),
                "idempotency_key": .string("subdirectory-current")
            ])
            XCTAssertEqual(created["result"], .string("created"), Self.json(created))
            XCTAssertEqual(created["bound"], .bool(true), Self.json(created))
            let worktreeID = try XCTUnwrap(created["worktree"]?.objectValue?["worktree_id"]?.stringValue, Self.json(created))
            XCTAssertEqual(
                fixture.targetBindingMap(), [Self.canonical(primary): worktreeID],
                "bound under the elected PRIMARY root, not the first installed root of its repository"
            )
        }
    }

    // MARK: - Literal repository paths (#1431)

    // Repository A sits at `project@main` and a distinct repository B at `project`. Read as a selector, A's path names
    // B's main checkout, so every selector the handler generates from creation's elected path must keep it literal.

    private static let selectorLookalikeNames = (alpha: "project@main", beta: "project")

    private static func lookalikeRoots(includeB: Bool = true, aInstalledFirst: Bool = true) -> ElectionRoots {
        { repos in
            let declared = includeB ? [repos.alpha, repos.beta] : [repos.alpha]
            return (declared: declared, installed: aInstalledFirst ? declared : declared.reversed())
        }
    }

    func testCreateDefaultBindKeepsARepositoryPathThatReadsAsASelectorLiteral() async throws {
        for aInstalledFirst in [true, false] {
            let order = aInstalledFirst ? "A installed first" : "B installed first"
            try await withFixture(
                election: true, electionRepositoryNames: Self.selectorLookalikeNames,
                electionRoots: Self.lookalikeRoots(aInstalledFirst: aInstalledFirst)
            ) { fixture in
                let repos = try XCTUnwrap(fixture.election)
                XCTAssertEqual([repos.alpha.lastPathComponent, repos.beta.lastPathComponent], ["project@main", "project"])
                let aCheckouts = try fixture.worktreeCount(repos.alpha)
                let bCheckouts = try fixture.worktreeCount(repos.beta)
                let request: [String: Value] = [
                    "op": .string("worktree_create"), "session_id": .string(fixture.sessionID.uuidString),
                    "branch": .string("e2e/literal-default"), "idempotency_key": .string("literal-default")
                ]
                let created = try await fixture.call(request)
                XCTAssertEqual(created["result"], .string("created"), "\(order): \(Self.json(created))")
                XCTAssertEqual(created["bound"], .bool(true), order)
                let worktree = try XCTUnwrap(created["worktree"]?.objectValue, Self.json(created))
                let worktreeID = try XCTUnwrap(worktree["worktree_id"]?.stringValue)
                let path = try URL(fileURLWithPath: XCTUnwrap(worktree["path"]?.stringValue))
                XCTAssertEqual(fixture.repositoryID(path), fixture.repositoryID(repos.alpha), "\(order): created in A")
                XCTAssertEqual(try fixture.worktreeCount(repos.alpha), aCheckouts + 1, order)
                XCTAssertEqual(try fixture.worktreeCount(repos.beta), bCheckouts, order)
                try await fixture.assertSoleBinding(logical: repos.alpha, worktreeID: worktreeID, order)
                XCTAssertEqual(
                    fixture.ownership.record(worktreeID: worktreeID)?.repoRootPath.map(Self.canonical), Self.canonical(repos.alpha),
                    "\(order): ownership keeps the literal path"
                )

                // The creation key replays its receipt rather than creating again.
                _ = try await fixture.call(request)
                XCTAssertEqual(try fixture.worktreeCount(repos.alpha), aCheckouts + 1, order)
                XCTAssertEqual(fixture.ownership.records.count, 1, order)
            }
        }
    }

    func testDeferredCreateBindKeepsARepositoryPathThatReadsAsASelectorLiteral() async throws {
        try await withFixture(
            election: true, electionRepositoryNames: Self.selectorLookalikeNames,
            electionRoots: Self.lookalikeRoots(aInstalledFirst: false)
        ) { fixture in
            let repos = try XCTUnwrap(fixture.election)
            let aCheckouts = try fixture.worktreeCount(repos.alpha)
            let bCheckouts = try fixture.worktreeCount(repos.beta)
            fixture.session.mcpFollowUpRunPending = true
            let created = try await fixture.call([
                "op": .string("worktree_create"), "session_id": .string(fixture.sessionID.uuidString),
                "branch": .string("e2e/literal-deferred"), "apply": .string("next_boundary"),
                "idempotency_key": .string("literal-deferred")
            ])
            XCTAssertEqual(created["result"], .string("created"), Self.json(created))
            XCTAssertEqual(created["binding"]?.objectValue?["result"], .string("queued"), Self.json(created))
            let worktreeID = try XCTUnwrap(created["worktree"]?.objectValue?["worktree_id"]?.stringValue, Self.json(created))
            fixture.session.mcpFollowUpRunPending = false

            let outcome = try await fixture.deferredOutcome()
            XCTAssertEqual(outcome["result"], .string("applied"), Self.json(.object(outcome)))
            XCTAssertEqual(outcome["worktree_id"], .string(worktreeID))
            try await fixture.assertSoleBinding(logical: repos.alpha, worktreeID: worktreeID)
            XCTAssertEqual(try fixture.worktreeCount(repos.alpha), aCheckouts + 1, "no second creation")
            XCTAssertEqual(try fixture.worktreeCount(repos.beta), bCheckouts)
            XCTAssertEqual(Array(fixture.ownership.records.keys), [worktreeID])
        }
    }

    func testCreateDefaultBindCompletesForASoleRepositoryWhosePathReadsAsASelector() async throws {
        try await withFixture(
            election: true, electionRepositoryNames: Self.selectorLookalikeNames, electionRoots: Self.lookalikeRoots(includeB: false)
        ) { fixture in
            let repos = try XCTUnwrap(fixture.election)
            let created = try await fixture.call([
                "op": .string("worktree_create"), "session_id": .string(fixture.sessionID.uuidString),
                "branch": .string("e2e/literal-sole"), "idempotency_key": .string("literal-sole")
            ])
            XCTAssertEqual(created["result"], .string("created"), Self.json(created))
            XCTAssertEqual(created["bound"], .bool(true), Self.json(created))
            let worktreeID = try XCTUnwrap(created["worktree"]?.objectValue?["worktree_id"]?.stringValue, Self.json(created))
            try await fixture.assertSoleBinding(logical: repos.alpha, worktreeID: worktreeID)
        }
    }

    func testCreateRecoveryCallsReplayARepositoryPathThatReadsAsASelectorLiterally() async throws {
        try await withFixture(
            election: true, electionRepositoryNames: Self.selectorLookalikeNames, electionRoots: Self.lookalikeRoots()
        ) { fixture in
            let repos = try XCTUnwrap(fixture.election)
            let aCheckouts = try fixture.worktreeCount(repos.alpha)
            let bCheckouts = try fixture.worktreeCount(repos.beta)
            fixture.session.mcpFollowUpRunPending = true
            let created = try await fixture.call([
                "op": .string("worktree_create"), "session_id": .string(fixture.sessionID.uuidString),
                "branch": .string("e2e/literal-recovery"), "idempotency_key": .string("literal-recovery")
            ])
            XCTAssertEqual(created["result"], .string("partial"), Self.json(created))
            let worktree = try XCTUnwrap(created["worktree"]?.objectValue, Self.json(created))
            let worktreeID = try XCTUnwrap(worktree["worktree_id"]?.stringValue)
            let reported = try XCTUnwrap(worktree["repo_root"]?.stringValue)
            XCTAssertEqual(Self.canonical(reported), Self.canonical(repos.alpha), "the receipt reports the literal path")
            let receiptCall = try XCTUnwrap(created["next_call"]?.objectValue?["arguments"]?.objectValue, Self.json(created))
            let binding = try XCTUnwrap(created["binding"]?.objectValue, Self.json(created))
            XCTAssertEqual(binding["code"], .string("target_busy"), Self.json(created))
            let busyCall = try XCTUnwrap(binding["next_call"]?.objectValue?["arguments"]?.objectValue, Self.json(created))
            for call in [receiptCall, busyCall] {
                XCTAssertEqual(call["repo_root"], .string("\(reported)@current"), Self.json(.object(call)))
            }
            fixture.session.mcpFollowUpRunPending = false

            for (label, call) in [("busy recovery", busyCall), ("receipt", receiptCall)] {
                let replayed = try await fixture.call(call)
                XCTAssertEqual(replayed["items"]?.arrayValue?.first?.objectValue?["result"], .string("bound"), "\(label): \(Self.json(replayed))")
                try await fixture.assertSoleBinding(logical: repos.alpha, worktreeID: worktreeID, label)
            }
            XCTAssertEqual(try fixture.worktreeCount(repos.alpha), aCheckouts + 1)
            XCTAssertEqual(try fixture.worktreeCount(repos.beta), bCheckouts)
        }
    }

    func testCreateRecoverySelectorKeepsALinkedPrimaryCheckout() async throws {
        let roots: ElectionRoots = { repos in
            (declared: [repos.alphaPrime, repos.alpha], installed: [repos.alpha, repos.alphaPrime])
        }
        try await withFixture(election: true, electionRoots: roots) { fixture in
            let repos = try XCTUnwrap(fixture.election)
            let created = try await fixture.call([
                "op": .string("worktree_create"), "session_id": .string(fixture.sessionID.uuidString),
                "branch": .string("e2e/linked-primary"), "bind": .bool(false), "idempotency_key": .string("linked-primary")
            ])
            XCTAssertEqual(created["result"], .string("created"), Self.json(created))
            let worktree = try XCTUnwrap(created["worktree"]?.objectValue, Self.json(created))
            let worktreeID = try XCTUnwrap(worktree["worktree_id"]?.stringValue)
            let path = try URL(fileURLWithPath: XCTUnwrap(worktree["path"]?.stringValue))
            XCTAssertEqual(try fixture.head(path), try fixture.head(repos.alphaPrime), "created from the linked PRIMARY")
            let reported = try XCTUnwrap(worktree["repo_root"]?.stringValue)
            XCTAssertEqual(Self.canonical(reported), Self.canonical(repos.alphaPrime))
            let next = try XCTUnwrap(created["next_call"]?.objectValue?["arguments"]?.objectValue, Self.json(created))
            XCTAssertEqual(next["repo_root"], .string("\(reported)@current"))

            let replayed = try await fixture.call(next)
            XCTAssertEqual(replayed["items"]?.arrayValue?.first?.objectValue?["result"], .string("bound"), Self.json(replayed))
            try await fixture.assertSoleBinding(logical: repos.alphaPrime, worktreeID: worktreeID)
        }
    }

    // MARK: - Error context (#1431)

    // The sole target binding beta -> beta' elects checkout beta', which differs from its logical root beta: each
    // failure names the checkout Git ran in, the requested branch/ref, and keeps the logical root legible.

    func testBranchExistsRefusalsNameTheExecutionCheckoutAndKeepReplayableRecovery() async throws {
        try await withFixture(election: true) { fixture in
            let repos = try XCTUnwrap(fixture.election)
            fixture.session.worktreeBindings = try [fixture.binding(logical: repos.beta, worktree: repos.betaPrime)]
            let registrations = try fixture.registrations()

            // No checkout holds the branch: the Git service refuses it before creation, and no bind is offered.
            try fixture.git.runGit(["branch", "e2e/no-checkout"], at: repos.beta)
            let bare = try await fixture.call([
                "op": .string("worktree_create"), "session_id": .string(fixture.sessionID.uuidString),
                "branch": .string("e2e/no-checkout"), "idempotency_key": .string("context-bare-branch")
            ])
            XCTAssertEqual(bare["code"], .string("branch_exists"), Self.json(bare))
            XCTAssertNil(bare["next_call"], Self.json(bare))
            let bareDetail = bare["detail"]?.stringValue ?? ""
            for fragment in ["Branch 'e2e/no-checkout' already exists", "new branch name", "Nothing was created."] {
                XCTAssertTrue(bareDetail.contains(fragment), bareDetail)
            }
            XCTAssertTrue(Self.names(bareDetail, "repository ", repos.betaPrime), bareDetail)
            XCTAssertTrue(Self.names(bareDetail, "workspace root ", repos.beta), bareDetail)

            // A checkout holds the branch: refused before creation, with a bind of that checkout as the recovery.
            let held = try await fixture.call([
                "op": .string("worktree_create"), "session_id": .string(fixture.sessionID.uuidString),
                "branch": .string(ElectionRepositories.topicBranch), "idempotency_key": .string("context-held-branch")
            ])
            XCTAssertEqual(held["code"], .string("branch_exists"), Self.json(held))
            let heldDetail = held["detail"]?.stringValue ?? ""
            for fragment in ["Branch '\(ElectionRepositories.topicBranch)' already exists", "Nothing was created."] {
                XCTAssertTrue(heldDetail.contains(fragment), heldDetail)
            }
            XCTAssertTrue(Self.names(heldDetail, "checked out at ", repos.betaTopic), heldDetail)
            XCTAssertTrue(Self.names(heldDetail, "repository ", repos.betaPrime), heldDetail)
            XCTAssertTrue(Self.names(heldDetail, "workspace root ", repos.beta), heldDetail)
            XCTAssertEqual(try fixture.registrations(), registrations, "neither refusal registers a checkout")
            XCTAssertTrue(fixture.ownership.records.isEmpty)

            // The recovery replays verbatim and binds the holding checkout under the same logical root.
            let next = try XCTUnwrap(held["next_call"]?.objectValue?["arguments"]?.objectValue, Self.json(held))
            let bound = try await fixture.call(next)
            XCTAssertEqual(bound["items"]?.arrayValue?.first?.objectValue?["result"], .string("bound"), Self.json(bound))
            XCTAssertEqual(fixture.targetBindingMap(), try [Self.canonical(repos.beta): fixture.worktreeID(repos.betaTopic)])
        }
    }

    func testInvalidBaseRefRefusesBeforeCreationWhileAnActualAddFailureClaimsNothingCreated() async throws {
        try await withFixture(election: true) { fixture in
            let repos = try XCTUnwrap(fixture.election)
            fixture.session.worktreeBindings = try [fixture.binding(logical: repos.beta, worktree: repos.betaPrime)]
            let bindings = fixture.session.worktreeBindings
            let registrations = try fixture.registrations()

            // An unresolvable base ref is refused by the Git service's preflight, before the commit fence.
            let invalid = await Self.failure {
                try await fixture.call([
                    "op": .string("worktree_create"), "session_id": .string(fixture.sessionID.uuidString),
                    "branch": .string("e2e/bad-base"), "base_ref": .string("no-such-ref"),
                    "idempotency_key": .string("context-bad-base")
                ])
            }
            for fragment in [
                "refused before creation", "base ref 'no-such-ref' does not resolve to a commit", "branch 'e2e/bad-base'",
                "Nothing was created."
            ] {
                XCTAssertTrue(invalid.contains(fragment), invalid)
            }
            XCTAssertTrue(Self.names(invalid, "repository ", repos.betaPrime), invalid)
            XCTAssertTrue(Self.names(invalid, "Workspace root ", repos.beta), invalid)
            XCTAssertThrowsError(try fixture.git.runGit(["show-ref", "--verify", "--quiet", "refs/heads/e2e/bad-base"], at: repos.beta))
            XCTAssertEqual(try fixture.registrations(), registrations, "the refusal registers no checkout")

            // A ref whose text contains "already exists" is still an invalid ref, not a branch conflict: the Git
            // service classifies the failure rather than the host searching a message that carries refs and paths.
            let oddRef = await Self.failure {
                try await fixture.call([
                    "op": .string("worktree_create"), "session_id": .string(fixture.sessionID.uuidString),
                    "branch": .string("e2e/odd-base"), "base_ref": .string("already exists"),
                    "idempotency_key": .string("context-odd-base")
                ])
            }
            XCTAssertTrue(oddRef.contains("base ref 'already exists' does not resolve to a commit"), oddRef)
            XCTAssertFalse(oddRef.contains("branch_exists"), oddRef)

            // `refs/heads/e2e/topic` exists, so Git cannot create `e2e/topic/child`; the preflight cannot know that.
            // The failure is Git's own, from `git worktree add` past the commit fence, so it claims nothing about
            // what was created.
            let addFailure = await Self.failure {
                try await fixture.call([
                    "op": .string("worktree_create"), "session_id": .string(fixture.sessionID.uuidString),
                    "branch": .string("e2e/topic/child"), "idempotency_key": .string("context-add-failure")
                ])
            }
            for fragment in ["git worktree add failed", "refs/heads/e2e/topic", "branch 'e2e/topic/child'", "omitted; Git default"] {
                XCTAssertTrue(addFailure.contains(fragment), addFailure)
            }
            XCTAssertTrue(Self.names(addFailure, "repository ", repos.betaPrime), addFailure)
            XCTAssertTrue(Self.names(addFailure, "Workspace root ", repos.beta), addFailure)
            let container = GitWorktreeDefaultPathPlanner.defaultContainer(forMainWorktreeRoot: repos.beta)
            XCTAssertTrue(Self.names(addFailure, "destination ", container), addFailure)
            XCTAssertFalse(addFailure.contains("Nothing was created"), addFailure)
            XCTAssertFalse(addFailure.contains("refused before creation"), addFailure)
            XCTAssertTrue(fixture.ownership.records.isEmpty, "neither failure returned a worktree to own")
            XCTAssertEqual(fixture.session.worktreeBindings, bindings)
        }
    }

    func testDirectHeadAndRefLookupsNameTheRepositoryAndRequestedRevision() async throws {
        try await withFixture(election: true) { fixture in
            let repos = try XCTUnwrap(fixture.election)
            let service = GitService()
            let missingRef = await Self.failure { try await service.getRefSHA(at: repos.betaPrime, ref: "no-such-ref") }
            XCTAssertTrue(missingRef.contains("requested ref 'no-such-ref'"), missingRef)
            XCTAssertTrue(Self.names(missingRef, "repository ", repos.betaPrime), missingRef)

            let unborn = fixture.git.sandbox.appendingPathComponent("unborn", isDirectory: true)
            try fixture.git.initializeRepository(at: unborn)
            let missingHead = await Self.failure { try await service.getHeadSHA(at: unborn) }
            XCTAssertTrue(missingHead.contains("requested HEAD"), missingHead)
            XCTAssertTrue(Self.names(missingHead, "repository ", unborn), missingHead)

            // Resolvable revisions still return their object IDs.
            let head = try await service.getHeadSHA(at: repos.betaPrime)
            XCTAssertEqual(head, try fixture.head(repos.betaPrime))
            let topic = try await service.getRefSHA(at: repos.betaPrime, ref: ElectionRepositories.topicBranch)
            XCTAssertEqual(topic, try fixture.head(repos.betaTopic))
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
        let callerSession: AgentTabSession
        let election: ElectionRepositories?

        func call(_ arguments: [String: Value]) async throws -> [String: Value] {
            let result = try await service.execute(args: arguments)
            return try XCTUnwrap(result.objectValue)
        }

        func binding(logical: URL, worktree: URL) throws -> AgentSessionWorktreeBinding {
            let identity = try XCTUnwrap(GitWorktreeIdentityResolver.resolve(atWorkTreeRoot: worktree))
            return AgentSessionWorktreeBinding(
                id: UUID().uuidString, repositoryID: identity.repository.repositoryID, repoKey: identity.repository.repoKey,
                logicalRootPath: logical.path, logicalRootName: logical.lastPathComponent,
                worktreeID: identity.worktreeID, worktreeRootPath: worktree.path,
                commonGitDir: identity.repository.commonGitDir, isMainWorktree: identity.isMain, source: "test"
            )
        }

        func worktreeID(_ root: URL) throws -> String {
            try XCTUnwrap(GitWorktreeIdentityResolver.resolve(atWorkTreeRoot: root)).worktreeID
        }

        func repositoryID(_ root: URL) -> String? {
            GitWorktreeIdentityResolver.resolve(atWorkTreeRoot: root)?.repository.repositoryID
        }

        func head(_ root: URL) throws -> String {
            try git.runGit(["rev-parse", "HEAD"], at: root).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// Git worktree registrations of every declared repository.
        func registrations() throws -> [String] {
            try (election?.declared ?? [repository]).map { try git.runGit(["worktree", "list", "--porcelain"], at: $0) }
        }

        /// Checkouts Git has registered for the repository at `root`.
        func worktreeCount(_ root: URL) throws -> Int {
            try git.runGit(["worktree", "list", "--porcelain"], at: root)
                .split(separator: "\n").count(where: { $0.hasPrefix("worktree ") })
        }

        /// The target's only binding, live and persisted, is `logical` -> `worktreeID`.
        func assertSoleBinding(
            logical: URL, worktreeID: String, _ message: String = "", file: StaticString = #filePath, line: UInt = #line
        ) async throws {
            let expected = [[SessionAdminWorktreeRecoveryTests.canonical(logical), worktreeID]]
            func rows(_ bindings: [AgentSessionWorktreeBinding]) -> [[String]] {
                bindings.map { [SessionAdminWorktreeRecoveryTests.canonical($0.logicalRootPath), $0.worktreeID] }
            }
            XCTAssertEqual(rows(session.worktreeBindings), expected, "live \(message)", file: file, line: line)
            let saved = try await savedSession()
            XCTAssertEqual(saved.map { rows($0.worktreeBindings) }, expected, "persisted \(message)", file: file, line: line)
        }

        /// Target bindings keyed by canonical logical root.
        func targetBindingMap() -> [String: String] {
            Dictionary(
                session.worktreeBindings.map { (SessionAdminWorktreeRecoveryTests.canonical($0.logicalRootPath), $0.worktreeID) },
                uniquingKeysWith: { first, _ in first }
            )
        }

        /// Waits through the production host's idle polling for the target's settled deferred bind.
        func deferredOutcome() async throws -> [String: Value] {
            var outcome: [String: Value]?
            try await AsyncTestWait.waitUntil("deferred bind settled", timeout: 20) {
                let inventory = try? await call(["op": .string("worktree_inventory")])
                outcome = inventory?["deferred_outcomes"]?.arrayValue?.first?.objectValue
                return outcome != nil
            }
            return try XCTUnwrap(outcome)
        }

        func assertMultipleBindingRefusal(_ detail: String?, file: StaticString = #filePath, line: UInt = #line) {
            let detail = detail ?? ""
            XCTAssertTrue(detail.contains("2 worktree bindings"), detail, file: file, line: line)
            if let election {
                XCTAssertTrue(detail.contains(election.alpha.path) && detail.contains(election.beta.path), detail, file: file, line: line)
            }
            XCTAssertFalse(detail.contains("DefaultRepositoryRequired"), detail, file: file, line: line)
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
    /// `election` declares the three `ElectionRepositories` roots and installs them in adversarial order;
    /// `electionRepositoryNames` names the alpha and beta repository directories; `electionRoots` replaces which of
    /// them are declared and their installation order.
    /// `replicaHoldsTarget: false` leaves the replica on its own workspace, for operations a replicated
    /// target never admits (merge apply).
    private func withFixture(
        fullAccess: Bool = true,
        election: Bool = false,
        electionRepositoryNames: (alpha: String, beta: String) = ("alpha", "beta"),
        electionRoots: ElectionRoots? = nil,
        replicaHoldsTarget: Bool = true,
        resolver: GitRepoTargetResolver = GitRepoTargetResolver(),
        _ body: (Fixture) async throws -> Void
    ) async throws {
        // Election repositories live under the resolved temporary directory so declared, loaded, and Git paths agree.
        let git = try ReviewGitRepositoryFixture(
            name: "SessionAdminWorktreeRecovery",
            parentDirectory: election ? FileManager.default.temporaryDirectory.resolvingSymlinksInPath() : nil
        )
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let replica = WindowState()
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(replica)
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        let previousFullAccess = OverseerGlobalAutoApprove.isEnabled
        OverseerGlobalAutoApprove.isEnabled = { fullAccess }
        let sessionID = UUID(), callerID = UUID()
        let cleanup: @MainActor () async -> Void = {
            let materializer = WorkspaceRootBindingProjectionMaterializer(store: window.promptManager.workspaceFileContextStore)
            await materializer.release(sessionID: sessionID)
            await materializer.release(sessionID: callerID)
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
            let electionRepositories = try election ? Self.makeElectionRepositories(git, names: electionRepositoryNames, roots: electionRoots) : nil
            let repository = try electionRepositories?.alpha
                ?? git.makeRepository(named: "repository", files: ["README.md": "fixture\n"])
            let declared = electionRepositories?.declared ?? [repository]
            await replica.workspaceManager.awaitInitialized()
            await window.workspaceManager.awaitInitialized()
            let created = window.workspaceManager.createWorkspace(name: "Worktree recovery", repoPaths: declared.map(\.path), ephemeral: true)
            await window.workspaceManager.switchWorkspace(to: created, saveState: false, reason: "worktreeRecoveryTest")
            if let electionRepositories {
                try await Self.installAdversarialOrder(electionRepositories, store: window.promptManager.workspaceFileContextStore)
            } else {
                _ = try await window.promptManager.workspaceFileContextStore.loadRoot(path: repository.path)
            }
            var workspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
            let foregroundTabID = try XCTUnwrap(workspace.activeComposeTabID)
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
            if replicaHoldsTarget {
                replica.workspaceManager.workspaces = [workspace]
                replica.workspaceManager.activeWorkspace = workspace
                replica.promptManager.loadComposeTabsFromWorkspace(workspace, syncPromptText: true)
                for tabID in Array(replica.agentModeViewModel.sessions.keys) {
                    replica.agentModeViewModel.test_removeSession(tabID: tabID)
                }
                replica.agentModeViewModel.test_installSessionIndexSnapshot(
                    viewModel.ownerValidatedSessionIndex, owner: owner, latestOwner: owner, activeWorkspace: workspace
                )
            }
            window.promptManager.promptText = "Owner draft"
            replica.promptManager.promptText = "Replica draft"
            // Draft publication is asynchronous. Capture the no-peer-mutation baseline only
            // after fixture setup has reached both workspace projections.
            try await AsyncTestWait.waitUntil("foreground drafts published") {
                window.workspaceManager.activeWorkspace?.composeTabs.first { $0.id == foregroundTabID }?.promptText == "Owner draft"
                    && (
                        !replicaHoldsTarget
                            || replica.workspaceManager.activeWorkspace?.composeTabs.first { $0.id == foregroundTabID }?.promptText == "Replica draft"
                    )
            }
            let source = OpenWindowsDelegationProvenanceSource()
            XCTAssertEqual(source.resolutionState(for: sessionID), replicaHoldsTarget ? .replicated : .unique)
            XCTAssertEqual(source.censusSnapshot().states[sessionID], replicaHoldsTarget ? .replicated : .unique)
            XCTAssertEqual(source.placement(for: sessionID)?.workspaceID, workspace.id)
            XCTAssertEqual(source.provenance(for: sessionID)?.hasUniqueRuntimeOwner, true)
            let runtimeOwner = try XCTUnwrap(SessionAdminWindows.runtimeOwner(for: sessionID))
            XCTAssertTrue(runtimeOwner.location.window === window)
            XCTAssertTrue(runtimeOwner.session === session)
            XCTAssertEqual(runtimeOwner.binding, session.currentRestorationBindingToken)
            let metadataPresenters = WindowStatesManager.shared.allWindows.filter {
                $0.agentModeViewModel.ownerValidatedSessionIndex[sessionID] != nil
            }
            if replicaHoldsTarget {
                XCTAssertTrue(metadataPresenters.first === replica, "Metadata order must not select the passive replica as writer")
            }
            XCTAssertEqual(metadataPresenters.count, replicaHoldsTarget ? 2 : 1)
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
            door.registerStructureHandlers(
                scopes: scopes, worktreeOwnership: ownership, worktreeHost: SessionAdminWindowsWorktreeHost(resolver: resolver)
            )
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
                ownership: ownership, service: service, callerSession: caller, election: electionRepositories
            ))
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }

    /// By default declared [alpha, beta, gamma] and installed [beta, gamma, alpha]. Each linked checkout carries its
    /// own commit, and alpha and beta both have an `e2e/topic` checkout, so a repository-relative `@main:e2e/topic`
    /// names a different worktree for each default repository.
    struct ElectionRepositories {
        static let topicBranch = "e2e/topic"

        let alpha: URL
        let beta: URL
        let gamma: URL
        let alphaPrime: URL
        let betaPrime: URL
        let alphaTopic: URL
        let betaTopic: URL
        /// Workspace roots in declared order (the first is PRIMARY), and the order the store installs them.
        var declared: [URL]
        var installed: [URL]
    }

    /// Which election repositories a fixture's workspace declares, and in what order they are installed.
    typealias ElectionRoots = (ElectionRepositories) throws -> (declared: [URL], installed: [URL])

    private static func makeElectionRepositories(
        _ git: ReviewGitRepositoryFixture, names: (alpha: String, beta: String), roots: ElectionRoots?
    ) throws -> ElectionRepositories {
        let alpha = try git.makeRepository(named: names.alpha, files: ["alpha.txt": "alpha\n"])
        let beta = try git.makeRepository(named: names.beta, files: ["beta.txt": "beta\n"])
        let gamma = try git.makeRepository(named: "gamma", files: ["gamma.txt": "gamma\n"])
        func linked(_ name: String, from root: URL, branch: String) throws -> URL {
            let path = git.sandbox.appendingPathComponent(name, isDirectory: true)
            try git.runGit(["worktree", "add", "-b", branch, path.path, "HEAD"], at: root)
            try git.write("\(name)\n", to: "\(name).txt", at: path)
            try git.stage("\(name).txt", at: path)
            try git.commit("\(name) commit", at: path)
            return path
        }
        var repos = try ElectionRepositories(
            alpha: alpha, beta: beta, gamma: gamma,
            alphaPrime: linked("alpha-wt", from: alpha, branch: "e2e/alpha-wt"),
            betaPrime: linked("beta-wt", from: beta, branch: "e2e/beta-wt"),
            alphaTopic: linked("alpha-topic", from: alpha, branch: ElectionRepositories.topicBranch),
            betaTopic: linked("beta-topic", from: beta, branch: ElectionRepositories.topicBranch),
            declared: [alpha, beta, gamma],
            installed: [beta, gamma, alpha]
        )
        if let roots {
            (repos.declared, repos.installed) = try roots(repos)
        }
        return repos
    }

    private static func installAdversarialOrder(_ repos: ElectionRepositories, store: WorkspaceFileContextStore) async throws {
        let declared = Set(repos.declared.map(\.path))
        for root in await store.roots() where declared.contains(root.standardizedFullPath) {
            await store.unloadRoot(id: root.id)
        }
        for root in repos.installed {
            _ = try await store.loadRoot(path: root.path)
        }
        let actor = await store.roots().filter { $0.kind == .primaryWorkspace }.map(\.standardizedFullPath)
        XCTAssertEqual(actor, repos.installed.map(\.path), "actor install order must be adversarial")
    }

    private static func savedMergeOperation(
        source: URL, target: URL, status: AgentSessionWorktreeMergeOperation.Status
    ) throws -> AgentSessionWorktreeMergeOperation {
        func endpoint(_ root: URL, head: String) throws -> GitWorktreeMergeEndpoint {
            let identity = try XCTUnwrap(GitWorktreeIdentityResolver.resolve(atWorkTreeRoot: root))
            return GitWorktreeMergeEndpoint(
                worktreeID: identity.worktreeID, repositoryID: identity.repository.repositoryID,
                repoKey: identity.repository.repoKey, path: root.path, name: root.lastPathComponent,
                branch: nil, head: head, isMain: identity.isMain
            )
        }
        let operationID = "merge_\(UUID().uuidString)"
        let sourceEndpoint = try endpoint(source, head: String(repeating: "a", count: 40))
        let targetEndpoint = try endpoint(target, head: String(repeating: "b", count: 40))
        let now = Date()
        let inspection = GitWorktreeMergeInspection(
            source: sourceEndpoint, target: targetEndpoint,
            mergeBase: String(repeating: "c", count: 40),
            sourceHead: sourceEndpoint.head, targetHead: targetEndpoint.head,
            sourceFingerprint: GitDiffFingerprint(headSHA: sourceEndpoint.head, baseRef: "HEAD", statusHash: "source-clean", generatedAt: now),
            targetFingerprint: GitDiffFingerprint(headSHA: targetEndpoint.head, baseRef: "HEAD", statusHash: "target-clean", generatedAt: now),
            blockers: [],
            conflictPrediction: GitWorktreeMergeConflictPrediction(status: .clean),
            summary: GitWorktreeMergeSummary(commits: 1, files: 1, insertions: 1, deletions: 0),
            visualization: "target <- source"
        )
        let preview = GitWorktreeMergePreview(operationID: operationID, inspection: inspection, artifacts: GitWorktreeMergePreviewArtifacts(
            snapshotID: "snapshot_\(operationID)",
            snapshotDirectory: "/tmp/snapshot_\(operationID)",
            manifestPath: "/tmp/snapshot_\(operationID)/manifest.json",
            mapPath: "/tmp/snapshot_\(operationID)/MAP.txt",
            allPatchPath: "/tmp/snapshot_\(operationID)/diff/all.patch",
            sidecarPath: "/tmp/snapshot_\(operationID)/merge_preview.json"
        ))
        return AgentWorktreeMergeCoordinator.makeOperation(preview: preview, status: status, now: now)
    }

    private static func canonical(_ url: URL) -> String {
        GitRepoRootAuthorization.canonicalPath(url.path)
    }

    private static func canonical(_ path: String) -> String {
        GitRepoRootAuthorization.canonicalPath(path)
    }

    private static func json(_ value: [String: Value]) -> String {
        json(.object(value))
    }

    /// Whether `text` names `url` after `label`, in its given, symlink-resolved, or `/private` realpath spelling.
    private static func names(_ text: String, _ label: String, _ url: URL) -> Bool {
        var spellings = [url.standardizedFileURL.path, canonical(url)]
        if let resolved = realpath(url.path, nil) {
            spellings.append(String(cString: resolved))
            free(resolved)
        }
        return spellings.contains { text.contains(label + $0) }
    }

    /// The description of the error `body` throws; fails the test if it returns instead.
    private static func failure(
        _ body: () async throws -> some Any, file: StaticString = #filePath, line: UInt = #line
    ) async -> String {
        do {
            let value = try await body()
            XCTFail("expected a thrown failure, got \(value)", file: file, line: line)
            return ""
        } catch {
            return "\(error) \(error.localizedDescription)"
        }
    }

    private static func json(_ value: Value) -> String {
        (try? JSONEncoder().encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "\(value)"
    }
}

/// Holds the first armed worktree query until released, so a test can change target state mid-resolution.
private actor DiscoveryHold {
    private var armed = false
    private var reached = false
    private var reachedWaiter: CheckedContinuation<Void, Never>?
    private var held: CheckedContinuation<Void, Never>?

    func arm() {
        armed = true
    }

    func pass() async {
        guard armed else { return }
        armed = false
        reached = true
        reachedWaiter?.resume()
        reachedWaiter = nil
        await withCheckedContinuation { held = $0 }
    }

    func waitUntilHeld() async {
        guard !reached else { return }
        await withCheckedContinuation { reachedWaiter = $0 }
    }

    func release() {
        held?.resume()
        held = nil
    }
}

@MainActor
final class DelegationScopeEndingTests: XCTestCase {
    func testEndingsRetainReasonTimeAndOwnerAcrossRestart() async throws {
        for reason: OverseerScopeEnding.Reason in [.userRevoked, .granteeReleased, .sessionDeleted, .expired] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            func store() -> DelegationScopeStore {
                .init(fileURL: directory.appendingPathComponent("delegationScopes.json"), backupsDirectoryURL: directory, mode: .enabled)
            }
            var clock = Date(timeIntervalSince1970: 2_000_000)
            let runtime = DelegationScopeRuntime(persistenceMode: .requiresStore, now: { clock }, notifyCatalogChanged: { _ in })
            await runtime.bootstrap(store: store())
            let caller = UUID()
            let request = try runtime.requestScope(requesterSessionID: caller, requesterTabID: nil, kind: .tree(rootSessionID: caller), capabilities: [.observe, .spawn], guardrails: .init(), expiresInSeconds: 60, reason: nil, idempotencyKey: nil).get()
            let scope = try runtime.approve(requestID: request.id).get()
            let childSession = UUID()
            let child = try runtime.attenuate(parentScopeID: scope.id, presentedGeneration: scope.generation, caller: .agentSession(caller), newGranteeSessionID: childSession, newGranteeMemberships: [.init(scopeID: scope.id, targetSessionID: childSession, basis: .treePath([childSession, caller]))], capabilities: [.observe], guardrails: scope.grant.guardrails).get()
            if reason != .granteeReleased { await runtime.flushPersistence() }
            clock = clock.addingTimeInterval(10)
            switch reason {
            case .userRevoked: runtime.revoke(scopeID: scope.id)
            case .granteeReleased: _ = try runtime.release(scopeID: scope.id, caller: .agentSession(caller)).get()
            case .sessionDeleted: runtime.revokeAll(involving: caller)
            default:
                clock = clock.addingTimeInterval(50)
                XCTAssertFalse(runtime.hasLiveScope(grantedTo: caller))
            }
            let evidence = try XCTUnwrap(runtime.ending(for: scope.id), reason.rawValue)
            XCTAssertEqual(evidence.reason, reason)
            XCTAssertEqual(evidence.at, clock)
            if reason == .granteeReleased { XCTAssertEqual(evidence.actorSessionID, caller) }
            if reason == .sessionDeleted { XCTAssertEqual(evidence.originatingSessionID, caller) }
            await runtime.flushPersistence()
            XCTAssertEqual(runtime.continuityState, "saved")
            runtime.freezeForTermination()
            let restored = DelegationScopeRuntime(persistenceMode: .requiresStore, now: { clock }, notifyCatalogChanged: { _ in })
            await restored.bootstrap(store: store())
            XCTAssertFalse(restored.hasLiveScope(grantedTo: caller))
            XCTAssertNil(restored.record(id: scope.id), "Restored history must not participate in authorization")
            XCTAssertEqual(restored.statusRecord(id: scope.id)?.id, scope.id)
            XCTAssertEqual(restored.ending(for: scope.id), evidence)
            XCTAssertEqual(restored.ending(for: child.id), evidence)
            XCTAssertFalse(restored.hasLiveScope(grantedTo: childSession))
            let record = try XCTUnwrap(restored.scopes(grantedTo: caller).first)
            XCTAssertEqual(record.id, scope.id)
            XCTAssertEqual(record.state, reason == .expired ? .expired : .revoked)
            let value = SessionAdminMCPToolService.scopeValue(record, now: clock, ending: restored.ending(for: scope.id))
            XCTAssertEqual(value.objectValue?["ending"]?.objectValue?["reason"], .string(reason.rawValue))
            restored.revoke(scopeID: scope.id)
            XCTAssertEqual(restored.ending(for: scope.id), evidence, "A later revoke must not replace the first ending")
            restored.freezeForTermination()
        }
    }

    func testFailedChildEndingSurvivesLaterAncestorCascadeAndRetry() async throws {
        final class FailureGate: @unchecked Sendable {
            private let lock = NSLock()
            private var failing = false
            func setFailing(_ value: Bool) {
                lock.withLock { failing = value }
            }

            func check() throws {
                if lock.withLock({ failing }) { throw CocoaError(.fileWriteOutOfSpace) }
            }
        }
        for (deleteAncestor, storeOnlyChild, failAncestorSave) in [
            (false, false, false), (true, false, false),
            (false, true, false), (true, true, false),
            (false, true, true), (true, true, true)
        ] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let gate = FailureGate()
            func store() -> DelegationScopeStore {
                .init(fileURL: directory.appendingPathComponent("delegationScopes.json"), backupsDirectoryURL: directory, mode: .enabled, beforeCommit: { try gate.check() })
            }
            var clock = Date(timeIntervalSince1970: 2_000_000)
            let runtime = DelegationScopeRuntime(persistenceMode: .requiresStore, now: { clock }, notifyCatalogChanged: { _ in })
            await runtime.bootstrap(store: store())
            let owner = UUID(), childOwner = UUID()
            let request = try runtime.requestScope(requesterSessionID: owner, requesterTabID: nil, kind: .tree(rootSessionID: owner), capabilities: [.observe, .spawn], guardrails: .init(), reason: nil, idempotencyKey: nil).get()
            let parent = try runtime.approve(requestID: request.id).get()
            await runtime.flushPersistence()
            let child: DomainDelegationScopeGrant
            if storeOnlyChild {
                child = .init(id: UUID(), granteeSessionID: childOwner, kind: .tree(rootSessionID: childOwner), capabilities: [.observe], guardrails: .init(), origin: .attenuatedFrom(scopeID: parent.id), grantedAt: clock)
                XCTAssertEqual(store().record(operationID: UUID(), grants: [child], revoked: []), .applied)
                XCTAssertNil(runtime.record(id: child.id), "Another writer's child must remain absent from this runtime")
            } else {
                child = try runtime.attenuate(parentScopeID: parent.id, presentedGeneration: parent.generation, caller: .agentSession(owner), newGranteeSessionID: childOwner, newGranteeMemberships: [.init(scopeID: parent.id, targetSessionID: childOwner, basis: .treePath([childOwner, owner]))], capabilities: [.observe], guardrails: .init()).get().grant
            }
            await runtime.flushPersistence()
            gate.setFailing(true)
            clock = clock.addingTimeInterval(1)
            let firstEnding: OverseerScopeEnding
            if storeOnlyChild {
                runtime.revokeAll(involving: childOwner, origin: .mcpClient(owner), fileRemoved: false)
                firstEnding = .init(reason: .sessionDeleted, at: clock, actorSessionID: owner, originatingSessionID: childOwner, deletionOrigin: .mcpClient, fileRemoved: false)
            } else {
                _ = try runtime.release(scopeID: child.id, caller: .agentSession(childOwner)).get()
                firstEnding = try XCTUnwrap(runtime.ending(for: child.id))
                XCTAssertEqual(firstEnding.reason, .granteeReleased)
            }
            XCTAssertEqual(runtime.lastPersistenceOutcome, .writeFailed)
            XCTAssertNotEqual(runtime.continuityState, "saved")
            // No suspension between the failed child save and the ancestor's save attempt:
            // the queued retry cannot run first and accidentally hide the ordering defect.
            gate.setFailing(failAncestorSave)
            clock = clock.addingTimeInterval(1)
            if deleteAncestor { runtime.revokeAll(involving: owner, origin: .userUI, fileRemoved: true) }
            else { runtime.revoke(scopeID: parent.id) }
            let parentEnding = try XCTUnwrap(runtime.ending(for: parent.id))
            XCTAssertNotEqual(parentEnding, firstEnding)
            if failAncestorSave { XCTAssertEqual(runtime.lastPersistenceOutcome, .writeFailed) }
            gate.setFailing(false)
            await runtime.flushPersistence()
            XCTAssertEqual(runtime.continuityState, "saved")
            runtime.freezeForTermination()
            let restored = DelegationScopeRuntime(persistenceMode: .requiresStore, now: { clock }, notifyCatalogChanged: { _ in })
            await restored.bootstrap(store: store())
            XCTAssertEqual(restored.ending(for: child.id), firstEnding, "A later ancestor transaction must retain the child's earlier reason, clock, and actor")
            XCTAssertEqual(restored.ending(for: parent.id), parentEnding)
            XCTAssertFalse(restored.hasLiveScope(grantedTo: owner))
            XCTAssertFalse(restored.hasLiveScope(grantedTo: childOwner))
            XCTAssertNil(restored.record(id: child.id))
            restored.freezeForTermination()
        }
    }

    func testExpiryDuringShutdownIsRecordedOnRecovery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        func store() -> DelegationScopeStore {
            .init(fileURL: directory.appendingPathComponent("delegationScopes.json"), backupsDirectoryURL: directory, mode: .enabled)
        }
        var clock = Date(timeIntervalSince1970: 2_000_000)
        let runtime = DelegationScopeRuntime(persistenceMode: .requiresStore, now: { clock }, notifyCatalogChanged: { _ in })
        await runtime.bootstrap(store: store())
        let caller = UUID()
        let request = try runtime.requestScope(requesterSessionID: caller, requesterTabID: nil, kind: .tree(rootSessionID: caller), capabilities: [.observe, .spawn], guardrails: .init(), expiresInSeconds: 60, reason: nil, idempotencyKey: nil).get()
        let scope = try runtime.approve(requestID: request.id).get()
        await runtime.flushPersistence()
        runtime.freezeForTermination()
        clock = clock.addingTimeInterval(61)
        var recoveryReads = 0
        let restored = DelegationScopeRuntime(persistenceMode: .requiresStore, now: {
            recoveryReads += 1
            // The grant crosses its deadline while recovery offers are read across an await.
            return recoveryReads == 1 ? clock.addingTimeInterval(-2) : clock
        }, notifyCatalogChanged: { _ in })
        await restored.bootstrap(store: store())
        await restored.flushPersistence()
        XCTAssertEqual(restored.ending(for: scope.id)?.reason, .expired)
        XCTAssertEqual(restored.statusRecord(id: scope.id)?.state, .expired)
        XCTAssertNil(restored.record(id: scope.id))
        XCTAssertFalse(restored.hasLiveScope(grantedTo: caller))
        let reopened = store()
        _ = reopened.loadForLaunch()
        XCTAssertEqual(reopened.endedScopes[scope.id]?.ending.reason, .expired)
        restored.freezeForTermination()
    }

    func testExpiryCascadeIsStableForBothSavedIdentityOrders() async throws {
        let ids = try [XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001")), XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))]
        for reversed in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            func store() -> DelegationScopeStore {
                .init(fileURL: directory.appendingPathComponent("delegationScopes.json"), backupsDirectoryURL: directory, mode: .enabled)
            }
            let date = Date(timeIntervalSince1970: 2_000_000)
            let parentID = ids[reversed ? 1 : 0], childID = ids[reversed ? 0 : 1]
            let owner = UUID(), childOwner = UUID()
            let parent = DomainDelegationScopeGrant(id: parentID, granteeSessionID: owner, kind: .tree(rootSessionID: owner), capabilities: [.observe, .spawn], guardrails: .init(expiresAt: date), origin: .user, grantedAt: date.addingTimeInterval(-60))
            let child = DomainDelegationScopeGrant(id: childID, granteeSessionID: childOwner, kind: .tree(rootSessionID: childOwner), capabilities: [.observe], guardrails: parent.guardrails, origin: .attenuatedFrom(scopeID: parentID), grantedAt: parent.grantedAt)
            XCTAssertEqual(store().record(operationID: UUID(), grants: [parent, child], revoked: []), .applied)
            let runtime = DelegationScopeRuntime(persistenceMode: .requiresStore, now: { date }, notifyCatalogChanged: { _ in })
            await runtime.bootstrap(store: store())
            await runtime.flushPersistence()
            let evidence = try XCTUnwrap(runtime.ending(for: childID))
            XCTAssertEqual(evidence.originatingScopeID, parentID)
            let reopened = store()
            _ = reopened.loadForLaunch()
            XCTAssertEqual(reopened.endedScopes[childID]?.ending, evidence)
            XCTAssertEqual(reopened.endedScopes[parentID]?.ending, evidence)
            runtime.freezeForTermination()
        }
    }

    func testDisablingFullAccessRecordsItsOwnEndingReason() throws {
        var enabled = true
        let runtime = DelegationScopeRuntime(persistenceMode: .ephemeral, notifyCatalogChanged: { _ in })
        runtime.isGlobalAutoApproveEnabled = { enabled }
        let owner = UUID()
        let request = try runtime.requestScope(requesterSessionID: owner, requesterTabID: nil, kind: .tree(rootSessionID: owner), capabilities: [.observe], guardrails: .init(), reason: nil, idempotencyKey: nil).get()
        XCTAssertTrue(runtime.approveWithStandingConsent(requestID: request.id))
        let scope = try XCTUnwrap(runtime.liveScopes(grantedTo: owner).first)
        let childOwner = UUID()
        let child = try runtime.attenuate(parentScopeID: scope.id, presentedGeneration: scope.generation, caller: .agentSession(owner), newGranteeSessionID: childOwner, newGranteeMemberships: [.init(scopeID: scope.id, targetSessionID: childOwner, basis: .allSessions)], capabilities: [.observe], guardrails: .init()).get()
        enabled = false
        runtime.reconcileGlobalAutoApprove(userInitiated: true)
        XCTAssertEqual(runtime.ending(for: scope.id)?.reason, .fullAccessDisabled)
        XCTAssertEqual(runtime.ending(for: child.id)?.originatingScopeID, scope.id)
        XCTAssertEqual(runtime.ending(for: child.id)?.reason, .fullAccessDisabled)
        XCTAssertFalse(runtime.hasLiveScope(grantedTo: owner))
        XCTAssertFalse(runtime.hasLiveScope(grantedTo: childOwner))
        runtime.freezeForTermination()
    }

    func testDeletionCommitCarriesOriginRemovalAndOneClockToStoreOnlyScopes() async throws {
        for origin: AgentSessionDeletionOrigin in [.unknown, .mcpClient(), .mcpClient(UUID()), .userUI, .agentCleanup(UUID()), .automaticDiscard, .composeTabBatch] {
            for removed in [false, true] {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: directory) }
                let store = DelegationScopeStore(fileURL: directory.appendingPathComponent("delegationScopes.json"), backupsDirectoryURL: directory, mode: .enabled)
                let date = Date(timeIntervalSince1970: 2_000_000), owner = UUID(), id = UUID()
                let grant = DomainDelegationScopeGrant(id: id, granteeSessionID: owner, kind: .tree(rootSessionID: owner), capabilities: [.observe], guardrails: .init(), origin: .user, grantedAt: date)
                // Deliberately do not load this grant into runtime: the deletion mutation must
                // terminalize scopes owned by another writer with the very same evidence.
                let runtime = DelegationScopeRuntime(persistenceMode: .requiresStore, now: { date }, notifyCatalogChanged: { _ in })
                await runtime.bootstrap(store: store)
                XCTAssertEqual(store.record(operationID: UUID(), grants: [grant], revoked: []), .applied)
                let registry = AgentSessionDeletionRegistry.test_instance(scopePersistenceMode: .ephemeral)
                var committedOrigin: AgentSessionDeletionOrigin?
                registry.commitObserver = { sessionID, observedOrigin, fileRemoved in
                    committedOrigin = observedOrigin
                    runtime.revokeAll(involving: sessionID, origin: observedOrigin, fileRemoved: fileRemoved)
                }
                let token = try registry.beginDurableDeletion(sessionID: owner, origin: origin)
                await registry.didCommitDurableDeletion(token, fileRemoved: removed)
                await runtime.flushPersistence()
                _ = store.loadForLaunch()
                let ending = try XCTUnwrap(store.endedScopes[id]?.ending)
                XCTAssertEqual(committedOrigin, origin)
                XCTAssertEqual(ending.at, date)
                XCTAssertEqual(ending.deletionOrigin, origin.kind)
                XCTAssertEqual(ending.actorSessionID, origin.actorSessionID)
                XCTAssertEqual(ending.fileRemoved, removed)
                XCTAssertNil(ending.originatingScopeID, "Store must not fabricate an origin different from runtime")
                let record = DomainDelegationScopeRecord(grant: grant, generation: 0, state: .revoked)
                let status = SessionAdminMCPToolService.scopeValue(record, now: date, ending: ending).objectValue?["ending"]?.objectValue
                XCTAssertEqual(status?["file_removed"], .bool(removed))
                XCTAssertEqual(status?["initiator"], .string(ending.initiator))
                if origin.actorSessionID != owner { XCTAssertNil(status?["actor_session_id"]) }
                runtime.freezeForTermination()
            }
        }
    }

    func testHistoryOutputIsBoundedOrderedAndGranteeIndexedWithMissingDates() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DelegationScopeStore(fileURL: directory.appendingPathComponent("delegationScopes.json"), backupsDirectoryURL: directory, mode: .enabled)
        let owner = UUID(), outsider = UUID(), date = Date(timeIntervalSince1970: 2_000_000)
        var expected: [UUID] = []
        for i in 0 ..< 20 {
            let id = try XCTUnwrap(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", i)))
            let grant = DomainDelegationScopeGrant(id: id, granteeSessionID: owner, kind: .tree(rootSessionID: owner), capabilities: [.observe], guardrails: .init(), origin: .user, grantedAt: date)
            let ending = try OverseerEndedScope(ending: .init(reason: .userRevoked, at: i < 14 ? date.addingTimeInterval(Double(i)) : nil), originalPayload: JSONEncoder().encode(grant))
            XCTAssertEqual(store.record(operationID: UUID(), grants: [], revoked: [id], endings: [id: ending]), .applied)
            expected.append(id)
        }
        expected = Array(expected.prefix(14).reversed()) + Array(expected.suffix(6))
        let runtime = DelegationScopeRuntime(persistenceMode: .requiresStore, now: { date }, notifyCatalogChanged: { _ in })
        await runtime.bootstrap(store: store)
        XCTAssertEqual(runtime.recentScopeEndings.map(\.id), Array(expected.prefix(16)))
        XCTAssertEqual(runtime.scopes(grantedTo: owner).map(\.id), Array(expected.prefix(16)))
        XCTAssertTrue(runtime.scopes(grantedTo: outsider).isEmpty)
        XCTAssertEqual(runtime.recentScopeEndings.map(\.id), Array(expected.prefix(16)), "Cached projection remains stable")
        for id in expected {
            XCTAssertNil(runtime.record(id: id))
        }
        runtime.freezeForTermination()
    }

    func testMalformedEvidenceStillPersistsDenyAndFutureReasonPreservesOriginalPayload() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DelegationScopeStore(fileURL: directory.appendingPathComponent("delegationScopes.json"), backupsDirectoryURL: directory, mode: .enabled)
        let id = UUID(), owner = UUID(), date = Date(timeIntervalSince1970: 2_000_000)
        let grant = DomainDelegationScopeGrant(id: id, granteeSessionID: owner, kind: .tree(rootSessionID: owner), capabilities: [.observe], guardrails: .init(), origin: .user, grantedAt: date)
        XCTAssertEqual(store.record(operationID: UUID(), grants: [grant], revoked: []), .applied)
        XCTAssertEqual(store.record(operationID: UUID(), grants: [], revoked: [id], endings: [id: .init(ending: .init(reason: .userRevoked), originalPayload: Data("malformed".utf8))]), .applied)
        _ = store.loadForLaunch()
        XCTAssertTrue(store.currentGrants.isEmpty)
        XCTAssertEqual(store.endedScopes[id]?.ending.reason, .historicalUnknown)
        let original = try JSONEncoder().encode(grant)
        let envelope = OverseerEndedScope(ending: .init(reason: .userRevoked, at: date), originalPayload: original)
        let bytes = try JSONEncoder().encode(envelope)
        let future = try XCTUnwrap(String(data: bytes, encoding: .utf8)).replacingOccurrences(of: "user_revoked", with: "future_reason")
        let decoded = try JSONDecoder().decode(OverseerEndedScope.self, from: Data(future.utf8))
        XCTAssertEqual(decoded.ending.reason, .historicalUnknown)
        XCTAssertEqual(decoded.originalPayload, original)
    }

    func testTerminalRetryRetainsFirstEvidenceAndHistoricalUnknownIsNotAttributed() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DelegationScopeStore(fileURL: directory.appendingPathComponent("delegationScopes.json"), backupsDirectoryURL: directory, mode: .enabled)
        let id = UUID(), owner = UUID(), operation = UUID()
        let date = Date(timeIntervalSince1970: 2_000_000)
        let grant = DomainDelegationScopeGrant(id: id, granteeSessionID: owner, kind: .tree(rootSessionID: owner), capabilities: [.observe, .spawn, .control, .organize], guardrails: .init(), origin: .user, grantedAt: date)
        let ending = OverseerScopeEnding(reason: .userRevoked, at: date, originatingScopeID: id)
        let ended = try OverseerEndedScope(ending: ending, originalPayload: JSONEncoder().encode(grant))
        for _ in 0 ..< 10 {
            XCTAssertEqual(store.record(operationID: operation, grants: [], revoked: [id], endings: [id: ended]), .applied)
        }
        XCTAssertTrue(store.lastReceipt?.replayed == true)
        XCTAssertEqual(store.replace(with: [], revokedScopeIDs: [id]), .applied)
        _ = store.loadForLaunch()
        XCTAssertEqual(store.endedScopes[id]?.ending, ending)
        let record = DomainDelegationScopeRecord(grant: grant, generation: 0, state: .revoked)
        let status = SessionAdminMCPToolService.scopeValue(record, now: date, ending: .init(reason: .historicalUnknown))
        XCTAssertEqual(status.objectValue?["ending"]?.objectValue?["initiator"], .string("unknown"))
        XCTAssertNil(status.objectValue?["ending"]?.objectValue?["at"])
    }
}
