import Darwin
import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptShared
import XCTest

@MainActor
final class ContextBuilderRunLifecycleTests: XCTestCase {
    func testTerminalClaimAndContinuationAreExactlyOnce() async throws {
        let tabID = UUID()
        let session = ContextBuilderAgentViewModel.TabSession(tabID: tabID)
        let ownership = session.beginRunAttempt(source: "test")
        var capturedRecord: ContextBuilderRunRecord?

        let waiter = Task<ContextBuilderAgentViewModel.MCPContextBuilderRunCompletion, Error> { @MainActor in
            try await withCheckedThrowingContinuation { continuation in
                capturedRecord = ContextBuilderRunRecord(
                    runID: UUID(),
                    tabID: tabID,
                    session: session,
                    ownership: ownership,
                    origin: .mcp(controlToken: UUID()),
                    agentKind: .claudeCode,
                    modelRaw: AgentModel.defaultModel.rawValue,
                    continuation: continuation
                )
            }
        }

        await Task.yield()
        let record = try XCTUnwrap(capturedRecord)
        XCTAssertEqual(record.cancellationState, .none)
        XCTAssertTrue(record.claimFinalContextCommit())
        XCTAssertTrue(record.finalContextCommitClaimed)
        XCTAssertEqual(record.cancellationState, .none)
        XCTAssertFalse(record.claimFinalContextCommit())
        XCTAssertTrue(record.claimTerminal(.completed))
        XCTAssertFalse(record.claimTerminal(.cancelled))

        let continuation = try XCTUnwrap(record.takeContinuation())
        XCTAssertNil(record.takeContinuation())
        continuation.resume(
            returning: ContextBuilderAgentViewModel.MCPContextBuilderRunCompletion(
                runID: record.runID,
                tabID: tabID,
                identity: nil,
                agentKind: nil,
                modelRaw: nil,
                terminalDisposition: .completed,
                agentOutput: "done",
                usedAgentOutputAsPrompt: false,
                committedTab: nil
            )
        )

        let snapshot = try await waiter.value
        XCTAssertEqual(snapshot.runID, record.runID)
        XCTAssertEqual(snapshot.agentOutput, "done")
    }

    func testRouteSettlementCoordinatorClaimsFirstSettlement() async {
        let routeFirst = ContextBuilderRouteSettlementCoordinator(
            maxBufferedTextCharacters: 5,
            maxBufferedEventCount: 5
        )
        XCTAssertTrue(routeFirst.settle(.routed))
        XCTAssertFalse(routeFirst.settle(.failedWithoutRoute("provider failed")))
        let routeFirstSettlement = await routeFirst.waitForSettlement()
        XCTAssertEqual(routeFirstSettlement, .routed)

        let terminalFirst = ContextBuilderRouteSettlementCoordinator(
            maxBufferedTextCharacters: 5,
            maxBufferedEventCount: 5
        )
        XCTAssertTrue(terminalFirst.settle(.failedWithoutRoute("provider failed")))
        XCTAssertFalse(terminalFirst.settle(.routed))
        let terminalFirstSettlement = await terminalFirst.waitForSettlement()
        XCTAssertEqual(terminalFirstSettlement, .failedWithoutRoute("provider failed"))
    }

    func testRouteSettlementCoordinatorBoundsBufferedPayloadsAndEvents() {
        let payloadBounded = ContextBuilderRouteSettlementCoordinator(
            maxBufferedTextCharacters: 28,
            maxBufferedEventCount: 10
        )
        payloadBounded.appendWhilePending(AIStreamResult(type: "content", text: "1234"))
        payloadBounded.appendWhilePending(AIStreamResult(type: "lifecycle", text: "retrying"))
        payloadBounded.appendWhilePending(AIStreamResult(type: "content", text: "6789"))
        let payloadResult = payloadBounded.drainBufferedEvents()
        XCTAssertEqual(payloadResult.events.map(\.type), ["lifecycle", "content"])
        XCTAssertEqual(payloadResult.events.map(\.text), ["retrying", "6789"])
        XCTAssertEqual(payloadResult.droppedTextCharacterCount, 11)
        XCTAssertEqual(payloadResult.droppedNonterminalEventCount, 1)

        let redundantProgressBounded = ContextBuilderRouteSettlementCoordinator(
            maxBufferedTextCharacters: 100,
            maxBufferedEventCount: 3
        )
        for index in 0 ..< 20 {
            redundantProgressBounded.appendWhilePending(
                AIStreamResult(type: "lifecycle", text: "retry-\(index)")
            )
            redundantProgressBounded.appendWhilePending(AIStreamResult(type: "content", text: ""))
        }
        redundantProgressBounded.appendWhilePending(AIStreamResult(type: "tool_call", text: "call"))
        redundantProgressBounded.appendWhilePending(AIStreamResult(type: "error", text: "provider warning"))
        redundantProgressBounded.appendWhilePending(AIStreamResult(type: "tool_result", text: "result"))
        let redundantProgressResult = redundantProgressBounded.drainBufferedEvents()
        XCTAssertEqual(redundantProgressResult.events.map(\.type), ["tool_call", "error", "tool_result"])
        XCTAssertEqual(redundantProgressResult.droppedNonterminalEventCount, 40)

        let protectedEventBounded = ContextBuilderRouteSettlementCoordinator(
            maxBufferedTextCharacters: 1000,
            maxBufferedEventCount: 3
        )
        let protectedEvents = [
            AIStreamResult(type: "tool_call", text: "call-0"),
            AIStreamResult(type: "error", text: "warning-1"),
            AIStreamResult(type: "tool_result", text: "result-2"),
            AIStreamResult(type: "tool_call", text: "call-3"),
            AIStreamResult(type: "error", text: "warning-4")
        ]
        for event in protectedEvents {
            protectedEventBounded.appendWhilePending(event)
        }
        let protectedEventResult = protectedEventBounded.drainBufferedEvents()
        XCTAssertEqual(protectedEventResult.events.map(\.text), ["result-2", "call-3", "warning-4"])
        XCTAssertEqual(protectedEventResult.droppedNonterminalEventCount, 2)
        XCTAssertEqual(protectedEventResult.droppedTextCharacterCount, 29)

        let oversizedPayloadBounded = ContextBuilderRouteSettlementCoordinator(
            maxBufferedTextCharacters: 8,
            maxBufferedEventCount: 3
        )
        oversizedPayloadBounded.appendWhilePending(
            AIStreamResult(type: "tool_call", text: nil, toolArgs: String(repeating: "x", count: 20))
        )
        let oversizedPayloadResult = oversizedPayloadBounded.drainBufferedEvents()
        XCTAssertTrue(oversizedPayloadResult.events.isEmpty)
        XCTAssertEqual(oversizedPayloadResult.droppedTextCharacterCount, 29)
        XCTAssertEqual(oversizedPayloadResult.droppedNonterminalEventCount, 1)

        let oversizedType = String(repeating: "t", count: 20)
        let zeroLimitTypeBounded = ContextBuilderRouteSettlementCoordinator(
            maxBufferedTextCharacters: 0,
            maxBufferedEventCount: 3
        )
        zeroLimitTypeBounded.appendWhilePending(AIStreamResult(type: oversizedType, text: nil))
        let zeroLimitTypeResult = zeroLimitTypeBounded.drainBufferedEvents()
        XCTAssertTrue(zeroLimitTypeResult.events.isEmpty)
        XCTAssertEqual(zeroLimitTypeResult.droppedTextCharacterCount, oversizedType.count)
        XCTAssertEqual(zeroLimitTypeResult.droppedNonterminalEventCount, 1)
    }

    func testCancellationDuringFinalCommitDefersUntilSafeBoundary() {
        let tabID = UUID()
        let session = ContextBuilderAgentViewModel.TabSession(tabID: tabID)
        let record = makeRecord(
            tabID: tabID,
            session: session,
            ownership: session.beginRunAttempt(source: "deferred-cancel")
        )
        let settlementPolicy = ContextBuilderRunCancellationSettlementPolicy(
            waiterResolution: .snapshot,
            saveHistory: true
        )

        XCTAssertTrue(record.claimFinalContextCommit())
        XCTAssertEqual(
            record.requestCancellation(deferredSettlementPolicy: settlementPolicy),
            .deferredUntilFinalContextCommitCompletes
        )
        XCTAssertEqual(record.cancellationState, .deferredUntilFinalContextCommitCompletes)
        XCTAssertEqual(record.deferredCancellationSettlementPolicy, settlementPolicy)
        XCTAssertTrue(record.hasDeferredCancellationPending)
        XCTAssertEqual(
            record.requestCancellation(deferredSettlementPolicy: settlementPolicy),
            .alreadyRequested
        )

        XCTAssertEqual(record.consumeDeferredCancellationAtSafeBoundary(), settlementPolicy)
        XCTAssertEqual(record.cancellationState, .applied)
        XCTAssertNil(record.consumeDeferredCancellationAtSafeBoundary())
        XCTAssertTrue(record.claimTerminal(.cancelled))
        XCTAssertFalse(record.claimTerminal(.completed))
    }

    func testDeferredWorkspaceCancellationPreservesErrorPolicyAfterCommitBoundaryCheck() {
        let tabID = UUID()
        let session = ContextBuilderAgentViewModel.TabSession(tabID: tabID)
        let record = makeRecord(
            tabID: tabID,
            session: session,
            ownership: session.beginRunAttempt(source: "workspace-cancel")
        )
        let workspaceCancellationPolicy = ContextBuilderRunCancellationSettlementPolicy(
            waiterResolution: .cancellationError,
            saveHistory: false
        )

        XCTAssertTrue(record.claimFinalContextCommit())
        XCTAssertNil(record.consumeDeferredCancellationAtSafeBoundary())
        XCTAssertEqual(
            record.requestCancellation(deferredSettlementPolicy: workspaceCancellationPolicy),
            .deferredUntilFinalContextCommitCompletes
        )
        XCTAssertEqual(
            record.consumeDeferredCancellationAtSafeBoundary(),
            workspaceCancellationPolicy
        )
        XCTAssertTrue(record.claimTerminal(.cancelled))
        XCTAssertFalse(record.claimTerminal(.completed))
    }

    func testCancelCommitRaceResolvesExactlyOnceForEitherOrdering() {
        let settlementPolicy = ContextBuilderRunCancellationSettlementPolicy(
            waiterResolution: .snapshot,
            saveHistory: true
        )
        let cancelFirstTabID = UUID()
        let cancelFirstSession = ContextBuilderAgentViewModel.TabSession(tabID: cancelFirstTabID)
        let cancelFirst = makeRecord(
            tabID: cancelFirstTabID,
            session: cancelFirstSession,
            ownership: cancelFirstSession.beginRunAttempt(source: "cancel-first")
        )

        XCTAssertEqual(
            cancelFirst.requestCancellation(deferredSettlementPolicy: settlementPolicy),
            .settleImmediately
        )
        XCTAssertFalse(cancelFirst.claimFinalContextCommit())
        XCTAssertTrue(cancelFirst.claimTerminal(.cancelled))
        XCTAssertFalse(cancelFirst.claimTerminal(.completed))
        XCTAssertEqual(
            cancelFirst.requestCancellation(deferredSettlementPolicy: settlementPolicy),
            .terminal
        )

        let commitFirstTabID = UUID()
        let commitFirstSession = ContextBuilderAgentViewModel.TabSession(tabID: commitFirstTabID)
        let commitFirst = makeRecord(
            tabID: commitFirstTabID,
            session: commitFirstSession,
            ownership: commitFirstSession.beginRunAttempt(source: "commit-first")
        )

        XCTAssertTrue(commitFirst.claimFinalContextCommit())
        XCTAssertEqual(
            commitFirst.requestCancellation(deferredSettlementPolicy: settlementPolicy),
            .deferredUntilFinalContextCommitCompletes
        )
        XCTAssertEqual(
            commitFirst.consumeDeferredCancellationAtSafeBoundary(),
            settlementPolicy
        )
        XCTAssertTrue(commitFirst.claimTerminal(.cancelled))
        XCTAssertFalse(commitFirst.claimTerminal(.completed))
        XCTAssertEqual(
            commitFirst.requestCancellation(deferredSettlementPolicy: settlementPolicy),
            .terminal
        )
    }

    func testPreCommitCancellationRemainsImmediate() {
        let tabID = UUID()
        let session = ContextBuilderAgentViewModel.TabSession(tabID: tabID)
        let record = makeRecord(
            tabID: tabID,
            session: session,
            ownership: session.beginRunAttempt(source: "pre-commit-cancel")
        )
        let settlementPolicy = ContextBuilderRunCancellationSettlementPolicy(
            waiterResolution: .cancellationError,
            saveHistory: false
        )

        XCTAssertEqual(
            record.requestCancellation(deferredSettlementPolicy: settlementPolicy),
            .settleImmediately
        )
        XCTAssertEqual(record.cancellationState, .requested)
        XCTAssertNil(record.deferredCancellationSettlementPolicy)
        XCTAssertFalse(record.hasDeferredCancellationPending)
        XCTAssertFalse(record.claimFinalContextCommit())
        XCTAssertTrue(record.claimTerminal(.cancelled))
        XCTAssertEqual(
            record.requestCancellation(deferredSettlementPolicy: settlementPolicy),
            .terminal
        )
    }

    func testTerminalCommitCapturesPromptFallbackBeforeContextCleanup() async throws {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        WindowStatesManager.shared.registerWindowState(window)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        await window.workspaceManager.awaitInitialized()

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContextBuilderPromptFallbackTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let workspace = window.workspaceManager.createWorkspace(
            name: "Context Builder prompt fallback test",
            repoPaths: [root.path],
            ephemeral: true
        )
        await window.workspaceManager.switchWorkspace(
            to: workspace,
            saveState: false,
            reason: "ContextBuilderRunLifecycleTests.promptFallback"
        )
        let workspaceID = try XCTUnwrap(window.workspaceManager.activeWorkspace?.id)
        let tabID = try XCTUnwrap(
            window.workspaceManager.activeWorkspace?.activeComposeTabID
                ?? window.workspaceManager.activeWorkspace?.composeTabs.first?.id
        )
        let identity = WorkspaceSelectionIdentity(workspaceID: workspaceID, tabID: tabID)
        var tab = try XCTUnwrap(window.workspaceManager.composeTab(for: identity))
        tab.promptText = ""
        tab.contextOverrides.useOverridePrompt = true
        tab.contextOverrides.overridePromptText = "stale override"
        XCTAssertTrue(window.workspaceManager.updateComposeTabStoredOnly(tab, inWorkspaceID: workspaceID))

        let connectionID = UUID()
        let runID = UUID()
        try window.mcpServer.bindTabForConnection(
            connectionID: connectionID,
            clientName: "context-builder-prompt-fallback-test",
            tabID: tabID,
            workspaceID: workspaceID,
            windowID: window.windowID,
            runID: runID
        )

        let result = await window.mcpServer.commitContextBuilderTabContext(
            connectionID: connectionID,
            expectedRunID: runID,
            isStillCurrent: { true },
            promptFallback: "Discovery response"
        )
        let committed = try XCTUnwrap(result.committedTab)
        XCTAssertEqual(result.outcome, .committed)
        XCTAssertTrue(committed.usedAgentOutputAsPrompt)
        XCTAssertEqual(committed.tab.promptText, "Discovery response")
        XCTAssertFalse(committed.tab.contextOverrides.useOverridePrompt)
        XCTAssertEqual(committed.tab.contextOverrides.overridePromptText, "")

        let stored = try XCTUnwrap(window.workspaceManager.composeTab(for: identity))
        XCTAssertEqual(stored.promptText, committed.tab.promptText)
        XCTAssertEqual(stored.contextOverrides, committed.tab.contextOverrides)
        XCTAssertEqual(
            window.workspaceManager.selectionRevisionForMCP(
                workspaceID: workspaceID,
                tabID: tabID
            ),
            committed.selectionRevision
        )
    }

    func testSuccessfulCommitPrecedesChildTerminationAndCleanupWaitsForJoin() async {
        let connectionID = UUID()
        let terminationGate = LifecycleTestGate()
        var events: [String] = []
        var cleanupCount = 0

        let finalization = Task { @MainActor in
            await ContextBuilderChildConnectionFinalizer.finalize(
                connectionIDs: [connectionID],
                awaitResponseDeliveryDrain: { drainedID in
                    XCTAssertEqual(drainedID, connectionID)
                    events.append("response_delivery_drained")
                    return true
                },
                commitContext: { committedID in
                    XCTAssertEqual(committedID, connectionID)
                    events.append("context_committed")
                    return true
                },
                beforeTerminationRequest: {
                    events.append("before_termination_request")
                },
                requestTermination: { requestedID in
                    XCTAssertEqual(requestedID, connectionID)
                    events.append("termination_requested")
                    return Task { @MainActor in
                        await terminationGate.arriveAndWait()
                    }
                },
                beforeTerminationJoin: {
                    events.append("termination_join")
                },
                cleanupMapping: { cleanedID in
                    XCTAssertEqual(cleanedID, connectionID)
                    cleanupCount += 1
                    events.append("mapping_cleaned")
                }
            )
        }

        await terminationGate.waitUntilArrived()
        XCTAssertEqual(events, [
            "response_delivery_drained",
            "context_committed",
            "before_termination_request",
            "termination_requested",
            "termination_join"
        ])
        XCTAssertEqual(cleanupCount, 0)

        await terminationGate.release()
        let didFinalize = await finalization.value
        XCTAssertTrue(didFinalize)
        XCTAssertEqual(cleanupCount, 1)
        XCTAssertEqual(events, [
            "response_delivery_drained",
            "context_committed",
            "before_termination_request",
            "termination_requested",
            "termination_join",
            "mapping_cleaned"
        ])
    }

    func testSuccessfulFinalizationWaitsForResponseDeliveryBeforeCommit() async {
        let connectionID = UUID()
        let responseDeliveryGate = LifecycleTestGate()
        var events: [String] = []

        let finalization = Task { @MainActor in
            await ContextBuilderChildConnectionFinalizer.finalize(
                connectionIDs: [connectionID],
                awaitResponseDeliveryDrain: { drainedID in
                    XCTAssertEqual(drainedID, connectionID)
                    events.append("drain_started")
                    await responseDeliveryGate.arriveAndWait()
                    events.append("drain_finished")
                    return true
                },
                commitContext: { committedID in
                    XCTAssertEqual(committedID, connectionID)
                    events.append("context_committed")
                    return true
                },
                beforeTerminationRequest: {
                    events.append("before_termination_request")
                },
                requestTermination: { requestedID in
                    XCTAssertEqual(requestedID, connectionID)
                    events.append("termination_requested")
                    return Task {}
                },
                beforeTerminationJoin: {
                    events.append("termination_join")
                },
                cleanupMapping: { cleanedID in
                    XCTAssertEqual(cleanedID, connectionID)
                    events.append("mapping_cleaned")
                }
            )
        }

        await responseDeliveryGate.waitUntilArrived()
        XCTAssertEqual(events, ["drain_started"])

        await responseDeliveryGate.release()
        let didFinalize = await finalization.value
        XCTAssertTrue(didFinalize)
        XCTAssertEqual(events, [
            "drain_started",
            "drain_finished",
            "context_committed",
            "before_termination_request",
            "termination_requested",
            "termination_join",
            "mapping_cleaned"
        ])
    }

    func testMissingCommitOwnershipDoesNotRequestTermination() async {
        let connectionID = UUID()
        var didRequestTermination = false
        var didCleanupMapping = false

        let didFinalize = await ContextBuilderChildConnectionFinalizer.finalize(
            connectionIDs: [connectionID],
            awaitResponseDeliveryDrain: { _ in true },
            commitContext: { _ in false },
            beforeTerminationRequest: {
                XCTFail("Termination phase must not start without committed context ownership")
            },
            requestTermination: { _ in
                didRequestTermination = true
                return Task {}
            },
            beforeTerminationJoin: {
                XCTFail("Termination join must not start without committed context ownership")
            },
            cleanupMapping: { _ in
                didCleanupMapping = true
            }
        )

        XCTAssertFalse(didFinalize)
        XCTAssertFalse(didRequestTermination)
        XCTAssertFalse(didCleanupMapping)

        var didAwaitNegativeTeardownResolution = false
        let liveDrainFailure = await ContextBuilderResponseDeliveryDrainResolver.resolve(
            initiallyDetached: false,
            awaitDrain: { false },
            isAuthoritativeDetached: { false },
            awaitTeardownPublication: {
                didAwaitNegativeTeardownResolution = true
                return .resolvedWithoutPeerEOFDetachment(reason: "read_error")
            }
        )
        XCTAssertTrue(didAwaitNegativeTeardownResolution)
        XCTAssertEqual(liveDrainFailure, .failed)
        XCTAssertFalse(liveDrainFailure.succeeded)

        var didAttemptInitialDrain = false
        let initiallyDetachedPeerEOF = await ContextBuilderResponseDeliveryDrainResolver.resolve(
            initiallyDetached: true,
            awaitDrain: {
                didAttemptInitialDrain = true
                return false
            },
            isAuthoritativeDetached: { true },
            awaitTeardownPublication: { .peerEOFDetached }
        )
        XCTAssertFalse(didAttemptInitialDrain)
        XCTAssertEqual(initiallyDetachedPeerEOF, .peerEOFDetached)
        XCTAssertTrue(initiallyDetachedPeerEOF.succeeded)

        let initiallyDetachedAfterDrainedClose = await ContextBuilderResponseDeliveryDrainResolver.resolve(
            initiallyDetached: true,
            awaitDrain: {
                XCTFail("Already-detached contexts must resolve from the teardown publication")
                return false
            },
            isAuthoritativeDetached: { true },
            awaitTeardownPublication: {
                .detachedAfterResponseDeliveryDrained(reason: "read_error")
            }
        )
        XCTAssertEqual(initiallyDetachedAfterDrainedClose, .detachedAfterResponseDeliveryDrained)
        XCTAssertTrue(initiallyDetachedAfterDrainedClose.succeeded)
        XCTAssertTrue(initiallyDetachedAfterDrainedClose.transportAlreadyClosed)

        let initiallyDetachedFailure = await ContextBuilderResponseDeliveryDrainResolver.resolve(
            initiallyDetached: true,
            awaitDrain: {
                XCTFail("Already-detached contexts must resolve from the teardown publication")
                return true
            },
            isAuthoritativeDetached: { true },
            awaitTeardownPublication: { .detachedWithoutOrderlyPeerEOF(reason: "read_error") }
        )
        XCTAssertEqual(initiallyDetachedFailure, .failed)
        XCTAssertFalse(initiallyDetachedFailure.succeeded)

        let failureDetachedDuringDrain = await ContextBuilderResponseDeliveryDrainResolver.resolve(
            initiallyDetached: false,
            awaitDrain: { false },
            isAuthoritativeDetached: { true },
            awaitTeardownPublication: { .detachedWithoutOrderlyPeerEOF(reason: "write_hangup") }
        )
        XCTAssertEqual(failureDetachedDuringDrain, .failed)
        XCTAssertFalse(failureDetachedDuringDrain.succeeded)
    }

    func testRealConnectionCleanupCannotEraseContextBeforeCommit() async throws {
        #if DEBUG
            let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            let window = WindowState()
            GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
            WindowStatesManager.shared.registerWindowState(window)
            defer { WindowStatesManager.shared.unregisterWindowState(window) }

            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("ContextBuilderCleanupCommitTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let workspace = window.workspaceManager.createWorkspace(
                name: "Context Builder cleanup commit test",
                repoPaths: [root.path],
                ephemeral: true
            )
            await window.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "ContextBuilderRunLifecycleTests.realCleanup"
            )

            let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
            let tabID = try XCTUnwrap(
                activeWorkspace.activeComposeTabID ?? activeWorkspace.composeTabs.first?.id
            )
            let clientName = "context-builder-cleanup-commit-test"
            let expectedPrompt = "context retained after peer EOF cleanup"
            var tab = try XCTUnwrap(window.workspaceManager.composeTab(with: tabID))
            tab.promptText = expectedPrompt
            XCTAssertTrue(window.workspaceManager.updateComposeTabStoredOnly(tab, inWorkspaceID: activeWorkspace.id))
            window.workspaceManager.promptViewModel.promptText = expectedPrompt

            let connectionID = UUID()
            let runID = UUID()
            try window.mcpServer.bindTabForConnection(
                connectionID: connectionID,
                clientName: clientName,
                tabID: tabID,
                workspaceID: activeWorkspace.id,
                windowID: window.windowID,
                runID: runID
            )
            var context = try XCTUnwrap(window.mcpServer.tabContextByConnectionID[connectionID])
            context.promptText = expectedPrompt
            window.mcpServer.tabContextByConnectionID[connectionID] = context

            let connection = ContextBuilderCleanupTestConnection()
            await ServerNetworkManager.shared.debugRegisterConnectionForSocketFixture(
                connectionID: connectionID,
                connection: connection,
                clientName: clientName,
                sessionToken: UUID().uuidString
            )
            await ServerNetworkManager.shared.debugSeedConnectionRunRouting(
                connectionID: connectionID,
                runID: runID,
                purpose: .discoverRun,
                windowID: window.windowID
            )

            // Reproduce the inverse production ordering: orderly peer EOF teardown
            // completes fully before end-of-run commit begins.
            await ServerNetworkManager.shared.removeConnection(
                connectionID,
                context: MCPConnectionCloseContext(
                    reason: MCPTransportTerminalCause.peerEOF.rawValue,
                    initiator: .peer
                )
            )
            XCTAssertNil(window.mcpServer.tabContextByConnectionID[connectionID])
            XCTAssertTrue(
                window.mcpServer.isDetachedContextBuilderConnection(
                    connectionID: connectionID,
                    runID: runID
                )
            )
            let removedClient = await ServerNetworkManager.shared.clientIdentifier(forConnection: connectionID)
            XCTAssertNil(removedClient)

            let commitOutcome = await window.mcpServer.commitContextBuilderTabContext(
                connectionID: connectionID,
                expectedRunID: runID,
                isStillCurrent: { true }
            )
            XCTAssertEqual(commitOutcome.outcome, .committed)
            XCTAssertEqual(commitOutcome.committedTab?.nestedRunID, runID)
            XCTAssertEqual(commitOutcome.committedTab?.identity.workspaceID, activeWorkspace.id)
            XCTAssertEqual(commitOutcome.committedTab?.identity.tabID, tabID)
            XCTAssertEqual(commitOutcome.committedTab?.tab.promptText, expectedPrompt)
            XCTAssertEqual(window.workspaceManager.composeTab(with: tabID)?.promptText, expectedPrompt)
            XCTAssertFalse(
                window.mcpServer.isDetachedContextBuilderConnection(
                    connectionID: connectionID,
                    runID: runID
                )
            )

            let secondCommitOutcome = await window.mcpServer.commitContextBuilderTabContext(
                connectionID: connectionID,
                expectedRunID: runID,
                isStillCurrent: { true }
            )
            XCTAssertEqual(
                secondCommitOutcome.outcome,
                .missingFinalContext(runID: runID, connectionID: connectionID)
            )

            // Begin finalization while the connection is live, then complete a non-orderly
            // teardown after every accepted request has a delivered response. The failed live
            // drain is accepted from the final delivery snapshot taken after awaited cleanup.
            let transitioningConnectionID = UUID()
            let transitioningRunID = UUID()
            let transitioningPrompt = "context detached during response drain"
            try window.mcpServer.bindTabForConnection(
                connectionID: transitioningConnectionID,
                clientName: clientName,
                tabID: tabID,
                workspaceID: activeWorkspace.id,
                windowID: window.windowID,
                runID: transitioningRunID
            )
            var transitioningContext = try XCTUnwrap(
                window.mcpServer.tabContextByConnectionID[transitioningConnectionID]
            )
            transitioningContext.promptText = transitioningPrompt
            window.mcpServer.tabContextByConnectionID[transitioningConnectionID] = transitioningContext

            let transitioningConnection = ContextBuilderCleanupTestConnection(
                pendingRequestCount: 1,
                subsequentPendingRequestCount: 0
            )
            await ServerNetworkManager.shared.debugRegisterConnectionForSocketFixture(
                connectionID: transitioningConnectionID,
                connection: transitioningConnection,
                clientName: clientName,
                sessionToken: UUID().uuidString
            )
            await ServerNetworkManager.shared.debugSeedConnectionRunRouting(
                connectionID: transitioningConnectionID,
                runID: transitioningRunID,
                purpose: .discoverRun,
                windowID: window.windowID
            )

            let handoffWaitStarted = LifecycleTestGate()
            let commitAfterPublication = LifecycleTestGate()
            var transitioningDrainOutcome: ContextBuilderResponseDeliveryDrainOutcome = .failed
            var transitioningCommitCount = 0
            var transitioningTerminationCount = 0
            let transitioningFinalization = Task { @MainActor in
                await ContextBuilderChildConnectionFinalizer.finalize(
                    connectionIDs: [transitioningConnectionID],
                    awaitResponseDeliveryDrain: { drainedID in
                        transitioningDrainOutcome = await ContextBuilderResponseDeliveryDrainResolver.resolve(
                            initiallyDetached: false,
                            awaitDrain: {
                                XCTAssertEqual(drainedID, transitioningConnectionID)
                                return false
                            },
                            isAuthoritativeDetached: {
                                window.mcpServer.isDetachedContextBuilderConnection(
                                    connectionID: drainedID,
                                    runID: transitioningRunID
                                )
                            },
                            awaitTeardownPublication: {
                                await handoffWaitStarted.arrive()
                                return await window.mcpServer.contextBuilderTeardownPublicationCoordinator.wait(
                                    runID: transitioningRunID,
                                    connectionID: drainedID,
                                    timeoutSeconds: 1
                                )
                            }
                        )
                        return transitioningDrainOutcome.succeeded
                    },
                    commitContext: { committedID in
                        await commitAfterPublication.arriveAndWait()
                        transitioningCommitCount += 1
                        let outcome = await window.mcpServer.commitContextBuilderTabContext(
                            connectionID: committedID,
                            expectedRunID: transitioningRunID,
                            isStillCurrent: { true },
                            deferRunMappingCleanupUntilCaller: true
                        )
                        return outcome.outcome == .committed
                    },
                    beforeTerminationRequest: {},
                    requestTermination: { requestedID in
                        guard !transitioningDrainOutcome.transportAlreadyClosed else {
                            return Task {}
                        }
                        transitioningTerminationCount += 1
                        return Task {
                            await ServerNetworkManager.shared.terminateConnection(
                                requestedID,
                                reason: .runCompleted,
                                message: "transitioning drain test completion"
                            )
                        }
                    },
                    beforeTerminationJoin: {},
                    cleanupMapping: { cleanedID in
                        window.mcpServer.removeTabContext(
                            forConnectionID: cleanedID,
                            clientName: clientName,
                            windowID: window.windowID,
                            runID: transitioningRunID
                        )
                    }
                )
            }

            await handoffWaitStarted.waitUntilArrived()
            XCTAssertFalse(
                window.mcpServer.isDetachedContextBuilderConnection(
                    connectionID: transitioningConnectionID,
                    runID: transitioningRunID
                )
            )
            await ServerNetworkManager.shared.removeConnection(
                transitioningConnectionID,
                context: MCPConnectionCloseContext(
                    reason: MCPTransportTerminalCause.readError.rawValue,
                    initiator: .peer
                )
            )
            await commitAfterPublication.waitUntilArrived()
            XCTAssertTrue(
                window.mcpServer.isDetachedContextBuilderConnection(
                    connectionID: transitioningConnectionID,
                    runID: transitioningRunID
                )
            )
            await commitAfterPublication.release()

            let didFinalizeTransition = await transitioningFinalization.value
            XCTAssertTrue(didFinalizeTransition)
            XCTAssertEqual(transitioningDrainOutcome, .detachedAfterResponseDeliveryDrained)
            XCTAssertEqual(transitioningCommitCount, 1)
            XCTAssertEqual(transitioningTerminationCount, 0)
            XCTAssertEqual(window.workspaceManager.composeTab(with: tabID)?.promptText, transitioningPrompt)
            XCTAssertFalse(
                window.mcpServer.isDetachedContextBuilderConnection(
                    connectionID: transitioningConnectionID,
                    runID: transitioningRunID
                )
            )
            let transitioningSecondCommit = await window.mcpServer.commitContextBuilderTabContext(
                connectionID: transitioningConnectionID,
                expectedRunID: transitioningRunID,
                isStillCurrent: { true }
            )
            XCTAssertEqual(
                transitioningSecondCommit.outcome,
                .missingFinalContext(
                    runID: transitioningRunID,
                    connectionID: transitioningConnectionID
                )
            )
            let transitioningConnectionTerminationCount = await transitioningConnection.terminationCount()
            XCTAssertEqual(transitioningConnectionTerminationCount, 0)

            // Non-orderly transport failures with an accepted response still pending detach
            // the final context so a later safe path can inspect/discard it, but they must not
            // satisfy response drain or commit partial context through successful finalization.
            let failureConnectionID = UUID()
            let failureRunID = UUID()
            let failurePrompt = "must not auto-commit after read error"
            try window.mcpServer.bindTabForConnection(
                connectionID: failureConnectionID,
                clientName: clientName,
                tabID: tabID,
                workspaceID: activeWorkspace.id,
                windowID: window.windowID,
                runID: failureRunID
            )
            var failureContext = try XCTUnwrap(window.mcpServer.tabContextByConnectionID[failureConnectionID])
            failureContext.promptText = failurePrompt
            window.mcpServer.tabContextByConnectionID[failureConnectionID] = failureContext
            await ServerNetworkManager.shared.debugRegisterConnectionForSocketFixture(
                connectionID: failureConnectionID,
                connection: ContextBuilderCleanupTestConnection(pendingRequestCount: 1),
                clientName: clientName,
                sessionToken: UUID().uuidString
            )
            await ServerNetworkManager.shared.debugSeedConnectionRunRouting(
                connectionID: failureConnectionID,
                runID: failureRunID,
                purpose: .discoverRun,
                windowID: window.windowID
            )

            let failureWaitStarted = LifecycleTestGate()
            var failureDrainOutcome: ContextBuilderResponseDeliveryDrainOutcome = .drained
            var failureCommitCount = 0
            var failureTerminationCount = 0
            let failureFinalization = Task { @MainActor in
                await ContextBuilderChildConnectionFinalizer.finalize(
                    connectionIDs: [failureConnectionID],
                    awaitResponseDeliveryDrain: { drainedID in
                        failureDrainOutcome = await ContextBuilderResponseDeliveryDrainResolver.resolve(
                            initiallyDetached: false,
                            awaitDrain: {
                                XCTAssertEqual(drainedID, failureConnectionID)
                                return false
                            },
                            isAuthoritativeDetached: {
                                window.mcpServer.isDetachedContextBuilderConnection(
                                    connectionID: drainedID,
                                    runID: failureRunID
                                )
                            },
                            awaitTeardownPublication: {
                                await failureWaitStarted.arrive()
                                return await window.mcpServer.contextBuilderTeardownPublicationCoordinator.wait(
                                    runID: failureRunID,
                                    connectionID: drainedID,
                                    timeoutSeconds: 1
                                )
                            }
                        )
                        return failureDrainOutcome.succeeded
                    },
                    commitContext: { _ in
                        failureCommitCount += 1
                        return true
                    },
                    beforeTerminationRequest: {},
                    requestTermination: { _ in
                        failureTerminationCount += 1
                        return Task {}
                    },
                    beforeTerminationJoin: {},
                    cleanupMapping: { _ in }
                )
            }

            await failureWaitStarted.waitUntilArrived()
            await ServerNetworkManager.shared.removeConnection(
                failureConnectionID,
                context: MCPConnectionCloseContext(
                    reason: MCPTransportTerminalCause.readError.rawValue,
                    initiator: .peer
                )
            )
            let didFinalizeFailure = await failureFinalization.value
            XCTAssertFalse(didFinalizeFailure)
            XCTAssertEqual(failureDrainOutcome, .failed)
            XCTAssertEqual(failureCommitCount, 0)
            XCTAssertEqual(failureTerminationCount, 0)
            XCTAssertTrue(
                window.mcpServer.isDetachedContextBuilderConnection(
                    connectionID: failureConnectionID,
                    runID: failureRunID
                )
            )
            XCTAssertEqual(
                window.mcpServer.contextBuilderFinalContextConnectionID(runID: failureRunID),
                failureConnectionID
            )
            XCTAssertEqual(window.workspaceManager.composeTab(with: tabID)?.promptText, transitioningPrompt)
            window.mcpServer.discardDetachedContextBuilderTabContext(runID: failureRunID)

            // The negative twin uses the same production peer-EOF teardown, then models
            // explicit cancellation before commit. Detached ownership is discarded and
            // the compose tab is not mutated.
            let cancelledConnectionID = UUID()
            let cancelledRunID = UUID()
            try window.mcpServer.bindTabForConnection(
                connectionID: cancelledConnectionID,
                clientName: clientName,
                tabID: tabID,
                workspaceID: activeWorkspace.id,
                windowID: window.windowID,
                runID: cancelledRunID
            )
            var cancelledContext = try XCTUnwrap(
                window.mcpServer.tabContextByConnectionID[cancelledConnectionID]
            )
            cancelledContext.promptText = "must not commit after cancellation"
            window.mcpServer.tabContextByConnectionID[cancelledConnectionID] = cancelledContext

            let cancelledConnection = ContextBuilderCleanupTestConnection()
            await ServerNetworkManager.shared.debugRegisterConnectionForSocketFixture(
                connectionID: cancelledConnectionID,
                connection: cancelledConnection,
                clientName: clientName,
                sessionToken: UUID().uuidString
            )
            await ServerNetworkManager.shared.debugSeedConnectionRunRouting(
                connectionID: cancelledConnectionID,
                runID: cancelledRunID,
                purpose: .discoverRun,
                windowID: window.windowID
            )
            await ServerNetworkManager.shared.removeConnection(
                cancelledConnectionID,
                context: MCPConnectionCloseContext(
                    reason: MCPTransportTerminalCause.peerEOF.rawValue,
                    initiator: .peer
                )
            )

            let cancelledOutcome = await window.mcpServer.commitContextBuilderTabContext(
                connectionID: cancelledConnectionID,
                expectedRunID: cancelledRunID,
                isStillCurrent: { false }
            )
            XCTAssertEqual(cancelledOutcome.outcome, .staleOrNoLongerCurrent)
            XCTAssertEqual(window.workspaceManager.composeTab(with: tabID)?.promptText, transitioningPrompt)
            XCTAssertFalse(
                window.mcpServer.isDetachedContextBuilderConnection(
                    connectionID: cancelledConnectionID,
                    runID: cancelledRunID
                )
            )

            func seedDiscoveryConnection(
                connectionID: UUID,
                runID: UUID,
                purpose: MCPRunPurpose,
                prompt: String? = nil,
                authoritative: Bool = true
            ) async throws {
                try window.mcpServer.bindTabForConnection(
                    connectionID: connectionID,
                    clientName: clientName,
                    tabID: tabID,
                    workspaceID: activeWorkspace.id,
                    windowID: window.windowID,
                    runID: runID
                )
                if let prompt {
                    var context = try XCTUnwrap(window.mcpServer.tabContextByConnectionID[connectionID])
                    context.promptText = prompt
                    window.mcpServer.tabContextByConnectionID[connectionID] = context
                }
                await ServerNetworkManager.shared.debugRegisterConnectionForSocketFixture(
                    connectionID: connectionID,
                    connection: ContextBuilderCleanupTestConnection(),
                    clientName: clientName,
                    sessionToken: UUID().uuidString
                )
                await ServerNetworkManager.shared.debugSeedConnectionRunRouting(
                    connectionID: connectionID,
                    runID: runID,
                    purpose: purpose,
                    windowID: window.windowID
                )
                if !authoritative {
                    window.mcpServer.connectionIDByRunID[runID] = UUID()
                }
            }

            func assertDiscoveryCloseDetachesAndCommits(
                closeContext: MCPConnectionCloseContext,
                prompt: String
            ) async throws {
                let detachedConnectionID = UUID()
                let detachedRunID = UUID()
                try await seedDiscoveryConnection(
                    connectionID: detachedConnectionID,
                    runID: detachedRunID,
                    purpose: .discoverRun,
                    prompt: prompt
                )

                await ServerNetworkManager.shared.removeConnection(
                    detachedConnectionID,
                    context: closeContext
                )

                XCTAssertNil(window.mcpServer.tabContextByConnectionID[detachedConnectionID])
                XCTAssertTrue(
                    window.mcpServer.isDetachedContextBuilderConnection(
                        connectionID: detachedConnectionID,
                        runID: detachedRunID
                    )
                )
                XCTAssertEqual(
                    window.mcpServer.contextBuilderFinalContextConnectionID(runID: detachedRunID),
                    detachedConnectionID
                )
                let commitOutcome = await window.mcpServer.commitContextBuilderTabContext(
                    connectionID: detachedConnectionID,
                    expectedRunID: detachedRunID,
                    isStillCurrent: { true }
                )
                XCTAssertEqual(commitOutcome.outcome, .committed)
                XCTAssertEqual(commitOutcome.committedTab?.nestedRunID, detachedRunID)
                XCTAssertEqual(commitOutcome.committedTab?.tab.promptText, prompt)
                XCTAssertFalse(
                    window.mcpServer.isDetachedContextBuilderConnection(
                        connectionID: detachedConnectionID,
                        runID: detachedRunID
                    )
                )
            }

            func assertDoesNotDetach(
                closeContext: MCPConnectionCloseContext,
                purpose: MCPRunPurpose,
                authoritative: Bool = true
            ) async throws {
                let excludedConnectionID = UUID()
                let excludedRunID = UUID()
                try await seedDiscoveryConnection(
                    connectionID: excludedConnectionID,
                    runID: excludedRunID,
                    purpose: purpose,
                    authoritative: authoritative
                )

                await ServerNetworkManager.shared.removeConnection(
                    excludedConnectionID,
                    context: closeContext
                )

                XCTAssertNil(window.mcpServer.tabContextByConnectionID[excludedConnectionID])
                XCTAssertFalse(
                    window.mcpServer.isDetachedContextBuilderConnection(
                        connectionID: excludedConnectionID,
                        runID: excludedRunID
                    )
                )
                XCTAssertNil(window.mcpServer.contextBuilderFinalContextConnectionID(runID: excludedRunID))
                let excludedCommitOutcome = await window.mcpServer.commitContextBuilderTabContext(
                    connectionID: excludedConnectionID,
                    expectedRunID: excludedRunID,
                    isStillCurrent: { true }
                )
                XCTAssertEqual(
                    excludedCommitOutcome.outcome,
                    .missingFinalContext(
                        runID: excludedRunID,
                        connectionID: excludedConnectionID
                    )
                )
                window.mcpServer.removeTabContext(
                    forConnectionID: nil,
                    clientName: clientName,
                    windowID: window.windowID,
                    runID: excludedRunID
                )
            }

            try await assertDiscoveryCloseDetachesAndCommits(
                closeContext: MCPConnectionCloseContext(
                    reason: "server_shutdown",
                    initiator: .app
                ),
                prompt: "context retained after app/server shutdown"
            )
            try await assertDiscoveryCloseDetachesAndCommits(
                closeContext: MCPConnectionCloseContext(
                    reason: TerminationReason.runCancelled.rawValue,
                    initiator: .app
                ),
                prompt: "context retained after app cancellation close"
            )
            try await assertDiscoveryCloseDetachesAndCommits(
                closeContext: MCPConnectionCloseContext(
                    reason: MCPTransportTerminalCause.readError.rawValue,
                    initiator: .peer
                ),
                prompt: "context retained after read error"
            )
            try await assertDiscoveryCloseDetachesAndCommits(
                closeContext: MCPConnectionCloseContext(
                    reason: MCPTransportTerminalCause.writeHangup.rawValue,
                    initiator: .app
                ),
                prompt: "context retained after write hangup"
            )
            try await assertDiscoveryCloseDetachesAndCommits(
                closeContext: MCPConnectionCloseContext(
                    reason: MCPTransportTerminalCause.writeStall.rawValue,
                    initiator: .app
                ),
                prompt: "context retained after write stall"
            )
            try await assertDoesNotDetach(
                closeContext: MCPConnectionCloseContext(
                    reason: MCPTransportTerminalCause.peerEOF.rawValue,
                    initiator: .peer
                ),
                purpose: .agentModeRun
            )
            try await assertDoesNotDetach(
                closeContext: MCPConnectionCloseContext(
                    reason: MCPTransportTerminalCause.peerEOF.rawValue,
                    initiator: .peer
                ),
                purpose: .discoverRun,
                authoritative: false
            )

            let missingResult = MCPServerViewModel.ContextBuilderTabContextCommitResult(
                outcome: .missingFinalContext(
                    runID: cancelledRunID,
                    connectionID: cancelledConnectionID
                ),
                committedTab: nil
            )
            guard case let .failed(message) = ContextBuilderAgentViewModel.terminalOutcome(
                forContextCommitResult: missingResult
            ) else {
                return XCTFail("Missing final ownership must be classified as failed")
            }
            XCTAssertTrue(message.contains(cancelledRunID.uuidString))
            XCTAssertTrue(message.contains(cancelledConnectionID.uuidString))
            XCTAssertFalse(message.contains("Cancelled by user"))

            let terminationCount = await connection.terminationCount()
            let stopCount = await connection.stopCount()
            let cancelledTerminationCount = await cancelledConnection.terminationCount()
            let cancelledStopCount = await cancelledConnection.stopCount()
            XCTAssertEqual(terminationCount, 0)
            XCTAssertGreaterThanOrEqual(stopCount, 1)
            XCTAssertEqual(cancelledTerminationCount, 0)
            XCTAssertGreaterThanOrEqual(cancelledStopCount, 1)
        #else
            throw XCTSkip("Real MCP connection cleanup fixture is DEBUG-only.")
        #endif
    }

    func testLogicalReleaseAdmitsSuccessorAndRejectsOldEvents() {
        let registry = ContextBuilderRunRegistry()
        let tabID = UUID()
        let session = ContextBuilderAgentViewModel.TabSession(tabID: tabID)
        let firstOwnership = session.beginRunAttempt(source: "first")
        let first = makeRecord(tabID: tabID, session: session, ownership: firstOwnership)

        XCTAssertTrue(registry.register(first))
        XCTAssertTrue(registry.acceptsEvents(from: first, currentSession: session))
        let blocked = makeRecord(tabID: tabID, session: session, ownership: firstOwnership)
        XCTAssertFalse(registry.register(blocked))
        XCTAssertTrue(first.claimTerminal(.cancelled))
        XCTAssertTrue(registry.releaseActiveSlot(for: first))

        let secondOwnership = session.beginRunAttempt(source: "second")
        let second = makeRecord(tabID: tabID, session: session, ownership: secondOwnership)
        XCTAssertTrue(registry.register(second))
        XCTAssertFalse(registry.acceptsEvents(from: first, currentSession: session))
        XCTAssertTrue(registry.acceptsEvents(from: second, currentSession: session))
    }

    func testPendingTeardownDoesNotRetainActiveRunSlot() {
        let registry = ContextBuilderRunRegistry()
        let tabID = UUID()
        let session = ContextBuilderAgentViewModel.TabSession(tabID: tabID)
        let first = makeRecord(
            tabID: tabID,
            session: session,
            ownership: session.beginRunAttempt(source: "first")
        )
        let provider = LifecycleTestProvider()

        XCTAssertTrue(registry.register(first))
        XCTAssertTrue(first.installProvider(provider))
        XCTAssertTrue(first.claimTerminal(.cancelled))
        XCTAssertTrue(registry.releaseActiveSlot(for: first))

        let teardown = try? XCTUnwrap(first.beginTeardown())
        XCTAssertNotNil(teardown)
        XCTAssertTrue((teardown?.provider as AnyObject?) === provider)
        XCTAssertNil(first.beginTeardown())
        XCTAssertTrue(first.isTeardownPending)

        let second = makeRecord(
            tabID: tabID,
            session: session,
            ownership: session.beginRunAttempt(source: "second")
        )
        XCTAssertTrue(registry.register(second))

        first.markProviderDisposalFinished()
        XCTAssertTrue(first.isTeardownPending)
        first.markExecutionTaskFinished()
        XCTAssertFalse(first.isTeardownPending)
        XCTAssertTrue(registry.removeAfterTeardown(first))
        XCTAssertTrue(registry.acceptsEvents(from: second, currentSession: session))
    }

    func testStaleRunRetirementStillDisposesProviderAndCancelsExecution() async throws {
        #if DEBUG
            let previousMCPAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            let composition = WindowStateCompositionFactory.make(
                windowID: -176,
                deferredInitialAgentSystemWorkspaceRefresh: true,
                sharedMCPService: MCPService()
            )
            GlobalSettingsStore.shared.setMCPAutoStart(previousMCPAutoStart, commit: false)
            await composition.workspaceManager.awaitInitialized()
            defer {
                Task {
                    await composition.mcpServer.stopServer()
                    await composition.mcpServer.shutdownListener()
                }
            }

            let tabID = UUID()
            let session = ContextBuilderAgentViewModel.TabSession(tabID: tabID)
            let ownership = session.beginRunAttempt(source: "stale-retirement-test")
            let record = ContextBuilderRunRecord(
                runID: UUID(),
                tabID: tabID,
                session: session,
                ownership: ownership,
                origin: .mcp(controlToken: UUID()),
                agentKind: .claudeCode,
                modelRaw: AgentModel.defaultModel.rawValue
            )
            let providerDisposeFinished = expectation(description: "stale provider disposed")
            let provider = ControllableLifecycleTestProvider(
                eventTexts: [],
                blocksDisposal: false,
                disposeFinishedExpectation: providerDisposeFinished
            )
            XCTAssertTrue(record.installProvider(provider))

            let executionCancelled = LifecycleTestGate()
            let executionTask = Task<Void, Never> {
                await withTaskCancellationHandler {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(10))
                    }
                } onCancel: {
                    Task { await executionCancelled.arrive() }
                }
            }
            record.executionTask = executionTask

            composition.contextBuilderAgentViewModel.retireStaleRunRecordForTesting(
                record,
                waiterResolution: .snapshot,
                cancelExecution: true
            )

            await executionCancelled.waitUntilArrived()
            await executionTask.value
            await fulfillment(of: [providerDisposeFinished], timeout: 1)
            for _ in 0 ..< 100 where record.teardownFinishedAt == nil {
                await Task.yield()
            }

            let disposeCallCount = await provider.disposeCallCount()
            XCTAssertEqual(disposeCallCount, 1)
            XCTAssertTrue(record.providerDisposalFinished)
            XCTAssertTrue(record.executionTaskFinished)
            XCTAssertNotNil(record.teardownFinishedAt)
            XCTAssertTrue(record.isTerminal)
        #else
            throw XCTSkip("Stale run retirement test uses DEBUG-only test hook.")
        #endif
    }

    func testProductionMCPCancellationResumesBeforeTeardownAndRejectsLateProviderEvent() async throws {
        let configRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContextBuilderStaleRunLeaseTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: configRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: configRoot) }
        let configService = MCPConfigExportService(
            configDirectoryURL: configRoot,
            renderServerConfig: { "{\"mcpServers\":{}}" }
        )
        let firstConfigLease = try await configService.prepareLaunchConfig()
        let firstConfigURL = firstConfigLease.url
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstConfigURL.path))

        let firstStreamStarted = expectation(description: "first provider stream started")
        let firstEventAccepted = expectation(description: "first provider event accepted")
        let firstDisposeStarted = expectation(description: "first provider disposal started")
        let firstDisposeFinished = expectation(description: "first provider disposal finished")
        let firstTeardownCompleted = expectation(description: "first run teardown completed")
        let successorStreamStarted = expectation(description: "successor provider stream started")
        let successorEventAccepted = expectation(description: "successor provider event accepted")
        let successorRouteSettled = expectation(description: "successor route settled and replay completed")
        let lateEventParked = expectation(description: "late provider event parked before processing")
        let lateEventRejected = expectation(description: "late provider event rejected")
        let firstProvider = ControllableLifecycleTestProvider(
            eventTexts: ["first-run-event", "late-old-run-event"],
            blocksDisposal: true,
            streamStartedExpectation: firstStreamStarted,
            disposeStartedExpectation: firstDisposeStarted,
            disposeFinishedExpectation: firstDisposeFinished,
            configLease: firstConfigLease
        )
        let successorProvider = ControllableLifecycleTestProvider(
            eventTexts: ["successor-event"],
            blocksDisposal: false,
            streamStartedExpectation: successorStreamStarted
        )
        let providers = LifecycleTestProviderQueue([firstProvider, successorProvider])
        let previousMCPEnabled = await ServerNetworkManager.shared.debugIsEnabledForBootstrapSocketURLOverride()

        let previousMCPAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let testMCPService = MCPService()
        let composition = WindowStateCompositionFactory.make(
            windowID: -74,
            deferredInitialAgentSystemWorkspaceRefresh: true,
            sharedMCPService: testMCPService,
            contextBuilderProviderFactory: { _, _, _ in providers.next() }
        )
        GlobalSettingsStore.shared.setMCPAutoStart(previousMCPAutoStart, commit: false)
        await composition.workspaceManager.awaitInitialized()

        do {
            let workspaceRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("ContextBuilderRunLifecycleTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(
                at: workspaceRoot,
                withIntermediateDirectories: true
            )
            defer {
                try? FileManager.default.removeItem(at: workspaceRoot)
            }

            let workspace = composition.workspaceManager.createWorkspace(
                name: "Context Builder lifecycle test",
                repoPaths: [workspaceRoot.path],
                ephemeral: true
            )
            await composition.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "ContextBuilderRunLifecycleTests"
            )

            let activeWorkspace = try XCTUnwrap(composition.workspaceManager.activeWorkspace)
            ContextBuilderTestReadinessSupport.seedCanonicalProviderReadiness(
                apiSettingsViewModel: composition.apiSettingsViewModel,
                workspaceID: activeWorkspace.id
            )
            let tabID = try XCTUnwrap(
                activeWorkspace.activeComposeTabID ?? activeWorkspace.composeTabs.first?.id
            )
            let viewModel = composition.contextBuilderAgentViewModel
            let lateEventGate = LifecycleTestGate()
            let firstWaiterCompletion = LifecycleTestCounter()
            var firstRunID: UUID?

            viewModel.installRunTestHooks(
                ContextBuilderAgentViewModel.RunTestHooks(
                    beforeProcessingProviderEvent: { result, _ in
                        if result.text == "late-old-run-event" {
                            lateEventParked.fulfill()
                            await lateEventGate.arriveAndWait()
                        }
                    },
                    providerEventDisposition: { result, _, accepted in
                        switch (result.text, accepted) {
                        case ("first-run-event", true):
                            firstEventAccepted.fulfill()
                        case ("successor-event", true):
                            successorEventAccepted.fulfill()
                        case ("late-old-run-event", false):
                            lateEventRejected.fulfill()
                        default:
                            break
                        }
                    },
                    teardownCompleted: { runID in
                        if runID == firstRunID {
                            firstTeardownCompleted.fulfill()
                        }
                    }
                )
            )
            defer {
                viewModel.installRunTestHooks(nil)
                Task {
                    await lateEventGate.release()
                    await firstProvider.releaseDisposal()
                }
            }

            let firstToken = try viewModel.beginMCPControlledRun(
                forTabID: tabID,
                responseType: nil,
                planModelName: nil
            )
            let firstWaiterFinished = expectation(description: "first MCP waiter finished")
            let firstWaiter = Task<Bool, Never> { @MainActor in
                let wasCancelled: Bool
                do {
                    _ = try await viewModel.runContextBuilderForMCP(
                        tabID: tabID,
                        mcpControlToken: firstToken
                    )
                    wasCancelled = false
                } catch is CancellationError {
                    wasCancelled = true
                } catch {
                    XCTFail("Unexpected first-run error: \(error)")
                    wasCancelled = false
                }
                await firstWaiterCompletion.increment()
                firstWaiterFinished.fulfill()
                return wasCancelled
            }

            await fulfillment(
                of: [firstStreamStarted, firstEventAccepted, lateEventParked],
                timeout: 2
            )
            firstRunID = try XCTUnwrap(viewModel.activeRunIDForTesting(tabID: tabID))

            // Replace the tab session to model a superseding owner while the original
            // provider stream remains parked. Cancellation by run ID must eagerly retire
            // the registered stale record instead of waiting for another provider event.
            viewModel.replaceSessionForTesting(tabID: tabID)
            try await viewModel.cancelMCPContextBuilderRun(runID: XCTUnwrap(firstRunID))
            await fulfillment(of: [firstWaiterFinished, firstDisposeStarted], timeout: 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: firstConfigURL.path))

            let firstWaiterWasCancelled = await firstWaiter.value
            let firstCompletionCount = await firstWaiterCompletion.value()
            XCTAssertTrue(firstWaiterWasCancelled)
            XCTAssertEqual(firstCompletionCount, 1)
            XCTAssertNil(viewModel.activeRunIDForTesting(tabID: tabID))
            XCTAssertTrue(try viewModel.isRunTeardownPendingForTesting(runID: XCTUnwrap(firstRunID)))

            let successorToken = try viewModel.beginMCPControlledRun(
                forTabID: tabID,
                responseType: nil,
                planModelName: nil
            )
            let successorWaiterFinished = expectation(description: "successor MCP waiter finished")
            let successorWaiter = Task<Bool, Never> { @MainActor in
                let wasCancelled: Bool
                do {
                    _ = try await viewModel.runContextBuilderForMCP(
                        tabID: tabID,
                        mcpControlToken: successorToken,
                        progressReporter: { phase in
                            guard phase == .providerStreamActive else { return }
                            successorRouteSettled.fulfill()
                        }
                    )
                    wasCancelled = false
                } catch is CancellationError {
                    wasCancelled = true
                } catch {
                    XCTFail("Unexpected successor error: \(error)")
                    wasCancelled = false
                }
                successorWaiterFinished.fulfill()
                return wasCancelled
            }

            await fulfillment(
                of: [successorStreamStarted, successorEventAccepted, successorRouteSettled],
                timeout: 2
            )
            let successorRunID = try XCTUnwrap(viewModel.activeRunIDForTesting(tabID: tabID))
            XCTAssertNotEqual(successorRunID, firstRunID)
            XCTAssertTrue(try viewModel.isRunTeardownPendingForTesting(runID: XCTUnwrap(firstRunID)))
            let disposalFinishedBeforeLateEvent = await firstProvider.isDisposalFinished()
            XCTAssertFalse(disposalFinishedBeforeLateEvent)

            await lateEventGate.release()
            await fulfillment(of: [lateEventRejected], timeout: 1)

            let completionCountAfterLateEvent = await firstWaiterCompletion.value()
            XCTAssertEqual(completionCountAfterLateEvent, 1)
            XCTAssertFalse(viewModel.agentLog.contains { $0.message.contains("late-old-run-event") })
            XCTAssertTrue(viewModel.agentLog.contains { $0.message.contains("successor-event") })
            XCTAssertEqual(viewModel.activeRunIDForTesting(tabID: tabID), successorRunID)
            XCTAssertTrue(try viewModel.isRunTeardownPendingForTesting(runID: XCTUnwrap(firstRunID)))
            let disposalFinishedBeforeRelease = await firstProvider.isDisposalFinished()
            XCTAssertFalse(disposalFinishedBeforeRelease)

            await firstProvider.releaseDisposal()
            await fulfillment(of: [firstDisposeFinished, firstTeardownCompleted], timeout: 1)
            XCTAssertFalse(try viewModel.isRunTeardownPendingForTesting(runID: XCTUnwrap(firstRunID)))

            await viewModel.cancelMCPContextBuilderRun(runID: successorRunID)
            await fulfillment(of: [successorWaiterFinished], timeout: 1)
            let successorWasCancelled = await successorWaiter.value
            XCTAssertTrue(successorWasCancelled)

            await composition.mcpServer.stopServer()
            await composition.mcpServer.shutdownListener()
            await ServerNetworkManager.shared.setEnabled(previousMCPEnabled)
        } catch {
            await composition.mcpServer.stopServer()
            await composition.mcpServer.shutdownListener()
            await ServerNetworkManager.shared.setEnabled(previousMCPEnabled)
            throw error
        }
    }

    func testMCPRoutingFailureAfterImmediateStreamReturnCleansBootstrapAndAllowsImmediateRetry() async throws {
        #if DEBUG
            let oldProcess = try makeSleepingProcessTree()
            let retryProcess = try makeSleepingProcessTree()
            defer {
                oldProcess.terminate()
                retryProcess.terminate()
            }
            let clientName = AgentProviderKind.codexExec.mcpClientNameHint ?? AgentProviderKind.codexMCPClientID
            let blockedProvider = CodexShapedBlockedRoutingTestProvider()
            let retryProvider = PIDOwnedRetryRoutingTestProvider(
                clientName: clientName,
                expectedParentPID: retryProcess.parentPID,
                connectionPID: retryProcess.childPID
            )
            let providers = LifecycleTestProviderQueue([blockedProvider, retryProvider])
            let previousMCPEnabled = await ServerNetworkManager.shared.debugIsEnabledForBootstrapSocketURLOverride()

            await HeadlessAgentConnectionGate.cancelAll()
            let previousMCPAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            let composition = WindowStateCompositionFactory.make(
                windowID: -75,
                deferredInitialAgentSystemWorkspaceRefresh: true,
                sharedMCPService: MCPService(),
                contextBuilderProviderFactory: { _, _, _ in providers.next() }
            )
            GlobalSettingsStore.shared.setMCPAutoStart(previousMCPAutoStart, commit: false)
            await composition.workspaceManager.awaitInitialized()
            var firstRunID: UUID?
            var retryRunID: UUID?
            let lateConnectionID = UUID()

            do {
                let workspaceRoot = FileManager.default.temporaryDirectory
                    .appendingPathComponent("ContextBuilderMCPRoutingFailureTests-\(UUID().uuidString)")
                try FileManager.default.createDirectory(
                    at: workspaceRoot,
                    withIntermediateDirectories: true
                )
                defer {
                    try? FileManager.default.removeItem(at: workspaceRoot)
                }

                let workspace = composition.workspaceManager.createWorkspace(
                    name: "Context Builder MCP routing failure test",
                    repoPaths: [workspaceRoot.path],
                    ephemeral: true
                )
                await composition.workspaceManager.switchWorkspace(
                    to: workspace,
                    saveState: false,
                    reason: "ContextBuilderRunLifecycleTests.mcpRoutingFailure"
                )

                let activeWorkspace = try XCTUnwrap(composition.workspaceManager.activeWorkspace)
                let tabID = try XCTUnwrap(
                    activeWorkspace.activeComposeTabID ?? activeWorkspace.composeTabs.first?.id
                )
                ContextBuilderTestReadinessSupport.seedCanonicalProviderReadiness(
                    apiSettingsViewModel: composition.apiSettingsViewModel,
                    workspaceID: activeWorkspace.id,
                    agent: .codexExec,
                    modelRaw: AgentModel.gpt55CodexLow.rawValue
                )

                let viewModel = composition.contextBuilderAgentViewModel
                let savedAgent = viewModel.selectedAgent
                let savedModelRaw = viewModel.selectedModelRaw
                viewModel.selectedAgent = .codexExec
                defer {
                    viewModel.selectedAgent = savedAgent
                    viewModel.selectModel(rawModel: savedModelRaw)
                }

                let firstTeardownCompleted = expectation(description: "failed provider teardown completed")
                viewModel.installRunTestHooks(
                    ContextBuilderAgentViewModel.RunTestHooks(
                        beforeProcessingProviderEvent: nil,
                        providerEventDisposition: nil,
                        teardownCompleted: { runID in
                            if runID == firstRunID {
                                firstTeardownCompleted.fulfill()
                            }
                        }
                    )
                )
                defer {
                    viewModel.installRunTestHooks(nil)
                }

                let firstToken = try viewModel.beginMCPControlledRun(
                    forTabID: tabID,
                    responseType: nil,
                    planModelName: nil
                )
                let firstWaiter = Task { @MainActor in
                    try await viewModel.runContextBuilderForMCP(
                        tabID: tabID,
                        mcpControlToken: firstToken
                    )
                }

                await blockedProvider.waitUntilInternalStartupEntered()
                firstRunID = try XCTUnwrap(viewModel.activeRunIDForTesting(tabID: tabID))
                let failedRunID = try XCTUnwrap(firstRunID)
                await ServerNetworkManager.shared.registerExpectedAgentPID(
                    oldProcess.parentPID,
                    for: clientName,
                    runID: failedRunID
                )
                let routingWaiterRegistered = await waitForRoutingWaiter(runID: failedRunID)
                XCTAssertTrue(routingWaiterRegistered)
                await MCPRoutingWaiter.notifyFailed(runID: failedRunID)

                let firstSnapshot = try await firstWaiter.value
                guard case let .failed(firstError) = firstSnapshot.runState else {
                    XCTFail("Expected MCP routing failure, got \(firstSnapshot.runState)")
                    throw MCPRoutingFailureTestError.unexpectedRunState
                }
                XCTAssertTrue(firstError.hasPrefix("mcp_routing_failed:"))
                XCTAssertTrue(firstError.contains("codex-mcp-client"))
                XCTAssertEqual(firstSnapshot.runID, failedRunID)

                await blockedProvider.waitUntilInternalStartupCancellationObserved()
                await blockedProvider.waitUntilDisposalStarted()
                let startupCancellationCount = await blockedProvider.internalStartupCancellationCount()
                let disposeCallCount = await blockedProvider.disposeCallCount()
                let internalStartupCompleted = await blockedProvider.internalStartupCompleted()
                let activeGateID = await HeadlessAgentConnectionGate.shared.debugActiveConnectionID()
                let waitingGateCount = await HeadlessAgentConnectionGate.shared.debugWaitingCount()
                let routingWaiterCount = await MCPRoutingWaiter.debugContinuationCount(runID: failedRunID)
                XCTAssertEqual(startupCancellationCount, 1)
                XCTAssertEqual(disposeCallCount, 1)
                XCTAssertFalse(internalStartupCompleted)
                XCTAssertNil(viewModel.activeRunIDForTesting(tabID: tabID))
                XCTAssertTrue(viewModel.isRunTeardownPendingForTesting(runID: failedRunID))
                XCTAssertNil(activeGateID)
                XCTAssertEqual(waitingGateCount, 0)
                XCTAssertEqual(routingWaiterCount, 0)
                let pendingPoliciesAfterFailure = await ServerNetworkManager.shared.debugPendingPolicySnapshot(
                    for: clientName
                )
                XCTAssertFalse(pendingPoliciesAfterFailure.contains { $0.runID == failedRunID })

                let retryToken = try viewModel.beginMCPControlledRun(
                    forTabID: tabID,
                    responseType: nil,
                    planModelName: nil
                )
                let retryWaiter = Task { @MainActor in
                    try await viewModel.runContextBuilderForMCP(
                        tabID: tabID,
                        mcpControlToken: retryToken
                    )
                }

                await retryProvider.waitUntilConnectionAttemptReady()
                retryRunID = try XCTUnwrap(viewModel.activeRunIDForTesting(tabID: tabID))
                let successorRunID = try XCTUnwrap(retryRunID)
                await ServerNetworkManager.shared.debugRegisterConnectionForSocketFixture(
                    connectionID: retryProvider.connectionID,
                    connection: ContextBuilderCleanupTestConnection(),
                    clientName: clientName,
                    sessionToken: UUID().uuidString
                )
                try composition.mcpServer.bindTabForConnection(
                    connectionID: retryProvider.connectionID,
                    clientName: clientName,
                    tabID: tabID,
                    workspaceID: activeWorkspace.id,
                    windowID: composition.mcpServer.windowID,
                    runID: successorRunID
                )
                let lateOldProviderConnection = await ServerNetworkManager.shared.debugApplyPendingPolicy(
                    clientName: clientName,
                    connectionID: lateConnectionID,
                    clientPid: Int(oldProcess.childPID),
                    bootstrapClientName: "repoprompt_ce_cli_debug",
                    pidGateTimeout: 0.05,
                    requireRunRouting: false
                )
                XCTAssertEqual(lateOldProviderConnection.outcome, "rejected:ownership_timeout")
                XCTAssertEqual(lateOldProviderConnection.runID, successorRunID)
                let lateMappedRunID = await ServerNetworkManager.shared.runIDForConnection(lateConnectionID)
                XCTAssertNil(lateMappedRunID)
                let pendingPoliciesAfterLateOldConnection = await ServerNetworkManager.shared.debugPendingPolicySnapshot(
                    for: clientName
                )
                XCTAssertTrue(pendingPoliciesAfterLateOldConnection.contains { $0.runID == successorRunID })

                await retryProvider.releaseConnectionAttempt()
                let retrySnapshot = try await retryWaiter.value
                let retryPolicyApplication = await retryProvider.policyApplicationResult()

                XCTAssertEqual(retryPolicyApplication?.outcome, "applied")
                XCTAssertEqual(retryPolicyApplication?.runID, successorRunID)
                XCTAssertEqual(retrySnapshot.runState, .completed)
                XCTAssertEqual(retrySnapshot.agentOutput, "retry-success")
                XCTAssertEqual(retrySnapshot.runID, successorRunID)
                XCTAssertNotEqual(retrySnapshot.runID, failedRunID)
                XCTAssertTrue(viewModel.isRunTeardownPendingForTesting(runID: failedRunID))
                let disposeCallCountAfterRetry = await blockedProvider.disposeCallCount()
                XCTAssertEqual(disposeCallCountAfterRetry, 1)

                await blockedProvider.releaseDisposal()
                await blockedProvider.waitUntilDisposalFinished()
                await fulfillment(of: [firstTeardownCompleted], timeout: 1)
                XCTAssertFalse(viewModel.isRunTeardownPendingForTesting(runID: failedRunID))

                await ServerNetworkManager.shared.clearExpectedAgentPID(
                    oldProcess.parentPID,
                    for: clientName,
                    runID: failedRunID
                )
                await ServerNetworkManager.shared.clearExpectedAgentPID(
                    retryProcess.parentPID,
                    for: clientName,
                    runID: successorRunID
                )
                await ServerNetworkManager.shared.removeConnection(lateConnectionID)
                await ServerNetworkManager.shared.removeConnection(retryProvider.connectionID)
                await composition.mcpServer.stopServer()
                await composition.mcpServer.shutdownListener()
                await ServerNetworkManager.shared.setEnabled(previousMCPEnabled)
            } catch {
                await blockedProvider.releaseInternalStartup()
                await blockedProvider.releaseDisposal()
                await retryProvider.releaseConnectionAttempt()
                if let firstRunID {
                    await ServerNetworkManager.shared.clearExpectedAgentPID(
                        oldProcess.parentPID,
                        for: clientName,
                        runID: firstRunID
                    )
                }
                if let retryRunID {
                    await ServerNetworkManager.shared.clearExpectedAgentPID(
                        retryProcess.parentPID,
                        for: clientName,
                        runID: retryRunID
                    )
                }
                await ServerNetworkManager.shared.removeConnection(lateConnectionID)
                await ServerNetworkManager.shared.removeConnection(retryProvider.connectionID)
                await composition.mcpServer.stopServer()
                await composition.mcpServer.shutdownListener()
                await ServerNetworkManager.shared.setEnabled(previousMCPEnabled)
                throw error
            }
        #else
            throw XCTSkip("MCP routing failure lifecycle inspection is DEBUG-only.")
        #endif
    }

    private func waitForRoutingWaiter(runID: UUID) async -> Bool {
        for _ in 0 ..< 1000 {
            if await MCPRoutingWaiter.debugContinuationCount(runID: runID) == 1 {
                return true
            }
            await Task.yield()
        }
        return false
    }

    #if DEBUG
        private struct SleepingProcessTree {
            let parent: Process
            let childPID: pid_t
            let parentExited: DispatchSemaphore

            var parentPID: pid_t {
                parent.processIdentifier
            }

            func terminate() {
                _ = Darwin.kill(childPID, SIGTERM)
                _ = Darwin.kill(parentPID, SIGTERM)
                guard parentExited.wait(timeout: .now() + 0.25) == .timedOut else {
                    parent.waitUntilExit()
                    return
                }

                _ = Darwin.kill(childPID, SIGKILL)
                _ = Darwin.kill(parentPID, SIGKILL)
                if parentExited.wait(timeout: .now() + 1.0) == .success {
                    parent.waitUntilExit()
                }
            }
        }

        private func makeSleepingProcessTree() throws -> SleepingProcessTree {
            let process = Process()
            let stdout = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [
                "python3",
                "-c",
                "import subprocess; child=subprocess.Popen(['/bin/sleep','30']); print(child.pid, flush=True); child.wait()"
            ]
            process.standardOutput = stdout
            let parentExited = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in parentExited.signal() }
            try process.run()
            var data = Data()
            while data.count < 32 {
                guard let byte = try stdout.fileHandleForReading.read(upToCount: 1), !byte.isEmpty else { break }
                if byte == Data([0x0A]) { break }
                data.append(byte)
            }
            guard let text = String(data: data, encoding: .utf8),
                  let childPID = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
            else {
                process.terminate()
                process.waitUntilExit()
                throw NSError(
                    domain: "ContextBuilderRunLifecycleTests",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to read child PID from process-tree fixture."]
                )
            }
            return SleepingProcessTree(parent: process, childPID: childPID, parentExited: parentExited)
        }
    #endif

    private func makeRecord(
        tabID: UUID,
        session: ContextBuilderAgentViewModel.TabSession,
        ownership: AgentRunOwnership
    ) -> ContextBuilderRunRecord {
        ContextBuilderRunRecord(
            runID: UUID(),
            tabID: tabID,
            session: session,
            ownership: ownership,
            origin: .ui,
            agentKind: .claudeCode,
            modelRaw: AgentModel.defaultModel.rawValue
        )
    }
}

private final class LifecycleTestProvider: HeadlessAgentProvider {
    func streamAgentMessage(
        _ message: AgentMessage,
        runID: UUID?
    ) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func dispose() async {}
}

private final class ControllableLifecycleTestProvider: HeadlessAgentProvider {
    private let eventTexts: [String]
    private let blocksDisposal: Bool
    private let streamStartedExpectation: XCTestExpectation?
    private let disposeStartedExpectation: XCTestExpectation?
    private let disposeFinishedExpectation: XCTestExpectation?
    private let configLease: MCPConfigLease?
    private let disposeGate = LifecycleTestGate()
    private let state = LifecycleTestProviderState()
    private var streamContinuation: AsyncThrowingStream<AIStreamResult, Error>.Continuation?

    init(
        eventTexts: [String],
        blocksDisposal: Bool,
        streamStartedExpectation: XCTestExpectation? = nil,
        disposeStartedExpectation: XCTestExpectation? = nil,
        disposeFinishedExpectation: XCTestExpectation? = nil,
        configLease: MCPConfigLease? = nil
    ) {
        self.eventTexts = eventTexts
        self.blocksDisposal = blocksDisposal
        self.streamStartedExpectation = streamStartedExpectation
        self.disposeStartedExpectation = disposeStartedExpectation
        self.disposeFinishedExpectation = disposeFinishedExpectation
        self.configLease = configLease
    }

    func streamAgentMessage(
        _ message: AgentMessage,
        runID: UUID?
    ) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
        _ = message
        guard let runID else {
            throw CancellationError()
        }
        let stream = AsyncThrowingStream<AIStreamResult, Error> { continuation in
            streamContinuation = continuation
            for text in eventTexts {
                continuation.yield(AIStreamResult(type: "content", text: text))
            }
        }
        await MCPRoutingWaiter.notifyRouted(runID: runID)
        streamStartedExpectation?.fulfill()
        return stream
    }

    func dispose() async {
        await state.recordDisposeCall()
        configLease?.release()
        disposeStartedExpectation?.fulfill()
        if blocksDisposal {
            await disposeGate.arriveAndWait()
        }
        streamContinuation?.finish()
        streamContinuation = nil
        await state.recordDisposalFinished()
        disposeFinishedExpectation?.fulfill()
    }

    func releaseDisposal() async {
        await disposeGate.release()
    }

    func disposeCallCount() async -> Int {
        await state.disposeCallCount
    }

    func isDisposalFinished() async -> Bool {
        await state.disposalFinished
    }
}

@MainActor
private final class LifecycleTestProviderQueue {
    private var providers: [HeadlessAgentProvider]

    init(_ providers: [HeadlessAgentProvider]) {
        self.providers = providers
    }

    func next() -> HeadlessAgentProvider {
        precondition(!providers.isEmpty, "Unexpected Context Builder provider request")
        return providers.removeFirst()
    }
}

private actor LifecycleTestProviderState {
    private(set) var disposeCallCount = 0
    private(set) var disposalFinished = false

    func recordDisposeCall() {
        disposeCallCount += 1
    }

    func recordDisposalFinished() {
        disposalFinished = true
    }
}

private actor LifecycleTestCounter {
    private var count = 0

    func increment() {
        count += 1
    }

    func value() -> Int {
        count
    }
}

private actor LifecycleTestGate {
    private var arrived = false
    private var released = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func arrive() {
        arrived = true
        let waiters = arrivalWaiters
        arrivalWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func arriveAndWait() async {
        arrive()
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilArrived() async {
        guard !arrived else { return }
        await withCheckedContinuation { continuation in
            arrivalWaiters.append(continuation)
        }
    }

    func release() {
        guard !released else { return }
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private final class CodexShapedBlockedRoutingTestProvider: HeadlessAgentProvider {
    private let internalStartupEntered = LifecycleTestGate()
    private let internalStartupBlock = LifecycleTestGate()
    private let internalStartupCancellationObserved = LifecycleTestGate()
    private let disposalStarted = LifecycleTestGate()
    private let disposalBlock = LifecycleTestGate()
    private let disposalFinished = LifecycleTestGate()
    private let state = CodexShapedBlockedRoutingTestState()
    private var internalStartupTask: Task<Void, Never>?
    private var streamContinuation: AsyncThrowingStream<AIStreamResult, Error>.Continuation?

    func streamAgentMessage(
        _ message: AgentMessage,
        runID: UUID?
    ) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
        _ = message
        _ = runID
        return AsyncThrowingStream { continuation in
            streamContinuation = continuation
            internalStartupTask = Task { [weak self] in
                guard let self else { return }
                await withTaskCancellationHandler {
                    await internalStartupEntered.arrive()
                    await internalStartupBlock.arriveAndWait()
                    guard !Task.isCancelled else { return }
                    await state.recordInternalStartupCompleted()
                    continuation.finish()
                } onCancel: {
                    Task { [weak self] in
                        guard let self else { return }
                        await state.recordInternalStartupCancellation()
                        await internalStartupCancellationObserved.arrive()
                        continuation.finish()
                    }
                }
            }
            continuation.onTermination = { [weak self] _ in
                self?.internalStartupTask?.cancel()
            }
        }
    }

    func dispose() async {
        await state.recordDisposeCall()
        internalStartupTask?.cancel()
        await internalStartupCancellationObserved.waitUntilArrived()
        await internalStartupBlock.release()
        await disposalStarted.arrive()
        await disposalBlock.arriveAndWait()
        streamContinuation?.finish()
        streamContinuation = nil
        await internalStartupTask?.value
        internalStartupTask = nil
        await state.recordDisposalFinished()
        await disposalFinished.arrive()
    }

    func waitUntilInternalStartupEntered() async {
        await internalStartupEntered.waitUntilArrived()
    }

    func waitUntilInternalStartupCancellationObserved() async {
        await internalStartupCancellationObserved.waitUntilArrived()
    }

    func waitUntilDisposalStarted() async {
        await disposalStarted.waitUntilArrived()
    }

    func waitUntilDisposalFinished() async {
        await disposalFinished.waitUntilArrived()
    }

    func releaseInternalStartup() async {
        internalStartupTask?.cancel()
        await internalStartupBlock.release()
    }

    func releaseDisposal() async {
        await disposalBlock.release()
    }

    func internalStartupCancellationCount() async -> Int {
        await state.internalStartupCancellationCount
    }

    func internalStartupCompleted() async -> Bool {
        await state.internalStartupCompleted
    }

    func disposeCallCount() async -> Int {
        await state.disposeCallCount
    }
}

private final class PIDOwnedRetryRoutingTestProvider: HeadlessAgentProvider {
    struct PolicyApplicationResult {
        let outcome: String
        let runID: UUID?
    }

    let connectionID = UUID()
    private let clientName: String
    private let expectedParentPID: pid_t
    private let connectionPID: pid_t
    private let connectionAttemptReady = LifecycleTestGate()
    private let connectionAttemptRelease = LifecycleTestGate()
    private let state = PIDOwnedRetryRoutingTestState()

    init(clientName: String, expectedParentPID: pid_t, connectionPID: pid_t) {
        self.clientName = clientName
        self.expectedParentPID = expectedParentPID
        self.connectionPID = connectionPID
    }

    func streamAgentMessage(
        _ message: AgentMessage,
        runID: UUID?
    ) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
        _ = message
        guard let runID else { throw CancellationError() }
        await connectionAttemptReady.arrive()
        await connectionAttemptRelease.arriveAndWait()
        #if DEBUG
            await ServerNetworkManager.shared.registerExpectedAgentPID(
                expectedParentPID,
                for: clientName,
                runID: runID
            )
            let result = await ServerNetworkManager.shared.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: connectionID,
                clientPid: Int(connectionPID),
                bootstrapClientName: "repoprompt_ce_cli_debug",
                pidGateTimeout: 0.25,
                requireRunRouting: false
            )
            await state.record(
                PolicyApplicationResult(outcome: result.outcome, runID: result.runID)
            )
            if result.outcome == "applied", result.runID == runID {
                await MCPRoutingWaiter.notifyRouted(runID: runID)
            } else {
                await MCPRoutingWaiter.notifyFailed(runID: runID)
            }
        #else
            throw CancellationError()
        #endif
        return AsyncThrowingStream { continuation in
            continuation.yield(AIStreamResult(type: "content", text: "retry-success"))
            continuation.finish()
        }
    }

    func dispose() async {}

    func waitUntilConnectionAttemptReady() async {
        await connectionAttemptReady.waitUntilArrived()
    }

    func releaseConnectionAttempt() async {
        await connectionAttemptRelease.release()
    }

    func policyApplicationResult() async -> PolicyApplicationResult? {
        await state.result
    }
}

private actor PIDOwnedRetryRoutingTestState {
    private(set) var result: PIDOwnedRetryRoutingTestProvider.PolicyApplicationResult?

    func record(_ result: PIDOwnedRetryRoutingTestProvider.PolicyApplicationResult) {
        self.result = result
    }
}

private actor CodexShapedBlockedRoutingTestState {
    private(set) var internalStartupCancellationCount = 0
    private(set) var internalStartupCompleted = false
    private(set) var disposeCallCount = 0
    private(set) var disposalFinished = false

    func recordInternalStartupCancellation() {
        internalStartupCancellationCount += 1
    }

    func recordInternalStartupCompleted() {
        internalStartupCompleted = true
    }

    func recordDisposeCall() {
        disposeCallCount += 1
    }

    func recordDisposalFinished() {
        disposalFinished = true
    }
}

private actor ContextBuilderCleanupTestConnection: MCPServerConnection {
    private var terminations = 0
    private var stops = 0
    private var deliverySnapshots: [MCPResponseDeliverySnapshot] = []

    init(
        pendingRequestCount: Int? = nil,
        subsequentPendingRequestCount: Int? = nil
    ) {
        deliverySnapshots = [pendingRequestCount, subsequentPendingRequestCount].compactMap { count in
            count.map {
                MCPResponseDeliverySnapshot(
                    pendingRequestCount: $0,
                    waiterCount: 0,
                    isTerminal: true
                )
            }
        }
    }

    nonisolated var isFilesystemBacked: Bool {
        false
    }

    nonisolated var connectionFolderURL: URL? {
        nil
    }

    nonisolated var capabilityToken: String? {
        nil
    }

    func start(approvalHandler _: @escaping (MCP.Client.Info) async -> Bool) async throws {
        // No transport startup is required for the cleanup fixture.
    }

    func stop() async {
        stops += 1
    }

    func abortForExecutionWatchdog() async {
        // The fixture does not execute tools.
    }

    func notifyToolListChanged() async {
        // The fixture has no client transport.
    }

    func connectionState() -> ConnectionStateSnapshot {
        .ready
    }

    func isViableForRetention() -> Bool {
        true
    }

    func secondsSinceLastActivity() async -> TimeInterval {
        0
    }

    func transportIngressSnapshot() async -> MCPTransportIngressSnapshot? {
        nil
    }

    func responseDeliverySnapshot() async -> MCPResponseDeliverySnapshot? {
        guard deliverySnapshots.count > 1 else { return deliverySnapshots.first }
        return deliverySnapshots.removeFirst()
    }

    func terminate(reason _: TerminationReason, message _: String?) async {
        terminations += 1
    }

    func sendProgress(
        tool _: String,
        kind _: RepoPromptProgressKind,
        stage _: String,
        message _: String
    ) async {
        // The fixture has no client transport.
    }

    func terminationCount() -> Int {
        terminations
    }

    func stopCount() -> Int {
        stops
    }
}

private enum MCPRoutingFailureTestError: Error {
    case unexpectedRunState
}
