import Foundation
import MCP
import RepoPromptDomainRuntime
@testable import RepoPromptMCPCore
import XCTest

/// Root-based headless binding (#1518): the startup binding and `bind_context bind` by `working_dirs`.
/// Each test runs a real `DirectHeadlessMCPService` runtime, drives `tools/call` through the installed MCP SDK
/// over an in-memory transport, and restarts on the same isolated temporary profile. No provider, app or stdio.
final class DirectHeadlessWorkingDirectoryBindingTests: XCTestCase {
    func testRestartWithRetiredDuplicateBindsCanonicalAndPreservesDuplicate() async throws {
        try await assertRestartBindsCanonical(seedingRetiredDuplicate: true)
    }

    /// Matched control: the same profile shape and restart without the retired duplicate.
    func testRestartWithoutRetiredDuplicateBindsCanonical() async throws {
        try await assertRestartBindsCanonical(seedingRetiredDuplicate: false)
    }

    /// A same-root duplicate that is not retired into the canonical keeps the root set ambiguous at both seams,
    /// so neither seam picks a workspace.
    func testSameRootDuplicatesNotRetiredIntoCanonicalStayAmbiguous() async throws {
        let cases: [(label: String, duplicates: [Duplicate])] = [
            ("visible", [Duplicate()]),
            ("hidden, not retired", [Duplicate(hidden: true)]),
            ("retired into a workspace outside the root set", [Duplicate(hidden: true, retirement: .intoAbsentWorkspace)]),
            (
                "retired into the canonical beside a visible duplicate without one resolvable context",
                [Duplicate(hidden: true, retirement: .intoCanonical), Duplicate(contexts: 2)]
            )
        ]
        for (label, duplicates) in cases {
            let profile = try makeProfile()
            try await withSession(profile) { session in
                let canonical = try await Self.status(session)
                XCTAssertEqual(canonical.kind, "context", label)
                for duplicate in duplicates {
                    _ = try await Self.seed(duplicate, session, profile: profile, canonicalID: canonical.workspaceUUID)
                }

                let refused = await Self.bindWorkingDirectories(session, profile: profile)
                XCTAssertTrue(refused.isError, "\(label): \(refused.text)")
                XCTAssertTrue(
                    refused.text.contains("working_dirs did not resolve one existing workspace"),
                    "\(label): \(refused.text)"
                )
                let unchanged = try await Self.status(session)
                XCTAssertEqual(unchanged, canonical, label)
            }
            try await withSession(profile) { session in
                let restarted = try await Self.status(session)
                XCTAssertEqual(restarted, .unbound, label)
            }
        }
    }

    /// Published variants survive the installed SDK boundary and describe the existing parser, not new inputs.
    func testPublishedWorkspaceContractMatchesHeadlessCalls() async throws {
        let profile = try makeProfile()
        try await withSession(profile, extraOperations: [
            "manage_workspaces.create", "manage_workspaces.select_tab", "manage_workspaces.create_tab",
            "manage_workspaces.close_tab", "manage_workspaces.delete"
        ]) { session in
            let tools = try await session.client.listTools().tools
            let bind = try XCTUnwrap(tools.first { $0.name == "bind_context" })
            let properties = try XCTUnwrap(bind.inputSchema.objectValue?["properties"]?.objectValue)
            let forms = try XCTUnwrap(properties["working_dirs"]?.objectValue?["anyOf"]?.arrayValue)
            XCTAssertEqual(forms.map { $0.objectValue?["type"] }, [.string("array"), .string("string")])
            XCTAssertTrue(properties["window_id"]?.objectValue?["description"]?.stringValue?.contains("headless rejects") == true)
            let manage = try XCTUnwrap(tools.first { $0.name == "manage_workspaces" })
            XCTAssertEqual(manage.inputSchema.objectValue?["required"], .array([.string("action")]))
            XCTAssertTrue(manage.description?.contains("Required for select_tab and close_tab") == true)
            XCTAssertTrue(manage.description?.contains("headless: workspace_id, name, repo_paths, hidden, contexts, without window IDs") == true)
            XCTAssertTrue(manage.description?.contains("UUID exactly as listed or unambiguous name for close_tab") == true)
            // #1517 remains a separate unresolved promise; this change must not silently remove it.
            XCTAssertTrue(manage.description?.contains("or any tab with a live bound run") == true)

            let original = try await Self.status(session)
            for roots in [Value.string(profile.root.path), .array([.string(profile.root.path)])] {
                let bound = await Self.callTool(session.client, "bind_context", [
                    "op": .string("bind"), "working_dirs": roots,
                    "create_if_missing": .bool(true), "tab_name": .string("Ignored name")
                ])
                XCTAssertEqual(bound.binding, original.explicitly, bound.text)
            }
            let before = await session.prepared.runtime.workspaceStore.snapshot()
            let missing = await Self.callTool(session.client, "bind_context", [
                "op": .string("bind"), "working_dirs": .array([.string(profile.base.path)]),
                "create_if_missing": .bool(true)
            ])
            XCTAssertTrue(missing.isError, missing.text)
            let after = await session.prepared.runtime.workspaceStore.snapshot()
            XCTAssertEqual(after.workspaces.count, before.workspaces.count)
            XCTAssertEqual(after.workspaces.map(\.document.metadata.name), before.workspaces.map(\.document.metadata.name))

            let commaRoot = profile.root.appendingPathComponent("comma,root", isDirectory: true)
            try FileManager.default.createDirectory(at: commaRoot, withIntermediateDirectories: true)
            let created = await Self.callTool(session.client, "manage_workspaces", [
                "action": .string("create"), "name": .string("Comma roots"),
                "folder_path": .string(commaRoot.path), "switch_to_created": .bool(true),
                "open_in_new_window": .bool(false)
            ])
            XCTAssertFalse(created.isError, created.text)
            let commaBinding = try XCTUnwrap(created.binding)
            let commaBound = await Self.callTool(session.client, "bind_context", [
                "op": .string("bind"), "working_dirs": .array([.string(commaRoot.path)])
            ])
            XCTAssertEqual(commaBound.binding, commaBinding, commaBound.text)

            let windowRefused = try await Self.callTool(session.client, "bind_context", [
                "op": .string("bind"), "context_id": .string(XCTUnwrap(commaBinding.contextID)),
                "window_id": .int(1)
            ])
            XCTAssertTrue(windowRefused.isError, windowRefused.text)
            XCTAssertTrue(windowRefused.text.contains("window_id is unavailable"), windowRefused.text)
            for flag in ["window_id": Value.int(1), "open_in_new_window": .bool(true)] {
                let refused = await Self.callTool(session.client, "manage_workspaces", [
                    "action": .string("list"), flag.key: flag.value
                ])
                XCTAssertTrue(refused.isError, refused.text)
                XCTAssertTrue(refused.text.contains("unavailable with --backend headless"), refused.text)
            }
            let named = await Self.callTool(session.client, "manage_workspaces", [
                "action": .string("select_tab"), "tab": .string("Prompt 1")
            ])
            XCTAssertTrue(named.isError, named.text)
            XCTAssertTrue(named.text.contains("canonical tab UUID"), named.text)
            let selected = try await Self.callTool(session.client, "manage_workspaces", [
                "action": .string("select_tab"), "tab": .string(XCTUnwrap(commaBinding.contextID)),
                "focus": .bool(true)
            ])
            XCTAssertEqual(selected.binding, commaBinding, selected.text)
            let newTab = await Self.callTool(session.client, "manage_workspaces", [
                "action": .string("create_tab"), "name": .string("Second"), "focus": .bool(true)
            ])
            XCTAssertFalse(newTab.isError, newTab.text)
            let beforeClose = try await Self.workspace(XCTUnwrap(commaBinding.workspaceUUID), in: session)
            XCTAssertEqual(beforeClose.contexts.count, 2)
            let active = try await Self.status(session)
            XCTAssertEqual(beforeClose.document.metadata.activeContextID?.uuidString, active.contextID)
            let omitted = await Self.callTool(session.client, "manage_workspaces", ["action": .string("close_tab")])
            XCTAssertTrue(omitted.isError, omitted.text)
            XCTAssertTrue(omitted.text.contains("requires an existing tab"), omitted.text)
            let unchanged = try await Self.workspace(XCTUnwrap(commaBinding.workspaceUUID), in: session)
            XCTAssertEqual(unchanged.contexts.map(\.metadata.identity), beforeClose.contexts.map(\.metadata.identity))
            let deleted = try await Self.callTool(session.client, "manage_workspaces", [
                "action": .string("delete"), "workspace": .string(XCTUnwrap(commaBinding.workspaceID)),
                "close_window": .bool(true)
            ])
            XCTAssertFalse(deleted.isError, deleted.text)
            let remaining = await session.prepared.runtime.workspaceStore.snapshot()
            XCTAssertFalse(remaining.workspaces.contains { $0.document.workspaceID == commaBinding.workspaceUUID })
        }
    }

    func testWorkspaceMetadataDoesNotGrantCloseAuthority() async throws {
        let profile = try makeProfile()
        try await withSession(profile) { session in
            let before = try await Self.status(session)
            let refused = try await Self.callTool(session.client, "manage_workspaces", [
                "action": .string("close_tab"), "tab": .string(XCTUnwrap(before.contextID)),
                "allow_active": .bool(true)
            ])
            XCTAssertTrue(refused.isError, refused.text)
            XCTAssertTrue(refused.text.contains("Protected mutation denied because no active grant covers this operation."), refused.text)
            let after = try await Self.status(session)
            XCTAssertEqual(after, before)
        }
    }

    // MARK: - Scenario

    private func assertRestartBindsCanonical(
        seedingRetiredDuplicate: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let profile = try makeProfile()
        let (canonical, retired) = try await withSession(profile) { session -> (WireBinding, (id: UUID, file: URL, bytes: Data)?) in
            let bootstrapped = try await Self.status(session)
            XCTAssertEqual(bootstrapped.kind, "context", file: file, line: line)
            XCTAssertEqual(bootstrapped.explicit, false, file: file, line: line)
            var retired: (id: UUID, file: URL, bytes: Data)?
            if seedingRetiredDuplicate {
                // Direct fixture seeding of the record shape duplicate-workspace cleanup (#915) persists when it
                // retires a duplicate (`WorkspaceManagerViewModel.persistDuplicateWorkspaceRetirement`): the same
                // root set, hidden, and consolidated into the canonical workspace. The app cleanup path is not run.
                let id = try await Self.seed(
                    Duplicate(hidden: true, retirement: .intoCanonical),
                    session,
                    profile: profile,
                    canonicalID: bootstrapped.workspaceUUID
                )
                let fileURL = try await Self.workspace(id, in: session).document.fileURL
                retired = try (id, fileURL, Data(contentsOf: fileURL))
            }
            let bound = await Self.bindWorkingDirectories(session, profile: profile)
            XCTAssertEqual(bound.binding, bootstrapped.explicitly, bound.text, file: file, line: line)
            return (bootstrapped, retired)
        }

        try await withSession(profile) { session in
            let restarted = try await Self.status(session)
            XCTAssertEqual(restarted, canonical, "startup binding after restart", file: file, line: line)
            let bound = await Self.bindWorkingDirectories(session, profile: profile)
            XCTAssertEqual(bound.binding, canonical.explicitly, bound.text, file: file, line: line)

            guard let retired else { return }
            let after = try await Self.workspace(retired.id, in: session)
            XCTAssertTrue(after.document.metadata.isHiddenInMenus, file: file, line: line)
            XCTAssertEqual(after.document.metadata.consolidatedIntoWorkspaceID, canonical.workspaceUUID, file: file, line: line)
            XCTAssertEqual(after.document.metadata.repoPaths, [profile.root.path], file: file, line: line)
            XCTAssertEqual(after.contexts.map(\.metadata.name), ["Duplicate Tab 1"], file: file, line: line)
        }
        if let retired {
            let persisted = try Data(contentsOf: retired.file)
            XCTAssertEqual(persisted, retired.bytes, "retired duplicate document on disk since seeding", file: file, line: line)
        }
    }

    // MARK: - Fixture

    private struct Profile {
        let base: URL
        let root: URL
        let environment: [String: String]
    }

    private struct Session {
        let service: DirectHeadlessMCPService
        let prepared: DirectHeadlessMCPService.PreparedRuntime
        let server: Server
        let client: Client
    }

    private struct Duplicate {
        enum Retirement {
            case none, intoCanonical, intoAbsentWorkspace
        }

        var hidden = false
        var retirement = Retirement.none
        /// More than one context and no active one: the workspace has no single resolvable context.
        var contexts = 1
    }

    private struct WireBinding: Equatable {
        let kind: String
        let workspaceID: String?
        let contextID: String?
        let explicit: Bool?

        static let unbound = WireBinding(kind: "unbound", workspaceID: nil, contextID: nil, explicit: nil)

        var workspaceUUID: UUID? {
            workspaceID.flatMap(UUID.init(uuidString:))
        }

        var explicitly: WireBinding {
            WireBinding(kind: kind, workspaceID: workspaceID, contextID: contextID, explicit: true)
        }
    }

    private func makeProfile() throws -> Profile {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("rp-headless-working-dirs-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        let root = base.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        return Profile(base: base, root: root, environment: [
            "REPOPROMPT_MCP_HEADLESS_PROFILE": "working-dirs-binding",
            "REPOPROMPT_MCP_HEADLESS_PROFILE_DIR": base.appendingPathComponent("profile").path,
            "REPOPROMPT_MCP_WORKING_DIRS": root.path,
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? ""
        ])
    }

    /// One headless process lifetime: always torn down before returning, so the next call is a real restart.
    private func withSession<T>(_ profile: Profile, extraOperations: Set<String> = [], _ body: (Session) async throws -> T) async throws -> T {
        let service = DirectHeadlessMCPService(environment: profile.environment, currentDirectory: profile.base)
        let prepared = try await service.prepareRuntime()
        let transports = await InMemoryTransport.createConnectedPair()
        let server = Server(name: "Headless working-dirs test", version: "1", capabilities: .init(tools: .init()))
        await service.installHandlers(server: server, prepared: prepared, connection: .init(
            connectionID: prepared.connectionID, connectionGeneration: prepared.connectionGeneration,
            principal: prepared.principal, policyProfile: .direct, restrictedToolNames: [],
            additionalToolNames: [],
            ephemeralGrantedOperations: DirectHeadlessMCPService.topLevelDefaultMutationOperations
                .union(["bind_context.bind"]).union(extraOperations)
        ))
        let client = Client(name: "Headless working-dirs client", version: "1")
        let session = Session(service: service, prepared: prepared, server: server, client: client)
        do {
            try await server.start(transport: transports.server)
            _ = try await client.connect(transport: transports.client)
            let value = try await body(session)
            await Self.stop(session)
            return value
        } catch {
            await Self.stop(session)
            throw error
        }
    }

    private static func stop(_ session: Session) async {
        await session.client.disconnect()
        await session.server.stop()
        await session.service.teardown(session.prepared)
    }

    private static func seed(
        _ duplicate: Duplicate,
        _ session: Session,
        profile: Profile,
        canonicalID: UUID?
    ) async throws -> UUID {
        let runtime = session.prepared.runtime
        let catalog = await runtime.workspaceStore.snapshot()
        let workspaceID = UUID()
        let contextIDs = (0 ..< duplicate.contexts).map { _ in UUID() }
        var object: [String: Any] = [
            "id": workspaceID.uuidString,
            "schemaVersion": 1,
            "name": "Same Root Duplicate",
            "repoPaths": [profile.root.path],
            "isHiddenInMenus": duplicate.hidden,
            "composeTabs": contextIDs.enumerated().map { index, contextID -> [String: Any] in
                ["id": contextID.uuidString, "name": "Duplicate Tab \(index + 1)", "prompt": "", "selectedPaths": [String]()]
            }
        ]
        if contextIDs.count == 1 {
            object["activeComposeTabID"] = contextIDs[0].uuidString
        }
        switch duplicate.retirement {
        case .none:
            break
        case .intoCanonical:
            object["consolidatedIntoWorkspaceID"] = try XCTUnwrap(canonicalID).uuidString
        case .intoAbsentWorkspace:
            object["consolidatedIntoWorkspaceID"] = UUID().uuidString
        }
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let document = try DomainWorkspaceDocument.decode(
            documentBytes: bytes,
            fileURL: runtime.configuration.workspaceStorageDirectory
                .appendingPathComponent("\(workspaceID.uuidString).json", isDirectory: false)
        )
        let outcome = await runtime.workspaceStore.execute(DomainWorkspaceCommandEnvelope(
            operationID: UUID(),
            expectedCatalogRevision: catalog.catalogRevision,
            origin: .standalone,
            command: .createWorkspace(document)
        ))
        XCTAssertEqual(outcome.disposition, .applied, "fixture: same-root workspace seeded")
        return workspaceID
    }

    private static func workspace(_ workspaceID: UUID, in session: Session) async throws -> DomainWorkspaceSnapshot {
        let catalog = await session.prepared.runtime.workspaceStore.snapshot()
        return try XCTUnwrap(catalog.workspaces.first { $0.document.workspaceID == workspaceID })
    }

    // MARK: - Wire

    private static func status(_ session: Session) async throws -> WireBinding {
        let result = await callTool(session.client, "bind_context", ["op": .string("status")])
        XCTAssertFalse(result.isError, result.text)
        return try XCTUnwrap(result.binding, result.text)
    }

    private static func bindWorkingDirectories(
        _ session: Session,
        profile: Profile
    ) async -> (isError: Bool, text: String, binding: WireBinding?) {
        await callTool(session.client, "bind_context", [
            "op": .string("bind"),
            "working_dirs": .array([.string(profile.root.path)])
        ])
    }

    /// Normalizes both wire shapes: an `isError` tool result and a thrown JSON-RPC error.
    private static func callTool(
        _ client: Client,
        _ name: String,
        _ arguments: [String: Value]
    ) async -> (isError: Bool, text: String, binding: WireBinding?) {
        let isError: Bool
        let text: String
        do {
            let result = try await client.callTool(name: name, arguments: arguments)
            text = result.content.compactMap { content -> String? in
                guard case let .text(value, _, _) = content else { return nil }
                return value
            }.joined(separator: "\n")
            isError = result.isError == true
        } catch {
            return (true, String(describing: error), nil)
        }
        guard !isError,
              let data = text.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let binding = object["binding"] as? [String: Any],
              let kind = binding["kind"] as? String
        else {
            return (isError, text, nil)
        }
        return (isError, text, WireBinding(
            kind: kind,
            workspaceID: binding["workspace_id"] as? String,
            contextID: binding["context_id"] as? String,
            explicit: binding["explicit"] as? Bool
        ))
    }
}
