import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class APISettingsCodexAuthPublicationTests: XCTestCase {
    func testSnapshotPublicationIsDiscardedWhenCrossWindowLogoutInvalidatesEpoch() async {
        let snapshotBlocked = expectation(description: "managed account snapshot blocked")
        let snapshotGate = CodexAuthPublicationGate(
            onWait: AuthPublicationExpectationSignal(snapshotBlocked)
        )
        let auth = ControlledCodexAuthRecovery(snapshotGate: snapshotGate)
        let fence = CodexManagedSessionFence()
        let viewModel = makeViewModel(auth: auth, fence: fence)
        viewModel.isCodexConnected = true

        let refresh = Task { @MainActor in
            await viewModel.test_refreshManagedCodexAccountSnapshotIfConnected()
        }
        await fulfillment(of: [snapshotBlocked], timeout: 2)
        let logoutToken = fence.beginLogout()
        await snapshotGate.open()
        await refresh.value

        XCTAssertNil(viewModel.managedCodexAccount)
        fence.finishLogout(token: logoutToken, succeeded: false)
        viewModel.prepareForWindowClose()
    }

    func testBrowserLoginPublicationIsDiscardedWhenCrossWindowLogoutInvalidatesEpoch() async throws {
        let loginBlocked = expectation(description: "browser login blocked")
        let loginGate = CodexAuthPublicationGate(
            onWait: AuthPublicationExpectationSignal(loginBlocked)
        )
        let auth = ControlledCodexAuthRecovery(loginGate: loginGate)
        let fence = CodexManagedSessionFence()
        let viewModel = makeViewModel(auth: auth, fence: fence)
        viewModel.isCodexConnected = false

        let login = Task { @MainActor in
            try await viewModel.startCodexManagedChatgptLogin { _ in }
        }
        await fulfillment(of: [loginBlocked], timeout: 2)
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
        let loginBlocked = expectation(description: "device-code login blocked")
        let loginGate = CodexAuthPublicationGate(
            onWait: AuthPublicationExpectationSignal(loginBlocked)
        )
        let auth = ControlledCodexAuthRecovery(loginGate: loginGate)
        let fence = CodexManagedSessionFence()
        let viewModel = makeViewModel(auth: auth, fence: fence)
        viewModel.isCodexConnected = false

        let login = Task { @MainActor in
            try await viewModel.startCodexManagedChatgptDeviceCodeLogin { _, _ in }
        }
        await fulfillment(of: [loginBlocked], timeout: 2)
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
        let refreshBlocked = expectation(description: "connection refresh blocked")
        let refreshGate = CodexAuthPublicationGate(
            onWait: AuthPublicationExpectationSignal(refreshBlocked)
        )
        let auth = ControlledCodexAuthRecovery(refreshGate: refreshGate)
        let fence = CodexManagedSessionFence()
        let viewModel = makeViewModel(auth: auth, fence: fence)
        viewModel.isCodexConnected = false

        let test = Task { @MainActor in
            try await viewModel.testCodexConnection()
        }
        await fulfillment(of: [refreshBlocked], timeout: 2)
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
}

private final class AuthPublicationExpectationSignal: @unchecked Sendable {
    private let expectation: XCTestExpectation

    init(_ expectation: XCTestExpectation) {
        self.expectation = expectation
    }

    func fulfill() {
        expectation.fulfill()
    }
}

private actor CodexAuthPublicationGate {
    private let onWait: AuthPublicationExpectationSignal?
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(onWait: AuthPublicationExpectationSignal? = nil) {
        self.onWait = onWait
    }

    func wait() async {
        onWait?.fulfill()
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
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
        await refreshGate?.wait()
        return .recovered(account: account)
    }

    func managedAccountSnapshot() async -> CodexManagedAccount? {
        await snapshotGate?.wait()
        return account
    }

    func startManagedChatgptLogin(
        openURL _: @MainActor @escaping @Sendable (URL) -> Void
    ) async -> CodexManagedChatgptLoginResult {
        await loginGate?.wait()
        return .authenticated(account: account)
    }

    func startManagedChatgptDeviceCodeLogin(
        presentDeviceCode _: @MainActor @escaping @Sendable (CodexManagedChatgptDeviceCode, Bool) -> Void
    ) async -> CodexManagedChatgptLoginResult {
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
