import Foundation
@testable import RepoPromptApp
import XCTest

final class CodexManagedAuthRecoveryServiceTests: XCTestCase {
    func testCheckManagedAccountUsesPassiveAccountRead() async {
        let client = ManagedAuthRPCClientFake(
            accountResult: Self.authenticatedAccount,
            loginStartResult: Self.loginStart
        )
        let service = makeService(client: client)

        let result = await service.checkManagedAccount()

        XCTAssertEqual(result, .recovered)
        let requests = await client.recordedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.method, "account/read")
        XCTAssertEqual(requests.first?.refreshToken, false)
    }

    func testRefreshManagedAccountForcesAccountRead() async {
        let client = ManagedAuthRPCClientFake(
            accountResult: Self.authenticatedAccount,
            loginStartResult: Self.loginStart
        )
        let service = makeService(client: client)

        let result = await service.refreshManagedAccount()

        XCTAssertEqual(result, .recovered)
        let requests = await client.recordedRequests()
        XCTAssertEqual(requests.first?.refreshToken, true)
    }

    func testLoginDoesNotAcceptPreExistingAccountBeforeCompletionNotification() async {
        let client = ManagedAuthRPCClientFake(
            accountResult: Self.authenticatedAccount,
            loginStartResult: Self.loginStart
        )
        let service = makeService(client: client, loginValidationTimeout: 0.03)

        let result = await service.startManagedChatgptLogin { _ in }

        guard case let .failed(message) = result else {
            return XCTFail("Expected pending browser login to time out, got \(result)")
        }
        XCTAssertTrue(message.contains("did not complete in time"))
        let requests = await client.recordedRequests()
        XCTAssertFalse(requests.contains { $0.method == "account/read" })
    }

    func testLoginAcceptsMatchingSuccessfulCompletionThenVerifiesAccount() async {
        let client = ManagedAuthRPCClientFake(
            accountResult: Self.authenticatedAccount,
            loginStartResult: Self.loginStart,
            notificationAfterLoginStart: Self.loginCompleted(loginID: "login-1", success: true)
        )
        let service = makeService(client: client)

        let result = await service.startManagedChatgptLogin { _ in }

        XCTAssertEqual(result, .authenticated)
        let requests = await client.recordedRequests()
        XCTAssertEqual(requests.map(\.method), ["account/login/start", "account/read"])
        XCTAssertEqual(requests.last?.refreshToken, false)
    }

    func testLoginRejectsMatchingCompletionWhenAccountVerificationFails() async {
        let client = ManagedAuthRPCClientFake(
            accountResult: ["requiresOpenaiAuth": true, "account": NSNull()],
            loginStartResult: Self.loginStart,
            notificationAfterLoginStart: Self.loginCompleted(loginID: "login-1", success: true)
        )
        let service = makeService(client: client)

        let result = await service.startManagedChatgptLogin { _ in }

        guard case let .failed(message) = result else {
            return XCTFail("Expected failed account verification, got \(result)")
        }
        XCTAssertTrue(message.contains("no authenticated account"))
    }

    func testLoginIgnoresCompletionForAnotherLoginID() async {
        let client = ManagedAuthRPCClientFake(
            accountResult: Self.authenticatedAccount,
            loginStartResult: Self.loginStart,
            notificationAfterLoginStart: Self.loginCompleted(loginID: "other-login", success: true)
        )
        let service = makeService(client: client, loginValidationTimeout: 0.03)

        let result = await service.startManagedChatgptLogin { _ in }

        guard case .failed = result else {
            return XCTFail("Expected mismatched completion to be ignored, got \(result)")
        }
        let requests = await client.recordedRequests()
        XCTAssertFalse(requests.contains { $0.method == "account/read" })
    }

    func testLoginRejectsMatchingFailedCompletion() async {
        let client = ManagedAuthRPCClientFake(
            accountResult: Self.authenticatedAccount,
            loginStartResult: Self.loginStart,
            notificationAfterLoginStart: Self.loginCompleted(
                loginID: "login-1",
                success: false,
                error: "Browser login was declined."
            )
        )
        let service = makeService(client: client)

        let result = await service.startManagedChatgptLogin { _ in }

        XCTAssertEqual(result, .failed(message: "Browser login was declined."))
        let requests = await client.recordedRequests()
        XCTAssertEqual(requests.map(\.method), ["account/login/start"])
    }

    func testLoginStartFailureDoesNotImplicitlyLogoutSharedCodexAccount() async {
        let client = ManagedAuthRPCClientFake(
            accountResult: Self.authenticatedAccount,
            loginStartResult: Self.loginStart,
            loginStartError: TestError(message: "external auth is active")
        )
        let service = makeService(client: client)

        let result = await service.startManagedChatgptLogin { _ in }

        guard case let .failed(message) = result else {
            return XCTFail("Expected login start failure, got \(result)")
        }
        XCTAssertEqual(message, "external auth is active")
        let requests = await client.recordedRequests()
        XCTAssertEqual(requests.map(\.method), ["account/login/start"])
    }

    private func makeService(
        client: ManagedAuthRPCClientFake,
        loginValidationTimeout: TimeInterval = 1
    ) -> CodexManagedAuthRecoveryService {
        CodexManagedAuthRecoveryService(
            refreshRequestTimeout: 1,
            loginValidationTimeout: loginValidationTimeout,
            loginPollInterval: 0.001
        ) {
            client
        }
    }

    private static let authenticatedAccount: [String: Any] = [
        "requiresOpenaiAuth": true,
        "account": ["type": "chatgpt"]
    ]

    private static let loginStart: [String: Any] = [
        "type": "chatgpt",
        "loginId": "login-1",
        "authUrl": "https://example.com/login"
    ]

    private static func loginCompleted(
        loginID: String,
        success: Bool,
        error: String? = nil
    ) -> CodexAppServerClient.Notification {
        var params: [String: CodexJSONValue] = [
            "loginId": .string(loginID),
            "success": .bool(success)
        ]
        if let error {
            params["error"] = .string(error)
        }
        return CodexAppServerClient.Notification(
            method: "account/login/completed",
            params: params
        )
    }
}

private actor ManagedAuthRPCClientFake: CodexManagedAuthRPCClient {
    struct Request {
        let method: String
        let refreshToken: Bool?
    }

    private let accountResult: [String: Any]
    private let loginStartResult: [String: Any]
    private let loginStartError: Error?
    private let notificationAfterLoginStart: CodexAppServerClient.Notification?
    private var requests: [Request] = []
    private let notificationStream: AsyncStream<CodexAppServerClient.Notification>
    private let notificationContinuation: AsyncStream<CodexAppServerClient.Notification>.Continuation

    init(
        accountResult: [String: Any],
        loginStartResult: [String: Any],
        loginStartError: Error? = nil,
        notificationAfterLoginStart: CodexAppServerClient.Notification? = nil
    ) {
        self.accountResult = accountResult
        self.loginStartResult = loginStartResult
        self.loginStartError = loginStartError
        self.notificationAfterLoginStart = notificationAfterLoginStart
        (notificationStream, notificationContinuation) = AsyncStream.makeStream()
    }

    func startIfNeeded() async throws {}

    func stop() async {
        notificationContinuation.finish()
    }

    func request(
        method: String,
        params: [String: Any]?,
        timeout _: TimeInterval?
    ) async throws -> [String: Any] {
        requests.append(Request(method: method, refreshToken: params?["refreshToken"] as? Bool))
        switch method {
        case "account/read":
            return accountResult
        case "account/login/start":
            if let loginStartError {
                throw loginStartError
            }
            if let notificationAfterLoginStart {
                notificationContinuation.yield(notificationAfterLoginStart)
            }
            return loginStartResult
        default:
            return [:]
        }
    }

    func subscribeNotifications() async -> AsyncStream<CodexAppServerClient.Notification> {
        notificationStream
    }

    func recordedRequests() -> [Request] {
        requests
    }
}

private struct TestError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}
