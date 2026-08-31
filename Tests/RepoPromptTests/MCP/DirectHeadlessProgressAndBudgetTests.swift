import Foundation
#if os(Linux)
    import Glibc
#endif
@testable import RepoPromptMCP
import XCTest

final class DirectHeadlessProgressAndBudgetTests: XCTestCase {
    func testContextBuilderPromptCarriesBothHardBudgetsAndResponseType() {
        let prompt = DirectHeadlessConversationBackend.contextBuilderPrompt(
            instructions: "Review origin/main...HEAD",
            responseType: "review",
            contextBudget: 100_000,
            analysisBudget: 150_000
        )

        XCTAssertTrue(prompt.contains("<response_type>review</response_type>"))
        XCTAssertTrue(prompt.contains("<context_token_budget>100000</context_token_budget>"))
        XCTAssertTrue(prompt.contains("<analysis_token_budget>150000</analysis_token_budget>"))
        XCTAssertTrue(prompt.contains("Review origin/main...HEAD"))
    }

    func testOraclePromptCarriesAnalysisHardBudget() {
        let prompt = DirectHeadlessConversationBackend.oraclePrompt(
            "Explain the finding",
            analysisBudget: 150_000
        )

        XCTAssertTrue(prompt.contains("<analysis_token_budget>150000</analysis_token_budget>"))
        XCTAssertTrue(prompt.contains("Explain the finding"))
    }

    func testCodexJSONProgressTailRetainsFinalAssistantAfterLargeOutput() async throws {
        let tail = DirectCodexProgressTail { _ in }
        tail.consume(Data((#"{"type":"item.completed","item":{"type":"command_execution","aggregated_output":""}}"# + "\n").utf8))
        tail.consume(Data(repeating: 0x78, count: 9 * 1024 * 1024))
        tail.consume(Data(("\n" + #"{"type":"item.completed","item":{"type":"agent_message","text":"FINAL_REVIEW"}}"# + "\n").utf8))

        XCTAssertEqual(tail.finalAssistantText(), "FINAL_REVIEW")
    }

    func testProviderCancellationTerminatesLinuxProcessGroup() async throws {
#if os(Linux)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DirectProcessCancellation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("provider.sh")
        let pidFile = root.appendingPathComponent("descendant.pid")
        try """
        #!/usr/bin/env bash
        sleep 30 &
        echo $! > "$1"
        wait
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)

        let task = Task {
            try await DirectProcess.run(script.path, arguments: [pidFile.path])
        }
        for _ in 0 ..< 100 where !FileManager.default.fileExists(atPath: pidFile.path) {
            try await Task.sleep(for: .milliseconds(20))
        }
        let descendantPID = try XCTUnwrap(
            Int32(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))
        )
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected provider cancellation")
        } catch is CancellationError {
            // Expected.
        }
        for _ in 0 ..< 100 where kill(descendantPID, 0) == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotEqual(kill(descendantPID, 0), 0, "provider descendant survived cancellation")
#endif
    }

    func testCodexJSONProgressTailEmitsSafeBoundedMilestones() throws {
        let cases: [(String, String?)] = [
            (#"{"type":"thread.started","thread_id":"secret"}"#, "Provider session started"),
            (#"{"type":"turn.started"}"#, "Provider began analyzing the workspace"),
            (#"{"type":"item.started","item":{"type":"command_execution","command":"cat /secret"}}"#, "Workspace inspection started"),
            (#"{"type":"item.completed","item":{"type":"mcp_tool_call","server":"secret"}}"#, "RepoPrompt tool call completed"),
            (#"{"type":"item.started","item":{"type":"agent_message","text":"secret"}}"#, "Provider is synthesizing a response"),
            (#"{"type":"turn.completed"}"#, "Provider completed analysis"),
            (#"{"type":"unknown","payload":"secret"}"#, nil),
        ]

        for (line, expected) in cases {
            XCTAssertEqual(
                DirectCodexProgressTail.progressMessage(from: Data(line.utf8)),
                expected
            )
        }
    }
}
