import Darwin
import Foundation
import RepoPromptAgentProviderContracts
import RepoPromptAIContracts
@testable import RepoPromptApp
import RepoPromptClaudeProvider
import RepoPromptMCPServer
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

        nonisolated func processEnvironmentOverrides(for _: AgentCLIToolContext) -> [String: String] {
            ["HOST_ROUTING_WITNESS": "host"]
        }

        nonisolated func hasModelSpecifier(_ model: String?) -> Bool {
            model != nil
        }

        nonisolated func explicitEffortLevel(for model: String?) -> ClaudeCodeEffortLevel? {
            model == "host-effort-witness" ? .high : nil
        }

        nonisolated func isDefaultModel(_ model: String) -> Bool {
            model == "host-default-witness"
        }

        nonisolated func shouldSuppressAbortArtifact(_ message: String) -> Bool {
            message == "host-abort-witness"
        }

        nonisolated func validateReadSourceFD(_ fd: Int32, label: String) throws {
            try ReadSourceFDPreflight.validateOpenFD(fd, label: label)
        }

        nonisolated func supplementedPathHints(_ hints: [String]) -> [String] {
            hints
        }

        nonisolated func expectedAgentClientName(for _: ClaudeCodeRuntimeVariant) -> String? {
            nil
        }

        nonisolated func isRawEventFileLoggingEnabled() -> Bool {
            false
        }

        nonisolated func makeRawEventLogFileURL(workspacePath _: String?, sessionID _: String) -> URL? {
            nil
        }

        nonisolated func recordLastRawEventLogFileURL(_: URL) {}
        nonisolated func isReasoningExtractionEnabled() -> Bool {
            false
        }

        nonisolated func appendReasoningDebug(_: String) {}
        nonisolated func isRepoPromptToolName(_: String) -> Bool {
            false
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

    func testFlagSettingsUseRequiredHostModelEffort() async throws {
        let controller = ClaudeNativeProcessSessionController(
            host: RefusingHost(), runID: UUID(), tabID: UUID(), windowID: 1,
            workspacePath: nil, config: .discovery(commandName: "/usr/bin/false")
        )
        let request = try await controller.test_resolveApplyFlagSettingsRequest(model: "host-effort-witness")
        XCTAssertEqual((request?["settings"] as? [String: Any])?["effortLevel"] as? String, "high")
        let override = try await controller.test_resolveApplyFlagSettingsRequest(model: "host-effort-witness", effortLevel: .low)
        XCTAssertEqual((override?["settings"] as? [String: Any])?["effortLevel"] as? String, "low")
        await controller.shutdown()
    }

    func testAppFDPreflightPreservesCanonicalErrorIdentity() {
        XCTAssertThrowsError(try ClaudeNativeSessionAppHost().validateReadSourceFD(-1, label: "Claude stdout")) { error in
            XCTAssertEqual(error as? ReadSourceFDPreflightError, .invalidFileDescriptor(label: "Claude stdout", fd: -1))
        }
    }

    func testDefaultModelAndAbortFilteringUseRequiredHost() async {
        let controller = ClaudeNativeProcessSessionController(
            host: RefusingHost(), runID: UUID(), tabID: UUID(), windowID: 1,
            workspacePath: nil, config: .discovery(commandName: "/usr/bin/false")
        )
        let defaultRequest = await controller.test_buildApplyFlagSettingsRequest(model: "host-default-witness")
        XCTAssertNil(defaultRequest)
        let suppressed = await controller.shouldSuppressUserFacingStreamResult(
            AIStreamResult(type: "error", text: "host-abort-witness")
        )
        XCTAssertTrue(suppressed)
        await controller.shutdown()
    }

    func testLaunchEnvironmentUsesRequiredHostOverrides() async {
        let controller = ClaudeNativeProcessSessionController(
            host: RefusingHost(), runID: UUID(), tabID: UUID(), windowID: 1,
            workspacePath: nil, config: .discovery(commandName: "/usr/bin/false")
        )
        let environment = await controller.test_effectiveLaunchEnvironment(base: [:])
        XCTAssertEqual(environment["HOST_ROUTING_WITNESS"], "host")
        await controller.shutdown()
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
