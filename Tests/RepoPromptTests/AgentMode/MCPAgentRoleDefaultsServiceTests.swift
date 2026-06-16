@testable import RepoPrompt
import XCTest

@MainActor
final class MCPAgentRoleDefaultsServiceTests: XCTestCase {
    func testResolutionsFallbackToActualAvailabilityWhenRecommendationAvailabilityIsEmpty() {
        let actualAvailability = AgentModelCatalog.AvailabilityContext(
            claudeCodeAvailable: false,
            codexAvailable: true,
            openCodeAvailable: false,
            cursorAvailable: false,
            zaiConfigured: false,
            kimiConfigured: false,
            customClaudeCompatibleConfigured: false
        )

        let resolutions = MCPAgentRoleDefaultsService.resolutions(
            availability: actualAvailability,
            recommendedAvailability: AgentModelCatalog.AvailabilityContext.none,
            settingsStore: RoleDefaultsStoreStub()
        )

        XCTAssertEqual(
            resolutions.map(\.role),
            AgentModelCatalog.TaskLabelKind.allCases
        )

        XCTAssertEqual(resolutions[0].recommended.agent, .codexExec)
        XCTAssertEqual(resolutions[0].recommended.modelRaw, AgentModel.gpt55CodexLow.rawValue)
        XCTAssertEqual(resolutions[1].recommended.agent, .codexExec)
        XCTAssertEqual(resolutions[1].recommended.modelRaw, AgentModel.gpt55CodexLow.rawValue)
        XCTAssertEqual(resolutions[2].recommended.agent, .codexExec)
        XCTAssertEqual(resolutions[2].recommended.modelRaw, AgentModel.gpt55CodexHigh.rawValue)
        XCTAssertEqual(resolutions[3].recommended.agent, .codexExec)
        XCTAssertEqual(resolutions[3].recommended.modelRaw, AgentModel.gpt55CodexMedium.rawValue)
    }

    func testResolutionsPreferRecommendationAvailabilityWhenItCanResolveRole() throws {
        let actualAvailability = AgentModelCatalog.AvailabilityContext(
            claudeCodeAvailable: false,
            codexAvailable: true,
            openCodeAvailable: false,
            cursorAvailable: false,
            zaiConfigured: true,
            kimiConfigured: false,
            customClaudeCompatibleConfigured: false
        )
        let recommendedAvailability = AgentModelCatalog.AvailabilityContext(
            claudeCodeAvailable: false,
            codexAvailable: false,
            openCodeAvailable: false,
            cursorAvailable: false,
            zaiConfigured: true,
            kimiConfigured: false,
            customClaudeCompatibleConfigured: false
        )

        let engineer = try XCTUnwrap(MCPAgentRoleDefaultsService.effectiveSelection(
            for: .engineer,
            availability: actualAvailability,
            recommendedAvailability: recommendedAvailability,
            settingsStore: RoleDefaultsStoreStub()
        ))

        XCTAssertEqual(engineer.recommended.agent, .claudeCodeGLM)
        XCTAssertEqual(engineer.recommended.modelRaw, AgentModel.claudeSonnet.rawValue)
        XCTAssertEqual(engineer.effective, engineer.recommended)
    }

    func testSetSelectionClearsOverrideWhenSelectionMatchesFallbackRecommendation() {
        let actualAvailability = AgentModelCatalog.AvailabilityContext(
            claudeCodeAvailable: false,
            codexAvailable: true,
            openCodeAvailable: false,
            cursorAvailable: false,
            zaiConfigured: false,
            kimiConfigured: false,
            customClaudeCompatibleConfigured: false
        )
        let store = RoleDefaultsStoreStub(overrides: [
            AgentModelCatalog.TaskLabelKind.explore.rawValue: AgentModelSelectionID(
                agentRaw: AgentProviderKind.claudeCode.rawValue,
                modelRaw: AgentModel.claudeOpus.rawValue
            ).rawValue
        ])
        let selection = AgentModelCatalog.NormalizedAgentSelection(
            agent: .codexExec,
            modelRaw: AgentModel.gpt55CodexLow.rawValue
        )

        MCPAgentRoleDefaultsService.setSelection(
            selection,
            for: .explore,
            availability: actualAvailability,
            settingsStore: store
        )

        XCTAssertNil(store.overrides)
    }
}

@MainActor
private final class RoleDefaultsStoreStub: MCPAgentRoleDefaultsStoring {
    private(set) var overrides: [String: String]?

    init(overrides: [String: String]? = nil) {
        self.overrides = overrides
    }

    func globalMCPAgentRoleOverrides() -> [String: String]? {
        overrides
    }

    func updateGlobalMCPAgentRoleOverrides(_ overrides: [String: String]?, commit: Bool) {
        self.overrides = overrides
    }
}
