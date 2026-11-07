import Foundation
import RepoPromptAgentProviderContracts
import RepoPromptAIContracts
import RepoPromptClaudeProvider
import RepoPromptDomainRuntime
import RepoPromptProcess
import XCTest

private actor ClaudeCLIUnusedConfig: ClaudeCLIConfigPreparing {
    func prepareClaudeEmptyLaunchConfig() throws -> any ClaudeCLIConfigLease {
        throw CancellationError()
    }
}

private struct ClaudeCLITestLease: ClaudeCLIConfigLease {
    let url: URL

    func release() {
        try? FileManager.default.removeItem(at: url)
    }
}

private actor ClaudeCLITestConfig: ClaudeCLIConfigPreparing {
    let directory: URL
    private(set) var lastURL: URL?

    init(directory: URL) {
        self.directory = directory
    }

    func prepareClaudeEmptyLaunchConfig() throws -> any ClaudeCLIConfigLease {
        let url = directory.appendingPathComponent(UUID().uuidString + ".json")
        try Data(#"{"mcpServers":{}}"#.utf8).write(to: url)
        lastURL = url
        return ClaudeCLITestLease(url: url)
    }
}

private struct ClaudeCLIUnusedResolver: ClaudeCodeLaunchEnvironmentResolving {
    func resolve(variant _: ClaudeCodeRuntimeVariant, requestedModel _: String?) async throws -> ClaudeCompatiblePluginLaunchEnvironment {
        throw CancellationError()
    }
}

final class ClaudeCodeProviderOwnerTests: XCTestCase {
    private func provider() -> ClaudeCodeProvider {
        ClaudeCodeProvider(
            composedRunner: CLIProcessRunner(config: CLIProcessConfiguration(command: "/usr/bin/false")),
            configService: ClaudeCLIUnusedConfig(),
            resolveModelSelection: { _ in throw AIProviderError.invalidModel },
            environmentFilter: { _ in { environment, _ in environment } },
            currentPromptDelivery: { ClaudeCLIPromptDelivery(sendsRepoPromptAsUserMessage: { false }, nativeSystemPromptOverride: { _ in nil }) },
            decorateUserMessage: { prompt, _ in prompt },
            compatibleDescriptor: { _ in nil },
            makeLaunchResolver: { ClaudeCLIUnusedResolver() },
            defaultRequestTimeout: 6000,
            testRequestTimeout: 30,
            maxRetries: 2,
            livenessHeartbeatInterval: 1
        )
    }

    func testRequiredInputsDriveRealProcessAndReleaseItsConfig() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("claude-owner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let argsURL = directory.appendingPathComponent("args")
        let stdinURL = directory.appendingPathComponent("stdin")
        let script = #"""
        printf '%s\n' "$*" > "$1"
        cat > "$2"
        printf '%s\n' '{"type":"result","subtype":"success","result":"owner answer"}'
        """#
        let runner = CLIProcessRunner(config: CLIProcessConfiguration(
            command: "/usr/bin/env", allowsProviderProcessLaunchForTesting: true,
            workingDirectory: directory.path, additionalPaths: [],
            commandSuffix: ["-i", "/bin/sh", "-c", script, "owner-fixture", argsURL.path, stdinURL.path],
            shellLookupMode: .disabled
        ))
        let config = ClaudeCLITestConfig(directory: directory)
        let subject = ClaudeCodeProvider(
            composedRunner: runner, configService: config,
            resolveModelSelection: { _ in ClaudeCodeCLIModelSelection(modelArgument: "owner-model", effortLevel: nil) },
            environmentFilter: { _ in { environment, _ in environment } },
            currentPromptDelivery: { ClaudeCLIPromptDelivery(sendsRepoPromptAsUserMessage: { true }, nativeSystemPromptOverride: { _ in "owner-system" }) },
            decorateUserMessage: { prompt, _ in "owner-decoration:\(prompt)" },
            compatibleDescriptor: { _ in nil }, makeLaunchResolver: { ClaudeCLIUnusedResolver() },
            defaultRequestTimeout: 30, testRequestTimeout: 30, maxRetries: 0, livenessHeartbeatInterval: 1
        )
        let completion = try await subject.completeMessage(AIMessage(systemPrompt: "instructions", userMessage: "hello"), model: .claudeCode)
        XCTAssertEqual(completion.text, "owner answer")
        let args = try String(contentsOf: argsURL, encoding: .utf8)
        XCTAssertTrue(args.contains("--model owner-model"))
        XCTAssertTrue(args.contains("--system-prompt owner-system"))
        XCTAssertTrue(args.contains("--strict-mcp-config"))
        XCTAssertTrue(try String(contentsOf: stdinURL, encoding: .utf8).hasPrefix("owner-decoration:"))
        let recordedURL = await config.lastURL
        let leasedURL = try XCTUnwrap(recordedURL)
        XCTAssertTrue(args.contains(leasedURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: leasedURL.path))
    }

    func testClaudeStreamJSONEncodesTransientImages() throws {
        let line = try ClaudeCodeProvider.makeStreamJSONInput(
            prompt: "Inspect",
            attachments: [.init(payload: .image(.png, Data([1, 2, 3])), fileName: "image.png", title: "Diagram")]
        )
        XCTAssertTrue(line.hasSuffix("\n"))
        let data = try XCTUnwrap(line.dropLast().data(using: .utf8))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let message = try XCTUnwrap(payload["message"] as? [String: Any])
        let content = try XCTUnwrap(message["content"] as? [[String: Any]])
        let image = try XCTUnwrap(content.last)
        let source = try XCTUnwrap(image["source"] as? [String: Any])

        XCTAssertEqual(payload["type"] as? String, "user")
        XCTAssertEqual(image["type"] as? String, "image")
        XCTAssertEqual(source["type"] as? String, "base64")
        XCTAssertEqual(source["media_type"] as? String, "image/png")
        XCTAssertEqual(source["data"] as? String, "AQID")

        var options = ClaudeCLIOptions()
        XCTAssertFalse(options.toTokens().contains("--input-format"))
        ClaudeCodeProvider.applyStreamJSONImageTransport(to: &options)
        let tokens = options.toTokens()
        XCTAssertTrue(tokens.contains("--input-format"))
        XCTAssertTrue(tokens.contains("stream-json"))
        XCTAssertTrue(tokens.contains("--verbose"))
        XCTAssertTrue(tokens.contains("-p"))
    }

    func testClaudeStreamJSONParsesTerminalResultAndUsage() throws {
        let output = """
        {"type":"system","subtype":"init"}
        {"type":"assistant","message":{"content":[{"type":"text","text":"Done"}]}}
        {"type":"result","subtype":"success","is_error":false,"result":"Done","usage":{"input_tokens":11,"output_tokens":7},"total_cost_usd":0.12}
        """
        let completion = try provider().parseStreamJSONCompletionPayload(Data(output.utf8), usageMode: .nativeClaudeTerminal)
        XCTAssertEqual(completion.text, "Done")
        XCTAssertEqual(completion.promptTokens, 11)
        XCTAssertEqual(completion.completionTokens, 7)
        XCTAssertEqual(completion.cost, 0.12)
    }

    func testClaudeStreamJSONPreservesContinuedAnswerWithoutDuplicatingResult() throws {
        let first = String(repeating: "First section. ", count: 20000) + "\n```swift\nfunc handl"
        let output = try [
            jsonText(["type": "assistant", "message": ["stop_reason": "max_tokens", "content": [
                ["type": "text", "text": first], ["type": "tool_use", "text": "not answer text"]
            ]]]),
            jsonText(["type": "user", "message": ["content": "continue"]]),
            jsonText(["type": "assistant", "parent_tool_use_id": "child", "message": ["content": [["type": "text", "text": "not the parent reply"]]]]),
            jsonText(["type": "assistant", "parent_tool_use_id": NSNull(), "message": ["stop_reason": "end_turn", "content": [
                ["type": "thinking", "thinking": "private"], ["type": "text", "text": "eRequest() {}\n"], ["type": "text", "text": "```"]
            ]]]),
            jsonText(["type": "result", "subtype": "success", "result": "eRequest() {}\n```"])
        ].joined(separator: "\n")
        let completion = try provider().parseStreamJSONCompletionPayload(Data(output.utf8), usageMode: .nativeClaudeTerminal)
        XCTAssertEqual(completion.text, first + "eRequest() {}\n```")
    }

    func testClaudeStreamJSONIgnoresNonJSONStdoutDiagnostics() throws {
        let output = """
        [SandboxDebug] Preparing sandbox
        {"type":"assistant","parent_tool_use_id":null,"message":{"content":[{"type":"text","text":"First "}]}}
        [SandboxDebug] Sandbox ready
        {"type":"assistant","parent_tool_use_id":null,"message":{"content":[{"type":"text","text":"last"}]}}
        {"type":"result","subtype":"success","is_error":false,"result":"last"}
        """
        let completion = try provider().parseStreamJSONCompletionPayload(Data(output.utf8), usageMode: .nativeClaudeTerminal)
        XCTAssertEqual(completion.text, "First last")
    }

    func testClaudeStreamJSONRejectsErrorsAndIncompleteOutput() throws {
        let assistant = #"{"type":"assistant","message":{"content":[{"type":"text","text":"Partial"}]}}"#
        let success = #"{"type":"result","subtype":"success","result":"Done"}"#
        for output in [assistant, assistant + "\n" + #"{"type":"result","is_error":true,"errors":["Failed"]}"#, assistant + "\n" + #"{"type":"error","message":"Failed"}"#, assistant + "\n{malformed}\n" + success, assistant + "\n" + success + "\n{"] {
            XCTAssertThrowsError(try provider().parseStreamJSONCompletionPayload(Data(output.utf8), usageMode: .nativeClaudeTerminal))
        }
        let completion = try provider().parseStreamJSONCompletionPayload(Data(success.utf8), usageMode: .nativeClaudeTerminal)
        XCTAssertEqual(completion.text, "Done")
    }

    func testClaudeStreamJSONExtractsTerminalError() {
        let output = """
        {"type":"result","subtype":"error_during_execution","is_error":true,"errors":["Request was aborted by user"],"usage":{"input_tokens":11,"output_tokens":0},"total_cost_usd":0.12}
        """
        XCTAssertEqual(provider().extractCLIErrorDetail(fromStdout: Data(output.utf8), isStreamJSON: true), "Request was aborted by user")
    }

    private func jsonText(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }
}
