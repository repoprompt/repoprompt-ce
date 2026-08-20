import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

#if DEBUG
    @MainActor
    final class MCPProtectedMutationInvocationIntegrationTests: XCTestCase {
        func testPromptStateMutationsCommitWithoutPhysicalPathAdmission() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await makeFixture(lease: lease)
                let endpoint = try fixture.endpointA()
                let manager = fixture.networkManager
                do {
                    try await registerDomainWorkspace(fixture.contextA)
                    await manager.debugSetDomainPeerIdentityForTesting(
                        connectionID: endpoint.connectionID,
                        identity: .verified(processID: Int(getpid()), fingerprint: "test:verified:prompt-state")
                    )
                    try await bind(endpoint, to: fixture.contextA)

                    let runtime = AppDomainRuntimeComposition.shared.runtime
                    var journalKeys = try await Set(runtime.mutationJournal.snapshot().recordSnapshots.map(\.key))
                    let preset = fixture.contextA.window.promptManager.currentCopyPreset()
                    let mutations: [(toolName: String, action: String, arguments: [String: Any])] = [
                        ("prompt", "set", ["op": "set", "text": "alpha"]),
                        ("prompt", "append", ["op": "append", "text": " beta"]),
                        ("prompt", "clear", ["op": "clear"]),
                        ("prompt", "select_preset", ["op": "select_preset", "preset": preset.id.uuidString]),
                        ("workspace_context", "select_preset", ["op": "select_preset", "preset": preset.id.uuidString])
                    ]

                    for (index, mutation) in mutations.enumerated() {
                        var arguments = mutation.arguments
                        arguments["operation_id"] = "prompt-state-\(index)"
                        let response = try await endpoint.callTool(name: mutation.toolName, arguments: arguments)
                        let result = try toolResult(response)
                        XCTAssertFalse(result.isError, "\(mutation.toolName).\(mutation.action): \(result.text)")
                        let capture = try await captureJournalRecord(
                            runtime: runtime,
                            excluding: journalKeys,
                            toolName: mutation.toolName,
                            action: mutation.action
                        )
                        journalKeys = capture.allKeys
                        XCTAssertEqual(capture.record.status.rawValue, DomainMutationJournalStatus.applied.rawValue)
                        XCTAssertNil(capture.record.pathFence)
                    }
                    XCTAssertEqual(fixture.contextA.window.promptManager.promptText, "")

                    await manager.debugSetDomainPeerIdentityForTesting(connectionID: endpoint.connectionID, identity: nil)
                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    await manager.debugSetDomainPeerIdentityForTesting(connectionID: endpoint.connectionID, identity: nil)
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testFileActionRevalidatesFenceAfterCommitAtBlockingIOBoundary() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await makeFixture(lease: lease)
                let endpoint = try fixture.endpointA()
                let manager = fixture.networkManager
                let store = fixture.contextA.window.workspaceFileContextStore
                let parent = fixture.contextA.rootURL.appendingPathComponent("late-swap-parent", isDirectory: true)
                let outside = fixture.rootURL.appendingPathComponent("late-swap-outside", isDirectory: true)
                let target = parent.appendingPathComponent("nested/blocked.txt")
                let escapedTarget = outside.appendingPathComponent("nested/blocked.txt")
                let swap = MutationBoundarySwapRecorder()
                do {
                    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
                    try await store.startWatchingRoot(id: fixture.contextA.rootID)
                    let loadedService = await store.fileSystemServiceForTesting(rootID: fixture.contextA.rootID)
                    let service = try XCTUnwrap(loadedService)
                    await service.setMutationIOWillExecuteHandlerForTesting { operation in
                        guard operation == .create else { return }
                        swap.perform {
                            try FileManager.default.removeItem(at: parent)
                            try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: outside)
                        }
                    }

                    try await registerDomainWorkspace(fixture.contextA)
                    await manager.debugSetDomainPeerIdentityForTesting(
                        connectionID: endpoint.connectionID,
                        identity: .verified(processID: Int(getpid()), fingerprint: "test:verified:late-fence")
                    )
                    try await bind(endpoint, to: fixture.contextA)
                    let runtime = AppDomainRuntimeComposition.shared.runtime
                    let journalKeys = try await Set(runtime.mutationJournal.snapshot().recordSnapshots.map(\.key))

                    let response = try await endpoint.callTool(
                        name: "file_actions",
                        arguments: [
                            "action": "create",
                            "path": target.path,
                            "content": "must not escape",
                            "operation_id": "late-fence-swap"
                        ]
                    )
                    let result = try toolResult(response)
                    XCTAssertTrue(result.isError, result.text)
                    XCTAssertTrue(swap.didPerform)
                    XCTAssertNil(swap.error)
                    XCTAssertFalse(FileManager.default.fileExists(atPath: escapedTarget.path))
                    let capture = try await captureJournalRecord(
                        runtime: runtime,
                        excluding: journalKeys,
                        toolName: "file_actions",
                        action: "create"
                    )
                    XCTAssertEqual(
                        capture.record.status.rawValue,
                        DomainMutationJournalStatus.indeterminateAfterCommit.rawValue
                    )

                    await service.setMutationIOWillExecuteHandlerForTesting(nil)
                    try? FileManager.default.removeItem(at: parent)
                    try? FileManager.default.removeItem(at: outside)
                    await manager.debugSetDomainPeerIdentityForTesting(connectionID: endpoint.connectionID, identity: nil)
                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    if let service = await store.fileSystemServiceForTesting(rootID: fixture.contextA.rootID) {
                        await service.setMutationIOWillExecuteHandlerForTesting(nil)
                    }
                    try? FileManager.default.removeItem(at: parent)
                    try? FileManager.default.removeItem(at: outside)
                    await manager.debugSetDomainPeerIdentityForTesting(connectionID: endpoint.connectionID, identity: nil)
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testRunScopedInvocationUsesAuthoritativeRegistrationAndVerifiedIdentity() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await makeFixture(lease: lease)
                let endpoint = try fixture.endpointA()
                let manager = fixture.networkManager
                do {
                    try await registerDomainWorkspace(fixture.contextA)
                    await manager.debugSetDomainPeerIdentityForTesting(
                        connectionID: endpoint.connectionID,
                        identity: .verified(processID: Int(getpid()), fingerprint: "test:verified:app")
                    )
                    try await bind(endpoint, to: fixture.contextA)
                    let initial = try await authoritativeContext(
                        manager: manager,
                        endpoint: endpoint,
                        toolName: "manage_selection"
                    )

                    _ = await AppDomainRuntimeComposition.shared.runtime.routingCoordinator.registerConnection(
                        connectionID: endpoint.connectionID,
                        operationID: UUID()
                    )
                    let reRegistered = await manager.debugDomainInvocationSecurityContextForTesting(
                        connectionID: endpoint.connectionID,
                        toolName: "manage_selection"
                    )
                    XCTAssertGreaterThan(reRegistered.connectionGeneration, initial.connectionGeneration)
                    XCTAssertFalse(reRegistered.hasAuthoritativeRoutingContext)
                    XCTAssertTrue(reRegistered.authorizedCanonicalRoots.isEmpty)

                    let currentRegistration = try await AppDomainRuntimeComposition.shared.runtime
                        .routingCoordinator.currentRegistration(connectionID: endpoint.connectionID)
                    let reboundOutcome = await AppDomainRuntimeComposition.shared.runtime.routingCoordinator.bind(
                        connection: currentRegistration,
                        binding: .context(
                            .init(
                                workspaceID: fixture.contextA.workspaceID,
                                contextID: fixture.contextA.tabID
                            ),
                            explicit: true
                        ),
                        operationID: UUID()
                    )
                    XCTAssertEqual(reboundOutcome.disposition, .applied)
                    let rebound = try await authoritativeContext(
                        manager: manager,
                        endpoint: endpoint,
                        toolName: "manage_selection"
                    )
                    XCTAssertEqual(rebound.workspaceID, fixture.contextA.workspaceID)
                    XCTAssertTrue(rebound.authorizedCanonicalRoots.contains(fixture.contextA.rootURL.path))

                    await manager.setRunPurpose(.agentModeRun, for: endpoint.connectionID)
                    await manager.debugSetDomainPeerIdentityForTesting(
                        connectionID: endpoint.connectionID,
                        identity: .unverified
                    )
                    let denied = try await endpoint.callTool(
                        name: "manage_selection",
                        arguments: ["op": "clear"]
                    )
                    let deniedResult = try toolResult(denied)
                    XCTAssertTrue(deniedResult.isError)
                    XCTAssertTrue(deniedResult.text.contains("principalUnverified"), deniedResult.text)

                    await manager.debugSetDomainPeerIdentityForTesting(
                        connectionID: endpoint.connectionID,
                        identity: .verified(processID: Int(getpid()), fingerprint: "test:verified:app")
                    )
                    let allowed = try await endpoint.callTool(
                        name: "manage_selection",
                        arguments: ["op": "clear"]
                    )
                    XCTAssertFalse(try toolResult(allowed).isError)

                    await manager.debugSetDomainPeerIdentityForTesting(
                        connectionID: endpoint.connectionID,
                        identity: nil
                    )
                    await manager.setRunPurpose(.unknown, for: endpoint.connectionID)
                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    await manager.debugSetDomainPeerIdentityForTesting(
                        connectionID: endpoint.connectionID,
                        identity: nil
                    )
                    await manager.setRunPurpose(.unknown, for: endpoint.connectionID)
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testCorrelationReuseExportEscapeAndBoundWorktreeTranslationCrossAppProvider() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await makeFixture(lease: lease)
                let endpoint = try fixture.endpointA()
                let manager = fixture.networkManager
                let repo = fixture.contextA.rootURL
                let worktree = fixture.rootURL.appendingPathComponent("bound-worktree", isDirectory: true)
                var worktreeCreated = false
                var physicalRootID: UUID?
                let sessionID = UUID()
                do {
                    try await registerDomainWorkspace(fixture.contextA)
                    let workspace = try XCTUnwrap(
                        fixture.contextA.window.workspaceManager.workspaces.first {
                            $0.id == fixture.contextA.workspaceID
                        }
                    )
                    await fixture.contextA.window.workspaceManager.switchWorkspace(
                        to: workspace,
                        saveState: false,
                        reason: "MCPProtectedMutationInvocationIntegrationTests"
                    )
                    let activeWorkspace = try XCTUnwrap(fixture.contextA.window.workspaceManager.activeWorkspace)
                    fixture.contextA.window.promptManager.loadComposeTabsFromWorkspace(
                        activeWorkspace,
                        syncPromptText: true
                    )
                    try initializeGitRepository(at: repo)
                    await manager.debugSetDomainPeerIdentityForTesting(
                        connectionID: endpoint.connectionID,
                        identity: .verified(processID: Int(getpid()), fingerprint: "test:verified:worktree")
                    )
                    try await bind(endpoint, to: fixture.contextA)
                    let initialSecurityContext = try await authoritativeContext(
                        manager: manager,
                        endpoint: endpoint,
                        toolName: "file_actions"
                    )
                    let runtime = AppDomainRuntimeComposition.shared.runtime
                    var journalKeys = try await Set(
                        runtime.mutationJournal.snapshot().recordSnapshots.map(\.key)
                    )
                    let sharedCorrelationID = "shared-correlation-id"

                    let firstLogical = repo.appendingPathComponent("CorrelationOne.txt")
                    let firstResponse = try await endpoint.callTool(
                        name: "file_actions",
                        arguments: [
                            "action": "create",
                            "path": firstLogical.path,
                            "content": "one",
                            "operation_id": sharedCorrelationID
                        ]
                    )
                    XCTAssertFalse(try toolResult(firstResponse).isError)
                    let firstCapture = try await captureJournalRecord(
                        runtime: runtime,
                        excluding: journalKeys,
                        toolName: "file_actions",
                        action: "create"
                    )
                    journalKeys = firstCapture.allKeys
                    assertDurableRequestKey(
                        firstCapture.record,
                        endpoint: endpoint,
                        connectionGeneration: initialSecurityContext.connectionGeneration,
                        operationID: sharedCorrelationID
                    )

                    _ = await runtime.routingCoordinator.registerConnection(
                        connectionID: endpoint.connectionID,
                        operationID: UUID()
                    )
                    try await bind(endpoint, to: fixture.contextA)
                    let routingProbe = try await endpoint.callTool(
                        name: "get_file_tree",
                        arguments: ["type": "roots"]
                    )
                    XCTAssertFalse(try toolResult(routingProbe).isError)
                    let reboundSecurityContext = try await authoritativeContext(
                        manager: manager,
                        endpoint: endpoint,
                        toolName: "file_actions"
                    )
                    XCTAssertGreaterThan(
                        reboundSecurityContext.connectionGeneration,
                        initialSecurityContext.connectionGeneration
                    )

                    let secondLogical = repo.appendingPathComponent("CorrelationTwo.txt")
                    let secondResponse = try await endpoint.callTool(
                        name: "file_actions",
                        arguments: [
                            "action": "create",
                            "path": secondLogical.path,
                            "content": "two",
                            "operation_id": sharedCorrelationID
                        ]
                    )
                    XCTAssertFalse(try toolResult(secondResponse).isError)
                    let secondCapture = try await captureJournalRecord(
                        runtime: runtime,
                        excluding: journalKeys,
                        toolName: "file_actions",
                        action: "create"
                    )
                    journalKeys = secondCapture.allKeys
                    assertDurableRequestKey(
                        secondCapture.record,
                        endpoint: endpoint,
                        connectionGeneration: reboundSecurityContext.connectionGeneration,
                        operationID: sharedCorrelationID
                    )
                    XCTAssertNotEqual(firstCapture.record.key, secondCapture.record.key)

                    let thirdLogical = repo.appendingPathComponent("CorrelationThree.txt")
                    let thirdResponse = try await endpoint.callTool(
                        name: "file_actions",
                        arguments: [
                            "action": "create",
                            "path": thirdLogical.path,
                            "content": "three",
                            "operation_id": sharedCorrelationID
                        ]
                    )
                    XCTAssertFalse(try toolResult(thirdResponse).isError)
                    let thirdCapture = try await captureJournalRecord(
                        runtime: runtime,
                        excluding: journalKeys,
                        toolName: "file_actions",
                        action: "create"
                    )
                    journalKeys = thirdCapture.allKeys
                    assertDurableRequestKey(
                        thirdCapture.record,
                        endpoint: endpoint,
                        connectionGeneration: reboundSecurityContext.connectionGeneration,
                        operationID: sharedCorrelationID
                    )
                    XCTAssertNotEqual(secondCapture.record.key, thirdCapture.record.key)
                    XCTAssertEqual(try String(contentsOf: firstLogical, encoding: .utf8), "one")
                    XCTAssertEqual(try String(contentsOf: secondLogical, encoding: .utf8), "two")
                    XCTAssertEqual(try String(contentsOf: thirdLogical, encoding: .utf8), "three")

                    await manager.setRunPurpose(.agentModeRun, for: endpoint.connectionID)
                    for toolName in ["prompt", "workspace_context"] {
                        let escapedExport = fixture.rootURL.appendingPathComponent(
                            "outside-workspace-\(toolName)-export.md"
                        )
                        let exportResponse = try await endpoint.callTool(
                            name: toolName,
                            arguments: ["op": "export", "path": escapedExport.path]
                        )
                        let exportResult = try toolResult(exportResponse)
                        XCTAssertTrue(exportResult.isError)
                        XCTAssertFalse(FileManager.default.fileExists(atPath: escapedExport.path))
                    }
                    await manager.setRunPurpose(.unknown, for: endpoint.connectionID)

                    let session = fixture.contextA.window.agentModeViewModel.session(for: fixture.contextA.tabID)
                    _ = fixture.contextA.window.agentModeViewModel.test_installPersistentSessionBinding(
                        sessionID: sessionID,
                        on: session,
                        updateWorkspaceMetadata: true
                    )
                    let create = try await endpoint.callTool(
                        name: "manage_worktree",
                        arguments: [
                            "op": "create",
                            "repo_root": repo.path,
                            "path": worktree.path,
                            "branch": "test/protected-mutation-\(UUID().uuidString.lowercased())",
                            "base_ref": "HEAD",
                            "allow_external_path": true,
                            "operation_id": sharedCorrelationID
                        ]
                    )
                    XCTAssertFalse(try toolResult(create).isError)
                    let worktreeCapture = try await captureJournalRecord(
                        runtime: runtime,
                        excluding: journalKeys,
                        toolName: "manage_worktree",
                        action: "create"
                    )
                    journalKeys = worktreeCapture.allKeys
                    assertDurableRequestKey(
                        worktreeCapture.record,
                        endpoint: endpoint,
                        connectionGeneration: reboundSecurityContext.connectionGeneration,
                        operationID: sharedCorrelationID
                    )
                    worktreeCreated = true
                    let testBinding = AgentSessionWorktreeBinding(
                        id: "test-binding-\(UUID().uuidString)",
                        repositoryID: repo.path,
                        repoKey: repo.path,
                        logicalRootPath: repo.path,
                        worktreeID: worktree.path,
                        worktreeRootPath: worktree.path,
                        worktreeName: worktree.lastPathComponent,
                        branch: nil,
                        head: nil,
                        source: "m4-integration-test"
                    )
                    session.worktreeBindings = [testBinding]
                    let materializer = WorkspaceRootBindingProjectionMaterializer(
                        store: fixture.contextA.window.workspaceFileContextStore
                    )
                    let preparation = try await materializer.prepare(
                        sessionID: sessionID,
                        bindings: [testBinding]
                    )
                    let committedProjection = try await materializer.commit(preparation)
                    let projection = try XCTUnwrap(committedProjection)
                    physicalRootID = projection.physicalRootRefs.first?.id
                    let lookupContext = WorkspaceLookupContext(
                        rootScope: projection.lookupRootScope,
                        bindingProjection: projection
                    )
                    let frozen = MCPServerViewModel.TabContextSnapshot(
                        tabID: fixture.contextA.tabID,
                        windowID: fixture.contextA.window.windowID,
                        workspaceID: fixture.contextA.workspaceID,
                        promptText: "",
                        selection: StoredSelection(),
                        selectedMetaPromptIDs: [],
                        tabName: "M4 bound worktree",
                        runID: sessionID,
                        activeAgentSessionID: sessionID,
                        worktreeBindings: [testBinding],
                        frozenLookupContext: lookupContext,
                        explicitlyBound: true
                    )
                    _ = fixture.contextA.window.mcpServer.installFrozenTabContext(
                        clientID: endpoint.connectionID.uuidString,
                        clientName: endpoint.clientName,
                        context: frozen
                    )
                    await manager.debugSeedConnectionRunRouting(
                        connectionID: endpoint.connectionID,
                        runID: sessionID,
                        purpose: .agentModeRun,
                        windowID: fixture.contextA.window.windowID
                    )
                    let registration = try await AppDomainRuntimeComposition.shared.runtime
                        .routingCoordinator.currentRegistration(connectionID: endpoint.connectionID)
                    _ = await AppDomainRuntimeComposition.shared.runtime.routingCoordinator.bind(
                        connection: registration,
                        binding: .runScoped(
                            runID: sessionID,
                            context: .init(
                                workspaceID: fixture.contextA.workspaceID,
                                contextID: fixture.contextA.tabID
                            )
                        ),
                        operationID: UUID()
                    )

                    let logicalTarget = fixture.contextA.fileURL
                    let relativeTarget = String(logicalTarget.path.dropFirst(repo.path.count))
                        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    let physicalTarget = worktree.appendingPathComponent(relativeTarget)
                    let replacement = "let translatedProtectedMutation = true"
                    let translated = try await endpoint.callTool(
                        name: "apply_edits",
                        arguments: [
                            "path": logicalTarget.path,
                            "search": fixture.contextA.sentinel,
                            "replace": replacement,
                            "operation_id": sharedCorrelationID
                        ]
                    )
                    let translatedResult = try toolResult(translated)
                    XCTAssertFalse(translatedResult.isError)
                    let applyEditsCapture = try await captureJournalRecord(
                        runtime: runtime,
                        excluding: journalKeys,
                        toolName: "apply_edits",
                        action: "replace"
                    )
                    journalKeys = applyEditsCapture.allKeys
                    assertDurableRequestKey(
                        applyEditsCapture.record,
                        endpoint: endpoint,
                        connectionGeneration: reboundSecurityContext.connectionGeneration,
                        operationID: sharedCorrelationID
                    )
                    XCTAssertEqual(
                        Set([
                            firstCapture.record.key,
                            secondCapture.record.key,
                            thirdCapture.record.key,
                            worktreeCapture.record.key,
                            applyEditsCapture.record.key
                        ]).count,
                        5
                    )
                    let logicalContents = try String(contentsOf: logicalTarget, encoding: .utf8)
                    let physicalContents = try String(contentsOf: physicalTarget, encoding: .utf8)
                    XCTAssertTrue(logicalContents.contains(fixture.contextA.sentinel))
                    XCTAssertFalse(logicalContents.contains(replacement))
                    XCTAssertTrue(
                        physicalContents.contains(replacement),
                        "apply_edits result=\(translatedResult.text) physical=\(physicalContents)"
                    )

                    session.worktreeBindings = []
                    await WorkspaceRootBindingProjectionMaterializer(
                        store: fixture.contextA.window.workspaceFileContextStore
                    ).release(sessionID: sessionID)
                    if let physicalRootID {
                        await fixture.contextA.window.workspaceFileContextStore.unloadRoot(id: physicalRootID)
                    }
                    try removeWorktreeIfPresent(worktree, from: repo)
                    worktreeCreated = false
                    await manager.debugSetDomainPeerIdentityForTesting(connectionID: endpoint.connectionID, identity: nil)
                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    await manager.setRunPurpose(.unknown, for: endpoint.connectionID)
                    await manager.debugSetDomainPeerIdentityForTesting(connectionID: endpoint.connectionID, identity: nil)
                    await WorkspaceRootBindingProjectionMaterializer(
                        store: fixture.contextA.window.workspaceFileContextStore
                    ).release(sessionID: sessionID)
                    if let physicalRootID {
                        await fixture.contextA.window.workspaceFileContextStore.unloadRoot(id: physicalRootID)
                    }
                    if worktreeCreated {
                        try? removeWorktreeIfPresent(worktree, from: repo)
                    }
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        private func makeFixture(
            lease: MCPSharedServerTestLease.Ownership
        ) async throws -> PersistentMCPTestFixture {
            try await PersistentMCPTestFixture.make(
                lease: lease,
                domainRuntime: AppDomainRuntimeComposition.shared.runtime
            )
        }

        private func captureJournalRecord(
            runtime: MCPDomainRuntime,
            excluding priorKeys: Set<String>,
            toolName: String,
            action: String
        ) async throws -> (record: DomainMutationJournalRecord, allKeys: Set<String>) {
            let document = try await runtime.mutationJournal.snapshot()
            let matches = document.recordSnapshots.filter {
                !priorKeys.contains($0.key) && $0.toolName == toolName && $0.action == action
            }
            let allKeys = Set(document.recordSnapshots.map(\.key))
            XCTAssertEqual(matches.count, 1, "new journal records=\(allKeys.sorted())")
            return try (XCTUnwrap(matches.first), allKeys)
        }

        private func assertDurableRequestKey(
            _ record: DomainMutationJournalRecord,
            endpoint: PersistentMCPTestEndpoint,
            connectionGeneration: UInt64,
            operationID: String,
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            let requestKey = [
                "v1",
                endpoint.connectionID.uuidString.lowercased(),
                String(connectionGeneration),
                record.ownerInvocationID.uuidString.lowercased()
            ].joined(separator: ":")
            XCTAssertEqual(
                record.key,
                "\(record.toolName).\(record.action):request:\(requestKey)",
                file: file,
                line: line
            )
            XCTAssertEqual(record.operationID, operationID, file: file, line: line)
            XCTAssertEqual(
                record.status.rawValue,
                DomainMutationJournalStatus.applied.rawValue,
                file: file,
                line: line
            )
        }

        private func registerDomainWorkspace(_ context: PersistentMCPTestContext) async throws {
            let workspace = try XCTUnwrap(
                context.window.workspaceManager.workspaces.first { $0.id == context.workspaceID }
            )
            let client = DomainWorkspaceAuthorityClient(
                store: AppDomainRuntimeComposition.shared.runtime.workspaceStore,
                windowID: context.window.windowID
            )
            _ = try await client.registerForRead(
                workspace,
                fileURL: context.rootURL.appendingPathComponent("fixture.repoprompt-workspace")
            )
        }

        private func bind(
            _ endpoint: PersistentMCPTestEndpoint,
            to context: PersistentMCPTestContext
        ) async throws {
            let workspace = try XCTUnwrap(
                context.window.workspaceManager.workspaces.first { $0.id == context.workspaceID }
            )
            await context.window.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "MCPProtectedMutationInvocationIntegrationTests"
            )
            context.window.promptManager.loadComposeTabsFromWorkspace(
                workspace,
                syncPromptText: true
            )
            let response = try await endpoint.callTool(
                name: "bind_context",
                arguments: ["op": "bind", "context_id": context.tabID.uuidString]
            )
            let result = try toolResult(response)
            XCTAssertFalse(result.isError, result.text)
            await context.window.mcpServer.domainRoutingPublishTask?.value
        }

        private func authoritativeContext(
            manager: ServerNetworkManager,
            endpoint: PersistentMCPTestEndpoint,
            toolName: String
        ) async throws -> DomainToolInvocationSecurityContext {
            let context = await manager.debugDomainInvocationSecurityContextForTesting(
                connectionID: endpoint.connectionID,
                toolName: toolName
            )
            guard context.hasAuthoritativeRoutingContext, context.workspaceID != nil,
                  !context.authorizedCanonicalRoots.isEmpty
            else {
                throw NSError(
                    domain: "MCPProtectedMutationInvocationIntegrationTests",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "domain routing context was not authoritative after binding publication completed"]
                )
            }
            return context
        }

        private func toolResult(_ response: PersistentMCPTestRPCResponse) throws -> (isError: Bool, text: String) {
            let data = try XCTUnwrap(response.rawJSON.data(using: .utf8))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual((object["id"] as? NSNumber)?.intValue, response.id)
            XCTAssertNil(object["error"])
            let result = try XCTUnwrap(object["result"] as? [String: Any])
            let content = try XCTUnwrap(result["content"] as? [[String: Any]])
            return (
                result["isError"] as? Bool == true,
                content.compactMap { $0["text"] as? String }.joined()
            )
        }

        private func initializeGitRepository(at repo: URL) throws {
            try runGit(["init"], cwd: repo)
            try runGit(["config", "user.name", "RepoPrompt Test"], cwd: repo)
            try runGit(["config", "user.email", "repoprompt@example.test"], cwd: repo)
            try runGit(["config", "commit.gpgSign", "false"], cwd: repo)
            try runGit(["checkout", "-b", "main"], cwd: repo)
            try runGit(["add", "."], cwd: repo)
            try runGit(["commit", "-m", "Initial fixture"], cwd: repo)
        }

        private func removeWorktreeIfPresent(_ worktree: URL, from repo: URL) throws {
            guard FileManager.default.fileExists(atPath: worktree.path) else { return }
            try runGit(["worktree", "remove", "--force", worktree.path], cwd: repo)
        }

        private func runGit(_ arguments: [String], cwd: URL) throws {
            var environment = ProcessInfo.processInfo.environment
            environment["GIT_CONFIG_NOSYSTEM"] = "1"
            environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
            environment["GIT_TERMINAL_PROMPT"] = "0"
            let result = try TestProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/git"),
                arguments: arguments,
                currentDirectoryURL: cwd,
                environment: environment
            )
            guard result.terminationStatus == 0 else {
                throw NSError(
                    domain: "MCPProtectedMutationInvocationIntegrationTests.git",
                    code: Int(result.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: result.outputText]
                )
            }
        }
    }

    private final class MutationBoundarySwapRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storedDidPerform = false
        private var storedError: (any Error)?

        var didPerform: Bool {
            lock.lock()
            defer { lock.unlock() }
            return storedDidPerform
        }

        var error: (any Error)? {
            lock.lock()
            defer { lock.unlock() }
            return storedError
        }

        func perform(_ operation: @Sendable () throws -> Void) {
            lock.lock()
            guard !storedDidPerform else {
                lock.unlock()
                return
            }
            storedDidPerform = true
            lock.unlock()
            do {
                try operation()
            } catch {
                lock.lock()
                storedError = error
                lock.unlock()
            }
        }
    }
#endif
