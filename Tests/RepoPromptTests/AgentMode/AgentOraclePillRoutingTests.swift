import Combine
import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptSettingsCore
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
            vm.sessions = [member]
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
                kind: .laneSettled, groupID: prepared.group.id, turnID: turnID,
                laneID: prepared.members[1].laneID, sequence: 1, text: canonicalStatus.rawValue
            ), owner: prepared.owner)
            vm.receiveOracleGroupProgress(started, owner: prepared.owner)
            XCTAssertEqual(vm.oracleMemberPresentation(for: member).status, .unknown, "settled progress is not publication")

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
            await vm.finishOracleGroupPresentation(invocationID: invocationID)
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
        secondaryStatus: OracleLaneResultStatus
    ) throws -> OracleGroupDocument {
        let results = try prepared.members.map { member in
            let status: OracleLaneResultStatus = member.laneID.index == 0 ? .completed : secondaryStatus
            return try OracleLaneResult(
                laneIndex: member.laneID.index,
                chatID: member.publicChatID,
                providerID: member.model.providerID,
                modelID: member.model.modelID,
                status: status,
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

    private func makeCanonicalOracleGroup(fixture: Fixture) throws -> (owner: OracleConversationOwner, group: OracleGroupDocument) {
        let owner = try OracleViewModel.oracleGroupOwner(
            workspaceID: fixture.workspace.id,
            tabID: fixture.tabID
        )
        let models = try ["model-a", "model-b"].map {
            try OracleModelReference(modelID: $0)
        }
        let descriptor = try OracleGroupDescriptor(size: models.count)
        let memberIDs = [UUID(), UUID()]
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
            AgentImageAttachment(source: .localFile(path: "/tmp/agent_attachments/A.png")),
            AgentImageAttachment(source: .url("https://example.com/remote.png")),
            AgentImageAttachment(source: .localFile(path: "/tmp/agent_attachments/B.jpg"))
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
            AgentImageAttachment(source: .localFile(path: inFlight)),
            // Outside the managed store: never authorized even though the session references it.
            AgentImageAttachment(source: .localFile(path: "/etc/hosts.png")),
            AgentImageAttachment(source: .localFile(path: "\(store)/nested/DEEP.png")),
            AgentImageAttachment(source: .url("https://example.com/remote.png"))
        ])
        session.appendItem(.user("earlier", attachments: [
            AgentImageAttachment(source: .localFile(path: earlierTurn)),
            AgentImageAttachment(source: .localFile(path: inFlight))
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
        let attachment = AgentImageAttachment(source: .localFile(path: temporaryFile.path), title: "shot.png")
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
        let attachment = try AgentImageAttachment(source: .localFile(path: writeTemporaryImage().path))
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
        let attachment = AgentImageAttachment(source: .localFile(path: temporaryFile.path))
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
        let attachment = AgentImageAttachment(source: .localFile(path: deadPath), title: "lost.png")
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

    func testRetentionMarksTheMovedTemporaryPathMissing() async throws {
        let viewModel = makeViewModel()
        let attachmentsRoot = workspaceDirectory.appendingPathComponent("AgentSessions/attachments", isDirectory: true)
        viewModel.sessionAttachmentsRootOverride = { attachmentsRoot }
        let session = viewModel.session(for: UUID())
        session.testInstallPersistentSessionBinding(sessionID: UUID())
        let temporaryFile = try writeTemporaryImage()
        let temporaryPath = temporaryFile.standardizedFileURL.path
        AgentAttachmentThumbnailCache.shared.availability.record(.available, forPath: temporaryPath)
        let attachment = AgentImageAttachment(source: .localFile(path: temporaryFile.path))
        session.appendItem(.user("look", attachments: [attachment]))
        let reservationID = viewModel.reserveAttachmentsForTurn([attachment], session: session)

        viewModel.finalizeAttachmentsForTurn(for: session, reservationID: reservationID, disposition: .deleteFiles)
        await viewModel.waitForAttachmentRetention()

        XCTAssertEqual(AgentAttachmentThumbnailCache.shared.availability.cachedAvailability(forPath: temporaryPath), .missing)
    }

    func testPaneEntryClearsAStuckTextViewHover() {
        let controller = AgentImageDropController()
        controller.setTextViewImageDragActive(true)
        controller.paneDragEntered(typeIdentifiers: ["public.utf8-plain-text"], fileURLProviders: [], currentTabID: UUID())
        XCTAssertFalse(controller.isTextViewImageDragActive)
        XCTAssertFalse(controller.isOverlayVisible)
    }

    func testFinishedTurnWithoutPersistedSessionDeletesTemporaryCopy() async throws {
        let viewModel = makeViewModel()
        let tabID = UUID()
        let session = viewModel.session(for: tabID)
        session.testInstallPersistentSessionBinding(sessionID: UUID())
        let temporaryFile = try writeTemporaryImage()
        let attachment = AgentImageAttachment(source: .localFile(path: temporaryFile.path))
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
        let attachment = AgentImageAttachment(source: .localFile(path: temporaryFile.path))
        let reservationID = viewModel.reserveAttachmentsForTurn([attachment], session: session)

        viewModel.finalizeAttachmentsForTurn(for: session, reservationID: reservationID, disposition: .restoreToPending)
        await viewModel.waitForAttachmentRetention()

        XCTAssertTrue(FileManager.default.fileExists(atPath: temporaryFile.path))
        XCTAssertEqual(session.pendingImageAttachments, [attachment])
    }

    func testPasteAndDropAttachWhenAllowed() throws {
        let viewModel = makeViewModel()
        let tabID = UUID()
        let session = viewModel.session(for: tabID)
        let source = try writeSourceImage()

        XCTAssertNil(viewModel.imageAttachmentBlockReason(tabID: tabID))
        XCTAssertTrue(viewModel.attachImagesIfAllowed(tabID: tabID, urls: [source]))
        XCTAssertEqual(session.pendingImageAttachments.count, 1)
    }

    func testPasteAndDropAreBlockedWhileAgentIsBusyWithoutTouchingTheTranscript() throws {
        let viewModel = makeViewModel()
        let tabID = UUID()
        let session = viewModel.session(for: tabID)
        session.runState = .running
        let itemCountBefore = session.items.count
        let source = try writeSourceImage()

        XCTAssertEqual(viewModel.imageAttachmentBlockReason(tabID: tabID), .agentBusy)
        XCTAssertFalse(viewModel.attachImagesIfAllowed(tabID: tabID, urls: [source]))

        XCTAssertTrue(session.pendingImageAttachments.isEmpty)
        XCTAssertEqual(session.items.count, itemCountBefore, "A running turn streams into the last row")
        XCTAssertEqual(viewModel.imageAttachmentNotice?.tabID, tabID)
        XCTAssertEqual(viewModel.imageAttachmentNotice?.message, AgentImageAttachmentBlockReason.agentBusy.message)
    }

    func testPasteAndDropAreBlockedForProvidersWithoutImageSupport() throws {
        let viewModel = makeViewModel()
        let tabID = UUID()
        let session = viewModel.session(for: tabID)
        session.selectedAgent = .grokBuild
        let source = try writeSourceImage()

        XCTAssertFalse(viewModel.attachImagesIfAllowed(tabID: tabID, urls: [source]))

        XCTAssertTrue(session.pendingImageAttachments.isEmpty)
        let errorRow = try XCTUnwrap(session.items.last)
        XCTAssertEqual(errorRow.kind, .error)
        XCTAssertEqual(
            errorRow.text,
            AgentImageAttachmentBlockReason.providerUnsupported(providerName: AgentProviderKind.grokBuild.displayName).message
        )
    }

    func testPaneDropAttachesToTabCapturedAtDragStartAfterTabSwitch() {
        let controller = AgentImageDropController()
        let dragStartTab = UUID()
        let switchedTab = UUID()
        var pendingCompletion: (([AgentImageInputAdapter.PreparedImage]) -> Void)?
        var attachedTab: UUID?
        var attachedURLs: [URL] = []

        controller.paneDragEntered(typeIdentifiers: ["public.png"], fileURLProviders: [], currentTabID: dragStartTab)
        XCTAssertTrue(controller.isOverlayVisible)
        XCTAssertTrue(controller.acceptsPaneDrop)

        let accepted = controller.performPaneDrop(
            currentTabID: switchedTab,
            load: { completion in
                pendingCompletion = completion
                return true
            },
            attach: { tabID, prepared in
                attachedTab = tabID
                attachedURLs = prepared.map(\.url)
            }
        )
        XCTAssertTrue(accepted)
        XCTAssertFalse(controller.isOverlayVisible)

        // The asynchronous load finishes after the user switched tabs.
        let image = URL(fileURLWithPath: "/tmp/dropped.png")
        pendingCompletion?([AgentImageInputAdapter.PreparedImage(url: image, isTemporary: false)])
        XCTAssertEqual(attachedTab, dragStartTab)
        XCTAssertEqual(attachedURLs, [image])
    }

    func testNonImageDropsAreNotHighlightedOrAccepted() {
        let controller = AgentImageDropController()
        var loadCalled = false

        controller.paneDragEntered(typeIdentifiers: ["public.utf8-plain-text"], fileURLProviders: [], currentTabID: UUID())
        XCTAssertFalse(controller.isOverlayVisible)
        XCTAssertFalse(controller.acceptsPaneDrop)

        let accepted = controller.performPaneDrop(
            currentTabID: UUID(),
            load: { _ in
                loadCalled = true
                return true
            },
            attach: { _, _ in XCTFail("Non-image drops must not attach") }
        )
        XCTAssertFalse(accepted)
        XCTAssertFalse(loadCalled)
    }

    func testTextViewImageDragKeepsOverlayLitAfterPaneExit() {
        let controller = AgentImageDropController()
        controller.paneDragEntered(typeIdentifiers: ["public.png"], fileURLProviders: [], currentTabID: UUID())
        controller.paneDragExited()
        controller.setTextViewImageDragActive(true)
        XCTAssertTrue(controller.isOverlayVisible)
        controller.setTextViewImageDragActive(false)
        XCTAssertFalse(controller.isOverlayVisible)
    }

    // MARK: - Helpers

    private func writeTemporaryImage() throws -> URL {
        let temporaryRoot = AgentAttachmentStore.managedStorageRootURL(for: workspaceDirectory)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        let fileURL = temporaryRoot.appendingPathComponent("\(UUID().uuidString).png")
        try Data("temporary image".utf8).write(to: fileURL)
        return fileURL
    }

    private func writeSourceImage() throws -> URL {
        let fileURL = workspaceDirectory.appendingPathComponent("source-\(UUID().uuidString).png")
        try Data("source image \(UUID().uuidString)".utf8).write(to: fileURL)
        return fileURL
    }

    private func makeViewModel() -> AgentModeViewModel {
        AgentModeViewModel(
            testWorkspaceDirectory: workspaceDirectory,
            codexControllerFactory: { _, _, _, _, _, _ in
                preconditionFailure("Image attachment retention tests must not start Codex")
            },
            headlessProviderFactory: { _, _ in
                UnsupportedHeadlessAgentProvider(reason: "image attachment retention test")
            }
        )
    }
}
