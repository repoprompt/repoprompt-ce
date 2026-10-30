import Darwin
import Foundation
import RepoPromptAIContracts
@testable import RepoPromptApp
import RepoPromptShared
import XCTest

final class ClaudeNativeSessionHostTests: XCTestCase {
    private actor RefusingHost: ClaudeNativeSessionHosting {
        private(set) var calls: [String] = []

        nonisolated func repoPromptPermissionMatch(toolName _: String, requestPayload _: [String: Any]) -> ClaudeNativePermissionMatch? {
            nil
        }

        func filterEnvironment(_ environment: [String: String], variant _: ClaudeCodeRuntimeVariant) async -> [String: String] {
            environment
        }

        nonisolated func mergeCurrentCarrier(into environment: [String: String]) -> [String: String] {
            environment
        }

        nonisolated func supplementedPathHints(_ hints: [String]) -> [String] {
            hints
        }

        nonisolated func expectedAgentClientName(for _: ClaudeCodeRuntimeVariant) -> String? {
            nil
        }

        #if DEBUG
            nonisolated func debugStatusLineArguments(launchArguments _: [String], isFirstParty _: Bool, providerArguments _: [String]) -> [String] {
                []
            }
        #endif

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

    func testPermissionDecisionUsesRequiredHostAtControlRequest() async {
        let payload: [String: Any] = [
            "tool_name": "mcp__RepoPromptCE__read_file",
            "tool_use_id": "toolu_host",
            "input": ["path": "Sources/App.swift"]
        ]
        for (host, expectApproval) in [
            (ClaudeNativeSessionAppHost() as any ClaudeNativeSessionHosting, false),
            (RefusingHost() as any ClaudeNativeSessionHosting, true)
        ] {
            let controller = ClaudeNativeProcessSessionController(
                host: host, runID: UUID(), tabID: UUID(), windowID: 1,
                workspacePath: nil, config: .discovery(commandName: "/usr/bin/false")
            )
            await controller.test_installConfigurationTransport(write: { _ in })
            let events = await controller.events
            await controller.test_handleControlRequest(requestID: "host-check", subtype: "can_use_tool", request: payload)
            await controller.shutdown()
            var approvals = 0
            for await event in events {
                if case .approvalRequest = event { approvals += 1 }
            }
            XCTAssertEqual(approvals, expectApproval ? 1 : 0)
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
