import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class OraclePairPreparationTests: XCTestCase {
    func testInMemoryPairResolutionPreservesExactRouteAndRejectsDuplicates() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let pairID = UUID()
        let ownerSessionID = UUID()
        let ownerRunID = UUID()
        let primary = makeSession(
            fixture: fixture,
            pairID: pairID,
            lane: .primary,
            ownerSessionID: ownerSessionID,
            ownerRunID: ownerRunID
        )
        let secondary = makeSession(
            fixture: fixture,
            pairID: pairID,
            lane: .secondary,
            ownerSessionID: ownerSessionID,
            ownerRunID: ownerRunID
        )
        fixture.oracleViewModel.sessions = [primary, secondary]

        let resolved = try await fixture.oracleViewModel.resolveInMemoryOraclePairMembers(
            pairID: pairID,
            workspaceID: fixture.workspace.id,
            tabID: fixture.tabID,
            agentModeSessionID: ownerSessionID,
            agentModeRunID: ownerRunID
        )
        XCTAssertEqual(resolved?.primary.id, primary.id)
        XCTAssertEqual(resolved?.secondary.id, secondary.id)
        let durableStubs = try await fixture.oracleViewModel.chatData.oraclePairSessionStubs(
            for: fixture.workspace,
            pairID: pairID
        )
        XCTAssertTrue(durableStubs.isEmpty)

        let routeMismatch = try await fixture.oracleViewModel.resolveInMemoryOraclePairMembers(
            pairID: pairID,
            workspaceID: fixture.workspace.id,
            tabID: UUID(),
            agentModeSessionID: ownerSessionID,
            agentModeRunID: ownerRunID
        )
        XCTAssertNil(routeMismatch)

        fixture.oracleViewModel.sessions = [primary]
        let incomplete = try await fixture.oracleViewModel.resolveInMemoryOraclePairMembers(
            pairID: pairID,
            workspaceID: fixture.workspace.id,
            tabID: fixture.tabID,
            agentModeSessionID: ownerSessionID,
            agentModeRunID: ownerRunID
        )
        XCTAssertNil(incomplete)

        let duplicatePrimary = makeSession(
            fixture: fixture,
            pairID: pairID,
            lane: .primary,
            ownerSessionID: ownerSessionID,
            ownerRunID: ownerRunID
        )
        fixture.oracleViewModel.sessions = [primary, duplicatePrimary]
        do {
            _ = try await fixture.oracleViewModel.resolveInMemoryOraclePairMembers(
                pairID: pairID,
                workspaceID: fixture.workspace.id,
                tabID: fixture.tabID,
                agentModeSessionID: ownerSessionID,
                agentModeRunID: ownerRunID
            )
            XCTFail("Expected duplicate lane conflict")
        } catch let error as ChatToolError {
            XCTAssertEqual(error.code, .conflict)
            XCTAssertTrue(error.message.contains("duplicate lanes"))
        }
    }

    func testLaneEffectiveModelsPersistWithFinalPairGeneration() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let pairID = UUID()
        let primary = makeSession(fixture: fixture, pairID: pairID, lane: .primary)
        let secondary = makeSession(fixture: fixture, pairID: pairID, lane: .secondary)
        fixture.oracleViewModel.sessions = [primary, secondary]
        let primaryLoaded = await fixture.oracleViewModel.ensureSessionMessagesLoaded(primary.id)
        let secondaryLoaded = await fixture.oracleViewModel.ensureSessionMessagesLoaded(secondary.id)
        XCTAssertTrue(primaryLoaded)
        XCTAssertTrue(secondaryLoaded)

        fixture.oracleViewModel.recordLaneEffectiveModel(sessionID: primary.id, model: .gpt54Pro)
        fixture.oracleViewModel.recordLaneEffectiveModel(sessionID: secondary.id, model: .claude4Sonnet)
        _ = try await fixture.oracleViewModel.persistOraclePairHistories(
            pairID: pairID,
            primarySessionID: primary.id,
            secondarySessionID: secondary.id
        )

        let stubs = try await fixture.oracleViewModel.chatData.oraclePairSessionStubs(
            for: fixture.workspace,
            pairID: pairID
        )
        XCTAssertEqual(stubs.count, 2)
        var persisted: [ChatSession] = []
        for stub in stubs {
            let fileURL = try XCTUnwrap(stub.fileURL)
            try await persisted.append(fixture.oracleViewModel.chatData.loadChatSession(from: fileURL))
        }
        XCTAssertEqual(
            persisted.first(where: { $0.oracleLane == .primary })?.preferredAIModel,
            AIModel.gpt54Pro.rawValue
        )
        XCTAssertEqual(
            persisted.first(where: { $0.oracleLane == .secondary })?.preferredAIModel,
            AIModel.claude4Sonnet.rawValue
        )
    }

    func testFiveLaneHistoryPersistenceIsAtomicAndDivergesFromAnyNonPrimaryHistory() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let groupID = UUID()
        let lanes = try OracleLane.orderedPrefix(count: 5)
        var members = lanes.map { lane in
            makeSession(
                fixture: fixture,
                pairID: groupID,
                lane: lane,
                groupSize: lanes.count
            )
        }
        for index in members.indices {
            members[index].messages = [
                StoredMessage(
                    isUser: true,
                    rawText: lanes[index] == .oracle4 ? "different user turn" : "shared user turn",
                    sequenceIndex: 0
                )
            ]
        }
        fixture.oracleViewModel.sessions = members
        for member in members {
            let loaded = await fixture.oracleViewModel.ensureSessionMessagesLoaded(member.id)
            XCTAssertTrue(loaded)
        }

        let diverged = try await fixture.oracleViewModel.persistOracleGroupHistories(
            groupID: groupID,
            sessionIDsByLane: Dictionary(uniqueKeysWithValues: zip(lanes, members.map(\.id)))
        )

        XCTAssertTrue(diverged)
        let stubs = try await fixture.oracleViewModel.chatData.oraclePairSessionStubs(
            for: fixture.workspace,
            pairID: groupID
        )
        XCTAssertEqual(stubs.compactMap(\.oracleLane), lanes)
        XCTAssertTrue(stubs.allSatisfy { $0.oracleGroupSize == 5 && $0.oracleHistoryDiverged })
        for stub in stubs {
            let persisted = try await fixture.oracleViewModel.chatData.loadChatSession(
                from: XCTUnwrap(stub.fileURL)
            )
            XCTAssertEqual(persisted.messages.count, 1)
            XCTAssertTrue(persisted.oracleHistoryDiverged)
        }
    }

    func testFiveLaneRenamePersistsTheWholeGroup() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let groupID = UUID()
        let lanes = try OracleLane.orderedPrefix(count: 5)
        let members = lanes.map { lane in
            makeSession(
                fixture: fixture,
                pairID: groupID,
                lane: lane,
                groupSize: lanes.count
            )
        }
        fixture.oracleViewModel.sessions = members
        _ = try await fixture.oracleViewModel.chatData.saveOraclePairSessions(
            members,
            for: fixture.workspace
        )
        let renamed = try XCTUnwrap(members.first(where: { $0.oracleLane == .oracle4 }))

        try await fixture.oracleViewModel.persistOraclePairRename(
            sessionID: renamed.id,
            newName: "Renamed Oracle 4"
        )

        let stubs = try await fixture.oracleViewModel.chatData.oraclePairSessionStubs(
            for: fixture.workspace,
            pairID: groupID
        )
        XCTAssertEqual(stubs.compactMap(\.oracleLane), lanes)
        for stub in stubs {
            let persisted = try await fixture.oracleViewModel.chatData.loadChatSession(
                from: XCTUnwrap(stub.fileURL)
            )
            let original = try XCTUnwrap(members.first(where: { $0.id == persisted.id }))
            let expectedName = persisted.id == renamed.id ? "Renamed Oracle 4" : original.name
            XCTAssertEqual(persisted.name, expectedName)
        }
    }

    func testDeletingOneFiveLaneMemberDeletesTheWholeGroup() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let groupID = UUID()
        let lanes = try OracleLane.orderedPrefix(count: 5)
        let members = lanes.map { lane in
            makeSession(
                fixture: fixture,
                pairID: groupID,
                lane: lane,
                groupSize: lanes.count
            )
        }
        fixture.oracleViewModel.sessions = members
        let fileURLs = try await fixture.oracleViewModel.chatData.saveOraclePairSessions(
            members,
            for: fixture.workspace
        )

        let deleted = await fixture.oracleViewModel.deleteClaimedSession(
            members[2],
            workspace: fixture.workspace
        )

        XCTAssertTrue(deleted)
        XCTAssertFalse(fixture.oracleViewModel.sessions.contains { $0.oraclePairID == groupID })
        XCTAssertTrue(fileURLs.values.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    func testExplicitContinuationLoadsTheCompletePersistedFiveLaneGroupFromOneColdMember() async throws {
        let fixture = try await makeFixture(sendPromptOverride: { _, model in
            (UUID(), completedOracleStream("\(model.rawValue) continued"))
        })
        defer { fixture.cleanup() }
        let groupID = UUID()
        let lanes = try OracleLane.orderedPrefix(count: 5)
        let members = lanes.map { lane in
            makeSession(
                fixture: fixture,
                pairID: groupID,
                lane: lane,
                groupSize: lanes.count
            )
        }
        _ = try await fixture.oracleViewModel.chatData.saveOraclePairSessions(
            members,
            for: fixture.workspace
        )
        let focusedTabID = UUID()
        var workspace = try XCTUnwrap(fixture.composition.workspaceManager.activeWorkspace)
        workspace.composeTabs.append(ComposeTabState(id: focusedTabID))
        workspace.activeComposeTabID = focusedTabID
        if let index = fixture.composition.workspaceManager.workspaces.firstIndex(where: { $0.id == workspace.id }) {
            fixture.composition.workspaceManager.workspaces[index] = workspace
        }
        fixture.composition.workspaceManager.activeWorkspace = workspace
        fixture.composition.promptManager.loadComposeTabsFromWorkspace(workspace)
        let focused = ChatSession(
            workspaceID: fixture.workspace.id,
            composeTabID: focusedTabID,
            name: "Focused unrelated chat"
        )
        fixture.oracleViewModel.sessions = [focused]
        fixture.oracleViewModel.currentSessionID = focused.id
        fixture.composition.workspaceManager.setActiveChatSessionID(focused.id, forTabID: focusedTabID)
        fixture.composition.workspaceManager.setActiveChatSessionID(nil, forTabID: fixture.tabID)

        let prompt = "Continue the persisted Oracle group."
        let packaging = OracleViewModel.OracleSendPackagingContext(
            sourceTabID: fixture.tabID,
            sourceWorkspaceID: fixture.workspace.id,
            sourceSelectionRevision: 0,
            sourceAgentSessionID: nil,
            sourceAgentRunID: nil,
            promptText: prompt,
            selection: StoredSelection(),
            lookupContext: nil,
            reviewGitContext: .automaticOnly(),
            provenance: .direct
        )
        let context = OracleViewModel.OracleSendTabContext(
            tabID: fixture.tabID,
            workspaceID: fixture.workspace.id,
            activationPolicy: .background,
            completionPolicy: .contextBuilderStrict,
            packaging: packaging
        )
        let primarySelection = OracleViewModel.ModelSelectionResult(
            model: .gpt54Pro,
            mcpControlInfo: nil,
            isAutoSelected: false,
            chatPresetID: nil
        )
        let additionalModels: [AIModel] = [
            .claude4Sonnet,
            .gpt54Pro,
            .claude4Sonnet,
            .gpt54Pro
        ]

        let result = try await fixture.oracleViewModel.sendOracle(
            args: [
                "message": .string(prompt),
                "chat_id": .string(members[4].shortID),
                "new_chat": .bool(false)
            ],
            promptVM: fixture.oracleViewModel.promptViewModel,
            tabContext: context,
            primaryModelSelection: primarySelection,
            additionalModelOverrides: additionalModels
        )

        guard case let .paired(group) = result.payload else {
            return XCTFail("Expected the persisted Oracle group to continue")
        }
        XCTAssertEqual(group.groupID, groupID)
        XCTAssertEqual(group.oracleCount, lanes.count)
        XCTAssertEqual(
            group.sessionIDsByLane,
            Dictionary(uniqueKeysWithValues: zip(lanes, members.map(\.id)))
        )
        XCTAssertEqual(
            Set(fixture.oracleViewModel.sessions.filter { $0.oraclePairID == groupID }.map(\.id)),
            Set(members.map(\.id))
        )
        XCTAssertEqual(fixture.oracleViewModel.currentSessionID, focused.id)
        XCTAssertEqual(
            fixture.composition.workspaceManager.activeChatSessionID(forTabID: focusedTabID),
            focused.id
        )
        XCTAssertNil(fixture.composition.workspaceManager.activeChatSessionID(forTabID: fixture.tabID))
    }

    func testGroupedDeletionFailsClosedWhenOwningWorkspaceIsUnavailable() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let pairID = UUID()
        var primary = makeSession(fixture: fixture, pairID: pairID, lane: .primary)
        var secondary = makeSession(fixture: fixture, pairID: pairID, lane: .secondary)
        let fileURLs = try await fixture.oracleViewModel.chatData.saveOraclePairSessions(
            [primary, secondary],
            for: fixture.workspace
        )
        primary.fileURL = fileURLs[primary.id]
        secondary.fileURL = fileURLs[secondary.id]
        primary.workspaceID = UUID()
        fixture.oracleViewModel.sessions = [primary, secondary]

        let deleted = await fixture.oracleViewModel.deleteSession(primary)

        XCTAssertFalse(deleted)
        XCTAssertEqual(Set(fixture.oracleViewModel.sessions.map(\.id)), Set([primary.id, secondary.id]))
        XCTAssertTrue(fileURLs.values.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    func testGroupedDeletionRejectsMixedGroupedAndLegacySeedsWithoutDeletingEither() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let pairID = UUID()
        let primary = makeSession(fixture: fixture, pairID: pairID, lane: .primary)
        let secondary = makeSession(fixture: fixture, pairID: pairID, lane: .secondary)
        let groupURLs = try await fixture.oracleViewModel.chatData.saveOraclePairSessions(
            [primary, secondary],
            for: fixture.workspace
        )
        let legacy = ChatSession(
            workspaceID: fixture.workspace.id,
            composeTabID: fixture.tabID,
            name: "Unrelated legacy chat"
        )
        let legacyURL = try await fixture.oracleViewModel.chatData.saveChatSession(
            legacy,
            for: fixture.workspace
        )

        do {
            try await fixture.oracleViewModel.chatData.deleteOraclePairSessionFiles(
                [primary.id, legacy.id],
                for: fixture.workspace
            )
            XCTFail("Expected mixed grouped and legacy deletion seeds to be rejected")
        } catch is ChatDataError {}

        XCTAssertTrue(groupURLs.values.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path))
    }

    func testPairedRenamePersistsBothMembersOrLeavesTheVisibleNameUnchanged() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let pairID = UUID()
        let primary = makeSession(fixture: fixture, pairID: pairID, lane: .primary)
        let secondary = makeSession(fixture: fixture, pairID: pairID, lane: .secondary)
        fixture.oracleViewModel.sessions = [primary, secondary]
        let fileURLs = try await fixture.oracleViewModel.chatData.saveOraclePairSessions(
            [primary, secondary],
            for: fixture.workspace
        )

        try await fixture.oracleViewModel.persistOraclePairRename(
            sessionID: primary.id,
            newName: "Renamed Primary"
        )

        var persisted: [ChatSession] = []
        for stub in try await fixture.oracleViewModel.chatData.oraclePairSessionStubs(
            for: fixture.workspace,
            pairID: pairID
        ) {
            try await persisted.append(fixture.oracleViewModel.chatData.loadChatSession(
                from: XCTUnwrap(stub.fileURL)
            ))
        }
        XCTAssertEqual(persisted.count, 2)
        XCTAssertEqual(persisted.first(where: { $0.id == primary.id })?.name, "Renamed Primary")
        XCTAssertEqual(persisted.first(where: { $0.id == secondary.id })?.name, secondary.name)
        XCTAssertEqual(
            fixture.oracleViewModel.sessions.first(where: { $0.id == primary.id })?.name,
            "Renamed Primary"
        )

        try FileManager.default.removeItem(at: XCTUnwrap(fileURLs[secondary.id]))
        do {
            try await fixture.oracleViewModel.persistOraclePairRename(
                sessionID: primary.id,
                newName: "Must Not Stick"
            )
            XCTFail("Expected incomplete pair rename to fail")
        } catch let error as ChatToolError {
            XCTAssertEqual(error.code, .conflict)
        }
        XCTAssertEqual(
            fixture.oracleViewModel.sessions.first(where: { $0.id == primary.id })?.name,
            "Renamed Primary"
        )
        let remainingPrimary = try await fixture.oracleViewModel.chatData.loadChatSession(
            from: XCTUnwrap(fileURLs[primary.id])
        )
        XCTAssertEqual(remainingPrimary.name, "Renamed Primary")
    }

    func testPairedRenameProjectsCommittedNameAfterStaleReloadInterleaving() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let pairID = UUID()
        let primary = makeSession(fixture: fixture, pairID: pairID, lane: .primary)
        let secondary = makeSession(fixture: fixture, pairID: pairID, lane: .secondary)
        fixture.oracleViewModel.sessions = [primary, secondary]
        let fileURLs = try await fixture.oracleViewModel.chatData.saveOraclePairSessions(
            [primary, secondary],
            for: fixture.workspace
        )
        var stalePrimary = primary
        stalePrimary.fileURL = try XCTUnwrap(fileURLs[primary.id])
        fixture.oracleViewModel.oraclePairDidCommitTestHook = {
            guard let index = fixture.oracleViewModel.sessions.firstIndex(where: { $0.id == primary.id }) else {
                return XCTFail("Expected the Primary session during stale reload projection")
            }
            fixture.oracleViewModel.sessions[index] = stalePrimary
            await fixture.oracleViewModel.reloadSessionFromMemory(stalePrimary)
        }
        defer { fixture.oracleViewModel.oraclePairDidCommitTestHook = nil }

        try await fixture.oracleViewModel.persistOraclePairRename(
            sessionID: primary.id,
            newName: "Committed Rename"
        )

        let persistedPrimary = try await fixture.oracleViewModel.chatData.loadChatSession(
            from: XCTUnwrap(fileURLs[primary.id])
        )
        XCTAssertEqual(persistedPrimary.name, "Committed Rename")
        XCTAssertEqual(
            fixture.oracleViewModel.sessions.first(where: { $0.id == primary.id })?.name,
            "Committed Rename"
        )
    }

    func testPairedRenameDoesNotRollbackAfterDurableProjectionConflict() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let pairID = UUID()
        let primary = makeSession(fixture: fixture, pairID: pairID, lane: .primary)
        let secondary = makeSession(fixture: fixture, pairID: pairID, lane: .secondary)
        fixture.oracleViewModel.sessions = [primary, secondary]
        let fileURLs = try await fixture.oracleViewModel.chatData.saveOraclePairSessions(
            [primary, secondary],
            for: fixture.workspace
        )
        fixture.oracleViewModel.oraclePairDidCommitTestHook = {
            fixture.oracleViewModel.sessions.removeAll { $0.id == secondary.id }
        }
        defer { fixture.oracleViewModel.oraclePairDidCommitTestHook = nil }

        do {
            try await fixture.oracleViewModel.persistOraclePairRename(
                sessionID: primary.id,
                newName: "Durably Committed"
            )
            XCTFail("Expected a post-durable projection conflict")
        } catch let error as ChatToolError {
            XCTAssertEqual(error.code, .conflict)
            XCTAssertEqual(error.details?["durable_commit"], "true")
        }

        XCTAssertEqual(fixture.oracleViewModel.sessions.count, 2)
        XCTAssertEqual(
            fixture.oracleViewModel.sessions.first(where: { $0.id == primary.id })?.name,
            "Durably Committed"
        )
        XCTAssertEqual(
            fixture.oracleViewModel.sessions.first(where: { $0.id == secondary.id })?.name,
            secondary.name
        )
        let persistedPrimary = try await fixture.oracleViewModel.chatData.loadChatSession(
            from: XCTUnwrap(fileURLs[primary.id])
        )
        let persistedSecondary = try await fixture.oracleViewModel.chatData.loadChatSession(
            from: XCTUnwrap(fileURLs[secondary.id])
        )
        XCTAssertEqual(persistedPrimary.name, "Durably Committed")
        XCTAssertEqual(persistedSecondary.name, secondary.name)
    }

    func testPairedRenameDoesNotProjectIntoWorkspaceActivatedAfterDurableCommit() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let pairID = UUID()
        let primary = makeSession(fixture: fixture, pairID: pairID, lane: .primary)
        let secondary = makeSession(fixture: fixture, pairID: pairID, lane: .secondary)
        fixture.oracleViewModel.sessions = [primary, secondary]
        let fileURLs = try await fixture.oracleViewModel.chatData.saveOraclePairSessions(
            [primary, secondary],
            for: fixture.workspace
        )

        let ambientRoot = fixture.storageRoot.appendingPathComponent("AmbientWorkspace", isDirectory: true)
        try FileManager.default.createDirectory(at: ambientRoot, withIntermediateDirectories: true)
        let ambient = fixture.composition.workspaceManager.createWorkspace(
            name: "Ambient pair projection workspace",
            repoPaths: [ambientRoot.path],
            ephemeral: true
        )
        fixture.oracleViewModel.oraclePairDidCommitTestHook = {
            await fixture.composition.workspaceManager.switchWorkspace(
                to: ambient,
                saveState: false,
                reason: #function
            )
            await fixture.oracleViewModel.loadSessionsFromWorkspace()
        }
        defer { fixture.oracleViewModel.oraclePairDidCommitTestHook = nil }

        do {
            try await fixture.oracleViewModel.persistOraclePairRename(
                sessionID: primary.id,
                newName: "Committed Before Workspace Switch"
            )
            XCTFail("Expected a post-commit workspace projection conflict")
        } catch let error as ChatToolError {
            XCTAssertEqual(error.code, .conflict)
            XCTAssertEqual(error.details?["durable_commit"], "true")
        }

        XCTAssertEqual(fixture.composition.workspaceManager.activeWorkspaceID, ambient.id)
        XCTAssertFalse(fixture.oracleViewModel.sessions.contains { $0.id == primary.id || $0.id == secondary.id })
        XCTAssertTrue(fixture.oracleViewModel.sessions.allSatisfy { $0.workspaceID == ambient.id })

        let persistedPrimary = try await fixture.oracleViewModel.chatData.loadChatSession(
            from: XCTUnwrap(fileURLs[primary.id])
        )
        XCTAssertEqual(persistedPrimary.name, "Committed Before Workspace Switch")
    }

    func testDisabledSecondaryDoesNotAcquireThePairedRouteClaim() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let settings = GlobalSettingsStore.shared
        let priorSecondary = settings.secondaryOracleModelRaw()
        settings.setSecondaryOracleModelRaw(nil, commit: false)
        defer { settings.setSecondaryOracleModelRaw(priorSecondary, commit: false) }

        let claimStarted = expectation(description: "legacy claim holder started")
        let claim = OracleSendClaimKey.oracleSend(
            workspaceID: fixture.workspace.id,
            tabID: fixture.tabID,
            agentModeSessionID: nil,
            agentModeRunID: nil
        )
        let holder = Task { @MainActor in
            try await fixture.oracleViewModel.oracleSendClaims.withClaim([claim]) {
                claimStarted.fulfill()
                try await Task.sleep(for: .seconds(30))
            }
        }
        defer { holder.cancel() }
        await fulfillment(of: [claimStarted])

        do {
            _ = try await fixture.oracleViewModel.sendOracle(
                args: ["message": .string("")],
                promptVM: fixture.oracleViewModel.promptViewModel
            )
            XCTFail("Expected empty-message validation")
        } catch let error as ChatToolError {
            XCTAssertEqual(error.message, "message cannot be empty")
        }
        holder.cancel()
        do { _ = try await holder.value } catch is CancellationError {}
    }

    func testDisabledSecondaryPreservesLegacyTabBindingWhenTargetTabIsNotFocused() async throws {
        let model = AIModel.customProvider(name: "Primary", provider: "custom", model: "oracle-primary")
        let fixture = try await makeFixture(sendPromptOverride: { _, _ in
            (UUID(), completedOracleStream("single response"))
        })
        defer { fixture.cleanup() }
        let settings = GlobalSettingsStore.shared
        let priorSecondary = settings.secondaryOracleModelRaw()
        settings.setSecondaryOracleModelRaw(nil, commit: false)
        defer { settings.setSecondaryOracleModelRaw(priorSecondary, commit: false) }

        let focusedTabID = UUID()
        var workspace = try XCTUnwrap(fixture.composition.workspaceManager.activeWorkspace)
        workspace.composeTabs.append(ComposeTabState(id: focusedTabID))
        workspace.activeComposeTabID = focusedTabID
        if let index = fixture.composition.workspaceManager.workspaces.firstIndex(where: { $0.id == workspace.id }) {
            fixture.composition.workspaceManager.workspaces[index] = workspace
        }
        fixture.composition.workspaceManager.activeWorkspace = workspace
        fixture.composition.promptManager.loadComposeTabsFromWorkspace(workspace)

        let focused = ChatSession(
            workspaceID: fixture.workspace.id,
            composeTabID: focusedTabID,
            name: "Focused chat"
        )
        let target = ChatSession(
            workspaceID: fixture.workspace.id,
            composeTabID: fixture.tabID,
            name: "Background target"
        )
        fixture.oracleViewModel.sessions = [focused, target]
        fixture.oracleViewModel.currentSessionID = focused.id
        fixture.composition.workspaceManager.setActiveChatSessionID(focused.id, forTabID: focusedTabID)

        let packaging = OracleViewModel.OracleSendPackagingContext(
            sourceTabID: fixture.tabID,
            sourceWorkspaceID: fixture.workspace.id,
            sourceSelectionRevision: 0,
            sourceAgentSessionID: nil,
            sourceAgentRunID: nil,
            promptText: "Continue in the target chat.",
            selection: StoredSelection(),
            lookupContext: nil,
            reviewGitContext: .automaticOnly(),
            provenance: .direct
        )
        let context = OracleViewModel.OracleSendTabContext(
            tabID: fixture.tabID,
            workspaceID: fixture.workspace.id,
            packaging: packaging
        )
        let selection = OracleViewModel.ModelSelectionResult(
            model: model,
            mcpControlInfo: nil,
            isAutoSelected: false,
            chatPresetID: nil
        )

        let result = try await fixture.oracleViewModel.sendOracle(
            args: [
                "message": .string("Continue in the target chat."),
                "chat_id": .string(target.shortID)
            ],
            promptVM: fixture.oracleViewModel.promptViewModel,
            tabContext: context,
            primaryModelSelection: selection
        )

        guard case .single = result.payload else { return XCTFail("Expected the legacy single-Oracle path") }
        XCTAssertEqual(
            fixture.composition.workspaceManager.activeChatSessionID(forTabID: fixture.tabID),
            target.id
        )
        XCTAssertEqual(fixture.oracleViewModel.currentSessionID, focused.id)
    }

    func testPairedContextBuilderRuntimePackagesAndPersistsBothSuccessfulLanes() async throws {
        let recorder = OracleRuntimeMessageRecorder()
        let fixture = try await makeFixture(sendPromptOverride: { message, model in
            await recorder.record(
                modelRaw: model.rawValue,
                prompt: message.conversationMessages.last?.content,
                fileBlocks: message.fileBlocks
            )
            return (UUID(), completedOracleStream("\(model.rawValue) response"))
        })
        defer { fixture.cleanup() }
        let primaryModel = AIModel.customProvider(name: "Primary", provider: "custom", model: "oracle-primary")
        let secondaryModel = AIModel.customProvider(name: "Secondary", provider: "custom", model: "oracle-secondary")
        let priorSecondary = GlobalSettingsStore.shared.secondaryOracleModelRaw()
        GlobalSettingsStore.shared.setSecondaryOracleModelRaw(secondaryModel.rawValue, commit: false)
        defer { GlobalSettingsStore.shared.setSecondaryOracleModelRaw(priorSecondary, commit: false) }
        installFollowUpModel(primaryModel, in: fixture)
        defer { fixture.composition.contextBuilderAgentViewModel.installRunTestHooks(nil) }

        let sentinel = "dual-oracle-packaging-sentinel"
        let selectedFile = fixture.storageRoot.appendingPathComponent("Selected.swift")
        try Data("// \(sentinel)".utf8).write(to: selectedFile)
        let fileSystemSettings = GlobalSettingsStore.shared.fileSystemSettingsSnapshot()
        _ = try await fixture.composition.workspaceFileContextStore.loadRoot(
            path: fixture.storageRoot.path,
            respectRepoIgnore: fileSystemSettings.respectRepoIgnore,
            respectCursorignore: fileSystemSettings.respectCursorignore,
            skipSymlinks: fileSystemSettings.skipSymlinks,
            enableHierarchicalIgnores: fileSystemSettings.enableHierarchicalIgnores
        )
        let prompt = "Plan the dual Oracle runtime."
        let result = try await fixture.composition.contextBuilderAgentViewModel.runMCPPlanOrQuestion(
            for: fixture.tabID,
            oracleViewModel: fixture.oracleViewModel,
            mode: .plan,
            prompt: prompt,
            selection: StoredSelection(selectedPaths: [selectedFile.path]),
            reviewGitContext: .automaticOnly()
        )

        guard case let .paired(pair) = result.payload else { return XCTFail("Expected paired Oracle result") }
        XCTAssertEqual(pair.status, .completed)
        let stubs = try await fixture.oracleViewModel.chatData.oraclePairSessionStubs(
            for: fixture.workspace,
            pairID: pair.pairID
        )
        XCTAssertEqual(Set(stubs.compactMap(\.oracleLane)), Set([.primary, .secondary]))
        XCTAssertEqual(stubs.count, 2)
        let snapshots = await recorder.snapshot()
        XCTAssertEqual(Set(snapshots.map(\.modelRaw)), Set([primaryModel.rawValue, secondaryModel.rawValue]))
        XCTAssertTrue(snapshots.allSatisfy { $0.prompt?.contains(prompt) == true })
        XCTAssertTrue(snapshots.allSatisfy { $0.fileBlocks.joined(separator: "\n").contains(sentinel) })
    }

    func testFiveOracleContextBuilderRuntimeDispatchesAndPersistsEveryLane() async throws {
        let recorder = OracleRuntimeMessageRecorder()
        let fixture = try await makeFixture(sendPromptOverride: { message, model in
            await recorder.record(
                modelRaw: model.rawValue,
                prompt: message.conversationMessages.last?.content,
                fileBlocks: message.fileBlocks
            )
            return (UUID(), completedOracleStream("\(model.rawValue) response"))
        })
        defer { fixture.cleanup() }
        let primaryModel = AIModel.customProvider(name: "Primary", provider: "custom", model: "oracle-primary")
        let additionalModels = (2 ... 5).map { ordinal in
            AIModel.customProvider(
                name: "Oracle \(ordinal)",
                provider: "custom",
                model: "oracle-\(ordinal)"
            )
        }
        let settings = GlobalSettingsStore.shared
        let priorAdditionalModels = settings.additionalOracleModelRaws()
        settings.setAdditionalOracleModelRaws(additionalModels.map(\.rawValue), commit: false)
        defer { settings.setAdditionalOracleModelRaws(priorAdditionalModels, commit: false) }
        installFollowUpModel(primaryModel, in: fixture)
        defer { fixture.composition.contextBuilderAgentViewModel.installRunTestHooks(nil) }

        let prompt = "Plan with five independent Oracles."
        let result = try await fixture.composition.contextBuilderAgentViewModel.runMCPPlanOrQuestion(
            for: fixture.tabID,
            oracleViewModel: fixture.oracleViewModel,
            mode: .plan,
            prompt: prompt,
            selection: StoredSelection(),
            reviewGitContext: .automaticOnly()
        )

        guard case let .paired(group) = result.payload else {
            return XCTFail("Expected grouped Oracle result")
        }
        XCTAssertEqual(group.status, .completed)
        XCTAssertEqual(group.oracleCount, 5)
        XCTAssertEqual(group.orderedLanes, OracleLane.allCases)
        let stubs = try await fixture.oracleViewModel.chatData.oraclePairSessionStubs(
            for: fixture.workspace,
            pairID: group.groupID
        )
        XCTAssertEqual(stubs.compactMap(\.oracleLane), OracleLane.allCases)
        XCTAssertTrue(stubs.allSatisfy { $0.oracleGroupSize == 5 })

        let snapshots = await recorder.snapshot()
        XCTAssertEqual(snapshots.count, 5)
        XCTAssertEqual(
            Set(snapshots.map(\.modelRaw)),
            Set([primaryModel.rawValue] + additionalModels.map(\.rawValue))
        )
        XCTAssertTrue(snapshots.allSatisfy { $0.prompt?.contains(prompt) == true })
    }

    func testPairedContextBuilderRuntimePersistsPartialSecondaryFailure() async throws {
        let primaryModel = AIModel.customProvider(name: "Primary", provider: "custom", model: "oracle-primary")
        let secondaryModel = AIModel.customProvider(name: "Secondary", provider: "custom", model: "oracle-secondary")
        let fixture = try await makeFixture(sendPromptOverride: { _, model in
            if model.rawValue == secondaryModel.rawValue { throw OracleRuntimeTestError.secondaryFailed }
            return (UUID(), completedOracleStream("primary response"))
        })
        defer { fixture.cleanup() }
        let priorSecondary = GlobalSettingsStore.shared.secondaryOracleModelRaw()
        GlobalSettingsStore.shared.setSecondaryOracleModelRaw(secondaryModel.rawValue, commit: false)
        defer { GlobalSettingsStore.shared.setSecondaryOracleModelRaw(priorSecondary, commit: false) }
        installFollowUpModel(primaryModel, in: fixture)
        defer { fixture.composition.contextBuilderAgentViewModel.installRunTestHooks(nil) }

        let result = try await fixture.composition.contextBuilderAgentViewModel.runMCPPlanOrQuestion(
            for: fixture.tabID,
            oracleViewModel: fixture.oracleViewModel,
            mode: .plan,
            prompt: "Exercise partial failure.",
            selection: StoredSelection(),
            reviewGitContext: .automaticOnly()
        )

        guard case let .paired(pair) = result.payload else { return XCTFail("Expected paired Oracle result") }
        XCTAssertEqual(pair.status, .partialFailure)
        guard case .success = pair.result.primary, case .failure = pair.result.secondary else {
            return XCTFail("Expected Primary success and Secondary failure")
        }
        let persisted = try await fixture.oracleViewModel.chatData.oraclePairSessionStubs(
            for: fixture.workspace,
            pairID: pair.pairID
        )
        XCTAssertEqual(persisted.count, 2)
    }

    func testPairedContextBuilderRuntimeCancellationFinalizesAndPersistsBothLanes() async throws {
        let gate = OracleRuntimeStreamGate()
        let fixture = try await makeFixture(sendPromptOverride: { _, _ in
            await (UUID(), gate.makeStream())
        })
        defer { fixture.cleanup() }
        let primaryModel = AIModel.customProvider(name: "Primary", provider: "custom", model: "oracle-primary")
        let secondaryModel = AIModel.customProvider(name: "Secondary", provider: "custom", model: "oracle-secondary")
        let priorSecondary = GlobalSettingsStore.shared.secondaryOracleModelRaw()
        GlobalSettingsStore.shared.setSecondaryOracleModelRaw(secondaryModel.rawValue, commit: false)
        defer { GlobalSettingsStore.shared.setSecondaryOracleModelRaw(priorSecondary, commit: false) }
        installFollowUpModel(primaryModel, in: fixture)
        defer { fixture.composition.contextBuilderAgentViewModel.installRunTestHooks(nil) }

        let operation = Task { @MainActor in
            try await fixture.composition.contextBuilderAgentViewModel.runMCPPlanOrQuestion(
                for: fixture.tabID,
                oracleViewModel: fixture.oracleViewModel,
                mode: .plan,
                prompt: "Cancel both lanes.",
                selection: StoredSelection(),
                reviewGitContext: .automaticOnly()
            )
        }
        await gate.waitUntilRegistered(2)
        operation.cancel()
        await gate.finishWithCancellation()
        do {
            _ = try await operation.value
            XCTFail("Expected paired runtime cancellation")
        } catch is CancellationError {}

        XCTAssertTrue(fixture.oracleViewModel.streamingSessions.isEmpty)
        let pairIDs = Set(fixture.oracleViewModel.sessions.compactMap(\.oraclePairID))
        XCTAssertEqual(pairIDs.count, 1)
        let pairID = try XCTUnwrap(pairIDs.first)
        let persisted = try await fixture.oracleViewModel.chatData.oraclePairSessionStubs(
            for: fixture.workspace,
            pairID: pairID
        )
        XCTAssertEqual(persisted.count, 2)
    }

    private func installFollowUpModel(_ model: AIModel, in fixture: Fixture) {
        fixture.composition.contextBuilderAgentViewModel.installRunTestHooks(
            ContextBuilderAgentViewModel.RunTestHooks(
                beforeProcessingProviderEvent: nil,
                providerEventDisposition: nil,
                teardownCompleted: nil,
                resolveMCPFollowUpModel: { _ in
                    (model: model, chatPresetID: nil, mcpControlInfo: nil)
                }
            )
        )
    }

    private func makeSession(
        fixture: Fixture,
        pairID: UUID,
        lane: OracleLane,
        groupSize: Int = 2,
        ownerSessionID: UUID? = nil,
        ownerRunID: UUID? = nil
    ) -> ChatSession {
        let name = switch lane {
        case .primary:
            "Primary"
        case .secondary:
            "Secondary"
        case .oracle3, .oracle4, .oracle5:
            "Oracle \(lane.ordinal)"
        }
        return ChatSession(
            workspaceID: fixture.workspace.id,
            composeTabID: fixture.tabID,
            agentModeSessionID: ownerSessionID,
            agentModeRunID: ownerRunID,
            oraclePairID: pairID,
            oracleLane: lane,
            oracleGroupSize: groupSize,
            name: name
        )
    }

    private func makeFixture(
        sendPromptOverride: AIQueriesService.SendPromptOverride? = nil
    ) async throws -> Fixture {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        defer { GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false) }
        let composition = WindowStateCompositionFactory.make(
            windowID: -937,
            deferredInitialAgentSystemWorkspaceRefresh: true,
            sharedMCPService: MCPService(),
            aiQueriesServiceFactory: { keyManager in
                AIQueriesService(keyManager: keyManager, sendPromptOverride: sendPromptOverride)
            }
        )
        await composition.workspaceManager.awaitInitialized()

        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("OraclePairPreparationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        var workspace = try XCTUnwrap(composition.workspaceManager.activeWorkspace)
        let tabID = UUID()
        workspace.customStoragePath = storageRoot
        workspace.composeTabs = [ComposeTabState(id: tabID)]
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
            storageRoot: storageRoot
        )
    }
}

private enum OracleRuntimeTestError: Error {
    case secondaryFailed
}

private struct OracleRuntimeMessageSnapshot {
    let modelRaw: String
    let prompt: String?
    let fileBlocks: [String]
}

private actor OracleRuntimeMessageRecorder {
    private var snapshots: [OracleRuntimeMessageSnapshot] = []

    func record(modelRaw: String, prompt: String?, fileBlocks: [String]) {
        snapshots.append(.init(modelRaw: modelRaw, prompt: prompt, fileBlocks: fileBlocks))
    }

    func snapshot() -> [OracleRuntimeMessageSnapshot] {
        snapshots
    }
}

private actor OracleRuntimeStreamGate {
    private var continuations: [AsyncThrowingStream<ChatStreamOutput, Error>.Continuation] = []

    func makeStream() -> AsyncThrowingStream<ChatStreamOutput, Error> {
        AsyncThrowingStream { continuation in
            continuations.append(continuation)
        }
    }

    func waitUntilRegistered(_ count: Int) async {
        while continuations.count < count {
            await Task.yield()
        }
    }

    func finishWithCancellation() {
        for continuation in continuations {
            continuation.finish(throwing: CancellationError())
        }
        continuations.removeAll()
    }
}

private func completedOracleStream(_ text: String) -> AsyncThrowingStream<ChatStreamOutput, Error> {
    AsyncThrowingStream { continuation in
        continuation.yield(ChatStreamOutput(
            text: text,
            reasoning: nil,
            tokens: ChatTokenInfo(),
            terminalOutcome: .completed
        ))
        continuation.finish()
    }
}

@MainActor
private struct Fixture {
    let composition: WindowStateComposition
    let workspace: WorkspaceModel
    let tabID: UUID
    let storageRoot: URL

    var oracleViewModel: OracleViewModel {
        composition.oracleViewModel
    }

    func cleanup() {
        oracleViewModel.sessions = []
        try? FileManager.default.removeItem(at: storageRoot)
    }
}
