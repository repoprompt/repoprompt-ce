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
