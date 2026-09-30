import Foundation
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

final class CodexFigmaMCPCredentialLogoutExecutorTests: XCTestCase {
    func testUsesFixedCommandAndStrictlyAllowlistedEnvironment() async throws {
        let home = URL(fileURLWithPath: "/tmp/figma-logout-home")
        let sqlite = URL(fileURLWithPath: "/tmp/figma-logout-sqlite")
        let executable = "/tmp/codex-test"
        let runtime = CodexRuntimeAuthority.Runtime(executableURL: URL(fileURLWithPath: executable), version: CodexRuntimeAuthority.bundledVersion, source: .externalOverride, statePaths: .init(codexHome: home, sqliteHome: sqlite))
        let resolution = CodexProviderHelpers.CodexExecutableResolution(commandName: "codex", resolvedCommand: executable, status: .available, runtime: runtime, userMessage: "", debugMessage: "")
        let request = LockedValue<ProcessEnvironmentRequest?>(nil)
        let resolvedEnvironment = LockedValue<[String: String]?>(nil)
        let invocation = LockedValue<CodexFigmaMCPCredentialLogoutExecutor.ProcessInvocation?>(nil)
        let executor = CodexFigmaMCPCredentialLogoutExecutor(
            inheritedEnvironment: [
                "PATH": "/inherited/bin",
                "HOME": "/inherited-home",
                "TMPDIR": "/inherited-tmp",
                "LANG": "en_US.UTF-8",
                "LC_ALL": "en_US.UTF-8",
                "LC_CTYPE": "UTF-8",
                "TERM": "xterm-256color",
                "CODEX_HOME": "/wrong",
                "CODEX_SQLITE_HOME": "/wrong-sqlite",
                "OPENAI_API_KEY": "redacted-test-value",
                "FIGMA_ACCESS_TOKEN": "redacted-test-value",
                "GITHUB_TOKEN": "redacted-test-value",
                "GH_TOKEN": "redacted-test-value",
                "FIGMA_PERSONAL_ACCESS_TOKEN": "redacted-test-value",
                "FIGMA_PAT": "redacted-test-value",
                "GITHUB_PAT": "redacted-test-value",
                "FIGMA_PATROL": "keep-test-value",
                "INNOCUOUS_RUNTIME_FLAG": "keep-test-value"
            ],
            environmentBuilder: { value in
                request.set(value)
                return .init(
                    environment: [
                        "PATH": "/shell/bin",
                        "HOME": "/shell-home",
                        "TMPDIR": "/shell-tmp",
                        "LANG": "en_GB.UTF-8",
                        "LC_ALL": "en_GB.UTF-8",
                        "LC_CTYPE": "UTF-8",
                        "TERM": "xterm-256color",
                        "CODEX_HOME": "/shell",
                        "CODEX_SQLITE_HOME": "/shell-sqlite",
                        "OPENAI_API_KEY": "redacted-test-value",
                        "FIGMA_ACCESS_TOKEN": "redacted-test-value",
                        "GITHUB_TOKEN": "redacted-test-value",
                        "GH_TOKEN": "redacted-test-value",
                        "FIGMA_PERSONAL_ACCESS_TOKEN": "redacted-test-value",
                        "FIGMA_PAT": "redacted-test-value",
                        "GITHUB_PAT": "redacted-test-value",
                        "FIGMA_PATROL": "keep-test-value",
                        "INNOCUOUS_RUNTIME_FLAG": "keep-test-value"
                    ],
                    launchContext: .detect(from: [:]),
                    shellEnvironmentSource: .capturedLoginShell
                )
            },
            runtimeResolver: { value in
                resolvedEnvironment.set(value)
                return resolution
            },
            runtimePreparer: { _ in },
            processRunner: { value in
                invocation.set(value)
                return .init(status: 0, timedOut: false)
            }
        )
        await assertOutcome(executor, equals: .credentialAbsent)
        XCTAssertEqual(request.value?.purpose, .codexCredentialLogout)
        let resolvedEnvironmentKeys: Set<String> = resolvedEnvironment.value.map { Set($0.keys) } ?? []
        XCTAssertEqual(
            resolvedEnvironmentKeys,
            Set(["PATH", "HOME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE"])
        )
        let call = try XCTUnwrap(invocation.value)
        XCTAssertEqual(
            Set(call.configuration.environment.keys),
            Set(["PATH", "HOME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "CODEX_HOME", "CODEX_SQLITE_HOME"])
        )
        XCTAssertEqual(call.arguments, ["mcp", "logout", "figma"])
        XCTAssertEqual(call.configuration.command, executable)
        XCTAssertEqual(call.configuration.environment["CODEX_HOME"], home.path)
        XCTAssertEqual(call.configuration.environment["CODEX_SQLITE_HOME"], sqlite.path)
        XCTAssertNil(resolvedEnvironment.value?["CODEX_HOME"])
        XCTAssertNil(resolvedEnvironment.value?["CODEX_SQLITE_HOME"])
        XCTAssertNil(resolvedEnvironment.value?["OPENAI_API_KEY"])
        XCTAssertNil(resolvedEnvironment.value?["FIGMA_ACCESS_TOKEN"])
        XCTAssertNil(resolvedEnvironment.value?["FIGMA_PATROL"])
        XCTAssertNil(resolvedEnvironment.value?["INNOCUOUS_RUNTIME_FLAG"])
        XCTAssertNil(call.configuration.environment["OPENAI_API_KEY"])
        XCTAssertNil(call.configuration.environment["FIGMA_ACCESS_TOKEN"])
        XCTAssertNil(call.configuration.environment["GITHUB_TOKEN"])
        XCTAssertNil(call.configuration.environment["GH_TOKEN"])
        XCTAssertNil(call.configuration.environment["FIGMA_PERSONAL_ACCESS_TOKEN"])
        XCTAssertNil(call.configuration.environment["FIGMA_PAT"])
        XCTAssertNil(call.configuration.environment["GITHUB_PAT"])
        XCTAssertNil(call.configuration.environment["FIGMA_PATROL"])
        XCTAssertNil(call.configuration.environment["INNOCUOUS_RUNTIME_FLAG"])
        XCTAssertTrue(call.additionalRemovedKeys.isSuperset(of: [
            "TERM", "OPENAI_API_KEY", "FIGMA_ACCESS_TOKEN", "GITHUB_TOKEN", "GH_TOKEN",
            "FIGMA_PERSONAL_ACCESS_TOKEN", "FIGMA_PAT", "GITHUB_PAT", "FIGMA_PATROL", "INNOCUOUS_RUNTIME_FLAG"
        ]))
        XCTAssertEqual(call.configuration.captureStdoutTailBytes, 0)
        XCTAssertEqual(call.configuration.captureStderrTailBytes, 0)
        XCTAssertEqual(call.configuration.logStdinSampleBytes, 0)
        XCTAssertFalse(call.configuration.enableDebugLogging)
        XCTAssertNil(call.configuration.logCollector)
        XCTAssertEqual(call.timeout, 30)
        XCTAssertTrue(call.cancelChildOnTaskCancellation)
    }

    func testCredentialLogoutUsesLoginShellEnvironmentForTerminalLaunch() async {
        let providerCalled = LockedValue(false)
        let result = await ProcessEnvironmentBuilder.build(
            ProcessEnvironmentRequest(
                purpose: .codexCredentialLogout,
                inheritedEnvironment: [
                    "PATH": "/inherited/bin:/usr/bin",
                    "TERM": "xterm-256color"
                ]
            ),
            shellEnvironmentProvider: { _, _ in
                providerCalled.set(true)
                return .init(
                    environment: ["PATH": "/login-shell/bin"],
                    source: .capturedLoginShell
                )
            }
        )

        XCTAssertTrue(providerCalled.value)
        XCTAssertEqual(result.shellEnvironmentSource, .capturedLoginShell)
        XCTAssertEqual(result.environment["PATH"], "/login-shell/bin:/inherited/bin:/usr/bin")
    }

    func testMapsExitAndProcessLifecycleOutcomesFailClosed() async {
        let success = makeExecutor { _ in .init(status: 0, timedOut: false) }
        await assertOutcome(success, equals: .credentialAbsent)
        let failure = makeExecutor { _ in .init(status: 9, timedOut: false) }
        await assertOutcome(failure, equals: .failed)
        let timeout = makeExecutor { _ in .init(status: 0, timedOut: true) }
        await assertOutcome(timeout, equals: .indeterminate)
        let cancelledBeforeLaunch = makeExecutor { _ in throw CancellationError() }
        await assertOutcome(cancelledBeforeLaunch, equals: .cancelledBeforeLaunch)
        let cancelledAfterLaunch = makeExecutor { invocation in
            invocation.onProcessStarted?()
            throw CancellationError()
        }
        await assertOutcome(cancelledAfterLaunch, equals: .indeterminate)
    }

    func testPreLaunchCancellationAndResolutionFailureDoNotLaunch() async {
        let cancelled = makeExecutor { _ in
            XCTFail("must not launch after pre-launch cancellation")
            return .init(status: 0, timedOut: false)
        }
        let task = Task { await cancelled.logoutFigmaCredential() }
        task.cancel()
        let cancelledOutcome = await task.value
        XCTAssertEqual(cancelledOutcome, .cancelledBeforeLaunch)
        let unavailable = CodexFigmaMCPCredentialLogoutExecutor(
            runtimeResolver: { _ in .init(commandName: "codex", resolvedCommand: "", status: .bundledRuntimeUnavailable, runtime: nil, userMessage: "", debugMessage: "") },
            processRunner: { _ in
                XCTFail("unavailable runtime must not launch")
                return .init(status: 0, timedOut: false)
            }
        )
        await assertOutcome(unavailable, equals: .failed)
    }

    private func assertOutcome(_ executor: CodexFigmaMCPCredentialLogoutExecutor, equals expected: FigmaMCPCredentialLogoutOutcome) async {
        let actual = await executor.logoutFigmaCredential()
        XCTAssertEqual(actual, expected)
    }

    private func makeExecutor(processRunner: @escaping CodexFigmaMCPCredentialLogoutExecutor.ProcessRunner) -> CodexFigmaMCPCredentialLogoutExecutor {
        let runtime = CodexRuntimeAuthority.Runtime(executableURL: URL(fileURLWithPath: "/tmp/codex"), version: CodexRuntimeAuthority.bundledVersion, source: .bundled(target: "test"), statePaths: .init(codexHome: URL(fileURLWithPath: "/tmp/home"), sqliteHome: URL(fileURLWithPath: "/tmp/sqlite")))
        let resolution = CodexProviderHelpers.CodexExecutableResolution(commandName: "codex", resolvedCommand: runtime.executableURL.path, status: .available, runtime: runtime, userMessage: "", debugMessage: "")
        return CodexFigmaMCPCredentialLogoutExecutor(
            environmentBuilder: { request in .init(environment: request.inheritedEnvironment, launchContext: .detect(from: request.inheritedEnvironment), shellEnvironmentSource: .capturedLoginShell) },
            runtimeResolver: { _ in resolution },
            processRunner: processRunner
        )
    }
}

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        lock.withLock { storage }
    }

    func set(_ value: Value) {
        lock.withLock { storage = value }
    }
}
