import Foundation

protocol CodexManagedAuthRPCClient: Sendable {
    func startIfNeeded() async throws
    func stop() async
    func request(
        method: String,
        params: [String: Any]?,
        timeout: TimeInterval?
    ) async throws -> [String: Any]
    func subscribeNotifications() async -> AsyncStream<CodexAppServerClient.Notification>
}

protocol CodexManagedAuthRecovering: Sendable {
    func refreshManagedAccount() async -> CodexManagedAuthRefreshResult
    func startManagedChatgptLogin(
        openURL: @MainActor @escaping @Sendable (URL) -> Void
    ) async -> CodexManagedChatgptLoginResult
}

enum CodexManagedAuthRefreshResult: Equatable {
    case recovered
    case requiresUserLogin(message: String)
    case executableUnavailable(message: String)
}

enum CodexManagedChatgptLoginResult: Equatable {
    case authenticated
    case failed(message: String)
    case executableUnavailable(message: String)
}

enum CodexManagedAuthRecoveryClassifier {
    static let loginActionTitle = "Login with ChatGPT"
    static let manualLoginGuidanceMessage = "Codex authentication could not be refreshed automatically. Use 'Login with ChatGPT', then retry."

    static func isRecoverable(issue: CodexNativeSessionController.ServerRequestIssue) -> Bool {
        guard issue.method == "account/chatgptAuthTokens/refresh" else { return false }
        switch issue.kind {
        case .authTokensRefreshInvalidParams, .authTokensRefreshUnavailable, .authTokensRefreshFailed:
            return true
        case .requestUserInputInvalidParams,
             .mcpElicitationInvalidParams,
             .mcpElicitationUnsupported,
             .permissionsRequestUnsupported,
             .dynamicToolCallUnsupported,
             .unsupportedMethod:
            return false
        }
    }

    static func isRecoverable(error: Error) -> Bool {
        isRecoverable(message: error.localizedDescription)
    }

    static func isRecoverable(message: String) -> Bool {
        let lowered = message.lowercased()
        let isRawUnauthorizedResponsesError =
            (lowered.contains("unexpected status 401") || lowered.contains("401 unauthorized"))
                && (
                    lowered.contains("missing bearer or basic authentication in header")
                        || lowered.contains("api.openai.com/v1/responses")
                )
        return lowered.contains("account/chatgptauthtokens/refresh")
            || lowered.contains("external auth is active")
            || isRawUnauthorizedResponsesError
    }

    static func preservesAsUserFacingGuidance(_ message: String) -> Bool {
        message == manualLoginGuidanceMessage
            || message.localizedCaseInsensitiveContains("Login with ChatGPT")
    }
}

actor CodexManagedAuthRecoveryService: CodexManagedAuthRecovering {
    static let shared = CodexManagedAuthRecoveryService {
        CodexProviderHelpers.makeOwnedNonAgentAppServerClient()
    }

    private let clientFactory: @Sendable () -> any CodexManagedAuthRPCClient
    private var inFlightRefreshTask: Task<CodexManagedAuthRefreshResult, Never>?
    private var inFlightCheckTask: Task<CodexManagedAuthRefreshResult, Never>?
    private var inFlightLoginTask: Task<CodexManagedChatgptLoginResult, Never>?
    private let refreshRequestTimeout: TimeInterval
    private let loginValidationTimeout: TimeInterval
    private let loginPollInterval: TimeInterval

    init(
        refreshRequestTimeout: TimeInterval = 30,
        loginValidationTimeout: TimeInterval = 300,
        loginPollInterval: TimeInterval = 0.5,
        clientFactory: @escaping @Sendable () -> any CodexManagedAuthRPCClient
    ) {
        self.refreshRequestTimeout = refreshRequestTimeout
        self.loginValidationTimeout = loginValidationTimeout
        self.loginPollInterval = loginPollInterval
        self.clientFactory = clientFactory
    }

    func refreshManagedAccount() async -> CodexManagedAuthRefreshResult {
        if let inFlightRefreshTask {
            return await inFlightRefreshTask.value
        }
        let task = accountReadTask(forceRefresh: true)
        inFlightRefreshTask = task
        let result = await task.value
        inFlightRefreshTask = nil
        return result
    }

    func checkManagedAccount() async -> CodexManagedAuthRefreshResult {
        if let inFlightCheckTask {
            return await inFlightCheckTask.value
        }
        let task = accountReadTask(forceRefresh: false)
        inFlightCheckTask = task
        let result = await task.value
        inFlightCheckTask = nil
        return result
    }

    private func accountReadTask(forceRefresh: Bool) -> Task<CodexManagedAuthRefreshResult, Never> {
        if let inFlightLoginTask {
            return Task {
                switch await inFlightLoginTask.value {
                case .authenticated:
                    .recovered
                case let .executableUnavailable(message):
                    .executableUnavailable(message: message)
                case .failed:
                    .requiresUserLogin(message: CodexManagedAuthRecoveryClassifier.manualLoginGuidanceMessage)
                }
            }
        }

        return Task<CodexManagedAuthRefreshResult, Never> { [clientFactory, refreshRequestTimeout] in
            let client = clientFactory()
            defer {
                Task { await client.stop() }
            }
            do {
                try await client.startIfNeeded()
                let result = try await client.request(
                    method: "account/read",
                    params: ["refreshToken": forceRefresh],
                    timeout: refreshRequestTimeout
                )
                if Self.isValidAccountReadResult(result) {
                    return .recovered
                }
            } catch {
                if let message = Self.executableUnavailableMessage(from: error) {
                    return .executableUnavailable(message: message)
                }
                return .requiresUserLogin(message: CodexManagedAuthRecoveryClassifier.manualLoginGuidanceMessage)
            }
            return .requiresUserLogin(message: CodexManagedAuthRecoveryClassifier.manualLoginGuidanceMessage)
        }
    }

    func startManagedChatgptLogin(
        openURL: @MainActor @escaping @Sendable (URL) -> Void
    ) async -> CodexManagedChatgptLoginResult {
        if let inFlightLoginTask {
            return await inFlightLoginTask.value
        }
        let pendingAccountReadTasks = [inFlightRefreshTask, inFlightCheckTask].compactMap(\.self)
        let task = Task<CodexManagedChatgptLoginResult, Never> { [clientFactory, refreshRequestTimeout, loginValidationTimeout, loginPollInterval] in
            for accountReadTask in pendingAccountReadTasks {
                if case let .executableUnavailable(message) = await accountReadTask.value {
                    return .executableUnavailable(message: message)
                }
            }

            let client = clientFactory()
            defer {
                Task { await client.stop() }
            }
            do {
                try await client.startIfNeeded()
                let notifications = await client.subscribeNotifications()
                let state = LoginNotificationState()

                let startResponse = try await Self.startChatgptLogin(client: client, timeout: refreshRequestTimeout)
                await openURL(startResponse.authURL)

                let notificationTask = Task {
                    var iterator = notifications.makeAsyncIterator()
                    while !Task.isCancelled, let notification = await iterator.next() {
                        await state.consume(notification: notification, expectedLoginID: startResponse.loginID)
                    }
                }
                defer { notificationTask.cancel() }

                let deadline = Date().addingTimeInterval(loginValidationTimeout)
                while Date() < deadline {
                    if let failure = await state.failureMessage {
                        return .failed(message: failure)
                    }
                    if await state.successSeen {
                        let readResult = try await client.request(
                            method: "account/read",
                            params: ["refreshToken": false],
                            timeout: refreshRequestTimeout
                        )
                        if Self.isValidAccountReadResult(readResult) {
                            return .authenticated
                        }
                        return .failed(message: "Codex reported that ChatGPT login completed, but no authenticated account was available.")
                    }
                    try? await Task.sleep(nanoseconds: UInt64(loginPollInterval * 1_000_000_000))
                }
                return .failed(message: "Codex ChatGPT login did not complete in time. After finishing login in the browser, retry or use 'Login with ChatGPT' again.")
            } catch {
                if let message = Self.executableUnavailableMessage(from: error) {
                    return .executableUnavailable(message: message)
                }
                return .failed(message: error.localizedDescription)
            }
        }
        inFlightLoginTask = task
        let result = await task.value
        inFlightLoginTask = nil
        return result
    }

    private static func executableUnavailableMessage(from error: Error) -> String? {
        if let clientError = error as? CodexAppServerClient.ClientError,
           case let .executableUnavailable(message) = clientError
        {
            return message
        }
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard CodexProviderHelpers.isCodexExecutableUnavailableMessage(message) else {
            return nil
        }
        return message
    }

    private static func startChatgptLogin(
        client: any CodexManagedAuthRPCClient,
        timeout: TimeInterval
    ) async throws -> ManagedChatgptLoginStartResponse {
        let response = try await client.request(
            method: "account/login/start",
            params: ["type": "chatgpt"],
            timeout: timeout
        )
        if let parsed = parseManagedChatgptLoginStartResponse(response) {
            return parsed
        }
        throw AIProviderError.invalidResponse(detail: "Codex returned an invalid ChatGPT login response.")
    }

    private static func parseManagedChatgptLoginStartResponse(_ response: [String: Any]) -> ManagedChatgptLoginStartResponse? {
        guard let authURLString = stringValue(in: response, keys: ["authUrl", "auth_url"]),
              let authURL = URL(string: authURLString),
              let loginID = stringValue(in: response, keys: ["loginId", "login_id"]),
              stringValue(in: response, keys: ["type"])?.lowercased() == "chatgpt"
        else {
            return nil
        }
        return ManagedChatgptLoginStartResponse(
            loginID: loginID,
            authURL: authURL
        )
    }

    private static func isValidAccountReadResult(_ result: [String: Any]) -> Bool {
        let requiresOpenAIAuth = boolValue(in: result, keys: ["requiresOpenaiAuth", "requires_openai_auth"]) ?? true
        if requiresOpenAIAuth == false {
            return true
        }
        guard let account = result["account"], !(account is NSNull) else {
            return false
        }
        return true
    }

    private static func stringValue(in payload: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = payload[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func boolValue(in payload: [String: Any], keys: [String]) -> Bool? {
        for key in keys {
            if let value = payload[key] as? Bool {
                return value
            }
        }
        return nil
    }

    private struct ManagedChatgptLoginStartResponse {
        let loginID: String
        let authURL: URL
    }

    private actor LoginNotificationState {
        private(set) var successSeen = false
        private(set) var failureMessage: String?

        func consume(notification: CodexAppServerClient.Notification, expectedLoginID: String) {
            let params = Self.decodeParams(notification.params)
            switch notification.method {
            case "account/login/completed":
                guard Self.stringValue(in: params, keys: ["loginId", "login_id"]) == expectedLoginID else {
                    return
                }
                if let success = Self.boolValue(in: params, keys: ["success"]), success {
                    successSeen = true
                } else {
                    failureMessage = Self.stringValue(in: params, keys: ["error"]) ?? "Codex ChatGPT login failed."
                }
            default:
                break
            }
        }

        private static func stringValue(in payload: [String: Any], keys: [String]) -> String? {
            for key in keys {
                if let value = payload[key] as? String, !value.isEmpty {
                    return value
                }
            }
            return nil
        }

        private static func boolValue(in payload: [String: Any], keys: [String]) -> Bool? {
            for key in keys {
                if let value = payload[key] as? Bool {
                    return value
                }
            }
            return nil
        }

        private static func decodeParams(_ params: [String: CodexJSONValue]) -> [String: Any] {
            var output: [String: Any] = [:]
            for (key, value) in params {
                output[key] = value.toAny()
            }
            return output
        }
    }
}

extension CodexAppServerClient: CodexManagedAuthRPCClient {}
