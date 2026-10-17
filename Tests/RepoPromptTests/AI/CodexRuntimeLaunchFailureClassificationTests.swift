import Foundation
import os
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

final class CodexCLIProviderErrorMappingTests: XCTestCase {
    @MainActor
    func testTypedInputTooLargeWinsOver429And503WithoutRecoveryOrFallback() async throws {
        for diagnostic in ["429", "503"] {
            let failure = inputFailure(message: "Input too large: \(diagnostic); account/chatgptAuthTokens/refresh; model_not_found gpt-5.3-codex; MCP client for `fixture-server` failed to start; timeout")
            for collecting in [false, true] {
                let controller = FailureController(error: CodexAppServerClient.ClientError.requestFailed(failure))
                let auth = AuthRecoveryRecorder()
                let provider = makeProvider(controller: controller, auth: auth, maxRetries: 2)
                do {
                    try await invoke(provider, collecting: collecting)
                    XCTFail("Expected input rejection")
                } catch {
                    try assertInputFailure(error, equals: failure)
                }
                XCTAssertEqual(controller.factoryCalls, 1)
                XCTAssertEqual(controller.attempts, 1)
                XCTAssertEqual(controller.shutdowns, 1)
                XCTAssertEqual(controller.models.count, 1)
                if !collecting { XCTAssertEqual(controller.models.first ?? nil, "gpt-5.3-codex") }
                let recoveries = await auth.refreshCalls
                XCTAssertEqual(recoveries, 0)
            }
        }
    }

    @MainActor
    func testTypedInputTooLargeBeforeDispatchSkipsManagedAuthRecovery() async throws {
        let failure = inputFailure(message: "429; account/chatgptAuthTokens/refresh; 503")
        let controller = FailureController(error: CodexAppServerClient.ClientError.invalidResponse)
        let auth = AuthRecoveryRecorder()
        let provider = makeProvider(controller: controller, auth: auth, readyFailure: CodexAppServerClient.ClientError.requestFailed(failure))
        do {
            try await invoke(provider, collecting: false)
            XCTFail("Expected input rejection before controller dispatch")
        } catch {
            try assertInputFailure(error, equals: failure)
        }
        XCTAssertEqual(controller.factoryCalls, 1)
        XCTAssertEqual(controller.attempts, 0)
        let recoveries = await auth.refreshCalls
        XCTAssertEqual(recoveries, 0)
    }

    @MainActor
    func testOrdinary429And503FailuresKeepExistingMappings() async throws {
        for (message, expected) in [("429", "Codex CLI rate limited"), ("503", "Codex servers look overloaded")] {
            let errors: [Error] = [
                NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: message]),
                CodexAppServerClient.ClientError.requestFailed(.init(method: "turn/start", code: -32602, message: message, data: .object(["input_error_code": .string("other")])))
            ]
            for error in errors {
                for collecting in [false, true] {
                    let controller = FailureController(error: error)
                    let auth = AuthRecoveryRecorder()
                    do {
                        try await invoke(makeProvider(controller: controller, auth: auth), collecting: collecting)
                        XCTFail("Expected ordinary failure")
                    } catch let AIProviderError.invalidConfiguration(detail) {
                        XCTAssertTrue(detail.hasPrefix(expected), detail)
                    } catch {
                        XCTFail("Unexpected mapping: \(error)")
                    }
                    XCTAssertEqual(controller.attempts, 1)
                }
            }
        }
    }

    @MainActor
    func testCancellationPropagatesOnCompletionAndCollectingPaths() async throws {
        for collecting in [false, true] {
            let controller = FailureController(error: CancellationError())
            let auth = AuthRecoveryRecorder()
            do {
                try await invoke(makeProvider(controller: controller, auth: auth), collecting: collecting)
                XCTFail("Expected cancellation")
            } catch is CancellationError {
            } catch {
                XCTFail("Cancellation was remapped: \(error)")
            }
            XCTAssertEqual(controller.attempts, 1)
            let recoveries = await auth.refreshCalls
            XCTAssertEqual(recoveries, 0)
        }
    }

    func testWrappedInputRejectionFriendlyStringKeepsReductionGuidance() {
        let wrapped = AIProviderError.apiError(source: CodexAppServerClient.ClientError.requestFailed(inputFailure(message: "Input exceeds the maximum length of 1048576 characters.")))
        XCTAssertTrue(wrapped.asFriendlyString().contains("Reduce the selected context"))
    }

    private func inputFailure(message: String) -> CodexAppServerClient.RequestFailure {
        .init(method: "turn/start", code: -32602, message: message, data: .object([
            "input_error_code": .string("input_too_large"), "max_chars": .number(1_048_576), "actual_chars": .number(1_050_429)
        ]))
    }

    private func assertInputFailure(_ error: Error, equals expected: CodexAppServerClient.RequestFailure) throws {
        guard case let AIProviderError.apiError(source) = error,
              case let CodexAppServerClient.ClientError.requestFailed(failure) = try XCTUnwrap(source)
        else { return XCTFail("Lost typed input rejection: \(error)") }
        XCTAssertEqual(failure, expected)
        XCTAssertTrue(failure.isInputTooLarge)
    }

    @MainActor
    private func invoke(_ provider: CodexCLIProvider, collecting: Bool) async throws {
        if collecting {
            _ = try await provider.testConnection()
        } else {
            _ = try await provider.completeMessage(AIMessage(systemPrompt: "", userMessage: "fixture"), model: .codexCliGpt5CodexMedium)
        }
    }

    private func makeProvider(controller: FailureController, auth: AuthRecoveryRecorder, maxRetries: Int = 0, readyFailure: Error? = nil) -> CodexCLIProvider {
        let readyHook: (() async throws -> Void)? = readyFailure.map { error in
            { () async throws in throw error }
        }
        return CodexCLIProvider(
            launchSnapshot: .init(selection: .external(path: "/nonexistent/codex-error-mapping-fixture")),
            maxRetries: maxRetries,
            appServerReadyHook: readyHook,
            authRecovery: auth,
            sessionControllerFactory: { _, _ in controller.recordFactoryCall()
                return controller
            }
        )
    }

    private actor AuthRecoveryRecorder: CodexManagedAuthRecovering {
        private(set) var refreshCalls = 0
        func refreshManagedAccount() async -> CodexManagedAuthRefreshResult {
            refreshCalls += 1
            return .recovered(account: nil)
        }

        func managedAccountSnapshot() async -> CodexManagedAccount? {
            nil
        }

        func startManagedChatgptLogin(openURL: @MainActor @escaping @Sendable (URL) -> Void) async -> CodexManagedChatgptLoginResult {
            .failed(message: "unused")
        }

        func startManagedChatgptDeviceCodeLogin(presentDeviceCode: @MainActor @escaping @Sendable (CodexManagedChatgptDeviceCode, Bool) -> Void) async -> CodexManagedChatgptLoginResult {
            .failed(message: "unused")
        }

        func logoutManagedAccount() async -> CodexManagedAuthLogoutResult {
            .signedOut
        }
    }

    private final class FailureController: CodexSessionControlling {
        private struct State {
            var factoryCalls = 0
            var attempts = 0
            var shutdowns = 0
            var models: [String?] = []
        }

        private let state = OSAllocatedUnfairLock(initialState: State())
        private let error: Error
        init(error: Error) {
            self.error = error
        }

        var factoryCalls: Int {
            state.withLock { $0.factoryCalls }
        }

        var attempts: Int {
            state.withLock { $0.attempts }
        }

        var shutdowns: Int {
            state.withLock { $0.shutdowns }
        }

        var models: [String?] {
            state.withLock { $0.models }
        }

        func recordFactoryCall() {
            state.withLock { $0.factoryCalls += 1 }
        }

        var hasActiveThread: Bool {
            true
        }

        var events: AsyncStream<CodexNativeSessionController.Event> {
            AsyncStream { $0.finish() }
        }

        func ensureEventsStreamReady() {}
        func startOrResume(existing: CodexNativeSessionController.SessionRef?, baseInstructions: String) async throws -> CodexNativeSessionController.SessionRef {
            .init(conversationID: "fixture", rolloutPath: nil, model: nil, reasoningEffort: nil)
        }

        func startOrResume(existing: CodexNativeSessionController.SessionRef?, baseInstructions: String, model: String?, reasoningEffort: String?) async throws -> CodexNativeSessionController.SessionRef {
            try await startOrResume(existing: existing, baseInstructions: baseInstructions)
        }

        func startOrResume(existing: CodexNativeSessionController.SessionRef?, baseInstructions: String, model: String?, reasoningEffort: String?, serviceTier: String?) async throws -> CodexNativeSessionController.SessionRef {
            try await startOrResume(existing: existing, baseInstructions: baseInstructions)
        }

        func startUserTurn(text: String, images: [AgentImageAttachment], model: String?, reasoningEffort: String?, serviceTier: String?) async throws -> CodexTurnStartReceipt {
            state.withLock { $0.attempts += 1
                $0.models.append(model)
            }
            throw error
        }

        func steerUserTurn(text: String, images: [AgentImageAttachment], expectedTurnID: String) async throws -> CodexTurnSteerReceipt {
            throw error
        }

        func readThreadSnapshot(includeTurns: Bool, timeout: TimeInterval?) async throws -> CodexNativeSessionController.ThreadSnapshot {
            throw error
        }

        func setThreadName(_ name: String, threadID: String?) async throws {}
        func prepareLifecycleAuthorityReconciliationAfterAcceptedMismatch(expectedCurrentTurnID: String, acceptedDispatchTurnID: String) async -> Bool {
            false
        }

        func interruptUserTurn(expectedTurnID: String) async throws -> CodexTurnInterruptReceipt {
            throw error
        }

        func reconcileAndInterruptCurrentTurn() async throws -> CodexTurnInterruptReceipt {
            throw error
        }

        func compactThread() async throws {}
        func getThreadGoal() async throws -> CodexNativeSessionController.ThreadGoal? {
            nil
        }

        func setThreadGoalObjective(_ objective: String) async throws -> CodexNativeSessionController.ThreadGoal {
            throw error
        }

        func setThreadGoalStatus(_ status: CodexNativeSessionController.ThreadGoalStatus) async throws -> CodexNativeSessionController.ThreadGoal {
            throw error
        }

        func clearThreadGoal() async throws -> Bool {
            false
        }

        func pendingTurnFailure(turnID: String?) async -> CodexNativeSessionController.TurnFailure? {
            nil
        }

        func acknowledgePendingTurnFailure(turnID: String?, failure: CodexNativeSessionController.TurnFailure) async {}
        func cancelCurrentTurn() async {}
        func shutdown() async {
            state.withLock { $0.shutdowns += 1 }
        }

        func respondToServerRequest(id: CodexAppServerRequestID, result: [String: Any]) async {}
    }
}

final class CodexRuntimeLaunchFailureClassificationTests: XCTestCase {
    func testSentinelClassifierAcceptsPrefixedMessagesAndRejectsRewrittenGuidance() {
        XCTAssertTrue(
            CodexProviderHelpers.isCodexExecutableUnavailableMessage(
                "RepoPrompt could not start Codex: the bundled package is missing. Reinstall RepoPrompt CE."
            )
        )
        XCTAssertTrue(
            CodexProviderHelpers.isCodexExecutableUnavailableMessage(
                "\n  RepoPrompt could not start Codex: leading whitespace is tolerated."
            )
        )
        XCTAssertFalse(
            CodexProviderHelpers.isCodexExecutableUnavailableMessage(
                "The selected Codex runtime could not be started. Reinstall RepoPrompt CE or configure a valid explicit override."
            )
        )
        XCTAssertFalse(
            CodexProviderHelpers.isCodexExecutableUnavailableMessage(
                "Permission denied. Ensure the 'codex' executable is accessible."
            )
        )
        XCTAssertFalse(
            CodexProviderHelpers.isCodexExecutableUnavailableMessage(
                "Codex is unavailable because RepoPrompt could not start Codex: (prefix must lead the message)"
            )
        )
    }
}
