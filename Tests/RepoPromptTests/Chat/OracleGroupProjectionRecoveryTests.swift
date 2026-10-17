import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptSettingsCore
import XCTest

@MainActor
final class OracleGroupProjectionRecoveryTests: XCTestCase {
    func testSettledLaneAwaitsCanonicalPublicationWithoutLosingOwnershipGuards() throws {
        let workspaceID = UUID()
        let tabID = UUID()
        let owner = try OracleViewModel.oracleGroupOwner(workspaceID: workspaceID, tabID: tabID)
        let models = try ["model-a", "model-b"].map { try OracleModelReference(modelID: $0) }
        let descriptor = try OracleGroupDescriptor(size: models.count)
        let members = try models.enumerated().map { index, model in
            try OracleGroupMember(
                laneID: OracleLaneID(index: index), publicChatID: "lane-\(index)", model: model
            )
        }
        let timestamp = Date(timeIntervalSince1970: 1000)
        let prepared = try OracleGroupDocument(
            group: descriptor, owner: owner, name: "Publication", revision: 1,
            createdAt: timestamp, updatedAt: timestamp,
            roster: OracleRoster(primary: models[0], additional: [models[1]]), members: members,
            turns: [OracleTurnRecord(
                input: OracleInput(mode: .chat, userMessage: "Question"), state: .prepared, startedAt: timestamp
            )]
        )
        let turnID = try XCTUnwrap(prepared.turns.last?.id)
        let sessions = members.map { member in
            ChatSession(
                id: member.memberID.rawValue, workspaceID: workspaceID, composeTabID: tabID,
                oracleGroupID: descriptor.id.rawValue, oracleLaneIndex: member.laneID.index,
                oracleGroupSize: 2, oracleModelRaw: member.model.modelID,
                name: "Publication", shortID: member.publicChatID
            )
        }
        var presentation = OracleGroupPresentation(document: prepared, invocationID: UUID())
        for member in members {
            presentation.receive(.init(
                kind: .laneStarted, groupID: descriptor.id, turnID: turnID,
                laneID: member.laneID, sequence: 0
            ))
        }
        presentation.receive(.init(
            kind: .laneSettled, groupID: descriptor.id, turnID: turnID,
            laneID: members[0].laneID, sequence: 2, text: "completed"
        ))
        XCTAssertEqual(presentation.member(sessions[0]).status.rawValue, "Settled — awaiting group result")
        XCTAssertEqual(presentation.member(sessions[1]).status, .streaming)
        let settled = presentation
        for event in [
            OracleProgressEvent(kind: .laneStarted, groupID: descriptor.id, turnID: turnID, laneID: members[0].laneID, sequence: 1),
            OracleProgressEvent(kind: .laneStarted, groupID: descriptor.id, turnID: turnID, laneID: members[0].laneID, sequence: 2),
            OracleProgressEvent(kind: .laneSettled, groupID: OracleGroupID(rawValue: UUID()), turnID: turnID, laneID: members[1].laneID, sequence: 3),
            OracleProgressEvent(kind: .laneSettled, groupID: descriptor.id, turnID: OracleTurnID(rawValue: UUID()), laneID: members[1].laneID, sequence: 3),
            OracleProgressEvent(kind: .laneStarted, groupID: descriptor.id, turnID: turnID, laneID: members[0].laneID, sequence: 3)
        ] {
            presentation.receive(event)
            XCTAssertEqual(presentation, settled)
        }
        var wrongOwner = sessions[0]
        wrongOwner.composeTabID = UUID()
        XCTAssertEqual(presentation.member(wrongOwner).status, .unknown)
        presentation.receive(.init(
            kind: .laneSettled, groupID: descriptor.id, turnID: turnID,
            laneID: members[1].laneID, sequence: 1, text: "failed"
        ))
        XCTAssertEqual(presentation.member(sessions[1]).status.rawValue, "Settled — awaiting group result")
        presentation.endExecution()
        XCTAssertEqual(presentation.member(sessions[0]).status, .unknown)
        presentation.receive(.init(
            kind: .laneStarted, groupID: descriptor.id, turnID: turnID,
            laneID: members[0].laneID, sequence: 3
        ))
        XCTAssertEqual(presentation.member(sessions[0]).status, .unknown)

        let results = try members.map { member in
            let failed = member.laneID.index == 1
            return try OracleLaneResult(
                laneIndex: member.laneID.index, chatID: member.publicChatID,
                providerID: member.model.providerID, modelID: member.model.modelID,
                status: failed ? .failed : .completed, response: failed ? nil : "Paid answer",
                error: failed ? OracleLaneError(code: "provider_error", message: "Provider stopped") : nil
            )
        }
        let terminal = try prepared.settling(OracleGroupResult(
            groupID: descriptor.id, status: .partialFailure, oracleResults: results
        ))
        presentation = OracleGroupPresentation(document: terminal)
        XCTAssertEqual(presentation.member(sessions[0]).status, .completed)
        XCTAssertEqual(presentation.member(sessions[1]).status, .failed)
        let published = presentation
        presentation.receive(.init(
            kind: .laneStarted, groupID: descriptor.id, turnID: turnID,
            laneID: members[0].laneID, sequence: 4
        ))
        presentation.endExecution()
        XCTAssertEqual(presentation, published)
    }

    func testMissingProjectionWithPriorOutputFailsBeforeProviderDispatch() async throws {
        for partial in [false, true] {
            let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            let composition = WindowStateCompositionFactory.make(
                windowID: partial ? -2885 : -2884,
                deferredInitialAgentSystemWorkspaceRefresh: true,
                sharedMCPService: MCPService()
            )
            GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
            await composition.workspaceManager.awaitInitialized()

            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("OracleGroupProjectionRecoveryTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer {
                composition.oracleViewModel.sessions = []
                try? FileManager.default.removeItem(at: root)
            }
            var workspace = try XCTUnwrap(composition.workspaceManager.activeWorkspace)
            let tab = ComposeTabState(id: UUID())
            workspace.customStoragePath = root
            workspace.composeTabs = [tab]
            workspace.activeComposeTabID = tab.id
            if let index = composition.workspaceManager.workspaces.firstIndex(where: { $0.id == workspace.id }) {
                composition.workspaceManager.workspaces[index] = workspace
            }
            composition.workspaceManager.activeWorkspace = workspace
            composition.promptManager.loadComposeTabsFromWorkspace(workspace)
            await composition.oracleViewModel.loadSessionsFromWorkspace()
            composition.oracleViewModel.sessions = []

            let owner = try OracleViewModel.oracleGroupOwner(workspaceID: workspace.id, tabID: tab.id)
            let models = try ["model-a", "model-b"].map { try OracleModelReference(modelID: $0) }
            let descriptor = try OracleGroupDescriptor(size: models.count)
            let members = try models.enumerated().map { index, model in
                let id = UUID()
                let name = OracleViewModel.oracleProjectionName(base: "History", laneIndex: index)
                return try OracleGroupMember(
                    laneID: OracleLaneID(index: index),
                    memberID: OracleMemberID(rawValue: id),
                    publicChatID: ChatSession.makeShortID(name: name, uuid: id),
                    model: model
                )
            }
            let timestamp = Date(timeIntervalSince1970: 1000)
            let prepared = try OracleGroupDocument(
                group: descriptor,
                owner: owner,
                name: "History",
                revision: 1,
                createdAt: timestamp,
                updatedAt: timestamp,
                roster: OracleRoster(primary: models[0], additional: [models[1]]),
                members: members,
                turns: [OracleTurnRecord(
                    input: OracleInput(mode: .chat, userMessage: "First question"),
                    state: .prepared,
                    startedAt: timestamp
                )]
            )
            let results = try members.map { member in
                let failed = partial && member.laneID.index == 1
                return try OracleLaneResult(
                    laneIndex: member.laneID.index,
                    chatID: member.publicChatID,
                    providerID: member.model.providerID,
                    modelID: member.model.modelID,
                    status: failed ? .failed : .completed,
                    response: failed ? nil : "Previous answer",
                    error: failed ? OracleLaneError(
                        code: "provider_error",
                        message: "Provider stopped",
                        partialResponse: "Previous partial answer"
                    ) : nil
                )
            }
            let terminal = try prepared.settling(OracleGroupResult(
                groupID: descriptor.id,
                status: partial ? .partialFailure : .completed,
                oracleResults: results
            ))
            let store = AppDomainRuntimeComposition.shared.oracleConversationStore
            try await store.create(prepared)
            addTeardownBlock {
                if let retained = try await store.load(groupID: descriptor.id, owner: owner) {
                    try await store.delete(groupID: descriptor.id, owner: owner, expectedRevision: retained.revision)
                }
            }
            try await store.save(terminal, expectedRevision: prepared.revision)

            // The primary projection survives; its sibling's prior answer exists only in the canonical group.
            let primary = members[0]
            composition.oracleViewModel.sessions = [ChatSession(
                id: primary.memberID.rawValue,
                workspaceID: workspace.id,
                composeTabID: tab.id,
                oracleGroupID: descriptor.id.rawValue,
                oracleLaneIndex: 0,
                oracleGroupSize: 2,
                oracleModelRaw: primary.model.modelID,
                name: "History",
                messages: [StoredMessage(isUser: false, rawText: "Previous answer", sequenceIndex: 0)],
                shortID: primary.publicChatID
            )]
            let context = OracleViewModel.OracleSendTabContext(
                tabID: tab.id,
                workspaceID: workspace.id,
                packaging: OracleViewModel.OracleSendPackagingContext(
                    sourceTabID: tab.id,
                    sourceWorkspaceID: workspace.id,
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
            composition.workspaceManager.setActiveChatSessionID(primary.memberID.rawValue, forTabID: tab.id)
            do {
                _ = try await composition.oracleViewModel.tool_chatSendWithConfiguredRosterCompletion(
                    args: ["message": .string("Follow up")],
                    promptVM: composition.promptManager,
                    tabContext: context,
                    callbacks: AppOracleGroupExecutionCallbacks(
                        prepared: { _, _, _ in throw TestStop.unexpectedPreparedCallback },
                        progress: { _ in },
                        laneProgress: { _, _, _ in }
                    ),
                    capturedProfile: AgentModelsSettingsProfile(
                        planningModelRaw: "model-a",
                        additionalOracleModelRaws: ["model-b"]
                    )
                )
                XCTFail("Expected missing conversation history to reject continuation")
            } catch let error as ChatToolError {
                XCTAssertEqual(error.code, .invalidParams)
                XCTAssertEqual(
                    error.message,
                    "Oracle conversation history is unavailable. Restore the chat history or set new_chat=true."
                )
            } catch {
                XCTFail("Unexpected error: \(error)")
            }

            XCTAssertEqual(composition.oracleViewModel.sessions.map(\.id), [primary.memberID.rawValue])
            let retained = try await store.load(groupID: descriptor.id, owner: owner)
            XCTAssertEqual(retained?.turns.first, terminal.turns.first)
        }
    }

    func testAutosaveWithoutWorkspaceReportsFailureExactlyOnce() async {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        defer { GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false) }
        let composition = WindowStateCompositionFactory.make(
            windowID: -2886,
            deferredInitialAgentSystemWorkspaceRefresh: true,
            sharedMCPService: MCPService()
        )
        await composition.workspaceManager.awaitInitialized()
        defer { composition.workspaceManager.prepareForWindowClose() }
        let session = ChatSession(workspaceID: nil, name: "Missing workspace")
        composition.oracleViewModel.sessions = [session]
        composition.oracleViewModel.currentSessionID = session.id
        composition.oracleViewModel.messages = []
        var completions: [Bool] = []

        composition.oracleViewModel.autosaveChatHistory(for: session.id, force: true) {
            completions.append($0)
        }

        XCTAssertEqual(completions, [false])
    }

    private enum TestStop: Error {
        case unexpectedPreparedCallback
    }
}
