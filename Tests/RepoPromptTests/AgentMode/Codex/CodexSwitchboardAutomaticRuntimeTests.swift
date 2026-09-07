@testable import RepoPromptApp
import XCTest

/// Genuine 0.149 controller/client + production protocol-2 engine and socket.
/// Canonical grants/quota and the strictly local Responses peer are synthetic.
@MainActor
final class CodexSwitchboardAutomaticRuntimeTests: XCTestCase {
    func testActualAutomaticGrantChangesOutgoingIdentityOnRetainedThread() async throws {
        try await exercise(busy: false)
    }

    func testActualBusyAutomaticIntentDoesNotBlockCurrentTurn() async throws {
        try await exercise(busy: true)
    }

    private func exercise(busy: Bool) async throws {
        let fixture = try SwitchboardControllerRuntimeFixture(mode: .automatic)
        defer { fixture.finish() }
        let client = try await CodexAppServerClient.makeForHostedIntegrationTest(fixture.configuration())
        let control = CodexSwitchboardSessionControl()
        var options = CodexNativeSessionController.Options.agentModeDefault(
            approvalPolicyProvider: { .never }, sandboxModeProvider: { .readOnly }, approvalReviewerProvider: { .user },
            shellToolEnabled: false, suppressThirdPartyMCPServers: true, goalSupportEnabledProvider: { false }, memoriesEnabledProvider: { false }
        )
        options.configOverridesProvider = {
            var overrides = CodexOverrides.appServerConfigMap(toolPolicy: .init(
                toolOutputTokenLimit: 1024,
                shellToolEnabled: false,
                webSearchRequestEnabled: false,
                multiAgentEnabled: false,
                modelReasoningSummary: CodexOverrides.ReasoningSummary.none
            ), featurePolicy: .defaultDisabled)
            let mcpOverrides = CodexOverrides.appServerMCPServerMap(
                entries: [.init(
                    rawName: "synthetic-third-party",
                    normalizedName: "synthetic-third-party",
                    cliPathComponent: "synthetic-third-party"
                )],
                policy: .disableAll(exceptBroken: [])
            )
            XCTAssertEqual(mcpOverrides["mcp_servers.synthetic-third-party.enabled"] as? Bool, false)
            overrides.merge(mcpOverrides) { _, fixtureValue in fixtureValue }
            return overrides
        }
        options.skillExtraRootsProvider = { [] }
        options.requestTimeout = 12
        options.authTokensRefreshHandler = { request in
            guard let previous = request.previousAccountID else { throw CodexAccountAdoptionReason.identityChanged }
            let grant = try await control.refresh(previousAccountID: previous)
            return await MainActor.run {
                .init(accessToken: grant.accessToken, chatgptAccountID: grant.accountID, chatgptPlanType: grant.plan, managedAuthorization: control.authorization)
            }
        }
        let controller = CodexNativeSessionController(
            client: client,
            runID: UUID(),
            tabID: UUID(),
            windowID: 1,
            workspacePaths: .uniform(fixture.workspace.path),
            options: options,
            clientShutdownBehavior: .stopOnShutdown,
            expectedMCPClientName: nil
        )
        let events = Events()
        let eventTask = Task {
            for await event in controller.events {
                if case let .turnCompleted(id?, status, _) = event { events.completed[id] = status }
            }
        }
        let watchdog = Task {
            do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
            await client.stop()
        }
        defer { eventTask.cancel()
            watchdog.cancel()
        }
        var stage = "prepare"
        do {
            let runtime = try await client.prepareRuntimeForLaunch()
            let sentinel = Data("SYNTHETIC_IGNORED_AUTH_FILE".utf8)
            let authFile = runtime.statePaths.codexHome.appendingPathComponent("auth.json")
            try sentinel.write(to: authFile)
            try fixture.writeSafeConfiguration(to: runtime.statePaths.codexHome)
            stage = "thread-start"
            let reference = try await controller.startOrResume(existing: nil, baseInstructions: "Synthetic local integration. Respond briefly without tools.", model: fixture.model, reasoningEffort: nil)
            let initial = try await client.request(method: "account/read", params: ["refreshToken": false], timeout: 3)
            XCTAssertTrue(initial["account"] is NSNull)
            var observed = try await controller.readThreadSnapshot(includeTurns: false, timeout: 3)
            let scope = CodexAccountAdoptionScope(consentID: UUID(), sessionID: UUID(), controllerGeneration: UUID(), threadID: reference.conversationID)
            let pairing = try fixture.pairing()
            let bridge = SwitchboardBridgeClient(pairing: pairing, scope: .init(consentID: scope.consentID, sessionID: scope.sessionID, controllerGeneration: scope.controllerGeneration, threadID: scope.threadID))
            var reservations = 0
            try await control.connect(scope: scope, bridge: bridge, runtime: .init(
                admission: {
                    .init(
                        scope: scope,
                        isExplicitRootCodexSession: true,
                        isManagedHTTPBackend: controller.usesManagedHTTPAccountAdoption,
                        isIdle: observed.runtimeStatus == .idle && !observed.hasActiveTurn,
                        hasPendingInteraction: false,
                        hasActiveTools: !observed.activeToolItems.isEmpty,
                        hasActiveChildren: false,
                        hasQueuedDispatch: false,
                        hasRecoveryOrReconnect: false
                    )
                },
                inspect: { try await controller.inspectAccountAdoptionRuntime() },
                reserve: {
                    reservations += 1
                    return try await controller.reserveAccountAdoption()
                },
                finish: { lease, allow in await controller.finishAccountAdoption(lease, allowTurns: allow) },
                install: { grant in try await controller.installAccountAdoptionGrant(grant, authorization: control.authorization) },
                automatic: .init(
                    peer: { try await controller.automaticNativePeer() },
                    hasEnded: { await controller.automaticNativeHasEnded() },
                    install: { grant, permit in try await controller.installAutomaticAccountGrant(grant, authorization: control.authorization, permit: permit) }
                )
            ))
            stage = "manual-bootstrap-a"
            XCTAssertEqual(try fixture.command("queue_a")["queued"] as? Int, 1)
            await control.pollOnce()
            try applied(control, revision: 1)
            let first = try await controller.startUserTurn(text: fixture.marker, images: [], model: fixture.model, reasoningEffort: nil, serviceTier: nil)
            observed = try await complete(controller, id: first.provisionalSubmissionID, events: events)

            stage = "explicit-automatic-offer"
            let channel = SwitchboardAutomaticClient(pairing: pairing, scope: scope)
            try await channel.hello()
            control.observeAutomaticOffers(client: channel, startPolling: false)
            let automatic = try XCTUnwrap(control.automatic)
            XCTAssertEqual(try fixture.command("offer")["offered"] as? Bool, true)
            await automatic.syncOnce()
            XCTAssertNil(automatic.enrollment)
            XCTAssertFalse(control.blocksDispatch)
            let offer = try XCTUnwrap(automatic.offer)
            try await automatic.accept(offerID: offer.id)

            var heldID: String?
            if busy {
                stage = "busy-native-turn"
                XCTAssertEqual(try fixture.command("hold_next_response")["armed"] as? Bool, true)
                let held = try await controller.startUserTurn(text: "Keep the original context.", images: [], model: fixture.model, reasoningEffort: nil, serviceTier: nil)
                heldID = held.provisionalSubmissionID
                try await waitUntil { try fixture.command("status")["held"] as? Bool == true }
                observed = try await controller.readThreadSnapshot(includeTurns: true, timeout: 3)
                XCTAssertTrue(observed.hasActiveTurn)
            }
            XCTAssertEqual(try fixture.command("plan")["planned"] as? Bool, true)
            if busy {
                let prior = reservations
                for _ in 0 ..< 4 {
                    await automatic.syncOnce()
                    try await waitUntil { !automatic.isWorkInFlight }
                }
                XCTAssertEqual(reservations, prior)
                XCTAssertFalse(control.blocksDispatch)
                try applied(control, revision: 1)
                XCTAssertEqual(try fixture.command("release_response")["released"] as? Bool, true)
                observed = try await complete(controller, id: XCTUnwrap(heldID), events: events)
            }
            stage = "automatic-native-b"
            let deadline = ContinuousClock.now.advanced(by: .seconds(12))
            while control.state != .appliedUnverified(revision: 2), ContinuousClock.now < deadline {
                await automatic.syncOnce()
                try await waitUntil { !automatic.isWorkInFlight }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            try applied(control, revision: 2)
            let second = try await controller.startUserTurn(text: "Recall the original marker.", images: [], model: fixture.model, reasoningEffort: nil, serviceTier: nil)
            observed = try await complete(controller, id: second.provisionalSubmissionID, events: events)
            XCTAssertEqual(observed.conversationID, reference.conversationID)
            let generation = await client.debugTransportGeneration()
            XCTAssertEqual(generation, 1)
            let result = try fixture.command("status")
            let requests = try XCTUnwrap(result["requests"] as? [[String: Any]])
            XCTAssertEqual(requests.compactMap { $0["account"] as? String }, busy ? ["a", "a", "b"] : ["a", "b"])
            XCTAssertTrue(requests.allSatisfy { $0["contains_marker"] as? Bool == true })
            XCTAssertEqual(result["protocol_errors"] as? Int, 0)
            XCTAssertEqual(result["logs_empty"] as? Bool, true)
            XCTAssertEqual(result["redacted"] as? Bool, true)
            let automaticStatus = try XCTUnwrap(result["automatic"] as? [String: Any])
            let targets = try XCTUnwrap(automaticStatus["targets"] as? [[String: Any]])
            XCTAssertEqual(targets.first?["applied_account"] as? String, "b@example.invalid")
            XCTAssertEqual(targets.first?["applied_revision"] as? Int, 2)
            XCTAssertEqual(try Data(contentsOf: authFile), sentinel)
            stage = "completed-pause"
            _ = try fixture.command("pause")
            await automatic.syncOnce()
            let paused = try XCTUnwrap(fixture.command("status")["automatic"] as? [String: Any])
            XCTAssertEqual(paused["effective_state"] as? String, "paused")
            XCTAssertFalse(control.blocksDispatch)
            await control.revokeAndWait()
            await controller.shutdown()
            let ended = await client.managedTransportHasFullyEnded()
            XCTAssertTrue(ended)
        } catch {
            print("Synthetic automatic integration failed at \(stage); error type \(String(describing: type(of: error)))")
            await control.revokeAndWait()
            await controller.shutdown()
            throw error
        }
    }

    private func applied(_ control: CodexSwitchboardSessionControl, revision: Int64) throws {
        XCTAssertEqual(control.state, .appliedUnverified(revision: revision))
        guard control.state == .appliedUnverified(revision: revision), !control.blocksDispatch else { throw CodexAccountAdoptionReason.mutationUnconfirmed }
    }

    private func waitUntil(_ predicate: () throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while try !predicate() {
            guard ContinuousClock.now < deadline else { throw CodexAccountAdoptionReason.runtimeUnavailable }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func complete(_ controller: CodexNativeSessionController, id: String, events: Events) async throws -> CodexNativeSessionController.ThreadSnapshot {
        let deadline = ContinuousClock.now.advanced(by: .seconds(18))
        while events.completed[id] == nil {
            guard ContinuousClock.now < deadline else { throw CodexAccountAdoptionReason.runtimeUnavailable }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(events.completed[id], .completed)
        let snapshot = try await controller.readThreadSnapshot(includeTurns: true, timeout: 3)
        guard snapshot.latestTerminalTurnID == id, !snapshot.hasActiveTurn, snapshot.latestTurnStatus == .completed else { throw CodexAccountAdoptionReason.runtimeUnavailable }
        return snapshot
    }

    private final class Events { var completed: [String: CodexNativeSessionController.TurnStatus] = [:] }
}
