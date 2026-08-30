import Foundation
import MCP
@testable import RepoPromptApp
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

    func testAgentExploreStartUsesSameDefaultAndPreservesLongerCallerTimeout() throws {
        XCTAssertEqual(
            try AgentExploreMCPToolService.resolvedStartTimeoutSeconds(nil),
            MCPTimeoutPolicy.agentLifecycleDefaultWaitSeconds
        )
        XCTAssertEqual(try AgentExploreMCPToolService.resolvedStartTimeoutSeconds(.double(900.5)), 900.5)
    }
}
