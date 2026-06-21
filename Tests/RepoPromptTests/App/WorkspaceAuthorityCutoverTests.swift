@testable import RepoPrompt
@testable import RepoPromptCore
import XCTest

@MainActor
final class WorkspaceAuthorityCutoverTests: XCTestCase {
    func testStoreLifecycleOwnsRootReadinessUnloadAndOpaqueQuery() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceAuthorityLifecycle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: root.appendingPathComponent("fixture.txt"))
        defer { try? FileManager.default.removeItem(at: root) }

        let store = WorkspaceFileContextStore(enableCatalogShardShadowValidation: false)
        let owner = WorkspaceSessionStoreLifecycleFactory.make(store: store)
        let query = owner.makeQueryCapability()
        let workspace = WorkspaceModel(name: "Lifecycle", repoPaths: [root.path])

        let readiness = try await owner.hydrate(workspace: workspace, generation: 7)
        XCTAssertEqual(readiness.workspaceID, workspace.id)
        XCTAssertEqual(readiness.generation, 7)
        let loadedPaths = await query.roots().map(\.standardizedFullPath)
        XCTAssertEqual(loadedPaths, [root.path])

        try await owner.unload(generation: 7)
        let rootsAfterUnload = await query.roots()
        XCTAssertTrue(rootsAfterUnload.isEmpty)
        await owner.close()
        let rootsAfterClose = await query.roots()
        XCTAssertTrue(rootsAfterClose.isEmpty)
    }

    func testCoreAndLegacyBackendsShareCompleteCommandParityMatrix() async throws {
        let fixture = CommandParityFixture()
        let sessionID = WorkspaceSessionID()
        let input = WorkspaceSessionHydrationInput(
            workspaces: [fixture.workspaceA, fixture.workspaceB],
            activeWorkspaceID: fixture.workspaceA.id
        )
        let coreLifecycle = WorkspaceSessionStoreLifecycleFactory.make(
            store: WorkspaceFileContextStore(enableCatalogShardShadowValidation: false)
        )
        let legacyLifecycle = WorkspaceSessionStoreLifecycleFactory.make(
            store: WorkspaceFileContextStore(enableCatalogShardShadowValidation: false)
        )
        let host = RepoPromptCoreHost()
        let createdRegistration = await host.createSession(
            id: sessionID,
            dependencies: RepoPromptCoreSessionDependencies(
                load: { input },
                lifecycleOwner: coreLifecycle
            )
        )
        let registration = try XCTUnwrap(createdRegistration)
        let legacy = LegacyWorkspaceSessionBackend(
            sessionID: sessionID,
            load: { input },
            lifecycleOwner: legacyLifecycle
        )

        guard case let .awaitingFirstSnapshotApplication(coreFirst) = await host.hydrateSession(sessionID),
              case let .awaitingFirstSnapshotApplication(legacyFirst) = await legacy.hydrate()
        else { return XCTFail("both backends must hydrate") }
        XCTAssertEqual(coreFirst.snapshotSequence, legacyFirst.snapshotSequence)
        guard case .activated = await host.acknowledgeFirstSnapshotApplied(
            sessionID: sessionID,
            sequence: coreFirst.snapshotSequence
        ), case .activated = await legacy.activate(appliedSnapshotSequence: legacyFirst.snapshotSequence)
        else { return XCTFail("both backends must activate") }

        let runner = CommandParityRunner(core: registration.handle, legacy: legacy, testCase: self)
        try await runner.run(.workspace(.create(fixture.workspaceC, makeActive: false)))
        try await runner.run(.workspace(.create(fixture.workspaceD, makeActive: true)))
        var renamedC = fixture.workspaceC
        renamedC.name = "C renamed"
        try await runner.run(.workspace(.replace(renamedC)))
        var invalidReplacement = renamedC
        invalidReplacement.repoPaths = ["/bypass"]
        try await runner.run(.workspace(.replace(invalidReplacement)))
        try await runner.run(.workspace(.replaceOrderedRoots(workspaceID: fixture.workspaceC.id, roots: ["/c"])))
        try await runner.run(.workspace(.setActive(workspaceID: fixture.workspaceA.id)))
        try await runner.run(.workspace(.setActive(workspaceID: fixture.workspaceB.id)))
        try await runner.run(.composeTab(.create(
            workspaceID: fixture.workspaceA.id,
            tab: fixture.tab3,
            makeActive: false
        )))
        var patchedTab3 = fixture.tab3
        patchedTab3.name = "Patched T3"
        patchedTab3.promptText = "patched"
        try await runner.run(.composeTab(.patch(
            workspaceID: fixture.workspaceA.id,
            tabID: fixture.tab3.id,
            patch: ComposeTabNonSelectionPatch(tab: patchedTab3)
        )))
        try await runner.run(.composeTab(.activate(workspaceID: fixture.workspaceA.id, tabID: fixture.tab3.id)))
        try await runner.run(.composeTab(.reorder(
            workspaceID: fixture.workspaceA.id,
            orderedTabIDs: [fixture.tab3.id, fixture.tab1.id, fixture.tab2.id]
        )))
        try await runner.run(.composeTab(.stash(
            workspaceID: fixture.workspaceA.id,
            tabID: fixture.tab2.id,
            stashedTabID: fixture.stashedTab2ID,
            stashedAt: fixture.timestamp
        )))
        var patchedStashedTab2 = fixture.tab2
        patchedStashedTab2.activeAgentSessionID = fixture.agentSessionID
        try await runner.run(.composeTab(.patchStashed(
            workspaceID: fixture.workspaceA.id,
            stashedTabID: fixture.stashedTab2ID,
            patch: ComposeTabNonSelectionPatch(tab: patchedStashedTab2)
        )))
        try await runner.run(.composeTab(.restore(
            workspaceID: fixture.workspaceA.id,
            stashedTabID: fixture.stashedTab2ID
        )))
        try await runner.run(.composeTab(.deleteStashed(
            workspaceID: fixture.workspaceA.id,
            stashedTabIDs: [fixture.initialStashedID]
        )))
        try await runner.run(.composeTab(.remove(workspaceID: fixture.workspaceA.id, tabID: fixture.tab3.id)))
        try await runner.run(.selection(WorkspaceSelectionCommand(
            workspaceID: fixture.workspaceA.id,
            tabID: fixture.tab1.id,
            expectedRevision: 0,
            selection: StoredSelection(selectedPaths: ["Sources/A.swift"])
        )))
        var compoundTab = fixture.tab1
        compoundTab.name = "Compound"
        try await runner.run(.selectionAndPatch(WorkspaceSelectionAndTabPatchCommand(
            selection: WorkspaceSelectionCommand(
                workspaceID: fixture.workspaceA.id,
                tabID: fixture.tab1.id,
                expectedRevision: 1,
                selection: StoredSelection(selectedPaths: ["Sources/B.swift"])
            ),
            patch: ComposeTabNonSelectionPatch(tab: compoundTab)
        )))
        try await runner.run(.switchWorkspace(WorkspaceSwitchCommand(
            targetWorkspaceID: fixture.workspaceB.id,
            shouldSaveCurrentState: true,
            reason: .user
        )))
        try await runner.run(.switchWorkspace(WorkspaceSwitchCommand(
            targetWorkspaceID: fixture.workspaceB.id,
            shouldSaveCurrentState: false,
            reason: .user
        )))
        let beforeRefresh = await registration.handle.currentSnapshot()
        let readiness = try XCTUnwrap(beforeRefresh).readiness.generation
        try await runner.run(.refresh(WorkspaceRefreshCommand(
            workspaceID: fixture.workspaceB.id,
            expectedReadinessGeneration: readiness
        )))
        try await runner.run(.workspace(.replaceOrderedRoots(
            workspaceID: fixture.workspaceB.id,
            roots: ["/active-b"]
        )))
        try await runner.run(.workspace(.delete(workspaceID: fixture.workspaceC.id)))
        try await runner.run(.workspace(.create(fixture.workspaceA, makeActive: false)))
        try await runner.run(.persistence(.saveIndex))
        try await runner.run(.persistence(.saveWorkspace(workspaceID: fixture.workspaceB.id)))
        try await runner.run(.persistence(.flushWorkspace(workspaceID: fixture.workspaceB.id)))
        try await runner.run(.persistence(.reloadWorkspace(workspaceID: fixture.workspaceB.id)))
        try await runner.run(.persistence(.reloadIndex))

        await registration.handle.shutdown()
        await legacy.shutdown()
    }

    func testCoreAndLegacyBackendsShareSuccessfulPersistenceAndReloadSemantics() async throws {
        let fixture = CommandParityFixture()
        let input = WorkspaceSessionHydrationInput(
            workspaces: [fixture.workspaceA, fixture.workspaceB],
            activeWorkspaceID: fixture.workspaceA.id
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceCommandParity-\(UUID().uuidString)")
        let coreRoot = root.appendingPathComponent("core")
        let legacyRoot = root.appendingPathComponent("legacy")
        try FileManager.default.createDirectory(at: coreRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let coreIndexURL = coreRoot.appendingPathComponent("index.json")
        let legacyIndexURL = legacyRoot.appendingPathComponent("index.json")
        let coreWorkspaceURL: @Sendable (WorkspaceModel) -> URL? = {
            coreRoot.appendingPathComponent("\($0.id.uuidString).json")
        }
        let legacyWorkspaceURL: @Sendable (WorkspaceModel) -> URL? = {
            legacyRoot.appendingPathComponent("\($0.id.uuidString).json")
        }
        let sessionID = WorkspaceSessionID()
        let coreLifecycle = WorkspaceSessionStoreLifecycleFactory.make(
            store: WorkspaceFileContextStore(enableCatalogShardShadowValidation: false)
        )
        let legacyLifecycle = WorkspaceSessionStoreLifecycleFactory.make(
            store: WorkspaceFileContextStore(enableCatalogShardShadowValidation: false)
        )
        let host = RepoPromptCoreHost()
        let createdRegistration = await host.createSession(
            id: sessionID,
            dependencies: RepoPromptCoreSessionDependencies(
                load: { input },
                lifecycleOwner: coreLifecycle,
                workspaceURL: coreWorkspaceURL,
                indexURL: { coreIndexURL }
            )
        )
        let registration = try XCTUnwrap(createdRegistration)
        let legacy = LegacyWorkspaceSessionBackend(
            sessionID: sessionID,
            load: { input },
            lifecycleOwner: legacyLifecycle,
            workspaceURL: legacyWorkspaceURL,
            indexURL: { legacyIndexURL }
        )
        guard case let .awaitingFirstSnapshotApplication(coreFirst) = await host.hydrateSession(sessionID),
              case let .awaitingFirstSnapshotApplication(legacyFirst) = await legacy.hydrate(),
              case .activated = await host.acknowledgeFirstSnapshotApplied(
                  sessionID: sessionID,
                  sequence: coreFirst.snapshotSequence
              ), case .activated = await legacy.activate(appliedSnapshotSequence: legacyFirst.snapshotSequence)
        else { return XCTFail("both persistence backends must activate") }

        let runner = CommandParityRunner(core: registration.handle, legacy: legacy, testCase: self)
        var patched = fixture.tab1
        patched.promptText = "persisted"
        try await runner.run(.composeTab(.patch(
            workspaceID: fixture.workspaceA.id,
            tabID: fixture.tab1.id,
            patch: ComposeTabNonSelectionPatch(tab: patched)
        )))
        try await runner.run(.persistence(.saveWorkspace(workspaceID: fixture.workspaceA.id)))
        try await runner.run(.persistence(.saveWorkspace(workspaceID: fixture.workspaceA.id)))
        patched.promptText = "flushed"
        try await runner.run(.composeTab(.patch(
            workspaceID: fixture.workspaceA.id,
            tabID: fixture.tab1.id,
            patch: ComposeTabNonSelectionPatch(tab: patched)
        )))
        try await runner.run(.persistence(.flushWorkspace(workspaceID: fixture.workspaceA.id)))
        try await runner.run(.persistence(.saveIndex))
        let coreIndexObject = try JSONSerialization.jsonObject(with: Data(contentsOf: coreIndexURL)) as? NSObject
        let legacyIndexObject = try JSONSerialization.jsonObject(with: Data(contentsOf: legacyIndexURL)) as? NSObject
        XCTAssertEqual(coreIndexObject, legacyIndexObject)

        var reloadedB = fixture.workspaceB
        reloadedB.name = "Reloaded inactive B"
        let reloadedBBytes = try JSONEncoder().encode(reloadedB)
        try reloadedBBytes.write(to: XCTUnwrap(coreWorkspaceURL(reloadedB)))
        try reloadedBBytes.write(to: XCTUnwrap(legacyWorkspaceURL(reloadedB)))
        try await runner.run(.persistence(.reloadWorkspace(workspaceID: fixture.workspaceB.id)))

        var reloadedA = fixture.workspaceA
        reloadedA.name = "Reloaded active A"
        let reloadedABytes = try JSONEncoder().encode(reloadedA)
        try reloadedABytes.write(to: XCTUnwrap(coreWorkspaceURL(reloadedA)))
        try reloadedABytes.write(to: XCTUnwrap(legacyWorkspaceURL(reloadedA)))
        try await runner.run(.persistence(.reloadWorkspace(workspaceID: fixture.workspaceA.id)))

        await registration.handle.shutdown()
        await legacy.shutdown()
    }

    func testCoreBackendConstructsOnlySelectedRuntimeAndAdmitsAfterFirstSnapshot() async throws {
        let defaults = isolatedDefaults()
        defaults.set("core", forKey: RepoPromptAppCoreContainer.backendDefaultsKey)
        let container = RepoPromptAppCoreContainer(userDefaults: defaults)
        let legacyConstructions = ConstructionCounter()
        let workspace = WorkspaceModel(name: "Core", repoPaths: [])
        let lifecycleOwner = WorkspaceSessionStoreLifecycleFactory.make(
            store: WorkspaceFileContextStore(enableCatalogShardShadowValidation: false)
        )

        let bootstrap = container.beginRuntime(
            windowID: 501,
            coreDependencies: {
                RepoPromptCoreSessionDependencies(
                    load: { WorkspaceSessionHydrationInput(workspaces: [workspace], activeWorkspaceID: workspace.id) },
                    lifecycleOwner: lifecycleOwner
                )
            },
            legacyFactory: { _ in
                await legacyConstructions.increment()
                throw TestFailure.unexpectedLegacyConstruction
            }
        )

        let preRuntimeAdmission = await bootstrap.commandIngress.admit()
        XCTAssertEqual(preRuntimeAdmission, .notReady(.hydrating))
        let runtime = try await bootstrap.runtimeTask.value
        let hydration = await runtime.hydrate()
        guard case let .awaitingFirstSnapshotApplication(first) = hydration else {
            return XCTFail("expected first authoritative snapshot")
        }
        XCTAssertEqual(first.stateGeneration, 1)
        let preActivationAdmission = await runtime.commandIngress.admit()
        XCTAssertEqual(preActivationAdmission, .notReady(.awaitingActivation))
        guard case .activated = await runtime.activateAfterApplyingFirstSnapshot(first.snapshotSequence) else {
            return XCTFail("expected activation")
        }
        guard case let .admitted(token) = await runtime.commandIngress.admit() else {
            return XCTFail("expected admission")
        }
        XCTAssertEqual(token.sessionID, first.sessionID)
        let legacyConstructionCount = await legacyConstructions.value()
        XCTAssertEqual(legacyConstructionCount, 0)
        await runtime.shutdown()
        container.releaseRuntime(windowID: 501)
    }

    func testLegacyNextLaunchRollbackReadsCurrentWorkspaceBytesWithoutCoreConstruction() async throws {
        let defaults = isolatedDefaults()
        defaults.set("legacy", forKey: RepoPromptAppCoreContainer.backendDefaultsKey)
        let container = RepoPromptAppCoreContainer(userDefaults: defaults)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceAuthorityCutoverTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = WorkspaceModel(name: "Rollback", repoPaths: [root.path])
        let bytes = try JSONEncoder().encode(workspace)
        let decoded = try JSONDecoder().decode(WorkspaceModel.self, from: bytes)
        let lifecycleOwner = WorkspaceSessionStoreLifecycleFactory.make(
            store: WorkspaceFileContextStore(enableCatalogShardShadowValidation: false)
        )

        let bootstrap = container.beginRuntime(
            windowID: 502,
            coreDependencies: {
                XCTFail("inactive Core dependencies must not be evaluated")
                return RepoPromptCoreSessionDependencies(
                    load: { throw TestFailure.unexpectedCoreConstruction },
                    lifecycleOwner: lifecycleOwner
                )
            },
            legacyFactory: { sessionID in
                let backend = LegacyWorkspaceSessionBackend(
                    sessionID: sessionID,
                    load: {
                        WorkspaceSessionHydrationInput(workspaces: [decoded], activeWorkspaceID: decoded.id)
                    },
                    lifecycleOwner: lifecycleOwner
                )
                return WorkspaceSessionRuntimeBundle(
                    sessionID: sessionID,
                    commandIngress: backend,
                    hydrate: { await backend.hydrate() },
                    activateAfterApplyingFirstSnapshot: { sequence in
                        await backend.activate(appliedSnapshotSequence: sequence)
                    },
                    shutdown: { await backend.shutdown() }
                )
            }
        )

        let runtime = try await bootstrap.runtimeTask.value
        guard case let .awaitingFirstSnapshotApplication(first) = await runtime.hydrate() else {
            return XCTFail("expected rollback snapshot")
        }
        XCTAssertEqual(first.workspaces, [workspace])
        guard case .activated = await runtime.activateAfterApplyingFirstSnapshot(first.snapshotSequence) else {
            return XCTFail("expected rollback activation")
        }
        guard case .admitted = await runtime.commandIngress.admit() else {
            return XCTFail("expected rollback admission")
        }
        await runtime.shutdown()
        container.releaseRuntime(windowID: 502)
    }

    func testObservationBridgeAppliesFirstSnapshotWithoutCommandFeedback() async {
        let workspace = WorkspaceModel(name: "Observed", repoPaths: [])
        let snapshot = WorkspaceSessionSnapshot(
            sessionID: WorkspaceSessionID(),
            snapshotSequence: 1,
            stateGeneration: 1,
            workspaces: [workspace],
            activeWorkspaceID: workspace.id,
            selectionRevisions: [:],
            dirtyGenerations: [workspace.id: 0],
            savedGenerations: [workspace.id: 0],
            switchState: .idle,
            readiness: WorkspaceSessionReadiness(generation: 1, isReady: false),
            availability: .awaitingActivation
        )
        var applied: [UInt64] = []
        let bridge = WorkspaceSessionObservationBridge(
            snapshotProvider: { snapshot },
            observationProvider: { _ in AsyncStream { $0.finish() } },
            applySnapshot: { applied.append($0.snapshotSequence) }
        )
        await bridge.applyFirstAuthoritativeSnapshot(snapshot)
        await bridge.waitUntilApplied(sequence: 1)
        XCTAssertEqual(applied, [1])
        XCTAssertEqual(bridge.projectionApplyDepth, 0)
    }

    func testAuthoritativeActiveWorkspaceTransitionNotifiesAfterCompleteProjectionApply() {
        let sessionID = WorkspaceSessionID()
        let firstWorkspace = WorkspaceModel(name: "First", repoPaths: [])
        let secondTab = ComposeTabState(name: "Second tab")
        let secondWorkspace = WorkspaceModel(
            name: "Second",
            repoPaths: [],
            composeTabs: [secondTab],
            activeComposeTabID: secondTab.id
        )
        let initialSnapshot = WorkspaceSessionSnapshot(
            sessionID: sessionID,
            snapshotSequence: 1,
            stateGeneration: 1,
            workspaces: [firstWorkspace, secondWorkspace],
            activeWorkspaceID: firstWorkspace.id,
            selectionRevisions: [:],
            dirtyGenerations: [firstWorkspace.id: 0, secondWorkspace.id: 0],
            savedGenerations: [firstWorkspace.id: 0, secondWorkspace.id: 0],
            switchState: .idle,
            readiness: WorkspaceSessionReadiness(generation: 1, isReady: true),
            availability: .active
        )
        let client = WorkspaceSessionCommandClient(
            sessionID: sessionID,
            ingress: AuthorityCutoverUnusedIngress()
        )
        let fileManager = WorkspaceFilesViewModel()
        let keyManager = KeyManager(
            secureService: SecureKeysService(secureStorage: TestSecureStorageBackend())
        )
        let prompt = PromptViewModel(
            fileManager: fileManager,
            apiSettingsViewModel: APISettingsViewModel(
                aiQueriesService: AIQueriesService(keyManager: keyManager),
                keyManager: keyManager,
                loadStoredDataOnInit: false
            ),
            windowID: -1,
            settingsManager: WindowSettingsManager(windowID: -1)
        )
        let manager = WorkspaceManagerViewModel(
            fileManager: fileManager,
            promptViewModel: prompt,
            performInitialWorkspaceActivation: false,
            workspaceSessionClient: client,
            initialAuthoritativeSnapshot: initialSnapshot
        )
        var observedWorkspaceID: UUID?
        var observedProjectionWorkspaceID: UUID?
        var observedSelectionRevision: UInt64?
        manager.addWorkspaceDidSwitchListener(label: "authority-cutover-test") { [weak manager] workspace in
            observedWorkspaceID = workspace?.id
            observedProjectionWorkspaceID = manager?.activeWorkspace?.id
            observedSelectionRevision = manager?.selectionRevisionForMCP(
                workspaceID: secondWorkspace.id,
                tabID: secondTab.id
            )
        }

        let selectionKey = WorkspaceTabSelectionKey(
            workspaceID: secondWorkspace.id,
            tabID: secondTab.id
        )
        manager.applyAuthoritativeSessionSnapshot(
            WorkspaceSessionSnapshot(
                sessionID: sessionID,
                snapshotSequence: 2,
                stateGeneration: 2,
                workspaces: [firstWorkspace, secondWorkspace],
                activeWorkspaceID: secondWorkspace.id,
                selectionRevisions: [selectionKey: 7],
                dirtyGenerations: [firstWorkspace.id: 0, secondWorkspace.id: 2],
                savedGenerations: [firstWorkspace.id: 0, secondWorkspace.id: 1],
                switchState: .idle,
                readiness: WorkspaceSessionReadiness(generation: 2, isReady: true),
                availability: .active
            )
        )

        XCTAssertEqual(observedWorkspaceID, secondWorkspace.id)
        XCTAssertEqual(observedProjectionWorkspaceID, secondWorkspace.id)
        XCTAssertEqual(observedSelectionRevision, 7)
    }

    private func isolatedDefaults() -> UserDefaults {
        let suite = "WorkspaceAuthorityCutoverTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}

private struct CommandParityFixture {
    let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
    let workspaceA: WorkspaceModel
    let workspaceB: WorkspaceModel
    let workspaceC: WorkspaceModel
    let workspaceD: WorkspaceModel
    let tab1: ComposeTabState
    let tab2: ComposeTabState
    let tab3: ComposeTabState
    let initialStashedID: UUID
    let stashedTab2ID = UUID()
    let agentSessionID = UUID()

    init() {
        let workspaceAID = UUID()
        let workspaceBID = UUID()
        let workspaceCID = UUID()
        let workspaceDID = UUID()
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        tab1 = ComposeTabState(id: UUID(), name: "T1", lastModified: timestamp)
        tab2 = ComposeTabState(id: UUID(), name: "T2", lastModified: timestamp)
        tab3 = ComposeTabState(id: UUID(), name: "T3", lastModified: timestamp)
        let stashedTab = ComposeTabState(id: UUID(), name: "Stashed", lastModified: timestamp)
        initialStashedID = UUID()
        workspaceA = WorkspaceModel(
            id: workspaceAID,
            dateModified: timestamp,
            name: "A",
            repoPaths: [],
            lastUsed: timestamp,
            composeTabs: [tab1, tab2],
            activeComposeTabID: tab1.id,
            stashedTabs: [StashedTab(id: initialStashedID, tab: stashedTab, stashedAt: timestamp)]
        )
        let tabB = ComposeTabState(id: UUID(), name: "B1", lastModified: timestamp)
        workspaceB = WorkspaceModel(
            id: workspaceBID,
            dateModified: timestamp,
            name: "B",
            repoPaths: [],
            lastUsed: timestamp,
            composeTabs: [tabB],
            activeComposeTabID: tabB.id
        )
        workspaceC = WorkspaceModel(
            id: workspaceCID,
            dateModified: timestamp,
            name: "C",
            repoPaths: [],
            lastUsed: timestamp,
            composeTabs: [ComposeTabState(id: UUID(), lastModified: timestamp)]
        )
        workspaceD = WorkspaceModel(
            id: workspaceDID,
            dateModified: timestamp,
            name: "D",
            repoPaths: [],
            lastUsed: timestamp,
            composeTabs: [ComposeTabState(id: UUID(), lastModified: timestamp)]
        )
    }
}

@MainActor
private final class CommandParityRunner {
    private let core: any WorkspaceSessionCommandIngress
    private let legacy: any WorkspaceSessionCommandIngress

    init(
        core: any WorkspaceSessionCommandIngress,
        legacy: any WorkspaceSessionCommandIngress,
        testCase _: XCTestCase
    ) {
        self.core = core
        self.legacy = legacy
    }

    func run(
        _ command: WorkspaceSessionCommand,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let coreBeforeValue = await awaitSnapshot(core)
        let legacyBeforeValue = await awaitSnapshot(legacy)
        let coreBefore = try XCTUnwrap(coreBeforeValue, file: file, line: line)
        let legacyBefore = try XCTUnwrap(legacyBeforeValue, file: file, line: line)
        assertEquivalent(coreBefore, legacyBefore, file: file, line: line)
        guard case let .admitted(coreToken) = await core.admit(),
              case let .admitted(legacyToken) = await legacy.admit()
        else {
            XCTFail("both backends must admit the matrix command", file: file, line: line)
            return
        }
        let commandID = UUID()
        let source = WorkspaceSessionCommandSource(kind: "parity")
        let coreResult = await core.execute(WorkspaceSessionCommandEnvelope(
            commandID: commandID,
            admissionToken: coreToken,
            expectedGeneration: coreBefore.stateGeneration,
            command: command,
            source: source
        ))
        let legacyResult = await legacy.execute(WorkspaceSessionCommandEnvelope(
            commandID: commandID,
            admissionToken: legacyToken,
            expectedGeneration: legacyBefore.stateGeneration,
            command: command,
            source: source
        ))
        assertEquivalent(
            coreResult,
            legacyResult,
            coreToken: coreToken,
            legacyToken: legacyToken,
            file: file,
            line: line
        )
        let coreAfterValue = await awaitSnapshot(core)
        let legacyAfterValue = await awaitSnapshot(legacy)
        let coreAfter = try XCTUnwrap(coreAfterValue, file: file, line: line)
        let legacyAfter = try XCTUnwrap(legacyAfterValue, file: file, line: line)
        assertEquivalent(coreAfter, legacyAfter, file: file, line: line)
    }

    private func awaitSnapshot(
        _ ingress: any WorkspaceSessionCommandIngress
    ) async -> WorkspaceSessionSnapshot? {
        await ingress.currentSnapshot()
    }

    private func assertEquivalent(
        _ core: WorkspaceSessionCommandResult,
        _ legacy: WorkspaceSessionCommandResult,
        coreToken: WorkspaceSessionAdmissionToken,
        legacyToken: WorkspaceSessionAdmissionToken,
        file: StaticString,
        line: UInt
    ) {
        switch (core, legacy) {
        case let (.committed(coreReceipt), .committed(legacyReceipt)),
             let (.unchanged(coreReceipt), .unchanged(legacyReceipt)):
            XCTAssertEqual(coreReceipt.commandID, legacyReceipt.commandID, file: file, line: line)
            XCTAssertEqual(coreReceipt.sessionID, coreToken.sessionID, file: file, line: line)
            XCTAssertEqual(legacyReceipt.sessionID, legacyToken.sessionID, file: file, line: line)
            XCTAssertEqual(coreReceipt.activationID, coreToken.activationID, file: file, line: line)
            XCTAssertEqual(legacyReceipt.activationID, legacyToken.activationID, file: file, line: line)
            XCTAssertEqual(coreReceipt.resultingGeneration, legacyReceipt.resultingGeneration, file: file, line: line)
            XCTAssertEqual(coreReceipt.selectionRevision, legacyReceipt.selectionRevision, file: file, line: line)
            XCTAssertEqual(coreReceipt.dirtyGeneration, legacyReceipt.dirtyGeneration, file: file, line: line)
            XCTAssertEqual(coreReceipt.persistenceDisposition, legacyReceipt.persistenceDisposition, file: file, line: line)
            XCTAssertEqual(coreReceipt.snapshotSequence, legacyReceipt.snapshotSequence, file: file, line: line)
        case let (.rejected(coreRejection), .rejected(legacyRejection)):
            XCTAssertEqual(coreRejection, legacyRejection, file: file, line: line)
        case let (.notReady(coreAvailability), .notReady(legacyAvailability)):
            XCTAssertEqual(coreAvailability, legacyAvailability, file: file, line: line)
        case let (.failed(coreFailure), .failed(legacyFailure)):
            XCTAssertEqual(coreFailure, legacyFailure, file: file, line: line)
        case let (.stale(coreSnapshot, coreConflict), .stale(legacySnapshot, legacyConflict)):
            XCTAssertEqual(coreConflict, legacyConflict, file: file, line: line)
            assertEquivalent(coreSnapshot, legacySnapshot, file: file, line: line)
        default:
            XCTFail("result parity mismatch: core=\(core), legacy=\(legacy)", file: file, line: line)
        }
    }

    private func assertEquivalent(
        _ core: WorkspaceSessionSnapshot,
        _ legacy: WorkspaceSessionSnapshot,
        file: StaticString,
        line: UInt
    ) {
        XCTAssertEqual(core.sessionID, legacy.sessionID, file: file, line: line)
        XCTAssertEqual(core.snapshotSequence, legacy.snapshotSequence, file: file, line: line)
        XCTAssertEqual(core.stateGeneration, legacy.stateGeneration, file: file, line: line)
        XCTAssertEqual(core.activeWorkspaceID, legacy.activeWorkspaceID, file: file, line: line)
        XCTAssertEqual(core.selectionRevisions, legacy.selectionRevisions, file: file, line: line)
        XCTAssertEqual(core.dirtyGenerations, legacy.dirtyGenerations, file: file, line: line)
        XCTAssertEqual(core.savedGenerations, legacy.savedGenerations, file: file, line: line)
        XCTAssertEqual(core.readiness, legacy.readiness, file: file, line: line)
        XCTAssertEqual(core.availability, legacy.availability, file: file, line: line)
        XCTAssertEqual(core.switchState.phase, legacy.switchState.phase, file: file, line: line)
        XCTAssertEqual(core.switchState.sourceWorkspaceID, legacy.switchState.sourceWorkspaceID, file: file, line: line)
        XCTAssertEqual(core.switchState.targetWorkspaceID, legacy.switchState.targetWorkspaceID, file: file, line: line)
        XCTAssertEqual(core.switchState.reason, legacy.switchState.reason, file: file, line: line)
        XCTAssertEqual(
            core.switchState.destructiveBoundaryCrossed,
            legacy.switchState.destructiveBoundaryCrossed,
            file: file,
            line: line
        )
        XCTAssertEqual(core.switchState.commitBoundaryCrossed, legacy.switchState.commitBoundaryCrossed, file: file, line: line)
        XCTAssertEqual(core.switchState.message, legacy.switchState.message, file: file, line: line)
        XCTAssertEqual(core.workspaces.map(normalized), legacy.workspaces.map(normalized), file: file, line: line)
    }

    private func normalized(_ workspace: WorkspaceModel) -> WorkspaceModel {
        var normalized = workspace
        normalized.dateModified = .distantPast
        for index in normalized.composeTabs.indices {
            normalized.composeTabs[index].lastModified = .distantPast
        }
        for index in normalized.stashedTabs.indices {
            normalized.stashedTabs[index].tab.lastModified = .distantPast
        }
        return normalized
    }
}

private actor ConstructionCounter {
    private var count = 0
    func increment() {
        count += 1
    }

    func value() -> Int {
        count
    }
}

private actor AuthorityCutoverUnusedIngress: WorkspaceSessionCommandIngress {
    func currentSnapshot() async -> WorkspaceSessionSnapshot? {
        nil
    }

    func observations(after _: UInt64?) async -> AsyncStream<WorkspaceSessionSnapshot> {
        AsyncStream { $0.finish() }
    }

    func admit() async -> WorkspaceSessionAdmissionResult {
        .notReady(.created)
    }

    func execute(_: WorkspaceSessionCommandEnvelope) async -> WorkspaceSessionCommandResult {
        .notReady(.created)
    }

    func shutdown() async {}
}

private enum TestFailure: Error {
    case unexpectedLegacyConstruction
    case unexpectedCoreConstruction
}
