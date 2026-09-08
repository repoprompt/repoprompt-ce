import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

#if DEBUG
    /// Real lifecycle/authority fixture. Requires the checked-in CI runner sandbox contract.
    /// `withFixture` owns setup-failure cleanup as well as normal and throwing test exits.
    @MainActor
    final class WorkspaceAuthorityRootTestFixture {
        struct Capture {
            let model: WorkspaceModel
            let canonical: DomainWorkspaceSnapshot
            let savedState: DomainWorkspaceSavedStateForTesting
            /// These bytes are claimed as the saved document only after digest verification.
            let disk: WorkspaceModel
            let diskBytes: Data
            let publicationSequence: UInt64
            let primaryRoots: [WorkspaceRootRecord]
            let readinessObservation: WorkspacePrimaryRootReadinessObservation
            let reconciliationTicket: WorkspaceRootReconciliationTicket?
            let shellPaths: [String]
            let shellIDs: [UUID]
            let stateVersion: Int
            let selection: StoredSelection
            let rootNotificationCount: Int
        }

        /// Gates are registered before use; shutdown always opens them before joining owned work.
        @MainActor
        final class Gate {
            private var opened = false
            private var waiters: [CheckedContinuation<Void, Never>] = []

            func wait() async {
                guard !opened else { return }
                await withCheckedContinuation { waiters.append($0) }
            }

            func release() {
                opened = true
                let pending = waiters
                waiters.removeAll()
                pending.forEach { $0.resume() }
            }
        }

        /// Observes the existing selection dirty callback without replacing its behavior.
        @MainActor
        final class RecordingManager: WorkspaceManagerViewModel {
            var dirtyMarkDidFinish: (() -> Void)?
            /// Negative control only: omit production request triggers after real setup.
            var omitRootReconciliationRequests = false

            override func requestRootReconciliation(workspaceID: UUID, allowsRefresh: Bool = false) -> WorkspaceRootReconciliationTicket? {
                guard !omitRootReconciliationRequests else { return nil }
                return super.requestRootReconciliation(workspaceID: workspaceID, allowsRefresh: allowsRefresh)
            }

            override func markWorkspaceDirty() {
                super.markWorkspaceDirty()
                dirtyMarkDidFinish?()
            }
        }

        let base: URL
        let storage: URL
        let rootPaths: [String]
        private(set) var workspace: WorkspaceModel!
        private(set) var runtime: MCPDomainRuntime!
        private(set) var manager: RecordingManager!
        private(set) var files: WorkspaceFilesViewModel!
        private(set) var bridge: DomainWorkspacePresentationBridge!
        private var previousStoragePreference: Any?
        private var changedStoragePreference = false
        private var notificationObserver: NSObjectProtocol?
        private var rootNotificationCount = 0
        private var gates: [Gate] = []
        private var ownedTasks: [Task<Void, Never>] = []
        private var didShutdown = false
        private(set) var initialRootAttemptStarts = 0
        var commandWillExecute: (@MainActor (DomainWorkspaceCommandEnvelope) async -> Void)?

        private func gateDomainCommand(_ envelope: DomainWorkspaceCommandEnvelope) async {
            await commandWillExecute?(envelope)
        }

        private init(sandbox: URL, rootNames: [String]) {
            let base = sandbox.appendingPathComponent("root-fixture-\(UUID().uuidString)", isDirectory: true)
            self.base = base
            storage = base.appendingPathComponent("Workspaces", isDirectory: true)
            rootPaths = rootNames.map { base.appendingPathComponent($0).path }
        }

        static func withFixture(
            paddedConfiguration: Bool = false,
            rootNames: [String] = ["A", "B"],
            configuration: (([String]) -> [String])? = nil,
            _ body: (WorkspaceAuthorityRootTestFixture) async throws -> Void
        ) async throws {
            // Must precede every shared settings, sidecar, key, and store access.
            let sandbox = try validatedSandbox()
            let fixture = WorkspaceAuthorityRootTestFixture(sandbox: sandbox, rootNames: rootNames)
            do {
                try await fixture.perform("real-authority fixture setup") {
                    try await fixture.setUp(paddedConfiguration: paddedConfiguration, configuration: configuration, sandbox: sandbox)
                }
                try await body(fixture)
                await fixture.shutdown()
            } catch {
                await fixture.shutdown()
                throw error
            }
        }

        private static func validatedSandbox() throws -> URL {
            let env = ProcessInfo.processInfo.environment
            let raw = try XCTUnwrap(
                env["REPOPROMPT_TEST_SANDBOX_ROOT"],
                "Run this suite with Scripts/ci_app_test_runner.py"
            )
            let sandbox = normalizedDirectoryURL(raw)
            guard (raw as NSString).isAbsolutePath, sandbox.path != "/" else {
                throw IsolationFailure.invalidEnvironment
            }

            let expectedHome = normalizedDirectoryURL(sandbox.appendingPathComponent("home", isDirectory: true).path)
            guard expectedHome.deletingLastPathComponent().path == sandbox.path,
                  try normalizedEnvironmentDirectory("HOME", in: env) == expectedHome,
                  try normalizedEnvironmentDirectory("CFFIXED_USER_HOME", in: env) == expectedHome
            else { throw IsolationFailure.invalidEnvironment }

            let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath()
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
            ).resolvingSymlinksInPath()
            guard home == expectedHome,
                  support.path.hasPrefix(home.path + "/"),
                  FileManager.default.fileExists(atPath: sandbox.appendingPathComponent(".issue944-test-sandbox").path)
            else { throw IsolationFailure.foundationOutsideSandbox }

            for (key, suffix) in [
                ("TMPDIR", "tmp"), ("TMP", "tmp"), ("TEMP", "tmp"),
                ("XDG_CONFIG_HOME", "config"), ("XDG_CACHE_HOME", "cache"), ("XDG_DATA_HOME", "data")
            ] {
                let expected = normalizedDirectoryURL(sandbox.appendingPathComponent(suffix, isDirectory: true).path)
                guard expected.deletingLastPathComponent().path == sandbox.path,
                      try normalizedEnvironmentDirectory(key, in: env) == expected
                else {
                    throw IsolationFailure.invalidEnvironment
                }
            }
            print("ISSUE944 isolation=verified foundationHome=true applicationSupport=true")
            return sandbox
        }

        private static func normalizedEnvironmentDirectory(
            _ key: String,
            in environment: [String: String]
        ) throws -> URL {
            let path = try XCTUnwrap(environment[key], "Missing \(key) in CI test sandbox")
            guard (path as NSString).isAbsolutePath else { throw IsolationFailure.invalidEnvironment }
            return normalizedDirectoryURL(path)
        }

        private static func normalizedDirectoryURL(_ path: String) -> URL {
            URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        }

        private func setUp(paddedConfiguration: Bool, configuration: (([String]) -> [String])?, sandbox: URL) async throws {
            try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
            previousStoragePreference = UserDefaults.standard.object(forKey: "GlobalCustomStorageURL")
            changedStoragePreference = true
            UserDefaults.standard.set(storage.path, forKey: "GlobalCustomStorageURL")
            // Isolation supplies defaults; leave optional sidecar overrides and MCP preference untouched.
            guard !GlobalSettingsStore.shared.mcpAutoStart() else { throw IsolationFailure.mcpAutoStartEnabled }
            let agentStorage = await AgentSessionDataService.shared.test_workspaceRootURL().resolvingSymlinksInPath()
            let chatStorage = ChatDataService.test_workspaceRootURL().resolvingSymlinksInPath()
            guard agentStorage.path.hasPrefix(sandbox.path + "/"), chatStorage.path.hasPrefix(sandbox.path + "/") else {
                throw IsolationFailure.sidecarOutsideSandbox
            }
            for path in rootPaths {
                let root = URL(fileURLWithPath: path, isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try "fixture".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
            }
            let tabID = UUID()
            let configured = configuration?(rootPaths) ?? rootPaths.enumerated().map { index, path in
                paddedConfiguration && index == 1 ? " " + path + "\n" : path
            }
            workspace = WorkspaceModel(
                name: "RootRemovalFixture", repoPaths: configured,
                composeTabs: [ComposeTabState(id: tabID, name: "Fixture")], activeComposeTabID: tabID
            )
            try FileManager.default.createDirectory(at: workspaceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(workspace!).write(to: workspaceURL, options: .atomic)
            try JSONEncoder().encode([WorkspaceIndexEntry(
                id: workspace.id, name: workspace.name, customStoragePath: nil,
                isSystemWorkspace: false, isHiddenInMenus: false
            )]).write(to: indexURL, options: .atomic)
            runtime = MCPDomainRuntime(configuration: .init(
                mode: .app, profileIdentifier: "issue944-\(UUID().uuidString)",
                storageDirectory: base.appendingPathComponent("runtime"), workspaceStorageDirectory: storage,
                eventDirectory: base.appendingPathComponent("events"), temporaryDirectory: base.appendingPathComponent("tmp"),
                externalReloadInterval: nil
            ))
            try await runtime.start()
            var client = DomainWorkspaceAuthorityClient(store: runtime.workspaceStore, windowID: -944)
            client.commandWillExecuteForTesting = { [weak self] envelope in await self?.gateDomainCommand(envelope) }
            let keys = KeyManager(secureService: SecureKeysService(secureStorage: TestSecureStorageBackend()))
            let queries = AIQueriesService(keyManager: keys)
            files = WorkspaceFilesViewModel()
            let api = APISettingsViewModel(aiQueriesService: queries, keyManager: keys, loadStoredDataOnInit: false)
            let prompt = PromptViewModel(
                fileManager: files, apiSettingsViewModel: api, windowID: -944,
                settingsManager: WindowSettingsManager(windowID: -944)
            )
            manager = RecordingManager(
                fileManager: files, promptViewModel: prompt, domainWorkspaceAuthorityClient: client,
                workspaceActivityCoordinator: WorkspaceActivityCoordinator(), performInitialWorkspaceActivation: false
            )
            await manager.awaitInitialized()
            bridge = DomainWorkspacePresentationBridge(workspaceManager: manager, client: client)
            bridge.start()
            try await settle()
            manager.activeWorkspace = try XCTUnwrap(manager.workspace(withID: workspace.id))
            let ticket = try XCTUnwrap(manager.requestRootReconciliation(workspaceID: workspace.id))
            _ = try await manager.awaitRootReconciliationCompletion(ticket: ticket)
            try await settle()
            initialRootAttemptStarts = manager.rootReconciliationStateForTesting.attemptStarts
            notificationObserver = NotificationCenter.default.addObserver(
                forName: .workspaceRepoPathsDidChange, object: nil, queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, notification.userInfo?["workspaceID"] as? UUID == self.workspace.id else { return }
                    self.rootNotificationCount += 1
                }
            }
        }

        var workspaceURL: URL {
            storage.appendingPathComponent(DomainWorkspaceStoragePath.directoryName(name: workspace.name, id: workspace.id))
                .appendingPathComponent("workspace.json")
        }

        private var indexURL: URL {
            storage.appendingPathComponent("workspacesIndex.json")
        }

        /// Seed an additional real canonical workspace without starting manager-owned create tasks.
        func createAdditionalWorkspace(name: String, repoPaths: [String]) async throws -> WorkspaceModel {
            let model = WorkspaceModel(name: name, repoPaths: repoPaths)
            let url = manager.workspaceFileURL(for: model)
            let client = DomainWorkspaceAuthorityClient(store: runtime.workspaceStore, windowID: -945)
            _ = try await client.create(model, fileURL: url, operationID: UUID())
            try await settle()
            return try XCTUnwrap(manager.workspace(withID: model.id))
        }

        /// Promotes two fixture directories to a real repository and linked worktree.
        /// Both remain under `base` and are removed after the root owners shut down.
        func makeWorktreeBinding(logicalRootIndex: Int, worktreeRootIndex: Int) throws -> AgentSessionWorktreeBinding {
            let logicalRoot = URL(fileURLWithPath: rootPaths[logicalRootIndex], isDirectory: true)
            let worktreeRoot = URL(fileURLWithPath: rootPaths[worktreeRootIndex], isDirectory: true)
            let git = try ReviewGitRepositoryFixture()
            try git.initializeRepository(at: logicalRoot)
            try git.stage("README.md", at: logicalRoot)
            try git.commit("Initial fixture commit", at: logicalRoot)
            // Git accepts an existing empty directory, but not the placeholder fixture file.
            try FileManager.default.removeItem(at: worktreeRoot.appendingPathComponent("README.md"))
            try git.runGit(["worktree", "add", "--detach", worktreeRoot.path, "HEAD"], at: logicalRoot)
            let identity = try XCTUnwrap(GitWorktreeIdentityResolver.resolve(atWorkTreeRoot: worktreeRoot))
            XCTAssertFalse(identity.isMain, "The bound fixture must exercise a linked worktree")
            return AgentSessionWorktreeBinding(
                id: "binding", repositoryID: identity.repository.repositoryID, repoKey: identity.repository.repoKey,
                logicalRootPath: logicalRoot.path, logicalRootName: "fixture",
                worktreeID: identity.worktreeID, worktreeRootPath: worktreeRoot.path,
                commonGitDir: identity.repository.commonGitDir, isMainWorktree: identity.isMain, source: "test"
            )
        }

        func makeGate() -> Gate {
            let gate = Gate()
            gates.append(gate)
            return gate
        }

        @discardableResult
        func startOwnedTask(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
            let task = Task { await operation() }
            ownedTasks.append(task)
            return task
        }

        /// Joins fixture-owned operations before an additional discovery window is disposed.
        func joinOwnedTasks() async {
            for task in ownedTasks {
                await task.value
            }
        }

        func releaseAllGates() {
            manager?.clearRootPreloadGateForTesting()
            gates.forEach { $0.release() }
        }

        /// A timeout fails admission to the assertion phase, releases gates, and leaves
        /// the task owned for cooperative joining in shutdown (cleanup has no hard deadline).
        func perform<Value>(
            _ description: String, timeout: TimeInterval = 10,
            _ operation: @escaping @MainActor () async throws -> Value
        ) async throws -> Value {
            let completed = XCTestExpectation(description: description)
            var result: Result<Value, Error>?
            let task = startOwnedTask {
                do { result = try await .success(operation()) }
                catch { result = .failure(error) }
                completed.fulfill()
            }
            let outcome = await XCTWaiter.fulfillment(of: [completed], timeout: timeout)
            guard outcome == .completed else {
                releaseAllGates()
                throw CheckpointFailure.operationTimedOut(description)
            }
            await task.value
            return try XCTUnwrap(result).get()
        }

        func awaitGateEvent(_ event: XCTestExpectation) async throws {
            guard await XCTWaiter.fulfillment(of: [event], timeout: 5) == .completed else {
                releaseAllGates()
                throw CheckpointFailure.operationTimedOut(event.expectationDescription)
            }
        }

        func selectFixtureFiles(_ paths: [String]) async throws {
            let dirty = XCTestExpectation(description: "selected files reached the real dirty observer")
            let expected = Set(paths)
            var fulfilled = false
            manager.dirtyMarkDidFinish = { [weak self] in
                guard let self, !fulfilled, Set(files.selectedFiles.map(\.fullPath)) == expected else { return }
                fulfilled = true
                dirty.fulfill()
            }
            defer { manager.dirtyMarkDidFinish = nil }
            try await perform("fixture selection applied") { await self.files.selectFiles(withPaths: paths) }
            try await awaitGateEvent(dirty)
            try await perform("selected fixture files saved") { await self.manager.pollAndSaveStateAsync() }
            try await settle()
        }

        /// Root-action return + save joins + bridge publication, not future W3 readiness.
        func settle() async throws {
            await manager.debugDrainScheduledSaves()
            await manager.debugAwaitWorkingDocumentCommitToDomainAuthority(workspaceID: workspace.id)
            let catalog = await runtime.workspaceStore.snapshot()
            let projected = await bridge.waitUntilProjected(through: catalog.publicationSequence)
            guard projected else { throw CheckpointFailure.projectionTimedOut }
            await WorkspaceManagerViewModel.WorkspaceDiskWriter.shared.flush(url: workspaceURL)
            await WorkspaceManagerViewModel.WorkspaceDiskWriter.shared.flush(url: indexURL)
        }

        /// Active admission is deliberately separate from the passive convergence checkpoint.
        func admit() async throws -> ContextBuilderWorkspaceContext {
            try await perform("separate real Context Builder admission") {
                let model = try XCTUnwrap(self.manager.workspace(withID: self.workspace.id))
                let invocation = try MCPServerViewModel.TabContextSnapshot(
                    tabID: XCTUnwrap(model.activeComposeTabID), windowID: -944, workspaceID: model.id,
                    promptText: "", selection: StoredSelection(), selectedMetaPromptIDs: [], tabName: "Fixture",
                    runID: UUID(), activeAgentSessionID: UUID(), worktreeBindingState: .hydrated([]), explicitlyBound: true
                )
                return try await ContextBuilderWorkspaceContext.resolve(
                    from: invocation, workspaceRepoPaths: model.repoPaths,
                    workspaceDirectoryPath: self.workspaceURL.deletingLastPathComponent().path,
                    workspaceManager: self.manager
                )
            }
        }

        /// Observation only: no save drain, bridge wait, reconciliation, admission or repair.
        /// Call immediately after the action-owned completion, before any active consumer.
        func capturePassive() async throws -> Capture {
            try await perform("passive bracketed authority/model/store/shell/disk checkpoint") {
                try await self.captureAtCheckpoint()
            }
        }

        private func captureAtCheckpoint() async throws -> Capture {
            let before = await runtime.workspaceStore.snapshot()
            let canonicalSnapshot = await runtime.workspaceStore.canonicalWorkspaceSnapshot(workspace.id)
            let canonical = try XCTUnwrap(canonicalSnapshot)
            let savedBefore = await runtime.workspaceStore.savedStateForTesting(workspace.id)
            let savedState = try XCTUnwrap(savedBefore)
            let model = try XCTUnwrap(manager.workspace(withID: workspace.id))
            let stateVersion = manager.debugStateVersionForWorkspace(workspace.id)
            let shells = files.visibleRootShellProjections
            let ticket = manager.currentRootReconciliationTicketForTesting
            let selection = files.snapshotSelection()
            let notifications = rootNotificationCount
            let diskBytes = try Data(contentsOf: workspaceURL)
            let roots = await files.workspaceFileContextStore.roots().filter { $0.kind == .primaryWorkspace }
            let manifest = WorkspacePrimaryRootManifest(normalizedPaths: model.repoPaths.map { files.workspaceRootIdentity(for: $0) })
            let readinessObservation = await files.workspaceFileContextStore.primaryRootReadinessObservation(orderedPaths: manifest.orderedPaths)
            let observationAfter = await files.workspaceFileContextStore.primaryRootReadinessObservation(orderedPaths: manifest.orderedPaths)
            let rootsAfter = await files.workspaceFileContextStore.roots().filter { $0.kind == .primaryWorkspace }
            let savedAfter = await runtime.workspaceStore.savedStateForTesting(workspace.id)
            let canonicalAfter = await runtime.workspaceStore.canonicalWorkspaceSnapshot(workspace.id)
            let after = await runtime.workspaceStore.snapshot()
            guard model == manager.workspace(withID: workspace.id),
                  stateVersion == manager.debugStateVersionForWorkspace(workspace.id),
                  shells == files.visibleRootShellProjections,
                  ticket == manager.currentRootReconciliationTicketForTesting,
                  selection == files.snapshotSelection(), notifications == rootNotificationCount,
                  roots == rootsAfter,
                  readinessObservation == observationAfter,
                  savedState == savedAfter,
                  before.publicationSequence == after.publicationSequence,
                  canonical == canonicalAfter, try diskBytes == Data(contentsOf: workspaceURL)
            else { throw CheckpointFailure.authorityChangedDuringCapture }
            guard savedState.revision == canonical.revisions.savedRevision,
                  DomainContentDigest.sha256(diskBytes) == savedState.digest else { throw CheckpointFailure.savedBytesUnverified }
            return try Capture(
                model: model, canonical: canonical, savedState: savedState,
                disk: JSONDecoder().decode(WorkspaceModel.self, from: diskBytes), diskBytes: diskBytes,
                publicationSequence: after.publicationSequence, primaryRoots: roots, readinessObservation: readinessObservation,
                reconciliationTicket: ticket,
                shellPaths: shells.map(\.fullPath), shellIDs: shells.map(\.id),
                stateVersion: stateVersion, selection: selection,
                rootNotificationCount: notifications
            )
        }

        func shutdown() async {
            guard !didShutdown else { return }
            didShutdown = true
            releaseAllGates()
            commandWillExecute = nil
            manager?.setWorkspaceSavePreparationDidFinishHandlerForTesting(nil)
            manager?.rootEditDidApplyHandlerForTesting = nil
            manager?.rootNotificationDidFinishForTesting = nil
            manager?.rootReconciliationGateForTesting = nil
            manager?.rootReconciliationWaiterCountDidChangeForTesting = nil
            manager?.rootProbeFailureForTesting = nil
            manager?.dirtyMarkDidFinish = nil
            manager?.omitRootReconciliationRequests = false
            // Detach admission/operation continuations before joining tasks blocked on them.
            // Full manager close still follows the existing save/writer drains below.
            manager?.beginRootReconciliationShutdown()
            if let files {
                await files.workspaceFileContextStore.setRootUnloadDidDetachHandler(nil)
                for root in await files.workspaceFileContextStore.roots() {
                    await files.workspaceFileContextStore.setPrimaryRootQueryabilityFailureForTesting(rootID: root.id, failure: nil)
                }
            }
            for task in ownedTasks {
                await task.value
            }
            ownedTasks.removeAll()
            await bridge?.stopAndJoinForTesting()
            if let manager {
                await manager.waitUntilPostSwitchGitDataLoadComplete()
                await manager.debugDrainScheduledSaves()
                for workspace in manager.workspaces {
                    await manager.debugAwaitWorkingDocumentCommitToDomainAuthority(workspaceID: workspace.id)
                }
                manager.prepareForWindowClose()
                await manager.awaitRootReconciliationShutdown()
            }
            if let notificationObserver { NotificationCenter.default.removeObserver(notificationObserver) }
            notificationObserver = nil
            if let files {
                for root in await files.workspaceFileContextStore.roots() {
                    await files.unloadRootFolderPath(root.standardizedFullPath)
                }
                let remaining = await files.workspaceFileContextStore.roots()
                XCTAssertTrue(remaining.isEmpty, "Fixture root lifecycle cleanup must complete")
            }
            if let runtime {
                let result = await runtime.shutdown()
                XCTAssertEqual(result.finalLifecycle, .stopped)
            }
            if workspace != nil {
                await WorkspaceManagerViewModel.WorkspaceDiskWriter.shared.flush(url: workspaceURL)
                await WorkspaceManagerViewModel.WorkspaceDiskWriter.shared.flush(url: indexURL)
            }
            bridge = nil
            manager = nil
            files = nil
            runtime = nil
            if changedStoragePreference {
                if let previousStoragePreference {
                    UserDefaults.standard.set(previousStoragePreference, forKey: "GlobalCustomStorageURL")
                } else {
                    UserDefaults.standard.removeObject(forKey: "GlobalCustomStorageURL")
                }
            }
            do {
                if FileManager.default.fileExists(atPath: base.path) {
                    try FileManager.default.removeItem(at: base)
                }
            } catch {
                XCTFail("Fixture directory cleanup failed: \(error)")
            }
            print("ISSUE944 cleanup=gatesReleased-ownedTasksJoined-bridgeJoined-savesDrained-rootsUnloaded-runtimeStopped-writersFlushed")
        }

        private enum IsolationFailure: Error {
            case invalidEnvironment, foundationOutsideSandbox, sidecarOutsideSandbox, mcpAutoStartEnabled
        }

        enum CheckpointFailure: Error, Equatable {
            case projectionTimedOut, authorityChangedDuringCapture, savedBytesUnverified
            case operationTimedOut(String)
        }
    }
#endif
