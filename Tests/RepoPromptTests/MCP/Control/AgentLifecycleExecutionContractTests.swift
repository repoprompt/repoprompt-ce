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

    func testAgentRunStartWaitAndSteerRejectOversizedTimeouts() throws {
        let maximum = AgentMCPToolHelpers.maximumTimeoutSeconds
        XCTAssertEqual(try AgentRunMCPToolService.resolvedStartTimeoutSeconds(.double(maximum)), maximum)
        XCTAssertEqual(try AgentRunMCPToolService.resolvedWaitTimeoutSeconds(.int(Int(maximum))), maximum)
        XCTAssertEqual(try AgentRunMCPToolService.resolvedSteerTimeoutSeconds(.string(String(Int(maximum)))), maximum)

        let resolvers: [(Value?) throws -> TimeInterval] = [
            AgentRunMCPToolService.resolvedStartTimeoutSeconds,
            AgentRunMCPToolService.resolvedWaitTimeoutSeconds,
            AgentRunMCPToolService.resolvedSteerTimeoutSeconds
        ]
        let oversizedValues = [
            Value.double(maximum + 1),
            .int(Int(maximum) + 1),
            .string(String(Int(maximum) + 1))
        ]
        for resolver in resolvers {
            for value in oversizedValues {
                XCTAssertThrowsError(try resolver(value)) { error in
                    XCTAssertTrue(String(describing: error).contains(String(Int(maximum))))
                }
            }
        }
    }

    func testAgentExploreStartUsesSameDefaultAndPreservesLongerCallerTimeout() throws {
        XCTAssertEqual(
            try AgentExploreMCPToolService.resolvedStartTimeoutSeconds(nil),
            MCPTimeoutPolicy.agentLifecycleDefaultWaitSeconds
        )
        XCTAssertEqual(try AgentExploreMCPToolService.resolvedStartTimeoutSeconds(.double(900.5)), 900.5)
    }
}
