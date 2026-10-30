import Darwin
import Foundation
@testable import RepoPromptApp
import RepoPromptShared
import XCTest

final class ClaudeNativeSessionHostTests: XCTestCase {
    private actor RefusingHost: ClaudeNativeSessionHosting {
        private(set) var calls: [String] = []

        func isMCPServerRunning() async -> Bool {
            calls.append("readiness")
            return false
        }

        func prepareMCPLaunchConfig() async throws -> any ClaudeNativeConfigLease {
            calls.append("lease")
            throw NSError(domain: "test", code: 1)
        }

        func registerExpectedAgentPID(_: pid_t, clientName _: String, runID _: UUID) async {
            calls.append("register")
        }

        func clearExpectedAgentPID(_: pid_t, clientName _: String, runID _: UUID) async {
            calls.append("clear")
        }
    }

    func testRequiredHostReadinessRefusalPrecedesLeaseAndLaunch() async {
        let host = RefusingHost()
        let controller = ClaudeNativeProcessSessionController(
            host: host,
            runID: UUID(),
            tabID: UUID(),
            windowID: 1,
            workspacePath: nil,
            config: .discovery(commandName: "/usr/bin/false")
        )
        let errorText: String? = await ProviderProcessLaunchPolicy.$allowsLaunchForTesting.withValue(true) {
            do {
                _ = try await controller.startOrResume(existingSessionID: nil, model: nil)
                return nil
            } catch {
                return error.localizedDescription
            }
        }
        XCTAssertEqual(errorText, "Could not start MCP server. Check MCP settings and try again.")
        let calls = await host.calls
        XCTAssertEqual(calls, ["readiness"])
        await controller.shutdown()
    }
}
