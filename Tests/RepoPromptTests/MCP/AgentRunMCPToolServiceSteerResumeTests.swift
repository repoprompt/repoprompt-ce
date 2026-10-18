import Foundation
import MCP
import RepoPromptSettingsCore
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

@MainActor
final class AgentRunMCPToolServiceSteerResumeTests: XCTestCase {
    func testScopeDecisionWaitsForActiveTurnAndResumesWithoutConsumingDraft() async throws {
        let window = try await makeWindow()
        let viewModel = window.agentModeViewModel
        let sessionID = UUID()
        let session = try await makeWorkspaceOwnedSession(in: window, sessionID: sessionID)
        session.isMCPOriginated = false
        session.selectedAgent = .codexExec
        session.installRunID(UUID())
        session.runState = .running
        viewModel.storeDraftText(for: session.tabID, "Keep my draft")
        let runtime = DelegationScopeRuntime(persistenceMode: .ephemeral, windows: { [window] }, notifyCatalogChanged: { _ in })
        runtime.test_suppressDecisionDelivery = false
        let request = try runtime.requestScope(
            requesterSessionID: sessionID, requesterTabID: session.tabID,
            kind: .tree(rootSessionID: sessionID), capabilities: [.observe],
            guardrails: .init(), reason: nil, idempotencyKey: nil
        ).get()
        _ = try runtime.approve(requestID: request.id).get()
        XCTAssertTrue(session.items.isEmpty, "Approval must not interrupt the active turn")
        var deliveredText: String?
        let resumed = Task { @MainActor in
            let response = try await withCheckedThrowingContinuation { session.instructionContinuation = $0 }
            deliveredText = response.text
        }
        try await AsyncTestWait.waitUntil("decision instruction continuation") {
            await MainActor.run { session.instructionContinuation != nil }
        }
        session.instructionWaitID = UUID()
        session.runState = .waitingForUser
        try await AsyncTestWait.waitUntil("scope decision delivered") {
            await MainActor.run { deliveredText != nil }
        }
        try await resumed.value
        XCTAssertTrue(deliveredText?.contains("RepoPrompt delegation decision: granted") == true)
        XCTAssertEqual(viewModel.retrieveDraftText(for: session.tabID), "Keep my draft")
        XCTAssertNil(session.mcpControlContext)
    }

    func testUnrelatedSteerUsesExactLinkSurfaceInsteadOfChildControl() async throws {
        let window = try await makeWindow()
        let target = UUID(), caller = UUID()
        let session = try await makeWorkspaceOwnedSession(in: window, sessionID: target)
        var service = makeService(window: window, resolveCaller: { _, _ in caller })
        var forwarded: [String: Value]?
        service.forwardOversightSteer = { args, metadata in
            XCTAssertEqual(metadata.windowID, window.windowID)
            forwarded = args
            return .object(["result": .string("link_transaction")])
        }
        let result = try await service.execute(args: [
            "op": .string("steer"), "session_id": .string(target.uuidString), "message": .string("Continue")
        ])
        XCTAssertEqual(result.objectValue?["result"], .string("link_transaction"))
        XCTAssertEqual(forwarded?["session_id"], .string(target.uuidString))
        XCTAssertEqual(forwarded?["message"], .string("Continue"))
        XCTAssertNil(session.mcpControlContext, "The fallback must never capture the managed lane as an MCP child")
        XCTAssertTrue(session.items.isEmpty)
        var cancelled = makeService(window: window, resolveCaller: { _, _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return caller
        })
        var cancellationForwarded = false
        cancelled.forwardOversightSteer = { _, _ in
            cancellationForwarded = true
            return .null
        }
        let task = Task { @MainActor in
            try await cancelled.execute(args: [
                "op": .string("steer"), "session_id": .string(target.uuidString), "message": .string("Cancelled")
            ])
        }
        do {
            _ = try await task.value
            XCTFail("A cancelled child request must not reach the managed delivery surface")
        } catch is CancellationError {} catch {
            XCTFail("Expected cancellation, got \(error)")
        }
        XCTAssertFalse(cancellationForwarded)
    }

    func testManagedSteerRejectsEveryUnforwardableArgumentWithoutDelivery() async throws {
        let window = try await makeWindow()
        let target = UUID(), caller = UUID()
        let session = try await makeWorkspaceOwnedSession(in: window, sessionID: target)
        var service = makeService(window: window, resolveCaller: { _, _ in caller })
        var deliveries = 0
        service.forwardOversightSteer = { _, _ in
            deliveries += 1
            return .object(["result": .string("delivered")])
        }
        let rejected: [(String, Value)] = [
            ("workflow_name", .string("review")), ("wait", .string("true")),
            ("wait", .int(1)), ("unknown_option", .string("not forwarded")),
            ("workflow", .string("review")), ("workflow_id", .string(UUID().uuidString)),
            ("timeout_seconds", .int(1)), ("wait", .bool(true)), ("wait", .string("false"))
        ]
        for (key, value) in rejected {
            var args: [String: Value] = [
                "op": .string("steer"), "session_id": .string(target.uuidString), "message": .string("Continue")
            ]
            args[key] = value
            do {
                _ = try await service.execute(args: args)
                XCTFail("Unsupported argument \(key) was accepted")
            } catch {
                XCTAssertTrue(String(describing: error).contains("'\(key)'"), "\(error)")
                XCTAssertTrue(String(describing: error).contains("Nothing was delivered"), "\(error)")
            }
            XCTAssertEqual(deliveries, 0)
            XCTAssertTrue(session.items.isEmpty)
            XCTAssertNil(session.mcpControlContext)
        }
        _ = try await service.execute(args: [
            "op": .string("steer"), "session_id": .string(target.uuidString),
            "message": .string("Continue"), "idempotency_key": .string("approved-shape"), "wait": .bool(false)
        ])
        XCTAssertEqual(deliveries, 1, "Literal wait=false remains supported")
    }

    func testResidentInstructionSteerAndPollDoNotCaptureOrConsumeComposer() async throws {
        let window = try await makeWindow()
        let viewModel = window.agentModeViewModel
        let sessionID = UUID()
        let session = try await makeWorkspaceOwnedSession(in: window, sessionID: sessionID)
        session.isMCPOriginated = false
        session.hasLoadedPersistedState = true
        session.selectedAgent = .codexExec
        session.installRunID(UUID())
        session.runState = .waitingForUser
        session.instructionWaitID = UUID()
        viewModel.storeDraftText(for: session.tabID, "local draft")
        let resumed = Task { @MainActor in
            try await withCheckedThrowingContinuation { session.instructionContinuation = $0 }
        }
        try await AsyncTestWait.waitUntil("instruction continuation") {
            await MainActor.run { session.instructionContinuation != nil }
        }
        let createdLaneTab = await window.promptManager.createBackgroundComposeTab(strategy: .blank)
        let laneTab = try XCTUnwrap(createdLaneTab)
        let lane = try await makeWorkspaceOwnedSession(in: window, sessionID: UUID(), tabID: laneTab.id)
        let endpoint = try XCTUnwrap(viewModel.agentSessionLinkObserverEndpoint(tabID: session.tabID))
        let laneEndpoint = try XCTUnwrap(viewModel.agentSessionLinkObserverEndpoint(tabID: lane.tabID))
        let bridge = AgentSessionLinkRuntimeBridge.shared
        guard case .added = await bridge.addMonitorLink(observerEndpoint: endpoint, targetEndpoint: laneEndpoint) else {
            return XCTFail("real oversight grant was not admitted")
        }
        await bridge.test_settleProjections()
        let route = try AgentSessionLinkRunCatalogRouteToken(
            runID: XCTUnwrap(session.runID), observerEndpoint: endpoint, connectionID: UUID(),
            routingAuthorityGeneration: 1, connectionLifecycleGeneration: 1
        )
        viewModel.test_agentSessionLinkAuthoritativeRunCatalogRouteToken = { runID, windowID, tabID in
            runID == route.runID && windowID == endpoint.windowID && tabID == endpoint.tabID ? route : nil
        }
        let service = makeService(window: window)
        let message = "</client_task> & \"not approval\""
        let value = try await service.execute(args: [
            "op": .string("steer"), "session_id": .string(sessionID.uuidString),
            "message": .string(message), "wait": .bool(false), "timeout_seconds": .int(0)
        ])
        let response = try await resumed.value
        let frame = AgentModeViewModel.mcpResidentTaskFrame(message)
        XCTAssertTrue(response.text?.contains(frame) == true)
        XCTAssertEqual(session.items.last { $0.kind == .user }?.text, frame)
        XCTAssertNil(session.items.last { $0.kind == .user }?.crossSessionAttribution)
        XCTAssertEqual(viewModel.retrieveDraftText(for: session.tabID), "local draft")
        XCTAssertNil(session.mcpControlContext)
        XCTAssertFalse(session.isMCPOriginated)
        XCTAssertNil(value.objectValue?["overseer"], "rich state is poll-only")
        session.appendItem(AgentChatItem.assistant("visible fake-provider reply", sequenceIndex: session.nextSequenceIndex))
        let logs = makeManageService(window: window)
        let log = try await logs.execute(args: ["op": .string("get_log"), "session_id": .string(sessionID.uuidString)])
        XCTAssertTrue(log.objectValue?["transcript_xml"]?.stringValue?.contains("visible fake-provider reply") == true)
        let polled = try await service.execute(args: ["op": .string("poll"), "session_id": .string(sessionID.uuidString)])
        XCTAssertEqual(polled.objectValue?["overseer"]?.objectValue?["lane_count"], .int(1))
        await bridge.test_auditObserverEligibility()
        let survivingGrant = await bridge.hasActiveOutboundLink(observerEndpoint: endpoint)
        XCTAssertTrue(survivingGrant, "the real eligibility audit must not revoke the grant after MCP access")
        XCTAssertEqual(polled.objectValue?["overseer"]?.objectValue?["context"], .null)
        XCTAssertNil(session.mcpControlContext)
        let registered = await AgentRunSessionStore.hasActiveRegistration(sessionID: sessionID)
        XCTAssertFalse(registered)
    }

    func testResidentMessageAndWaitRefusesBeforeSubmission() async throws {
        let window = try await makeWindow()
        let sessionID = UUID()
        let session = try await makeWorkspaceOwnedSession(in: window, sessionID: sessionID)
        let service = makeService(window: window)
        let count = session.items.count
        let cases: [[String: Value]] = [
            ["op": .string("steer"), "session_id": .string(sessionID.uuidString), "message": .string("task"), "wait": .bool(true)],
            ["op": .string("steer"), "session_id": .string(sessionID.uuidString), "message": .string("task"), "timeout_seconds": .int(0)]
        ]
        for args in cases {
            do {
                _ = try await service.execute(args: args)
                XCTFail("resident message-and-wait must refuse")
            } catch {
                XCTAssertTrue(String(describing: error).contains(AgentModeViewModel.mcpResidentWaitError))
            }
        }
        XCTAssertEqual(session.items.count, count)
        XCTAssertNil(session.mcpControlContext)
        let zero = try await service.execute(args: ["op": .string("poll"), "session_id": .string(sessionID.uuidString)])
        XCTAssertEqual(zero.objectValue?["overseer"]?.objectValue?["lane_count"], .int(0))
        let many = try await service.execute(args: ["op": .string("poll"), "session_ids": .array([.string(sessionID.uuidString)])])
        XCTAssertEqual(many.objectValue?["snapshots"]?.arrayValue?.first?.objectValue?["overseer"]?.objectValue?["lane_count"], .int(0))
    }

    /// Pre-PR base 6d23fbcd: no control registration means the legacy terminal expired
    /// snapshot, returned successfully before any timeout wait is enrolled.
    func testResidentStandaloneWaitPreservesLegacyResult() async throws {
        let window = try await makeWindow()
        let sessionID = UUID()
        let session = try await makeWorkspaceOwnedSession(in: window, sessionID: sessionID)
        let service = makeService(window: window)
        let expected = legacyExpiredValue(sessionID: sessionID)
        let itemCount = session.items.count
        for timeout: Value? in [nil, .int(0), .int(30)] {
            for target in [
                "session_id": Value.string(sessionID.uuidString),
                "session_ids": .array([.string(sessionID.uuidString)])
            ] {
                var args: [String: Value] = ["op": .string("wait"), target.key: target.value]
                args["timeout"] = timeout
                let result = try await service.execute(args: args)
                XCTAssertEqual(withoutSnapshotTimestamps(result), expected)
            }
        }
        let createdTab = await window.promptManager.createBackgroundComposeTab(strategy: .blank)
        let laneTab = try XCTUnwrap(createdTab)
        let secondID = UUID()
        _ = try await makeWorkspaceOwnedSession(in: window, sessionID: secondID, tabID: laneTab.id)
        let many = try await service.execute(args: [
            "op": .string("wait"), "session_ids": .array([.string(sessionID.uuidString), .string(secondID.uuidString)]),
            "timeout": .int(0)
        ])
        var expectedMany = try XCTUnwrap(expected.objectValue)
        expectedMany["_meta"] = .object(["wait_result": .string("expired")])
        expectedMany["wait"] = .object([
            "mode": .string("any"), "result": .string("expired"), "winner_session_id": .null,
            "session_ids": .array([.string(sessionID.uuidString), .string(secondID.uuidString)]),
            "waited_count": .int(2), "pending_session_ids": .array([]), "instruction": .null
        ])
        XCTAssertEqual(withoutSnapshotTimestamps(many), .object(expectedMany))
        XCTAssertEqual(session.items.count, itemCount)
        XCTAssertNil(session.mcpControlContext)
        XCTAssertFalse(session.isMCPOriginated)
    }

    func testColdResidentPollPreservesLegacySuccessShape() async throws {
        let window = try await makeWindow()
        let sessionID = UUID()
        let session = try await makeWorkspaceOwnedSession(in: window, sessionID: sessionID, restored: false)
        XCTAssertFalse(session.permitsBoundOperationAndSave, "A cold binding must remain unproven")
        let service = makeService(window: window)
        let expected = legacyExpiredValue(sessionID: sessionID)
        let single = try await service.execute(args: ["op": .string("poll"), "session_id": .string(sessionID.uuidString)])
        XCTAssertEqual(withoutSnapshotTimestamps(single), expected)
        let many = try await service.execute(args: ["op": .string("poll"), "session_ids": .array([.string(sessionID.uuidString)])])
        XCTAssertEqual(withoutSnapshotTimestamps(many), .object([
            "poll": .object([
                "mode": .string("many"), "session_ids": .array([.string(sessionID.uuidString)]),
                "polled_count": .int(1), "interesting_session_ids": .array([.string(sessionID.uuidString)]),
                "running_session_ids": .array([]), "terminal_session_ids": .array([.string(sessionID.uuidString)])
            ]), "snapshots": .array([expected])
        ]))
        XCTAssertFalse(session.hasLoadedPersistedState)
        XCTAssertNil(session.mcpControlContext)
        XCTAssertFalse(session.isMCPOriginated)
    }

    func testReconstructedSteerAcceptsBeforeLaterBookkeepingFailure() async throws {
        let window = try await makeWindow()

        let viewModel = window.agentModeViewModel
        let sessionID = UUID()
        let persistedTabID = UUID()
        let workspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        let persistedItems = [
            AgentChatItem.user("saved request", sequenceIndex: 0),
            AgentChatItem.assistant("saved response", sequenceIndex: 1)
        ]
        // Reconstruction must restore a real payload; an index row cannot establish authority.
        _ = try await AgentSessionDataService.shared.saveAgentSession(
            AgentSession(
                id: sessionID,
                workspaceID: workspace.id,
                composeTabID: persistedTabID,
                name: "Persisted reconstructed steer",
                items: persistedItems.map { AgentChatItemPersist(from: $0) },
                itemCount: persistedItems.count,
                agentKind: AgentProviderKind.codexExec.rawValue,
                agentModel: "test-model",
                lastRunState: AgentSessionRunState.completed.rawValue,
                autoEditEnabled: false,
                isMCPOriginated: true
            ),
            for: workspace
        )
        viewModel.upsertSessionIndex(
            sessionID: sessionID,
            tabID: persistedTabID,
            name: "Persisted reconstructed steer",
            lastUserMessageAt: nil,
            savedAt: Date(timeIntervalSince1970: 1_800_000_000),
            lastRunStateRaw: AgentSessionRunState.completed.rawValue,
            itemCount: 2,
            agentKindRaw: "codex",
            agentModelRaw: "test-model",
            agentReasoningEffortRaw: nil,
            autoEditEnabled: false
        )
        var providerDispatchCount = 0
        var reconstructedTarget: AgentModeViewModel.MCPSessionTarget?
        var service = makeService(window: window)
        service.testDispatchSteerInstruction = { dispatchedSessionID, _, _, agentModeVM in
            providerDispatchCount += 1
            let session = try XCTUnwrap(agentModeVM.mcpControlledSession(sessionID: dispatchedSessionID))
            XCTAssertTrue(session.qualifiedRestorationReadiness.isAuthoritative)
            XCTAssertTrue(session.items.contains { $0.kind == .assistant && $0.text == "saved response" })
            session.runState = .running
            agentModeVM.publishMCPStateChange(for: session)
            return .startedRun
        }
        service.testAfterSteerDispatchBeforeBookkeeping = { target in
            reconstructedTarget = target
            throw MCPError.internalError("synthetic post-dispatch bookkeeping failure")
        }

        do {
            _ = try await service.execute(args: [
                "op": .string("steer"),
                "session_id": .string(sessionID.uuidString),
                "message": .string("dispatch exactly once before bookkeeping fails")
            ])
            XCTFail("Expected synthetic post-dispatch bookkeeping failure")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains("synthetic post-dispatch bookkeeping failure"),
                String(describing: error)
            )
        }

        let target = try XCTUnwrap(reconstructedTarget)
        XCTAssertEqual(target.origin, .createdForSessionResume)
        XCTAssertEqual(try XCTUnwrap(target.recoveryClaim).state, .accepted)
        XCTAssertEqual(providerDispatchCount, 1)
        let discardResult = await viewModel.mcpDiscardSessionTarget(target)
        XCTAssertEqual(discardResult, .complete)
        XCTAssertNotNil(viewModel.session(for: target.tabID, createIfNeeded: false))
        XCTAssertNotNil(window.workspaceManager.composeTab(with: target.tabID))
        XCTAssertEqual(providerDispatchCount, 1)
    }

    func testMCPOriginSteerReactivationDispatchFailureCleansControlContext() async throws {
        let window = try await makeWindow()

        let viewModel = window.agentModeViewModel
        let sessionID = UUID()
        let session = try await makeWorkspaceOwnedSession(in: window, sessionID: sessionID)
        session.isMCPOriginated = true
        session.runState = .completed

        var service = makeService(window: window)
        service.testDispatchSteerInstruction = { _, _, _, agentModeVM in
            let controlledSession = try XCTUnwrap(agentModeVM.mcpControlledSession(sessionID: sessionID))
            XCTAssertIdentical(controlledSession, session)
            XCTAssertTrue(controlledSession.mcpFollowUpRunPending)
            throw MCPError.internalError("synthetic steer dispatch failure")
        }

        do {
            _ = try await service.execute(args: [
                "op": .string("steer"),
                "session_id": .string(sessionID.uuidString),
                "message": .string("this dispatch fails")
            ])
            XCTFail("Expected steer dispatch failure")
        } catch {
            XCTAssertTrue(String(describing: error).contains("synthetic steer dispatch failure"), String(describing: error))
        }

        XCTAssertNil(session.mcpControlContext)
        XCTAssertFalse(session.mcpFollowUpRunPending)
        XCTAssertTrue(session.isMCPOriginated)
        let hasActiveRegistration = await AgentRunSessionStore.hasActiveRegistration(sessionID: sessionID)
        XCTAssertFalse(hasActiveRegistration)
    }

    func testMCPOriginSteerReactivationDispatchFailurePreservesReplacementControlContextButClearsPendingMask() async throws {
        let window = try await makeWindow()

        let viewModel = window.agentModeViewModel
        let sessionID = UUID()
        let session = try await makeWorkspaceOwnedSession(in: window, sessionID: sessionID)
        session.isMCPOriginated = true
        session.runState = .completed

        var replacementActivationID: UUID?
        var replacementRegistration: AgentRunSessionStore.Registration?
        var service = makeService(window: window)
        service.testDispatchSteerInstruction = { _, _, _, agentModeVM in
            let controlledSession = try XCTUnwrap(agentModeVM.mcpControlledSession(sessionID: sessionID))
            XCTAssertIdentical(controlledSession, session)
            let originalContext = try XCTUnwrap(controlledSession.mcpControlContext)
            XCTAssertTrue(controlledSession.mcpFollowUpRunPending)

            try await agentModeVM.mcpActivateControlContext(
                forTabID: controlledSession.tabID,
                sessionID: sessionID,
                originatingConnectionID: UUID(),
                startPending: true,
                markSessionAsMCPOriginated: false,
                requireInactiveRunState: true
            )
            let replacementContext = try XCTUnwrap(controlledSession.mcpControlContext)
            XCTAssertNotEqual(replacementContext.activationID, originalContext.activationID)
            replacementActivationID = replacementContext.activationID
            replacementRegistration = replacementContext.registration
            throw MCPError.internalError("synthetic steer dispatch failure after replacement")
        }

        do {
            _ = try await service.execute(args: [
                "op": .string("steer"),
                "session_id": .string(sessionID.uuidString),
                "message": .string("this dispatch fails after replacement")
            ])
            XCTFail("Expected steer dispatch failure")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains("synthetic steer dispatch failure after replacement"),
                String(describing: error)
            )
        }

        let activationID = try XCTUnwrap(replacementActivationID)
        let registration = try XCTUnwrap(replacementRegistration)
        let context = try XCTUnwrap(session.mcpControlContext)
        XCTAssertEqual(context.activationID, activationID)
        XCTAssertEqual(context.registration, registration)
        XCTAssertFalse(session.mcpFollowUpRunPending)
        XCTAssertTrue(session.isMCPOriginated)
        let currentRegistration = await AgentRunSessionStore.currentRegistration(for: sessionID)
        XCTAssertEqual(currentRegistration, registration)

        await viewModel.mcpDeactivateControlContext(sessionID: sessionID, cleanupSessionStore: true)
    }

    func testSteerUnknownSessionIDStillFailsWithoutCreatingRegistration() async throws {
        let window = try await makeWindow()

        let viewModel = window.agentModeViewModel
        let unknownSessionID = UUID()
        var service = makeService(window: window)
        service.testDispatchSteerInstruction = { _, _, _, _ in
            XCTFail("Unknown sessions must not reach dispatch")
            return .startedRun
        }

        do {
            _ = try await service.execute(args: [
                "op": .string("steer"),
                "session_id": .string(unknownSessionID.uuidString),
                "message": .string("unknown session")
            ])
            XCTFail("Expected unknown session failure")
        } catch {
            XCTAssertTrue(String(describing: error).contains("was not found"), String(describing: error))
        }

        XCTAssertNil(viewModel.mcpControlledSession(sessionID: unknownSessionID))
        let hasActiveRegistration = await AgentRunSessionStore.hasActiveRegistration(sessionID: unknownSessionID)
        XCTAssertFalse(hasActiveRegistration)
    }

    func testMCPOriginReconstructedSteerRejectsWorkspaceDriftWhenSessionBecomesActiveDuringControlActivation() async throws {
        let window = try await makeWindow()

        let viewModel = window.agentModeViewModel
        let sessionID = UUID()
        let session = try await makeWorkspaceOwnedSession(in: window, sessionID: sessionID)
        session.isMCPOriginated = true
        session.runState = .completed
        let driftWorkspace = window.workspaceManager.createWorkspace(
            name: "Steer Activation Drift \(UUID().uuidString.prefix(8))",
            repoPaths: [],
            ephemeral: true
        )
        var switchSucceeded = false
        viewModel.test_afterMCPControlActivation = { activatedSession in
            XCTAssertIdentical(activatedSession, session)
            activatedSession.runState = .running
            window.workspaceManager.activeWorkspace = driftWorkspace
            switchSucceeded = window.workspaceManager.activeWorkspace?.id == driftWorkspace.id
        }
        defer { viewModel.test_afterMCPControlActivation = nil }
        var dispatchCount = 0
        var service = makeService(window: window)
        service.testDispatchSteerInstruction = { _, _, _, _ in
            dispatchCount += 1
            return .queuedClaudeInterrupt
        }

        do {
            _ = try await service.execute(args: [
                "op": .string("steer"),
                "session_id": .string(sessionID.uuidString),
                "message": .string("must reject before the active dispatch branch")
            ])
            XCTFail("Expected workspace drift after reconstructed control activation to reject")
        } catch {
            guard let mcpError = error as? MCPError,
                  case let .invalidParams(message) = mcpError
            else {
                return XCTFail("Expected typed invalidParams workspace rejection, got: \(error)")
            }
            XCTAssertTrue(message?.contains("active workspace") == true, message ?? "missing message")
        }

        XCTAssertTrue(switchSucceeded)
        XCTAssertEqual(dispatchCount, 0)
        XCTAssertNil(session.mcpControlContext)
        let hasActiveRegistration = await AgentRunSessionStore.hasActiveRegistration(sessionID: sessionID)
        XCTAssertFalse(hasActiveRegistration)
    }

    func testResidentSteerCancelledDuringCallerResolutionDoesNotAcceptInput() async throws {
        let window = try await makeWindow()
        let viewModel = window.agentModeViewModel
        let sessionID = UUID()
        let session = try await makeWorkspaceOwnedSession(in: window, sessionID: sessionID)
        session.selectedAgent = .claudeCode
        session.runState = .running
        session.installRunID(UUID())
        // Keep accepted steering queued so a provider flush cannot hide an erroneous admission.
        session.isMCPInstructionDispatchInProgress = true
        viewModel.storeDraftText(for: session.tabID, "local draft")
        viewModel.interviewFirst = true
        let transcript = session.transcript
        let items = session.items
        let audit = session.automationTurnAudit
        let composerToken = session.composerSubmissionToken
        let controlGeneration = session.mcpControlActivationGeneration
        let callerResolution = ResidentSteerGate()
        let service = makeService(window: window, resolveCaller: { _, _ in
            await callerResolution.wait()
            return nil
        })
        let task = Task { @MainActor in
            try await service.execute(args: [
                "op": .string("steer"), "session_id": .string(sessionID.uuidString),
                "message": .string("cancelled client task"), "wait": .bool(false)
            ])
        }
        defer {
            task.cancel()
            callerResolution.release()
        }
        try await AsyncTestWait.waitUntil("caller resolution parked") {
            await MainActor.run { callerResolution.isWaiting }
        }
        task.cancel()
        callerResolution.release()
        do {
            _ = try await task.value
            XCTFail("Cancellation before resident admission must throw")
        } catch {
            XCTAssertTrue(error is CancellationError, "Expected ordinary cancellation, got: \(error)")
        }
        XCTAssertEqual(session.items, items)
        XCTAssertEqual(session.transcript, transcript)
        XCTAssertEqual(session.automationTurnAudit, audit)
        XCTAssertTrue(session.pendingClaudeSteeringInstructions.isEmpty, "No Claude interrupt may be queued")
        XCTAssertTrue(session.pendingACPSteeringInstructions.isEmpty)
        XCTAssertTrue(session.pendingInstructions.isEmpty)
        XCTAssertNil(session.claudeSteeringFlushTask)
        XCTAssertTrue(session.claudeSupersedingProtectedTurnIDs.isEmpty)
        XCTAssertEqual(session.composerSubmissionToken, composerToken)
        XCTAssertFalse(session.isComposerSubmissionInFlight)
        XCTAssertEqual(viewModel.retrieveDraftText(for: session.tabID), "local draft")
        XCTAssertTrue(viewModel.interviewFirst)
        XCTAssertEqual(session.mcpControlActivationGeneration, controlGeneration)
        XCTAssertNil(session.mcpControlContext)
        XCTAssertFalse(session.isMCPOriginated)
        let registered = await AgentRunSessionStore.hasActiveRegistration(sessionID: sessionID)
        XCTAssertFalse(registered)
    }

    func testResidentSteerCancellationAfterAcceptanceRetainsQueuedInput() async throws {
        let window = try await makeWindow()
        let sessionID = UUID()
        let session = try await makeWorkspaceOwnedSession(in: window, sessionID: sessionID)
        session.selectedAgent = .claudeCode
        session.runState = .running
        session.isMCPInstructionDispatchInProgress = true
        let service = makeService(window: window)
        var acceptedValue: Value?
        let callerCompletion = ResidentSteerGate()
        let task = Task { @MainActor in
            acceptedValue = try await service.execute(args: [
                "op": .string("steer"), "session_id": .string(sessionID.uuidString),
                "message": .string("accepted client task"), "wait": .bool(false)
            ])
            await callerCompletion.wait()
            try Task.checkCancellation()
        }
        defer {
            task.cancel()
            callerCompletion.release()
        }
        try await AsyncTestWait.waitUntil("resident steer accepted") {
            await MainActor.run { callerCompletion.isWaiting }
        }
        let acceptedItems = session.items
        let acceptedTranscript = session.transcript
        let acceptedAudit = session.automationTurnAudit
        let acceptedQueue = session.pendingClaudeSteeringInstructions
        XCTAssertEqual(acceptedValue?.objectValue?["_meta"]?.objectValue?["delivery"], .string("queued_claude_interrupt"))
        XCTAssertEqual(acceptedQueue.count, 1)
        XCTAssertEqual(session.items.last { $0.kind == .user }?.text, AgentModeViewModel.mcpResidentTaskFrame("accepted client task"))
        task.cancel()
        callerCompletion.release()
        do {
            try await task.value
            XCTFail("Caller completion must observe cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(session.items, acceptedItems)
        XCTAssertEqual(session.transcript, acceptedTranscript)
        XCTAssertEqual(session.automationTurnAudit, acceptedAudit)
        XCTAssertEqual(session.pendingClaudeSteeringInstructions, acceptedQueue)
        XCTAssertNil(session.mcpControlContext)
        XCTAssertFalse(session.isMCPOriginated)
    }

    func testResidentActiveClaudeSessionQueuesWithoutCapture() async throws {
        let window = try await makeWindow()
        let sessionID = UUID()
        let session = try await makeWorkspaceOwnedSession(in: window, sessionID: sessionID)
        session.selectedAgent = .claudeCode
        session.runState = .running
        session.isMCPInstructionDispatchInProgress = true
        let callerResolution = ResidentSteerGate()
        let service = makeService(window: window, resolveCaller: { _, _ in
            await callerResolution.wait()
            return nil
        })
        let task = Task { @MainActor in
            try await service.execute(args: [
                "op": .string("steer"), "session_id": .string(sessionID.uuidString),
                "message": .string("active client task"), "wait": .bool(false)
            ])
        }
        defer {
            task.cancel()
            callerResolution.release()
        }
        try await AsyncTestWait.waitUntil("uncancelled caller resolution parked") {
            await MainActor.run { callerResolution.isWaiting }
        }
        callerResolution.release()
        let value = try await task.value
        XCTAssertEqual(session.pendingClaudeSteeringInstructions.count, 1)
        XCTAssertEqual(value.objectValue?["_meta"]?.objectValue?["delivery"], .string("queued_claude_interrupt"))
        XCTAssertEqual(session.items.last { $0.kind == .user }?.text, AgentModeViewModel.mcpResidentTaskFrame("active client task"))
        XCTAssertNil(session.mcpControlContext)
        XCTAssertFalse(session.isMCPOriginated)
    }

    func testLinkedResidentResumeAndExistingTabStartRefuseBeforeActivation() async throws {
        let window = try await makeWindow()
        let sessionID = UUID()
        let session = try await makeWorkspaceOwnedSession(in: window, sessionID: sessionID)
        let viewModel = window.agentModeViewModel
        viewModel.test_agentSessionLinkHasActiveOutboundLink = { _ in true }
        let before = session.mcpControlActivationGeneration
        let run = makeService(window: window, requestedTabID: session.tabID)
        let manage = makeManageService(window: window)
        for operation in ["start", "resume_session"] {
            do {
                if operation == "start" {
                    _ = try await run.execute(args: ["op": .string(operation), "message": .string("task")])
                } else {
                    _ = try await manage.execute(args: ["op": .string(operation), "session_id": .string(sessionID.uuidString)])
                }
                XCTFail("activation must refuse")
            } catch {
                XCTAssertTrue(String(describing: error).contains("Session \(sessionID.uuidString) is app-owned and oversees other sessions."))
            }
        }
        XCTAssertEqual(session.mcpControlActivationGeneration, before)
        XCTAssertNil(session.mcpControlContext)
        XCTAssertFalse(session.isMCPOriginated)
    }

    func testLateRealGrantRefusesInstallationAndSurvivesEligibilityAudit() async throws {
        let window = try await makeWindow()
        let viewModel = window.agentModeViewModel
        let sessionID = UUID()
        let session = try await makeWorkspaceOwnedSession(in: window, sessionID: sessionID)
        let createdLaneTab = await window.promptManager.createBackgroundComposeTab(strategy: .blank)
        let laneTab = try XCTUnwrap(createdLaneTab)
        let lane = try await makeWorkspaceOwnedSession(in: window, sessionID: UUID(), tabID: laneTab.id)
        let endpoint = try XCTUnwrap(viewModel.agentSessionLinkObserverEndpoint(tabID: session.tabID))
        let laneEndpoint = try XCTUnwrap(viewModel.agentSessionLinkObserverEndpoint(tabID: lane.tabID))
        let bridge = AgentSessionLinkRuntimeBridge.shared
        viewModel.test_afterMCPControlRegistration = { _ in
            guard case .added = await bridge.addMonitorLink(observerEndpoint: endpoint, targetEndpoint: laneEndpoint) else {
                return XCTFail("late real grant was not admitted")
            }
        }
        do {
            _ = try await viewModel.mcpActivateControlContext(forTabID: session.tabID, sessionID: sessionID, originatingConnectionID: UUID())
            XCTFail("late membership must refuse installation")
        } catch {
            XCTAssertTrue(String(describing: error).contains("MCP activation would revoke its oversight links."))
        }
        XCTAssertNil(session.mcpControlContext)
        XCTAssertFalse(session.isMCPOriginated)
        let registered = await AgentRunSessionStore.hasActiveRegistration(sessionID: sessionID)
        XCTAssertFalse(registered)
        await bridge.test_auditObserverEligibility()
        let survivingGrant = await bridge.hasActiveOutboundLink(observerEndpoint: endpoint)
        XCTAssertTrue(survivingGrant)
    }

    func testActivationIdentityAndMembershipHoldRefuseButStableZeroLinkAdopts() async throws {
        let window = try await makeWindow()
        let viewModel = window.agentModeViewModel
        let sessionID = UUID()
        let session = try await makeWorkspaceOwnedSession(in: window, sessionID: sessionID)
        let endpoint = try XCTUnwrap(viewModel.agentSessionLinkObserverEndpoint(tabID: session.tabID))
        let hold = viewModel.agentSessionLinkWithholdPromptInventory(for: endpoint)
        do {
            _ = try await viewModel.mcpActivateControlContext(forTabID: session.tabID, sessionID: sessionID, originatingConnectionID: nil)
            XCTFail("membership hold must refuse")
        } catch { XCTAssertTrue(String(describing: error).contains(AgentModeViewModel.mcpResidentTargetError)) }
        viewModel.agentSessionLinkReleasePromptInventoryHold(hold, for: endpoint, publishing: nil)
        var transitionGeneration: UInt64 = 0
        viewModel.test_agentSessionLinkHasActiveOutboundLink = { _ in
            transitionGeneration = session.beginPersistentBindingTransition()
            return false
        }
        do {
            _ = try await viewModel.mcpActivateControlContext(forTabID: session.tabID, sessionID: sessionID, originatingConnectionID: nil)
            XCTFail("post-await target drift must refuse")
        } catch let error as MCPError {
            XCTAssertEqual(
                String(describing: error),
                String(describing: MCPError.invalidParams("Wait for this session to finish loading."))
            )
        }
        session.finishPersistentBindingTransition(generation: transitionGeneration)
        establishRestoredFixture(session)
        viewModel.test_agentSessionLinkHasActiveOutboundLink = { _ in false }
        _ = try await viewModel.mcpActivateControlContext(forTabID: session.tabID, sessionID: sessionID, originatingConnectionID: nil)
        XCTAssertNotNil(session.mcpControlContext)
        await viewModel.mcpDeactivateControlContext(sessionID: sessionID, cleanupSessionStore: true)
    }

    func testInstalledActivationRejectionRestoresOwnedStateAndPreservesSuccessorRegistration() async throws {
        enum Interleaving: CaseIterable { case lateMembership, successorEpoch, reboundBinding }
        for interleaving in Interleaving.allCases {
            let window = try await makeWindow()
            let viewModel = window.agentModeViewModel
            let sessionID = UUID()
            let session = try await makeWorkspaceOwnedSession(in: window, sessionID: sessionID)
            try await AsyncTestWait.waitUntil("approval-store subscription initialized") {
                await MainActor.run { session.applyEditsApprovalSubscriptionID != nil }
            }
            await viewModel.applyEditsApprovalStore.setAutoEditEnabled(
                false, for: viewModel.applyEditsScope(for: session.tabID), updateGlobalDefault: false
            )
            try await AsyncTestWait.waitUntil("approval-store auto-edit override applied") {
                await MainActor.run { !session.autoEditEnabled }
            }
            let previousPermission = session.permissionProfile
            let endpoint = try XCTUnwrap(viewModel.agentSessionLinkObserverEndpoint(tabID: session.tabID))
            var hold: UInt64?
            var setupAwaitCount = 0
            var installedContext: AgentModeViewModel.AgentMCPControlContext?
            var successorContext: AgentModeViewModel.AgentMCPControlContext?
            viewModel.test_afterMCPControlSetupAwait = { current in
                XCTAssertIdentical(current, session)
                setupAwaitCount += 1
                guard let context = current.mcpControlContext else { return XCTFail("Expected installed context") }
                installedContext = context
                switch interleaving {
                case .lateMembership:
                    guard setupAwaitCount == 2 else { return }
                    XCTAssertTrue(current.isMCPOriginated)
                    let autoEdit = await viewModel.applyEditsApprovalStore.autoEditEnabled(
                        for: viewModel.applyEditsScope(for: current.tabID)
                    )
                    XCTAssertTrue(autoEdit, "Activation must override the authoritative approval store")
                    // The setter yields a snapshot; its return does not acknowledge UI subscription delivery.
                    do {
                        try await AsyncTestWait.waitUntil("approval-store activation override projected") {
                            await MainActor.run { current.autoEditEnabled }
                        }
                    } catch {
                        XCTFail("Activation override was not projected: \(error)")
                    }
                    XCTAssertTrue(current.autoEditEnabled)
                    hold = viewModel.agentSessionLinkWithholdPromptInventory(for: endpoint)
                case .successorEpoch:
                    var successor = context
                    successor.pendingEpochTransition = .init(token: UUID(), kind: .steering, expectedCurrentEpoch: nil)
                    current.mcpControlContext = successor
                    successorContext = successor
                case .reboundBinding:
                    do { try self.rebindCancelSession(current, to: UUID(), in: window) }
                    catch { XCTFail("Could not install successor binding: \(error)") }
                }
            }
            do {
                _ = try await viewModel.mcpActivateControlContext(
                    forTabID: session.tabID, sessionID: sessionID, originatingConnectionID: nil, startPending: true
                )
                XCTFail("The changed activation must be rejected: \(interleaving)")
            } catch let error as MCPError {
                let expected = interleaving == .lateMembership
                    ? AgentModeViewModel.mcpResidentTargetError
                    : "The MCP control activation was superseded during setup."
                XCTAssertEqual(String(describing: error), String(describing: MCPError.invalidParams(expected)))
            }
            viewModel.test_afterMCPControlSetupAwait = nil
            let installed = try XCTUnwrap(installedContext)
            let registration = await AgentRunSessionStore.currentRegistration(for: sessionID)
            if interleaving == .successorEpoch {
                XCTAssertEqual(session.mcpControlContext, successorContext)
                XCTAssertEqual(registration, installed.registration, "The losing activation must not clean its successor's registration")
            } else {
                XCTAssertNil(registration, "An abandoned activation must release its own registration")
            }
            if interleaving == .lateMembership {
                XCTAssertEqual(setupAwaitCount, 2, "Exercise rejection after origin, pending state and permission were overridden")
                XCTAssertNil(session.mcpControlContext)
                XCTAssertFalse(session.mcpFollowUpRunPending)
                XCTAssertFalse(session.isMCPOriginated)
                XCTAssertEqual(session.permissionProfile, previousPermission)
                let autoEdit = await viewModel.applyEditsApprovalStore.autoEditEnabled(for: viewModel.applyEditsScope(for: session.tabID))
                XCTAssertFalse(autoEdit)
                try await AsyncTestWait.waitUntil("approval-store rollback projected") {
                    await MainActor.run { !session.autoEditEnabled }
                }
                XCTAssertFalse(session.autoEditEnabled)
                if let hold { viewModel.agentSessionLinkReleasePromptInventoryHold(hold, for: endpoint, publishing: nil) }
            }
            await viewModel.mcpDeactivateControlContext(sessionID: sessionID, cleanupSessionStore: true)
        }
    }

    func testActivationFenceRejectsLossOfInitiallyRegisteredWindow() async throws {
        let window = try await makeWindow()
        let sessionID = UUID()
        let session = try await makeWorkspaceOwnedSession(in: window, sessionID: sessionID)
        let vm = window.agentModeViewModel
        let admitted = try await vm.mcpPreflightResidentActivation(sessionID: sessionID)
        let target = try XCTUnwrap(admitted)
        XCTAssertNoThrow(try vm.mcpRequireResidentActivationFence(target))
        WindowStatesManager.shared.unregisterWindowState(window)
        XCTAssertThrowsError(try vm.mcpRequireResidentActivationFence(target))
        XCTAssertFalse(vm.mcpResidentTargetIsCurrent(target))
        XCTAssertNil(session.mcpControlContext)
    }

    func testCancelRejectsUnprovenLiveTargetsBeforeHeartbeat() async throws {
        enum InvalidTarget: CaseIterable {
            case ambiguous, controlledObjectMismatch, unrelatedParent
        }
        for invalidTarget in InvalidTarget.allCases {
            let window = try await makeCancelWindow()
            let viewModel = window.agentModeViewModel
            let callerID = UUID(), sessionID = UUID()
            let session = try await makeControlledCancelSession(
                in: window, sessionID: sessionID, parentSessionID: callerID
            )
            switch invalidTarget {
            case .ambiguous:
                let duplicate = AgentModeViewModel.TabSession(tabID: UUID())
                duplicate.installPersistentSessionBinding(.init(tabID: duplicate.tabID, sessionID: sessionID))
                duplicate.hasLoadedPersistedState = true
                duplicate.parentSessionID = UUID()
                viewModel.test_installLiveSession(duplicate)
            case .controlledObjectMismatch:
                try rebindCancelSession(session, to: UUID(), in: window)
                let actual = AgentModeViewModel.TabSession(tabID: UUID())
                actual.installPersistentSessionBinding(.init(tabID: actual.tabID, sessionID: sessionID))
                actual.hasLoadedPersistedState = true
                actual.parentSessionID = callerID
                viewModel.test_installLiveSession(actual)
            case .unrelatedParent:
                session.parentSessionID = UUID()
            }
            installCancelIndex(sessionID: sessionID, tabID: session.tabID, parentSessionID: callerID, in: viewModel)
            let generation = session.stopState.cancellationGeneration
            let runID = session.runID
            var heartbeatEntered = false
            var cancellationReached = false
            viewModel.test_setBeforeCancellationCommit { _ in cancellationReached = true }
            let service = makeService(
                window: window, resolveCaller: { _, _ in callerID },
                beforeHeartbeatOperation: { heartbeatEntered = true }
            )
            try await requireCancelDenied(service, sessionID: sessionID, requiresScopeUnavailableMessage: true)
            XCTAssertFalse(heartbeatEntered, "\(invalidTarget) must fail before the heartbeat boundary")
            XCTAssertFalse(cancellationReached, "\(invalidTarget)")
            XCTAssertEqual(session.stopState.cancellationGeneration, generation, "\(invalidTarget)")
            XCTAssertEqual(session.runID, runID, "\(invalidTarget)")
            XCTAssertEqual(session.runState, .running, "\(invalidTarget)")
        }
    }

    func testCancelUsesExactChildProvenanceAndStopsUnchangedActiveOrPendingTarget() async throws {
        for pending in [false, true] {
            let window = try await makeCancelWindow()
            let viewModel = window.agentModeViewModel
            let callerID = UUID(), sessionID = UUID()
            let session = try await makeControlledCancelSession(
                in: window, sessionID: sessionID, parentSessionID: callerID, startPending: pending
            )
            // A stale index must neither grant nor override the exact loaded object's parent.
            installCancelIndex(sessionID: sessionID, tabID: session.tabID, parentSessionID: UUID(), in: viewModel)
            let originalContext = try XCTUnwrap(session.mcpControlContext)
            let originalGeneration = session.stopState.cancellationGeneration
            let originalExplicitStopGeneration = session.stopState.explicitStopGeneration
            let originalOwnership = session.activeRunOwnership
            let originalRunID = session.runID
            var heartbeatEntered = false
            var cancelledObjects: [ObjectIdentifier] = []
            viewModel.test_setBeforeCancellationCommit { cancelledObjects.append(ObjectIdentifier($0)) }
            let service = makeService(
                window: window, resolveCaller: { _, _ in callerID },
                beforeHeartbeatOperation: { heartbeatEntered = true }
            )
            let result = try await service.execute(args: [
                "op": .string("cancel"), "session_id": .string(sessionID.uuidString)
            ])
            XCTAssertTrue(heartbeatEntered)
            XCTAssertEqual(result.objectValue?["session_id"], .string(sessionID.uuidString))
            let cancellation = try XCTUnwrap(result.objectValue?["cancellation"]?.objectValue)
            XCTAssertEqual(cancellation["initiated"], .bool(!pending))
            XCTAssertEqual(cancellation["stopped"], .bool(!pending))
            XCTAssertEqual(cancellation["pending_start_withdrawn"], .bool(pending))
            XCTAssertEqual(cancellation["run_id"], originalRunID.map { .string($0.uuidString) } ?? .null)
            XCTAssertFalse(session.mcpFollowUpRunPending)
            XCTAssertNotEqual(session.stopState.cancellationGeneration, originalGeneration)
            XCTAssertNotEqual(session.stopState.explicitStopGeneration, originalExplicitStopGeneration)
            XCTAssertEqual(session.mcpControlContext?.activationID, originalContext.activationID)
            XCTAssertEqual(session.mcpControlContext?.registration, originalContext.registration)
            if pending {
                XCTAssertTrue(cancelledObjects.isEmpty, "Withdrawing a producer must not synthesize a cancelled run")
                XCTAssertNil(session.lastTerminalCommitRevision)
                XCTAssertEqual(session.activeRunOwnership, originalOwnership)
                XCTAssertFalse(session.runState.isActive)
                XCTAssertNotEqual(result.objectValue?["status"], .string("running"))
            } else {
                XCTAssertEqual(cancelledObjects, [ObjectIdentifier(session)])
                XCTAssertEqual(session.lastTerminalCommitRevision?.terminalState, .cancelled)
                XCTAssertEqual(session.runState, .cancelled)
            }
        }
    }

    func testCancelRefusesActiveTargetDriftAcrossHeartbeat() async throws {
        enum Drift: CaseIterable {
            case successorRun, replacementObject, reboundObject, controlLost, controlReplaced, callerChanged
        }
        for drift in Drift.allCases {
            let window = try await makeCancelWindow()
            let viewModel = window.agentModeViewModel
            let callerID = UUID(), sessionID = UUID()
            let original = try await makeControlledCancelSession(
                in: window, sessionID: sessionID, parentSessionID: callerID
            )
            var currentCallerID = callerID
            var protectedSession = original
            var protectedGeneration = original.stopState.cancellationGeneration
            var protectedRunID = original.runID
            var protectedContext = original.mcpControlContext
            var heartbeatEntered = false
            var cancellationReached = false
            viewModel.test_setBeforeCancellationCommit { _ in cancellationReached = true }
            let service = makeService(
                window: window, resolveCaller: { _, _ in currentCallerID },
                beforeHeartbeatOperation: {
                    heartbeatEntered = true
                    switch drift {
                    case .successorRun:
                        original.installRunID(UUID())
                        _ = original.beginRunAttempt(source: "public-cancel-successor")
                    case .replacementObject:
                        let replacement = AgentModeViewModel.TabSession(tabID: original.tabID)
                        viewModel.test_installLiveSession(replacement)
                        try self.rebindCancelSession(replacement, to: UUID(), in: window)
                        self.establishRestoredFixture(replacement)
                        replacement.parentSessionID = callerID
                        replacement.selectedAgent = .claudeCode
                        _ = try await viewModel.mcpActivateControlContext(
                            forTabID: replacement.tabID,
                            sessionID: XCTUnwrap(replacement.activeAgentSessionID),
                            originatingConnectionID: nil
                        )
                        replacement.installRunID(UUID())
                        _ = replacement.beginRunAttempt(source: "public-cancel-replacement")
                        replacement.runState = .running
                        protectedSession = replacement
                    case .reboundObject:
                        try self.rebindCancelSession(original, to: UUID(), in: window)
                    case .callerChanged:
                        currentCallerID = UUID()
                    case .controlLost:
                        original.mcpControlContext = nil
                    case .controlReplaced:
                        _ = try await viewModel.mcpActivateControlContext(
                            forTabID: original.tabID, sessionID: sessionID, originatingConnectionID: nil
                        )
                    }
                    protectedGeneration = protectedSession.stopState.cancellationGeneration
                    protectedRunID = protectedSession.runID
                    protectedContext = protectedSession.mcpControlContext
                }
            )
            try await requireCancelDenied(service, sessionID: sessionID)
            XCTAssertTrue(heartbeatEntered, "\(drift) must exercise the post-await fence")
            XCTAssertFalse(cancellationReached, "\(drift)")
            XCTAssertEqual(protectedSession.stopState.cancellationGeneration, protectedGeneration, "\(drift)")
            XCTAssertEqual(protectedSession.runID, protectedRunID, "\(drift)")
            XCTAssertEqual(protectedSession.mcpControlContext, protectedContext, "\(drift)")
            XCTAssertEqual(protectedSession.runState, .running, "\(drift)")
            XCTAssertNil(protectedSession.lastTerminalCommitRevision, "\(drift)")
        }
    }

    func testCancelRefusesSuccessorPendingProducerOrStartedRunAcrossHeartbeat() async throws {
        enum Drift: CaseIterable {
            case successorEpoch, pendingRevision, scheduledProducer, startedRun
        }
        for drift in Drift.allCases {
            let window = try await makeCancelWindow()
            let viewModel = window.agentModeViewModel
            let callerID = UUID(), sessionID = UUID()
            var observedPendingActivation = false
            viewModel.test_afterMCPControlSetupAwait = { current in
                observedPendingActivation = true
                XCTAssertTrue(current.mcpFollowUpRunPending, "Pending start must precede observable control setup")
                guard let snapshot = viewModel.mcpSnapshot(for: current), let context = current.mcpControlContext else {
                    return XCTFail("Control setup must expose its pending snapshot")
                }
                XCTAssertEqual(snapshot.status, .running)
                // Join the same publication an observer can enqueue during setup, so a terminal
                // snapshot cannot escape this regression through favorable task scheduling.
                await AgentRunSessionStore.signalSnapshot(
                    snapshot, cursor: .init(registration: context.registration, epoch: context.currentEpoch)
                )
            }
            let session = try await makeControlledCancelSession(
                in: window, sessionID: sessionID, parentSessionID: callerID, startPending: true
            )
            viewModel.test_afterMCPControlSetupAwait = nil
            XCTAssertTrue(observedPendingActivation)
            let originalTransition = try XCTUnwrap(session.mcpControlContext?.pendingEpochTransition?.token)
            let originalPendingRevision = Date().addingTimeInterval(60)
            session.mcpFollowUpRunPendingUpdatedAt = originalPendingRevision
            if drift == .scheduledProducer {
                session.scheduledACPFollowUp = .init(
                    id: UUID(), instruction: "original pending task", stopFence: .init(session: session)
                )
            }
            var protectedGeneration = session.stopState.cancellationGeneration
            var protectedExplicitStopGeneration = session.stopState.explicitStopGeneration
            var protectedContext = session.mcpControlContext
            var protectedRunID = session.runID
            var protectedPendingRevision = session.mcpFollowUpRunPendingUpdatedAt
            var protectedProducerID = session.scheduledACPFollowUp?.id
            var heartbeatEntered = false
            var cancellationReached = false
            viewModel.test_setBeforeCancellationCommit { _ in cancellationReached = true }
            let service = makeService(
                window: window, resolveCaller: { _, _ in callerID },
                beforeHeartbeatOperation: {
                    heartbeatEntered = true
                    switch drift {
                    case .startedRun:
                        viewModel.setMCPFollowUpRunPending(sessionID: sessionID, false)
                        session.installRunID(UUID())
                        _ = session.beginRunAttempt(source: "public-cancel-pending-started")
                        session.runState = .running
                    case .successorEpoch:
                        let successor = try XCTUnwrap(viewModel.stageMCPRunEpochTransition(sessionID: sessionID, kind: .steering))
                        XCTAssertNotEqual(successor, originalTransition)
                    case .pendingRevision:
                        session.mcpFollowUpRunPendingUpdatedAt = originalPendingRevision.addingTimeInterval(1)
                    case .scheduledProducer:
                        session.scheduledACPFollowUp = .init(
                            id: UUID(), instruction: "replacement pending task", stopFence: .init(session: session)
                        )
                    }
                    protectedGeneration = session.stopState.cancellationGeneration
                    protectedExplicitStopGeneration = session.stopState.explicitStopGeneration
                    protectedContext = session.mcpControlContext
                    protectedRunID = session.runID
                    protectedPendingRevision = session.mcpFollowUpRunPendingUpdatedAt
                    protectedProducerID = session.scheduledACPFollowUp?.id
                }
            )
            try await requireCancelDenied(service, sessionID: sessionID)
            XCTAssertTrue(heartbeatEntered, "\(drift)")
            XCTAssertFalse(cancellationReached, "\(drift)")
            XCTAssertEqual(session.stopState.cancellationGeneration, protectedGeneration, "\(drift)")
            XCTAssertEqual(session.stopState.explicitStopGeneration, protectedExplicitStopGeneration, "\(drift)")
            XCTAssertEqual(session.mcpControlContext, protectedContext, "\(drift)")
            XCTAssertEqual(session.runID, protectedRunID, "\(drift)")
            XCTAssertEqual(session.mcpFollowUpRunPendingUpdatedAt, protectedPendingRevision, "\(drift)")
            XCTAssertEqual(session.scheduledACPFollowUp?.id, protectedProducerID, "\(drift)")
            XCTAssertEqual(session.mcpFollowUpRunPending, drift != .startedRun, "\(drift)")
            XCTAssertEqual(session.runState, drift == .startedRun ? .running : .idle, "\(drift)")
            XCTAssertNil(session.lastTerminalCommitRevision, "\(drift)")
        }
    }

    private func makeCancelWindow() async throws -> WindowState {
        let window = try await makeWindow()
        addTeardownBlock { @MainActor in
            window.agentModeViewModel.test_setBeforeCancellationCommit(nil)
        }
        return window
    }

    private func makeControlledCancelSession(
        in window: WindowState, sessionID: UUID, parentSessionID: UUID, startPending: Bool = false
    ) async throws -> AgentModeViewModel.TabSession {
        let session = try await makeWorkspaceOwnedSession(in: window, sessionID: sessionID)
        session.hasLoadedPersistedState = true
        session.parentSessionID = parentSessionID
        session.selectedAgent = .claudeCode
        session.runState = .idle
        _ = try await window.agentModeViewModel.mcpActivateControlContext(
            forTabID: session.tabID, sessionID: sessionID,
            originatingConnectionID: nil, startPending: startPending
        )
        if startPending {
            _ = try XCTUnwrap(window.agentModeViewModel.stageMCPRunEpochTransition(sessionID: sessionID, kind: .steering))
        } else {
            await window.agentModeViewModel.prepareMCPWaitTrackingForRunStart(
                session: session, stopFence: .init(session: session)
            )
            let preparedEpoch = try XCTUnwrap(session.mcpControlContext?.preparedEpoch)
            XCTAssertEqual(session.mcpControlContext?.currentEpoch, preparedEpoch)
            session.installRunID(UUID())
            let ownership = session.beginRunAttempt(source: "public-cancel-admission")
            XCTAssertEqual(ownership.turnEpoch, preparedEpoch)
            XCTAssertNil(session.mcpControlContext?.preparedEpoch)
            session.runState = .running
        }
        window.agentModeViewModel.publishMCPStateChange(for: session)
        return session
    }

    private func rebindCancelSession(_ session: AgentModeViewModel.TabSession, to sessionID: UUID, in window: WindowState) throws {
        var tab = try XCTUnwrap(window.workspaceManager.composeTab(with: session.tabID))
        tab.activeAgentSessionID = sessionID
        window.workspaceManager.updateComposeTab(tab, markDirty: false)
        session.installPersistentSessionBinding(.init(tabID: session.tabID, sessionID: sessionID))
    }

    private func installCancelIndex(sessionID: UUID, tabID: UUID, parentSessionID: UUID, in viewModel: AgentModeViewModel) {
        viewModel.upsertSessionIndex(
            sessionID: sessionID, tabID: tabID, name: "Cancel provenance",
            lastUserMessageAt: nil, savedAt: Date(timeIntervalSince1970: 1),
            lastRunStateRaw: AgentSessionRunState.running.rawValue, itemCount: 0,
            agentKindRaw: "claudeCode", agentModelRaw: nil, agentReasoningEffortRaw: nil,
            autoEditEnabled: false, parentSessionID: parentSessionID
        )
    }

    private func requireCancelDenied(
        _ service: AgentRunMCPToolService, sessionID: UUID, requiresScopeUnavailableMessage: Bool = false
    ) async throws {
        do {
            _ = try await service.execute(args: ["op": .string("cancel"), "session_id": .string(sessionID.uuidString)])
            XCTFail("Expected invalidParams before cancellation")
        } catch let error as MCPError {
            guard case .invalidParams = error else { return XCTFail("Unexpected error: \(error)") }
            if requiresScopeUnavailableMessage {
                XCTAssertEqual(
                    String(describing: error),
                    String(describing: AgentSessionTargetOperationGuard.denialError(sessionID: sessionID))
                )
            }
        }
    }

    /// Release is latched even if timeout cleanup runs before the task reaches its gate.
    @MainActor
    private final class ResidentSteerGate {
        private var released = false
        private var continuation: CheckedContinuation<Void, Never>?
        private(set) var isWaiting = false

        func wait() async {
            guard !released else { return }
            isWaiting = true
            await withCheckedContinuation { continuation = $0 }
        }

        func release() {
            released = true
            continuation?.resume()
            continuation = nil
        }
    }

    private func legacyExpiredValue(sessionID: UUID) -> Value {
        .object([
            "session_id": .string(sessionID.uuidString), "status": .string("expired"),
            "transcript_item_count": .int(0),
            "session": .object(["id": .string(sessionID.uuidString), "name": .null]),
            "status_text": .string("This run/control/wait handle has expired. If the session still exists in the active workspace, you can usually continue it with `agent_run` using `op: \"steer\"`, the same `session_id`, and a new `message`. Use `op: \"start\"` only when you want a new session.")
        ])
    }

    private func withoutSnapshotTimestamps(_ value: Value) -> Value {
        guard var object = value.objectValue else { return value }
        if object["session_id"] != nil {
            XCTAssertNotNil(object.removeValue(forKey: "updated_at")?.stringValue)
        }
        if let snapshots = object["snapshots"]?.arrayValue {
            object["snapshots"] = .array(snapshots.map(withoutSnapshotTimestamps))
        }
        return .object(object)
    }

    private func makeManageService(window: WindowState) -> AgentManageMCPToolService {
        AgentManageMCPToolService(
            toolName: MCPWindowToolName.agentManage,
            captureRequestMetadata: { .init(connectionID: UUID(), clientName: "external-client", windowID: window.windowID) },
            requireTargetWindow: { window }, resolveSpawnSourceTabID: { _ in nil },
            resolveSpawnParentSessionID: { _, _ in nil }, bindCurrentRequestToTab: { _, _ in }
        )
    }

    private func makeWindow() async throws -> WindowState {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        addTeardownBlock { @MainActor in
            let viewModel = window.agentModeViewModel
            viewModel.test_afterMCPControlActivation = nil
            viewModel.test_afterMCPControlRegistration = nil
            viewModel.test_afterMCPControlSetupAwait = nil
            viewModel.test_agentSessionLinkHasActiveOutboundLink = nil
            viewModel.test_agentSessionLinkAuthoritativeRunCatalogRouteToken = nil
            await window.tearDown()
            WindowStatesManager.shared.unregisterWindowState(window)
        }
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)

        await window.workspaceManager.awaitInitialized()
        let workspace = window.workspaceManager.createWorkspace(
            name: "Steer Resume \(UUID().uuidString.prefix(8))",
            repoPaths: [],
            ephemeral: true
        )
        await window.workspaceManager.switchWorkspace(
            to: workspace,
            saveState: false,
            reason: "agentRunSteerResumeTests"
        )
        let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        window.promptManager.loadComposeTabsFromWorkspace(activeWorkspace, syncPromptText: true)
        return window
    }

    private func makeWorkspaceOwnedSession(
        in window: WindowState,
        sessionID: UUID, tabID requestedTabID: UUID? = nil, restored: Bool = true
    ) async throws -> AgentModeViewModel.TabSession {
        let workspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        let tabID = try XCTUnwrap(requestedTabID ?? workspace.activeComposeTabID)
        let session = await window.agentModeViewModel.ensureSessionReady(tabID: tabID)
        let binding = window.agentModeViewModel.test_installPersistentSessionBinding(
            sessionID: sessionID,
            on: session,
            compareAndSetInWorkspaceID: workspace.id
        )
        _ = try XCTUnwrap(binding)
        if restored {
            establishRestoredFixture(session)
        } else {
            session.hasLoadedPersistedState = false
        }
        return session
    }

    /// These management fixtures begin after restoration; binding installation alone is not proof.
    private func establishRestoredFixture(_ session: AgentModeViewModel.TabSession) {
        session.hasLoadedPersistedState = true
        session.recordRestorationAuthoritative(.persistedPayloadApplied)
        session.markCurrentBindingHydrated()
        XCTAssertTrue(session.permitsBoundOperationAndSave)
    }

    private func makeService(
        window: WindowState, requestedTabID: UUID? = nil,
        resolveCaller: @escaping AgentSessionTargetOperationGuard.SpawnParentSessionResolver = { _, _ in nil },
        beforeHeartbeatOperation: (@MainActor () async throws -> Void)? = nil
    ) -> AgentRunMCPToolService {
        AgentRunMCPToolService(
            toolName: MCPWindowToolName.agentRun,
            captureRequestMetadata: {
                MCPServerViewModel.RequestMetadata(
                    connectionID: UUID(),
                    clientName: "agent-run-steer-resume-tests",
                    windowID: window.windowID
                )
            },
            requireTargetWindow: { window },
            resolveRequestedTabID: { _ in requestedTabID },
            resolveSpawnParentSourceTabID: { _ in nil },
            resolveSpawnParentSessionID: resolveCaller,
            withHeartbeat: { _, _, _, _, operation in
                try await beforeHeartbeatOperation?()
                return try await operation()
            },
            startRun: { _, _, _, _, _, _, _, _, _, _, _, _ in
                throw MCPError.internalError("startRun should not be used by steer resume tests")
            }
        )
    }
}
