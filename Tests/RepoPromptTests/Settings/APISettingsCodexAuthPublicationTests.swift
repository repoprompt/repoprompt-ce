import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class APISettingsCodexAuthPublicationTests: XCTestCase {
    func testSnapshotPublicationIsDiscardedWhenCrossWindowLogoutInvalidatesEpoch() async throws {
        let snapshotGate = CodexAuthPublicationGate()
        let auth = ControlledCodexAuthRecovery(snapshotGate: snapshotGate)
        let fence = CodexManagedSessionFence()
        let viewModel = makeViewModel(auth: auth, fence: fence)
        viewModel.isCodexConnected = true

        let refresh = Task { @MainActor in
            await viewModel.test_refreshManagedCodexAccountSnapshotIfConnected()
        }
        try await waitUntil { await auth.snapshotCallCount == 1 }
        let logoutToken = fence.beginLogout()
        await snapshotGate.open()
        await refresh.value

        XCTAssertNil(viewModel.managedCodexAccount)
        fence.finishLogout(token: logoutToken, succeeded: false)
        viewModel.prepareForWindowClose()
    }

    func testBrowserLoginPublicationIsDiscardedWhenCrossWindowLogoutInvalidatesEpoch() async throws {
        let loginGate = CodexAuthPublicationGate()
        let auth = ControlledCodexAuthRecovery(loginGate: loginGate)
        let fence = CodexManagedSessionFence()
        let viewModel = makeViewModel(auth: auth, fence: fence)
        viewModel.isCodexConnected = false

        let login = Task { @MainActor in
            try await viewModel.startCodexManagedChatgptLogin { _ in }
        }
        try await waitUntil { await auth.browserLoginCallCount == 1 }
        let logoutToken = fence.beginLogout()
        await loginGate.open()
        let published = try await login.value

        XCTAssertFalse(published)
        XCTAssertFalse(viewModel.isCodexConnected)
        XCTAssertNil(viewModel.managedCodexAccount)
        fence.finishLogout(token: logoutToken, succeeded: true)
        viewModel.test_applyAuthoritativeCodexDisconnectedState()
        XCTAssertEqual(viewModel.codexConnectionPhase, .idle)
        XCTAssertTrue(viewModel.canAttemptCodexManagedLogin)
        viewModel.prepareForWindowClose()
    }

    func testDeviceCodeLoginPublicationIsDiscardedWhenCrossWindowLogoutInvalidatesEpoch() async throws {
        let loginGate = CodexAuthPublicationGate()
        let auth = ControlledCodexAuthRecovery(loginGate: loginGate)
        let fence = CodexManagedSessionFence()
        let viewModel = makeViewModel(auth: auth, fence: fence)
        viewModel.isCodexConnected = false

        let login = Task { @MainActor in
            try await viewModel.startCodexManagedChatgptDeviceCodeLogin { _, _ in }
        }
        try await waitUntil { await auth.deviceLoginCallCount == 1 }
        let logoutToken = fence.beginLogout()
        await loginGate.open()
        let published = try await login.value

        XCTAssertFalse(published)
        XCTAssertFalse(viewModel.isCodexConnected)
        XCTAssertNil(viewModel.managedCodexAccount)
        fence.finishLogout(token: logoutToken, succeeded: true)
        viewModel.test_applyAuthoritativeCodexDisconnectedState()
        XCTAssertEqual(viewModel.codexConnectionPhase, .idle)
        XCTAssertTrue(viewModel.canAttemptCodexManagedLogin)
        viewModel.prepareForWindowClose()
    }

    func testConnectionRefreshPublicationIsDiscardedWhenCrossWindowLogoutInvalidatesEpoch() async throws {
        let refreshGate = CodexAuthPublicationGate()
        let auth = ControlledCodexAuthRecovery(refreshGate: refreshGate)
        let fence = CodexManagedSessionFence()
        let viewModel = makeViewModel(auth: auth, fence: fence)
        viewModel.isCodexConnected = false

        let test = Task { @MainActor in
            try await viewModel.testCodexConnection()
        }
        try await waitUntil { await auth.refreshCallCount == 1 }
        let logoutToken = fence.beginLogout()
        await refreshGate.open()
        let published = try await test.value

        XCTAssertFalse(published)
        XCTAssertFalse(viewModel.isCodexConnected)
        XCTAssertNil(viewModel.managedCodexAccount)
        fence.finishLogout(token: logoutToken, succeeded: true)
        viewModel.test_applyAuthoritativeCodexDisconnectedState()
        XCTAssertEqual(viewModel.codexConnectionPhase, .idle)
        XCTAssertTrue(viewModel.canAttemptCodexManagedLogin)
        viewModel.prepareForWindowClose()
    }

    private func makeViewModel(
        auth: ControlledCodexAuthRecovery,
        fence: CodexManagedSessionFence
    ) -> APISettingsViewModel {
        let keyManager = KeyManager(
            secureService: SecureKeysService(secureStorage: TestSecureStorageBackend())
        )
        let pollingService = CodexModelPollingService(client: CodexAuthPublicationModelClient())
        return APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keyManager),
            keyManager: keyManager,
            loadStoredDataOnInit: false,
            codexModelPollingService: pollingService,
            codexManagedAuthRecovery: auth,
            codexSessionFence: fence,
            codexExecutablePreflight: { _ in
                CodexProviderHelpers.CodexExecutableResolution(
                    commandName: "codex",
                    resolvedCommand: "/test/codex",
                    status: .available,
                    runtime: nil,
                    userMessage: "",
                    debugMessage: "test runtime"
                )
            }
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while await !condition() {
            guard clock.now < deadline else {
                XCTFail("Timed out waiting for controlled auth call")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private actor CodexAuthPublicationGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}

private actor ControlledCodexAuthRecovery: CodexManagedAuthRecovering {
    private let account = CodexManagedAccount(
        email: "controlled@example.com",
        planType: "plus",
        accountType: "chatgpt",
        authenticationMode: "managed_chatgpt"
    )
    private let snapshotGate: CodexAuthPublicationGate?
    private let loginGate: CodexAuthPublicationGate?
    private let refreshGate: CodexAuthPublicationGate?
    private(set) var snapshotCallCount = 0
    private(set) var browserLoginCallCount = 0
    private(set) var deviceLoginCallCount = 0
    private(set) var refreshCallCount = 0

    init(
        snapshotGate: CodexAuthPublicationGate? = nil,
        loginGate: CodexAuthPublicationGate? = nil,
        refreshGate: CodexAuthPublicationGate? = nil
    ) {
        self.snapshotGate = snapshotGate
        self.loginGate = loginGate
        self.refreshGate = refreshGate
    }

    func refreshManagedAccount() async -> CodexManagedAuthRefreshResult {
        refreshCallCount += 1
        await refreshGate?.wait()
        return .recovered(account: account)
    }

    func managedAccountSnapshot() async -> CodexManagedAccount? {
        snapshotCallCount += 1
        await snapshotGate?.wait()
        return account
    }

    func startManagedChatgptLogin(
        openURL _: @MainActor @escaping @Sendable (URL) -> Void
    ) async -> CodexManagedChatgptLoginResult {
        browserLoginCallCount += 1
        await loginGate?.wait()
        return .authenticated(account: account)
    }

    func startManagedChatgptDeviceCodeLogin(
        presentDeviceCode _: @MainActor @escaping @Sendable (CodexManagedChatgptDeviceCode, Bool) -> Void
    ) async -> CodexManagedChatgptLoginResult {
        deviceLoginCallCount += 1
        await loginGate?.wait()
        return .authenticated(account: account)
    }

    func logoutManagedAccount() async -> CodexManagedAuthLogoutResult {
        .signedOut
    }
}

private actor CodexAuthPublicationModelClient: CodexModelListingClient {
    func listModels(limit _: Int) async throws -> [CodexAppServerClient.RemoteModel] {
        []
    }

    func stop() async {}
}
