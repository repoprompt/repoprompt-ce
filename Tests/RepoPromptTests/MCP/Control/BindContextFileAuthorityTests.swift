import Darwin
import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

#if DEBUG
    final class BindContextFileAuthorityTests: XCTestCase {
        @MainActor
        func testBindStoresAuthorityConsumedByNextFileOperation() async throws {
            let fixture = try await makeFixture(rootPaths: [makeTemporaryRoot().path])
            let authority = try await fixture.window.mcpServer.resolveFileToolAuthority(
                tabID: fixture.contextID,
                workspaceID: fixture.workspace.id
            )

            try fixture.window.mcpServer.bindTabForConnection(
                connectionID: fixture.connectionID,
                clientName: "BindContextFileAuthorityTests",
                tabID: fixture.contextID,
                workspaceID: fixture.workspace.id,
                windowID: fixture.window.windowID,
                frozenFileToolAuthority: authority
            )
            let consumed = try await fixture.window.mcpServer.requiredFileToolLookupContext(
                from: metadata(for: fixture)
            )

            XCTAssertTrue(authority.hasSameRoutingAuthority(as: consumed))
            XCTAssertEqual(consumed.lookupContext, authority.lookupContext)
        }

        @MainActor
        func testRepeatedBindRefreshesStoredAuthorityWithoutChangingRoute() async throws {
            let fixture = try await makeFixture(rootPaths: [makeTemporaryRoot().path])
            let first = try await fixture.window.mcpServer.resolveFileToolAuthority(
                tabID: fixture.contextID,
                workspaceID: fixture.workspace.id
            )
            try fixture.window.mcpServer.bindTabForConnection(
                connectionID: fixture.connectionID,
                clientName: nil,
                tabID: fixture.contextID,
                workspaceID: fixture.workspace.id,
                windowID: fixture.window.windowID,
                frozenFileToolAuthority: first
            )
            fixture.window.workspaceManager.republishReadyRootCatalogWithNextGenerationForTesting()
            let refreshed = try await fixture.window.mcpServer.resolveFileToolAuthority(
                tabID: fixture.contextID,
                workspaceID: fixture.workspace.id
            )

            fixture.window.mcpServer.updateBoundFileToolAuthority(
                connectionID: fixture.connectionID,
                tabID: fixture.contextID,
                workspaceID: fixture.workspace.id,
                authority: refreshed
            )
            let consumed = try await fixture.window.mcpServer.requiredFileToolLookupContext(
                from: metadata(for: fixture)
            )

            XCTAssertTrue(refreshed.hasSameRoutingAuthority(as: consumed))
            XCTAssertFalse(first.hasSameRoutingAuthority(as: consumed))
        }

        @MainActor
        func testFailedReplacementPreservesPriorBinding() async throws {
            let fixture = try await makeFixture(rootPaths: [makeTemporaryRoot().path])
            let authority = try await fixture.window.mcpServer.resolveFileToolAuthority(
                tabID: fixture.contextID,
                workspaceID: fixture.workspace.id
            )
            try fixture.window.mcpServer.bindTabForConnection(
                connectionID: fixture.connectionID,
                clientName: nil,
                tabID: fixture.contextID,
                workspaceID: fixture.workspace.id,
                windowID: fixture.window.windowID,
                frozenFileToolAuthority: authority
            )
            let prior = fixture.window.mcpServer.connectionBindingSnapshot(
                forConnection: fixture.connectionID
            )

            XCTAssertThrowsError(try fixture.window.mcpServer.bindTabForConnection(
                connectionID: fixture.connectionID,
                clientName: nil,
                tabID: UUID(),
                workspaceID: UUID(),
                windowID: fixture.window.windowID,
                frozenFileToolAuthority: authority
            ))

            let retained = fixture.window.mcpServer.connectionBindingSnapshot(
                forConnection: fixture.connectionID
            )
            XCTAssertEqual(retained.windowID, prior.windowID)
            XCTAssertEqual(retained.workspaceID, prior.workspaceID)
            XCTAssertEqual(retained.tabID, prior.tabID)
            XCTAssertEqual(retained.explicitlyBound, prior.explicitlyBound)
        }

        @MainActor
        func testSupersededCatalogRejectsPreviouslyIssuedAuthority() async throws {
            let fixture = try await makeFixture(rootPaths: [makeTemporaryRoot().path])
            let authority = try await fixture.window.mcpServer.resolveFileToolAuthority(
                tabID: fixture.contextID,
                workspaceID: fixture.workspace.id
            )
            fixture.window.workspaceManager.republishReadyRootCatalogWithNextGenerationForTesting()

            do {
                try await authority.validate(
                    workspaceManager: fixture.window.workspaceManager,
                    store: fixture.window.promptManager.workspaceFileContextStore
                )
                XCTFail("A superseded readiness ticket must not remain usable")
            } catch let failure as MCPServerViewModel.FileToolAuthorityFailure {
                XCTAssertEqual(failure, .superseded)
            }

            var enteredCommit = false
            let performed = try await fixture.window.mcpServer.performIfFileToolAuthorityIsCurrent(
                authority,
                tabID: fixture.contextID,
                workspaceID: fixture.workspace.id
            ) {
                enteredCommit = true
            }
            XCTAssertFalse(performed)
            XCTAssertFalse(enteredCommit)
        }

        @MainActor
        func testCanonicalRootMutationAfterCaptureRejectsAuthority() async throws {
            let fixture = try await makeFixture(rootPaths: [makeTemporaryRoot().path])
            let authority = try await fixture.window.mcpServer.resolveFileToolAuthority(
                tabID: fixture.contextID,
                workspaceID: fixture.workspace.id
            )
            let additionalRoot = try makeTemporaryRoot()
            let loaded = try await fixture.window.promptManager.workspaceFileContextStore.loadRoot(
                path: additionalRoot.path,
                kind: .primaryWorkspace
            )
            addTeardownBlock {
                await fixture.window.promptManager.workspaceFileContextStore.unloadRoot(id: loaded.id)
            }

            do {
                try await authority.validate(
                    workspaceManager: fixture.window.workspaceManager,
                    store: fixture.window.promptManager.workspaceFileContextStore
                )
                XCTFail("A changed canonical root set must invalidate captured authority")
            } catch let failure as MCPServerViewModel.FileToolAuthorityFailure {
                XCTAssertEqual(failure, .mismatchedProjection)
            }
        }

        @MainActor
        func testAffinityFailurePreservesPriorBindingAndAuthority() async throws {
            let prior = try await makeFixture(rootPaths: [makeTemporaryRoot().path])
            let replacement = try await makeFixture(rootPaths: [makeTemporaryRoot().path])
            let priorAuthority = try await prior.window.mcpServer.resolveFileToolAuthority(
                tabID: prior.contextID,
                workspaceID: prior.workspace.id
            )
            try prior.window.mcpServer.bindTabForConnection(
                connectionID: prior.connectionID,
                clientName: nil,
                tabID: prior.contextID,
                workspaceID: prior.workspace.id,
                windowID: prior.window.windowID,
                frozenFileToolAuthority: priorAuthority
            )
            let replacementAuthority = try await replacement.window.mcpServer.resolveFileToolAuthority(
                tabID: replacement.contextID,
                workspaceID: replacement.workspace.id
            )
            let previousWindows = WindowStatesManager.shared.allWindows
            WindowStatesManager.shared.allWindows = [prior.window, replacement.window]
            addTeardownBlock { @MainActor in
                WindowStatesManager.shared.allWindows = previousWindows
            }
            let service = WindowRoutingService(
                windowStates: WindowStatesManager.shared,
                networkMgr: ServerNetworkManager.shared,
                setActiveWindowForCurrentConnection: { _ in throw AffinityFailure.injected }
            )

            do {
                _ = try await service.test_bindTarget(
                    windowID: replacement.window.windowID,
                    workspaceID: replacement.workspace.id,
                    tabID: replacement.contextID,
                    repoPaths: replacement.workspace.repoPaths,
                    connectionID: prior.connectionID,
                    authority: replacementAuthority
                )
                XCTFail("The injected affinity failure must reject replacement")
            } catch {
                XCTAssertTrue(error is AffinityFailure)
            }

            let retained = prior.window.mcpServer.connectionBindingSnapshot(forConnection: prior.connectionID)
            XCTAssertEqual(retained.windowID, prior.window.windowID)
            XCTAssertEqual(retained.workspaceID, prior.workspace.id)
            XCTAssertEqual(retained.tabID, prior.contextID)
            let consumed = try await prior.window.mcpServer.requiredFileToolLookupContext(from: metadata(for: prior))
            XCTAssertTrue(priorAuthority.hasSameRoutingAuthority(as: consumed))
            XCTAssertNil(replacement.window.mcpServer.boundTabID(forConnection: prior.connectionID))
        }

        @MainActor
        func testSupersededBindPreservesPriorNetworkAffinityAndBinding() async throws {
            let prior = try await makeFixture(rootPaths: [makeTemporaryRoot().path])
            let replacement = try await makeFixture(rootPaths: [makeTemporaryRoot().path])
            let priorAuthority = try await prior.window.mcpServer.resolveFileToolAuthority(
                tabID: prior.contextID, workspaceID: prior.workspace.id
            )
            try prior.window.mcpServer.bindTabForConnection(
                connectionID: prior.connectionID, clientName: nil, tabID: prior.contextID,
                workspaceID: prior.workspace.id, windowID: prior.window.windowID,
                frozenFileToolAuthority: priorAuthority
            )
            let replacementAuthority = try await replacement.window.mcpServer.resolveFileToolAuthority(
                tabID: replacement.contextID, workspaceID: replacement.workspace.id
            )
            let previousWindows = WindowStatesManager.shared.allWindows
            WindowStatesManager.shared.allWindows = [prior.window, replacement.window]
            let gate = RootHydrationSuspensionGate()
            replacement.window.mcpServer.setAfterFileToolLookupContextRootValidationForTesting {
                await gate.hold()
            }
            let network = ServerNetworkManager.shared
            addTeardownBlock { @MainActor in
                await gate.release()
                replacement.window.mcpServer.setAfterFileToolLookupContextRootValidationForTesting(nil)
                WindowStatesManager.shared.allWindows = previousWindows
                await network.debugRemoveConnection(prior.connectionID)
            }
            try await ServerNetworkManager.$currentConnectionID.withValue(prior.connectionID) {
                try await network.setActiveWindowForCurrentConnection(prior.window.windowID)
            }
            let service = WindowRoutingService(windowStates: WindowStatesManager.shared, networkMgr: network)
            let bind = Task { @MainActor in
                try await ServerNetworkManager.$currentConnectionID.withValue(prior.connectionID) {
                    try await service.test_bindTarget(
                        windowID: replacement.window.windowID, workspaceID: replacement.workspace.id,
                        tabID: replacement.contextID, repoPaths: replacement.workspace.repoPaths,
                        connectionID: prior.connectionID, authority: replacementAuthority
                    )
                }
            }
            await gate.waitUntilHeld()
            let whilePending = await network.selectedWindow(for: prior.connectionID)
            XCTAssertEqual(whilePending, prior.window.windowID, "Unvalidated affinity must not be published")
            replacement.window.workspaceManager.republishReadyRootCatalogWithNextGenerationForTesting()
            await gate.release()
            do {
                _ = try await bind.value
                XCTFail("Superseded authority must reject replacement")
            } catch {}
            let retainedWindow = await network.selectedWindow(for: prior.connectionID)
            XCTAssertEqual(retainedWindow, prior.window.windowID)
            XCTAssertEqual(prior.window.mcpServer.boundTabID(forConnection: prior.connectionID), prior.contextID)
            XCTAssertNil(replacement.window.mcpServer.boundTabID(forConnection: prior.connectionID))
            let consumed = try await prior.window.mcpServer.requiredFileToolLookupContext(from: metadata(for: prior))
            XCTAssertTrue(priorAuthority.hasSameRoutingAuthority(as: consumed))

            // A failed transaction must settle and permit a subsequent valid replacement.
            replacement.window.mcpServer.setAfterFileToolLookupContextRootValidationForTesting(nil)
            let refreshed = try await replacement.window.mcpServer.resolveFileToolAuthority(
                tabID: replacement.contextID, workspaceID: replacement.workspace.id
            )
            let changed = try await ServerNetworkManager.$currentConnectionID.withValue(prior.connectionID) {
                try await service.test_bindTarget(
                    windowID: replacement.window.windowID, workspaceID: replacement.workspace.id,
                    tabID: replacement.contextID, repoPaths: replacement.workspace.repoPaths,
                    connectionID: prior.connectionID, authority: refreshed
                )
            }
            XCTAssertTrue(changed)
            let finalWindow = await network.selectedWindow(for: prior.connectionID)
            XCTAssertEqual(finalWindow, replacement.window.windowID)
            XCTAssertNil(prior.window.mcpServer.boundTabID(forConnection: prior.connectionID))
            XCTAssertEqual(replacement.window.mcpServer.boundTabID(forConnection: prior.connectionID), replacement.contextID)
        }

        @MainActor
        func testCancelledAffinityTransactionDoesNotStrandQueuedSelectionOrClear() async throws {
            let network = ServerNetworkManager.shared
            let connectionID = UUID()
            let gate = RootHydrationSuspensionGate()
            addTeardownBlock {
                await gate.release()
                await network.debugRemoveConnection(connectionID)
            }
            let first = Task { @MainActor in
                try await ServerNetworkManager.$currentConnectionID.withValue(connectionID) {
                    try await network.withValidatedWindowBinding(windowID: 101, connectionID: connectionID) {
                        await gate.hold()
                        try Task.checkCancellation()
                        return true
                    }
                }
            }
            await gate.waitUntilHeld()
            let mutexValue = await network.debugWindowBindingMutexForTesting(connectionID: connectionID)
            let mutex = try XCTUnwrap(mutexValue)
            let enqueued = expectation(description: "second affinity transaction queued")
            await mutex.setDidEnqueueWaiterForTesting { enqueued.fulfill() }
            let cancelledSettled = expectation(description: "queued cancellation settled before predecessor release")
            var didCancel = false
            let cancelled = Task { @MainActor in
                defer { cancelledSettled.fulfill() }
                do {
                    try await ServerNetworkManager.$currentConnectionID.withValue(connectionID) {
                        try await network.setActiveWindowForCurrentConnection(202)
                    }
                    XCTFail("Canceled queued transaction must not publish")
                } catch is CancellationError {
                    didCancel = true
                }
            }
            await fulfillment(of: [enqueued], timeout: 5)
            cancelled.cancel()
            await fulfillment(of: [cancelledSettled], timeout: 5)
            XCTAssertTrue(didCancel, "Cancellation must settle while the predecessor remains held")
            let beforeRelease = await network.selectedWindow(for: connectionID)
            XCTAssertNil(beforeRelease)
            await mutex.setDidEnqueueWaiterForTesting(nil)
            await gate.release()
            let firstChanged = try await first.value
            XCTAssertTrue(firstChanged)
            try await cancelled.value
            let predecessorSelection = await network.selectedWindow(for: connectionID)
            XCTAssertEqual(predecessorSelection, 101)
            try await ServerNetworkManager.$currentConnectionID.withValue(connectionID) {
                try await network.setActiveWindowForCurrentConnection(303)
            }
            let selected = await network.selectedWindow(for: connectionID)
            XCTAssertEqual(selected, 303)
            try await ServerNetworkManager.$currentConnectionID.withValue(connectionID) {
                try await network.clearActiveWindowForCurrentConnection()
            }
            let cleared = await network.selectedWindow(for: connectionID)
            XCTAssertNil(cleared)
        }

        @MainActor
        func testQueuedAutoSelectionRejectsSupersededAuthorityWithoutChangingCodemapPolicy() async throws {
            try await assertSupersededAutoSelectionPreservesStoredSelection(atCommitBoundary: false)
        }

        @MainActor
        func testAutoSelectionFinalCommitRejectsSupersededAuthority() async throws {
            try await assertSupersededAutoSelectionPreservesStoredSelection(atCommitBoundary: true)
        }

        @MainActor
        private func assertSupersededAutoSelectionPreservesStoredSelection(atCommitBoundary: Bool) async throws {
            let root = try makeTemporaryRoot()
            let path = root.appendingPathComponent("Sentinel.swift")
            try "struct Sentinel {}\n".write(to: path, atomically: true, encoding: .utf8)
            let fixture = try await makeFixture(rootPaths: [root.path])
            let server = fixture.window.mcpServer
            let authority = try await server.resolveFileToolAuthority(
                tabID: fixture.contextID, workspaceID: fixture.workspace.id
            )
            try server.bindTabForConnection(
                connectionID: fixture.connectionID, clientName: nil, tabID: fixture.contextID,
                workspaceID: fixture.workspace.id, windowID: fixture.window.windowID,
                frozenFileToolAuthority: authority
            )
            let context = try XCTUnwrap(server.tabContextByConnectionID[fixture.connectionID])
            let key = MCPReadFileAutoSelectionCoordinator.ContextKey(
                windowID: fixture.window.windowID, workspaceID: fixture.workspace.id,
                tabID: fixture.contextID, route: .bound(connectionID: fixture.connectionID, runID: nil),
                bindingGeneration: context.readFileAutoSelectionGeneration
            )
            let identity = WorkspaceSelectionIdentity(workspaceID: fixture.workspace.id, tabID: fixture.contextID)
            let manager = fixture.window.workspaceManager
            var tab = try XCTUnwrap(manager.composeTab(for: identity))
            tab.selection = StoredSelection(selectedPaths: [], codemapAutoEnabled: true)
            XCTAssertTrue(manager.updateComposeTabStoredOnly(tab, inWorkspaceID: fixture.workspace.id))
            let prior = tab.selection
            let coordinator = server.readFileAutoSelectionCoordinator
            let gate = RootHydrationSuspensionGate()
            if atCommitBoundary {
                let selectionCoordinator = try XCTUnwrap(server.selectionCoordinator)
                selectionCoordinator.beforeAuthorizedCommitForTesting = { await gate.hold() }
            } else {
                server.setReadFileAutoSelectionCanonicalApplyGateForTesting { await gate.hold() }
            }
            addTeardownBlock { @MainActor in
                await gate.release()
                server.setReadFileAutoSelectionCanonicalApplyGateForTesting(nil)
                server.selectionCoordinator?.beforeAuthorizedCommitForTesting = nil
            }
            XCTAssertTrue(coordinator.enqueue(
                intent: .full(paths: [path.path], automaticCodemapDisposition: .disableAutomaticPreservingManual),
                authority: authority, for: key
            ))
            await gate.waitUntilHeld()
            manager.republishReadyRootCatalogWithNextGenerationForTesting()
            XCTAssertTrue(server.isReadFileAutoSelectionContextCurrent(key), "Tab identity deliberately stays unchanged")
            await gate.release()
            let result = await coordinator.drain(.canonicalSelection, for: key)
            XCTAssertEqual(result, .completed)
            XCTAssertEqual(manager.composeTab(for: identity)?.selection, prior)
            let settled = try XCTUnwrap(coordinator.debugContextSnapshot(for: key))
            XCTAssertEqual(settled.acceptedHighWaterSequence, settled.completedHighWaterSequence)
            XCTAssertFalse(settled.pendingWork)
            XCTAssertEqual(settled.waiterCount, 0)
            XCTAssertEqual(settled.changedApplyCount, 0)
        }

        @MainActor
        func testAutoSelectionFinalCommitRejectsRetiredPhysicalRootLifetime() async throws {
            let fixture = try await makeFixture(rootPaths: [makeTemporaryRoot().path])
            let server = fixture.window.mcpServer
            let canonical = try await server.resolveFileToolAuthority(
                tabID: fixture.contextID, workspaceID: fixture.workspace.id
            )
            let store = fixture.window.workspaceFileContextStore
            let physicalURL = try makeTemporaryRoot()
            let physicalRecord = try await store.loadRoot(path: physicalURL.path, kind: .sessionWorktree)
            let physicalValue = await store.exactRootRef(path: physicalURL.path, kind: .sessionWorktree)
            let physical = try XCTUnwrap(physicalValue)
            let logical = try XCTUnwrap(canonical.canonicalRoots.first)
            let projection = WorkspaceRootBindingProjection(
                sessionID: UUID(),
                boundRoots: [.init(
                    logicalRoot: logical, physicalRoot: physical,
                    binding: AgentSessionWorktreeBinding(
                        id: "lifetime", repositoryID: "repo", repoKey: "repo", logicalRootPath: logical.fullPath,
                        worktreeID: "worktree", worktreeRootPath: physical.fullPath, source: "test"
                    )
                )]
            )
            let context = WorkspaceLookupContext(rootScope: projection.lookupRootScope, bindingProjection: projection)
            let authority = try await MCPServerViewModel.FrozenFileToolAuthority.capture(
                lookupContext: context, rootCatalogSnapshot: canonical.rootCatalogSnapshot,
                store: store, sourceIdentity: canonical.sourceIdentity
            )
            try server.bindTabForConnection(
                connectionID: fixture.connectionID, clientName: nil, tabID: fixture.contextID,
                workspaceID: fixture.workspace.id, windowID: fixture.window.windowID,
                frozenFileToolAuthority: authority
            )
            let bound = try XCTUnwrap(server.tabContextByConnectionID[fixture.connectionID])
            let key = MCPReadFileAutoSelectionCoordinator.ContextKey(
                windowID: fixture.window.windowID, workspaceID: fixture.workspace.id, tabID: fixture.contextID,
                route: .bound(connectionID: fixture.connectionID, runID: nil),
                bindingGeneration: bound.readFileAutoSelectionGeneration
            )
            let identity = WorkspaceSelectionIdentity(workspaceID: fixture.workspace.id, tabID: fixture.contextID)
            let prior = try XCTUnwrap(fixture.window.workspaceManager.composeTab(for: identity)).selection
            let gate = RootHydrationSuspensionGate()
            let coordinator = try XCTUnwrap(server.selectionCoordinator)
            coordinator.beforeAuthorizedCommitForTesting = { await gate.hold() }
            addTeardownBlock { @MainActor in
                await gate.release()
                coordinator.beforeAuthorizedCommitForTesting = nil
                await store.unloadRoot(id: physicalRecord.id)
            }
            let apply = Task { @MainActor in
                await server.acceptReadFileAutoSelection(
                    selection: StoredSelection(
                        selectedPaths: prior.selectedPaths + [physicalURL.appendingPathComponent("Sentinel.swift").path],
                        manualCodemapPaths: prior.manualCodemapPaths,
                        slices: prior.slices,
                        codemapAutoEnabled: false
                    ),
                    lookupContext: context, contextKey: key, expectedBaseSelection: prior,
                    automaticCodemapDisposition: .disableAutomaticPreservingManual, authority: authority
                )
            }
            await gate.waitUntilHeld()
            await store.unloadRoot(id: physicalRecord.id)
            XCTAssertTrue(server.isReadFileAutoSelectionContextCurrent(key))
            await gate.release()
            let result = await apply.value
            XCTAssertNil(result)
            XCTAssertEqual(fixture.window.workspaceManager.composeTab(for: identity)?.selection, prior)
        }

        @MainActor
        func testDiscoveryKeepsFrozenPrimaryRootsAndAuthorizedGitArtifactsOnly() async throws {
            let root = try makeTemporaryRoot()
            let artifactRoot = try makeTemporaryRoot()
            let extraRoot = try makeTemporaryRoot()
            let primaryPath = root.appendingPathComponent("PrimarySentinel.swift")
            let artifactPath = artifactRoot.appendingPathComponent("ArtifactSentinel.swift")
            let extraPath = extraRoot.appendingPathComponent("UnauthorizedSentinel.swift")
            for path in [primaryPath, artifactPath, extraPath] {
                try "sentinel\n".write(to: path, atomically: true, encoding: .utf8)
            }
            let store = WorkspaceFileContextStore()
            let primary = try await store.loadRoot(path: root.path, kind: .primaryWorkspace)
            let artifact = try await store.loadRoot(path: artifactRoot.path, kind: .workspaceGitData)
            let captured = try await AgentWorkspaceLookupContextResolver.requiredLookupContext(
                source: AgentWorkspaceLookupContextSource(activeAgentSessionID: nil, worktreeBindingState: .notApplicable),
                store: store
            )
            let emptyBindingContext = try await AgentWorkspaceLookupContextResolver.requiredLookupContext(
                source: AgentWorkspaceLookupContextSource(activeAgentSessionID: UUID(), worktreeBindingState: .hydrated([])),
                store: store
            )
            XCTAssertEqual(emptyBindingContext, captured)
            let discovery = MCPServerViewModel.fileToolLookupContext(captured, applying: .visibleWorkspacePlusGitData)
            let ordinary = MCPServerViewModel.fileToolLookupContext(captured, applying: .visibleWorkspace)
            let extra = try await store.loadRoot(path: extraRoot.path, kind: .primaryWorkspace)
            addTeardownBlock {
                for id in [primary.id, artifact.id, extra.id] {
                    await store.unloadRoot(id: id)
                }
            }
            for (context, expectedPaths) in [(discovery, [primaryPath.path, artifactPath.path]), (ordinary, [primaryPath.path])] {
                let search = try await StoreBackedWorkspaceSearch.search(
                    pattern: "*Sentinel.swift", mode: .path, isRegex: false, caseInsensitive: true,
                    maxPaths: 100, paths: [], rootScope: context.rootScope, store: store, workspaceManager: nil
                )
                XCTAssertEqual(Set(search.paths ?? []), Set(expectedPaths))
                let tree = await store.makeCurrentSnapshotFileTreePresentation(
                    selection: StoredSelection(),
                    request: WorkspaceFileTreePresentationRequest(
                        mode: .full, filePathDisplay: .relative, onlyIncludeRootsWithSelectedFiles: false,
                        includeLegend: false, showCodeMapMarkers: false, rootScope: context.rootScope
                    ),
                    lookupContext: context
                )
                XCTAssertTrue(tree.content.contains("PrimarySentinel.swift"))
                XCTAssertEqual(tree.content.contains("ArtifactSentinel.swift"), context == discovery)
                XCTAssertFalse(tree.content.contains("UnauthorizedSentinel.swift"))
            }
            let rootless = WorkspaceLookupContext(
                rootScope: .validatedSessionBoundWorkspace(canonicalRoots: [], physicalRoots: []), bindingProjection: nil
            )
            let rootlessDiscovery = MCPServerViewModel.fileToolLookupContext(rootless, applying: .visibleWorkspacePlusGitData)
            let rootlessRoots = await store.rootRefs(scope: rootlessDiscovery.rootScope)
            XCTAssertEqual(rootlessRoots, [])
        }

        @MainActor
        func testBindSerializesHeldHydrationAsRetryableAuthorityFailure() async throws {
            let root = try makeTemporaryRoot()
            let targetWindow = WindowState()
            await targetWindow.workspaceManager.awaitInitialized()
            let contextID = UUID()
            let workspace = WorkspaceModel(
                name: "Held Hydration",
                repoPaths: [root.path],
                composeTabs: [ComposeTabState(id: contextID, name: "Context")],
                activeComposeTabID: contextID
            )
            targetWindow.workspaceManager.workspaces = [workspace]
            let gate = RootHydrationSuspensionGate()
            targetWindow.workspaceManager.setWorkspaceRootHydrationWillSpawnHandlerForTesting { _ in
                await gate.hold()
            }
            addTeardownBlock { @MainActor in
                targetWindow.workspaceManager.setWorkspaceRootHydrationWillSpawnHandlerForTesting(nil)
                await gate.release()
            }
            let switchTask = Task { @MainActor in
                await targetWindow.workspaceManager.switchWorkspace(
                    to: workspace,
                    saveState: false,
                    reason: "bind-context-held-hydration-test"
                )
            }
            await gate.waitUntilHeld()

            let previousWindows = WindowStatesManager.shared.allWindows
            WindowStatesManager.shared.allWindows = [targetWindow]
            addTeardownBlock { @MainActor in
                WindowStatesManager.shared.allWindows = previousWindows
            }
            try await AppGlobalMCPServiceComposition.shared.ensureRegistered()
            let toolsEnabled = await targetWindow.mcpServer.setWindowToolsEnabled(true)
            XCTAssertTrue(toolsEnabled)
            addTeardownBlock { @MainActor in
                _ = await targetWindow.mcpServer.setWindowToolsEnabled(false)
            }
            let connection = try await makeProductionMCPConnection()
            addTeardownBlock { await connection.cleanup() }

            let result = try await connection.client.callTool(name: "bind_context", arguments: [
                "op": .string("bind"),
                "context_id": .string(contextID.uuidString),
                "_rawJSON": .bool(true)
            ])
            XCTAssertNotEqual(result.isError, true, toolText(result))
            let data = try XCTUnwrap(toolText(result).data(using: .utf8))
            let response = try JSONDecoder().decode(BindContextResponse.self, from: data)
            XCTAssertEqual(response.changed, false)
            XCTAssertEqual(response.errorCode, "workspace_authority_timeout")
            XCTAssertEqual(response.retryable, true)
            XCTAssertEqual(response.retryAfterMilliseconds, 1000)
            XCTAssertFalse(response.binding.explicit)
            XCTAssertNil(response.binding.contextID)

            await gate.release()
            _ = await switchTask.value
        }

        @MainActor
        func testGenuinelyRootlessBindProducesExplicitEmptyAuthority() async throws {
            let fixture = try await makeFixture(rootPaths: [])
            let authority = try await fixture.window.mcpServer.resolveFileToolAuthority(
                tabID: fixture.contextID,
                workspaceID: fixture.workspace.id
            )

            XCTAssertTrue(authority.rootCatalogSnapshot.isGenuinelyRootless)
            XCTAssertEqual(authority.lookupContext.bindingProjection, nil)
        }

        @MainActor
        func testUnboundOneShotHintsReadFilesWithoutInstallingBindingOrSelecting() async throws {
            let root = try makeTemporaryRoot()
            let file = root.appendingPathComponent("OneShotSentinel.swift")
            try "struct OneShotSentinel {}\n".write(to: file, atomically: true, encoding: .utf8)
            let fixture = try await makeFixture(rootPaths: [root.path])
            let previousWindows = WindowStatesManager.shared.allWindows
            WindowStatesManager.shared.allWindows = [fixture.window]
            addTeardownBlock { @MainActor in
                WindowStatesManager.shared.allWindows = previousWindows
            }
            try await AppGlobalMCPServiceComposition.shared.ensureRegistered()
            let enabled = await fixture.window.mcpServer.setWindowToolsEnabled(true)
            XCTAssertTrue(enabled)
            addTeardownBlock { @MainActor in
                _ = await fixture.window.mcpServer.setWindowToolsEnabled(false)
            }
            let connection = try await makeProductionMCPConnection()
            addTeardownBlock { await connection.cleanup() }
            let identity = WorkspaceSelectionIdentity(workspaceID: fixture.workspace.id, tabID: fixture.contextID)
            let initialSelection = try XCTUnwrap(fixture.window.workspaceManager.composeTab(for: identity)).selection

            let roots = try await connection.client.callTool(name: "get_file_tree", arguments: [
                "type": .string("roots"),
                "_windowID": .int(fixture.window.windowID),
                "_rawJSON": .bool(true)
            ])
            XCTAssertNotEqual(roots.isError, true, toolText(roots))
            let rootsReply = try JSONDecoder().decode(
                ToolResultDTOs.FileTreeDTO.self,
                from: XCTUnwrap(toolText(roots).data(using: .utf8))
            )
            XCTAssertEqual(rootsReply.rootsCount, 1)
            XCTAssertNil(rootsReply.errorCode)

            let read = try await connection.client.callTool(name: "read_file", arguments: [
                "path": .string(file.path),
                "context_id": .string(fixture.contextID.uuidString),
                "_rawJSON": .bool(true)
            ])
            XCTAssertNotEqual(read.isError, true, toolText(read))
            let readReply = try JSONDecoder().decode(
                ToolResultDTOs.ReadFileReply.self,
                from: XCTUnwrap(toolText(read).data(using: .utf8))
            )
            XCTAssertTrue(readReply.content.contains("OneShotSentinel"))
            XCTAssertNil(readReply.errorCode)

            let selected = try await connection.client.callTool(name: "get_file_tree", arguments: [
                "mode": .string("selected"),
                "context_id": .string(fixture.contextID.uuidString),
                "_rawJSON": .bool(true)
            ])
            XCTAssertNotEqual(selected.isError, true, toolText(selected))
            XCTAssertNil(fixture.window.mcpServer.boundTabID(forConnection: connection.connectionID))
            XCTAssertEqual(fixture.window.workspaceManager.composeTab(for: identity)?.selection, initialSelection)
        }

        @MainActor
        func testRunScopedOneShotHintStillRequiresConnectionAuthority() async throws {
            let fixture = try await makeFixture(rootPaths: [makeTemporaryRoot().path])
            let runID = UUID()
            fixture.window.mcpServer.connectionIDToRunID[fixture.connectionID] = runID
            addTeardownBlock { @MainActor in
                fixture.window.mcpServer.connectionIDToRunID.removeValue(forKey: fixture.connectionID)
            }
            let metadata = MCPServerViewModel.RequestMetadata(
                connectionID: fixture.connectionID,
                clientName: "BindContextFileAuthorityTests",
                windowID: fixture.window.windowID,
                tabContextHint: MCPServerViewModel.TabContextHint(
                    tabID: fixture.contextID,
                    workspaceID: fixture.workspace.id,
                    windowID: fixture.window.windowID
                )
            )

            do {
                _ = try await fixture.window.mcpServer.requiredFileToolLookupContext(from: metadata)
                XCTFail("A run-scoped hint without a connection binding must fail closed")
            } catch let failure as MCPServerViewModel.FileToolAuthorityFailure {
                XCTAssertEqual(failure, .superseded)
            }
        }

        func testFileTreeReadinessFailureIsTypedAndRetryable() throws {
            let value = try failureValue(tool: MCPWindowToolName.getFileTree, args: ["type": .string("roots")])
            let reply = try XCTUnwrap(value.decode(ToolResultDTOs.FileTreeDTO.self))
            XCTAssertEqual(reply.errorCode, "workspace_authority_timeout")
            XCTAssertEqual(reply.retryable, true)
            XCTAssertEqual(reply.retryAfterMilliseconds, 1000)
        }

        func testReadFileReadinessFailurePreservesRequestedPath() throws {
            let value = try failureValue(tool: MCPWindowToolName.readFile, args: ["path": .string("README.md")])
            let reply = try XCTUnwrap(value.decode(ToolResultDTOs.ReadFileReply.self))
            XCTAssertEqual(reply.displayPath, "README.md")
            XCTAssertEqual(reply.errorCode, "workspace_authority_timeout")
            XCTAssertEqual(reply.retryable, true)
        }

        func testFileSearchReadinessFailureIsTypedAndEmpty() throws {
            let value = try failureValue(tool: MCPWindowToolName.search, args: ["pattern": .string("needle")])
            let reply = try XCTUnwrap(value.decode(ToolResultDTOs.SearchResultDTO.self))
            XCTAssertEqual(reply.totalMatches, 0)
            XCTAssertEqual(reply.errorCode, "workspace_authority_timeout")
            XCTAssertEqual(reply.retryable, true)
        }

        func testCodeStructureReadinessFailurePrecedesProjection() throws {
            let value = try failureValue(
                tool: MCPWindowToolName.getCodeStructure,
                args: ["paths": .array([.string("Sources")])]
            )
            let reply = try XCTUnwrap(value.decode(ToolResultDTOs.CodeStructureReplyDTO.self))
            XCTAssertEqual(reply.status, .unavailable)
            XCTAssertEqual(reply.issues.map(\.code), ["workspace_authority_timeout"])
            XCTAssertEqual(reply.issues.map(\.retryable), [true])
            XCTAssertEqual(reply.files, [])
        }

        private func failureValue(tool: String, args: [String: Value]) throws -> Value {
            try MCPFileToolProvider.authorityFailureValue(
                toolName: tool,
                args: args,
                failure: .timedOut
            )
        }

        @MainActor
        private func makeFixture(rootPaths: [String]) async throws -> Fixture {
            let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            defer { GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false) }
            let window = WindowState()
            await window.workspaceManager.awaitInitialized()
            let contextID = UUID()
            let workspace = WorkspaceModel(
                name: "Authority",
                repoPaths: rootPaths,
                composeTabs: [ComposeTabState(id: contextID, name: "Context")],
                activeComposeTabID: contextID
            )
            window.workspaceManager.workspaces = [workspace]
            let result = await window.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "bind-context-file-authority-test"
            )
            XCTAssertTrue(result.didSwitch)
            return Fixture(
                window: window,
                workspace: workspace,
                contextID: contextID,
                connectionID: UUID()
            )
        }

        private func makeTemporaryRoot() throws -> URL {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("repoprompt-bind-authority-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: root) }
            return root
        }

        @MainActor
        private func metadata(for fixture: Fixture) -> MCPServerViewModel.RequestMetadata {
            MCPServerViewModel.RequestMetadata(
                connectionID: fixture.connectionID,
                clientName: "BindContextFileAuthorityTests",
                windowID: fixture.window.windowID
            )
        }

        private func toolText(_ result: (content: [MCP.Tool.Content], isError: Bool?)) -> String {
            result.content.compactMap { content -> String? in
                if case let .text(text, _, _) = content { return text }
                return nil
            }.joined(separator: "\n")
        }

        private func makeProductionMCPConnection() async throws -> ProductionMCPConnection {
            var descriptors = [Int32](repeating: -1, count: 2)
            guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENFILE)
            }
            defer {
                for descriptor in descriptors where descriptor >= 0 {
                    Darwin.close(descriptor)
                }
            }

            let connectionID = UUID()
            let sessionToken = "bind-file-authority-\(UUID().uuidString)"
            let clientName = "BindContextFileAuthorityTests"
            let networkManager = ServerNetworkManager.shared
            let wasNetworkManagerRunning = await networkManager.isRunning()
            let connectionManager = try BootstrapSocketConnectionManager(
                connectionID: connectionID,
                sessionToken: sessionToken,
                clientPid: Int(getpid()),
                observedKernelPeerPID: Int(getpid()),
                clientName: clientName,
                purpose: .unknown,
                codeMapsDisabled: true,
                connectedFD: descriptors[0],
                parentManager: networkManager
            )
            descriptors[0] = -1
            let clientTransport = try UnixSocketMCPTransport(
                connectedFD: descriptors[1],
                connectionID: connectionID,
                correlationConnectionID: sessionToken
            )
            descriptors[1] = -1
            await networkManager.debugInstallDirectAdmissionConnectionForTesting(
                connectionID: connectionID,
                connection: connectionManager,
                pendingClientID: clientName
            )
            _ = await networkManager.debugInstallConnectionLimiterForTesting(connectionID: connectionID)

            do {
                try await connectionManager.start { $0.name == clientName }
                let client = Client(name: clientName, version: "1.0")
                _ = try await client.connect(transport: clientTransport)
                return ProductionMCPConnection(
                    client: client,
                    connectionID: connectionID,
                    connectionManager: connectionManager,
                    wasNetworkManagerRunning: wasNetworkManagerRunning
                )
            } catch {
                await clientTransport.disconnect()
                await connectionManager.stop()
                await networkManager.debugRemoveConnection(connectionID)
                if !wasNetworkManagerRunning {
                    await networkManager.stop()
                }
                throw error
            }
        }
    }

    private struct Fixture {
        let window: WindowState
        let workspace: WorkspaceModel
        let contextID: UUID
        let connectionID: UUID
    }

    private enum AffinityFailure: Error {
        case injected
    }

    private actor RootHydrationSuspensionGate {
        private var held = false
        private var released = false
        private var heldWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func hold() async {
            held = true
            let waiters = heldWaiters
            heldWaiters.removeAll()
            waiters.forEach { $0.resume() }
            guard !released else { return }
            await withCheckedContinuation { releaseWaiters.append($0) }
        }

        func waitUntilHeld() async {
            guard !held else { return }
            await withCheckedContinuation { heldWaiters.append($0) }
        }

        func release() {
            released = true
            let waiters = releaseWaiters
            releaseWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    private struct ProductionMCPConnection {
        let client: Client
        let connectionID: UUID
        let connectionManager: BootstrapSocketConnectionManager
        let wasNetworkManagerRunning: Bool

        func cleanup() async {
            let networkManager = ServerNetworkManager.shared
            await client.disconnect()
            await connectionManager.stop()
            await networkManager.debugRemoveConnection(connectionID)
            if !wasNetworkManagerRunning {
                await networkManager.stop()
            }
        }
    }
#endif
