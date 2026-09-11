import Foundation
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

final class DevinACPStderrPresentationTests: XCTestCase {
    // Normalized prefix fixtures from the archived installed 3000.6.14 plain-hi control.
    private let info = "2026-09-06T14:56:09.512658Z  INFO run_acp_server: chisel_server::acp: Starting ACP server"
    private let warning = "2026-09-06T14:56:09.603601Z  WARN message_forest: MessageChain tree duplication: system prefix changed (old_len=0, new_len=4, messages_to_copy=3)"

    func testOnlyTimestampPrefixedINFOIsSuppressed() {
        let provider = DevinACPAgentProvider(config: DevinAgentConfig(includeRepoPromptMCPServer: false))
        XCTAssertFalse(provider.shouldEmitStderrLine(info))
        XCTAssertFalse(provider.shouldEmitStderrLine("2026-09-06T14:56:09Z INFO chisel: logging initialized"))
        for line in [
            warning,
            "2026-09-06T14:56:09.512658Z ERROR chisel: authentication failed",
            "2026-09-06T14:56:09.512658Z DEBUG chisel: diagnostic",
            "2026-09-06T14:56:09.512658Z INFOGRAPHIC unknown",
            "INFO unrecognized prefix",
            "connection failed: INFO unavailable",
            "Authentication failed. Run /login.",
            "thread 'main' panicked at startup"
        ] {
            XCTAssertTrue(provider.shouldEmitStderrLine(line), line)
        }
        XCTAssertTrue(OMPACPAgentProvider(config: OMPAgentConfig()).shouldEmitStderrLine(info))
    }

    func testControllerKeepsSuppressedINFOInDiagnosticsAndEmitsActionableStderr() async throws {
        let directory = try makeTestDirectory(name: "DevinACPStderrPresentation")
        let provider = try ACPModelSelectionFixtureProvider(directory: directory, providerID: .devin)
        defer { AgentACPModelRegistry.shared.test_reset(providerID: .devin) }
        let error = "Authentication failed. Run /login."
        let failure = "2026-09-06T14:56:09.512658Z ERROR chisel: transport failed"
        let stderr = ["\u{1B}[2m\(info)\u{1B}[0m", warning, failure, error]
        try stderr.joined(separator: "\n").write(to: directory.appendingPathComponent("stderr.txt"), atomically: true, encoding: .utf8)
        let request = ACPRunRequest(
            agentKind: .devin,
            modelString: "default",
            workspacePath: directory.path,
            resumeSessionID: nil,
            attachments: [],
            taskLabelKind: nil
        )
        let diagnostics = StderrRecords()
        let received = expectation(description: "all stderr reaches diagnostics")
        received.expectedFulfillmentCount = stderr.count
        let controller = try ACPAgentSessionController(provider: provider, runRequest: request, diagnosticSink: { event in
            if case let .stderrLine(line) = event {
                diagnostics.append(line)
                received.fulfill()
            }
        })
        let events = await controller.events
        let consumer = Task { () -> [String] in
            var lines: [String] = []
            for await event in events {
                if case let .stream(result) = event, result.type == "system", let text = result.text {
                    lines.append(text)
                }
            }
            return lines
        }
        do {
            _ = try await controller.bootstrap()
            try await controller.prompt(AgentMessage(userMessage: "hi"), request: request)
            await fulfillment(of: [received], timeout: 5)
            await controller.shutdown()
        } catch {
            await controller.shutdown()
            _ = await consumer.value
            throw error
        }
        let lines = await consumer.value
        XCTAssertEqual(diagnostics.snapshot(), [info, warning, failure, error])
        XCTAssertFalse(lines.contains(info))
        for line in [warning, failure, error] {
            XCTAssertTrue(lines.contains(line), "Missing \(line) in \(lines)")
        }
    }
}

private final class StderrRecords: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        lines.append(line)
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}
