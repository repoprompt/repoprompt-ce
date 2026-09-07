import Darwin
@testable import RepoPromptApp
import XCTest

/// Actual controller/client/control + production private bridge + pinned native
/// executable. Only the grant source and loopback Responses service are fake.
@MainActor
final class CodexSwitchboardControllerRuntimeTests: XCTestCase {
    func testActualNativeControllerSwitchesAccountsOnSameConversation() async throws {
        try await exerciseNativeController(refreshWhileBusy: false)
    }

    func testActualNativeRefreshKeepsAppliedAccountWhileDestinationWaits() async throws {
        try await exerciseNativeController(refreshWhileBusy: true)
    }

    func testUnavailableDestinationCapacityCannotMutateNativeAccount() async throws {
        try await exerciseNativeController(refreshWhileBusy: false, refuseCapacity: true)
    }

    func testNewPairingRetainsExactLiveControllerConversation() async throws {
        try await exerciseNativeController(refreshWhileBusy: false, repairPairing: true)
    }

    func testPersistentUnauthorizedCannotFallThroughToPendingAccount() async throws {
        try await exerciseNativeController(refreshWhileBusy: true, persistentUnauthorized: true)
    }

    func testRevocationBetweenAdmissionAndFramePublicationPreventsNativeTurn() async throws {
        try await exerciseNativeController(refreshWhileBusy: false, revokeAtPublication: true)
    }

    func testLargeSyntheticContextSurvivesAuthorizedWriteAndAccountSwitch() async throws {
        try await exerciseNativeController(refreshWhileBusy: false, largeContext: true)
    }

    func testRevocationAfterNativeFramePrefixRetiresOwnedTransportWithoutTurn() async throws {
        try await exerciseNativeController(refreshWhileBusy: false, revokeAfterPrefix: true)
    }

    private func exerciseNativeController(refreshWhileBusy: Bool, refuseCapacity: Bool = false, repairPairing: Bool = false, persistentUnauthorized: Bool = false, revokeAtPublication: Bool = false, largeContext: Bool = false, revokeAfterPrefix: Bool = false) async throws {
        let fixture = try SwitchboardControllerRuntimeFixture()
        defer { fixture.finish() }
        let configuration = try fixture.configuration()
        let control = CodexSwitchboardSessionControl()
        let authorization = control.authorization
        let client = try await CodexAppServerClient.makeForHostedIntegrationTest(configuration, beforeFramePublication: { method in
            if revokeAtPublication, method == "turn/start" { authorization.invalidate() }
        }, afterFrameChunk: { method, _ in
            if revokeAfterPrefix, method == "turn/start" { authorization.invalidate() }
        })
        let watchdog = Task {
            do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
            await client.stop()
        }
        defer { watchdog.cancel() }
        let binding = ControlBinding(control)
        var options = CodexNativeSessionController.Options.agentModeDefault(
            approvalPolicyProvider: { .never }, sandboxModeProvider: { .readOnly }, approvalReviewerProvider: { .user },
            shellToolEnabled: false, suppressThirdPartyMCPServers: true,
            goalSupportEnabledProvider: { false }, memoriesEnabledProvider: { false }
        )
        // This kernel lane has no app/MCP authority. Do not consult the default
        // options closure, which reads global MCP entries and user preferences.
        options.configOverridesProvider = {
            CodexOverrides.appServerConfigMap(
                toolPolicy: .init(
                    toolOutputTokenLimit: 1024,
                    shellToolEnabled: false,
                    webSearchRequestEnabled: false,
                    multiAgentEnabled: false,
                    modelReasoningSummary: CodexOverrides.ReasoningSummary.none
                ),
                featurePolicy: .defaultDisabled
            )
        }
        // agentModeDefault otherwise forwards the user's global skills path.
        // This lane has no shared skill-directory authority, even for discovery.
        options.skillExtraRootsProvider = { [] }
        options.requestTimeout = 12
        options.authTokensRefreshHandler = { request in
            guard let previous = request.previousAccountID else { throw CodexAccountAdoptionReason.identityChanged }
            let currentControl = await MainActor.run { binding.control }
            let grant = try await currentControl.refresh(previousAccountID: previous)
            return await MainActor.run {
                .init(
                    accessToken: grant.accessToken,
                    chatgptAccountID: grant.accountID,
                    chatgptPlanType: grant.plan,
                    managedAuthorization: currentControl.authorization
                )
            }
        }
        let controller = CodexNativeSessionController(
            client: client, runID: UUID(), tabID: UUID(), windowID: 1,
            workspacePaths: .uniform(fixture.workspace.path), options: options,
            clientShutdownBehavior: .stopOnShutdown, expectedMCPClientName: nil
        )
        let events = TurnEvents()
        let eventTask = Task {
            for await event in controller.events {
                if case let .turnCompleted(id?, status, _) = event { events.completed[id] = status }
            }
        }
        defer { eventTask.cancel() }
        var stage = "prepare-state"
        do {
            let runtime = try await client.prepareRuntimeForLaunch()
            let sentinel = Data("SYNTHETIC_IGNORED_AUTH_FILE".utf8)
            let authFile = runtime.statePaths.codexHome.appendingPathComponent("auth.json")
            try sentinel.write(to: authFile)
            try fixture.writeSafeConfiguration(to: runtime.statePaths.codexHome)
            stage = "start-native-thread"
            let reference = try await controller.startOrResume(existing: nil, baseInstructions: "Synthetic integration test. Respond briefly; do not use tools.", model: fixture.model, reasoningEffort: nil)
            stage = "initial-account-read"
            let initial = try await client.request(method: "account/read", params: ["refreshToken": false], timeout: 5)
            XCTAssertTrue(initial["account"] is NSNull)
            let scope = CodexAccountAdoptionScope(consentID: UUID(), sessionID: UUID(), controllerGeneration: UUID(), threadID: reference.conversationID)
            var observedSnapshot = try await controller.readThreadSnapshot(includeTurns: false, timeout: 3)
            let bridge = try SwitchboardBridgeClient(pairing: fixture.pairing(), scope: .init(
                consentID: scope.consentID, sessionID: scope.sessionID,
                controllerGeneration: scope.controllerGeneration, threadID: scope.threadID
            ))
            stage = "connect-private-bridge"
            try await control.connect(scope: scope, bridge: bridge, runtime: .init(
                admission: { .init(
                    scope: scope,
                    isExplicitRootCodexSession: true,
                    isManagedHTTPBackend: controller.usesManagedHTTPAccountAdoption,
                    isIdle: observedSnapshot.runtimeStatus == .idle && !observedSnapshot.hasActiveTurn,
                    hasPendingInteraction: false,
                    hasActiveTools: !observedSnapshot.activeToolItems.isEmpty,
                    hasActiveChildren: false,
                    hasQueuedDispatch: false,
                    hasRecoveryOrReconnect: false
                ) },
                inspect: { try await controller.inspectAccountAdoptionRuntime() },
                reserve: { try await controller.reserveAccountAdoption() },
                finish: { lease, allow in await controller.finishAccountAdoption(lease, allowTurns: allow) },
                install: { grant in try await controller.installAccountAdoptionGrant(grant, authorization: control.authorization) }
            ))
            XCTAssertEqual(try fixture.command("queue_a")["queued"] as? Int, 1)
            stage = "apply-a"
            await control.pollOnce()
            try requireApplied(control, revision: 1)
            if revokeAtPublication || revokeAfterPrefix {
                stage = "revoke-between-admission-and-write"
                do {
                    let forbiddenText = (revokeAfterPrefix ? String(repeating: "Synthetic context. ", count: 16384) : "") + fixture.marker
                    let forbidden = try await controller.startUserTurn(text: forbiddenText, images: [], model: fixture.model, reasoningEffort: nil, serviceTier: nil)
                    _ = try await waitForCompletion(controller, turnID: forbidden.provisionalSubmissionID, events: events)
                    XCTFail("Revoked consent crossed the native publication boundary")
                } catch {
                    if revokeAfterPrefix {
                        if case let CodexAppServerClient.ClientError.transportWriteFailed(_, errno) = error {
                            XCTAssertEqual(errno, ECANCELED)
                        } else { XCTFail("Partial-frame revoke did not report terminal write failure") }
                    } else {
                        XCTAssertEqual(error as? CodexAccountAdoptionReason, .revoked)
                    }
                }
                if !revokeAfterPrefix {
                    let refusedSnapshot = try await controller.readThreadSnapshot(includeTurns: false, timeout: 3)
                    XCTAssertEqual(refusedSnapshot.runtimeStatus, .idle)
                    XCTAssertFalse(refusedSnapshot.hasActiveTurn)
                    XCTAssertNil(refusedSnapshot.latestTerminalTurnID)
                    let unmaterialized = await client.permitsUnmaterializedManagedThreadProof()
                    XCTAssertTrue(unmaterialized)
                    let repairProof = try await controller.inspectAccountAdoptionRuntime()
                    XCTAssertTrue(repairProof.isAuthoritativelyIdle)
                    XCTAssertEqual(repairProof.threadID, reference.conversationID)
                } else {
                    try await assertProviderTurnBlocked(controller, fixture: fixture)
                }
                let refusedReceipt = try fixture.command("status")
                XCTAssertEqual((refusedReceipt["requests"] as? [[String: Any]])?.count, 0)
                XCTAssertEqual(controller.currentSessionReference?.conversationID, reference.conversationID)
                XCTAssertEqual(try Data(contentsOf: authFile), sentinel)
                await control.revokeAndWait()
                await controller.shutdown()
                let ended = await client.managedTransportHasFullyEnded()
                XCTAssertTrue(ended)
                let generation = await client.debugTransportGeneration()
                XCTAssertEqual(generation, 1)
                return
            }
            stage = "turn-a"
            let firstText = (largeContext ? String(repeating: "Synthetic context. ", count: 16384) : "") + fixture.marker
            let first = try await controller.startUserTurn(text: firstText, images: [], model: fixture.model, reasoningEffort: nil, serviceTier: nil)
            observedSnapshot = try await waitForCompletion(controller, turnID: first.provisionalSubmissionID, events: events)
            if refuseCapacity {
                stage = "capacity-waiting-turn"
                XCTAssertEqual(try fixture.command("hold_next_request")["armed"] as? Bool, true)
                let held = try await controller.startUserTurn(text: "Continue with the retained context.", images: [], model: fixture.model, reasoningEffort: nil, serviceTier: nil)
                try await waitForHeldRequest(fixture)
                observedSnapshot = try await controller.readThreadSnapshot(includeTurns: true, timeout: 3)
                guard observedSnapshot.hasActiveTurn else { throw CodexAccountAdoptionReason.runtimeUnavailable }
                XCTAssertEqual(try fixture.command("queue_b")["queued"] as? Int, 1)
                await control.pollOnce()
                XCTAssertEqual(control.state, .waitingIdle(.busy))
                XCTAssertEqual(try fixture.command("no_capacity")["armed"] as? Bool, true)
                XCTAssertEqual(try fixture.command("release_response")["released"] as? Bool, true)
                observedSnapshot = try await waitForCompletion(controller, turnID: held.provisionalSubmissionID, events: events)
                stage = "capacity-admission-refusal"
                await control.pollOnce()
                XCTAssertTrue(control.blocksDispatch)
                if case .failedUnknown = control.state {} else { XCTFail("Unavailable destination was not failed closed") }
                let unchanged = try await client.request(method: "account/read", params: ["refreshToken": false], timeout: 3)
                XCTAssertEqual((unchanged["account"] as? [String: Any])?["email"] as? String, "a@example.invalid")
                XCTAssertEqual(controller.currentSessionReference?.conversationID, reference.conversationID)
                try await assertProviderTurnBlocked(controller, fixture: fixture)
                let receipt = try fixture.command("status")
                XCTAssertEqual((receipt["requests"] as? [[String: Any]])?.compactMap { $0["account"] as? String }, ["a", "a"])
                XCTAssertEqual(receipt["protocol_errors"] as? Int, 0)
                XCTAssertEqual(receipt["redacted"] as? Bool, true)
                XCTAssertEqual(try Data(contentsOf: authFile), sentinel)
                await control.revokeAndWait()
                await controller.shutdown()
                let ended = await client.managedTransportHasFullyEnded()
                XCTAssertTrue(ended)
                return
            }
            if refreshWhileBusy {
                stage = "held-native-turn"
                XCTAssertEqual(try fixture.command("hold_next_request")["armed"] as? Bool, true)
                let held = try await controller.startUserTurn(text: "Keep the original marker in context.", images: [], model: fixture.model, reasoningEffort: nil, serviceTier: nil)
                try await waitForHeldRequest(fixture)
                observedSnapshot = try await controller.readThreadSnapshot(includeTurns: true, timeout: 3)
                XCTAssertTrue(observedSnapshot.hasActiveTurn)
                guard observedSnapshot.hasActiveTurn else { throw CodexAccountAdoptionReason.runtimeUnavailable }
                XCTAssertEqual(try fixture.command("queue_b")["queued"] as? Int, 1)
                await control.pollOnce()
                XCTAssertEqual(control.state, .waitingIdle(.busy))
                XCTAssertFalse(control.blocksDispatch)
                let beforeRefresh = try await client.request(method: "account/read", params: ["refreshToken": false], timeout: 3)
                XCTAssertEqual((beforeRefresh["account"] as? [String: Any])?["email"] as? String, "a@example.invalid")
                XCTAssertEqual(try fixture.command("renew_a")["renewed"] as? Bool, true)
                XCTAssertEqual(try fixture.command(persistentUnauthorized ? "reject_all_a" : "reject_next_a")["armed"] as? Bool, true)
                XCTAssertEqual(try fixture.command("release_response")["released"] as? Bool, true)
                stage = "native-401-refresh"
                if persistentUnauthorized {
                    observedSnapshot = try await waitForTerminal(controller, turnID: held.provisionalSubmissionID, events: events)
                    XCTAssertEqual(events.completed[held.provisionalSubmissionID], .failed)
                    XCTAssertEqual(observedSnapshot.latestTurnStatus, .failed)
                    XCTAssertEqual(observedSnapshot.conversationID, reference.conversationID)
                    // Repeated authorization failure cannot obtain another
                    // fresh A grant. Local authority closes without replacing
                    // the backend or falling through to queued B.
                    XCTAssertEqual(control.state, .failedUnknown(.bridgeUnavailable))
                    XCTAssertTrue(control.blocksDispatch)
                    let failedAccount = try await client.request(method: "account/read", params: ["refreshToken": false], timeout: 3)
                    XCTAssertEqual((failedAccount["account"] as? [String: Any])?["email"] as? String, "a@example.invalid")
                    let failedGeneration = await client.debugTransportGeneration()
                    XCTAssertEqual(failedGeneration, 1)
                    let failedReceipt = try fixture.command("status")
                    let failedRequests = try XCTUnwrap(failedReceipt["requests"] as? [[String: Any]])
                    let failedCalls = try XCTUnwrap(failedReceipt["provider_calls"] as? [[String: Any]])
                    let failedRenewals = failedCalls.filter { $0["refresh"] as? Bool == true }
                    XCTAssertGreaterThanOrEqual(failedRenewals.count, 2)
                    XCTAssertTrue(failedRenewals.allSatisfy {
                        $0["account"] as? String == "a" && $0["previous_account"] as? String == "fixture-a@example.invalid"
                    })
                    // Pinned 0.149 retries the renewed grant six times before
                    // terminal failure; none may fall through to pending B.
                    XCTAssertEqual(failedRequests.compactMap { $0["account"] as? String }, Array(repeating: "a", count: 8))
                    XCTAssertEqual(failedRequests.compactMap { $0["generation"] as? Int }, [1, 1] + Array(repeating: 2, count: 6))
                    XCTAssertEqual(failedRequests.compactMap { $0["status"] as? Int }, [200] + Array(repeating: 401, count: 7))
                    XCTAssertTrue(failedRequests.allSatisfy { $0["contains_marker"] as? Bool == true })
                    XCTAssertEqual(failedReceipt["protocol_errors"] as? Int, 0)
                    XCTAssertEqual(failedReceipt["logs_empty"] as? Bool, true)
                    XCTAssertEqual(failedReceipt["redacted"] as? Bool, true)
                    XCTAssertEqual(try Data(contentsOf: authFile), sentinel)
                    await control.revokeAndWait()
                    try await assertProviderTurnBlocked(controller, fixture: fixture)
                    XCTAssertEqual(try (fixture.command("status")["requests"] as? [[String: Any]])?.count, failedRequests.count)
                    await controller.shutdown()
                    let ended = await client.managedTransportHasFullyEnded()
                    XCTAssertTrue(ended)
                    return
                }
                observedSnapshot = try await waitForCompletion(controller, turnID: held.provisionalSubmissionID, events: events)
                XCTAssertEqual(control.state, .waitingIdle(.busy))
                let refreshed = try fixture.command("status")
                let calls = try XCTUnwrap(refreshed["provider_calls"] as? [[String: Any]])
                let renewal = try XCTUnwrap(calls.last { $0["refresh"] as? Bool == true })
                XCTAssertEqual(renewal["account"] as? String, "a")
                XCTAssertEqual(renewal["previous_account"] as? String, "fixture-a@example.invalid")
            } else {
                XCTAssertEqual(try fixture.command("queue_b")["queued"] as? Int, 1)
            }
            stage = "apply-b"
            await control.pollOnce()
            try requireApplied(control, revision: 2)
            stage = "turn-b"
            let second = try await controller.startUserTurn(text: "Recall the earlier marker.", images: [], model: fixture.model, reasoningEffort: nil, serviceTier: nil)
            observedSnapshot = try await waitForCompletion(controller, turnID: second.provisionalSubmissionID, events: events)
            XCTAssertEqual(controller.currentSessionReference?.conversationID, reference.conversationID)
            let proof = try await controller.inspectAccountAdoptionRuntime()
            XCTAssertEqual(proof.threadID, reference.conversationID)
            XCTAssertEqual(proof.loadedThreadIDs, [reference.conversationID])
            XCTAssertTrue(proof.isAuthoritativelyIdle)
            let receipt = try fixture.command("status")
            let requests = try XCTUnwrap(receipt["requests"] as? [[String: Any]])
            XCTAssertEqual(requests.compactMap { $0["account"] as? String }, refreshWhileBusy ? ["a", "a", "a", "b"] : ["a", "b"])
            XCTAssertEqual(requests.compactMap { $0["generation"] as? Int }, refreshWhileBusy ? [1, 1, 2, 1] : [1, 1])
            XCTAssertEqual(requests.compactMap { $0["status"] as? Int }, refreshWhileBusy ? [200, 401, 200, 200] : [200, 200])
            XCTAssertTrue(requests.allSatisfy { $0["contains_marker"] as? Bool == true })
            XCTAssertEqual(receipt["protocol_errors"] as? Int, 0)
            XCTAssertEqual(receipt["logs_empty"] as? Bool, true)
            XCTAssertEqual(receipt["redacted"] as? Bool, true)
            XCTAssertEqual(try Data(contentsOf: authFile), sentinel)
            let publicRows = try XCTUnwrap(receipt["status"] as? [[String: Any]])
            XCTAssertEqual(publicRows.first?["state"] as? String, "applied_unverified")
            XCTAssertEqual(publicRows.first?["runtime_verified"] as? Bool, false)
            if repairPairing {
                stage = "re-pair-same-controller"
                let reply = try fixture.command("pair_replacement")
                let object = try XCTUnwrap(reply["envelope"] as? [String: Any])
                let pairing = try SwitchboardPairingEnvelope.parse(JSONSerialization.data(withJSONObject: object))
                await control.revokeAndWait()
                let replacement = CodexSwitchboardSessionControl()
                binding.control = replacement
                let replacementScope = CodexAccountAdoptionScope(
                    consentID: UUID(), sessionID: scope.sessionID, controllerGeneration: scope.controllerGeneration, threadID: scope.threadID
                )
                let replacementBridge = SwitchboardBridgeClient(pairing: pairing, scope: .init(
                    consentID: replacementScope.consentID, sessionID: scope.sessionID,
                    controllerGeneration: scope.controllerGeneration, threadID: scope.threadID
                ))
                do {
                    try await replacement.connect(scope: replacementScope, bridge: replacementBridge, runtime: .init(
                        admission: { .init(
                            scope: replacementScope,
                            isExplicitRootCodexSession: true,
                            isManagedHTTPBackend: controller.usesManagedHTTPAccountAdoption,
                            isIdle: observedSnapshot.runtimeStatus == .idle && !observedSnapshot.hasActiveTurn,
                            hasPendingInteraction: false,
                            hasActiveTools: !observedSnapshot.activeToolItems.isEmpty,
                            hasActiveChildren: false,
                            hasQueuedDispatch: false,
                            hasRecoveryOrReconnect: false
                        ) },
                        inspect: { try await controller.inspectAccountAdoptionRuntime() },
                        reserve: { try await controller.reserveAccountAdoption() },
                        finish: { lease, allow in await controller.finishAccountAdoption(lease, allowTurns: allow) },
                        install: { grant in try await controller.installAccountAdoptionGrant(grant, authorization: replacement.authorization) }
                    ))
                    XCTAssertEqual(try fixture.command("queue_a")["queued"] as? Int, 1)
                    await replacement.pollOnce()
                    try requireApplied(replacement, revision: 1)
                    let resumed = try await controller.startUserTurn(text: "Continue the same retained conversation.", images: [], model: fixture.model, reasoningEffort: nil, serviceTier: nil)
                    observedSnapshot = try await waitForCompletion(controller, turnID: resumed.provisionalSubmissionID, events: events)
                    XCTAssertEqual(observedSnapshot.conversationID, reference.conversationID)
                    let transportGeneration = await client.debugTransportGeneration()
                    XCTAssertEqual(transportGeneration, 1)
                    let repairedReceipt = try fixture.command("status")
                    let repairedRequests = try XCTUnwrap(repairedReceipt["requests"] as? [[String: Any]])
                    XCTAssertEqual(repairedRequests.compactMap { $0["account"] as? String }, ["a", "b", "a"])
                    XCTAssertTrue(repairedRequests.allSatisfy { $0["contains_marker"] as? Bool == true })
                    XCTAssertEqual(repairedReceipt["redacted"] as? Bool, true)
                    XCTAssertEqual(try Data(contentsOf: authFile), sentinel)
                    await replacement.revokeAndWait()
                } catch {
                    await replacement.revokeAndWait()
                    throw error
                }
            }
            await control.revokeAndWait()
            try await assertProviderTurnBlocked(controller, fixture: fixture)
            XCTAssertEqual(try (fixture.command("status")["requests"] as? [[String: Any]])?.count, repairPairing ? 3 : (refreshWhileBusy ? 4 : 2))
            await controller.shutdown()
            let ended = await client.managedTransportHasFullyEnded()
            XCTAssertTrue(ended)
        } catch {
            let generation = await client.debugTransportGeneration()
            let termination = await client.debugLastTransportTerminationReason()
            if stage == "start-native-thread" { fixture.preservePreAuthFailureArtifacts() }
            XCTFail("Synthetic controller integration failed at \(stage); transport generation \(generation), termination \(String(describing: termination)), error \(safeErrorKind(error))")
            await control.revokeAndWait()
            await controller.shutdown()
            throw error
        }
    }

    private func assertProviderTurnBlocked(_ controller: CodexNativeSessionController, fixture: SwitchboardControllerRuntimeFixture) async throws {
        do {
            _ = try await controller.startUserTurn(text: "Must remain blocked", images: [], model: fixture.model, reasoningEffort: nil, serviceTier: nil)
            XCTFail("Closed account authority allowed a provider turn")
        } catch {}
    }

    @MainActor private final class ControlBinding {
        var control: CodexSwitchboardSessionControl
        init(_ control: CodexSwitchboardSessionControl) {
            self.control = control
        }
    }

    @MainActor private final class TurnEvents {
        var completed: [String: CodexNativeSessionController.TurnStatus] = [:]
    }

    private func safeErrorKind(_ error: Error) -> String {
        guard let failure = error as? CodexAppServerClient.ClientError else { return String(describing: type(of: error)) }
        switch failure {
        case let .requestFailed(request): return "requestFailed(method:\(request.method),code:\(String(describing: request.code)))"
        case let .processExited(evidence): return "processExited(\(evidence.status))"
        case .executableUnavailable: return "executableUnavailable"
        case .transportWriteFailed: return "transportWriteFailed"
        case .transportReadSetupFailed: return "transportReadSetupFailed"
        case .processNotRunning: return "processNotRunning"
        case .invalidResponse: return "invalidResponse"
        case .jsonDecodeFailed: return "jsonDecodeFailed"
        }
    }

    private func requireApplied(_ control: CodexSwitchboardSessionControl, revision: Int64) throws {
        XCTAssertEqual(control.state, .appliedUnverified(revision: revision))
        guard control.state == .appliedUnverified(revision: revision), !control.blocksDispatch else {
            throw CodexAccountAdoptionReason.mutationUnconfirmed
        }
    }

    private func waitForCompletion(_ controller: CodexNativeSessionController, turnID: String, events: TurnEvents) async throws -> CodexNativeSessionController.ThreadSnapshot {
        let snapshot = try await waitForTerminal(controller, turnID: turnID, events: events)
        XCTAssertEqual(events.completed[turnID], .completed)
        XCTAssertEqual(snapshot.latestTurnStatus, .completed)
        guard snapshot.latestTurnStatus == .completed else { throw CodexAccountAdoptionReason.runtimeUnavailable }
        return snapshot
    }

    private func waitForTerminal(_ controller: CodexNativeSessionController, turnID: String, events: TurnEvents) async throws -> CodexNativeSessionController.ThreadSnapshot {
        let deadline = Date().addingTimeInterval(18)
        while Date() < deadline {
            if events.completed[turnID] != nil {
                // A turn/start receipt precedes native rollout materialization.
                // Synchronize on real completion, then require full history;
                // never reinterpret a failed full read as empty/idle evidence.
                let snapshot = try await controller.readThreadSnapshot(includeTurns: true, timeout: 3)
                guard snapshot.latestTerminalTurnID == turnID, !snapshot.hasActiveTurn else { throw CodexAccountAdoptionReason.runtimeUnavailable }
                return snapshot
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        throw CodexAccountAdoptionReason.runtimeUnavailable
    }

    private func waitForHeldRequest(_ fixture: SwitchboardControllerRuntimeFixture) async throws {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if try fixture.command("status")["held"] as? Bool == true { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        throw CodexAccountAdoptionReason.runtimeUnavailable
    }
}
