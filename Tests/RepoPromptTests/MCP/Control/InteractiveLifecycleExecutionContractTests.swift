import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptShared
import XCTest

@MainActor
final class InteractiveLifecycleExecutionContractTests: XCTestCase {
    func testAskUserPreservesResolvedDefaultAndLongerCallerTimeout() throws {
        XCTAssertEqual(
            try MCPAskUserToolProvider.resolvedInteractionTimeoutSeconds(
                nil,
                defaultTimeout: MCPTimeoutPolicy.askUserDefaultTimeoutSeconds
            ),
            MCPTimeoutPolicy.askUserDefaultTimeoutSeconds
        )
        XCTAssertEqual(
            try MCPAskUserToolProvider.resolvedInteractionTimeoutSeconds(
                .int(900),
                defaultTimeout: MCPTimeoutPolicy.askUserDefaultTimeoutSeconds
            ),
            900
        )
    }

    func testWaitForNextInstructionPreservesDefaultAndLongerCallerTimeout() throws {
        XCTAssertEqual(
            try MCPAgentSessionControlToolProvider.resolvedInstructionWaitTimeoutSeconds(nil),
            MCPTimeoutPolicy.nextUserInstructionDefaultWaitSeconds
        )
        XCTAssertEqual(
            try MCPAgentSessionControlToolProvider.resolvedInstructionWaitTimeoutSeconds(.int(1200)),
            1200
        )
    }
}
