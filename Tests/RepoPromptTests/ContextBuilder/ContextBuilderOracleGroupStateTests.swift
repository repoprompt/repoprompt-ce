import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

final class ContextBuilderOracleGroupStateTests: XCTestCase {
    func testTwoThreeAndFiveLaneRunsAcceptCompleteLifecycle() throws {
        for count in [2, 3, 5] {
            var fixture = try boundState(count: count)
            XCTAssertTrue(fixture.state.accept(
                event(.groupPrepared, fixture: fixture),
                generation: fixture.generation
            ))

            for member in fixture.members {
                XCTAssertTrue(fixture.state.accept(
                    event(.laneStarted, laneID: member.laneID, sequence: 0, fixture: fixture),
                    generation: fixture.generation
                ))
                XCTAssertTrue(fixture.state.accept(
                    event(.laneDelta, laneID: member.laneID, sequence: 1, fixture: fixture),
                    generation: fixture.generation
                ))
                XCTAssertTrue(fixture.state.acceptsLaneCallback(
                    member.laneID,
                    generation: fixture.generation
                ))
                XCTAssertTrue(fixture.state.accept(
                    event(.laneSettled, laneID: member.laneID, sequence: 2, fixture: fixture),
                    generation: fixture.generation
                ))
                XCTAssertFalse(fixture.state.acceptsLaneCallback(
                    member.laneID,
                    generation: fixture.generation
                ))
            }

            XCTAssertTrue(fixture.state.accept(
                event(.groupSettled, fixture: fixture),
                generation: fixture.generation
            ))
            XCTAssertFalse(fixture.state.accept(
                event(.groupSettled, fixture: fixture),
                generation: fixture.generation
            ))
        }
    }

    func testRejectsMalformedAndOutOfOrderLifecycleEvents() throws {
        var fixture = try boundState(count: 2)
        let primary = fixture.members[0].laneID
        let additional = fixture.members[1].laneID

        XCTAssertFalse(fixture.state.accept(
            event(.groupPrepared, laneID: primary, sequence: 0, fixture: fixture),
            generation: fixture.generation
        ))
        XCTAssertFalse(fixture.state.accept(
            event(.groupPrepared, sequence: 0, fixture: fixture),
            generation: fixture.generation
        ))
        XCTAssertTrue(fixture.state.accept(
            event(.groupPrepared, fixture: fixture),
            generation: fixture.generation
        ))
        XCTAssertFalse(fixture.state.accept(
            event(.groupPrepared, fixture: fixture),
            generation: fixture.generation
        ))
        XCTAssertFalse(fixture.state.accept(
            event(.laneStarted, laneID: primary, fixture: fixture),
            generation: fixture.generation
        ))
        XCTAssertFalse(fixture.state.accept(
            event(.laneStarted, sequence: 0, fixture: fixture),
            generation: fixture.generation
        ))
        XCTAssertFalse(fixture.state.accept(
            event(.laneDelta, laneID: primary, sequence: 0, fixture: fixture),
            generation: fixture.generation
        ))
        XCTAssertFalse(fixture.state.accept(
            event(.laneSettled, laneID: primary, sequence: 0, fixture: fixture),
            generation: fixture.generation
        ))
        XCTAssertTrue(fixture.state.accept(
            event(.laneStarted, laneID: primary, sequence: 0, fixture: fixture),
            generation: fixture.generation
        ))
        XCTAssertFalse(fixture.state.accept(
            event(.laneStarted, laneID: primary, sequence: 1, fixture: fixture),
            generation: fixture.generation
        ))
        XCTAssertTrue(fixture.state.accept(
            event(.laneDelta, laneID: primary, sequence: 1, fixture: fixture),
            generation: fixture.generation
        ))
        XCTAssertTrue(fixture.state.accept(
            event(.laneSettled, laneID: primary, sequence: 2, fixture: fixture),
            generation: fixture.generation
        ))
        XCTAssertFalse(fixture.state.acceptsLaneCallback(primary, generation: fixture.generation))
        XCTAssertFalse(fixture.state.accept(
            event(.laneSettled, laneID: primary, sequence: 3, fixture: fixture),
            generation: fixture.generation
        ))
        XCTAssertFalse(fixture.state.accept(
            event(.laneDelta, laneID: primary, sequence: 3, fixture: fixture),
            generation: fixture.generation
        ))
        XCTAssertFalse(fixture.state.accept(
            event(.groupSettled, fixture: fixture),
            generation: fixture.generation
        ))

        XCTAssertTrue(fixture.state.accept(
            event(.laneStarted, laneID: additional, sequence: 0, fixture: fixture),
            generation: fixture.generation
        ))
        XCTAssertTrue(fixture.state.accept(
            event(.laneSettled, laneID: additional, sequence: 1, fixture: fixture),
            generation: fixture.generation
        ))
        XCTAssertFalse(fixture.state.accept(
            event(.groupSettled, laneID: additional, sequence: 2, fixture: fixture),
            generation: fixture.generation
        ))
        XCTAssertTrue(fixture.state.accept(
            event(.groupSettled, fixture: fixture),
            generation: fixture.generation
        ))
        XCTAssertFalse(fixture.state.accept(
            event(.laneDelta, laneID: additional, sequence: 2, fixture: fixture),
            generation: fixture.generation
        ))
        XCTAssertFalse(fixture.state.acceptsLaneCallback(additional, generation: fixture.generation))
    }

    func testReplacementAcceptsOnlyNewGenerationAndMembers() throws {
        var state = ContextBuilderOracleGroupState()
        let oldGeneration = state.beginRun()
        let oldMembers = try members(count: 2, prefix: "old")
        XCTAssertTrue(state.bind(
            groupID: OracleGroupID(),
            turnID: OracleTurnID(),
            members: oldMembers,
            generation: oldGeneration
        ))
        _ = state.invalidateAndTakeMembers()

        let newGeneration = state.beginRun()
        let newGroupID = OracleGroupID()
        let newTurnID = OracleTurnID()
        let newMembers = try members(count: 3, prefix: "new")
        XCTAssertTrue(state.bind(
            groupID: newGroupID,
            turnID: newTurnID,
            members: newMembers,
            generation: newGeneration
        ))
        XCTAssertFalse(state.acceptsLaneCallback(oldMembers[0].laneID, generation: oldGeneration))
        XCTAssertTrue(state.acceptsLaneCallback(newMembers[2].laneID, generation: newGeneration))
        XCTAssertTrue(state.accept(
            OracleProgressEvent(
                kind: .groupPrepared,
                groupID: newGroupID,
                turnID: newTurnID
            ),
            generation: newGeneration
        ))
        XCTAssertTrue(state.accept(
            OracleProgressEvent(
                kind: .laneStarted,
                groupID: newGroupID,
                turnID: newTurnID,
                laneID: newMembers[2].laneID,
                sequence: 0
            ),
            generation: newGeneration
        ))
    }

    func testFinalResultMustMatchPreparedGroupAndOrderedChatIDs() throws {
        let fixture = try boundState(count: 3)
        let matching = try groupResult(
            groupID: fixture.groupID,
            chatIDs: fixture.members.map(\.chatID)
        )
        XCTAssertTrue(fixture.state.matchesFinalResult(
            matching,
            generation: fixture.generation
        ))

        let wrongGroup = try groupResult(
            groupID: OracleGroupID(),
            chatIDs: fixture.members.map(\.chatID)
        )
        XCTAssertFalse(fixture.state.matchesFinalResult(
            wrongGroup,
            generation: fixture.generation
        ))

        let wrongCount = try groupResult(
            groupID: fixture.groupID,
            chatIDs: Array(fixture.members.prefix(2).map(\.chatID))
        )
        XCTAssertFalse(fixture.state.matchesFinalResult(
            wrongCount,
            generation: fixture.generation
        ))

        let wrongOrder = try groupResult(
            groupID: fixture.groupID,
            chatIDs: [
                fixture.members[1].chatID,
                fixture.members[0].chatID,
                fixture.members[2].chatID
            ]
        )
        XCTAssertFalse(fixture.state.matchesFinalResult(
            wrongOrder,
            generation: fixture.generation
        ))
        XCTAssertFalse(fixture.state.matchesFinalResult(
            matching,
            generation: fixture.generation &+ 1
        ))
    }

    func testBindIsOneShotWithinAGeneration() throws {
        var fixture = try boundState(count: 2)
        XCTAssertTrue(fixture.state.accept(
            event(.groupPrepared, fixture: fixture),
            generation: fixture.generation
        ))
        XCTAssertTrue(fixture.state.accept(
            event(.laneStarted, laneID: fixture.members[0].laneID, sequence: 0, fixture: fixture),
            generation: fixture.generation
        ))

        XCTAssertFalse(try fixture.state.bind(
            groupID: OracleGroupID(),
            turnID: OracleTurnID(),
            members: members(count: 2, prefix: "other"),
            generation: fixture.generation
        ))
        XCTAssertEqual(fixture.state.groupID, fixture.groupID)
        XCTAssertEqual(fixture.state.turnID, fixture.turnID)
        XCTAssertEqual(fixture.state.members, fixture.members)
        XCTAssertTrue(fixture.state.acceptsLaneCallback(
            fixture.members[0].laneID,
            generation: fixture.generation
        ))
    }

    @MainActor
    func testUIOriginGroupIgnoresMCPExposureAndSharesCapturedPromptAcrossLanes() async throws {
        let composition = WindowStateCompositionFactory.make(
            windowID: -883,
            deferredInitialAgentSystemWorkspaceRefresh: true,
            sharedMCPService: MCPService()
        )
        await composition.workspaceManager.awaitInitialized()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContextBuilderUIOracleGroup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            composition.oracleViewModel.setOraclePostPackagingTransportOverrideForTesting(nil)
            composition.workspaceManager.prepareForWindowClose()
            try? FileManager.default.removeItem(at: root)
        }

        let workspace = composition.workspaceManager.createWorkspace(
            name: "Context Builder UI Oracle group",
            repoPaths: [root.path],
            ephemeral: true
        )
        var tab = ComposeTabState(name: "UI Oracle group")
        tab.promptText = "Build a plan"
        let workspaceIndex = try XCTUnwrap(
            composition.workspaceManager.workspaces.firstIndex(where: { $0.id == workspace.id })
        )
        composition.workspaceManager.workspaces[workspaceIndex].composeTabs = [tab]
        composition.workspaceManager.workspaces[workspaceIndex].activeComposeTabID = tab.id
        await composition.workspaceManager.switchWorkspace(
            to: composition.workspaceManager.workspaces[workspaceIndex],
            saveState: false,
            reason: #function
        )
        composition.promptManager.loadComposeTabsFromWorkspace(
            composition.workspaceManager.workspaces[workspaceIndex],
            syncPromptText: true
        )
        composition.apiSettingsViewModel.openAIApiKey = "test-key"
        composition.apiSettingsViewModel.isOpenAIKeyValid = true

        let marker = "CONTEXT BUILDER CAPTURED PROMPT"
        let chatPreset = ChatPreset(name: "Captured Plan", mode: .plan)
        let profile = AgentModelsSettingsProfile(
            planningModelRaw: AIModel.gpt54Mini.rawValue,
            additionalOracleModelRaws: [AIModel.gpt54Mini.rawValue]
        )
        let execution = try OracleExecutionResolver(
            resolveModel: AIModel.fromModelName,
            isModelAvailable: { _ in true },
            capturePromptConfiguration: { preset, mode in
                OraclePromptConfiguration(
                    chatPreset: preset,
                    mode: mode,
                    promptContext: PromptContextResolved(
                        includeFiles: true,
                        includeUserPrompt: true,
                        includeMetaPrompts: false,
                        includeFileTree: true,
                        fileTreeMode: .auto,
                        codeMapUsage: .auto,
                        gitInclusion: .none,
                        storedPromptIds: []
                    ),
                    systemPrompt: marker,
                    metaInstructions: []
                )
            }
        ).resolve(
            choice: .automatic,
            mode: "plan",
            snapshot: OracleSelectionSnapshot(
                origin: .contextBuilderUI,
                agentModelsProfile: profile,
                modelPresets: [],
                modelPresetsExposed: false,
                modelPresetsTemporarilyDisabled: true,
                chatPresets: [chatPreset],
                defaultChatPresets: [.plan: chatPreset],
                contextBuilderUIModelStrings: [
                    AIModel.gpt54Mini.rawValue,
                    AIModel.gpt54Mini.rawValue
                ],
                contextBuilderUIChatPreset: chatPreset
            )
        )
        var capturedMessages: [AIMessage] = []
        composition.oracleViewModel.setOraclePostPackagingTransportOverrideForTesting { message, _ in
            capturedMessages.append(message)
            let stream = AsyncThrowingStream<ChatStreamOutput, Error> { continuation in
                continuation.yield(
                    ChatStreamOutput(text: "done", reasoning: nil, tokens: ChatTokenInfo(), terminalOutcome: .completed)
                )
                continuation.finish()
            }
            return (UUID(), stream)
        }
        let owner = try OracleViewModel.oracleGroupOwner(workspaceID: workspace.id, tabID: tab.id)
        let store = AppDomainRuntimeComposition.shared.oracleConversationStore
        var groupIDForCleanup: OracleGroupID?
        defer {
            if let groupIDForCleanup {
                addTeardownBlock {
                    if let retained = try await store.load(groupID: groupIDForCleanup, owner: owner) {
                        try await store.delete(
                            groupID: retained.group.id,
                            owner: owner,
                            expectedRevision: retained.revision
                        )
                    }
                }
            }
        }

        let reply = try await composition.contextBuilderAgentViewModel.runMCPPlanOrQuestion(
            for: WorkspaceSelectionIdentity(workspaceID: workspace.id, tabID: tab.id),
            oracleViewModel: composition.oracleViewModel,
            mode: .plan,
            execution: execution,
            prompt: tab.promptText,
            selection: tab.selection,
            reviewGitContext: .automaticOnly()
        )
        groupIDForCleanup = reply.oracleGroup?.result.groupID

        XCTAssertEqual(reply.oracleGroup?.result.oracleCount, 2)
        XCTAssertEqual(capturedMessages.count, 2)
        XCTAssertTrue(capturedMessages.allSatisfy { $0.systemPrompt == marker })
    }

    @MainActor
    func testPrelaunchFailureUsesOwningGenerationCleanup() async throws {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        defer { GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false) }

        let composition = WindowStateCompositionFactory.make(
            windowID: -884,
            deferredInitialAgentSystemWorkspaceRefresh: true,
            sharedMCPService: MCPService()
        )
        await composition.workspaceManager.awaitInitialized()

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContextBuilderOraclePrelaunch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let workspace = composition.workspaceManager.createWorkspace(
            name: "Context Builder Oracle prelaunch",
            repoPaths: [root.path],
            ephemeral: true
        )
        let tab = ComposeTabState(name: "Prelaunch failure")
        guard let workspaceIndex = composition.workspaceManager.workspaces.firstIndex(where: { $0.id == workspace.id }) else {
            return XCTFail("Expected workspace")
        }
        composition.workspaceManager.workspaces[workspaceIndex].composeTabs = [tab]
        composition.workspaceManager.workspaces[workspaceIndex].activeComposeTabID = tab.id
        await composition.workspaceManager.switchWorkspace(
            to: composition.workspaceManager.workspaces[workspaceIndex],
            saveState: false,
            reason: #function
        )
        composition.promptManager.loadComposeTabsFromWorkspace(
            composition.workspaceManager.workspaces[workspaceIndex],
            syncPromptText: true
        )

        let viewModel = composition.contextBuilderAgentViewModel
        viewModel.replaceSessionForTesting(tabID: tab.id)
        let session = try XCTUnwrap(viewModel.sessions[tab.id])
        let profile = AgentModelsSettingsProfile(
            planningModelRaw: composition.promptManager.preferredAIModel.rawValue,
            additionalOracleModelRaws: [composition.promptManager.preferredAIModel.rawValue]
        )
        let chatPreset = ChatPreset.BuiltIn.plan
        let execution = try OracleExecutionResolver(
            resolveModel: AIModel.fromModelName,
            isModelAvailable: { _ in true },
            capturePromptConfiguration: { preset, mode in
                OraclePromptConfiguration(
                    chatPreset: preset,
                    mode: mode,
                    promptContext: PromptContextResolved(
                        includeFiles: true,
                        includeUserPrompt: true,
                        includeMetaPrompts: false,
                        includeFileTree: true,
                        fileTreeMode: .auto,
                        codeMapUsage: .auto,
                        gitInclusion: .none,
                        storedPromptIds: preset.storedPromptIds
                    ),
                    systemPrompt: preset.name,
                    metaInstructions: []
                )
            }
        ).resolve(
            choice: .automatic,
            mode: "plan",
            snapshot: OracleSelectionSnapshot(
                origin: .contextBuilderUI,
                agentModelsProfile: profile,
                modelPresets: [],
                modelPresetsExposed: false,
                modelPresetsTemporarilyDisabled: false,
                chatPresets: [chatPreset],
                defaultChatPresets: [.plan: chatPreset],
                contextBuilderUIModelStrings: [
                    composition.promptManager.preferredAIModel.rawValue,
                    composition.promptManager.preferredAIModel.rawValue
                ],
                contextBuilderUIChatPreset: chatPreset
            )
        )
        viewModel.installRunTestHooks(.init(
            beforeProcessingProviderEvent: nil,
            providerEventDisposition: nil,
            teardownCompleted: nil,
            isOracleModelAvailable: { _ in true },
            beforeOracleGroupPackaging: {
                throw ProbeError.packagingFailed
            }
        ))
        defer { viewModel.installRunTestHooks(nil) }

        do {
            _ = try await viewModel.runMCPPlanOrQuestion(
                for: WorkspaceSelectionIdentity(workspaceID: workspace.id, tabID: tab.id),
                oracleViewModel: composition.oracleViewModel,
                mode: .plan,
                execution: execution,
                prompt: "Build a plan",
                selection: tab.selection,
                reviewGitContext: .automaticOnly()
            )
            XCTFail("Expected packaging failure")
        } catch {
            XCTAssertEqual(error as? ProbeError, .packagingFailed)
        }

        XCTAssertFalse(session.isBackgroundPlanGenerating)
        XCTAssertNil(session.backgroundPlanResponseText)
        XCTAssertNil(session.backgroundPlanReasoningText)
        XCTAssertNil(session.generatedAnswerRoute)
        XCTAssertNotNil(session.backgroundPlanError)
        XCTAssertNil(session.followUpOracleGroupTask)
        XCTAssertNil(session.followUpOracleGroupState.groupID)
        XCTAssertTrue(session.followUpOracleGroupState.members.isEmpty)

        // A newer run takes ownership while the replacement awaits the old task's drain.
        let newerRoute = ContextBuilderGeneratedAnswerRoute(
            workspaceID: workspace.id,
            tabID: tab.id,
            chatID: "newer-oracle"
        )
        var newerGeneration: UInt64?
        let drainingTask = Task<OracleGroupRuntime.Completion, Error> { @MainActor in
            do {
                try await Task.sleep(for: .seconds(5))
                XCTFail("Expected the previous Oracle task to be cancelled")
            } catch is CancellationError {
                newerGeneration = session.followUpOracleGroupState.beginRun()
                session.generatedAnswerRoute = newerRoute
                session.isBackgroundPlanGenerating = true
                session.backgroundPlanResponseText = "newer answer"
                session.backgroundPlanError = nil
                throw CancellationError()
            }
            throw ProbeError.packagingFailed
        }
        session.followUpOracleGroupTask = drainingTask
        defer { drainingTask.cancel() }

        do {
            _ = try await viewModel.runMCPPlanOrQuestion(
                for: WorkspaceSelectionIdentity(workspaceID: workspace.id, tabID: tab.id),
                oracleViewModel: composition.oracleViewModel,
                mode: .plan,
                execution: execution,
                prompt: "Superseded replacement",
                selection: tab.selection,
                reviewGitContext: .automaticOnly()
            )
            XCTFail("Expected superseded startup to be cancelled")
        } catch is CancellationError {
        } catch {
            XCTFail("Superseded startup reached packaging: \(error)")
        }
        let expectedGeneration = try XCTUnwrap(newerGeneration)
        XCTAssertEqual(session.followUpOracleGroupState.generation, expectedGeneration)
        XCTAssertEqual(session.generatedAnswerRoute, newerRoute)
        XCTAssertEqual(session.backgroundPlanResponseText, "newer answer")
        XCTAssertTrue(session.isBackgroundPlanGenerating)
        XCTAssertNil(session.backgroundPlanError)

        // A queued request cancelled before startup must not invalidate that newer run either.
        let cancelledRequest = Task { @MainActor in
            try await viewModel.runMCPPlanOrQuestion(
                for: WorkspaceSelectionIdentity(workspaceID: workspace.id, tabID: tab.id),
                oracleViewModel: composition.oracleViewModel,
                mode: .plan,
                execution: execution,
                prompt: "Already cancelled replacement",
                selection: tab.selection,
                reviewGitContext: .automaticOnly()
            )
        }
        cancelledRequest.cancel()
        do {
            _ = try await cancelledRequest.value
            XCTFail("Expected cancelled startup to stop before draining")
        } catch is CancellationError {
        } catch {
            XCTFail("Cancelled startup reached packaging: \(error)")
        }
        XCTAssertEqual(session.followUpOracleGroupState.generation, expectedGeneration)
        XCTAssertEqual(session.generatedAnswerRoute, newerRoute)
        XCTAssertEqual(session.backgroundPlanResponseText, "newer answer")
        XCTAssertTrue(session.isBackgroundPlanGenerating)
        XCTAssertNil(session.backgroundPlanError)
    }

    private typealias Fixture = (
        state: ContextBuilderOracleGroupState,
        generation: UInt64,
        groupID: OracleGroupID,
        turnID: OracleTurnID,
        members: [ContextBuilderOracleMemberHandle]
    )

    private func boundState(count: Int) throws -> Fixture {
        var state = ContextBuilderOracleGroupState()
        let generation = state.beginRun()
        let groupID = OracleGroupID()
        let turnID = OracleTurnID()
        let members = try members(count: count, prefix: "chat")
        XCTAssertTrue(state.bind(
            groupID: groupID,
            turnID: turnID,
            members: members,
            generation: generation
        ))
        return (state, generation, groupID, turnID, members)
    }

    private func event(
        _ kind: OracleProgressKind,
        laneID: OracleLaneID? = nil,
        sequence: UInt64? = nil,
        fixture: Fixture
    ) -> OracleProgressEvent {
        OracleProgressEvent(
            kind: kind,
            groupID: fixture.groupID,
            turnID: fixture.turnID,
            laneID: laneID,
            sequence: sequence
        )
    }

    private func groupResult(
        groupID: OracleGroupID,
        chatIDs: [String]
    ) throws -> OracleGroupResult {
        let results = try chatIDs.enumerated().map { index, chatID in
            try OracleLaneResult(
                laneIndex: index,
                chatID: chatID,
                providerID: nil,
                modelID: "model-\(index)",
                status: .completed,
                response: "response-\(index)"
            )
        }
        return try OracleGroupResult(
            groupID: groupID,
            status: .completed,
            oracleResults: results
        )
    }

    private func members(count: Int, prefix: String) throws -> [ContextBuilderOracleMemberHandle] {
        try (0 ..< count).map { index in
            try ContextBuilderOracleMemberHandle(
                laneID: OracleLaneID(index: index),
                sessionID: UUID(),
                chatID: "\(prefix)-\(index)"
            )
        }
    }
}

private enum ProbeError: Error, LocalizedError, Equatable {
    case packagingFailed

    var errorDescription: String? {
        "packaging failed"
    }
}
