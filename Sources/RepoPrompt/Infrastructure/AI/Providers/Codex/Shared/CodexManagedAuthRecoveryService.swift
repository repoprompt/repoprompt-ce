import Foundation

protocol CodexManagedAuthRPCClient: Sendable {
    func updateDefaultRequestTimeout(_ timeout: TimeInterval?) async
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
    func managedAccountSnapshot() async -> CodexManagedAccount?
    func startManagedChatgptLogin(
        openURL: @MainActor @escaping @Sendable (URL) -> Void
    ) async -> CodexManagedChatgptLoginResult
    func startManagedChatgptDeviceCodeLogin(
        presentDeviceCode: @MainActor @escaping @Sendable (CodexManagedChatgptDeviceCode, Bool) -> Void
    ) async -> CodexManagedChatgptLoginResult
    func logoutManagedAccount() async -> CodexManagedAuthLogoutResult
}

enum CodexManagedLoginFlow: Equatable {
    case browser
    case deviceCode
}

struct CodexManagedAccount: Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let email: String?
    let planType: String?
    let accountType: String?
    let accountID: String?
    let authenticationMode: String?
    let managedLoginValidated: Bool

    init(
        email: String? = nil,
        planType: String? = nil,
        accountType: String? = nil,
        accountID: String? = nil,
        authenticationMode: String? = nil,
        managedLoginValidated: Bool = false
    ) {
        self.email = email
        self.planType = planType
        self.accountType = accountType
        self.accountID = accountID
        self.authenticationMode = authenticationMode
        self.managedLoginValidated = managedLoginValidated
    }

    var description: String {
        "CodexManagedAccount(present)"
    }

    var debugDescription: String {
        description
    }

    var customMirror: Mirror {
        Mirror(
            self,
            children: [
                "hasEmail": email != nil,
                "hasPlanType": planType != nil,
                "hasAccountType": accountType != nil,
                "hasAccountID": accountID != nil,
                "hasAuthenticationMode": authenticationMode != nil,
                "managedLoginValidated": managedLoginValidated
            ],
            displayStyle: .struct
        )
    }

    var identityLabel: String {
        email ?? "Managed Codex account"
    }

    var planDisplayLabel: String {
        Self.normalizedLabel(planType) ?? "Plan not provided"
    }

    var authenticationModeDisplayLabel: String {
        Self.normalizedLabel(authenticationMode) ?? "Managed Codex sign-in"
    }

    var settingsProjection: CodexManagedAccountSettingsProjection {
        CodexManagedAccountSettingsProjection(
            account: identityLabel,
            plan: planDisplayLabel,
            authentication: authenticationModeDisplayLabel
        )
    }

    var isConfirmedManagedAuthentication: Bool {
        if let accountType,
           accountType.trimmingCharacters(in: .whitespacesAndNewlines)
           .caseInsensitiveCompare("chatgpt") == .orderedSame
        {
            return true
        }
        return managedLoginValidated
    }

    private static func normalizedLabel(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.caseInsensitiveCompare("chatgpt") == .orderedSame {
            return "ChatGPT"
        }
        return trimmed
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .map { word in
                let lowered = word.lowercased()
                switch lowered {
                case "api": return "API"
                case "chatgpt": return "ChatGPT"
                case "oauth": return "OAuth"
                case "sso": return "SSO"
                default: return lowered.prefix(1).uppercased() + lowered.dropFirst()
                }
            }
            .joined(separator: " ")
    }
}

struct CodexManagedAccountSettingsProjection: Equatable {
    let account: String
    let plan: String
    let authentication: String
}

enum CodexManagedAuthRefreshResult: Equatable {
    case recovered(account: CodexManagedAccount?)
    case requiresUserLogin(message: String)
    case executableUnavailable(message: String)
}

enum CodexManagedChatgptLoginResult: Equatable {
    case authenticated(account: CodexManagedAccount)
    case authenticatedWithoutManagedAccount
    case failed(message: String)
    case executableUnavailable(message: String)
}

enum CodexManagedAuthLogoutResult: Equatable {
    case signedOut
    case failed(message: String)
    case executableUnavailable(message: String)

    var failureMessage: String? {
        switch self {
        case .signedOut:
            nil
        case let .failed(message), let .executableUnavailable(message):
            message
        }
    }
}

struct CodexManagedChatgptDeviceCode: Equatable {
    let loginID: String
    let userCode: String
    let verificationURL: URL
}

enum CodexManagedAuthRecoveryClassifier {
    static let loginActionTitle = "Login with ChatGPT"
    static let deviceCodeActionTitle = "Use device code instead"
    static let separateSignInExplanation =
        "RepoPrompt CE uses a separate Codex sign-in from any ~/.codex CLI credentials; sign in once here."
    static let manualLoginGuidanceMessage =
        "Codex authentication could not be refreshed automatically. Use 'Login with ChatGPT' or 'Use device code instead', then retry. \(separateSignInExplanation)"

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
            || message.localizedCaseInsensitiveContains(loginActionTitle)
            || message.localizedCaseInsensitiveContains(deviceCodeActionTitle)
    }
}

actor CodexManagedAuthRecoveryService: CodexManagedAuthRecovering {
    static let shared = CodexManagedAuthRecoveryService {
        CodexProviderHelpers.makeOwnedNonAgentAppServerClient()
    }

    private struct InFlightRefresh {
        let id: UUID
        let task: Task<CodexManagedAuthRefreshResult, Never>
    }

    private struct InFlightLogin {
        let id: UUID
        let flow: CodexManagedLoginFlow
        let task: Task<CodexManagedChatgptLoginResult, Never>
    }

    private struct InFlightLogout {
        let id: UUID
        let task: Task<CodexManagedAuthLogoutResult, Never>
    }

    private let clientFactory: @Sendable () -> any CodexManagedAuthRPCClient
    private let refreshRequestTimeout: TimeInterval
    private let browserLoginValidationTimeout: TimeInterval
    private let deviceCodeLoginValidationTimeout: TimeInterval
    private let loginPollInterval: TimeInterval
    private let cancelledWorkRetirementTimeout: TimeInterval
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let retirementSleep: @Sendable (TimeInterval) async throws -> Void
    private var inFlightRefresh: InFlightRefresh?
    private var inFlightLogin: InFlightLogin?
    private var inFlightLogout: InFlightLogout?
    private var latestManagedAccount: CodexManagedAccount?
    private var authMutationGeneration: UInt64 = 0
    private var deviceCodePresenters: [UUID: @MainActor @Sendable (CodexManagedChatgptDeviceCode, Bool) -> Void] = [:]
    private var currentDeviceCode: CodexManagedChatgptDeviceCode?

    init(
        clientFactory: @escaping @Sendable () -> any CodexManagedAuthRPCClient,
        refreshRequestTimeout: TimeInterval = 30,
        browserLoginValidationTimeout: TimeInterval = 300,
        deviceCodeLoginValidationTimeout: TimeInterval = 15 * 60,
        loginPollInterval: TimeInterval = 0.5,
        cancelledWorkRetirementTimeout: TimeInterval = 5,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { interval in
            try await Task.sleep(nanoseconds: UInt64(max(0, interval) * 1_000_000_000))
        },
        retirementSleep: @escaping @Sendable (TimeInterval) async throws -> Void = { interval in
            try await Task.sleep(nanoseconds: UInt64(max(0, interval) * 1_000_000_000))
        }
    ) {
        self.clientFactory = clientFactory
        self.refreshRequestTimeout = refreshRequestTimeout
        self.browserLoginValidationTimeout = browserLoginValidationTimeout
        self.deviceCodeLoginValidationTimeout = deviceCodeLoginValidationTimeout
        self.loginPollInterval = loginPollInterval
        self.cancelledWorkRetirementTimeout = cancelledWorkRetirementTimeout
        self.now = now
        self.sleep = sleep
        self.retirementSleep = retirementSleep
    }

    func refreshManagedAccount() async -> CodexManagedAuthRefreshResult {
        if let inFlightLogout {
            switch await inFlightLogout.task.value {
            case .signedOut:
                latestManagedAccount = nil
                return .requiresUserLogin(message: CodexManagedAuthRecoveryClassifier.manualLoginGuidanceMessage)
            case .failed, .executableUnavailable:
                break
            }
        }
        let operationGeneration = authMutationGeneration
        if let inFlightLogin {
            let result = await inFlightLogin.task.value
            guard operationGeneration == authMutationGeneration else {
                return .requiresUserLogin(message: CodexManagedAuthRecoveryClassifier.manualLoginGuidanceMessage)
            }
            switch result {
            case let .authenticated(account):
                latestManagedAccount = account
                return .recovered(account: account)
            case .authenticatedWithoutManagedAccount:
                latestManagedAccount = nil
                return .recovered(account: nil)
            case let .executableUnavailable(message):
                latestManagedAccount = nil
                return .executableUnavailable(message: message)
            case .failed:
                return .requiresUserLogin(message: CodexManagedAuthRecoveryClassifier.manualLoginGuidanceMessage)
            }
        }
        if let inFlightRefresh {
            let result = await inFlightRefresh.task.value
            guard operationGeneration == authMutationGeneration else {
                return .requiresUserLogin(message: CodexManagedAuthRecoveryClassifier.manualLoginGuidanceMessage)
            }
            applyRefreshResult(result)
            return result
        }

        let task = Task<CodexManagedAuthRefreshResult, Never> { [clientFactory, refreshRequestTimeout] in
            let client = clientFactory()
            let result: CodexManagedAuthRefreshResult
            do {
                await client.updateDefaultRequestTimeout(refreshRequestTimeout)
                try await client.startIfNeeded()
                let response = try await client.request(
                    method: "account/read",
                    params: ["refreshToken": true],
                    timeout: refreshRequestTimeout
                )
                if Self.isValidAccountReadResult(response) {
                    result = .recovered(account: Self.parseManagedAccount(from: response))
                } else {
                    result = .requiresUserLogin(message: CodexManagedAuthRecoveryClassifier.manualLoginGuidanceMessage)
                }
            } catch {
                if let message = Self.executableUnavailableMessage(from: error) {
                    result = .executableUnavailable(message: message)
                } else {
                    result = .requiresUserLogin(message: CodexManagedAuthRecoveryClassifier.manualLoginGuidanceMessage)
                }
            }
            await client.stop()
            return result
        }
        let refreshID = UUID()
        inFlightRefresh = InFlightRefresh(id: refreshID, task: task)
        let result = await task.value
        if inFlightRefresh?.id == refreshID {
            inFlightRefresh = nil
        }
        guard operationGeneration == authMutationGeneration else {
            return .requiresUserLogin(message: CodexManagedAuthRecoveryClassifier.manualLoginGuidanceMessage)
        }
        applyRefreshResult(result)
        return result
    }

    func managedAccountSnapshot() -> CodexManagedAccount? {
        latestManagedAccount
    }

    private func applyRefreshResult(_ result: CodexManagedAuthRefreshResult) {
        switch result {
        case let .recovered(account):
            latestManagedAccount = account
        case .requiresUserLogin, .executableUnavailable:
            latestManagedAccount = nil
        }
    }

    func startManagedChatgptLogin(
        openURL: @MainActor @escaping @Sendable (URL) -> Void
    ) async -> CodexManagedChatgptLoginResult {
        await startManagedLogin(flow: .browser) { [
            clientFactory,
            refreshRequestTimeout,
            browserLoginValidationTimeout,
            loginPollInterval,
            now,
            sleep
        ] in
            let client = clientFactory()
            return await Self.runLogin(
                client: client,
                flow: .browser,
                requestTimeout: refreshRequestTimeout,
                validationTimeout: browserLoginValidationTimeout,
                pollInterval: loginPollInterval,
                now: now,
                sleep: sleep,
                browserOpened: openURL,
                deviceCodeStarted: nil
            )
        }
    }

    func startManagedChatgptDeviceCodeLogin(
        presentDeviceCode: @MainActor @escaping @Sendable (CodexManagedChatgptDeviceCode, Bool) -> Void
    ) async -> CodexManagedChatgptLoginResult {
        let presenterID = UUID()
        deviceCodePresenters[presenterID] = presentDeviceCode
        defer { deviceCodePresenters[presenterID] = nil }

        if let currentDeviceCode, inFlightLogin?.flow == .deviceCode {
            await presentDeviceCode(currentDeviceCode, false)
        }

        return await startManagedLogin(flow: .deviceCode) { [
            clientFactory,
            refreshRequestTimeout,
            deviceCodeLoginValidationTimeout,
            loginPollInterval,
            now,
            sleep,
            weak self
        ] in
            let client = clientFactory()
            return await Self.runLogin(
                client: client,
                flow: .deviceCode,
                requestTimeout: refreshRequestTimeout,
                validationTimeout: deviceCodeLoginValidationTimeout,
                pollInterval: loginPollInterval,
                now: now,
                sleep: sleep,
                browserOpened: nil,
                deviceCodeStarted: { [self] code in
                    await self?.publishDeviceCode(code, initiatingPresenterID: presenterID)
                }
            )
        }
    }

    private func startManagedLogin(
        flow: CodexManagedLoginFlow,
        operation: @escaping @Sendable () async -> CodexManagedChatgptLoginResult
    ) async -> CodexManagedChatgptLoginResult {
        if let inFlightLogout {
            _ = await inFlightLogout.task.value
        }
        let operationGeneration = authMutationGeneration
        var waitedForRefresh = false
        while true {
            guard operationGeneration == authMutationGeneration else {
                return .failed(message: "Codex sign-in was canceled because sign out started.")
            }
            if let slot = inFlightLogin {
                if slot.flow == flow {
                    let result = await slot.task.value
                    guard operationGeneration == authMutationGeneration else {
                        return .failed(message: "Codex sign-in was canceled because sign out started.")
                    }
                    return result
                }
                slot.task.cancel()
                _ = await slot.task.value
                if inFlightLogin?.id == slot.id {
                    inFlightLogin = nil
                    currentDeviceCode = nil
                }
                continue
            }

            if !waitedForRefresh, let refresh = inFlightRefresh {
                waitedForRefresh = true
                let refreshResult = await refresh.task.value
                guard operationGeneration == authMutationGeneration else {
                    return .failed(message: "Codex sign-in was canceled because sign out started.")
                }
                switch refreshResult {
                case let .recovered(account?):
                    latestManagedAccount = account
                    return .authenticated(account: account)
                case .recovered(account: nil):
                    latestManagedAccount = nil
                    return .authenticatedWithoutManagedAccount
                case .requiresUserLogin:
                    continue
                case let .executableUnavailable(message):
                    latestManagedAccount = nil
                    return .executableUnavailable(message: message)
                }
            }

            let id = UUID()
            let task = Task<CodexManagedChatgptLoginResult, Never> {
                await operation()
            }
            inFlightLogin = InFlightLogin(id: id, flow: flow, task: task)
            let result = await task.value
            if inFlightLogin?.id == id {
                inFlightLogin = nil
                currentDeviceCode = nil
            }
            guard operationGeneration == authMutationGeneration else {
                return .failed(message: "Codex sign-in was canceled because sign out started.")
            }
            switch result {
            case let .authenticated(account):
                latestManagedAccount = account
            case .authenticatedWithoutManagedAccount, .executableUnavailable:
                latestManagedAccount = nil
            case .failed:
                break
            }
            return result
        }
    }

    func logoutManagedAccount() async -> CodexManagedAuthLogoutResult {
        if let inFlightLogout {
            return await inFlightLogout.task.value
        }

        authMutationGeneration &+= 1
        let loginTask = inFlightLogin?.task
        loginTask?.cancel()
        if inFlightLogin != nil {
            inFlightLogin = nil
        }
        let refreshTask = inFlightRefresh?.task
        refreshTask?.cancel()
        inFlightRefresh = nil
        currentDeviceCode = nil

        var retirementTasks: [Task<Void, Never>] = []
        if let loginTask {
            retirementTasks.append(Task { _ = await loginTask.value })
        }
        if let refreshTask {
            retirementTasks.append(Task { _ = await refreshTask.value })
        }

        let id = UUID()
        let task = Task<CodexManagedAuthLogoutResult, Never> { [
            clientFactory,
            refreshRequestTimeout,
            cancelledWorkRetirementTimeout,
            retirementSleep
        ] in
            _ = await Self.awaitCancelledWorkRetirement(
                retirementTasks,
                timeout: cancelledWorkRetirementTimeout,
                sleep: retirementSleep
            )

            let client = clientFactory()
            let result: CodexManagedAuthLogoutResult
            do {
                await client.updateDefaultRequestTimeout(refreshRequestTimeout)
                try await client.startIfNeeded()
                _ = try await client.request(
                    method: "account/logout",
                    params: nil,
                    timeout: refreshRequestTimeout
                )
                result = .signedOut
            } catch {
                if let message = Self.executableUnavailableMessage(from: error) {
                    result = .executableUnavailable(message: message)
                } else {
                    result = .failed(message: Self.trimmedMessage(
                        error.localizedDescription,
                        fallback: "Codex could not complete sign out."
                    ))
                }
            }
            await client.stop()
            await self.finishLogoutOperation(id: id, result: result)
            return result
        }
        inFlightLogout = InFlightLogout(id: id, task: task)
        return await task.value
    }

    private func finishLogoutOperation(id: UUID, result: CodexManagedAuthLogoutResult) {
        guard inFlightLogout?.id == id else { return }
        inFlightLogout = nil
        switch result {
        case .signedOut, .executableUnavailable:
            latestManagedAccount = nil
        case .failed:
            break
        }
    }

    private static func awaitCancelledWorkRetirement(
        _ tasks: [Task<Void, Never>],
        timeout: TimeInterval,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void
    ) async -> Bool {
        guard !tasks.isEmpty else { return true }
        let signal = RetirementSignal()
        let retirementTask = Task {
            for task in tasks {
                await task.value
            }
            await signal.resolve(true)
        }
        let timeoutTask = Task {
            do {
                try await sleep(max(0, timeout))
            } catch {
                return
            }
            await signal.resolve(false)
        }
        let retired = await signal.wait()
        retirementTask.cancel()
        timeoutTask.cancel()
        return retired
    }

    private func publishDeviceCode(
        _ code: CodexManagedChatgptDeviceCode,
        initiatingPresenterID: UUID
    ) async {
        currentDeviceCode = code
        for (presenterID, presenter) in deviceCodePresenters {
            await presenter(code, presenterID == initiatingPresenterID)
        }
    }

    private static func runLogin(
        client: any CodexManagedAuthRPCClient,
        flow: CodexManagedLoginFlow,
        requestTimeout: TimeInterval,
        validationTimeout: TimeInterval,
        pollInterval: TimeInterval,
        now: @escaping @Sendable () -> Date,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void,
        browserOpened: (@MainActor @Sendable (URL) -> Void)?,
        deviceCodeStarted: (@Sendable (CodexManagedChatgptDeviceCode) async -> Void)?
    ) async -> CodexManagedChatgptLoginResult {
        let cancellation = LoginCancellationState()
        var failureAuthURL: URL?
        let result = await withTaskCancellationHandler {
            do {
                await client.updateDefaultRequestTimeout(requestTimeout)
                try await client.startIfNeeded()
                let notifications = await client.subscribeNotifications()
                let state = LoginNotificationState()
                let loginID: String
                let browserAuthURL: URL?

                switch flow {
                case .browser:
                    let startResponse = try await startChatgptLogin(
                        client: client,
                        flow: flow,
                        timeout: requestTimeout
                    )
                    guard case let .browser(browser) = startResponse else {
                        throw AIProviderError.invalidResponse(detail: "Codex returned an invalid ChatGPT login response.")
                    }
                    loginID = browser.loginID
                    browserAuthURL = browser.authURL
                    failureAuthURL = browser.authURL
                    await cancellation.register(loginID: loginID, client: client, timeout: requestTimeout)
                    try Task.checkCancellation()
                    await browserOpened?(browser.authURL)
                case .deviceCode:
                    let startResponse = try await startChatgptLogin(
                        client: client,
                        flow: flow,
                        timeout: requestTimeout
                    )
                    guard case let .deviceCode(deviceCode) = startResponse else {
                        throw AIProviderError.invalidResponse(detail: "Codex returned an invalid ChatGPT device-code response.")
                    }
                    loginID = deviceCode.loginID
                    browserAuthURL = nil
                    await cancellation.register(loginID: loginID, client: client, timeout: requestTimeout)
                    try Task.checkCancellation()
                    await deviceCodeStarted?(deviceCode)
                }

                let notificationTask = Task {
                    var iterator = notifications.makeAsyncIterator()
                    while !Task.isCancelled, let notification = await iterator.next() {
                        await state.consume(notification: notification, expectedLoginID: loginID)
                    }
                }
                defer { notificationTask.cancel() }

                let deadline = now().addingTimeInterval(validationTimeout)
                return try await withThrowingTaskGroup(of: CodexManagedChatgptLoginResult?.self) { group in
                    // A matching managed-login completion is the primary success signal.
                    // Even then, account/read(refreshToken: true) remains authoritative.
                    group.addTask {
                        guard let completion = await state.waitForCompletion() else {
                            return nil
                        }
                        switch completion {
                        case .success:
                            guard let account = try await readAuthenticatedAccount(
                                client: client,
                                timeout: requestTimeout,
                                retryDelay: pollInterval,
                                sleep: sleep
                            ) else {
                                return nil
                            }
                            return .authenticated(account: account)
                        case let .failure(message):
                            return .failed(message: failureGuidance(
                                flow: flow,
                                message: message,
                                authURL: browserAuthURL
                            ))
                        }
                    }
                    group.addTask {
                        // Notifications can be lost with a dying transport. Keep a bounded
                        // fallback, but force token refresh so an unvalidated stale account
                        // snapshot cannot report success. A successful refresh remains
                        // authoritative even when the user signs back into the same account.
                        while now() < deadline {
                            try Task.checkCancellation()
                            if let account = try await readAuthenticatedAccount(
                                client: client,
                                timeout: requestTimeout,
                                retryDelay: pollInterval,
                                sleep: sleep
                            ) {
                                return .authenticated(account: account)
                            }
                            let remaining = deadline.timeIntervalSince(now())
                            if remaining > 0 {
                                try await sleep(min(pollInterval, remaining))
                            }
                        }
                        try Task.checkCancellation()
                        if let account = try await readAuthenticatedAccount(
                            client: client,
                            timeout: requestTimeout,
                            retryDelay: pollInterval,
                            sleep: sleep
                        ) {
                            return .authenticated(account: account)
                        }
                        return .failed(message: timeoutGuidance(flow: flow, authURL: browserAuthURL))
                    }
                    while let candidate = try await group.next() {
                        if let candidate {
                            group.cancelAll()
                            return candidate
                        }
                    }
                    return .failed(message: timeoutGuidance(flow: flow, authURL: browserAuthURL))
                }
            } catch is CancellationError {
                await cancellation.cancel(client: client, timeout: requestTimeout)
                return .failed(message: "Codex ChatGPT login was canceled before completion. Start the login again when ready.")
            } catch {
                await cancellation.cancel(client: client, timeout: requestTimeout)
                if let message = executableUnavailableMessage(from: error) {
                    return .executableUnavailable(message: message)
                }
                return .failed(message: failureGuidance(
                    flow: flow,
                    message: error.localizedDescription,
                    authURL: failureAuthURL
                ))
            }
        } onCancel: {
            Task {
                await cancellation.cancel(client: client, timeout: requestTimeout)
            }
        }
        await client.stop()
        return result
    }

    private static func readAuthenticatedAccount(
        client: any CodexManagedAuthRPCClient,
        timeout: TimeInterval,
        retryDelay: TimeInterval,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void
    ) async throws -> CodexManagedAccount? {
        var transientFailureCount = 0
        while true {
            do {
                let result = try await client.request(
                    method: "account/read",
                    params: ["refreshToken": true],
                    timeout: timeout
                )
                guard let account = parseManagedAccount(from: result) else { return nil }
                return CodexManagedAccount(
                    email: account.email,
                    planType: account.planType,
                    accountType: account.accountType,
                    accountID: account.accountID,
                    authenticationMode: account.authenticationMode ?? "managed_chatgpt",
                    managedLoginValidated: true
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard isClearlyTransientAccountReadFailure(error), transientFailureCount < 2 else {
                    throw error
                }
                transientFailureCount += 1
                let backoff = min(max(retryDelay, 0.1) * pow(2, Double(transientFailureCount - 1)), 2)
                try await sleep(backoff)
            }
        }
    }

    private static func isClearlyTransientAccountReadFailure(_ error: Error) -> Bool {
        guard let clientError = error as? CodexAppServerClient.ClientError,
              case let .requestFailed(failure) = clientError
        else {
            return false
        }
        // Codex documents -32001 as its overloaded/retry-later response.
        return failure.code == -32001
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
        flow: CodexManagedLoginFlow,
        timeout: TimeInterval
    ) async throws -> ManagedChatgptLoginStartResponse {
        let type = flow == .browser ? "chatgpt" : "chatgptDeviceCode"
        do {
            return try await requestLoginStart(client: client, type: type, timeout: timeout)
        } catch {
            if error.localizedDescription.localizedCaseInsensitiveContains("external auth is active") {
                _ = try? await client.request(method: "account/logout", params: nil, timeout: timeout)
                return try await requestLoginStart(client: client, type: type, timeout: timeout)
            }
            throw error
        }
    }

    private static func requestLoginStart(
        client: any CodexManagedAuthRPCClient,
        type: String,
        timeout: TimeInterval
    ) async throws -> ManagedChatgptLoginStartResponse {
        let response = try await client.request(
            method: "account/login/start",
            params: ["type": type],
            timeout: timeout
        )
        if type == "chatgpt", let parsed = parseManagedChatgptLoginStartResponse(response) {
            return .browser(parsed)
        }
        if type == "chatgptDeviceCode", let parsed = parseManagedChatgptDeviceCodeStartResponse(response) {
            return .deviceCode(parsed)
        }
        let detail = type == "chatgpt"
            ? "Codex returned an invalid ChatGPT login response."
            : "Codex returned an invalid ChatGPT device-code response."
        throw AIProviderError.invalidResponse(detail: detail)
    }

    static func parseManagedChatgptLoginStartResponse(
        _ response: [String: Any]
    ) -> ManagedChatgptBrowserLoginStartResponse? {
        guard let loginID = stringValue(in: response, keys: ["loginId", "login_id"]),
              let authURLString = stringValue(in: response, keys: ["authUrl", "auth_url"]),
              let authURL = URL(string: authURLString),
              stringValue(in: response, keys: ["type"])?.lowercased() == "chatgpt"
        else {
            return nil
        }
        return ManagedChatgptBrowserLoginStartResponse(loginID: loginID, authURL: authURL)
    }

    static func parseManagedChatgptDeviceCodeStartResponse(
        _ response: [String: Any]
    ) -> CodexManagedChatgptDeviceCode? {
        guard let loginID = stringValue(in: response, keys: ["loginId", "login_id"]),
              let userCode = stringValue(in: response, keys: ["userCode", "user_code"]),
              let verificationURLString = stringValue(
                  in: response,
                  keys: ["verificationUrl", "verification_url"]
              ),
              let verificationURL = URL(string: verificationURLString),
              stringValue(in: response, keys: ["type"])?.lowercased() == "chatgptdevicecode"
        else {
            return nil
        }
        return CodexManagedChatgptDeviceCode(
            loginID: loginID,
            userCode: userCode,
            verificationURL: verificationURL
        )
    }

    static func browserCallbackPort(from authURL: URL) -> Int? {
        if authURL.host?.localizedCaseInsensitiveCompare("localhost") == .orderedSame {
            return authURL.port
        }
        guard let components = URLComponents(url: authURL, resolvingAgainstBaseURL: false),
              let redirectURI = components.queryItems?.first(where: {
                  $0.name.localizedCaseInsensitiveCompare("redirect_uri") == .orderedSame
              })?.value,
              let redirectURL = URL(string: redirectURI),
              redirectURL.host?.localizedCaseInsensitiveCompare("localhost") == .orderedSame
        else {
            return nil
        }
        return redirectURL.port
    }

    static func browserFailureGuidance(message: String, authURL: URL?) -> String {
        var parts = [trimmedMessage(message, fallback: "Codex ChatGPT login failed.")]
        if let authURL, let port = browserCallbackPort(from: authURL) {
            parts.append(
                "Codex was waiting for the browser callback on localhost:\(port). Use `lsof -iTCP:\(port) -sTCP:LISTEN` to verify that the listener belongs to the active Codex app-server, then confirm that process is still running and healthy."
            )
        } else {
            parts.append("Verify that the Codex app-server process is still running and able to receive the browser callback.")
        }
        parts.append("Try 'Use device code instead' to sign in without a localhost callback.")
        parts.append(CodexManagedAuthRecoveryClassifier.separateSignInExplanation)
        return parts.joined(separator: " ")
    }

    private static func failureGuidance(flow: CodexManagedLoginFlow, message: String, authURL: URL?) -> String {
        switch flow {
        case .browser:
            browserFailureGuidance(message: message, authURL: authURL)
        case .deviceCode:
            "\(trimmedMessage(message, fallback: "Codex ChatGPT device-code login failed.")) Request a new device code and try again. \(CodexManagedAuthRecoveryClassifier.separateSignInExplanation)"
        }
    }

    private static func timeoutGuidance(flow: CodexManagedLoginFlow, authURL: URL?) -> String {
        switch flow {
        case .browser:
            browserFailureGuidance(
                message: "Codex ChatGPT login did not complete in time. The managed account was checked once more and is still signed out.",
                authURL: authURL
            )
        case .deviceCode:
            "Codex ChatGPT device-code login did not complete before the code expired. The managed account was checked once more and is still signed out. Request a new device code and try again. \(CodexManagedAuthRecoveryClassifier.separateSignInExplanation)"
        }
    }

    private static func trimmedMessage(_ message: String, fallback: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private static func isValidAccountReadResult(_ result: [String: Any]) -> Bool {
        let requiresOpenAIAuth = boolValue(in: result, keys: ["requiresOpenaiAuth", "requires_openai_auth"]) ?? true
        if requiresOpenAIAuth == false {
            return true
        }
        return isAuthenticatedAccountReadResult(result)
    }

    private static func isAuthenticatedAccountReadResult(_ result: [String: Any]) -> Bool {
        guard let account = result["account"], !(account is NSNull) else {
            return false
        }
        return true
    }

    static func parseManagedAccount(from result: [String: Any]) -> CodexManagedAccount? {
        guard boolValue(in: result, keys: ["requiresOpenaiAuth", "requires_openai_auth"]) != false else {
            return nil
        }
        guard isAuthenticatedAccountReadResult(result) else { return nil }
        guard let account = result["account"] as? [String: Any] else {
            return CodexManagedAccount()
        }
        let accountType = stringValue(in: account, keys: ["type", "kind", "accountType", "account_type"])
        let explicitAuthenticationMode = stringValue(
            in: account,
            keys: ["authenticationMode", "authentication_mode", "authMode", "auth_mode"]
        ) ?? stringValue(
            in: result,
            keys: ["authenticationMode", "authentication_mode", "authMode", "auth_mode"]
        )
        return CodexManagedAccount(
            email: stringValue(in: account, keys: ["email"]),
            planType: stringValue(in: account, keys: ["planType", "plan_type", "plan"]),
            accountType: accountType,
            accountID: stringValue(in: account, keys: ["accountId", "account_id", "id"]),
            authenticationMode: explicitAuthenticationMode
        )
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

    struct ManagedChatgptBrowserLoginStartResponse: Equatable {
        let loginID: String
        let authURL: URL
    }

    private enum ManagedChatgptLoginStartResponse {
        case browser(ManagedChatgptBrowserLoginStartResponse)
        case deviceCode(CodexManagedChatgptDeviceCode)
    }

    private actor RetirementSignal {
        private var result: Bool?
        private var waiters: [CheckedContinuation<Bool, Never>] = []

        func wait() async -> Bool {
            if let result { return result }
            return await withCheckedContinuation { continuation in
                if let result {
                    continuation.resume(returning: result)
                } else {
                    waiters.append(continuation)
                }
            }
        }

        func resolve(_ result: Bool) {
            guard self.result == nil else { return }
            self.result = result
            let pending = waiters
            waiters.removeAll()
            for waiter in pending {
                waiter.resume(returning: result)
            }
        }
    }

    private actor LoginCancellationState {
        private var loginID: String?
        private var cancellationRequested = false
        private var cancellationTask: Task<Void, Never>?

        func register(
            loginID: String,
            client: any CodexManagedAuthRPCClient,
            timeout: TimeInterval
        ) async {
            self.loginID = loginID
            if cancellationRequested {
                await sendCancellationIfNeeded(client: client, timeout: timeout)
            }
        }

        func cancel(client: any CodexManagedAuthRPCClient, timeout: TimeInterval) async {
            cancellationRequested = true
            await sendCancellationIfNeeded(client: client, timeout: timeout)
        }

        private func sendCancellationIfNeeded(
            client: any CodexManagedAuthRPCClient,
            timeout: TimeInterval
        ) async {
            if let cancellationTask {
                await cancellationTask.value
                return
            }
            guard let loginID else { return }
            let task = Task {
                _ = try? await client.request(
                    method: "account/login/cancel",
                    params: ["loginId": loginID],
                    timeout: timeout
                )
            }
            cancellationTask = task
            await task.value
        }
    }

    private actor LoginNotificationState {
        enum Completion {
            case success
            case failure(String)
        }

        private var completion: Completion?
        private var pendingCompletionWaiters: [CheckedContinuation<Completion?, Never>] = []

        func consume(notification: CodexAppServerClient.Notification, expectedLoginID: String) {
            guard notification.method == "account/login/completed", completion == nil else { return }
            let params = Self.decodeParams(notification.params)
            // The broad Codex notification union permits a null loginId for non-managed
            // variants. Browser and device-code starts return an ID, so only an exact
            // match can complete this attempt. Absent, null, and foreign IDs are ignored;
            // account/read provides the bounded notification-loss fallback.
            guard Self.stringValue(in: params, keys: ["loginId", "login_id"]) == expectedLoginID else {
                return
            }
            let observedCompletion: Completion = if Self.boolValue(in: params, keys: ["success"]) == true {
                .success
            } else {
                .failure(
                    Self.stringValue(in: params, keys: ["error"]) ?? "Codex ChatGPT login failed."
                )
            }
            completion = observedCompletion
            resolvePendingWaiters(with: observedCompletion)
        }

        /// Suspends until the correlated terminal notification arrives. Returns `nil`
        /// when the waiter is cancelled so task-group cancellation cannot strand it.
        func waitForCompletion() async -> Completion? {
            if let completion {
                return completion
            }
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    registerWaiterIfStillPending(continuation)
                }
            } onCancel: {
                Task { await self.cancelPendingWaiters() }
            }
        }

        private func registerWaiterIfStillPending(_ continuation: CheckedContinuation<Completion?, Never>) {
            if let completion {
                continuation.resume(returning: completion)
                return
            }
            pendingCompletionWaiters.append(continuation)
        }

        private func resolvePendingWaiters(with completion: Completion) {
            let waiters = pendingCompletionWaiters
            pendingCompletionWaiters.removeAll()
            for waiter in waiters {
                waiter.resume(returning: completion)
            }
        }

        private func cancelPendingWaiters() {
            let waiters = pendingCompletionWaiters
            pendingCompletionWaiters.removeAll()
            for waiter in waiters {
                waiter.resume(returning: nil)
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
