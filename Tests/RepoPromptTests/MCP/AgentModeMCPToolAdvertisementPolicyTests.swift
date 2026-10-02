import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptSecureStorage
import XCTest

final class AgentModeMCPToolAdvertisementPolicyTests: XCTestCase {
    @MainActor
    func testEffectiveWindowCatalogAdvertisesStartDeadlineExactlyOnce() async throws {
        let service = MCPService(
            hostBootstrapOperation: {},
            controllerStartOperation: {},
            controllerFullShutdownOperation: {}
        )
        let server = makeServerViewModel(service: service)
        let tools = await server.windowMCPTools
        let run = try XCTUnwrap(tools.first { $0.name == MCPWindowToolName.agentRun })
        let sentence = "Start: setup ≤150s, return ≤25s; timeout may follow dispatch—inspect its session, never blindly retry."
        XCTAssertEqual(run.description.components(separatedBy: sentence).count - 1, 1)
    }

    @MainActor
    private func makeServerViewModel(service: MCPService) -> MCPServerViewModel {
        let store = WorkspaceFileContextStore()
        let fileManager = WorkspaceFilesViewModel(workspaceFileContextStore: store)
        let keyManager = KeyManager(
            secureService: SecureKeysService(secureStorage: TestSecureStorageBackend())
        )
        let aiQueriesService = AIQueriesService(keyManager: keyManager)
        let apiSettings = APISettingsViewModel(
            aiQueriesService: aiQueriesService,
            keyManager: keyManager,
            loadStoredDataOnInit: false
        )
        let settingsManager = WindowSettingsManager(windowID: -1)
        let prompt = PromptViewModel(
            fileManager: fileManager,
            aiQueriesService: aiQueriesService,
            apiSettingsViewModel: apiSettings,
            windowID: -1,
            settingsManager: settingsManager
        )
        let workspaceManager = WorkspaceManagerViewModel(
            fileManager: fileManager,
            promptViewModel: prompt,
            performInitialWorkspaceActivation: false
        )
        let oracle = OracleViewModel(
            aiQueriesService: aiQueriesService,
            promptViewModel: prompt,
            workspaceManager: workspaceManager,
            chatData: ChatDataService()
        )
        return MCPServerViewModel(
            service: service,
            promptVM: prompt,
            oracleVM: oracle,
            workspaceManager: workspaceManager,
            windowID: -1,
            workspaceSearch: { _, _, _, _, _, _, _, _, _, _, _, _, _, _ in
                throw MCPError.internalError("workspace search is not used by these tests")
            },
            ensureGitDataRootLoaded: { _, _ in
                throw MCPError.internalError("git-data loading is not used by these tests")
            }
        )
    }

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
