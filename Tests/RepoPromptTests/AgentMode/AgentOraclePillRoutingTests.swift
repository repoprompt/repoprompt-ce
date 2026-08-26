import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
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
                sessions: [historical, latestProjected]
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
        XCTAssertEqual(
            AgentOraclePillLogic.aggregateOracleCount(configuredAdditionalCount: 99, sessions: []),
            5
        )
        XCTAssertEqual(
            (0 ... 4).map(OracleViewModel.oracleLabel(laneIndex:)),
            ["Oracle", "Oracle 2", "Oracle 3", "Oracle 4", "Oracle 5"]
        )
        XCTAssertEqual(
            AgentOraclePillLogic.laneDotState(isStreaming: true, lastAssistantContent: "Error: stale"),
            .streaming
        )
        XCTAssertEqual(
            AgentOraclePillLogic.laneDotState(
                isStreaming: false,
                lastAssistantContent: "partial answer\n\n--\nError:\nstatus code 502"
            ),
            .failed
        )
        XCTAssertEqual(
            AgentOraclePillLogic.laneDotState(
                isStreaming: false,
                lastAssistantContent: "Error: status code 502 Gemini response stalled"
            ),
            .failed
        )
        XCTAssertEqual(
            AgentOraclePillLogic.laneDotState(
                isStreaming: false,
                lastAssistantContent: "Review looks correct. Mention error handling."
            ),
            .completed
        )
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

    func testOnlyExplicitStartUsesConfiguredAdditionalModelsToCreateGroup() throws {
        let explicitStart = try OracleConversationRoute.resolve(
            chatID: nil,
            newChat: true,
            modelOverride: nil,
            whenMissingChatID: .continueCurrent
        )
        let implicitContinuation = try OracleConversationRoute.resolve(
            chatID: nil,
            newChat: false,
            modelOverride: nil,
            whenMissingChatID: .continueCurrent
        )
        let exactContinuation = try OracleConversationRoute.resolve(
            chatID: "single-chat",
            newChat: false,
            modelOverride: nil,
            whenMissingChatID: .continueCurrent
        )

        XCTAssertTrue(AppOracleGroupRouting.startsConfiguredGroup(
            route: explicitStart,
            additionalModelRaws: ["model-b"]
        ))
        XCTAssertFalse(AppOracleGroupRouting.startsConfiguredGroup(
            route: implicitContinuation,
            additionalModelRaws: ["model-b"]
        ))
        XCTAssertFalse(AppOracleGroupRouting.startsConfiguredGroup(
            route: exactContinuation,
            additionalModelRaws: ["model-b"]
        ))
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
            deferredInitialAgentSystemWorkspaceRefresh: false,
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
