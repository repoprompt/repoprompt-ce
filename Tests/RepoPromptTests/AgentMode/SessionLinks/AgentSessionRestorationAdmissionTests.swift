import Foundation
import RepoPromptDomainRuntime
import RepoPromptSecureStorage
import RepoPromptSettingsCore
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

/// A workspace carrier is not proof that its session payload was ever saved. Exercise the real
/// creation, file writer, workspace persistence, reload and admission owners together.
@MainActor
final class AgentSessionRestorationAdmissionTests: XCTestCase {
    func testUntouchedForegroundSessionWritesEmptyPayloadAndReopensAuthoritatively() async throws {
        let fixture = try await makeFixture()
        let creationResult = await fixture.vm.createAndActivateSessionTab()
        let createdTabID = try XCTUnwrap(creationResult)
        let created = try XCTUnwrap(fixture.vm.sessions[createdTabID])
        let sessionID = try XCTUnwrap(created.activeAgentSessionID)
        let payloadURL = sessionFile(root: fixture.root, sessionID: sessionID)
        let payload = try JSONDecoder().decode(AgentSession.self, from: Data(contentsOf: payloadURL))
        XCTAssertEqual(payload.id, sessionID)
        XCTAssertEqual(payload.composeTabID, createdTabID)
        XCTAssertEqual(payload.workspaceID, fixture.workspaceID)
        XCTAssertTrue(payload.toLiveItems().isEmpty)
        XCTAssertTrue(created.qualifiedRestorationReadiness.isAuthoritative)

        let reopened = try await reopen(fixture)
        let restored = await reopened.vm.ensureSessionReady(tabID: createdTabID)
        XCTAssertEqual(restored.activeAgentSessionID, sessionID)
        XCTAssertTrue(restored.items.isEmpty)
        guard case .authoritative(_, .persistedPayloadApplied) = restored.qualifiedRestorationReadiness else {
            return XCTFail("The new runtime must earn authority from the saved payload")
        }
        XCTAssertNil(restored.restorationAdmissionFailureMessage)
        let route = try await reopened.vm.activateRoutedAgentSession(
            tabID: createdTabID, sessionID: sessionID,
            workspace: XCTUnwrap(reopened.manager.activeWorkspace)
        )
        XCTAssertEqual(route, .ready)
        XCTAssertTrue(reopened.providerRequests.events.isEmpty, "Opening an empty session must not start a provider")
    }

    func testRejectedRoutePreservesOnlyTheSourceBindingsPreviouslyEarnedReadiness() async throws {
        for priorState in ["authoritative", "pending", "terminal"] {
            let fixture = try await makeFixture()
            let sourceTabID = await fixture.vm.createAndActivateSessionTab()
            let targetTabID = await fixture.vm.createAndActivateSessionTab()
            let source = try XCTUnwrap(fixture.vm.sessions[XCTUnwrap(sourceTabID)])
            let target = try XCTUnwrap(fixture.vm.sessions[XCTUnwrap(targetTabID)])
            XCTAssertTrue(source.permitsBoundOperationAndSave)
            XCTAssertTrue(target.permitsBoundOperationAndSave)
            let sourceID = try XCTUnwrap(source.activeAgentSessionID)
            let sourceBinding = try XCTUnwrap(source.persistentSessionBindingIdentity)
            let oldToken = try XCTUnwrap(source.currentRestorationBindingToken)
            let targetBinding = target.persistentSessionBindingIdentity
            if priorState == "pending" {
                let generation = source.beginPersistentBindingTransition()
                source.finishPersistentBindingTransition(generation: generation)
            }
            if priorState == "terminal" { source.recordRestorationTerminal(.loadFailed) }
            let workspace = try XCTUnwrap(fixture.manager.activeWorkspace)
            // Legacy payloads without a saved tab reach the real move-owner check. The source's
            // live carrier remains authoritative and its active run must refuse that move.
            var payload = try readPayload(fixture, sessionID: sourceID)
            payload.composeTabID = nil
            _ = try await fixture.writer.saveAgentSession(payload, for: workspace)
            source.runState = .running
            let result = await fixture.vm.activateRoutedAgentSession(
                tabID: target.tabID, sessionID: sourceID, workspace: workspace
            )
            XCTAssertEqual(result, .blockedByActiveDifferentSession, priorState)
            XCTAssertEqual(source.persistentSessionBindingIdentity, sourceBinding, priorState)
            XCTAssertEqual(target.persistentSessionBindingIdentity, targetBinding, priorState)
            XCTAssertNotEqual(source.currentRestorationBindingToken, oldToken, "The refused move still retires its old incarnation.")
            XCTAssertEqual(source.permitsBoundOperationAndSave, priorState == "authoritative", priorState)
            XCTAssertTrue(target.permitsBoundOperationAndSave, priorState)
            XCTAssertNil(source.oversight.overseerActivation, priorState)
            source.runState = .idle
            if priorState == "authoritative" {
                let save = await fixture.vm.flushSaveRequired(for: source.tabID, workspaceID: workspace.id)
                guard case .success = save else { return XCTFail("The unchanged source must remain saveable: \(save)") }
            }
            XCTAssertTrue(fixture.providerRequests.events.isEmpty, priorState)
        }
    }

    func testFailedRouteCannotRestoreReadinessToUnreadyOrSupersededBinding() async throws {
        for change in ["pending", "terminal", "replaced", "rebound", "carrier", "revision"] {
            let fixture = try await makeFixture()
            let createdTabID = await fixture.vm.createAndActivateSessionTab()
            let tabID = try XCTUnwrap(createdTabID)
            let original = try XCTUnwrap(fixture.vm.sessions[tabID])
            let sessionID = try XCTUnwrap(original.activeAgentSessionID)
            XCTAssertTrue(original.permitsBoundOperationAndSave, "The fixture must start from a durably created session.")
            if change == "pending" {
                let generation = original.beginPersistentBindingTransition()
                original.finishPersistentBindingTransition(generation: generation)
            }
            if change == "terminal" { original.recordRestorationTerminal(.loadFailed) }
            let missingSessionID = UUID()
            let gate = TestReleaseFence(name: "failed route before \(change)")
            await AgentSessionDataService.shared.test_setAfterHydrationPrepareHook { id in
                if id == missingSessionID { await gate.enterAndWait() }
            }
            let workspace = try XCTUnwrap(fixture.manager.activeWorkspace)
            let route = Task { @MainActor in
                await fixture.vm.activateRoutedAgentSession(
                    tabID: tabID, sessionID: missingSessionID, workspace: workspace
                )
            }
            addTeardownBlock {
                gate.release()
                _ = await route.value
                await AgentSessionDataService.shared.test_setAfterHydrationPrepareHook(nil)
            }
            guard await gate.waitUntilEntered() else { return }
            switch change {
            case "replaced":
                let replacement = AgentModeViewModel.TabSession(tabID: tabID)
                replacement.testInstallPersistentSessionBinding(sessionID: sessionID)
                fixture.vm.test_replaceSessionForDeferredHydration(tabID: tabID, with: replacement)
            case "rebound":
                original.testInstallPersistentSessionBinding(sessionID: sessionID)
            case "carrier":
                XCTAssertTrue(fixture.manager.compareAndSetActiveAgentSessionID(
                    expected: sessionID, replacement: UUID(), forTabID: tabID, inWorkspaceID: workspace.id
                ))
            case "revision":
                let previousRevision = original.sourceItemsRevision
                original.appendItem(AgentChatItem.user("A newer local transcript", sequenceIndex: 0))
                XCTAssertGreaterThan(original.sourceItemsRevision, previousRevision, "The fixture must supersede the admitted payload revision.")
            default:
                break
            }
            gate.release()
            let result = await route.value
            await AgentSessionDataService.shared.test_setAfterHydrationPrepareHook(nil)
            XCTAssertEqual(result, .sessionNotFound, change)
            let current = try XCTUnwrap(fixture.vm.sessions[tabID])
            XCTAssertFalse(current.permitsBoundOperationAndSave, change)
            XCTAssertFalse(original.permitsBoundOperationAndSave, "The outgoing object cannot regain proof after \(change).")
            XCTAssertNil(current.oversight.overseerActivation, change)
            XCTAssertTrue(fixture.providerRequests.events.isEmpty, change)
        }
    }

    func testFailedFirstPayloadWriteLeavesCarrierUnavailableAfterFreshRuntimeReopen() async throws {
        let fixture = try await makeFixture()
        let initialTabIDs = Set(fixture.prompt.currentComposeTabs.map(\.id))
        // This is the actual atomic writer's boundary. A nonempty directory at the file path
        // deterministically rejects the write without replacing the saver with a success/failure stub.
        let sessionFolder = fixture.root.appendingPathComponent("AgentSessions").resolvingSymlinksInPath().standardizedFileURL
        await fixture.writer.test_setBeforeSessionWriteHook { url in
            guard url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path == sessionFolder.path else { return }
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try? Data("retained obstruction".utf8).write(to: url.appendingPathComponent("keep"))
        }
        let creationResult = await fixture.vm.createAndActivateSessionTab()
        XCTAssertNil(creationResult, "Creation must not report a durable empty session after its real write failed")
        let createdTab = try XCTUnwrap(fixture.prompt.currentComposeTabs.first { !initialTabIDs.contains($0.id) })
        let sessionID = try XCTUnwrap(createdTab.activeAgentSessionID)
        let payloadURL = sessionFile(root: fixture.root, sessionID: sessionID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: payloadURL.appendingPathComponent("keep").path))
        let savedWorkspace = try await persistCarrier(fixture)
        XCTAssertEqual(savedWorkspace.composeTabs.first { $0.id == createdTab.id }?.activeAgentSessionID, sessionID)

        // Keep the obstruction until the first runtime has fully stopped, so teardown cannot retry
        // the first save successfully and accidentally turn this into a successful-restore test.
        await close(fixture)
        await fixture.writer.test_setBeforeSessionWriteHook(nil)
        try FileManager.default.removeItem(at: payloadURL)
        let reopened = try await makeFixture(root: fixture.root, workspace: savedWorkspace)
        let restored = await reopened.vm.ensureSessionReady(tabID: createdTab.id)
        guard case .terminal(_, .missingPayload) = restored.qualifiedRestorationReadiness else {
            return XCTFail("The durable carrier must be reported as unavailable after its initial payload write failed")
        }
        XCTAssertEqual(restored.activeAgentSessionID, sessionID)
        try await assertUnavailableAdmissionPreservesPayload(reopened, session: restored, expectedBytes: nil)
        XCTAssertEqual(reopened.manager.composeTab(with: createdTab.id)?.activeAgentSessionID, sessionID)
    }

    func testMalformedPayloadIsPreservedUntilExplicitRetryLoadsRepairedFile() async throws {
        let root = try makeRoot()
        let tabID = UUID(), sessionID = UUID()
        let workspace = makeWorkspace(root: root, tabID: tabID, sessionID: sessionID)
        let fixture = try await makeFixture(root: root, workspace: workspace)
        _ = try await persistCarrier(fixture)
        let payloadURL = sessionFile(root: root, sessionID: sessionID)
        try FileManager.default.createDirectory(at: payloadURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let malformed = Data("{\"id\":\"\(sessionID)\",\"important_history\":broken".utf8)
        try malformed.write(to: payloadURL, options: .atomic)

        let reopened = try await reopen(fixture)
        let restored = await reopened.vm.ensureSessionReady(tabID: tabID)
        guard case .terminal(_, .loadFailed) = restored.qualifiedRestorationReadiness else {
            return XCTFail("Malformed bytes must produce an explicit restoration failure")
        }
        try await assertUnavailableAdmissionPreservesPayload(reopened, session: restored, expectedBytes: malformed)
        let firstRetry = await reopened.vm.retrySessionRestoration(tabID: tabID)
        XCTAssertFalse(firstRetry)
        XCTAssertEqual(try Data(contentsOf: payloadURL), malformed)

        // Repair is external to admission: Retry must read this real replacement payload rather
        // than bless the old empty runtime or save over the original file.
        let recoveredRow = AgentChatItem.user("History recovered from the repaired file", sequenceIndex: 0)
        var repaired = AgentSession(
            id: sessionID, workspaceID: workspace.id, name: "Recovered history",
            items: [AgentChatItemPersist(from: recoveredRow)], autoEditEnabled: false
        )
        repaired.composeTabID = tabID
        _ = try await reopened.writer.saveAgentSession(repaired, for: workspace)
        let retry = await reopened.vm.retrySessionRestoration(tabID: tabID)
        XCTAssertTrue(retry)
        XCTAssertTrue(restored.qualifiedRestorationReadiness.isAuthoritative)
        XCTAssertNil(restored.restorationAdmissionFailureMessage)
        XCTAssertTrue(restored.items.contains { $0.id == recoveredRow.id && $0.text == recoveredRow.text })
        XCTAssertTrue(reopened.providerRequests.events.isEmpty)
    }

    func testLegacyCarrierDoesNotSwallowNewSessionRecoveryOrTransferItsIdentity() async throws {
        let root = try makeRoot()
        let tabID = UUID(), sessionID = UUID()
        let fixture = try await makeFixture(root: root, workspace: makeWorkspace(root: root, tabID: tabID, sessionID: sessionID))
        let reopened = try await reopen(fixture)
        let unavailable = await reopened.vm.ensureSessionReady(tabID: tabID)
        XCTAssertNotNil(unavailable.restorationAdmissionFailureMessage)
        XCTAssertFalse(reopened.vm.shouldSwallowNewSessionClick(for: tabID))

        let creationResult = await reopened.vm.createAndActivateSessionTab()
        let newTabID = try XCTUnwrap(creationResult)
        let newSessionID = try XCTUnwrap(reopened.vm.sessions[newTabID]?.activeAgentSessionID)
        XCTAssertNotEqual(newTabID, tabID)
        XCTAssertNotEqual(newSessionID, sessionID)
        XCTAssertEqual(reopened.manager.composeTab(with: tabID)?.activeAgentSessionID, sessionID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionFile(root: root, sessionID: sessionID).path))
        let saved = try JSONDecoder().decode(AgentSession.self, from: Data(contentsOf: sessionFile(root: root, sessionID: newSessionID)))
        XCTAssertEqual(saved.id, newSessionID)
        XCTAssertTrue(saved.toLiveItems().isEmpty)
    }

    func testForegroundCreationCannotBlessOrSaveSameUUIDSuccessorAfterActivation() async throws {
        let fixture = try await makeFixture()
        let gate = TestReleaseFence(name: "foreground creation before completion")
        var created: AgentModeViewModel.TabSession?
        fixture.vm.test_afterFreshForegroundSessionCreation = { handle in
            created = handle.session
            await gate.enterAndWait()
        }
        let creation = Task { @MainActor in await fixture.vm.createAndActivateSessionTab() }
        registerGatedCreationCleanup(fixture, gate: gate, creation: creation)
        guard await gate.waitUntilEntered() else { return }
        let original = try XCTUnwrap(created)
        let sessionID = try XCTUnwrap(original.activeAgentSessionID)
        let replacement = AgentModeViewModel.TabSession(tabID: original.tabID)
        fixture.vm.test_replaceSessionForDeferredHydration(tabID: original.tabID, with: replacement)
        _ = fixture.vm.test_installPersistentSessionBinding(sessionID: sessionID, on: replacement, updateWorkspaceMetadata: false)
        replacement.setItemsSilently([.user("Successor history must survive", sequenceIndex: 0)], reason: .testOverride)
        replacement.parentSessionID = UUID()
        let parentID = replacement.parentSessionID
        let revision = replacement.sourceItemsRevision
        gate.release()

        let result = await creation.value
        XCTAssertNil(result)
        XCTAssertTrue(fixture.vm.sessions[original.tabID] === replacement)
        XCTAssertEqual(replacement.items.map(\.text), ["Successor history must survive"])
        XCTAssertEqual(replacement.sourceItemsRevision, revision)
        XCTAssertEqual(replacement.parentSessionID, parentID)
        XCTAssertFalse(replacement.qualifiedRestorationReadiness.isAuthoritative)
        XCTAssertNotNil(replacement.restorationAdmissionFailureMessage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionFile(root: fixture.root, sessionID: sessionID).path))
        XCTAssertTrue(fixture.providerRequests.events.isEmpty)
    }

    func testForegroundCreationRecognizesItsPayloadSavedBeforeCreationContinuation() async throws {
        let fixture = try await makeFixture()
        var savedTabID: UUID?
        var savedSessionID: UUID?
        fixture.vm.test_afterFreshForegroundSessionCreation = { handle in
            let session = handle.session
            savedTabID = session.tabID
            savedSessionID = session.activeAgentSessionID
            let token = session.currentRestorationBindingToken
            guard session.qualifiedRestorationReadiness.isCreating else {
                return XCTFail("The actual foreground owner must retain its creation claim until configured persistence")
            }
            do {
                try await self.assertPreparingAdmission(fixture, session: session)
            } catch {
                return XCTFail("Preparing foreground admission assertions failed: \(error)")
            }
            let saved = await fixture.vm.commitConfiguredSessionCreation(handle: handle)
            XCTAssertTrue(saved, "The exact configured owner must save before resuming creation")
            XCTAssertEqual(session.currentRestorationBindingToken, token)
            guard case let .authoritative(savedToken, .freshBindingDurablyCreated) = session.qualifiedRestorationReadiness else {
                return XCTFail("The real save must acknowledge this exact fresh binding")
            }
            XCTAssertEqual(savedToken, token)
        }

        let result = await fixture.vm.createAndActivateSessionTab()
        let createdTabID = try XCTUnwrap(result, "An already-acknowledged first save is successful creation")
        XCTAssertEqual(createdTabID, savedTabID)
        let sessionID = try XCTUnwrap(savedSessionID)
        let payloadURL = sessionFile(root: fixture.root, sessionID: sessionID)
        let persisted = try JSONDecoder().decode(AgentSession.self, from: Data(contentsOf: payloadURL))
        XCTAssertEqual(persisted.id, sessionID)
        XCTAssertEqual(persisted.composeTabID, createdTabID)
        XCTAssertTrue(persisted.toLiveItems().isEmpty)
        XCTAssertEqual(fixture.prompt.currentComposeTabs.count(where: { $0.activeAgentSessionID == sessionID }), 1)
        XCTAssertTrue(fixture.providerRequests.events.isEmpty)
    }

    func testFreshMCPRejectsGenericAdmissionUntilItsConfiguredOwnerSaves() async throws {
        let fixture = try await makeFixture()
        let originalTabIDs = Set(fixture.prompt.currentComposeTabs.map(\.id))
        var captured: AgentModeViewModel.TabSession?
        fixture.vm.test_setAfterDurableChildTabCreation {
            do {
                let tab = try XCTUnwrap(fixture.prompt.currentComposeTabs.first { !originalTabIDs.contains($0.id) })
                let session = try XCTUnwrap(fixture.vm.sessions[tab.id])
                captured = session
                try await self.assertPreparingAdmission(fixture, session: session)
            } catch {
                XCTFail("Preparing MCP admission assertions failed: \(error)")
            }
        }
        defer { fixture.vm.test_setAfterDurableChildTabCreation(nil) }

        let target = try await fixture.vm.mcpResolveOrCreateSessionTarget(
            tabID: nil, sessionID: nil, createIfNeeded: true, sessionName: "Configured MCP session",
            expectedWorkspaceID: fixture.workspaceID
        )
        let handle = try XCTUnwrap(target.creationHandle)
        XCTAssertTrue(handle.session === captured)
        XCTAssertTrue(handle.session.qualifiedRestorationReadiness.isCreating)
        let model = "claude-sonnet-4-5"
        try await fixture.vm.mcpConfigureSession(
            tabID: target.tabID, agentRaw: AgentProviderKind.claudeCode.rawValue, modelRaw: model,
            reasoningEffortRaw: "high", creationHandle: handle
        )
        XCTAssertNil(fixture.vm.captureSessionCreationRetry(for: handle.session))
        let committed = await fixture.vm.commitConfiguredSessionCreation(target: target)
        XCTAssertTrue(committed)
        let sessionID = try XCTUnwrap(target.sessionID)
        let payload = try readPayload(fixture, sessionID: sessionID)
        XCTAssertEqual(payload.agentKind, AgentProviderKind.claudeCode.rawValue)
        XCTAssertEqual(payload.agentModel, model)
        XCTAssertEqual(payload.agentReasoningEffort, "high")
        XCTAssertEqual(payload.composeTabID, target.tabID)
        XCTAssertTrue(payload.toLiveItems().isEmpty)
        XCTAssertEqual(handle.session.qualifiedRestorationReadiness, .authoritative(handle.bindingToken, .freshBindingDurablyCreated))
        XCTAssertTrue(fixture.providerRequests.events.isEmpty)
    }

    func testConfiguredFirstSaveCanRetryAfterCreationReturnsWithoutChangingOwner() async throws {
        let fixture = try await makeFixture()
        let failed = try await failConfiguredCreation(fixture)
        let retry = try XCTUnwrap(fixture.vm.captureSessionCreationRetry(for: failed.session))
        XCTAssertNotNil(retry.expectedConfigurationStamp)
        XCTAssertTrue(retry.session === failed.session)
        XCTAssertEqual(retry.bindingToken, failed.session.currentRestorationBindingToken)
        let model = failed.session.selectedModelRaw
        let autoEdit = failed.session.autoEditEnabled
        try await removeWriteObstruction(fixture, sessionID: failed.sessionID)

        let genericSave = await fixture.vm.flushSaveRequired(for: failed.session.tabID, workspaceID: fixture.workspaceID)
        guard case .failure = genericSave else {
            return XCTFail("A ready configured creation still requires its exact owner to save")
        }
        await fixture.vm.flushSave(for: failed.session.tabID)
        guard case .blocked = fixture.vm.submitUserTurn(text: "Do not dispatch before retry", tabID: failed.session.tabID) else {
            return XCTFail("A failed configured first save must keep submission blocked")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionFile(root: fixture.root, sessionID: failed.sessionID).path))
        XCTAssertTrue(failed.session.items.isEmpty)

        let committed = await fixture.vm.retrySessionInitialSave(retry)
        XCTAssertTrue(committed)
        let payload = try readPayload(fixture, sessionID: failed.sessionID)
        XCTAssertEqual(payload.agentModel, model)
        XCTAssertEqual(payload.autoEditEnabled, autoEdit)
        XCTAssertTrue(payload.toLiveItems().isEmpty)
        XCTAssertEqual(failed.session.qualifiedRestorationReadiness, .authoritative(retry.bindingToken, .freshBindingDurablyCreated))
        XCTAssertNil(fixture.vm.captureSessionCreationRetry(for: failed.session))
        XCTAssertTrue(fixture.providerRequests.events.isEmpty)
    }

    func testExternalMCPStartHonorsPendingStopAfterConfiguredSaveBeforeDispatch() async throws {
        for stopPendingStart in [false, true] {
            let fixture = try await makeFixture()
            let target = try await fixture.vm.mcpResolveOrCreateSessionTarget(
                tabID: nil, sessionID: nil, createIfNeeded: true, sessionName: "MCP start save fence",
                expectedWorkspaceID: fixture.workspaceID
            )
            let handle = try XCTUnwrap(target.creationHandle)
            let sessionID = try XCTUnwrap(target.sessionID)
            let gate = TestReleaseFence(name: "external MCP configured save acknowledged")
            var acknowledgements = 0
            var dispatches = 0
            fixture.vm.test_afterConfiguredCreationAcknowledgement = { acknowledged in
                XCTAssertTrue(acknowledged.session === handle.session)
                XCTAssertEqual(acknowledged.bindingToken, handle.bindingToken)
                acknowledgements += 1
                await gate.enterAndWait()
            }
            let starter = Task { @MainActor in
                try await AgentExternalMCPRunStarter.startPreservingCallerBinding(
                    target: target,
                    message: "Dispatch only if the pending start has not been stopped",
                    metadata: .init(connectionID: UUID(), clientName: "configured-save-stop-test", windowID: -1),
                    agentModeVM: fixture.vm,
                    agentRaw: AgentProviderKind.claudeCode.rawValue,
                    modelRaw: "claude-sonnet-4-5",
                    reasoningEffortRaw: "high",
                    dispatchInstruction: { dispatchedSessionID, tabID, _, _, _ in
                        XCTAssertEqual(dispatchedSessionID, sessionID)
                        XCTAssertEqual(tabID, target.tabID)
                        dispatches += 1
                        return .startedRun
                    }
                )
            }
            addTeardownBlock { @MainActor in
                fixture.vm.test_afterConfiguredCreationAcknowledgement = nil
                await fixture.writer.test_setBeforeSessionWriteHook(nil)
                gate.release()
                starter.cancel()
                _ = await starter.result
            }
            guard await gate.waitUntilEntered() else { return }

            // Stop happens after the actual first write is acknowledged, so an unchanged save
            // token cannot incidentally reject startup and conceal a missing producer fence.
            XCTAssertEqual(acknowledgements, 1)
            XCTAssertEqual(dispatches, 0)
            XCTAssertTrue(fixture.vm.sessions[target.tabID] === handle.session)
            XCTAssertEqual(handle.session.qualifiedRestorationReadiness, .authoritative(handle.bindingToken, .freshBindingDurablyCreated))
            XCTAssertNotNil(handle.session.mcpControlContext)
            XCTAssertTrue(handle.session.mcpFollowUpRunPending)
            XCTAssertNil(handle.session.activeRunOwnership)
            let beforeStop = try readPayload(fixture, sessionID: sessionID)
            XCTAssertEqual(beforeStop.id, sessionID)
            XCTAssertEqual(beforeStop.agentModel, "claude-sonnet-4-5")
            XCTAssertTrue(beforeStop.toLiveItems().isEmpty)
            let pendingFence = AgentRunStartStopFence(session: handle.session)
            if stopPendingStart {
                let binding = try XCTUnwrap(handle.session.persistentSessionBindingIdentity)
                let admission = AgentRunCancellationAdmission(
                    scope: .pendingStart, session: handle.session, binding: binding,
                    expectedOwnership: handle.session.activeRunOwnership, expectedRunID: handle.session.runID,
                    cancellationGeneration: handle.session.stopState.cancellationGeneration,
                    pendingStartFence: pendingFence,
                    validateAndClaim: {
                        fixture.vm.sessions[target.tabID] === handle.session
                            && handle.session.currentRestorationBindingToken == handle.bindingToken
                    }
                )
                XCTAssertTrue(fixture.vm.withdrawPendingStartForSessionLink(session: handle.session, admission: admission))
                XCTAssertFalse(handle.session.mcpFollowUpRunPending)
                XCTAssertFalse(pendingFence.permitsStart(of: handle.session))
            } else {
                handle.session.mcpFollowUpRunPending = false
                XCTAssertTrue(pendingFence.permitsStart(of: handle.session), "Clearing presentation state does not withdraw the producer")
            }
            fixture.vm.test_afterConfiguredCreationAcknowledgement = nil
            gate.release()
            let result = await starter.result
            XCTAssertFalse(starter.isCancelled, "The pending Stop must be detected without cancelling the caller task")
            if stopPendingStart {
                guard case let .failure(error) = result else {
                    return XCTFail("A withdrawn startup must not resume dispatch after its configured save")
                }
                XCTAssertTrue(String(describing: error).contains("withdrawn or replaced"), "\(error)")
                XCTAssertEqual(dispatches, 0)
            } else {
                guard case let .success(outcome) = result else {
                    return XCTFail("Unchanged startup must still dispatch: \(result)")
                }
                XCTAssertEqual(outcome.delivery, .startedRun)
                XCTAssertEqual(dispatches, 1)
            }
            XCTAssertEqual(target.recoveryClaim?.state, .accepted)
            XCTAssertEqual(handle.session.qualifiedRestorationReadiness, .authoritative(handle.bindingToken, .freshBindingDurablyCreated))
            let retained = try readPayload(fixture, sessionID: sessionID)
            XCTAssertEqual(retained.id, sessionID)
            XCTAssertEqual(retained.composeTabID, target.tabID)
            XCTAssertTrue(fixture.providerRequests.events.isEmpty)
        }
    }

    func testExternalMCPStartHonorsPendingStopDuringActualAutoEffortJudgment() async throws {
        let fixture = try await makeFixture()
        let gate = TestReleaseFence(name: "external MCP initial auto-effort judgment")
        let client = RestorationInitialEffortJevClient(gate: gate)
        let credentials = JevRouterCredentialService(
            secureKeys: SecureKeysService(secureStorage: TestSecureStorageBackend(values: [.jevRouterAPIKey: "fixture-key"])),
            client: client
        )
        guard case .saved = await credentials.validateStoredKey(operationID: UUID()) else {
            return XCTFail("The in-memory fake Jev credential must validate before dispatch")
        }
        let suiteName = "RestorationInitialEffort-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let settings = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(fileURL: fixture.root.appendingPathComponent("router-settings.json"))
        )
        settings.setAutoEffortEnabled(true)
        let runtime = try AgentTaskRouterRuntime(registrations: [
            .init(
                service: JevDecisionService(credentialService: credentials),
                configuration: JevDecisionService.settingsRegistration(controller: credentials)
            )
        ], demandSource: settings)
        await runtime.reconcileDemand()
        try await AsyncTestWait.waitUntil("initial effort backend readiness") { runtime.isBackendReady(.jev) }
        fixture.vm.modelRouterSettingsStore = settings
        fixture.vm.modelRouterRuntime = runtime
        let target = try await fixture.vm.mcpResolveOrCreateSessionTarget(
            tabID: nil, sessionID: nil, createIfNeeded: true, sessionName: "MCP initial effort stop",
            expectedWorkspaceID: fixture.workspaceID
        )
        let handle = try XCTUnwrap(target.creationHandle)
        let sessionID = try XCTUnwrap(target.sessionID)
        let starter = Task { @MainActor in
            try await AgentExternalMCPRunStarter.startPreservingCallerBinding(
                target: target,
                message: "Review the session management implementation for correctness",
                metadata: .init(connectionID: UUID(), clientName: "initial-effort-stop-test", windowID: -1),
                agentModeVM: fixture.vm,
                agentRaw: AgentProviderKind.claudeCode.rawValue,
                modelRaw: "claude-opus-5-5",
                reasoningEffortRaw: "high"
            )
        }
        addTeardownBlock { @MainActor in
            fixture.vm.test_afterConfiguredCreationAcknowledgement = nil
            await fixture.writer.test_setBeforeSessionWriteHook(nil)
            gate.release()
            starter.cancel()
            _ = await starter.result
            fixture.vm.modelRouterRuntime = nil
        }
        guard await gate.waitUntilEntered() else { return }
        let requests = await client.requestCount
        XCTAssertEqual(requests, 1)
        XCTAssertNotNil(handle.session.autoEffortJudgmentID)
        XCTAssertTrue(handle.session.mcpFollowUpRunPending)
        XCTAssertNotNil(handle.session.mcpControlContext)
        XCTAssertNil(handle.session.activeRunOwnership)
        XCTAssertTrue(handle.session.items.isEmpty)
        XCTAssertTrue(fixture.providerRequests.events.isEmpty)
        XCTAssertEqual(handle.session.qualifiedRestorationReadiness, .authoritative(handle.bindingToken, .freshBindingDurablyCreated))
        XCTAssertEqual(try readPayload(fixture, sessionID: sessionID).agentModel, "claude-opus-5-5")
        let pendingFence = AgentRunStartStopFence(session: handle.session)
        let admission = try AgentRunCancellationAdmission(
            scope: .pendingStart, session: handle.session,
            binding: XCTUnwrap(handle.session.persistentSessionBindingIdentity),
            expectedOwnership: handle.session.activeRunOwnership, expectedRunID: handle.session.runID,
            cancellationGeneration: handle.session.stopState.cancellationGeneration,
            pendingStartFence: pendingFence,
            validateAndClaim: {
                fixture.vm.sessions[target.tabID] === handle.session
                    && handle.session.currentRestorationBindingToken == handle.bindingToken
            }
        )
        XCTAssertTrue(fixture.vm.withdrawPendingStartForSessionLink(session: handle.session, admission: admission))
        XCTAssertFalse(pendingFence.permitsStart(of: handle.session))
        gate.release()
        let result = await starter.result

        XCTAssertFalse(starter.isCancelled, "Stop must withdraw the producer without cancelling the external request")
        guard case let .failure(error) = result else {
            return XCTFail("The original producer must recheck Stop after the actual effort await")
        }
        XCTAssertTrue(String(describing: error).contains("withdrawn or replaced"), "\(error)")
        XCTAssertNil(handle.session.autoEffortJudgmentID)
        XCTAssertTrue(handle.session.items.isEmpty, "The stopped producer must not append its first user row")
        XCTAssertNil(handle.session.runID)
        XCTAssertTrue(fixture.providerRequests.events.isEmpty, "The stopped producer must not reach a provider factory")
        XCTAssertEqual(target.recoveryClaim?.state, .accepted)
        XCTAssertEqual(handle.session.qualifiedRestorationReadiness, .authoritative(handle.bindingToken, .freshBindingDurablyCreated))
        let retained = try readPayload(fixture, sessionID: sessionID)
        XCTAssertEqual(retained.composeTabID, target.tabID)
        XCTAssertTrue(retained.toLiveItems().isEmpty)
    }

    func testScheduledSaveDuringConfiguredWritePreservesAcknowledgementAndReopensPayload() async throws {
        guard !AppLaunchConfiguration.current.suppressesAgentSessionPersistence else {
            return XCTFail("This regression requires persistence enabled so scheduleSave reaches its creation guard")
        }
        let fixture = try await makeFixture()
        let gate = TestReleaseFence(name: "configured first payload writer")
        let sessionFolder = fixture.root.appendingPathComponent("AgentSessions").resolvingSymlinksInPath().standardizedFileURL
        var captured: AgentSessionCreationHandle?
        fixture.vm.test_afterFreshForegroundSessionCreation = { captured = $0 }
        await fixture.writer.test_setBeforeSessionWriteHook { url in
            guard url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path == sessionFolder.path else { return }
            await gate.enterAndWait()
        }
        let creation = Task { @MainActor in await fixture.vm.createAndActivateSessionTab() }
        registerGatedCreationCleanup(fixture, gate: gate, creation: creation)
        guard await gate.waitUntilEntered() else { return }
        let handle = try XCTUnwrap(captured)
        let sessionID = try XCTUnwrap(handle.session.activeAgentSessionID)
        let generation = handle.session.saveRequestGeneration
        XCTAssertNotNil(fixture.vm.captureSessionCreationRetry(for: handle.session))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionFile(root: fixture.root, sessionID: sessionID).path))

        fixture.vm.scheduleSave(for: handle.session.tabID)
        XCTAssertEqual(handle.session.saveRequestGeneration, generation, "A generic scheduling request must not invalidate the owned write")
        XCTAssertNil(handle.session.saveDebounceTask)
        fixture.vm.test_afterFreshForegroundSessionCreation = nil
        await fixture.writer.test_setBeforeSessionWriteHook(nil)
        gate.release()
        let result = await creation.value

        XCTAssertEqual(result, handle.session.tabID)
        XCTAssertEqual(handle.session.qualifiedRestorationReadiness, .authoritative(handle.bindingToken, .freshBindingDurablyCreated))
        let payload = try readPayload(fixture, sessionID: sessionID)
        XCTAssertEqual(payload.composeTabID, handle.session.tabID)
        XCTAssertTrue(payload.toLiveItems().isEmpty)
        let reopened = try await reopen(fixture)
        let restored = await reopened.vm.ensureSessionReady(tabID: handle.session.tabID)
        XCTAssertEqual(restored.activeAgentSessionID, sessionID)
        guard case .authoritative(_, .persistedPayloadApplied) = restored.qualifiedRestorationReadiness else {
            return XCTFail("The acknowledged file must supply authority to a fresh runtime")
        }
        XCTAssertTrue(restored.items.isEmpty)
        XCTAssertTrue(fixture.providerRequests.events.isEmpty)
        XCTAssertTrue(reopened.providerRequests.events.isEmpty)
    }

    func testConfigurationMutationDuringWriterAwaitCannotAcknowledgeOrReplacePreparedPayload() async throws {
        guard !AppLaunchConfiguration.current.suppressesAgentSessionPersistence else {
            return XCTFail("This regression requires persistence enabled")
        }
        for mutation in ConfigurationMutation.allCases {
            let fixture = try await makeFixture()
            let gate = TestReleaseFence(name: "configured payload before \(mutation) mutation")
            let sessionFolder = fixture.root.appendingPathComponent("AgentSessions").resolvingSymlinksInPath().standardizedFileURL
            var captured: AgentSessionCreationHandle?
            fixture.vm.test_afterFreshForegroundSessionCreation = { captured = $0 }
            await fixture.writer.test_setBeforeSessionWriteHook { url in
                guard url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path == sessionFolder.path else { return }
                await gate.enterAndWait()
            }
            let creation = Task { @MainActor in await fixture.vm.createAndActivateSessionTab() }
            registerGatedCreationCleanup(fixture, gate: gate, creation: creation)
            guard await gate.waitUntilEntered() else { return }
            let handle = try XCTUnwrap(captured)
            let sessionID = try XCTUnwrap(handle.session.activeAgentSessionID)
            let originalModel = handle.session.selectedModelRaw
            let originalParameters = handle.session.acpModelParameterSelections
            let originalAutoEdit = handle.session.autoEditEnabled
            let generation = handle.session.saveRequestGeneration
            mutateConfiguration(mutation, on: handle.session)
            XCTAssertEqual(handle.session.saveRequestGeneration, generation, "This must exercise the configuration fence, independently of scheduling")
            fixture.vm.test_afterFreshForegroundSessionCreation = nil
            await fixture.writer.test_setBeforeSessionWriteHook(nil)
            gate.release()

            let result = await creation.value
            XCTAssertNil(result, "\(mutation)")
            XCTAssertTrue(handle.session.qualifiedRestorationReadiness.isCreating, "\(mutation)")
            XCTAssertFalse(handle.session.qualifiedRestorationReadiness.isAuthoritative, "\(mutation)")
            let payloadURL = sessionFile(root: fixture.root, sessionID: sessionID)
            let originalBytes = try Data(contentsOf: payloadURL)
            let payload = try JSONDecoder().decode(AgentSession.self, from: originalBytes)
            XCTAssertEqual(payload.agentModel, originalModel, "\(mutation)")
            XCTAssertEqual(payload.acpModelParameterSelections, originalParameters, "\(mutation)")
            XCTAssertEqual(payload.autoEditEnabled, originalAutoEdit, "\(mutation)")
            let retry = try XCTUnwrap(fixture.vm.captureSessionCreationRetry(for: handle.session))
            let retried = await fixture.vm.retrySessionInitialSave(retry)
            XCTAssertFalse(retried, "\(mutation)")
            XCTAssertEqual(try Data(contentsOf: payloadURL), originalBytes, "Retry must preserve the originally prepared bytes: \(mutation)")
            XCTAssertTrue(handle.session.items.isEmpty, "\(mutation)")
            XCTAssertTrue(fixture.providerRequests.events.isEmpty, "\(mutation)")
        }
    }

    func testConfiguredRetryRejectsModelParametersAndAutoEditMutations() async throws {
        for mutation in ConfigurationMutation.allCases {
            let fixture = try await makeFixture()
            let failed = try await failConfiguredCreation(fixture)
            let retry = try XCTUnwrap(fixture.vm.captureSessionCreationRetry(for: failed.session))
            try await removeWriteObstruction(fixture, sessionID: failed.sessionID)
            mutateConfiguration(mutation, on: failed.session)

            let committed = await fixture.vm.retrySessionInitialSave(retry)
            XCTAssertFalse(committed, "Retry must preserve the failed configured payload: \(mutation)")
            let recaptured = try XCTUnwrap(fixture.vm.captureSessionCreationRetry(for: failed.session))
            XCTAssertEqual(recaptured.expectedConfigurationStamp, retry.expectedConfigurationStamp)
            let recapturedResult = await fixture.vm.retrySessionInitialSave(recaptured)
            XCTAssertFalse(recapturedResult, "A rerendered Retry control must not capture a new payload: \(mutation)")
            XCTAssertFalse(failed.session.qualifiedRestorationReadiness.isAuthoritative, "\(mutation)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: sessionFile(root: fixture.root, sessionID: failed.sessionID).path), "\(mutation)")
            XCTAssertTrue(failed.session.items.isEmpty, "\(mutation)")
            XCTAssertTrue(fixture.providerRequests.events.isEmpty, "\(mutation)")
        }
    }

    func testConfiguredRetryRefusesSameUUIDReplacementAndSameObjectRebind() async throws {
        for replaceRuntime in [true, false] {
            let fixture = try await makeFixture()
            let failed = try await failConfiguredCreation(fixture)
            let retry = try XCTUnwrap(fixture.vm.captureSessionCreationRetry(for: failed.session))
            try await removeWriteObstruction(fixture, sessionID: failed.sessionID)
            let successor: AgentModeViewModel.TabSession
            if replaceRuntime {
                successor = AgentModeViewModel.TabSession(tabID: failed.session.tabID)
                fixture.vm.test_replaceSessionForDeferredHydration(tabID: successor.tabID, with: successor)
            } else {
                successor = failed.session
                _ = fixture.vm.test_installPersistentSessionBinding(sessionID: nil, on: successor, updateWorkspaceMetadata: false)
            }
            _ = fixture.vm.test_installPersistentSessionBinding(sessionID: failed.sessionID, on: successor, updateWorkspaceMetadata: false)
            XCTAssertEqual(successor.activeAgentSessionID, failed.sessionID)
            if !replaceRuntime {
                XCTAssertNotEqual(successor.currentRestorationBindingToken, retry.bindingToken)
            }
            successor.setItemsSilently([.user("Retain successor history", sequenceIndex: 0)], reason: .testOverride)
            let revision = successor.sourceItemsRevision

            let committed = await fixture.vm.retrySessionInitialSave(retry)
            XCTAssertFalse(committed)
            XCTAssertTrue(fixture.vm.sessions[successor.tabID] === successor)
            XCTAssertEqual(successor.items.map(\.text), ["Retain successor history"])
            XCTAssertEqual(successor.sourceItemsRevision, revision)
            XCTAssertFalse(successor.qualifiedRestorationReadiness.isAuthoritative)
            XCTAssertFalse(FileManager.default.fileExists(atPath: sessionFile(root: fixture.root, sessionID: failed.sessionID).path))
            XCTAssertTrue(fixture.providerRequests.events.isEmpty)
        }
    }

    func testCancellationBeforeAndAfterConfiguredAcknowledgementPreservesDurabilityBoundary() async throws {
        for cancelAfterAcknowledgement in [false, true] {
            let fixture = try await makeFixture()
            var captured: AgentSessionCreationHandle?
            fixture.vm.test_afterFreshForegroundSessionCreation = { handle in
                captured = handle
                if !cancelAfterAcknowledgement {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
            fixture.vm.test_afterConfiguredCreationAcknowledgement = { handle in
                XCTAssertEqual(handle.session.qualifiedRestorationReadiness, .authoritative(handle.bindingToken, .freshBindingDurablyCreated))
                if cancelAfterAcknowledgement {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
            let creation = Task { @MainActor in await fixture.vm.createAndActivateSessionTab() }
            let result = await creation.value
            XCTAssertTrue(creation.isCancelled, "The owner must cross the tested boundary with cancellation set")
            let handle = try XCTUnwrap(captured)
            let sessionID = try XCTUnwrap(handle.session.activeAgentSessionID)
            if cancelAfterAcknowledgement {
                let payload = try readPayload(fixture, sessionID: sessionID)
                XCTAssertEqual(payload.composeTabID, handle.session.tabID)
                XCTAssertTrue(payload.toLiveItems().isEmpty)
                XCTAssertEqual(handle.session.qualifiedRestorationReadiness, .authoritative(handle.bindingToken, .freshBindingDurablyCreated))
            } else {
                XCTAssertNil(result)
                guard let state = handle.session.creationState,
                      case .failedBeforeConfiguration = state.phase
                else {
                    return XCTFail("A cancelled creator must retain failed preparation, not wait forever")
                }
                XCTAssertFalse(handle.session.qualifiedRestorationReadiness.isAuthoritative)
                XCTAssertNotNil(handle.session.operationAdmissionFailureMessage)
                XCTAssertNil(fixture.vm.captureSessionCreationRetry(for: handle.session))
                XCTAssertFalse(FileManager.default.fileExists(atPath: sessionFile(root: fixture.root, sessionID: sessionID).path))
            }
            XCTAssertTrue(fixture.providerRequests.events.isEmpty)
        }
    }

    private enum ConfigurationMutation: CaseIterable { case model, parameters, autoEdit }

    private func mutateConfiguration(_ mutation: ConfigurationMutation, on session: AgentModeViewModel.TabSession) {
        switch mutation {
        case .model:
            session.selectedModelRaw += "-changed"
        case .parameters:
            session.acpModelParameterSelections = [.init(
                providerID: .openCode, baseModelRaw: "vendor/model", kind: .thinking,
                configID: "effort", valueRaw: "high"
            )]
        case .autoEdit:
            session.autoEditEnabled.toggle()
        }
    }

    private func registerGatedCreationCleanup(_ fixture: Fixture, gate: TestReleaseFence, creation: Task<UUID?, Never>) {
        addTeardownBlock { @MainActor in
            fixture.vm.test_afterFreshForegroundSessionCreation = nil
            fixture.vm.test_afterConfiguredCreationAcknowledgement = nil
            fixture.vm.test_setAfterDurableChildTabCreation(nil)
            await fixture.writer.test_setBeforeSessionWriteHook(nil)
            gate.release()
            creation.cancel()
            _ = await creation.value
        }
    }

    private func assertPreparingAdmission(_ fixture: Fixture, session: AgentModeViewModel.TabSession) async throws {
        XCTAssertTrue(session.qualifiedRestorationReadiness.isCreating)
        XCTAssertNil(fixture.vm.captureSessionCreationRetry(for: session))
        let blocker = try XCTUnwrap(session.operationAdmissionFailureMessage)
        let requiredSave = await fixture.vm.flushSaveRequired(for: session.tabID, workspaceID: fixture.workspaceID)
        guard case let .failure(error) = requiredSave else {
            return XCTFail("Generic required save must reject a preparing creation")
        }
        XCTAssertEqual(error.message, blocker)
        session.isDirty = true
        await fixture.vm.flushSave(for: session.tabID)
        let submission = fixture.vm.submitUserTurn(text: "Do not dispatch while preparing", tabID: session.tabID)
        guard case let .blocked(message) = submission else {
            return XCTFail("A preparing creation must reject submission before admitting a user row")
        }
        XCTAssertEqual(message, blocker)
        let directRun = await fixture.vm.startAgentRun(tabID: session.tabID, initialMessage: "Do not dispatch")
        guard case let .failed(message)? = directRun else {
            return XCTFail("A preparing creation must reject direct provider admission")
        }
        XCTAssertEqual(message, blocker)
        let sessionID = try XCTUnwrap(session.activeAgentSessionID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionFile(root: fixture.root, sessionID: sessionID).path))
        XCTAssertTrue(session.items.isEmpty)
        XCTAssertNil(session.runID)
        XCTAssertFalse(session.runState.isActive)
        XCTAssertTrue(fixture.providerRequests.events.isEmpty)
        XCTAssertTrue(session.qualifiedRestorationReadiness.isCreating)
        XCTAssertNil(fixture.vm.captureSessionCreationRetry(for: session))
    }

    private func failConfiguredCreation(_ fixture: Fixture) async throws -> (session: AgentModeViewModel.TabSession, sessionID: UUID) {
        let initialTabIDs = Set(fixture.prompt.currentComposeTabs.map(\.id))
        let sessionFolder = fixture.root.appendingPathComponent("AgentSessions").resolvingSymlinksInPath().standardizedFileURL
        await fixture.writer.test_setBeforeSessionWriteHook { url in
            guard url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path == sessionFolder.path else { return }
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try? Data("retained obstruction".utf8).write(to: url.appendingPathComponent("keep"))
        }
        let result = await fixture.vm.createAndActivateSessionTab()
        XCTAssertNil(result)
        let tab = try XCTUnwrap(fixture.prompt.currentComposeTabs.first { !initialTabIDs.contains($0.id) })
        let session = try XCTUnwrap(fixture.vm.sessions[tab.id])
        let sessionID = try XCTUnwrap(session.activeAgentSessionID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionFile(root: fixture.root, sessionID: sessionID).appendingPathComponent("keep").path))
        XCTAssertTrue(session.qualifiedRestorationReadiness.isCreating)
        XCTAssertFalse(session.qualifiedRestorationReadiness.isAuthoritative)
        return (session, sessionID)
    }

    private func removeWriteObstruction(_ fixture: Fixture, sessionID: UUID) async throws {
        await fixture.writer.test_setBeforeSessionWriteHook(nil)
        try FileManager.default.removeItem(at: sessionFile(root: fixture.root, sessionID: sessionID))
    }

    private func readPayload(_ fixture: Fixture, sessionID: UUID) throws -> AgentSession {
        try JSONDecoder().decode(AgentSession.self, from: Data(contentsOf: sessionFile(root: fixture.root, sessionID: sessionID)))
    }

    private func assertUnavailableAdmissionPreservesPayload(
        _ fixture: Fixture, session: AgentModeViewModel.TabSession, expectedBytes: Data?,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let sessionID = try XCTUnwrap(session.activeAgentSessionID, file: file, line: line)
        let failure = try XCTUnwrap(session.restorationAdmissionFailureMessage, file: file, line: line)
        let workspace = try XCTUnwrap(fixture.manager.activeWorkspace, file: file, line: line)
        let originalItems = session.items.map(\.id)
        session.draftText = "Keep this unsent local draft"
        guard case let .blocked(message) = fixture.vm.submitUserTurn(text: session.draftText, tabID: session.tabID) else {
            return XCTFail("Unavailable restored session must reject local submission", file: file, line: line)
        }
        XCTAssertEqual(message, failure, file: file, line: line)
        let route = await fixture.vm.activateRoutedAgentSession(tabID: session.tabID, sessionID: sessionID, workspace: workspace)
        XCTAssertEqual(route, .sessionNotFound, file: file, line: line)
        guard case let .failed(message)? = await fixture.vm.startAgentRun(tabID: session.tabID, initialMessage: "Do not dispatch") else {
            return XCTFail("Direct provider admission must report restoration failure", file: file, line: line)
        }
        XCTAssertEqual(message, failure, file: file, line: line)

        let candidate = try XCTUnwrap(fixture.vm.agentSessionLinkCandidate(
            tabID: session.tabID, sessionID: sessionID, tabName: "Unavailable", isWindowClosing: false
        ), file: file, line: line)
        XCTAssertTrue(fixture.vm.agentSessionLinkLiveSession(matching: candidate) === session, file: file, line: line)
        let request = AgentSessionLinkSendRequest(
            linkID: UUID(), linkGeneration: 1,
            observerEndpoint: AgentSessionLinkIdentityTestSupport.endpoint(sessionID: UUID(), windowID: 2),
            observerDisplayName: "Observer", message: "Do not append attributed history", workflow: nil
        )
        var authorizationCommits = 0
        let delivery = await fixture.vm.agentSessionLinkPerformSend(
            to: candidate, request: request,
            liveness: { .init(observerEndpointIsLive: true, targetEndpointIsLive: true, targetWindowIsClosing: false) },
            commitAuthorization: { authorizationCommits += 1
                return .committed
            }
        )
        guard case .blocked(.targetRestoreUnavailable) = delivery else {
            return XCTFail("Oversight delivery must reject unavailable restoration", file: file, line: line)
        }
        XCTAssertEqual(authorizationCommits, 0, file: file, line: line)
        // Both shortcuts matter: a clean carrier must not acknowledge required persistence, and
        // a later setting/draft mutation must not make the same unavailable session overwriteable.
        for dirty in [false, true] {
            session.isDirty = dirty
            let flush = await fixture.vm.flushSaveRequired(for: session.tabID, workspaceID: workspace.id)
            guard case let .failure(error) = flush else {
                return XCTFail("Unavailable restoration must reject required save even when clean", file: file, line: line)
            }
            XCTAssertEqual(error.message, failure, file: file, line: line)
        }
        XCTAssertEqual(session.items.map(\.id), originalItems, file: file, line: line)
        XCTAssertEqual(session.draftText, "Keep this unsent local draft", file: file, line: line)
        XCTAssertFalse(session.qualifiedRestorationReadiness.isAuthoritative, file: file, line: line)
        XCTAssertTrue(fixture.providerRequests.events.isEmpty, file: file, line: line)
        let payloadURL = sessionFile(root: fixture.root, sessionID: sessionID)
        if let expectedBytes {
            XCTAssertEqual(try Data(contentsOf: payloadURL), expectedBytes, file: file, line: line)
        } else {
            XCTAssertFalse(FileManager.default.fileExists(atPath: payloadURL.path), file: file, line: line)
        }
    }

    private struct Fixture {
        let root: URL
        let workspaceID: UUID
        let writer: AgentSessionDataService
        let vm: AgentModeViewModel
        let manager: WorkspaceManagerViewModel
        let prompt: PromptViewModel
        let providerRequests: LifecycleRecorder
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RestorationAdmission-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func makeWorkspace(root: URL, tabID: UUID = UUID(), sessionID: UUID? = nil) -> WorkspaceModel {
        WorkspaceModel(
            name: "Restoration admission", repoPaths: [], customStoragePath: root,
            composeTabs: [ComposeTabState(id: tabID, name: "Original", activeAgentSessionID: sessionID)], activeComposeTabID: tabID
        )
    }

    private func makeFixture(root suppliedRoot: URL? = nil, workspace suppliedWorkspace: WorkspaceModel? = nil) async throws -> Fixture {
        let root = try suppliedRoot ?? makeRoot()
        let workspace = suppliedWorkspace ?? makeWorkspace(root: root)
        let files = WorkspaceFilesViewModel()
        let keys = KeyManager(secureService: SecureKeysService(secureStorage: TestSecureStorageBackend()))
        let api = APISettingsViewModel(aiQueriesService: AIQueriesService(keyManager: keys), keyManager: keys, loadStoredDataOnInit: false)
        let prompt = PromptViewModel(fileManager: files, apiSettingsViewModel: api, windowID: -1, settingsManager: WindowSettingsManager(windowID: -1))
        let manager = WorkspaceManagerViewModel(fileManager: files, promptViewModel: prompt, performInitialWorkspaceActivation: false)
        await manager.awaitInitialized()
        manager.workspaces = [workspace]
        manager.activeWorkspace = workspace
        prompt.loadComposeTabsFromWorkspace(workspace)
        let requests = LifecycleRecorder()
        let vm = AgentModeViewModel(
            testWorkspacePath: root.path,
            codexControllerFactory: { _, _, _, _, _, _ in
                requests.record("codex")
                return LifecycleNoopCodexController(recorder: LifecycleRecorder())
            },
            claudeControllerFactory: { _, _, _, _ in
                requests.record("claude")
                return MonitorFakeNativeController()
            },
            headlessProviderFactory: { _, _ in
                requests.record("headless")
                return AgentSessionLinkCapturingHeadlessProvider(failuresRemaining: 1)
            },
            acpProviderFactory: { _, _ in requests.record("acp-provider")
                throw CocoaError(.featureUnsupported)
            },
            acpControllerFactory: { _, _ in requests.record("acp-controller")
                throw CocoaError(.featureUnsupported)
            },
            connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
            mcpServerEnabler: { false }
        )
        vm.workspaceManager = manager
        vm.promptManager = prompt
        let writer = AgentSessionDataService()
        vm.test_setAgentSessionSaver { session, owningWorkspace, count in
            try await writer.saveAgentSession(
                session, for: owningWorkspace, preparation: .alreadyCanonicalTranscript,
                trustedCanonicalItemCount: count
            )
        }
        vm.completeAgentSessionLinkDiscoveryEpoch(vm.beginAgentSessionLinkDiscoveryEpoch(workspaceID: workspace.id))
        let fixture = Fixture(root: root, workspaceID: workspace.id, writer: writer, vm: vm, manager: manager, prompt: prompt, providerRequests: requests)
        addTeardownBlock { @MainActor in
            vm.test_afterFreshForegroundSessionCreation = nil
            vm.test_afterConfiguredCreationAcknowledgement = nil
            vm.test_setAfterDurableChildTabCreation(nil)
            await writer.test_setBeforeSessionWriteHook(nil)
            for session in vm.sessions.values {
                session.saveDebounceTask?.cancel()
            }
            await vm.prepareForWindowClose()
            manager.prepareForWindowClose()
        }
        return fixture
    }

    private func persistCarrier(_ fixture: Fixture) async throws -> WorkspaceModel {
        fixture.manager.markWorkspaceDirty()
        let result = await fixture.manager.pollAndSaveStateWithOutcomeAsync(
            workspaceID: fixture.workspaceID, source: WorkspaceSaveSource("restorationAdmissionTest")
        )
        guard case .persisted = result else {
            throw NSError(domain: "RestorationAdmissionTests.carrierSave", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(result)"])
        }
        let workspace = try XCTUnwrap(fixture.manager.activeWorkspace)
        return try WorkspaceManagerViewModel.loadWorkspaceFromFile(
            at: fixture.manager.workspaceFileURL(for: workspace), scheduleNormalizationWriteback: false
        )
    }

    private func reopen(_ fixture: Fixture) async throws -> Fixture {
        let workspace = try await persistCarrier(fixture)
        await close(fixture)
        return try await makeFixture(root: fixture.root, workspace: workspace)
    }

    private func close(_ fixture: Fixture) async {
        fixture.vm.test_afterFreshForegroundSessionCreation = nil
        fixture.vm.test_afterConfiguredCreationAcknowledgement = nil
        fixture.vm.test_setAfterDurableChildTabCreation(nil)
        await fixture.writer.test_setBeforeSessionWriteHook(nil)
        for session in fixture.vm.sessions.values {
            session.saveDebounceTask?.cancel()
        }
        await fixture.vm.prepareForWindowClose()
        fixture.manager.prepareForWindowClose()
    }

    private func sessionFile(root: URL, sessionID: UUID) -> URL {
        root.appendingPathComponent("AgentSessions").appendingPathComponent("AgentSession-\(sessionID.uuidString).json")
    }
}

private actor RestorationInitialEffortJevClient: JevRoutingClientProtocol {
    let gate: TestReleaseFence
    private(set) var requestCount = 0

    init(gate: TestReleaseFence) {
        self.gate = gate
    }

    func listModels(apiKey _: String, timeout _: Duration) -> JevModelList {
        .init(models: [.init(name: "jev-latest")])
    }

    func judge(request: JevRoutingWireRequest, apiKey _: String, timeout _: Duration) async -> JevRoutingWireResponse {
        requestCount += 1
        await gate.enterAndWait()
        let choices = request.questions["effort"]?.criteria.keys.sorted() ?? []
        let chosen = choices.first ?? "high"
        return .init(
            model: JevRouterCredentialService.pinnedModel,
            answers: ["effort": .init(
                type: "choice", choice: chosen,
                probabilities: Dictionary(uniqueKeysWithValues: choices.map { ($0, $0 == chosen ? 1.0 : 0.0) }),
                confidence: 1.0
            )],
            usage: .init(inputTokens: 1, outputTokens: 1)
        )
    }
}
