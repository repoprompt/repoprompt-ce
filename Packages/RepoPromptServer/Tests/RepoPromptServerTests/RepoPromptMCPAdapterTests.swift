import Foundation
import RepoPromptHeadlessRuntime
import RepoPromptMCPAdapter
import RepoPromptServicePersistence
import RepoPromptServiceProtocol
import RepoPromptWorkspaceRuntimeCore
import XCTest

@testable import RepoPromptServerHost
@testable import RepoPromptServerExecutable
@testable import RepoPromptHeadlessRuntime
final class RepoPromptMCPAdapterTests: XCTestCase {
    func testCanonicalCatalogDispatchesWorkspaceStateThroughDurableAuthority() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "hello adapter".write(
            to: root.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try await SQLiteServiceStore.open(storage: .memory)
        let authority = RepoPromptHeadlessAuthority(store: store)
        let actor = ExternalActor(userID: "mcp", username: "mcp", displayName: "MCP")
        let project = try await authority.createProject(
            input: .init(name: "Adapter", roots: [
                .init(logicalName: "source", path: root.path, writable: true)
            ]),
            externalActor: actor,
            idempotencyKey: "adapter-project",
            requestDigest: "adapter-project"
        )
        let session = try await authority.createSession(
            input: .init(
                projectID: project.projectID,
                provider: .codex,
                visibility: .privateSession
            ),
            externalActor: actor,
            idempotencyKey: "adapter-session",
            requestDigest: "adapter-session"
        )
        let adapter = RepoPromptMCPAdapter(serving: await RepoPromptAuthorityMCPService.admitted(authority: authority, portalSettings: PortalDesktopSettingsService(store: store), admissionGate: AuthorityMutationGate()))
        let binding = RepoPromptMCPBinding(sessionID: session.sessionID, actor: actor)

        XCTAssertEqual(RepoPromptMCPAdapter.canonicalToolNames.count, 27)
        XCTAssertEqual(Set(RepoPromptMCPAdapter.canonicalToolNames).count, 27)
        XCTAssertEqual(Set(RepoPromptMCPAdapter.canonicalToolNames), Set([
            "app_settings", "bind_context", "manage_workspaces", "manage_selection",
            "file_actions", "get_code_structure", "get_file_tree", "read_file",
            "file_search", "workspace_context", "prompt", "apply_edits", "oracle_utils",
            "ask_oracle", "oracle_send", "oracle_chat_log", "git", "manage_worktree",
            "context_builder", "ask_user", "agent_explore", "agent_run", "agent_manage",
            "history", "share_thoughts", "set_status", "wait_for_next_user_instruction"
        ]))

        _ = try await adapter.invoke(
            toolName: "manage_selection",
            argumentsJSON: json(["op": "set", "paths": ["README.md"]]),
            binding: binding
        )
        let selection = try await authority.selectionSnapshot(sessionID: session.sessionID)
        XCTAssertEqual(selection.entries.map(\.logicalPath), ["README.md"])

        let readData = try await adapter.invoke(
            toolName: "read_file",
            argumentsJSON: json(["path": "README.md"]),
            binding: binding
        )
        let read = try JSONSerialization.jsonObject(with: readData) as? [String: Any]
        XCTAssertEqual(read?["content"] as? String, "hello adapter")

        _ = try await adapter.invoke(
            toolName: "prompt",
            argumentsJSON: json(["op": "set", "text": "durable prompt"]),
            binding: binding
        )
        let context = try await authority.sessionContext(sessionID: session.sessionID)
        XCTAssertEqual(context.prompt, "durable prompt")
        XCTAssertEqual(context.contextRevision, 2)

        let historyData = try await adapter.invoke(
            toolName: "history",
            argumentsJSON: json(["op": "get_session", "session_id": session.sessionID.uuidString]),
            binding: binding
        )
        let history = try JSONDecoder.serviceDecoder.decode(SessionSnapshot.self, from: historyData)
        XCTAssertEqual(history.sessionID, session.sessionID)

        let eventTypes = try await authority.events(after: nil, limit: 20).events.map(\.eventType)
        XCTAssertTrue(eventTypes.contains(.selectionUpdated))
        XCTAssertTrue(eventTypes.contains(.contextUpdated))
        XCTAssertGreaterThanOrEqual(eventTypes.count(where: { $0 == .toolStarted }), 4)
        XCTAssertGreaterThanOrEqual(eventTypes.count(where: { $0 == .toolCompleted }), 4)

        _ = try await adapter.invoke(
            toolName: "share_thoughts",
            argumentsJSON: json(["text": "durable progress"]),
            binding: binding
        )
        _ = try await adapter.invoke(
            toolName: "set_status",
            argumentsJSON: json(["session_name": "Adapter Agent"]),
            binding: binding
        )
        let updated = try await authority.sessionSnapshot(sessionID: session.sessionID)
        XCTAssertEqual(updated.transcript.last?.kind, .progress)
        XCTAssertEqual(updated.transcript.last?.content, "durable progress")
        let agents = try await authority.agentSnapshots(rootSessionID: session.sessionID)
        let agent = try XCTUnwrap(agents.first)
        XCTAssertEqual(agent.label, "Adapter Agent")
        let finalEventTypes = try await authority.events(after: nil, limit: 100).events.map(\.eventType)
        XCTAssertTrue(finalEventTypes.contains(.transcriptProgress))
        XCTAssertTrue(finalEventTypes.contains(.agentUpdated))
        try await store.close()
    }

    func testListWorkflowsLiveReadsFeaturedOrderAndOmitsHiddenBuiltIns() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "catalog".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try await SQLiteServiceStore.open(storage: .memory)
        let authority = RepoPromptHeadlessAuthority(store: store)
        try await authority.recover()
        let initial = try await authority.workflowRepositorySnapshot()
        let featured = try await authority.reorderWorkflows(
            .init(expectedRevision: initial.revision, featuredWorkflowIDs: ["rp-review", "rp-orchestrate"]),
            attribution: .init(actorID: "certificate:mcp-workflows", actorLabel: "MCP Workflows", channel: "test")
        )

        let actor = ExternalActor(userID: "mcp-workflows", username: "mcp-workflows", displayName: "MCP Workflows")
        let project = try await authority.createProject(
            input: .init(name: "Workflows", roots: [
                .init(logicalName: "source", path: root.path, writable: true)
            ]),
            externalActor: actor,
            idempotencyKey: "workflow-project",
            requestDigest: "workflow-project"
        )
        let session = try await authority.createSession(
            input: .init(
                projectID: project.projectID,
                provider: .codex,
                visibility: .privateSession
            ),
            externalActor: actor,
            idempotencyKey: "workflow-session",
            requestDigest: "workflow-session"
        )
        let adapter = RepoPromptMCPAdapter(serving: await RepoPromptAuthorityMCPService.admitted(authority: authority, portalSettings: PortalDesktopSettingsService(store: store), admissionGate: AuthorityMutationGate()))
        let binding = RepoPromptMCPBinding(sessionID: session.sessionID, actor: actor)
        let data = try await adapter.invoke(
            toolName: "agent_manage",
            argumentsJSON: json(["op": "list_workflows"]),
            binding: binding
        )
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(payload["revision"] as? Int, Int(featured.revision))
        let workflows = try XCTUnwrap(payload["workflows"] as? [[String: Any]])
        let ids = workflows.compactMap { $0["workflowId"] as? String }
        XCTAssertFalse(ids.contains("rp-build"))
        XCTAssertFalse(ids.contains("rp-reminder"))
        XCTAssertTrue(ids.contains("rp-review"))
        XCTAssertTrue(ids.contains("rp-orchestrate"))
        let review = try XCTUnwrap(workflows.first { $0["workflowId"] as? String == "rp-review" })
        XCTAssertEqual(review["visible"] as? Bool, true)
        XCTAssertEqual(review["featuredOrder"] as? Int, 0)
        XCTAssertEqual(review["name"] as? String, "Review")
        let orchestrate = try XCTUnwrap(workflows.first { $0["workflowId"] as? String == "rp-orchestrate" })
        XCTAssertEqual(orchestrate["featuredOrder"] as? Int, 1)
        let hidden = try await authority.workflowSnapshot(workflowID: "rp-build")
        XCTAssertFalse(hidden.visible)
        XCTAssertNil(hidden.featuredOrder)
        try await store.close()
    }

    func testOracleUsesProviderNativeContinuationIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        let artifacts = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: artifacts)
        }
        let runner = NativeOracleRunner()
        let modelCatalogURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("repoprompt-oracle-test-models-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: modelCatalogURL) }
        try JSONEncoder.serviceEncoder.encode([
            ProviderModelCatalogEntry(
                id: "gpt-5.6-sol",
                displayName: "GPT-5.6 Sol",
                isProviderDefault: true
            ),
        ]).write(to: modelCatalogURL)
        let configuration = ProviderCLIConfiguration(
            kind: .codex,
            executable: "/usr/bin/true",
            expectedVersion: "1.0",
            credentialSourceDirectory: root.path
        )
        let provider = ProviderCLIAdapter(
            configurations: [configuration],
            runner: runner
        )
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let providerSettings = ProviderSettingsService(
            store: store,
            adapter: provider,
            configurations: [configuration],
            initiallyEnabled: [.codex],
            modelCatalogFiles: [.codex: modelCatalogURL.path],
            runner: runner
        )
        try await providerSettings.bootstrap()
        _ = try await providerSettings.setEnabled(
            providerID: .codex,
            enabled: true,
            request: .init(expectedRevision: 1),
            attribution: .init(actorID: "test", actorLabel: "Test", channel: "test")
        )
        let serverSettings = ServerSettingsService(
            store: store,
            providerCatalog: providerSettings,
            projectCatalog: store
        )
        let target = AgentModelTarget(providerID: .codex, modelID: "gpt-5.6-sol")
        _ = try await serverSettings.replaceGlobalAgentModels(
            .init(expectedRevision: 0, profile: .init(oracle: target)),
            attribution: .init(actorID: "test", actorLabel: "Test", channel: "test")
        )
        let authority = try RepoPromptHeadlessAuthority(
            store: store,
            artifactService: ArtifactRuntimeService(baseDirectory: artifacts.path),
            providerAdapter: provider,
            serverSettings: serverSettings,
            providerSettings: providerSettings
        )
        let actor = ExternalActor(userID: "oracle", username: "oracle", displayName: "Oracle")
        let project = try await authority.createProject(
            input: .init(name: "Oracle", roots: [.init(logicalName: "source", path: root.path, writable: true)]),
            externalActor: actor,
            idempotencyKey: "oracle-project",
            requestDigest: "oracle-project"
        )
        let session = try await authority.createSession(
            input: .init(projectID: project.projectID, provider: .codex, visibility: .privateSession),
            externalActor: actor,
            idempotencyKey: "oracle-session",
            requestDigest: "oracle-session"
        )

        let first = try await authority.askOracle(
            sessionID: session.sessionID,
            input: .init(chatID: nil, prompt: "first", contextMode: "selected"),
            actor: actor
        )
        let second = try await authority.askOracle(
            sessionID: session.sessionID,
            input: .init(chatID: first.chatID, prompt: "second", contextMode: "selected"),
            actor: actor
        )

        XCTAssertEqual(second.revision, 2)
        let calls = await runner.calls()
        XCTAssertEqual(Array(calls[1].prefix(4)), ["exec", "resume", "--json", "--skip-git-repo-check"])
        XCTAssertTrue(calls[1].contains("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"))
        let chat = try await authority.oracleChatState(sessionID: session.sessionID, chatID: first.chatID)
        XCTAssertEqual(chat.providerSessionID, "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
        try await store.close()
    }

    func testRetainedProductionAdapterRejectsToolAdvertisementBeforeClosedStoreAccess() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rp-retained-adapter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let descriptor = try AuthorityNamespaceDescriptor(
            storageRoot: directory.path,
            databasePath: directory.appendingPathComponent("state.sqlite").path,
            profile: "retained-adapter",
            servingMode: .server
        )
        let host = try await RepoPromptAuthorityHostFactory.start(
            configuration: .init(namespace: descriptor)
        )
        let store = try await host.storeForRecovery()
        let eventHub = ServiceEventHub()
        let authority = RepoPromptHeadlessAuthority(store: store, eventHub: eventHub)
        try await authority.recover()
        let metadata = try await store.metadata()
        let dispatcher = OrderedEventOutboxDispatcher(store: store, hub: eventHub)
        try await dispatcher.drainStartupWatermark(
            .init(storeID: metadata.storeID, globalSequence: metadata.nextGlobalSequence - 1)
        )
        await dispatcher.start()
        await host.installRecoveredAuthority(
            authority,
            eventHub: eventHub,
            eventOutboxDispatcher: dispatcher
        )
        let serving = try await host.makeMCPService(
            portalSettings: PortalDesktopSettingsService(store: store)
        )
        let retainedAdapter = RepoPromptMCPAdapter(serving: serving)

        let report = await host.shutdown(reason: "retained-adapter-test", deadline: .seconds(1))
        XCTAssertTrue(report.clean)
        XCTAssertTrue(report.leaseReleased)

        do {
            _ = try await retainedAdapter.advertisedToolNames(isRootSession: true)
            XCTFail("retained production adapter reached the closed authority store")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .staleCapability)
        }
    }

    private func json(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

private actor NativeOracleRunner: WorkspaceCommandRunning {
    private var recorded: [[String]] = []

    func run(
        executable _: String,
        arguments: [String],
        workingDirectory _: String,
        maximumBytes _: Int
    ) async throws -> String {
        recorded.append(arguments)
        return """
        {"type":"thread.started","thread_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"}
        {"type":"item.completed","item":{"type":"agent_message","text":"oracle response"}}
        """
    }

    func run(
        executable: String,
        arguments: [String],
        workingDirectory: String,
        maximumBytes: Int,
        launchValidation: @escaping @Sendable () throws -> Void,
        launchAcknowledgement: @escaping @Sendable () async throws -> Void
    ) async throws -> String {
        try launchValidation()
        try await launchAcknowledgement()
        return try await run(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            maximumBytes: maximumBytes
        )
    }

    func calls() -> [[String]] {
        recorded
    }
}
