import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptShared
import XCTest

#if DEBUG
    @MainActor
    final class AgentSessionLinkLateQualificationTests: XCTestCase {
        func testClaudeRunnerUsesOnlyCatalogReturnedBeforePhysicalInput() async throws {
            try await exerciseRunner(.claudeCode)
        }

        func testCodexReconnectUsesOnlyCatalogReturnedBeforePhysicalInput() async throws {
            try await exerciseRunner(.codexExec)
        }

        func testClaudeRunnerRetainsActualOfferAcrossBenignPolicyRenewal() async throws {
            try await exerciseRetainedOffer(.benign)
        }

        func testAbsentOfferCannotResurrectUntilFreshPositiveList() async throws {
            try await exerciseRetainedOffer(.absentThenFresh)
        }

        func testReconnectionCannotInheritPredecessorOffer() async throws {
            try await exerciseRetainedOffer(.reconnect)
        }

        func testAmbiguousReturnedDefinitionCannotRetainOffer() async throws {
            try await exerciseRetainedOffer(.ambiguous)
        }

        func testCatalogCaptureCannotBorrowAnotherBindingIncarnation() async throws {
            try await exerciseRetainedOffer(.mismatchedIngress)
        }

        func testAvailabilityProducerABAVetoesRetainedOffer() async throws {
            try await exerciseRetainedOffer(.availabilityABA)
        }

        func testActualOfferCapturesConsentExpiryWithoutTimer() async throws {
            try await exerciseRetainedOffer(.expiry)
        }

        func testCommittedDeletionInvalidatesActualOfferBeforeCleanup() async throws {
            try await exerciseRetainedOffer(.committedDeletion)
        }

        func testReversibleDeletionInvalidatesActualOffersOnBeginAndFailure() async throws {
            try await exerciseRetainedOffer(.failedDeletion)
        }

        private enum RetainedOfferCase {
            case benign, absentThenFresh, reconnect, ambiguous, mismatchedIngress, availabilityABA, expiry, committedDeletion, failedDeletion

            var qualifies: Bool {
                self == .benign || self == .absentThenFresh || self == .expiry
            }
        }

        private func exerciseRetainedOffer(_ scenario: RetainedOfferCase) async throws {
            try await MCPSharedServerTestLease.shared.withLease { _ in
                try await self.exerciseRunner(.claudeCode, catalogBeforeSend: scenario.qualifies, retainedOffer: scenario)
            }
        }

        func testQualificationLogCost() throws {
            try XCTSkipUnless(ProcessInfo.processInfo.environment["RPCE_RUN_SCALE_TESTS"] == "quiet-qualification", "Opt-in qualification diagnostic cost")
            let tabID = UUID()
            var samples: [Double] = []
            for ordinal in 0 ..< 1100 {
                let start = ContinuousClock.now
                let logged = AgentSessionLinkCatalogDiagnostics.quietQualification(
                    tabID: tabID, reserved: false, candidate: true, routingGeneration: 42,
                    definition: .exact, serverProof: true, ordinary: false, qualified: true
                )
                let duration = start.duration(to: .now)
                try XCTSkipUnless(logged, "Notice logging disabled: no enabled-path cost sample")
                if ordinal >= 100 {
                    samples.append(Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15)
                }
            }
            samples.sort()
            print("QUIET_QUALIFICATION_LOG_COST count=\(samples.count) median_ms=\(samples[500]) p95_ms=\(samples[949]) max_ms=\(samples[999])")
        }

        private func exerciseRunner(_ kind: AgentProviderKind) async throws {
            // These are the two sides of the physical-input boundary, not provider permutations.
            for beforeSend in [true, false] {
                try await MCPSharedServerTestLease.shared.withLease { _ in
                    try await self.exerciseRunner(kind, catalogBeforeSend: beforeSend)
                }
            }
        }

        private func exerciseRunner(_ kind: AgentProviderKind, catalogBeforeSend: Bool, retainedOffer: RetainedOfferCase? = nil) async throws {
            let reusesConnection = retainedOffer != nil
            let manager = ServerNetworkManager.shared
            try await AppGlobalMCPServiceComposition.shared.ensureRegistered()
            let window = WindowState(domainRuntime: AppDomainRuntimeComposition.shared.runtime)
            let windowID = window.windowID
            WindowStatesManager.shared.registerWindowState(window)
            WindowStatesManager.shared.attachAgentSessionLinkBridge()
            let registration = try await AppDomainRuntimeComposition.shared.register(window.mcpServer.windowMCPToolCatalogService)
            let vm = window.agentModeViewModel
            let wasClaudeConnected = window.apiSettingsViewModel.isClaudeCodeConnected
            let wasCodexConnected = window.apiSettingsViewModel.isCodexConnected
            let bridge = AgentSessionLinkRuntimeBridge.shared
            let wasDecisionSuppressed = bridge.delegationScopes.test_suppressDecisionDelivery
            let provider = HeldDiscoveryProvider()
            let clientName = kind == .codexExec ? AgentProviderKind.codexMCPClientID : AgentProviderKind.claudeMCPClientID
            let runID = UUID()
            let observerTab = UUID()
            let targetTab = UUID()
            var transports: [PersistentMCPTestEndpoint] = []
            var grant: DomainAgentSessionLinkReference?
            var session: AgentTabSession?
            var native: ClaudeNativeProcessSessionController?
            var expiringScope: DomainDelegationScopeRecord?
            let codex = MonitorFakeCodexController(dispatches: MonitorCodexDispatchRecorder(), processID: getpid())
            let frames = WrittenFrames()
            let cleanup: @MainActor () async -> Void = {
                session?.oversight.autoWakeOnUpdates = false
                session?.agentTask?.cancel()
                session?.codexEventTask?.cancel()
                if let native { await native.shutdown() }
                await codex.shutdown()
                await session?.agentTask?.value
                await provider.shutdown()
                await manager.debugSetReturnedCatalogToolsForTesting(nil)
                await manager.debugSetCatalogOfferRouteForTesting(nil)
                if let expiringScope {
                    bridge.delegationScopes.revoke(scopeID: expiringScope.id)
                }
                bridge.delegationScopes.test_suppressDecisionDelivery = wasDecisionSuppressed
                if let grant {
                    await bridge.revokeLink(linkID: grant.linkID, generation: grant.generation)
                }
                for transport in transports {
                    transport.client.close()
                    await transport.connectionManager.stop()
                    await manager.debugRemoveConnection(transport.connectionID)
                }
                await manager.clearClientConnectionPolicy(for: clientName, windowID: windowID, runID: runID)
                await manager.cleanupRunRoutingState(for: runID, windowID: windowID)
                window.apiSettingsViewModel.isClaudeCodeConnected = wasClaudeConnected
                window.apiSettingsViewModel.isCodexConnected = wasCodexConnected
                await window.tearDown()
                await AppDomainRuntimeComposition.shared.unregister(registration.handle)
                WindowStatesManager.shared.unregisterWindowState(window)
            }
            do {
                await window.workspaceManager.awaitInitialized()
                var workspace = WorkspaceModel(name: "Late catalog qualification", repoPaths: [])
                workspace.isEphemeral = true
                workspace.composeTabs = [
                    ComposeTabState(id: observerTab, name: "Observer", activeAgentSessionID: UUID()),
                    ComposeTabState(id: targetTab, name: "Target", activeAgentSessionID: UUID())
                ]
                workspace.activeComposeTabID = observerTab
                for tab in workspace.composeTabs {
                    let payload = try AgentSession(id: XCTUnwrap(tab.activeAgentSessionID), workspaceID: workspace.id, composeTabID: tab.id, name: tab.name, agentKind: kind.rawValue, autoWakeOnOversightUpdates: false)
                    _ = try await AgentSessionDataService.shared.saveAgentSession(payload, for: workspace)
                }
                window.workspaceManager.workspaces.append(workspace)
                let switched = await window.workspaceManager.switchWorkspace(to: workspace, saveState: false)
                XCTAssertTrue(switched.didSwitch)
                window.promptManager.loadComposeTabsFromWorkspace(workspace, syncPromptText: false)
                let observer = await vm.ensureSessionReady(tabID: observerTab, reconnectActiveProviders: false)
                session = observer
                let target = await vm.ensureSessionReady(tabID: targetTab, reconnectActiveProviders: false)
                observer.installRunID(runID)
                observer.appendItem(.user("ordinary baseline", sequenceIndex: observer.nextSequenceIndex))
                observer.appendItem(.assistant("ordinary conclusion", sequenceIndex: observer.nextSequenceIndex))
                observer.runState = .completed
                vm.refreshDerivedTranscriptState(for: observer, publishActivePresentation: false)
                let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(vm, tabID: observerTab)
                guard case .added = try await bridge.addMonitorLink(observerSessionID: endpoint.sessionID, rawTargetSessionID: XCTUnwrap(target.activeAgentSessionID).uuidString) else {
                    throw CancellationError()
                }
                let links = await AppDomainRuntimeComposition.shared.runtime.agentSessionLinkAuthority.links(forObserver: endpoint.sessionID)
                let link = try XCTUnwrap(links.items.first)
                grant = .init(linkID: link.linkID, generation: link.generation)
                if retainedOffer == .expiry {
                    let grantee = endpoint.sessionID
                    bridge.delegationScopes.test_suppressDecisionDelivery = true
                    let request = try bridge.delegationScopes.requestScope(
                        requesterSessionID: grantee, requesterTabID: nil, kind: .tree(rootSessionID: grantee),
                        capabilities: [.observe], guardrails: .init(), expiresInSeconds: 60,
                        reason: nil, idempotencyKey: nil
                    ).get()
                    expiringScope = try bridge.delegationScopes.approve(requestID: request.id).get()
                }
                // Only the retention cases begin with a positive actual list. No fixture installs
                // a positive projection, expected definition, or route token.
                if !reusesConnection {
                    await manager.debugSetReturnedCatalogToolsForTesting { tools, _ in tools.filter { $0.name != MCPWindowToolName.selfNoop } }
                }
                await manager.installClientConnectionPolicy(for: clientName, windowID: windowID, restrictedTools: AgentModeMCPToolPolicy.restrictedTools, oneShot: true, reason: "late-catalog fixture", ttl: 60, tabID: observerTab, runID: runID, additionalTools: reusesConnection ? AgentModeMCPPolicyInstaller.additionalTools(for: kind) : nil, purpose: .agentModeRun, taskLabelKind: nil, allowsAgentExternalControlTools: false)
                await manager.setEnabled(true)
                let initial = try await PersistentMCPTestEndpoint.make(label: "late-catalog-initial", networkManager: manager, clientName: clientName, requiredToolNames: [MCPWindowToolName.agentSessionLink])
                transports.append(initial)
                await provider.attach(initial)
                _ = try await provider.listTools()
                XCTAssertEqual(vm.selfNoopHintIsCurrent(for: observer), reusesConnection)
                let initialOffer = await manager.debugRunCatalogProjection(for: runID)
                observer.isPreparingInitialWorktree = true
                observer.oversight.autoWakeOnUpdates = true
                target.installRunID(UUID())
                _ = target.beginRunAttempt(source: "late-catalog ordinary cause")
                target.runState = .running
                target.appendItem(.assistant("ordinary cause", sequenceIndex: target.nextSequenceIndex))
                await vm.test_finishQuietFeasibilityRun(target)
                await bridge.test_settleTargetPublications()
                await bridge.test_refreshStatus(sessionIDs: [endpoint.sessionID])
                let attempt = try XCTUnwrap(observer.oversight.pendingAutoWake)
                attempt.task?.cancel()
                await attempt.task?.value
                let dispatchID = AgentSessionLinkPromptDispatchID.autoWake(wakeID: attempt.wakeID)
                let early = try XCTUnwrap(vm.agentSessionLinkPromptClaim(for: observer, dispatchID: dispatchID))
                XCTAssertFalse(early.routineQuietCheckIn)
                observer.isPreparingInitialWorktree = false
                XCTAssertNotNil(vm.agentSessionLinkPrepareAutoWakeDispatch(wakeID: attempt.wakeID, endpoint: endpoint))
                if retainedOffer == .committedDeletion {
                    let prior = try XCTUnwrap(initialOffer)
                    let route = try XCTUnwrap(prior.routeToken)
                    XCTAssertNotNil(prior.returnedCatalog?[MCPWindowToolName.becomeOverseer])
                    let before = await manager.hasCurrentReturnedTool(AgentModeViewModel.selfNoopCatalogDefinition, routeToken: route, projectionRevision: prior.projectionRevision)
                    XCTAssertTrue(before)
                    XCTAssertNotNil(vm.agentSessionLinkBootstrapState(for: endpoint))
                    let registry = AgentSessionDeletionRegistry.shared
                    let oldCommit = registry.commitObserver
                    let oldChange = registry.changeObserver
                    let gate = TestReleaseFence(name: "committed deletion before authority cleanup")
                    defer {
                        gate.release()
                        registry.commitObserver = oldCommit
                        registry.changeObserver = oldChange
                    }
                    registry.commitObserver = { sessionID, origin, fileRemoved in
                        if sessionID == endpoint.sessionID { await gate.enterAndWait() }
                        await oldCommit?(sessionID, origin, fileRemoved)
                    }
                    // Begin notifies the existing eligibility audit normally; only commit cleanup
                    // waits at the gate. No file deletion is invoked.
                    let token = try registry.beginDurableDeletion(sessionID: endpoint.sessionID)
                    defer { registry.didFailDurableDeletion(token) }
                    _ = try await provider.listTools()
                    let beforeCommitProjection = await manager.debugRunCatalogProjection(for: runID)
                    let beforeCommit = try XCTUnwrap(beforeCommitProjection)
                    let beforeCommitRoute = try XCTUnwrap(beforeCommit.routeToken)
                    let supportBeforeCommit = await manager.hasCurrentReturnedTool(AgentModeViewModel.selfNoopCatalogDefinition, routeToken: beforeCommitRoute, projectionRevision: beforeCommit.projectionRevision)
                    XCTAssertTrue(supportBeforeCommit)
                    XCTAssertTrue(vm.selfNoopHintIsCurrent(for: observer))
                    let deletion = Task { @MainActor in await registry.didCommitDurableDeletion(token) }
                    guard await gate.waitUntilEntered() else {
                        gate.release()
                        await deletion.value
                        throw CancellationError()
                    }
                    do {
                        XCTAssertTrue(registry.isPermanentlyDeleted(sessionID: endpoint.sessionID))
                        XCTAssertNil(vm.agentSessionLinkBootstrapState(for: endpoint))
                        let currentInputs = await manager.debugCurrentRunCatalogOfferInputs(for: runID)
                        let retained = await manager.hasCurrentReturnedTool(AgentModeViewModel.selfNoopCatalogDefinition, routeToken: beforeCommitRoute, projectionRevision: beforeCommit.projectionRevision)
                        // Sample the independent physical fence before a fresh list can replace
                        // the observation. Acquisition admits ordinary owed work, not quiet permission.
                        let reserved = try XCTUnwrap(vm.agentSessionLinkPromptClaimStore.pendingClaim(dispatchID: dispatchID, observerSessionID: endpoint.sessionID))
                        XCTAssertFalse(reserved.routineQuietCheckIn)
                        let hintCurrent = vm.selfNoopHintIsCurrent(for: observer)
                        let acquired = vm.agentSessionLinkAcquirePhysicalDispatch(for: observer, dispatchID: dispatchID)
                        vm.agentSessionLinkRecordPhysicalDispatchNotAttempted(for: observer, dispatchID: dispatchID)
                        print("DELETION_RETAINED_OFFER inputsUnchanged=\(currentInputs == beforeCommit.offerInputs) serverProof=\(retained) mirrorHint=\(hintCurrent) physicalAcquisition=\(acquired)")
                        XCTAssertFalse(retained, "A committed deletion changes advertisement eligibility before asynchronous authority cleanup")
                        XCTAssertNotEqual(currentInputs, beforeCommit.offerInputs)
                        XCTAssertFalse(hintCurrent)
                        XCTAssertTrue(acquired, "Ordinary acquisition remains independent of quiet eligibility")
                        XCTAssertTrue(frames.userMessages.isEmpty)
                        XCTAssertTrue(codex.startedTurns.isEmpty)
                        let names = try await provider.listTools()
                        XCTAssertFalse(names.contains(MCPWindowToolName.becomeOverseer), "A fresh actual list must reflect the committed tombstone")
                        XCTAssertTrue(names.contains(MCPWindowToolName.selfNoop), "Cleanup has not yet revoked the outbound link")
                        XCTAssertNotEqual(Set(names), try Set(XCTUnwrap(prior.returnedCatalog).keys))
                    } catch {
                        gate.release()
                        await deletion.value
                        throw error
                    }
                    gate.release()
                    await deletion.value
                    registry.commitObserver = oldCommit
                    registry.changeObserver = oldChange
                    await cleanup()
                    return
                }
                if retainedOffer == .failedDeletion {
                    let registry = AgentSessionDeletionRegistry.shared
                    let prior = try XCTUnwrap(initialOffer)
                    let route = try XCTUnwrap(prior.routeToken)
                    let supportBeforeBegin = await manager.hasCurrentReturnedTool(AgentModeViewModel.selfNoopCatalogDefinition, routeToken: route, projectionRevision: prior.projectionRevision)
                    XCTAssertTrue(supportBeforeBegin)
                    let before = ServerNetworkManager.catalogAdvertisementRevision
                    let token = try registry.beginDurableDeletion(sessionID: endpoint.sessionID)
                    defer { registry.didFailDurableDeletion(token) }
                    XCTAssertNotEqual(ServerNetworkManager.catalogAdvertisementRevision, before)
                    let oldSupport = await manager.hasCurrentReturnedTool(AgentModeViewModel.selfNoopCatalogDefinition, routeToken: route, projectionRevision: prior.projectionRevision)
                    XCTAssertFalse(oldSupport, "Beginning deletion changes bootstrap eligibility before cleanup")
                    XCTAssertFalse(vm.selfNoopHintIsCurrent(for: observer))
                    _ = try await provider.listTools()
                    let duringProjection = await manager.debugRunCatalogProjection(for: runID)
                    let during = try XCTUnwrap(duringProjection)
                    let duringRoute = try XCTUnwrap(during.routeToken)
                    let currentSupport = await manager.hasCurrentReturnedTool(AgentModeViewModel.selfNoopCatalogDefinition, routeToken: duringRoute, projectionRevision: during.projectionRevision)
                    XCTAssertTrue(currentSupport)
                    let inProgress = ServerNetworkManager.catalogAdvertisementRevision
                    registry.didFailDurableDeletion(token)
                    XCTAssertNil(registry.state(forSessionID: endpoint.sessionID))
                    XCTAssertNotEqual(ServerNetworkManager.catalogAdvertisementRevision, inProgress)
                    let afterFailure = await manager.hasCurrentReturnedTool(AgentModeViewModel.selfNoopCatalogDefinition, routeToken: duringRoute, projectionRevision: during.projectionRevision)
                    XCTAssertFalse(afterFailure, "Failure restores eligibility but cannot resurrect an earlier offer")
                    XCTAssertFalse(vm.selfNoopHintIsCurrent(for: observer))
                    _ = try await provider.listTools()
                    XCTAssertTrue(vm.selfNoopHintIsCurrent(for: observer))
                    XCTAssertTrue(frames.userMessages.isEmpty)
                    XCTAssertTrue(codex.startedTurns.isEmpty)
                    await cleanup()
                    return
                }
                // Keep the production policy installer. Only process/PID admission is replaced
                // with this test process's real socket client after that policy has been installed.
                vm.test_initializeRunService(mcpServerEnabler: { true }, expectedPIDPolicyArmer: { spec in
                    guard let name = spec.clientName else { return false }
                    await manager.registerExpectedAgentPID(getpid(), for: name, runID: spec.runID)
                    let armed = await manager.requireExpectedAgentPIDForPendingPolicy(for: name, runID: spec.runID, windowID: spec.windowID)
                    guard armed else { return false }
                    if let retainedOffer {
                        if retainedOffer == .benign || retainedOffer == .expiry {
                            let currentInputs = await manager.debugCurrentRunCatalogOfferInputs(for: runID)
                            XCTAssertEqual(initialOffer?.offerInputs, currentInputs, "Only a semantically benign renewal may retain an offer")
                        }
                        let prior = try? XCTUnwrap(initialOffer)
                        if retainedOffer == .mismatchedIngress {
                            // Model a captured token just before rebinding, with colliding per-session
                            // revision values. Actual definitions still come from the real socket list.
                            await manager.debugSetCatalogOfferRouteForTesting { route in
                                guard let route else { return nil }
                                let endpoint = route.observerEndpoint
                                return .init(
                                    runID: route.runID,
                                    observerEndpoint: .init(
                                        windowID: endpoint.windowID, workspaceID: endpoint.workspaceID,
                                        tabID: endpoint.tabID, sessionID: endpoint.sessionID,
                                        persistentBindingGeneration: UUID(),
                                        bindingTransitionGeneration: endpoint.bindingTransitionGeneration
                                    ),
                                    connectionID: route.connectionID,
                                    routingAuthorityGeneration: route.routingAuthorityGeneration,
                                    connectionLifecycleGeneration: route.connectionLifecycleGeneration
                                )
                            }
                        }
                        if retainedOffer == .availabilityABA {
                            ToolAvailabilityStore.shared.debugDisableAndReenableWithoutPersistenceForTesting(MCPWindowToolName.selfNoop)
                        }
                        if retainedOffer == .absentThenFresh || retainedOffer == .reconnect {
                            await manager.debugSetReturnedCatalogToolsForTesting { tools, _ in tools.filter { $0.name != MCPWindowToolName.selfNoop } }
                        } else if retainedOffer == .ambiguous {
                            await manager.debugSetReturnedCatalogToolsForTesting { tools, _ in
                                tools + tools.filter { $0.name == MCPWindowToolName.selfNoop }
                            }
                        }
                        do {
                            if retainedOffer == .reconnect {
                                let next = try await PersistentMCPTestEndpoint.make(label: "retained-offer-reconnect", networkManager: manager, clientName: name, useProductionAgentAdmission: true, requiredToolNames: [MCPWindowToolName.agentSessionLink])
                                transports.append(next)
                                await provider.attach(next)
                            }
                            if retainedOffer == .absentThenFresh || retainedOffer == .reconnect || retainedOffer == .ambiguous || retainedOffer == .mismatchedIngress {
                                _ = try await provider.listTools()
                            }
                            await manager.debugSetCatalogOfferRouteForTesting(nil)
                            if retainedOffer == .mismatchedIngress {
                                let captured = await manager.debugRunCatalogProjection(for: runID)
                                XCTAssertNil(captured?.returnedCatalog, "A list must not associate another binding's barriers or expiry with its shaped response")
                            }
                            if let prior, let token = prior.routeToken, retainedOffer != .benign, retainedOffer != .expiry {
                                let oldSupport = await manager.hasCurrentReturnedTool(AgentModeViewModel.selfNoopCatalogDefinition, routeToken: token, projectionRevision: prior.projectionRevision)
                                XCTAssertFalse(oldSupport, "A later absent/ambiguous list, reconnect or producer ABA cannot reuse a positive predecessor")
                            }
                            if retainedOffer == .absentThenFresh {
                                await manager.debugSetReturnedCatalogToolsForTesting(nil)
                                let absentProjection = await manager.debugRunCatalogProjection(for: runID)
                                let absent = try XCTUnwrap(absentProjection)
                                let token = try XCTUnwrap(absent.routeToken)
                                let restoredWithoutList = await manager.hasCurrentReturnedTool(AgentModeViewModel.selfNoopCatalogDefinition, routeToken: token, projectionRevision: absent.projectionRevision)
                                XCTAssertFalse(restoredWithoutList, "Restored expected presence is not a returned offer")
                                _ = try await provider.listTools()
                            }
                        } catch {
                            XCTFail("Retention edge fixture failed: \(error)")
                        }
                        let committed = await manager.isRunRouteAuthoritativelyCommitted(runID: spec.runID, windowID: spec.windowID, tabID: spec.tabID, expectedAgentPID: getpid())
                        await manager.clearExpectedAgentPID(getpid(), for: name, runID: spec.runID)
                        return committed
                    }
                    if catalogBeforeSend {
                        await manager.debugSetReturnedCatalogToolsForTesting(nil)
                    }
                    do {
                        let next = try await PersistentMCPTestEndpoint.make(label: "late-catalog-current-policy", networkManager: manager, clientName: name, useProductionAgentAdmission: true, requiredToolNames: [MCPWindowToolName.agentSessionLink])
                        transports.append(next)
                        await provider.attach(next)
                        _ = try await provider.listTools()
                        try await Self.assertReturnedDeclaration(runID: spec.runID, expected: catalogBeforeSend)
                        let committed = await manager.isRunRouteAuthoritativelyCommitted(runID: spec.runID, windowID: spec.windowID, tabID: spec.tabID, expectedAgentPID: getpid())
                        await manager.clearExpectedAgentPID(getpid(), for: name, runID: spec.runID)
                        return committed
                    } catch {
                        XCTFail("Actual startup catalog failed: \(error)")
                        await manager.clearExpectedAgentPID(getpid(), for: name, runID: spec.runID)
                        return false
                    }
                })
                if kind == .claudeCode {
                    window.apiSettingsViewModel.isClaudeCodeConnected = true
                    let controller = ClaudeNativeProcessSessionController(runID: runID, tabID: observerTab, windowID: windowID, workspacePath: nil, config: .discovery(commandName: "/usr/bin/false", runtimeVariant: .standard))
                    native = controller
                    await controller.test_installConfigurationTransport(initialized: reusesConnection, controlRequest: { _ in ["session_id": "late-catalog-claude"] }, write: { frames.append($0) })
                    observer.claudeController = controller
                    let binding = vm.providerBindingService
                    let runtime = ClaudeControllerLaunchPolicy.resolve(permissionMode: binding.runtimePermission(for: kind, profile: observer.permissionProfile).claudePermissionMode, profile: observer.permissionProfile, defaults: binding.preferences.defaults, securePermissions: binding.preferences.securePermissions)
                    let permission = ClaudeAgentToolPreferences.resolvePermissionMode(requestedMode: runtime.permissionMode ?? observer.permissionProfile.claudePermissionMode, agentKind: kind, selectedModelRaw: observer.selectedModelRaw, unsupportedAutoFallback: .autoApproveEdits)
                    try vm.test_claudeCoordinator.test_setControllerLaunchSettings(.init(runtimeVariant: .standard, workspacePath: vm.effectiveWorkspacePath(for: observer), permissionMode: permission.effectiveMode, allowNativeBashTool: runtime.allowNativeBashTool, mcpStrictMode: runtime.mcpStrictMode), for: observer)
                } else {
                    window.apiSettingsViewModel.isCodexConnected = true
                    observer.codexController = codex
                    observer.codexNeedsReconnect = true
                    observer.codexControllerPermissionProfile = observer.permissionProfile
                    observer.codexControllerTaskLabelKind = observer.mcpControlContext?.taskLabelKind
                    observer.codexControllerWorkspacePaths = try vm.codexRuntimeWorkspacePaths(for: observer)
                    observer.codexControllerFeatureState = .init(computerUseEnabled: false, goalSupportEnabled: CodexGoalSupport.isEnabled, reasoningSummariesEnabled: CodexReasoningSummaries.isEnabled, memoriesEnabled: CodexMemories.isEnabled, capabilities: vm.providerBindingService.codexCapabilitiesForLaunch(isMCPRelated: observer.isMCPRelated))
                    codex.setStartOrResumeHook {
                        await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: runID)
                        let armed = await manager.requireExpectedAgentPIDForPendingPolicy(for: clientName, runID: runID, windowID: windowID)
                        if catalogBeforeSend { await manager.debugSetReturnedCatalogToolsForTesting(nil) }
                        do {
                            XCTAssertTrue(armed)
                            let next = try await PersistentMCPTestEndpoint.make(label: "late-catalog-codex-startup", networkManager: manager, clientName: clientName, useProductionAgentAdmission: true, requiredToolNames: [MCPWindowToolName.agentSessionLink])
                            await MainActor.run { transports.append(next) }
                            await provider.attach(next)
                            _ = try await provider.listTools()
                            try await Self.assertReturnedDeclaration(runID: runID, expected: catalogBeforeSend)
                        } catch {
                            XCTFail("Actual Codex startup socket failed: \(error)")
                        }
                        await manager.clearExpectedAgentPID(getpid(), for: clientName, runID: runID)
                    }
                }
                let outcome = AgentRunStartOutcomeRecorder()
                await vm.startAgentRun(tabID: observerTab, initialMessage: "", directStartOptions: .laneUpdate(wakeID: attempt.wakeID), startOutcome: outcome)
                XCTAssertEqual(outcome.outcome, .accepted)
                try await AsyncTestWait.waitUntil("one real runner physical input") { kind == .claudeCode ? !frames.userMessages.isEmpty : !codex.startedTurns.isEmpty }
                let sent = kind == .claudeCode ? frames.userMessages : codex.startedTurns
                if retainedOffer == .benign || retainedOffer == .expiry {
                    let retained = await manager.debugRunCatalogProjection(for: runID)
                    XCTAssertEqual(retained?.routeToken, initialOffer?.routeToken, "Renewal must not relabel the actual offer as a newer-generation list")
                    XCTAssertEqual(retained?.projectionRevision, initialOffer?.projectionRevision, "No re-list or replacement observation was manufactured")
                    XCTAssertEqual(transports.count, 1, "The initialized Claude process keeps its original socket")
                    if retainedOffer == .expiry {
                        let bound = try XCTUnwrap(expiringScope?.grant.guardrails.expiresAt)
                        XCTAssertEqual(retained?.offerExpiresAt, bound)
                        XCTAssertTrue(try XCTUnwrap(retained).hasUnchangedOffer(at: bound.addingTimeInterval(-0.001)))
                        XCTAssertFalse(try XCTUnwrap(retained).hasUnchangedOffer(at: bound), "The same offer becomes negative at the captured consent expiry, without any timer or mutation")
                    }
                }
                XCTAssertEqual(sent.count, 1)
                XCTAssertEqual(try XCTUnwrap(sent.first).contains("Nothing needed? Call self_noop."), catalogBeforeSend)
                let owner = try XCTUnwrap(observer.activeRunOwnership)
                XCTAssertEqual(observer.quietLedger.routineWakeID(owner: owner) == attempt.wakeID, catalogBeforeSend)
                XCTAssertEqual(observer.quietLedger.hasOrdinaryOccurrence(owner: owner), !catalogBeforeSend)
                if !catalogBeforeSend {
                    await manager.debugSetReturnedCatalogToolsForTesting(nil)
                    let afterSendTools = try await provider.listTools()
                    XCTAssertTrue(afterSendTools.contains(MCPWindowToolName.selfNoop))
                    XCTAssertNil(observer.quietLedger.routineWakeID(owner: owner), "Post-send evidence never upgrades the attempt")
                    XCTAssertTrue(observer.quietLedger.hasOrdinaryOccurrence(owner: owner))
                }
                // Both providers acknowledge the owed batch; no routine debt remains.
                await bridge.test_settleTargetPublications()
                await bridge.test_refreshStatus(sessionIDs: [endpoint.sessionID])
                let remaining = vm.agentSessionLinkPassiveNoticesBySessionID[endpoint.sessionID]
                XCTAssertFalse(remaining?.entries.contains { $0.isRoutineWakeEligible } ?? false)
                XCTAssertTrue(observer.liveItemIDs.contains(attempt.wakeID))
                XCTAssertEqual(kind == .claudeCode ? frames.userMessages.count : codex.startedTurns.count, 1)
                await cleanup()
            } catch {
                await cleanup()
                throw error
            }
        }

        private static func assertReturnedDeclaration(runID: UUID, expected: Bool) async throws {
            let manager = ServerNetworkManager.shared
            let observed = await manager.debugRunCatalogProjection(for: runID)
            let projection = try XCTUnwrap(observed)
            let route = try XCTUnwrap(projection.routeToken)
            let returned = await manager.hasCurrentReturnedTool(AgentModeViewModel.selfNoopCatalogDefinition, routeToken: route, projectionRevision: projection.projectionRevision)
            XCTAssertEqual(returned, expected, "The real startup socket, not a supplied readiness result, establishes support")
        }

        private final class WrittenFrames: @unchecked Sendable {
            private let lock = NSLock()
            private var frames: [Data] = []
            func append(_ data: Data) {
                lock.withLock { frames.append(data) }
            }

            var userMessages: [String] {
                lock.withLock { frames }.compactMap { data in
                    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["type"] as? String == "user", let message = object["message"] as? [String: Any] else { return nil }
                    let content = message["content"] as? [[String: Any]]
                    return content?.compactMap { $0["text"] as? String }.joined()
                }
            }
        }
    }
#endif
