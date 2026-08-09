import Darwin
import Foundation
@testable import RepoPromptApp
import XCTest

final class CodexManagedAuthRecoveryServiceTests: XCTestCase {
    func testParsesBrowserAndDeviceCodeStartResponses() throws {
        let browser = try XCTUnwrap(CodexManagedAuthRecoveryService.parseManagedChatgptLoginStartResponse([
            "type": "chatgpt",
            "loginId": "browser-login",
            "authUrl": "https://auth.openai.com/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A1457%2Fauth%2Fcallback"
        ]))
        XCTAssertEqual(browser.loginID, "browser-login")
        XCTAssertEqual(CodexManagedAuthRecoveryService.browserCallbackPort(from: browser.authURL), 1457)

        let device = try XCTUnwrap(CodexManagedAuthRecoveryService.parseManagedChatgptDeviceCodeStartResponse([
            "type": "chatgptDeviceCode",
            "loginId": "device-login",
            "userCode": "ABCD-EFGH",
            "verificationUrl": "https://auth.openai.com/codex/device"
        ]))
        XCTAssertEqual(device.loginID, "device-login")
        XCTAssertEqual(device.userCode, "ABCD-EFGH")
        XCTAssertEqual(device.verificationURL.absoluteString, "https://auth.openai.com/codex/device")

        XCTAssertNil(CodexManagedAuthRecoveryService.parseManagedChatgptLoginStartResponse([
            "type": "chatgpt",
            "authUrl": "https://auth.openai.com/authorize"
        ]))
        XCTAssertNil(CodexManagedAuthRecoveryService.parseManagedChatgptDeviceCodeStartResponse([
            "type": "chatgptDeviceCode",
            "loginId": "device-login",
            "verificationUrl": "https://auth.openai.com/codex/device"
        ]))
    }

    func testBrowserGuidanceIncludesCallbackPortDeviceEscapeHatchAndSeparateSignIn() {
        let authURL = URL(
            string: "https://auth.openai.com/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback"
        )
        let guidance = CodexManagedAuthRecoveryService.browserFailureGuidance(
            message: "Login failed.",
            authURL: authURL
        )

        XCTAssertTrue(guidance.contains("localhost:1455"))
        XCTAssertTrue(guidance.contains("lsof -iTCP:1455"))
        XCTAssertTrue(guidance.contains("listener belongs to the active Codex app-server"))
        XCTAssertTrue(guidance.contains("still running and healthy"))
        XCTAssertFalse(guidance.contains("Another app may be occupying"))
        XCTAssertTrue(guidance.contains(CodexManagedAuthRecoveryClassifier.deviceCodeActionTitle))
        XCTAssertTrue(guidance.contains(CodexManagedAuthRecoveryClassifier.separateSignInExplanation))
        XCTAssertTrue(CodexManagedAuthRecoveryClassifier.preservesAsUserFacingGuidance(guidance))
    }

    func testDeviceCodeLoginSucceedsFromAccountReadWithoutSuccessNotification() async {
        let client = MockCodexManagedAuthClient(
            loginStartResponse: Self.deviceStartResponse,
            accountReadResponses: [Self.signedOutAccount, Self.signedInAccount]
        )
        let clock = TestClock()
        let service = makeService(client: client, clock: clock, validationTimeout: 2)
        let presented = LockedBox<(code: CodexManagedChatgptDeviceCode, shouldOpen: Bool)>()

        let result = await service.startManagedChatgptDeviceCodeLogin { code, shouldOpen in
            presented.set((code: code, shouldOpen: shouldOpen))
        }

        assertAuthenticated(result)
        XCTAssertEqual(presented.value?.code.userCode, "ABCD-EFGH")
        XCTAssertEqual(presented.value?.shouldOpen, true)
        XCTAssertEqual(client.requestCount(method: "account/login/start"), 1)
        XCTAssertEqual(client.requestCount(method: "account/read"), 2)
        XCTAssertEqual(client.requestCount(method: "account/login/cancel"), 0)
        XCTAssertEqual(client.stopCallCount(), 1)
    }

    func testStalePreLoginAccountCannotAuthenticateWithoutValidatingRefresh() async {
        let staleAccount: [String: Any] = [
            "account": ["type": "chatgpt", "email": "stale@example.com"],
            "requiresOpenaiAuth": true
        ]
        let client = MockCodexManagedAuthClient(
            loginStartResponse: Self.browserStartResponse,
            accountReadResponses: [Self.signedOutAccount],
            unrefreshedAccountReadResponse: staleAccount
        )
        let clock = TestClock()
        let service = makeService(client: client, clock: clock, validationTimeout: 1)

        let result = await service.startManagedChatgptLogin { _ in }

        guard case let .failed(message) = result else {
            return XCTFail("Expected unchanged stale account to time out, got \(result)")
        }
        XCTAssertTrue(message.contains("still signed out"))
        XCTAssertEqual(client.accountReadRefreshFlags(), [true, true])
        XCTAssertEqual(client.requestCount(method: "account/login/cancel"), 0)
        XCTAssertEqual(client.stopCallCount(), 1)
    }

    func testCorrelatedSuccessValidatesRefreshBeforeAcceptingUnchangedAccount() async {
        let unchangedAccount: [String: Any] = [
            "account": ["type": "chatgpt", "email": "same@example.com"],
            "requiresOpenaiAuth": true
        ]
        let client = MockCodexManagedAuthClient(
            loginStartResponse: Self.browserStartResponse,
            accountReadResponses: [unchangedAccount],
            notificationOnLoginStart: CodexAppServerClient.Notification(
                method: "account/login/completed",
                params: [
                    "loginId": .string("browser-login"),
                    "success": .bool(true),
                    "error": .null
                ]
            )
        )
        let service = CodexManagedAuthRecoveryService(
            clientFactory: { client },
            refreshRequestTimeout: 1,
            browserLoginValidationTimeout: 300,
            deviceCodeLoginValidationTimeout: 900,
            loginPollInterval: 1,
            sleep: { _ in try await Task.sleep(nanoseconds: .max) }
        )

        let result = await service.startManagedChatgptLogin { _ in }

        assertAuthenticated(result)
        let refreshFlags = client.accountReadRefreshFlags()
        XCTAssertFalse(refreshFlags.isEmpty)
        XCTAssertTrue(refreshFlags.allSatisfy(\.self))
        XCTAssertEqual(client.stopCallCount(), 1)
    }

    func testAbsentAndNullCompletionLoginIDsAreIgnoredAndSafeFallbackRemainsAvailable() async {
        let notificationParams: [[String: CodexJSONValue]] = [
            [
                "success": .bool(false),
                "error": .string("Uncorrelated failure without an ID.")
            ],
            [
                "loginId": .null,
                "success": .bool(false),
                "error": .string("Uncorrelated failure with a null ID.")
            ]
        ]

        for params in notificationParams {
            let client = MockCodexManagedAuthClient(
                loginStartResponse: Self.deviceStartResponse,
                accountReadResponses: [Self.signedOutAccount, Self.signedInAccount],
                notificationOnLoginStart: CodexAppServerClient.Notification(
                    method: "account/login/completed",
                    params: params
                )
            )
            let clock = TestClock()
            let service = makeService(client: client, clock: clock, validationTimeout: 1)

            let result = await service.startManagedChatgptDeviceCodeLogin { _, _ in }

            assertAuthenticated(result)
            XCTAssertEqual(client.accountReadRefreshFlags(), [true, true])
            XCTAssertEqual(client.stopCallCount(), 1)
        }
    }

    func testDocumentedOverloadRetryBudgetIsBounded() async {
        let overload = CodexAppServerClient.ClientError.requestFailed(.init(
            method: "account/read",
            code: -32001,
            message: "Server overloaded; retry later.",
            data: nil
        ))
        let client = MockCodexManagedAuthClient(
            loginStartResponse: Self.browserStartResponse,
            accountReadOutcomes: [.failure(overload)]
        )
        let clock = TestClock()
        let service = makeService(client: client, clock: clock, validationTimeout: 300)

        let result = await service.startManagedChatgptLogin { _ in }

        guard case let .failed(message) = result else {
            return XCTFail("Expected bounded overload failure, got \(result)")
        }
        XCTAssertTrue(message.contains("Server overloaded; retry later."))
        XCTAssertEqual(client.requestCount(method: "account/read"), 3)
        XCTAssertEqual(clock.now.timeIntervalSince1970, 3, accuracy: 0.001)
        XCTAssertEqual(client.requestCount(method: "account/login/cancel"), 1)
        XCTAssertEqual(client.stopCallCount(), 1)
    }

    func testProcessExitDuringValidationFailsPromptlyCancelsAndAwaitsStop() async throws {
        let events = EventRecorder()
        let processExit = CodexAppServerClient.ClientError.processExited(.init(
            executablePath: "/tmp/codex",
            launchDirectory: "/tmp",
            pid: 4242,
            status: .exited(code: 23),
            stderrTail: Data("fixture process exit".utf8),
            stderrWasTruncated: false,
            stderrWasSettled: true
        ))
        let client = MockCodexManagedAuthClient(
            label: "browser",
            loginStartResponse: Self.browserStartResponse,
            accountReadOutcomes: [
                .response(Self.signedOutAccount),
                .failure(processExit)
            ],
            eventRecorder: { events.record($0) }
        )
        let clock = TestClock()
        let service = makeService(client: client, clock: clock, validationTimeout: 300)

        let result = await service.startManagedChatgptLogin { _ in }

        guard case let .failed(message) = result else {
            return XCTFail("Expected prompt process-exit failure, got \(result)")
        }
        XCTAssertTrue(message.contains("exited with status 23"))
        XCTAssertTrue(message.contains("fixture process exit"))
        XCTAssertTrue(message.contains("listener belongs to the active Codex app-server"))
        XCTAssertTrue(message.contains(CodexManagedAuthRecoveryClassifier.deviceCodeActionTitle))
        XCTAssertEqual(clock.now.timeIntervalSince1970, 1, accuracy: 0.001)
        XCTAssertEqual(client.requestCount(method: "account/login/cancel"), 1)
        XCTAssertEqual(client.stopCallCount(), 1)

        let recordedEvents = events.snapshot()
        let validationRead = try XCTUnwrap(recordedEvents.lastIndex(of: "browser.account/read"))
        let cancel = try XCTUnwrap(recordedEvents.firstIndex(of: "browser.account/login/cancel"))
        let stop = try XCTUnwrap(recordedEvents.firstIndex(of: "browser.stop"))
        XCTAssertLessThan(validationRead, cancel)
        XCTAssertLessThan(cancel, stop)
    }

    func testTransportFailureDuringValidationFailsPromptlyCancelsAndAwaitsStop() async throws {
        let events = EventRecorder()
        let transportFailure = CodexAppServerClient.ClientError.transportReadSetupFailed(
            message: "Codex app-server process pipe reader failed to start: Bad file descriptor",
            errno: EBADF
        )
        let client = MockCodexManagedAuthClient(
            label: "device",
            loginStartResponse: Self.deviceStartResponse,
            accountReadOutcomes: [
                .response(Self.signedOutAccount),
                .failure(transportFailure)
            ],
            eventRecorder: { events.record($0) }
        )
        let clock = TestClock()
        let service = makeService(client: client, clock: clock, validationTimeout: 900)

        let result = await service.startManagedChatgptDeviceCodeLogin { _, _ in }

        guard case let .failed(message) = result else {
            return XCTFail("Expected prompt transport failure, got \(result)")
        }
        XCTAssertTrue(message.contains("process pipe reader failed to start"))
        XCTAssertTrue(message.contains("Request a new device code and try again"))
        XCTAssertTrue(message.contains(CodexManagedAuthRecoveryClassifier.separateSignInExplanation))
        XCTAssertEqual(clock.now.timeIntervalSince1970, 1, accuracy: 0.001)
        XCTAssertEqual(client.requestCount(method: "account/login/cancel"), 1)
        XCTAssertEqual(client.stopCallCount(), 1)

        let recordedEvents = events.snapshot()
        let validationRead = try XCTUnwrap(recordedEvents.lastIndex(of: "device.account/read"))
        let cancel = try XCTUnwrap(recordedEvents.firstIndex(of: "device.account/login/cancel"))
        let stop = try XCTUnwrap(recordedEvents.firstIndex(of: "device.stop"))
        XCTAssertLessThan(validationRead, cancel)
        XCTAssertLessThan(cancel, stop)
    }

    func testCompletionFailureNotificationStopsLoginWithoutRetry() async {
        let client = MockCodexManagedAuthClient(
            loginStartResponse: Self.deviceStartResponse,
            accountReadResponses: [Self.signedOutAccount],
            notificationOnLoginStart: CodexAppServerClient.Notification(
                method: "account/login/completed",
                params: [
                    "loginId": .string("device-login"),
                    "success": .bool(false),
                    "error": .string("Device authorization was denied.")
                ]
            )
        )
        let service = CodexManagedAuthRecoveryService(
            clientFactory: { client },
            refreshRequestTimeout: 1,
            browserLoginValidationTimeout: 10,
            deviceCodeLoginValidationTimeout: 10,
            loginPollInterval: 1,
            sleep: { _ in try await Task.sleep(nanoseconds: .max) }
        )

        let result = await service.startManagedChatgptDeviceCodeLogin { _, _ in }

        guard case let .failed(message) = result else {
            return XCTFail("Expected notification failure, got \(result)")
        }
        XCTAssertTrue(message.contains("Device authorization was denied."))
        XCTAssertTrue(message.contains(CodexManagedAuthRecoveryClassifier.separateSignInExplanation))
        XCTAssertEqual(client.requestCount(method: "account/login/start"), 1)
        XCTAssertEqual(client.requestCount(method: "account/logout"), 0)
    }

    func testLateSuccessIsAcceptedByFinalAccountReadAtDeadline() async {
        let client = MockCodexManagedAuthClient(
            loginStartResponse: Self.browserStartResponse,
            accountReadResponses: [Self.signedOutAccount, Self.signedInAccount]
        )
        let clock = TestClock()
        let service = makeService(client: client, clock: clock, validationTimeout: 1)

        let result = await service.startManagedChatgptLogin { _ in }

        assertAuthenticated(result)
        XCTAssertEqual(client.requestCount(method: "account/read"), 2)
        XCTAssertEqual(client.requestCount(method: "account/login/start"), 1)
    }

    func testTimeoutPerformsFinalReadAndDoesNotRetryOrLogout() async {
        let client = MockCodexManagedAuthClient(
            loginStartResponse: Self.browserStartResponse,
            accountReadResponses: [Self.signedOutAccount]
        )
        let clock = TestClock()
        let service = makeService(client: client, clock: clock, validationTimeout: 1)

        let result = await service.startManagedChatgptLogin { _ in }

        guard case let .failed(message) = result else {
            return XCTFail("Expected timeout failure, got \(result)")
        }
        XCTAssertTrue(message.contains("checked once more"))
        XCTAssertTrue(message.contains("localhost:1457"))
        XCTAssertTrue(message.contains(CodexManagedAuthRecoveryClassifier.separateSignInExplanation))
        XCTAssertEqual(client.requestCount(method: "account/read"), 2)
        XCTAssertEqual(client.requestCount(method: "account/login/start"), 1)
        XCTAssertEqual(client.requestCount(method: "account/logout"), 0)
    }

    func testSwitchingFromBrowserToDeviceCodeCancelsFirstLoginBeforeStartingSecond() async throws {
        let browserClient = MockCodexManagedAuthClient(
            loginStartResponse: Self.browserStartResponse,
            accountReadResponses: [Self.signedOutAccount]
        )
        let deviceClient = MockCodexManagedAuthClient(
            loginStartResponse: Self.deviceStartResponse,
            accountReadResponses: [Self.signedOutAccount, Self.signedInAccount],
            notificationOnLoginStart: Self.deviceSuccessNotification
        )
        let clients = ClientFactoryBox([browserClient, deviceClient])
        let service = CodexManagedAuthRecoveryService(
            clientFactory: { clients.next() },
            refreshRequestTimeout: 1,
            browserLoginValidationTimeout: 300,
            deviceCodeLoginValidationTimeout: 900,
            loginPollInterval: 1,
            sleep: { _ in
                try await Task.sleep(nanoseconds: .max)
            }
        )

        let browserTask = Task {
            await service.startManagedChatgptLogin { _ in }
        }
        try await waitUntil {
            browserClient.requestCount(method: "account/login/start") == 1
        }

        let deviceResult = await service.startManagedChatgptDeviceCodeLogin { _, _ in }
        let browserResult = await browserTask.value

        assertAuthenticated(deviceResult)
        guard case .failed = browserResult else {
            return XCTFail("Expected the browser flow to be canceled, got \(browserResult)")
        }
        XCTAssertEqual(browserClient.requestCount(method: "account/login/cancel"), 1)
        XCTAssertEqual(browserClient.lastLoginID(for: "account/login/cancel"), "browser-login")
        XCTAssertEqual(browserClient.stopCallCount(), 1)
        XCTAssertEqual(deviceClient.requestCount(method: "account/login/start"), 1)
        XCTAssertEqual(deviceClient.lastLoginType(), "chatgptDeviceCode")
    }

    func testConcurrentSameFlowDeviceCodeLoginsCoalesceAndOnlyInitiatingPresenterOpensURL() async {
        let client = MockCodexManagedAuthClient(
            loginStartResponse: Self.deviceStartResponse,
            accountReadResponses: [Self.signedOutAccount, Self.signedInAccount],
            notificationOnLoginStart: Self.deviceSuccessNotification
        )
        let clients = ClientFactoryBox([client])
        let service = CodexManagedAuthRecoveryService(
            clientFactory: { clients.next() },
            refreshRequestTimeout: 1,
            browserLoginValidationTimeout: 300,
            deviceCodeLoginValidationTimeout: 900,
            loginPollInterval: 1,
            sleep: { _ in
                try await Task.sleep(nanoseconds: .max)
            }
        )
        let presentedA = LockedBox<Bool>()
        let presentedB = LockedBox<Bool>()

        async let resultA = service.startManagedChatgptDeviceCodeLogin { _, shouldOpen in
            presentedA.set(shouldOpen)
        }
        async let resultB = service.startManagedChatgptDeviceCodeLogin { _, shouldOpen in
            presentedB.set(shouldOpen)
        }
        let (a, b) = await (resultA, resultB)

        assertAuthenticated(a)
        assertAuthenticated(b)
        XCTAssertEqual(client.requestCount(method: "account/login/start"), 1)
        XCTAssertEqual(clients.remaining, 0)

        let openFlags = [presentedA.value, presentedB.value].compactMap(\.self)
        XCTAssertEqual(openFlags.count, 2, "both concurrent callers should have been presented the same device code")
        XCTAssertEqual(openFlags.count(where: { $0 }), 1, "exactly one presenter should be told to open the verification URL")
        XCTAssertEqual(openFlags.count(where: { !$0 }), 1)
    }

    func testConcurrentReplacementCallersShareSingleReplacementAfterCancelAndAwaitedStop() async throws {
        let events = EventRecorder()
        let browserClient = MockCodexManagedAuthClient(
            label: "browser",
            loginStartResponse: Self.browserStartResponse,
            accountReadResponses: [Self.signedOutAccount],
            eventRecorder: { events.record($0) }
        )
        let deviceClient = MockCodexManagedAuthClient(
            label: "device",
            loginStartResponse: Self.deviceStartResponse,
            accountReadResponses: [Self.signedInAccount],
            notificationOnLoginStart: Self.deviceSuccessNotification,
            eventRecorder: { events.record($0) }
        )
        let clients = ClientFactoryBox([browserClient, deviceClient])
        let service = CodexManagedAuthRecoveryService(
            clientFactory: { clients.next() },
            refreshRequestTimeout: 1,
            browserLoginValidationTimeout: 300,
            deviceCodeLoginValidationTimeout: 900,
            loginPollInterval: 1,
            sleep: { _ in
                try await Task.sleep(nanoseconds: .max)
            }
        )

        let browserTask = Task {
            await service.startManagedChatgptLogin { _ in }
        }
        try await waitUntil {
            browserClient.requestCount(method: "account/login/start") == 1
        }

        async let deviceResult1 = service.startManagedChatgptDeviceCodeLogin { _, _ in }
        async let deviceResult2 = service.startManagedChatgptDeviceCodeLogin { _, _ in }
        let (result1, result2) = await (deviceResult1, deviceResult2)
        let browserResult = await browserTask.value

        assertAuthenticated(result1)
        assertAuthenticated(result2)
        guard case .failed = browserResult else {
            return XCTFail("Expected the browser flow to be canceled, got \(browserResult)")
        }

        XCTAssertEqual(browserClient.requestCount(method: "account/login/cancel"), 1)
        XCTAssertEqual(browserClient.stopCallCount(), 1)
        XCTAssertEqual(deviceClient.requestCount(method: "account/login/start"), 1)
        XCTAssertEqual(clients.remaining, 0)

        let recordedEvents = events.snapshot()
        let cancelIndex = recordedEvents.firstIndex(of: "browser.account/login/cancel")
        let stopIndex = recordedEvents.firstIndex(of: "browser.stop")
        let deviceStartIndex = recordedEvents.firstIndex(of: "device.account/login/start")
        let cancelIdx = try XCTUnwrap(cancelIndex, "expected a recorded browser cancel RPC")
        let stopIdx = try XCTUnwrap(stopIndex, "expected a recorded browser stop")
        let startIdx = try XCTUnwrap(deviceStartIndex, "expected a recorded device login/start")
        XCTAssertLessThan(cancelIdx, stopIdx, "the canceled login must be requested before its client stops")
        XCTAssertLessThan(stopIdx, startIdx, "the canceled login's client must stop before the replacement login starts")
    }

    func testBrowserLoginUsesDefaultThreeHundredSecondLifetime() async {
        let client = MockCodexManagedAuthClient(
            loginStartResponse: Self.browserStartResponse,
            accountReadResponses: [Self.signedOutAccount]
        )
        let clock = TestClock()
        let service = CodexManagedAuthRecoveryService(
            clientFactory: { client },
            refreshRequestTimeout: 1,
            loginPollInterval: 50,
            now: { clock.now },
            sleep: { interval in clock.advance(by: interval) }
        )

        let result = await service.startManagedChatgptLogin { _ in }

        guard case .failed = result else {
            return XCTFail("Expected timeout failure, got \(result)")
        }
        XCTAssertEqual(clock.now.timeIntervalSince1970, 300, accuracy: 0.001)
    }

    func testDeviceCodeLoginUsesDefaultNineHundredSecondLifetime() async {
        let client = MockCodexManagedAuthClient(
            loginStartResponse: Self.deviceStartResponse,
            accountReadResponses: [Self.signedOutAccount]
        )
        let clock = TestClock()
        let service = CodexManagedAuthRecoveryService(
            clientFactory: { client },
            refreshRequestTimeout: 1,
            loginPollInterval: 50,
            now: { clock.now },
            sleep: { interval in clock.advance(by: interval) }
        )

        let result = await service.startManagedChatgptDeviceCodeLogin { _, _ in }

        guard case .failed = result else {
            return XCTFail("Expected timeout failure, got \(result)")
        }
        XCTAssertEqual(clock.now.timeIntervalSince1970, 900, accuracy: 0.001)
    }

    func testManagedAccountParsingSupportsRepresentativeAndPartialPayloads() throws {
        let full = try XCTUnwrap(CodexManagedAuthRecoveryService.parseManagedAccount(from: [
            "account": [
                "type": "chatgpt",
                "email": "person@example.com",
                "planType": "self_serve_business_prolite",
                "accountId": "account-123"
            ],
            "requiresOpenaiAuth": true
        ]))
        XCTAssertEqual(
            full,
            CodexManagedAccount(
                email: "person@example.com",
                planType: "self_serve_business_prolite",
                accountType: "chatgpt",
                accountID: "account-123"
            )
        )
        XCTAssertEqual(full.identityLabel, "person@example.com")
        XCTAssertEqual(full.planDisplayLabel, "Self Serve Business Prolite")
        XCTAssertEqual(full.authenticationModeDisplayLabel, "Managed Codex sign-in")
        XCTAssertTrue(full.isConfirmedManagedAuthentication)

        let partial = try XCTUnwrap(CodexManagedAuthRecoveryService.parseManagedAccount(from: [
            "account": ["plan_type": "plus"]
        ]))
        XCTAssertEqual(
            partial,
            CodexManagedAccount(planType: "plus")
        )
        XCTAssertEqual(partial.identityLabel, "Managed Codex account")
        XCTAssertEqual(partial.planDisplayLabel, "Plus")
        XCTAssertEqual(partial.authenticationModeDisplayLabel, "Managed Codex sign-in")
        XCTAssertFalse(partial.isConfirmedManagedAuthentication)

        let explicitMode = try XCTUnwrap(CodexManagedAuthRecoveryService.parseManagedAccount(from: [
            "account": ["authentication_mode": "enterprise_sso"]
        ]))
        XCTAssertEqual(explicitMode.authenticationMode, "enterprise_sso")
        XCTAssertEqual(explicitMode.authenticationModeDisplayLabel, "Enterprise SSO")
        XCTAssertFalse(explicitMode.isConfirmedManagedAuthentication)

        let apiKeyAccount = try XCTUnwrap(CodexManagedAuthRecoveryService.parseManagedAccount(from: [
            "account": ["type": "apiKey", "authentication_mode": "api_key"]
        ]))
        XCTAssertEqual(apiKeyAccount.authenticationModeDisplayLabel, "API Key")
        XCTAssertFalse(apiKeyAccount.isConfirmedManagedAuthentication)

        XCTAssertEqual(
            CodexManagedAuthRecoveryService.parseManagedAccount(from: ["account": "present"]),
            CodexManagedAccount()
        )
        XCTAssertNil(CodexManagedAuthRecoveryService.parseManagedAccount(from: [:]))
        XCTAssertNil(CodexManagedAuthRecoveryService.parseManagedAccount(from: ["account": NSNull()]))
    }

    func testManagedAccountDisplayProjectionKeepsAccountPlanAndAuthenticationDistinct() {
        let account = CodexManagedAccount(
            email: "person@example.com",
            planType: "business_plus",
            accountType: "chatgpt",
            accountID: "not-for-display",
            authenticationMode: "enterprise_sso"
        )

        XCTAssertEqual(
            account.settingsProjection,
            CodexManagedAccountSettingsProjection(
                account: "person@example.com",
                plan: "Business Plus",
                authentication: "Enterprise SSO"
            )
        )
        XCTAssertNotEqual(account.settingsProjection.plan, account.settingsProjection.authentication)

        let fallback = CodexManagedAccount()
        XCTAssertEqual(
            fallback.settingsProjection,
            CodexManagedAccountSettingsProjection(
                account: "Managed Codex account",
                plan: "Plan not provided",
                authentication: "Managed Codex sign-in"
            )
        )
    }

    func testRefreshPublishesSnapshotAndDefinitiveSignedOutClearsIt() async {
        let accountPayload: [String: Any] = [
            "account": ["type": "chatgpt", "email": "refresh@example.com", "planType": "pro"],
            "requiresOpenaiAuth": true
        ]
        let client = MockCodexManagedAuthClient(
            loginStartResponse: Self.browserStartResponse,
            accountReadResponses: [accountPayload, Self.signedOutAccount]
        )
        let service = makeService(client: client, clock: TestClock(), validationTimeout: 1)

        let first = await service.refreshManagedAccount()
        XCTAssertEqual(
            first,
            .recovered(account: CodexManagedAccount(
                email: "refresh@example.com",
                planType: "pro",
                accountType: "chatgpt"
            ))
        )
        let firstSnapshot = await service.managedAccountSnapshot()
        XCTAssertNotNil(firstSnapshot)

        guard case .requiresUserLogin = await service.refreshManagedAccount() else {
            return XCTFail("Expected the signed-out account response to require login")
        }
        let clearedSnapshot = await service.managedAccountSnapshot()
        XCTAssertNil(clearedSnapshot)
    }

    func testLoginReturnsFreshManagedAccountSnapshot() async {
        let accountPayload: [String: Any] = [
            "account": ["type": "chatgpt", "email": "fresh@example.com", "planType": "plus"],
            "requiresOpenaiAuth": true
        ]
        let client = MockCodexManagedAuthClient(
            loginStartResponse: Self.deviceStartResponse,
            accountReadResponses: [Self.signedOutAccount, accountPayload]
        )
        let service = makeService(client: client, clock: TestClock(), validationTimeout: 2)

        let result = await service.startManagedChatgptDeviceCodeLogin { _, _ in }
        guard case let .authenticated(account) = result else {
            return XCTFail("Expected authenticated result, got \(result)")
        }
        XCTAssertEqual(account.email, "fresh@example.com")
        XCTAssertEqual(account.planType, "plus")
        XCTAssertTrue(account.isConfirmedManagedAuthentication)
        let snapshot = await service.managedAccountSnapshot()
        XCTAssertEqual(snapshot, account)
    }

    func testRecoveredConnectionWithoutManagedAccountDoesNotStartChatGPTLogin() async throws {
        let refreshStopGate = TestAsyncGate()
        let client = MockCodexManagedAuthClient(
            loginStartResponse: Self.browserStartResponse,
            accountReadResponses: [[
                "account": [
                    "type": "chatgpt",
                    "email": "incidental@example.com",
                    "authentication_mode": "enterprise_sso"
                ],
                "requiresOpenaiAuth": false
            ]],
            stopGate: refreshStopGate
        )
        let service = makeService(client: client, clock: TestClock(), validationTimeout: 1)

        let refreshTask = Task { await service.refreshManagedAccount() }
        try await waitUntil { client.requestCount(method: "account/read") == 1 }
        let loginTask = Task { await service.startManagedChatgptLogin { _ in } }
        await Task.yield()

        XCTAssertEqual(client.requestCount(method: "account/login/start"), 0)
        await refreshStopGate.open()
        let refreshResult = await refreshTask.value
        let loginResult = await loginTask.value
        XCTAssertEqual(refreshResult, .recovered(account: nil))
        XCTAssertEqual(loginResult, .authenticatedWithoutManagedAccount)
        XCTAssertEqual(client.requestCount(method: "account/login/start"), 0)
        let snapshot = await service.managedAccountSnapshot()
        XCTAssertNil(snapshot)
    }

    func testLogoutBoundsCanceledLoginRetirementAndDoesNotClobberLaterLogin() async throws {
        let abandonedLoginStopGate = TestAsyncGate()
        let abandonedLoginClient = MockCodexManagedAuthClient(
            label: "abandoned-login",
            loginStartResponse: Self.deviceStartResponse,
            accountReadResponses: [Self.signedInAccount],
            stopGate: abandonedLoginStopGate
        )
        let logoutClient = MockCodexManagedAuthClient(
            label: "logout",
            loginStartResponse: Self.browserStartResponse,
            accountReadResponses: []
        )
        let laterLoginPayload: [String: Any] = [
            "account": ["type": "chatgpt", "email": "later@example.com"],
            "requiresOpenaiAuth": true
        ]
        let laterLoginClient = MockCodexManagedAuthClient(
            label: "later-login",
            loginStartResponse: Self.browserStartResponse,
            accountReadResponses: [laterLoginPayload]
        )
        let clients = ClientFactoryBox([abandonedLoginClient, logoutClient, laterLoginClient])
        let service = CodexManagedAuthRecoveryService(
            clientFactory: { clients.next() },
            refreshRequestTimeout: 1,
            browserLoginValidationTimeout: 1,
            deviceCodeLoginValidationTimeout: 1,
            loginPollInterval: 0.01,
            cancelledWorkRetirementTimeout: 1,
            retirementSleep: { _ in }
        )

        let abandonedLogin = Task {
            await service.startManagedChatgptDeviceCodeLogin { _, _ in }
        }
        try await waitUntil { abandonedLoginClient.requestCount(method: "account/read") == 1 }

        let logoutResult = await service.logoutManagedAccount()
        XCTAssertEqual(logoutResult, .signedOut)
        XCTAssertEqual(logoutClient.requestCount(method: "account/logout"), 1)
        XCTAssertEqual(abandonedLoginClient.stopCallCount(), 0)

        let laterLogin = await service.startManagedChatgptLogin { _ in }
        guard case let .authenticated(account) = laterLogin else {
            await abandonedLoginStopGate.open()
            _ = await abandonedLogin.value
            return XCTFail("Expected later login to succeed, got \(laterLogin)")
        }
        XCTAssertEqual(account.email, "later@example.com")

        await abandonedLoginStopGate.open()
        _ = await abandonedLogin.value
        let snapshot = await service.managedAccountSnapshot()
        XCTAssertEqual(snapshot?.email, "later@example.com")
    }

    func testAbandonedRefreshCannotClearLaterRefreshSlotOrRaceManagedLogin() async throws {
        let abandonedRefreshStopGate = TestAsyncGate()
        let laterRefreshStopGate = TestAsyncGate()
        let abandonedRefreshClient = MockCodexManagedAuthClient(
            label: "abandoned-refresh",
            loginStartResponse: Self.browserStartResponse,
            accountReadResponses: [Self.signedInAccount],
            stopGate: abandonedRefreshStopGate
        )
        let logoutClient = MockCodexManagedAuthClient(
            label: "logout",
            loginStartResponse: Self.browserStartResponse,
            accountReadResponses: []
        )
        let laterPayload: [String: Any] = [
            "account": ["type": "chatgpt", "email": "later-refresh@example.com"],
            "requiresOpenaiAuth": true
        ]
        let laterRefreshClient = MockCodexManagedAuthClient(
            label: "later-refresh",
            loginStartResponse: Self.browserStartResponse,
            accountReadResponses: [laterPayload],
            stopGate: laterRefreshStopGate
        )
        let unexpectedLoginClient = MockCodexManagedAuthClient(
            label: "unexpected-login",
            loginStartResponse: Self.browserStartResponse,
            accountReadResponses: [laterPayload]
        )
        let clients = ClientFactoryBox([
            abandonedRefreshClient,
            logoutClient,
            laterRefreshClient,
            unexpectedLoginClient
        ])
        let service = CodexManagedAuthRecoveryService(
            clientFactory: { clients.next() },
            cancelledWorkRetirementTimeout: 1,
            retirementSleep: { _ in }
        )

        let abandonedRefresh = Task { await service.refreshManagedAccount() }
        try await waitUntil { abandonedRefreshClient.requestCount(method: "account/read") == 1 }
        let logoutResult = await service.logoutManagedAccount()
        XCTAssertEqual(logoutResult, .signedOut)

        let laterRefresh = Task { await service.refreshManagedAccount() }
        try await waitUntil { laterRefreshClient.requestCount(method: "account/read") == 1 }
        await abandonedRefreshStopGate.open()
        _ = await abandonedRefresh.value

        let login = Task { await service.startManagedChatgptLogin { _ in } }
        await Task.yield()
        XCTAssertEqual(unexpectedLoginClient.requestCount(method: "account/login/start"), 0)

        await laterRefreshStopGate.open()
        guard case let .recovered(account?) = await laterRefresh.value else {
            return XCTFail("Expected later refresh to recover its account")
        }
        XCTAssertEqual(account.email, "later-refresh@example.com")
        guard case let .authenticated(loginAccount) = await login.value else {
            return XCTFail("Expected login to await and reuse the later refresh")
        }
        XCTAssertEqual(loginAccount.email, "later-refresh@example.com")
        XCTAssertEqual(unexpectedLoginClient.requestCount(method: "account/login/start"), 0)
    }

    func testLogoutSupersedesInFlightLoginWithoutPublishingStaleSnapshot() async throws {
        let loginStopGate = TestAsyncGate()
        let loginClient = MockCodexManagedAuthClient(
            label: "login",
            loginStartResponse: Self.deviceStartResponse,
            accountReadResponses: [Self.signedInAccount],
            stopGate: loginStopGate
        )
        let logoutClient = MockCodexManagedAuthClient(
            label: "logout",
            loginStartResponse: Self.browserStartResponse,
            accountReadResponses: []
        )
        let clients = ClientFactoryBox([loginClient, logoutClient])
        let service = CodexManagedAuthRecoveryService(
            clientFactory: { clients.next() },
            deviceCodeLoginValidationTimeout: 2,
            loginPollInterval: 0.01
        )

        let loginTask = Task {
            await service.startManagedChatgptDeviceCodeLogin { _, _ in }
        }
        try await waitUntil { loginClient.requestCount(method: "account/read") == 1 }
        let logoutTask = Task { await service.logoutManagedAccount() }
        await Task.yield()
        await Task.yield()
        await loginStopGate.open()

        let loginResult = await loginTask.value
        let logoutResult = await logoutTask.value
        guard case .failed = loginResult else {
            return XCTFail("Expected sign out to supersede the in-flight login, got \(loginResult)")
        }
        XCTAssertEqual(logoutResult, .signedOut)
        XCTAssertEqual(logoutClient.requestCount(method: "account/logout"), 1)
        let snapshot = await service.managedAccountSnapshot()
        XCTAssertNil(snapshot)
    }

    func testRealLogoutClearsSnapshotAndAwaitsClientStop() async throws {
        let stopGate = TestAsyncGate()
        let refreshClient = MockCodexManagedAuthClient(
            label: "refresh",
            loginStartResponse: Self.browserStartResponse,
            accountReadResponses: [Self.signedInAccount]
        )
        let logoutClient = MockCodexManagedAuthClient(
            label: "logout",
            loginStartResponse: Self.browserStartResponse,
            accountReadResponses: [],
            stopGate: stopGate
        )
        let clients = ClientFactoryBox([refreshClient, logoutClient])
        let service = CodexManagedAuthRecoveryService(
            clientFactory: { clients.next() },
            refreshRequestTimeout: 1
        )
        _ = await service.refreshManagedAccount()
        let signedInSnapshot = await service.managedAccountSnapshot()
        XCTAssertNotNil(signedInSnapshot)
        let completed = LockedBox<Bool>()

        let task = Task {
            let result = await service.logoutManagedAccount()
            completed.set(true)
            return result
        }
        try await waitUntil { logoutClient.requestCount(method: "account/logout") == 1 }
        XCTAssertNotEqual(completed.value, true)

        await stopGate.open()
        let logoutResult = await task.value
        XCTAssertEqual(logoutResult, .signedOut)
        XCTAssertEqual(completed.value, true)
        XCTAssertEqual(logoutClient.stopCallCount(), 1)
        let clearedSnapshot = await service.managedAccountSnapshot()
        XCTAssertNil(clearedSnapshot)
    }

    func testLogoutFailureRetainsLastConfirmedSnapshotAndReportsFailure() async {
        let accountPayload: [String: Any] = [
            "account": ["type": "chatgpt", "email": "still-signed-in@example.com"],
            "requiresOpenaiAuth": true
        ]
        let client = MockCodexManagedAuthClient(
            loginStartResponse: Self.browserStartResponse,
            accountReadResponses: [accountPayload],
            logoutError: AIProviderError.invalidResponse(detail: "logout RPC rejected")
        )
        let service = makeService(client: client, clock: TestClock(), validationTimeout: 1)
        _ = await service.refreshManagedAccount()

        let result = await service.logoutManagedAccount()

        guard case let .failed(message) = result else {
            return XCTFail("Expected logout failure, got \(result)")
        }
        XCTAssertTrue(message.contains("logout RPC rejected"))
        let retainedSnapshot = await service.managedAccountSnapshot()
        XCTAssertEqual(retainedSnapshot?.email, "still-signed-in@example.com")
        XCTAssertEqual(client.requestCount(method: "account/logout"), 1)
        XCTAssertEqual(client.stopCallCount(), 2)
    }

    func testLogoutExecutableUnavailableClearsSnapshotWithoutClaimingSuccess() async {
        let refreshClient = MockCodexManagedAuthClient(
            label: "refresh",
            loginStartResponse: Self.browserStartResponse,
            accountReadResponses: [Self.signedInAccount]
        )
        let logoutClient = MockCodexManagedAuthClient(
            label: "logout",
            loginStartResponse: Self.browserStartResponse,
            accountReadResponses: [],
            logoutError: CodexAppServerClient.ClientError.executableUnavailable("Codex executable unavailable")
        )
        let clients = ClientFactoryBox([refreshClient, logoutClient])
        let service = CodexManagedAuthRecoveryService(clientFactory: { clients.next() })
        _ = await service.refreshManagedAccount()

        let result = await service.logoutManagedAccount()

        XCTAssertEqual(result, .executableUnavailable(message: "Codex executable unavailable"))
        XCTAssertNotEqual(result, .signedOut)
        let snapshot = await service.managedAccountSnapshot()
        XCTAssertNil(snapshot)
        XCTAssertEqual(logoutClient.stopCallCount(), 1)
    }

    func testManagedAccountStringAndMirrorDoNotExposeSensitiveFields() {
        let account = CodexManagedAccount(
            email: "private@example.com",
            planType: "enterprise",
            accountType: "chatgpt",
            accountID: "secret-account-id",
            authenticationMode: "enterprise_sso"
        )
        let rendered = String(describing: account) + String(reflecting: account)
        let mirrorValues = account.customMirror.children.map { String(describing: $0.value) }.joined()

        XCTAssertFalse(rendered.contains("private@example.com"))
        XCTAssertFalse(rendered.contains("secret-account-id"))
        XCTAssertFalse(mirrorValues.contains("private@example.com"))
        XCTAssertFalse(mirrorValues.contains("secret-account-id"))
    }

    func testManagedGuidanceAdvertisesBothUISurfacesAndSeparateCredentialNamespace() {
        let guidance = CodexManagedAuthRecoveryClassifier.manualLoginGuidanceMessage

        XCTAssertTrue(guidance.contains(CodexManagedAuthRecoveryClassifier.loginActionTitle))
        XCTAssertTrue(guidance.contains(CodexManagedAuthRecoveryClassifier.deviceCodeActionTitle))
        XCTAssertTrue(guidance.contains("separate Codex sign-in"))
        XCTAssertTrue(guidance.contains("~/.codex"))
        XCTAssertFalse(guidance.localizedCaseInsensitiveContains("codex login"))
    }

    private func makeService(
        client: MockCodexManagedAuthClient,
        clock: TestClock,
        validationTimeout: TimeInterval
    ) -> CodexManagedAuthRecoveryService {
        CodexManagedAuthRecoveryService(
            clientFactory: { client },
            refreshRequestTimeout: 1,
            browserLoginValidationTimeout: validationTimeout,
            deviceCodeLoginValidationTimeout: validationTimeout,
            loginPollInterval: 1,
            now: { clock.now },
            sleep: { interval in clock.advance(by: interval) }
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: @escaping @Sendable () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(condition(), "Condition was not satisfied before timeout")
    }

    private static let browserStartResponse: [String: Any] = [
        "type": "chatgpt",
        "loginId": "browser-login",
        "authUrl": "https://auth.openai.com/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A1457%2Fauth%2Fcallback"
    ]

    private static let deviceStartResponse: [String: Any] = [
        "type": "chatgptDeviceCode",
        "loginId": "device-login",
        "userCode": "ABCD-EFGH",
        "verificationUrl": "https://auth.openai.com/codex/device"
    ]

    private static let deviceSuccessNotification = CodexAppServerClient.Notification(
        method: "account/login/completed",
        params: [
            "loginId": .string("device-login"),
            "success": .bool(true),
            "error": .null
        ]
    )

    private func assertAuthenticated(
        _ result: CodexManagedChatgptLoginResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .authenticated = result else {
            return XCTFail("Expected authenticated result, got \(result)", file: file, line: line)
        }
    }

    private static let signedOutAccount: [String: Any] = [
        "account": NSNull(),
        "requiresOpenaiAuth": true
    ]

    private static let signedInAccount: [String: Any] = [
        "account": ["type": "chatgpt"],
        "requiresOpenaiAuth": true
    ]
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 0)

    var now: Date {
        lock.withLock { date }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock {
            date = date.addingTimeInterval(interval)
        }
    }
}

private actor TestAsyncGate {
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

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Value?

    var value: Value? {
        lock.withLock { storedValue }
    }

    func set(_ value: Value) {
        lock.withLock {
            storedValue = value
        }
    }
}

private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    func record(_ event: String) {
        lock.withLock {
            events.append(event)
        }
    }

    func snapshot() -> [String] {
        lock.withLock { events }
    }
}

private final class ClientFactoryBox: @unchecked Sendable {
    private let lock = NSLock()
    private var clients: [MockCodexManagedAuthClient]

    init(_ clients: [MockCodexManagedAuthClient]) {
        self.clients = clients
    }

    var remaining: Int {
        lock.withLock { clients.count }
    }

    func next() -> MockCodexManagedAuthClient {
        lock.withLock {
            precondition(!clients.isEmpty, "Unexpected extra client creation")
            return clients.removeFirst()
        }
    }
}

private enum MockAccountReadOutcome {
    case response([String: Any])
    case failure(Error)
}

private final class MockCodexManagedAuthClient: CodexManagedAuthRPCClient, @unchecked Sendable {
    private struct RequestRecord {
        let method: String
        let loginType: String?
        let loginID: String?
        let refreshToken: Bool?
    }

    private let lock = NSLock()
    private let label: String
    private let loginStartResponse: [String: Any]
    private let unrefreshedAccountReadOutcome: MockAccountReadOutcome?
    private var accountReadOutcomes: [MockAccountReadOutcome]
    private let notificationOnLoginStart: CodexAppServerClient.Notification?
    private let notificationStream: AsyncStream<CodexAppServerClient.Notification>
    private let notificationContinuation: AsyncStream<CodexAppServerClient.Notification>.Continuation
    private let eventRecorder: (@Sendable (String) -> Void)?
    private let logoutError: Error?
    private let stopGate: TestAsyncGate?
    private var requests: [RequestRecord] = []
    private var stopCount = 0

    init(
        label: String = "client",
        loginStartResponse: [String: Any],
        accountReadResponses: [[String: Any]],
        unrefreshedAccountReadResponse: [String: Any]? = nil,
        notificationOnLoginStart: CodexAppServerClient.Notification? = nil,
        eventRecorder: (@Sendable (String) -> Void)? = nil,
        logoutError: Error? = nil,
        stopGate: TestAsyncGate? = nil
    ) {
        self.label = label
        self.loginStartResponse = loginStartResponse
        unrefreshedAccountReadOutcome = unrefreshedAccountReadResponse.map(MockAccountReadOutcome.response)
        accountReadOutcomes = accountReadResponses.map(MockAccountReadOutcome.response)
        self.notificationOnLoginStart = notificationOnLoginStart
        self.eventRecorder = eventRecorder
        self.logoutError = logoutError
        self.stopGate = stopGate
        var continuation: AsyncStream<CodexAppServerClient.Notification>.Continuation!
        notificationStream = AsyncStream { continuation = $0 }
        notificationContinuation = continuation
    }

    init(
        label: String = "client",
        loginStartResponse: [String: Any],
        accountReadOutcomes: [MockAccountReadOutcome],
        notificationOnLoginStart: CodexAppServerClient.Notification? = nil,
        eventRecorder: (@Sendable (String) -> Void)? = nil,
        logoutError: Error? = nil,
        stopGate: TestAsyncGate? = nil
    ) {
        self.label = label
        self.loginStartResponse = loginStartResponse
        unrefreshedAccountReadOutcome = nil
        self.accountReadOutcomes = accountReadOutcomes
        self.notificationOnLoginStart = notificationOnLoginStart
        self.eventRecorder = eventRecorder
        self.logoutError = logoutError
        self.stopGate = stopGate
        var continuation: AsyncStream<CodexAppServerClient.Notification>.Continuation!
        notificationStream = AsyncStream { continuation = $0 }
        notificationContinuation = continuation
    }

    func updateDefaultRequestTimeout(_: TimeInterval?) async {}

    func startIfNeeded() async throws {}

    func stop() async {
        await stopGate?.wait()
        lock.withLock {
            stopCount += 1
        }
        notificationContinuation.finish()
        eventRecorder?("\(label).stop")
    }

    func request(
        method: String,
        params: [String: Any]?,
        timeout _: TimeInterval?
    ) async throws -> [String: Any] {
        let loginType = params?["type"] as? String
        let loginID = params?["loginId"] as? String
        let refreshToken = params?["refreshToken"] as? Bool
        lock.withLock {
            requests.append(RequestRecord(
                method: method,
                loginType: loginType,
                loginID: loginID,
                refreshToken: refreshToken
            ))
        }
        eventRecorder?("\(label).\(method)")

        switch method {
        case "account/login/start":
            if let notificationOnLoginStart {
                notificationContinuation.yield(notificationOnLoginStart)
            }
            return loginStartResponse
        case "account/read":
            let outcome = lock.withLock {
                if refreshToken == false, let unrefreshedAccountReadOutcome {
                    return unrefreshedAccountReadOutcome
                }
                guard accountReadOutcomes.count > 1 else {
                    return accountReadOutcomes.first ?? .response([
                        "account": NSNull(),
                        "requiresOpenaiAuth": true
                    ])
                }
                return accountReadOutcomes.removeFirst()
            }
            switch outcome {
            case let .response(response):
                return response
            case let .failure(error):
                throw error
            }
        case "account/login/cancel":
            return ["status": "canceled"]
        case "account/logout":
            if let logoutError {
                throw logoutError
            }
            return [:]
        default:
            XCTFail("Unexpected mock request: \(method)")
            return [:]
        }
    }

    func subscribeNotifications() async -> AsyncStream<CodexAppServerClient.Notification> {
        notificationStream
    }

    func requestCount(method: String) -> Int {
        lock.withLock {
            requests.count(where: { $0.method == method })
        }
    }

    func stopCallCount() -> Int {
        lock.withLock { stopCount }
    }

    func lastLoginType() -> String? {
        lock.withLock {
            requests.last(where: { $0.method == "account/login/start" })?.loginType
        }
    }

    func lastLoginID(for method: String) -> String? {
        lock.withLock {
            requests.last(where: { $0.method == method })?.loginID
        }
    }

    func accountReadRefreshFlags() -> [Bool] {
        lock.withLock {
            requests.compactMap { record in
                record.method == "account/read" ? record.refreshToken : nil
            }
        }
    }
}
