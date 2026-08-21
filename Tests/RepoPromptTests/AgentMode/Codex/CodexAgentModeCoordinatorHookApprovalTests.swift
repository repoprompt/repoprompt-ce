import Foundation
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

@MainActor
final class CodexAgentModeCoordinatorHookApprovalTests: XCTestCase {
    func testHookDiscoveryPrecedesFirstTurnAndDoesNotRunAtBindingTime() async throws {
        let controller = try HookApprovalFakeCodexController(
            listResults: [.success(inventory(hooks: []))]
        )
        let (viewModel, session) = makeSession(controller: controller)

        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(controller.operations, [])

        let outcome = await send(on: viewModel, session: session)

        XCTAssertEqual(outcome, .sent)
        XCTAssertEqual(controller.operations, ["list", "start"])
        XCTAssertNil(session.pendingCodexHookReview)
    }

    func testConcurrentInitialGateEntrantsShareOneDiscoveryAndReview() async throws {
        let discoveryGate = HookApprovalAsyncGate()
        let controller = try HookApprovalFakeCodexController(
            listResults: [.success(inventory(hooks: [hook(key: "alpha")]))],
            listGate: discoveryGate
        )
        let (viewModel, session) = makeSession(controller: controller)

        let firstGate = Task {
            try await viewModel.test_codexCoordinator.test_gateFirstTurnForProjectHooks(
                session: session,
                controller: controller
            )
        }
        try await discoveryGate.waitUntilWaiting()
        let secondGate = Task {
            try await viewModel.test_codexCoordinator.test_gateFirstTurnForProjectHooks(
                session: session,
                controller: controller
            )
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(controller.listCount, 1)
        XCTAssertEqual(session.codexHookGateGeneration, 1)

        await discoveryGate.release()
        let request = try await waitForRequest(session)
        XCTAssertEqual(session.pendingCodexHookReview?.id, request.id)
        try await continueWithoutHooks(request, session: session, viewModel: viewModel)

        try await firstGate.value
        try await secondGate.value
        XCTAssertEqual(controller.operations, ["list"])
        XCTAssertNil(session.pendingCodexHookReview)
    }

    func testContinueWithoutHooksBlocksFirstTurnThenReleasesBindingOnce() async throws {
        let controller = try HookApprovalFakeCodexController(
            listResults: [.success(inventory(hooks: [hook(key: "alpha")]))]
        )
        let (viewModel, session) = makeSession(controller: controller)
        let sendTask = Task { await self.send(on: viewModel, session: session) }

        let request = try await waitForRequest(session)
        XCTAssertEqual(request.phase, .reviewRequired)
        XCTAssertEqual(controller.startCount, 0)
        XCTAssertEqual(session.runState, .waitingForApproval)

        try await viewModel.test_codexCoordinator.resolveCodexHookReview(
            session: session,
            requestID: request.id,
            decision: .continueWithoutHooks
        )

        let outcome = await sendTask.value
        XCTAssertEqual(outcome, .sent)
        XCTAssertEqual(controller.operations, ["list", "start"])
        XCTAssertEqual(session.codexHookGateAudit?.status, .continuedWithoutHooks)
        XCTAssertEqual(session.codexHookGateAudit?.approvedCount, 0)
        XCTAssertEqual(session.codexHookGateAudit?.skippedCount, 1)
        XCTAssertTrue(session.items.contains { $0.kind == .system && $0.text.contains("Continued without trusting 1") })
    }

    func testApproveSelectedUsesExactCandidatesAndRetainsFailureIdentity() async throws {
        let first = try hook(key: "alpha")
        let second = try hook(key: "beta")
        let initial = try inventory(hooks: [first, second])
        let verified = try inventory(hooks: [
            hook(key: "alpha", status: .trusted),
            second
        ])
        let controller = HookApprovalFakeCodexController(
            listResults: [.success(initial)],
            trustResults: [.failure(CodexHookTrustError.batchWriteFailed), .success(verified)]
        )
        let (viewModel, session) = makeSession(controller: controller)
        let sendTask = Task { await self.send(on: viewModel, session: session) }
        let request = try await waitForRequest(session)

        try await viewModel.test_codexCoordinator.resolveCodexHookReview(
            session: session,
            requestID: request.id,
            decision: .approveSelected(hookKeys: ["alpha"])
        )
        let failed = try XCTUnwrap(session.pendingCodexHookReview)
        XCTAssertEqual(failed.id, request.id)
        XCTAssertEqual(failed.phase, .writeFailed)
        XCTAssertEqual(controller.startCount, 0)

        try await viewModel.test_codexCoordinator.resolveCodexHookReview(
            session: session,
            requestID: failed.id,
            decision: .approveSelected(hookKeys: ["alpha"])
        )

        let outcome = await sendTask.value
        XCTAssertEqual(outcome, .sent)
        XCTAssertEqual(controller.trustCalls.count, 2)
        XCTAssertEqual(controller.trustCalls.last?.candidates, [CodexHookTrustCandidate(key: "alpha", currentHash: "hash-alpha")])
        XCTAssertEqual(controller.trustCalls.last?.fingerprint, initial.fingerprint)
        XCTAssertEqual(session.codexHookGateAudit?.status, .approvedSelected)
        XCTAssertEqual(session.codexHookGateAudit?.approvedCount, 1)
        XCTAssertEqual(session.codexHookGateAudit?.skippedCount, 1)
    }

    func testPartialApprovalNoticeUsesVerifiedUnresolvedCountWhenSkippedHookResolvesExternally() async throws {
        let initial = try inventory(hooks: [hook(key: "alpha"), hook(key: "beta")])
        let verified = try inventory(hooks: [hook(key: "alpha", status: .trusted)])
        let controller = HookApprovalFakeCodexController(
            listResults: [.success(initial)],
            trustResults: [.success(verified)]
        )
        let (viewModel, session) = makeSession(controller: controller)
        let sendTask = Task { await self.send(on: viewModel, session: session) }
        let request = try await waitForRequest(session)

        try await viewModel.test_codexCoordinator.resolveCodexHookReview(
            session: session,
            requestID: request.id,
            decision: .approveSelected(hookKeys: ["alpha"])
        )

        await assertOutcome(sendTask, equals: .sent)
        XCTAssertEqual(session.codexHookGateAudit?.status, .approvedSelected)
        XCTAssertEqual(session.codexHookGateAudit?.approvedCount, 1)
        XCTAssertEqual(session.codexHookGateAudit?.skippedCount, 1)
        let notice = try XCTUnwrap(session.items.last { item in
            item.kind == .system && item.text.contains("Trusted 1 Codex project hook(s)")
        })
        XCTAssertTrue(notice.text.contains("0 remain untrusted for this controller binding"))
        XCTAssertFalse(notice.text.contains("1 remain untrusted for this controller binding"))
    }

    func testStrictModeIsReadLiveAndRejectsContinueWithoutMutation() async throws {
        let settings = HookApprovalFakeSettingsProvider(enabled: false)
        let controller = try HookApprovalFakeCodexController(
            listResults: [.success(inventory(hooks: [hook(key: "alpha")]))]
        )
        let (viewModel, session) = makeSession(controller: controller, settings: settings)
        let sendTask = Task { await self.send(on: viewModel, session: session) }
        let request = try await waitForRequest(session)

        settings.enabled = true
        do {
            try await viewModel.test_codexCoordinator.resolveCodexHookReview(
                session: session,
                requestID: request.id,
                decision: .continueWithoutHooks
            )
            XCTFail("Expected strict-mode rejection")
        } catch let error as AgentCodexHookReviewResolutionError {
            XCTAssertEqual(error, .strictModeRequiresApproval)
            XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("strict mode"))
        }
        XCTAssertEqual(session.pendingCodexHookReview?.id, request.id)
        XCTAssertEqual(controller.startCount, 0)
        XCTAssertTrue(controller.trustCalls.isEmpty)

        settings.enabled = false
        try await viewModel.test_codexCoordinator.resolveCodexHookReview(
            session: session,
            requestID: request.id,
            decision: .continueWithoutHooks
        )
        let outcome = await sendTask.value
        XCTAssertEqual(outcome, .sent)
    }

    func testStrictModeRejectsPartialApproveSelectedButAllowsAllKeys() async throws {
        let alpha = try hook(key: "alpha")
        let beta = try hook(key: "beta")
        let initial = try inventory(hooks: [alpha, beta])
        let verified = try inventory(hooks: [
            hook(key: "alpha", status: .trusted),
            hook(key: "beta", status: .trusted)
        ])
        let settings = HookApprovalFakeSettingsProvider(enabled: false)
        let controller = HookApprovalFakeCodexController(
            listResults: [.success(initial)],
            trustResults: [.success(verified)]
        )
        let (viewModel, session) = makeSession(controller: controller, settings: settings)
        let sendTask = Task { await self.send(on: viewModel, session: session) }
        let request = try await waitForRequest(session)

        settings.enabled = true
        do {
            try await viewModel.test_codexCoordinator.resolveCodexHookReview(
                session: session,
                requestID: request.id,
                decision: .approveSelected(hookKeys: ["alpha"])
            )
            XCTFail("Expected strict-mode rejection")
        } catch let error as AgentCodexHookReviewResolutionError {
            XCTAssertEqual(error, .strictModeRequiresApproval)
            XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("strict mode"))
        }
        XCTAssertEqual(session.pendingCodexHookReview?.id, request.id)
        XCTAssertNotNil(session.codexHookReviewContinuation)
        XCTAssertEqual(controller.startCount, 0)
        XCTAssertTrue(controller.trustCalls.isEmpty)

        try await viewModel.test_codexCoordinator.resolveCodexHookReview(
            session: session,
            requestID: request.id,
            decision: .approveSelected(hookKeys: ["alpha", "beta"])
        )
        await assertOutcome(sendTask, equals: .sent)
        XCTAssertEqual(controller.trustCalls.count, 1)
        XCTAssertEqual(Set(controller.trustCalls[0].candidates.map(\.key)), Set(["alpha", "beta"]))
        XCTAssertEqual(session.codexHookGateAudit?.status, .approvedSelected)
        XCTAssertEqual(session.codexHookGateAudit?.approvedCount, 2)
        XCTAssertEqual(session.codexHookGateAudit?.skippedCount, 0)
    }

    func testStrictModeEnabledDuringPartialApprovalRefreshesSkippedHooks() async throws {
        let alpha = try hook(key: "alpha")
        let beta = try hook(key: "beta")
        let initial = try inventory(hooks: [alpha, beta])
        let partiallyVerified = try inventory(hooks: [
            hook(key: "alpha", status: .trusted),
            beta
        ])
        let fullyVerified = try inventory(hooks: [
            hook(key: "alpha", status: .trusted),
            hook(key: "beta", status: .trusted)
        ])
        let settings = HookApprovalFakeSettingsProvider(enabled: false)
        let trustGate = HookApprovalAsyncGate()
        let controller = HookApprovalFakeCodexController(
            listResults: [.success(initial)],
            trustResults: [.success(partiallyVerified), .success(fullyVerified)],
            trustGate: trustGate
        )
        let (viewModel, session) = makeSession(controller: controller, settings: settings)
        let sendTask = Task { await self.send(on: viewModel, session: session) }
        let request = try await waitForRequest(session)
        let response = Task {
            try await viewModel.test_codexCoordinator.resolveCodexHookReview(
                session: session,
                requestID: request.id,
                decision: .approveSelected(hookKeys: ["alpha"])
            )
        }
        try await trustGate.waitUntilWaiting()

        settings.enabled = true
        await trustGate.release()
        try await response.value

        let replacement = try XCTUnwrap(session.pendingCodexHookReview)
        XCTAssertNotEqual(replacement.id, request.id)
        XCTAssertEqual(replacement.hooks.map(\.key), ["beta"])
        XCTAssertNotNil(session.codexHookReviewContinuation)
        XCTAssertNil(session.codexHookGateAudit)
        XCTAssertNil(session.codexHookGateBindingMemo)
        XCTAssertEqual(controller.startCount, 0)

        try await viewModel.test_codexCoordinator.resolveCodexHookReview(
            session: session,
            requestID: replacement.id,
            decision: .approveAll
        )
        await assertOutcome(sendTask, equals: .sent)
        XCTAssertEqual(controller.startCount, 1)
        XCTAssertEqual(controller.trustCalls.count, 2)
        XCTAssertEqual(session.codexHookGateAudit?.status, .approvedAll)
    }

    func testStrictModeEnabledDuringFullApprovalWithCleanVerificationCompletes() async throws {
        let initial = try inventory(hooks: [hook(key: "alpha"), hook(key: "beta")])
        let verified = try inventory(hooks: [
            hook(key: "alpha", status: .trusted),
            hook(key: "beta", status: .trusted)
        ])
        let settings = HookApprovalFakeSettingsProvider(enabled: false)
        let trustGate = HookApprovalAsyncGate()
        let controller = HookApprovalFakeCodexController(
            listResults: [.success(initial)],
            trustResults: [.success(verified)],
            trustGate: trustGate
        )
        let (viewModel, session) = makeSession(controller: controller, settings: settings)
        let sendTask = Task { await self.send(on: viewModel, session: session) }
        let request = try await waitForRequest(session)
        let response = Task {
            try await viewModel.test_codexCoordinator.resolveCodexHookReview(
                session: session,
                requestID: request.id,
                decision: .approveAll
            )
        }
        try await trustGate.waitUntilWaiting()

        settings.enabled = true
        await trustGate.release()
        try await response.value

        await assertOutcome(sendTask, equals: .sent)
        XCTAssertNil(session.pendingCodexHookReview)
        XCTAssertNil(session.codexHookReviewContinuation)
        XCTAssertEqual(controller.startCount, 1)
        XCTAssertEqual(controller.trustCalls.count, 1)
        XCTAssertEqual(session.codexHookGateAudit?.status, .approvedAll)
        XCTAssertNotNil(session.codexHookGateBindingMemo)
    }

    func testDiscoveryFailureCarriesCwdErrorAndRetryToZeroResolvesExternally() async throws {
        let controller = try HookApprovalFakeCodexController(
            listResults: [
                .failure(CodexHookTrustError.discoveryFailed(cwdErrors: ["invalid hook table in /repo/.codex/config.toml"])),
                .success(inventory(hooks: []))
            ]
        )
        let (viewModel, session) = makeSession(controller: controller)
        let sendTask = Task { await self.send(on: viewModel, session: session) }
        let failed = try await waitForRequest(session)

        XCTAssertEqual(failed.phase, .discoveryFailed)
        XCTAssertTrue(failed.errorMessage?.contains("invalid hook table") == true)
        XCTAssertEqual(controller.startCount, 0)

        try await viewModel.test_codexCoordinator.resolveCodexHookReview(
            session: session,
            requestID: failed.id,
            decision: .retryDiscovery
        )

        let outcome = await sendTask.value
        XCTAssertEqual(outcome, .sent)
        XCTAssertNil(session.pendingCodexHookReview)
        XCTAssertEqual(session.codexHookGateAudit?.status, .resolvedExternally)
        XCTAssertEqual(controller.operations, ["list", "list", "start"])
    }

    func testInventoryDriftReplacesIdentityAndDriftToZeroResolvesExternally() async throws {
        let initial = try inventory(hooks: [hook(key: "alpha")])
        let replacement = try inventory(hooks: [hook(key: "beta")])
        let empty = try inventory(hooks: [])
        let controller = HookApprovalFakeCodexController(
            listResults: [.success(initial)],
            trustResults: [
                .failure(CodexHookTrustError.inventoryChanged(replacement: replacement)),
                .failure(CodexHookTrustError.inventoryChanged(replacement: empty))
            ]
        )
        let (viewModel, session) = makeSession(controller: controller)
        let sendTask = Task { await self.send(on: viewModel, session: session) }
        let firstRequest = try await waitForRequest(session)

        try await viewModel.test_codexCoordinator.resolveCodexHookReview(
            session: session,
            requestID: firstRequest.id,
            decision: .approveAll
        )
        let drifted = try XCTUnwrap(session.pendingCodexHookReview)
        XCTAssertNotEqual(drifted.id, firstRequest.id)
        XCTAssertEqual(drifted.hooks.map(\.key), ["beta"])
        XCTAssertEqual(controller.startCount, 0)

        do {
            try await viewModel.test_codexCoordinator.resolveCodexHookReview(
                session: session,
                requestID: firstRequest.id,
                decision: .approveAll
            )
            XCTFail("Expected stale request rejection")
        } catch let error as AgentCodexHookReviewResolutionError {
            XCTAssertEqual(error, .staleRequest(currentID: drifted.id))
        }

        try await viewModel.test_codexCoordinator.resolveCodexHookReview(
            session: session,
            requestID: drifted.id,
            decision: .approveAll
        )
        let outcome = await sendTask.value
        XCTAssertEqual(outcome, .sent)
        XCTAssertEqual(session.codexHookGateAudit?.status, .resolvedExternally)
        XCTAssertEqual(controller.startCount, 1)
    }

    func testPostWriteInventoryDriftPublishesReplacementAndKeepsTurnSuspended() async throws {
        let initial = try inventory(hooks: [hook(key: "alpha")])
        let postWriteDrift = try inventory(hooks: [
            hook(key: "alpha", status: .trusted),
            hook(key: "beta")
        ])
        let fullyVerified = try inventory(hooks: [
            hook(key: "alpha", status: .trusted),
            hook(key: "beta", status: .trusted)
        ])
        let controller = HookApprovalFakeCodexController(
            listResults: [.success(initial)],
            trustResults: [.success(postWriteDrift), .success(fullyVerified)]
        )
        let (viewModel, session) = makeSession(controller: controller)
        let sendTask = Task { await self.send(on: viewModel, session: session) }
        let firstRequest = try await waitForRequest(session)

        try await viewModel.test_codexCoordinator.resolveCodexHookReview(
            session: session,
            requestID: firstRequest.id,
            decision: .approveAll
        )

        let replacement = try XCTUnwrap(session.pendingCodexHookReview)
        XCTAssertNotEqual(replacement.id, firstRequest.id)
        XCTAssertEqual(replacement.hooks.map(\.key), ["beta"])
        XCTAssertNotNil(session.codexHookReviewContinuation)
        XCTAssertNil(session.codexHookGateAudit)
        XCTAssertEqual(controller.startCount, 0)

        try await viewModel.test_codexCoordinator.resolveCodexHookReview(
            session: session,
            requestID: replacement.id,
            decision: .approveAll
        )
        await assertOutcome(sendTask, equals: .sent)
        XCTAssertEqual(controller.startCount, 1)
        XCTAssertEqual(controller.trustCalls.count, 2)
        XCTAssertEqual(session.codexHookGateAudit?.status, .approvedAll)
    }

    func testControllerReplacementCancelsSuspendedFirstTurnExactlyOnce() async throws {
        let controller = try HookApprovalFakeCodexController(
            listResults: [.success(inventory(hooks: [hook(key: "alpha")]))]
        )
        let replacement = try HookApprovalFakeCodexController(
            listResults: [.success(inventory(hooks: []))]
        )
        let (viewModel, session) = makeSession(controller: controller)
        let sendTask = Task { await self.send(on: viewModel, session: session) }
        _ = try await waitForRequest(session)

        session.codexController = replacement

        let outcome = await sendTask.value
        guard case .stale = outcome else {
            return XCTFail("Expected stale cancellation after controller replacement, got \(outcome)")
        }
        XCTAssertNil(session.pendingCodexHookReview)
        XCTAssertNil(session.codexHookReviewContinuation)
        XCTAssertEqual(controller.startCount, 0)
        XCTAssertEqual(replacement.startCount, 0)
    }

    func testBindingMemoizesSameControllerAndReplacementPromptsAgain() async throws {
        let controller = try HookApprovalFakeCodexController(
            listResults: [.success(inventory(hooks: [hook(key: "alpha")]))]
        )
        let (viewModel, session) = makeSession(controller: controller)
        let firstSend = Task { await self.send(on: viewModel, session: session) }
        let firstRequest = try await waitForRequest(session)
        try await continueWithoutHooks(firstRequest, session: session, viewModel: viewModel)
        await assertOutcome(firstSend, equals: .sent)

        prepareDirectStart(session)
        let secondOutcome = await send(on: viewModel, session: session)
        XCTAssertEqual(secondOutcome, .sent)
        XCTAssertEqual(controller.listCount, 1)
        XCTAssertEqual(controller.startCount, 2)

        let replacement = try HookApprovalFakeCodexController(
            listResults: [.success(inventory(hooks: [hook(key: "beta")]))]
        )
        session.codexController = replacement
        prepareDirectStart(session)
        let replacementSend = Task { await self.send(on: viewModel, session: session) }
        let replacementRequest = try await waitForRequest(session)
        XCTAssertEqual(replacementRequest.hooks.map(\.key), ["beta"])
        XCTAssertEqual(replacement.listCount, 1)
        XCTAssertEqual(replacement.startCount, 0)
        try await continueWithoutHooks(replacementRequest, session: session, viewModel: viewModel)
        await assertOutcome(replacementSend, equals: .sent)
    }

    func testControlOnlyBindingRoutesDeferHookReviewUntilLaterFirstSend() async throws {
        enum Route: CaseIterable {
            case restore
            case reconnect
            case goal
            case compact
        }

        CodexGoalSupport.setEnabledForTesting(true)
        defer { CodexGoalSupport.setEnabledForTesting(nil) }

        for route in Route.allCases {
            let controller = try HookApprovalFakeCodexController(
                listResults: [.success(inventory(hooks: [hook(key: "hook-\(route)")]))]
            )
            let (viewModel, session) = makeUnboundSession(controller: controller)
            let coordinator = viewModel.test_codexCoordinator

            switch route {
            case .restore:
                coordinator.restoreCodexMetadata(
                    from: AgentSession(
                        agentKind: AgentProviderKind.codexExec.rawValue,
                        codexConversationID: "thread"
                    ),
                    session: session
                )
                await coordinator.ensureCodexNativeSession(session: session)
            case .reconnect:
                session.codexConversationID = "thread"
                session.codexNeedsReconnect = true
                await coordinator.ensureCodexNativeSession(session: session)
            case .goal:
                session.codexConversationID = "thread"
                _ = await coordinator.executeNativeSlashCommand(
                    .goal,
                    argumentsText: "",
                    session: session
                )
            case .compact:
                session.codexConversationID = "thread"
                _ = await coordinator.executeNativeSlashCommand(
                    .compact,
                    argumentsText: "",
                    session: session
                )
            }

            XCTAssertNotNil(session.codexController, "\(route)")
            XCTAssertEqual(controller.listCount, 0, "\(route)")
            XCTAssertNil(session.pendingCodexHookReview, "\(route)")

            prepareDirectStart(session)
            let sendTask = Task { await self.send(on: viewModel, session: session) }
            let request = try await waitForRequest(session)
            XCTAssertEqual(controller.listCount, 1, "\(route)")
            XCTAssertEqual(controller.startCount, 0, "\(route)")
            try await continueWithoutHooks(request, session: session, viewModel: viewModel)
            await assertOutcome(sendTask, equals: .sent, message: "\(route)")
        }
    }

    func testManagedAuthRecoveryReplayRunsHookGateBeforeSecondStart() async throws {
        let controller = try HookApprovalFakeCodexController(
            listResults: [
                .success(inventory(hooks: [])),
                .success(inventory(hooks: [hook(key: "replay")]))
            ],
            startResults: [
                .failure(HookApprovalTestError.managedAuthRequired),
                .success(.init(provisionalSubmissionID: "replayed"))
            ]
        )
        let authRecovery = HookApprovalFakeAuthRecovery()
        let (viewModel, session) = makeSession(controller: controller, authRecovery: authRecovery)
        let sendTask = Task { await self.send(on: viewModel, session: session) }

        let request = try await waitForRequest(session)
        XCTAssertEqual(request.hooks.map(\.key), ["replay"])
        let refreshCount = await authRecovery.refreshCount
        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(controller.listCount, 2)
        XCTAssertEqual(controller.startCount, 1)

        try await continueWithoutHooks(request, session: session, viewModel: viewModel)
        await assertOutcome(sendTask, equals: .sent)
        XCTAssertEqual(controller.startCount, 2)
    }

    func testTrustAllSuccessReleasesTurnAndRecordsApprovedAllAudit() async throws {
        let unresolved = try hook(key: "alpha")
        let verified = try inventory(hooks: [hook(key: "alpha", status: .trusted)])
        let controller = try HookApprovalFakeCodexController(
            listResults: [.success(inventory(hooks: [unresolved]))],
            trustResults: [.success(verified)]
        )
        let (viewModel, session) = makeSession(controller: controller)
        let sendTask = Task { await self.send(on: viewModel, session: session) }
        let request = try await waitForRequest(session)

        try await viewModel.test_codexCoordinator.resolveCodexHookReview(
            session: session,
            requestID: request.id,
            decision: .approveAll
        )

        await assertOutcome(sendTask, equals: .sent)
        XCTAssertEqual(session.codexHookGateAudit?.status, .approvedAll)
        XCTAssertEqual(session.codexHookGateAudit?.approvedCount, 1)
        XCTAssertEqual(session.codexHookGateAudit?.skippedCount, 0)
        XCTAssertEqual(controller.operations, ["list", "trust", "start"])
    }

    func testVerificationFailureRetainsIdentityAndTrustAllRetryReleasesTurn() async throws {
        let unresolved = try inventory(hooks: [hook(key: "alpha")])
        let verified = try inventory(hooks: [hook(key: "alpha", status: .trusted)])
        let controller = HookApprovalFakeCodexController(
            listResults: [.success(unresolved)],
            trustResults: [.success(unresolved), .success(verified)]
        )
        let (viewModel, session) = makeSession(controller: controller)
        let sendTask = Task { await self.send(on: viewModel, session: session) }
        let request = try await waitForRequest(session)

        try await viewModel.test_codexCoordinator.resolveCodexHookReview(
            session: session,
            requestID: request.id,
            decision: .approveAll
        )
        let failed = try XCTUnwrap(session.pendingCodexHookReview)
        XCTAssertEqual(failed.phase, .verificationFailed)
        XCTAssertEqual(failed.id, request.id)
        XCTAssertEqual(controller.startCount, 0)

        try await viewModel.test_codexCoordinator.resolveCodexHookReview(
            session: session,
            requestID: failed.id,
            decision: .approveAll
        )
        await assertOutcome(sendTask, equals: .sent)
        XCTAssertEqual(controller.trustCalls.count, 2)
        XCTAssertEqual(session.codexHookGateAudit?.status, .approvedAll)
    }

    func testFailedHookGateDoesNotPersistUncommittedControllerReferenceOnCancellation() async throws {
        let unresolved = try inventory(hooks: [hook(key: "alpha")])
        let controller = HookApprovalFakeCodexController(
            listResults: [.success(unresolved)],
            trustResults: [.failure(CodexHookTrustError.batchWriteFailed)]
        )
        controller.currentSessionReference = .init(
            conversationID: "uncommitted-recovery-thread",
            rolloutPath: "/tmp/uncommitted-rollout.jsonl",
            model: "gpt-test",
            reasoningEffort: "medium"
        )
        let (viewModel, session) = makeSession(controller: controller)
        let sendTask = Task { await self.send(on: viewModel, session: session) }
        let request = try await waitForRequest(session)

        try await viewModel.test_codexCoordinator.resolveCodexHookReview(
            session: session,
            requestID: request.id,
            decision: .approveAll
        )
        XCTAssertEqual(session.pendingCodexHookReview?.phase, .writeFailed)

        _ = session.cancelCodexHookReview()
        await assertOutcome(sendTask, equals: .cancelled)
        XCTAssertEqual(session.codexConversationID, "thread")
        XCTAssertNil(session.codexRolloutPath)
    }

    func testRetryDiscoveryNonemptyInventoryReplacesIdentityWithoutResumingTurn() async throws {
        let controller = try HookApprovalFakeCodexController(
            listResults: [
                .failure(CodexHookTrustError.discoveryFailed(cwdErrors: ["broken config"])),
                .success(inventory(hooks: [hook(key: "replacement")]))
            ]
        )
        let (viewModel, session) = makeSession(controller: controller)
        let sendTask = Task { await self.send(on: viewModel, session: session) }
        let failed = try await waitForRequest(session)

        try await viewModel.test_codexCoordinator.resolveCodexHookReview(
            session: session,
            requestID: failed.id,
            decision: .retryDiscovery
        )

        let replacement = try XCTUnwrap(session.pendingCodexHookReview)
        XCTAssertNotEqual(replacement.id, failed.id)
        XCTAssertEqual(replacement.phase, .reviewRequired)
        XCTAssertEqual(replacement.hooks.map(\.key), ["replacement"])
        XCTAssertEqual(controller.startCount, 0)
        _ = session.cancelCodexHookReview()
        await assertOutcome(sendTask, equals: .cancelled)
    }

    func testDuplicateTrustAllResponseIsBusyAndRunsOneOperation() async throws {
        let trustGate = HookApprovalAsyncGate()
        let controller = try HookApprovalFakeCodexController(
            listResults: [.success(inventory(hooks: [hook(key: "alpha")]))],
            trustResults: [.success(inventory(hooks: [hook(key: "alpha", status: .trusted)]))],
            trustGate: trustGate
        )
        let (viewModel, session) = makeSession(controller: controller)
        let sendTask = Task { await self.send(on: viewModel, session: session) }
        let request = try await waitForRequest(session)
        let firstResponse = Task {
            try await viewModel.test_codexCoordinator.resolveCodexHookReview(
                session: session,
                requestID: request.id,
                decision: .approveAll
            )
        }
        try await trustGate.waitUntilWaiting()

        do {
            try await viewModel.test_codexCoordinator.resolveCodexHookReview(
                session: session,
                requestID: request.id,
                decision: .approveAll
            )
            XCTFail("Expected duplicate response to be busy")
        } catch let error as AgentCodexHookReviewResolutionError {
            XCTAssertEqual(error, .busy)
        }
        XCTAssertEqual(controller.trustCalls.count, 1)
        await trustGate.release()
        try await firstResponse.value
        await assertOutcome(sendTask, equals: .sent)
        XCTAssertEqual(controller.trustCalls.count, 1)
    }

    func testLateApprovalResultsRequireGenerationBindingAndAttemptTokenIndependently() async throws {
        enum InvalidatedAuthority: CaseIterable {
            case gateGeneration
            case bindingIdentity
            case attemptToken
        }

        for authority in InvalidatedAuthority.allCases {
            let trustGate = HookApprovalAsyncGate()
            let controller = try HookApprovalFakeCodexController(
                listResults: [.success(inventory(hooks: [hook(key: "alpha")]))],
                trustResults: [.success(inventory(hooks: [hook(key: "alpha", status: .trusted)]))],
                trustGate: trustGate
            )
            let (viewModel, session) = makeSession(controller: controller)
            let sendTask = Task { await self.send(on: viewModel, session: session) }
            let request = try await waitForRequest(session)
            let response = Task {
                try await viewModel.test_codexCoordinator.resolveCodexHookReview(
                    session: session,
                    requestID: request.id,
                    decision: .approveAll
                )
            }
            try await trustGate.waitUntilWaiting()

            switch authority {
            case .gateGeneration:
                session.codexHookGateGeneration &+= 1
            case .bindingIdentity:
                let unrelated = HookApprovalFakeCodexController(listResults: [])
                session.codexHookGateActiveBinding = .init(
                    controllerInstanceID: ObjectIdentifier(unrelated),
                    controllerGeneration: session.codexControllerGeneration
                )
            case .attemptToken:
                session.codexHookGateAttemptToken = UUID()
            }

            await trustGate.release()
            try await response.value
            XCTAssertNil(session.codexHookGateAudit, "\(authority)")
            XCTAssertEqual(controller.startCount, 0, "\(authority)")
            XCTAssertNotNil(session.pendingCodexHookReview, "\(authority)")
            _ = session.cancelCodexHookReview()
            await assertOutcome(sendTask, equals: .cancelled, message: "\(authority)")
        }
    }

    func testCancellationRoutesResumeSuspendedTurnExactlyOnce() async throws {
        enum CancellationRoute: CaseIterable {
            case directTask
            case tabClose
            case appTeardown
        }

        for route in CancellationRoute.allCases {
            let controller = try HookApprovalFakeCodexController(
                listResults: [.success(inventory(hooks: [hook(key: "alpha")]))]
            )
            let (viewModel, session) = makeSession(controller: controller)
            let counter = HookApprovalCompletionCounter()
            let sendTask = Task { await self.send(on: viewModel, session: session) }
            let observed = Task {
                let outcome = await sendTask.value
                await counter.record(outcome)
                return outcome
            }
            _ = try await waitForRequest(session)

            switch route {
            case .directTask:
                sendTask.cancel()
                sendTask.cancel()
            case .tabClose:
                _ = await viewModel.handleComposeTabsDidRemove(
                    [session.tabID],
                    reason: .stash,
                    workspaceID: UUID()
                )
            case .appTeardown:
                await viewModel.prepareForWindowClose()
            }

            await assertOutcome(observed, equals: .cancelled, message: "\(route)")
            try await Task.sleep(nanoseconds: 20_000_000)
            let completionCount = await counter.count
            XCTAssertEqual(completionCount, 1, "\(route)")
            XCTAssertNil(session.codexHookReviewContinuation, "\(route)")
            XCTAssertNil(session.pendingCodexHookReview, "\(route)")
        }
    }

    func testTrustAllSuccessResumesSuspendedTurnExactlyOnce() async throws {
        let controller = try HookApprovalFakeCodexController(
            listResults: [.success(inventory(hooks: [hook(key: "alpha")]))],
            trustResults: [.success(inventory(hooks: [hook(key: "alpha", status: .trusted)]))]
        )
        let (viewModel, session) = makeSession(controller: controller)
        let counter = HookApprovalCompletionCounter()
        let sendTask = Task { await self.send(on: viewModel, session: session) }
        let observed = Task {
            let outcome = await sendTask.value
            await counter.record(outcome)
            return outcome
        }
        let request = try await waitForRequest(session)

        try await viewModel.test_codexCoordinator.resolveCodexHookReview(
            session: session,
            requestID: request.id,
            decision: .approveAll
        )
        await assertOutcome(observed, equals: .sent)
        _ = session.cancelCodexHookReview()
        try await Task.sleep(nanoseconds: 20_000_000)
        let completionCount = await counter.count
        XCTAssertEqual(completionCount, 1)
    }

    func testCancelledComposerFirstMessageRestoresDraftAndAttachmentsExactlyOnce() async throws {
        let controller = try HookApprovalFakeCodexController(
            listResults: [.success(inventory(hooks: [hook(key: "alpha")]))]
        )
        let (viewModel, session) = makeComposerSession(controller: controller)
        viewModel.test_setCurrentTabIDOverride(session.tabID)
        defer { viewModel.test_setCurrentTabIDOverride(nil) }

        let image = AgentImageAttachment(
            source: .localFile(path: "/tmp/hook-approval-cancelled.png"),
            title: "hook-approval-cancelled.png"
        )
        let taggedFile = AgentTaggedFileAttachment(
            relativePath: "Sources/Secret.swift",
            displayName: "Secret.swift"
        )
        let draft = "unsent first message"
        session.pendingImageAttachments = [image]
        session.pendingTaggedFileAttachments = [taggedFile]
        viewModel.storeDraftText(for: session.tabID, draft)

        let target = try XCTUnwrap(viewModel.makeComposerSubmitTarget(tabID: session.tabID, session: session))
        let attempt = AgentComposerSubmitAttempt(
            id: UUID(),
            target: target,
            inputRevision: 1,
            noticeRevision: 0,
            rawDraftSnapshot: draft
        )
        let claim: AgentModeViewModel.AgentComposerSubmitClaim
        switch viewModel.claimComposerSubmitAttempt(attempt) {
        case let .claimed(value):
            claim = value
        case let .rejected(rejection):
            return XCTFail("Expected composer claim, got \(rejection)")
        }
        let submitResult = await viewModel.executeComposerSubmitAttempt(text: draft, claim: claim)
        XCTAssertEqual(submitResult, .submitted)
        _ = try await waitForRequest(session)

        await viewModel.cancelAgentRun(tabID: session.tabID, completion: .terminalTeardownCompleted)
        await viewModel.cancelAgentRun(tabID: session.tabID, completion: .terminalTeardownCompleted)
        try await waitUntil {
            viewModel.retrieveDraftText(for: session.tabID) == draft
                && session.pendingImageAttachments == [image]
                && session.pendingTaggedFileAttachments == [taggedFile]
        }
        XCTAssertEqual(session.pendingImageAttachments, [image])
        XCTAssertEqual(session.pendingTaggedFileAttachments, [taggedFile])
        XCTAssertEqual(viewModel.retrieveDraftText(for: session.tabID), draft)
        XCTAssertEqual(session.items.count(where: { $0.kind == .user }), 0)
    }

    func testStableHookReviewIdentityIgnoresPhaseAndErrorButTracksSeedComponents() throws {
        let tabID = UUID()
        let attemptID = UUID()
        let runID = UUID()
        let baseHook = try AgentCodexHookReviewHook(metadata: hook(key: "alpha"))
        func request(
            tabID: UUID = tabID,
            attemptID: UUID = attemptID,
            cwd: String = "/repo",
            hook: AgentCodexHookReviewHook = baseHook,
            phase: AgentCodexHookReviewRequest.Phase = .reviewRequired,
            error: String? = nil
        ) -> AgentCodexHookReviewRequest {
            AgentCodexHookReviewRequest(
                tabID: tabID,
                runAttemptID: attemptID,
                runID: runID,
                executionCWD: cwd,
                hooks: [hook],
                phase: phase,
                errorMessage: error,
                gateGeneration: 7
            )
        }

        let baseline = request()
        XCTAssertEqual(request(phase: .submitting).id, baseline.id)
        XCTAssertEqual(request(phase: .verificationFailed, error: "different failure text").id, baseline.id)
        XCTAssertNotEqual(request(tabID: UUID()).id, baseline.id)
        XCTAssertNotEqual(request(attemptID: UUID()).id, baseline.id)
        XCTAssertNotEqual(request(cwd: "/other").id, baseline.id)

        let sameKeyDifferentHash = try AgentCodexHookReviewHook(
            metadata: CodexHookMetadata(
                eventName: "PreToolUse",
                source: "project",
                sourcePath: "/repo/.codex/config.toml",
                key: "alpha",
                currentHash: "explicit-different-hash",
                enabled: true,
                handlerType: "command",
                trustStatus: .untrusted,
                commandOrHandler: "./hooks/alpha"
            )
        )
        XCTAssertNotEqual(request(hook: sameKeyDifferentHash).id, baseline.id)

        let differentKeySameHash = try AgentCodexHookReviewHook(
            metadata: CodexHookMetadata(
                eventName: "PreToolUse",
                source: "project",
                sourcePath: "/repo/.codex/config.toml",
                key: "beta",
                currentHash: "hash-alpha",
                enabled: true,
                handlerType: "command",
                trustStatus: .untrusted,
                commandOrHandler: "./hooks/alpha"
            )
        )
        XCTAssertNotEqual(request(hook: differentKeySameHash).id, baseline.id)

        XCTAssertNotEqual(
            try request(hook: AgentCodexHookReviewHook(metadata: hook(key: "beta"))).id,
            baseline.id
        )
    }

    func testHookOutcomeTranscriptNoticesExcludeInventoryMetadata() async throws {
        let sensitiveHook = try CodexHookMetadata(
            eventName: "PreToolUse",
            source: "project",
            sourcePath: "/repo/private/.codex/config.toml",
            key: "private-hook-key",
            currentHash: "private-hash",
            enabled: true,
            handlerType: "command",
            trustStatus: .untrusted,
            commandOrHandler: "/repo/private/run-secret-hook"
        )
        let trusted = try CodexHookMetadata(
            eventName: sensitiveHook.eventName,
            source: sensitiveHook.source,
            sourcePath: sensitiveHook.sourcePath,
            key: sensitiveHook.key,
            currentHash: sensitiveHook.currentHash,
            enabled: true,
            handlerType: sensitiveHook.handlerType,
            trustStatus: .trusted,
            commandOrHandler: sensitiveHook.commandOrHandler
        )
        let approvalController = try HookApprovalFakeCodexController(
            listResults: [.success(inventory(hooks: [sensitiveHook]))],
            trustResults: [.success(inventory(hooks: [trusted]))]
        )
        let (approvalViewModel, approvalSession) = makeSession(controller: approvalController)
        let approvalSend = Task { await self.send(on: approvalViewModel, session: approvalSession) }
        let approvalRequest = try await waitForRequest(approvalSession)
        try await approvalViewModel.test_codexCoordinator.resolveCodexHookReview(
            session: approvalSession,
            requestID: approvalRequest.id,
            decision: .approveAll
        )
        await assertOutcome(approvalSend, equals: .sent)
        assertHookNoticesArePrivate(approvalSession)

        let externalController = HookApprovalFakeCodexController(
            listResults: [.failure(CodexHookTrustError.discoveryFailed(cwdErrors: ["private discovery error"]))]
        )
        let (externalViewModel, externalSession) = makeSession(controller: externalController)
        let externalSend = Task { await self.send(on: externalViewModel, session: externalSession) }
        let externalRequest = try await waitForRequest(externalSession)
        externalController.listResults = try [.success(inventory(hooks: []))]
        try await externalViewModel.test_codexCoordinator.resolveCodexHookReview(
            session: externalSession,
            requestID: externalRequest.id,
            decision: .retryDiscovery
        )
        await assertOutcome(externalSend, equals: .sent)
        assertHookNoticesArePrivate(externalSession)
    }

    private func makeSession(
        controller: HookApprovalFakeCodexController,
        settings: HookApprovalFakeSettingsProvider? = nil,
        authRecovery: (any CodexManagedAuthRecovering)? = nil
    ) -> (AgentModeViewModel, AgentModeViewModel.TabSession) {
        let (viewModel, session) = makeUnboundSession(
            controller: controller,
            settings: settings,
            authRecovery: authRecovery
        )
        session.installRunID(UUID())
        session.beginRunAttempt(source: "test.codexHookApproval")
        bindReadyController(controller, to: session)
        return (viewModel, session)
    }

    private func makeUnboundSession(
        controller: HookApprovalFakeCodexController,
        settings: HookApprovalFakeSettingsProvider? = nil,
        authRecovery: (any CodexManagedAuthRecovering)? = nil
    ) -> (AgentModeViewModel, AgentModeViewModel.TabSession) {
        let settings = settings ?? HookApprovalFakeSettingsProvider(enabled: false)
        let viewModel = AgentModeViewModel(
            testWorkspacePath: "/repo",
            codexControllerFactory: { _, _, _, _, _, _ in controller },
            testCodexManagedAuthRecovery: authRecovery,
            testCodexHookApprovalSettingsProvider: settings
        )
        viewModel.test_initializeRunService()
        let session = viewModel.session(for: UUID())
        session.selectedAgent = .codexExec
        session.runState = .idle
        return (viewModel, session)
    }

    private func makeComposerSession(
        controller: HookApprovalFakeCodexController
    ) -> (AgentModeViewModel, AgentModeViewModel.TabSession) {
        let (viewModel, session) = makeUnboundSession(controller: controller)
        bindReadyController(controller, to: session)
        session.testInstallPersistentSessionBinding(sessionID: UUID())
        session.hasLoadedPersistedState = true
        return (viewModel, session)
    }

    private func bindReadyController(
        _ controller: HookApprovalFakeCodexController,
        to session: AgentModeViewModel.TabSession
    ) {
        session.codexController = controller
        session.codexControllerPermissionProfile = session.permissionProfile
        session.codexControllerWorkspacePaths = .uniform("/repo")
        session.codexConversationID = "thread"
        session.codexControllerFeatureState = .init(
            computerUseEnabled: false,
            goalSupportEnabled: CodexGoalSupport.isEnabled,
            reasoningSummariesEnabled: CodexReasoningSummaries.isEnabled,
            memoriesEnabled: CodexMemories.isEnabled
        )
    }

    private func prepareDirectStart(_ session: AgentModeViewModel.TabSession) {
        if let ownership = session.activeRunOwnership {
            _ = session.endRunAttempt(ifCurrent: ownership, source: "test.codexHookApproval.reset")
        }
        session.installRunID(UUID())
        session.runState = .idle
        session.codexPendingTurnKind = nil
        session.codexAuthoritativeActiveTurn = nil
        session.codexAnonymousActiveTurn = nil
        session.codexPendingAuthRetryTurn = nil
        _ = session.beginRunAttempt(source: "test.codexHookApproval.nextStart")
    }

    private func continueWithoutHooks(
        _ request: AgentCodexHookReviewRequest,
        session: AgentModeViewModel.TabSession,
        viewModel: AgentModeViewModel
    ) async throws {
        try await viewModel.test_codexCoordinator.resolveCodexHookReview(
            session: session,
            requestID: request.id,
            decision: .continueWithoutHooks
        )
    }

    private func assertHookNoticesArePrivate(
        _ session: AgentModeViewModel.TabSession,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let notices = session.items.filter { $0.kind == .system }.map(\.text).joined(separator: "\n")
        XCTAssertTrue(
            notices.contains("Trusted 1") || notices.contains("resolved externally"),
            notices,
            file: file,
            line: line
        )
        for secret in [
            "private-hook-key",
            "/repo/private/run-secret-hook",
            "/repo/private/.codex/config.toml",
            "/repo",
            "private-hash"
        ] {
            XCTAssertFalse(notices.contains(secret), "Leaked \(secret): \(notices)", file: file, line: line)
        }
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ predicate: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for Codex hook approval state")
    }

    private func assertOutcome(
        _ task: Task<CodexAgentModeCoordinator.NativeSendOutcome, Never>,
        equals expected: CodexAgentModeCoordinator.NativeSendOutcome,
        message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let actual = await task.value
        XCTAssertEqual(actual, expected, message, file: file, line: line)
    }

    private func send(
        on viewModel: AgentModeViewModel,
        session: AgentModeViewModel.TabSession
    ) async -> CodexAgentModeCoordinator.NativeSendOutcome {
        await viewModel.test_codexCoordinator.sendCodexNativeMessage(
            session: session,
            text: "hello",
            attachments: []
        )
    }

    private func waitForRequest(
        _ session: AgentModeViewModel.TabSession,
        timeout: TimeInterval = 2
    ) async throws -> AgentCodexHookReviewRequest {
        try await waitForPendingCodexHookReview(
            in: session,
            timeout: timeout,
            diagnostic: "Timed out waiting for Codex hook review; runState=\(session.runState), items=\(session.items.map { "\($0.kind):\($0.text)" })"
        )
    }

    private func inventory(hooks: [CodexHookMetadata]) throws -> CodexHookInventory {
        try CodexHookInventory(executionCWD: "/repo", hooks: hooks)
    }

    private func hook(
        key: String,
        status: CodexHookTrustStatus = .untrusted,
        enabled: Bool = true
    ) throws -> CodexHookMetadata {
        try CodexHookMetadata(
            eventName: "PreToolUse",
            source: "project",
            sourcePath: "/repo/.codex/config.toml",
            key: key,
            currentHash: "hash-\(key)",
            enabled: enabled,
            handlerType: "command",
            trustStatus: status,
            commandOrHandler: "./hooks/\(key)"
        )
    }
}

@MainActor
private final class HookApprovalFakeSettingsProvider: CodexHookApprovalSettingsProviding {
    var enabled: Bool

    init(enabled: Bool) {
        self.enabled = enabled
    }

    func codexHookApprovalStrictModeEnabled(workspaceID _: UUID?) -> Bool {
        enabled
    }
}

private final class HookApprovalFakeCodexController: CodexSessionControllerPassiveStubDefaults {
    struct TrustCall: Equatable {
        let candidates: [CodexHookTrustCandidate]
        let fingerprint: String
    }

    var listResults: [Result<CodexHookInventory, Error>]
    var trustResults: [Result<CodexHookInventory, Error>]
    var startResults: [Result<CodexTurnStartReceipt, Error>]
    private let listGate: HookApprovalAsyncGate?
    private let trustGate: HookApprovalAsyncGate?
    private(set) var operations: [String] = []
    private(set) var trustCalls: [TrustCall] = []
    private(set) var startCount = 0
    var currentSessionReference: CodexNativeSessionController.SessionRef?

    var listCount: Int {
        operations.count(where: { $0 == "list" })
    }

    init(
        listResults: [Result<CodexHookInventory, Error>],
        trustResults: [Result<CodexHookInventory, Error>] = [],
        startResults: [Result<CodexTurnStartReceipt, Error>] = [],
        listGate: HookApprovalAsyncGate? = nil,
        trustGate: HookApprovalAsyncGate? = nil
    ) {
        self.listResults = listResults
        self.trustResults = trustResults
        self.startResults = startResults
        self.listGate = listGate
        self.trustGate = trustGate
    }

    var hasActiveThread: Bool {
        true
    }

    var events: AsyncStream<CodexNativeSessionController.Event> {
        AsyncStream { _ in }
    }

    func startOrResume(
        existing _: CodexNativeSessionController.SessionRef?,
        baseInstructions _: String,
        model: String?,
        reasoningEffort: String?,
        serviceTier _: String?
    ) async throws -> CodexNativeSessionController.SessionRef {
        .init(conversationID: "thread", rolloutPath: nil, model: model, reasoningEffort: reasoningEffort)
    }

    func listHooksForCurrentWorkspace() async throws -> CodexHookInventory {
        operations.append("list")
        await listGate?.wait()
        guard !listResults.isEmpty else {
            throw CodexHookTrustError.malformedListResponse
        }
        return try listResults.removeFirst().get()
    }

    func trustHooksForCurrentWorkspace(
        expectedCandidates: [CodexHookTrustCandidate],
        expectedInventoryFingerprint: String
    ) async throws -> CodexHookInventory {
        operations.append("trust")
        trustCalls.append(.init(candidates: expectedCandidates, fingerprint: expectedInventoryFingerprint))
        await trustGate?.wait()
        guard !trustResults.isEmpty else {
            throw CodexHookTrustError.batchWriteFailed
        }
        return try trustResults.removeFirst().get()
    }

    func startUserTurn(
        text _: String,
        images _: [AgentImageAttachment],
        model _: String?,
        reasoningEffort _: String?,
        serviceTier _: String?
    ) async throws -> CodexTurnStartReceipt {
        operations.append("start")
        startCount += 1
        if !startResults.isEmpty {
            return try startResults.removeFirst().get()
        }
        return .init(provisionalSubmissionID: "submission-\(startCount)")
    }

    func readThreadSnapshot(includeTurns _: Bool, timeout _: TimeInterval?) async throws -> CodexNativeSessionController.ThreadSnapshot {
        throw CancellationError()
    }

    func shutdown() async {}
}

private actor HookApprovalAsyncGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isWaiting = false
    private var isReleased = false

    func wait() async {
        guard !isReleased else { return }
        isWaiting = true
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilWaiting(timeout: TimeInterval = 2) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isWaiting { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw HookApprovalTestError.gateTimeout
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

private actor HookApprovalCompletionCounter {
    private(set) var count = 0
    private(set) var outcomes: [CodexAgentModeCoordinator.NativeSendOutcome] = []

    func record(_ outcome: CodexAgentModeCoordinator.NativeSendOutcome) {
        count += 1
        outcomes.append(outcome)
    }
}

private actor HookApprovalFakeAuthRecovery: CodexManagedAuthRecovering {
    private let account = CodexManagedAccount(
        email: "hook-approval@example.com",
        accountType: "chatgpt",
        authenticationMode: "managed_chatgpt",
        managedLoginValidated: true
    )
    private(set) var refreshCount = 0

    func refreshManagedAccount() async -> CodexManagedAuthRefreshResult {
        refreshCount += 1
        return .recovered(account: account)
    }

    func managedAccountSnapshot() async -> CodexManagedAccount? {
        account
    }

    func startManagedChatgptLogin(
        openURL _: @MainActor @escaping @Sendable (URL) -> Void
    ) async -> CodexManagedChatgptLoginResult {
        .authenticated(account: account)
    }

    func startManagedChatgptDeviceCodeLogin(
        presentDeviceCode _: @MainActor @escaping @Sendable (CodexManagedChatgptDeviceCode, Bool) -> Void
    ) async -> CodexManagedChatgptLoginResult {
        .authenticated(account: account)
    }

    func logoutManagedAccount() async -> CodexManagedAuthLogoutResult {
        .signedOut
    }
}

private enum HookApprovalTestError: LocalizedError {
    case managedAuthRequired
    case gateTimeout

    var errorDescription: String? {
        switch self {
        case .managedAuthRequired:
            "account/chatgptAuthTokens/refresh failed"
        case .gateTimeout:
            "Timed out waiting for the test gate."
        }
    }
}
