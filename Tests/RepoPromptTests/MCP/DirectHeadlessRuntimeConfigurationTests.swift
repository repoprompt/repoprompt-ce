import Foundation
import MCP
import RepoPromptDomainRuntime
@testable import RepoPromptMCP
import XCTest

final class DirectHeadlessRuntimeConfigurationTests: XCTestCase {
    func testDefaultProfileUsesCanonicalAppStorageAndNeverFallsBackToCWD() throws {
        let home = temporaryDirectory("home")
        let cwd = temporaryDirectory("cwd")
        let temporary = temporaryDirectory("tmp")
        let locations = try DirectHeadlessRuntimeLocationResolver.resolve(
            environment: [:],
            currentDirectory: cwd,
            homeDirectory: home,
            temporaryDirectory: temporary,
            customWorkspaceStoragePath: nil
        )

        let canonicalRoot = home.appendingPathComponent(
            "Library/Application Support/RepoPrompt CE",
            isDirectory: true
        )
        XCTAssertEqual(locations.profileIdentifier, "default")
        XCTAssertEqual(locations.storageDirectory, canonicalRoot)
        XCTAssertEqual(
            locations.workspaceStorageDirectory,
            canonicalRoot.appendingPathComponent("Workspaces", isDirectory: true)
        )
        XCTAssertEqual(locations.workingDirectories, [])
        XCTAssertFalse(locations.storageDirectory.path.contains("/Headless/"))
        XCTAssertFalse(locations.mayBootstrapIsolatedWorkspace)
    }

    func testDefaultProfileUsesCanonicalCustomWorkspaceStorage() throws {
        let home = temporaryDirectory("home")
        let custom = temporaryDirectory("custom-workspaces")
        let locations = try DirectHeadlessRuntimeLocationResolver.resolve(
            environment: [:],
            currentDirectory: home,
            homeDirectory: home,
            customWorkspaceStoragePath: custom.path
        )

        XCTAssertEqual(
            locations.workspaceStorageDirectory,
            custom.standardizedFileURL.resolvingSymlinksInPath()
        )
    }

    func testExplicitProfileDirectoryAndRootsAreIntentionalIsolation() throws {
        let profile = temporaryDirectory("profile")
        let root = temporaryDirectory("root")
        let locations = try DirectHeadlessRuntimeLocationResolver.resolve(
            environment: [
                "REPOPROMPT_MCP_HEADLESS_PROFILE": "test-profile",
                "REPOPROMPT_MCP_HEADLESS_PROFILE_DIR": profile.path,
                "REPOPROMPT_MCP_WORKING_DIRS": root.path
            ],
            currentDirectory: profile,
            homeDirectory: profile
        )

        XCTAssertEqual(locations.profileIdentifier, "test-profile")
        XCTAssertEqual(locations.storageDirectory, profile.standardizedFileURL.resolvingSymlinksInPath())
        XCTAssertEqual(locations.workingDirectories, [root.standardizedFileURL.resolvingSymlinksInPath()])
        XCTAssertTrue(locations.usesExplicitProfileDirectory)
        XCTAssertTrue(locations.mayBootstrapIsolatedWorkspace)
    }

    func testNonDefaultProfileRequiresExplicitDirectory() throws {
        XCTAssertThrowsError(try DirectHeadlessRuntimeLocationResolver.resolve(
            environment: ["REPOPROMPT_MCP_HEADLESS_PROFILE": "other"],
            currentDirectory: FileManager.default.temporaryDirectory,
            customWorkspaceStoragePath: nil
        )) { error in
            XCTAssertEqual(
                error as? DirectHeadlessRuntimeLocationError,
                .profileDirectoryRequired("other")
            )
        }
    }

    func testBindContextWorkingDirsRequireAbsoluteExistingUniqueDirectories() throws {
        let root = temporaryDirectory("bind-root")
        let target = temporaryDirectory("bind-target")
        let alias = root.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        let file = root.appendingPathComponent("not-a-directory")
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: Data()))

        let resolved = try DirectHeadlessGlobalBackend.workingDirectories(from: .array([.string(" \(alias.path) ")]))
        XCTAssertEqual(resolved, [target.standardizedFileURL.resolvingSymlinksInPath()])

        let invalidInputs: [(String, Value)] = [
            ("empty string", .string("")),
            ("empty array", .array([])),
            ("relative path", .string("relative-working-dir")),
            ("duplicate paths", .array([.string(root.path), .string(root.path)])),
            ("file path", .string(file.path))
        ]
        for (label, input) in invalidInputs {
            XCTAssertThrowsError(
                try DirectHeadlessGlobalBackend.workingDirectories(from: input),
                label
            )
        }
    }

    func testDuplicateOrEmptyExplicitRootsFailClosed() throws {
        let root = temporaryDirectory("root")
        for value in ["\(root.path):\(root.path)", ""] {
            XCTAssertThrowsError(try DirectHeadlessRuntimeLocationResolver.resolve(
                environment: ["REPOPROMPT_MCP_WORKING_DIRS": value],
                currentDirectory: root,
                homeDirectory: root,
                customWorkspaceStoragePath: nil
            ), "value=\(value)")
        }
    }

    func testBindContextWorkingDirsPrefersExactAndAuthorizesCompleteResolvedRoots() async throws {
        let root = temporaryDirectory("routing")
        let primaryRoot = root.appendingPathComponent("primary", isDirectory: true)
        let secondaryRoot = root.appendingPathComponent("secondary", isDirectory: true)
        let storageRoot = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: primaryRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondaryRoot, withIntermediateDirectories: true)
        let primaryWorkspaceID = UUID()
        let primaryContextID = UUID()
        let secondaryWorkspaceID = UUID()
        let secondaryContextID = UUID()
        let runtime = MCPDomainRuntime(configuration: .init(
            mode: .standalone,
            profileIdentifier: "headless-routing",
            storageDirectory: storageRoot,
            eventDirectory: root.appendingPathComponent("events", isDirectory: true),
            temporaryDirectory: root.appendingPathComponent("tmp", isDirectory: true),
            externalReloadInterval: nil
        ))
        try await runtime.start()
        addTeardownBlock {
            _ = await runtime.shutdown()
            try? FileManager.default.removeItem(at: root)
        }
        try await createWorkspace(
            makeWorkspaceDocument(
                workspaceID: primaryWorkspaceID,
                contextID: primaryContextID,
                roots: [primaryRoot],
                fileURL: storageRoot.appendingPathComponent("primary.json")
            ),
            in: runtime
        )
        try await createWorkspace(
            makeWorkspaceDocument(
                workspaceID: secondaryWorkspaceID,
                contextID: secondaryContextID,
                roots: [primaryRoot, secondaryRoot],
                fileURL: storageRoot.appendingPathComponent("secondary.json")
            ),
            in: runtime
        )
        let scopeID = DomainStandaloneScopeID()
        let connectionID = UUID()
        _ = try await runtime.standaloneScopeCoordinator.register(
            scopeID: scopeID,
            connectionID: connectionID,
            workingDirectories: [primaryRoot]
        )
        let context = DirectHeadlessDomainContext(runtime: runtime, scopeID: scopeID)
        let backend = DirectHeadlessGlobalBackend(runtime: runtime, scopeID: scopeID, context: context)

        _ = try await backend.routeContext(bindRequest(workingDirs: [primaryRoot]))
        let exact = try await runtime.standaloneScopeCoordinator.snapshot(scopeID: scopeID)
        XCTAssertEqual(
            exact.binding,
            .context(DomainContextIdentity(workspaceID: primaryWorkspaceID, contextID: primaryContextID), explicit: true)
        )

        _ = try await backend.routeContext(bindRequest(workingDirs: [secondaryRoot]))
        let superset = try await runtime.standaloneScopeCoordinator.snapshot(scopeID: scopeID)
        XCTAssertEqual(
            superset.binding,
            .context(DomainContextIdentity(workspaceID: secondaryWorkspaceID, contextID: secondaryContextID), explicit: true)
        )
        let authorized = try await context.snapshot(connectionID: connectionID)
        XCTAssertEqual(Set(authorized.roots.map(\.path)), Set([primaryRoot.path, secondaryRoot.path]))
    }

    func testCloseTabAllowActivePreservesUnrelatedBindingForSameConnection() async throws {
        let root = temporaryDirectory("close-tab-binding")
        let storageRoot = root.appendingPathComponent("state", isDirectory: true)
        let closedWorkspaceID = UUID()
        let closedTabID = UUID()
        let replacementTabID = UUID()
        let otherWorkspaceID = UUID()
        let otherContextID = UUID()
        let runtime = MCPDomainRuntime(configuration: .init(
            mode: .standalone,
            profileIdentifier: "headless-close-tab",
            storageDirectory: storageRoot,
            eventDirectory: root.appendingPathComponent("events", isDirectory: true),
            temporaryDirectory: root.appendingPathComponent("tmp", isDirectory: true),
            externalReloadInterval: nil
        ))
        try await runtime.start()
        addTeardownBlock {
            _ = await runtime.shutdown()
            try? FileManager.default.removeItem(at: root)
        }
        try await createWorkspace(
            makeWorkspaceDocument(
                workspaceID: closedWorkspaceID,
                contextID: closedTabID,
                additionalContextID: replacementTabID,
                roots: [root],
                fileURL: storageRoot.appendingPathComponent("closed.json")
            ),
            in: runtime
        )
        try await createWorkspace(
            makeWorkspaceDocument(
                workspaceID: otherWorkspaceID,
                contextID: otherContextID,
                roots: [root],
                fileURL: storageRoot.appendingPathComponent("other.json")
            ),
            in: runtime
        )
        let scopeID = DomainStandaloneScopeID()
        let connectionID = UUID()
        _ = try await runtime.standaloneScopeCoordinator.register(
            scopeID: scopeID,
            connectionID: connectionID,
            workingDirectories: []
        )
        let unrelatedBinding = DomainContextIdentity(
            workspaceID: otherWorkspaceID,
            contextID: otherContextID
        )
        _ = try await runtime.standaloneScopeCoordinator.bind(
            scopeID: scopeID,
            context: unrelatedBinding
        )
        let context = DirectHeadlessDomainContext(runtime: runtime, scopeID: scopeID)
        let backend = DirectHeadlessGlobalBackend(runtime: runtime, scopeID: scopeID, context: context)
        let request = try DomainPhysicalToolRequest(
            argumentsJSON: JSONEncoder().encode([
                "action": Value.string("close_tab"),
                "workspace": .string(closedWorkspaceID.uuidString),
                "tab": .string(closedTabID.uuidString),
                "allow_active": .bool(true)
            ]),
            securityContext: nil
        )

        _ = try await backend.manageWorkspaceLifecycle(request)

        let snapshot = try await runtime.standaloneScopeCoordinator.snapshot(scopeID: scopeID)
        XCTAssertEqual(snapshot.binding, .context(unrelatedBinding, explicit: true))
    }

    private func createWorkspace(
        _ document: DomainWorkspaceDocument,
        in runtime: MCPDomainRuntime
    ) async throws {
        let catalog = await runtime.workspaceStore.snapshot()
        let outcome = await runtime.workspaceStore.execute(DomainWorkspaceCommandEnvelope(
            operationID: UUID(),
            expectedCatalogRevision: catalog.catalogRevision,
            origin: .standalone,
            command: .createWorkspace(document)
        ))
        XCTAssertEqual(outcome.disposition, .applied, outcome.diagnostic ?? String(describing: outcome.disposition))
    }

    private func bindRequest(workingDirs: [URL]) throws -> DomainPhysicalToolRequest {
        try DomainPhysicalToolRequest(
            argumentsJSON: JSONEncoder().encode([
                "op": Value.string("bind"),
                "working_dirs": Value.array(workingDirs.map { .string($0.path) })
            ]),
            securityContext: nil
        )
    }

    private func makeWorkspaceDocument(
        workspaceID: UUID,
        contextID: UUID,
        additionalContextID: UUID? = nil,
        roots: [URL],
        fileURL: URL
    ) throws -> DomainWorkspaceDocument {
        let tabIDs: [UUID] = if let additionalContextID {
            [contextID, additionalContextID]
        } else {
            [contextID]
        }
        let object: [String: Any] = [
            "id": workspaceID.uuidString,
            "schemaVersion": 1,
            "name": workspaceID.uuidString,
            "repoPaths": roots.map(\.path),
            "isSystemWorkspace": false,
            "isHiddenInMenus": false,
            "activeComposeTabID": contextID.uuidString,
            "composeTabs": tabIDs.map { tabID -> [String: Any] in
                [
                    "id": tabID.uuidString,
                    "name": tabID.uuidString,
                    "prompt": "",
                    "selectedPaths": []
                ]
            }
        ]
        return try DomainWorkspaceDocument.decode(
            documentBytes: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            fileURL: fileURL
        )
    }

    private func temporaryDirectory(_ suffix: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("direct-headless-locations-\(suffix)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
