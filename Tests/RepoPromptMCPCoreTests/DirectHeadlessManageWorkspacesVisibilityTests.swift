import Foundation
import MCP
import RepoPromptDomainRuntime
@testable import RepoPromptMCPCore
import XCTest

/// Headless `manage_workspaces` hidden-workspace rules, driven through the MCP SDK.
///
/// Each test starts a real headless runtime on an isolated temporary profile, which binds its
/// bootstrapped visible workspace, and only then seeds extra workspaces that reuse that root.
/// Seeding after startup keeps the startup binding unambiguous, and reusing the root keeps root
/// validation from deciding any outcome.
final class DirectHeadlessManageWorkspacesVisibilityTests: XCTestCase {
    private static let unresolved = "workspace is unknown or ambiguous"

    func testListExcludesHiddenUnlessIncludeHiddenWhileContextInventoriesKeepThem() async throws {
        let fixture = try await makeFixture(grants: [])
        let bound = fixture.boundWorkspaceID
        let hidden = try await fixture.seedWorkspace(name: "Hidden Fixture", hidden: true)

        for arguments: [String: Value] in [["action": "list"], ["action": "list", "include_hidden": false]] {
            let listed = try await fixture.call("manage_workspaces", arguments)
            XCTAssertEqual(listed.workspaceIDs, [bound], "\(arguments)")
        }
        let included = try await fixture.call("manage_workspaces", ["action": "list", "include_hidden": true])
        XCTAssertEqual(Set(included.workspaceIDs), [bound, hidden])

        let inventories: [(String, [String: Value])] = [
            ("bind_context", ["op": "list"]),
            ("manage_workspaces", ["action": "list_tabs"])
        ]
        for (tool, arguments) in inventories {
            let inventory = try await fixture.call(tool, arguments)
            XCTAssertEqual(Set(inventory.workspaceIDs), [bound, hidden], "\(tool) \(arguments)")
        }
    }

    func testNameSwitchExcludesHiddenByDefaultPrefersVisibleAndKeepsExplicitUUID() async throws {
        let fixture = try await makeFixture(grants: ["manage_workspaces.switch"])
        let hidden = try await fixture.seedWorkspace(name: "Hidden Fixture", hidden: true)
        let shared = try await fixture.seedWorkspace(name: "Shared", hidden: false)
        _ = try await fixture.seedWorkspace(name: "Shared", hidden: true)

        for arguments: [String: Value] in [
            ["action": "switch", "workspace": "Hidden Fixture"],
            ["action": "switch", "workspace": "Hidden Fixture", "include_hidden": false]
        ] {
            let refused = try await fixture.call("manage_workspaces", arguments, expectError: true)
            XCTAssertTrue(refused.text.contains(Self.unresolved), refused.text)
            let status = try await fixture.call("bind_context", ["op": "status"])
            XCTAssertEqual(status.bindingWorkspaceID, fixture.boundWorkspaceID, "\(arguments)")
        }

        let optedIn = try await fixture.call("manage_workspaces", [
            "action": "switch", "workspace": "Hidden Fixture", "include_hidden": true
        ])
        XCTAssertEqual(optedIn.bindingWorkspaceID, hidden)
        let visible = try await fixture.call("manage_workspaces", ["action": "switch", "workspace": "shared"])
        XCTAssertEqual(visible.bindingWorkspaceID, shared)
        let explicit = try await fixture.call("manage_workspaces", [
            "action": "switch", "workspace": .string(hidden.uuidString)
        ])
        XCTAssertEqual(explicit.bindingWorkspaceID, hidden)
    }

    func testHideAndUnhideUseActionLocalNameRulesRegardlessOfIncludeHidden() async throws {
        let fixture = try await makeFixture(grants: ["manage_workspaces.hide", "manage_workspaces.unhide"])
        let hidden = try await fixture.seedWorkspace(name: "Hidden Fixture", hidden: true)
        let shared = try await fixture.seedWorkspace(name: "Shared", hidden: false)
        let sharedHidden = try await fixture.seedWorkspace(name: "Shared", hidden: true)
        let sharedBefore = await fixture.state(of: shared)
        let sharedHiddenBefore = await fixture.state(of: sharedHidden)

        // unhide matches visible and hidden names alike, so a visible and a hidden namesake are ambiguous.
        let ambiguous = try await fixture.call("manage_workspaces", [
            "action": "unhide", "workspace": "Shared"
        ], expectError: true)
        XCTAssertTrue(ambiguous.text.contains(Self.unresolved), ambiguous.text)
        let sharedAfterUnhide = await fixture.state(of: shared)
        XCTAssertEqual(sharedAfterUnhide, sharedBefore)
        let sharedHiddenAfterUnhide = await fixture.state(of: sharedHidden)
        XCTAssertEqual(sharedHiddenAfterUnhide, sharedHiddenBefore)

        // hide ignores include_hidden and prefers the visible namesake.
        _ = try await fixture.call("manage_workspaces", [
            "action": "hide", "workspace": "Shared", "include_hidden": true
        ])
        let sharedAfterHide = await fixture.state(of: shared)
        XCTAssertEqual(sharedAfterHide?.hidden, true)

        // Re-hiding an already-hidden name must succeed; `call` asserts the success.
        _ = try await fixture.call("manage_workspaces", ["action": "hide", "workspace": "Hidden Fixture"])

        _ = try await fixture.call("manage_workspaces", ["action": "unhide", "workspace": "Hidden Fixture"])
        let hiddenAfterUnhide = await fixture.state(of: hidden)
        XCTAssertEqual(hiddenAfterUnhide?.hidden, false)
    }

    func testUnhideByNameStillNeedsItsGrantAndNameDeleteStillExcludesHidden() async throws {
        let fixture = try await makeFixture(grants: ["manage_workspaces.delete"])
        let hidden = try await fixture.seedWorkspace(name: "Hidden Fixture", hidden: true)
        let before = await fixture.state(of: hidden)
        XCTAssertEqual(before?.hidden, true)

        let denied = try await fixture.call("manage_workspaces", [
            "action": "unhide", "workspace": "Hidden Fixture"
        ], expectError: true)
        XCTAssertTrue(denied.text.contains("no active grant covers this operation"), denied.text)
        let deleteRefused = try await fixture.call("manage_workspaces", [
            "action": "delete", "workspace": "Hidden Fixture"
        ], expectError: true)
        XCTAssertTrue(deleteRefused.text.contains(Self.unresolved), deleteRefused.text)

        let after = await fixture.state(of: hidden)
        XCTAssertEqual(after, before)
        let status = try await fixture.call("bind_context", ["op": "status"])
        XCTAssertEqual(status.bindingWorkspaceID, fixture.boundWorkspaceID)
    }

    // MARK: - Fixture

    private struct WireResult {
        let text: String

        private var object: [String: Any] {
            text.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
        }

        var workspaceIDs: [UUID] {
            (object["workspaces"] as? [[String: Any]] ?? []).compactMap {
                ($0["workspace_id"] as? String).flatMap(UUID.init(uuidString:))
            }
        }

        var bindingWorkspaceID: UUID? {
            ((object["binding"] as? [String: Any])?["workspace_id"] as? String).flatMap(UUID.init(uuidString:))
        }
    }

    private struct WorkspaceState: Equatable {
        let hidden: Bool
        let workingRevision: UInt64
    }

    private struct SeedFailure: Error {
        let detail: String
    }

    private struct Fixture {
        let client: Client
        let runtime: MCPDomainRuntime
        let root: URL
        let boundWorkspaceID: UUID

        func call(
            _ tool: String,
            _ arguments: [String: Value],
            expectError: Bool = false,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async throws -> WireResult {
            let result = try await client.callTool(name: tool, arguments: arguments)
            let text = result.content.compactMap { content -> String? in
                guard case let .text(value, _, _) = content else { return nil }
                return value
            }.joined(separator: "\n")
            XCTAssertEqual(result.isError == true, expectError, "\(tool) \(arguments): \(text)", file: file, line: line)
            return WireResult(text: text)
        }

        func state(of workspaceID: UUID) async -> WorkspaceState? {
            let catalog = await runtime.workspaceStore.snapshot()
            return catalog.workspaces.first { $0.document.workspaceID == workspaceID }.map {
                WorkspaceState(hidden: $0.document.metadata.isHiddenInMenus, workingRevision: $0.revisions.workingRevision)
            }
        }

        func seedWorkspace(name: String, hidden: Bool) async throws -> UUID {
            let catalog = await runtime.workspaceStore.snapshot()
            let workspaceID = UUID()
            let contextID = UUID()
            let object: [String: Any] = [
                "id": workspaceID.uuidString,
                "schemaVersion": 1,
                "name": name,
                "repoPaths": [root.path],
                "isSystemWorkspace": false,
                "isHiddenInMenus": hidden,
                "activeComposeTabID": contextID.uuidString,
                "composeTabs": [["id": contextID.uuidString, "name": "Prompt 1", "prompt": "", "selectedPaths": [String]()]]
            ]
            let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            let fileURL = runtime.configuration.workspaceStorageDirectory
                .appendingPathComponent("\(workspaceID.uuidString).json", isDirectory: false)
            let outcome = try await runtime.workspaceStore.execute(DomainWorkspaceCommandEnvelope(
                operationID: UUID(),
                expectedCatalogRevision: catalog.catalogRevision,
                origin: .standalone,
                command: .createWorkspace(DomainWorkspaceDocument.decode(documentBytes: bytes, fileURL: fileURL))
            ))
            guard outcome.disposition == .applied else {
                throw SeedFailure(detail: outcome.diagnostic ?? outcome.disposition.rawValue)
            }
            return workspaceID
        }
    }

    private func makeFixture(grants: Set<String>) async throws -> Fixture {
        let created = FileManager.default.temporaryDirectory
            .appendingPathComponent("rp-headless-workspace-visibility-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: created, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: created) }
        let directory = created.resolvingSymlinksInPath()
        let root = directory.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let service = DirectHeadlessMCPService(environment: [
            "REPOPROMPT_MCP_HEADLESS_PROFILE": "workspace-visibility",
            "REPOPROMPT_MCP_HEADLESS_PROFILE_DIR": directory.appendingPathComponent("profile").path,
            "REPOPROMPT_MCP_WORKING_DIRS": root.path,
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? ""
        ], currentDirectory: directory)
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }
        let bound = try await prepared.context.snapshot(connectionID: prepared.connectionID)

        let transports = await InMemoryTransport.createConnectedPair()
        let server = Server(name: "Headless workspace visibility test", version: "1", capabilities: .init(tools: .init()))
        await service.installHandlers(server: server, prepared: prepared, connection: .init(
            connectionID: prepared.connectionID, connectionGeneration: prepared.connectionGeneration,
            principal: prepared.principal, policyProfile: .direct, restrictedToolNames: [],
            additionalToolNames: [],
            ephemeralGrantedOperations: DirectHeadlessMCPService.topLevelDefaultMutationOperations.union(grants)
        ))
        try await server.start(transport: transports.server)
        addTeardownBlock { await server.stop() }
        let client = Client(name: "Headless workspace visibility client", version: "1")
        _ = try await client.connect(transport: transports.client)
        addTeardownBlock { await client.disconnect() }
        return Fixture(client: client, runtime: prepared.runtime, root: root, boundWorkspaceID: bound.identity.workspaceID)
    }
}
