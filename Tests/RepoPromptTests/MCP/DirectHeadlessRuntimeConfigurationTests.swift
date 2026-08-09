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

    func testDefaultProfileRoutesSavedWorkspaceThroughExistingWorktreeWithoutPersistence() async throws {
        let fixture = try await makeSavedWorkspaceWorktreeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = DirectHeadlessMCPService(
            environment: [
                "REPOPROMPT_MCP_HEADLESS_PROFILE": "worktree-routing-test",
                "REPOPROMPT_MCP_HEADLESS_PROFILE_DIR": fixture.profile.path,
                "REPOPROMPT_MCP_WORKING_DIRS": fixture.launchWorktree.path,
                "REPOPROMPT_CODEX_COMMAND": fixture.provider.path,
                "PATH": ProcessInfo.processInfo.environment["PATH"] ?? ""
            ],
            currentDirectory: fixture.launchWorktree
        )
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }

        let processSnapshot = try await prepared.context.snapshot(connectionID: prepared.connectionID)
        XCTAssertEqual(processSnapshot.identity.workspaceID, fixture.workspaceID)
        XCTAssertEqual(processSnapshot.identity.contextID, fixture.contextID)
        XCTAssertEqual(processSnapshot.canonicalRoots.map(\.path), [fixture.canonicalRepo.path])
        XCTAssertEqual(processSnapshot.roots.map(\.path), [fixture.launchWorktree.path])
        XCTAssertEqual(processSnapshot.workspace.document.metadata.repoPaths, [fixture.canonicalRepo.path])
        let workspaceCatalog = await prepared.runtime.workspaceStore.snapshot()
        XCTAssertEqual(workspaceCatalog.workspaces.count, 1)

        let security = DomainToolInvocationSecurityContext(
            principal: prepared.principal,
            connectionID: prepared.connectionID,
            connectionGeneration: prepared.connectionGeneration,
            invocationID: UUID(),
            runtimeID: prepared.runtime.identity.runtimeID,
            runtimeGeneration: prepared.runtime.identity.lifecycleGeneration,
            workspaceID: processSnapshot.identity.workspaceID,
            workspaceRevision: processSnapshot.workspace.revisions.workingRevision,
            authorizedCanonicalRoots: Set(processSnapshot.roots.map(\.path)),
            hasAuthoritativeRoutingContext: true,
            ephemeralGrantedToolNames: [],
            ephemeralGrantedOperations: DirectHeadlessMCPService.topLevelDefaultMutationOperations.union([
                "agent_run.ai_cost",
                "agent_run.external_process"
            ])
        )
        let agentRunResolution = try await prepared.runtime.domainHost.resolve(
            toolName: "agent_run",
            scope: .standalone(id: prepared.scopeID)
        )
        func invokeAgentRun(
            _ arguments: [String: Value],
            securityContext: DomainToolInvocationSecurityContext
        ) async throws -> Value {
            let invocationContext = DomainToolInvocationSecurityContext(
                principal: securityContext.principal,
                connectionID: securityContext.connectionID,
                connectionGeneration: securityContext.connectionGeneration,
                invocationID: UUID(),
                runtimeID: securityContext.runtimeID,
                runtimeGeneration: securityContext.runtimeGeneration,
                workspaceID: securityContext.workspaceID,
                workspaceRevision: securityContext.workspaceRevision,
                authorizedCanonicalRoots: securityContext.authorizedCanonicalRoots,
                hasAuthoritativeRoutingContext: securityContext.hasAuthoritativeRoutingContext,
                ephemeralGrantedToolNames: securityContext.ephemeralGrantedToolNames,
                ephemeralGrantedOperations: securityContext.ephemeralGrantedOperations
            )
            return try await prepared.runtime.domainHost.invoke(MCPDomainHostInvocation(
                invocationID: invocationContext.invocationID,
                connectionID: prepared.connectionID,
                resolution: agentRunResolution,
                arguments: arguments,
                securityContext: invocationContext
            ))
        }
        let result = try await invokeAgentRun(
            [
                "message": .string("Report the working directory."),
                "worktree": .string("@branch:route-alternate"),
                "worktree_label": .string("Alternate route"),
                "worktree_color": .string("#3366ff"),
                "inherit_worktree": .bool(false),
                "detach": .bool(true),
                "timeout": .int(10)
            ],
            securityContext: security
        )
        let resultObject = try XCTUnwrap(result.objectValue)
        XCTAssertEqual(resultObject["status"]?.stringValue, "running")
        let sessionID = try XCTUnwrap(try UUID(
            uuidString: XCTUnwrap(resultObject["session_id"]?.stringValue)
        ))
        let terminal = await prepared.providerCoordinator.waitAgent(sessionID: sessionID, timeout: 10)
        XCTAssertEqual(terminal.status, .completed)
        let providerWorkingDirectory = try URL(
            fileURLWithPath: XCTUnwrap(terminal.latestAssistantPreview),
            isDirectory: true
        ).standardizedFileURL.resolvingSymlinksInPath()
        XCTAssertEqual(providerWorkingDirectory.path, fixture.alternateWorktree.resolvingSymlinksInPath().path)
        XCTAssertEqual(terminal.worktreeBindings.count, 1)
        XCTAssertEqual(
            terminal.worktreeBindings.first?.worktreeRootPath,
            fixture.alternateWorktree.path
        )
        XCTAssertTrue(terminal.worktreeBindings.first?.repoKey.hasPrefix("canonical-") == true)
        XCTAssertEqual(terminal.worktreeBindings.first?.visualLabel, "Alternate route")
        XCTAssertEqual(terminal.worktreeBindings.first?.visualColorHex, "#3366FF")
        let sessionSnapshot = try await prepared.context.snapshot(
            connectionID: prepared.connectionID,
            sessionID: sessionID
        )
        XCTAssertEqual(sessionSnapshot.roots.map(\.path), [fixture.alternateWorktree.path])
        let runPrincipal = DomainClientPrincipal(
            principalID: UUID(),
            stableKey: "test-run-principal",
            displayName: "Test run",
            kind: .runScoped,
            assurance: .hostLaunchToken,
            processID: nil,
            runID: sessionID,
            provider: "test"
        )
        let runSecurity = await DirectHeadlessMCPService.securityContext(
            prepared: prepared,
            connection: DirectHeadlessMCPService.ConnectionContext(
                connectionID: prepared.connectionID,
                connectionGeneration: prepared.connectionGeneration,
                principal: runPrincipal,
                policyProfile: .direct,
                restrictedToolNames: [],
                additionalToolNames: [],
                ephemeralGrantedOperations: []
            ),
            invocationID: UUID()
        )
        XCTAssertEqual(runSecurity.authorizedCanonicalRoots, [fixture.alternateWorktree.path])
        let conversationRequest = try DomainPhysicalToolRequest(
            argumentsJSON: JSONEncoder().encode(["message": Value.string("Report the working directory.")]),
            securityContext: runSecurity
        )
        let (_, conversationText) = try await prepared.providerCoordinator.createConversation(
            providerID: nil,
            message: "Report the working directory.",
            model: nil,
            request: conversationRequest
        )
        XCTAssertEqual(
            URL(fileURLWithPath: conversationText)
                .standardizedFileURL.resolvingSymlinksInPath().path,
            fixture.alternateWorktree.path
        )
        XCTAssertThrowsError(
            try DirectHeadlessDomainContext.resolvePath(
                fixture.canonicalRepo.appendingPathComponent("fixture.txt").path,
                roots: sessionSnapshot.roots
            )
        )
        let persistedBindings = await prepared.runtime.agentWorktreeBindingStore.bindings(sessionID: sessionID)
        XCTAssertTrue(persistedBindings.isEmpty)
        XCTAssertEqual(processSnapshot.workspace.document.documentBytes, fixture.savedWorkspaceBytes)

        let secondTopLevelStart = try await invokeAgentRun(
            [
                "message": .string("Report the second top-level working directory."),
                "detach": .bool(true)
            ],
            securityContext: security
        )
        let secondTopLevelID = try XCTUnwrap(try UUID(
            uuidString: XCTUnwrap(secondTopLevelStart.objectValue?["session_id"]?.stringValue)
        ))
        XCTAssertNotEqual(secondTopLevelID, sessionID)
        XCTAssertNotEqual(secondTopLevelID, prepared.scopeID.rawValue)
        let secondTopLevelTerminal = await prepared.providerCoordinator.waitAgent(
            sessionID: secondTopLevelID,
            timeout: 10
        )
        XCTAssertEqual(secondTopLevelTerminal.status, .completed)
        XCTAssertEqual(
            try URL(fileURLWithPath: XCTUnwrap(secondTopLevelTerminal.latestAssistantPreview))
                .standardizedFileURL.resolvingSymlinksInPath().path,
            fixture.launchWorktree.path
        )

        let childStart = try await invokeAgentRun(
            [
                "message": .string("Report the inherited working directory."),
                "detach": .bool(true)
            ],
            securityContext: runSecurity
        )
        let childID = try XCTUnwrap(try UUID(
            uuidString: XCTUnwrap(childStart.objectValue?["session_id"]?.stringValue)
        ))
        XCTAssertNotEqual(childID, sessionID)
        XCTAssertNotEqual(childID, secondTopLevelID)
        let childTerminal = await prepared.providerCoordinator.waitAgent(sessionID: childID, timeout: 10)
        XCTAssertEqual(childTerminal.status, .completed)
        XCTAssertEqual(childTerminal.parentSessionID, sessionID)
        XCTAssertEqual(childTerminal.worktreeBindings.first?.worktreeRootPath, fixture.alternateWorktree.path)
        XCTAssertEqual(
            try URL(fileURLWithPath: XCTUnwrap(childTerminal.latestAssistantPreview))
                .standardizedFileURL.resolvingSymlinksInPath().path,
            fixture.alternateWorktree.path
        )
        let childPrincipal = DomainClientPrincipal(
            principalID: UUID(),
            stableKey: "test-child-principal",
            displayName: "Test child",
            kind: .runScoped,
            assurance: .hostLaunchToken,
            processID: nil,
            runID: childID,
            provider: "test"
        )
        let childSecurity = await DirectHeadlessMCPService.securityContext(
            prepared: prepared,
            connection: DirectHeadlessMCPService.ConnectionContext(
                connectionID: prepared.connectionID,
                connectionGeneration: prepared.connectionGeneration,
                principal: childPrincipal,
                policyProfile: .direct,
                restrictedToolNames: [],
                additionalToolNames: [],
                ephemeralGrantedOperations: []
            ),
            invocationID: UUID()
        )
        XCTAssertEqual(childSecurity.authorizedCanonicalRoots, [fixture.alternateWorktree.path])
        let listedSessions = await prepared.providerCoordinator.listAgents()
        let listedChild = listedSessions.first { value in
            value.objectValue?["session_id"]?.stringValue == childID.uuidString
        }
        XCTAssertEqual(listedChild?.objectValue?["status"]?.stringValue, "completed")
        XCTAssertEqual(
            listedChild?.objectValue?["session"]?.objectValue?["parent_session_id"]?.stringValue,
            sessionID.uuidString
        )

        let optedOutStart = try await invokeAgentRun(
            [
                "message": .string("Report the process working directory."),
                "inherit_worktree": .bool(false),
                "detach": .bool(true)
            ],
            securityContext: runSecurity
        )
        let optedOutID = try XCTUnwrap(try UUID(
            uuidString: XCTUnwrap(optedOutStart.objectValue?["session_id"]?.stringValue)
        ))
        let optedOutTerminal = await prepared.providerCoordinator.waitAgent(sessionID: optedOutID, timeout: 10)
        XCTAssertEqual(optedOutTerminal.parentSessionID, sessionID)
        XCTAssertEqual(
            try URL(fileURLWithPath: XCTUnwrap(optedOutTerminal.latestAssistantPreview))
                .standardizedFileURL.resolvingSymlinksInPath().path,
            fixture.launchWorktree.path
        )

        do {
            _ = try await prepared.context.prepareSessionRootMappings(
                sessionID: UUID(),
                sourceSessionID: nil,
                arguments: ["worktree_create": .bool(true)],
                connectionID: prepared.connectionID
            )
            XCTFail("Expected direct-headless worktree creation to be rejected")
        } catch {
            XCTAssertTrue(String(describing: error).contains("does not create worktrees"), String(describing: error))
        }
        XCTAssertEqual(try Data(contentsOf: fixture.savedWorkspaceURL), fixture.savedWorkspaceBytes)
        let finalWorktreeInventory = try await DirectProcess.run(
            "/usr/bin/git",
            arguments: ["-C", fixture.canonicalRepo.path, "worktree", "list", "--porcelain"]
        )
        XCTAssertEqual(finalWorktreeInventory, fixture.worktreeInventory)
    }

    func testSelectedWorktreeMetadataIsBoundedAndIdentityRevalidatedBeforeLaterUse() async throws {
        let fixture = try await makeSavedWorkspaceWorktreeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = DirectHeadlessMCPService(
            environment: [
                "REPOPROMPT_MCP_HEADLESS_PROFILE": "worktree-revalidation-test",
                "REPOPROMPT_MCP_HEADLESS_PROFILE_DIR": fixture.profile.path,
                "REPOPROMPT_MCP_WORKING_DIRS": fixture.launchWorktree.path,
                "REPOPROMPT_CODEX_COMMAND": fixture.provider.path,
                "PATH": ProcessInfo.processInfo.environment["PATH"] ?? ""
            ],
            currentDirectory: fixture.launchWorktree
        )
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }
        let sessionID = UUID()
        _ = try await prepared.context.prepareSessionRootMappings(
            sessionID: sessionID,
            sourceSessionID: nil,
            arguments: [
                "worktree": .string("@branch:route-alternate"),
                "inherit_worktree": .bool(false)
            ],
            connectionID: prepared.connectionID
        )

        let gitFile = fixture.alternateWorktree.appendingPathComponent(".git")
        let originalGitFile = try Data(contentsOf: gitFile)
        defer { try? originalGitFile.write(to: gitFile) }
        var oversizedGitFile = originalGitFile
        oversizedGitFile.append(Data(repeating: 0x20, count: max(0, 4097 - oversizedGitFile.count)))
        try oversizedGitFile.write(to: gitFile)

        let worktreesAfterReplacement = try await DirectHeadlessWorktreeRouting.listWorktrees(
            repositoryRoot: fixture.canonicalRepo
        )
        XCTAssertFalse(worktreesAfterReplacement.contains { $0.path.path == fixture.alternateWorktree.path })

        do {
            _ = try await prepared.context.snapshot(
                connectionID: prepared.connectionID,
                sessionID: sessionID
            )
            XCTFail("Expected replaced worktree identity to fail closed")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains("selected worktree identity could not be verified"),
                String(describing: error)
            )
        }
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

    private struct SavedWorkspaceWorktreeFixture {
        let root: URL
        let profile: URL
        let canonicalRepo: URL
        let launchWorktree: URL
        let alternateWorktree: URL
        let provider: URL
        let workspaceID: UUID
        let contextID: UUID
        let savedWorkspaceURL: URL
        let savedWorkspaceBytes: Data
        let worktreeInventory: String
    }

    private func makeSavedWorkspaceWorktreeFixture() async throws -> SavedWorkspaceWorktreeFixture {
        let root = temporaryDirectory("saved-workspace-worktree")
        let profile = root.appendingPathComponent("profile", isDirectory: true)
        let workspaceDirectory = profile.appendingPathComponent("Workspaces", isDirectory: true)
        let canonicalRepo = root.appendingPathComponent("canonical", isDirectory: true)
        let launchWorktree = root.appendingPathComponent("launch-worktree", isDirectory: true)
        let alternateWorktree = root.appendingPathComponent("alternate-worktree", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: canonicalRepo, withIntermediateDirectories: true)
        _ = try await DirectProcess.run("/usr/bin/git", arguments: ["-C", canonicalRepo.path, "init", "-b", "main"])
        _ = try await DirectProcess.run("/usr/bin/git", arguments: ["-C", canonicalRepo.path, "config", "user.email", "test@example.invalid"])
        _ = try await DirectProcess.run("/usr/bin/git", arguments: ["-C", canonicalRepo.path, "config", "user.name", "RepoPrompt Tests"])
        try "fixture\n".write(
            to: canonicalRepo.appendingPathComponent("fixture.txt"),
            atomically: true,
            encoding: .utf8
        )
        _ = try await DirectProcess.run("/usr/bin/git", arguments: ["-C", canonicalRepo.path, "add", "fixture.txt"])
        _ = try await DirectProcess.run("/usr/bin/git", arguments: ["-C", canonicalRepo.path, "commit", "-m", "fixture"])
        _ = try await DirectProcess.run(
            "/usr/bin/git",
            arguments: ["-C", canonicalRepo.path, "worktree", "add", "-b", "route-launch", launchWorktree.path]
        )
        _ = try await DirectProcess.run(
            "/usr/bin/git",
            arguments: ["-C", canonicalRepo.path, "worktree", "add", "-b", "route-alternate", alternateWorktree.path]
        )

        let workspaceID = UUID()
        let contextID = UUID()
        let workspaceName = workspaceID.uuidString
        let savedWorkspaceDirectory = workspaceDirectory.appendingPathComponent(
            DomainWorkspaceStoragePath.directoryName(name: workspaceName, id: workspaceID),
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: savedWorkspaceDirectory, withIntermediateDirectories: true)
        let workspaceURL = savedWorkspaceDirectory.appendingPathComponent("workspace.json")
        let workspace = try makeWorkspaceDocument(
            workspaceID: workspaceID,
            contextID: contextID,
            roots: [canonicalRepo],
            fileURL: workspaceURL
        )
        try workspace.documentBytes.write(to: workspaceURL)
        let index = [[
            "id": workspaceID.uuidString,
            "name": workspaceName,
            "customStoragePath": NSNull(),
            "isSystemWorkspace": false,
            "isHiddenInMenus": false
        ] as [String: Any]]
        try JSONSerialization.data(withJSONObject: index, options: [.sortedKeys]).write(
            to: workspaceDirectory.appendingPathComponent("workspacesIndex.json")
        )

        let provider = root.appendingPathComponent("fake-codex-provider")
        let providerScript = """
        #!/bin/sh
        cat >/dev/null
        printf '{"item":{"type":"agent_message","text":"%s"}}\\n' "$PWD"
        """
        try providerScript.write(to: provider, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: provider.path)
        let worktreeInventory = try await DirectProcess.run(
            "/usr/bin/git",
            arguments: ["-C", canonicalRepo.path, "worktree", "list", "--porcelain"]
        )
        return SavedWorkspaceWorktreeFixture(
            root: root,
            profile: profile,
            canonicalRepo: canonicalRepo.standardizedFileURL.resolvingSymlinksInPath(),
            launchWorktree: launchWorktree.standardizedFileURL.resolvingSymlinksInPath(),
            alternateWorktree: alternateWorktree.standardizedFileURL.resolvingSymlinksInPath(),
            provider: provider,
            workspaceID: workspaceID,
            contextID: contextID,
            savedWorkspaceURL: workspaceURL,
            savedWorkspaceBytes: workspace.documentBytes,
            worktreeInventory: worktreeInventory
        )
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
