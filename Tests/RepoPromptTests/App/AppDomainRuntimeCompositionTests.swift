import AppKit
import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptFoundation
import RepoPromptMCPServer
import RepoPromptPersistence
import RepoPromptSettingsCore
import RepoPromptShared
@testable import RepoPromptWorkspaceContext
import RepoPromptWorkspaceCore
import SQLite3
import XCTest

final class AppDomainRuntimeCompositionTests: XCTestCase {
    @MainActor
    func testWindowCompositionInstallsLinkExecutionInItsHostScope() throws {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        defer { GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false) }

        let composition = WindowStateCompositionFactory.make(
            windowID: -2890,
            deferredInitialAgentSystemWorkspaceRefresh: true,
            sharedMCPService: MCPService(),
            loadStoredAPISettingsDataOnInit: false,
            automaticProviderModelDiscoveryEnabled: false
        )
        let presenter = composition.agentModeViewModel
        XCTAssertTrue(presenter.workspaceSwitchProvider === presenter.runtimeHost.workspaceSwitchCleanup)
        let scope = presenter.runtimeHost.scope
        // Inspect the scope before asking presentation for its projection.
        let installed = try XCTUnwrap(scope.linkExecution)
        XCTAssertNotNil(scope.worktrees.terminalContinuationLauncher)
        XCTAssertTrue(presenter.linkExecutionRuntime === installed)
        XCTAssertTrue(scope.linkExecution === installed)
    }

    @MainActor
    func testIncompleteVisibleHostPreparationReleasesItsIndependentRoute() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VisibleHost-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let runtime = MCPDomainRuntime(configuration: .init(
            mode: .app, profileIdentifier: "visible-host-\(UUID())", storageDirectory: directory,
            workspaceStorageDirectory: directory.appendingPathComponent("workspaces"),
            eventDirectory: directory.appendingPathComponent("events"),
            temporaryDirectory: directory.appendingPathComponent("temporary"), externalReloadInterval: nil
        ))
        try await runtime.start()
        addTeardownBlock {
            _ = await runtime.shutdown()
            try? FileManager.default.removeItem(at: directory)
        }
        let root = directory.appendingPathComponent("root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let workspace = WorkspaceModel(name: "Original", repoPaths: [root.path], customStoragePath: directory.appendingPathComponent("saved"))
        let authority = DomainWorkspaceAuthorityClient(store: runtime.workspaceStore, windowID: 0)
        let created = try await authority.create(
            workspace, fileURL: runtime.configuration.workspaceStorageDirectory.appendingPathComponent("\(workspace.id.uuidString).json")
        )
        XCTAssertEqual(created.disposition, .applied)
        let activations = AgentWorkspaceSessionIndexStore()
        let owner = activations.receiveWorkspaceSwitchNotification(workspace)
        let keys = KeyManager()
        let settings = APISettingsViewModel(aiQueriesService: AIQueriesService(keyManager: keys), keyManager: keys, loadStoredDataOnInit: false)
        let resources = AgentHostWorkspaceResources(
            files: WorkspaceFileContextStore(codemapGraphIndexBuildLaunchPolicyForTesting: .disabled), contexts: runtime.contextStore
        )
        var candidate: AgentSessionRuntimeHost?
        var candidateRootLease: AgentHostWorkspaceResources.Lease?
        do {
            _ = try await WindowStateCompositionFactory.prepareVisibleAgentHost(
                workspace: workspace, owner: owner, activations: activations, resources: resources,
                apiSettings: settings, settingsStore: .shared, runtime: runtime
            ) { host, rootLease in
                candidate = host
                candidateRootLease = rootLease
                XCTAssertEqual(rootLease.snapshot.document.workspaceID, workspace.id)
                XCTAssertEqual(rootLease.snapshot.document.metadata.repoPaths, [root.path])
                XCTAssertTrue(rootLease.rootsAreCurrent)
                XCTAssertEqual(host.route.identity.kind, .independent)
                XCTAssertTrue(host.route.isLeaseManaged)
                XCTAssertTrue(host.workspaceActivation?.isPresenterCurrent == true)
                // No execution or catalog is installed by this fixture.
            }
            XCTFail("A candidate without the required capabilities must not publish")
        } catch AgentHostWorkspaceResources.Failure.authorityUnavailable {
            let host = try XCTUnwrap(candidate)
            try await AsyncTestWait.waitUntil("the unpublished host releases its original route") {
                host.scope.hasReleasedWriterClaims && host.route.isClosing && host.scope.retainedDrain == nil
            }
            XCTAssertFalse(AgentSessionRuntimeStore.shared.retainedExecutionHosts.contains { $0 === host })
            XCTAssertTrue(try XCTUnwrap(candidateRootLease).isReleased)
            XCTAssertEqual(activations.latestSessionIndexOwner, owner)
        }
    }

    @MainActor
    func testPrepareVisibleAgentHostSucceedsWithNonDefaultFileSystemSettings() async throws {
        let fixture = try await makeVisibleHostPreparationFixture()
        fixture.settingsStore.setRespectRepoIgnore(false, commit: false)
        fixture.settingsStore.setRespectCursorignore(false, commit: false)
        fixture.settingsStore.setSkipSymlinks(false, commit: false)
        let loaded = try await fixture.files.loadRoot(
            path: fixture.root.path,
            fileSystemSettings: fixture.settingsStore.fileSystemSettingsSnapshot()
        )
        addTeardownBlock { await fixture.files.unloadRoot(id: loaded.id) }

        let host = try await WindowStateCompositionFactory.prepareVisibleAgentHost(
            workspace: fixture.workspace,
            owner: fixture.owner,
            activations: fixture.activations,
            resources: fixture.resources,
            apiSettings: fixture.apiSettings,
            settingsStore: fixture.settingsStore,
            runtime: fixture.runtime
        ) { host, roots in
            try await self.installTestVisibleExecution(
                host, roots: roots, settings: fixture.settingsStore, service: fixture.mcpService
            )
        }
        addTeardownBlock { @MainActor in await self.retireVisibleHost(host) }

        XCTAssertTrue(host.workspaceActivation?.catalogFileLease?.rootsAreCurrent == true)
        XCTAssertEqual(host.workspaceActivation?.catalogFileLease?.roots.map(\.id), [loaded.id])
        XCTAssertTrue(host.route.hasCurrentModelCatalogRoute)
        await retireVisibleHost(host)
    }

    @MainActor
    func testPrepareVisibleAgentHostSucceedsWhenReadOverlayExistsAndKeepsCanonicalRunRouting() async throws {
        let fixture = try await makeVisibleHostPreparationFixture()
        let canonicalBeforeValue = await fixture.runtime.workspaceStore.canonicalWorkspaceSnapshot(fixture.workspace.id)
        let canonicalBefore = try XCTUnwrap(canonicalBeforeValue)

        var overlayWorkspace = fixture.workspace
        overlayWorkspace.name = "Transient Read Overlay"
        let overlayDocument = try DomainWorkspaceDocument.decode(
            documentBytes: JSONEncoder().encode(overlayWorkspace),
            fileURL: fixture.workspaceURL
        )
        let overlay = await fixture.runtime.workspaceStore.registerReadDocument(overlayDocument)
        let overlayObserved = await fixture.runtime.workspaceStore.workspaceSnapshot(fixture.workspace.id)
        XCTAssertEqual(overlayObserved, overlay)
        XCTAssertNotEqual(overlay, canonicalBefore)

        let host = try await WindowStateCompositionFactory.prepareVisibleAgentHost(
            workspace: fixture.workspace,
            owner: fixture.owner,
            activations: fixture.activations,
            resources: fixture.resources,
            apiSettings: fixture.apiSettings,
            settingsStore: fixture.settingsStore,
            runtime: fixture.runtime
        ) { host, roots in
            try await self.installTestVisibleExecution(
                host, roots: roots, settings: fixture.settingsStore, service: fixture.mcpService
            )
        }
        addTeardownBlock { @MainActor in await self.retireVisibleHost(host) }

        let catalogLease = try XCTUnwrap(host.workspaceActivation?.catalogFileLease)
        XCTAssertEqual(catalogLease.snapshotAuthority, .canonical)
        XCTAssertEqual(catalogLease.snapshot, canonicalBefore)
        XCTAssertTrue(host.route.hasCurrentModelCatalogRoute)

        let runID = UUID()
        let connectionID = UUID()
        let tab = try XCTUnwrap(fixture.workspace.composeTabs.first)
        var tabContext = MCPTabContextSnapshot(
            tabID: tab.id,
            windowID: host.routeID,
            workspaceID: fixture.workspace.id,
            promptText: "",
            selection: .init(),
            selectedMetaPromptIDs: [],
            tabName: tab.name,
            runID: runID,
            activeAgentSessionID: nil,
            explicitlyBound: false
        )
        tabContext.routeOwnerIdentity = ObjectIdentifier(host.route)
        host.route.publishBinding(connectionID: connectionID, context: tabContext)
        await host.route.settleRoutingPublications()

        let registration = try await fixture.runtime.routingCoordinator.currentRegistration(connectionID: connectionID)
        let handle = try await fixture.runtime.routingCoordinator.resolveReadContext(connection: registration)
        XCTAssertEqual(handle.bindingKind, .runScoped(runID: runID))
        XCTAssertEqual(handle.workspaceRevision, canonicalBefore.revisions.workingRevision)
        XCTAssertNotEqual(handle.workspaceRevision, overlay.revisions.workingRevision)

        await retireVisibleHost(host)
    }

    @MainActor
    func testCanonicalHostAndOverlayPresentationFileReadsCoexistAcrossReadOverlay() async throws {
        let fixture = try await makeVisibleHostPreparationFixture()
        let canonicalOnlyFile = fixture.root.appendingPathComponent("canonical-only.txt")
        let overlayOnlyFile = fixture.root.appendingPathComponent("overlay-only.txt")
        let noteFile = fixture.root.appendingPathComponent("note.txt")
        try Data("from canonical".utf8).write(to: canonicalOnlyFile)
        try Data("from overlay".utf8).write(to: overlayOnlyFile)

        let sessionID = UUID()
        var canonicalWorkspace = fixture.workspace
        let initialTab = try XCTUnwrap(canonicalWorkspace.composeTabs.first)
        var canonicalTab = initialTab
        canonicalTab.activeAgentSessionID = sessionID
        canonicalTab.selection = StoredSelection(selectedPaths: [canonicalOnlyFile.path])
        canonicalWorkspace.composeTabs = [canonicalTab]
        canonicalWorkspace.activeComposeTabID = canonicalTab.id

        let beforeSaveValue = await fixture.authority.canonicalWorkspaceSnapshot(fixture.workspace.id)
        let beforeSave = try XCTUnwrap(beforeSaveValue)
        let saved = try await fixture.authority.save(
            canonicalWorkspace,
            fileURL: fixture.workspaceURL,
            expectedWorkspaceRevision: beforeSave.revisions.workingRevision,
            expectedContentDigest: beforeSave.document.contentDigest
        )
        XCTAssertEqual(saved.disposition, .applied)
        let canonicalSnapshotValue = await fixture.runtime.workspaceStore.canonicalWorkspaceSnapshot(fixture.workspace.id)
        let canonicalSnapshot = try XCTUnwrap(canonicalSnapshotValue)

        var overlayWorkspace = canonicalWorkspace
        overlayWorkspace.name = "Transient Read Overlay"
        var overlayTab = canonicalTab
        overlayTab.selection = StoredSelection(selectedPaths: [overlayOnlyFile.path])
        overlayWorkspace.composeTabs = [overlayTab]
        let overlayDocument = try DomainWorkspaceDocument.decode(
            documentBytes: JSONEncoder().encode(overlayWorkspace),
            fileURL: fixture.workspaceURL
        )
        let overlaySnapshot = await fixture.runtime.workspaceStore.registerReadDocument(overlayDocument)
        XCTAssertNotEqual(overlaySnapshot.revisions.workingRevision, canonicalSnapshot.revisions.workingRevision)

        let host = try await WindowStateCompositionFactory.prepareVisibleAgentHost(
            workspace: canonicalWorkspace,
            owner: fixture.owner,
            activations: fixture.activations,
            resources: fixture.resources,
            apiSettings: fixture.apiSettings,
            settingsStore: fixture.settingsStore,
            runtime: fixture.runtime
        ) { host, roots in
            try await self.installTestVisibleExecution(
                host, roots: roots, settings: fixture.settingsStore, service: fixture.mcpService
            )
        }
        addTeardownBlock { @MainActor in await self.retireVisibleHost(host) }

        let catalogLease = try XCTUnwrap(host.workspaceActivation?.catalogFileLease)
        let session = host.scope.makeSession(tabID: canonicalTab.id)
        session.installPersistentSessionBinding(.init(
            tabID: canonicalTab.id, sessionID: sessionID, workspaceID: canonicalWorkspace.id
        ))
        session.recordRestorationAuthoritative(.persistedPayloadApplied)
        session.hasLoadedPersistedState = true
        let hostRunID = UUID()
        session.installRunID(hostRunID)
        host.scope.replaceSessions([canonicalTab.id: session])
        let command = try host.scope.admit(session: session, expectedWorkspaceID: canonicalWorkspace.id)

        let hostConnectionID = UUID()
        var hostTabContext = MCPTabContextSnapshot(
            tabID: canonicalTab.id,
            windowID: host.routeID,
            workspaceID: canonicalWorkspace.id,
            promptText: "",
            selection: canonicalTab.selection,
            selectedMetaPromptIDs: [],
            tabName: canonicalTab.name,
            runID: hostRunID,
            activeAgentSessionID: sessionID,
            explicitlyBound: false
        )
        hostTabContext.routeOwnerIdentity = ObjectIdentifier(host.route)
        hostTabContext.modelWriterAtBinding = .captured(command.identity)
        host.route.runRouteBindings.tabContextByConnectionID[hostConnectionID] = hostTabContext
        host.route.publishBinding(connectionID: hostConnectionID, context: hostTabContext)
        await host.route.settleRoutingPublications()

        let hostFileReads = host.makeHostFileReadResources(catalogLease)
        let hostTreeBinding = try XCTUnwrap(hostFileReads.binding(named: MCPWindowToolName.getFileTree, route: host.route))
        let hostReadBinding = try XCTUnwrap(hostFileReads.binding(named: MCPWindowToolName.readFile, route: host.route))

        let hostTreeInvocation = ToolInvocationContext.trustedLocal(
            toolName: MCPWindowToolName.getFileTree,
            metadata: .init(connectionID: hostConnectionID, clientName: nil, windowID: host.routeID)
        )
        let hostTreeValue = try await MCPInvocationContextBridge.withInvocation(hostTreeInvocation) {
            try await hostTreeBinding(["mode": .string("selected")])
        }
        XCTAssertNil(hostTreeValue.objectValue?["error_code"], String(describing: hostTreeValue))
        let hostTree = try XCTUnwrap(hostTreeValue.objectValue?["tree"]?.stringValue)
        XCTAssertTrue(hostTree.contains("canonical-only.txt"), hostTree)
        XCTAssertFalse(hostTree.contains("overlay-only.txt"), hostTree)

        let hostReadInvocation = ToolInvocationContext.trustedLocal(
            toolName: MCPWindowToolName.readFile,
            metadata: .init(connectionID: hostConnectionID, clientName: nil, windowID: host.routeID)
        )
        let hostReadValue = try await MCPInvocationContextBridge.withInvocation(hostReadInvocation) {
            try await hostReadBinding(["path": .string(noteFile.path)])
        }
        XCTAssertNil(hostReadValue.objectValue?["error_code"], String(describing: hostReadValue))
        let hostContent = try XCTUnwrap(hostReadValue.objectValue?["content"]?.stringValue)
        XCTAssertTrue(hostContent.contains("synthetic"), hostContent)

        let presentationRoute = MCPHostRouteResources(
            identity: MCPRouteIdentityAllocator.allocateHost(),
            coordinator: fixture.runtime.routingCoordinator,
            runtime: fixture.runtime
        )
        XCTAssertFalse(presentationRoute.isLeaseManaged)
        let overlayLease = try await fixture.resources.acquire(
            context: .init(workspaceID: canonicalWorkspace.id, contextID: canonicalTab.id),
            rootIDs: catalogLease.roots.map(\.id)
        )
        addTeardownBlock { @MainActor in
            await presentationRoute.close()
            await overlayLease.release()
        }
        XCTAssertEqual(overlayLease.snapshotAuthority, .readOverlay)
        XCTAssertEqual(overlayLease.snapshot, overlaySnapshot)

        let overlayRunID = UUID()
        let overlayConnectionID = UUID()
        var overlayTabContext = MCPTabContextSnapshot(
            tabID: canonicalTab.id,
            windowID: presentationRoute.identity.routeID,
            workspaceID: canonicalWorkspace.id,
            promptText: "",
            selection: overlayTab.selection,
            selectedMetaPromptIDs: [],
            tabName: overlayTab.name,
            runID: overlayRunID,
            activeAgentSessionID: sessionID,
            explicitlyBound: false
        )
        overlayTabContext.routeOwnerIdentity = ObjectIdentifier(presentationRoute)
        presentationRoute.runRouteBindings.tabContextByConnectionID[overlayConnectionID] = overlayTabContext
        presentationRoute.publishBinding(connectionID: overlayConnectionID, context: overlayTabContext)
        await presentationRoute.settleRoutingPublications()

        let overlayFileReads = MCPFileReadResources(workspace: overlayLease, settings: fixture.settingsStore)
        let overlayTreeBinding = try XCTUnwrap(
            overlayFileReads.binding(named: MCPWindowToolName.getFileTree, route: presentationRoute)
        )
        let overlayTreeInvocation = ToolInvocationContext.trustedLocal(
            toolName: MCPWindowToolName.getFileTree,
            metadata: .init(connectionID: overlayConnectionID, clientName: nil, windowID: presentationRoute.identity.routeID)
        )
        let overlayTreeValue = try await MCPInvocationContextBridge.withInvocation(overlayTreeInvocation) {
            try await overlayTreeBinding(["mode": .string("selected")])
        }
        XCTAssertNil(overlayTreeValue.objectValue?["error_code"], String(describing: overlayTreeValue))
        let overlayTree = try XCTUnwrap(overlayTreeValue.objectValue?["tree"]?.stringValue)
        XCTAssertTrue(overlayTree.contains("overlay-only.txt"), overlayTree)
        XCTAssertFalse(overlayTree.contains("canonical-only.txt"), overlayTree)

        await presentationRoute.close()
        await overlayLease.release()
        await retireVisibleHost(host)
    }

    @MainActor
    func testPrepareVisibleAgentHostSucceedsAcrossConcurrentLastUsedAndSaveDuringRootRetention() async throws {
        let fixture = try await makeVisibleHostPreparationFixture()
        let beforeValue = await fixture.authority.canonicalWorkspaceSnapshot(fixture.workspace.id)
        let before = try XCTUnwrap(beforeValue)

        var resources = fixture.resources
        var didCommitConcurrentSave = false
        resources.test_afterRetainRootsBeforeRecheck = {
            guard !didCommitConcurrentSave else { return }
            didCommitConcurrentSave = true
            var updated = fixture.workspace
            updated.lastUsed = Date().addingTimeInterval(60)
            let outcome = try? await fixture.authority.save(
                updated,
                fileURL: fixture.workspaceURL,
                expectedWorkspaceRevision: before.revisions.workingRevision,
                expectedContentDigest: before.document.contentDigest
            )
            XCTAssertEqual(outcome?.disposition, .applied)
        }

        let host = try await WindowStateCompositionFactory.prepareVisibleAgentHost(
            workspace: fixture.workspace,
            owner: fixture.owner,
            activations: fixture.activations,
            resources: resources,
            apiSettings: fixture.apiSettings,
            settingsStore: fixture.settingsStore,
            runtime: fixture.runtime
        ) { host, roots in
            try await self.installTestVisibleExecution(
                host, roots: roots, settings: fixture.settingsStore, service: fixture.mcpService
            )
        }
        addTeardownBlock { @MainActor in await self.retireVisibleHost(host) }

        XCTAssertTrue(didCommitConcurrentSave)
        let afterValue = await fixture.authority.canonicalWorkspaceSnapshot(fixture.workspace.id)
        let after = try XCTUnwrap(afterValue)
        XCTAssertGreaterThan(after.revisions.workingRevision, before.revisions.workingRevision)
        XCTAssertNil(after.revisions.dirtyRevision)
        XCTAssertEqual(host.workspaceActivation?.catalogFileLease?.snapshot.revisions, after.revisions)
        XCTAssertTrue(host.workspaceActivation?.catalogFileLease?.rootsAreCurrent == true)

        await retireVisibleHost(host)
    }

    @MainActor
    func testCanonicalCarrierAdmissionAndWorktreePreparationNormalizeWhitespaceAndDuplicateRepoPaths() async throws {
        let fixture = try await makeVisibleHostPreparationFixture { root in
            ["  \(root.path)  ", root.path]
        }
        let sessionID = UUID()
        var canonicalWorkspace = fixture.workspace
        var canonicalTab = try XCTUnwrap(canonicalWorkspace.composeTabs.first)
        canonicalTab.activeAgentSessionID = sessionID
        canonicalWorkspace.composeTabs = [canonicalTab]
        canonicalWorkspace.activeComposeTabID = canonicalTab.id

        let beforeSaveValue = await fixture.authority.canonicalWorkspaceSnapshot(fixture.workspace.id)
        let beforeSave = try XCTUnwrap(beforeSaveValue)
        let saved = try await fixture.authority.save(
            canonicalWorkspace,
            fileURL: fixture.workspaceURL,
            expectedWorkspaceRevision: beforeSave.revisions.workingRevision,
            expectedContentDigest: beforeSave.document.contentDigest
        )
        XCTAssertEqual(saved.disposition, .applied)

        let host = try await WindowStateCompositionFactory.prepareVisibleAgentHost(
            workspace: canonicalWorkspace,
            owner: fixture.owner,
            activations: fixture.activations,
            resources: fixture.resources,
            apiSettings: fixture.apiSettings,
            settingsStore: fixture.settingsStore,
            runtime: fixture.runtime
        ) { host, roots in
            try await self.installTestVisibleExecution(
                host, roots: roots, settings: fixture.settingsStore, service: fixture.mcpService
            )
        }
        addTeardownBlock { @MainActor in await self.retireVisibleHost(host) }

        let session = host.scope.makeSession(tabID: canonicalTab.id)
        session.installPersistentSessionBinding(.init(
            tabID: canonicalTab.id, sessionID: sessionID, workspaceID: canonicalWorkspace.id
        ))
        session.recordRestorationAuthoritative(.persistedPayloadApplied)
        session.hasLoadedPersistedState = true
        let runID = UUID()
        session.installRunID(runID)
        host.scope.replaceSessions([canonicalTab.id: session])
        let command = try host.scope.admit(session: session, expectedWorkspaceID: canonicalWorkspace.id)

        let connectionID = UUID()
        var tabContext = MCPTabContextSnapshot(
            tabID: canonicalTab.id,
            windowID: host.routeID,
            workspaceID: canonicalWorkspace.id,
            promptText: "",
            selection: canonicalTab.selection,
            selectedMetaPromptIDs: [],
            tabName: canonicalTab.name,
            runID: runID,
            activeAgentSessionID: sessionID,
            explicitlyBound: false
        )
        tabContext.routeOwnerIdentity = ObjectIdentifier(host.route)
        tabContext.modelWriterAtBinding = .captured(command.identity)
        host.route.runRouteBindings.tabContextByConnectionID[connectionID] = tabContext
        host.route.publishBinding(connectionID: connectionID, context: tabContext)
        await host.route.settleRoutingPublications()
        await ServerNetworkManager.shared.debugSeedConnectionRunRouting(
            connectionID: connectionID,
            runID: runID,
            purpose: .agentModeRun,
            windowID: host.routeID
        )

        let invocation = ToolInvocationContext.trustedLocal(
            toolName: MCPWindowToolName.agentRun,
            metadata: .init(connectionID: connectionID, clientName: nil, windowID: host.routeID)
        )
        let admission = try await AgentRunHostAdmission(host: host, invocation: invocation)
        let snapshot = try await admission.canonicalSnapshot()
        let canonicalRoot = try XCTUnwrap(StandardizedPath.canonicalWorkspaceRootPath(fixture.root.path))
        XCTAssertEqual(
            Set(snapshot.document.metadata.canonicalLoadableRepoPaths.compactMap {
                DomainMutationPathFence.canonicalPath($0)
            }),
            [canonicalRoot]
        )

        let coordinator = AgentMCPStartWorktreeCoordinator(
            operationName: "agent_run.start",
            vcsService: .shared,
            gitTargetResolver: .init(),
            startupPhaseEventSink: AppWorktreeStartupPhaseEventSink()
        )
        let preparedRoot = try await AgentRunHostStartTransaction.prepareWorktree(
            coordinator.parseRequest(args: [:]),
            from: admission,
            host: host,
            command: command,
            stopFence: AgentRunStartStopFence(session: session),
            proposedParentID: sessionID,
            requireTarget: {}
        )
        XCTAssertEqual(preparedRoot, canonicalRoot)

        await retireVisibleHost(host)
    }

    @MainActor
    func testPrepareVisibleAgentHostBootstrapsBeforeReadingCanonicalWorkspace() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VisibleHostBootstrap-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let root = directory.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let workspacesDir = directory.appendingPathComponent("workspaces", isDirectory: true)
        let eventsDir = directory.appendingPathComponent("events", isDirectory: true)
        let tempDir = directory.appendingPathComponent("temporary", isDirectory: true)
        let profileID = "visible-host-bootstrap-\(UUID())"

        var workspace = WorkspaceModel(
            name: "PreBootstrap",
            repoPaths: [root.path],
            customStoragePath: directory.appendingPathComponent("saved", isDirectory: true)
        )
        workspace.composeTabs = [ComposeTabState()]
        let workspaceURL = workspacesDir.appendingPathComponent("\(workspace.id.uuidString).json")

        let seedRuntime = MCPDomainRuntime(configuration: .init(
            mode: .app, profileIdentifier: profileID, storageDirectory: directory,
            workspaceStorageDirectory: workspacesDir, eventDirectory: eventsDir,
            temporaryDirectory: tempDir, externalReloadInterval: nil
        ))
        try await seedRuntime.start()
        let seedAuthority = DomainWorkspaceAuthorityClient(store: seedRuntime.workspaceStore, windowID: 0)
        let created = try await seedAuthority.create(workspace, fileURL: workspaceURL)
        XCTAssertEqual(created.disposition, .applied)
        _ = await seedRuntime.shutdown()

        let coldRuntime = MCPDomainRuntime(configuration: .init(
            mode: .app, profileIdentifier: profileID, storageDirectory: directory,
            workspaceStorageDirectory: workspacesDir, eventDirectory: eventsDir,
            temporaryDirectory: tempDir, externalReloadInterval: nil
        ))
        addTeardownBlock { _ = await coldRuntime.shutdown() }

        let beforeBootstrap = await coldRuntime.workspaceStore.canonicalWorkspaceSnapshot(workspace.id)
        XCTAssertNil(beforeBootstrap, "Cold runtime must not have bootstrapped before host preparation")

        let (defaults, suiteName) = try makeIsolatedDefaults()
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(fileURL: directory.appendingPathComponent("settings.json"))
        )
        let activations = AgentWorkspaceSessionIndexStore()
        let owner = activations.receiveWorkspaceSwitchNotification(workspace)
        let keys = KeyManager()
        let apiSettings = APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keys), keyManager: keys, loadStoredDataOnInit: false
        )
        let files = WorkspaceFileContextStore(codemapGraphIndexBuildLaunchPolicyForTesting: .disabled)
        let resources = AgentHostWorkspaceResources(files: files, contexts: coldRuntime.contextStore)
        let mcpService = MCPService(
            hostBootstrapOperation: {}, controllerStartOperation: {}, controllerFullShutdownOperation: {}
        )

        let host = try await WindowStateCompositionFactory.prepareVisibleAgentHost(
            workspace: workspace,
            owner: owner,
            activations: activations,
            resources: resources,
            apiSettings: apiSettings,
            settingsStore: settingsStore,
            runtime: coldRuntime
        ) { host, roots in
            try await self.installTestVisibleExecution(
                host, roots: roots, settings: settingsStore, service: mcpService
            )
        }
        addTeardownBlock { @MainActor in await self.retireVisibleHost(host) }

        let afterBootstrap = await coldRuntime.workspaceStore.canonicalWorkspaceSnapshot(workspace.id)
        XCTAssertNotNil(afterBootstrap)
        XCTAssertTrue(host.workspaceActivation?.catalogFileLease?.rootsAreCurrent == true)
        XCTAssertTrue(host.route.hasCurrentModelCatalogRoute)

        await retireVisibleHost(host)
    }

    @MainActor
    private struct VisibleHostPreparationFixture {
        let directory: URL
        let root: URL
        let workspace: WorkspaceModel
        let workspaceURL: URL
        let runtime: MCPDomainRuntime
        let authority: DomainWorkspaceAuthorityClient
        let activations: AgentWorkspaceSessionIndexStore
        let owner: AgentWorkspaceSessionIndexStore.SessionIndexOwner
        let apiSettings: APISettingsViewModel
        let settingsStore: GlobalSettingsStore
        let files: WorkspaceFileContextStore
        let resources: AgentHostWorkspaceResources
        let mcpService: MCPService
    }

    @MainActor
    private func makeVisibleHostPreparationFixture(
        repoPaths: ((URL) -> [String])? = nil
    ) async throws -> VisibleHostPreparationFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VisibleHost-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let runtime = MCPDomainRuntime(configuration: .init(
            mode: .app, profileIdentifier: "visible-host-\(UUID())", storageDirectory: directory,
            workspaceStorageDirectory: directory.appendingPathComponent("workspaces"),
            eventDirectory: directory.appendingPathComponent("events"),
            temporaryDirectory: directory.appendingPathComponent("temporary"), externalReloadInterval: nil
        ))
        try await runtime.start()
        addTeardownBlock {
            _ = await runtime.shutdown()
            try? FileManager.default.removeItem(at: directory)
        }
        let root = directory.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("synthetic".utf8).write(to: root.appendingPathComponent("note.txt"))
        var workspace = WorkspaceModel(
            name: "Original",
            repoPaths: repoPaths?(root) ?? [root.path],
            customStoragePath: directory.appendingPathComponent("saved", isDirectory: true)
        )
        workspace.composeTabs = [ComposeTabState()]
        let workspaceURL = runtime.configuration.workspaceStorageDirectory.appendingPathComponent("\(workspace.id.uuidString).json")
        let authority = DomainWorkspaceAuthorityClient(store: runtime.workspaceStore, windowID: 0)
        let created = try await authority.create(workspace, fileURL: workspaceURL)
        XCTAssertEqual(created.disposition, .applied)

        let (defaults, suiteName) = try makeIsolatedDefaults()
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(fileURL: directory.appendingPathComponent("settings.json"))
        )
        let activations = AgentWorkspaceSessionIndexStore()
        let owner = activations.receiveWorkspaceSwitchNotification(workspace)
        let keys = KeyManager()
        let apiSettings = APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keys), keyManager: keys, loadStoredDataOnInit: false
        )
        let files = WorkspaceFileContextStore(codemapGraphIndexBuildLaunchPolicyForTesting: .disabled)
        let resources = AgentHostWorkspaceResources(files: files, contexts: runtime.contextStore)
        let mcpService = MCPService(
            hostBootstrapOperation: {}, controllerStartOperation: {}, controllerFullShutdownOperation: {}
        )
        return VisibleHostPreparationFixture(
            directory: directory,
            root: root,
            workspace: workspace,
            workspaceURL: workspaceURL,
            runtime: runtime,
            authority: authority,
            activations: activations,
            owner: owner,
            apiSettings: apiSettings,
            settingsStore: settingsStore,
            files: files,
            resources: resources,
            mcpService: mcpService
        )
    }

    @MainActor
    private func installTestVisibleExecution(
        _ host: AgentSessionRuntimeHost,
        roots: AgentHostWorkspaceResources.Lease,
        settings: GlobalSettingsStore,
        service: MCPService
    ) async throws {
        guard let activation = host.workspaceActivation, activation.catalogFileLease === roots,
              let workspace = try? JSONDecoder().decode(WorkspaceModel.self, from: roots.snapshot.document.documentBytes)
        else { throw AgentHostWorkspaceResources.Failure.authorityUnavailable }
        let storage = AgentSessionStorageInputs(
            workspaceID: workspace.id,
            workspaceWithID: { $0 == workspace.id ? workspace : nil },
            displayName: { _ in AgentSessionRestoreSupport.normalizedSessionTitle(nil) },
            isSuppressed: { true },
            attachmentWorkspaceDirectory: { FileManager.default.temporaryDirectory }
        )
        host.scope.persistence.composition = storage.persistenceComposition(
            scope: host.scope,
            canonicalStorage: .init(workspaceID: workspace.id) { id in
                guard let snapshot = await activation.authority.canonicalWorkspaceSnapshot(id),
                      snapshot.health != .removed else { return nil }
                return try? JSONDecoder().decode(WorkspaceModel.self, from: snapshot.document.documentBytes)
            }
        )
        let perf = AppAgentModePerfRecorder()
        host.scope.persistence.perfRecorder = perf
        try host.installHostRunExecution(
            sessionTitle: { _ in AgentSessionRestoreSupport.normalizedSessionTitle(nil) },
            settings: settings,
            perf: perf,
            diagnostics: AppAgentSessionLinkCatalogEventSink()
        )
        host.scope.mcp.installRunRoute(id: host.routeID, bindings: host.route.runRouteBindings)
        host.scope.mcp.codexCoordinator = host.codexCoordinator
        host.scope.mcp.claudeCoordinator = host.claudeCoordinator
        _ = host.scope.interactions(routeID: host.routeID, approvalStore: .shared)
        try await host.registerHostCatalog(service: service)
    }

    @MainActor
    private func retireVisibleHost(_ host: AgentSessionRuntimeHost) async {
        guard !host.scope.hasReleasedWriterClaims else { return }
        let drain = host.beginRetirement()
        drain.attemptRecovery()
        let settled = await drain.wait(until: .now.advanced(by: .seconds(5)))
        XCTAssertEqual(settled, .released)
    }

    func testCollectLegacyRuntimeDefaultsSerializesBooleanScalarFragments() throws {
        for value in [true, false] {
            let (defaults, suiteName) = try makeIsolatedDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }
            defaults.set(value, forKey: "agentModeAutoEditEnabled")

            let collected = AppDomainRuntimeComposition.collectLegacyRuntimeDefaults(from: defaults)
            let data = try XCTUnwrap(collected["agentModeAutoEditEnabled"])

            XCTAssertEqual(try JSONDecoder().decode(Bool.self, from: data), value)
            XCTAssertEqual(String(decoding: data, as: UTF8.self), value ? "true" : "false")
        }
    }

    func testCollectLegacyRuntimeDefaultsPreservesRawDataAlongsideBoolean() throws {
        let (defaults, suiteName) = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let approvalBytes = Data([0x00, 0xFF, 0x7B, 0x01])
        defaults.set(approvalBytes, forKey: "workspace.approvalSettings")
        defaults.set(false, forKey: "agentModeAutoEditEnabled")

        let collected = AppDomainRuntimeComposition.collectLegacyRuntimeDefaults(from: defaults)

        XCTAssertEqual(collected["workspace.approvalSettings"], approvalBytes)
        let booleanData = try XCTUnwrap(collected["agentModeAutoEditEnabled"])
        XCTAssertFalse(try JSONDecoder().decode(Bool.self, from: booleanData))
    }

    func testCollectLegacyRuntimeDefaultsSkipsInvalidValueWithoutMutationAndIsRepeatable() throws {
        let (defaults, suiteName) = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let invalidDate = Date(timeIntervalSince1970: 1_725_000_000)
        defaults.set(invalidDate, forKey: "workspace.approvalSettings")
        defaults.set(true, forKey: "agentModeAutoEditEnabled")

        let first = AppDomainRuntimeComposition.collectLegacyRuntimeDefaults(from: defaults)
        let second = AppDomainRuntimeComposition.collectLegacyRuntimeDefaults(from: defaults)

        XCTAssertEqual(first, second)
        XCTAssertNil(first["workspace.approvalSettings"])
        let booleanData = try XCTUnwrap(first["agentModeAutoEditEnabled"])
        XCTAssertTrue(try JSONDecoder().decode(Bool.self, from: booleanData))
        XCTAssertEqual(defaults.object(forKey: "workspace.approvalSettings") as? Date, invalidDate)
        XCTAssertEqual(defaults.object(forKey: "agentModeAutoEditEnabled") as? Bool, true)
    }

    private func makeIsolatedDefaults() throws -> (defaults: UserDefaults, suiteName: String) {
        let suiteName = "AppDomainRuntimeCompositionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}

/// Profile composition must select disjoint mutable stores for both app flavors.
@MainActor
final class DebugSessionStorageLocationsTests: XCTestCase {
    func testMutableStoreLocationsUseOneStateIdentityWithoutMovingDiscovery() {
        let locations = AppProfileLocations.current
        XCTAssertEqual(WorkspaceStoragePaths.defaultRoot, locations.workspaceRoot)
        XCTAssertEqual(AgentSessionDataService.defaultWorkspaceRootURL(), locations.workspaceRoot)
        XCTAssertEqual(ChatDataService.defaultWorkspaceRootURL(), locations.workspaceRoot)
        XCTAssertEqual(AgentWorkflowStore.workflowsDirectoryURL, locations.applicationSupportRoot.appendingPathComponent("Workflows", isDirectory: true))
        XCTAssertEqual(WindowSessionStore.sessionFileURL().deletingLastPathComponent(), locations.applicationSupportRoot)
        XCTAssertEqual(PresetFileStore.appSupportDirectoryName, locations.identity.applicationStateDirectoryName)
        XCTAssertEqual(GlobalSettingsFileStore.appSupportDirectoryName, locations.identity.applicationStateDirectoryName)
        XCTAssertEqual(locations.identity.applicationSupportDirectoryName, "RepoPrompt CE")
        if locations.identity.buildFlavor == .debug {
            XCTAssertEqual(locations.applicationSupportRoot.lastPathComponent, "RepoPrompt CE Debug")
            XCTAssertEqual(WorkspaceStoragePaths.userDataBackupDirectoryName, "RepoPrompt-Debug-Backup")
        } else {
            XCTAssertEqual(WorkspaceStoragePaths.userDataBackupDirectoryName, "RepoPrompt-Backup")
        }
    }

    func testTwoFlavorsWithSameRepositoryWorkspaceAndTabCannotOverwriteSelections() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("PartitionProfiles-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let release = AppProfileLocations(identity: .repoPromptCE(.release), homeDirectory: home)
        let debug = AppProfileLocations(identity: .repoPromptCE(.debug), homeDirectory: home)
        let releaseStore = PartitionStore(profileLocations: release)
        let debugStore = PartitionStore(profileLocations: debug)
        let scope = PartitionScope(workspaceID: UUID(), tabID: UUID())
        let repository = "/fixture/shared-repository"
        let file = "/fixture/shared-repository/source.swift"
        let releaseRanges = [LineRange(start: 2, end: 5)]
        let debugRanges = [LineRange(start: 20, end: 25)]
        var data = PartitionStore.PartitionData.empty()
        data.files[file] = .init(ranges: releaseRanges, fileModificationTime: nil)
        try await releaseStore.save(forRoot: repository, scope: scope, data: data)
        let before = try snapshot(release.applicationSupportRoot)

        data.files[file] = .init(ranges: debugRanges, fileModificationTime: nil)
        try await debugStore.save(forRoot: repository, scope: scope, data: data)
        let releaseResult = await releaseStore.load(forRoot: repository, scope: scope)
        let debugResult = await debugStore.load(forRoot: repository, scope: scope)
        XCTAssertEqual(releaseResult.files[file]?.ranges, releaseRanges)
        XCTAssertEqual(debugResult.files[file]?.ranges, debugRanges)
        XCTAssertEqual(try snapshot(release.applicationSupportRoot), before)

        let aliased = PartitionStore(
            baseURL: release.applicationSupportRoot.appendingPathComponent("Partitions"),
            profileLocations: debug
        )
        do {
            try await aliased.save(forRoot: repository, scope: scope, data: data)
            XCTFail("Debug must reject a release selection-store alias")
        } catch is ProfileLocationError {}
        XCTAssertEqual(try snapshot(release.applicationSupportRoot), before)
    }

    private func snapshot(_ root: URL) throws -> [String: Data] {
        let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        var files: [String: Data] = [:]
        while let url = entries?.nextObject() as? URL {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                files[url.path] = try Data(contentsOf: url)
            }
        }
        return files
    }
}

/// Disposable fake HOME fixtures exercise the real startup publish boundary.
final class DebugStateBootstrapTests: XCTestCase {
    struct Fixture {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("DebugSeed-\(UUID().uuidString)")
        var release: AppProfileLocations {
            .init(identity: .repoPromptCE(.release), homeDirectory: home)
        }

        var debug: AppProfileLocations {
            .init(identity: .repoPromptCE(.debug), homeDirectory: home, releaseCustomStorageRoots: [])
        }

        var recovery: URL {
            debug.applicationSupportRoot.deletingLastPathComponent().appendingPathComponent("RepoPrompt CE Debug Recovery")
        }

        func write(_ data: Data, _ url: URL) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }

        func writeJSON(_ value: Any, _ url: URL) throws {
            try write(JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), url)
        }

        func object(_ url: URL) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: home)
        }
    }

    func testExplicitSnapshotCopiesByValueAndCleanResetArchivesPriorDebugState() throws {
        let f = Fixture()
        defer { f.cleanup() }
        let settings = f.release.applicationSupportRoot.appendingPathComponent("Settings/globalSettings.json")
        try f.writeJSON(["schemaVersion": 1, "value": "production"], settings)
        let sourceBytes = try Data(contentsOf: settings)
        let debugSettings = f.debug.applicationSupportRoot.appendingPathComponent("Settings/globalSettings.json")
        _ = try DebugStateBootstrap.seed(locations: f.debug, cleanSlate: false, releasePreferences: ["fontSize": 14])
        XCTAssertEqual(try Data(contentsOf: debugSettings), sourceBytes)
        try f.writeJSON(["value": "debug-only"], debugSettings)
        let previousDebugBytes = try Data(contentsOf: debugSettings)
        _ = try DebugStateBootstrap.seed(locations: f.debug, cleanSlate: true, releasePreferences: ["fontSize": 14])
        XCTAssertFalse(FileManager.default.fileExists(atPath: debugSettings.path))
        let archives = try FileManager.default.contentsOfDirectory(at: f.recovery, includingPropertiesForKeys: nil)
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }
        XCTAssertEqual(archives.count, 1)
        XCTAssertEqual(try Data(contentsOf: archives[0].appendingPathComponent("Settings/globalSettings.json")), previousDebugBytes)
        _ = try DebugStateBootstrap.seed(locations: f.debug, cleanSlate: false, releasePreferences: ["fontSize": 14])
        XCTAssertEqual(try Data(contentsOf: debugSettings), sourceBytes)
        XCTAssertEqual(try Data(contentsOf: settings), sourceBytes)
        XCTAssertEqual(DebugStateBootstrap.cleanSlateArgument, "--debug-clean-slate")
    }

    func testCustomWorkspaceJournalAndConversationBackingsAreCopiedWithoutResumeAuthority() throws {
        let f = Fixture()
        defer { f.cleanup() }
        let id = UUID(), tabID = UUID(), sessionID = UUID()
        let custom = f.home.appendingPathComponent("CustomMetadata")
        let directory = custom.appendingPathComponent("original")
        let workspaceURL = directory.appendingPathComponent("workspace.json")
        let workspace: [String: Any] = [
            "id": id.uuidString,
            "name": "Fixture",
            "customStoragePath": directory.absoluteString,
            "composeTabs": [["id": tabID.uuidString, "activeAgentSessionID": sessionID.uuidString]]
        ]
        try f.writeJSON(workspace, workspaceURL)
        let backing = directory.appendingPathComponent("AgentSessions/attachments/image.bin")
        try f.write(Data([0, 1, 2, 3]), backing)
        let sessionURL = directory.appendingPathComponent("AgentSessions/AgentSession-" + sessionID.uuidString + ".json")
        try f.writeJSON([
            "id": sessionID.uuidString,
            "fileURL": sessionURL.absoluteString,
            "providerSessionID": "production-remote",
            "codexConversationID": "production-thread",
            "providerCleanupHandle": ["id": "production-remote"],
            "autoWakeOnOversightUpdates": true,
            "items": [["text": "kept history"]]
        ], sessionURL)
        try f.writeJSON([["id": id.uuidString, "name": "Fixture", "customStoragePath": directory.absoluteString]], custom.appendingPathComponent("workspacesIndex.json"))
        let runtime = f.release.applicationSupportRoot.appendingPathComponent("DomainRuntime/v1/default-37a8eec1ce19")
        var working = workspace
        working["name"] = "Unsaved"
        let workingData = try JSONSerialization.data(withJSONObject: working)
        try f.writeJSON(["version": 1, "workspaceID": id.uuidString, "fileURL": workspaceURL.absoluteString, "workingDocument": workingData.base64EncodedString()], runtime.appendingPathComponent("working-journals/" + id.uuidString + ".json"))
        _ = try DebugStateBootstrap.seed(locations: f.debug, cleanSlate: false, releasePreferences: ["GlobalCustomStorageURL": custom.path])
        let destination = f.debug.workspaceRoot.appendingPathComponent("Workspace-Unsaved-" + id.uuidString)
        let copied = try f.object(destination.appendingPathComponent("workspace.json"))
        XCTAssertEqual(copied["name"] as? String, "Unsaved")
        XCTAssertNil(copied["customStoragePath"])
        let copySession = try f.object(destination.appendingPathComponent("AgentSessions/" + sessionURL.lastPathComponent))
        XCTAssertNil(copySession["providerSessionID"])
        XCTAssertNil(copySession["providerCleanupHandle"])
        XCTAssertNil(copySession["codexConversationID"])
        XCTAssertEqual(copySession["autoWakeOnOversightUpdates"] as? Bool, false)
        XCTAssertEqual(copySession["fileURL"] as? String, destination.appendingPathComponent("AgentSessions/" + sessionURL.lastPathComponent).absoluteString)
        XCTAssertNotNil(copySession["items"])
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("AgentSessions/attachments/image.bin")), Data([0, 1, 2, 3]))
        XCTAssertEqual(try f.object(workspaceURL)["name"] as? String, "Fixture")
        XCTAssertEqual(try f.object(sessionURL)["providerSessionID"] as? String, "production-remote")
    }

    func testDeletedWorkspaceStaysDeletedAndJournalOnlyWorkspaceIsRecoverable() throws {
        let f = Fixture()
        defer { f.cleanup() }
        let removed = UUID(), recovered = UUID()
        let runtime = f.release.applicationSupportRoot.appendingPathComponent("DomainRuntime/v1/default-37a8eec1ce19")
        let dead = f.release.workspaceRoot.appendingPathComponent("Workspace-Removed-" + removed.uuidString + "/workspace.json")
        let fresh = f.release.workspaceRoot.appendingPathComponent("Workspace-Recovered-" + recovered.uuidString + "/workspace.json")
        try f.writeJSON(["id": removed.uuidString, "name": "Removed"], dead)
        try f.writeJSON([["id": removed.uuidString, "name": "Removed"]], f.release.workspaceRoot.appendingPathComponent("workspacesIndex.json"))
        try f.writeJSON(["version": 1, "workspaceID": removed.uuidString], runtime.appendingPathComponent("deletion-tombstones/" + removed.uuidString + ".json"))
        let bytes = try JSONSerialization.data(withJSONObject: ["id": recovered.uuidString, "name": "Recovered"])
        try f.writeJSON(["version": 1, "workspaceID": recovered.uuidString, "fileURL": fresh.absoluteString, "workingDocument": bytes.base64EncodedString()], runtime.appendingPathComponent("working-journals/" + recovered.uuidString + ".json"))
        _ = try DebugStateBootstrap.seed(locations: f.debug, cleanSlate: false, releasePreferences: [:])
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.debug.workspaceRoot.appendingPathComponent("Workspace-Removed-" + removed.uuidString).path))
        XCTAssertEqual(try f.object(f.debug.workspaceRoot.appendingPathComponent("Workspace-Recovered-" + recovered.uuidString + "/workspace.json"))["name"] as? String, "Recovered")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dead.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.path))
    }

    func testPersistedProductionPreferencesAreCapturedAndPriorPreferenceBytesAreRecoverable() throws {
        let f = Fixture()
        defer { f.cleanup() }
        try FileManager.default.createDirectory(at: f.release.applicationSupportRoot, withIntermediateDirectories: true)
        let preferenceSource = f.home.appendingPathComponent("Library/Preferences/production.plist")
        let previousPreference = f.home.appendingPathComponent("Library/Preferences/debug.plist")
        let sourceBytes = try PropertyListSerialization.data(fromPropertyList: ["fontSize": 19], format: .binary, options: 0)
        let priorBytes = try PropertyListSerialization.data(fromPropertyList: ["fontSize": 11], format: .xml, options: 0)
        try f.write(sourceBytes, preferenceSource)
        try f.write(priorBytes, previousPreference)
        _ = try DebugStateBootstrap.seed(locations: f.debug, cleanSlate: true, releasePreferences: [:])
        _ = try DebugStateBootstrap.seed(locations: f.debug, cleanSlate: false, releasePreferences: [:], preferenceSourceURL: preferenceSource, previousPreferenceFileURL: previousPreference)
        let url = f.debug.applicationSupportRoot.appendingPathComponent("seedPreferences.plist")
        let values = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        XCTAssertEqual(values["fontSize"] as? Int, 19)
        let records = try FileManager.default.contentsOfDirectory(at: f.recovery, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        let record = try f.object(XCTUnwrap(records.first))
        XCTAssertEqual((record["previousPreferences"] as? String).flatMap { Data(base64Encoded: $0) }, priorBytes)
        XCTAssertEqual(try Data(contentsOf: preferenceSource), sourceBytes)
        XCTAssertEqual(try Data(contentsOf: previousPreference), priorBytes)
        _ = try DebugStateBootstrap.seed(locations: f.debug, cleanSlate: true, releasePreferences: [:], preferenceSourceURL: preferenceSource)
        let cleanValues = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        XCTAssertTrue(cleanValues.isEmpty)
    }

    func testCatalogOnlyTombstoneCannotResurrectAnExistingWorkspaceFile() throws {
        let f = Fixture()
        defer { f.cleanup() }
        let id = UUID()
        let source = f.release.workspaceRoot.appendingPathComponent("Workspace-Removed-" + id.uuidString + "/workspace.json")
        try f.writeJSON(["id": id.uuidString, "name": "Removed"], source)
        let catalog = f.release.applicationSupportRoot.appendingPathComponent("DomainRuntime/v1/default-37a8eec1ce19/workspace-catalog.json")
        try f.writeJSON(["version": 1, "entries": [["workspaceID": id.uuidString, "fileURL": source.absoluteString]], "deletions": [["workspaceID": id.uuidString]]], catalog)
        _ = try DebugStateBootstrap.seed(locations: f.debug, cleanSlate: false, releasePreferences: [:])
        let index = try JSONSerialization.jsonObject(with: Data(contentsOf: f.debug.workspaceRoot.appendingPathComponent("workspacesIndex.json"))) as? [Any]
        XCTAssertEqual(index?.count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testChangedSourceAndSymlinkFailBeforeReplacingPriorDebugState() throws {
        let f = Fixture()
        defer { f.cleanup() }
        let input = f.release.applicationSupportRoot.appendingPathComponent("Settings/globalSettings.json")
        try f.write(Data("first".utf8), input)
        _ = try DebugStateBootstrap.seed(locations: f.debug, cleanSlate: true, releasePreferences: [:])
        let sentinel = f.debug.applicationSupportRoot.appendingPathComponent("prior.txt")
        try f.write(Data("prior".utf8), sentinel)
        var plan = DebugStateSnapshot.Plan()
        try plan.add(input, as: "Settings/globalSettings.json")
        try f.write(Data("source changed".utf8), input)
        XCTAssertThrowsError(try DebugStateSnapshot(locations: f.debug).publish(plan: plan, cleanSlate: false, preferences: Data(), previousPreferences: Data()))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("prior".utf8))
        let alias = f.release.applicationSupportRoot.appendingPathComponent("Presets")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.debug.applicationSupportRoot)
        XCTAssertThrowsError(try DebugStateBootstrap.seed(locations: f.debug, cleanSlate: false, releasePreferences: [:]))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("prior".utf8))
    }

    func testRecoveryRetentionIsBoundedAndUnknownRecoveryDataIsNotDeleted() throws {
        let f = Fixture()
        defer { f.cleanup() }
        try FileManager.default.createDirectory(at: f.release.applicationSupportRoot, withIntermediateDirectories: true)
        let original = Data("unclassified prior debug data".utf8)
        try f.write(original, f.debug.applicationSupportRoot.appendingPathComponent("Unmanaged/keep.bin"))
        for _ in 0 ..< 6 {
            _ = try DebugStateBootstrap.seed(locations: f.debug, cleanSlate: true, releasePreferences: [:], previousPreferences: ["remember": "old debug"])
        }
        let entries = try FileManager.default.contentsOfDirectory(at: f.recovery, includingPropertiesForKeys: nil)
        let archives = entries.filter { UUID(uuidString: $0.lastPathComponent) != nil }
        XCTAssertEqual(archives.count, 4, "Three recognized snapshots plus the preserved pre-bootstrap original")
        XCTAssertEqual(archives.compactMap { try? Data(contentsOf: $0.appendingPathComponent("Unmanaged/keep.bin")) }, [original])
        let unknown = f.recovery.appendingPathComponent("unknown-user-file")
        try f.write(Data("preserve".utf8), unknown)
        _ = try DebugStateBootstrap.seed(locations: f.debug, cleanSlate: true, releasePreferences: [:])
        XCTAssertEqual(try Data(contentsOf: unknown), Data("preserve".utf8))
    }

    func testExplicitSnapshotPreservesDebugApprovalsAndEndpointWorkspaceWhileRefreshingOtherState() throws {
        let f = Fixture()
        defer { f.cleanup() }
        let workspaceID = UUID(), sessionID = UUID(), tabID = UUID()
        let directory = "Workspace-Fixture-" + workspaceID.uuidString
        let prior = f.debug.workspaceRoot.appendingPathComponent(directory)
        let production = f.release.workspaceRoot.appendingPathComponent(directory)
        for root in [prior, production] {
            try f.writeJSON([["id": workspaceID.uuidString, "name": "Fixture"]], root.deletingLastPathComponent().appendingPathComponent("workspacesIndex.json"))
            try f.writeJSON([
                "id": workspaceID.uuidString, "name": "Fixture",
                "composeTabs": root == prior ? [["id": tabID.uuidString, "activeAgentSessionID": sessionID.uuidString]] : []
            ], root.appendingPathComponent("workspace.json"))
        }
        let backing = prior.appendingPathComponent("AgentSessions/AgentSession-" + sessionID.uuidString + ".json")
        try f.writeJSON(["id": sessionID.uuidString, "providerSessionID": "debug-owned-thread", "items": [["text": "debug-only history"]]], backing)
        try f.write(Data([7, 8, 9]), prior.appendingPathComponent("AgentSessions/attachments/image.bin"))
        let database = f.debug.applicationSupportRoot.appendingPathComponent("Overseer/continuity.sqlite")
        try FileManager.default.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let owner = OverseerContinuityStore(databaseURL: database, profile: OverseerContinuityRepository.productionProfile)
        let grant = DomainDelegationScopeGrant(id: UUID(), granteeSessionID: sessionID, kind: .allSessions, capabilities: [.observe], guardrails: .init(), origin: .user, grantedAt: Date())
        _ = try owner.commit(operationID: UUID(), origin: "fixture", mutations: [.grant(OverseerContinuityRepository.scopeRow(grant))])
        let sourceBytes = try Data(contentsOf: production.appendingPathComponent("workspace.json"))
        for size in [15, 17] {
            _ = try DebugStateBootstrap.seed(locations: f.debug, cleanSlate: false, releasePreferences: ["fontSize": size])
            XCTAssertEqual(try f.object(backing)["providerSessionID"] as? String, "debug-owned-thread")
            XCTAssertEqual(try f.object(prior.appendingPathComponent("workspace.json"))["composeTabs"] as? [[String: String]], [["id": tabID.uuidString, "activeAgentSessionID": sessionID.uuidString]])
            XCTAssertEqual(try DebugStateSnapshot.continuityIdentities(database).sessions, [sessionID.uuidString])
            XCTAssertEqual(try Data(contentsOf: prior.appendingPathComponent("AgentSessions/attachments/image.bin")), Data([7, 8, 9]))
            let preferences = try PropertyListSerialization.propertyList(from: Data(contentsOf: f.debug.applicationSupportRoot.appendingPathComponent("seedPreferences.plist")), format: nil) as? [String: Int]
            XCTAssertEqual(preferences?["fontSize"], size)
        }
        XCTAssertEqual(try Data(contentsOf: production.appendingPathComponent("workspace.json")), sourceBytes)
        _ = try DebugStateBootstrap.seed(locations: f.debug, cleanSlate: true, releasePreferences: [:])
        XCTAssertFalse(FileManager.default.fileExists(atPath: database.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backing.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: f.recovery.path).contains { UUID(uuidString: $0) != nil })
    }

    func testSQLiteBackupIsReadOnlyAndWrongProfileContinuityIsNotActivated() throws {
        let f = Fixture()
        defer { f.cleanup() }
        let source = f.release.applicationSupportRoot.appendingPathComponent("Overseer/continuity.sqlite")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(source.path, &db), SQLITE_OK)
        defer { sqlite3_close_v2(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE fixture(value TEXT); INSERT INTO fixture VALUES ('source');", nil, nil, nil), SQLITE_OK)
        let bytes = try Data(contentsOf: source)
        let stamp = try DebugStateSnapshot.stamp(source)
        _ = try DebugStateBootstrap.seed(locations: f.debug, cleanSlate: false, releasePreferences: [:])
        let copy = f.debug.applicationSupportRoot.appendingPathComponent("ProductionContinuity/continuity.sqlite")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.debug.applicationSupportRoot.appendingPathComponent("Overseer/continuity.sqlite").path))
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertEqual(try DebugStateSnapshot.stamp(source), stamp)
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA journal_mode=WAL; INSERT INTO fixture VALUES ('new');", nil, nil, nil), SQLITE_OK)
        let wal = URL(fileURLWithPath: source.path + "-wal")
        let walBytes = try Data(contentsOf: wal)
        XCTAssertThrowsError(try DebugStateBootstrap.seed(locations: f.debug, cleanSlate: false, releasePreferences: [:]))
        XCTAssertEqual(try Data(contentsOf: wal), walBytes)
    }
}

extension DebugStateBootstrapTests {
    private func oracleStore(_ locations: AppProfileLocations, interrupt: Bool = false) -> (DomainOracleConversationStore, URL) {
        let identity = DomainRuntimeIdentity(runtimeID: UUID(), lifecycleGeneration: 1, processID: 42, mode: .standalone, createdAt: Date())
        let persistence = DomainPersistenceCoordinator(configuration: .init(
            mode: .standalone, profileIdentifier: locations.profileIdentifier,
            storageDirectory: locations.applicationSupportRoot,
            eventDirectory: locations.applicationSupportRoot.appendingPathComponent("Events"),
            temporaryDirectory: locations.applicationSupportRoot.appendingPathComponent("Temporary"), externalReloadInterval: nil
        ), identity: identity)
        return (DomainOracleConversationStore(persistence: persistence, identity: identity, mutationObserver: { phase in
            if interrupt, case .journalPersisted = phase { throw OraclePersistenceError.invalidDocument("fixture_interruption") }
        }), persistence.oracleStorageRoot)
    }

    private func oracleGroup(workspace: UUID, seed: String, context: OracleContextEnvelope? = nil) async throws -> OracleGroupDocument {
        let model = try OracleModelReference(providerID: "fixture", modelID: "model")
        let owner = try await OracleViewModel.oracleGroupOwner(workspaceID: workspace, tabID: UUID())
        let second = try OracleModelReference(providerID: "fixture", modelID: "second")
        let members = try [model, second].enumerated().map { index, model in
            try OracleGroupMember(laneID: OracleLaneID(index: index), publicChatID: index == 0 ? seed : seed + "-second", model: model)
        }
        let turn = try OracleTurnRecord(input: OracleInput(mode: .chat, userMessage: seed, context: context), state: .prepared, startedAt: Date(timeIntervalSince1970: 1000))
        return try OracleGroupDocument(
            group: OracleGroupDescriptor(size: 2),
            owner: owner,
            name: seed,
            revision: 1,
            createdAt: turn.startedAt,
            updatedAt: turn.startedAt,
            roster: OracleRoster(primary: model, additional: [second]),
            members: members,
            turns: [turn]
        )
    }

    private func retainOracleWorkspace(_ f: Fixture, id: UUID) throws {
        let workspace = f.debug.workspaceRoot.appendingPathComponent("Workspace-Fixture-" + id.uuidString)
        try f.writeJSON([["id": id.uuidString, "name": "Fixture"]], f.debug.workspaceRoot.appendingPathComponent("workspacesIndex.json"))
        try f.writeJSON(["id": id.uuidString, "name": "Fixture", "composeTabs": []], workspace.appendingPathComponent("workspace.json"))
        let grant = DomainDelegationScopeGrant(id: UUID(), granteeSessionID: UUID(), kind: .workspace(workspaceID: id), capabilities: [.observe], guardrails: .init(), origin: .user, grantedAt: Date())
        let encoder = JSONEncoder()
        try f.write(encoder.encode(DelegationScopeDocument(scopes: [grant])), f.debug.applicationSupportRoot.appendingPathComponent("delegationScopes.json"))
    }

    func testOracleRetentionRecoversCapturedIndexJournalAndReseedsWithoutResurrection() async throws {
        let f = Fixture()
        defer { f.cleanup() }
        let workspace = UUID()
        try retainOracleWorkspace(f, id: workspace)
        let (release, releaseRoot) = oracleStore(f.release)
        let (debug, debugRoot) = oracleStore(f.debug, interrupt: true)
        let retained = try await oracleGroup(workspace: workspace, seed: "debug-member")
        let deleted = try await oracleGroup(workspace: workspace, seed: "release-deleted")
        let unrelated = try await oracleGroup(workspace: UUID(), seed: "release-member")
        try await release.create(deleted)
        try await release.create(unrelated)
        do { try await debug.create(retained)
            XCTFail("Expected interruption")
        } catch {}
        let journalDirectory = debugRoot.appendingPathComponent("transactions")
        let journal = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: journalDirectory, includingPropertiesForKeys: nil).first)
        let journalBytes = try Data(contentsOf: journal)
        let releaseIndex = try Data(contentsOf: releaseRoot.appendingPathComponent("index.json"))
        for iteration in 0 ..< 2 {
            _ = try DebugStateBootstrap.seed(locations: f.debug, cleanSlate: false, releasePreferences: [:])
            let (cold, _) = oracleStore(f.debug)
            let loaded = try await cold.load(member: .init(publicChatID: "debug-member"), owner: retained.owner)
            XCTAssertEqual(loaded, retained)
            let other = try await cold.load(member: .init(publicChatID: "release-member"), owner: unrelated.owner)
            XCTAssertEqual(other, unrelated)
            let absent = try await cold.load(member: .init(publicChatID: "release-deleted"), owner: deleted.owner)
            XCTAssertNil(absent)
            XCTAssertEqual(try Data(contentsOf: releaseRoot.appendingPathComponent("index.json")), releaseIndex)
            XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
            if iteration == 0 {
                let archives = try FileManager.default.contentsOfDirectory(at: f.recovery, includingPropertiesForKeys: nil)
                let relative = DomainPersistenceCoordinator.runtimeDirectoryName(profileIdentifier: f.debug.profileIdentifier) + "/oracle/transactions/" + journal.lastPathComponent
                XCTAssertTrue(archives.contains { (try? Data(contentsOf: $0.appendingPathComponent(relative))) == journalBytes }, "The original journal survives unchanged in the archived source profile")
            }
        }
        let results = try retained.members.map { member in
            try OracleLaneResult(laneIndex: member.laneID.index, chatID: member.publicChatID, providerID: member.model.providerID, modelID: member.model.modelID, status: .completed, response: "completed reply")
        }
        let preparedTurn = try XCTUnwrap(retained.turns.last)
        let terminalTurn = OracleTurnRecord(id: preparedTurn.id, input: preparedTurn.input, state: .terminal, startedAt: preparedTurn.startedAt, finishedAt: preparedTurn.startedAt.addingTimeInterval(1), status: .completed, warnings: [], results: results)
        let terminal = try OracleGroupDocument(group: retained.group, owner: retained.owner, name: retained.name, revision: 2, createdAt: retained.createdAt, updatedAt: preparedTurn.startedAt.addingTimeInterval(1), roster: retained.roster, members: retained.members, turns: [terminalTurn])
        let (interrupted, _) = oracleStore(f.debug, interrupt: true)
        do { try await interrupted.save(terminal, expectedRevision: retained.revision)
            XCTFail("Expected interruption")
        } catch {}
        _ = try DebugStateBootstrap.seed(locations: f.debug, cleanSlate: false, releasePreferences: [:])
        let (beforeDeletion, _) = oracleStore(f.debug)
        let loadedTerminal = try await beforeDeletion.load(groupID: retained.group.id, owner: retained.owner)
        XCTAssertEqual(loadedTerminal, terminal)
        try await beforeDeletion.delete(groupID: retained.group.id, owner: retained.owner, expectedRevision: terminal.revision)
        _ = try DebugStateBootstrap.seed(locations: f.debug, cleanSlate: false, releasePreferences: [:])
        let (cold, _) = oracleStore(f.debug)
        let absent = try await cold.load(member: .init(publicChatID: "release-deleted"), owner: deleted.owner)
        XCTAssertNil(absent, "An empty retained debug set must not fall back to release")
        let deletedGroup = try await cold.load(groupID: retained.group.id, owner: retained.owner)
        XCTAssertNil(deletedGroup)
        for member in retained.members {
            let deletedMember = try await cold.load(member: .init(publicChatID: member.publicChatID), owner: retained.owner)
            XCTAssertNil(deletedMember)
        }
        let survivingRelease = try await cold.load(member: .init(publicChatID: "release-member"), owner: unrelated.owner)
        XCTAssertEqual(survivingRelease, unrelated)
    }

    func testOracleRetentionPreservesUnknownGroupFieldsAndReferencedArtifactBytes() async throws {
        let f = Fixture()
        defer { f.cleanup() }
        let workspace = UUID()
        try retainOracleWorkspace(f, id: workspace)
        let (debug, debugRoot) = oracleStore(f.debug)
        let artifactBytes = Data("retained frozen context\n".utf8)
        let artifactID = try await debug.storeArtifact(artifactBytes)
        let context = OracleContextEnvelope(content: .durableArtifact(id: artifactID), sha256: artifactID)
        let retained = try await oracleGroup(workspace: workspace, seed: "byte-preservation", context: context)
        try await debug.create(retained)
        let groupURL = debugRoot.appendingPathComponent("groups/" + retained.group.id.rawValue.uuidString + ".json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: groupURL)) as? [String: Any])
        json["future_retention_fixture"] = "unknown field must survive"
        let groupBytes = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .prettyPrinted])
        try groupBytes.write(to: groupURL)
        let artifactURL = debugRoot.appendingPathComponent("artifacts/" + artifactID + ".blob")

        for _ in 0 ..< 2 {
            _ = try DebugStateBootstrap.seed(locations: f.debug, cleanSlate: false, releasePreferences: [:])
            XCTAssertEqual(try Data(contentsOf: groupURL), groupBytes)
            XCTAssertEqual(try Data(contentsOf: artifactURL), artifactBytes)
            let (cold, _) = oracleStore(f.debug)
            for member in retained.members {
                let loaded = try await cold.load(member: .init(publicChatID: member.publicChatID), owner: retained.owner)
                XCTAssertEqual(loaded, retained)
            }
        }
    }

    func testOracleRetentionRetriesOptionalStoreAppearanceButIgnoresTemporaryChurn() throws {
        let f = Fixture()
        defer { f.cleanup() }
        try retainOracleWorkspace(f, id: UUID())
        try FileManager.default.createDirectory(at: f.release.applicationSupportRoot, withIntermediateDirectories: true)
        let (_, releaseRoot) = oracleStore(f.release)
        let (_, debugRoot) = oracleStore(f.debug)
        var captures = 0
        _ = try DebugStateBootstrap.seed(locations: f.debug, cleanSlate: false, releasePreferences: [:], retryDelay: 0) { _ in
            captures += 1
            if captures == 1 { try f.write(Data("future".utf8), releaseRoot.appendingPathComponent("future-metadata")) }
        }
        XCTAssertEqual(captures, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: debugRoot.appendingPathComponent("future-metadata").path))
        captures = 0
        _ = try DebugStateBootstrap.seed(locations: f.debug, cleanSlate: false, releasePreferences: [:], retryDelay: 0) { _ in
            captures += 1
            try f.write(Data("transient".utf8), releaseRoot.appendingPathComponent(".DS_Store"))
            try f.write(Data(), releaseRoot.appendingPathComponent("locks/new.lock"))
        }
        XCTAssertEqual(captures, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: debugRoot.appendingPathComponent(".DS_Store").path))
    }

    func testOracleRetentionOmitsOpaqueReleaseFilesAndPreservesDebugBytes() async throws {
        let f = Fixture()
        defer { f.cleanup() }
        let workspace = UUID()
        try retainOracleWorkspace(f, id: workspace)
        let (release, releaseRoot) = oracleStore(f.release)
        let (debug, debugRoot) = oracleStore(f.debug)
        try await release.create(oracleGroup(workspace: UUID(), seed: "release"))
        try await debug.create(oracleGroup(workspace: workspace, seed: "debug"))
        try f.write(Data("release".utf8), releaseRoot.appendingPathComponent("future-metadata"))
        try f.write(Data("debug".utf8), debugRoot.appendingPathComponent("future-metadata"))
        _ = try DebugStateBootstrap.seed(locations: f.debug, cleanSlate: false, releasePreferences: [:])
        let receipt = try Data(contentsOf: f.debug.applicationSupportRoot.appendingPathComponent("debugSeedRetainedContinuity.json"))
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: receipt) as? [String: Any])
        XCTAssertEqual(report["oracleReleaseOmissions"] as? [[String: String]], [["path": "future-metadata", "reason": "opaque_release_file"]])
        XCTAssertEqual(try Data(contentsOf: releaseRoot.appendingPathComponent("future-metadata")), Data("release".utf8))
        XCTAssertEqual(try Data(contentsOf: debugRoot.appendingPathComponent("future-metadata")), Data("debug".utf8))
    }

    func testRealLegacyScopesAndOwnershipRetainArchivedCarriersWithoutLinksOrDatabase() throws {
        for kind in ["session", "tree", "workspace", "grantee", "ownership"] {
            let f = Fixture()
            defer { f.cleanup() }
            let workspaceID = UUID(), sessionID = UUID(), granteeID = UUID()
            let directory = f.debug.workspaceRoot.appendingPathComponent("Workspace-Archived-" + workspaceID.uuidString)
            try f.writeJSON([["id": workspaceID.uuidString, "name": "Archived"]], f.debug.workspaceRoot.appendingPathComponent("workspacesIndex.json"))
            // No compose tab: the endpoint is archived, not actively selected.
            try f.writeJSON(["id": workspaceID.uuidString, "name": "Archived", "composeTabs": []], directory.appendingPathComponent("workspace.json"))
            let backing = directory.appendingPathComponent("AgentSessions/AgentSession-" + sessionID.uuidString + ".json")
            try f.writeJSON(["id": sessionID.uuidString, "providerSessionID": "debug-owned"], backing)
            let encoder = JSONEncoder()
            let continuity: URL
            let bytes: Data
            if kind == "ownership" {
                continuity = f.debug.applicationSupportRoot.appendingPathComponent("delegationWorktreeOwnership.json")
                let record = WorktreeOwnershipRecord(worktreeID: "fixture", path: "/fixture/repository", createdBySessionID: sessionID, createdAt: Date())
                encoder.dateEncodingStrategy = .iso8601
                bytes = try encoder.encode(WorktreeOwnershipDocument(version: 1, worktrees: [record]))
            } else {
                continuity = f.debug.applicationSupportRoot.appendingPathComponent("delegationScopes.json")
                let scopeKind: DomainDelegationScopeKind = kind == "grantee" ? .allSessions : kind == "workspace" ? .workspace(workspaceID: workspaceID) : kind == "tree" ? .tree(rootSessionID: sessionID) : .session(targetSessionID: sessionID)
                let grant = DomainDelegationScopeGrant(id: UUID(), granteeSessionID: kind == "grantee" ? sessionID : granteeID, kind: scopeKind, capabilities: [.observe], guardrails: .init(), origin: .user, grantedAt: Date())
                if kind == "grantee" {
                    // A real v1 envelope predates clean-shutdown bookkeeping.
                    bytes = try JSONSerialization.data(withJSONObject: ["version": 1, "scopes": JSONSerialization.jsonObject(with: encoder.encode([grant]))])
                } else {
                    bytes = try encoder.encode(DelegationScopeDocument(scopes: [grant]))
                }
            }
            try f.write(bytes, continuity)
            for _ in 0 ..< 2 {
                _ = try DebugStateBootstrap.seed(locations: f.debug, cleanSlate: false, releasePreferences: [:])
                XCTAssertEqual(try Data(contentsOf: continuity), bytes, kind)
                XCTAssertEqual(try f.object(backing)["providerSessionID"] as? String, "debug-owned", kind)
                XCTAssertFalse(FileManager.default.fileExists(atPath: f.debug.applicationSupportRoot.appendingPathComponent("Overseer/continuity.sqlite").path))
                XCTAssertFalse(FileManager.default.fileExists(atPath: f.debug.applicationSupportRoot.appendingPathComponent("agentSessionOversightLinks.json").path))
            }
        }
    }

    func testUnknownLegacySchemaAndWrongDatabaseProfileAbortRefreshRatherThanDroppingBacking() throws {
        let f = Fixture()
        defer { f.cleanup() }
        let sentinel = f.debug.applicationSupportRoot.appendingPathComponent("prior.txt")
        let legacy = f.debug.applicationSupportRoot.appendingPathComponent("delegationScopes.json")
        try f.write(Data("keep".utf8), sentinel)
        try f.writeJSON(["version": 999, "scopes": []], legacy)
        XCTAssertThrowsError(try DebugStateBootstrap.seed(locations: f.debug, cleanSlate: false, releasePreferences: [:]))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
        try FileManager.default.removeItem(at: legacy)
        let database = f.debug.applicationSupportRoot.appendingPathComponent("Overseer/continuity.sqlite")
        let owner = OverseerContinuityStore(databaseURL: database, profile: "another-profile")
        _ = try owner.engineSettings()
        let bytes = try Data(contentsOf: database)
        XCTAssertThrowsError(try DebugStateBootstrap.seed(locations: f.debug, cleanSlate: false, releasePreferences: [:]))
        XCTAssertEqual(try Data(contentsOf: database), bytes)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
    }

    func testManagedAttachmentsInItemsAndTranscriptSurviveRemovalOfProductionBacking() throws {
        let f = Fixture()
        defer { f.cleanup() }
        let workspaceID = UUID(), sessionID = UUID()
        let folder = "Workspace-Images-" + workspaceID.uuidString
        let source = f.release.workspaceRoot.appendingPathComponent(folder)
        try f.writeJSON([["id": workspaceID.uuidString, "name": "Images"]], f.release.workspaceRoot.appendingPathComponent("workspacesIndex.json"))
        try f.writeJSON(["id": workspaceID.uuidString, "name": "Images"], source.appendingPathComponent("workspace.json"))
        let image = f.home.appendingPathComponent("source.png")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.setColor(.red, atX: 0, y: 0)
        let imageBytes = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try f.write(imageBytes, image)
        let imported = try AgentAttachmentStore().importFile(sourceURL: image, workspaceDirectory: source)
        let external = AgentFileAttachment(source: .localFile(path: image.path))
        let remote = AgentFileAttachment(source: .url("https://example.invalid/image.png"))
        let item = AgentChatItem(kind: .user, text: imported.fileURL.path, attachments: [imported.attachment, external, remote])
        let activity = AgentTranscriptActivity(id: UUID(), timestamp: Date(), sequenceIndex: 1, role: .assistant, itemKind: .assistant, text: imported.fileURL.path, attachments: [imported.attachment])
        let transcript = AgentTranscript(turns: [.init(request: .init(from: item), responseSpans: [.init(startedAt: Date(), activities: [activity])], startedAt: Date())])
        let encoder = JSONEncoder()
        let payload: [String: Any] = try [
            "id": sessionID.uuidString,
            "items": JSONSerialization.jsonObject(with: encoder.encode([item])),
            "transcript": JSONSerialization.jsonObject(with: encoder.encode(transcript)),
            "toolPayload": ["attachments": JSONSerialization.jsonObject(with: encoder.encode([imported.attachment]))],
            "text": imported.fileURL.path
        ]
        let file = "AgentSessions/AgentSession-" + sessionID.uuidString + ".json"
        try f.writeJSON(payload, source.appendingPathComponent(file))
        _ = try DebugStateBootstrap.seed(locations: f.debug, cleanSlate: false, releasePreferences: [:])
        let copied = try f.object(f.debug.workspaceRoot.appendingPathComponent(folder + "/" + file))
        try FileManager.default.removeItem(at: source)
        let copiedItems = try JSONDecoder().decode([AgentChatItem].self, from: JSONSerialization.data(withJSONObject: XCTUnwrap(copied["items"])))
        let copiedTranscript = try JSONDecoder().decode(AgentTranscript.self, from: JSONSerialization.data(withJSONObject: XCTUnwrap(copied["transcript"])))
        let expected = f.debug.workspaceRoot.appendingPathComponent(folder + "/agent_attachments/" + imported.fileURL.lastPathComponent)
        for attachment in try [copiedItems[0].attachments[0], XCTUnwrap(copiedTranscript.turns[0].request).attachments[0], copiedTranscript.turns[0].responseSpans[0].activities[0].attachments[0]] {
            XCTAssertEqual(attachment.source, .localFile(path: expected.path))
        }
        XCTAssertEqual(try Data(contentsOf: expected), imageBytes)
        XCTAssertNotNil(NSImage(contentsOf: expected), "Copied history can render its own managed image after the production backing is removed")
        XCTAssertEqual(copiedItems[0].attachments[1], external)
        XCTAssertEqual(copiedItems[0].attachments[2], remote)
        XCTAssertEqual(copiedItems[0].text, imported.fileURL.path)
        XCTAssertEqual(copied["text"] as? String, imported.fileURL.path)
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: XCTUnwrap(copied["toolPayload"]), options: .sortedKeys), try JSONSerialization.data(withJSONObject: XCTUnwrap(payload["toolPayload"]), options: .sortedKeys))
    }

    func testMissingReleasePreferencesAndDebugOwnedRuntimeRecoverySurviveRepeatedRefresh() throws {
        let f = Fixture()
        defer { f.cleanup() }
        let runtime = DomainPersistenceCoordinator.runtimeDirectoryName(profileIdentifier: f.debug.profileIdentifier)
        let paths = [runtime + "/settings/runtime-policy.json", runtime + "/settings/protected-mutations.json", runtime + "/settings/agent-sessions.json", runtime + "/settings/agent-worktree-bindings.json", "Settings/Backups/future.json", "Presets/Backups/future.json", "workspace-cleanup-backups/recovery.bin", "Workspaces/Workspace-Orphan-" + UUID().uuidString + "/AgentSessions/.self-compact-recovery/corrupt.json"]
        let bytes = Data("unknown exact debug-owned recovery bytes".utf8)
        for path in paths {
            try f.write(bytes, f.debug.applicationSupportRoot.appendingPathComponent(path))
        }
        let preferences: [String: Any] = ["fontSize": 13, "claudeRawEventLoggingEnabled": true, "enableAgentModePerfDiagnostics": true]
        for _ in 0 ..< 5 {
            _ = try DebugStateBootstrap.seed(locations: f.debug, cleanSlate: false, releasePreferences: nil, previousPreferences: preferences, preferenceSourceURL: f.home.appendingPathComponent("missing.plist"))
            let values = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: f.debug.applicationSupportRoot.appendingPathComponent("seedPreferences.plist")), format: nil) as? [String: Any])
            XCTAssertEqual(values["fontSize"] as? Int, 13)
            XCTAssertEqual(values["claudeRawEventLoggingEnabled"] as? Bool, true)
            for path in paths {
                XCTAssertEqual(try Data(contentsOf: f.debug.applicationSupportRoot.appendingPathComponent(path)), bytes, path)
            }
        }
        _ = try DebugStateBootstrap.seed(locations: f.debug, cleanSlate: false, releasePreferences: ["fontSize": 19], previousPreferences: preferences)
        let values = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: f.debug.applicationSupportRoot.appendingPathComponent("seedPreferences.plist")), format: nil) as? [String: Any])
        XCTAssertEqual(values["fontSize"] as? Int, 19)
        XCTAssertEqual(values["enableAgentModePerfDiagnostics"] as? Bool, true)
    }

    func testFreshDebugDomainNeverInheritsReleaseDiagnosticPreferences() throws {
        let f = Fixture()
        defer { f.cleanup() }
        let release: [String: Any] = ["fontSize": 19, "claudeRawEventLoggingEnabled": true, "claudeRawEventLogFilePath": "/release/logs", "enableAgentModePerfDiagnostics": true, "emitAgentModePerfDiagnosticsToOSLog": true]
        _ = try DebugStateBootstrap.seed(locations: f.debug, cleanSlate: false, releasePreferences: release)
        let values = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: f.debug.applicationSupportRoot.appendingPathComponent("seedPreferences.plist")), format: nil) as? [String: Any])
        XCTAssertEqual(values["fontSize"] as? Int, 19)
        for key in release.keys where key != "fontSize" {
            XCTAssertNil(values[key], key)
        }
    }

    func testHeadlessAdmissionPreventsSeedUntilAllWritersReleaseAndSeedExcludesNewWriters() throws {
        let f = Fixture()
        defer { f.cleanup() }
        let sentinel = f.debug.applicationSupportRoot.appendingPathComponent("prior.txt")
        try f.write(Data("prior".utf8), sentinel)
        var policy: AppMetadataPathPolicy? = .init(locations: f.debug, roots: [f.debug.applicationSupportRoot])
        try policy?.acquireProfileAccess()
        XCTAssertThrowsError(try DebugStateBootstrap.seed(locations: f.debug, cleanSlate: false, releasePreferences: [:]))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("prior".utf8))
        policy = nil
        var seedLease: DebugProfileAccessLease? = try .acquire(locations: f.debug, exclusive: true)
        let nextWriter = AppMetadataPathPolicy(locations: f.debug, roots: [f.debug.applicationSupportRoot])
        XCTAssertThrowsError(try nextWriter.acquireProfileAccess())
        try seedLease?.allowWriters()
        try nextWriter.acquireProfileAccess()
        seedLease = nil
        try withExtendedLifetime(nextWriter) {
            XCTAssertThrowsError(try DebugStateBootstrap.seed(locations: f.debug, cleanSlate: false, releasePreferences: [:]))
        }
    }
}

@MainActor
final class DebugStorageRootAdmissionTests: XCTestCase {
    func testAppClientAdmitsSafeSelectionBeforeRuntimeCreateAndRejectsAliasesBeforeMove() async throws {
        let f = DebugStateBootstrapTests.Fixture()
        defer { f.cleanup() }
        let policy = AppMetadataPathPolicy(locations: f.debug, roots: [f.debug.applicationSupportRoot, f.debug.workspaceRoot])
        let runtime = MCPDomainRuntime(configuration: .init(mode: .app, profileIdentifier: f.debug.profileIdentifier, storageDirectory: f.debug.applicationSupportRoot, workspaceStorageDirectory: f.debug.workspaceRoot, eventDirectory: f.debug.applicationSupportRoot.appendingPathComponent("Events"), temporaryDirectory: f.home.appendingPathComponent("Temporary"), externalReloadInterval: nil, metadataPathPolicy: policy))
        let client = DomainWorkspaceAuthorityClient(store: runtime.workspaceStore, windowID: -1381, metadataPathPolicy: policy)
        let selected = try f.debug.customWorkspaceRoot(selectedDirectory: f.home.appendingPathComponent("Chosen"))
        var workspace = WorkspaceModel(name: "Selected", repoPaths: [])
        let destination = selected.appendingPathComponent("Workspace-Selected-" + workspace.id.uuidString + "/workspace.json")
        XCTAssertThrowsError(try policy.validate(destination))
        try client.admitStorageRoot(selected)
        let created = try await client.create(workspace, fileURL: destination)
        XCTAssertEqual(created.disposition, .applied)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        workspace.currentPromptText = "persisted after relocation"
        let current = await client.workspaceSnapshot(workspace.id)
        let snapshot = try XCTUnwrap(current)
        _ = try await client.saveFailClosed(workspace, fileURL: destination, expectedWorkspaceRevision: snapshot.revisions.workingRevision, expectedContentDigest: snapshot.document.contentDigest)
        XCTAssertEqual(try f.object(destination)["currentPromptText"] as? String, "persisted after relocation")
        let sourceBytes = try Data(contentsOf: destination)
        XCTAssertThrowsError(try client.admitStorageRoot(f.release.applicationSupportRoot))
        let alias = f.home.appendingPathComponent("Alias/RepoPrompt CE Debug")
        try FileManager.default.createDirectory(at: alias.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.release.applicationSupportRoot)
        XCTAssertThrowsError(try client.admitStorageRoot(alias))
        XCTAssertEqual(try Data(contentsOf: destination), sourceBytes)
    }
}

/// A running release app keeps writing while a debug launch captures it. Startup must
/// converge on one verified point-in-time snapshot instead of demanding an idle release,
/// and must still fail closed, never publishing torn state, when production never settles.
extension DebugStateBootstrapTests {
    private func liveProductionWorkspace(_ f: Fixture, sessions: Int) throws -> (directory: URL, sessions: [URL]) {
        let id = UUID()
        let directory = f.release.workspaceRoot.appendingPathComponent("Workspace-Live-" + id.uuidString)
        try f.writeJSON([["id": id.uuidString, "name": "Live"]], f.release.workspaceRoot.appendingPathComponent("workspacesIndex.json"))
        try f.writeJSON(["id": id.uuidString, "name": "Live"], directory.appendingPathComponent("workspace.json"))
        let urls = try (0 ..< sessions).map { index -> URL in
            let url = directory.appendingPathComponent("AgentSessions/AgentSession-" + UUID().uuidString + ".json")
            try f.writeJSON(["items": [["text": "session \(index) turn 0"]]], url)
            return url
        }
        return (directory, urls)
    }

    func testLiveTranscriptWritesBeyondTheOldRetryBudgetConvergeOnLatestVerifiedBytes() throws {
        let f = Fixture()
        defer { f.cleanup() }
        let (directory, sessions) = try liveProductionWorkspace(f, sessions: 6)
        let cache = DebugStateSnapshot.CaptureCache()
        var derivationsAtCapture: [Int] = []
        _ = try DebugStateBootstrap.seed(locations: f.debug, cleanSlate: false, releasePreferences: [:], captureCache: cache, retryDelay: 0) { attempt in
            derivationsAtCapture.append(cache.derivations)
            // An active release agent saves its transcript after each of the first four captures.
            if attempt < 4 { try f.writeJSON(["items": [["text": "turn \(attempt + 1)"]]], sessions[0]) }
        }
        XCTAssertEqual(derivationsAtCapture.count, 5)
        let copy = f.debug.workspaceRoot.appendingPathComponent(directory.lastPathComponent + "/AgentSessions/" + sessions[0].lastPathComponent)
        XCTAssertEqual(try f.object(copy)["items"] as? [[String: String]], [["text": "turn 4"]])
        XCTAssertEqual(try f.object(sessions[0])["items"] as? [[String: String]], [["text": "turn 4"]])
        // Each retry re-derived only the rewritten transcript, not every record again.
        XCTAssertEqual(zip(derivationsAtCapture.dropFirst(), derivationsAtCapture).map { $0 - $1 }, [1, 1, 1, 1])
    }

    func testWorkspaceDocumentChangedBetweenAttemptsIsReparsedNotServedFromCache() throws {
        let f = Fixture()
        defer { f.cleanup() }
        let (directory, sessions) = try liveProductionWorkspace(f, sessions: 1)
        let workspaceURL = directory.appendingPathComponent("workspace.json")
        let id = try XCTUnwrap(f.object(workspaceURL)["id"] as? String)
        var captures = 0
        _ = try DebugStateBootstrap.seed(locations: f.debug, cleanSlate: false, releasePreferences: [:], retryDelay: 0) { attempt in
            captures += 1
            if attempt == 0 { try f.writeJSON(["id": id, "name": "Renamed", "isHiddenInMenus": true], workspaceURL) }
        }
        XCTAssertEqual(captures, 2)
        let index = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: f.debug.workspaceRoot.appendingPathComponent("workspacesIndex.json"))) as? [[String: Any]])
        XCTAssertEqual(index.count, 1)
        XCTAssertEqual(index.first?["name"] as? String, "Renamed")
        XCTAssertEqual(index.first?["isHiddenInMenus"] as? Bool, true)
        let renamed = f.debug.workspaceRoot.appendingPathComponent("Workspace-Renamed-" + id)
        XCTAssertEqual(try f.object(renamed.appendingPathComponent("workspace.json"))["name"] as? String, "Renamed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.appendingPathComponent("AgentSessions/" + sessions[0].lastPathComponent).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.debug.workspaceRoot.appendingPathComponent(directory.lastPathComponent).path))
    }

    func testChangedWorkingJournalIsReparsedWhileItsSavedDocumentStaysUnchanged() throws {
        let f = Fixture()
        defer { f.cleanup() }
        let (directory, _) = try liveProductionWorkspace(f, sessions: 1)
        let workspaceURL = directory.appendingPathComponent("workspace.json")
        let id = try XCTUnwrap(f.object(workspaceURL)["id"] as? String)
        let savedBytes = try Data(contentsOf: workspaceURL)
        let runtime = f.release.applicationSupportRoot.appendingPathComponent(DomainPersistenceCoordinator.runtimeDirectoryName(profileIdentifier: f.release.profileIdentifier))
        let journal = runtime.appendingPathComponent("working-journals/" + id + ".json")
        func writeJournal(_ name: String) throws {
            let working = try JSONSerialization.data(withJSONObject: ["id": id, "name": name])
            try f.writeJSON(["version": 1, "workspaceID": id, "fileURL": workspaceURL.absoluteString, "workingDocument": working.base64EncodedString()], journal)
        }
        try writeJournal("Draft")
        var captures = 0
        _ = try DebugStateBootstrap.seed(locations: f.debug, cleanSlate: false, releasePreferences: [:], retryDelay: 0) { attempt in
            captures += 1
            if attempt == 0 { try writeJournal("Redrafted") }
        }
        XCTAssertEqual(captures, 2)
        let copy = f.debug.workspaceRoot.appendingPathComponent("Workspace-Redrafted-" + id + "/workspace.json")
        XCTAssertEqual(try f.object(copy)["name"] as? String, "Redrafted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.debug.workspaceRoot.appendingPathComponent("Workspace-Draft-" + id).path))
        XCTAssertEqual(try Data(contentsOf: workspaceURL), savedBytes)
    }

    func testOneSourceCapturedTwiceAcrossAChangeIsRejectedRatherThanPublishedAsTwoVersions() throws {
        let f = Fixture()
        defer { f.cleanup() }
        let source = f.release.applicationSupportRoot.appendingPathComponent("Settings/globalSettings.json")
        try f.write(Data("first".utf8), source)
        var plan = DebugStateSnapshot.Plan()
        try plan.add(source, as: "Settings/a.json")
        try f.write(Data("second".utf8), source)
        XCTAssertThrowsError(try plan.add(source, as: "Settings/b.json")) { error in
            guard case DebugStateSnapshot.Failure.sourceChanged = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testDebugOwnedRecoveryUnderTemporaryLookingNamesIsRetainedVerbatim() throws {
        let f = Fixture()
        defer { f.cleanup() }
        try FileManager.default.createDirectory(at: f.release.applicationSupportRoot, withIntermediateDirectories: true)
        let relative = "Workspaces/Workspace-Research.sb-tools-" + UUID().uuidString + "/AgentSessions/.self-compact-recovery/partial.tmp"
        let bytes = Data("debug-owned recovery".utf8)
        try f.write(bytes, f.debug.applicationSupportRoot.appendingPathComponent(relative))
        _ = try DebugStateBootstrap.seed(locations: f.debug, cleanSlate: false, releasePreferences: [:], retryDelay: 0)
        XCTAssertEqual(try Data(contentsOf: f.debug.applicationSupportRoot.appendingPathComponent(relative)), bytes)
    }

    func testProductionThatNeverSettlesFailsClosedWithoutStagingOrReplacingDebugState() throws {
        let f = Fixture()
        defer { f.cleanup() }
        let (_, sessions) = try liveProductionWorkspace(f, sessions: 1)
        let sentinel = f.debug.applicationSupportRoot.appendingPathComponent("prior.txt")
        try f.write(Data("prior".utf8), sentinel)
        var captures = 0
        XCTAssertThrowsError(try DebugStateBootstrap.seed(locations: f.debug, cleanSlate: false, releasePreferences: [:], retryDelay: 0) { attempt in
            captures += 1
            try f.writeJSON(["items": [["text": "write \(attempt)"]]], sessions[0])
        }) { error in
            guard case DebugStateSnapshot.Failure.sourceChanged = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(captures, DebugStateBootstrap.captureAttempts)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("prior".utf8))
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: f.recovery.path)) ?? []
        XCTAssertTrue(leftovers.isEmpty, "Unverified attempts must not stage or archive anything: \(leftovers)")
    }

    func testFinderMetadataAndAtomicWriteTemporariesNeitherSeedNorInvalidateCapture() throws {
        let f = Fixture()
        defer { f.cleanup() }
        let (directory, _) = try liveProductionWorkspace(f, sessions: 1)
        let settings = f.release.applicationSupportRoot.appendingPathComponent("Settings")
        try f.writeJSON(["value": "production"], settings.appendingPathComponent("globalSettings.json"))
        let finderMetadata = [directory.appendingPathComponent(".DS_Store"), settings.appendingPathComponent(".DS_Store")]
        for url in finderMetadata {
            try f.write(Data("view".utf8), url)
        }
        try f.write(Data("abandoned".utf8), directory.appendingPathComponent(".dat.nosync0001.AbCdEf"))
        var captures = 0
        _ = try DebugStateBootstrap.seed(locations: f.debug, cleanSlate: false, releasePreferences: [:], retryDelay: 0) { attempt in
            captures += 1
            for url in finderMetadata {
                try f.write(Data("view \(attempt)".utf8), url)
            }
            try f.write(Data("in flight".utf8), directory.appendingPathComponent(".dat.nosync\(attempt).Tmp"))
        }
        XCTAssertEqual(captures, 1, "Non-state churn must not force a re-capture")
        let names = try FileManager.default.contentsOfDirectory(atPath: f.debug.workspaceRoot.appendingPathComponent(directory.lastPathComponent).path)
        XCTAssertEqual(names.filter { $0 == ".DS_Store" || $0.hasPrefix(".dat.nosync") }, [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.debug.applicationSupportRoot.appendingPathComponent("Settings").path), ["globalSettings.json"])
    }

    func testSourceDeletedDuringCaptureIsRetriedRatherThanReportedUnsafe() throws {
        let f = Fixture()
        defer { f.cleanup() }
        let (directory, sessions) = try liveProductionWorkspace(f, sessions: 2)
        var captures = 0
        _ = try DebugStateBootstrap.seed(locations: f.debug, cleanSlate: false, releasePreferences: [:], retryDelay: 0) { attempt in
            captures += 1
            if attempt == 0 { try FileManager.default.removeItem(at: sessions[1]) }
        }
        XCTAssertEqual(captures, 2)
        let copies = f.debug.workspaceRoot.appendingPathComponent(directory.lastPathComponent + "/AgentSessions")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: copies.path), [sessions[0].lastPathComponent])
    }
}

/// Enumeration and verification share one selection rule per listing; cooperative
/// cancellation stops only at safe points and leaves no partial state behind.
extension DebugStateBootstrapTests {
    func testOwnedTreeExclusionChurnNeitherSeedsNorInvalidatesCapture() throws {
        let f = Fixture()
        defer { f.cleanup() }
        let (directory, _) = try liveProductionWorkspace(f, sessions: 1)
        let settings = f.release.applicationSupportRoot.appendingPathComponent("Settings")
        try f.writeJSON(["value": "production"], settings.appendingPathComponent("globalSettings.json"))
        let index = directory.appendingPathComponent("AgentSessions/AgentSessionIndex.json")
        var captures = 0
        _ = try DebugStateBootstrap.seed(locations: f.debug, cleanSlate: false, releasePreferences: [:], retryDelay: 0) { attempt in
            captures += 1
            // Production rebuilds its index and takes locks/backups while the debug launch captures.
            try f.writeJSON(["rebuilt": attempt], index)
            try f.write(Data("pid".utf8), directory.appendingPathComponent("locks/owner"))
            try f.write(Data("claim".utf8), directory.appendingPathComponent("claims/\(attempt)"))
            try f.write(Data("backup".utf8), settings.appendingPathComponent("Backups/\(attempt).json"))
        }
        XCTAssertEqual(captures, 1, "Excluded names must not force a re-capture")
        let copy = f.debug.workspaceRoot.appendingPathComponent(directory.lastPathComponent)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: copy.path).sorted(), ["AgentSessions", "workspace.json"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.appendingPathComponent("AgentSessions/AgentSessionIndex.json").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.debug.applicationSupportRoot.appendingPathComponent("Settings").path), ["globalSettings.json"])
    }

    func testTransientRecognitionIsExactAndKeepsUserDerivedNames() throws {
        let f = Fixture()
        defer { f.cleanup() }
        let root = f.release.applicationSupportRoot
        let partition = "Partitions/client.sb-tools-0123abcd4567/selection.json"
        try f.write(Data("selection".utf8), root.appendingPathComponent(partition))
        try f.writeJSON(["value": "production"], root.appendingPathComponent("Settings/globalSettings.json"))
        try f.write(Data("safe-save".utf8), root.appendingPathComponent("Settings/globalSettings.json.sb-4993fc53-J85yTY"))
        try f.write(Data("atomic".utf8), root.appendingPathComponent("Settings/.globalSettings.json.\(UUID().uuidString).tmp"))
        try f.write(Data("lock".utf8), root.appendingPathComponent("Settings/globalSettings.json.lock"))
        _ = try DebugStateBootstrap.seed(locations: f.debug, cleanSlate: false, releasePreferences: [:], retryDelay: 0)
        XCTAssertEqual(try Data(contentsOf: f.debug.applicationSupportRoot.appendingPathComponent(partition)), Data("selection".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.debug.applicationSupportRoot.appendingPathComponent("Settings").path), ["globalSettings.json"])
    }

    func testOverlappingSelectionsMustAgreeOnTheMembershipEachConsumed() throws {
        let f = Fixture()
        defer { f.cleanup() }
        let directory = f.release.applicationSupportRoot.appendingPathComponent("Settings")
        try f.write(Data("a".utf8), directory.appendingPathComponent("a.json"))
        try f.write(Data("skip".utf8), directory.appendingPathComponent("skip.json"))
        let filtered = DebugStateSnapshot.Selection(excluding: ["skip.json"])
        var plan = DebugStateSnapshot.Plan()
        XCTAssertEqual(try plan.children(directory, selection: filtered).map(\.lastPathComponent), ["a.json"])
        // A change confined to names the first selection skipped keeps both views consistent.
        try FileManager.default.removeItem(at: directory.appendingPathComponent("skip.json"))
        XCTAssertEqual(try plan.children(directory, selection: .verbatim).map(\.lastPathComponent), ["a.json"])
        try plan.verify()
        // Reverse order: a verbatim view then a filtered view of a changed membership.
        var reversed = DebugStateSnapshot.Plan()
        _ = try reversed.children(directory, selection: .verbatim)
        try f.write(Data("skip".utf8), directory.appendingPathComponent("skip.json"))
        XCTAssertThrowsError(try reversed.children(directory, selection: filtered))
        try FileManager.default.removeItem(at: directory.appendingPathComponent("skip.json"))
        // A name the first selection consumes cannot appear between enumerations or before verification.
        var racing = DebugStateSnapshot.Plan()
        _ = try racing.children(directory, selection: filtered)
        try f.write(Data("b".utf8), directory.appendingPathComponent("b.json"))
        XCTAssertThrowsError(try racing.children(directory, selection: .verbatim)) { error in
            guard case DebugStateSnapshot.Failure.sourceChanged = error else { return XCTFail("Unexpected error: \(error)") }
        }
        try f.write(Data("late".utf8), directory.appendingPathComponent("late.json"))
        XCTAssertThrowsError(try plan.verify())
    }

    func testPagedSQLiteBackupHonorsCancellationBetweenBatchesAndCompletesOtherwise() throws {
        let f = Fixture()
        defer { f.cleanup() }
        let source = f.release.applicationSupportRoot.appendingPathComponent("Overseer/continuity.sqlite")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(source.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA page_size=4096; CREATE TABLE fixture(value BLOB); INSERT INTO fixture VALUES (zeroblob(1500000));", nil, nil, nil), SQLITE_OK)
        sqlite3_close_v2(db)
        let stamp = try DebugStateSnapshot.stamp(source)
        let destinations = f.home.appendingPathComponent("Copies")
        try FileManager.default.createDirectory(at: destinations, withIntermediateDirectories: true)
        var checks = 0
        let cancelled = destinations.appendingPathComponent("cancelled.sqlite")
        XCTAssertThrowsError(try DebugStateSnapshot.copyDatabase(from: source, to: cancelled, cancellation: .init {
            checks += 1
            return checks > 1
        })) { error in
            guard case DebugStateSnapshot.Failure.cancelled = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(checks, 2, "One page batch ran before the stop request was honored")
        var batches = 0
        let complete = destinations.appendingPathComponent("complete.sqlite")
        try DebugStateSnapshot.copyDatabase(from: source, to: complete, cancellation: .init {
            batches += 1
            return false
        })
        XCTAssertGreaterThan(batches, 2, "A multi-batch source is copied in bounded page steps")
        XCTAssertEqual(try DebugStateSnapshot.stamp(source), stamp)
        // A production write between batches would restart the backup; the attempt ends as a
        // retryable source change instead of looping against a busy source.
        var calls = 0
        XCTAssertThrowsError(try DebugStateSnapshot.copyDatabase(from: source, to: destinations.appendingPathComponent("raced.sqlite"), expectedStamp: stamp, cancellation: .init {
            calls += 1
            if calls == 2 {
                var writer: OpaquePointer?
                XCTAssertEqual(sqlite3_open(source.path, &writer), SQLITE_OK)
                XCTAssertEqual(sqlite3_exec(writer, "INSERT INTO fixture VALUES (x'01');", nil, nil, nil), SQLITE_OK)
                sqlite3_close_v2(writer)
            }
            return false
        })) { error in
            guard case DebugStateSnapshot.Failure.sourceChanged = error else { return XCTFail("Unexpected error: \(error)") }
        }
        var copy: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(complete.path, &copy, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close_v2(copy) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(copy, "SELECT length(value) FROM fixture", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(statement, 0), 1_500_000)
    }

    func testCancellationAfterStagedEntriesRemovesTheStageAndALaterLaunchSucceeds() throws {
        let f = Fixture()
        defer { f.cleanup() }
        for name in ["a.json", "b.json", "c.json"] {
            try f.writeJSON(["value": name], f.release.applicationSupportRoot.appendingPathComponent("Settings/" + name))
        }
        let sentinel = f.debug.applicationSupportRoot.appendingPathComponent("prior.txt")
        try f.write(Data("prior".utf8), sentinel)
        let recovery = f.recovery
        // The stop request arrives once publication has already written a staged entry.
        let stagedEntryWritten: () -> Bool = {
            let stages = ((try? FileManager.default.contentsOfDirectory(atPath: recovery.path)) ?? []).filter { UUID(uuidString: $0) != nil }
            return stages.contains { stage in
                ((try? FileManager.default.contentsOfDirectory(atPath: recovery.appendingPathComponent(stage + "/Settings").path)) ?? []).isEmpty == false
            }
        }
        var captures = 0
        XCTAssertThrowsError(try DebugStateBootstrap.seed(locations: f.debug, cleanSlate: false, releasePreferences: [:], retryDelay: 0, cancellation: .init(stagedEntryWritten)) { _ in
            captures += 1
        }) { error in
            guard case DebugStateSnapshot.Failure.cancelled = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(captures, 1, "Cancellation is not retried")
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: recovery.path)) ?? [], [])
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("prior".utf8))
        _ = try DebugStateBootstrap.seed(locations: f.debug, cleanSlate: false, releasePreferences: [:], retryDelay: 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.debug.applicationSupportRoot.appendingPathComponent("Settings").path).sorted(), ["a.json", "b.json", "c.json"])
    }

    func testStartEmptyCleanPublicationHonorsCancellationAndKeepsTheProfile() throws {
        let f = Fixture()
        defer { f.cleanup() }
        try FileManager.default.createDirectory(at: f.release.applicationSupportRoot, withIntermediateDirectories: true)
        let sentinel = f.debug.applicationSupportRoot.appendingPathComponent("prior.txt")
        try f.write(Data("prior".utf8), sentinel)
        var stop = false
        XCTAssertThrowsError(try DebugStateBootstrap.seed(locations: f.debug, cleanSlate: true, releasePreferences: [:], retryDelay: 0, cancellation: .init { stop }) { _ in
            stop = true
        }) { error in
            guard case DebugStateSnapshot.Failure.cancelled = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("prior".utf8))
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: f.recovery.path)) ?? [], [])
    }

    func testStartupSIGTERMIsRecordedThenRestoredAndDelivered() throws {
        func disposition() -> Int {
            var current = sigaction()
            sigaction(SIGTERM, nil, &current)
            return unsafeBitCast(current.__sigaction_u.__sa_handler, to: Int.self)
        }
        let original = disposition()
        let request = try XCTUnwrap(DebugStateBootstrap.TerminationRequest.install())
        XCTAssertFalse(request.isRequested)
        XCTAssertNotEqual(disposition(), original)
        raise(SIGTERM) // Recorded by the startup handler, not delivered to the default action.
        XCTAssertTrue(request.isRequested)
        XCTAssertThrowsError(try DebugStateSnapshot.Cancellation { request.isRequested }.check())
        var delivered = false
        request.finish { delivered = true }
        XCTAssertTrue(delivered, "A recorded stop request is delivered after preparation")
        XCTAssertEqual(disposition(), original, "The previous disposition is reinstated before delivery")
        let next = try XCTUnwrap(DebugStateBootstrap.TerminationRequest.install())
        XCTAssertFalse(next.isRequested, "Each preparation starts without a stale request")
        next.finish { XCTFail("No request was made") }
        XCTAssertEqual(disposition(), original)
    }

    func testStartEmptyIsOfferedOnlyWhereAnEmptyProfileCanRecover() {
        let recoverable: [Error] = [DebugStateSnapshot.Failure.oracleRetention("fixture"), DebugStateSnapshot.Failure.sourceChanged, DebugStateSnapshot.Failure.unsafeFile, DebugStateSnapshot.Failure.database(SQLITE_BUSY), DebugStateSnapshot.Failure.unsupportedWAL]
        let unrecoverable: [Error] = [DebugStateSnapshot.Failure.cancelled, DebugStateSnapshot.Failure.unsafeDestination, DebugProfileAccessLease.Failure.busy, ProfileLocationError.releaseAlias("/fixture")]
        XCTAssertEqual(recoverable.map(DebugStateBootstrap.startEmptyCanRecover), Array(repeating: true, count: recoverable.count))
        XCTAssertEqual(unrecoverable.map(DebugStateBootstrap.startEmptyCanRecover), Array(repeating: false, count: unrecoverable.count))
    }
}

final class DebugProfileInitializationTests: XCTestCase {
    private let connectionKeys = [
        "ClaudeCodeConnected", "CodexCLIConnected", "OpenCodeCLIConnected",
        "CursorCLIConnected", "GrokBuildCLIConnected"
    ]

    func testNormalRelaunchPreservesEveryCLIConnectionAndDebugSettings() throws {
        try withProfile { fixture, defaults, domain in
            let sourceSettings = fixture.release.applicationSupportRoot.appendingPathComponent("Settings/globalSettings.json")
            let debugSettings = fixture.debug.applicationSupportRoot.appendingPathComponent("Settings/globalSettings.json")
            let releasePreferences = Dictionary(uniqueKeysWithValues: connectionKeys.map { ($0, false) })
            try writeReleasePreferences(releasePreferences, fixture: fixture)
            try fixture.writeJSON(["value": "production"], sourceSettings)

            XCTAssertEqual(try prepare(fixture, defaults: defaults, domain: domain), .imported)
            XCTAssertEqual(try Data(contentsOf: debugSettings), try Data(contentsOf: sourceSettings))
            for key in connectionKeys {
                XCTAssertFalse(defaults.bool(forKey: key), key)
                defaults.set(true, forKey: key)
            }
            defaults.set(17, forKey: "fontSize")
            try fixture.writeJSON(["value": "debug-only"], debugSettings)
            let debugBytes = try Data(contentsOf: debugSettings)
            let receiptURL = fixture.debug.applicationSupportRoot.appendingPathComponent("debugSeed.json")
            let receiptBytes = try Data(contentsOf: receiptURL)
            try fixture.writeJSON(["value": "production changed"], sourceSettings)
            try writeReleasePreferences(releasePreferences, fixture: fixture)

            for _ in 0 ..< 2 {
                XCTAssertEqual(try prepare(fixture, defaults: defaults, domain: domain, preferenceSourceURL: fixture.home), .reused)
                for key in connectionKeys {
                    XCTAssertTrue(defaults.bool(forKey: key), key)
                }
                XCTAssertEqual(defaults.integer(forKey: "fontSize"), 17)
                XCTAssertEqual(try Data(contentsOf: debugSettings), debugBytes)
                XCTAssertEqual(try Data(contentsOf: receiptURL), receiptBytes)
            }
            XCTAssertEqual(try fixture.object(sourceSettings)["value"] as? String, "production changed")
        }
    }

    func testExistingDebugFilesOrPreferencesWithoutReceiptAreAdopted() throws {
        for hasExistingFile in [false, true] {
            try withProfile { fixture, defaults, domain in
                let existingFile = fixture.debug.applicationSupportRoot.appendingPathComponent("unknown-debug-state.bin")
                let bytes = Data([0, 17, 255])
                if hasExistingFile {
                    try fixture.write(bytes, existingFile)
                } else {
                    defaults.set(false, forKey: "ClaudeCodeConnected")
                }
                let previousPreferences = defaults.persistentDomain(forName: domain) ?? [:]

                XCTAssertEqual(try prepare(fixture, defaults: defaults, domain: domain, preferenceSourceURL: fixture.home), .reused)

                XCTAssertTrue(NSDictionary(dictionary: previousPreferences).isEqual(to: defaults.persistentDomain(forName: domain) ?? [:]))
                XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.debug.applicationSupportRoot.appendingPathComponent("debugSeed.json").path))
                if hasExistingFile { XCTAssertEqual(try Data(contentsOf: existingFile), bytes) }
            }
        }
    }

    func testLegacyReceiptWithoutPublicationIDDoesNotReplayOldPreferences() throws {
        try withProfile { fixture, defaults, domain in
            let receiptURL = fixture.debug.applicationSupportRoot.appendingPathComponent("debugSeed.json")
            try fixture.writeJSON([
                "version": 1, "profile": fixture.debug.preferencesDomain,
                "cleanSlate": false, "copiedFiles": 0, "copiedBytes": 0, "seconds": 0
            ], receiptURL)
            let snapshotURL = fixture.debug.applicationSupportRoot.appendingPathComponent("seedPreferences.plist")
            let staleSnapshot = Data("not a plist: warm launches must not load this snapshot".utf8)
            try fixture.write(staleSnapshot, snapshotURL)
            defaults.set(true, forKey: "CodexCLIConnected")
            defaults.set(19, forKey: "fontSize")

            XCTAssertEqual(try prepare(fixture, defaults: defaults, domain: domain, preferenceSourceURL: fixture.home), .reused)

            XCTAssertTrue(defaults.bool(forKey: "CodexCLIConnected"))
            XCTAssertEqual(defaults.integer(forKey: "fontSize"), 19)
            XCTAssertNil(defaults.object(forKey: DebugStateBootstrap.preferencesIDKey))
            XCTAssertEqual(try Data(contentsOf: snapshotURL), staleSnapshot)
        }
    }

    func testExplicitCleanSlateRemainsEmptyUntilAnotherExplicitReset() throws {
        try withProfile { fixture, defaults, domain in
            try writeReleasePreferences(["CodexCLIConnected": true], fixture: fixture)
            let sourceSettings = fixture.release.applicationSupportRoot.appendingPathComponent("Settings/globalSettings.json")
            let debugSettings = fixture.debug.applicationSupportRoot.appendingPathComponent("Settings/globalSettings.json")
            try fixture.writeJSON(["value": "production"], sourceSettings)
            XCTAssertEqual(try prepare(fixture, defaults: defaults, domain: domain), .imported)

            XCTAssertEqual(try prepare(fixture, defaults: defaults, domain: domain, cleanSlate: true), .reset)
            let resetID = try XCTUnwrap(defaults.string(forKey: DebugStateBootstrap.preferencesIDKey))
            XCTAssertNil(defaults.object(forKey: "CodexCLIConnected"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: debugSettings.path))
            XCTAssertEqual(try prepare(fixture, defaults: defaults, domain: domain), .reused)
            XCTAssertNil(defaults.object(forKey: "CodexCLIConnected"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: debugSettings.path))
            XCTAssertEqual(defaults.string(forKey: DebugStateBootstrap.preferencesIDKey), resetID)

            defaults.set(true, forKey: "CodexCLIConnected")
            try fixture.writeJSON(["value": "new debug settings"], debugSettings)
            XCTAssertEqual(try prepare(fixture, defaults: defaults, domain: domain, cleanSlate: true), .reset)
            XCTAssertNil(defaults.object(forKey: "CodexCLIConnected"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: debugSettings.path))
            XCTAssertNotEqual(defaults.string(forKey: DebugStateBootstrap.preferencesIDKey), resetID)
            XCTAssertEqual(try fixture.object(sourceSettings)["value"] as? String, "production")
        }
    }

    func testInterruptedPreferencePublicationRecoversOnceWithoutRecapturingProduction() throws {
        try withProfile { fixture, defaults, domain in
            let sourceSettings = fixture.release.applicationSupportRoot.appendingPathComponent("Settings/globalSettings.json")
            let debugSettings = fixture.debug.applicationSupportRoot.appendingPathComponent("Settings/globalSettings.json")
            try fixture.writeJSON(["value": "captured production"], sourceSettings)
            defaults.set(false, forKey: "ClaudeCodeConnected")
            let receipt = try DebugStateBootstrap.seed(
                locations: fixture.debug,
                cleanSlate: false,
                releasePreferences: ["ClaudeCodeConnected": true, "fontSize": 15]
            )
            try fixture.writeJSON(["value": "new production state"], sourceSettings)

            XCTAssertEqual(try prepare(fixture, defaults: defaults, domain: domain, preferenceSourceURL: fixture.home), .recoveredPreferences)
            XCTAssertTrue(defaults.bool(forKey: "ClaudeCodeConnected"))
            XCTAssertEqual(defaults.integer(forKey: "fontSize"), 15)
            XCTAssertEqual(defaults.string(forKey: DebugStateBootstrap.preferencesIDKey), try XCTUnwrap(receipt.preferencesID).uuidString)
            XCTAssertEqual(try fixture.object(debugSettings)["value"] as? String, "captured production")

            defaults.set(false, forKey: "ClaudeCodeConnected")
            defaults.set(21, forKey: "fontSize")
            XCTAssertEqual(try prepare(fixture, defaults: defaults, domain: domain, preferenceSourceURL: fixture.home), .reused)
            XCTAssertFalse(defaults.bool(forKey: "ClaudeCodeConnected"))
            XCTAssertEqual(defaults.integer(forKey: "fontSize"), 21)
        }
    }

    func testHeadlessWriterAllowsReuseButPreventsImportAndReset() throws {
        for hasExistingPreferences in [false, true] {
            try withProfile { fixture, defaults, domain in
                if hasExistingPreferences { defaults.set(true, forKey: "CursorCLIConnected") }
                do {
                    let writer = try DebugProfileAccessLease.acquire(locations: fixture.debug, exclusive: false)
                    defer { withExtendedLifetime(writer) {} }
                    if hasExistingPreferences {
                        XCTAssertEqual(try prepare(fixture, defaults: defaults, domain: domain), .reused)
                    } else {
                        XCTAssertThrowsError(try prepare(fixture, defaults: defaults, domain: domain)) { error in
                            guard case DebugProfileAccessLease.Failure.busy = error else { return XCTFail("Unexpected error: \(error)") }
                        }
                    }
                    XCTAssertThrowsError(try prepare(fixture, defaults: defaults, domain: domain, cleanSlate: true)) { error in
                        guard case DebugProfileAccessLease.Failure.busy = error else { return XCTFail("Unexpected error: \(error)") }
                    }
                }
                XCTAssertEqual(defaults.bool(forKey: "CursorCLIConnected"), hasExistingPreferences)
                XCTAssertNil(defaults.object(forKey: DebugStateBootstrap.preferencesIDKey))
                XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.debug.applicationSupportRoot.appendingPathComponent("debugSeed.json").path))
            }
        }
    }

    func testFailedInitialImportLeavesNoCompletedProfileAndCanRetry() throws {
        try withProfile { fixture, defaults, domain in
            let sourcePreferences = releasePreferencesURL(fixture)
            try fixture.write(Data("invalid property list".utf8), sourcePreferences)

            XCTAssertThrowsError(try prepare(fixture, defaults: defaults, domain: domain))
            XCTAssertTrue((defaults.persistentDomain(forName: domain) ?? [:]).isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.debug.applicationSupportRoot.path))

            try writeReleasePreferences(["GrokBuildCLIConnected": true], fixture: fixture)
            XCTAssertEqual(try prepare(fixture, defaults: defaults, domain: domain), .imported)
            XCTAssertTrue(defaults.bool(forKey: "GrokBuildCLIConnected"))
        }
    }

    func testFinderBookkeepingAloneDoesNotSuppressInitialImport() throws {
        try withProfile { fixture, defaults, domain in
            try fixture.write(Data([0]), fixture.debug.applicationSupportRoot.appendingPathComponent(".DS_Store"))
            try writeReleasePreferences(["OpenCodeCLIConnected": true], fixture: fixture)

            XCTAssertEqual(try prepare(fixture, defaults: defaults, domain: domain), .imported)
            XCTAssertTrue(defaults.bool(forKey: "OpenCodeCLIConnected"))
        }
    }

    private func withProfile(_ body: (DebugStateBootstrapTests.Fixture, UserDefaults, String) throws -> Void) throws {
        let fixture = DebugStateBootstrapTests.Fixture()
        let domain = "DebugProfileInitializationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer {
            defaults.removePersistentDomain(forName: domain)
            fixture.cleanup()
        }
        try body(fixture, defaults, domain)
    }

    private func prepare(
        _ fixture: DebugStateBootstrapTests.Fixture,
        defaults: UserDefaults,
        domain: String,
        cleanSlate: Bool = false,
        preferenceSourceURL: URL? = nil
    ) throws -> DebugStateBootstrap.PreparationAction {
        try DebugStateBootstrap.prepareProfile(
            locations: fixture.debug,
            defaults: defaults,
            preferencesDomain: domain,
            cleanSlate: cleanSlate,
            preferenceSourceURL: preferenceSourceURL
        ).action
    }

    private func releasePreferencesURL(_ fixture: DebugStateBootstrapTests.Fixture) -> URL {
        fixture.home.appendingPathComponent("Library/Preferences/\(fixture.release.preferencesDomain).plist")
    }

    private func writeReleasePreferences(_ preferences: [String: Any], fixture: DebugStateBootstrapTests.Fixture) throws {
        try fixture.write(
            PropertyListSerialization.data(fromPropertyList: preferences, format: .binary, options: 0),
            releasePreferencesURL(fixture)
        )
    }
}
