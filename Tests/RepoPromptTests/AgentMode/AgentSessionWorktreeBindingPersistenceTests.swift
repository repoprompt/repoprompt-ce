@testable import RepoPrompt
import XCTest

final class AgentSessionWorktreeBindingPersistenceTests: XCTestCase {
    func testOldAgentSessionJSONDecodesWithEmptyWorktreeBindings() throws {
        let payload = """
        {
          "id": "00000000-0000-0000-0000-000000000101",
          "serializationVersion": 4,
          "name": "Legacy Session",
          "savedAt": 0,
          "items": [],
          "autoEditEnabled": true
        }
        """

        let decoded = try JSONDecoder().decode(AgentSession.self, from: Data(payload.utf8))

        XCTAssertEqual(decoded.serializationVersion, 4)
        XCTAssertTrue(decoded.worktreeBindings.isEmpty)
        XCTAssertTrue(decoded.worktreeMergeOperations.isEmpty)
    }

    func testAgentSessionRoundTripsWorktreeBindingsAsVersionSix() throws {
        let binding = makeBinding()
        let session = try AgentSession(
            id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000102")),
            name: "Bound Session",
            savedAt: Date(timeIntervalSinceReferenceDate: 10),
            autoEditEnabled: false,
            worktreeBindings: [binding]
        )

        let encoded = try JSONEncoder().encode(session)
        let encodedString = String(data: encoded, encoding: .utf8) ?? ""
        XCTAssertTrue(encodedString.contains("worktreeBindings"), encodedString)

        let decoded = try JSONDecoder().decode(AgentSession.self, from: encoded)

        XCTAssertEqual(decoded.serializationVersion, AgentSession.currentSerializationVersion)
        XCTAssertEqual(decoded.serializationVersion, 6)
        XCTAssertEqual(decoded.worktreeBindings, [binding])
    }

    @MainActor
    func testPersistedLiveSwitchBindingDrivesFutureRuntimeWorkspaceWithoutTransientRetention() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSessionLiveSwitchPersistence-\(UUID().uuidString)", isDirectory: true)
        let logicalRoot = parent.appendingPathComponent("logical", isDirectory: true)
        let switchedWorktree = parent.appendingPathComponent("switched", isDirectory: true)
        try FileManager.default.createDirectory(at: logicalRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: switchedWorktree, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let binding = AgentSessionWorktreeBinding(
            id: "bind-live-switch",
            repositoryID: "gitrepo_live",
            repoKey: "repo",
            logicalRootPath: logicalRoot.path,
            logicalRootName: "logical",
            worktreeID: "wt_live",
            worktreeRootPath: switchedWorktree.path,
            worktreeName: "switched",
            branch: "feature/live-switch",
            source: "test_live_switch"
        )
        let session = AgentSession(
            id: UUID(),
            name: "Live switched session",
            savedAt: Date(),
            autoEditEnabled: true,
            worktreeBindings: [binding]
        )

        let encoded = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(AgentSession.self, from: encoded)

        XCTAssertEqual(decoded.serializationVersion, 6)
        XCTAssertEqual(decoded.worktreeBindings, [binding])
        XCTAssertEqual(
            try AgentWorktreeRuntimeWorkspaceResolver.effectiveWorkspacePath(
                bindings: decoded.worktreeBindings,
                fallbackWorkspacePath: logicalRoot.path
            ),
            switchedWorktree.path
        )
        let hydratedTabSession = AgentModeViewModel.TabSession(tabID: UUID())
        hydratedTabSession.worktreeBindings = decoded.worktreeBindings
        XCTAssertNil(hydratedTabSession.liveWorktreeSwitchRuntimeRetention)
    }

    func testDataServiceStubAndMetadataExposeWorktreeBindingSummaries() async throws {
        let service = AgentSessionDataService.shared
        let workspace = makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: try XCTUnwrap(workspace.customStoragePath)) }
        let binding = makeBinding()
        let sessionID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000103"))
        let tabID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000104"))
        let session = AgentSession(
            id: sessionID,
            workspaceID: workspace.id,
            composeTabID: tabID,
            name: "Metadata Session",
            savedAt: Date(timeIntervalSinceReferenceDate: 20),
            itemCount: 3,
            autoEditEnabled: true,
            worktreeBindings: [binding]
        )

        let fileURL = try await service.saveAgentSession(session, for: workspace, preparation: .alreadyCanonicalTranscript, trustedCanonicalItemCount: 3)
        let stub = try await service.loadAgentSessionStub(from: fileURL)
        let metadata = try await service.listAgentSessionsMeta(for: workspace)
        let sidebar = try await service.buildSidebarIndex(
            AgentSessionSidebarBuildRequest(
                workspace: workspace,
                tabNameByID: [tabID: "Metadata Tab"],
                validTabIDs: [tabID],
                boundSessionIDByTabID: [tabID: sessionID]
            )
        )

        XCTAssertNil(stub.transcript)
        XCTAssertTrue(stub.items.isEmpty)
        XCTAssertEqual(stub.worktreeBindings, [binding])

        let summary = binding.summary
        XCTAssertEqual(metadata.first?.worktreeBindingSummaries, [summary])
        XCTAssertEqual(sidebar.entriesBySessionID[sessionID]?.worktreeBindingSummaries, [summary])
        XCTAssertEqual(sidebar.preferredSessionIDByTabID[tabID], sessionID)
    }

    func testLegacyMetadataIndexRecordsDecodeWithEmptyWorktreeBindingSummaries() throws {
        let payload = """
        {
          "schemaVersion": 1,
          "generatedAt": 0,
          "entries": [
            {
              "id": "00000000-0000-0000-0000-000000000105",
              "filename": "AgentSession-00000000-0000-0000-0000-000000000105.json",
              "name": "Indexed Legacy Session",
              "savedAt": 0,
              "itemCount": 0,
              "hasUnknownConversationContent": false,
              "autoEditEnabled": true,
              "isMCPOriginated": false,
              "lastIndexedAt": 0
            }
          ],
          "quarantinedFiles": []
        }
        """

        let decoded = try JSONDecoder().decode(AgentSessionMetadataIndex.self, from: Data(payload.utf8))

        XCTAssertEqual(decoded.entries.count, 1)
        XCTAssertEqual(decoded.entries.first?.worktreeBindingSummaries, [])
        XCTAssertEqual(decoded.entries.first?.activeWorktreeMergeSummaries, [])
        XCTAssertEqual(decoded.entries.first?.agentSessionMeta().worktreeBindingSummaries, [])
        XCTAssertEqual(decoded.entries.first?.agentSessionMeta().activeWorktreeMergeSummaries, [])
    }

    private func makeBinding() -> AgentSessionWorktreeBinding {
        AgentSessionWorktreeBinding(
            id: "bind_repo-main_wt-feature",
            repositoryID: "gitrepo_abc123",
            repoKey: "repo",
            logicalRootPath: "/Users/example/dev/repo",
            logicalRootName: "repo",
            worktreeID: "wt_feature123",
            worktreeRootPath: "/Users/example/dev/.repoprompt-worktrees/repo/rp-agent-feature",
            worktreeName: "rp-agent-feature",
            branch: "feature/worktree-bindings",
            head: "abcdef1234567890",
            visualLabel: "feature",
            visualColorHex: "#3366FF",
            boundAt: Date(timeIntervalSinceReferenceDate: 123),
            source: "test"
        )
    }

    private func makeTemporaryWorkspace() -> WorkspaceModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSessionWorktreeBindingPersistenceTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return WorkspaceModel(
            name: "Worktree Binding Persistence",
            repoPaths: ["/tmp/repo"],
            customStoragePath: directory
        )
    }
}
