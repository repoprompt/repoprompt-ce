import enum MCP.Value
@testable import RepoPromptApp
import XCTest

final class ContextBuilderDualOracleStateTests: XCTestCase {
    @MainActor
    func testAuthorizedReviewUsesPairedRuntimeWithExactPayloadAndResolvedModelNames() async throws {
        #if DEBUG
            let settings = GlobalSettingsStore.shared
            let previousSecondaryModel = settings.secondaryOracleModelRaw()
            settings.setSecondaryOracleModelRaw(AIModel.claude4Sonnet.rawValue, commit: false)
            defer { settings.setSecondaryOracleModelRaw(previousSecondaryModel, commit: false) }

            let fixture = try await makeFixture(windowID: -929)
            defer { fixture.cleanup() }
            let viewModel = fixture.composition.contextBuilderAgentViewModel
            let oracleViewModel = fixture.composition.oracleViewModel
            let workspaceID = try XCTUnwrap(fixture.composition.workspaceManager.activeWorkspaceID)
            let primaryID = UUID()
            let secondaryID = UUID()
            let primaryModel = AIModel.gpt54Pro
            let secondaryModel = AIModel.claude4Sonnet
            let prompt = "Review this exact payload"

            viewModel.installRunTestHooks(.init(
                beforeProcessingProviderEvent: nil,
                providerEventDisposition: nil,
                teardownCompleted: nil,
                resolveMCPFollowUpModel: { _ in
                    (model: primaryModel, chatPresetID: nil, mcpControlInfo: nil)
                },
                toolChatSend: { args, _, context, selection, callbacks in
                    XCTAssertEqual(args["mode"]?.stringValue, "review")
                    XCTAssertEqual(selection.model, primaryModel)
                    XCTAssertEqual(context.tabID, fixture.tabID)
                    XCTAssertEqual(context.workspaceID, workspaceID)
                    XCTAssertEqual(context.agentModeSessionID, UUID(uuidString: "00000000-0000-0000-0000-000000000111"))
                    XCTAssertEqual(context.agentModeRunID, UUID(uuidString: "00000000-0000-0000-0000-000000000222"))
                    let payload = try XCTUnwrap(context.packaging.prebuiltAIMessage)
                    XCTAssertTrue(payload.conversationMessages.last?.content.contains(prompt) == true)
                    XCTAssertTrue(oracleViewModel.acceptsOverrideAIMessageForTesting(payload, userMessage: prompt))
                    callbacks.modelsResolved?(primaryModel, secondaryModel)
                    try await callbacks.pairSessionsResolved?(primaryID, secondaryID)
                    callbacks.primaryProgress?("Paired review response", nil)
                    return pairedResult(
                        primaryID: primaryID,
                        secondaryID: secondaryID,
                        primaryModel: primaryModel,
                        secondary: .success(reply(id: secondaryID, text: "Secondary review response")),
                        context: context
                    )
                }
            ))
            defer { viewModel.installRunTestHooks(nil) }

            let agentSessionID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000111"))
            let agentRunID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000222"))
            let result = try await viewModel.runMCPPlanOrQuestion(
                for: .init(workspaceID: workspaceID, tabID: fixture.tabID),
                oracleViewModel: oracleViewModel,
                agentModeSessionID: agentSessionID,
                agentModeRunID: agentRunID,
                mode: .review,
                prompt: prompt,
                selection: .init(),
                reviewGitContext: .automaticOnly(),
                gitScopeOverride: .selected
            )

            guard case .paired = result.payload else { return XCTFail("Expected paired review result") }
            XCTAssertEqual(result.route.contextID, fixture.tabID)
            XCTAssertEqual(result.route.agentSessionID, agentSessionID)
            XCTAssertEqual(result.route.agentRunID, agentRunID)
            XCTAssertEqual(
                viewModel.sessions[fixture.tabID]?.mcpPlanModel,
                "\(primaryModel.displayName) + \(secondaryModel.displayName)"
            )
            XCTAssertEqual(viewModel.sessions[fixture.tabID]?.generatedAnswerRoute?.chatID, primaryID.uuidString)
        #endif
    }

    @MainActor
    func testAuthorizedReviewWithoutSecondaryPreservesLegacySingleHeadlessResult() async throws {
        #if DEBUG
            let settings = GlobalSettingsStore.shared
            let previousSecondaryModel = settings.secondaryOracleModelRaw()
            settings.setSecondaryOracleModelRaw(nil, commit: false)
            defer { settings.setSecondaryOracleModelRaw(previousSecondaryModel, commit: false) }

            let fixture = try await makeFixture(windowID: -930, deterministicResponse: "Legacy review response")
            defer { fixture.cleanup() }
            let viewModel = fixture.composition.contextBuilderAgentViewModel
            let oracleViewModel = fixture.composition.oracleViewModel
            let workspaceID = try XCTUnwrap(fixture.composition.workspaceManager.activeWorkspaceID)
            let primaryModel = AIModel.gpt54Pro
            var pairedRuntimeWasCalled = false

            viewModel.installRunTestHooks(.init(
                beforeProcessingProviderEvent: nil,
                providerEventDisposition: nil,
                teardownCompleted: nil,
                resolveMCPFollowUpModel: { _ in
                    (model: primaryModel, chatPresetID: nil, mcpControlInfo: nil)
                },
                toolChatSend: { _, _, _, _, _ in
                    pairedRuntimeWasCalled = true
                    throw CancellationError()
                }
            ))
            defer { viewModel.installRunTestHooks(nil) }

            let result = try await viewModel.runMCPPlanOrQuestion(
                for: .init(workspaceID: workspaceID, tabID: fixture.tabID),
                oracleViewModel: oracleViewModel,
                mode: .review,
                prompt: "Review with one Oracle",
                selection: .init(),
                reviewGitContext: .automaticOnly(),
                gitScopeOverride: .selected
            )

            guard case let .single(reply) = result.payload else { return XCTFail("Expected legacy single review result") }
            XCTAssertEqual(reply.response, "Legacy review response")
            XCTAssertFalse(pairedRuntimeWasCalled)
            XCTAssertEqual(viewModel.sessions[fixture.tabID]?.mcpPlanModel, primaryModel.displayName)
        #endif
    }

    @MainActor
    func testInactiveWorkspaceSingleOracleUsesLegacyHeadlessRoute() async throws {
        #if DEBUG
            let settings = GlobalSettingsStore.shared
            let previousSecondaryModel = settings.secondaryOracleModelRaw()
            settings.setSecondaryOracleModelRaw(nil, commit: false)
            defer { settings.setSecondaryOracleModelRaw(previousSecondaryModel, commit: false) }

            let fixture = try await makeFixture(windowID: -938, deterministicResponse: "Inactive headless response")
            defer { fixture.cleanup() }
            let composition = fixture.composition
            let targetWorkspaceID = try XCTUnwrap(composition.workspaceManager.activeWorkspaceID)
            var pairedRuntimeWasCalled = false
            composition.contextBuilderAgentViewModel.installRunTestHooks(.init(
                beforeProcessingProviderEvent: nil,
                providerEventDisposition: nil,
                teardownCompleted: nil,
                resolveMCPFollowUpModel: { _ in
                    (model: .gpt54Pro, chatPresetID: nil, mcpControlInfo: nil)
                },
                toolChatSend: { _, _, _, _, _ in
                    pairedRuntimeWasCalled = true
                    throw CancellationError()
                }
            ))
            defer { composition.contextBuilderAgentViewModel.installRunTestHooks(nil) }

            let ambient = composition.workspaceManager.createWorkspace(
                name: "Ambient workspace",
                repoPaths: [fixture.root.path],
                ephemeral: true
            )
            await composition.workspaceManager.switchWorkspace(to: ambient, saveState: false, reason: #function)

            let result = try await composition.contextBuilderAgentViewModel.runMCPPlanOrQuestion(
                for: .init(workspaceID: targetWorkspaceID, tabID: fixture.tabID),
                oracleViewModel: composition.oracleViewModel,
                mode: .plan,
                prompt: "Use the target workspace headlessly.",
                selection: .init(),
                reviewGitContext: .automaticOnly()
            )

            guard case let .single(reply) = result.payload else { return XCTFail("Expected single Oracle result") }
            XCTAssertEqual(reply.response, "Inactive headless response")
            XCTAssertFalse(pairedRuntimeWasCalled)
            XCTAssertEqual(composition.workspaceManager.activeWorkspaceID, ambient.id)
            XCTAssertFalse(composition.oracleViewModel.sessions.contains(where: { $0.id == reply.chatId }))
        #endif
    }

    @MainActor
    func testInactiveWorkspacePairedOracleKeepsCoordinatedRuntime() async throws {
        #if DEBUG
            let settings = GlobalSettingsStore.shared
            let previousSecondaryModel = settings.secondaryOracleModelRaw()
            settings.setSecondaryOracleModelRaw(AIModel.claude4Sonnet.rawValue, commit: false)
            defer { settings.setSecondaryOracleModelRaw(previousSecondaryModel, commit: false) }

            let fixture = try await makeFixture(windowID: -939)
            defer { fixture.cleanup() }
            let composition = fixture.composition
            let targetWorkspaceID = try XCTUnwrap(composition.workspaceManager.activeWorkspaceID)
            let primaryID = UUID()
            let secondaryID = UUID()
            var pairedRuntimeWasCalled = false
            composition.contextBuilderAgentViewModel.installRunTestHooks(.init(
                beforeProcessingProviderEvent: nil,
                providerEventDisposition: nil,
                teardownCompleted: nil,
                resolveMCPFollowUpModel: { _ in
                    (model: .gpt54Pro, chatPresetID: nil, mcpControlInfo: nil)
                },
                toolChatSend: { _, _, context, _, callbacks in
                    pairedRuntimeWasCalled = true
                    XCTAssertEqual(context.workspaceID, targetWorkspaceID)
                    XCTAssertNil(context.packaging.prebuiltAIMessage)
                    callbacks.modelsResolved?(.gpt54Pro, .claude4Sonnet)
                    try await callbacks.pairSessionsResolved?(primaryID, secondaryID)
                    return pairedResult(
                        primaryID: primaryID,
                        secondaryID: secondaryID,
                        primaryModel: .gpt54Pro,
                        secondary: .success(reply(id: secondaryID, text: "Secondary response")),
                        context: context
                    )
                }
            ))
            defer { composition.contextBuilderAgentViewModel.installRunTestHooks(nil) }

            let ambient = composition.workspaceManager.createWorkspace(
                name: "Ambient paired workspace",
                repoPaths: [fixture.root.path],
                ephemeral: true
            )
            await composition.workspaceManager.switchWorkspace(to: ambient, saveState: false, reason: #function)

            let result = try await composition.contextBuilderAgentViewModel.runMCPPlanOrQuestion(
                for: .init(workspaceID: targetWorkspaceID, tabID: fixture.tabID),
                oracleViewModel: composition.oracleViewModel,
                mode: .plan,
                prompt: "Run both target workspace Oracles.",
                selection: .init(),
                reviewGitContext: .automaticOnly()
            )

            guard case .paired = result.payload else { return XCTFail("Expected paired Oracle result") }
            XCTAssertTrue(pairedRuntimeWasCalled)
            XCTAssertEqual(composition.workspaceManager.activeWorkspaceID, ambient.id)
        #endif
    }

    @MainActor
    func testPairedRuntimePublishesPrimaryPreviewAndNeverActivatesChat() async throws {
        #if DEBUG
            let fixture = try await makeFixture(windowID: -931)
            defer { fixture.cleanup() }
            let viewModel = fixture.composition.contextBuilderAgentViewModel
            let oracleViewModel = fixture.composition.oracleViewModel
            let workspaceID = try XCTUnwrap(fixture.composition.workspaceManager.activeWorkspaceID)
            let primaryID = UUID()
            let secondaryID = UUID()
            var runtimeCurrent: UUID?
            var runtimeActive: UUID?
            let primaryModel = AIModel.gpt54Pro
            let primaryPresetID = UUID()
            let primaryMCPControlInfo = "Plan mode • MCP override"
            let activityRecorder = DualOracleActivityRecorder()

            viewModel.installRunTestHooks(.init(
                beforeProcessingProviderEvent: nil,
                providerEventDisposition: nil,
                teardownCompleted: nil,
                resolveMCPFollowUpModel: { _ in
                    (
                        model: primaryModel,
                        chatPresetID: primaryPresetID,
                        mcpControlInfo: primaryMCPControlInfo
                    )
                },
                toolChatSend: { args, _, context, selection, callbacks in
                    XCTAssertNil(args["model"])
                    XCTAssertEqual(selection.model, primaryModel)
                    XCTAssertEqual(selection.chatPresetID, primaryPresetID)
                    XCTAssertEqual(selection.mcpControlInfo, primaryMCPControlInfo)
                    XCTAssertFalse(selection.isAutoSelected)
                    XCTAssertEqual(context.workspaceID, workspaceID)
                    XCTAssertEqual(context.activationPolicy, .background)
                    XCTAssertEqual(context.completionPolicy, .contextBuilderStrict)
                    runtimeCurrent = oracleViewModel.currentSessionID
                    runtimeActive = fixture.composition.workspaceManager.activeChatSessionID(forTabID: fixture.tabID)
                    try await callbacks.pairSessionsResolved?(primaryID, secondaryID)
                    callbacks.laneLifecycle?(.primary, .init(kind: .streamActivity))
                    callbacks.laneLifecycle?(.secondary, .init(kind: .streamActivity))
                    callbacks.laneLifecycle?(.primary, .init(kind: .streamActivity))
                    callbacks.laneLifecycle?(.secondary, .init(kind: .streamActivity))
                    callbacks.laneLifecycle?(.primary, .init(kind: .finalizationCompleted))
                    callbacks.laneLifecycle?(.secondary, .init(kind: .streamFailed))
                    callbacks.laneLifecycle?(.secondary, .init(kind: .streamCancelled))
                    callbacks.primaryProgress?("Primary preview", "Primary reasoning")
                    return pairedResult(
                        primaryID: primaryID,
                        secondaryID: secondaryID,
                        primaryModel: primaryModel,
                        secondary: .failure(.init(message: "Secondary unavailable"))
                    )
                }
            ))
            defer { viewModel.installRunTestHooks(nil) }

            let result = try await viewModel.runMCPPlanOrQuestion(
                for: .init(workspaceID: workspaceID, tabID: fixture.tabID),
                oracleViewModel: oracleViewModel,
                mode: .plan,
                prompt: "Plan this change",
                selection: .init(),
                reviewGitContext: .automaticOnly(),
                activityReporter: { activity in
                    await activityRecorder.record(activity)
                }
            )

            let state = try XCTUnwrap(viewModel.sessions[fixture.tabID])
            let reply = primaryReply(from: result)
            guard case let .paired(pair) = result.payload,
                  case let .failure(secondaryFailure) = pair.result.secondary
            else { return XCTFail("Expected the paired result envelope") }
            XCTAssertEqual(secondaryFailure.message, "Secondary unavailable")
            XCTAssertEqual(reply.response, "Primary response")
            XCTAssertEqual(reply.errors, ["Secondary Oracle failed: Secondary unavailable"])
            XCTAssertEqual(state.backgroundPlanResponseText, "Primary response")
            XCTAssertEqual(state.backgroundPlanReasoningText, "Primary reasoning")
            XCTAssertNil(state.followUpPrimarySessionID)
            XCTAssertNil(state.followUpSecondarySessionID)
            XCTAssertEqual(state.generatedAnswerRoute?.chatID, primaryID.uuidString)
            let activities = await activityRecorder.snapshot()
            XCTAssertEqual(activities.phases, [
                .streaming,
                .streaming,
                .streaming,
                .streaming,
                .messageFinalization,
                .streaming
            ])
            XCTAssertEqual(activities.messages, [
                "Still in Primary Oracle response streaming",
                "Still in Secondary Oracle response streaming",
                "Still in Primary Oracle response streaming",
                "Still in Secondary Oracle response streaming",
                "Primary Oracle message finalization completed",
                "Secondary Oracle stream failed"
            ])
            XCTAssertEqual(activities.suppressedHeartbeats, [.streaming])
            XCTAssertFalse(activities.messages.contains("Oracle response streaming"))
            XCTAssertFalse(activities.messages.contains("Oracle message finalization completed"))
            XCTAssertEqual(oracleViewModel.currentSessionID, runtimeCurrent)
            XCTAssertEqual(
                fixture.composition.workspaceManager.activeChatSessionID(forTabID: fixture.tabID),
                runtimeActive
            )
        #endif
    }

    @MainActor
    func testReplacementCancelsBothOldLanesOnceAndRejectsStaleCallbacks() async throws {
        #if DEBUG
            let fixture = try await makeFixture(windowID: -932)
            defer { fixture.cleanup() }
            let viewModel = fixture.composition.contextBuilderAgentViewModel
            let oracleViewModel = fixture.composition.oracleViewModel
            let workspaceID = try XCTUnwrap(fixture.composition.workspaceManager.activeWorkspaceID)
            let oldPrimary = UUID()
            let oldSecondary = UUID()
            let replacementPrimary = UUID()
            let gate = FollowUpGate()
            let recorder = FollowUpRecorder()
            let firstStarted = AsyncSignal()
            let model = AIModel.gpt54Pro

            viewModel.installRunTestHooks(.init(
                beforeProcessingProviderEvent: nil,
                providerEventDisposition: nil,
                teardownCompleted: nil,
                resolveMCPFollowUpModel: { _ in
                    (model: model, chatPresetID: nil, mcpControlInfo: nil)
                },
                cancelFollowUpOracleSession: { await recorder.recordCancellation($0) },
                toolChatSend: { _, _, context, _, callbacks in
                    let dispatch = await recorder.recordDispatch()
                    if dispatch == 1 {
                        try await callbacks.pairSessionsResolved?(oldPrimary, oldSecondary)
                        await firstStarted.signal()
                        await gate.wait()
                        callbacks.primaryProgress?("stale preview", nil)
                        return pairedResult(
                            primaryID: oldPrimary,
                            secondaryID: oldSecondary,
                            primaryModel: model,
                            secondary: .success(reply(id: oldSecondary, text: "Old secondary"))
                        )
                    }
                    try await callbacks.primarySessionResolved?(replacementPrimary)
                    callbacks.primaryProgress?("Fresh preview", nil)
                    return singleResult(id: replacementPrimary, context: context, response: "Fresh response")
                }
            ))
            defer { viewModel.installRunTestHooks(nil) }
            let identity = WorkspaceSelectionIdentity(workspaceID: workspaceID, tabID: fixture.tabID)

            let first = Task { @MainActor in
                try await viewModel.runMCPPlanOrQuestion(
                    for: identity,
                    oracleViewModel: oracleViewModel,
                    mode: .plan,
                    prompt: "First",
                    selection: .init(),
                    reviewGitContext: .automaticOnly()
                )
            }
            await firstStarted.wait()
            let replacement = Task { @MainActor in
                try await viewModel.runMCPPlanOrQuestion(
                    for: identity,
                    oracleViewModel: oracleViewModel,
                    mode: .plan,
                    prompt: "Replacement",
                    selection: .init(),
                    reviewGitContext: .automaticOnly()
                )
            }

            await waitUntil { await recorder.snapshot().cancelledIDs.count == 2 }
            var snapshot = await recorder.snapshot()
            XCTAssertEqual(snapshot.dispatchCount, 1)
            await gate.release()
            let replacementReply = try await primaryReply(from: replacement.value)
            _ = try? await first.value

            let state = try XCTUnwrap(viewModel.sessions[fixture.tabID])
            XCTAssertEqual(replacementReply.response, "Fresh response")
            XCTAssertEqual(state.backgroundPlanResponseText, "Fresh response")
            snapshot = await recorder.snapshot()
            XCTAssertEqual(Set(snapshot.cancelledIDs), [oldPrimary, oldSecondary])
            XCTAssertEqual(snapshot.cancelledIDs.count, 2)
        #endif
    }

    @MainActor
    func testDrainTimeoutStartsNoReplacementAndRetryWorksAfterRetainedDrainClears() async throws {
        #if DEBUG
            let fixture = try await makeFixture(windowID: -933)
            defer { fixture.cleanup() }
            let viewModel = fixture.composition.contextBuilderAgentViewModel
            let oracleViewModel = fixture.composition.oracleViewModel
            let workspaceID = try XCTUnwrap(fixture.composition.workspaceManager.activeWorkspaceID)
            let gate = FollowUpGate()
            let recorder = FollowUpRecorder()
            let firstStarted = AsyncSignal()
            let model = AIModel.gpt54Pro

            viewModel.installRunTestHooks(.init(
                beforeProcessingProviderEvent: nil,
                providerEventDisposition: nil,
                teardownCompleted: nil,
                resolveMCPFollowUpModel: { _ in
                    (model: model, chatPresetID: nil, mcpControlInfo: nil)
                },
                cancelFollowUpOracleSession: { await recorder.recordCancellation($0) },
                toolChatSend: { _, _, context, _, callbacks in
                    let dispatch = await recorder.recordDispatch()
                    let primary = UUID()
                    try await callbacks.primarySessionResolved?(primary)
                    if dispatch == 1 {
                        await firstStarted.signal()
                        await gate.wait()
                    }
                    return singleResult(id: primary, context: context, response: "Response \(dispatch)")
                },
                supersededDrainTimeout: 0.01
            ))
            defer { viewModel.installRunTestHooks(nil) }
            let identity = WorkspaceSelectionIdentity(workspaceID: workspaceID, tabID: fixture.tabID)

            let first = Task { @MainActor in
                try await viewModel.runMCPPlanOrQuestion(
                    for: identity,
                    oracleViewModel: oracleViewModel,
                    mode: .plan,
                    prompt: "First",
                    selection: .init(),
                    reviewGitContext: .automaticOnly()
                )
            }
            await firstStarted.wait()

            // swiftformat:disable redundantAwait hoistAwait
            await XCTAssertThrowsErrorAsync(try await viewModel.runMCPPlanOrQuestion(
                for: identity,
                oracleViewModel: oracleViewModel,
                mode: .plan,
                prompt: "Timed out replacement",
                selection: .init(),
                reviewGitContext: .automaticOnly()
            )) { error in
                XCTAssertEqual(
                    error.localizedDescription,
                    "Previous Oracle follow-up did not stop within 0.0s; no replacement was started."
                )
            }
            // swiftformat:enable redundantAwait hoistAwait
            var snapshot = await recorder.snapshot()
            XCTAssertEqual(snapshot.dispatchCount, 1)
            XCTAssertNotNil(viewModel.sessions[fixture.tabID]?.supersededFollowUpDrain)

            await gate.release()
            _ = try? await first.value
            await waitUntil { viewModel.sessions[fixture.tabID]?.supersededFollowUpDrain == nil }

            let retry = try await primaryReply(from: viewModel.runMCPPlanOrQuestion(
                for: identity,
                oracleViewModel: oracleViewModel,
                mode: .plan,
                prompt: "Retry",
                selection: .init(),
                reviewGitContext: .automaticOnly()
            ))
            XCTAssertEqual(retry.response, "Response 2")
            snapshot = await recorder.snapshot()
            XCTAssertEqual(snapshot.dispatchCount, 2)
        #endif
    }

    @MainActor
    func testSecondPairedFollowUpContinuesPrimaryChat() async throws {
        #if DEBUG
            let fixture = try await makeFixture(windowID: -934)
            defer { fixture.cleanup() }
            let viewModel = fixture.composition.contextBuilderAgentViewModel
            let oracleViewModel = fixture.composition.oracleViewModel
            let workspaceID = try XCTUnwrap(fixture.composition.workspaceManager.activeWorkspaceID)
            let primaryID = UUID()
            let secondaryID = UUID()
            let model = AIModel.gpt54Pro
            var dispatchCount = 0

            viewModel.installRunTestHooks(.init(
                beforeProcessingProviderEvent: nil,
                providerEventDisposition: nil,
                teardownCompleted: nil,
                resolveMCPFollowUpModel: { _ in
                    (model: model, chatPresetID: nil, mcpControlInfo: nil)
                },
                toolChatSend: { args, _, _, _, callbacks in
                    dispatchCount += 1
                    if dispatchCount == 1 {
                        XCTAssertEqual(args["new_chat"]?.boolValue, true)
                        XCTAssertNil(args["chat_id"])
                    } else {
                        XCTAssertEqual(args["new_chat"]?.boolValue, false)
                        XCTAssertEqual(args["chat_id"]?.stringValue, primaryID.uuidString)
                    }
                    try await callbacks.pairSessionsResolved?(primaryID, secondaryID)
                    return pairedResult(
                        primaryID: primaryID,
                        secondaryID: secondaryID,
                        primaryModel: model,
                        secondary: .success(reply(id: secondaryID, text: "Secondary response"))
                    )
                }
            ))
            defer { viewModel.installRunTestHooks(nil) }
            let identity = WorkspaceSelectionIdentity(workspaceID: workspaceID, tabID: fixture.tabID)

            _ = try await viewModel.runMCPPlanOrQuestion(
                for: identity,
                oracleViewModel: oracleViewModel,
                mode: .plan,
                prompt: "First",
                selection: .init(),
                reviewGitContext: .automaticOnly()
            )
            let second = try await viewModel.runMCPPlanOrQuestion(
                for: identity,
                oracleViewModel: oracleViewModel,
                mode: .plan,
                prompt: "Second",
                selection: .init(),
                reviewGitContext: .automaticOnly()
            )

            guard case let .paired(pair) = second.payload else {
                return XCTFail("Expected paired continuation")
            }
            XCTAssertEqual(pair.primaryChatID, primaryID.uuidString)
            XCTAssertEqual(dispatchCount, 2)
            XCTAssertEqual(viewModel.sessions[fixture.tabID]?.generatedAnswerRoute?.chatID, primaryID.uuidString)
        #endif
    }

    @MainActor
    func testRejectedContinuationFallsBackOnceBeforeAnyLanePublishes() async throws {
        #if DEBUG
            let fixture = try await makeFixture(windowID: -935)
            defer { fixture.cleanup() }
            let viewModel = fixture.composition.contextBuilderAgentViewModel
            let oracleViewModel = fixture.composition.oracleViewModel
            let workspaceID = try XCTUnwrap(fixture.composition.workspaceManager.activeWorkspaceID)
            let firstID = UUID()
            let freshID = UUID()
            let model = AIModel.gpt54Pro
            var dispatchCount = 0

            viewModel.installRunTestHooks(.init(
                beforeProcessingProviderEvent: nil,
                providerEventDisposition: nil,
                teardownCompleted: nil,
                resolveMCPFollowUpModel: { _ in
                    (model: model, chatPresetID: nil, mcpControlInfo: nil)
                },
                toolChatSend: { args, _, context, _, callbacks in
                    dispatchCount += 1
                    switch dispatchCount {
                    case 1:
                        XCTAssertEqual(args["new_chat"]?.boolValue, true)
                        XCTAssertNil(args["chat_id"])
                        try await callbacks.primarySessionResolved?(firstID)
                        return singleResult(id: firstID, context: context, response: "First")
                    case 2:
                        XCTAssertEqual(args["new_chat"]?.boolValue, false)
                        XCTAssertEqual(args["chat_id"]?.stringValue, firstID.uuidString)
                        throw ChatToolError.notFound("stale continuation")
                    default:
                        XCTAssertEqual(args["new_chat"]?.boolValue, true)
                        XCTAssertNil(args["chat_id"])
                        try await callbacks.primarySessionResolved?(freshID)
                        return singleResult(id: freshID, context: context, response: "Fresh")
                    }
                }
            ))
            defer { viewModel.installRunTestHooks(nil) }
            let identity = WorkspaceSelectionIdentity(workspaceID: workspaceID, tabID: fixture.tabID)

            _ = try await viewModel.runMCPPlanOrQuestion(
                for: identity,
                oracleViewModel: oracleViewModel,
                mode: .plan,
                prompt: "First",
                selection: .init(),
                reviewGitContext: .automaticOnly()
            )
            let retry = try await viewModel.runMCPPlanOrQuestion(
                for: identity,
                oracleViewModel: oracleViewModel,
                mode: .plan,
                prompt: "Retry",
                selection: .init(),
                reviewGitContext: .automaticOnly()
            )

            XCTAssertEqual(primaryReply(from: retry).response, "Fresh")
            XCTAssertEqual(dispatchCount, 3)
            XCTAssertEqual(viewModel.sessions[fixture.tabID]?.generatedAnswerRoute?.chatID, freshID.uuidString)
        #endif
    }

    @MainActor
    func testMismatchedStoredRouteStartsFreshWithoutContinuationAttempt() async throws {
        #if DEBUG
            let fixture = try await makeFixture(windowID: -936)
            defer { fixture.cleanup() }
            let viewModel = fixture.composition.contextBuilderAgentViewModel
            let oracleViewModel = fixture.composition.oracleViewModel
            let workspaceID = try XCTUnwrap(fixture.composition.workspaceManager.activeWorkspaceID)
            let firstID = UUID()
            let secondID = UUID()
            let model = AIModel.gpt54Pro
            var dispatchCount = 0

            viewModel.installRunTestHooks(.init(
                beforeProcessingProviderEvent: nil,
                providerEventDisposition: nil,
                teardownCompleted: nil,
                resolveMCPFollowUpModel: { _ in
                    (model: model, chatPresetID: nil, mcpControlInfo: nil)
                },
                toolChatSend: { args, _, context, _, callbacks in
                    dispatchCount += 1
                    XCTAssertEqual(args["new_chat"]?.boolValue, true)
                    XCTAssertNil(args["chat_id"])
                    let id = dispatchCount == 1 ? firstID : secondID
                    try await callbacks.primarySessionResolved?(id)
                    return singleResult(id: id, context: context, response: "Response")
                }
            ))
            defer { viewModel.installRunTestHooks(nil) }
            let identity = WorkspaceSelectionIdentity(workspaceID: workspaceID, tabID: fixture.tabID)

            _ = try await viewModel.runMCPPlanOrQuestion(
                for: identity,
                oracleViewModel: oracleViewModel,
                mode: .plan,
                prompt: "First",
                selection: .init(),
                reviewGitContext: .automaticOnly()
            )
            viewModel.sessions[fixture.tabID]?.generatedAnswerRoute = .init(
                workspaceID: UUID(),
                tabID: fixture.tabID,
                chatID: firstID.uuidString
            )
            _ = try await viewModel.runMCPPlanOrQuestion(
                for: identity,
                oracleViewModel: oracleViewModel,
                mode: .plan,
                prompt: "Second",
                selection: .init(),
                reviewGitContext: .automaticOnly()
            )

            XCTAssertEqual(dispatchCount, 2)
            XCTAssertEqual(viewModel.sessions[fixture.tabID]?.generatedAnswerRoute?.chatID, secondID.uuidString)
        #endif
    }

    @MainActor
    private func makeFixture(windowID: Int, deterministicResponse: String? = nil) async throws -> Fixture {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let composition: WindowStateComposition = if let deterministicResponse {
            WindowStateCompositionFactory.make(
                windowID: windowID,
                deferredInitialAgentSystemWorkspaceRefresh: true,
                sharedMCPService: MCPService(),
                aiQueriesServiceFactory: { keyManager in
                    AIQueriesService(
                        keyManager: keyManager,
                        sendPromptOverride: { _, _ in
                            let stream = AsyncThrowingStream<ChatStreamOutput, Error> { continuation in
                                continuation.yield(ChatStreamOutput(
                                    text: deterministicResponse,
                                    reasoning: nil,
                                    tokens: ChatTokenInfo(),
                                    terminalOutcome: .completed
                                ))
                                continuation.finish()
                            }
                            return (UUID(), stream)
                        }
                    )
                }
            )
        } else {
            WindowStateCompositionFactory.make(
                windowID: windowID,
                deferredInitialAgentSystemWorkspaceRefresh: true,
                sharedMCPService: MCPService()
            )
        }
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        await composition.workspaceManager.awaitInitialized()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContextBuilderDualOracleStateTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let workspace = composition.workspaceManager.createWorkspace(
            name: "Dual Oracle state test",
            repoPaths: [root.path],
            ephemeral: true
        )
        await composition.workspaceManager.switchWorkspace(to: workspace, saveState: false, reason: #function)
        let active = try XCTUnwrap(composition.workspaceManager.activeWorkspace)
        let tabID = try XCTUnwrap(active.activeComposeTabID ?? active.composeTabs.first?.id)
        return Fixture(composition: composition, tabID: tabID, root: root)
    }
}

@MainActor
private struct Fixture {
    let composition: WindowStateComposition
    let tabID: UUID
    let root: URL

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private actor AsyncSignal {
    private var isSignaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        guard !isSignaled else { return }
        isSignaled = true
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        for waiter in pending {
            waiter.resume()
        }
    }

    func wait() async {
        guard !isSignaled else { return }
        await withCheckedContinuation { continuation in
            if isSignaled {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }
}

private actor FollowUpGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private actor FollowUpRecorder {
    struct Snapshot {
        let dispatchCount: Int
        let cancelledIDs: [UUID]
    }

    private var dispatchCount = 0
    private var cancelledIDs: [UUID] = []

    func recordDispatch() -> Int {
        dispatchCount += 1
        return dispatchCount
    }

    func recordCancellation(_ id: UUID) {
        cancelledIDs.append(id)
    }

    func snapshot() -> Snapshot {
        .init(dispatchCount: dispatchCount, cancelledIDs: cancelledIDs)
    }
}

@MainActor
private func waitUntil(_ condition: @escaping @MainActor () async -> Bool) async {
    for _ in 0 ..< 500 {
        if await condition() { return }
        await Task.yield()
    }
    XCTFail("Condition did not become true")
}

@MainActor
private func XCTAssertThrowsErrorAsync(
    _ expression: @autoclosure () async throws -> some Any,
    _ verify: (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error")
    } catch {
        verify(error)
    }
}

private actor DualOracleActivityRecorder {
    private var phases: [ContextBuilderMCPProgressPhase] = []
    private var messages: [String] = []
    private var suppressedHeartbeats: [ContextBuilderMCPProgressPhase] = []

    func record(_ activity: ContextBuilderMCPActivity) {
        switch activity {
        case let .report(phase, message):
            phases.append(phase)
            messages.append(message)
        case let .suppressHeartbeat(phase):
            suppressedHeartbeats.append(phase)
        }
    }

    func snapshot() -> (
        phases: [ContextBuilderMCPProgressPhase],
        messages: [String],
        suppressedHeartbeats: [ContextBuilderMCPProgressPhase]
    ) {
        (phases, messages, suppressedHeartbeats)
    }
}

private func primaryReply(from result: OracleSendResult) -> ChatSendReply {
    switch result.payload {
    case let .single(reply): reply
    case let .paired(pair): pair.primaryReply()
    }
}

private func reply(id: UUID, text: String) -> ChatSendReply {
    ChatSendReply(chatId: id, shortId: id.uuidString, mode: "plan", response: text, errors: nil)
}

private func singleResult(
    id: UUID,
    context: OracleViewModel.OracleSendTabContext,
    response: String
) -> OracleSendResult {
    OracleSendResult(
        payload: .single(reply(id: id, text: response)),
        route: .init(
            contextID: context.tabID,
            agentSessionID: context.agentModeSessionID,
            agentRunID: context.agentModeRunID
        )
    )
}

private func pairedResult(
    primaryID: UUID,
    secondaryID: UUID,
    primaryModel: AIModel,
    secondary: OraclePairCoordinator.LaneExecution<ChatSendReply>,
    context: OracleViewModel.OracleSendTabContext? = nil
) -> OracleSendResult {
    OracleSendResult(
        payload: .paired(.init(
            pairID: UUID(),
            mode: "plan",
            primaryChatID: primaryID.uuidString,
            secondaryChatID: secondaryID.uuidString,
            primaryModel: primaryModel,
            secondaryModel: .claude4Sonnet,
            result: .init(
                primary: .success(reply(id: primaryID, text: "Primary response")),
                secondary: secondary
            ),
            historyDiverged: false,
            historyPersistenceError: nil
        )),
        route: .init(
            contextID: context?.tabID,
            agentSessionID: context?.agentModeSessionID,
            agentRunID: context?.agentModeRunID
        )
    )
}
