import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptFoundation
@testable import RepoPromptWorkspaceContext
import XCTest

#if DEBUG
    @MainActor
    final class MCPReadAutoSelectionRecoveryIntegrationTests: XCTestCase {
        func testFileActionsCreatePreservesNewerBoundSelectionAndForegroundSlices() async throws {
            try await assertCreatedFileUsesLatestBoundSelection(toolName: MCPWindowToolName.fileActions)
        }

        func testApplyEditsCreatePreservesBoundSelectionAndForegroundSlices() async throws {
            try await assertCreatedFileUsesLatestBoundSelection(toolName: MCPWindowToolName.applyEdits)
        }

        func testApplyEditsDisconnectReleasesPrepublicationCodemapFence() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(
                    lease: lease,
                    domainRuntime: AppDomainRuntimeComposition.shared.runtime
                )
                let context = fixture.contextA
                let store = context.window.workspaceFileContextStore
                let cleanupGate = TestReleaseFence(name: "store-owned CodeMap cleanup during edit resolution")
                let target = context.rootURL.appendingPathComponent("Uncatalogued.swift")
                var endpoints: [PersistentMCPTestEndpoint] = []
                do {
                    try await fixture.registerDomainWorkspace(context)
                    try await Self.activateWorkspace(context)
                    let fileSystemService = await store.fileSystemServiceForTesting(rootID: context.rootID)
                    let service = try XCTUnwrap(fileSystemService)
                    try "Uncatalogued.swift\n".write(
                        to: context.rootURL.appendingPathComponent(".repo_ignore"), atomically: true, encoding: .utf8
                    )
                    try await service.updateRespectRepoIgnore(true)
                    try await service.refreshIgnoreRules()
                    try "let target = 1\n".write(to: target, atomically: true, encoding: .utf8)

                    let caller = try await Self.makeBoundEndpoint(
                        label: "uncatalogued-edit", fixture: fixture, requiredToolNames: [MCPWindowToolName.applyEdits]
                    )
                    endpoints.append(caller)
                    let survivor = try await Self.makeBoundEndpoint(
                        label: "same-root-edit", fixture: fixture, requiredToolNames: [MCPWindowToolName.applyEdits]
                    )
                    endpoints.append(survivor)
                    let input = try WorkspaceExactFileInput.parse(target.path)
                    let roots = await store.rootRefs(scope: .visibleWorkspace)
                    _ = try await store.awaitAppliedIngressForExplicitRequest(
                        input, namespace: .identity(roots: roots), timeout: .seconds(10)
                    )
                    let before = await store.file(rootID: context.rootID, relativePath: target.lastPathComponent)
                    XCTAssertNil(before)
                    let installed = await store.installCodemapCleanupFlightForTesting(rootID: context.rootID) {
                        await cleanupGate.enterAndWait()
                    }
                    XCTAssertTrue(installed)
                    guard await cleanupGate.waitUntilEntered() else {
                        throw CocoaError(.fileReadUnknown)
                    }

                    // A catalogued file can resolve and reach the edit engine while cleanup is held.
                    let temporarySentinel = "let catalogueControl = true"
                    let control = try await survivor.callTool(
                        name: MCPWindowToolName.applyEdits,
                        arguments: [
                            "path": context.fileURL.path,
                            "edits": [
                                ["search": context.sentinel, "replace": temporarySentinel],
                                ["search": temporarySentinel, "replace": context.sentinel]
                            ]
                        ]
                    )
                    XCTAssertFalse(control.rawJSON.contains("\"isError\":true"), control.rawJSON)
                    XCTAssertTrue(try Self.toolResultText(control).contains("no net change"))
                    XCTAssertEqual(try String(contentsOf: context.fileURL, encoding: .utf8), "\(context.sentinel)\n")

                    let pending = Task {
                        try await caller.callTool(
                            name: MCPWindowToolName.applyEdits,
                            arguments: ["path": target.path, "search": "target = 1", "replace": "target = 2"]
                        )
                    }
                    defer { pending.cancel() }
                    try await AsyncTestWait.waitUntil("exact materialization joins the gated cleanup", timeout: 10) {
                        await store.codemapCleanupWaiterCountForTesting(rootID: context.rootID) == 1
                    }
                    let fenceHeld = await store.codemapRootMutationFenceIsHeldForTesting(rootID: context.rootID)
                    XCTAssertTrue(fenceHeld)
                    let recordDuringWait = await store.file(rootID: context.rootID, relativePath: target.lastPathComponent)
                    XCTAssertNil(recordDuringWait)
                    XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "let target = 1\n")
                    caller.client.close()
                    try await AsyncTestWait.waitUntil("disconnect releases the root fence before cleanup ends", timeout: 10) {
                        await !store.codemapRootMutationFenceIsHeldForTesting(rootID: context.rootID)
                    }
                    let cleanupStillPending = await store.codemapCleanupIsPendingForTesting(rootID: context.rootID)
                    XCTAssertTrue(cleanupStillPending)
                    let recordAfterDisconnect = await store.file(rootID: context.rootID, relativePath: target.lastPathComponent)
                    XCTAssertNil(recordAfterDisconnect)
                    XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "let target = 1\n")

                    cleanupGate.release()
                    _ = try? await pending.value
                    try await AsyncTestWait.waitUntil("store-owned CodeMap cleanup drains", timeout: 10) {
                        await !store.codemapCleanupIsPendingForTesting(rootID: context.rootID)
                    }
                    let retry = try await survivor.callTool(
                        name: MCPWindowToolName.applyEdits,
                        arguments: ["path": target.path, "search": "target = 1", "replace": "target = 2"]
                    )
                    XCTAssertFalse(retry.rawJSON.contains("\"isError\":true"), retry.rawJSON)
                    XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "let target = 2\n")
                    for endpoint in endpoints {
                        await Self.cleanupEndpoint(endpoint, manager: fixture.networkManager)
                    }
                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    cleanupGate.release()
                    for endpoint in endpoints {
                        await Self.cleanupEndpoint(endpoint, manager: fixture.networkManager)
                    }
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        private func assertCreatedFileUsesLatestBoundSelection(toolName: String) async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(
                    lease: lease,
                    domainRuntime: AppDomainRuntimeComposition.shared.runtime
                )
                let context = fixture.contextA
                let manager = context.window.workspaceManager
                let server = context.window.mcpServer
                let coordinator = context.window.selectionCoordinator
                let identity = WorkspaceSelectionIdentity(workspaceID: context.workspaceID, tabID: context.tabID)
                let addedElsewhere = context.rootURL.appendingPathComponent("AddedElsewhere.swift")
                let foregroundFile = context.rootURL.appendingPathComponent("Foreground.swift")
                let manualCodemap = context.rootURL.appendingPathComponent("ManualCodemap.swift")
                let createdFile = context.rootURL.appendingPathComponent("CreatedByMCP.swift")
                var endpoint: PersistentMCPTestEndpoint?
                do {
                    for file in [addedElsewhere, foregroundFile, manualCodemap] {
                        _ = try await context.window.workspaceFileContextStore.createFile(
                            rootID: context.rootID,
                            relativePath: file.lastPathComponent,
                            content: "let first = 1\nlet second = 2\n"
                        )
                    }
                    try await fixture.registerDomainWorkspace(context)
                    try await Self.activateWorkspace(context)
                    let initial = StoredSelection(
                        selectedPaths: [context.fileURL.path],
                        manualCodemapPaths: [manualCodemap.path],
                        slices: [context.fileURL.path: [LineRange(start: 1, end: 1)]],
                        codemapAutoEnabled: false
                    )
                    _ = await coordinator.persistSelection(initial, for: identity, source: .mcpTabContext)
                    let caller = try await Self.makeBoundEndpoint(
                        label: "create-\(toolName)",
                        fixture: fixture,
                        requiredToolNames: [toolName]
                    )
                    endpoint = caller
                    let background = await context.window.promptManager.createBackgroundComposeTab(
                        strategy: .blank, name: "Foreground"
                    )
                    let foreground = try XCTUnwrap(background)
                    await context.window.promptManager.switchComposeTab(foreground.id)
                    let foregroundIdentity = WorkspaceSelectionIdentity(
                        workspaceID: context.workspaceID, tabID: foreground.id
                    )
                    let foregroundSelection = StoredSelection(
                        selectedPaths: [foregroundFile.path],
                        slices: [foregroundFile.path: [LineRange(start: 2, end: 2)]],
                        codemapAutoEnabled: false
                    )
                    _ = await coordinator.persistSelection(
                        foregroundSelection, for: foregroundIdentity, source: .mcpTabContext
                    )
                    let foregroundUIPaths = Set(context.window.workspaceFilesViewModel.selectedFiles.map(\.fullPath))

                    var latest = try XCTUnwrap(manager.composeTab(for: identity))
                    latest.selection = StoredSelection(
                        selectedPaths: [context.fileURL.path, addedElsewhere.path],
                        manualCodemapPaths: initial.manualCodemapPaths,
                        slices: initial.slices,
                        codemapAutoEnabled: false
                    )
                    XCTAssertTrue(manager.updateComposeTabStoredOnly(latest, inWorkspaceID: context.workspaceID))
                    XCTAssertFalse(try XCTUnwrap(
                        server.runRouteBindings.tabContextByConnectionID[caller.connectionID]
                    ).selection.selectedPaths.contains(addedElsewhere.path))

                    let arguments: [String: Any] = toolName == MCPWindowToolName.fileActions
                        ? ["action": "create", "path": createdFile.path, "content": "let created = true\n"]
                        : ["path": createdFile.path, "rewrite": "let created = true\n", "on_missing": "create"]
                    let reply = try await caller.callTool(name: toolName, arguments: arguments)
                    XCTAssertFalse(reply.rawJSON.contains("\"isError\":true"), reply.rawJSON)
                    let text = try Self.toolResultText(reply)
                    XCTAssertFalse(text.contains("not confirmed"), text)
                    XCTAssertEqual(try String(contentsOf: createdFile, encoding: .utf8), "let created = true\n")
                    let expected = StoredSelection(
                        selectedPaths: latest.selection.selectedPaths + [createdFile.path],
                        manualCodemapPaths: initial.manualCodemapPaths,
                        slices: initial.slices,
                        codemapAutoEnabled: false
                    )
                    XCTAssertEqual(try XCTUnwrap(manager.composeTab(for: identity)).selection, expected)
                    XCTAssertEqual(
                        try XCTUnwrap(manager.composeTab(for: foregroundIdentity)).selection,
                        foregroundSelection
                    )
                    XCTAssertEqual(manager.activeWorkspace?.activeComposeTabID, foreground.id)
                    XCTAssertEqual(
                        Set(context.window.workspaceFilesViewModel.selectedFiles.map(\.fullPath)),
                        foregroundUIPaths
                    )
                    XCTAssertEqual(
                        server.runRouteBindings.tabContextByConnectionID[caller.connectionID]?.selection,
                        expected
                    )
                    await Self.cleanupEndpoint(caller, manager: fixture.networkManager)
                    endpoint = nil
                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    if let endpoint { await Self.cleanupEndpoint(endpoint, manager: fixture.networkManager) }
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testCreatedFileSelectionRejectsReboundConnectionWithoutRedirectingOrRemovingFile() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(
                    lease: lease,
                    domainRuntime: AppDomainRuntimeComposition.shared.runtime
                )
                let context = fixture.contextA
                let server = context.window.mcpServer
                let manager = context.window.workspaceManager
                var endpoint: PersistentMCPTestEndpoint?
                do {
                    try await fixture.registerDomainWorkspace(context)
                    try await Self.activateWorkspace(context)
                    let caller = try await Self.makeBoundEndpoint(label: "rebound-create", fixture: fixture)
                    endpoint = caller
                    let metadata = MCPServerViewModel.RequestMetadata(
                        connectionID: caller.connectionID, clientName: nil, windowID: context.window.windowID
                    )
                    let (resolved, lookup) = try await server.resolveMutationFileToolContext(
                        route: server.routeResources,
                        from: metadata,
                        toolName: MCPWindowToolName.fileActions
                    )
                    let createdPath = context.rootURL.appendingPathComponent("CreatedBeforeRebind.swift")
                    _ = try await context.window.workspaceFileContextStore.createFile(
                        rootID: context.rootID,
                        relativePath: createdPath.lastPathComponent,
                        content: "let durable = true\n"
                    )
                    let record = await context.window.workspaceFileContextStore.lookupFiles(
                        atPaths: [createdPath.path], rootScope: lookup.rootScope
                    )[createdPath.path]
                    let file = try XCTUnwrap(record)
                    let createdTab = await context.window.promptManager.createBackgroundComposeTab(
                        strategy: .blank, name: "Replacement binding"
                    )
                    let replacement = try XCTUnwrap(createdTab)
                    await context.window.promptManager.switchComposeTab(replacement.id)
                    try server.bindTabForConnection(
                        route: server.routeResources,
                        connectionID: caller.connectionID,
                        clientName: caller.clientName,
                        tabID: replacement.id,
                        workspaceID: context.workspaceID,
                        windowID: context.window.windowID
                    )
                    let originalIdentity = WorkspaceSelectionIdentity(
                        workspaceID: context.workspaceID, tabID: context.tabID
                    )
                    let replacementIdentity = WorkspaceSelectionIdentity(
                        workspaceID: context.workspaceID, tabID: replacement.id
                    )
                    let originalSelection = try XCTUnwrap(manager.composeTab(for: originalIdentity)).selection
                    let replacementSelection = try XCTUnwrap(manager.composeTab(for: replacementIdentity)).selection
                    let warning = await server.selectCreatedFile(
                        route: server.routeResources,
                        file,
                        resolvedContext: resolved,
                        metadata: metadata,
                        lookupContext: lookup
                    )
                    XCTAssertTrue(try XCTUnwrap(warning).contains("selection was not confirmed"))
                    XCTAssertEqual(try String(contentsOf: createdPath, encoding: .utf8), "let durable = true\n")
                    XCTAssertEqual(try XCTUnwrap(manager.composeTab(for: originalIdentity)).selection, originalSelection)
                    XCTAssertEqual(try XCTUnwrap(manager.composeTab(for: replacementIdentity)).selection, replacementSelection)
                    XCTAssertEqual(manager.activeWorkspace?.activeComposeTabID, replacement.id)
                    await Self.cleanupEndpoint(caller, manager: fixture.networkManager)
                    endpoint = nil
                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    if let endpoint { await Self.cleanupEndpoint(endpoint, manager: fixture.networkManager) }
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testBackgroundReadSelectionDoesNotBlockLaterDrainsOrChangeForegroundSelection() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(
                    lease: lease,
                    domainRuntime: AppDomainRuntimeComposition.shared.runtime
                )
                let context = fixture.contextA
                let server = context.window.mcpServer
                let manager = context.window.workspaceManager
                var endpoint: PersistentMCPTestEndpoint?
                do {
                    try await fixture.registerDomainWorkspace(context)
                    try await Self.activateWorkspace(context)
                    let caller = try await Self.makeBoundEndpoint(label: "background-reader", fixture: fixture)
                    endpoint = caller
                    _ = try await caller.callTool(name: MCPWindowToolName.manageSelection, arguments: ["op": "clear"])
                    let created = await context.window.promptManager.createBackgroundComposeTab(strategy: .blank, name: "Foreground")
                    let foreground = try XCTUnwrap(created)
                    await context.window.promptManager.switchComposeTab(foreground.id)
                    let foregroundSelection = Set(context.window.workspaceFilesViewModel.selectedFiles.map(\.fullPath))
                    XCTAssertFalse(foregroundSelection.contains(context.fileURL.path))

                    let read = try await caller.callTool(
                        name: MCPWindowToolName.readFile,
                        arguments: ["path": context.fileURL.path]
                    )
                    XCTAssertFalse(read.rawJSON.contains("\"isError\":true"), read.rawJSON)
                    let metadata = MCPServerViewModel.RequestMetadata(
                        connectionID: caller.connectionID, clientName: nil, windowID: context.window.windowID
                    )
                    let firstDrain = try await server.drainReadFileAutoSelection(route: server.routeResources, metadata: metadata, requirement: .mirroredSelectionAndMetrics)
                    XCTAssertEqual(firstDrain, .completed)
                    let identity = WorkspaceSelectionIdentity(workspaceID: context.workspaceID, tabID: context.tabID)
                    XCTAssertTrue(try XCTUnwrap(manager.composeTab(for: identity)).selection.selectedPaths.contains(context.fileURL.path))
                    let add = try await caller.callTool(
                        name: MCPWindowToolName.manageSelection,
                        arguments: ["op": "add", "paths": [context.fileURL.path]]
                    )
                    XCTAssertFalse(add.rawJSON.contains("\"isError\":true"), add.rawJSON)
                    XCTAssertEqual(manager.activeWorkspace?.activeComposeTabID, foreground.id)
                    XCTAssertEqual(Set(context.window.workspaceFilesViewModel.selectedFiles.map(\.fullPath)), foregroundSelection)

                    await context.window.promptManager.switchComposeTab(context.tabID)
                    XCTAssertTrue(context.window.workspaceFilesViewModel.selectedFiles.contains { $0.fullPath == context.fileURL.path })
                    await Self.cleanupEndpoint(caller, manager: fixture.networkManager)
                    endpoint = nil
                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    if let endpoint { await Self.cleanupEndpoint(endpoint, manager: fixture.networkManager) }
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testParkedMirrorConnectionRemovalPreservesSameWindowOwnerAndSelectionMutations() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(
                    lease: lease,
                    domainRuntime: AppDomainRuntimeComposition.shared.runtime
                )
                let manager = fixture.networkManager
                let server = fixture.contextA.window.mcpServer
                let mirrorGate = MCPExecutionIgnoringCancellationGate()
                let secondRelativePath = "Sources/RecoverySurvivor.swift"
                let secondURL = fixture.contextA.rootURL.appendingPathComponent(secondRelativePath)
                var removedEndpoint: PersistentMCPTestEndpoint?
                var survivorEndpoint: PersistentMCPTestEndpoint?
                var firstReadTask: Task<PersistentMCPTestRPCResponse, Error>?

                _ = try await fixture.contextA.window.workspaceFileContextStore.createFile(
                    rootID: fixture.contextA.rootID,
                    relativePath: secondRelativePath,
                    content: SwiftFixtureSource.emptyStruct("RecoverySurvivor")
                )
                do {
                    try await fixture.registerDomainWorkspace(fixture.contextA)
                    try await Self.activateWorkspace(fixture.contextA)
                    let first = try await Self.makeBoundEndpoint(
                        label: "parked-owner",
                        fixture: fixture
                    )
                    removedEndpoint = first
                    let survivor = try await Self.makeBoundEndpoint(
                        label: "surviving-owner",
                        fixture: fixture
                    )
                    survivorEndpoint = survivor

                    _ = try await survivor.callTool(
                        name: MCPWindowToolName.manageSelection,
                        arguments: ["op": "clear"]
                    )
                    server.setReadFileAutoSelectionMirrorGateForTesting {
                        await mirrorGate.enterAndWait()
                    }
                    let activeFirstReadTask = Task {
                        try await first.callTool(
                            name: MCPWindowToolName.readFile,
                            arguments: ["path": fixture.contextA.fileURL.path]
                        )
                    }
                    firstReadTask = activeFirstReadTask
                    try await mirrorGate.waitUntilEntered(count: 1)

                    let removalTask = Task {
                        await manager.removeConnection(first.connectionID)
                    }
                    await mirrorGate.release()
                    await removalTask.value
                    _ = try? await activeFirstReadTask.value
                    firstReadTask = nil
                    removedEndpoint = nil
                    XCTAssertNil(server.runRouteBindings.tabContextByConnectionID[first.connectionID])
                    XCTAssertEqual(
                        server.runRouteBindings.tabContextByConnectionID[survivor.connectionID]?.tabID,
                        fixture.contextA.tabID
                    )

                    server.setReadFileAutoSelectionMirrorGateForTesting(nil)
                    let add = try await survivor.callTool(
                        name: MCPWindowToolName.manageSelection,
                        arguments: [
                            "op": "add",
                            "paths": [secondURL.path],
                            "view": "files"
                        ]
                    )
                    XCTAssertFalse(add.rawJSON.contains("\"isError\":true"), add.rawJSON)
                    let get = try await survivor.callTool(
                        name: MCPWindowToolName.manageSelection,
                        arguments: ["op": "get", "view": "files"]
                    )
                    let text = try Self.toolResultText(get)
                    XCTAssertTrue(text.contains(fixture.contextA.fileURL.lastPathComponent), text)
                    XCTAssertTrue(text.contains(secondURL.lastPathComponent), text)
                    XCTAssertEqual(
                        Set(server.runRouteBindings.tabContextByConnectionID[survivor.connectionID]?.selection.selectedPaths ?? []),
                        Set([fixture.contextA.fileURL.path, secondURL.path])
                    )

                    await Self.cleanupEndpoint(survivor, manager: manager)
                    survivorEndpoint = nil
                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    firstReadTask?.cancel()
                    await mirrorGate.release()
                    server.setReadFileAutoSelectionMirrorGateForTesting(nil)
                    if let firstReadTask { _ = try? await firstReadTask.value }
                    if let removedEndpoint { await Self.cleanupEndpoint(removedEndpoint, manager: manager) }
                    if let survivorEndpoint { await Self.cleanupEndpoint(survivorEndpoint, manager: manager) }
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        private static func makeBoundEndpoint(
            label: String,
            fixture: PersistentMCPTestFixture,
            requiredToolNames: Set<String> = [MCPWindowToolName.readFile, MCPWindowToolName.manageSelection]
        ) async throws -> PersistentMCPTestEndpoint {
            let manager = fixture.networkManager
            let clientName = "read-recovery-\(label)-\(UUID().uuidString)"
            let endpoint = try await PersistentMCPTestEndpoint.make(
                label: label,
                networkManager: manager,
                clientName: clientName,
                requiredToolNames: requiredToolNames
            )
            await manager.debugSetDomainPeerIdentityForTesting(
                connectionID: endpoint.connectionID,
                identity: .verified(
                    processID: Int(getpid()),
                    fingerprint: "test:verified:read-auto-selection-recovery"
                )
            )
            let bind = try await endpoint.callTool(
                name: "bind_context",
                arguments: ["op": "bind", "context_id": fixture.contextA.tabID.uuidString]
            )
            XCTAssertFalse(bind.rawJSON.contains("\"isError\":true"), bind.rawJSON)
            await fixture.contextA.window.mcpServer.routeResources.settleRoutingPublications()
            return endpoint
        }

        private static func activateWorkspace(_ context: PersistentMCPTestContext) async throws {
            let manager = context.window.workspaceManager
            let workspace = try XCTUnwrap(
                manager.workspaces.first { $0.id == context.workspaceID }
            )
            await manager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "MCPReadAutoSelectionRecoveryIntegrationTests"
            )
            await manager.waitUntilPostSwitchGitDataLoadComplete()
            let activeWorkspace = try XCTUnwrap(manager.activeWorkspace)
            XCTAssertEqual(activeWorkspace.id, context.workspaceID)
            context.window.promptManager.loadComposeTabsFromWorkspace(
                activeWorkspace,
                syncPromptText: true
            )
        }

        private static func cleanupEndpoint(
            _ endpoint: PersistentMCPTestEndpoint,
            manager: ServerNetworkManager
        ) async {
            await manager.debugSetDomainPeerIdentityForTesting(
                connectionID: endpoint.connectionID,
                identity: nil
            )
            endpoint.client.close()
            await endpoint.connectionManager.stop()
            await manager.debugRemoveConnection(endpoint.connectionID)
            await manager.clearClientConnectionPolicy(for: endpoint.clientName)
            await manager.debugClearPersistedRoutingState(for: endpoint.clientName)
        }

        private static func toolResultText(_ response: PersistentMCPTestRPCResponse) throws -> String {
            let object = try MCPExportWatchdogIntegrationTests.responseObject(from: response)
            let result = try XCTUnwrap(object["result"] as? [String: Any])
            let content = try XCTUnwrap(result["content"] as? [[String: Any]])
            return try XCTUnwrap(content.first?["text"] as? String)
        }
    }
#endif
