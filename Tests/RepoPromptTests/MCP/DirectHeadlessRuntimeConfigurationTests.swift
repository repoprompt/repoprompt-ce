import Foundation
import MCP
import RepoPromptDomainRuntime
@testable import RepoPromptMCP
import XCTest

final class DirectHeadlessRuntimeConfigurationTests: XCTestCase {
    func testDirectHeadlessAgentLifecycleRequiresAdvertisedOperation() throws {
        let supportedOperations = [
            "agent_run": ["start", "poll", "wait", "cancel"],
            "agent_explore": ["start", "poll", "wait", "cancel"]
        ]
        for (toolName, operations) in supportedOperations {
            XCTAssertThrowsError(try DirectHeadlessMCPService.validatedCallArguments(
                toolName: toolName,
                arguments: [:]
            ))
            for invalidOperation in [
                Value.null,
                .bool(true),
                .int(1),
                .string(" start "),
                .string("steer"),
                .string("respond"),
                .string("unknown")
            ] {
                XCTAssertThrowsError(try DirectHeadlessMCPService.validatedCallArguments(
                    toolName: toolName,
                    arguments: ["op": invalidOperation]
                ))
            }
            for operation in operations {
                let validated = try DirectHeadlessMCPService.validatedCallArguments(
                    toolName: toolName,
                    arguments: ["op": .string(operation)]
                )
                XCTAssertEqual(validated["op"]?.stringValue, operation)
            }
        }
        XCTAssertTrue(try DirectHeadlessMCPService.validatedCallArguments(
            toolName: "get_file_tree",
            arguments: [:]
        ).isEmpty)
    }

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

    func testIdentityRoutingPreservesLegacyWorkspaceCreateSwitchAndRootMutations() async throws {
        let root = temporaryDirectory("identity-routing")
        let initialRoot = root.appendingPathComponent("initial", isDirectory: true)
        let createdRoot = root.appendingPathComponent("created", isDirectory: true)
        let addedRoot = root.appendingPathComponent("added", isDirectory: true)
        let storageRoot = root.appendingPathComponent("state", isDirectory: true)
        for directory in [initialRoot, createdRoot, addedRoot] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let runtime = MCPDomainRuntime(configuration: .init(
            mode: .standalone,
            profileIdentifier: "headless-identity-routing",
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
        let initialWorkspaceID = UUID()
        try await createWorkspace(
            makeWorkspaceDocument(
                workspaceID: initialWorkspaceID,
                contextID: UUID(),
                roots: [initialRoot],
                fileURL: storageRoot.appendingPathComponent("initial.json")
            ),
            in: runtime
        )
        let route = try await DirectHeadlessWorktreeRouting.resolveInitialRoute(
            workingDirectories: [initialRoot],
            catalog: runtime.workspaceStore.snapshot()
        )
        XCTAssertTrue(route.rootOverlay.mappings.isEmpty)
        let scopeID = DomainStandaloneScopeID()
        _ = try await runtime.standaloneScopeCoordinator.register(
            scopeID: scopeID,
            connectionID: UUID(),
            workingDirectories: route.bindingWorkingDirectories
        )
        let context = DirectHeadlessDomainContext(
            runtime: runtime,
            scopeID: scopeID,
            processRootOverlay: route.rootOverlay
        )
        let backend = DirectHeadlessGlobalBackend(runtime: runtime, scopeID: scopeID, context: context)
        func request(_ arguments: [String: Value]) throws -> DomainPhysicalToolRequest {
            try DomainPhysicalToolRequest(
                argumentsJSON: JSONEncoder().encode(arguments),
                securityContext: nil
            )
        }

        let createResult = try await backend.manageWorkspaceLifecycle(request([
            "action": .string("create"),
            "name": .string("Created workspace"),
            "folder_path": .string(createdRoot.path),
            "switch_to_created": .bool(false)
        ]))
        let createValue = try JSONDecoder().decode(Value.self, from: createResult.json)
        let createdWorkspaceID = try XCTUnwrap(createValue.objectValue?["workspace_id"]?.stringValue)
        _ = try await backend.manageWorkspaceLifecycle(request([
            "action": .string("switch"),
            "workspace": .string(createdWorkspaceID)
        ]))
        _ = try await backend.manageWorkspaceLifecycle(request([
            "action": .string("add_folder"),
            "workspace": .string(createdWorkspaceID),
            "folder_path": .string(addedRoot.path)
        ]))
        _ = try await backend.manageWorkspaceLifecycle(request([
            "action": .string("remove_folder"),
            "workspace": .string(createdWorkspaceID),
            "folder_path": .string(createdRoot.path)
        ]))
        let createdID = try XCTUnwrap(UUID(uuidString: createdWorkspaceID))
        let createdSnapshot = await runtime.contextStore.workspaceSnapshot(createdID)
        let created = try XCTUnwrap(createdSnapshot)
        XCTAssertEqual(created.document.metadata.repoPaths, [addedRoot.path])
    }

    func testEquivalentDuplicateCanonicalRootsRemainUnboundAndExplicitlyRecoverable() async throws {
        let fixture = try await makeSavedWorkspaceWorktreeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let canonicalAlias = fixture.root.appendingPathComponent("canonical-alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: canonicalAlias,
            withDestinationURL: fixture.canonicalRepo
        )
        let storageRoot = fixture.root.appendingPathComponent("duplicate-state", isDirectory: true)
        let runtime = MCPDomainRuntime(configuration: .init(
            mode: .standalone,
            profileIdentifier: "headless-duplicate-route",
            storageDirectory: storageRoot,
            eventDirectory: fixture.root.appendingPathComponent("duplicate-events", isDirectory: true),
            temporaryDirectory: fixture.root.appendingPathComponent("duplicate-tmp", isDirectory: true),
            externalReloadInterval: nil
        ))
        try await runtime.start()
        addTeardownBlock { _ = await runtime.shutdown() }
        let firstWorkspaceID = UUID()
        let firstContextID = UUID()
        let secondWorkspaceID = UUID()
        let secondContextID = UUID()
        for (workspaceID, contextID, name, workspaceRoot) in [
            (firstWorkspaceID, firstContextID, "first", fixture.canonicalRepo),
            (secondWorkspaceID, secondContextID, "second", canonicalAlias)
        ] {
            try await createWorkspace(
                makeWorkspaceDocument(
                    workspaceID: workspaceID,
                    contextID: contextID,
                    roots: [workspaceRoot],
                    fileURL: storageRoot.appendingPathComponent("\(name).json")
                ),
                in: runtime
            )
        }

        let route = try await DirectHeadlessWorktreeRouting.resolveInitialRoute(
            workingDirectories: [fixture.launchWorktree],
            catalog: runtime.workspaceStore.snapshot()
        )
        XCTAssertEqual(route.bindingWorkingDirectories.map(\.path), [fixture.canonicalRepo.path])
        let scopeID = DomainStandaloneScopeID()
        let connectionID = UUID()
        let initial = try await runtime.standaloneScopeCoordinator.register(
            scopeID: scopeID,
            connectionID: connectionID,
            workingDirectories: route.bindingWorkingDirectories
        )
        XCTAssertEqual(initial.binding, .unbound)
        let context = DirectHeadlessDomainContext(
            runtime: runtime,
            scopeID: scopeID,
            processRootOverlay: route.rootOverlay
        )
        let backend = DirectHeadlessGlobalBackend(runtime: runtime, scopeID: scopeID, context: context)
        _ = try await backend.routeContext(DomainPhysicalToolRequest(
            argumentsJSON: JSONEncoder().encode([
                "op": Value.string("bind"),
                "context_id": .string(secondContextID.uuidString)
            ]),
            securityContext: nil
        ))
        let rebound = try await runtime.standaloneScopeCoordinator.snapshot(scopeID: scopeID)
        XCTAssertEqual(
            rebound.binding,
            .context(DomainContextIdentity(workspaceID: secondWorkspaceID, contextID: secondContextID), explicit: true)
        )
    }

    func testDuplicateMultiRootWorkspacesRemainRecoverableAcrossRootOrdering() async throws {
        let root = temporaryDirectory("duplicate-multi-root")
        let first = try await makeWorktreeRepository(in: root, prefix: "first")
        let second = try await makeWorktreeRepository(in: root, prefix: "second")
        let storageRoot = root.appendingPathComponent("state", isDirectory: true)
        let runtime = MCPDomainRuntime(configuration: .init(
            mode: .standalone,
            profileIdentifier: "headless-duplicate-multi-root",
            storageDirectory: storageRoot,
            eventDirectory: root.appendingPathComponent("events", isDirectory: true),
            temporaryDirectory: root.appendingPathComponent("tmp", isDirectory: true),
            externalReloadInterval: nil
        ))
        try await runtime.start()
        addTeardownBlock { _ = await runtime.shutdown() }
        for (index, roots) in [
            [first.canonicalRepo, second.canonicalRepo],
            [second.canonicalRepo, first.canonicalRepo]
        ].enumerated() {
            try await createWorkspace(
                makeWorkspaceDocument(
                    workspaceID: UUID(),
                    contextID: UUID(),
                    roots: roots,
                    fileURL: storageRoot.appendingPathComponent("workspace-\(index).json")
                ),
                in: runtime
            )
        }

        let route = try await DirectHeadlessWorktreeRouting.resolveInitialRoute(
            workingDirectories: [first.launchWorktree, second.launchWorktree],
            catalog: runtime.workspaceStore.snapshot()
        )
        XCTAssertEqual(
            Set(route.bindingWorkingDirectories.map(\.path)),
            Set([first.canonicalRepo.path, second.canonicalRepo.path])
        )
        let scopeID = DomainStandaloneScopeID()
        let scope = try await runtime.standaloneScopeCoordinator.register(
            scopeID: scopeID,
            connectionID: UUID(),
            workingDirectories: route.bindingWorkingDirectories
        )
        XCTAssertEqual(scope.binding, .unbound)
    }

    func testInitialWorktreeRouteRejectsAmbiguousCanonicalAndPhysicalWorkspaces() async throws {
        let fixture = try await makeSavedWorkspaceWorktreeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let storageRoot = fixture.root.appendingPathComponent("ambiguous-state", isDirectory: true)
        let runtime = MCPDomainRuntime(configuration: .init(
            mode: .standalone,
            profileIdentifier: "headless-ambiguous-route",
            storageDirectory: storageRoot,
            eventDirectory: fixture.root.appendingPathComponent("ambiguous-events", isDirectory: true),
            temporaryDirectory: fixture.root.appendingPathComponent("ambiguous-tmp", isDirectory: true),
            externalReloadInterval: nil
        ))
        try await runtime.start()
        addTeardownBlock { _ = await runtime.shutdown() }
        try await createWorkspace(
            makeWorkspaceDocument(
                workspaceID: UUID(),
                contextID: UUID(),
                roots: [fixture.canonicalRepo],
                fileURL: storageRoot.appendingPathComponent("canonical.json")
            ),
            in: runtime
        )
        try await createWorkspace(
            makeWorkspaceDocument(
                workspaceID: UUID(),
                contextID: UUID(),
                roots: [fixture.launchWorktree],
                fileURL: storageRoot.appendingPathComponent("physical.json")
            ),
            in: runtime
        )

        do {
            _ = try await DirectHeadlessWorktreeRouting.resolveInitialRoute(
                workingDirectories: [fixture.launchWorktree],
                catalog: runtime.workspaceStore.snapshot()
            )
            XCTFail("Expected mixed canonical/physical workspace ambiguity to fail closed")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains("multiple saved workspaces"),
                String(describing: error)
            )
        }
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

        let invocationPrincipal = DomainClientPrincipal(
            principalID: UUID(),
            stableKey: "test-top-level-principal",
            displayName: "Test top-level",
            kind: .runScoped,
            assurance: .hostLaunchToken,
            processID: nil,
            runID: prepared.scopeID.rawValue,
            provider: "test"
        )
        let security = DomainToolInvocationSecurityContext(
            principal: invocationPrincipal,
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
                "op": .string("start"),
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
                additionalToolNames: ["agent_run"],
                ephemeralGrantedOperations: []
            ),
            invocationID: UUID()
        )
        XCTAssertEqual(runSecurity.authorizedCanonicalRoots, [fixture.alternateWorktree.path])
        let contextBuilderSecurity = DomainToolInvocationSecurityContext(
            principal: runSecurity.principal,
            connectionID: runSecurity.connectionID,
            connectionGeneration: runSecurity.connectionGeneration,
            invocationID: UUID(),
            runtimeID: runSecurity.runtimeID,
            runtimeGeneration: runSecurity.runtimeGeneration,
            workspaceID: runSecurity.workspaceID,
            workspaceRevision: runSecurity.workspaceRevision,
            authorizedCanonicalRoots: runSecurity.authorizedCanonicalRoots,
            hasAuthoritativeRoutingContext: runSecurity.hasAuthoritativeRoutingContext,
            ephemeralGrantedToolNames: runSecurity.ephemeralGrantedToolNames,
            ephemeralGrantedOperations: runSecurity.ephemeralGrantedOperations.union([
                "context_builder.ai_cost",
                "context_builder.external_process"
            ])
        )
        let preparedConversationCarrier = try await prepared.childLaunchCoordinator.prepare(
            toolName: "context_builder",
            arguments: ["instructions": .string("Report the working directory.")],
            securityContext: contextBuilderSecurity
        )
        let conversationCarrier = try XCTUnwrap(preparedConversationCarrier)
        XCTAssertEqual(conversationCarrier.runID, sessionID)
        let callbackPrincipal = DomainClientPrincipal(
            principalID: UUID(),
            stableKey: "test-conversation-callback",
            displayName: "Test conversation callback",
            kind: .runScoped,
            assurance: .hostLaunchToken,
            processID: nil,
            runID: conversationCarrier.runID,
            provider: "test"
        )
        let callbackSecurity = await DirectHeadlessMCPService.securityContext(
            prepared: prepared,
            connection: DirectHeadlessMCPService.ConnectionContext(
                connectionID: prepared.connectionID,
                connectionGeneration: prepared.connectionGeneration,
                principal: callbackPrincipal,
                policyProfile: .direct,
                restrictedToolNames: [],
                additionalToolNames: [],
                ephemeralGrantedOperations: []
            ),
            invocationID: UUID()
        )
        XCTAssertEqual(callbackSecurity.authorizedCanonicalRoots, [fixture.alternateWorktree.path])

        let rejectedSessionID = UUID()
        _ = try await prepared.context.prepareSessionRootOverlay(
            sessionID: rejectedSessionID,
            sourceSessionID: sessionID,
            arguments: [:],
            connectionID: prepared.connectionID
        )
        let rejectingCoordinator = DirectHeadlessProviderCoordinator(
            runtime: prepared.runtime,
            context: prepared.context,
            settingsStore: DomainDirectSettingsStore(
                persistence: prepared.runtime.persistenceCoordinator,
                profileIdentifier: prepared.runtime.configuration.profileIdentifier
            ),
            environment: [
                "REPOPROMPT_CODEX_COMMAND": fixture.provider.path,
                "PATH": ProcessInfo.processInfo.environment["PATH"] ?? ""
            ],
            beginEpoch: { _, _ in .rejected(reason: "injected epoch rejection") }
        )
        let conflictingCarrier = DomainChildLaunchCarrier(
            runID: rejectedSessionID,
            launchTokenID: UUID(),
            credentialEnvelope: nil,
            environment: [:]
        )
        let conflictingArguments: [String: Value] = [
            "message": .string("This start must be rejected before provider execution."),
            "worktree": .string("@main")
        ]
        let conflictingRequest = try DomainPhysicalToolRequest(
            argumentsJSON: JSONEncoder().encode(conflictingArguments),
            securityContext: runSecurity
        )
        do {
            _ = try await DomainChildLaunchContext.$current.withValue(conflictingCarrier) {
                try await rejectingCoordinator.startAgent(
                    args: conflictingArguments,
                    request: conflictingRequest
                )
            }
            XCTFail("Expected the injected epoch rejection to fail the start")
        } catch {
            XCTAssertTrue(String(describing: error).contains("injected epoch rejection"), String(describing: error))
        }
        let rejectedRegistrationRemainsActive = await prepared.runtime.agentSessionStore.hasActiveRegistration(
            sessionID: rejectedSessionID
        )
        XCTAssertFalse(rejectedRegistrationRemainsActive)
        let rolledBackSnapshot = try await prepared.context.snapshot(
            connectionID: prepared.connectionID,
            sessionID: rejectedSessionID
        )
        XCTAssertEqual(rolledBackSnapshot.roots.map(\.path), [fixture.alternateWorktree.path])
        XCTAssertEqual(rolledBackSnapshot.activeRoot?.path, fixture.alternateWorktree.path)

        let contextBuilderResolution = try await prepared.runtime.domainHost.resolve(
            toolName: "context_builder",
            scope: .standalone(id: prepared.scopeID)
        )
        let contextBuilderValue = try await prepared.runtime.domainHost.invoke(MCPDomainHostInvocation(
            invocationID: contextBuilderSecurity.invocationID,
            connectionID: prepared.connectionID,
            resolution: contextBuilderResolution,
            arguments: ["instructions": .string("Report the working directory.")],
            securityContext: contextBuilderSecurity
        ))
        let conversationText = try XCTUnwrap(contextBuilderValue.objectValue?["response"]?.stringValue)
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
                "op": .string("start"),
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
                "op": .string("start"),
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
                "op": .string("start"),
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

        for invalidSelector in [Value.string("  "), .null] {
            do {
                _ = try await prepared.context.prepareSessionRootOverlay(
                    sessionID: UUID(),
                    sourceSessionID: sessionID,
                    arguments: ["worktree": invalidSelector],
                    connectionID: prepared.connectionID
                )
                XCTFail("Expected an empty explicit worktree selector to be rejected")
            } catch {
                XCTAssertTrue(String(describing: error).contains("non-empty string"), String(describing: error))
            }
        }

        do {
            _ = try await prepared.context.prepareSessionRootOverlay(
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

    func testSubdirectoryWorkspaceRootAndAbsoluteSelectionStayFencedAcrossWorktrees() async throws {
        let relativeRoot = "Packages/App"
        let canonicalSelectedFile = "\(relativeRoot)/app.txt"
        let fixture = try await makeSavedWorkspaceWorktreeFixture(
            workspaceRelativeRoot: relativeRoot,
            selectedPaths: [canonicalSelectedFile]
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let canonicalRoot = fixture.canonicalRepo.appendingPathComponent(relativeRoot, isDirectory: true)
        let launchRoot = fixture.launchWorktree.appendingPathComponent(relativeRoot, isDirectory: true)
        let alternateRoot = fixture.alternateWorktree.appendingPathComponent(relativeRoot, isDirectory: true)
        let service = DirectHeadlessMCPService(
            environment: [
                "REPOPROMPT_MCP_HEADLESS_PROFILE": "worktree-subdirectory-test",
                "REPOPROMPT_MCP_HEADLESS_PROFILE_DIR": fixture.profile.path,
                "REPOPROMPT_MCP_WORKING_DIRS": launchRoot.path,
                "REPOPROMPT_CODEX_COMMAND": fixture.provider.path,
                "PATH": ProcessInfo.processInfo.environment["PATH"] ?? ""
            ],
            currentDirectory: launchRoot
        )
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }

        let processSnapshot = try await prepared.context.snapshot(connectionID: prepared.connectionID)
        XCTAssertEqual(processSnapshot.canonicalRoots.map(\.path), [canonicalRoot.path])
        XCTAssertEqual(processSnapshot.roots.map(\.path), [launchRoot.path])
        XCTAssertEqual(
            processSnapshot.selection,
            [launchRoot.appendingPathComponent("app.txt").path]
        )

        let sessionID = UUID()
        _ = try await prepared.context.prepareSessionRootOverlay(
            sessionID: sessionID,
            sourceSessionID: nil,
            arguments: [
                "worktree": .string("@branch:route-alternate"),
                "inherit_worktree": .bool(false)
            ],
            connectionID: prepared.connectionID
        )
        let sessionSnapshot = try await prepared.context.snapshot(
            connectionID: prepared.connectionID,
            sessionID: sessionID
        )
        XCTAssertEqual(sessionSnapshot.roots.map(\.path), [alternateRoot.path])
        XCTAssertEqual(
            sessionSnapshot.selection,
            [alternateRoot.appendingPathComponent("app.txt").path]
        )

        let security = await DirectHeadlessMCPService.securityContext(
            prepared: prepared,
            connection: DirectHeadlessMCPService.ConnectionContext(
                connectionID: prepared.connectionID,
                connectionGeneration: prepared.connectionGeneration,
                principal: DomainClientPrincipal(
                    principalID: UUID(),
                    stableKey: "selection-translation",
                    displayName: "Selection translation",
                    kind: .runScoped,
                    assurance: .hostLaunchToken,
                    processID: nil,
                    runID: sessionID,
                    provider: "test"
                ),
                policyProfile: .direct,
                restrictedToolNames: [],
                additionalToolNames: [],
                ephemeralGrantedOperations: []
            ),
            invocationID: UUID()
        )
        let newPhysicalSelection = alternateRoot.appendingPathComponent("new.swift").path
        let mutated = try await prepared.context.mutate(
            request: DomainPhysicalToolRequest(argumentsJSON: Data(), securityContext: security),
            mutation: .setSelection([newPhysicalSelection])
        )
        XCTAssertEqual(mutated.selection, [newPhysicalSelection])
        let persistedSnapshot = await prepared.runtime.contextStore.workspaceSnapshot(fixture.workspaceID)
        let persisted = try XCTUnwrap(persistedSnapshot)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: persisted.document.documentBytes) as? [String: Any]
        )
        let tabs = try XCTUnwrap(object["composeTabs"] as? [[String: Any]])
        XCTAssertEqual(
            tabs.first?["selectedPaths"] as? [String],
            [canonicalRoot.appendingPathComponent("new.swift").path]
        )

        do {
            _ = try await prepared.context.mutate(
                request: DomainPhysicalToolRequest(argumentsJSON: Data(), securityContext: security),
                mutation: .setSelection([fixture.launchWorktree.appendingPathComponent("fixture.txt").path])
            )
            XCTFail("Expected an absolute path outside the selected physical and canonical roots to fail")
        } catch {
            XCTAssertTrue(String(describing: error).contains("pathOutsideWorkspace"))
        }
    }

    func testAbsoluteMissingSelectionUsesLongestOverlappingRootMappingAfterSymlinkCanonicalization() async throws {
        let relativeRoot = "Packages/App"
        let fixture = try await makeSavedWorkspaceWorktreeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let canonicalRoot = fixture.canonicalRepo.appendingPathComponent(relativeRoot, isDirectory: true)
        let launchRoot = fixture.launchWorktree.appendingPathComponent(relativeRoot, isDirectory: true)
        let alternateRoot = fixture.alternateWorktree.appendingPathComponent(relativeRoot, isDirectory: true)
        let canonicalAlias = fixture.root.appendingPathComponent("selection-alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: canonicalAlias,
            withDestinationURL: fixture.canonicalRepo
        )
        let missingSelection = canonicalAlias
            .appendingPathComponent(relativeRoot, isDirectory: true)
            .appendingPathComponent("missing.swift", isDirectory: false)
        let workspace = try makeWorkspaceDocument(
            workspaceID: fixture.workspaceID,
            contextID: fixture.contextID,
            roots: [fixture.canonicalRepo, canonicalRoot],
            fileURL: fixture.savedWorkspaceURL,
            selectedPaths: [missingSelection.path]
        )
        try workspace.documentBytes.write(to: fixture.savedWorkspaceURL)

        let service = DirectHeadlessMCPService(
            environment: [
                "REPOPROMPT_MCP_HEADLESS_PROFILE": "overlapping-selection-test",
                "REPOPROMPT_MCP_HEADLESS_PROFILE_DIR": fixture.profile.path,
                "REPOPROMPT_MCP_WORKING_DIRS": [fixture.launchWorktree, launchRoot]
                    .map(\.path)
                    .joined(separator: ":"),
                "REPOPROMPT_CODEX_COMMAND": fixture.provider.path,
                "PATH": ProcessInfo.processInfo.environment["PATH"] ?? ""
            ],
            currentDirectory: fixture.launchWorktree
        )
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }

        let processSnapshot = try await prepared.context.snapshot(connectionID: prepared.connectionID)
        XCTAssertEqual(
            processSnapshot.selection,
            [launchRoot.appendingPathComponent("missing.swift").path]
        )

        let sessionID = UUID()
        _ = try await prepared.context.prepareSessionRootOverlay(
            sessionID: sessionID,
            sourceSessionID: nil,
            arguments: [
                "worktree": .string("@branch:route-alternate"),
                "worktree_repo_root": .string(canonicalRoot.path),
                "inherit_worktree": .bool(false)
            ],
            connectionID: prepared.connectionID
        )
        let sessionSnapshot = try await prepared.context.snapshot(
            connectionID: prepared.connectionID,
            sessionID: sessionID
        )
        XCTAssertEqual(
            sessionSnapshot.roots.map(\.path),
            [fixture.launchWorktree.path, alternateRoot.path]
        )
        XCTAssertEqual(
            sessionSnapshot.selection,
            [alternateRoot.appendingPathComponent("missing.swift").path]
        )
    }

    func testAbsoluteAliasedSelectionPreservesExistingSymlinkNameAcrossWorktrees() async throws {
        let fixture = try await makeSavedWorkspaceWorktreeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let canonicalAlias = fixture.root.appendingPathComponent("selection-symlink-alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: canonicalAlias,
            withDestinationURL: fixture.canonicalRepo
        )
        for (root, target) in [
            (fixture.canonicalRepo, "canonical-target.swift"),
            (fixture.launchWorktree, "launch-target.swift"),
            (fixture.alternateWorktree, "alternate-target.swift")
        ] {
            let targetURL = root.appendingPathComponent(target)
            try Data("// \(target)\n".utf8).write(to: targetURL)
            for selectionName in ["current.swift", "next.swift"] {
                try FileManager.default.createSymbolicLink(
                    at: root.appendingPathComponent(selectionName),
                    withDestinationURL: targetURL
                )
            }
        }
        let canonicalSelection = canonicalAlias.appendingPathComponent("current.swift")
        let workspace = try makeWorkspaceDocument(
            workspaceID: fixture.workspaceID,
            contextID: fixture.contextID,
            roots: [fixture.canonicalRepo],
            fileURL: fixture.savedWorkspaceURL,
            selectedPaths: [canonicalSelection.path]
        )
        try workspace.documentBytes.write(to: fixture.savedWorkspaceURL)

        let service = DirectHeadlessMCPService(
            environment: [
                "REPOPROMPT_MCP_HEADLESS_PROFILE": "selection-symlink-name-test",
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
        XCTAssertEqual(
            processSnapshot.selection,
            [fixture.launchWorktree.appendingPathComponent("current.swift").path]
        )

        let sessionID = UUID()
        _ = try await prepared.context.prepareSessionRootOverlay(
            sessionID: sessionID,
            sourceSessionID: nil,
            arguments: [
                "worktree": .string("@branch:route-alternate"),
                "inherit_worktree": .bool(false)
            ],
            connectionID: prepared.connectionID
        )
        let sessionSnapshot = try await prepared.context.snapshot(
            connectionID: prepared.connectionID,
            sessionID: sessionID
        )
        XCTAssertEqual(
            sessionSnapshot.selection,
            [fixture.alternateWorktree.appendingPathComponent("current.swift").path]
        )

        let security = await DirectHeadlessMCPService.securityContext(
            prepared: prepared,
            connection: DirectHeadlessMCPService.ConnectionContext(
                connectionID: prepared.connectionID,
                connectionGeneration: prepared.connectionGeneration,
                principal: DomainClientPrincipal(
                    principalID: UUID(),
                    stableKey: "selection-symlink-name",
                    displayName: "Selection symlink name",
                    kind: .runScoped,
                    assurance: .hostLaunchToken,
                    processID: nil,
                    runID: sessionID,
                    provider: "test"
                ),
                policyProfile: .direct,
                restrictedToolNames: [],
                additionalToolNames: [],
                ephemeralGrantedOperations: []
            ),
            invocationID: UUID()
        )
        let physicalSelection = fixture.alternateWorktree.appendingPathComponent("next.swift").path
        _ = try await prepared.context.mutate(
            request: DomainPhysicalToolRequest(argumentsJSON: Data(), securityContext: security),
            mutation: .setSelection([physicalSelection])
        )
        let storedSnapshot = await prepared.runtime.contextStore.workspaceSnapshot(fixture.workspaceID)
        let persistedSnapshot = try XCTUnwrap(storedSnapshot)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: persistedSnapshot.document.documentBytes) as? [String: Any]
        )
        let tabs = try XCTUnwrap(object["composeTabs"] as? [[String: Any]])
        XCTAssertEqual(
            tabs.first?["selectedPaths"] as? [String],
            [fixture.canonicalRepo.appendingPathComponent("next.swift").path]
        )
    }

    func testExplicitWorktreeSelectionRejectsSymlinkThatCollapsesSubdirectoryFence() async throws {
        let relativeRoot = "Packages/App"
        let fixture = try await makeSavedWorkspaceWorktreeFixture(workspaceRelativeRoot: relativeRoot)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let launchRoot = fixture.launchWorktree.appendingPathComponent(relativeRoot, isDirectory: true)
        let alternateRoot = fixture.alternateWorktree.appendingPathComponent(relativeRoot, isDirectory: true)
        try FileManager.default.removeItem(at: alternateRoot)
        try FileManager.default.createSymbolicLink(at: alternateRoot, withDestinationURL: fixture.alternateWorktree)
        let service = DirectHeadlessMCPService(
            environment: [
                "REPOPROMPT_MCP_HEADLESS_PROFILE": "worktree-symlink-fence-test",
                "REPOPROMPT_MCP_HEADLESS_PROFILE_DIR": fixture.profile.path,
                "REPOPROMPT_MCP_WORKING_DIRS": launchRoot.path,
                "REPOPROMPT_CODEX_COMMAND": fixture.provider.path,
                "PATH": ProcessInfo.processInfo.environment["PATH"] ?? ""
            ],
            currentDirectory: launchRoot
        )
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }

        do {
            _ = try await prepared.context.prepareSessionRootOverlay(
                sessionID: UUID(),
                sourceSessionID: nil,
                arguments: [
                    "worktree": .string("@branch:route-alternate"),
                    "inherit_worktree": .bool(false)
                ],
                connectionID: prepared.connectionID
            )
            XCTFail("Expected a symlink-collapsed subdirectory root to fail closed")
        } catch {
            XCTAssertTrue(String(describing: error).contains("does not preserve the logical root fence"))
        }
    }

    func testSelectedSubdirectoryRootRejectsSymlinkReplacementBeforeLaterUse() async throws {
        let relativeRoot = "Packages/App"
        let fixture = try await makeSavedWorkspaceWorktreeFixture(workspaceRelativeRoot: relativeRoot)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let launchRoot = fixture.launchWorktree.appendingPathComponent(relativeRoot, isDirectory: true)
        let alternateRoot = fixture.alternateWorktree.appendingPathComponent(relativeRoot, isDirectory: true)
        let service = DirectHeadlessMCPService(
            environment: [
                "REPOPROMPT_MCP_HEADLESS_PROFILE": "worktree-symlink-revalidation-test",
                "REPOPROMPT_MCP_HEADLESS_PROFILE_DIR": fixture.profile.path,
                "REPOPROMPT_MCP_WORKING_DIRS": launchRoot.path,
                "REPOPROMPT_CODEX_COMMAND": fixture.provider.path,
                "PATH": ProcessInfo.processInfo.environment["PATH"] ?? ""
            ],
            currentDirectory: launchRoot
        )
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }
        let sessionID = UUID()
        _ = try await prepared.context.prepareSessionRootOverlay(
            sessionID: sessionID,
            sourceSessionID: nil,
            arguments: [
                "worktree": .string("@branch:route-alternate"),
                "inherit_worktree": .bool(false)
            ],
            connectionID: prepared.connectionID
        )

        try FileManager.default.removeItem(at: alternateRoot)
        try FileManager.default.createSymbolicLink(
            at: alternateRoot,
            withDestinationURL: fixture.alternateWorktree
        )
        do {
            _ = try await prepared.context.snapshot(
                connectionID: prepared.connectionID,
                sessionID: sessionID
            )
            XCTFail("Expected a changed subdirectory mapping to fail closed before later use")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains("rootMappingUnavailable"),
                String(describing: error)
            )
        }
    }

    func testMultiRootSessionOverlayPreservesMappingsAndActiveRoot() async throws {
        let fixture = try await makeSavedWorkspaceWorktreeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let secondary = try await makeWorktreeRepository(in: fixture.root, prefix: "secondary")
        let workspace = try makeWorkspaceDocument(
            workspaceID: fixture.workspaceID,
            contextID: fixture.contextID,
            roots: [fixture.canonicalRepo, secondary.canonicalRepo],
            fileURL: fixture.savedWorkspaceURL
        )
        try workspace.documentBytes.write(to: fixture.savedWorkspaceURL)

        let processRoots = [fixture.launchWorktree, secondary.launchWorktree]
        let service = DirectHeadlessMCPService(
            environment: [
                "REPOPROMPT_MCP_HEADLESS_PROFILE": "multi-root-overlay-test",
                "REPOPROMPT_MCP_HEADLESS_PROFILE_DIR": fixture.profile.path,
                "REPOPROMPT_MCP_WORKING_DIRS": processRoots.map(\.path).joined(separator: ":"),
                "REPOPROMPT_CODEX_COMMAND": fixture.provider.path,
                "PATH": ProcessInfo.processInfo.environment["PATH"] ?? ""
            ],
            currentDirectory: fixture.launchWorktree
        )
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }

        let processSnapshot = try await prepared.context.snapshot(connectionID: prepared.connectionID)
        XCTAssertEqual(processSnapshot.roots.map(\.path), processRoots.map(\.path))
        XCTAssertEqual(processSnapshot.activeRoot?.path, fixture.launchWorktree.path)

        let primaryWorktrees = try await DirectHeadlessWorktreeRouting.listWorktrees(
            repositoryRoot: fixture.canonicalRepo
        )
        let primaryWorktree = try XCTUnwrap(
            primaryWorktrees.first { $0.path.path == fixture.alternateWorktree.path }
        )
        let primaryByID = try await startAgent(
            prepared: prepared,
            arguments: [
                "op": .string("start"),
                "message": .string("Report the primary selected worktree."),
                "worktree_id": .string(primaryWorktree.worktreeID),
                "detach": .bool(true)
            ]
        )
        let primaryByIDTerminal = await prepared.providerCoordinator.waitAgent(sessionID: primaryByID, timeout: 10)
        XCTAssertEqual(primaryByIDTerminal.status, .completed)
        XCTAssertEqual(
            try URL(fileURLWithPath: XCTUnwrap(primaryByIDTerminal.latestAssistantPreview))
                .standardizedFileURL.resolvingSymlinksInPath().path,
            fixture.alternateWorktree.path
        )
        let primaryByIDSnapshot = try await prepared.context.snapshot(
            connectionID: prepared.connectionID,
            sessionID: primaryByID
        )
        XCTAssertEqual(
            primaryByIDSnapshot.roots.map(\.path),
            [fixture.alternateWorktree.path, secondary.launchWorktree.path]
        )
        XCTAssertEqual(primaryByIDSnapshot.activeRoot?.path, fixture.alternateWorktree.path)

        let parentID = try await startAgent(
            prepared: prepared,
            arguments: [
                "op": .string("start"),
                "message": .string("Report the selected non-first root."),
                "worktree": .string("@branch:route-alternate"),
                "worktree_repo_root": .string(secondary.canonicalRepo.path),
                "detach": .bool(true)
            ]
        )
        let parentTerminal = await prepared.providerCoordinator.waitAgent(sessionID: parentID, timeout: 10)
        XCTAssertEqual(parentTerminal.status, .completed)
        XCTAssertEqual(
            try URL(fileURLWithPath: XCTUnwrap(parentTerminal.latestAssistantPreview))
                .standardizedFileURL.resolvingSymlinksInPath().path,
            secondary.alternateWorktree.path
        )
        let parentSnapshot = try await prepared.context.snapshot(
            connectionID: prepared.connectionID,
            sessionID: parentID
        )
        XCTAssertEqual(
            parentSnapshot.roots.map(\.path),
            [fixture.launchWorktree.path, secondary.alternateWorktree.path]
        )
        XCTAssertEqual(parentSnapshot.activeRoot?.path, secondary.alternateWorktree.path)

        let falseRepresentations: [Value] = [
            .bool(false),
            .string(" FALSE "),
            .string("0"),
            .string("No"),
            .int(0),
            .double(0)
        ]
        for representation in falseRepresentations {
            let sessionID = UUID()
            let preparation = try await prepared.context.prepareSessionRootOverlay(
                sessionID: sessionID,
                sourceSessionID: parentID,
                arguments: ["inherit_worktree": representation],
                connectionID: prepared.connectionID
            )
            let snapshot = try await prepared.context.snapshot(
                connectionID: prepared.connectionID,
                sessionID: sessionID
            )
            XCTAssertEqual(snapshot.roots.map(\.path), processRoots.map(\.path))
            XCTAssertEqual(snapshot.activeRoot?.path, fixture.launchWorktree.path)
            await prepared.context.rollbackSessionRootOverlay(preparation)
        }

        let nullSessionID = UUID()
        let nullPreparation = try await prepared.context.prepareSessionRootOverlay(
            sessionID: nullSessionID,
            sourceSessionID: parentID,
            arguments: ["inherit_worktree": .null],
            connectionID: prepared.connectionID
        )
        let nullSnapshot = try await prepared.context.snapshot(
            connectionID: prepared.connectionID,
            sessionID: nullSessionID
        )
        XCTAssertEqual(nullSnapshot.roots.map(\.path), parentSnapshot.roots.map(\.path))
        XCTAssertEqual(nullSnapshot.activeRoot?.path, secondary.alternateWorktree.path)
        await prepared.context.rollbackSessionRootOverlay(nullPreparation)

        let malformedSessionID = UUID()
        do {
            _ = try await prepared.context.prepareSessionRootOverlay(
                sessionID: malformedSessionID,
                sourceSessionID: parentID,
                arguments: ["inherit_worktree": .string("sometimes")],
                connectionID: prepared.connectionID
            )
            XCTFail("Expected malformed inherit_worktree to be rejected")
        } catch {
            XCTAssertTrue(String(describing: error).contains("inherit_worktree must be a boolean"))
        }
        let malformedSnapshot = try await prepared.context.snapshot(
            connectionID: prepared.connectionID,
            sessionID: malformedSessionID
        )
        XCTAssertEqual(malformedSnapshot.roots.map(\.path), processRoots.map(\.path))
        XCTAssertEqual(malformedSnapshot.activeRoot?.path, fixture.launchWorktree.path)

        let inheritedID = try await startAgent(
            prepared: prepared,
            parentSessionID: parentID,
            arguments: [
                "op": .string("start"),
                "message": .string("Report the inherited non-first root."),
                "detach": .bool(true)
            ]
        )
        let inheritedTerminal = await prepared.providerCoordinator.waitAgent(sessionID: inheritedID, timeout: 10)
        XCTAssertEqual(inheritedTerminal.status, .completed)
        XCTAssertEqual(
            try URL(fileURLWithPath: XCTUnwrap(inheritedTerminal.latestAssistantPreview))
                .standardizedFileURL.resolvingSymlinksInPath().path,
            secondary.alternateWorktree.path
        )

        let partialOverrideID = try await startAgent(
            prepared: prepared,
            parentSessionID: parentID,
            arguments: [
                "op": .string("start"),
                "message": .string("Report the explicitly selected first root."),
                "worktree": .string("@main"),
                "worktree_repo_root": .string(fixture.canonicalRepo.path),
                "detach": .bool(true)
            ]
        )
        let partialOverrideTerminal = await prepared.providerCoordinator.waitAgent(
            sessionID: partialOverrideID,
            timeout: 10
        )
        XCTAssertEqual(partialOverrideTerminal.status, .completed)
        XCTAssertEqual(
            Set(partialOverrideTerminal.worktreeBindings.map(\.source)),
            ["direct-headless-session-overlay"]
        )
        XCTAssertEqual(
            try URL(fileURLWithPath: XCTUnwrap(partialOverrideTerminal.latestAssistantPreview))
                .standardizedFileURL.resolvingSymlinksInPath().path,
            fixture.canonicalRepo.path
        )
        let partialOverrideSnapshot = try await prepared.context.snapshot(
            connectionID: prepared.connectionID,
            sessionID: partialOverrideID
        )
        XCTAssertEqual(
            partialOverrideSnapshot.roots.map(\.path),
            [fixture.canonicalRepo.path, secondary.alternateWorktree.path]
        )
        XCTAssertEqual(partialOverrideSnapshot.activeRoot?.path, fixture.canonicalRepo.path)

        let optedOutID = try await startAgent(
            prepared: prepared,
            parentSessionID: parentID,
            arguments: [
                "op": .string("start"),
                "message": .string("Report the process active root."),
                "inherit_worktree": .bool(false),
                "detach": .bool(true)
            ]
        )
        let optedOutTerminal = await prepared.providerCoordinator.waitAgent(sessionID: optedOutID, timeout: 10)
        XCTAssertEqual(optedOutTerminal.status, .completed)
        XCTAssertEqual(
            try URL(fileURLWithPath: XCTUnwrap(optedOutTerminal.latestAssistantPreview))
                .standardizedFileURL.resolvingSymlinksInPath().path,
            fixture.launchWorktree.path
        )
        let optedOutSnapshot = try await prepared.context.snapshot(
            connectionID: prepared.connectionID,
            sessionID: optedOutID
        )
        XCTAssertEqual(optedOutSnapshot.roots.map(\.path), processRoots.map(\.path))
        XCTAssertEqual(optedOutSnapshot.activeRoot?.path, fixture.launchWorktree.path)
    }

    func testTerminalAgentRecordsRemainTruthfulWithoutSessionStoreSnapshot() async throws {
        let fixture = try await makeSavedWorkspaceWorktreeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = DirectHeadlessMCPService(
            environment: [
                "REPOPROMPT_MCP_HEADLESS_PROFILE": "terminal-reconciliation-test",
                "REPOPROMPT_MCP_HEADLESS_PROFILE_DIR": fixture.profile.path,
                "REPOPROMPT_MCP_WORKING_DIRS": fixture.launchWorktree.path,
                "REPOPROMPT_CODEX_COMMAND": fixture.provider.path,
                "PATH": ProcessInfo.processInfo.environment["PATH"] ?? ""
            ],
            currentDirectory: fixture.launchWorktree
        )
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }

        let failedID = try await startAgent(
            prepared: prepared,
            arguments: [
                "op": .string("start"),
                "message": .string("FAIL deterministically"),
                "detach": .bool(true)
            ]
        )
        let failed = await prepared.providerCoordinator.waitAgent(sessionID: failedID, timeout: 10)
        XCTAssertEqual(failed.status, .failed)

        let cancelledID = try await startAgent(
            prepared: prepared,
            arguments: [
                "op": .string("start"),
                "message": .string("WAIT until cancelled"),
                "detach": .bool(true)
            ]
        )
        await prepared.providerCoordinator.cancelAgent(sessionID: cancelledID)
        let cancelled = await prepared.providerCoordinator.waitAgent(sessionID: cancelledID, timeout: 10)
        XCTAssertEqual(cancelled.status, .cancelled)

        _ = await prepared.runtime.agentSessionStore.shutdown(deadline: .seconds(1))
        let listed = await prepared.providerCoordinator.listAgents()
        let statuses = Dictionary(uniqueKeysWithValues: listed.compactMap { value -> (String, String)? in
            guard let object = value.objectValue,
                  let sessionID = object["session_id"]?.stringValue,
                  let status = object["status"]?.stringValue
            else { return nil }
            return (sessionID, status)
        })
        XCTAssertEqual(statuses[failedID.uuidString], "failed")
        XCTAssertEqual(statuses[cancelledID.uuidString], "cancelled")
        let retainedFailed = await prepared.providerCoordinator.pollAgent(sessionID: failedID, timeout: 0)
        let retainedCancelled = await prepared.providerCoordinator.pollAgent(sessionID: cancelledID, timeout: 0)
        XCTAssertEqual(retainedFailed.status, .failed)
        XCTAssertEqual(retainedCancelled.status, .cancelled)
    }

    func testWorktreeRouteRejectsIncompatibleRebindingAndRootMutationBeforeStateChanges() async throws {
        let fixture = try await makeSavedWorkspaceWorktreeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = DirectHeadlessMCPService(
            environment: [
                "REPOPROMPT_MCP_HEADLESS_PROFILE": "worktree-state-safety-test",
                "REPOPROMPT_MCP_HEADLESS_PROFILE_DIR": fixture.profile.path,
                "REPOPROMPT_MCP_WORKING_DIRS": fixture.launchWorktree.path,
                "REPOPROMPT_CODEX_COMMAND": fixture.provider.path,
                "PATH": ProcessInfo.processInfo.environment["PATH"] ?? ""
            ],
            currentDirectory: fixture.launchWorktree
        )
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }
        let backend = DirectHeadlessGlobalBackend(
            runtime: prepared.runtime,
            scopeID: prepared.scopeID,
            context: prepared.context
        )
        let originalBinding = try await prepared.runtime.standaloneScopeCoordinator.snapshot(
            scopeID: prepared.scopeID
        ).binding
        let unrelatedRoot = fixture.root.appendingPathComponent("unrelated", isDirectory: true)
        try FileManager.default.createDirectory(at: unrelatedRoot, withIntermediateDirectories: true)
        let unrelatedWorkspaceID = UUID()
        let unrelatedContextID = UUID()
        try await createWorkspace(
            makeWorkspaceDocument(
                workspaceID: unrelatedWorkspaceID,
                contextID: unrelatedContextID,
                roots: [unrelatedRoot],
                fileURL: fixture.profile.appendingPathComponent("unrelated.json")
            ),
            in: prepared.runtime
        )
        let bind = try DomainPhysicalToolRequest(
            argumentsJSON: JSONEncoder().encode([
                "op": Value.string("bind"),
                "context_id": .string(unrelatedContextID.uuidString)
            ]),
            securityContext: nil
        )
        do {
            _ = try await backend.routeContext(bind)
            XCTFail("Expected incompatible context rebinding to fail before changing the binding")
        } catch {
            XCTAssertTrue(String(describing: error).contains("rootMappingUnavailable"), String(describing: error))
        }
        let bindingAfterRejectedRebind = try await prepared.runtime.standaloneScopeCoordinator.snapshot(
            scopeID: prepared.scopeID
        ).binding
        XCTAssertEqual(bindingAfterRejectedRebind, originalBinding)

        let security = await DirectHeadlessMCPService.securityContext(
            prepared: prepared,
            connection: DirectHeadlessMCPService.ConnectionContext(
                connectionID: prepared.connectionID,
                connectionGeneration: prepared.connectionGeneration,
                principal: prepared.principal,
                policyProfile: .direct,
                restrictedToolNames: [],
                additionalToolNames: [],
                ephemeralGrantedOperations: []
            ),
            invocationID: UUID()
        )
        let beforeMutationSnapshot = await prepared.runtime.contextStore.workspaceSnapshot(fixture.workspaceID)
        let beforeMutation = try XCTUnwrap(beforeMutationSnapshot).document.documentBytes
        let addFolder = try DomainPhysicalToolRequest(
            argumentsJSON: JSONEncoder().encode([
                "action": Value.string("add_folder"),
                "workspace": .string(fixture.workspaceID.uuidString),
                "folder_path": .string(unrelatedRoot.path)
            ]),
            securityContext: security
        )
        do {
            _ = try await backend.manageWorkspaceLifecycle(addFolder)
            XCTFail("Expected incompatible root mutation to fail before persistence")
        } catch {
            XCTAssertTrue(String(describing: error).contains("rootMappingUnavailable"), String(describing: error))
        }
        let afterMutationSnapshot = await prepared.runtime.contextStore.workspaceSnapshot(fixture.workspaceID)
        XCTAssertEqual(try XCTUnwrap(afterMutationSnapshot).document.documentBytes, beforeMutation)

        let catalogBeforeRejectedCreate = await prepared.runtime.workspaceStore.snapshot()
        let createWorkspace = try DomainPhysicalToolRequest(
            argumentsJSON: JSONEncoder().encode([
                "action": Value.string("create"),
                "name": .string("Rejected physical-root workspace"),
                "folder_path": .string(unrelatedRoot.path),
                "switch_to_created": .bool(false)
            ]),
            securityContext: security
        )
        do {
            _ = try await backend.manageWorkspaceLifecycle(createWorkspace)
            XCTFail("Expected unswitched incompatible workspace creation to fail before persistence")
        } catch {
            XCTAssertTrue(String(describing: error).contains("rootMappingUnavailable"), String(describing: error))
        }
        let catalogAfterRejectedCreate = await prepared.runtime.workspaceStore.snapshot()
        XCTAssertEqual(catalogAfterRejectedCreate.catalogRevision, catalogBeforeRejectedCreate.catalogRevision)
        XCTAssertEqual(catalogAfterRejectedCreate.workspaces.count, catalogBeforeRejectedCreate.workspaces.count)
        let bindingAfterRejectedCreate = try await prepared.runtime.standaloneScopeCoordinator.snapshot(
            scopeID: prepared.scopeID
        ).binding
        XCTAssertEqual(bindingAfterRejectedCreate, originalBinding)
    }

    func testWorktreeRouteRejectsRootlessWorkspaceCreateBeforeCommitForBothSwitchModes() async throws {
        let fixture = try await makeSavedWorkspaceWorktreeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = DirectHeadlessMCPService(
            environment: [
                "REPOPROMPT_MCP_HEADLESS_PROFILE": "worktree-rootless-create-test",
                "REPOPROMPT_MCP_HEADLESS_PROFILE_DIR": fixture.profile.path,
                "REPOPROMPT_MCP_WORKING_DIRS": fixture.launchWorktree.path,
                "REPOPROMPT_CODEX_COMMAND": fixture.provider.path,
                "PATH": ProcessInfo.processInfo.environment["PATH"] ?? ""
            ],
            currentDirectory: fixture.launchWorktree
        )
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }
        let backend = DirectHeadlessGlobalBackend(
            runtime: prepared.runtime,
            scopeID: prepared.scopeID,
            context: prepared.context
        )
        let security = await DirectHeadlessMCPService.securityContext(
            prepared: prepared,
            connection: DirectHeadlessMCPService.ConnectionContext(
                connectionID: prepared.connectionID,
                connectionGeneration: prepared.connectionGeneration,
                principal: prepared.principal,
                policyProfile: .direct,
                restrictedToolNames: [],
                additionalToolNames: [],
                ephemeralGrantedOperations: []
            ),
            invocationID: UUID()
        )
        let originalCatalog = await prepared.runtime.workspaceStore.snapshot()
        let originalBinding = try await prepared.runtime.standaloneScopeCoordinator.snapshot(
            scopeID: prepared.scopeID
        ).binding

        for switchToCreated in [false, true] {
            let request = try DomainPhysicalToolRequest(
                argumentsJSON: JSONEncoder().encode([
                    "action": Value.string("create"),
                    "name": .string("Rejected rootless workspace \(switchToCreated)"),
                    "switch_to_created": .bool(switchToCreated)
                ]),
                securityContext: security
            )
            let controller = DomainMutationCommitController(operation: {
                throw MCPError.internalError("rootless create reached the commit boundary")
            })
            do {
                _ = try await MCPDomainMutationCommitContext.$controller.withValue(controller) {
                    try await backend.manageWorkspaceLifecycle(request)
                }
                XCTFail("Expected rootless workspace creation to fail before persistence")
            } catch {
                XCTAssertTrue(String(describing: error).contains("rootMappingUnavailable"), String(describing: error))
            }
            let catalog = await prepared.runtime.workspaceStore.snapshot()
            XCTAssertEqual(catalog, originalCatalog)
            let binding = try await prepared.runtime.standaloneScopeCoordinator.snapshot(
                scopeID: prepared.scopeID
            ).binding
            XCTAssertEqual(binding, originalBinding)
        }
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
        _ = try await prepared.context.prepareSessionRootOverlay(
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
        let linkedMetadata = fixture.root.appendingPathComponent("linked-git-metadata")
        try originalGitFile.write(to: linkedMetadata)
        try FileManager.default.removeItem(at: gitFile)
        try FileManager.default.createSymbolicLink(at: gitFile, withDestinationURL: linkedMetadata)
        let worktreesAfterSymlink = try await DirectHeadlessWorktreeRouting.listWorktrees(
            repositoryRoot: fixture.canonicalRepo
        )
        XCTAssertFalse(worktreesAfterSymlink.contains { $0.path.path == fixture.alternateWorktree.path })
        try FileManager.default.removeItem(at: gitFile)
        try originalGitFile.write(to: gitFile)

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

        try originalGitFile.write(to: gitFile)
        let replacementRoot = fixture.root.appendingPathComponent("replacement-worktree-root", isDirectory: true)
        try FileManager.default.createDirectory(at: replacementRoot, withIntermediateDirectories: true)
        try originalGitFile.write(to: replacementRoot.appendingPathComponent(".git"))
        try FileManager.default.removeItem(at: fixture.alternateWorktree)
        try FileManager.default.createSymbolicLink(
            at: fixture.alternateWorktree,
            withDestinationURL: replacementRoot
        )
        do {
            _ = try await prepared.context.snapshot(
                connectionID: prepared.connectionID,
                sessionID: sessionID
            )
            XCTFail("Expected a symlink-replaced worktree root to fail closed")
        } catch {
            let message = String(describing: error)
            XCTAssertTrue(
                message.contains("selected worktree identity could not be verified")
                    || message.contains("rootMappingUnavailable"),
                message
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

    private func startAgent(
        prepared: DirectHeadlessMCPService.PreparedRuntime,
        parentSessionID: UUID? = nil,
        arguments: [String: Value]
    ) async throws -> UUID {
        let principal: DomainClientPrincipal = if let parentSessionID {
            DomainClientPrincipal(
                principalID: UUID(),
                stableKey: "test-parent-\(parentSessionID.uuidString)",
                displayName: "Test parent",
                kind: .runScoped,
                assurance: .hostLaunchToken,
                processID: nil,
                runID: parentSessionID,
                provider: "test"
            )
        } else {
            prepared.principal
        }
        let security = await DirectHeadlessMCPService.securityContext(
            prepared: prepared,
            connection: DirectHeadlessMCPService.ConnectionContext(
                connectionID: prepared.connectionID,
                connectionGeneration: prepared.connectionGeneration,
                principal: principal,
                policyProfile: .direct,
                restrictedToolNames: [],
                additionalToolNames: [],
                ephemeralGrantedOperations: []
            ),
            invocationID: UUID()
        )
        let request = try DomainPhysicalToolRequest(
            argumentsJSON: JSONEncoder().encode(arguments),
            securityContext: security
        )
        let value = try await prepared.providerCoordinator.startAgent(
            args: arguments,
            request: request
        )
        return try XCTUnwrap(
            value.objectValue?["session_id"]?.stringValue.flatMap(UUID.init(uuidString:))
        )
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

    private struct WorktreeRepositoryFixture {
        let canonicalRepo: URL
        let launchWorktree: URL
        let alternateWorktree: URL
    }

    private func makeWorktreeRepository(
        in root: URL,
        prefix: String = ""
    ) async throws -> WorktreeRepositoryFixture {
        let stem = prefix.isEmpty ? "" : "\(prefix)-"
        let canonicalRepo = root.appendingPathComponent("\(stem)canonical", isDirectory: true)
        let launchWorktree = root.appendingPathComponent("\(stem)launch-worktree", isDirectory: true)
        let alternateWorktree = root.appendingPathComponent("\(stem)alternate-worktree", isDirectory: true)
        try FileManager.default.createDirectory(at: canonicalRepo, withIntermediateDirectories: true)
        _ = try await DirectProcess.run("/usr/bin/git", arguments: ["-C", canonicalRepo.path, "init", "-b", "main"])
        _ = try await DirectProcess.run("/usr/bin/git", arguments: ["-C", canonicalRepo.path, "config", "user.email", "test@example.invalid"])
        _ = try await DirectProcess.run("/usr/bin/git", arguments: ["-C", canonicalRepo.path, "config", "user.name", "RepoPrompt Tests"])
        try "fixture\n".write(
            to: canonicalRepo.appendingPathComponent("fixture.txt"),
            atomically: true,
            encoding: .utf8
        )
        let packageRoot = canonicalRepo.appendingPathComponent("Packages/App", isDirectory: true)
        try FileManager.default.createDirectory(at: packageRoot, withIntermediateDirectories: true)
        try "app\n".write(
            to: packageRoot.appendingPathComponent("app.txt"),
            atomically: true,
            encoding: .utf8
        )
        _ = try await DirectProcess.run("/usr/bin/git", arguments: ["-C", canonicalRepo.path, "add", "."])
        _ = try await DirectProcess.run("/usr/bin/git", arguments: ["-C", canonicalRepo.path, "commit", "-m", "fixture"])
        _ = try await DirectProcess.run(
            "/usr/bin/git",
            arguments: ["-C", canonicalRepo.path, "worktree", "add", "-b", "route-launch", launchWorktree.path]
        )
        _ = try await DirectProcess.run(
            "/usr/bin/git",
            arguments: ["-C", canonicalRepo.path, "worktree", "add", "-b", "route-alternate", alternateWorktree.path]
        )
        return WorktreeRepositoryFixture(
            canonicalRepo: canonicalRepo.standardizedFileURL.resolvingSymlinksInPath(),
            launchWorktree: launchWorktree.standardizedFileURL.resolvingSymlinksInPath(),
            alternateWorktree: alternateWorktree.standardizedFileURL.resolvingSymlinksInPath()
        )
    }

    private func makeSavedWorkspaceWorktreeFixture(
        workspaceRelativeRoot: String? = nil,
        selectedPaths: [String] = []
    ) async throws -> SavedWorkspaceWorktreeFixture {
        let root = temporaryDirectory("saved-workspace-worktree")
        let profile = root.appendingPathComponent("profile", isDirectory: true)
        let workspaceDirectory = profile.appendingPathComponent("Workspaces", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDirectory, withIntermediateDirectories: true)
        let repository = try await makeWorktreeRepository(in: root)
        let canonicalRepo = repository.canonicalRepo
        let launchWorktree = repository.launchWorktree
        let alternateWorktree = repository.alternateWorktree
        let workspaceRoot = workspaceRelativeRoot.map {
            canonicalRepo.appendingPathComponent($0, isDirectory: true)
        } ?? canonicalRepo

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
            roots: [workspaceRoot],
            fileURL: workspaceURL,
            selectedPaths: selectedPaths.map { path in
                path.hasPrefix("/") ? path : canonicalRepo.appendingPathComponent(path).path
            }
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
        input=$(cat)
        case "$input" in
          *FAIL*) exit 7 ;;
          *WAIT*) sleep 5 ;;
        esac
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
        fileURL: URL,
        selectedPaths: [String] = []
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
                    "selectedPaths": selectedPaths
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
