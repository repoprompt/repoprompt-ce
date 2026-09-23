import Foundation
@testable import RepoPromptApp
import XCTest

final class CodexExecAgentProviderRuntimePreparationTests: XCTestCase {
    func testPromptExperimentConstraintsPinModelEffortCwdAndNativeToolRestrictions() {
        let root = "/tmp/prompt-experiment-synthetic-root"
        let constraints = CodexExecRunConstraints.promptExperiment(workingDirectory: root)
        let command = CodexExecAgentProvider.buildCodexExecArguments(
            selectedModelString: "gpt-5.6-sol-ultra",
            serverEntries: [],
            brokenServers: [],
            fullAccess: true,
            runConstraints: constraints
        )

        XCTAssertEqual(command.modelSpecifier.baseModel, "gpt-5.6-sol")
        XCTAssertEqual(command.modelSpecifier.reasoningEffort, .ultra)
        XCTAssertTrue(command.args.contains("--model"))
        XCTAssertTrue(command.args.contains("gpt-5.6-sol"))
        XCTAssertTrue(command.args.contains("model_reasoning_effort=ultra"))
        XCTAssertTrue(command.args.contains("features.shell_tool=false"))
        XCTAssertTrue(command.args.contains("features.unified_exec=false"))
        XCTAssertTrue(command.args.contains("web_search=disabled"))
        XCTAssertTrue(command.args.contains("features.multi_agent=false"))
        XCTAssertTrue(command.args.contains("workspace-write"))
        XCTAssertFalse(command.args.contains("--dangerously-bypass-approvals-and-sandbox"))
        XCTAssertFalse(CodexExecAgentProvider.allowsModelFallback(runConstraints: constraints))

        let resolution = CodexProviderHelpers.CodexExecutableResolution(
            commandName: "codex",
            resolvedCommand: "/usr/bin/codex",
            status: .available,
            runtime: nil,
            userMessage: "",
            debugMessage: ""
        )
        let process = CodexExecAgentProvider.processConfiguration(
            for: resolution,
            enableDebugLogging: false,
            workingDirectory: constraints.workingDirectory
        )
        XCTAssertEqual(process.workingDirectory, root)
    }

    func testDefaultCodexExecBehaviorStillAllowsConfiguredFullAccessAndFallback() {
        let command = CodexExecAgentProvider.buildCodexExecArguments(
            selectedModelString: "gpt-5.6-sol-ultra",
            serverEntries: [],
            brokenServers: [],
            fullAccess: true
        )
        XCTAssertTrue(command.args.contains("--dangerously-bypass-approvals-and-sandbox"))
        XCTAssertFalse(command.args.contains("web_search=disabled"))
        XCTAssertTrue(CodexExecAgentProvider.allowsModelFallback(runConstraints: nil))
    }

    func testPrepareUsesRuntimeStateAuthorityAndMapsFailureBeforeMCPBootstrap() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexExecAgentProviderRuntimePreparationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("codex")
        try "#!/bin/sh\necho 'codex 0.156.0'\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let recorder = PreparedRuntimeRecorder()
        let provider = CodexExecAgentProvider(
            config: .init(commandName: executable.path, additionalPathHints: []),
            runtimeStatePreparer: { runtime in
                recorder.record(runtime)
                throw RuntimePreparationFailure.conflict
            }
        )

        do {
            _ = try await provider.prepare()
            XCTFail("prepare must fail when isolated Codex state preparation fails")
        } catch let AIProviderError.invalidConfiguration(detail) {
            XCTAssertTrue(detail.contains("unable to prepare its isolated Codex state"))
            XCTAssertTrue(detail.contains("projection conflict"))
        } catch {
            XCTFail("Expected invalidConfiguration, got \(error)")
        }

        XCTAssertEqual(recorder.callCount, 1)
        XCTAssertEqual(recorder.runtime?.source, .externalOverride)
        XCTAssertEqual(recorder.runtime?.executableURL, executable)
    }
}

private enum RuntimePreparationFailure: Error, LocalizedError {
    case conflict

    var errorDescription: String? {
        "projection conflict"
    }
}

private final class PreparedRuntimeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedRuntime: CodexRuntimeAuthority.Runtime?
    private var recordedCallCount = 0

    func record(_ runtime: CodexRuntimeAuthority.Runtime) {
        lock.lock()
        recordedRuntime = runtime
        recordedCallCount += 1
        lock.unlock()
    }

    var runtime: CodexRuntimeAuthority.Runtime? {
        lock.lock()
        defer { lock.unlock() }
        return recordedRuntime
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedCallCount
    }
}
