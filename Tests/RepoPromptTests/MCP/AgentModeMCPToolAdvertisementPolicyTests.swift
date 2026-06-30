@testable import RepoPrompt
import XCTest

final class AgentModeMCPToolAdvertisementPolicyTests: XCTestCase {
    func testDelegationAdvertisementRequiresTopLevelNonExploreControl() {
        let roleCases: [(AgentModelCatalog.TaskLabelKind, String)] = [
            (.pair, "Pair"),
            (.engineer, "Engineer"),
            (.design, "Design")
        ]

        for (role, label) in roleCases {
            XCTAssertTrue(
                AgentModeMCPToolAdvertisementPolicy.shouldAdvertise(
                    toolName: MCPWindowToolName.agentRun,
                    taskLabelKind: role,
                    allowsAgentExternalControlTools: true
                ),
                "\(label) top-level agent_run"
            )
            XCTAssertTrue(
                AgentModeMCPToolAdvertisementPolicy.shouldAdvertise(
                    toolName: MCPWindowToolName.agentManage,
                    taskLabelKind: role,
                    allowsAgentExternalControlTools: true
                ),
                "\(label) top-level agent_manage"
            )
            XCTAssertTrue(
                AgentModeMCPToolAdvertisementPolicy.shouldAdvertise(
                    toolName: MCPWindowToolName.agentExplore,
                    taskLabelKind: role,
                    allowsAgentExternalControlTools: true
                ),
                "\(label) top-level agent_explore"
            )

            XCTAssertFalse(
                AgentModeMCPToolAdvertisementPolicy.shouldAdvertise(
                    toolName: MCPWindowToolName.agentRun,
                    taskLabelKind: role,
                    allowsAgentExternalControlTools: false
                ),
                "\(label) nested agent_run"
            )
            XCTAssertFalse(
                AgentModeMCPToolAdvertisementPolicy.shouldAdvertise(
                    toolName: MCPWindowToolName.agentManage,
                    taskLabelKind: role,
                    allowsAgentExternalControlTools: false
                ),
                "\(label) nested agent_manage"
            )
            XCTAssertTrue(
                AgentModeMCPToolAdvertisementPolicy.shouldAdvertise(
                    toolName: MCPWindowToolName.agentExplore,
                    taskLabelKind: role,
                    allowsAgentExternalControlTools: false
                ),
                "\(label) nested agent_explore"
            )
        }

        for allowsExternalControl in [false, true] {
            XCTAssertFalse(
                AgentModeMCPToolAdvertisementPolicy.shouldAdvertise(
                    toolName: MCPWindowToolName.agentRun,
                    taskLabelKind: .explore,
                    allowsAgentExternalControlTools: allowsExternalControl
                )
            )
            XCTAssertFalse(
                AgentModeMCPToolAdvertisementPolicy.shouldAdvertise(
                    toolName: MCPWindowToolName.agentManage,
                    taskLabelKind: .explore,
                    allowsAgentExternalControlTools: allowsExternalControl
                )
            )
            XCTAssertFalse(
                AgentModeMCPToolAdvertisementPolicy.shouldAdvertise(
                    toolName: MCPWindowToolName.agentExplore,
                    taskLabelKind: .explore,
                    allowsAgentExternalControlTools: allowsExternalControl
                )
            )
        }
    }

    func testDirectConnectionDoesNotAdvertiseExploreControl() {
        XCTAssertTrue(
            AgentModeMCPToolAdvertisementPolicy.shouldAdvertise(
                toolName: MCPWindowToolName.agentRun,
                taskLabelKind: nil,
                allowsAgentExternalControlTools: false
            )
        )
        XCTAssertTrue(
            AgentModeMCPToolAdvertisementPolicy.shouldAdvertise(
                toolName: MCPWindowToolName.agentManage,
                taskLabelKind: nil,
                allowsAgentExternalControlTools: false
            )
        )
        XCTAssertFalse(
            AgentModeMCPToolAdvertisementPolicy.shouldAdvertise(
                toolName: MCPWindowToolName.agentExplore,
                taskLabelKind: nil,
                allowsAgentExternalControlTools: false
            )
        )
    }
}
