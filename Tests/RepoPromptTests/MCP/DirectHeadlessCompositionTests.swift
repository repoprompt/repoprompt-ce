import Darwin
import Foundation
import MCP
import RepoPromptDomainRuntime
@testable import RepoPromptMCP
import XCTest

final class DirectHeadlessCompositionTests: XCTestCase {
    func testManageWorktreeFencesAbsoluteSelectorsToBoundWorkspaceRoots() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rp-headless-worktree-fence-\(UUID().uuidString)", isDirectory: true)
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("rp-headless-foreign-worktree-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let allowed = try DirectHeadlessVersionControlBackend.authorizeWorktreePath(root, roots: [root])
        XCTAssertEqual(allowed.path, root.standardizedFileURL.resolvingSymlinksInPath().path)
        XCTAssertThrowsError(
            try DirectHeadlessVersionControlBackend.authorizeWorktreePath(outside, roots: [root])
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("outside the bound workspace roots"), error.localizedDescription)
        }
    }

    func testHeadlessMergeMutationRejectsPreviewEndpointMovedOutsideViaSymlink() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rp-headless-merge-fence-\(UUID().uuidString)", isDirectory: true)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("rp-headless-merge-outside-\(UUID().uuidString)", isDirectory: true)
        let target = root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }

        XCTAssertThrowsError(
            try DirectHeadlessVersionControlBackend.revalidateMergeEndpointPaths(
                sourceRoot: root,
                targetRoot: target,
                roots: [root],
                listedWorktrees: [root, target]
            )
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("outside the bound workspace roots"),
                error.localizedDescription
            )
        }
    }

    func testHeadlessMergeMutationRejectsSameRepositorySameHeadWorktreeSwap() throws {
        let repositoryIdentity = "/tmp/headless-repo/.git"
        let head = String(repeating: "a", count: 40)
        let expectedWorktreeIdentity = "/tmp/headless-repo/.git/worktrees/target"
        let currentWorktreeIdentity = "/tmp/headless-repo/.git/worktrees/other"

        XCTAssertThrowsError(
            try DirectHeadlessVersionControlBackend.validateMergeEndpointIdentity(
                expectedHead: head,
                currentHead: head,
                expectedRepositoryIdentity: repositoryIdentity,
                currentRepositoryIdentity: repositoryIdentity,
                expectedWorktreeIdentity: expectedWorktreeIdentity,
                currentWorktreeIdentity: currentWorktreeIdentity
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("endpoint identity changed"), String(describing: error))
        }
    }

    func testHeadlessMergeMutationExecutionBindsValidatedGitDirectoryAfterDotGitSwap() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rp-headless-merge-execution-\(UUID().uuidString)", isDirectory: true)
        let replacementGitDirectory = root
            .appendingPathComponent("replacement-git", isDirectory: true)
        let gitEndpoint = root.appendingPathComponent(".git")
        let validatedGitDirectory = root
            .appendingPathComponent("validated-git", isDirectory: true)
            .standardizedFileURL
            .path
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: replacementGitDirectory, withIntermediateDirectories: true)
        try await DirectProcess.run("/usr/bin/git", arguments: ["init", "--bare", validatedGitDirectory])
        try FileManager.default.createSymbolicLink(at: gitEndpoint, withDestinationURL: replacementGitDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let identityArguments = DirectHeadlessVersionControlBackend.mergeMutationArguments(
            targetRoot: root,
            gitDirectory: validatedGitDirectory,
            command: ["rev-parse", "--git-dir"]
        )
        let resolvedGitDirectory = try await DirectProcess.run("/usr/bin/git", arguments: identityArguments)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(
            URL(fileURLWithPath: resolvedGitDirectory).standardizedFileURL.resolvingSymlinksInPath().path,
            validatedGitDirectory
        )

        let commands = [
            ["merge", "--no-ff", "-m", "message", String(repeating: "a", count: 40)],
            ["merge", "--continue"],
            ["merge", "--abort"]
        ]
        for command in commands {
            // Model a .git substitution after willCommit: execution must use the
            // post-check identity, not rediscover the endpoint through -C.
            let arguments = DirectHeadlessVersionControlBackend.mergeMutationArguments(
                targetRoot: root,
                gitDirectory: validatedGitDirectory,
                command: command
            )
            XCTAssertEqual(
                Array(arguments.prefix(4)),
                ["--git-dir", validatedGitDirectory, "--work-tree", root.standardizedFileURL.path]
            )
            XCTAssertFalse(arguments.contains("-C"))
            XCTAssertFalse(arguments.contains(gitEndpoint.path))
        }
    }

    func testHeadlessFileSearchHonorsAdvertisedFiltersAndPathAlias() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rp-headless-file-search-\(UUID().uuidString)", isDirectory: true)
        let profile = FileManager.default.temporaryDirectory
            .appendingPathComponent("rp-headless-file-search-profile-\(UUID().uuidString)", isDirectory: true)
        let files = [
            root.appendingPathComponent("src/keep.swift"),
            root.appendingPathComponent("src/excluded.swift"),
            root.appendingPathComponent("src/notes.txt"),
            root.appendingPathComponent("outside.swift"),
            root.appendingPathComponent("root.log"),
            root.appendingPathComponent("nested/deep.log"),
            root.appendingPathComponent("foo/*.log"),
            root.appendingPathComponent("foo/bar.log")
        ]
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("foo"), withIntermediateDirectories: true)
        for file in files {
            try "needle\n".write(to: file, atomically: true, encoding: .utf8)
        }
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: profile)
        }

        let service = DirectHeadlessMCPService(
            environment: [
                "REPOPROMPT_MCP_HEADLESS_PROFILE": "file-search-test",
                "REPOPROMPT_MCP_HEADLESS_PROFILE_DIR": profile.path,
                "REPOPROMPT_MCP_WORKING_DIRS": root.path,
                "PATH": ProcessInfo.processInfo.environment["PATH"] ?? ""
            ],
            currentDirectory: root
        )
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }

        let backend = DirectHeadlessWorkspaceBackend(context: prepared.context)
        let sideEffects = MCPDomainReadSideEffectEmitter { _, _, _, _, operation in
            try await operation()
        }
        let invocationContext = DomainReadInvocationContext(
            handle: nil,
            connectionID: prepared.connectionID
        )

        func search(_ arguments: [String: Value]) async throws -> [String: Any] {
            let request = try DomainPhysicalReadRequest(
                request: DomainPhysicalToolRequest(
                    argumentsJSON: JSONEncoder().encode(arguments),
                    securityContext: nil
                ),
                context: invocationContext,
                sideEffects: sideEffects
            )
            let result = try await backend.searchFiles(request)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: result.json) as? [String: Any])
        }

        let filtered = try await search([
            "pattern": .string("needle"),
            "mode": .string("content"),
            "regex": .bool(false),
            "filter": .object([
                "extensions": .array([.string(".swift")]),
                "paths": .array([.string("src")]),
                "exclude": .array([.string("excluded")])
            ])
        ])
        let filteredMatches = try XCTUnwrap(filtered["matches"] as? [[String: Any]])
        XCTAssertEqual(filteredMatches.compactMap { $0["path"] as? String }, ["src/keep.swift"])
        XCTAssertEqual((filtered["count"] as? NSNumber)?.intValue, 1)

        let excludedLogs = try await search([
            "pattern": .string("needle"),
            "mode": .string("content"),
            "regex": .bool(false),
            "filter": .object([
                "extensions": .array([.string(".log")]),
                "exclude": .array([.string("**/*.log")])
            ])
        ])
        XCTAssertTrue((excludedLogs["matches"] as? [[String: Any]] ?? []).isEmpty)
        XCTAssertEqual((excludedLogs["count"] as? NSNumber)?.intValue, 0)

        let slashCrossingLogs = try await search([
            "pattern": .string("needle"),
            "mode": .string("content"),
            "regex": .bool(false),
            "filter": .object([
                "extensions": .array([.string(".log")]),
                "exclude": .array([.string("*.log")])
            ])
        ])
        XCTAssertTrue((slashCrossingLogs["matches"] as? [[String: Any]] ?? []).isEmpty)

        let escapedStar = try await search([
            "pattern": .string("needle"),
            "mode": .string("content"),
            "regex": .bool(false),
            "filter": .object([
                "extensions": .array([.string(".log")]),
                "exclude": .array([.string("foo/\\*.log")])
            ])
        ])
        let escapedStarMatches = try XCTUnwrap(escapedStar["matches"] as? [[String: Any]])
        XCTAssertEqual(
            Set(escapedStarMatches.compactMap { $0["path"] as? String }),
            Set(["root.log", "nested/deep.log", "foo/bar.log"])
        )

        let pathAlias = try await search([
            "pattern": .string("*"),
            "mode": .string("path"),
            "regex": .bool(false),
            "path": .string("src/keep.swift")
        ])
        let pathMatches = try XCTUnwrap(pathAlias["matches"] as? [[String: Any]])
        XCTAssertEqual(pathMatches.compactMap { $0["path"] as? String }, ["src/keep.swift"])
    }

    func testProductionStandaloneCompositionResolvesAndDispatchesAllTwentySevenToolsWithoutAppTypes() async throws {
        let profile = FileManager.default.temporaryDirectory
            .appendingPathComponent("rp-headless-composition-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: profile) }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let service = DirectHeadlessMCPService(
            environment: [
                "REPOPROMPT_MCP_HEADLESS_PROFILE": "composition-test",
                "REPOPROMPT_MCP_HEADLESS_PROFILE_DIR": profile.path,
                "REPOPROMPT_MCP_WORKING_DIRS": root.path,
                "PATH": ProcessInfo.processInfo.environment["PATH"] ?? ""
            ],
            currentDirectory: root
        )
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }
        XCTAssertEqual(prepared.principal.kind, .runScoped)
        XCTAssertEqual(prepared.principal.assurance, .verifiedProcess)
        XCTAssertEqual(prepared.principal.runID, prepared.scopeID.rawValue)
        XCTAssertEqual(prepared.principal.processID, getppid())
        XCTAssertNotNil(prepared.principal.verifiedIdentityFingerprint)
        let snapshot = try await prepared.context.snapshot(connectionID: prepared.connectionID)
        let mutationRootMappings = DirectHeadlessVersionControlBackend.mutationRootMappings(
            workspaceRoots: snapshot.roots
        )
        XCTAssertEqual(Set(mutationRootMappings.map(\.canonicalRoot)), Set(snapshot.roots.map(\.path)))
        XCTAssertEqual(Set(mutationRootMappings.map(\.physicalRoot)), Set(snapshot.roots.map(\.path)))
        let untrustedRequestedTarget = profile.appendingPathComponent("caller-selected-worktree", isDirectory: true)
        XCTAssertFalse(mutationRootMappings.contains {
            $0.physicalRoot == untrustedRequestedTarget.deletingLastPathComponent().standardizedFileURL.path
        })
        let context = DomainToolInvocationSecurityContext(
            principal: prepared.principal,
            connectionID: prepared.connectionID,
            connectionGeneration: prepared.connectionGeneration,
            invocationID: UUID(),
            runtimeID: prepared.runtime.identity.runtimeID,
            runtimeGeneration: prepared.runtime.identity.lifecycleGeneration,
            workspaceID: snapshot.identity.workspaceID,
            workspaceRevision: snapshot.workspace.revisions.workingRevision,
            authorizedCanonicalRoots: Set(snapshot.roots.map(\.path)),
            hasAuthoritativeRoutingContext: true,
            ephemeralGrantedToolNames: [],
            ephemeralGrantedOperations: DirectHeadlessMCPService.topLevelDefaultMutationOperations
        )
        let fixturePath = root.appendingPathComponent("Package.swift").path
        let arguments: [String: [String: Value]] = [
            "app_settings": ["op": .string("list")],
            "bind_context": ["op": .string("status")],
            "manage_workspaces": ["action": .string("list")],
            "manage_selection": ["op": .string("set"), "paths": .array([.string("Package.swift")])],
            "file_actions": ["action": .string("create"), "path": .string(profile.appendingPathComponent("denied.txt").path)],
            "get_code_structure": ["paths": .array([.string(fixturePath)]), "signatures": .bool(false)],
            "get_file_tree": ["type": .string("roots")],
            "read_file": ["path": .string(fixturePath), "start_line": .int(1), "limit": .int(1)],
            "file_search": ["pattern": .string("swift-tools-version"), "path": .string(fixturePath), "regex": .bool(false)],
            "workspace_context": ["op": .string("snapshot")],
            "prompt": ["op": .string("set"), "text": .string("headless context mutation")],
            "apply_edits": ["path": .string(fixturePath), "search": .string("not-present"), "replace": .string("never")],
            "oracle_utils": ["op": .string("models")],
            "ask_oracle": ["message": .string("Reply exactly OK")],
            "oracle_send": ["chat_id": .string(UUID().uuidString), "message": .string("continue")],
            "oracle_chat_log": [:],
            "context_builder": ["instructions": .string("Inspect the workspace")],
            "ask_user": ["questions": .array([.object(["id": .string("q"), "question": .string("Continue?")])])],
            "git": ["op": .string("status")],
            "manage_worktree": ["op": .string("list")],
            "agent_explore": ["op": .string("poll"), "session_id": .string(UUID().uuidString)],
            "agent_run": ["op": .string("poll"), "session_id": .string(UUID().uuidString)],
            "agent_manage": ["op": .string("list_agents"), "roles_only": .bool(true)],
            "share_thoughts": ["text": .string("progress")],
            "set_status": ["session_name": .string("composition")],
            "wait_for_next_user_instruction": [:],
            "history": ["op": .string("list_sessions")]
        ]
        XCTAssertEqual(arguments.count, 27)
        XCTAssertEqual(Set(arguments.keys), Set(MCPDomainCanonicalToolDefinitions.definitions.map(\.name)))

        var dispatched: Set<String> = []
        for name in MCPDomainToolCatalog.orderedToolNames {
            let scope: MCPDomainToolRegistrationScope = ["app_settings", "bind_context", "manage_workspaces"].contains(name)
                ? .application
                : .standalone(id: prepared.scopeID)
            let resolution = try await prepared.runtime.domainHost.resolve(toolName: name, scope: scope)
            var invocationContext = context
            invocationContext = DomainToolInvocationSecurityContext(
                principal: context.principal,
                connectionID: context.connectionID,
                connectionGeneration: context.connectionGeneration,
                invocationID: UUID(),
                runtimeID: context.runtimeID,
                runtimeGeneration: context.runtimeGeneration,
                workspaceID: context.workspaceID,
                workspaceRevision: context.workspaceRevision,
                authorizedCanonicalRoots: context.authorizedCanonicalRoots,
                hasAuthoritativeRoutingContext: context.hasAuthoritativeRoutingContext,
                ephemeralGrantedToolNames: context.ephemeralGrantedToolNames,
                ephemeralGrantedOperations: context.ephemeralGrantedOperations
            )
            do {
                _ = try await prepared.runtime.domainHost.invoke(MCPDomainHostInvocation(
                    invocationID: invocationContext.invocationID,
                    connectionID: prepared.connectionID,
                    resolution: resolution,
                    arguments: XCTUnwrap(arguments[name]),
                    securityContext: invocationContext
                ))
            } catch {
                let text = String(describing: error)
                XCTAssertFalse(text.contains("Missing canonical definition"), "tool=\(name): \(text)")
                XCTAssertFalse(text.contains("No standalone"), "tool=\(name): \(text)")
                XCTAssertFalse(text.contains("live Agent session/worktree binding adapter"), "tool=\(name): \(text)")
            }
            dispatched.insert(name)
        }
        XCTAssertEqual(dispatched, Set(arguments.keys))
        let mutated = try await prepared.context.snapshot(connectionID: prepared.connectionID)
        XCTAssertEqual(mutated.selection, ["Package.swift"])
        XCTAssertEqual(mutated.prompt, "headless context mutation")

        let deniedExport = try await prepared.runtime.domainHost.resolve(
            toolName: "prompt",
            scope: .standalone(id: prepared.scopeID)
        )
        let deniedPath = root.appendingPathComponent(".build/denied-headless-prompt-export-\(UUID().uuidString).txt")
        let deniedInvocationID = UUID()
        let deniedSecurityContext = DomainToolInvocationSecurityContext(
            principal: context.principal,
            connectionID: context.connectionID,
            connectionGeneration: context.connectionGeneration,
            invocationID: deniedInvocationID,
            runtimeID: context.runtimeID,
            runtimeGeneration: context.runtimeGeneration,
            workspaceID: context.workspaceID,
            workspaceRevision: context.workspaceRevision,
            authorizedCanonicalRoots: context.authorizedCanonicalRoots,
            hasAuthoritativeRoutingContext: context.hasAuthoritativeRoutingContext,
            ephemeralGrantedToolNames: context.ephemeralGrantedToolNames,
            ephemeralGrantedOperations: context.ephemeralGrantedOperations
        )
        do {
            _ = try await prepared.runtime.domainHost.invoke(MCPDomainHostInvocation(
                invocationID: deniedInvocationID,
                connectionID: prepared.connectionID,
                resolution: deniedExport,
                arguments: ["op": .string("export"), "path": .string(deniedPath.path)],
                securityContext: deniedSecurityContext
            ))
            XCTFail("A verified direct session must not broaden prompt mutation defaults to filesystem export")
        } catch let error as DomainMutationPolicyError {
            XCTAssertEqual(error, .grantMissing)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: deniedPath.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: profile.appendingPathComponent("denied.txt").path))
    }
}
