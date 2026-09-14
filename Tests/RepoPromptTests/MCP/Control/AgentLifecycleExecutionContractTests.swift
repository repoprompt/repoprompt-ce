import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptShared
import XCTest

@MainActor
final class AgentLifecycleExecutionContractTests: XCTestCase {
    func testAgentRunLifecycleWaitDefaultsAndExplicitOverrides() throws {
        let expected: TimeInterval = 300
        let captured = expected
        XCTAssertEqual(AgentRunMCPToolService.defaultWaitTimeoutSeconds, expected)
        XCTAssertEqual(try AgentRunMCPToolService.resolvedStartTimeoutSeconds(nil, capturedDefaultWaitSeconds: captured), expected)
        XCTAssertEqual(try AgentRunMCPToolService.resolvedWaitTimeoutSeconds(nil, capturedDefaultWaitSeconds: captured), expected)
        XCTAssertEqual(try AgentRunMCPToolService.resolvedSteerTimeoutSeconds(nil, capturedDefaultWaitSeconds: captured), expected)
        XCTAssertEqual(try AgentRunMCPToolService.resolvedStartTimeoutSeconds(.null, capturedDefaultWaitSeconds: captured), expected)
        XCTAssertEqual(try AgentRunMCPToolService.resolvedWaitTimeoutSeconds(.null, capturedDefaultWaitSeconds: captured), expected)
        XCTAssertEqual(try AgentRunMCPToolService.resolvedSteerTimeoutSeconds(.null, capturedDefaultWaitSeconds: captured), expected)
        XCTAssertEqual(try AgentRunMCPToolService.resolvedStartTimeoutSeconds(.int(0), capturedDefaultWaitSeconds: captured), 0)
        XCTAssertEqual(try AgentRunMCPToolService.resolvedWaitTimeoutSeconds(.int(30), capturedDefaultWaitSeconds: captured), 30)
        XCTAssertEqual(try AgentRunMCPToolService.resolvedSteerTimeoutSeconds(.double(45.5), capturedDefaultWaitSeconds: captured), 45.5)
        XCTAssertEqual(try AgentRunMCPToolService.resolvedWaitTimeoutSeconds(.int(7200), capturedDefaultWaitSeconds: captured), 7200)
    }

    func testAgentRunLifecycleWaitUsesInjectedCapturedDefault() throws {
        let capturedDefault: TimeInterval = 600
        XCTAssertEqual(
            try AgentRunMCPToolService.resolvedStartTimeoutSeconds(nil, capturedDefaultWaitSeconds: capturedDefault),
            capturedDefault
        )
        XCTAssertEqual(
            try AgentRunMCPToolService.resolvedWaitTimeoutSeconds(.null, capturedDefaultWaitSeconds: capturedDefault),
            capturedDefault
        )
        XCTAssertEqual(
            try AgentRunMCPToolService.resolvedSteerTimeoutSeconds(nil, capturedDefaultWaitSeconds: capturedDefault),
            capturedDefault
        )
        XCTAssertEqual(try AgentRunMCPToolService.resolvedWaitTimeoutSeconds(.int(30), capturedDefaultWaitSeconds: capturedDefault), 30)
    }

    func testCapturedDefaultWaitTimeoutSecondsReadsConfiguredPreferenceOnce() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let suiteName = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = GlobalSettingsStore(defaults: defaults, fileStore: GlobalSettingsFileStore(fileURL: fileURL))
        XCTAssertEqual(AgentRunMCPToolService.capturedDefaultWaitTimeoutSeconds(from: store), 300)

        XCTAssertTrue(store.setSubagentDefaultWaitSeconds(1200))
        // Freeze the value an in-flight wait would have captured, then change the preference:
        // the wait must keep resolving against its capture, not the new setting.
        let frozenDefault = AgentRunMCPToolService.capturedDefaultWaitTimeoutSeconds(from: store)
        XCTAssertEqual(frozenDefault, 1200)

        XCTAssertTrue(store.setSubagentDefaultWaitSeconds(120))
        XCTAssertEqual(
            try AgentRunMCPToolService.resolvedWaitTimeoutSeconds(nil, capturedDefaultWaitSeconds: frozenDefault),
            frozenDefault
        )
        XCTAssertEqual(AgentRunMCPToolService.capturedDefaultWaitTimeoutSeconds(from: store), 120)
    }

    func testAgentExploreStartSharesLifecycleWaitPolicy() throws {
        XCTAssertEqual(
            try AgentExploreMCPToolService.resolvedStartTimeoutSeconds(
                nil,
                capturedDefaultWaitSeconds: MCPTimeoutPolicy.agentLifecycleDefaultWaitSeconds
            ),
            MCPTimeoutPolicy.agentLifecycleDefaultWaitSeconds
        )
        XCTAssertEqual(
            try AgentExploreMCPToolService.resolvedStartTimeoutSeconds(
                .double(900.5),
                capturedDefaultWaitSeconds: MCPTimeoutPolicy.agentLifecycleDefaultWaitSeconds
            ),
            900.5
        )
        XCTAssertEqual(
            try AgentExploreMCPToolService.resolvedStartTimeoutSeconds(nil, capturedDefaultWaitSeconds: 1800),
            1800
        )
    }
}
