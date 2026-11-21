import Darwin
import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
@testable import RepoPromptMCPServer
import RepoPromptProcess
import RepoPromptSecureStorage
import RepoPromptSettingsCore
import RepoPromptShared
import RepoPromptVCS
@testable import RepoPromptWorkspaceContext
import RepoPromptWorkspaceCore
import XCTest

private actor RouteInvocationGate {
    private var entered = false
    private var released = false
    private var entries: [CheckedContinuation<Void, Never>] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var validationCalls = 0

    func recordValidation() -> Bool {
        validationCalls += 1
        return true
    }

    func enter() async {
        entered = true
        let pending = entries
        entries.removeAll()
        pending.forEach { $0.resume() }
        if !released { await withCheckedContinuation { waiters.append($0) } }
    }

    func didEnter() -> Bool {
        entered
    }

    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { entries.append($0) } }
    }

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor RouteHistoryScanner: HistorySessionScanning {
    enum Failure: Error { case scan }
    private(set) var scans = 0
    private var fails = false
    private var gate: RouteInvocationGate?

    func setFailure(_ value: Bool) {
        fails = value
    }

    func block(on gate: RouteInvocationGate) {
        fails = false
        self.gate = gate
    }

    func scanAllWorkspaces() async throws -> [HistoryWorkspaceScanResult] {
        scans += 1
        if fails { throw Failure.scan }
        await gate?.enter()
        try Task.checkCancellation()
        return []
    }

    func scanAllWorkspacesRefreshing() async throws -> [HistoryWorkspaceScanResult] {
        try await scanAllWorkspaces()
    }

    nonisolated func sessionsMatchingFilters(
        _: [HistoryWorkspaceScanResult], workspace _: String?, agentKind _: String?, model _: String?,
        filePath _: String?, from _: Date?, to _: Date?
    ) -> [HistoryFilteredSessionRecord] {
        []
    }

    func loadTranscriptForSearch(sessionID _: UUID, workspaceDir _: URL) async throws -> AgentTranscript {
        throw Failure.scan
    }

    func transcriptDerivedFieldsAreStale(for _: AgentSessionMetadataRecord, sessionID _: UUID, workspaceDir _: URL) async -> Bool {
        false
    }
}

/// Regression coverage for per-subscriber MCP state streams.
///
/// `MCPService` previously exposed one shared `AsyncStream` (`stateStream`) to
/// every window's `MCPServerViewModel`. `AsyncStream` distributes each yield to
/// a single waiting iterator, so windows could steal each other's snapshots —
/// including pending-approval updates — and a closed window's iterator kept its
/// view model (and everything it holds) alive forever.
///
/// These tests pin the replacement contract: every live subscriber receives
/// every snapshot, a late subscriber is seeded with the current state,
/// `unsubscribeFromStateUpdates` finishes only that subscriber's stream, and a
/// view model can be deallocated once observation stops.
final class MCPStateSubscriptionTests: XCTestCase {
    @MainActor
    func testCanonicalReceiptsKeepTheirOwnContextsOnSharedPhysicalRoute() async throws {
        let runtime = try await makeHistoryRouteRuntime()
        let route = MCPHostRouteResources(identity: .legacyWindow(42), coordinator: nil, runtime: runtime)
        addTeardownBlock { await route.close() }

        let runID = UUID()
        func registration(workspaceID: UUID) -> MCPRunRoutingCleanupReceipt {
            let snapshot = MCPTabContextSnapshot(
                tabID: UUID(), windowID: route.identity.routeID, workspaceID: workspaceID,
                promptText: "", selection: .init(), selectedMetaPromptIDs: [], tabName: "Epoch",
                runID: runID, explicitlyBound: true
            )
            return .init(
                managerIdentity: ObjectIdentifier(route), policyID: UUID(), runID: runID,
                routeID: route.identity.routeID, routingAuthorityGeneration: 0, routingWaitGeneration: nil,
                routeOwner: route, providerContextResolver: {
                    .init(snapshot: snapshot, isCurrent: { true }, validateCarrier: { true })
                }
            )
        }

        let workspaceA = UUID()
        let workspaceB = UUID()
        let predecessor = registration(workspaceID: workspaceA)
        let successor = registration(workspaceID: workspaceB)
        let connectionA = UUID()
        let connectionB = UUID()
        let admittedA = await route.installPendingPolicy(predecessor, connectionID: connectionA, clientName: nil, tabID: nil)
        let admittedB = await route.installPendingPolicy(successor, connectionID: connectionB, clientName: nil, tabID: nil)
        XCTAssertEqual(admittedA?.workspaceID, workspaceA)
        XCTAssertEqual(admittedB?.workspaceID, workspaceB)

        let predecessorToken = try XCTUnwrap(admittedA?.token)
        let staleRollback = route.rollbackPendingPolicy(predecessor, token: predecessorToken, clientName: nil)
        guard case .supersededByOtherConnection? = staleRollback else {
            return XCTFail("Stale predecessor must not roll back the successor")
        }
        await route.consumeCleanup(predecessor)
        await route.consumeCleanup(predecessor)
        XCTAssertNil(route.runRouteBindings.tabContextByConnectionID[connectionA])
        XCTAssertEqual(route.runRouteBindings.tabContextByConnectionID[connectionB]?.workspaceID, workspaceB)
        XCTAssertEqual(route.runRouteBindings.connectionIDByRunID[runID], connectionB)
        XCTAssertFalse(route.isClosing)

        let successorToken = try XCTUnwrap(admittedB?.token)
        let rollback = route.rollbackPendingPolicy(successor, token: successorToken, clientName: nil)
        if case .restored? = rollback {} else {
            XCTFail("The originating canonical adapter must roll back the installation")
        }
        XCTAssertNil(route.runRouteBindings.tabContextByConnectionID[connectionB])
        await route.consumeCleanup(successor)
    }

    @MainActor
    func testPhysicalRouteDisposalWaitsForSuccessorEpochExecutionLease() async throws {
        let runtime = try await makeHistoryRouteRuntime()
        let owner = MCPHostRouteResources.LeaseOwner(
            identity: MCPRouteIdentityAllocator.allocateHost(), coordinator: runtime.routingCoordinator, runtime: runtime
        )
        let route = owner.route
        let presentation = try XCTUnwrap(owner.acquire(.presentation))
        let predecessor = try XCTUnwrap(owner.acquire(.execution))
        let registered = await route.ensureRegistered(workspaceID: nil, contextID: nil, revision: 0)
        let descriptor = try XCTUnwrap(registered)
        let successor = try XCTUnwrap(owner.acquire(.execution))

        await predecessor.release()
        XCTAssertFalse(route.isClosing)
        await owner.requestTerminalDisposal()
        XCTAssertNil(owner.acquire(.presentation))
        XCTAssertNil(owner.acquire(.execution))
        await presentation.release()
        await predecessor.release()
        XCTAssertFalse(route.isClosing)
        let retained = await runtime.routingCoordinator.snapshot()
        XCTAssertTrue(retained.windows.contains { $0.windowID == descriptor.windowID && $0.generation == descriptor.generation })

        await successor.release()
        XCTAssertTrue(route.isClosing)
        XCTAssertNil(route.descriptor)
        await owner.requestTerminalDisposal()
        let closed = await runtime.routingCoordinator.snapshot()
        XCTAssertFalse(closed.windows.contains { $0.windowID == descriptor.windowID })
    }

    @MainActor
    func testModelEndpointRefusesWriterReacquisitionOnTheSameBinding() async throws {
        let server = makeServerViewModel(service: makeService())
        let manager = try XCTUnwrap(server.workspaceManager)
        await manager.awaitInitialized()
        let store = AgentSessionRuntimeStore()
        let scope = store.makeScope()
        let sessionID = UUID()
        var tab = ComposeTabState()
        tab.activeAgentSessionID = sessionID
        let workspace = WorkspaceModel(
            name: "Model route selection", repoPaths: [], ephemeralFlag: true, composeTabs: [tab]
        )
        manager.workspaces = [workspace]
        let workspaceID = workspace.id
        let tabID = tab.id
        let runID = UUID()
        let connectionID = UUID()
        let route = MCPHostRouteResources(identity: MCPRouteIdentityAllocator.allocateHost(), coordinator: nil)
        let routeID = route.identity.routeID
        let session = AgentTabSession(tabID: tabID)
        session.installPersistentSessionBinding(.init(tabID: tabID, sessionID: sessionID, workspaceID: workspaceID))
        session.hasLoadedPersistedState = true
        session.recordRestorationAuthoritative(.persistedPayloadApplied)
        scope.replaceSessions([tabID: session])
        let original = try scope.admit(session: session)
        let endpoint = DomainAgentSessionLinkEndpointIdentity(
            windowID: routeID, workspaceID: workspaceID, tabID: tabID, sessionID: sessionID,
            persistentBindingGeneration: original.writer.binding.generation,
            bindingTransitionGeneration: session.bindingTransitionGeneration
        )
        route.installModelEndpointResolver { [weak scope] requestedTabID in
            guard requestedTabID == tabID, let scope, let session = scope.sessions[tabID],
                  let command = try? scope.admit(session: session) else { return nil }
            return .init(endpoint: endpoint, writer: command.identity)
        }

        let receipt = MCPRunRoutingCleanupReceipt(
            managerIdentity: ObjectIdentifier(store), policyID: UUID(), runID: runID, routeID: routeID,
            routingAuthorityGeneration: 1, routingWaitGeneration: nil, routeOwner: route
        )
        _ = try XCTUnwrap(route.runRouteBindings.beginPendingPolicy(
            connectionID: connectionID, runID: runID, windowID: routeID, cleanupReceipt: receipt
        ))
        var context = MCPTabContextSnapshot(
            tabID: tabID, windowID: routeID, workspaceID: workspaceID, promptText: "",
            selection: .init(), selectedMetaPromptIDs: [], tabName: "Original",
            runID: runID, activeAgentSessionID: sessionID, explicitlyBound: false
        )
        context.routeOwnerIdentity = ObjectIdentifier(route)
        route.runRouteBindings.tabContextByConnectionID[connectionID] = context
        route.publishBinding(connectionID: connectionID, context: context, cleanupReceipt: receipt)
        XCTAssertEqual(route.modelObserverEndpoint(
            registration: receipt, connectionID: connectionID, workspaceID: workspaceID, tabID: tabID
        ), endpoint)
        XCTAssertNil(route.modelObserverEndpoint(
            registration: receipt, connectionID: connectionID, workspaceID: UUID(), tabID: tabID
        ))

        // A request snapshot can predate writer capture. Read the binding's current proof on writeback.
        var mutation = context
        mutation.selection = StoredSelection(selectedPaths: ["/workspace/Selection.swift"])
        let verification = await server.persistResolvedTabContextSnapshot(
            route: route,
            .init(snapshot: mutation, source: .runInstall),
            metadata: .init(connectionID: connectionID, clientName: nil, windowID: routeID),
            mutated: true
        )
        XCTAssertEqual(verification?.canonicalSelection, mutation.selection)
        let refreshed = try XCTUnwrap(route.runRouteBindings.tabContextByConnectionID[connectionID])
        XCTAssertEqual(refreshed.selection, mutation.selection)
        XCTAssertEqual(refreshed.routeOwnerIdentity, ObjectIdentifier(route))
        XCTAssertEqual(route.modelObserverEndpoint(
            registration: receipt, connectionID: connectionID, workspaceID: workspaceID, tabID: tabID
        ), endpoint)

        scope.replaceSessions([:])
        scope.replaceSessions([tabID: session])
        let reacquired = try scope.admit(session: session)
        XCTAssertNotEqual(reacquired.identity, original.identity)
        XCTAssertEqual(session.bindingTransitionGeneration, endpoint.bindingTransitionGeneration)
        route.publishBinding(connectionID: connectionID, context: context, cleanupReceipt: receipt)
        XCTAssertNil(route.modelObserverEndpoint(
            registration: receipt, connectionID: connectionID, workspaceID: workspaceID, tabID: tabID
        ))
    }

    private func makeService() -> MCPService {
        MCPService(
            hostBootstrapOperation: {},
            controllerStartOperation: {},
            controllerFullShutdownOperation: {}
        )
    }

    private func collectAll(_ stream: AsyncStream<MCPService.Snapshot>) async -> [MCPService.Snapshot] {
        var items: [MCPService.Snapshot] = []
        for await snapshot in stream {
            items.append(snapshot)
        }
        return items
    }

    /// Polls a condition with a bounded timeout. Used where state delivery
    /// crosses actors (subscribe/apply hops are asynchronous).
    @MainActor
    private func waitUntil(
        _ condition: @MainActor () async -> Bool,
        timeout: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let satisfied = await condition()
        XCTAssertTrue(satisfied, "Timed out waiting for condition", file: file, line: line)
    }

    /// Two subscribers must each receive every snapshot. On the shared-stream
    /// implementation each yield reached exactly one iterator, so at least one
    /// subscriber would miss updates.
    func testEverySubscriberReceivesEverySnapshot() async {
        let service = makeService()
        let (idA, streamA) = await service.subscribeToStateUpdates()
        let (idB, streamB) = await service.subscribeToStateUpdates()

        await service.join(windowID: 1)
        await service.leave(windowID: 1)
        await service.refreshState()

        await service.unsubscribeFromStateUpdates(id: idA)
        await service.unsubscribeFromStateUpdates(id: idB)

        let snapshotsA = await collectAll(streamA)
        let snapshotsB = await collectAll(streamB)

        // 1 seed snapshot at subscribe + 3 broadcast yields.
        XCTAssertEqual(snapshotsA.count, 4)
        XCTAssertEqual(snapshotsB.count, 4)
        XCTAssertEqual(snapshotsA, snapshotsB)
    }

    /// A subscriber that joins after state changed must observe the current
    /// snapshot first rather than missing it.
    func testLateSubscriberReceivesCurrentSnapshot() async {
        let service = makeService()
        await service.setPendingApprovalForTesting("early-client")

        let (id, stream) = await service.subscribeToStateUpdates()
        await service.unsubscribeFromStateUpdates(id: id)

        let snapshots = await collectAll(stream)
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.pendingClientID, "early-client")
    }

    /// Unsubscribing must finish only that subscriber's stream and stop its
    /// deliveries; other subscribers keep receiving updates.
    func testUnsubscribeFinishesOnlyThatStream() async {
        let service = makeService()
        let (idA, streamA) = await service.subscribeToStateUpdates()
        let (idB, streamB) = await service.subscribeToStateUpdates()
        let initialCount = await service.stateSubscriberCountForTesting()
        XCTAssertEqual(initialCount, 2)

        await service.unsubscribeFromStateUpdates(id: idA)
        let remainingCount = await service.stateSubscriberCountForTesting()
        XCTAssertEqual(remainingCount, 1)

        await service.setPendingApprovalForTesting("client-1")
        await service.unsubscribeFromStateUpdates(id: idB)

        let snapshotsA = await collectAll(streamA)
        let snapshotsB = await collectAll(streamB)

        // A only saw the seed snapshot; B saw the seed + the approval update.
        XCTAssertEqual(snapshotsA.count, 1)
        XCTAssertNil(snapshotsA.last?.pendingClientID)
        XCTAssertEqual(snapshotsB.count, 2)
        XCTAssertEqual(snapshotsB.last?.pendingClientID, "client-1")
        let finalCount = await service.stateSubscriberCountForTesting()
        XCTAssertEqual(finalCount, 0)
    }

    /// A pending-approval snapshot must reach every live window's stream, not
    /// whichever iterator happened to be parked on a shared stream.
    func testPendingApprovalBroadcastsToAllSubscribers() async {
        let service = makeService()
        var streams: [AsyncStream<MCPService.Snapshot>] = []
        var ids: [UUID] = []
        for _ in 0 ..< 3 {
            let (id, stream) = await service.subscribeToStateUpdates()
            ids.append(id)
            streams.append(stream)
        }

        await service.setPendingApprovalForTesting("client-xyz")
        for id in ids {
            await service.unsubscribeFromStateUpdates(id: id)
        }

        for stream in streams {
            let snapshots = await collectAll(stream)
            XCTAssertEqual(snapshots.last?.pendingClientID, "client-xyz")
        }
    }

    @MainActor
    private func makeServerViewModel(service: MCPService, validation: MCPToolInvocationValidator? = nil) -> MCPServerViewModel {
        let store = WorkspaceFileContextStore()
        let fileManager = WorkspaceFilesViewModel(workspaceFileContextStore: store)
        let keyManager = KeyManager(
            secureService: SecureKeysService(secureStorage: TestSecureStorageBackend())
        )
        let aiQueriesService = AIQueriesService(keyManager: keyManager)
        let apiSettings = APISettingsViewModel(
            aiQueriesService: aiQueriesService,
            keyManager: keyManager,
            loadStoredDataOnInit: false
        )
        let settingsManager = WindowSettingsManager(windowID: -1)
        let prompt = PromptViewModel(
            fileManager: fileManager,
            aiQueriesService: aiQueriesService,
            apiSettingsViewModel: apiSettings,
            windowID: -1,
            settingsManager: settingsManager
        )
        let workspaceManager = WorkspaceManagerViewModel(
            fileManager: fileManager,
            promptViewModel: prompt,
            performInitialWorkspaceActivation: false
        )
        let oracle = OracleViewModel(
            aiQueriesService: aiQueriesService,
            promptViewModel: prompt,
            workspaceManager: workspaceManager,
            chatData: ChatDataService()
        )
        return MCPServerViewModel(
            service: service,
            promptVM: prompt,
            oracleVM: oracle,
            workspaceManager: workspaceManager,
            windowID: -1,
            workspaceSearch: { _, _, _, _, _, _, _, _, _, _, _, _, _, _ in
                throw MCPError.internalError("workspace search is not used by these tests")
            },
            ensureGitDataRootLoaded: { _, _ in
                throw MCPError.internalError("git-data loading is not used by these tests")
            },
            validateInvocation: validation ?? { context, routeID, owner in
                await ServerNetworkManager.shared.validateToolInvocationContext(
                    context, expectedWindowID: routeID, expectedServerViewModelIdentity: owner
                )
            }
        )
    }

    @MainActor
    private func makeHistoryRouteRuntime() async throws -> MCPDomainRuntime {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("route-binding-\(UUID())")
        let runtime = MCPDomainRuntime(configuration: .init(
            mode: .app, profileIdentifier: UUID().uuidString, storageDirectory: directory,
            workspaceStorageDirectory: directory.appendingPathComponent("workspaces"),
            eventDirectory: directory.appendingPathComponent("events"),
            temporaryDirectory: directory.appendingPathComponent("tmp"), externalReloadInterval: nil
        ))
        try await runtime.start()
        addTeardownBlock {
            _ = await runtime.shutdown()
            try? FileManager.default.removeItem(at: directory)
        }
        return runtime
    }

    @MainActor
    private struct TreeRouteFixture {
        let route: MCPHostRouteResources
        let tree: MCPDomainResolvedTool
        let connectionID: UUID
        let workspace: WorkspaceModel
        let documentURL: URL
        let files: WorkspaceFileContextStore
        let root: WorkspaceRootRecord
        let lease: AgentHostWorkspaceResources.Lease
    }

    @MainActor
    private func registeredTreeAfterServerRelease(
        runtime: MCPDomainRuntime, worktree: Bool = false, gate: RouteInvocationGate? = nil,
        identity: MCPHostRouteIdentity? = nil, validation: MCPToolInvocationValidator? = nil
    ) async throws -> TreeRouteFixture {
        // Test repositories stay inside this admitted checkout, never in a /tmp worktree.
        let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let git = try ReviewGitRepositoryFixture(name: "RouteTree", parentDirectory: repoRoot.appendingPathComponent(".build/validation-artifacts/m9-tree"))
        let directory = git.sandbox
        let base = try git.makeRepository(named: "logical", files: ["BaseOnly.swift": "base", "Sources/Selected.swift": "selected"])
        let physical = directory.appendingPathComponent("bound")
        var worktreeIdentity: GitWorktreeIdentitySnapshot?
        if worktree {
            try git.runGit(["worktree", "add", "--detach", physical.path, "HEAD"], at: base)
            try FileManager.default.removeItem(at: physical.appendingPathComponent("BaseOnly.swift"))
            try git.write("bound", to: "BoundOnly.swift", at: physical)
            try git.write("selected bound", to: "Sources/Selected.swift", at: physical)
            worktreeIdentity = try XCTUnwrap(GitWorktreeIdentityResolver.resolve(atWorkTreeRoot: physical))
            XCTAssertFalse(try XCTUnwrap(worktreeIdentity).isMain)
        }
        let files = WorkspaceFileContextStore(codemapGraphIndexBuildLaunchPolicyForTesting: .disabled)
        let root = try await files.loadRoot(path: base.path)
        var workspace = WorkspaceModel(name: "Canonical tree", repoPaths: [base.path])
        var tab = ComposeTabState()
        tab.selection = StoredSelection(selectedPaths: [base.appendingPathComponent("Sources/Selected.swift").path])
        tab.activeAgentSessionID = worktree ? UUID() : nil
        workspace.composeTabs = [tab]
        workspace.activeComposeTabID = tab.id
        let route = MCPHostRouteResources(identity: identity ?? MCPRouteIdentityAllocator.allocateHost(), coordinator: runtime.routingCoordinator, runtime: runtime)
        let documentURL = runtime.configuration.workspaceStorageDirectory.appendingPathComponent("tree-\(workspace.id).json")
        _ = try await DomainWorkspaceAuthorityClient(store: runtime.workspaceStore, windowID: route.identity.routeID).create(workspace, fileURL: documentURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: documentURL.path), "Use actual canonical persistence")
        let context = DomainContextIdentity(workspaceID: workspace.id, contextID: tab.id)
        let lease = try await AgentHostWorkspaceResources(files: files, contexts: runtime.contextStore).acquire(context: context, rootIDs: [root.id])
        addTeardownBlock {
            await route.close()
            await lease.release()
            await files.unloadRoot(id: root.id)
            git.cleanup()
        }
        let bindings: [AgentSessionWorktreeBinding] = worktreeIdentity.map { identity in [.init(
            id: "tree-binding", repositoryID: identity.repository.repositoryID, repoKey: identity.repository.repoKey,
            logicalRootPath: base.path, logicalRootName: base.lastPathComponent,
            worktreeID: identity.worktreeID, worktreeRootPath: physical.path,
            commonGitDir: identity.repository.commonGitDir, isMainWorktree: identity.isMain, source: "test"
        )] } ?? []
        let suiteName = "RouteTree.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let settings = GlobalSettingsStore(defaults: defaults, fileStore: GlobalSettingsFileStore(fileURL: directory.appendingPathComponent("settings.json")))
        var resources = MCPFileReadResources(workspace: lease, settings: settings)
        if let gate { resources.beforeReplyValidationForTesting = { await gate.enter() } }
        var server: MCPServerViewModel? = makeServerViewModel(service: makeService(), validation: validation)
        let released = { @MainActor [weak server, weak prompt = server?.promptVM, weak manager = server?.workspaceManager] in
            server == nil && prompt == nil && manager == nil
        }
        let lifetimeStatus = { @MainActor [weak server, weak prompt = server?.promptVM, weak manager = server?.workspaceManager] in
            "released server=\(server == nil), prompt=\(prompt == nil), workspace=\(manager == nil)"
        }
        let catalog = try XCTUnwrap(server).makeToolCatalog(route: route, fileReads: resources)
        let physicalNames = try Set(XCTUnwrap(server).makeToolCatalog(route: server!.routeResources).materializeTools().map(\.name))
        _ = await route.ensureRegistered(workspaceID: workspace.id, contextID: tab.id, revision: 0)
        let connectionID = UUID()
        var snapshot = MCPTabContextSnapshot(tabID: tab.id, windowID: route.identity.routeID, workspaceID: workspace.id, promptText: "", selection: .init(), selectedMetaPromptIDs: [], tabName: "Original", runID: nil, activeAgentSessionID: tab.activeAgentSessionID, worktreeBindings: bindings, explicitlyBound: true)
        snapshot.routeOwnerIdentity = ObjectIdentifier(route)
        route.runRouteBindings.tabContextByConnectionID[connectionID] = snapshot
        route.publishBinding(connectionID: connectionID, context: snapshot)
        await route.settleRoutingPublications()
        server?.stopServiceObservation()
        server?.promptVM.cancelInitialModelRefreshForWindowClose()
        server?.promptVM.gitViewModel.prepareForWindowClose()
        server?.workspaceManager?.prepareForWindowClose()
        await server?.workspaceManager?.awaitInitialWorkspaceActivationCompletion()
        await server?.workspaceManager?.awaitPostSwitchGitDataLoadShutdown()
        await server?.promptVM.awaitInitialModelRefreshCompletion()
        await server?.workspaceManager?.awaitRootReconciliationShutdown()
        await server?.workspaceManager?.awaitOwnSavesForWindowClose()
        await server?.promptVM.stopTokenCountUpdateTimer()
        server = nil
        await waitUntil { released() }
        XCTAssertTrue(released(), "The complete catalog must retain no server, prompt or workspace VM: \(lifetimeStatus())")
        // First materialization and authoritative registration happen only after all three VMs
        // are gone. No pre-deallocation tool cache may conceal a physical dependency.
        XCTAssertEqual(try Set(catalog.materializeTools().map(\.name)), physicalNames)
        _ = try await route.registerCatalog(catalog)
        let resolved = await runtime.toolRegistry.resolve(toolName: "get_file_tree", scope: .window(id: route.identity.routeID))
        return try TreeRouteFixture(route: route, tree: XCTUnwrap(resolved), connectionID: connectionID, workspace: workspace, documentURL: documentURL, files: files, root: root, lease: lease)
    }

    @MainActor
    private func invokeTree(_ fixture: TreeRouteFixture, args: [String: Value]) async throws -> Value {
        let invocation = ToolInvocationContext.trustedLocal(toolName: "get_file_tree", metadata: .init(connectionID: fixture.connectionID, clientName: nil, windowID: fixture.route.identity.routeID))
        return try await MCPInvocationContextBridge.withInvocation(invocation) { try await fixture.tree.binding(args) }
    }

    @MainActor
    func testRegisteredFileTreeUsesCanonicalSelectionAndPhysicalBoundRootsWithoutVMs() async throws {
        let runtime = try await makeHistoryRouteRuntime()
        try await AppDomainRuntimeComposition.shared.withRuntimeForTesting(runtime) {
            let count = WindowState.windowCounter
            for worktree in [false, true] {
                let fixture = try await registeredTreeAfterServerRelease(runtime: runtime, worktree: worktree)
                let full = try await invokeTree(fixture, args: ["mode": .string("full")])
                let tree = try XCTUnwrap(full.objectValue?["tree"]?.stringValue)
                XCTAssertTrue(tree.contains(worktree ? "BoundOnly.swift" : "BaseOnly.swift"), tree)
                XCTAssertFalse(tree.contains(worktree ? "BaseOnly.swift" : "BoundOnly.swift"), tree)
                let selected = try await invokeTree(fixture, args: ["mode": .string("selected")])
                let selection = try XCTUnwrap(selected.objectValue?["tree"]?.stringValue)
                XCTAssertTrue(selection.contains("Selected.swift"), selection)
                XCTAssertFalse(selection.contains("Only.swift"), "Selection comes from canonical context bytes, not the intentionally empty route snapshot")
                for args: [String: Value] in [["type": .string("roots")], ["mode": .string("folders")], ["mode": .string("auto"), "path": .string("Sources"), "max_depth": .int(1)]] {
                    let value = try await invokeTree(fixture, args: args)
                    XCTAssertNil(value.objectValue?["error_code"], String(describing: value))
                }
                do {
                    _ = try await invokeTree(fixture, args: ["mode": .string("invalid")])
                    XCTFail("Preserve invalid-mode diagnostics")
                } catch let error as MCPError { XCTAssertEqual(error, .invalidParams("invalid mode: invalid")) }
                for name in ["read_file", "file_search", "file_actions", "apply_edits", "prompt"] {
                    let resolved = await runtime.toolRegistry.resolve(toolName: name, scope: .window(id: fixture.route.identity.routeID))
                    let tool = try XCTUnwrap(resolved)
                    let request = ToolInvocationContext.trustedLocal(toolName: name, metadata: .init(connectionID: fixture.connectionID, clientName: nil, windowID: fixture.route.identity.routeID))
                    do {
                        _ = try await MCPInvocationContextBridge.withInvocation(request) { try await tool.binding([:]) }
                        XCTFail("Unmigrated \(name) must not enter physical-window execution")
                    } catch let error as MCPError { XCTAssertEqual(error, .invalidRequest("Tool \(name) is not supported by the independent Agent session route"))
                    } catch DomainMutationPolicyError.principalMissing {
                        XCTAssertTrue(["file_actions", "apply_edits"].contains(name), "Protected mutation admission remains in front of physical dispatch")
                    }
                }
                XCTAssertEqual(fixture.route.toolExecutionRuntime.activeExecutionCount, 0)
            }
            XCTAssertEqual(WindowState.windowCounter, count)
        }
    }

    @MainActor
    func testRegisteredCodeStructureReadsExactCanonicalSelectionAndBoundWorktreeWithoutVMs() async throws {
        let runtime = try await makeHistoryRouteRuntime()
        try await AppDomainRuntimeComposition.shared.withRuntimeForTesting(runtime) {
            let fixture = try await registeredTreeAfterServerRelease(runtime: runtime, worktree: true)
            let name = MCPWindowToolName.getCodeStructure
            let registered = await runtime.toolRegistry.resolve(toolName: name, scope: .window(id: fixture.route.identity.routeID))
            let tool = try XCTUnwrap(registered)
            let metadata = MCPRequestMetadata(connectionID: fixture.connectionID, clientName: nil, windowID: fixture.route.identity.routeID)
            func invoke(paths: [String]? = nil) async throws -> Value {
                var arguments: [String: Value] = ["signatures": .bool(false)]
                if let paths { arguments["paths"] = .array(paths.map(Value.string)) }
                let request = ToolInvocationContext.trustedLocal(toolName: name, metadata: metadata)
                let input = arguments
                return try await MCPInvocationContextBridge.withInvocation(request) { try await tool.binding(input) }
            }
            func seedPaths(_ value: Value) -> [String] {
                (value.objectValue?["roots"]?.arrayValue ?? []).flatMap { root in
                    (root.objectValue?["seeds"]?.arrayValue ?? []).compactMap { $0.objectValue?["path"]?.stringValue }
                }
            }

            let selected = try await invoke()
            XCTAssertEqual(seedPaths(selected), ["\(fixture.root.name)/Sources/Selected.swift"], String(describing: selected))
            let explicit = try await invoke(paths: [fixture.root.fullPath + "/BoundOnly.swift"])
            XCTAssertEqual(seedPaths(explicit), ["\(fixture.root.name)/BoundOnly.swift"], String(describing: explicit))
            let missing = try await invoke(paths: [fixture.root.fullPath + "/BaseOnly.swift"])
            XCTAssertTrue(seedPaths(missing).isEmpty)
            XCTAssertEqual(missing.objectValue?["issues"]?.arrayValue?.first?.objectValue?["code"]?.stringValue, "path_not_found")
            XCTAssertEqual(fixture.route.toolExecutionRuntime.activeExecutionCount, 0)
        }
    }

    @MainActor
    func testRegisteredFileReadsKeepTwoConnectionsScopedToTheirOwnTabs() async throws {
        let runtime = try await makeHistoryRouteRuntime()
        try await AppDomainRuntimeComposition.shared.withRuntimeForTesting(runtime) {
            let fixture = try await registeredTreeAfterServerRelease(runtime: runtime)
            var workspace = fixture.workspace
            var secondTab = ComposeTabState()
            secondTab.selection = StoredSelection(selectedPaths: [fixture.root.fullPath + "/BaseOnly.swift"])
            workspace.composeTabs.append(secondTab)
            let document = try DomainWorkspaceDocument.decode(documentBytes: JSONEncoder().encode(workspace), fileURL: fixture.documentURL)
            _ = await runtime.workspaceStore.registerReadDocument(document)

            let route = fixture.route
            let secondConnectionID = UUID()
            var second = MCPTabContextSnapshot(
                tabID: secondTab.id, windowID: route.identity.routeID, workspaceID: workspace.id,
                promptText: "", selection: .init(), selectedMetaPromptIDs: [], tabName: "Second", runID: nil, explicitlyBound: true
            )
            second.routeOwnerIdentity = ObjectIdentifier(route)
            route.runRouteBindings.tabContextByConnectionID[secondConnectionID] = second
            route.publishBinding(connectionID: secondConnectionID, context: second)
            await route.settleRoutingPublications()
            XCTAssertEqual(route.descriptor?.activeContextID, secondTab.id)

            let codeStructure = await runtime.toolRegistry.resolve(toolName: MCPWindowToolName.getCodeStructure, scope: .window(id: route.identity.routeID))
            let codeBinding = try XCTUnwrap(codeStructure).binding
            let pairs = [(fixture.connectionID, "Selected.swift", "BaseOnly.swift"), (secondConnectionID, "BaseOnly.swift", "Selected.swift")]
            for (id, expected, unexpected) in pairs {
                let metadata = MCPRequestMetadata(connectionID: id, clientName: nil, windowID: route.identity.routeID)
                let treeRequest = ToolInvocationContext.trustedLocal(toolName: MCPWindowToolName.getFileTree, metadata: metadata)
                let reply = try await MCPInvocationContextBridge.withInvocation(treeRequest) { try await fixture.tree.binding(["mode": .string("selected")]) }
                let tree = try XCTUnwrap(reply.objectValue?["tree"]?.stringValue)
                XCTAssertTrue(tree.contains(expected), tree)
                XCTAssertFalse(tree.contains(unexpected), tree)

                let codeRequest = ToolInvocationContext.trustedLocal(toolName: MCPWindowToolName.getCodeStructure, metadata: metadata)
                let code = try await MCPInvocationContextBridge.withInvocation(codeRequest) { try await codeBinding(["signatures": .bool(false)]) }
                let seeds = (code.objectValue?["roots"]?.arrayValue ?? []).flatMap { root in
                    (root.objectValue?["seeds"]?.arrayValue ?? []).compactMap { $0.objectValue?["path"]?.stringValue }
                }
                XCTAssertEqual(seeds.map { ($0 as NSString).lastPathComponent }, [expected], String(describing: code))
            }
        }
    }

    @MainActor
    func testRegisteredCodeStructureRejectsContextReplacedBeforeReply() async throws {
        let runtime = try await makeHistoryRouteRuntime()
        try await AppDomainRuntimeComposition.shared.withRuntimeForTesting(runtime) {
            let replyGate = RouteInvocationGate()
            let fixture = try await registeredTreeAfterServerRelease(runtime: runtime, gate: replyGate)
            let name = MCPWindowToolName.getCodeStructure
            let registered = await runtime.toolRegistry.resolve(toolName: name, scope: .window(id: fixture.route.identity.routeID))
            let tool = try XCTUnwrap(registered)
            let metadata = MCPRequestMetadata(connectionID: fixture.connectionID, clientName: nil, windowID: fixture.route.identity.routeID)
            var changed = fixture.workspace
            changed.composeTabs[0].selection = StoredSelection(selectedPaths: [fixture.root.fullPath + "/BaseOnly.swift"])
            let document = try DomainWorkspaceAuthorityClient.document(for: changed, fileURL: fixture.documentURL)
            let pending = Task {
                let request = ToolInvocationContext.trustedLocal(toolName: name, metadata: metadata)
                return try await MCPInvocationContextBridge.withInvocation(request) { try await tool.binding(["signatures": .bool(false)]) }
            }
            addTeardownBlock {
                pending.cancel()
                await replyGate.release()
                _ = await pending.result
            }
            try await AsyncTestWait.waitUntil("code structure reply reached its final validation") { await replyGate.didEnter() }
            _ = await runtime.workspaceStore.registerReadDocument(document)
            await replyGate.release()
            let reply = try await pending.value
            XCTAssertEqual(reply.objectValue?["status"]?.stringValue, "unavailable")
            XCTAssertEqual(reply.objectValue?["issues"]?.arrayValue?.first?.objectValue?["code"]?.stringValue, "workspace_authority_superseded")
            XCTAssertEqual(reply.objectValue?["roots"]?.arrayValue, [])
            XCTAssertEqual(fixture.route.toolExecutionRuntime.activeExecutionCount, 0)
        }
    }

    @MainActor
    func testRegisteredFileTreeRejectsRevocationAcrossRealTreeAwaitButIgnoresUnrelatedPresenter() async throws {
        let runtime = try await makeHistoryRouteRuntime()
        try await AppDomainRuntimeComposition.shared.withRuntimeForTesting(runtime) {
            for change in ["context", "sameContext", "binding", "roots", "removed", "connection", "catalog", "close", "presentation", "cancel"] {
                let gate = RouteInvocationGate()
                let fixture = try await registeredTreeAfterServerRelease(runtime: runtime, worktree: true, gate: gate)
                let pending = Task { try await self.invokeTree(fixture, args: ["mode": .string("selected")]) }
                addTeardownBlock { pending.cancel()
                    await gate.release()
                    _ = await pending.result
                }
                try await AsyncTestWait.waitUntil("tree reply validation entered") { await gate.didEnter() }
                switch change {
                case "context":
                    var replacement = fixture.workspace
                    replacement.composeTabs[0].selection = StoredSelection()
                    let document = try DomainWorkspaceDocument.decode(documentBytes: JSONEncoder().encode(replacement), fileURL: fixture.documentURL)
                    _ = await runtime.workspaceStore.registerReadDocument(document)
                case "sameContext":
                    var removed = fixture.workspace
                    removed.composeTabs = []
                    removed.activeComposeTabID = nil
                    _ = try await runtime.workspaceStore.registerReadDocument(DomainWorkspaceAuthorityClient.document(for: removed, fileURL: fixture.documentURL))
                    var successor = fixture.workspace
                    successor.composeTabs[0].name = "Same ID successor"
                    successor.composeTabs[0].selection = StoredSelection()
                    _ = try await runtime.workspaceStore.registerReadDocument(DomainWorkspaceAuthorityClient.document(for: successor, fileURL: fixture.documentURL))
                case "binding":
                    var successor = try XCTUnwrap(fixture.route.runRouteBindings.tabContextByConnectionID[fixture.connectionID])
                    successor.readFileAutoSelectionGeneration += 1
                    fixture.route.runRouteBindings.tabContextByConnectionID[fixture.connectionID] = successor
                    fixture.route.publishBinding(connectionID: fixture.connectionID, context: successor)
                    await fixture.route.settleRoutingPublications()
                case "roots": try await fixture.files.replaceRootLifetimeForTesting(rootID: fixture.root.id)
                case "removed":
                    await fixture.files.unloadRoot(id: fixture.root.id)
                    await fixture.lease.release()
                case "connection":
                    _ = await runtime.routingCoordinator.registerConnection(connectionID: fixture.connectionID, operationID: UUID())
                case "catalog": try await fixture.route.unregisterCatalog(XCTUnwrap(fixture.route.catalogHandle))
                case "close": fixture.route.closeDomainAdmission()
                case "presentation":
                    _ = await runtime.routingCoordinator.openWindow(windowID: 100_000, activeWorkspaceID: UUID(), activeContextID: UUID(), presentationRevision: 1, operationID: UUID())
                case "cancel": pending.cancel()
                default: XCTFail("Unknown case")
                }
                await gate.release()
                do {
                    let value = try await pending.value
                    if change == "presentation" {
                        XCTAssertTrue(value.objectValue?["tree"]?.stringValue?.contains("Selected.swift") == true)
                    } else {
                        XCTAssertNotNil(value.objectValue?["error_code"], "Must not return stale bytes after \(change): \(value)")
                        XCTAssertFalse(value.objectValue?["tree"]?.stringValue?.contains("Selected.swift") == true)
                    }
                } catch is CancellationError { XCTAssertEqual(change, "cancel")
                } catch is MCPToolExecutionCancelledError { XCTAssertEqual(change, "cancel")
                } catch ServerNetworkManager.ToolDispatchAdmissionError.windowTerminal {
                    XCTAssertTrue(["catalog", "close", "binding"].contains(change))
                } catch is DomainReadContextResolutionError { XCTAssertEqual(change, "connection") }
                XCTAssertEqual(fixture.route.toolExecutionRuntime.activeExecutionCount, 0)
            }
        }
    }

    @MainActor
    func testRegisteredFileTreeDrainsCanonicalHighWaterOnlyForSelectedMode() async throws {
        let runtime = try await makeHistoryRouteRuntime()
        try await AppDomainRuntimeComposition.shared.withRuntimeForTesting(runtime) {
            let fixture = try await registeredTreeAfterServerRelease(runtime: runtime)
            let metadata = MCPRequestMetadata(connectionID: fixture.connectionID, clientName: nil, windowID: fixture.route.identity.routeID)
            let connection = try fixture.route.fileReadConnection(metadata: metadata, workspaceID: fixture.workspace.id)
            let handle = try await fixture.route.fileReadHandle(for: connection)
            var changed = fixture.workspace
            changed.composeTabs[0].selection = StoredSelection(selectedPaths: [fixture.root.fullPath + "/BaseOnly.swift"])
            let document = try DomainWorkspaceDocument.decode(documentBytes: JSONEncoder().encode(changed), fileURL: fixture.documentURL)
            let gate = RouteInvocationGate()
            addTeardownBlock { await gate.release() }
            _ = try await runtime.readSideEffectCoordinator.submit(handle: handle, effectClass: .selection, operationID: UUID(), fingerprint: "tree-selection") {
                await gate.enter()
                _ = await runtime.workspaceStore.registerReadDocument(document)
            }
            try await AsyncTestWait.waitUntil("selection effect entered") { await gate.didEnter() }
            var completed = false
            let full = Task { @MainActor in
                let value = try await self.invokeTree(fixture, args: ["mode": .string("full")])
                completed = true
                return value
            }
            addTeardownBlock { full.cancel()
                await gate.release()
                _ = await full.result
            }
            try await AsyncTestWait.waitUntil("non-selected tree must not drain selection") { await MainActor.run { completed } }
            _ = try await full.value
            let selected = Task { try await self.invokeTree(fixture, args: ["mode": .string("selected")]) }
            addTeardownBlock { selected.cancel()
                await gate.release()
                _ = await selected.result
            }
            await gate.release()
            let value = try await selected.value
            let tree = try XCTUnwrap(value.objectValue?["tree"]?.stringValue)
            XCTAssertNil(value.objectValue?["error_code"], tree)
            XCTAssertTrue(tree.contains("BaseOnly.swift"), tree)
            XCTAssertFalse(tree.contains("Selected.swift"), "Selection is captured after the real side-effect ACK and domain revision refresh")
        }
    }

    @MainActor
    func testRegisteredFileTreeRefusesExtraStoreRootAndSameIDSuccessor() async throws {
        let runtime = try await makeHistoryRouteRuntime()
        try await AppDomainRuntimeComposition.shared.withRuntimeForTesting(runtime) {
            let fixture = try await registeredTreeAfterServerRelease(runtime: runtime)
            let extra = runtime.configuration.temporaryDirectory.appendingPathComponent("foreign")
            try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
            try "foreign".write(to: extra.appendingPathComponent("MustNotEscape.swift"), atomically: true, encoding: .utf8)
            let root = try await fixture.files.loadRoot(path: extra.path)
            addTeardownBlock { await fixture.files.unloadRoot(id: root.id) }
            let denied = try await invokeTree(fixture, args: ["mode": .string("full")])
            XCTAssertEqual(denied.objectValue?["error_code"], .string("workspace_authority_mismatch"))
            XCTAssertFalse(denied.objectValue?["tree"]?.stringValue?.contains("MustNotEscape.swift") == true)
            try await fixture.route.unregisterCatalog(XCTUnwrap(fixture.route.catalogHandle))
            let successor = try await registeredTreeAfterServerRelease(runtime: runtime, identity: fixture.route.identity)
            do {
                _ = try await invokeTree(fixture, args: [:])
                XCTFail("Original binding cannot borrow a same-ID successor")
            } catch ServerNetworkManager.ToolDispatchAdmissionError.windowTerminal {}
            await fixture.route.close()
            let value = try await invokeTree(successor, args: ["mode": .string("full")])
            XCTAssertNil(value.objectValue?["error_code"])
        }
    }

    @MainActor
    func testRegisteredFileTreeNetworkBindingRequiresOriginalCatalogOwnerProof() async throws {
        let runtime = try await makeHistoryRouteRuntime()
        try await AppDomainRuntimeComposition.shared.withRuntimeForTesting(runtime) {
            let recorder = RouteInvocationGate()
            let fixture = try await registeredTreeAfterServerRelease(runtime: runtime, validation: { _, _, _ in await recorder.recordValidation() })
            let route = fixture.route
            let handle = try XCTUnwrap(route.catalogHandle)
            let captured = await ServerNetworkManager.shared.captureWindowToolDispatchIdentity(windowID: route.identity.routeID, catalogRegistrationHandle: handle)
            let original = try XCTUnwrap(captured)
            let foreignOwner = NSObject()
            for change in ["catalog", "owner", "missing", "none"] {
                let dispatch = MCPWindowToolDispatchIdentity(windowID: original.windowID, windowStateIdentity: original.windowStateIdentity, serverViewModelIdentity: change == "owner" ? ObjectIdentifier(foreignOwner) : original.serverViewModelIdentity, catalogRegistrationHandle: change == "catalog" ? .init(registryID: handle.registryID, registrationID: .init(), generation: handle.generation) : handle)
                let invocationID = UUID()
                let invocation = ToolInvocationContext(origin: .network, invocationID: invocationID, requestID: nil, toolName: "get_file_tree", metadata: .init(connectionID: fixture.connectionID, clientName: nil, windowID: route.identity.routeID, invocationID: invocationID), dispatchAuthorization: change == "missing" ? nil : .init(connectionID: fixture.connectionID, connectionIdentity: ObjectIdentifier(foreignOwner), lifecycleGeneration: 1, windowIdentity: dispatch))
                let before = await recorder.validationCalls
                do {
                    let value = try await MCPInvocationContextBridge.withInvocation(invocation) { try await fixture.tree.binding(["mode": .string("full")]) }
                    XCTAssertEqual(change, "none")
                    XCTAssertNil(value.objectValue?["error_code"])
                } catch MCPInvocationContextFailure.missingAuthorization { XCTAssertEqual(change, "missing")
                } catch ServerNetworkManager.ToolDispatchAdmissionError.windowTerminal { XCTAssertTrue(["catalog", "owner"].contains(change)) }
                let after = await recorder.validationCalls
                if change == "none" { XCTAssertGreaterThan(after, before) }
                else { XCTAssertEqual(after, before) }
            }
        }
    }

    @MainActor
    private func registeredHistoryAfterServerRelease(
        runtime: MCPDomainRuntime, scanner: RouteHistoryScanner,
        identity: MCPHostRouteIdentity? = nil, validation: MCPToolInvocationValidator? = nil
    ) async throws -> (MCPHostRouteResources, MCPDomainResolvedTool, MCPDomainResolvedTool) {
        let route = MCPHostRouteResources(
            identity: identity ?? MCPRouteIdentityAllocator.allocateHost(), coordinator: runtime.routingCoordinator, runtime: runtime
        )
        addTeardownBlock { await route.close() }
        let service = makeService()
        var server: MCPServerViewModel? = makeServerViewModel(service: service, validation: validation)
        let serverIsReleased = { @MainActor [weak server] in server == nil }
        server?.historyScannerFactoryForTesting = { scanner }
        let catalog = try XCTUnwrap(server).makeToolCatalog(route: route)
        _ = await route.ensureRegistered(workspaceID: nil, contextID: nil, revision: 0)
        let handle = try await route.registerCatalog(catalog)
        let captured = await runtime.toolRegistry.resolve(toolName: "history", scope: .window(id: route.identity.routeID))
        let history = try XCTUnwrap(captured)
        XCTAssertEqual(history.handle, handle)
        let other = await runtime.toolRegistry.resolve(toolName: "read_file", scope: .window(id: route.identity.routeID))
        server?.stopServiceObservation()
        server = nil
        await waitUntil { serverIsReleased() }
        XCTAssertTrue(serverIsReleased(), "The registered invocation binding must not retain its server VM")
        return try (route, history, XCTUnwrap(other))
    }

    @MainActor
    private func invokeRegistered(_ tool: MCPDomainResolvedTool, routeID: Int, connectionID: UUID? = nil) async throws -> Value {
        let invocation = ToolInvocationContext.trustedLocal(
            toolName: tool.binding.definition.name,
            metadata: .init(connectionID: connectionID, clientName: nil, windowID: routeID)
        )
        return try await MCPInvocationContextBridge.withInvocation(invocation) {
            try await tool.binding(["op": .string("list_sessions")])
        }
    }

    @MainActor
    func testRegisteredHistoryBindingOutlivesServerButNotOriginalRoute() async throws {
        let runtime = try await makeHistoryRouteRuntime()
        try await AppDomainRuntimeComposition.shared.withRuntimeForTesting(runtime) {
            let scanner = RouteHistoryScanner()
            let (route, history, readFile) = try await registeredHistoryAfterServerRelease(runtime: runtime, scanner: scanner)
            let workspace = WorkspaceModel(name: "Route-only history authority", repoPaths: [])
            let authority = DomainWorkspaceAuthorityClient(store: runtime.workspaceStore, windowID: route.identity.routeID)
            _ = try await authority.create(
                workspace, fileURL: runtime.configuration.workspaceStorageDirectory.appendingPathComponent("route-only.json")
            )
            guard case let .matched(location) = await route.historyWorkspaceLocations.resolve(.id(workspace.id)) else {
                return XCTFail("History must read the route runtime's store, not the absent server authority")
            }
            XCTAssertEqual(location.runtimeID, runtime.identity.runtimeID)
            XCTAssertEqual(location.workspaceID, workspace.id)
            let value = try await invokeRegistered(history, routeID: route.identity.routeID)
            XCTAssertEqual(value.objectValue?["total_sessions"], .int(0))
            let scans = await scanner.scans
            XCTAssertEqual(scans, 1, "The actual registered catalog binding must reach the existing history backend")
            XCTAssertEqual(route.toolExecutionRuntime.activeExecutionCount, 0)
            do {
                _ = try await invokeRegistered(readFile, routeID: route.identity.routeID)
                XCTFail("Unmigrated file capabilities must not enter physical-window execution")
            } catch let error as MCPError {
                XCTAssertEqual(error, .invalidRequest("Tool read_file is not supported by the independent Agent session route"))
            }
            route.closeDomainAdmission()
            do {
                _ = try await invokeRegistered(history, routeID: route.identity.routeID)
                XCTFail("Closing the original route must refuse even with a retained binding")
            } catch ServerNetworkManager.ToolDispatchAdmissionError.windowTerminal {}
            let finalScans = await scanner.scans
            XCTAssertEqual(finalScans, 1)
        }
    }

    @MainActor
    func testRegisteredHistoryNetworkInvocationRequiresExactOriginalDispatchProof() async throws {
        let runtime = try await makeHistoryRouteRuntime()
        try await AppDomainRuntimeComposition.shared.withRuntimeForTesting(runtime) {
            let recorder = RouteInvocationGate()
            let scanner = RouteHistoryScanner()
            let (route, history, _) = try await registeredHistoryAfterServerRelease(
                runtime: runtime, scanner: scanner, validation: { _, _, _ in await recorder.recordValidation() }
            )
            let handle = try XCTUnwrap(route.catalogHandle)
            let captured = await ServerNetworkManager.shared.captureWindowToolDispatchIdentity(
                windowID: route.identity.routeID, catalogRegistrationHandle: handle
            )
            let original = try XCTUnwrap(captured)
            let foreignOwner = NSObject()
            let connectionID = UUID()
            for change in ["catalog", "owner", "missing", "none"] {
                let dispatch = MCPWindowToolDispatchIdentity(
                    windowID: original.windowID, windowStateIdentity: original.windowStateIdentity,
                    serverViewModelIdentity: change == "owner" ? ObjectIdentifier(foreignOwner) : original.serverViewModelIdentity,
                    catalogRegistrationHandle: change == "catalog" ? .init(
                        registryID: handle.registryID, registrationID: .init(), generation: handle.generation
                    ) : handle
                )
                let invocationID = UUID()
                let context = ToolInvocationContext(
                    origin: .network, invocationID: invocationID, requestID: nil, toolName: "history",
                    metadata: .init(connectionID: connectionID, clientName: nil, windowID: route.identity.routeID, invocationID: invocationID),
                    dispatchAuthorization: change == "missing" ? nil : .init(
                        connectionID: connectionID, connectionIdentity: ObjectIdentifier(foreignOwner), lifecycleGeneration: 1,
                        windowIdentity: dispatch
                    )
                )
                let before = await recorder.validationCalls
                do {
                    _ = try await MCPInvocationContextBridge.withInvocation(context) {
                        try await history.binding(["op": .string("list_sessions")])
                    }
                    XCTAssertEqual(change, "none")
                } catch MCPInvocationContextFailure.missingAuthorization {
                    XCTAssertEqual(change, "missing")
                } catch ServerNetworkManager.ToolDispatchAdmissionError.windowTerminal {
                    XCTAssertTrue(change == "catalog" || change == "owner")
                }
                let after = await recorder.validationCalls
                if change == "none" { XCTAssertGreaterThan(after, before) }
                else { XCTAssertEqual(after, before, "Wrong original proof must refuse before the injected validator") }
            }
            let scans = await scanner.scans
            XCTAssertEqual(scans, 1)
        }
    }

    @MainActor
    func testIndependentRouteCatalogIsReadyWithoutPresentationUntilClosed() async throws {
        let runtime = try await makeHistoryRouteRuntime()
        try await AppDomainRuntimeComposition.shared.withRuntimeForTesting(runtime) {
            try await AppGlobalMCPServiceComposition.shared.ensureRegistered()
            let (route, _, _) = try await registeredHistoryAfterServerRelease(runtime: runtime, scanner: RouteHistoryScanner())
            let ready = await MCPToolCatalogReadiness.shared.awaitReady(windowID: route.identity.routeID)
            XCTAssertTrue(ready)
            await route.close()
            let closedIsReady = await MCPToolCatalogReadiness.shared.awaitReady(windowID: route.identity.routeID, timeout: 0.25)
            XCTAssertFalse(closedIsReady)
        }
    }

    @MainActor
    func testEnteredRouteMappingRetainsOnlyOriginalCleanupOwnerUntilConsumed() async throws {
        let runtime = try await makeHistoryRouteRuntime()
        try await AppDomainRuntimeComposition.shared.withRuntimeForTesting(runtime) {
            let route = MCPHostRouteResources(
                identity: MCPRouteIdentityAllocator.allocateHost(), coordinator: runtime.routingCoordinator, runtime: runtime
            )
            addTeardownBlock { await route.close() }
            var server: MCPServerViewModel? = makeServerViewModel(service: makeService())
            let serverIsReleased = { @MainActor [weak server] in server == nil }
            let catalog = try XCTUnwrap(server).makeToolCatalog(route: route)
            _ = await route.ensureRegistered(workspaceID: nil, contextID: nil, revision: 0)
            _ = try await route.registerCatalog(catalog)
            let network = ServerNetworkManager.shared
            let receiptValue = await network.installClientConnectionPolicy(
                for: "binding-cleanup-\(UUID())", windowID: route.identity.routeID,
                restrictedTools: [], runID: UUID(), purpose: .agentModeRun, routingOwner: route
            )
            let receipt = try XCTUnwrap(receiptValue)
            let installed = await route.installPendingPolicy(receipt, connectionID: UUID(), clientName: nil, tabID: nil)
            XCTAssertNotNil(installed)
            server?.stopServiceObservation()
            server = nil
            XCTAssertFalse(serverIsReleased(), "An entered mapping retains its exact physical cleanup adapter")
            await route.close()
            XCTAssertFalse(serverIsReleased(), "Closing admission is not acknowledgement of mapping cleanup")
            await network.cleanupRunRoutingState(ownedBy: receipt)
            await waitUntil { serverIsReleased() }
            XCTAssertTrue(serverIsReleased())
        }
    }

    @MainActor
    func testRegisteredHistoryRechecksCatalogRevocationAcrossInvocationAwait() async throws {
        let runtime = try await makeHistoryRouteRuntime()
        try await AppDomainRuntimeComposition.shared.withRuntimeForTesting(runtime) {
            let scanner = RouteHistoryScanner()
            let gate = RouteInvocationGate()
            let (route, history, _) = try await registeredHistoryAfterServerRelease(
                runtime: runtime, scanner: scanner, validation: { _, _, _ in
                    await gate.enter()
                    return true
                }
            )
            let pending = Task { try await self.invokeRegistered(history, routeID: route.identity.routeID) }
            await gate.waitUntilEntered()
            let original = try XCTUnwrap(route.catalogHandle)
            await route.unregisterCatalog(original)
            await gate.release()
            do {
                _ = try await pending.value
                XCTFail("Catalog revocation during admission must prevent provider entry")
            } catch ServerNetworkManager.ToolDispatchAdmissionError.windowTerminal {}
            let scans = await scanner.scans
            XCTAssertEqual(scans, 0)
            XCTAssertEqual(route.toolExecutionRuntime.activeExecutionCount, 0)
        }
    }

    @MainActor
    func testRegisteredHistoryNeverFollowsSameIDReplacementOrLateCleanup() async throws {
        let runtime = try await makeHistoryRouteRuntime()
        try await AppDomainRuntimeComposition.shared.withRuntimeForTesting(runtime) {
            let originalScanner = RouteHistoryScanner()
            let (original, history, _) = try await registeredHistoryAfterServerRelease(runtime: runtime, scanner: originalScanner)
            let handle = try XCTUnwrap(original.catalogHandle)
            let originalDescriptor = try XCTUnwrap(original.descriptor)
            await original.unregisterCatalog(handle)
            let successorScanner = RouteHistoryScanner()
            let (successor, replacement, _) = try await registeredHistoryAfterServerRelease(
                runtime: runtime, scanner: successorScanner, identity: original.identity
            )
            let successorDescriptor = try XCTUnwrap(successor.descriptor)
            XCTAssertNotEqual(originalDescriptor.generation, successorDescriptor.generation)
            do {
                _ = try await invokeRegistered(history, routeID: original.identity.routeID)
                XCTFail("The old binding must not borrow the successor's catalog or route proof")
            } catch ServerNetworkManager.ToolDispatchAdmissionError.windowTerminal {}
            await original.close()
            let routing = await runtime.routingCoordinator.snapshot()
            XCTAssertTrue(routing.windows.contains {
                $0.windowID == successorDescriptor.windowID && $0.generation == successorDescriptor.generation && !$0.isClosing
            }, "Late close must leave the successor domain descriptor registered")
            let value = try await invokeRegistered(replacement, routeID: successor.identity.routeID)
            XCTAssertEqual(value.objectValue?["total_sessions"], .int(0))
            let oldScans = await originalScanner.scans
            let newScans = await successorScanner.scans
            XCTAssertEqual(oldScans, 0)
            XCTAssertEqual(newScans, 1, "Original cleanup must leave the replacement route usable")
        }
    }

    @MainActor
    func testRegisteredHistoryPreservesProviderErrorCancellationAndEnteredWork() async throws {
        let runtime = try await makeHistoryRouteRuntime()
        try await AppDomainRuntimeComposition.shared.withRuntimeForTesting(runtime) {
            let scanner = RouteHistoryScanner()
            let (route, history, _) = try await registeredHistoryAfterServerRelease(runtime: runtime, scanner: scanner)
            await scanner.setFailure(true)
            do {
                _ = try await invokeRegistered(history, routeID: route.identity.routeID)
                XCTFail("The original provider error must not become a route failure or retry")
            } catch RouteHistoryScanner.Failure.scan {}
            let gate = RouteInvocationGate()
            await scanner.block(on: gate)
            let connectionID = UUID(), runID = UUID()
            let installed = await ServerNetworkManager.shared.installClientConnectionPolicy(
                for: "history-index-\(UUID())", windowID: route.identity.routeID,
                restrictedTools: [], runID: runID, purpose: .agentModeRun, routingOwner: route
            )
            let cleanup = try XCTUnwrap(installed)
            XCTAssertEqual(route.runRouteBindings.register(
                connectionID: connectionID, runID: runID, windowID: route.identity.routeID, cleanupReceipt: cleanup
            ), .registered(displacedConnectionID: nil))
            let pending = Task { try await self.invokeRegistered(history, routeID: route.identity.routeID, connectionID: connectionID) }
            await gate.waitUntilEntered()
            XCTAssertTrue(route.toolExecutionRuntime.hasActiveToolExecutions(runID: runID))
            pending.cancel()
            await gate.release()
            do {
                _ = try await pending.value
                XCTFail("Cancellation must remain cancellation after provider entry")
            } catch is MCPToolExecutionCancelledError {}
            let scans = await scanner.scans
            XCTAssertEqual(scans, 2, "Entered provider work is retained; no retry or effect rollback is fabricated")
            XCTAssertEqual(route.toolExecutionRuntime.activeExecutionCount, 0)
            await ServerNetworkManager.shared.cleanupRunRoutingState(ownedBy: cleanup)
        }
    }

    /// Composition must leave old events untouched: pruning belongs to window
    /// appearance, not to any of the per-window view-model constructors.
    @MainActor
    func testTwentySixViewModelsDoNotPruneEventDirectoryDuringComposition() throws {
        let directory = MCPExternalClientEvent.eventsDirectoryURL
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let prefix = "startup-scale-" + UUID().uuidString
        let files = (0 ..< 3000).map { directory.appendingPathComponent("\(prefix)-\($0).json") }
        defer {
            for file in files {
                try? FileManager.default.removeItem(at: file)
            }
        }
        for file in files {
            try Data("{}".utf8).write(to: file)
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-8 * 24 * 3600)],
                ofItemAtPath: file.path
            )
        }

        let service = makeService()
        var servers: [MCPServerViewModel] = []
        let started = ProcessInfo.processInfo.systemUptime
        for _ in 0 ..< 26 {
            servers.append(makeServerViewModel(service: service))
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        defer { for server in servers {
            server.stopServiceObservation()
        } }

        print("STARTUP_SCALE windows=26 events=3000 composition_seconds=\(elapsed)")
        XCTAssertLessThan(elapsed, 5, "Window composition must not wait on repeated event housekeeping")
        XCTAssertTrue(
            files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) },
            "View-model composition must not prune old events"
        )
    }

    /// The view model's observation loop must not retain the view model: after
    /// teardown stops observation and external references drop, the VM (and its
    /// subscription) must be released. On the shared-stream implementation the
    /// loop held `self` forever and the subscriber slot leaked.
    @MainActor
    func testViewModelDeallocatesAfterObservationStops() async {
        let service = makeService()
        var server: MCPServerViewModel? = makeServerViewModel(service: service)
        weak var weakServer = server

        // The observation task subscribes asynchronously; wait for it to land.
        await waitUntil { await service.stateSubscriberCountForTesting() == 1 }

        server?.stopServiceObservation()
        server = nil

        await waitUntil { weakServer == nil }
        await waitUntil { await service.stateSubscriberCountForTesting() == 0 }
    }

    /// The live window's view model must observe a pending approval, which is
    /// what surfaces the approval overlay.
    @MainActor
    func testViewModelAppliesPendingApprovalSnapshot() async {
        let service = makeService()
        let server = makeServerViewModel(service: service)

        await service.setPendingApprovalForTesting("client-live")

        await waitUntil { server.pendingClientID == "client-live" }
        XCTAssertTrue(server.isApprovalOverlayVisible)

        server.stopServiceObservation()
    }
}

final class MCPExternalEventsCleanupTests: XCTestCase {
    @MainActor
    func testManyWindowAppearancesPruneOnceOffMainThread() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let started = expectation(description: "background prune started")
        started.assertForOverFulfill = true
        let executions = ExecutionCounter()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let monitor = MCPExternalEventsMonitor(eventsDirectory: directory) { _ in
            XCTAssertFalse(Thread.isMainThread)
            executions.increment()
            started.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
        }

        let first = monitor.scheduleCleanupOnce()
        XCTAssertEqual(executions.value, 0, "No prune in the synchronous appearance turn")
        await fulfillment(of: [started], timeout: 5)
        var tasks: [Task<Void, Never>] = []
        for _ in 0 ..< 25 {
            tasks.append(monitor.scheduleCleanupOnce())
        }
        XCTAssertEqual(executions.value, 1)
        release.signal()
        await first.value
        for task in tasks {
            await task.value
        }
        // Later windows must not restart maintenance after the first pass finishes.
        await monitor.scheduleCleanupOnce().value
        XCTAssertEqual(executions.value, 1)
    }

    func testSymlinkRetentionMatchesPreviousMetadataLookupWithoutRemovingTargets() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = root.appendingPathComponent("events")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cutoff = now.addingTimeInterval(-7 * 24 * 3600)
        let cases: [(String, TimeInterval, TimeInterval?)] = [
            ("recent-link.json", -60, -8 * 24 * 3600),
            ("old-link.json", -8 * 24 * 3600, -60),
            ("dangling.json", -8 * 24 * 3600, nil)
        ]
        var expectedNames: Set<String> = []
        var targets: [URL] = []
        for (name, linkAge, targetAge) in cases {
            let target = root.appendingPathComponent(name + ".target")
            if let targetAge {
                try Data("target".utf8).write(to: target)
                try FileManager.default.setAttributes(
                    [.modificationDate: now.addingTimeInterval(targetAge)], ofItemAtPath: target.path
                )
                targets.append(target)
            }
            let link = directory.appendingPathComponent(name)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            let timestamp = timespec(tv_sec: Int(now.addingTimeInterval(linkAge).timeIntervalSince1970), tv_nsec: 0)
            let times = [timestamp, timestamp]
            let result = times.withUnsafeBufferPointer {
                utimensat(AT_FDCWD, link.path, $0.baseAddress, AT_SYMLINK_NOFOLLOW)
            }
            XCTAssertEqual(result, 0)
            // Characterize the original decision, including dangling links, rather
            // than inventing a new link-following policy.
            let attributes = try FileManager.default.attributesOfItem(atPath: link.path)
            let modification = try XCTUnwrap(attributes[.modificationDate] as? Date)
            if modification >= cutoff { expectedNames.insert(name) }
        }

        MCPExternalEventsMonitor.cleanupOldEvents(in: directory, now: now)
        XCTAssertEqual(try Set(FileManager.default.contentsOfDirectory(atPath: directory.path)), expectedNames)
        for target in targets {
            XCTAssertEqual(try Data(contentsOf: target), Data("target".utf8))
        }
    }

    func testRetentionPreservesRecentBoundaryHiddenAndNonJSONFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let retention: TimeInterval = 7 * 24 * 3600
        let cases: [(String, TimeInterval, Bool)] = [
            ("old.json", -retention - 1, false),
            ("cli-old.json", -retention - 1, false),
            ("boundary.json", -retention, true),
            ("recent.json", -60, true),
            ("future.json", 60, true),
            (".hidden.json", -retention - 1, true),
            ("old.txt", -retention - 1, true)
        ]
        for (name, age, _) in cases {
            let url = directory.appendingPathComponent(name)
            try Data("{}".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(age)], ofItemAtPath: url.path)
        }

        MCPExternalEventsMonitor.cleanupOldEvents(in: directory, now: now)
        for (name, _, shouldExist) in cases {
            XCTAssertEqual(FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path), shouldExist, name)
        }
        // Missing directories remain a best-effort no-op.
        MCPExternalEventsMonitor.cleanupOldEvents(in: directory.appendingPathComponent("missing"), now: now)
    }
}

private final class ExecutionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
    }
}

#if DEBUG
    final class MCPConnectionAdmissionTests: XCTestCase {
        private func principal(pid: Int32 = 400, start: UInt64 = 1, parent: Int32 = 200) -> MCPApprovalProcessIdentity {
            MCPApprovalProcessIdentity(
                pid: pid, parentPID: parent, effectiveUID: geteuid(),
                startSeconds: start, startMicroseconds: 5, executablePath: "/test/launcher"
            )
        }

        func testSuspendedLivenessCheckCannotBeOvertakenByNewArrival() async {
            // Exercise both an initial arrival and a head dequeued after resolving UI.
            for queuedHead in [false, true] {
                let controller = ServerController(installNetworkCallbacks: false)
                let events = AdmissionEvents()
                let suspended = expectation(description: "FIFO head suspended (queued: \(queuedHead))")
                let gate = ApprovalLivenessGate(suspended: suspended)
                await controller.setApprovalCallback { clientID, generation, _ in
                    events.decide(clientID)
                    events.prompt(generation)
                }
                if queuedHead {
                    await controller.test_requestApproval(clientID: "active", approve: {}, deny: {})
                    await controller.test_requestApproval(
                        clientID: "head", isConnectionLive: { await gate.check() }, approve: {}, deny: {}
                    )
                }
                await gate.pause()
                let advance = Task {
                    if queuedHead {
                        await controller.resolvePendingApproval(allow: false, generation: events.generations[0])
                    } else {
                        await controller.test_requestApproval(
                            clientID: "head", isConnectionLive: { await gate.check() }, approve: {}, deny: {}
                        )
                    }
                }
                await fulfillment(of: [suspended], timeout: 2)
                await controller.test_requestApproval(clientID: "tail", approve: {}, deny: {})
                XCTAssertEqual(events.decisions, queuedHead ? ["active"] : [], "New arrival must not overtake the suspended head")
                await gate.resume()
                await advance.value
                XCTAssertEqual(events.decisions, queuedHead ? ["active", "head"] : ["head"])
                if let generation = events.generations.last {
                    await controller.resolvePendingApproval(allow: false, generation: generation)
                }
                XCTAssertEqual(events.decisions, queuedHead ? ["active", "head", "tail"] : ["head", "tail"])
                if let generation = events.generations.last {
                    await controller.resolvePendingApproval(allow: false, generation: generation)
                }
            }
        }

        private actor ApprovalLivenessGate {
            let suspended: XCTestExpectation
            private var paused = false
            private var continuation: CheckedContinuation<Bool, Never>?

            init(suspended: XCTestExpectation) {
                self.suspended = suspended
            }

            func pause() {
                paused = true
            }

            func check() async -> Bool {
                guard paused else { return true }
                return await withCheckedContinuation { continuation in
                    self.continuation = continuation
                    suspended.fulfill()
                }
            }

            func resume() {
                paused = false
                continuation?.resume(returning: true)
                continuation = nil
            }
        }

        func testSessionApprovalCoversReconnectsButNotSameNameOrRecycledPID() async {
            let controller = ServerController(installNetworkCallbacks: false, processIsCurrent: { _ in true })
            let events = AdmissionEvents()
            await controller.setApprovalCallback { _, generation, path in
                XCTAssertEqual(path, "/test/launcher")
                events.prompt(generation)
            }
            let launcher = principal()
            for _ in 0 ..< 2 {
                await controller.test_requestApproval(
                    clientID: "external-test-client", principal: launcher,
                    approve: { events.decide("allowed") }, deny: { events.decide("denied") }
                )
            }
            await controller.resolvePendingApproval(allow: true, generation: events.generations[0])
            XCTAssertEqual(events.decisions, ["allowed", "allowed"])
            await controller.test_requestApproval(
                clientID: "different-self-reported-name", principal: launcher,
                approve: { events.decide("reconnected") }, deny: { events.decide("denied") }
            )
            XCTAssertEqual(events.decisions.last, "reconnected")
            XCTAssertEqual(events.generations.count, 1)
            await controller.test_requestApproval(
                clientID: "external-test-client", principal: principal(start: 2),
                approve: {}, deny: {}
            )
            XCTAssertEqual(events.generations.count, 2)
            await controller.resolvePendingApproval(allow: false, generation: events.generations[1])
        }

        func testDenialCooldownDrainsQueuedRetriesAndDoesNotSlide() async {
            let clock = AdmissionClock()
            let controller = ServerController(
                installNetworkCallbacks: false, monotonicNow: { clock.now }, processIsCurrent: { _ in true }
            )
            let events = AdmissionEvents()
            await controller.setApprovalCallback { _, generation, _ in events.prompt(generation) }
            for _ in 0 ..< 2 {
                await controller.test_requestApproval(
                    clientID: "same-name", principal: principal(),
                    approve: { events.decide("allowed") }, deny: { events.decide("denied") }
                )
            }
            await controller.resolvePendingApproval(allow: false, generation: events.generations[0])
            XCTAssertEqual(events.decisions, ["denied", "denied"])
            clock.advance(59)
            await controller.test_requestApproval(
                clientID: "same-name", principal: principal(),
                approve: {}, deny: { events.decide("cooldown") }
            )
            XCTAssertEqual(events.decisions.last, "cooldown")
            XCTAssertEqual(events.generations.count, 1)
            clock.advance(2)
            await controller.test_requestApproval(clientID: "same-name", principal: principal(), approve: {}, deny: {})
            XCTAssertEqual(events.generations.count, 2)
            await controller.resolvePendingApproval(allow: false, generation: events.generations[1])
            await controller.test_requestApproval(
                clientID: "same-name", principal: principal(pid: 401), approve: {}, deny: {}
            )
            XCTAssertEqual(events.generations.count, 3)
            await controller.resolvePendingApproval(allow: false, generation: events.generations[2])
        }

        func testBundledHelperUsesImmediateParentButUnverifiedPeerCannot() {
            let launcher = principal()
            let helper = principal(pid: 500, parent: launcher.pid)
            let replacement = principal(pid: 501, parent: launcher.pid)
            let processes = [launcher.pid: launcher, helper.pid: helper, replacement.pid: replacement]
            XCTAssertEqual(MCPApprovalProcessIdentity.resolve(peerPID: helper.pid, bundledHelper: true, read: { processes[$0] }), launcher)
            XCTAssertEqual(MCPApprovalProcessIdentity.resolve(peerPID: replacement.pid, bundledHelper: true, read: { processes[$0] }), launcher)
            XCTAssertEqual(MCPApprovalProcessIdentity.resolve(peerPID: helper.pid, bundledHelper: false, read: { processes[$0] }), helper)
            XCTAssertNil(MCPApprovalProcessIdentity.resolve(peerPID: 999, bundledHelper: true, read: { processes[$0] }))
            XCTAssertNil(MCPApprovalProcessIdentity.resolve(peerPID: helper.pid, bundledHelper: true, read: { $0 == helper.pid ? helper : nil }))
            var reads = 0
            XCTAssertNil(MCPApprovalProcessIdentity.resolve(peerPID: helper.pid, bundledHelper: true, read: {
                reads += 1
                return reads == 3 ? replacement : processes[$0]
            }))
        }

        func testCapacityRetiresDeadEntriesBeforeLongLivedLauncherConsent() async throws {
            let lifetimes = AdmissionLiveness()
            let controller = ServerController(
                installNetworkCallbacks: false,
                processIsCurrent: { $0.pid == 400 || $0.pid == 656 || lifetimes.isLive }
            )
            let events = AdmissionEvents()
            await controller.setApprovalCallback { _, generation, _ in events.prompt(generation) }
            for pid in Int32(400) ..< Int32(656) {
                await controller.test_requestApproval(clientID: "client", principal: principal(pid: pid), approve: {}, deny: {})
                let generation = try XCTUnwrap(events.generations.last)
                await controller.resolvePendingApproval(allow: true, generation: generation)
            }
            lifetimes.close()
            await controller.test_requestApproval(clientID: "client", principal: principal(pid: 656), approve: {}, deny: {})
            let generation = try XCTUnwrap(events.generations.last)
            await controller.resolvePendingApproval(allow: true, generation: generation)
            await controller.test_requestApproval(
                clientID: "long-lived-client", principal: principal(),
                approve: { events.decide("remembered") }, deny: { events.decide("denied") }
            )
            XCTAssertEqual(events.generations.count, 257)
            XCTAssertEqual(events.decisions, ["remembered"])
        }

        func testApprovalQueueIsBoundedAndResolvesOverflow() async {
            let controller = ServerController(installNetworkCallbacks: false)
            let events = AdmissionEvents()
            await controller.setApprovalCallback { _, generation, _ in events.prompt(generation) }
            for _ in 0 ..< 33 {
                await controller.test_requestApproval(clientID: "peer", approve: {}, deny: { events.decide("denied") })
            }
            XCTAssertEqual(events.generations.count, 1)
            XCTAssertEqual(events.decisions, ["denied"])
            for index in 0 ..< 32 {
                await controller.resolvePendingApproval(allow: false, generation: events.generations[index])
            }
            XCTAssertEqual(events.decisions.count, 33)
        }

        func testVanishedHelperRetainsConsentForLiveLauncherButCannotUseDeadConnection() async {
            let controller = ServerController(installNetworkCallbacks: false, processIsCurrent: { _ in true })
            let events = AdmissionEvents()
            await controller.setApprovalCallback { _, generation, _ in events.prompt(generation) }
            await controller.test_requestApproval(
                clientID: "external", principal: principal(), validate: { false },
                approve: { events.decide("unexpected") }, deny: { events.decide("gone") }
            )
            await controller.test_requestApproval(
                clientID: "external", principal: principal(),
                approve: { events.decide("allowed") }, deny: { events.decide("denied") }
            )
            await controller.resolvePendingApproval(allow: true, generation: events.generations[0])
            XCTAssertEqual(events.decisions, ["gone", "allowed"])
            XCTAssertEqual(events.generations.count, 1)
            await controller.test_requestApproval(
                clientID: "external", principal: principal(), validate: { false },
                approve: { events.decide("unexpected") }, deny: { events.decide("rejected") }
            )
            XCTAssertEqual(events.decisions, ["gone", "allowed", "rejected"])
            XCTAssertEqual(events.generations.count, 1)
        }

        /// Avoid blocking Process.waitUntilExit across actor hops and bound cleanup.
        /// The exact mechanism of the CI hang was not identified.
        private func withAdmissionChild(_ operation: (ChildProcessExitObserver) async throws -> Void) async throws {
            let process = try ProcessLauncher.spawn(
                command: "/bin/sleep", arguments: ["60"], environment: [:], workingDirectory: nil, purpose: .tool
            )
            let child = ChildProcessExitObserver.observe(pid: process.pid)
            process.stdin?.closeFile()
            process.stdout.closeFile()
            process.stderr.closeFile()
            do {
                try await operation(child)
            } catch {
                _ = await stopAdmissionChild(child)
                throw error
            }
            _ = await stopAdmissionChild(child)
        }

        private func stopAdmissionChild(_ child: ChildProcessExitObserver) async -> Bool {
            // The observer owns reaping and closes signaling before PID reuse.
            // Repeated cleanup after an explicit stop is therefore safe.
            _ = child.signalRootProcessFamilyIfUnreaped(processGroupID: nil, signal: SIGKILL)
            let outcome = await child.wait(timeout: 5)
            let expected = ChildProcessExitObserver.Outcome.exited(.uncaughtSignal(signal: SIGKILL))
            XCTAssertEqual(outcome, expected, "Synthetic admission child exit/cleanup was not confirmed within five seconds")
            return outcome == expected
        }

        /// Uses real OS child lifetimes to exercise process resolution and consent;
        /// bundled-executable verification and the MCP socket path are separate boundaries.
        func testRealChildRespawnsShareLauncherConsentEvenAfterPromptingChildExits() async throws {
            for allow in [true, false] {
                let controller = ServerController(installNetworkCallbacks: false)
                let events = AdmissionEvents()
                await controller.setApprovalCallback { _, generation, _ in events.prompt(generation) }
                try await withAdmissionChild { first in
                    let firstPID = first.pid
                    let firstPeer = try XCTUnwrap(MCPApprovalProcessIdentity.read(pid: firstPID))
                    let launcher = try XCTUnwrap(MCPApprovalProcessIdentity.resolve(peerPID: firstPID, bundledHelper: true))
                    XCTAssertEqual(launcher.pid, getpid())
                    await controller.test_requestApproval(
                        clientID: "external-test-client", principal: launcher,
                        validate: { MCPApprovalProcessIdentity.read(pid: firstPID) == firstPeer },
                        isConnectionLive: { MCPApprovalProcessIdentity.read(pid: firstPID) == firstPeer },
                        approve: { events.decide("unexpected") }, deny: { events.decide("old-helper-denied") }
                    )
                    guard await stopAdmissionChild(first) else { return }
                    try await withAdmissionChild { second in
                        let secondPID = second.pid
                        let secondPeer = try XCTUnwrap(MCPApprovalProcessIdentity.read(pid: secondPID))
                        let secondLauncher = try XCTUnwrap(MCPApprovalProcessIdentity.resolve(peerPID: secondPID, bundledHelper: true))
                        XCTAssertEqual(secondLauncher, launcher)
                        await controller.test_requestApproval(
                            clientID: "external-test-client", principal: secondLauncher,
                            validate: { MCPApprovalProcessIdentity.read(pid: secondPID) == secondPeer },
                            isConnectionLive: { MCPApprovalProcessIdentity.read(pid: secondPID) == secondPeer },
                            approve: { events.decide("new-helper-allowed") }, deny: { events.decide("new-helper-denied") }
                        )
                        await controller.resolvePendingApproval(allow: allow, generation: events.generations[0])
                        XCTAssertEqual(events.generations.count, 1)
                        XCTAssertEqual(events.decisions, ["old-helper-denied", allow ? "new-helper-allowed" : "new-helper-denied"])
                    }
                }
            }
        }

        func testClosedQueuedConnectionNeverPresentsAnotherDialog() async {
            let controller = ServerController(installNetworkCallbacks: false)
            let events = AdmissionEvents()
            let liveness = AdmissionLiveness()
            await controller.setApprovalCallback { _, generation, _ in events.prompt(generation) }
            await controller.test_requestApproval(clientID: "active", approve: { events.decide("active") }, deny: {})
            await controller.test_requestApproval(
                clientID: "closed", isConnectionLive: { liveness.isLive },
                approve: { events.decide("unexpected") }, deny: { events.decide("closed") }
            )
            liveness.close()
            await controller.resolvePendingApproval(allow: true, generation: events.generations[0])
            XCTAssertEqual(events.decisions, ["active", "closed"])
            XCTAssertEqual(events.generations.count, 1)
            await controller.test_requestApproval(
                clientID: "already-closed", isConnectionLive: { false }, approve: {}, deny: { events.decide("discarded") }
            )
            XCTAssertEqual(events.decisions.last, "discarded")
            XCTAssertEqual(events.generations.count, 1)
        }

        func testUnverifiedTimeoutDrainsOnlySameNameUnverifiedRequests() async {
            let controller = ServerController(installNetworkCallbacks: false)
            let events = AdmissionEvents()
            await controller.setApprovalCallback { _, generation, _ in events.prompt(generation) }
            for _ in 0 ..< 2 {
                await controller.test_requestApproval(clientID: "unknown", approve: {}, deny: { events.decide("timed-out") })
            }
            await controller.test_requestApproval(clientID: "other", approve: {}, deny: { events.decide("other") })
            await controller.test_timeoutApproval(generation: events.generations[0])
            XCTAssertEqual(events.decisions, ["timed-out", "timed-out"])
            XCTAssertEqual(events.generations.count, 2)
            await controller.resolvePendingApproval(allow: false, generation: events.generations[1])
        }

        func testTimeoutCreatesCooldownAndDrainsOnlyMatchingProcess() async {
            let controller = ServerController(installNetworkCallbacks: false, processIsCurrent: { _ in true })
            let events = AdmissionEvents()
            await controller.setApprovalCallback { _, generation, _ in events.prompt(generation) }
            for _ in 0 ..< 2 {
                await controller.test_requestApproval(
                    clientID: "external", principal: principal(), approve: {}, deny: { events.decide("timeout") }
                )
            }
            await controller.test_requestApproval(
                clientID: "external", principal: principal(pid: 401), approve: {}, deny: { events.decide("other") }
            )
            await controller.test_timeoutApproval(generation: events.generations[0])
            XCTAssertEqual(events.decisions, ["timeout", "timeout"])
            XCTAssertEqual(events.generations.count, 2)
            await controller.test_timeoutApproval(generation: events.generations[0])
            XCTAssertEqual(events.decisions.count, 2)
            await controller.resolvePendingApproval(allow: false, generation: events.generations[1])
        }

        func testProcessIdentityComesFromKernelAndDoesNotDependOnLauncherAncestry() throws {
            let observed = try XCTUnwrap(MCPApprovalProcessIdentity.read(pid: getpid()))
            XCTAssertEqual(observed.pid, getpid())
            XCTAssertEqual(observed.effectiveUID, geteuid())
            XCTAssertGreaterThan(observed.startSeconds, 0)
            XCTAssertFalse(observed.executablePath.isEmpty)
            XCTAssertEqual(principal(), principal(parent: 999))
            XCTAssertEqual(Set([principal(), principal(parent: 999)]).count, 1)
        }

        func testBundledHelperAdmissionStillRequiresExecutableVerification() {
            let names = [
                "claude-code", "codex-mcp-client", "gemini-cli-mcp-client",
                "opencode", "cursor", "cursor-mcp-client", "claude-ai",
                "Claude Code 2", "cursor-custom", "previously-approved-client",
                "RepoPrompt CLI", "RepoPrompt CLI Debug"
            ]
            for name in names {
                XCTAssertFalse(ServerController.canAutomaticallyApprove(clientName: name, bundledCLI: false), name)
            }
            XCTAssertTrue(ServerController.canAutomaticallyApprove(clientName: "RepoPrompt CLI", bundledCLI: true))
            XCTAssertTrue(ServerController.canAutomaticallyApprove(clientName: "RepoPrompt CLI Debug", bundledCLI: true))
            XCTAssertFalse(ServerController.canAutomaticallyApprove(clientName: "cursor", bundledCLI: true))
            XCTAssertFalse(ServerController.canSaveAlwaysAllowed(clientName: "RepoPrompt CLI"))
            XCTAssertFalse(ServerController.isBuiltInAlwaysAllowedClient("RepoPrompt CLI Debug"))
            XCTAssertTrue(ServerController.canSaveAlwaysAllowed(clientName: "external-test-client"))
            XCTAssertTrue(ServerController.isBuiltInAlwaysAllowedClient("cursor"))
        }

        func testLegacyNamesArePreservedAndCannotBypassBundledHelperVerification() throws {
            let suite = "MCPConnectionAdmissionTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let names = ["previously-approved-client", "RepoPrompt CLI", "cursor-custom"]
            defaults.set(names, forKey: "mcp.alwaysAllowedClients")
            XCTAssertEqual(ServerController.loadLegacyClientNames(defaults: defaults), Set(names))
            XCTAssertEqual(defaults.stringArray(forKey: "mcp.alwaysAllowedClients"), names)
            for name in names {
                XCTAssertFalse(ServerController.canAutomaticallyApprove(clientName: name, bundledCLI: false))
            }
        }

        func testStrictModeCannotSaveAlwaysAllowAndStaleResponseCannotSaveSuccessorName() async throws {
            for strict in [true, false] {
                let suite = "MCPConnectionAdmissionTests.\(UUID().uuidString)"
                let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
                defer { defaults.removePersistentDomain(forName: suite) }
                let controller = ServerController(
                    installNetworkCallbacks: false, approvalDefaults: defaults,
                    strictConnectionApprovalEnabled: { strict }
                )
                let events = AdmissionEvents()
                await controller.setApprovalCallback { _, generation, _ in events.prompt(generation) }
                for name in ["first", "second"] {
                    await controller.test_requestApproval(
                        clientID: name, approve: { events.decide(name) }, deny: {}
                    )
                }
                let first = try XCTUnwrap(events.generations.first)
                await controller.resolvePendingApproval(allow: true, generation: first, alwaysAllow: true)
                await controller.resolvePendingApproval(allow: true, generation: first, alwaysAllow: true)
                XCTAssertEqual(defaults.stringArray(forKey: "mcp.alwaysAllowedClients") ?? [], strict ? [] : ["first"])
                XCTAssertEqual(events.decisions, ["first"])
                await controller.resolvePendingApproval(allow: false, generation: events.generations[1])
            }
        }

        func testAlwaysAllowCannotPersistForClosedAnonymousConnectionOrExitedProcess() async throws {
            for (hasPrincipal, connectionIsValid) in [(false, false), (true, false), (true, true)] {
                let suite = "MCPConnectionAdmissionTests.\(UUID().uuidString)"
                let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
                defer { defaults.removePersistentDomain(forName: suite) }
                let process = AdmissionLiveness()
                let controller = ServerController(
                    installNetworkCallbacks: false, approvalDefaults: defaults,
                    strictConnectionApprovalEnabled: { false }, processIsCurrent: { _ in process.isLive }
                )
                let events = AdmissionEvents()
                await controller.setApprovalCallback { _, generation, _ in events.prompt(generation) }
                await controller.test_requestApproval(
                    clientID: "external-test-client", principal: hasPrincipal ? principal() : nil,
                    validate: { connectionIsValid },
                    approve: { events.decide("allowed") }, deny: { events.decide("denied") }
                )
                let generation = try XCTUnwrap(events.generations.first)
                process.close()
                await controller.resolvePendingApproval(allow: true, generation: generation, alwaysAllow: true)
                XCTAssertEqual(defaults.stringArray(forKey: "mcp.alwaysAllowedClients") ?? [], [])
                XCTAssertEqual(events.decisions, ["denied"])
            }
        }

        func testOneTimeApprovalDoesNotTransferToSameNamePeerOrStaleResponse() async {
            let controller = ServerController(installNetworkCallbacks: false)
            let events = AdmissionEvents()
            await controller.setApprovalCallback { _, generation, _ in events.prompt(generation) }
            await controller.test_requestApproval(
                clientID: "same-name", approve: { events.decide("first-allowed") }, deny: { events.decide("first-denied") }
            )
            await controller.test_requestApproval(
                clientID: "same-name", approve: { events.decide("second-allowed") }, deny: { events.decide("second-denied") }
            )
            XCTAssertEqual(events.generations.count, 1)
            let first = events.generations[0]
            await controller.resolvePendingApproval(allow: true, generation: first)
            XCTAssertEqual(events.decisions, ["first-allowed"])
            XCTAssertEqual(events.generations.count, 2)
            let second = events.generations[1]
            XCTAssertNotEqual(first, second)
            await controller.resolvePendingApproval(allow: true, generation: first)
            XCTAssertEqual(events.decisions, ["first-allowed"])
            await controller.resolvePendingApproval(allow: true, generation: second)
            XCTAssertEqual(events.decisions, ["first-allowed", "second-allowed"])
        }

        func testTwoWindowServiceResponsesCannotResolveSuccessorGeneration() async throws {
            let controller = ServerController(installNetworkCallbacks: false)
            let service = MCPService(
                controller: controller,
                hostBootstrapOperation: {}, controllerStartOperation: {}, controllerFullShutdownOperation: {}
            )
            let (windowA, streamA) = await service.subscribeToStateUpdates()
            let (windowB, streamB) = await service.subscribeToStateUpdates()
            let events = AdmissionEvents()
            await controller.setApprovalCallback { name, generation, executablePath in
                await service.setPendingApprovalForTesting(name, generation: generation, executablePath: executablePath)
                events.prompt(generation)
            }
            for peer in ["first", "second"] {
                await controller.test_requestApproval(
                    clientID: "same-name", approve: { events.decide("\(peer)-allowed") }, deny: { events.decide("\(peer)-denied") }
                )
            }
            // Init may have installed the equivalent production callback. Read the generations
            // from the service streams themselves, just as two windows do.
            var iteratorA = streamA.makeAsyncIterator()
            _ = await iteratorA.next() // seed
            let nextFirstSnapshot = await iteratorA.next()
            let firstSnapshot = try XCTUnwrap(nextFirstSnapshot)
            let first = try XCTUnwrap(firstSnapshot.pendingApprovalGeneration)
            await service.continuePendingApproval(allow: true, generation: first)
            _ = await iteratorA.next() // clear before successor
            let nextSecondSnapshot = await iteratorA.next()
            let secondSnapshot = try XCTUnwrap(nextSecondSnapshot)
            let second = try XCTUnwrap(secondSnapshot.pendingApprovalGeneration)
            XCTAssertNotEqual(first, second)
            XCTAssertEqual(secondSnapshot.pendingClientID, "same-name")
            await service.updateDiagnostics(MCPDiagnostics())
            // A delayed second-window click cannot clear or resolve the successor.
            await service.continuePendingApproval(allow: false, generation: first)
            XCTAssertEqual(events.decisions, ["first-allowed"])
            await service.continuePendingApproval(allow: false, generation: second)
            XCTAssertEqual(events.decisions, ["first-allowed", "second-denied"])
            // Publish a known diagnostic before finishing the streams, without relying
            // on when the controller's unawaited denial diagnostic happens to run.
            let marker = MCPDiagnostics(
                issue: .lastClientApprovalDenied(clientID: "same-name"),
                listenerStateDescription: "controlled approval diagnostic"
            )
            await service.updateDiagnostics(marker)
            await service.unsubscribeFromStateUpdates(id: windowA)
            await service.unsubscribeFromStateUpdates(id: windowB)
            var snapshotsB: [MCPService.Snapshot] = []
            for await snapshot in streamB {
                snapshotsB.append(snapshot)
            }
            // Diagnostics also publish snapshots; compare approval transitions, not notification counts.
            let approvalTransitions = snapshotsB.reduce(into: [MCPService.Snapshot]()) { transitions, snapshot in
                if let previous = transitions.last,
                   previous.pendingApprovalGeneration == snapshot.pendingApprovalGeneration,
                   previous.pendingClientID == snapshot.pendingClientID,
                   previous.pendingApprovalExecutablePath == snapshot.pendingApprovalExecutablePath
                { return }
                transitions.append(snapshot)
            }
            XCTAssertEqual(approvalTransitions.map(\.pendingApprovalGeneration), [nil, first, nil, second, nil])
            XCTAssertEqual(approvalTransitions.map(\.pendingClientID), [nil, "same-name", nil, "same-name", nil])
            XCTAssertEqual(approvalTransitions.map(\.pendingApprovalExecutablePath), [nil, nil, nil, nil, nil])
            // Diagnostic snapshots may also occur while the successor is pending. Start
            // the suffix after its final clear, rather than assuming five publications.
            let lastPendingIndex = try XCTUnwrap(snapshotsB.lastIndex { $0.pendingApprovalGeneration == second })
            let approvalSuffix = snapshotsB.dropFirst(lastPendingIndex + 2)
            _ = try XCTUnwrap(approvalSuffix.first { $0.diagnostics == marker })
            for snapshot in approvalSuffix {
                XCTAssertNil(snapshot.pendingClientID)
                XCTAssertNil(snapshot.pendingApprovalGeneration)
                XCTAssertNil(snapshot.pendingApprovalExecutablePath)
                XCTAssertNotEqual(snapshot.diagnostics, MCPDiagnostics(), "only diagnostic publications may follow the final clear")
            }
        }

        func testExplicitDenialRemainsConnectionSpecific() async {
            let controller = ServerController(installNetworkCallbacks: false)
            let events = AdmissionEvents()
            await controller.setApprovalCallback { _, generation, _ in events.prompt(generation) }
            for peer in ["first", "second"] {
                await controller.test_requestApproval(
                    clientID: "same-name", approve: { events.decide("\(peer)-allowed") }, deny: { events.decide("\(peer)-denied") }
                )
            }
            await controller.resolvePendingApproval(allow: false, generation: events.generations[0])
            XCTAssertEqual(events.decisions, ["first-denied"])
            await controller.resolvePendingApproval(allow: true, generation: events.generations[1])
            XCTAssertEqual(events.decisions, ["first-denied", "second-allowed"])
        }
    }

    private final class AdmissionLiveness: @unchecked Sendable {
        private let lock = NSLock()
        private var value = true
        var isLive: Bool {
            lock.withLock { value }
        }

        func close() {
            lock.withLock { value = false }
        }
    }

    private final class AdmissionClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: TimeInterval = 0
        var now: TimeInterval {
            lock.withLock { value }
        }

        func advance(_ seconds: TimeInterval) {
            lock.withLock { value += seconds }
        }
    }

    private final class AdmissionEvents: @unchecked Sendable {
        private let lock = NSLock()
        private var storedGenerations: [UInt64] = []
        private var storedDecisions: [String] = []

        var generations: [UInt64] {
            lock.withLock { storedGenerations }
        }

        var decisions: [String] {
            lock.withLock { storedDecisions }
        }

        func prompt(_ generation: UInt64) {
            lock.withLock { storedGenerations.append(generation) }
        }

        func decide(_ decision: String) {
            lock.withLock { storedDecisions.append(decision) }
        }
    }

    /// Isolated socket-level coverage: real MCP initialize, kernel peer credentials,
    /// production admission/identity/liveness, and connection removal. No app launch.
    final class MCPConnectionApprovalTransportTests: XCTestCase {
        func testAlwaysAllowPersistsAcrossReconnectAndControllerRestart() async throws {
            try await exerciseReconnectAndRestart(strict: false, clientName: "external-test-client")
        }

        func testBuiltInNamesAreAllowedByDefault() async throws {
            try await exerciseReconnectAndRestart(strict: false, clientName: "cursor")
        }

        func testStrictModeIgnoresSavedNamesAndResetsOnRestart() async throws {
            try await exerciseReconnectAndRestart(strict: true, clientName: "external-test-client")
        }

        func testStrictModeKeepsExplicitGlobalAutoApprove() async throws {
            try await exerciseReconnectAndRestart(strict: true, clientName: "external-test-client", autoApproveAll: true)
        }

        func testStrictModeAlsoPromptsForBuiltInNames() async throws {
            try await exerciseReconnectAndRestart(strict: true, clientName: "cursor")
        }

        private func exerciseReconnectAndRestart(
            strict: Bool, clientName: String, autoApproveAll: Bool = false
        ) async throws {
            let suite = "MCPConnectionApprovalTransportTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            // Strict runs start with a saved name that default mode would honor.
            if strict { defaults.set([clientName], forKey: "mcp.alwaysAllowedClients") }
            defaults.set(autoApproveAll, forKey: "mcpAutoApproveAllClients")
            let events = ApprovalEvents()
            // New owners model a RepoPrompt restart: only the same defaults survive.
            for _ in 0 ..< 2 {
                let network = ServerNetworkManager()
                let controller = ServerController(
                    networkManager: network, installNetworkCallbacks: false,
                    approvalDefaults: defaults, strictConnectionApprovalEnabled: { strict }
                )
                await controller.setApprovalCallback { [weak controller] name, generation, _ in
                    XCTAssertEqual(name, clientName)
                    events.prompt(generation)
                    await controller?.resolvePendingApproval(allow: true, generation: generation, alwaysAllow: true)
                }
                for _ in 0 ..< 2 {
                    let connection = try await makeConnection(network: network, controller: controller, clientName: clientName)
                    do {
                        _ = try await connection.client.connect(transport: connection.transport)
                    } catch {
                        await connection.close()
                        await network.stop()
                        throw error
                    }
                    await connection.close()
                }
                await controller.setApprovalCallback { _, _, _ in }
                await network.stop()
            }
            let expectedPrompts = autoApproveAll ? 0 : (strict ? 2 : (clientName == "cursor" ? 0 : 1))
            XCTAssertEqual(events.generations.count, expectedPrompts)
            XCTAssertEqual(defaults.stringArray(forKey: "mcp.alwaysAllowedClients") ?? [], clientName == "cursor" && !strict ? [] : [clientName])
        }

        func testAllowSurvivesSocketCloseBeforeClickAndAdmitsReconnectWithoutPrompt() async throws {
            try await exerciseDecisionAfterSocketCloses(allow: true)
        }

        func testDenySurvivesSocketCloseBeforeClickAndRejectsReconnectWithoutPrompt() async throws {
            try await exerciseDecisionAfterSocketCloses(allow: false)
        }

        func testAlwaysAllowSurvivesSocketCloseBeforeClickAndControllerRestart() async throws {
            try await exerciseDecisionAfterSocketCloses(allow: true, strict: false, alwaysAllow: true)
        }

        private func exerciseDecisionAfterSocketCloses(
            allow: Bool, strict: Bool = true, alwaysAllow: Bool = false
        ) async throws {
            let suite = "MCPConnectionApprovalTransportTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let network = ServerNetworkManager()
            let controller = ServerController(
                networkManager: network, installNetworkCallbacks: false,
                approvalDefaults: defaults, strictConnectionApprovalEnabled: { strict }
            )
            let autoApprove = await controller.getAutoApproveAllClients()
            XCTAssertFalse(autoApprove, "This regression must exercise manual approval, not the global bypass")
            let prompted = expectation(description: "External initialize requests manual approval")
            let events = ApprovalEvents()
            await controller.setApprovalCallback { [weak controller] name, generation, path in
                XCTAssertEqual(name, "external-test-client")
                XCTAssertEqual(path, MCPApprovalProcessIdentity.read(pid: getpid())?.executablePath)
                events.prompt(generation)
                if events.generations.count == 1 {
                    prompted.fulfill()
                } else {
                    XCTFail("A replacement connection unexpectedly prompted again")
                    await controller?.resolvePendingApproval(allow: false, generation: generation)
                }
            }
            let first = try await makeConnection(network: network, controller: controller)
            let initialize = Task { try await first.client.connect(transport: first.transport) }
            await fulfillment(of: [prompted], timeout: 5)
            guard let generation = events.generations.first else {
                initialize.cancel()
                await first.close()
                await network.stop()
                return XCTFail("Production admission never presented an approval")
            }

            // Model a host abandoning initialize while the user is reading the dialog.
            // The OS principal remains alive, but the actual network lifecycle is gone.
            await first.close()
            let firstIsLive = await network.isConnectionLiveForApproval(first.id)
            XCTAssertFalse(firstIsLive)
            await controller.resolvePendingApproval(allow: allow, generation: generation, alwaysAllow: alwaysAllow)
            initialize.cancel()
            _ = await initialize.result
            let removed = await network.debugDirectAdmissionStateForTesting(connectionID: first.id)
            XCTAssertNil(removed.pendingClientID)

            let second = try await makeConnection(network: network, controller: controller)
            do {
                do {
                    _ = try await second.client.connect(transport: second.transport)
                    XCTAssertTrue(allow, "A remembered denial must reject the replacement connection")
                } catch {
                    if allow { throw error }
                }
                XCTAssertEqual(events.generations.count, 1, "Replacement sockets from the same process must not prompt again")
                if !allow {
                    let deniedIsLive = await network.isConnectionLiveForApproval(second.id)
                    let denied = await network.debugDirectAdmissionStateForTesting(connectionID: second.id)
                    XCTAssertFalse(deniedIsLive)
                    XCTAssertNil(denied.pendingClientID, "Cooldown rejection must release the reserved admission slot")
                }
            } catch {
                await second.close()
                await controller.setApprovalCallback { _, _, _ in }
                await network.stop()
                throw error
            }
            await second.close()
            await controller.setApprovalCallback { _, _, _ in }
            await network.stop()

            let shouldPersist = allow && alwaysAllow && !strict
            XCTAssertEqual(defaults.stringArray(forKey: "mcp.alwaysAllowedClients") ?? [], shouldPersist ? ["external-test-client"] : [])
            guard shouldPersist else { return }

            let restartedNetwork = ServerNetworkManager()
            let restartedController = ServerController(
                networkManager: restartedNetwork, installNetworkCallbacks: false,
                approvalDefaults: defaults, strictConnectionApprovalEnabled: { strict }
            )
            await restartedController.setApprovalCallback { [weak restartedController] _, generation, _ in
                events.prompt(generation)
                XCTFail("Always Allow after socket closure must survive controller recreation")
                await restartedController?.resolvePendingApproval(allow: false, generation: generation)
            }
            let reconnected = try await makeConnection(network: restartedNetwork, controller: restartedController)
            do {
                _ = try await reconnected.client.connect(transport: reconnected.transport)
                XCTAssertEqual(events.generations.count, 1)
            } catch {
                await reconnected.close()
                await restartedNetwork.stop()
                throw error
            }
            await reconnected.close()
            await restartedNetwork.stop()
        }

        private func makeConnection(
            network: ServerNetworkManager,
            controller: ServerController,
            clientName: String = "external-test-client"
        ) async throws -> SocketConnection {
            var descriptors = [Int32](repeating: -1, count: 2)
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENFILE)
            }
            defer {
                for fd in descriptors where fd >= 0 {
                    Darwin.close(fd)
                }
            }
            var peerPID: pid_t = 0
            var length = socklen_t(MemoryLayout<pid_t>.size)
            guard getsockopt(descriptors[0], SOL_LOCAL, LOCAL_PEERPID, &peerPID, &length) == 0, peerPID > 1 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ESRCH)
            }
            XCTAssertEqual(peerPID, getpid())
            let id = UUID()
            let token = UUID().uuidString
            let server = try BootstrapSocketConnectionManager(
                connectionID: id, sessionToken: token, clientPid: Int(peerPID),
                observedKernelPeerPID: Int(peerPID), clientName: clientName,
                purpose: .unknown, codeMapsDisabled: true, connectedFD: descriptors[0], parentManager: network
            )
            descriptors[0] = -1
            let transport = try UnixSocketMCPTransport(connectedFD: descriptors[1], connectionID: id, correlationConnectionID: token)
            descriptors[1] = -1
            await network.debugInstallDirectAdmissionConnectionForTesting(
                connectionID: id, connection: server, pendingClientID: clientName
            )
            _ = await network.debugInstallConnectionLimiterForTesting(connectionID: id)
            do {
                try await server.start { info in
                    await controller.test_authorizeConnection(connectionID: id, clientName: info.name)
                }
            } catch {
                await transport.disconnect()
                await server.stop()
                await network.debugRemoveConnection(id)
                throw error
            }
            return SocketConnection(
                id: id, client: Client(name: clientName, version: "1.0"),
                transport: transport, server: server, network: network
            )
        }

        private struct SocketConnection {
            let id: UUID
            let client: Client
            let transport: UnixSocketMCPTransport
            let server: BootstrapSocketConnectionManager
            let network: ServerNetworkManager

            func close() async {
                await client.disconnect()
                await transport.disconnect()
                await server.stop()
                await network.debugRemoveConnection(id)
            }
        }

        private final class ApprovalEvents: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [UInt64] = []
            var generations: [UInt64] {
                lock.withLock { values }
            }

            func prompt(_ generation: UInt64) {
                lock.withLock { values.append(generation) }
            }
        }
    }
#endif
