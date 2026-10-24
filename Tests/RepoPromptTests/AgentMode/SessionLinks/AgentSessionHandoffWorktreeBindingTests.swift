import Foundation
import MCP
import RepoPromptSettingsCore
import RepoPromptVCS
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

/// The message-footer Handoff must continue in the source conversation's worktree: the fresh
/// destination receives the source's execution mappings, with its own projection ownership, before
/// its first save or activation. A stale or unavailable source fails visibly instead of silently
/// falling back to the primary checkout. Regression coverage for repoprompt-ce#1210.
@MainActor
final class AgentSessionHandoffWorktreeBindingTests: XCTestCase {
    override func setUp() {
        super.setUp()
        GlobalSettingsStore.installApplicationModelIdentityPolicy()
    }

    func testBoundSourceHandoffInstallsSourceMappingsBeforeFirstSaveAndActivation() async throws {
        try await withFixture(bindSource: true) { fixture in
            let sourceBindings = fixture.sourceSession.worktreeBindings
            XCTAssertFalse(sourceBindings.isEmpty)
            let cutoffItemID = try XCTUnwrap(fixture.sourceSession.items.last?.id)
            var destinationSaves: [[AgentSessionWorktreeBinding]] = []
            var sawPublishedDestinationBinding = false

            fixture.viewModel.test_afterHandoffDestinationCreation = { destination in
                sawPublishedDestinationBinding = true
                let sessionID = destination.activeAgentSessionID
                XCTAssertNotNil(sessionID)
                XCTAssertEqual(
                    fixture.window.workspaceManager.composeTab(with: destination.tabID)?.activeAgentSessionID,
                    sessionID,
                    "the creation owner must publish the claimed identity before any asynchronous preparation"
                )
                XCTAssertTrue(destination.qualifiedRestorationReadiness.isCreating)
                XCTAssertNotNil(destination.operationAdmissionFailureMessage)
            }

            fixture.viewModel.test_setAgentSessionSaver { session, _, _ in
                guard session.id != fixture.sourceSessionID else {
                    return fixture.git.sandbox.appendingPathComponent("source-session.json")
                }
                XCTAssertEqual(
                    fixture.window.promptManager.activeComposeTabID,
                    fixture.sourceTabID,
                    "the destination must not be activated before its first save"
                )
                destinationSaves.append(session.worktreeBindings)
                return fixture.git.sandbox.appendingPathComponent("handoff-session.json")
            }
            fixture.viewModel.test_setAgentSessionLinkInheritanceHandler { _, _ in .empty }

            let destinationTabID = try await fixture.viewModel.prepareHandoffToNewTab(
                upToItemID: cutoffItemID,
                destinationAgent: fixture.sourceSession.selectedAgent,
                destinationModelRaw: fixture.sourceSession.selectedModelRaw,
                destinationReasoningEffortRaw: fixture.sourceSession.selectedReasoningEffortRaw
            )

            let destination = try XCTUnwrap(fixture.viewModel.sessions[destinationTabID])
            XCTAssertTrue(sawPublishedDestinationBinding)
            let destinationSessionID = try XCTUnwrap(destination.activeAgentSessionID)
            XCTAssertNotEqual(destinationSessionID, fixture.sourceSessionID)
            XCTAssertEqual(
                destinationSaves.first,
                sourceBindings,
                "the first durable save must already carry the source mappings"
            )
            XCTAssertEqual(destination.worktreeBindings, sourceBindings)
            XCTAssertEqual(
                fixture.viewModel.worktreeBindingState(forAgentSessionID: destinationSessionID),
                .hydrated(sourceBindings)
            )
            XCTAssertEqual(fixture.window.promptManager.activeComposeTabID, destinationTabID)

            // Fresh conversation identity: no provider, spawn, merge, or overseer provenance aliasing.
            XCTAssertNil(destination.providerSessionID)
            XCTAssertNil(destination.parentSessionID)
            XCTAssertNil(destination.createdByOverseerSessionID)
            XCTAssertTrue(destination.worktreeMergeOperations.isEmpty)
            XCTAssertNotNil(destination.pendingHandoff.payload)
            XCTAssertTrue(destination.pendingHandoff.defersProviderLockUntilSend)
            XCTAssertFalse(destination.pendingHandoff.isStagedForSend)

            // The source conversation is unchanged.
            XCTAssertEqual(fixture.sourceSession.activeAgentSessionID, fixture.sourceSessionID)
            XCTAssertEqual(fixture.sourceSession.worktreeBindings, sourceBindings)
            XCTAssertEqual(
                fixture.viewModel.worktreeBindingState(forAgentSessionID: fixture.sourceSessionID),
                .hydrated(sourceBindings)
            )

            // Independent projection ownership: releasing the source does not invalidate the destination.
            let materializer = WorkspaceRootBindingProjectionMaterializer(store: fixture.store)
            await materializer.release(sessionID: fixture.sourceSessionID)
            let destinationPreparation = try await materializer.prepare(
                sessionID: destinationSessionID,
                bindings: sourceBindings
            )
            XCTAssertTrue(
                destinationPreparation.ownership.reusesInstalledOwnership,
                "the destination must own its installed projection independently of the source"
            )
            let projection = await materializer.materialize(sessionID: destinationSessionID, bindings: sourceBindings)
            XCTAssertEqual(projection?.isFullyMaterialized, true)
        }
    }

    func testProvisionalInstallNeverAutosavesUnboundDestination() async throws {
        try await withFixture(bindSource: true) { fixture in
            let sourceBindings = fixture.sourceSession.worktreeBindings
            let cutoffItemID = try XCTUnwrap(fixture.sourceSession.items.last?.id)
            var installIsProvisional = false
            var destinationSaves: [(bindings: [AgentSessionWorktreeBinding], duringInstall: Bool, data: Data)] = []

            fixture.viewModel.test_setAgentSessionSaver { session, _, _ in
                if session.id != fixture.sourceSessionID {
                    try destinationSaves.append((
                        session.worktreeBindings,
                        installIsProvisional,
                        JSONEncoder().encode(session)
                    ))
                }
                return fixture.git.sandbox.appendingPathComponent("\(session.id).json")
            }
            fixture.viewModel.test_setAgentSessionLinkInheritanceHandler { _, _ in .empty }
            // Hold installation past the ordinary one-second autosave debounce that the transcript
            // and payload mutations arm; the real scheduler must not save the unbound destination.
            fixture.viewModel.test_beforeHandoffDestinationWorktreeInstall = {
                installIsProvisional = true
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                installIsProvisional = false
            }

            let destinationTabID = try await fixture.viewModel.prepareHandoffToNewTab(
                upToItemID: cutoffItemID,
                destinationAgent: fixture.sourceSession.selectedAgent,
                destinationModelRaw: fixture.sourceSession.selectedModelRaw,
                destinationReasoningEffortRaw: fixture.sourceSession.selectedReasoningEffortRaw
            )

            XCTAssertFalse(
                destinationSaves.contains(where: \.duringInstall),
                "no destination save may run while installation is provisional"
            )
            let firstSave = try XCTUnwrap(destinationSaves.first)
            XCTAssertEqual(firstSave.bindings, sourceBindings)
            let reloaded = try JSONDecoder().decode(AgentSession.self, from: firstSave.data)
            XCTAssertEqual(reloaded.worktreeBindings, sourceBindings, "the first durable record reloads bound")
            XCTAssertEqual(fixture.viewModel.sessions[destinationTabID]?.worktreeBindings, sourceBindings)
            XCTAssertFalse(fixture.viewModel.sessions[destinationTabID]?.isInstallingHandoffWorktreeBindings ?? true)
        }
    }

    func testSourceBranchMetadataRefreshDuringHandoffStillInstallsSameLocation() async throws {
        try await withFixture(bindSource: true) { fixture in
            let original = try XCTUnwrap(fixture.sourceSession.worktreeBindings.first)
            let cutoffItemID = try XCTUnwrap(fixture.sourceSession.items.last?.id)
            let refreshed = original.updatingCheckout(branch: "refreshed-branch", head: "0123456789abcdef")
            XCTAssertNotEqual(refreshed, original)
            fixture.viewModel.test_setAgentSessionSaver { session, _, _ in
                fixture.git.sandbox.appendingPathComponent("\(session.id).json")
            }
            fixture.viewModel.test_setAgentSessionLinkInheritanceHandler { _, _ in .empty }
            // A branch/head refresh rewrites the source's binding metadata without moving it.
            fixture.viewModel.test_beforeHandoffDestinationWorktreeInstall = {
                fixture.sourceSession.worktreeBindings = [refreshed]
            }

            let destinationTabID = try await fixture.viewModel.prepareHandoffToNewTab(
                upToItemID: cutoffItemID,
                destinationAgent: fixture.sourceSession.selectedAgent,
                destinationModelRaw: fixture.sourceSession.selectedModelRaw,
                destinationReasoningEffortRaw: fixture.sourceSession.selectedReasoningEffortRaw
            )

            XCTAssertEqual(fixture.viewModel.sessions[destinationTabID]?.worktreeBindings, [refreshed])
            XCTAssertEqual(fixture.window.promptManager.activeComposeTabID, destinationTabID)
        }
    }

    func testDestinationCannotSendOrPersistWhileInstallIsProvisional() async throws {
        try await withFixture(bindSource: true) { fixture in
            let sourceBindings = fixture.sourceSession.worktreeBindings
            let cutoffItemID = try XCTUnwrap(fixture.sourceSession.items.last?.id)
            let workspaceID = try XCTUnwrap(fixture.window.workspaceManager.activeWorkspace?.id)
            var destinationSaves: [[AgentSessionWorktreeBinding]] = []
            var gatedDuringInstall = false
            var requiredFlushFailedDuringInstall = false

            fixture.viewModel.test_setAgentSessionSaver { session, _, _ in
                if session.id != fixture.sourceSessionID {
                    destinationSaves.append(session.worktreeBindings)
                }
                return fixture.git.sandbox.appendingPathComponent("\(session.id).json")
            }
            fixture.viewModel.test_setAgentSessionLinkInheritanceHandler { _, _ in .empty }
            fixture.viewModel.test_beforeHandoffDestinationWorktreeInstall = {
                guard let destination = fixture.viewModel.sessions.values.first(where: {
                    $0.tabID != fixture.sourceTabID && $0.isInstallingHandoffWorktreeBindings
                }) else { return }
                // The background tab is visible: the existing initial-worktree gate blocks sends,
                // and an explicit required flush cannot persist the unbound provisional record.
                gatedDuringInstall = destination.isPreparingInitialWorktree
                if case .failure = await fixture.viewModel.flushSaveRequired(
                    for: destination.tabID,
                    workspaceID: workspaceID
                ) {
                    requiredFlushFailedDuringInstall = true
                }
            }

            let destinationTabID = try await fixture.viewModel.prepareHandoffToNewTab(
                upToItemID: cutoffItemID,
                destinationAgent: fixture.sourceSession.selectedAgent,
                destinationModelRaw: fixture.sourceSession.selectedModelRaw,
                destinationReasoningEffortRaw: fixture.sourceSession.selectedReasoningEffortRaw
            )

            XCTAssertTrue(gatedDuringInstall)
            XCTAssertTrue(requiredFlushFailedDuringInstall)
            XCTAssertEqual(destinationSaves.first, sourceBindings, "no save may precede the installed bindings")
            let destination = try XCTUnwrap(fixture.viewModel.sessions[destinationTabID])
            XCTAssertFalse(destination.isPreparingInitialWorktree)
            XCTAssertFalse(destination.isInstallingHandoffWorktreeBindings)
            XCTAssertNotNil(destination.pendingHandoff.payload)
        }
    }

    func testSourceStartingInitialWorktreePreparationDuringHandoffFails() async throws {
        try await withFixture(bindSource: true) { fixture in
            let cutoffItemID = try XCTUnwrap(fixture.sourceSession.items.last?.id)
            let composeTabIDsBefore = composeTabIDs(fixture)
            fixture.viewModel.test_setAgentSessionSaver { session, _, _ in
                fixture.git.sandbox.appendingPathComponent("\(session.id).json")
            }
            fixture.viewModel.test_setAgentSessionsDeleter { _, _ in }
            fixture.viewModel.test_beforeHandoffDestinationWorktreeInstall = {
                fixture.sourceSession.isPreparingInitialWorktree = true
            }

            do {
                _ = try await fixture.viewModel.prepareHandoffToNewTab(
                    upToItemID: cutoffItemID,
                    destinationAgent: fixture.sourceSession.selectedAgent,
                    destinationModelRaw: fixture.sourceSession.selectedModelRaw,
                    destinationReasoningEffortRaw: fixture.sourceSession.selectedReasoningEffortRaw
                )
                XCTFail("A source preparing a new execution location must not be snapshotted mid-move")
            } catch let partial as SessionAdminPartialForkError {
                XCTAssertEqual(partial.code, "worktree_install_failed")
                XCTAssertTrue(partial.detail.contains("changed during Handoff"), partial.detail)
                let retained = try XCTUnwrap(fixture.viewModel.sessions.values.first { $0.activeAgentSessionID == partial.sessionID })
                try await assertRecoveryBlocksSubmission(fixture.viewModel, session: retained)
            }
            fixture.sourceSession.isPreparingInitialWorktree = false
            XCTAssertEqual(fixture.window.promptManager.activeComposeTabID, fixture.sourceTabID)
            XCTAssertEqual(composeTabIDs(fixture).count, composeTabIDsBefore.count + 1)
        }
    }

    func testUnboundSourceHandoffKeepsPrimaryCheckoutBehavior() async throws {
        try await withFixture(bindSource: false) { fixture in
            XCTAssertTrue(fixture.sourceSession.worktreeBindings.isEmpty)
            let cutoffItemID = try XCTUnwrap(fixture.sourceSession.items.last?.id)
            var events: [String] = []
            var hookCalled = false
            fixture.viewModel.test_beforeHandoffDestinationWorktreeInstall = { hookCalled = true }
            fixture.viewModel.test_setAgentSessionSaver { session, _, _ in
                if session.id != fixture.sourceSessionID {
                    events.append("save")
                    XCTAssertTrue(session.worktreeBindings.isEmpty)
                }
                return fixture.git.sandbox.appendingPathComponent("\(session.id).json")
            }
            fixture.viewModel.test_setAgentSessionLinkInheritanceHandler { _, _ in
                events.append("inherit")
                return .empty
            }

            let destinationTabID = try await fixture.viewModel.prepareHandoffToNewTab(
                upToItemID: cutoffItemID,
                destinationAgent: fixture.sourceSession.selectedAgent,
                destinationModelRaw: fixture.sourceSession.selectedModelRaw,
                destinationReasoningEffortRaw: fixture.sourceSession.selectedReasoningEffortRaw
            )

            let destination = try XCTUnwrap(fixture.viewModel.sessions[destinationTabID])
            XCTAssertFalse(hookCalled, "an unbound source never enters the worktree install path")
            XCTAssertEqual(events, ["save", "inherit"])
            XCTAssertTrue(destination.worktreeBindings.isEmpty)
            XCTAssertTrue(fixture.sourceSession.worktreeBindings.isEmpty)
            XCTAssertEqual(fixture.window.promptManager.activeComposeTabID, destinationTabID)
        }
    }

    func testSourceExecutionLocationChangeDuringHandoffRetainsBlockedDestination() async throws {
        try await withFixture(bindSource: true) { fixture in
            XCTAssertFalse(fixture.sourceSession.worktreeBindings.isEmpty)
            let cutoffItemID = try XCTUnwrap(fixture.sourceSession.items.last?.id)
            let composeTabIDsBefore = composeTabIDs(fixture)
            var inheritanceWasCalled = false
            var deletedTabIDs: [UUID] = []

            fixture.viewModel.test_setAgentSessionSaver { session, _, _ in
                fixture.git.sandbox.appendingPathComponent("\(session.id).json")
            }
            fixture.viewModel.test_setAgentSessionsDeleter { tabID, _ in
                deletedTabIDs.append(tabID)
            }
            fixture.viewModel.test_setAgentSessionLinkInheritanceHandler { _, _ in
                inheritanceWasCalled = true
                return .empty
            }
            // The source returns to its primary checkout after the payload was built from the worktree.
            fixture.viewModel.test_beforeHandoffDestinationWorktreeInstall = {
                fixture.sourceSession.worktreeBindings = []
            }

            do {
                _ = try await fixture.viewModel.prepareHandoffToNewTab(
                    upToItemID: cutoffItemID,
                    destinationAgent: fixture.sourceSession.selectedAgent,
                    destinationModelRaw: fixture.sourceSession.selectedModelRaw,
                    destinationReasoningEffortRaw: fixture.sourceSession.selectedReasoningEffortRaw
                )
                XCTFail("A stale source must not produce a primary-checkout destination")
            } catch let partial as SessionAdminPartialForkError {
                XCTAssertEqual(partial.code, "worktree_install_failed")
                XCTAssertTrue(partial.detail.contains("changed during Handoff"), partial.detail)
                let retained = try XCTUnwrap(fixture.viewModel.sessions.values.first { $0.activeAgentSessionID == partial.sessionID })
                try await assertRecoveryBlocksSubmission(fixture.viewModel, session: retained)
            }

            XCTAssertFalse(inheritanceWasCalled)
            XCTAssertEqual(fixture.window.promptManager.activeComposeTabID, fixture.sourceTabID)
            XCTAssertEqual(composeTabIDs(fixture).count, composeTabIDsBefore.count + 1)
            XCTAssertTrue(deletedTabIDs.isEmpty, "a failed human fork also retains its identity for explicit recovery")
        }
    }

    func testUnavailableSourceWorktreeFailsBeforeCreatingDestination() async throws {
        try await withFixture(bindSource: true) { fixture in
            let cutoffItemID = try XCTUnwrap(fixture.sourceSession.items.last?.id)
            let composeTabIDsBefore = composeTabIDs(fixture)
            var saverCalledForDestination = false
            fixture.viewModel.test_setAgentSessionSaver { session, _, _ in
                if session.id != fixture.sourceSessionID {
                    saverCalledForDestination = true
                }
                return fixture.git.sandbox.appendingPathComponent("\(session.id).json")
            }
            try fixture.git.runGit(["worktree", "remove", "--force", fixture.linkedWorktreeURL.path], at: fixture.logicalRootURL)

            do {
                _ = try await fixture.viewModel.prepareHandoffToNewTab(
                    upToItemID: cutoffItemID,
                    destinationAgent: fixture.sourceSession.selectedAgent,
                    destinationModelRaw: fixture.sourceSession.selectedModelRaw,
                    destinationReasoningEffortRaw: fixture.sourceSession.selectedReasoningEffortRaw
                )
                XCTFail("An unavailable source worktree must not fall back to the primary checkout")
            } catch let AgentSessionError.handoffExecutionLocationUnavailable(reason) {
                XCTAssertTrue(reason.contains("no longer available"), reason)
            }

            XCTAssertFalse(saverCalledForDestination)
            XCTAssertEqual(fixture.window.promptManager.activeComposeTabID, fixture.sourceTabID)
            XCTAssertEqual(composeTabIDs(fixture), composeTabIDsBefore)
        }
    }

    func testDelegatedHandoffWithoutCurrentAuthorityCreatesNoDestination() async throws {
        try await withFixture(bindSource: false) { fixture in
            let before = composeTabIDs(fixture)
            let sessionIDsBefore = Set(fixture.viewModel.sessions.keys)
            var destinationSaves = 0
            fixture.viewModel.test_setAgentSessionSaver { session, _, _ in
                if session.id != fixture.sourceSessionID { destinationSaves += 1 }
                return fixture.git.sandbox.appendingPathComponent("session.json")
            }
            do {
                _ = try await fixture.viewModel.prepareHandoffToNewTab(
                    upToItemID: XCTUnwrap(fixture.sourceSession.items.last?.id),
                    destinationAgent: fixture.sourceSession.selectedAgent,
                    destinationModelRaw: fixture.sourceSession.selectedModelRaw,
                    destinationReasoningEffortRaw: fixture.sourceSession.selectedReasoningEffortRaw,
                    isStillAuthorized: { false }
                )
                XCTFail("authority loss before tab creation must reject the fork")
            } catch SessionAdminHostError.authorityEnded {
                // The source survived; no partial destination exists to clean up.
            }
            XCTAssertEqual(composeTabIDs(fixture), before)
            XCTAssertEqual(Set(fixture.viewModel.sessions.keys), sessionIDsBefore)
            XCTAssertEqual(destinationSaves, 0)
            XCTAssertEqual(fixture.window.promptManager.activeComposeTabID, fixture.sourceTabID)
        }
    }

    func testDelegatedHandoffSaveFailureReportsCreatedIdentityWithoutDeletingIt() async throws {
        try await withFixture(bindSource: false) { fixture in
            let before = composeTabIDs(fixture)
            var savedDestinationIDs: [UUID] = []
            fixture.viewModel.test_setAgentSessionSaver { session, _, _ in
                if session.id != fixture.sourceSessionID {
                    savedDestinationIDs.append(session.id)
                    throw NSError(domain: "HandoffSaveFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Injected disk failure"])
                }
                return fixture.git.sandbox.appendingPathComponent("source.json")
            }
            var deletedTabIDs: [UUID] = []
            fixture.viewModel.test_setAgentSessionsDeleter { tabID, _ in deletedTabIDs.append(tabID) }
            do {
                _ = try await fixture.viewModel.prepareHandoffToNewTab(
                    upToItemID: XCTUnwrap(fixture.sourceSession.items.last?.id),
                    destinationAgent: fixture.sourceSession.selectedAgent,
                    destinationModelRaw: fixture.sourceSession.selectedModelRaw,
                    destinationReasoningEffortRaw: fixture.sourceSession.selectedReasoningEffortRaw,
                    activateDestination: false,
                    inheritOversightLinks: false,
                    isStillAuthorized: { true }
                )
                XCTFail("a failed first save must not report ordinary fork success")
            } catch let partial as SessionAdminPartialForkError {
                XCTAssertEqual(partial.code, "persist_failed")
                XCTAssertTrue(partial.detail.contains("Injected disk failure"))
                XCTAssertTrue(savedDestinationIDs.contains(partial.sessionID))
                XCTAssertTrue(fixture.viewModel.sessions.values.contains { $0.activeAgentSessionID == partial.sessionID })
            }
            XCTAssertEqual(composeTabIDs(fixture).count, before.count + 1)
            XCTAssertTrue(deletedTabIDs.isEmpty)
            XCTAssertEqual(fixture.window.promptManager.activeComposeTabID, fixture.sourceTabID)
        }
    }

    func testDelegatedHandoffRejectsSameIDSuccessorAfterOracleClone() async throws {
        try await withFixture(bindSource: false) { fixture in
            let before = composeTabIDs(fixture)
            let workspace = try XCTUnwrap(fixture.window.workspaceManager.activeWorkspace)
            let sentinelItem = AgentChatItemPersist(from: .user("Replacement conversation sentinel", sequenceIndex: 0))
            let sentinelParentID = UUID()
            let sentinelOverseerID = UUID()
            var createdSessionID: UUID?
            var successor: AgentModeViewModel.TabSession?
            var sentinelFile: URL?
            var sentinelBytes: Data?
            var hookFailure: Error?
            var destinationSaves = 0
            var deletedTabIDs: [UUID] = []

            fixture.viewModel.test_setAgentSessionSaver { session, workspace, count in
                if session.id != fixture.sourceSessionID { destinationSaves += 1 }
                return try await AgentSessionDataService.shared.saveAgentSession(
                    session, for: workspace, preparation: .alreadyCanonicalTranscript, trustedCanonicalItemCount: count
                )
            }
            fixture.viewModel.test_setAgentSessionsDeleter { tabID, _ in deletedTabIDs.append(tabID) }
            fixture.viewModel.test_afterHandoffDestinationCreation = { destination in
                do {
                    let sessionID = try XCTUnwrap(destination.activeAgentSessionID)
                    createdSessionID = sessionID
                    XCTAssertTrue(destination.qualifiedRestorationReadiness.isCreating)
                    XCTAssertNotNil(destination.operationAdmissionFailureMessage, "ordinary operations must be blocked before Oracle cloning suspends")
                    if case .success = await fixture.viewModel.flushSaveRequired(
                        for: destination.tabID, workspaceID: workspace.id
                    ) {
                        XCTFail("an external flush must not persist the unconfigured fork")
                    }
                    let absentPayload = try await AgentSessionDataService.shared.loadAgentSession(id: sessionID, for: workspace)
                    XCTAssertNil(absentPayload, "fork preparation must not publish a runnable blank payload")
                } catch {
                    hookFailure = error
                }
            }
            fixture.viewModel.test_afterHandoffChatClone = { destination in
                do {
                    let sessionID = try XCTUnwrap(destination.activeAgentSessionID)
                    let creationToken = try XCTUnwrap(destination.currentRestorationBindingToken)
                    XCTAssertEqual(sessionID, createdSessionID, "the fork must reach the clone-completion boundary with its original identity")
                    XCTAssertTrue(destination.qualifiedRestorationReadiness.isCreating)

                    // Replace the destination at the real clone-completion boundary. UUID equality
                    // and authoritative restoration are both true afterward; neither gives the old
                    // fork ownership of this runtime when its post-await continuation resumes.
                    let persistedSuccessor = AgentSession(
                        id: sessionID,
                        workspaceID: workspace.id,
                        composeTabID: destination.tabID,
                        name: "Replacement conversation",
                        items: [sentinelItem],
                        autoEditEnabled: false,
                        parentSessionID: sentinelParentID,
                        createdByOverseerSessionID: sentinelOverseerID,
                        pendingHandoffPayload: "Replacement handoff sentinel"
                    )
                    let fileURL = try await AgentSessionDataService.shared.saveAgentSession(persistedSuccessor, for: workspace)
                    let replacement = AgentModeViewModel.TabSession(tabID: destination.tabID)
                    fixture.viewModel.test_replaceSessionForDeferredHydration(tabID: destination.tabID, with: replacement)
                    _ = fixture.viewModel.test_installPersistentSessionBinding(
                        sessionID: sessionID, on: replacement, updateWorkspaceMetadata: false
                    )
                    let hydrated = await fixture.viewModel.ensureSessionReady(tabID: destination.tabID)
                    XCTAssertTrue(hydrated === replacement)
                    let replacementToken = try XCTUnwrap(replacement.currentRestorationBindingToken)
                    XCTAssertNotEqual(replacementToken, creationToken)
                    XCTAssertEqual(replacement.qualifiedRestorationReadiness, .authoritative(replacementToken, .persistedPayloadApplied))
                    replacement.isPreparingInitialWorktree = true
                    successor = replacement
                    sentinelFile = fileURL
                    sentinelBytes = try Data(contentsOf: fileURL)
                } catch {
                    hookFailure = error
                }
            }

            do {
                _ = try await fixture.viewModel.prepareHandoffToNewTab(
                    upToItemID: XCTUnwrap(fixture.sourceSession.items.last?.id),
                    destinationAgent: fixture.sourceSession.selectedAgent,
                    destinationModelRaw: fixture.sourceSession.selectedModelRaw,
                    destinationReasoningEffortRaw: fixture.sourceSession.selectedReasoningEffortRaw,
                    activateDestination: false,
                    inheritOversightLinks: false,
                    isStillAuthorized: { true }
                )
                XCTFail("the original fork must not adopt a successor that happens to use the same session UUID")
            } catch let partial as SessionAdminPartialForkError {
                XCTAssertEqual(partial.code, "target_changed")
                XCTAssertEqual(partial.sessionID, createdSessionID, "the receipt must retain the identity already created")
            }

            if let hookFailure { throw hookFailure }
            let replacement = try XCTUnwrap(successor)
            let replacementToken = try XCTUnwrap(replacement.currentRestorationBindingToken)
            XCTAssertTrue(fixture.viewModel.sessions[replacement.tabID] === replacement)
            XCTAssertEqual(replacement.activeAgentSessionID, createdSessionID)
            XCTAssertEqual(replacement.items.map(\.id), [sentinelItem.id])
            XCTAssertEqual(replacement.parentSessionID, sentinelParentID)
            XCTAssertEqual(replacement.createdByOverseerSessionID, sentinelOverseerID)
            XCTAssertEqual(replacement.pendingHandoff.payload, "Replacement handoff sentinel")
            XCTAssertEqual(replacement.qualifiedRestorationReadiness, .authoritative(replacementToken, .persistedPayloadApplied))
            XCTAssertTrue(replacement.isPreparingInitialWorktree, "cleanup must not release preparation owned by the successor")
            XCTAssertFalse(replacement.isInstallingHandoffWorktreeBindings)
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(sentinelFile)), try XCTUnwrap(sentinelBytes))
            XCTAssertEqual(destinationSaves, 0, "the stale fork must never reach a save for the replacement")
            XCTAssertTrue(deletedTabIDs.isEmpty, "a delegated partial fork retains its created identity")
            XCTAssertEqual(composeTabIDs(fixture).count, before.count + 1)
            XCTAssertEqual(fixture.window.promptManager.activeComposeTabID, fixture.sourceTabID)
        }
    }

    func testDelegatedHandoffCancellationAfterOracleCloneKeepsCreationBlocked() async throws {
        try await withFixture(bindSource: true) { fixture in
            let before = composeTabIDs(fixture)
            let workspace = try XCTUnwrap(fixture.window.workspaceManager.activeWorkspace)
            var createdDestination: AgentModeViewModel.TabSession?
            var destinationSaves = 0
            var deletedTabIDs: [UUID] = []
            fixture.viewModel.test_setAgentSessionSaver { session, workspace, count in
                if session.id != fixture.sourceSessionID { destinationSaves += 1 }
                return try await AgentSessionDataService.shared.saveAgentSession(
                    session, for: workspace, preparation: .alreadyCanonicalTranscript, trustedCanonicalItemCount: count
                )
            }
            fixture.viewModel.test_setAgentSessionsDeleter { tabID, _ in deletedTabIDs.append(tabID) }
            fixture.viewModel.test_afterHandoffChatClone = { destination in
                createdDestination = destination
                // Cancel only the fork task at the clone-completion boundary. The test's parent
                // task remains alive to verify and reopen the retained partial identity.
                withUnsafeCurrentTask { currentTask in currentTask?.cancel() }
            }

            let fork = Task { @MainActor in
                try await fixture.viewModel.prepareHandoffToNewTab(
                    upToItemID: XCTUnwrap(fixture.sourceSession.items.last?.id),
                    destinationAgent: fixture.sourceSession.selectedAgent,
                    destinationModelRaw: fixture.sourceSession.selectedModelRaw,
                    destinationReasoningEffortRaw: fixture.sourceSession.selectedReasoningEffortRaw,
                    activateDestination: false,
                    inheritOversightLinks: false,
                    isStillAuthorized: { true }
                )
            }
            do {
                _ = try await fork.value
                XCTFail("cancellation must report the retained partial fork")
            } catch let partial as SessionAdminPartialForkError {
                XCTAssertEqual(partial.code, "target_changed")
                XCTAssertEqual(partial.sessionID, createdDestination?.activeAgentSessionID)
            }

            let destination = try XCTUnwrap(createdDestination)
            let sessionID = try XCTUnwrap(destination.activeAgentSessionID)
            XCTAssertFalse(Task.isCancelled, "the fixture's owner must not inherit the fork's cancellation")
            XCTAssertTrue(fixture.viewModel.sessions[destination.tabID] === destination)
            XCTAssertTrue(destination.items.isEmpty)
            XCTAssertTrue(destination.worktreeBindings.isEmpty)
            XCTAssertNil(destination.pendingHandoff.payload)
            XCTAssertTrue(destination.qualifiedRestorationReadiness.isCreating)
            XCTAssertFalse(destination.qualifiedRestorationReadiness.isAuthoritative)
            try await assertRecoveryBlocksSubmission(fixture.viewModel, session: destination)
            if case .success = await fixture.viewModel.flushSaveRequired(
                for: destination.tabID, workspaceID: workspace.id
            ) {
                XCTFail("ordinary persistence must not complete an unconfigured cancelled fork")
            }
            let absentPayload = try await AgentSessionDataService.shared.loadAgentSession(id: sessionID, for: workspace)
            XCTAssertNil(absentPayload)
            XCTAssertEqual(destinationSaves, 0, "neither cancellation nor ordinary flush may publish a runnable blank")

            // Restart cannot inherit a process-local creation owner. With no configured payload,
            // the same carrier is unavailable, and neither loading nor saving may invent one.
            await drainFixtureSaves(fixture.viewModel)
            let replacement = AgentModeViewModel.TabSession(tabID: destination.tabID)
            fixture.viewModel.test_replaceSessionForDeferredHydration(tabID: destination.tabID, with: replacement)
            _ = fixture.viewModel.test_installPersistentSessionBinding(
                sessionID: sessionID, on: replacement, updateWorkspaceMetadata: false
            )
            let reopened = await fixture.viewModel.ensureSessionReady(tabID: destination.tabID)
            XCTAssertTrue(reopened === replacement)
            XCTAssertEqual(reopened.activeAgentSessionID, sessionID)
            XCTAssertFalse(reopened.qualifiedRestorationReadiness.isCreating)
            XCTAssertEqual(reopened.qualifiedRestorationReadiness.terminalFailure, .missingPayload)
            try await assertRecoveryBlocksSubmission(fixture.viewModel, session: reopened)
            if case .success = await fixture.viewModel.flushSaveRequired(
                for: reopened.tabID, workspaceID: workspace.id
            ) {
                XCTFail("reopening a missing partial fork must not make it saveable")
            }
            let stillAbsent = try await AgentSessionDataService.shared.loadAgentSession(id: sessionID, for: workspace)
            XCTAssertNil(stillAbsent)
            XCTAssertEqual(destinationSaves, 0)
            XCTAssertTrue(deletedTabIDs.isEmpty)
            XCTAssertEqual(composeTabIDs(fixture).count, before.count + 1)
            XCTAssertEqual(fixture.window.promptManager.activeComposeTabID, fixture.sourceTabID)
        }
    }

    func testHandoffUsesOriginalSourceSettingsOrRejectsPostCloneSourceChanges() async throws {
        for rebindSource in [false, true] {
            try await withFixture(bindSource: false) { fixture in
                let workspace = try XCTUnwrap(fixture.window.workspaceManager.activeWorkspace)
                let originalAgent: AgentProviderKind = .cursor
                let originalModel = "composer-2.5"
                let originalParameters = [ACPModelParameterSelection(
                    providerID: .cursor, baseModelRaw: originalModel, kind: .thinking,
                    configID: "thought_level", valueRaw: "medium"
                )]
                fixture.sourceSession.selectedAgent = originalAgent
                fixture.sourceSession.selectedModelRaw = originalModel
                fixture.sourceSession.acpModelParameterSelections = originalParameters
                fixture.sourceSession.autoEditEnabled = false
                let originalToken = fixture.sourceSession.currentRestorationBindingToken
                var createdSessionID: UUID?
                var didChangeSource = false
                fixture.viewModel.test_setAgentSessionSaver { session, workspace, count in
                    try await AgentSessionDataService.shared.saveAgentSession(
                        session, for: workspace, preparation: .alreadyCanonicalTranscript, trustedCanonicalItemCount: count
                    )
                }
                fixture.viewModel.test_setAgentSessionLinkInheritanceHandler { _, _ in .empty }
                fixture.viewModel.test_afterHandoffChatClone = { destination in
                    createdSessionID = destination.activeAgentSessionID
                    didChangeSource = true
                    if rebindSource {
                        _ = fixture.viewModel.test_installPersistentSessionBinding(
                            sessionID: nil, on: fixture.sourceSession, updateWorkspaceMetadata: true
                        )
                        _ = fixture.viewModel.test_installPersistentSessionBinding(
                            sessionID: fixture.sourceSessionID, on: fixture.sourceSession, updateWorkspaceMetadata: true
                        )
                        XCTAssertNotEqual(fixture.sourceSession.currentRestorationBindingToken, originalToken)
                    }
                    // Retain the same source object and UUID. Reading its mutable settings after
                    // this await would combine a captured transcript with a different policy.
                    fixture.sourceSession.selectedAgent = .claudeCode
                    fixture.sourceSession.selectedModelRaw = "sonnet"
                    fixture.sourceSession.acpModelParameterSelections = [ACPModelParameterSelection(
                        providerID: .cursor, baseModelRaw: originalModel, kind: .thinking,
                        configID: "thought_level", valueRaw: "high"
                    )]
                    fixture.sourceSession.autoEditEnabled = true
                    fixture.window.promptManager.renameComposeTab(fixture.sourceTabID, to: "Changed source")
                }

                do {
                    let destinationTabID = try await fixture.viewModel.prepareHandoffToNewTab(
                        upToItemID: XCTUnwrap(fixture.sourceSession.items.last?.id),
                        destinationAgent: originalAgent,
                        destinationModelRaw: originalModel,
                        destinationReasoningEffortRaw: nil,
                        activateDestination: false,
                        inheritOversightLinks: false,
                        isStillAuthorized: { true }
                    )
                    let destination = try XCTUnwrap(fixture.viewModel.sessions[destinationTabID])
                    XCTAssertTrue(destination.qualifiedRestorationReadiness.isAuthoritative)
                    XCTAssertEqual(destination.selectedAgent, originalAgent)
                    XCTAssertEqual(destination.selectedModelRaw, originalModel)
                    XCTAssertEqual(destination.acpModelParameterSelections, originalParameters)
                    XCTAssertFalse(destination.autoEditEnabled)
                    XCTAssertEqual(fixture.window.workspaceManager.composeTabName(with: destinationTabID), "Source (handoff)")
                    let saved = try await AgentSessionDataService.shared.loadAgentSession(
                        id: XCTUnwrap(destination.activeAgentSessionID), for: workspace
                    )
                    let persisted = try XCTUnwrap(saved)
                    XCTAssertEqual(persisted.agentKind, originalAgent.rawValue)
                    XCTAssertEqual(persisted.agentModel, originalModel)
                    XCTAssertEqual(persisted.acpModelParameterSelections, originalParameters)
                    XCTAssertFalse(persisted.autoEditEnabled)
                    XCTAssertNil(persisted.pendingHandoffExecutionLocationFailure)
                } catch let partial as SessionAdminPartialForkError {
                    XCTAssertEqual(partial.sessionID, createdSessionID)
                    let retained = try XCTUnwrap(fixture.viewModel.sessions.values.first {
                        $0.activeAgentSessionID == partial.sessionID
                    })
                    try await assertRecoveryBlocksSubmission(fixture.viewModel, session: retained)
                    let saved = try await AgentSessionDataService.shared.loadAgentSession(id: partial.sessionID, for: workspace)
                    if let saved {
                        XCTAssertNotNil(saved.pendingHandoffExecutionLocationFailure, "a rejected fork must not leave a runnable mixed-settings payload")
                    }
                }
                XCTAssertTrue(didChangeSource, "the regression must reach the real post-clone boundary")
            }
        }
    }

    func testDelegatedHandoffWorktreeFailurePreservesBlockedDestination() async throws {
        try await withFixture(bindSource: true) { fixture in
            let before = composeTabIDs(fixture)
            let manager = fixture.window.workspaceManager
            let workspaceIndex = try XCTUnwrap(manager.workspaces.firstIndex { $0.id == manager.activeWorkspaceID })
            manager.workspaces[workspaceIndex].customStoragePath = fixture.git.sandbox.appendingPathComponent("blocked-fork", isDirectory: true)
            fixture.viewModel.test_setAgentSessionSaver { session, workspace, count in
                try await AgentSessionDataService.shared.saveAgentSession(
                    session, for: workspace, preparation: .alreadyCanonicalTranscript, trustedCanonicalItemCount: count
                )
            }
            var deletedTabIDs: [UUID] = []
            fixture.viewModel.test_setAgentSessionsDeleter { tabID, _ in deletedTabIDs.append(tabID) }
            fixture.viewModel.test_beforeHandoffDestinationWorktreeInstall = {
                fixture.sourceSession.worktreeBindings = []
            }
            do {
                _ = try await fixture.viewModel.prepareHandoffToNewTab(
                    upToItemID: XCTUnwrap(fixture.sourceSession.items.last?.id),
                    destinationAgent: fixture.sourceSession.selectedAgent,
                    destinationModelRaw: fixture.sourceSession.selectedModelRaw,
                    destinationReasoningEffortRaw: fixture.sourceSession.selectedReasoningEffortRaw,
                    activateDestination: false,
                    inheritOversightLinks: false,
                    isStillAuthorized: { true }
                )
                XCTFail("a failed install must not report ordinary fork success")
            } catch let partial as SessionAdminPartialForkError {
                XCTAssertEqual(partial.code, "worktree_install_failed")
                let destination = try XCTUnwrap(fixture.viewModel.sessions.values.first { $0.activeAgentSessionID == partial.sessionID })
                XCTAssertTrue(destination.isPreparingInitialWorktree, "the incomplete destination must not run on the primary checkout")
                XCTAssertNotNil(destination.pendingHandoff.executionLocationFailure)
                try await assertRecoveryBlocksSubmission(fixture.viewModel, session: destination)
                let workspace = try XCTUnwrap(manager.activeWorkspace)
                let saved = try await AgentSessionDataService.shared.loadAgentSession(id: partial.sessionID, for: workspace)
                let persisted = try XCTUnwrap(saved)
                XCTAssertNotNil(persisted.pendingHandoffExecutionLocationFailure)
                XCTAssertTrue(persisted.worktreeBindings.isEmpty, "the fixture failed before publishing any mapping")

                // Reopen through the production hydration owner with a fresh runtime object. No
                // copied in-memory blocker may make this assertion pass accidentally.
                destination.saveDebounceTask?.cancel()
                let replacement = AgentModeViewModel.TabSession(tabID: destination.tabID)
                fixture.viewModel.test_replaceSessionForDeferredHydration(tabID: destination.tabID, with: replacement)
                _ = fixture.viewModel.test_installPersistentSessionBinding(
                    sessionID: partial.sessionID, on: replacement, updateWorkspaceMetadata: false
                )
                XCTAssertFalse(replacement.isPreparingInitialWorktree)
                let reopened = await fixture.viewModel.ensureSessionReady(tabID: destination.tabID)
                XCTAssertTrue(reopened === replacement)
                XCTAssertTrue(reopened.hasLoadedPersistedState)
                XCTAssertEqual(reopened.pendingHandoff.executionLocationFailure, persisted.pendingHandoffExecutionLocationFailure)
                XCTAssertTrue(reopened.isPreparingInitialWorktree)
                XCTAssertEqual(
                    fixture.viewModel.executionLocationProps(tabID: reopened.tabID)?.disabledReason,
                    persisted.pendingHandoffExecutionLocationFailure,
                    "the execution-location UI must explain the safe recovery action"
                )
                reopened.pendingHandoff.clearAfterSend()
                reopened.isPreparingInitialWorktree = false
                XCTAssertTrue(reopened.isPreparingInitialWorktree, "ordinary send/reset cleanup cannot clear the durable blocker")
                try await assertRecoveryBlocksSubmission(fixture.viewModel, session: reopened)
            }
            XCTAssertEqual(composeTabIDs(fixture).count, before.count + 1)
            XCTAssertTrue(deletedTabIDs.isEmpty)
            XCTAssertEqual(fixture.window.promptManager.activeComposeTabID, fixture.sourceTabID)
        }
    }

    func testDelegatedHandoffKeepsRecoveryGateUntilBoundSaveIsAcknowledged() async throws {
        for failFinalSave in [false, true] {
            try await withFixture(bindSource: true) { fixture in
                let destinationFile = fixture.git.sandbox.appendingPathComponent("fork.json")
                let sourceSessionID = fixture.sourceSessionID
                let sourceFile = fixture.git.sandbox.appendingPathComponent("source.json")
                var destinationSessionID: UUID?
                var sawBlockedSave = false
                var sawBoundSave = false
                fixture.viewModel.test_setAgentSessionSaver { [weak viewModel = fixture.viewModel] session, _, _ in
                    guard session.id != sourceSessionID else { return sourceFile }
                    let viewModel = try XCTUnwrap(viewModel)
                    destinationSessionID = session.id
                    if session.worktreeBindings.isEmpty {
                        sawBlockedSave = true
                        XCTAssertNotNil(session.pendingHandoffExecutionLocationFailure)
                    } else if session.pendingHandoffExecutionLocationFailure != nil {
                        XCTFail("a failed configured write must not mutate its immutable payload or start another recovery write")
                    } else if !sawBoundSave {
                        sawBoundSave = true
                        XCTAssertTrue(sawBlockedSave, "a recovery record must precede mapping installation")
                        let tabID = try XCTUnwrap(session.composeTabID)
                        XCTAssertNotNil(viewModel.sessions[tabID]?.operationAdmissionFailureMessage, "the owned first save must complete before ordinary operation admission")
                        if failFinalSave {
                            let lastAcknowledged = try JSONDecoder().decode(AgentSession.self, from: Data(contentsOf: destinationFile))
                            XCTAssertNotNil(lastAcknowledged.pendingHandoffExecutionLocationFailure)
                            XCTAssertTrue(lastAcknowledged.worktreeBindings.isEmpty)
                            throw CocoaError(.fileWriteUnknown)
                        }
                    } else {
                        XCTAssertFalse(failFinalSave, "ordinary persistence must not clear a failed fork's blocker")
                    }
                    try JSONEncoder().encode(session).write(to: destinationFile, options: .atomic)
                    return destinationFile
                }
                do {
                    _ = try await fixture.viewModel.prepareHandoffToNewTab(
                        upToItemID: XCTUnwrap(fixture.sourceSession.items.last?.id),
                        destinationAgent: fixture.sourceSession.selectedAgent,
                        destinationModelRaw: fixture.sourceSession.selectedModelRaw,
                        destinationReasoningEffortRaw: fixture.sourceSession.selectedReasoningEffortRaw,
                        activateDestination: false,
                        inheritOversightLinks: false,
                        isStillAuthorized: { true }
                    )
                    XCTAssertFalse(failFinalSave)
                } catch let partial as SessionAdminPartialForkError {
                    XCTAssertTrue(failFinalSave)
                    XCTAssertEqual(partial.code, "persist_failed")
                    XCTAssertEqual(partial.sessionID, destinationSessionID)
                }
                XCTAssertTrue(sawBlockedSave)
                XCTAssertTrue(sawBoundSave)
                let sessionID = try XCTUnwrap(destinationSessionID)
                let destination = try XCTUnwrap(fixture.viewModel.sessions.values.first { $0.activeAgentSessionID == sessionID })
                destination.saveDebounceTask?.cancel()
                XCTAssertEqual(destination.qualifiedRestorationReadiness.isCreating, failFinalSave)
                XCTAssertEqual(destination.operationAdmissionFailureMessage != nil, failFinalSave)
                XCTAssertNil(destination.pendingHandoff.executionLocationFailure, "the completed configuration remains intact for its owner's retry")
                if failFinalSave {
                    try await assertRecoveryBlocksSubmission(fixture.viewModel, session: destination)
                    let workspaceID = try XCTUnwrap(fixture.window.workspaceManager.activeWorkspace?.id)
                    XCTAssertTrue(sawBlockedSave, "the earlier recovery payload must remain the last acknowledged record")
                    let lastAcknowledged = try Data(contentsOf: destinationFile)
                    let recovery = await fixture.viewModel.flushSaveRequired(for: destination.tabID, workspaceID: workspaceID)
                    if case .success = recovery { XCTFail("Ordinary flush must not complete or retry a failed creation.") }
                    XCTAssertEqual(try Data(contentsOf: destinationFile), lastAcknowledged)
                    XCTAssertTrue(destination.qualifiedRestorationReadiness.isCreating)
                    try await assertRecoveryBlocksSubmission(fixture.viewModel, session: destination)
                }
                let saved = try JSONDecoder().decode(AgentSession.self, from: Data(contentsOf: destinationFile))
                XCTAssertEqual(saved.pendingHandoffExecutionLocationFailure != nil, failFinalSave)
                XCTAssertEqual(saved.worktreeBindings, failFinalSave ? [] : fixture.sourceSession.worktreeBindings)
            }
        }
    }

    func testHandoffExecutionRecoveryMarkerDecodesLegacyAndUnknownValuesSafely() throws {
        let legacy = AgentSession(name: "Legacy handoff", autoEditEnabled: false)
        let encoded = try JSONEncoder().encode(legacy)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "pendingHandoffExecutionLocationFailure")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decodedLegacy = try JSONDecoder().decode(AgentSession.self, from: legacyData)
        XCTAssertNil(decodedLegacy.pendingHandoffExecutionLocationFailure)
        XCTAssertNil(try JSONDecoder().decode(AgentSession.self, from: JSONEncoder().encode(decodedLegacy)).pendingHandoffExecutionLocationFailure)

        let invalidValues: [Any] = [42, "", ["version": 999, "state": "unknown"]]
        for invalid in invalidValues {
            object["pendingHandoffExecutionLocationFailure"] = invalid
            let data = try JSONSerialization.data(withJSONObject: object)
            let decoded = try JSONDecoder().decode(AgentSession.self, from: data)
            XCTAssertEqual(decoded.pendingHandoffExecutionLocationFailure, AgentSession.incompleteHandoffExecutionLocationMessage)
            let roundTrip = try JSONDecoder().decode(AgentSession.self, from: JSONEncoder().encode(decoded))
            XCTAssertEqual(roundTrip.pendingHandoffExecutionLocationFailure, decoded.pendingHandoffExecutionLocationFailure)
        }
    }

    // MARK: - Fixture

    private struct Fixture {
        let git: ReviewGitRepositoryFixture
        let window: WindowState
        let logicalRootURL: URL
        let linkedWorktreeURL: URL
        let viewModel: AgentModeViewModel
        let store: WorkspaceFileContextStore
        let sourceTabID: UUID
        let sourceSessionID: UUID
        let sourceSession: AgentModeViewModel.TabSession
    }

    private func withFixture(bindSource: Bool, _ body: (Fixture) async throws -> Void) async throws {
        let fixture = try await makeFixture(bindSource: bindSource)
        do {
            try await body(fixture)
        } catch {
            await cleanup(fixture)
            throw error
        }
        await cleanup(fixture)
    }

    private func makeFixture(bindSource: Bool) async throws -> Fixture {
        let git = try ReviewGitRepositoryFixture(name: "AgentSessionHandoffWorktreeBindingTests")
        let logicalRootURL = try git.makeRepository(named: "logical", files: ["README.md": "fixture\n"])
        let linkedWorktreeURL = git.sandbox.appendingPathComponent("linked", isDirectory: true)
        try git.runGit(["worktree", "add", "--detach", linkedWorktreeURL.path, "HEAD"], at: logicalRootURL)
        let identity = try XCTUnwrap(GitWorktreeIdentityResolver.resolve(atWorkTreeRoot: linkedWorktreeURL))

        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        await window.workspaceManager.awaitInitialized()

        do {
            let workspace = window.workspaceManager.createWorkspace(
                name: "Handoff worktree \(UUID().uuidString.prefix(8))",
                repoPaths: [logicalRootURL.path],
                ephemeral: true
            )
            await window.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "agentSessionHandoffWorktreeBindingTests"
            )

            let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
            let sourceTabID = UUID()
            let sourceSessionID = UUID()
            let workspaceIndex = try XCTUnwrap(
                window.workspaceManager.workspaces.firstIndex(where: { $0.id == activeWorkspace.id })
            )
            window.workspaceManager.workspaces[workspaceIndex].customStoragePath = git.sandbox.appendingPathComponent("sessions", isDirectory: true)
            let sourceBindings: [AgentSessionWorktreeBinding] = bindSource ? [AgentSessionWorktreeBinding(
                id: "primary",
                repositoryID: identity.repository.repositoryID,
                repoKey: identity.repository.repoKey,
                logicalRootPath: logicalRootURL.path,
                logicalRootName: "Project",
                worktreeID: identity.worktreeID,
                worktreeRootPath: linkedWorktreeURL.path,
                commonGitDir: identity.repository.commonGitDir,
                isMainWorktree: false,
                source: "test"
            )] : []
            // Write the source before publishing its carrier. Ordinary hydration must earn the
            // source's restoration proof; a completion latch alone cannot authorize Handoff.
            let persistedSource = AgentSession(
                id: sourceSessionID,
                workspaceID: activeWorkspace.id,
                composeTabID: sourceTabID,
                name: "Source",
                items: [
                    AgentChatItemPersist(from: .user("Source user", sequenceIndex: 0)),
                    AgentChatItemPersist(from: .assistant("Source assistant", sequenceIndex: 1))
                ],
                autoEditEnabled: false,
                worktreeBindings: sourceBindings
            )
            _ = try await AgentSessionDataService.shared.saveAgentSession(
                persistedSource, for: window.workspaceManager.workspaces[workspaceIndex]
            )
            window.workspaceManager.workspaces[workspaceIndex].composeTabs = [
                ComposeTabState(id: sourceTabID, name: "Source", activeAgentSessionID: sourceSessionID)
            ]
            window.workspaceManager.workspaces[workspaceIndex].activeComposeTabID = sourceTabID
            window.promptManager.loadComposeTabsFromWorkspace(
                window.workspaceManager.workspaces[workspaceIndex],
                syncPromptText: true
            )

            let store = window.promptManager.workspaceFileContextStore
            let visibleRootPaths = await store.rootRefs(scope: .visibleWorkspace).map(\.standardizedFullPath)
            if !visibleRootPaths.contains(logicalRootURL.standardizedFileURL.path) {
                _ = try await store.loadRoot(path: logicalRootURL.path)
            }

            let viewModel = window.agentModeViewModel
            let sourceSession = await viewModel.ensureSessionReady(tabID: sourceTabID)
            XCTAssertEqual(sourceSession.activeAgentSessionID, sourceSessionID)
            let sourceToken = try XCTUnwrap(sourceSession.currentRestorationBindingToken)
            XCTAssertEqual(sourceSession.qualifiedRestorationReadiness, .authoritative(sourceToken, .persistedPayloadApplied))
            XCTAssertEqual(sourceSession.worktreeBindings, sourceBindings)
            XCTAssertEqual(sourceSession.items.count, 2)

            if bindSource {
                // Give the hydrated source its own installed projection, as a real bound session would have.
                let materializer = WorkspaceRootBindingProjectionMaterializer(store: store)
                let preparation = try await materializer.prepare(sessionID: sourceSessionID, bindings: sourceBindings)
                _ = try await materializer.commit(preparation)
            }
            viewModel.setAgentModeActive(true)

            return Fixture(
                git: git,
                window: window,
                logicalRootURL: logicalRootURL,
                linkedWorktreeURL: linkedWorktreeURL,
                viewModel: viewModel,
                store: store,
                sourceTabID: sourceTabID,
                sourceSessionID: sourceSessionID,
                sourceSession: sourceSession
            )
        } catch {
            window.beginClose()
            await window.tearDown()
            WindowStatesManager.shared.unregisterWindowState(window)
            git.cleanup()
            throw error
        }
    }

    private func composeTabIDs(_ fixture: Fixture) -> Set<UUID> {
        Set(fixture.window.workspaceManager.activeWorkspace?.composeTabs.map(\.id) ?? [])
    }

    private func assertRecoveryBlocksSubmission(
        _ viewModel: AgentModeViewModel,
        session: AgentModeViewModel.TabSession,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        XCTAssertNil(viewModel.makeComposerSubmitTarget(tabID: session.tabID, session: session), file: file, line: line)
        let sessionID = try XCTUnwrap(session.activeAgentSessionID, file: file, line: line)
        // The UI cannot mint a target while blocked. Model an already-captured, otherwise-current
        // target to prove the claim boundary independently rejects a delayed submission callback.
        let target = AgentComposerSubmitTarget(
            tabID: session.tabID,
            route: .existingAgentSession,
            expectedSourceTabSessionIdentity: ObjectIdentifier(session),
            expectedSourceAgentSessionID: sessionID,
            expectedPersistentBindingIdentity: session.persistentSessionBindingIdentity,
            expectedBindingTransitionGeneration: session.bindingTransitionGeneration,
            expectedRunState: session.runState,
            expectedRunID: session.runID,
            expectedRunAttemptID: session.activeRunAttemptID,
            expectedSubmissionToken: session.composerSubmissionToken,
            expectedInitialStartLocation: viewModel.initialStartLocationProps(tabID: session.tabID)?.selection
        )
        let attempt = AgentComposerSubmitAttempt(
            id: UUID(), target: target, inputRevision: 0, noticeRevision: 0,
            rawDraftSnapshot: "This failed fork must not dispatch."
        )
        let itemIDs = session.items.map(\.id)
        let claimResult = viewModel.claimComposerSubmitAttempt(attempt, requireActiveTabOwnership: false)
        guard case .rejected = claimResult else {
            return XCTFail("An incomplete fork must reject composer admission.", file: file, line: line)
        }
        if session.qualifiedRestorationReadiness.isAuthoritative {
            guard case .rejected(.initialWorktreePreparationInProgress) = claimResult else {
                return XCTFail("A restored recovery record must retain its execution-location blocker.", file: file, line: line)
            }
        }
        XCTAssertNil(session.activeComposerSubmitAttempt, file: file, line: line)
        XCTAssertNil(session.agentTask, file: file, line: line)
        XCTAssertNil(session.runID, file: file, line: line)
        XCTAssertEqual(session.items.map(\.id), itemIDs, file: file, line: line)

        // A completed payload retains the execution-location blocker. Incomplete creation and
        // failed restoration must additionally remain blocked when that presentation flag is off.
        var readiness = AgentModeViewModel.agentSessionLinkDeliveryReadinessSnapshot(
            session: session, endpointMatchesGrant: true, isClosing: false
        )
        if session.qualifiedRestorationReadiness.isAuthoritative {
            XCTAssertEqual(AgentSessionLinkDeliveryReadiness.evaluate(snapshot: readiness), .blocked(.targetNotIdle), file: file, line: line)
            readiness.isPreparingInitialWorktree = false
            XCTAssertEqual(AgentSessionLinkDeliveryReadiness.evaluate(snapshot: readiness), .ready, file: file, line: line)
        } else {
            XCTAssertFalse(AgentSessionLinkDeliveryReadiness.evaluate(snapshot: readiness).isReady, file: file, line: line)
            readiness.isPreparingInitialWorktree = false
            XCTAssertFalse(AgentSessionLinkDeliveryReadiness.evaluate(snapshot: readiness).isReady, file: file, line: line)
        }
        if let restorationFailure = session.restorationAdmissionFailureMessage {
            do {
                _ = try viewModel.mcpResidentTarget(sessionID: sessionID)
                XCTFail("An incomplete fork must not resolve as a resident task target.", file: file, line: line)
            } catch let MCPError.invalidParams(message) {
                XCTAssertEqual(message, restorationFailure, file: file, line: line)
            }
        } else {
            let resident = try XCTUnwrap(viewModel.mcpResidentTarget(sessionID: sessionID), file: file, line: line)
            XCTAssertTrue(resident.session === session, file: file, line: line)
            do {
                _ = try await viewModel.mcpSubmitResidentTask(
                    resident, text: "This failed fork must not dispatch.", workflow: nil,
                    windowIsAvailable: { resident.window?.isClosing == false }
                )
                XCTFail("An incomplete fork must reject external task input.", file: file, line: line)
            } catch let MCPError.invalidParams(message) {
                XCTAssertEqual(message, AgentModeViewModel.mcpResidentBusyError, file: file, line: line)
            }
        }
        XCTAssertEqual(session.items.map(\.id), itemIDs, file: file, line: line)
        XCTAssertNil(session.activeComposerSubmitAttempt, file: file, line: line)
        XCTAssertNil(session.agentTask, file: file, line: line)
        XCTAssertNil(session.runID, file: file, line: line)
    }

    private func drainFixtureSaves(_ viewModel: AgentModeViewModel) async {
        while true {
            // Capture, cancel, and detach each exact handle synchronously. A completion may
            // schedule another save while awaited below; the next pass captures that new handle.
            let tasks = viewModel.sessions.values.compactMap { session -> Task<Void, Never>? in
                let task = session.saveDebounceTask
                task?.cancel()
                session.saveDebounceTask = nil
                return task
            }
            guard !tasks.isEmpty else { return }
            for task in tasks {
                await task.value
            }
        }
    }

    private func cleanup(_ fixture: Fixture) async {
        fixture.viewModel.test_beforeHandoffDestinationWorktreeInstall = nil
        fixture.viewModel.test_afterHandoffDestinationCreation = nil
        fixture.viewModel.test_afterHandoffChatClone = nil
        // Retire body-owned assertion callbacks before cleanup awaits. Their fixture captures
        // otherwise retain the window and can assert during a later XCTest case.
        let sandbox = fixture.git.sandbox
        fixture.viewModel.test_setAgentSessionSaver { session, _, _ in
            let file = sandbox.appendingPathComponent("cleanup-\(session.id.uuidString).json")
            try JSONEncoder().encode(session).write(to: file, options: .atomic)
            return file
        }
        fixture.viewModel.test_setAgentSessionLinkInheritanceHandler { _, _ in .empty }
        fixture.viewModel.test_setAgentSessionsDeleter { _, _ in }
        fixture.window.beginClose()
        await drainFixtureSaves(fixture.viewModel)
        await fixture.window.tearDown()
        await drainFixtureSaves(fixture.viewModel)
        WindowStatesManager.shared.unregisterWindowState(fixture.window)
        fixture.git.cleanup()
    }
}
