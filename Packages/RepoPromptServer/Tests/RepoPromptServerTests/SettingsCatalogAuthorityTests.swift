import Foundation
import Hummingbird
import HummingbirdTesting
import RepoPromptHeadlessRuntime
@testable import RepoPromptServiceHTTP
@testable import RepoPromptServicePersistence
import RepoPromptServiceProtocol
import RepoPromptWorkspaceRuntimeCore
import XCTest

@testable import RepoPromptServerHost
@testable import RepoPromptServerExecutable
@testable import RepoPromptHeadlessRuntime
final class SettingsCatalogAuthorityTests: XCTestCase {
    func testNamedSelectionPresetCRUDReorderCaptureAndApplyUseSelectionFences() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "a".write(to: root.appendingPathComponent("A.swift"), atomically: true, encoding: .utf8)
        try "b".write(to: root.appendingPathComponent("B.swift"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let settings = ServerSettingsService(
            store: store,
            providerCatalog: Item3ProviderCatalog(),
            projectCatalog: store
        )
        let authority = RepoPromptHeadlessAuthority(store: store, serverSettings: settings)
        try await authority.recover()
        let actor = Self.actor
        let project = try await authority.createProject(
            input: .init(name: "Presets", roots: [.init(logicalName: "source", path: root.path, writable: true)]),
            externalActor: actor,
            idempotencyKey: "preset-project",
            requestDigest: "preset-project"
        )
        let rootID = try XCTUnwrap(project.roots.first?.rootID)
        let session = try await authority.createSession(
            input: .init(projectID: project.projectID, provider: .codex, visibility: .privateSession),
            externalActor: actor,
            idempotencyKey: "preset-session",
            requestDigest: "preset-session"
        )
        let firstEntry = LogicalSelectionEntry(rootID: rootID, logicalPath: "A.swift", mode: .full)
        let secondEntry = LogicalSelectionEntry(rootID: rootID, logicalPath: "B.swift", mode: .full)
        let selected = try await authority.replaceSelection(
            sessionID: session.sessionID,
            entries: [firstEntry],
            expectedRevision: 1,
            actor: actor
        )

        let captured = try await authority.captureProjectSelectionPreset(
            projectID: project.projectID,
            request: .init(
                expectedCollectionRevision: 0,
                sessionID: session.sessionID,
                expectedSelectionRevision: selected.revision,
                name: "Captured"
            ),
            attribution: Self.attribution
        )
        XCTAssertEqual(captured.revision, 1)
        XCTAssertEqual(captured.presets.first?.entries, [firstEntry])
        let capturedID = try XCTUnwrap(captured.presets.first?.presetID)

        do {
            _ = try await authority.createProjectSelectionPreset(
                projectID: project.projectID,
                request: .init(expectedCollectionRevision: 0, name: "Stale", entries: [secondEntry]),
                attribution: Self.attribution
            )
            XCTFail("expected stale preset collection fence")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .staleRevision)
            XCTAssertEqual(error.currentRevision, captured.revision)
        }

        let created = try await authority.createProjectSelectionPreset(
            projectID: project.projectID,
            request: .init(expectedCollectionRevision: 1, name: "Second", entries: [secondEntry]),
            attribution: Self.attribution
        )
        let secondID = try XCTUnwrap(created.presets.last?.presetID)
        let reordered = try await authority.reorderProjectSelectionPresets(
            projectID: project.projectID,
            request: .init(expectedCollectionRevision: 2, orderedPresetIDs: [secondID, capturedID]),
            attribution: Self.attribution
        )
        XCTAssertEqual(reordered.presets.map(\.presetID), [secondID, capturedID])
        XCTAssertEqual(reordered.presets.map(\.order), [0, 1])

        let capturedAfterReorder = try XCTUnwrap(reordered.presets.first { $0.presetID == capturedID })
        let renamed = try await authority.updateProjectSelectionPreset(
            projectID: project.projectID,
            presetID: capturedID,
            request: .init(
                expectedCollectionRevision: reordered.revision,
                expectedRowRevision: capturedAfterReorder.rowRevision,
                name: "Renamed",
                entries: capturedAfterReorder.entries
            ),
            attribution: Self.attribution
        )
        XCTAssertEqual(renamed.presets.first { $0.presetID == capturedID }?.name, "Renamed")

        let applied = try await authority.applyProjectSelectionPreset(
            projectID: project.projectID,
            request: .init(
                presetID: secondID,
                expectedCollectionRevision: renamed.revision,
                sessionID: session.sessionID,
                expectedSelectionRevision: selected.revision
            ),
            actor: actor
        )
        XCTAssertEqual(applied.entries, [secondEntry])
        XCTAssertEqual(applied.revision, selected.revision + 1)

        do {
            _ = try await authority.applyProjectSelectionPreset(
                projectID: project.projectID,
                request: .init(
                    presetID: secondID,
                    expectedCollectionRevision: renamed.revision,
                    sessionID: session.sessionID,
                    expectedSelectionRevision: selected.revision
                ),
                actor: actor
            )
            XCTFail("expected stale session-selection fence")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .staleRevision)
            XCTAssertEqual(error.currentRevision, applied.revision)
        }

        let second = try XCTUnwrap(renamed.presets.first { $0.presetID == secondID })
        let deleted = try await authority.deleteProjectSelectionPreset(
            projectID: project.projectID,
            presetID: secondID,
            request: .init(expectedCollectionRevision: renamed.revision, expectedRowRevision: second.rowRevision),
            attribution: Self.attribution
        )
        XCTAssertEqual(deleted.presets.map(\.presetID), [capturedID])

        do {
            _ = try await authority.createProjectSelectionPreset(
                projectID: project.projectID,
                request: .init(
                    expectedCollectionRevision: deleted.revision,
                    name: "Escaped",
                    entries: [.init(rootID: UUID(), logicalPath: "outside", mode: .full)]
                ),
                attribution: Self.attribution
            )
            XCTFail("expected project root confinement")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .rootUnauthorized)
        }

        let otherProject = try await authority.createProject(
            input: .init(name: "Other", roots: [.init(logicalName: "source", path: root.path, writable: false)]),
            externalActor: actor,
            idempotencyKey: "other-project",
            requestDigest: "other-project"
        )
        do {
            _ = try await authority.captureProjectSelectionPreset(
                projectID: otherProject.projectID,
                request: .init(
                    expectedCollectionRevision: 0,
                    sessionID: session.sessionID,
                    expectedSelectionRevision: applied.revision,
                    name: "Cross project"
                ),
                attribution: Self.attribution
            )
            XCTFail("expected cross-project rejection")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .authorizationDecisionRejected)
        }
    }

    func testWorkflowRepositoryCRUDVisibilityCloneReloadCleanupAndRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("workflows.sqlite")

        var store = try await SQLiteServiceStore.open(storage: .file(database.path))
        var authority = RepoPromptHeadlessAuthority(store: store)
        try await authority.recover()
        let initial = try await authority.workflowRepositorySnapshot()
        let builtinNames = Dictionary(
            uniqueKeysWithValues: initial.workflows
                .filter { $0.source == .builtin }
                .map { ($0.workflowID, $0.name) }
        )
        XCTAssertEqual(builtinNames, [
            "rp-build": "Plan & Build",
            "rp-review": "Review",
            "rp-refactor": "Refactor",
            "rp-investigate": "Investigate",
            "rp-oracle-export": "ChatGPT Export",
            "rp-orchestrate": "Orchestrate",
            "rp-optimize": "Optimize",
            "rp-deep-plan": "Deep Plan"
        ])
        XCTAssertFalse(builtinNames.keys.contains("rp-reminder"))
        XCTAssertFalse(builtinNames.values.contains { $0.hasPrefix("rp-") })
        XCTAssertEqual(initial.revision, 0)

        let created = try await authority.createWorkflow(
            .init(expectedRevision: 0, name: "Server Review", definition: Self.workflowMarkdown, featured: true),
            attribution: Self.attribution
        )
        let custom = try XCTUnwrap(created.workflows.first { $0.source == .custom })
        XCTAssertEqual(custom.featuredOrder, 0)
        XCTAssertEqual(custom.rowRevision, 1)

        let updated = try await authority.updateWorkflow(
            workflowID: custom.workflowID,
            request: .init(
                expectedRevision: created.revision,
                expectedRowRevision: custom.rowRevision,
                name: "Server Review Updated",
                definition: Self.workflowMarkdown,
                enabled: true,
                visible: true,
                featured: true
            ),
            attribution: Self.attribution
        )
        XCTAssertEqual(updated.workflows.first { $0.workflowID == custom.workflowID }?.rowRevision, 2)

        do {
            _ = try await authority.createWorkflow(
                .init(expectedRevision: 0, name: "Stale", definition: Self.workflowMarkdown),
                attribution: Self.attribution
            )
            XCTFail("expected stale workflow collection")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .staleRevision)
            XCTAssertEqual(error.currentRevision, updated.revision)
        }

        let builtin = try XCTUnwrap(updated.workflows.first { $0.source == .builtin })
        let cloned = try await authority.cloneWorkflow(
            workflowID: builtin.workflowID,
            request: .init(expectedRevision: updated.revision, expectedSourceRowRevision: builtin.rowRevision, name: "Built-in Clone"),
            attribution: Self.attribution
        )
        let clone = try XCTUnwrap(cloned.workflows.first { $0.name == "Built-in Clone" })
        XCTAssertEqual(clone.source, .custom)

        let hidden = try await authority.setWorkflowVisibility(
            workflowID: builtin.workflowID,
            request: .init(expectedRevision: cloned.revision, expectedRowRevision: builtin.rowRevision, visible: false),
            attribution: Self.attribution
        )
        let visibleWorkflows = try await authority.workflowSnapshots()
        XCTAssertFalse(visibleWorkflows.contains { $0.workflowID == builtin.workflowID })

        let ordered = try await authority.reorderWorkflows(
            .init(expectedRevision: hidden.revision, featuredWorkflowIDs: [clone.workflowID, custom.workflowID]),
            attribution: Self.attribution
        )
        XCTAssertEqual(
            ordered.workflows.filter { $0.featuredOrder != nil }.sorted { $0.featuredOrder! < $1.featuredOrder! }.map(\.workflowID),
            [clone.workflowID, custom.workflowID]
        )

        let cleanupOff = try await authority.updateWorkflowPreferences(
            .init(expectedRevision: ordered.revision, includeSessionCleanupGuidance: false),
            attribution: Self.attribution
        )
        XCTAssertEqual(cleanupOff.revision, ordered.revision)
        XCTAssertEqual(cleanupOff.workflows.map(\.rowRevision), ordered.workflows.map(\.rowRevision))
        let rawRuntime = try await authority.workflowSnapshot(workflowID: custom.workflowID)
        XCTAssertFalse(rawRuntime.definition.contains("### Session cleanup guidance"))
        let builtinOff = try await authority.workflowSnapshot(workflowID: "rp-review")
        XCTAssertFalse(builtinOff.definition.contains("### Session cleanup guidance"))
        let cleanupOn = try await authority.updateWorkflowPreferences(
            .init(expectedRevision: cleanupOff.revision, includeSessionCleanupGuidance: true),
            attribution: Self.attribution
        )
        XCTAssertEqual(cleanupOn.revision, ordered.revision)
        let guidedCustom = try await authority.workflowSnapshot(workflowID: custom.workflowID)
        XCTAssertFalse(guidedCustom.definition.contains("### Session cleanup guidance"))
        let guidedBuiltin = try await authority.workflowSnapshot(workflowID: "rp-review")
        XCTAssertTrue(guidedBuiltin.definition.contains("### Session cleanup guidance"))

        do {
            _ = try await authority.createWorkflow(
                .init(expectedRevision: cleanupOn.revision, name: "Path workflow", definition: Self.workflowMarkdownWithPath),
                attribution: Self.attribution
            )
            XCTFail("expected workflow path frontmatter rejection")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .invalidRequest)
        }
        do {
            _ = try await authority.createWorkflow(
                .init(
                    expectedRevision: cleanupOn.revision,
                    name: "Oversized workflow",
                    definition: String(repeating: "x", count: 256 * 1024 + 1)
                ),
                attribution: Self.attribution
            )
            XCTFail("expected workflow definition size rejection")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .invalidRequest)
        }
        do {
            _ = try await authority.deleteWorkflow(
                workflowID: builtin.workflowID,
                request: .init(expectedRevision: cleanupOn.revision, expectedRowRevision: hidden.workflows.first { $0.workflowID == builtin.workflowID }!.rowRevision),
                attribution: Self.attribution
            )
            XCTFail("expected built-in immutability")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .invalidRequest)
        }

        let cloneBeforeDelete = try XCTUnwrap(cleanupOn.workflows.first { $0.workflowID == clone.workflowID })
        let deleted = try await authority.deleteWorkflow(
            workflowID: clone.workflowID,
            request: .init(expectedRevision: cleanupOn.revision, expectedRowRevision: cloneBeforeDelete.rowRevision),
            attribution: Self.attribution
        )
        XCTAssertNil(deleted.workflows.first { $0.workflowID == clone.workflowID })
        let customBeforeCompaction = try XCTUnwrap(cleanupOn.workflows.first { $0.workflowID == custom.workflowID })
        let customAfterCompaction = try XCTUnwrap(deleted.workflows.first { $0.workflowID == custom.workflowID })
        XCTAssertEqual(customAfterCompaction.featuredOrder, 0)
        XCTAssertEqual(customAfterCompaction.rowRevision, customBeforeCompaction.rowRevision + 1)

        let reloaded = try await authority.reloadWorkflows(
            .init(expectedRevision: deleted.revision),
            attribution: Self.attribution
        )
        XCTAssertNotNil(reloaded.workflows.first { $0.workflowID == custom.workflowID })
        XCTAssertFalse(reloaded.workflows.first { $0.workflowID == builtin.workflowID }?.visible ?? true)
        let audits = try await store.settingsAuditRecords(domain: .workflowRepository, scopeID: "global")
        XCTAssertEqual(audits.filter { $0.operation != "updatePreferences" }.count, Int(reloaded.revision))
        XCTAssertEqual(audits.filter { $0.operation == "updatePreferences" }.count, 2)
        XCTAssertTrue(audits.allSatisfy { $0.payloadDigest.count == 64 })

        try await authority.quiesce()
        try await store.close(clean: true)
        store = try await SQLiteServiceStore.open(storage: .file(database.path))
        authority = RepoPromptHeadlessAuthority(store: store)
        try await authority.recover()
        let recovered = try await authority.workflowRepositorySnapshot()
        XCTAssertEqual(recovered.revision, reloaded.revision)
        XCTAssertEqual(recovered.includeSessionCleanupGuidance, true)
        XCTAssertNotNil(recovered.workflows.first { $0.workflowID == custom.workflowID })
        XCTAssertFalse(recovered.workflows.first { $0.workflowID == builtin.workflowID }?.visible ?? true)
        try await authority.quiesce()
        try await store.close(clean: true)
    }

    func testTypedSettingsDirectConfigurationWorkflowAndPresetHTTPContractsAreAuthenticatedAndRejectPathAuthorityFields() async throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder.serviceEncoder.encode(
                CreateServerWorkflowRequest(expectedRevision: 0, name: "Strict", definition: Self.workflowMarkdown)
            )) as? [String: Any]
        )
        object["path"] = "/opt/arbitrary"
        let data = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try RepoPromptHTTPService.decodeStrictWorkflowPayload(
            CreateServerWorkflowRequest.self,
            data: data,
            allowedKeys: ["expectedRevision", "name", "definition", "enabled", "visible", "featured"]
        )) { error in
            XCTAssertEqual((error as? ServiceAPIError)?.code, .invalidRequest)
        }

        let store = try await SQLiteServiceStore.open(storage: .memory)
        let authority = RepoPromptHeadlessAuthority(store: store)
        try await authority.recover()
        let service = RepoPromptHTTPService(
            authority: authority,
            store: store,
            authenticator: InternalRequestAuthenticator(keys: [], store: store),
            eventSigningKey: InternalSigningKey(keyID: "response", role: .sync, direction: "test", secret: Data("secret".utf8))
        , mutationGate: AuthorityMutationGate()
        )
        let app = Application(router: service.internalRouter())
        let projectID = UUID().uuidString
        let presetID = UUID().uuidString
        let routes: [(HTTPRequest.Method, String)] = [
            (.get, "/portal/api/v1/settings/agent-models"),
            (.patch, "/portal/api/v1/settings/agent-models"),
            (.post, "/portal/api/v1/settings/agent-models/apply-recommendations"),
            (.get, "/portal/api/v1/projects/\(projectID)/settings/agent-models"),
            (.patch, "/portal/api/v1/projects/\(projectID)/settings/agent-models"),
            (.post, "/portal/api/v1/projects/\(projectID)/settings/agent-models/copy-global"),
            (.post, "/portal/api/v1/projects/\(projectID)/settings/agent-models/copy-project"),
            (.post, "/portal/api/v1/projects/\(projectID)/settings/agent-models/apply-recommendations"),
            (.get, "/portal/api/v1/settings/subagent-permissions"),
            (.patch, "/portal/api/v1/settings/subagent-permissions"),
            (.get, "/portal/api/v1/settings/direct-agent-permissions"),
            (.patch, "/portal/api/v1/settings/direct-agent-permissions"),
            (.get, "/portal/api/v1/settings/context-builder"),
            (.patch, "/portal/api/v1/settings/context-builder"),
            (.get, "/portal/api/v1/projects/\(projectID)/settings/context-builder"),
            (.patch, "/portal/api/v1/projects/\(projectID)/settings/context-builder"),
            (.post, "/portal/api/v1/projects/\(projectID)/settings/context-builder/copy-global"),
            (.get, "/portal/api/v1/settings/model-presets"),
            (.patch, "/portal/api/v1/settings/model-presets"),
            (.get, "/portal/api/v1/settings/advanced"),
            (.patch, "/portal/api/v1/settings/advanced"),
            (.get, "/portal/api/v1/settings/workspace-approvals"),
            (.patch, "/portal/api/v1/settings/workspace-approvals"),
            (.get, "/portal/api/v1/settings/mcp-disabled-tools"),
            (.patch, "/portal/api/v1/settings/mcp-disabled-tools"),
            (.get, "/portal/api/v1/settings/show-model-presets"),
            (.patch, "/portal/api/v1/settings/show-model-presets"),
            (.get, "/portal/api/v1/provider-settings/openAIAPI/direct-configuration"),
            (.patch, "/portal/api/v1/provider-settings/openAIAPI/direct-configuration"),
            (.get, "/portal/api/v1/sessions/\(presetID)/selection"),
            (.get, "/portal/api/v1/projects/\(projectID)/selection-presets"),
            (.post, "/portal/api/v1/projects/\(projectID)/selection-presets"),
            (.patch, "/portal/api/v1/projects/\(projectID)/selection-presets/\(presetID)"),
            (.delete, "/portal/api/v1/projects/\(projectID)/selection-presets/\(presetID)"),
            (.post, "/portal/api/v1/projects/\(projectID)/selection-presets/reorder"),
            (.post, "/portal/api/v1/projects/\(projectID)/selection-presets/capture"),
            (.post, "/portal/api/v1/projects/\(projectID)/selection-presets/apply"),
            (.get, "/portal/api/v1/workflows"),
            (.post, "/portal/api/v1/workflows"),
            (.patch, "/portal/api/v1/workflows/custom-test"),
            (.delete, "/portal/api/v1/workflows/custom-test"),
            (.post, "/portal/api/v1/workflows/custom-test/clone"),
            (.patch, "/portal/api/v1/workflows/custom-test/visibility"),
            (.post, "/portal/api/v1/workflows/reorder"),
            (.patch, "/portal/api/v1/workflows/preferences"),
            (.post, "/portal/api/v1/workflows/reload")
        ]
        try await app.test(.router) { client in
            for route in routes {
                try await client.execute(uri: route.1, method: route.0, body: ByteBuffer(string: "{}")) { response in
                    XCTAssertEqual(response.status, .unauthorized, "route was not protected: \(route.1)")
                }
            }
            try await client.execute(
                uri: "/portal/api/v1/sessions/\(presetID)/context-builder",
                method: .post,
                body: ByteBuffer(string: "{}")
            ) { response in
                XCTAssertEqual(response.status, .notFound, "portal-only Context Builder execution route must remain removed")
            }
        }
        try await store.close()
    }

    func testBootstrapWorkflowProjectionCarriesRepositoryMetadataAndLegacyDefaults() throws {
        let summary = PortalWorkflowSummary(
            workflowID: "custom-one",
            name: "One",
            source: .custom,
            enabled: true,
            visible: true,
            featuredOrder: 0,
            rowRevision: 7
        )
        let response = PortalBootstrapResponse(
            projects: [],
            sessions: [],
            workflows: [summary],
            workflowRepositoryRevision: 9,
            includeSessionCleanupGuidance: false
        )
        let decoded = try JSONDecoder.serviceDecoder.decode(
            PortalBootstrapResponse.self,
            from: JSONEncoder.serviceEncoder.encode(response)
        )
        XCTAssertEqual(decoded.workflows, [summary])
        XCTAssertEqual(decoded.workflowRepositoryRevision, 9)
        XCTAssertFalse(decoded.includeSessionCleanupGuidance)

        let legacy = try JSONDecoder.serviceDecoder.decode(
            PortalBootstrapResponse.self,
            from: Data(#"{"projects":[],"sessions":[],"workflows":[]}"#.utf8)
        )
        XCTAssertEqual(legacy.workflowRepositoryRevision, 0)
        XCTAssertTrue(legacy.includeSessionCleanupGuidance)
    }

    private static let actor = ExternalActor(
        userID: "item3-test",
        username: "item3-test",
        displayName: "Item 3 Test"
    )

    private static let attribution = SettingsMutationAttribution(
        actorID: "certificate:item3-test",
        actorLabel: "Item 3 Test",
        channel: "portal-test"
    )

    func testRecoverRemovesDemotedReminderBuiltinRow() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await SQLiteServiceStore.open(storage: .file(directory.appendingPathComponent("workflows.sqlite").path))
        let authority = RepoPromptHeadlessAuthority(store: store)
        try await authority.recover()

        let leftoverDefinition = """
        ---
        name: "rp-reminder"
        description: leftover builtin row
        ---
        """
        let leftover = WorkflowSnapshot(
            workflowID: "rp-reminder",
            source: "builtin",
            name: "Reminder",
            definition: leftoverDefinition,
            contentDigest: CanonicalSigning.bodyDigest(Data(leftoverDefinition.utf8)),
            enabled: true
        )
        try await store.installWorkflows([leftover])
        try await store.bootstrapWorkflowRepository(
            builtins: try BuiltinWorkflowCatalog().workflows() + [leftover]
        )
        let leftoverSnapshot = try await authority.workflowRepositorySnapshot()
        XCTAssertTrue(leftoverSnapshot.workflows.contains { $0.workflowID == "rp-reminder" })

        try await authority.recover()
        let recovered = try await authority.workflowRepositorySnapshot()
        XCTAssertFalse(recovered.workflows.contains { $0.workflowID == "rp-reminder" })
        XCTAssertEqual(Set(recovered.workflows.filter { $0.source == .builtin }.map(\.workflowID)).count, 8)
    }

    private static let workflowMarkdown = """
    ---
    name: server-review
    description: Review selected server context
    ---

    # Server review

    Review: $ARGUMENTS
    """

    private static let workflowMarkdownWithPath = """
    ---
    name: unsafe
    description: Unsafe workflow
    path: /opt/arbitrary
    ---

    # Unsafe
    """
}

private struct Item3ProviderCatalog: ServerSettingsProviderCatalogProviding {
    func serverSettingsProviderCatalog() async throws -> ProviderSettingsCatalogResponse {
        .init(providers: [])
    }
}
