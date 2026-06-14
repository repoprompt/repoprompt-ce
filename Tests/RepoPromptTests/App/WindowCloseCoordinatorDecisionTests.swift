@testable import RepoPrompt
import XCTest

@MainActor
final class WindowCloseCoordinatorDecisionTests: XCTestCase {
    private var trackedWindows: [WindowState] = []
    private var explicitlyUnregisteredWindowIDs: Set<ObjectIdentifier> = []

    override func tearDown() async throws {
        for window in trackedWindows.reversed() {
            if !explicitlyUnregisteredWindowIDs.contains(ObjectIdentifier(window)) {
                WindowStatesManager.shared.unregisterWindowState(window)
            }
            await window.tearDown()
        }
        trackedWindows.removeAll()
        explicitlyUnregisteredWindowIDs.removeAll()
        try await super.tearDown()
    }

    func testUnregisterStopsPeriodicWindowBackgroundWork() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WindowCloseCoordinatorDecisionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let window = trackWindow(WindowState())
        let manager = WindowStatesManager.shared
        manager.registerWindowState(window)
        let root = FolderViewModel(
            folder: Folder(name: rootURL.lastPathComponent, path: rootURL.path, modificationDate: Date()),
            rootPath: rootURL.path
        )
        window.promptManager.gitViewModel.updateRootFolders([root])

        XCTAssertTrue(window.workspaceManager.test_isPollTimerActive)
        XCTAssertTrue(window.promptManager.gitViewModel.test_hasGitContextRefreshTask)

        unregisterTrackedWindow(window)

        XCTAssertFalse(window.workspaceManager.test_isPollTimerActive)
        XCTAssertFalse(window.promptManager.gitViewModel.test_hasGitContextRefreshTask)
    }

    func testSuspendedGitContextRefreshDoesNotRetainViewModel() async throws {
        let refreshGate = GitContextRefreshGate()
        var viewModel: GitViewModel? = GitViewModel(
            gitContextRefreshIntervalNanoseconds: 0,
            refreshGitContexts: { rootPaths in
                await refreshGate.refresh(rootPaths: rootPaths)
            }
        )
        let weakViewModel = WeakLifecycleReference(viewModel)
        let root = FolderViewModel(
            folder: Folder(name: "root", path: "/tmp/git-refresh-lifecycle", modificationDate: Date()),
            rootPath: "/tmp/git-refresh-lifecycle"
        )
        viewModel?.updateRootFolders([root])
        let refreshTask = try XCTUnwrap(viewModel?.test_gitContextRefreshTask)

        await refreshGate.waitUntilEntered()
        viewModel = nil
        let deallocatedWithoutExplicitClose = weakViewModel.value == nil
        weakViewModel.value?.prepareForWindowClose()
        await refreshGate.release()
        await refreshTask.value

        let observedCancellation = await refreshGate.observedCancellation
        XCTAssertTrue(deallocatedWithoutExplicitClose)
        XCTAssertTrue(observedCancellation)
    }

    func testWorkspacePollTimerDoesNotRetainManager() {
        let fileManager = WorkspaceFilesViewModel()
        let keyManager = KeyManager(
            secureService: SecureKeysService(secureStorage: TestSecureStorageBackend())
        )
        let apiSettings = APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keyManager),
            keyManager: keyManager,
            loadStoredDataOnInit: false
        )
        let prompt = PromptViewModel(
            fileManager: fileManager,
            apiSettingsViewModel: apiSettings,
            windowID: -1,
            settingsManager: WindowSettingsManager(windowID: -1)
        )
        var manager: WorkspaceManagerViewModel? = WorkspaceManagerViewModel(
            fileManager: fileManager,
            promptViewModel: prompt,
            performInitialWorkspaceActivation: false
        )
        let weakManager = WeakLifecycleReference(manager)

        XCTAssertTrue(manager?.test_isPollTimerActive == true)
        manager = nil

        XCTAssertNil(weakManager.value)
    }

    func testUnregisterDisposesPerWindowCodexModelSubscribersAndStopsOwnedClient() async throws {
        let client = WindowClosePollingClientSpy()
        let pollingService = CodexModelPollingService(
            client: client,
            intervalNanos: 60_000_000_000,
            stopClientWhenIdle: true
        )
        let window = trackWindow(WindowState(
            codexModelPollingService: pollingService,
            loadStoredAPISettingsDataOnInit: false
        ))
        let manager = WindowStatesManager.shared
        manager.registerWindowState(window)

        try await waitUntil("initial API settings load to settle", timeout: .seconds(15)) {
            window.apiSettingsViewModel.test_hasFinishedInitialStoredDataLoad
        }
        window.apiSettingsViewModel.test_stopCodexModelsSubscription()
        window.contextBuilderAgentViewModel.test_stopCodexModelsSubscription()
        try await waitUntil("startup model subscribers to detach") {
            await pollingService.test_subscriberCount() == 0
        }

        window.apiSettingsViewModel.isCodexConnected = true
        window.apiSettingsViewModel.test_completeContextBuilderProviderValidation(
            verifiedProviders: [.codexExec]
        )
        XCTAssertFalse(window.isClosing)
        XCTAssertFalse(window.apiSettingsViewModel.test_hasPreparedForWindowClose)
        window.apiSettingsViewModel.test_startCodexModelsSubscriptionIfNeeded()
        window.contextBuilderAgentViewModel.test_startCodexModelsSubscriptionIfNeeded()
        try await waitUntil("two per-window subscribers to attach") {
            await pollingService.test_subscriberCount() == 2
        }
        let attachedSubscriberCount = await pollingService.test_subscriberCount()
        XCTAssertEqual(
            attachedSubscriberCount,
            2,
            "apiTask=\(window.apiSettingsViewModel.test_hasCodexModelsSubscriptionTask) contextBuilderTask=\(window.contextBuilderAgentViewModel.test_hasCodexModelsSubscriptionTask)"
        )
        let stopCallCountBeforeClose = client.stopCallCount

        unregisterTrackedWindow(window)

        try await waitUntil("window-close subscriber disposal and client stop") {
            await pollingService.test_subscriberCount() == 0
                && client.stopCallCount > stopCallCountBeforeClose
        }
        let subscriberCount = await pollingService.test_subscriberCount()
        XCTAssertTrue(window.isClosing)
        XCTAssertEqual(subscriberCount, 0)
        XCTAssertGreaterThan(client.stopCallCount, stopCallCountBeforeClose)
    }

    func testAPISettingsCloseDuringInitialLoadDoesNotStartProviderValidation() async throws {
        let loadGate = APISettingsInitialLoadGate()
        let validationProbe = APISettingsProviderValidationProbe()
        let keyManager = KeyManager(
            secureService: SecureKeysService(secureStorage: TestSecureStorageBackend())
        )
        let viewModel = APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keyManager),
            keyManager: keyManager,
            storedDataLoadBoundary: {
                await loadGate.arriveAndWait()
            },
            contextBuilderProviderValidationWillBegin: {
                await validationProbe.recordStart()
            }
        )
        let initialLoadTask = try XCTUnwrap(viewModel.test_initialLoadTask)

        await loadGate.waitUntilEntered()
        viewModel.prepareForWindowClose()
        await loadGate.release()
        await initialLoadTask.value

        let validationStartCount = await validationProbe.startCount
        XCTAssertTrue(viewModel.test_hasPreparedForWindowClose)
        XCTAssertFalse(viewModel.test_hasFinishedInitialStoredDataLoad)
        XCTAssertFalse(viewModel.test_hasContextBuilderProviderValidationTask)
        XCTAssertEqual(validationStartCount, 0)
    }

    private func trackWindow(_ makeWindow: @autoclosure () -> WindowState) -> WindowState {
        let previousMCPAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        defer {
            GlobalSettingsStore.shared.setMCPAutoStart(previousMCPAutoStart, commit: false)
        }

        let window = makeWindow()
        trackedWindows.append(window)
        return window
    }

    private func unregisterTrackedWindow(_ window: WindowState) {
        WindowStatesManager.shared.unregisterWindowState(window)
        explicitlyUnregisteredWindowIDs.insert(ObjectIdentifier(window))
    }

    func testTerminationAndAuthorizationAllowDespiteOtherwiseBlockingImpact() {
        let otherwiseBlockingSnapshot = makeSnapshot(
            isLastAppWindow: true,
            isLastMCPEnabledWindow: true,
            activeItems: [activity(id: "workspace-session", count: 1, singular: "active workspace session", plural: "active workspace sessions")],
            mcp: mcp(toolsEnabled: true, liveConnectionCount: 2, activeExecutionCount: 1, hasIdleLiveConnections: true)
        )
        let cases: [(name: String, snapshot: WindowCloseImpactSnapshot, authorization: WindowCloseAuthorization?)] = [
            (
                "termination",
                makeSnapshot(
                    isTerminating: true,
                    isLastAppWindow: true,
                    isLastMCPEnabledWindow: true,
                    activeItems: otherwiseBlockingSnapshot.activeItems,
                    mcp: otherwiseBlockingSnapshot.mcp
                ),
                nil
            ),
            ("user confirmation", otherwiseBlockingSnapshot, authorization(source: .userConfirmed)),
            ("workspace deletion", otherwiseBlockingSnapshot, authorization(source: .workspaceDelete)),
            ("system", otherwiseBlockingSnapshot, authorization(source: .system))
        ]

        for testCase in cases {
            XCTAssertEqual(
                WindowCloseCoordinator.decide(snapshot: testCase.snapshot, authorization: testCase.authorization),
                .allow,
                testCase.name
            )
        }
    }

    func testActiveWorkConfirmationPrecedesMCPContinuityAndFormatsDeterministically() {
        let cases: [(name: String, snapshot: WindowCloseImpactSnapshot, expected: WindowCloseDecision)] = [
            (
                "workspace activity",
                makeSnapshot(activeItems: [activity(id: "workspace-session", count: 1, singular: "active workspace session", plural: "active workspace sessions")]),
                .confirm(activeWorkConfirmation("1 active workspace session"))
            ),
            (
                "zero count is ignored",
                makeSnapshot(activeItems: [activity(id: "workspace-session", count: 0, singular: "active workspace session", plural: "active workspace sessions")]),
                .allow
            ),
            (
                "MCP execution precedes MCP continuity",
                makeSnapshot(
                    isLastAppWindow: true,
                    isLastMCPEnabledWindow: true,
                    mcp: mcp(toolsEnabled: true, liveConnectionCount: 2, activeExecutionCount: 1, hasIdleLiveConnections: true)
                ),
                .confirm(activeWorkConfirmation("1 active MCP tool execution"))
            ),
            (
                "mixed activity is sorted and pluralized",
                makeSnapshot(
                    activeItems: [
                        activity(id: "z-search", count: 2, singular: "active search", plural: "active searches"),
                        activity(id: "a-session", count: 1, singular: "active agent session", plural: "active agent sessions")
                    ],
                    mcp: mcp(activeExecutionCount: 3)
                ),
                .confirm(activeWorkConfirmation("1 active agent session and 3 active MCP tool executions and 2 active searches"))
            )
        ]

        for testCase in cases {
            XCTAssertEqual(
                WindowCloseCoordinator.decide(snapshot: testCase.snapshot, authorization: nil),
                testCase.expected,
                testCase.name
            )
        }
    }

    func testMCPContinuityConfirmationAndOrdinaryAllowCases() {
        let cases: [(name: String, snapshot: WindowCloseImpactSnapshot, expected: WindowCloseDecision)] = [
            (
                "last tools-enabled window without connections",
                makeSnapshot(
                    isLastAppWindow: true,
                    isLastMCPEnabledWindow: true,
                    mcp: mcp(toolsEnabled: true)
                ),
                .confirm(lastWindowMCPConfirmation(connectionCount: 0))
            ),
            (
                "last tools-enabled window with connections",
                makeSnapshot(
                    isLastAppWindow: true,
                    isLastMCPEnabledWindow: true,
                    mcp: mcp(toolsEnabled: true, liveConnectionCount: 2, hasIdleLiveConnections: true)
                ),
                .confirm(lastWindowMCPConfirmation(connectionCount: 2))
            ),
            (
                "last MCP-enabled window with idle connection",
                makeSnapshot(
                    isLastMCPEnabledWindow: true,
                    mcp: mcp(liveConnectionCount: 1, hasIdleLiveConnections: true)
                ),
                .confirm(disconnectMCPConfirmation(connectionCount: 1))
            ),
            (
                "non-last MCP-enabled window with idle connection",
                makeSnapshot(mcp: mcp(liveConnectionCount: 1, hasIdleLiveConnections: true)),
                .allow
            ),
            ("ordinary close", makeSnapshot(), .allow)
        ]

        for testCase in cases {
            XCTAssertEqual(
                WindowCloseCoordinator.decide(snapshot: testCase.snapshot, authorization: nil),
                testCase.expected,
                testCase.name
            )
        }
    }

    private func waitUntil(
        _ description: String,
        timeout: Duration = .seconds(5),
        condition: @escaping @MainActor () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while await !condition() {
            guard clock.now < deadline else {
                XCTFail("Timed out waiting for \(description)")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func authorization(source: WindowCloseAuthorization.Source) -> WindowCloseAuthorization {
        WindowCloseAuthorization(
            source: source,
            bypassConfirmation: true,
            bypassBackgroundPreservation: true
        )
    }

    private func activity(id: String, count: Int, singular: String, plural: String) -> WindowCloseActivityItem {
        WindowCloseActivityItem(
            id: id,
            count: count,
            singularLabel: singular,
            pluralLabel: plural
        )
    }

    private func makeSnapshot(
        isTerminating: Bool = false,
        isLastAppWindow: Bool = false,
        isLastMCPEnabledWindow: Bool = false,
        activeItems: [WindowCloseActivityItem] = [],
        mcp: WindowMCPCloseSafetyState = .inactive
    ) -> WindowCloseImpactSnapshot {
        WindowCloseImpactSnapshot(
            isTerminating: isTerminating,
            isLastAppWindow: isLastAppWindow,
            isLastMCPEnabledWindow: isLastMCPEnabledWindow,
            activeItems: activeItems,
            mcp: mcp
        )
    }

    private func mcp(
        toolsEnabled: Bool = false,
        liveConnectionCount: Int = 0,
        activeExecutionCount: Int = 0,
        hasIdleLiveConnections: Bool = false
    ) -> WindowMCPCloseSafetyState {
        WindowMCPCloseSafetyState(
            toolsEnabled: toolsEnabled,
            liveConnectionCount: liveConnectionCount,
            activeExecutionCount: activeExecutionCount,
            hasIdleLiveConnections: hasIdleLiveConnections,
            activeToolName: nil
        )
    }

    private func activeWorkConfirmation(_ summary: String) -> WindowCloseConfirmation {
        WindowCloseConfirmation(
            title: "Close Window?",
            message: "Closing this window will terminate \(summary). Do you want to continue?",
            confirmButtonTitle: "Close and End Sessions",
            secondaryButtonTitle: nil,
            secondaryAction: nil
        )
    }

    private func disconnectMCPConfirmation(connectionCount: Int) -> WindowCloseConfirmation {
        let label = connectionCount == 1 ? "client" : "clients"
        return WindowCloseConfirmation(
            title: "Disconnect MCP?",
            message: "Closing this window will disconnect \(connectionCount) MCP \(label).",
            confirmButtonTitle: "Close and Disconnect",
            secondaryButtonTitle: nil,
            secondaryAction: nil
        )
    }

    private func lastWindowMCPConfirmation(connectionCount: Int) -> WindowCloseConfirmation {
        let message: String
        if connectionCount > 0 {
            let label = connectionCount == 1 ? "client" : "clients"
            message = "This is the last MCP-enabled window. Close to disconnect \(connectionCount) \(label) and stop MCP, or hide it to keep MCP running from the menu bar."
        } else {
            message = "This is the last MCP-enabled window. Close to stop MCP, or hide it to keep MCP running from the menu bar."
        }
        return WindowCloseConfirmation(
            title: "Keep MCP running?",
            message: message,
            confirmButtonTitle: "Close and Stop MCP",
            secondaryButtonTitle: "Hide and Keep Running",
            secondaryAction: .backgroundWindow
        )
    }
}

private actor APISettingsInitialLoadGate {
    private var hasEntered = false
    private var hasReleased = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func arriveAndWait() async {
        hasEntered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        waiters.forEach { $0.resume() }

        guard !hasReleased else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilEntered() async {
        guard !hasEntered else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func release() {
        hasReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor APISettingsProviderValidationProbe {
    private(set) var startCount = 0

    func recordStart() {
        startCount += 1
    }
}

private actor GitContextRefreshGate {
    private var hasEntered = false
    private var hasReleased = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var observedCancellation = false

    func refresh(rootPaths _: [String]) async -> [GitStatusActor.RepoDetection] {
        hasEntered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        waiters.forEach { $0.resume() }

        if !hasReleased {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }
        observedCancellation = Task.isCancelled
        return []
    }

    func waitUntilEntered() async {
        guard !hasEntered else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func release() {
        hasReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private final class WeakLifecycleReference<Value: AnyObject> {
    weak var value: Value?

    init(_ value: Value?) {
        self.value = value
    }
}

private final class WindowClosePollingClientSpy: CodexModelListingClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _stopCallCount = 0

    var stopCallCount: Int {
        lock.withLock { _stopCallCount }
    }

    func listModels(limit _: Int) async throws -> [CodexAppServerClient.RemoteModel] {
        try await Task.sleep(for: .seconds(60))
        return []
    }

    func stop() async {
        lock.withLock {
            _stopCallCount += 1
        }
    }
}
