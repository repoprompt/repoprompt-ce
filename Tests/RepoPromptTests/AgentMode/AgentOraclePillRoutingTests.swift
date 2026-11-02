import AppKit
import Combine
import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptSettingsCore
import UniformTypeIdentifiers
import XCTest

@MainActor
final class AgentOraclePillRoutingTests: XCTestCase {
    func testExplicitRequestStateRejectsBlankStaleTabAndMismatchedSession() throws {
        let tabID = UUID()
        let otherTabID = UUID()
        let workspaceID = UUID()
        let session = ChatSession(workspaceID: workspaceID, composeTabID: tabID, name: "Exact Session")
        let otherSession = ChatSession(workspaceID: workspaceID, composeTabID: tabID, name: "Other Session")

        XCTAssertNil(
            AgentOraclePillLogic.explicitOpenRequest(
                chatID: "  \n ",
                workspaceID: workspaceID,
                tabID: tabID,
                generation: 1
            )
        )

        let request = try XCTUnwrap(
            AgentOraclePillLogic.explicitOpenRequest(
                chatID: session.id.uuidString.lowercased(),
                workspaceID: workspaceID,
                tabID: tabID,
                generation: 4,
                presentation: .generatedAnswerReadOnly
            )
        )
        XCTAssertEqual(request.presentation, .generatedAnswerReadOnly)
        XCTAssertTrue(
            AgentOraclePillLogic.shouldPresent(
                session: session,
                for: request,
                currentGeneration: 4,
                currentWorkspaceID: workspaceID,
                currentTabID: tabID
            )
        )
        XCTAssertFalse(
            AgentOraclePillLogic.shouldPresent(
                session: session,
                for: request,
                currentGeneration: 5,
                currentWorkspaceID: workspaceID,
                currentTabID: tabID
            )
        )
        XCTAssertNil(AgentOraclePillLogic.reconciledPresentedSessionID(
            currentSessionID: session.id,
            isExplicit: true,
            currentWorkspaceID: UUID(),
            sameTabSessions: [session],
            eligibleSessions: [session],
            streamingSessionIDs: []
        ))
        XCTAssertFalse(
            AgentOraclePillLogic.shouldPresent(
                session: session,
                for: request,
                currentGeneration: 4,
                currentWorkspaceID: workspaceID,
                currentTabID: otherTabID
            )
        )
        XCTAssertFalse(
            AgentOraclePillLogic.shouldPresent(
                session: otherSession,
                for: request,
                currentGeneration: 4,
                currentWorkspaceID: workspaceID,
                currentTabID: tabID
            )
        )
        XCTAssertFalse(
            AgentOraclePillLogic.shouldPresent(
                session: session,
                for: request,
                currentGeneration: 4,
                currentWorkspaceID: UUID(),
                currentTabID: tabID
            )
        )
    }

    func testCompletedOracleHistorySurvivesRunAdvanceWithinSameAgentSession() {
        let workspaceID = UUID()
        let tabID = UUID()
        let agentID = UUID()
        let previousRunID = UUID()
        let nextRunID = UUID()
        let previous = ChatSession(
            workspaceID: workspaceID,
            composeTabID: tabID,
            agentModeSessionID: agentID,
            agentModeRunID: previousRunID,
            name: "Completed Oracle",
            messages: [StoredMessage(isUser: false, rawText: "Completed answer", sequenceIndex: 0)]
        )
        let otherAgent = ChatSession(
            agentModeSessionID: UUID(),
            agentModeRunID: nextRunID,
            name: "Other agent",
            messages: previous.messages
        )
        let legacy = ChatSession(name: "Unowned", messages: previous.messages)
        let sessions = [otherAgent, previous, legacy]
        let eligible = AgentOraclePillLogic.eligibleSessions(
            sessions: sessions,
            streamingSessionIDs: [],
            liveMessageCount: { _ in nil },
            activeAgentSessionID: agentID,
            activeRunID: nextRunID
        )
        XCTAssertEqual(eligible.map(\.id), [previous.id])
        XCTAssertEqual(AgentOraclePillLogic.latestSession(in: eligible, streamingSessionIDs: [])?.id, previous.id)
        XCTAssertEqual(AgentOraclePillLogic.reconciledPresentedSessionID(
            currentSessionID: previous.id,
            isExplicit: false,
            currentWorkspaceID: workspaceID,
            sameTabSessions: sessions,
            eligibleSessions: eligible,
            streamingSessionIDs: []
        ), previous.id)
        XCTAssertEqual(AgentOraclePillLogic.selectedSessionID(
            currentSelectionID: previous.id,
            in: eligible,
            streamingSessionIDs: []
        ), previous.id)
    }

    func testCurrentRunOracleDisplacesHistoryOnlyWhenRenderableOrStreaming() {
        let agentID = UUID()
        let runID = UUID()
        let history = ChatSession(
            agentModeSessionID: agentID,
            agentModeRunID: UUID(),
            name: "History",
            messages: [StoredMessage(isUser: false, rawText: "Answer", sequenceIndex: 0)]
        )
        let current = ChatSession(agentModeSessionID: agentID, agentModeRunID: runID, name: "Current")
        for (streamingIDs, expectedID) in [(Set<UUID>(), history.id), (Set([current.id]), current.id)] {
            let eligible = AgentOraclePillLogic.eligibleSessions(
                sessions: [history, current],
                streamingSessionIDs: streamingIDs,
                liveMessageCount: { _ in nil },
                activeAgentSessionID: agentID,
                activeRunID: runID
            )
            XCTAssertEqual(eligible.map(\.id), [expectedID])
        }
        let eligible = AgentOraclePillLogic.eligibleSessions(
            sessions: [history, current],
            streamingSessionIDs: [],
            liveMessageCount: { $0 == current.id ? 1 : nil },
            activeAgentSessionID: agentID,
            activeRunID: runID
        )
        XCTAssertEqual(eligible.map(\.id), [current.id])
        XCTAssertEqual(AgentOraclePillLogic.selectedSessionID(
            currentSelectionID: history.id,
            in: eligible,
            streamingSessionIDs: []
        ), current.id)
    }

    func testOracleHistoryFallbackPreservesOwnerAndLegacyPrecedence() {
        let agentID = UUID()
        let runID = UUID()
        let messages = [StoredMessage(isUser: false, rawText: "Answer", sequenceIndex: 0)]
        let history = ChatSession(agentModeSessionID: agentID, agentModeRunID: UUID(), name: "History", messages: messages)
        let runless = ChatSession(agentModeSessionID: agentID, name: "Runless", messages: messages)
        let unowned = ChatSession(name: "Unowned", messages: messages)
        let other = ChatSession(agentModeSessionID: UUID(), agentModeRunID: runID, name: "Other", messages: messages)
        let cases: [(sessions: [ChatSession], agent: UUID?, run: UUID?, expected: [UUID])] = [
            ([history, runless, unowned, other], agentID, runID, [runless.id]),
            ([other, unowned], agentID, runID, [unowned.id]),
            ([other], agentID, runID, []),
            ([history, other, unowned], nil, UUID(), [unowned.id]),
            ([history, other, unowned], nil, runID, [other.id]),
            ([history, other, unowned], agentID, nil, [history.id])
        ]
        for item in cases {
            XCTAssertEqual(AgentOraclePillLogic.eligibleSessions(
                sessions: item.sessions,
                streamingSessionIDs: [],
                liveMessageCount: { _ in nil },
                activeAgentSessionID: item.agent,
                activeRunID: item.run
            ).map(\.id), item.expected)
        }
    }

    func testTranscriptActionPolicyMatchesPopoverPresentation() {
        XCTAssertEqual(
            AgentOraclePillLogic.transcriptActionPolicy(for: .standard),
            .standard
        )
        XCTAssertEqual(
            AgentOraclePillLogic.transcriptActionPolicy(for: .generatedAnswerReadOnly),
            .nonMutating
        )
    }

    func testExactInMemoryResolutionUsesUUIDOrShortIDInsteadOfLatestSession() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }

        let exact = ChatSession(
            workspaceID: fixture.workspace.id,
            composeTabID: fixture.tabID,
            name: "Exact Session",
            savedAt: Date(timeIntervalSince1970: 100),
            messages: [StoredMessage(isUser: false, rawText: "exact", sequenceIndex: 0)]
        )
        let newer = ChatSession(
            workspaceID: fixture.workspace.id,
            composeTabID: fixture.tabID,
            name: "Newer Session",
            savedAt: Date(timeIntervalSince1970: 200),
            messages: [StoredMessage(isUser: false, rawText: "newer", sequenceIndex: 0)]
        )
        fixture.oracleViewModel.sessions = [exact, newer]
        let didLoadExactSessionMessages = await fixture.oracleViewModel.ensureSessionMessagesLoaded(exact.id)
        XCTAssertTrue(didLoadExactSessionMessages)

        XCTAssertEqual(
            AgentOraclePillLogic.latestSession(
                in: fixture.oracleViewModel.sessions(forTabID: fixture.tabID),
                streamingSessionIDs: [newer.id]
            )?.id,
            newer.id
        )

        let byUUID = await fixture.oracleViewModel.resolveExactSessionForPopover(
            chatID: exact.id.uuidString.lowercased(),
            workspaceID: fixture.workspace.id,
            tabID: fixture.tabID
        )
        XCTAssertEqual(byUUID?.id, exact.id)

        let byShortID = await fixture.oracleViewModel.resolveExactSessionForPopover(
            chatID: exact.shortID,
            workspaceID: fixture.workspace.id,
            tabID: fixture.tabID
        )
        XCTAssertEqual(byShortID?.id, exact.id)
        XCTAssertEqual(fixture.oracleViewModel.messagesSnapshot(for: exact.id).count, 1)
    }

    func testLatestStreamingSessionDoesNotFallbackToStaleCompletedSession() {
        let workspaceID = UUID()
        let tabID = UUID()
        let olderStreaming = ChatSession(
            workspaceID: workspaceID,
            composeTabID: tabID,
            name: "Older Streaming",
            savedAt: Date(timeIntervalSince1970: 100)
        )
        let staleCompleted = ChatSession(
            workspaceID: workspaceID,
            composeTabID: tabID,
            name: "Stale Completed",
            savedAt: Date(timeIntervalSince1970: 300)
        )
        let newerStreaming = ChatSession(
            workspaceID: workspaceID,
            composeTabID: tabID,
            name: "Newer Streaming",
            savedAt: Date(timeIntervalSince1970: 200)
        )
        let sessions = [olderStreaming, staleCompleted, newerStreaming]

        XCTAssertEqual(
            AgentOraclePillLogic.latestSession(
                in: sessions,
                streamingSessionIDs: [olderStreaming.id, newerStreaming.id]
            )?.id,
            newerStreaming.id
        )
        XCTAssertEqual(
            AgentOraclePillLogic.latestStreamingSession(
                in: sessions,
                streamingSessionIDs: [olderStreaming.id, newerStreaming.id]
            )?.id,
            newerStreaming.id
        )
        XCTAssertNil(AgentOraclePillLogic.latestStreamingSession(
            in: sessions,
            streamingSessionIDs: []
        ))
        XCTAssertEqual(
            AgentOraclePillLogic.latestSession(
                in: sessions,
                streamingSessionIDs: []
            )?.id,
            staleCompleted.id
        )
    }

    func testExactPersistedResolutionHydratesAndRegistersUUIDAndShortID() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }

        let persisted = ChatSession(
            workspaceID: fixture.workspace.id,
            composeTabID: fixture.tabID,
            name: "Persisted Exact Session",
            savedAt: Date(timeIntervalSince1970: 100),
            messages: [StoredMessage(isUser: false, rawText: "persisted", sequenceIndex: 0)]
        )
        _ = try await fixture.oracleViewModel.chatData.saveChatSession(
            persisted,
            for: fixture.workspace
        )
        let distractor = ChatSession(
            workspaceID: fixture.workspace.id,
            composeTabID: fixture.tabID,
            name: "Newer Distractor",
            savedAt: Date(timeIntervalSince1970: 300),
            messages: [StoredMessage(isUser: false, rawText: "distractor", sequenceIndex: 0)]
        )
        fixture.oracleViewModel.sessions = [distractor]

        let byShortID = await fixture.oracleViewModel.resolveExactSessionForPopover(
            chatID: persisted.shortID,
            workspaceID: fixture.workspace.id,
            tabID: fixture.tabID
        )
        XCTAssertEqual(byShortID?.id, persisted.id)
        XCTAssertEqual(
            fixture.oracleViewModel.sessions.first(where: { $0.id == persisted.id })?.messages.count,
            1
        )
        XCTAssertEqual(fixture.oracleViewModel.messagesSnapshot(for: persisted.id).count, 1)

        fixture.oracleViewModel.sessions = [distractor]
        let byUUID = await fixture.oracleViewModel.resolveExactSessionForPopover(
            chatID: persisted.id.uuidString.lowercased(),
            workspaceID: fixture.workspace.id,
            tabID: fixture.tabID
        )
        XCTAssertEqual(byUUID?.id, persisted.id)
        XCTAssertTrue(fixture.oracleViewModel.sessions.contains(where: { $0.id == persisted.id }))

        let collidingShortID = "shared-oracle-chat"
        let persistedCollision = ChatSession(
            workspaceID: fixture.workspace.id,
            composeTabID: fixture.tabID,
            name: "Persisted Collision",
            messages: [StoredMessage(isUser: false, rawText: "same-tab collision", sequenceIndex: 0)],
            shortID: collidingShortID
        )
        _ = try await fixture.oracleViewModel.chatData.saveChatSession(
            persistedCollision,
            for: fixture.workspace
        )
        let wrongTabCollision = ChatSession(
            workspaceID: fixture.workspace.id,
            composeTabID: fixture.otherTabID,
            name: "Wrong Tab Collision",
            messages: [StoredMessage(isUser: false, rawText: "wrong-tab collision", sequenceIndex: 0)],
            shortID: collidingShortID
        )
        fixture.oracleViewModel.sessions = [distractor, wrongTabCollision]

        let collisionResult = await fixture.oracleViewModel.resolveExactSessionForPopover(
            chatID: collidingShortID,
            workspaceID: fixture.workspace.id,
            tabID: fixture.tabID
        )
        XCTAssertEqual(collisionResult?.id, persistedCollision.id)
        XCTAssertEqual(collisionResult?.composeTabID, fixture.tabID)
    }

    func testExactPersistedResolutionRejectsWrongTabAndUnknownWithoutLatestFallback() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }

        let wrongTab = ChatSession(
            workspaceID: fixture.workspace.id,
            composeTabID: fixture.otherTabID,
            name: "Wrong Tab Session",
            messages: [StoredMessage(isUser: false, rawText: "wrong tab", sequenceIndex: 0)]
        )
        _ = try await fixture.oracleViewModel.chatData.saveChatSession(
            wrongTab,
            for: fixture.workspace
        )
        let latest = ChatSession(
            workspaceID: fixture.workspace.id,
            composeTabID: fixture.tabID,
            name: "Latest Session",
            savedAt: Date(timeIntervalSince1970: 500),
            messages: [StoredMessage(isUser: false, rawText: "latest", sequenceIndex: 0)]
        )
        fixture.oracleViewModel.sessions = [latest]

        let wrongTabResult = await fixture.oracleViewModel.resolveExactSessionForPopover(
            chatID: wrongTab.shortID,
            workspaceID: fixture.workspace.id,
            tabID: fixture.tabID
        )
        XCTAssertNil(wrongTabResult)

        let unknownResult = await fixture.oracleViewModel.resolveExactSessionForPopover(
            chatID: UUID().uuidString,
            workspaceID: fixture.workspace.id,
            tabID: fixture.tabID
        )
        XCTAssertNil(unknownResult)
        XCTAssertEqual(fixture.oracleViewModel.sessions.map(\.id), [latest.id])

        let persistedBeforeReassignment = ChatSession(
            workspaceID: fixture.workspace.id,
            composeTabID: fixture.tabID,
            name: "Reassigned Session",
            messages: [StoredMessage(isUser: false, rawText: "persisted tab", sequenceIndex: 0)]
        )
        _ = try await fixture.oracleViewModel.chatData.saveChatSession(
            persistedBeforeReassignment,
            for: fixture.workspace
        )
        var reassignedInMemory = persistedBeforeReassignment
        reassignedInMemory.composeTabID = fixture.otherTabID
        fixture.oracleViewModel.sessions = [latest, reassignedInMemory]

        let staleDiskResult = await fixture.oracleViewModel.resolveExactSessionForPopover(
            chatID: persistedBeforeReassignment.shortID,
            workspaceID: fixture.workspace.id,
            tabID: fixture.tabID
        )
        XCTAssertNil(staleDiskResult)
        XCTAssertEqual(
            fixture.oracleViewModel.sessions.first(where: { $0.id == persistedBeforeReassignment.id })?.composeTabID,
            fixture.otherTabID
        )
    }

    func testExactResolutionRejectsSameTabShortIDCollisionsInMemoryAndOnDisk() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }

        let sharedShortID = "same-tab-collision"
        let first = ChatSession(
            workspaceID: fixture.workspace.id,
            composeTabID: fixture.tabID,
            name: "First Collision",
            messages: [StoredMessage(isUser: false, rawText: "first", sequenceIndex: 0)],
            shortID: sharedShortID
        )
        let second = ChatSession(
            workspaceID: fixture.workspace.id,
            composeTabID: fixture.tabID,
            name: "Second Collision",
            messages: [StoredMessage(isUser: false, rawText: "second", sequenceIndex: 0)],
            shortID: sharedShortID
        )

        fixture.oracleViewModel.sessions = [first, second]
        let inMemoryCollision = await fixture.oracleViewModel.resolveExactSessionForPopover(
            chatID: sharedShortID,
            workspaceID: fixture.workspace.id,
            tabID: fixture.tabID
        )
        XCTAssertNil(inMemoryCollision)

        _ = try await fixture.oracleViewModel.chatData.saveChatSession(first, for: fixture.workspace)
        _ = try await fixture.oracleViewModel.chatData.saveChatSession(second, for: fixture.workspace)
        fixture.oracleViewModel.sessions = [first]
        let mixedCollision = await fixture.oracleViewModel.resolveExactSessionForPopover(
            chatID: sharedShortID,
            workspaceID: fixture.workspace.id,
            tabID: fixture.tabID
        )
        XCTAssertNil(mixedCollision)

        fixture.oracleViewModel.sessions = []
        let persistedCollision = await fixture.oracleViewModel.resolveExactSessionForPopover(
            chatID: sharedShortID,
            workspaceID: fixture.workspace.id,
            tabID: fixture.tabID
        )
        XCTAssertNil(persistedCollision)
    }

    func testExactResolutionRejectsWorkspaceMismatch() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }

        let session = ChatSession(
            workspaceID: fixture.workspace.id,
            composeTabID: fixture.tabID,
            name: "Workspace Bound",
            messages: [StoredMessage(isUser: false, rawText: "workspace", sequenceIndex: 0)]
        )
        fixture.oracleViewModel.sessions = [session]

        let wrongWorkspace = await fixture.oracleViewModel.resolveExactSessionForPopover(
            chatID: session.shortID,
            workspaceID: UUID(),
            tabID: fixture.tabID
        )
        XCTAssertNil(wrongWorkspace)
    }

    func testAggregateOraclePillCountAndLabelsUseConfiguredOrLatestProjectedGroup() {
        let historical = ChatSession(
            oracleGroupID: UUID(),
            oracleLaneIndex: 0,
            oracleGroupSize: 5,
            name: "Historical",
            savedAt: Date(timeIntervalSince1970: 100)
        )
        let latestSingle = ChatSession(
            name: "Latest Single",
            savedAt: Date(timeIntervalSince1970: 200)
        )
        let latestGroupID = UUID()
        let latestProjected = ChatSession(
            oracleGroupID: latestGroupID,
            oracleLaneIndex: 0,
            oracleGroupSize: 4,
            name: "Latest Group",
            savedAt: Date(timeIntervalSince1970: 300)
        )
        let staleSiblingProjection = ChatSession(
            oracleGroupID: latestGroupID,
            oracleLaneIndex: 1,
            oracleGroupSize: 5,
            name: "Stale Group Sibling",
            savedAt: Date(timeIntervalSince1970: 200)
        )
        let invalidProjected = ChatSession(
            oracleGroupID: UUID(),
            oracleLaneIndex: 0,
            oracleGroupSize: 99,
            name: "Invalid Projection",
            savedAt: Date(timeIntervalSince1970: 400)
        )

        XCTAssertEqual(
            AgentOraclePillLogic.aggregateOracleCount(
                configuredAdditionalCount: 0,
                sessions: [historical, latestSingle]
            ),
            1
        )
        XCTAssertEqual(
            AgentOraclePillLogic.aggregateOracleCount(
                configuredAdditionalCount: 0,
                sessions: [historical, staleSiblingProjection, latestProjected]
            ),
            4
        )
        XCTAssertEqual(
            AgentOraclePillLogic.aggregateOracleCount(configuredAdditionalCount: 2, sessions: []),
            3
        )
        XCTAssertEqual(
            AgentOraclePillLogic.aggregateOracleCount(configuredAdditionalCount: 0, sessions: [invalidProjected]),
            5
        )
        XCTAssertFalse(AgentOraclePillLogic.canCopyAll(latestSingle))
        XCTAssertTrue(AgentOraclePillLogic.canCopyAll(latestProjected))
        XCTAssertEqual(
            (0 ... 4).map(OracleViewModel.oracleLabel(laneIndex:)),
            ["Oracle", "Oracle 2", "Oracle 3", "Oracle 4", "Oracle 5"]
        )
    }

    func testGroupedExecutionCapturesExactQueryMessageNameAndNeverFallsBackToPredecessor() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        // sendMessage rechecks availability before the placeholder and transport override exist.
        fixture.composition.apiSettingsViewModel.isOpenAIKeyValid = true
        let vm = fixture.oracleViewModel
        defer { vm.setOraclePostPackagingTransportOverrideForTesting(nil) }
        let profile = AgentModelsSettingsProfile(
            planningModelRaw: AIModel.gpt54.rawValue,
            additionalOracleModelRaws: [AIModel.gpt54Mini.rawValue]
        )
        let snapshot = OracleSelectionSnapshot(
            origin: .mcp, agentModelsProfile: profile, modelPresets: [],
            modelPresetsExposed: false, modelPresetsTemporarilyDisabled: false,
            chatPresets: ChatPreset.BuiltIn.all(),
            defaultChatPresets: [.chat: ChatPreset.BuiltIn.chat]
        )
        let execution = try OracleExecutionResolver(
            resolveModel: AIModel.fromModelName,
            isModelAvailable: { _ in true },
            capturePromptConfiguration: { preset, mode in
                OraclePromptConfiguration(
                    chatPreset: preset, mode: mode,
                    promptContext: PromptContextResolved(
                        includeFiles: false, includeUserPrompt: true, includeMetaPrompts: false,
                        includeFileTree: false, fileTreeMode: .auto, codeMapUsage: .auto,
                        gitInclusion: GitInclusion.none, storedPromptIds: []
                    ),
                    systemPrompt: "Identity capture test", metaInstructions: []
                )
            }
        ).resolve(choice: .oracleSend("current_chat_model"), mode: "chat", snapshot: snapshot)
        let exactName = "  Exact current assistant footer—not the request ID  "
        var queryIDs: [Int: UUID] = [:]
        vm.setOraclePostPackagingTransportOverrideForTesting { _, model in
            let session = try XCTUnwrap(vm.sessions.first { $0.preferredAIModel == model.rawValue })
            let laneIndex = try XCTUnwrap(session.oracleLaneIndex)
            let messages = vm.messagesSnapshot(for: session.id)
            XCTAssertTrue(messages.contains { !$0.isUser && $0.modelName == "PREDECESSOR_MODEL" })
            let activeQueryID = try XCTUnwrap(vm.activeQueryId(for: session.id))
            let query = try XCTUnwrap(messages.first { $0.id == activeQueryID && !$0.isUser })
            XCTAssertNotEqual(query.modelName, "PREDECESSOR_MODEL")
            XCTAssertEqual(vm.oracleMemberPresentation(for: session).capturedModelName, query.modelName, "Placeholder callback publishes this exact query before transport")
            queryIDs[laneIndex] = query.id
            vm.updateMessage(withId: query.id) { message in
                message = AIChatMessage(
                    id: query.id, content: "", isUser: false,
                    modelName: laneIndex == 1 ? exactName : nil
                )
            }
            let stream = AsyncThrowingStream<ChatStreamOutput, Error> { continuation in
                continuation.yield(ChatStreamOutput(
                    text: "answer-\(laneIndex)", reasoning: nil,
                    tokens: ChatTokenInfo(), terminalOutcome: .completed
                ))
                continuation.finish()
            }
            return (UUID(), stream)
        }
        let store = AppDomainRuntimeComposition.shared.oracleConversationStore
        let owner = try OracleViewModel.oracleGroupOwner(workspaceID: fixture.workspace.id, tabID: fixture.tabID)
        let completion = try await vm.tool_chatSendWithConfiguredRosterCompletion(
            args: ["message": .string("capture identity"), "new_chat": .bool(true)],
            promptVM: fixture.composition.promptManager,
            tabContext: oracleTabContext(fixture),
            callbacks: AppOracleGroupExecutionCallbacks(
                prepared: { groupID, _, members in
                    self.addTeardownBlock {
                        if let retained = try await store.load(groupID: groupID, owner: owner) {
                            try await store.delete(groupID: groupID, owner: owner, expectedRevision: retained.revision)
                        }
                    }
                    for member in members {
                        let index = try XCTUnwrap(vm.sessions.firstIndex { $0.id == member.memberID.rawValue })
                        XCTAssertNil(vm.oracleMemberPresentation(for: vm.sessions[index]).capturedModelName)
                        vm.sessions[index].messages = [StoredMessage(
                            isUser: false, rawText: "previous turn", modelName: "PREDECESSOR_MODEL"
                        )]
                        let loaded = await vm.ensureSessionMessagesLoaded(member.memberID.rawValue)
                        XCTAssertTrue(loaded)
                    }
                },
                progress: { _ in }, laneProgress: { _, _, _ in }
            ),
            capturedProfile: profile,
            selectionSnapshotOverride: snapshot,
            resolvedStartExecution: execution
        )
        // Settled background lanes may already be unloaded; wait for their saves before reading disk or cleaning up.
        await vm.drainTrackedAutosaves(for: fixture.workspace.id)
        let laneErrors = completion.result.oracleResults.compactMap(\.error).map(\.message).joined(separator: "\n")
        XCTAssertEqual(completion.result.oracleResults.map(\.status), [.completed, .completed], laneErrors)
        XCTAssertEqual(completion.result.oracleResults.map(\.capturedModelName), [nil, exactName])
        XCTAssertEqual(queryIDs.count, 2)
        for member in completion.terminalDocument.members {
            let queryID = try XCTUnwrap(queryIDs[member.laneID.index])
            let session = try XCTUnwrap(vm.sessions.first { $0.id == member.memberID.rawValue })
            let fileURL = try XCTUnwrap(session.fileURL)
            let storedSession = try await vm.chatData.loadChatSession(from: fileURL)
            let query = try XCTUnwrap(storedSession.messages.first { $0.id == queryID && !$0.isUser })
            XCTAssertEqual(completion.result.oracleResults[member.laneID.index].capturedModelName, query.modelName)
        }
        let projections = vm.sessions
        vm.sessions = []
        vm.sessions = projections
        let selected = try XCTUnwrap(projections.first { $0.oracleLaneIndex == 0 })
        await vm.loadOracleGroupPresentation(containing: selected)
        XCTAssertNil(vm.oracleMemberPresentation(for: selected).capturedModelName, "Primary must not borrow its predecessor or the background lane's name")
        let sibling = try XCTUnwrap(projections.first { $0.oracleLaneIndex == 1 })
        XCTAssertEqual(vm.oracleMemberPresentation(for: sibling).capturedModelName, exactName)
    }

    func testGroupedCurrentTurnModelNameRejectsStaleCallbacksAndNeverBorrowsAnotherLane() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let models = try [
            OracleModelReference(modelID: "codex_custom_requested"),
            OracleModelReference(modelID: "grokbuild_custom_requested")
        ]
        let group = try makeCanonicalOracleGroup(fixture: fixture, models: models).group
        let member = group.members[0]
        var session = makeProjection(member: member, group: group, fixture: fixture)
        session.messages = [StoredMessage(isUser: false, rawText: "previous answer", modelName: "PREDECESSOR_MODEL")]
        let sibling = makeProjection(member: group.members[1], group: group, fixture: fixture)
        let turnID = try XCTUnwrap(group.turns.last?.id)
        let invocationID = UUID()
        var presentation = OracleGroupPresentation(document: group, invocationID: invocationID)
        XCTAssertNil(presentation.member(session).providerID)
        XCTAssertNil(presentation.member(session).capturedModelName, "No current placeholder; request IDs and prior messages are not display authority")
        presentation.captureModelName("SIBLING_MODEL", providerID: "grokBuild", member: group.members[1], turnID: turnID, invocationID: invocationID)
        XCTAssertNil(presentation.member(session).capturedModelName)
        XCTAssertNil(presentation.member(session).providerID)
        XCTAssertEqual(presentation.member(sibling).capturedModelName, "SIBLING_MODEL")
        XCTAssertEqual(presentation.member(sibling).providerID, "grokBuild")

        let mismatchedMember = try OracleGroupMember(
            laneID: member.laneID, memberID: member.memberID,
            publicChatID: "not-the-current-member", model: member.model
        )
        let staleCallbacks: [(OracleGroupMember, OracleTurnID, UUID)] = [
            (member, OracleTurnID(rawValue: UUID()), invocationID),
            (member, turnID, UUID()),
            (mismatchedMember, turnID, invocationID)
        ]
        for (callbackMember, callbackTurn, callbackInvocation) in staleCallbacks {
            presentation.captureModelName("STALE_MODEL", providerID: "bogus-provider", member: callbackMember, turnID: callbackTurn, invocationID: callbackInvocation)
            XCTAssertNil(presentation.member(session).capturedModelName)
            XCTAssertNil(presentation.member(session).providerID)
        }

        let exactName = "CLI·Captured display name (High)"
        presentation.captureModelName(exactName, providerID: "codex", member: member, turnID: turnID, invocationID: invocationID)
        var mismatchedSession = session
        mismatchedSession.shortID = "replacement-projection"
        XCTAssertNil(presentation.member(mismatchedSession).capturedModelName)
        XCTAssertNil(presentation.member(mismatchedSession).providerID)
        mismatchedSession = session
        mismatchedSession.workspaceID = UUID()
        XCTAssertNil(presentation.member(mismatchedSession).capturedModelName)
        XCTAssertNil(presentation.member(mismatchedSession).providerID)
        for (sequence, kind) in [OracleProgressKind.laneStarted, .laneSettled].enumerated() {
            presentation.receive(OracleProgressEvent(
                kind: kind, groupID: group.group.id, turnID: turnID,
                laneID: member.laneID, sequence: UInt64(sequence)
            ))
            XCTAssertEqual(presentation.member(session).capturedModelName, exactName)
            XCTAssertEqual(presentation.member(session).providerID, "codex")
        }
        XCTAssertEqual(presentation.member(session).status, .settled)
        XCTAssertEqual(presentation.member(sibling).capturedModelName, "SIBLING_MODEL")
        XCTAssertEqual(presentation.member(sibling).providerID, "grokBuild")
        for (callbackMember, callbackTurn, callbackInvocation) in staleCallbacks {
            presentation.captureModelName("STALE_MODEL", providerID: "bogus-provider", member: callbackMember, turnID: callbackTurn, invocationID: callbackInvocation)
            XCTAssertEqual(presentation.member(session).capturedModelName, exactName)
            XCTAssertEqual(presentation.member(session).providerID, "codex")
        }
        presentation.captureModelName(nil, member: member, turnID: turnID, invocationID: invocationID)
        XCTAssertNil(presentation.member(session).capturedModelName, "No surviving exact-query message must not preserve an older name")
        XCTAssertEqual(presentation.member(session).providerID, "codex")
        presentation.captureModelName(exactName, providerID: "codex", member: member, turnID: turnID, invocationID: invocationID)
        presentation.endExecution()
        XCTAssertNil(presentation.member(session).capturedModelName)
        XCTAssertNil(presentation.member(session).providerID)
        presentation.captureModelName("LATE_MODEL", providerID: "bogus-provider", member: member, turnID: turnID, invocationID: invocationID)
        XCTAssertNil(presentation.member(session).capturedModelName, "Ended invocations cannot republish identity")
        XCTAssertNil(presentation.member(session).providerID)
    }

    func testGroupedTerminalModelNameIsAuthoritativeAcrossColdReloadAndLegacyRemainsUnavailable() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let prepared = try makeCanonicalOracleGroup(fixture: fixture).group
        let store = AppDomainRuntimeComposition.shared.oracleConversationStore
        try await store.create(prepared)
        addTeardownBlock { try? await self.deleteCanonicalOracleGroup(prepared) }
        let vm = fixture.oracleViewModel
        var projections = prepared.members.map { makeProjection(member: $0, group: prepared, fixture: fixture) }
        projections[1].messages = [StoredMessage(isUser: false, rawText: "older response", modelName: "OLD_FOOTER")]
        vm.sessions = projections
        let invocationID = UUID()
        let turnID = try XCTUnwrap(prepared.turns.last?.id)
        var live = OracleGroupPresentation(document: prepared, invocationID: invocationID)
        live.captureModelName("LIVE_MODEL", providerID: "codex", member: prepared.members[0], turnID: turnID, invocationID: invocationID)
        vm.oracleGroupPresentations[live.key] = live
        XCTAssertEqual(vm.oracleMemberPresentation(for: projections[0]).capturedModelName, "LIVE_MODEL")
        XCTAssertEqual(vm.oracleMemberPresentation(for: projections[0]).providerID, "codex")

        let terminalName = "  Claude Code exact terminal footer  "
        let terminal = try terminalGroup(prepared, secondaryStatus: .failed, capturedModelNames: [0: terminalName])
        _ = try await OracleGroupTerminalPublisher.publish(
            terminal: terminal, expectedRevision: prepared.revision, store: store
        )
        vm.recordOracleGroupPresentation(terminal)
        XCTAssertEqual(vm.oracleMemberPresentation(for: projections[0]).capturedModelName, terminalName)
        XCTAssertNil(vm.oracleMemberPresentation(for: projections[0]).providerID, "Canonical legacy result replaces transient provider identity")
        XCTAssertNil(vm.oracleMemberPresentation(for: projections[1]).capturedModelName, "Legacy result must not borrow a stored footer")
        var terminalPresentation = try XCTUnwrap(vm.oracleGroupPresentations[live.key])
        terminalPresentation.captureModelName("LATE_MODEL", providerID: "bogus-provider", member: prepared.members[0], turnID: turnID, invocationID: invocationID)
        XCTAssertEqual(terminalPresentation.member(projections[0]).capturedModelName, terminalName)
        XCTAssertNil(terminalPresentation.member(projections[0]).providerID)
        vm.recordOracleGroupPresentation(prepared, invocationID: invocationID)
        XCTAssertEqual(vm.oracleMemberPresentation(for: projections[0]).capturedModelName, terminalName, "Older prepared publication cannot replace terminal identity")

        vm.sessions = []
        XCTAssertTrue(vm.oracleGroupPresentations.isEmpty)
        vm.sessions = projections
        await vm.loadOracleGroupPresentation(containing: projections[0])
        XCTAssertEqual(vm.oracleMemberPresentation(for: projections[0]).capturedModelName, terminalName)
        XCTAssertNil(vm.oracleMemberPresentation(for: projections[0]).providerID)
        XCTAssertNil(vm.oracleMemberPresentation(for: projections[1]).capturedModelName)
        XCTAssertEqual(vm.oracleMemberPresentation(for: projections[1]).status, .failed)
    }

    func testGroupedContinuationPreservesLegacyNilProviderRoster() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let vm = fixture.oracleViewModel
        // Configure only the fixture's availability flags; all transport remains stubbed.
        fixture.composition.apiSettingsViewModel.isOpenAIKeyValid = true
        fixture.composition.apiSettingsViewModel.isAnthropicKeyValid = true
        let models = try [AIModel.gpt54, .claude4Sonnet].map {
            try OracleModelReference(modelID: $0.rawValue)
        }
        let prepared = try makeCanonicalOracleGroup(fixture: fixture, models: models).group
        let store = AppDomainRuntimeComposition.shared.oracleConversationStore
        try await store.create(prepared)
        addTeardownBlock { try? await self.deleteCanonicalOracleGroup(prepared) }
        let terminal = try terminalGroup(prepared, secondaryStatus: .completed)
        let previousTurnID = try XCTUnwrap(terminal.turns.last?.id)
        _ = try await OracleGroupTerminalPublisher.publish(
            terminal: terminal, expectedRevision: prepared.revision, store: store
        )
        let projections = terminal.members.map { makeProjection(member: $0, group: terminal, fixture: fixture) }
        vm.sessions = projections
        let profile = AgentModelsSettingsProfile(
            planningModelRaw: AIModel.gpt54Mini.rawValue,
            additionalOracleModelRaws: [AIModel.gpt54Mini.rawValue]
        )
        let snapshot = OracleSelectionSnapshot(
            origin: .mcp, agentModelsProfile: profile, modelPresets: [],
            modelPresetsExposed: false, modelPresetsTemporarilyDisabled: false,
            chatPresets: ChatPreset.BuiltIn.all(),
            defaultChatPresets: [.chat: ChatPreset.BuiltIn.chat]
        )
        let transportsReady = expectation(description: "Both continuation lanes reached stub transport")
        transportsReady.expectedFulfillmentCount = 2
        let firstLaneSettled = expectation(description: "Primary settled while sibling transport remains gated")
        var streams: [Int: AsyncThrowingStream<ChatStreamOutput, Error>.Continuation] = [:]
        vm.setOraclePostPackagingTransportOverrideForTesting { _, model in
            let laneIndex = try XCTUnwrap(models.firstIndex { $0.modelID == model.rawValue })
            let (stream, continuation) = AsyncThrowingStream<ChatStreamOutput, Error>.makeStream()
            streams[laneIndex] = continuation
            transportsReady.fulfill()
            return (UUID(), stream)
        }
        defer {
            vm.setOraclePostPackagingTransportOverrideForTesting(nil)
            for stream in streams.values {
                stream.finish()
            }
        }
        var capturedMembers: [OracleGroupMember]?
        let invocation = Task { @MainActor in
            try await vm.tool_chatSendWithConfiguredRosterCompletion(
                args: ["message": .string("continue"), "chat_id": .string(terminal.members[0].publicChatID)],
                promptVM: fixture.composition.promptManager,
                tabContext: oracleTabContext(fixture),
                callbacks: AppOracleGroupExecutionCallbacks(
                    prepared: { _, _, members in capturedMembers = members },
                    progress: { event in
                        if event.kind == .laneSettled, event.laneID == terminal.members[0].laneID {
                            firstLaneSettled.fulfill()
                        }
                    },
                    laneProgress: { _, _, _ in }
                ),
                capturedProfile: profile,
                selectionSnapshotOverride: snapshot
            )
        }
        defer { invocation.cancel() }
        await fulfillment(of: [transportsReady], timeout: 5)
        XCTAssertEqual(streams.count, 2)
        XCTAssertEqual(projections.map { vm.oracleMemberPresentation(for: $0).status }, [.streaming, .streaming])
        XCTAssertEqual(projections.map { vm.oracleMemberPresentation(for: $0).providerID }, ["openAI", "anthropic"])

        streams[0]?.yield(ChatStreamOutput(
            text: "primary continuation", reasoning: nil, tokens: ChatTokenInfo(), terminalOutcome: .completed
        ))
        streams[0]?.finish()
        await fulfillment(of: [firstLaneSettled], timeout: 5)
        XCTAssertEqual(vm.oracleMemberPresentation(for: projections[0]).status, .settled)
        XCTAssertEqual(vm.oracleMemberPresentation(for: projections[1]).status, .streaming)
        XCTAssertEqual(projections.map { vm.oracleMemberPresentation(for: $0).providerID }, ["openAI", "anthropic"])

        if let key = OracleGroupPresentation.Key(session: projections[0]),
           let current = vm.oracleGroupPresentations[key],
           let turnID = current.turnID, let invocationID = current.invocationID
        {
            var challenged = current
            challenged.captureModelName("stale turn", providerID: "bogus-prior-turn-provider", member: terminal.members[0], turnID: previousTurnID, invocationID: invocationID)
            XCTAssertEqual(challenged, current, "Prior-turn callbacks cannot replace current identity")
            challenged.captureModelName("stale invocation", providerID: "bogus-other-invocation-provider", member: terminal.members[0], turnID: turnID, invocationID: UUID())
            XCTAssertEqual(challenged, current, "Other invocations cannot replace current identity")
        } else {
            XCTFail("A current invocation must remain observable while its sibling is gated")
        }

        streams[1]?.yield(ChatStreamOutput(
            text: "sibling continuation", reasoning: nil, tokens: ChatTokenInfo(), terminalOutcome: .completed
        ))
        streams[1]?.finish()
        let completion = try await invocation.value
        await vm.drainTrackedAutosaves(for: fixture.workspace.id)
        XCTAssertEqual(try XCTUnwrap(capturedMembers), terminal.members)
        let laneErrors = completion.result.oracleResults.compactMap(\.error).map(\.message).joined(separator: "\n")
        XCTAssertEqual(completion.result.oracleResults.map(\.status), [.completed, .completed], laneErrors)
        XCTAssertEqual(completion.result.oracleResults.map { $0.executionProfile?.providerID }, ["openAI", "anthropic"])
        let loaded = try await store.load(groupID: terminal.group.id, owner: terminal.owner)
        let continued = try XCTUnwrap(loaded)
        XCTAssertEqual(continued.roster, terminal.roster)
        XCTAssertEqual(continued.members, terminal.members)
        XCTAssertTrue(continued.roster.orderedModels.allSatisfy { $0.providerID == nil })
        XCTAssertEqual(continued.turns.count, terminal.turns.count + 1)
        XCTAssertEqual(continued.turns.first, terminal.turns.first, "Continuation does not backfill historical metadata")
    }

    func testGroupedMemberStatusUsesPersistedFailureWithoutAssistantErrorText() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let prepared = try makeCanonicalOracleGroup(fixture: fixture).group
        let store = AppDomainRuntimeComposition.shared.oracleConversationStore
        try await store.create(prepared)
        addTeardownBlock { try? await self.deleteCanonicalOracleGroup(prepared) }
        let terminal = try terminalGroup(prepared, secondaryStatus: .failed)
        _ = try await OracleGroupTerminalPublisher.publish(
            terminal: terminal,
            expectedRevision: prepared.revision,
            store: store
        )
        var completed = makeProjection(member: prepared.members[0], group: prepared, fixture: fixture)
        var failed = makeProjection(member: prepared.members[1], group: prepared, fixture: fixture)
        fixture.oracleViewModel.sessions = [completed, failed]
        let canonical = try await fixture.oracleViewModel.oracleGroupCopyPayload(containing: failed)
        XCTAssertEqual(canonical.lanes.map(\.status), [.completed, .failed])
        await fixture.oracleViewModel.loadOracleGroupPresentation(containing: failed)

        let pill = AgentOraclePill(
            oracleViewModel: fixture.oracleViewModel,
            windowID: -1,
            currentTabID: fixture.tabID,
            activeAgentSessionID: nil,
            activeRunID: nil
        )
        completed.messages = [StoredMessage(isUser: false, rawText: "Completed sibling answer")]
        fixture.oracleViewModel.sessions = [completed, failed]
        XCTAssertEqual(pill.memberDotState(for: completed), .completed, "loaded completed sibling")
        completed.messages = []
        fixture.oracleViewModel.sessions = [completed, failed]
        XCTAssertEqual(pill.memberDotState(for: completed), .completed, "unloaded completed sibling")

        let user = StoredMessage(isUser: true, rawText: "test")
        let cases: [(String, [StoredMessage])] = [
            ("empty", []),
            ("user-only", [user]),
            ("partial", [user, StoredMessage(isUser: false, rawText: "Unmarked partial answer")])
        ]
        for (label, messages) in cases {
            failed.messages = messages
            fixture.oracleViewModel.sessions = [completed, failed]
            XCTAssertEqual(pill.memberDotState(for: failed), .failed, label)
        }
    }

    func testGroupedStatusUsesCurrentOutcomeIdentityAndMatchingLiveEvidence() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let vm = fixture.oracleViewModel
        let cases: [(OracleLaneResultStatus, OracleMemberPresentation.Status)] = [
            (.completed, .completed), (.failed, .failed), (.cancelled, .cancelled)
        ]
        for (canonicalStatus, expected) in cases {
            let prepared = try makeCanonicalOracleGroup(fixture: fixture).group
            var member = makeProjection(member: prepared.members[1], group: prepared, fixture: fixture)
            member.messages = [StoredMessage(isUser: false, rawText: "Error: not an outcome")]
            let sibling = makeProjection(member: prepared.members[0], group: prepared, fixture: fixture)
            vm.sessions = [sibling, member]
            let pill = AgentOraclePill(
                oracleViewModel: vm, windowID: -1, currentTabID: fixture.tabID,
                activeAgentSessionID: nil, activeRunID: nil
            )
            let turnID = try XCTUnwrap(prepared.turns.last?.id)
            let started = OracleProgressEvent(
                kind: .laneStarted, groupID: prepared.group.id, turnID: turnID,
                laneID: prepared.members[1].laneID, sequence: 0
            )
            vm.recordOracleGroupPresentation(prepared)
            vm.receiveOracleGroupProgress(started, owner: prepared.owner)
            XCTAssertEqual(vm.oracleMemberPresentation(for: member).status, .unknown, "prepared is not live")

            vm.recordOracleGroupPresentation(prepared, invocationID: UUID())
            vm.receiveOracleGroupProgress(started, owner: prepared.owner)
            XCTAssertEqual(vm.oracleMemberPresentation(for: member).status, .streaming)
            vm.receiveOracleGroupProgress(OracleProgressEvent(
                kind: .laneStarted, groupID: prepared.group.id, turnID: turnID,
                laneID: prepared.members[0].laneID, sequence: 0
            ), owner: prepared.owner)
            vm.receiveOracleGroupProgress(OracleProgressEvent(
                kind: .laneSettled, groupID: prepared.group.id, turnID: turnID,
                laneID: prepared.members[1].laneID, sequence: 1, text: canonicalStatus.rawValue
            ), owner: prepared.owner)
            vm.receiveOracleGroupProgress(started, owner: prepared.owner)
            XCTAssertEqual(pill.memberDotState(for: member), .settled, "settled progress is not publication")
            XCTAssertEqual(pill.memberDotState(for: member).rawValue, "Settled · awaiting group")
            XCTAssertEqual(pill.memberDotState(for: sibling), .streaming, "sibling is still running")
            XCTAssertNil(vm.oracleMemberPresentation(for: member).errorMessage)
            vm.recordOracleGroupPresentation(prepared)
            let ignoredEvents = [
                OracleProgressEvent(
                    kind: .laneStarted, groupID: prepared.group.id, turnID: turnID,
                    laneID: prepared.members[1].laneID, sequence: 1
                ),
                OracleProgressEvent(
                    kind: .laneSettled, groupID: prepared.group.id, turnID: turnID,
                    laneID: prepared.members[1].laneID
                ),
                OracleProgressEvent(
                    kind: .laneStarted, groupID: prepared.group.id, turnID: OracleTurnID(rawValue: UUID()),
                    laneID: prepared.members[1].laneID, sequence: 2
                ),
                OracleProgressEvent(
                    kind: .groupSettled, groupID: prepared.group.id, turnID: turnID,
                    sequence: 2, text: canonicalStatus.rawValue
                )
            ]
            for event in ignoredEvents {
                vm.receiveOracleGroupProgress(event, owner: prepared.owner)
            }
            XCTAssertEqual(pill.memberDotState(for: member), .settled, "stale, missing and mismatched evidence cannot reset settlement")
            XCTAssertEqual(pill.memberDotState(for: sibling), .streaming)

            let terminal = try terminalGroup(prepared, secondaryStatus: canonicalStatus)
            vm.recordOracleGroupPresentation(terminal)
            vm.receiveOracleGroupProgress(started, owner: prepared.owner)
            vm.recordOracleGroupPresentation(prepared)
            XCTAssertEqual(vm.oracleMemberPresentation(for: member).status, expected, "terminal beats text, live and older loads")
            XCTAssertEqual(
                vm.oracleMemberPresentation(for: member).errorMessage,
                canonicalStatus == .completed ? nil : "[provider_failed] Synthetic lane failure"
            )

            let nextTurn = try OracleTurnRecord(
                input: OracleInput(mode: .chat, userMessage: "next"),
                state: .prepared, startedAt: terminal.updatedAt.addingTimeInterval(1)
            )
            let replacement = try OracleGroupDocument(
                group: terminal.group, owner: terminal.owner, name: terminal.name,
                revision: terminal.revision + 1, createdAt: terminal.createdAt,
                updatedAt: nextTurn.startedAt, roster: terminal.roster, members: terminal.members,
                turns: terminal.turns + [nextTurn]
            )
            let invocationID = UUID()
            vm.recordOracleGroupPresentation(replacement, invocationID: invocationID)
            vm.receiveOracleGroupProgress(started, owner: prepared.owner)
            vm.recordOracleGroupPresentation(terminal)
            XCTAssertEqual(vm.oracleMemberPresentation(for: member).status, .unknown, "new turn fences old results/events")
            vm.receiveOracleGroupProgress(OracleProgressEvent(
                kind: .laneSettled, groupID: replacement.group.id, turnID: nextTurn.id,
                laneID: prepared.members[1].laneID, sequence: 0, text: "completed"
            ), owner: prepared.owner)
            await vm.finishOracleGroupPresentation(invocationID: UUID())
            XCTAssertEqual(pill.memberDotState(for: member), .settled, "unrelated invocation cannot end settlement")
            await vm.finishOracleGroupPresentation(invocationID: invocationID)
            vm.recordOracleGroupPresentation(replacement)
            vm.receiveOracleGroupProgress(OracleProgressEvent(
                kind: .laneStarted, groupID: replacement.group.id, turnID: nextTurn.id,
                laneID: prepared.members[1].laneID, sequence: 0
            ), owner: prepared.owner)
            XCTAssertEqual(vm.oracleMemberPresentation(for: member).status, .unknown, "failed publication cannot stay live")

            var mismatched = member
            mismatched.shortID = "different-member"
            vm.sessions = [mismatched]
            XCTAssertEqual(vm.oracleMemberPresentation(for: member).status, .unknown, "replaced projection")
            XCTAssertEqual(vm.oracleMemberPresentation(for: mismatched).status, .unknown, "member identity")
            mismatched.workspaceID = UUID()
            vm.sessions = [mismatched]
            vm.recordOracleGroupPresentation(terminal)
            XCTAssertEqual(vm.oracleMemberPresentation(for: mismatched).status, .unknown, "owner identity")
            XCTAssertTrue(vm.oracleGroupPresentations.isEmpty, "no retained status for absent owners/groups")
        }
    }

    func testOpenGroupPresentationObservesExceptionalOutcomesAndColdReloadWithoutProvider() async throws {
        for expected in [OracleMemberPresentation.Status.failed, .cancelled] {
            let fixture = try await makeFixture()
            defer { fixture.cleanup() }
            let prepared = try makeCanonicalOracleGroup(fixture: fixture).group
            let store = AppDomainRuntimeComposition.shared.oracleConversationStore
            try await store.create(prepared)
            addTeardownBlock { try? await self.deleteCanonicalOracleGroup(prepared) }
            let projections = prepared.members.map { makeProjection(member: $0, group: prepared, fixture: fixture) }
            let selected = projections[1]
            let vm = fixture.oracleViewModel
            vm.sessions = projections
            let pill = AgentOraclePill(
                oracleViewModel: vm, windowID: -1, currentTabID: fixture.tabID,
                activeAgentSessionID: nil, activeRunID: nil
            )
            let key = try XCTUnwrap(OracleGroupPresentation.Key(session: selected))
            var observed: [OracleMemberPresentation.Status] = []
            let observation = vm.$oracleGroupPresentations.sink { snapshots in
                observed.append(snapshots[key]?.member(selected).status ?? .unknown)
            }
            defer { observation.cancel() }
            await vm.loadOracleGroupPresentation(containing: selected)
            XCTAssertEqual(pill.memberDotState(for: selected), .unknown)
            var sawPrepared = false
            let invocation = Task { @MainActor in
                do {
                    _ = try await vm.tool_chatSendWithConfiguredRosterCompletion(
                        args: ["message": .string("next"), "chat_id": .string(selected.shortID)],
                        promptVM: fixture.composition.promptManager,
                        tabContext: oracleTabContext(fixture),
                        callbacks: AppOracleGroupExecutionCallbacks(
                            prepared: { _, _, _ in
                                sawPrepared = true
                                XCTAssertEqual(pill.memberDotState(for: selected), .unknown)
                                // Cancel the invoking task, not just the thrown error: reconciliation must
                                // still observe the runtime's published cancellation without a provider run.
                                if expected == .cancelled {
                                    withUnsafeCurrentTask { $0?.cancel() }
                                    XCTAssertTrue(Task.isCancelled)
                                    throw CancellationError()
                                }
                                throw OracleProjectionRoutingTestStop.afterPrepared
                            },
                            progress: { _ in }, laneProgress: { _, _, _ in }
                        ),
                        capturedProfile: AgentModelsSettingsProfile(
                            planningModelRaw: "model-a", additionalOracleModelRaws: ["model-b"]
                        )
                    )
                    XCTFail("Expected prepared callback stop")
                } catch OracleProjectionRoutingTestStop.afterPrepared {
                    XCTAssertEqual(expected, .failed)
                } catch is CancellationError {
                    XCTAssertEqual(expected, .cancelled)
                    XCTAssertTrue(Task.isCancelled)
                }
            }
            try await invocation.value
            XCTAssertTrue(sawPrepared)
            let loaded = try await store.load(groupID: prepared.group.id, owner: prepared.owner)
            let canonical = try XCTUnwrap(loaded)
            XCTAssertEqual(
                canonical.turns.last?.results.map(\.status),
                expected == .cancelled ? [.cancelled, .cancelled] : [.failed, .failed]
            )
            XCTAssertEqual(observed.first, .unknown)
            XCTAssertEqual(observed.last, expected, "existing subscriber sees actual publication")
            XCTAssertEqual(pill.memberDotState(for: selected), expected, "same presentation, without a reload call")
            XCTAssertNotNil(vm.oracleMemberPresentation(for: selected).errorMessage)
            XCTAssertTrue(vm.sessions.allSatisfy(\.messages.isEmpty), "no fabricated error transcript")

            vm.sessions = []
            XCTAssertTrue(vm.oracleGroupPresentations.isEmpty)
            vm.sessions = projections
            await vm.loadOracleGroupPresentation(containing: selected)
            XCTAssertEqual(pill.memberDotState(for: selected), expected, "cold presentation uses stored latest turn")
            try await deleteCanonicalOracleGroup(prepared)
            await vm.loadOracleGroupPresentation(containing: selected)
            XCTAssertEqual(pill.memberDotState(for: selected), .unknown, "missing authority cannot preserve stale success/failure")
        }
    }

    func testGroupedDeleteFallsBackToProjectionCleanupWhenCanonicalDocumentIsMissing() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        var projection = ChatSession(
            workspaceID: fixture.workspace.id,
            composeTabID: fixture.tabID,
            oracleGroupID: UUID(),
            oracleLaneIndex: 0,
            oracleGroupSize: 2,
            name: "Missing Canonical Group",
            messages: [StoredMessage(isUser: false, rawText: "preserve me", sequenceIndex: 0)]
        )
        projection.fileURL = try await fixture.oracleViewModel.chatData.saveChatSession(
            projection,
            for: fixture.workspace
        )
        fixture.oracleViewModel.sessions = [projection]

        let handledAsGroup = try await fixture.oracleViewModel.deleteOracleGroupIfNeeded(containing: projection)
        XCTAssertFalse(handledAsGroup)
        await fixture.oracleViewModel.deleteSession(projection)
        XCTAssertTrue(fixture.oracleViewModel.sessions.isEmpty)
        XCTAssertFalse(try FileManager.default.fileExists(atPath: XCTUnwrap(projection.fileURL).path))
    }

    func testExplicitGroupedContinuationFailsClosedWhenProjectionCanonicalGroupIsMissing() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let projection = ChatSession(
            workspaceID: fixture.workspace.id,
            composeTabID: fixture.tabID,
            oracleGroupID: UUID(),
            oracleLaneIndex: 0,
            oracleGroupSize: 2,
            oracleModelRaw: "model-a",
            name: "Orphan Group Projection",
            messages: [StoredMessage(isUser: false, rawText: "preserve me", sequenceIndex: 0)]
        )
        fixture.oracleViewModel.sessions = [projection]

        await assertChatToolError(
            code: .internalError,
            message: "Canonical Oracle group was not found."
        ) {
            _ = try await fixture.oracleViewModel.tool_chatSendWithConfiguredRoster(
                args: [
                    "message": .string("continue"),
                    "chat_id": .string(projection.id.uuidString.lowercased())
                ],
                promptVM: fixture.composition.promptManager,
                tabContext: oracleTabContext(fixture),
                capturedProfile: AgentModelsSettingsProfile(planningModelRaw: "model-a")
            )
        }
        XCTAssertEqual(fixture.oracleViewModel.sessions.map(\.id), [projection.id])
        XCTAssertEqual(fixture.oracleViewModel.sessions.first?.messages.map(\.rawText), ["preserve me"])
    }

    func testGroupedContinuationRejectsProjectionIdentityMismatches() async throws {
        struct ProjectionMismatchCase {
            let name: String
            let mutate: (inout ChatSession, OracleGroupDocument, OracleGroupMember, Fixture) -> Void
        }
        let cases: [ProjectionMismatchCase] = [
            ProjectionMismatchCase(name: "member ID") { projection, _, _, _ in
                projection = ChatSession(
                    id: UUID(),
                    workspaceID: projection.workspaceID,
                    composeTabID: projection.composeTabID,
                    oracleGroupID: projection.oracleGroupID,
                    oracleLaneIndex: projection.oracleLaneIndex,
                    oracleGroupSize: projection.oracleGroupSize,
                    oracleModelRaw: projection.oracleModelRaw,
                    name: projection.name,
                    shortID: projection.shortID
                )
            },
            ProjectionMismatchCase(name: "short/public chat ID") { projection, _, _, _ in
                projection.shortID = "wrong-public-chat"
            },
            ProjectionMismatchCase(name: "member and public chat IDs") { projection, _, _, _ in
                projection = ChatSession(
                    id: UUID(),
                    workspaceID: projection.workspaceID,
                    composeTabID: projection.composeTabID,
                    oracleGroupID: projection.oracleGroupID,
                    oracleLaneIndex: projection.oracleLaneIndex,
                    oracleGroupSize: projection.oracleGroupSize,
                    oracleModelRaw: projection.oracleModelRaw,
                    name: projection.name,
                    shortID: "wrong-public-chat"
                )
            },
            ProjectionMismatchCase(name: "workspace") { projection, _, _, _ in
                projection.workspaceID = UUID()
            },
            ProjectionMismatchCase(name: "tab") { projection, _, _, fixture in
                projection.composeTabID = fixture.otherTabID
            },
            ProjectionMismatchCase(name: "group") { projection, _, _, _ in
                projection.oracleGroupID = UUID()
            },
            ProjectionMismatchCase(name: "lane") { projection, _, _, _ in
                projection.oracleLaneIndex = 1
            },
            ProjectionMismatchCase(name: "size") { projection, _, _, _ in
                projection.oracleGroupSize = 3
            },
            ProjectionMismatchCase(name: "model") { projection, _, _, _ in
                projection.oracleModelRaw = "different-model"
            }
        ]

        for mismatch in cases {
            let fixture = try await makeFixture()
            let canonical = try makeCanonicalOracleGroup(fixture: fixture)
            try await AppDomainRuntimeComposition.shared.oracleConversationStore.create(canonical.group)
            addTeardownBlock { try? await self.deleteCanonicalOracleGroup(canonical.group) }
            var projection = makeProjection(
                member: canonical.group.members[0],
                group: canonical.group,
                fixture: fixture
            )
            mismatch.mutate(&projection, canonical.group, canonical.group.members[0], fixture)
            let unchangedIdentity = ProjectionIdentitySnapshot(projection)
            fixture.oracleViewModel.sessions = [projection]

            await assertChatToolError(
                code: .internalError,
                message: "Oracle group projection identity conflict.",
                mismatch.name
            ) {
                _ = try await fixture.oracleViewModel.tool_chatSendWithConfiguredRosterCompletion(
                    args: [
                        "message": .string("continue"),
                        "chat_id": .string(canonical.group.members[0].publicChatID)
                    ],
                    promptVM: fixture.composition.promptManager,
                    tabContext: oracleTabContext(fixture),
                    callbacks: stopAfterPreparedCallbacks(),
                    capturedProfile: AgentModelsSettingsProfile(
                        planningModelRaw: "model-a",
                        additionalOracleModelRaws: ["model-b"]
                    )
                )
            }
            XCTAssertEqual(
                fixture.oracleViewModel.sessions.first.map(ProjectionIdentitySnapshot.init),
                unchangedIdentity,
                mismatch.name
            )
            try await deleteCanonicalOracleGroup(canonical.group)
            fixture.cleanup()
        }
    }

    func testGroupedContinuationRejectsDuplicateCanonicalLaneClaims() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let canonical = try makeCanonicalOracleGroup(fixture: fixture)
        try await AppDomainRuntimeComposition.shared.oracleConversationStore.create(canonical.group)
        addTeardownBlock { try? await self.deleteCanonicalOracleGroup(canonical.group) }
        let member = canonical.group.members[0]
        let projection = makeProjection(member: member, group: canonical.group, fixture: fixture)
        let duplicate = ChatSession(
            id: UUID(),
            workspaceID: fixture.workspace.id,
            composeTabID: fixture.tabID,
            oracleGroupID: canonical.group.group.id.rawValue,
            oracleLaneIndex: member.laneID.index,
            oracleGroupSize: canonical.group.group.size,
            oracleModelRaw: member.model.modelID,
            name: projection.name,
            shortID: "duplicate-canonical-lane"
        )
        fixture.oracleViewModel.sessions = [projection, duplicate]

        await assertChatToolError(
            code: .internalError,
            message: "Oracle group projection identity conflict."
        ) {
            _ = try await fixture.oracleViewModel.tool_chatSendWithConfiguredRosterCompletion(
                args: [
                    "message": .string("continue"),
                    "chat_id": .string(member.publicChatID)
                ],
                promptVM: fixture.composition.promptManager,
                tabContext: oracleTabContext(fixture),
                callbacks: stopAfterPreparedCallbacks(),
                capturedProfile: AgentModelsSettingsProfile(
                    planningModelRaw: "model-a",
                    additionalOracleModelRaws: ["model-b"]
                )
            )
        }
        XCTAssertEqual(fixture.oracleViewModel.sessions.map(\.id), [projection.id, duplicate.id])
    }

    func testGroupedProjectionRestorationRepairsNameOnlyWhenIdentityMatches() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let canonical = try makeCanonicalOracleGroup(fixture: fixture)
        try await AppDomainRuntimeComposition.shared.oracleConversationStore.create(canonical.group)
        addTeardownBlock { try? await self.deleteCanonicalOracleGroup(canonical.group) }
        var projection = makeProjection(
            member: canonical.group.members[0],
            group: canonical.group,
            fixture: fixture
        )
        projection.name = "Mutable presentation name"
        let beforeIdentity = ProjectionIdentitySnapshot(projection)
        fixture.oracleViewModel.sessions = [projection]

        do {
            _ = try await fixture.oracleViewModel.tool_chatSendWithConfiguredRosterCompletion(
                args: [
                    "message": .string("continue"),
                    "chat_id": .string(canonical.group.members[0].publicChatID)
                ],
                promptVM: fixture.composition.promptManager,
                tabContext: oracleTabContext(fixture),
                callbacks: stopAfterPreparedCallbacks(),
                capturedProfile: AgentModelsSettingsProfile(
                    planningModelRaw: "model-a",
                    additionalOracleModelRaws: ["model-b"]
                )
            )
            XCTFail("Expected prepared callback stop")
        } catch OracleProjectionRoutingTestStop.afterPrepared {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let restored = try XCTUnwrap(fixture.oracleViewModel.sessions.first)
        XCTAssertEqual(restored.name, OracleViewModel.oracleProjectionName(base: canonical.group.name, laneIndex: 0))
        XCTAssertEqual(ProjectionIdentitySnapshot(restored), beforeIdentity)
    }

    func testLegacyMessageOnlySelectionPrefersTabActiveThenMostRecentEligibleSession() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let active = ChatSession(
            workspaceID: fixture.workspace.id,
            composeTabID: fixture.tabID,
            name: "Active",
            savedAt: Date(timeIntervalSince1970: 100)
        )
        let recentGroupProjection = ChatSession(
            workspaceID: fixture.workspace.id,
            composeTabID: fixture.tabID,
            oracleGroupID: UUID(),
            oracleLaneIndex: 0,
            oracleGroupSize: 2,
            name: "Recent Group Projection",
            savedAt: Date(timeIntervalSince1970: 200)
        )
        fixture.oracleViewModel.sessions = [active, recentGroupProjection]
        fixture.composition.workspaceManager.setActiveChatSessionID(active.id, forTabID: fixture.tabID)

        let selectedActive = try await fixture.oracleViewModel.locateOrCreateChat(
            nil,
            tabID: fixture.tabID,
            activateInUI: false
        )
        XCTAssertEqual(selectedActive, active.id)

        fixture.composition.workspaceManager.setActiveChatSessionID(nil, forTabID: fixture.tabID)
        XCTAssertEqual(
            fixture.oracleViewModel.resolveImplicitOracleContinuationCandidate(
                tabID: fixture.tabID,
                activateInUI: false
            )?.id,
            recentGroupProjection.id
        )
        let selectedRecent = try await fixture.oracleViewModel.locateOrCreateChat(
            nil,
            tabID: fixture.tabID,
            activateInUI: false
        )
        XCTAssertEqual(selectedRecent, recentGroupProjection.id)
        XCTAssertEqual(fixture.oracleViewModel.sessions.count, 2)
    }

    func testFrozenImplicitSessionIdentitySurvivesShortIDCollision() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let sharedShortID = "collision-shared"
        let first = ChatSession(
            workspaceID: fixture.workspace.id,
            composeTabID: fixture.tabID,
            name: "First",
            savedAt: Date(timeIntervalSince1970: 200),
            shortID: sharedShortID
        )
        let selected = ChatSession(
            workspaceID: fixture.workspace.id,
            composeTabID: fixture.tabID,
            name: "Selected",
            savedAt: Date(timeIntervalSince1970: 100),
            shortID: sharedShortID
        )
        fixture.oracleViewModel.sessions = [first, selected]
        fixture.composition.workspaceManager.setActiveChatSessionID(selected.id, forTabID: fixture.tabID)

        let candidate = try XCTUnwrap(fixture.oracleViewModel.resolveImplicitOracleContinuationCandidate(
            tabID: fixture.tabID,
            activateInUI: false
        ))
        XCTAssertEqual(candidate.id, selected.id)
        XCTAssertEqual(fixture.oracleViewModel.resolveSession(id: sharedShortID)?.id, first.id)

        let resumed = try await fixture.oracleViewModel.locateOrCreateChat(
            nil,
            tabID: fixture.tabID,
            activateInUI: false,
            implicitSessionID: candidate.id
        )
        XCTAssertEqual(resumed, selected.id)
    }

    func testFrozenImplicitSessionIdentityPreservesSessionOwnerMatchWithoutExplicitRejection() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let agentSessionID = UUID()
        let session = ChatSession(
            workspaceID: fixture.workspace.id,
            composeTabID: fixture.tabID,
            agentModeSessionID: agentSessionID,
            agentModeRunID: UUID(),
            name: "Session-Owned Legacy Run"
        )
        fixture.oracleViewModel.sessions = [session]

        let candidate = try XCTUnwrap(fixture.oracleViewModel.resolveImplicitOracleContinuationCandidate(
            tabID: fixture.tabID,
            activateInUI: false,
            agentModeSessionID: agentSessionID,
            agentModeRunID: nil
        ))
        XCTAssertEqual(candidate.id, session.id)
        XCTAssertFalse(OracleViewModel.sessionMatchesOracleOwnerForExplicitContinuation(
            session,
            agentModeSessionID: agentSessionID,
            agentModeRunID: nil
        ))

        let resumed = try await fixture.oracleViewModel.locateOrCreateChat(
            nil,
            tabID: fixture.tabID,
            activateInUI: false,
            agentModeSessionID: agentSessionID,
            agentModeRunID: nil,
            implicitSessionID: candidate.id
        )
        XCTAssertEqual(resumed, session.id)
    }

    func testGroupedDeleteRejectsProjectionThatIsNotACanonicalMember() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let owner = try OracleConversationOwner(
            kind: "app-tab",
            identifier: "workspace:\(fixture.workspace.id.uuidString):tab:\(fixture.tabID.uuidString)"
        )
        let models = try ["model-a", "model-b"].map {
            try OracleModelReference(providerID: "fixture", modelID: $0)
        }
        let descriptor = try OracleGroupDescriptor(size: models.count)
        let members = try models.enumerated().map { index, model in
            try OracleGroupMember(
                laneID: OracleLaneID(index: index),
                publicChatID: "canonical-\(index)",
                model: model
            )
        }
        let timestamp = Date(timeIntervalSince1970: 1000)
        let group = try OracleGroupDocument(
            group: descriptor,
            owner: owner,
            name: "Canonical Group",
            revision: 1,
            createdAt: timestamp,
            updatedAt: timestamp,
            roster: OracleRoster(primary: models[0], additional: Array(models.dropFirst())),
            members: members,
            turns: [OracleTurnRecord(
                input: OracleInput(mode: .chat, userMessage: "test"),
                state: .prepared,
                startedAt: timestamp
            )]
        )
        let store = AppDomainRuntimeComposition.shared.oracleConversationStore
        try await store.create(group)
        var mismatchedProjection = ChatSession(
            workspaceID: fixture.workspace.id,
            composeTabID: fixture.tabID,
            oracleGroupID: descriptor.id.rawValue,
            oracleLaneIndex: 0,
            oracleGroupSize: 2,
            name: "Forged Projection",
            messages: [StoredMessage(isUser: false, rawText: "preserve me", sequenceIndex: 0)]
        )
        mismatchedProjection.fileURL = try await fixture.oracleViewModel.chatData.saveChatSession(
            mismatchedProjection,
            for: fixture.workspace
        )
        fixture.oracleViewModel.sessions = [mismatchedProjection]

        let handledAsGroup = try await fixture.oracleViewModel.deleteOracleGroupIfNeeded(containing: mismatchedProjection)
        let retained = try await store.load(groupID: descriptor.id, owner: owner)
        if let retained {
            try await store.delete(
                groupID: retained.group.id,
                owner: owner,
                expectedRevision: retained.revision
            )
        }

        XCTAssertFalse(handledAsGroup)
        XCTAssertNotNil(retained)
        XCTAssertEqual(fixture.oracleViewModel.sessions.map(\.id), [mismatchedProjection.id])
        XCTAssertTrue(try FileManager.default.fileExists(atPath: XCTUnwrap(mismatchedProjection.fileURL).path))
    }

    private func assertChatToolError(
        code: ChatToolErrorCode,
        message: String,
        _ context: String = "",
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected ChatToolError \(context)")
        } catch let error as ChatToolError {
            XCTAssertEqual(error.code, code, context)
            XCTAssertEqual(error.message, message, context)
        } catch {
            XCTFail("Unexpected error \(context): \(error)")
        }
    }

    private func terminalGroup(
        _ prepared: OracleGroupDocument,
        secondaryStatus: OracleLaneResultStatus,
        capturedModelNames: [Int: String] = [:]
    ) throws -> OracleGroupDocument {
        let results = try prepared.members.map { member in
            let status: OracleLaneResultStatus = member.laneID.index == 0 ? .completed : secondaryStatus
            return try OracleLaneResult(
                laneIndex: member.laneID.index,
                chatID: member.publicChatID,
                providerID: member.model.providerID,
                modelID: member.model.modelID,
                status: status,
                capturedModelName: capturedModelNames[member.laneID.index],
                response: status == .completed ? "Completed sibling answer" : nil,
                error: status == .completed ? nil : OracleLaneError(
                    code: "provider_failed", message: "Synthetic lane failure", partialResponse: "Unmarked partial answer"
                )
            )
        }
        return try prepared.settling(OracleGroupResult(
            groupID: prepared.group.id,
            status: secondaryStatus == .completed ? .completed : .partialFailure,
            oracleResults: results
        ), finishedAt: prepared.updatedAt.addingTimeInterval(10))
    }

    private func makeCanonicalOracleGroup(
        fixture: Fixture,
        models suppliedModels: [OracleModelReference]? = nil
    ) throws -> (owner: OracleConversationOwner, group: OracleGroupDocument) {
        let owner = try OracleViewModel.oracleGroupOwner(
            workspaceID: fixture.workspace.id,
            tabID: fixture.tabID
        )
        let models = try suppliedModels ?? ["model-a", "model-b"].map {
            try OracleModelReference(modelID: $0)
        }
        let descriptor = try OracleGroupDescriptor(size: models.count)
        let memberIDs = models.map { _ in UUID() }
        let members = try models.enumerated().map { index, model in
            let name = OracleViewModel.oracleProjectionName(base: "Canonical Group", laneIndex: index)
            return try OracleGroupMember(
                laneID: OracleLaneID(index: index),
                memberID: OracleMemberID(rawValue: memberIDs[index]),
                publicChatID: ChatSession.makeShortID(name: name, uuid: memberIDs[index]),
                model: model
            )
        }
        let timestamp = Date(timeIntervalSince1970: 1000)
        let roster = try OracleRoster(primary: models[0], additional: Array(models.dropFirst()))
        let group = try OracleGroupDocument(
            group: descriptor,
            owner: owner,
            name: "Canonical Group",
            revision: 1,
            createdAt: timestamp,
            updatedAt: timestamp,
            roster: roster,
            members: members,
            turns: [OracleTurnRecord(
                input: OracleInput(mode: .chat, userMessage: "test"),
                state: .prepared,
                startedAt: timestamp
            )]
        )
        return (owner, group)
    }

    private func makeProjection(
        member: OracleGroupMember,
        group: OracleGroupDocument,
        fixture: Fixture
    ) -> ChatSession {
        ChatSession(
            id: member.memberID.rawValue,
            workspaceID: fixture.workspace.id,
            composeTabID: fixture.tabID,
            oracleGroupID: group.group.id.rawValue,
            oracleLaneIndex: member.laneID.index,
            oracleGroupSize: group.group.size,
            oracleModelRaw: member.model.modelID,
            name: OracleViewModel.oracleProjectionName(base: group.name, laneIndex: member.laneID.index),
            shortID: member.publicChatID
        )
    }

    private func deleteCanonicalOracleGroup(_ group: OracleGroupDocument) async throws {
        let store = AppDomainRuntimeComposition.shared.oracleConversationStore
        if let retained = try await store.load(groupID: group.group.id, owner: group.owner) {
            try await store.delete(
                groupID: retained.group.id,
                owner: retained.owner,
                expectedRevision: retained.revision
            )
        }
    }

    private func oracleTabContext(_ fixture: Fixture) -> OracleViewModel.OracleSendTabContext {
        OracleViewModel.OracleSendTabContext(
            tabID: fixture.tabID,
            workspaceID: fixture.workspace.id,
            packaging: OracleViewModel.OracleSendPackagingContext(
                sourceTabID: fixture.tabID,
                sourceWorkspaceID: fixture.workspace.id,
                sourceSelectionRevision: 0,
                sourceAgentSessionID: nil,
                sourceAgentRunID: nil,
                promptText: "",
                selection: StoredSelection(),
                lookupContext: nil,
                reviewGitContext: .automaticOnly(),
                provenance: .direct
            )
        )
    }

    private func stopAfterPreparedCallbacks() -> AppOracleGroupExecutionCallbacks {
        AppOracleGroupExecutionCallbacks(
            prepared: { _, _, _ in throw OracleProjectionRoutingTestStop.afterPrepared },
            progress: { _ in },
            laneProgress: { _, _, _ in }
        )
    }

    private struct ProjectionIdentitySnapshot: Equatable {
        let id: UUID
        let shortID: String
        let workspaceID: UUID?
        let composeTabID: UUID?
        let oracleGroupID: UUID?
        let oracleLaneIndex: Int?
        let oracleGroupSize: Int?
        let oracleModelRaw: String?

        init(_ session: ChatSession) {
            id = session.id
            shortID = session.shortID
            workspaceID = session.workspaceID
            composeTabID = session.composeTabID
            oracleGroupID = session.oracleGroupID
            oracleLaneIndex = session.oracleLaneIndex
            oracleGroupSize = session.oracleGroupSize
            oracleModelRaw = session.oracleModelRaw
        }
    }

    private enum OracleProjectionRoutingTestStop: Error {
        case afterPrepared
    }

    private static var nextFixtureWindowID = -1200

    private static func allocateFixtureWindowID() -> Int {
        nextFixtureWindowID -= 1
        return nextFixtureWindowID
    }

    private func makeFixture() async throws -> Fixture {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        defer { GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false) }
        let composition = WindowStateCompositionFactory.make(
            windowID: Self.allocateFixtureWindowID(),
            deferredInitialAgentSystemWorkspaceRefresh: true,
            sharedMCPService: MCPService()
        )
        await composition.workspaceManager.awaitInitialized()

        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentOraclePillRoutingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)

        var workspace = try XCTUnwrap(composition.workspaceManager.activeWorkspace)
        let tabID = UUID()
        let otherTabID = UUID()
        workspace.customStoragePath = storageRoot
        workspace.composeTabs = [ComposeTabState(id: tabID), ComposeTabState(id: otherTabID)]
        workspace.activeComposeTabID = tabID
        if let index = composition.workspaceManager.workspaces.firstIndex(where: { $0.id == workspace.id }) {
            composition.workspaceManager.workspaces[index] = workspace
        }
        composition.workspaceManager.activeWorkspace = workspace
        composition.promptManager.loadComposeTabsFromWorkspace(workspace)
        await composition.oracleViewModel.loadSessionsFromWorkspace()
        composition.oracleViewModel.sessions = []

        return Fixture(
            composition: composition,
            workspace: workspace,
            tabID: tabID,
            otherTabID: otherTabID,
            storageRoot: storageRoot
        )
    }

    @MainActor
    private struct Fixture {
        let composition: WindowStateComposition
        let workspace: WorkspaceModel
        let tabID: UUID
        let otherTabID: UUID
        let storageRoot: URL

        var oracleViewModel: OracleViewModel {
            composition.oracleViewModel
        }

        func cleanup() {
            oracleViewModel.sessions = []
            try? FileManager.default.removeItem(at: storageRoot)
        }
    }
}

/// Pasted images must be nameable by the agent in `ask_oracle.images`, and only the owning
/// session's own managed attachment files may be authorized for the Oracle.
@MainActor
final class AgentOracleAttachmentForwardingTests: XCTestCase {
    private var workspaceDirectory: URL!

    override func setUpWithError() throws {
        workspaceDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("oracle-attachment-forwarding-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workspaceDirectory {
            try? FileManager.default.removeItem(at: workspaceDirectory)
        }
    }

    func testNativeImageTransportsReceiveAttachmentPathsAsText() {
        let viewModel = makeViewModel()
        let attachments = [
            AgentFileAttachment(source: .localFile(path: "/tmp/agent_attachments/A.png")),
            AgentFileAttachment(source: .url("https://example.com/remote.png")),
            AgentFileAttachment(source: .localFile(path: "/tmp/agent_attachments/B.jpg"))
        ]
        let expected = [
            "what do you see?",
            "",
            AgentModeViewModel.attachmentPathNoteHeader,
            "- /tmp/agent_attachments/A.png",
            "- /tmp/agent_attachments/B.jpg"
        ].joined(separator: "\n")
        for agent in [AgentProviderKind.devin, .codexExec, .grokBuild] {
            XCTAssertEqual(
                viewModel.renderProviderMessage(text: "what do you see?", attachments: attachments, agent: agent),
                expected,
                "\(agent)"
            )
        }
        // Image-only turns carry just the note; text-only turns are unchanged.
        XCTAssertTrue(
            viewModel.renderProviderMessage(text: "", attachments: attachments, agent: .devin)
                .hasPrefix(AgentModeViewModel.attachmentPathNoteHeader)
        )
        XCTAssertEqual(viewModel.renderProviderMessage(text: "hi", attachments: [], agent: .devin), "hi")
        // @path agents keep their existing rendering.
        XCTAssertFalse(
            viewModel.renderProviderMessage(text: "hi", attachments: attachments, agent: .claudeCode)
                .contains(AgentModeViewModel.attachmentPathNoteHeader)
        )
    }

    func testOracleAuthorizedAttachmentPathsAreSessionScopedManagedFiles() {
        let viewModel = makeViewModel()
        let tabID = UUID()
        let agentSessionID = UUID()
        let session = viewModel.session(for: tabID)
        session.testInstallPersistentSessionBinding(sessionID: agentSessionID)

        let store = AgentAttachmentStore.managedStorageRootURL(for: workspaceDirectory).path
        let inFlight = "\(store)/IN-FLIGHT.png"
        let earlierTurn = "\(store)/EARLIER.png"
        session.attachmentTurnState = .reserved(reservationID: UUID(), attachments: [
            AgentFileAttachment(source: .localFile(path: inFlight)),
            // Outside the managed store: never authorized even though the session references it.
            AgentFileAttachment(source: .localFile(path: "/etc/hosts.png")),
            AgentFileAttachment(source: .localFile(path: "\(store)/nested/DEEP.png")),
            AgentFileAttachment(source: .url("https://example.com/remote.png"))
        ])
        session.appendItem(.user("earlier", attachments: [
            AgentFileAttachment(source: .localFile(path: earlierTurn)),
            AgentFileAttachment(source: .localFile(path: inFlight))
        ]))

        XCTAssertEqual(
            viewModel.oracleAuthorizedAttachmentPaths(tabID: tabID, agentSessionID: agentSessionID),
            [inFlight, earlierTurn]
        )
        // A different (or missing) owning session gets nothing from this tab.
        XCTAssertEqual(viewModel.oracleAuthorizedAttachmentPaths(tabID: tabID, agentSessionID: UUID()), [])
        XCTAssertEqual(viewModel.oracleAuthorizedAttachmentPaths(tabID: tabID, agentSessionID: nil), [])
        XCTAssertEqual(viewModel.oracleAuthorizedAttachmentPaths(tabID: UUID(), agentSessionID: agentSessionID), [])
    }

    private func makeViewModel() -> AgentModeViewModel {
        AgentModeViewModel(
            testWorkspaceDirectory: workspaceDirectory,
            codexControllerFactory: { _, _, _, _, _, _ in
                preconditionFailure("Oracle attachment forwarding tests must not start Codex")
            },
            headlessProviderFactory: { _, _ in
                UnsupportedHeadlessAgentProvider(reason: "oracle attachment forwarding test")
            }
        )
    }
}

/// Composer image intake and session-lifetime retention: the attach guard for paste/drop, pane
/// drops routed to the tab captured at drag start, and finished turns keeping their images.
@MainActor
final class AgentImageAttachmentRetentionTests: XCTestCase {
    private var workspaceDirectory: URL!

    override func setUpWithError() throws {
        workspaceDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("image-attachment-retention-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workspaceDirectory {
            try? FileManager.default.removeItem(at: workspaceDirectory)
        }
    }

    func testFinishedTurnMovesImagesIntoSessionStorageAndRewritesUserRow() async throws {
        let viewModel = makeViewModel()
        let attachmentsRoot = workspaceDirectory
            .appendingPathComponent("AgentSessions", isDirectory: true)
            .appendingPathComponent(AgentSessionAttachmentStore.directoryName, isDirectory: true)
        viewModel.sessionAttachmentsRootOverride = { attachmentsRoot }
        let tabID = UUID()
        let agentSessionID = UUID()
        let session = viewModel.session(for: tabID)
        session.testInstallPersistentSessionBinding(sessionID: agentSessionID)
        let temporaryFile = try writeTemporaryImage()
        let attachment = AgentFileAttachment(source: .localFile(path: temporaryFile.path), title: "shot.png")
        session.appendItem(.user("look", attachments: [attachment]))
        let reservationID = viewModel.reserveAttachmentsForTurn([attachment], session: session)

        viewModel.finalizeAttachmentsForTurn(for: session, reservationID: reservationID, disposition: .deleteFiles)
        await viewModel.waitForAttachmentRetention()

        let keptPath = AgentSessionAttachmentStore(rootURL: attachmentsRoot)
            .sessionFolderURL(sessionID: agentSessionID)
            .appendingPathComponent("\(attachment.id.uuidString).png")
            .path
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: keptPath))
        let userRow = try XCTUnwrap(session.items.last { $0.kind == .user })
        XCTAssertEqual(userRow.attachments.map(\.id), [attachment.id])
        XCTAssertEqual(userRow.attachments.first?.source, .localFile(path: keptPath))
        XCTAssertEqual(userRow.attachments.first?.title, "shot.png")
        XCTAssertTrue(session.isDirty)
        // The kept copy stays exact-file Oracle authority for its own session only.
        XCTAssertEqual(viewModel.oracleAuthorizedAttachmentPaths(tabID: tabID, agentSessionID: agentSessionID), [keptPath])
        XCTAssertEqual(viewModel.oracleAuthorizedAttachmentPaths(tabID: tabID, agentSessionID: UUID()), [])
    }

    func testAttachmentRootConsultsTheInjectedPersistencePolicyOnEachResolution() {
        var suppressed = true
        let viewModel = makeViewModel(attachmentPersistenceIsSuppressed: { suppressed })
        let workspace = WorkspaceModel(name: "Attachment policy", repoPaths: [])
        XCTAssertNil(viewModel.sessionAttachmentsRootURL(for: workspace))
        suppressed = false
        XCTAssertNotNil(viewModel.sessionAttachmentsRootURL(for: workspace))
        suppressed = true
        XCTAssertNil(viewModel.sessionAttachmentsRootURL(for: workspace))
    }

    func testSweepQueriesLiveOwnersAndProtectsItsOwnUnregisteredRuntime() throws {
        let other = makeViewModel()
        var liveOwners: [AgentModeViewModel] = []
        let viewModel = makeViewModel(attachmentSweepViewModels: { liveOwners })
        let localSession = viewModel.session(for: UUID())
        let localID = UUID()
        localSession.testInstallPersistentSessionBinding(sessionID: localID)
        let local = try AgentFileAttachment(source: .localFile(path: writeTemporaryImage().path))
        localSession.pendingFileAttachments = [local]
        let otherSession = other.session(for: UUID())
        let otherID = UUID()
        otherSession.testInstallPersistentSessionBinding(sessionID: otherID)
        let pending = try AgentFileAttachment(source: .localFile(path: writeTemporaryImage().path))
        let reserved = try AgentFileAttachment(source: .localFile(path: writeTemporaryImage().path))
        let consumed = try AgentFileAttachment(source: .localFile(path: writeTemporaryImage().path))
        otherSession.pendingFileAttachments = [pending]
        _ = other.reserveAttachmentsForTurn([reserved], session: otherSession)
        otherSession.attachmentsPendingProviderConsumptionCleanup = [consumed]

        XCTAssertEqual(viewModel.liveAttachmentSweepProtection().sessionIDs, [localID])
        liveOwners = [other]
        let protection = viewModel.liveAttachmentSweepProtection()
        XCTAssertEqual(protection.sessionIDs, [localID, otherID])
        XCTAssertEqual(protection.temporaryPaths, Set([local, pending, reserved, consumed].compactMap(AgentImageAttachmentAvailabilityResolver.path(for:))))
        liveOwners = []
        XCTAssertEqual(viewModel.liveAttachmentSweepProtection().sessionIDs, [localID])
    }

    func testWindowCompositionSuppliesCurrentWindowOwnersAndLaunchPolicy() async {
        GlobalSettingsStore.installApplicationModelIdentityPolicy()
        let settings = GlobalSettingsStore.shared
        let previousAutoStart = settings.mcpAutoStart()
        settings.setMCPAutoStart(false, commit: false)
        defer { settings.setMCPAutoStart(previousAutoStart, commit: false) }
        let first = WindowState()
        WindowStatesManager.shared.registerWindowState(first)
        await first.workspaceManager.awaitInitialized()
        XCTAssertEqual(first.agentModeViewModel.attachmentPersistenceIsSuppressed(), AppLaunchConfiguration.current.suppressesAgentSessionPersistence)
        let second = WindowState()
        WindowStatesManager.shared.registerWindowState(second)
        await second.workspaceManager.awaitInitialized()
        XCTAssertTrue(first.agentModeViewModel.attachmentSweepViewModels().contains { $0 === second.agentModeViewModel })
        second.beginClose()
        await second.tearDown()
        WindowStatesManager.shared.unregisterWindowState(second)
        XCTAssertFalse(first.agentModeViewModel.attachmentSweepViewModels().contains { $0 === second.agentModeViewModel })
        first.beginClose()
        await first.tearDown()
        WindowStatesManager.shared.unregisterWindowState(first)
    }

    func testWorkspaceSwitchSchedulesTheStartupSweepThroughTheLivePath() async throws {
        let viewModel = makeViewModel()
        let agentSessionsFolder = workspaceDirectory.appendingPathComponent("AgentSessions", isDirectory: true)
        let attachmentsRoot = AgentSessionAttachmentStore.rootURL(forAgentSessionsFolder: agentSessionsFolder)
        viewModel.sessionAttachmentsRootOverride = { attachmentsRoot }
        viewModel.sessionAttachmentSweepDelayNanoseconds = 0
        let orphan = UUID()
        let orphanFolder = AgentSessionAttachmentStore(rootURL: attachmentsRoot).sessionFolderURL(sessionID: orphan)
        try FileManager.default.createDirectory(at: orphanFolder, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3600)],
            ofItemAtPath: orphanFolder.path
        )

        // The private owner-taking path the workspace-did-switch listener calls.
        let owner = viewModel.test_receiveWorkspaceSwitchNotification(nil)
        await viewModel.test_handleWorkspaceSwitch(nil, owner: owner)

        let sweep = try XCTUnwrap(viewModel.sessionAttachmentSweepTask, "The live switch path must schedule the sweep")
        let result = await sweep.value
        XCTAssertEqual(result?.removedSessionFolders, [orphan])
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanFolder.path))
    }

    func testRetentionUsesTheRootCapturedWhenTheTurnReservedItsImages() async throws {
        let viewModel = makeViewModel()
        let reservedRoot = workspaceDirectory.appendingPathComponent("WorkspaceA/AgentSessions/attachments", isDirectory: true)
        let switchedRoot = workspaceDirectory.appendingPathComponent("WorkspaceB/AgentSessions/attachments", isDirectory: true)
        var currentRoot = reservedRoot
        viewModel.sessionAttachmentsRootOverride = { currentRoot }
        let session = viewModel.session(for: UUID())
        let agentSessionID = UUID()
        session.testInstallPersistentSessionBinding(sessionID: agentSessionID)
        let attachment = try AgentFileAttachment(source: .localFile(path: writeTemporaryImage().path))
        session.appendItem(.user("look", attachments: [attachment]))
        let reservationID = viewModel.reserveAttachmentsForTurn([attachment], session: session)

        currentRoot = switchedRoot // The window switched workspace mid-turn.
        viewModel.finalizeAttachmentsForTurn(for: session, reservationID: reservationID, disposition: .deleteFiles)
        await viewModel.waitForAttachmentRetention()

        let keptPath = AgentSessionAttachmentStore(rootURL: reservedRoot)
            .sessionFolderURL(sessionID: agentSessionID)
            .appendingPathComponent("\(attachment.id.uuidString).png").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: keptPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: switchedRoot.path))
        XCTAssertNil(session.attachmentRetentionRoot)
    }

    func testFinalizeForASessionThatIsNoLongerLiveDeletesTheTemporaryCopy() async throws {
        let viewModel = makeViewModel()
        let attachmentsRoot = workspaceDirectory.appendingPathComponent("AgentSessions/attachments", isDirectory: true)
        viewModel.sessionAttachmentsRootOverride = { attachmentsRoot }
        let tabID = UUID()
        let session = viewModel.session(for: tabID)
        session.testInstallPersistentSessionBinding(sessionID: UUID())
        let temporaryFile = try writeTemporaryImage()
        let attachment = AgentFileAttachment(source: .localFile(path: temporaryFile.path))
        let reservationID = viewModel.reserveAttachmentsForTurn([attachment], session: session)
        viewModel.test_installLiveSession(AgentModeViewModel.TabSession(tabID: tabID))

        viewModel.finalizeAttachmentsForTurn(for: session, reservationID: reservationID, disposition: .deleteFiles)
        await viewModel.waitForAttachmentRetention()

        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: attachmentsRoot.path))
    }

    func testHydrationRepairsADeadTemporaryPathFromTheKeptCopy() async throws {
        let viewModel = makeViewModel()
        let attachmentsRoot = workspaceDirectory.appendingPathComponent("AgentSessions/attachments", isDirectory: true)
        viewModel.sessionAttachmentsRootOverride = { attachmentsRoot }
        let session = viewModel.session(for: UUID())
        let agentSessionID = UUID()
        session.testInstallPersistentSessionBinding(sessionID: agentSessionID)
        let deadPath = AgentAttachmentStore.managedStorageRootURL(for: workspaceDirectory)
            .appendingPathComponent("\(UUID().uuidString).png").path
        let attachment = AgentFileAttachment(source: .localFile(path: deadPath), title: "lost.png")
        session.appendItem(.user("look", attachments: [attachment]))
        let folder = AgentSessionAttachmentStore(rootURL: attachmentsRoot).sessionFolderURL(sessionID: agentSessionID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let kept = folder.appendingPathComponent("\(attachment.id.uuidString).png")
        try Data("kept".utf8).write(to: kept)

        viewModel.repairRetainedAttachmentPathsAfterHydration(session, sessionID: agentSessionID)
        await viewModel.waitForAttachmentRetention()

        let row = try XCTUnwrap(session.items.last { $0.kind == .user })
        XCTAssertEqual(row.attachments.first?.source, .localFile(path: kept.path))
        XCTAssertEqual(row.attachments.first?.title, "lost.png")
    }

    func testHydrationRepairsCompactedCanonicalImageAndPersistsItsRenderedPath() async throws {
        let viewModel = makeViewModel()
        let attachmentsRoot = workspaceDirectory.appendingPathComponent("AgentSessions/attachments", isDirectory: true)
        viewModel.sessionAttachmentsRootOverride = { attachmentsRoot }
        let session = viewModel.session(for: UUID())
        let sessionID = UUID()
        session.testInstallPersistentSessionBinding(sessionID: sessionID)
        let attachment = AgentFileAttachment(
            source: .localFile(path: workspaceDirectory.appendingPathComponent("lost.png").path),
            title: "compacted image",
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let request = AgentChatItem.user("earlier request", attachments: [attachment], sequenceIndex: 0)
        let transcript = compactedTranscript(for: request)
        session.runState = .completed
        session.nextSequenceIndex = transcript.nextSequenceIndex
        session.setItemsSilently(AgentTranscriptIO.workingSourceItems(from: transcript), reason: .persistedSessionHydration)
        viewModel.applyTranscriptPresentation(transcript, to: session, isColdLoad: true)
        session.isDirty = false
        let mutationGeneration = session.persistenceMutationGeneration
        XCTAssertTrue(session.items.isEmpty, "The request exists only in canonical compacted history")
        XCTAssertNotNil(session.turnProjectionCaches[transcript.turns[0].id], "Prime the completed-turn projection cache")
        XCTAssertEqual(session.fullTranscriptProjection.workingRows.first?.attachments, [attachment])
        let folder = AgentSessionAttachmentStore(rootURL: attachmentsRoot).sessionFolderURL(sessionID: sessionID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let kept = folder.appendingPathComponent("\(attachment.id.uuidString).png")
        try Data("compacted kept image".utf8).write(to: kept)

        viewModel.repairRetainedAttachmentPathsAfterHydration(session, sessionID: sessionID)
        await viewModel.waitForAttachmentRetention()

        let expected = AgentFileAttachment(
            id: attachment.id, source: .localFile(path: kept.path), title: attachment.title, createdAt: attachment.createdAt
        )
        XCTAssertTrue(session.items.isEmpty, "Repair must not reintroduce compacted requests into the working suffix")
        XCTAssertEqual(session.transcript.turns.first?.request?.attachments, [expected])
        XCTAssertEqual(session.fullTranscriptProjection.workingRows.first?.attachments, [expected])
        XCTAssertEqual(session.fullTranscriptProjection.workingBlocks.first?.rows.first?.attachments, [expected])
        XCTAssertTrue(session.isDirty)
        XCTAssertGreaterThan(session.persistenceMutationGeneration, mutationGeneration)

        let workspace = WorkspaceModel(name: "Compacted attachment repair", repoPaths: [], customStoragePath: workspaceDirectory)
        let service = AgentSessionDataService()
        let savedURL = try await service.saveAgentSession(
            AgentSession(
                id: sessionID, workspaceID: workspace.id, composeTabID: session.tabID,
                transcript: session.transcript, lastRunState: AgentSessionRunState.completed.rawValue
            ),
            for: workspace,
            preparation: .alreadyCanonicalTranscript
        )
        let reloaded = try await service.loadAgentSession(from: savedURL)
        let reloadedTranscript = try XCTUnwrap(reloaded.transcript)
        XCTAssertTrue(reloaded.items.isEmpty)
        XCTAssertEqual(reloadedTranscript.turns.first?.request?.attachments, [expected])
        let reloadedProjection = AgentTranscriptProjectionBuilder.build(from: reloadedTranscript)
        XCTAssertEqual(reloadedProjection.workingRows.first?.attachments, [expected])
        XCTAssertEqual(reloadedProjection.workingBlocks.first?.rows.first?.attachments, [expected])
        XCTAssertEqual(try Data(contentsOf: kept), Data("compacted kept image".utf8))
    }

    func testHydrationRepairsSharedAttachmentWithoutReplacingEachRequestsMetadata() async throws {
        for workingPathAlreadyRetained in [false, true] {
            let viewModel = makeViewModel()
            let attachmentsRoot = workspaceDirectory.appendingPathComponent("AgentSessions/attachments", isDirectory: true)
            viewModel.sessionAttachmentsRootOverride = { attachmentsRoot }
            let session = viewModel.session(for: UUID())
            let sessionID = UUID()
            session.testInstallPersistentSessionBinding(sessionID: sessionID)
            let attachmentID = UUID()
            let folder = AgentSessionAttachmentStore(rootURL: attachmentsRoot).sessionFolderURL(sessionID: sessionID)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let kept = folder.appendingPathComponent("\(attachmentID.uuidString).png")
            try Data("shared kept image".utf8).write(to: kept)
            let missingPath = workspaceDirectory.appendingPathComponent("missing-\(attachmentID).png").path
            let historicalAttachment = AgentFileAttachment(
                id: attachmentID, source: .localFile(path: missingPath), title: "original title", createdAt: Date(timeIntervalSince1970: 10)
            )
            let workingAttachment = AgentFileAttachment(
                id: attachmentID,
                source: .localFile(path: workingPathAlreadyRetained ? kept.path : missingPath),
                title: "reused title", createdAt: Date(timeIntervalSince1970: 20)
            )
            let historicalRequest = AgentChatItem.user("older", attachments: [historicalAttachment], sequenceIndex: 0)
            let workingRequest = AgentChatItem.user("newer", attachments: [workingAttachment], sequenceIndex: 1)
            var transcript = compactedTranscript(for: historicalRequest)
            transcript.turns.append(AgentTranscriptTurn(
                request: AgentTranscriptRequestAnchor(from: workingRequest), terminalState: .completed,
                startedAt: workingRequest.timestamp, completedAt: workingRequest.timestamp
            ))
            transcript.nextSequenceIndex = 2
            session.runState = .completed
            session.nextSequenceIndex = transcript.nextSequenceIndex
            session.setItemsSilently([workingRequest], reason: .persistedSessionHydration)
            viewModel.applyTranscriptPresentation(transcript, to: session, isColdLoad: true)

            viewModel.repairRetainedAttachmentPathsAfterHydration(session, sessionID: sessionID)
            await viewModel.waitForAttachmentRetention()

            let expectedHistorical = AgentFileAttachment(
                id: attachmentID, source: .localFile(path: kept.path), title: historicalAttachment.title, createdAt: historicalAttachment.createdAt
            )
            let expectedWorking = AgentFileAttachment(
                id: attachmentID, source: .localFile(path: kept.path), title: workingAttachment.title, createdAt: workingAttachment.createdAt
            )
            XCTAssertEqual(session.items.map(\.id), [workingRequest.id])
            XCTAssertEqual(session.items.first?.attachments, [expectedWorking])
            XCTAssertEqual(session.transcript.turns.first { $0.request?.id == historicalRequest.id }?.request?.attachments, [expectedHistorical])
            XCTAssertEqual(session.transcript.turns.first { $0.request?.id == workingRequest.id }?.request?.attachments, [expectedWorking])
            XCTAssertEqual(session.fullTranscriptProjection.workingRows.first { $0.id == historicalRequest.id }?.attachments, [expectedHistorical])
            XCTAssertEqual(session.fullTranscriptProjection.workingRows.first { $0.id == workingRequest.id }?.attachments, [expectedWorking])
        }
    }

    func testRetentionMarksTheMovedTemporaryPathMissing() async throws {
        let viewModel = makeViewModel()
        let attachmentsRoot = workspaceDirectory.appendingPathComponent("AgentSessions/attachments", isDirectory: true)
        viewModel.sessionAttachmentsRootOverride = { attachmentsRoot }
        let session = viewModel.session(for: UUID())
        session.testInstallPersistentSessionBinding(sessionID: UUID())
        let temporaryFile = try writeTemporaryImage()
        let temporaryPath = temporaryFile.standardizedFileURL.path
        AttachmentTilePreviewCache.shared.retainedImages.availability.record(.available, forPath: temporaryPath)
        let attachment = AgentFileAttachment(source: .localFile(path: temporaryFile.path))
        session.appendItem(.user("look", attachments: [attachment]))
        let reservationID = viewModel.reserveAttachmentsForTurn([attachment], session: session)

        viewModel.finalizeAttachmentsForTurn(for: session, reservationID: reservationID, disposition: .deleteFiles)
        await viewModel.waitForAttachmentRetention()

        XCTAssertEqual(AttachmentTilePreviewCache.shared.retainedImages.availability.cachedAvailability(forPath: temporaryPath), .missing)
    }

    func testPaneEntryClearsAStuckTextViewHover() {
        let controller = AgentAttachmentDropController()
        controller.setTextViewAttachmentDragActive(true)
        controller.paneDragEntered(typeIdentifiers: ["public.utf8-plain-text"], currentTabID: UUID())
        XCTAssertFalse(controller.isTextViewAttachmentDragActive)
        XCTAssertFalse(controller.isOverlayVisible)
    }

    func testFinishedTurnWithoutPersistedSessionDeletesTemporaryCopy() async throws {
        let viewModel = makeViewModel()
        let tabID = UUID()
        let session = viewModel.session(for: tabID)
        session.testInstallPersistentSessionBinding(sessionID: UUID())
        let temporaryFile = try writeTemporaryImage()
        let attachment = AgentFileAttachment(source: .localFile(path: temporaryFile.path))
        session.appendItem(.user("look", attachments: [attachment]))
        let reservationID = viewModel.reserveAttachmentsForTurn([attachment], session: session)

        viewModel.finalizeAttachmentsForTurn(for: session, reservationID: reservationID, disposition: .deleteFiles)
        await viewModel.waitForAttachmentRetention()

        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryFile.path))
        XCTAssertEqual(session.items.last { $0.kind == .user }?.attachments, [attachment])
    }

    func testRestoredTurnKeepsItsTemporaryCopyPending() async throws {
        let viewModel = makeViewModel()
        viewModel.sessionAttachmentsRootOverride = { [workspaceDirectory] in
            workspaceDirectory?.appendingPathComponent("AgentSessions/attachments", isDirectory: true)
        }
        let session = viewModel.session(for: UUID())
        session.testInstallPersistentSessionBinding(sessionID: UUID())
        let temporaryFile = try writeTemporaryImage()
        let attachment = AgentFileAttachment(source: .localFile(path: temporaryFile.path))
        let reservationID = viewModel.reserveAttachmentsForTurn([attachment], session: session)

        viewModel.finalizeAttachmentsForTurn(for: session, reservationID: reservationID, disposition: .restoreToPending)
        await viewModel.waitForAttachmentRetention()

        XCTAssertTrue(FileManager.default.fileExists(atPath: temporaryFile.path))
        XCTAssertEqual(session.pendingFileAttachments, [attachment])
    }

    func testEvictionPublishesInvalidationAndFencesAlreadyQueuedCachedThumbnail() async throws {
        let source = workspaceDirectory.appendingPathComponent("\(UUID().uuidString).png")
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII="))
        try png.write(to: source)
        let cache = AttachmentTilePreviewCache.shared.retainedImages
        let key = AgentAttachmentImageKey.preview(path: source.path, backingScale: 1)
        let loaded = expectation(description: "Initial image loaded")
        let initialToken = cache.loadImage(for: key) { result in
            guard case .image = result else { return XCTFail("Fixture must decode as an image") }
            loaded.fulfill()
        }
        defer { initialToken.cancel() }
        await fulfillment(of: [loaded], timeout: 5)
        XCTAssertNotNil(cache.cachedImage(for: key))
        let invalidated = expectation(description: "Mounted-card invalidation delivered")
        let subscription = cache.invalidatedPaths.receive(on: DispatchQueue.main).sink { paths in
            guard paths.contains(source.path) else { return }
            XCTAssertEqual(cache.availability.cachedAvailability(forPath: source.path), .missing)
            invalidated.fulfill()
        }
        defer { subscription.cancel() }
        let refreshed = expectation(description: "Queued cached result becomes missing")
        let queuedToken = cache.loadImage(for: key) { result in
            guard case .missing = result else { return XCTFail("Eviction must fence the queued cached image") }
            refreshed.fulfill()
        }
        defer { queuedToken.cancel() }
        try FileManager.default.removeItem(at: source)
        cache.invalidate(paths: [source.path])
        await fulfillment(of: [invalidated, refreshed], timeout: 5)
        XCTAssertNil(cache.cachedImage(for: key))
    }

    func testPasteAndDropAttachWhenAllowed() async throws {
        let viewModel = makeViewModel()
        let tabID = UUID()
        let session = viewModel.session(for: tabID)
        let source = try writeSourceImage()

        XCTAssertNil(viewModel.imageAttachmentBlockReason(tabID: tabID))
        let accepted = await viewModel.attachImagesIfAllowed(tabID: tabID, urls: [source])
        XCTAssertTrue(accepted)
        XCTAssertEqual(session.pendingFileAttachments.count, 1)
    }

    func testPasteAndDropAreBlockedWhileAgentIsBusyWithoutTouchingTheTranscript() async throws {
        let viewModel = makeViewModel()
        let tabID = UUID()
        let session = viewModel.session(for: tabID)
        session.runState = .running
        let itemCountBefore = session.items.count
        let source = try writeSourceImage()

        XCTAssertEqual(viewModel.imageAttachmentBlockReason(tabID: tabID), .agentBusy)
        let accepted = await viewModel.attachImagesIfAllowed(tabID: tabID, urls: [source])
        XCTAssertFalse(accepted)

        XCTAssertTrue(session.pendingFileAttachments.isEmpty)
        XCTAssertEqual(session.items.count, itemCountBefore, "A running turn streams into the last row")
        XCTAssertEqual(viewModel.imageAttachmentNotice?.tabID, tabID)
        XCTAssertEqual(viewModel.imageAttachmentNotice?.message, AgentImageAttachmentBlockReason.agentBusy.message)
    }

    func testPasteAndDropAreBlockedForProvidersWithoutImageSupport() async throws {
        let viewModel = makeViewModel()
        let tabID = UUID()
        let session = viewModel.session(for: tabID)
        session.selectedAgent = .grokBuild
        let source = try writeSourceImage()

        let accepted = await viewModel.attachImagesIfAllowed(tabID: tabID, urls: [source])
        XCTAssertFalse(accepted)

        XCTAssertTrue(session.pendingFileAttachments.isEmpty)
        let errorRow = try XCTUnwrap(session.items.last)
        XCTAssertEqual(errorRow.kind, .error)
        XCTAssertEqual(
            errorRow.text,
            AgentImageAttachmentBlockReason.providerUnsupported(providerName: AgentProviderKind.grokBuild.displayName).message
        )
    }

    func testPaneDropAttachesToTabCapturedAtDragStartAfterTabSwitch() {
        let controller = AgentAttachmentDropController()
        let dragStartTab = UUID()
        let switchedTab = UUID()
        var pendingCompletion: (([AgentAttachmentIntake.Prepared], [AgentAttachmentFailure]) -> Void)?
        var attachedTab: UUID?
        var attachedURLs: [URL] = []

        controller.paneDragEntered(typeIdentifiers: ["public.png"], currentTabID: dragStartTab)
        XCTAssertTrue(controller.isOverlayVisible)
        XCTAssertTrue(controller.acceptsPaneDrop)

        let accepted = controller.performPaneDrop(
            currentTabID: switchedTab,
            load: { completion in
                pendingCompletion = completion
                return true
            },
            prepareAttach: { tabID in
                { prepared, _ in
                    attachedTab = tabID
                    attachedURLs = prepared.map(\.url)
                }
            }
        )
        XCTAssertTrue(accepted)
        XCTAssertFalse(controller.isOverlayVisible)

        // The asynchronous load finishes after the user switched tabs.
        let image = URL(fileURLWithPath: "/tmp/dropped.png")
        pendingCompletion?([AgentAttachmentIntake.Prepared(url: image, isTemporary: false)], [])
        XCTAssertEqual(attachedTab, dragStartTab)
        XCTAssertEqual(attachedURLs, [image])
    }

    func testDelayedPaneDropDoesNotRecreateRemovedSession() async throws {
        let viewModel = makeViewModel()
        let tabID = UUID()
        let removedSession = viewModel.session(for: tabID)
        let source = try writeSourceImage()
        let controller = AgentAttachmentDropController()
        var pendingCompletion: (([AgentAttachmentIntake.Prepared], [AgentAttachmentFailure]) -> Void)?
        var intakeTask: Task<Void, Never>?
        controller.paneDragEntered(typeIdentifiers: ["public.png"], currentTabID: tabID)
        XCTAssertTrue(controller.performPaneDrop(
            currentTabID: tabID,
            load: { pendingCompletion = $0
                return true
            },
            prepareAttach: { tabID in
                let attach = viewModel.prepareAttachmentIntake(tabID: tabID)
                return { prepared, failures in
                    intakeTask = Task { await attach(prepared.map(\.url), failures) }
                }
            }
        ))
        viewModel.test_removeSession(tabID: tabID)
        pendingCompletion?([AgentAttachmentIntake.Prepared(url: source, isTemporary: false)], [])
        await intakeTask?.value
        XCTAssertNil(viewModel.session(for: tabID, createIfNeeded: false))
        XCTAssertTrue(removedSession.pendingFileAttachments.isEmpty)
    }

    func testPreparedDropDoesNotAttachToReplacementOrReboundSession() async throws {
        let viewModel = makeViewModel()
        let tabID = UUID()
        let original = viewModel.session(for: tabID)
        let source = try writeSourceImage()
        let attachBeforeReplacement = viewModel.prepareAttachmentIntake(tabID: tabID)
        viewModel.test_removeSession(tabID: tabID)
        let replacement = viewModel.session(for: tabID)
        await attachBeforeReplacement([source], [])
        XCTAssertTrue(original.pendingFileAttachments.isEmpty)
        XCTAssertTrue(replacement.pendingFileAttachments.isEmpty)
        let attachBeforeRebinding = viewModel.prepareAttachmentIntake(tabID: tabID)
        replacement.testInstallPersistentSessionBinding(sessionID: UUID())
        await attachBeforeRebinding([source], [])
        XCTAssertTrue(replacement.pendingFileAttachments.isEmpty)
    }

    func testPaneAndEditorDropsShareBroadFileIntakeAndReportFailuresForClaudeAndCodex() async throws {
        var sources: [URL] = []
        for (name, bytes) in [
            ("report.pdf", Data("%PDF-1.7\nreport".utf8)),
            ("table.csv", Data("name,value\na,1".utf8)),
            ("config.json", Data("{\"enabled\":true}".utf8)),
            ("source.custom-extension", Data("let answer = 42".utf8)),
            ("notebook.ipynb", Data("{\"cells\":[],\"nbformat\":4}".utf8)),
            ("document.docx", Data([0x50, 0x4B, 0x03, 0x04, 0, 0xFF])),
            ("sheet.xlsx", Data([0x50, 0x4B, 0x03, 0x04, 0, 0xFE]))
        ] {
            let url = workspaceDirectory.appendingPathComponent(name)
            try bytes.write(to: url)
            sources.append(url)
        }
        try sources.append(writeSourceImage())
        let folder = workspaceDirectory.appendingPathComponent("NotAFile", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for agent in [AgentProviderKind.claudeCode, .codexExec] {
            for viaEditor in [false, true] {
                let viewModel = makeViewModel()
                let tabID = UUID()
                let session = viewModel.session(for: tabID)
                session.selectedAgent = agent
                let controller = AgentAttachmentDropController()
                controller.paneDragEntered(typeIdentifiers: [UTType.fileURL.identifier], currentTabID: tabID)
                XCTAssertTrue(controller.isOverlayVisible, "All file URLs highlight immediately, not just images")
                let finished = expectation(description: "\(agent) editor=\(viaEditor)")
                let delegate = AgentAttachmentPaneDropDelegate(
                    controller: controller,
                    currentTabID: { tabID },
                    prepareAttach: { tabID in
                        let attach = viewModel.prepareAttachmentIntake(tabID: tabID)
                        return { urls, failures in
                            await attach(urls, failures)
                            finished.fulfill()
                        }
                    }
                )
                let dropped = sources + [folder]
                if viaEditor {
                    let pasteboard = NSPasteboard.withUniqueName()
                    defer { pasteboard.releaseGlobally() }
                    XCTAssertTrue(pasteboard.writeObjects(dropped.map { $0 as NSURL }))
                    XCTAssertTrue(delegate.performDrop(pasteboard: pasteboard))
                } else {
                    XCTAssertTrue(delegate.performDrop(providers: dropped.map {
                        NSItemProvider(item: $0 as NSURL, typeIdentifier: UTType.fileURL.identifier)
                    }))
                }
                await fulfillment(of: [finished], timeout: 10)
                XCTAssertFalse(controller.isOverlayVisible)
                XCTAssertEqual(Set(session.pendingFileAttachments.map(\.fileName)), Set(sources.map(\.lastPathComponent)))
                XCTAssertEqual(session.pendingFileAttachments.count, sources.count)
                XCTAssertTrue(session.items.contains { $0.kind == .error && $0.text.contains("NotAFile") })
                let message = viewModel.renderProviderMessage(text: "Inspect these files", attachments: session.pendingFileAttachments, agent: agent)
                for attachment in session.pendingFileAttachments {
                    guard case let .localFile(path) = attachment.source else { return XCTFail("Expected owned local file") }
                    XCTAssertTrue(message.contains(path), "Non-images must reach the provider as file references, not be silently discarded")
                }
                await viewModel.prepareForWindowClose()
            }
        }
    }

    func testEditorRawImageDropUsesSharedOwnerAndCleansTemporaryIntake() async throws {
        let image = try writeSourceImage()
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(try pasteboard.setData(Data(contentsOf: image), forType: .png))
        let temporaryRoot = workspaceDirectory.appendingPathComponent("raw-drop", isDirectory: true)
        let controller = AgentAttachmentDropController()
        let finished = expectation(description: "raw image attached")
        var copied: Data?
        let delegate = AgentAttachmentPaneDropDelegate(
            controller: controller,
            currentTabID: { UUID() },
            prepareAttach: { _ in { urls, failures in
                XCTAssertTrue(failures.isEmpty)
                copied = try? Data(contentsOf: urls[0])
                finished.fulfill()
            } },
            attachmentIntake: AgentAttachmentIntake(temporaryRoot: temporaryRoot)
        )
        XCTAssertTrue(delegate.performDrop(pasteboard: pasteboard))
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertEqual(copied, try Data(contentsOf: image))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temporaryRoot.path), [])
    }

    func testDirectEditorEntryReplacesCancelledDragAndKeepsItsTabAcrossSwitch() async throws {
        let source = try writeSourceImage()
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(pasteboard.writeObjects([source as NSURL]))
        let viewModel = makeViewModel()
        let originalTab = UUID()
        let switchedTab = UUID()
        let original = viewModel.session(for: originalTab)
        let switched = viewModel.session(for: switchedTab)
        let controller = AgentAttachmentDropController()
        controller.paneDragEntered(typeIdentifiers: [UTType.fileURL.identifier], currentTabID: UUID(), dragID: "cancelled-old-drag")
        controller.paneDragExited()
        // Native entry can happen without a SwiftUI pane entry, or before a late pane exit.
        controller.textViewDragEntered(pasteboard: pasteboard, currentTabID: originalTab)
        controller.paneDragExited()
        XCTAssertTrue(controller.isOverlayVisible)
        let finished = expectation(description: "editor destination retained")
        let delegate = AgentAttachmentPaneDropDelegate(
            controller: controller,
            currentTabID: { switchedTab },
            prepareAttach: { tabID in
                XCTAssertEqual(tabID, originalTab)
                let attach = viewModel.prepareAttachmentIntake(tabID: tabID)
                return { urls, failures in
                    await attach(urls, failures)
                    finished.fulfill()
                }
            }
        )
        XCTAssertTrue(delegate.performDrop(pasteboard: pasteboard))
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertEqual(original.pendingFileAttachments.count, 1)
        XCTAssertTrue(switched.pendingFileAttachments.isEmpty)
        await viewModel.prepareForWindowClose()
    }

    func testDirectEditorExitClearsOverlayWithoutASwiftUIPaneExit() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("file:///tmp/notes.txt", forType: .fileURL)
        let controller = AgentAttachmentDropController()
        controller.textViewDragEntered(pasteboard: pasteboard, currentTabID: UUID())
        XCTAssertTrue(controller.isOverlayVisible)
        controller.setTextViewAttachmentDragActive(false)
        XCTAssertFalse(controller.isOverlayVisible)
    }

    func testFailureOnlyAndMixedDropsWhileBusyDoNotAppendTranscriptRows() async throws {
        let viewModel = makeViewModel()
        let tabID = UUID()
        let session = viewModel.session(for: tabID)
        session.runState = .running
        let before = session.items
        let source = try writeSourceImage()
        let attach = viewModel.prepareAttachmentIntake(tabID: tabID)
        for urls in [[], [source]] {
            await attach(urls, [AgentAttachmentFailure(fileName: "folder", reason: "Not a regular file")])
            XCTAssertEqual(session.items, before)
            XCTAssertTrue(session.pendingFileAttachments.isEmpty)
            XCTAssertEqual(viewModel.imageAttachmentNotice?.message, AgentImageAttachmentBlockReason.agentBusy.message)
        }
    }

    func testMixedEditorFileAndRawImageDropKeepsBothWithoutDuplicatingRepresentations() async throws {
        let source = try writeSourceImage()
        let file = workspaceDirectory.appendingPathComponent("notes.txt")
        try Data("Read these notes".utf8).write(to: file)
        let fileItem = NSPasteboardItem()
        XCTAssertTrue(fileItem.setString(file.absoluteString, forType: .fileURL))
        XCTAssertTrue(try fileItem.setData(Data(contentsOf: source), forType: .png))
        let imageItem = NSPasteboardItem()
        XCTAssertTrue(try imageItem.setData(Data(contentsOf: source), forType: .png))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(pasteboard.writeObjects([fileItem, imageItem]))
        let temporaryRoot = workspaceDirectory.appendingPathComponent("mixed-drop", isDirectory: true)
        let viewModel = makeViewModel()
        let tabID = UUID()
        let session = viewModel.session(for: tabID)
        let finished = expectation(description: "file and raw image attached")
        let delegate = AgentAttachmentPaneDropDelegate(
            controller: AgentAttachmentDropController(), currentTabID: { tabID },
            prepareAttach: { tabID in
                let attach = viewModel.prepareAttachmentIntake(tabID: tabID)
                return { urls, failures in
                    await attach(urls, failures)
                    finished.fulfill()
                }
            },
            attachmentIntake: AgentAttachmentIntake(temporaryRoot: temporaryRoot)
        )
        XCTAssertTrue(delegate.performDrop(pasteboard: pasteboard))
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertEqual(session.pendingFileAttachments.count, 2)
        XCTAssertEqual(Set(session.pendingFileAttachments.map(\.kind)), [.text, .image])
        XCTAssertFalse(session.items.contains { $0.kind == .error })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temporaryRoot.path), [])
        await viewModel.prepareForWindowClose()
    }

    func testPlainTextDropsAreNotHighlightedOrAccepted() {
        let controller = AgentAttachmentDropController()
        var loadCalled = false

        controller.paneDragEntered(typeIdentifiers: ["public.utf8-plain-text"], currentTabID: UUID())
        XCTAssertFalse(controller.isOverlayVisible)
        XCTAssertFalse(controller.acceptsPaneDrop)

        let accepted = controller.performPaneDrop(
            currentTabID: UUID(),
            load: { _ in
                loadCalled = true
                return true
            },
            prepareAttach: { _ in { _, _ in XCTFail("Plain-text drops must not attach") } }
        )
        XCTAssertFalse(accepted)
        XCTAssertFalse(loadCalled)
    }

    func testTextViewFileDragKeepsOverlayLitAfterPaneExit() {
        let controller = AgentAttachmentDropController()
        controller.paneDragEntered(typeIdentifiers: ["public.file-url"], currentTabID: UUID())
        controller.paneDragExited()
        controller.setTextViewAttachmentDragActive(true)
        XCTAssertTrue(controller.isOverlayVisible)
        controller.setTextViewAttachmentDragActive(false)
        XCTAssertFalse(controller.isOverlayVisible)
    }

    // MARK: - Helpers

    private func compactedTranscript(for request: AgentChatItem) -> AgentTranscript {
        AgentTranscript(
            turns: [AgentTranscriptTurn(
                request: AgentTranscriptRequestAnchor(from: request), retentionTier: .condensed, terminalState: .completed,
                startedAt: request.timestamp, completedAt: request.timestamp
            )],
            nextSequenceIndex: request.sequenceIndex + 1
        )
    }

    private func writeTemporaryImage() throws -> URL {
        let temporaryRoot = AgentAttachmentStore.managedStorageRootURL(for: workspaceDirectory)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        let fileURL = temporaryRoot.appendingPathComponent("\(UUID().uuidString).png")
        try Data("temporary image".utf8).write(to: fileURL)
        return fileURL
    }

    private func writeSourceImage() throws -> URL {
        let fileURL = workspaceDirectory.appendingPathComponent("source-\(UUID().uuidString).png")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32
        ))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: fileURL)
        return fileURL
    }

    private func makeViewModel(
        attachmentPersistenceIsSuppressed: @escaping () -> Bool = { false },
        attachmentSweepViewModels: @escaping () -> [AgentModeViewModel] = { [] }
    ) -> AgentModeViewModel {
        AgentModeViewModel(
            testWorkspaceDirectory: workspaceDirectory,
            attachmentPersistenceIsSuppressed: attachmentPersistenceIsSuppressed,
            attachmentSweepViewModels: attachmentSweepViewModels,
            codexControllerFactory: { _, _, _, _, _, _ in
                preconditionFailure("Image attachment retention tests must not start Codex")
            },
            headlessProviderFactory: { _, _ in
                UnsupportedHeadlessAgentProvider(reason: "image attachment retention test")
            }
        )
    }
}
