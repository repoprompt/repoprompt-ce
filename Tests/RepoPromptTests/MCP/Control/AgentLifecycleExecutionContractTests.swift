import Foundation
import MCP
@testable import RepoPrompt
import RepoPromptShared
import XCTest

@MainActor
final class AgentLifecycleExecutionContractTests: XCTestCase {
    func testAgentRunStartWaitAndSteerUseTwoMinuteDefault() throws {
        let expected = MCPTimeoutPolicy.agentLifecycleDefaultWaitSeconds
        XCTAssertEqual(AgentRunMCPToolService.defaultWaitTimeoutSeconds, expected)
        XCTAssertEqual(try AgentRunMCPToolService.resolvedStartTimeoutSeconds(nil), expected)
        XCTAssertEqual(try AgentRunMCPToolService.resolvedWaitTimeoutSeconds(nil), expected)
        XCTAssertEqual(try AgentRunMCPToolService.resolvedSteerTimeoutSeconds(nil), expected)
    }

    func testAgentRunStartWaitAndSteerPreserveLongerCallerTimeouts() throws {
        let longerThanWatchdog = Value.int(600)

        XCTAssertEqual(try AgentRunMCPToolService.resolvedStartTimeoutSeconds(longerThanWatchdog), 600)
        XCTAssertEqual(try AgentRunMCPToolService.resolvedWaitTimeoutSeconds(longerThanWatchdog), 600)
        XCTAssertEqual(try AgentRunMCPToolService.resolvedSteerTimeoutSeconds(longerThanWatchdog), 600)
        XCTAssertGreaterThan(
            try AgentRunMCPToolService.resolvedWaitTimeoutSeconds(longerThanWatchdog),
            TimeInterval(MCPTimeoutPolicy.boundedToolExecutionDeadlineSeconds)
        )
    }

    func testAgentExploreStartUsesSameDefaultAndPreservesLongerCallerTimeout() throws {
        XCTAssertEqual(
            try AgentExploreMCPToolService.resolvedStartTimeoutSeconds(nil),
            MCPTimeoutPolicy.agentLifecycleDefaultWaitSeconds
        )
        XCTAssertEqual(try AgentExploreMCPToolService.resolvedStartTimeoutSeconds(.double(900.5)), 900.5)
    }
}
