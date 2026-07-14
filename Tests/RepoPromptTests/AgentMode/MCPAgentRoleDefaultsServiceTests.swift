@testable import RepoPromptApp
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
        XCTAssertEqual(resolutions[0].recommended.modelRaw, AgentModel.gpt56SolLow.rawValue)
        XCTAssertEqual(resolutions[1].recommended.agent, .codexExec)
        XCTAssertEqual(resolutions[1].recommended.modelRaw, AgentModel.gpt56SolMedium.rawValue)
        XCTAssertEqual(resolutions[2].recommended.agent, .codexExec)
        XCTAssertEqual(resolutions[2].recommended.modelRaw, AgentModel.gpt56SolHigh.rawValue)
        XCTAssertEqual(resolutions[3].recommended.agent, .codexExec)
        XCTAssertEqual(resolutions[3].recommended.modelRaw, AgentModel.gpt56SolMedium.rawValue)
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

    func testWorkspaceOverrideResolvesIndependentlyFromGlobalOverride() throws {
        let workspaceID = UUID()
        let availability = AgentModelCatalog.AvailabilityContext(
            claudeCodeAvailable: false,
            codexAvailable: true,
            openCodeAvailable: false,
            cursorAvailable: false,
            zaiConfigured: false,
            kimiConfigured: false,
            customClaudeCompatibleConfigured: false
        )
        let store = RoleDefaultsStoreStub(
            overrides: [
                AgentModelCatalog.TaskLabelKind.explore.rawValue: AgentModelSelectionID(
                    agentRaw: AgentProviderKind.codexExec.rawValue,
                    modelRaw: AgentModel.gpt55CodexHigh.rawValue
                ).rawValue
            ],
            workspaceOverrides: [
                workspaceID: [
                    AgentModelCatalog.TaskLabelKind.explore.rawValue: AgentModelSelectionID(
                        agentRaw: AgentProviderKind.codexExec.rawValue,
                        modelRaw: AgentModel.gpt55CodexMedium.rawValue
                    ).rawValue
                ]
            ]
        )

        let global = try XCTUnwrap(MCPAgentRoleDefaultsService.effectiveSelection(
            for: .explore,
            availability: availability,
            settingsStore: store
        ))
        let workspace = try XCTUnwrap(MCPAgentRoleDefaultsService.effectiveSelection(
            for: .explore,
            availability: availability,
            workspaceID: workspaceID,
            settingsStore: store
        ))

        XCTAssertEqual(global.effective.modelRaw, AgentModel.gpt55CodexHigh.rawValue)
        XCTAssertEqual(workspace.effective.modelRaw, AgentModel.gpt55CodexMedium.rawValue)
    }

    /// Regression for the sub-agent role "reset after restart" bug: an explicit role pick
    /// must persist even when it currently equals the (transient, availability-dependent)
    /// recommendation. Previously setSelection dropped the override on a recommendation
    /// match, so nothing was stored and the role silently drifted to a different model when
    /// the recommendation later changed.
    func testSetSelectionPersistsExplicitPickEvenWhenItMatchesRecommendation() throws {
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
        // This selection equals the fallback recommendation for `.explore` under this availability.
        let selection = AgentModelCatalog.NormalizedAgentSelection(
            agent: .codexExec,
            modelRaw: AgentModel.gpt56SolLow.rawValue
        )

        MCPAgentRoleDefaultsService.setSelection(
            selection,
            for: .explore,
            scope: .global,
            settingsStore: store
        )

        let expected = AgentModelSelectionID(
            agentRaw: selection.agent.rawValue,
            modelRaw: selection.modelRaw
        ).rawValue
        XCTAssertEqual(store.overrides?[AgentModelCatalog.TaskLabelKind.explore.rawValue], expected)
        XCTAssertEqual(
            MCPAgentRoleDefaultsService.effectiveNormalizedSelection(
                for: .explore,
                availability: actualAvailability,
                settingsStore: store
            ),
            selection
        )

        let resolution = try XCTUnwrap(MCPAgentRoleDefaultsService.effectiveSelection(
            for: .explore,
            availability: actualAvailability,
            settingsStore: store
        ))
        XCTAssertTrue(resolution.hasStoredOverride)
        XCTAssertFalse(resolution.hasCustomOverride)
        XCTAssertFalse(resolution.overrideUnavailable)
        XCTAssertEqual(resolution.effective, selection)
    }

    /// Guards the persist-always change: reverting a role to recommendation-tracking stays
    /// an explicit action via clearOverride.
    func testClearOverrideStillRevertsRoleToRecommendedTracking() throws {
        let availability = AgentModelCatalog.AvailabilityContext(
            claudeCodeAvailable: false,
            codexAvailable: true,
            openCodeAvailable: false,
            cursorAvailable: false,
            zaiConfigured: false,
            kimiConfigured: false,
            customClaudeCompatibleConfigured: false
        )
        let store = RoleDefaultsStoreStub()
        MCPAgentRoleDefaultsService.setSelection(
            AgentModelCatalog.NormalizedAgentSelection(
                agent: .codexExec,
                modelRaw: AgentModel.gpt56SolHigh.rawValue
            ),
            for: .engineer,
            scope: .global,
            settingsStore: store
        )
        XCTAssertNotNil(store.overrides?[AgentModelCatalog.TaskLabelKind.engineer.rawValue])
        let pinnedResolution = try XCTUnwrap(MCPAgentRoleDefaultsService.effectiveSelection(
            for: .engineer,
            availability: availability,
            settingsStore: store
        ))
        XCTAssertTrue(pinnedResolution.hasStoredOverride)
        XCTAssertTrue(pinnedResolution.hasCustomOverride)

        MCPAgentRoleDefaultsService.clearOverride(for: .engineer, scope: .global, settingsStore: store)
        XCTAssertNil(store.overrides?[AgentModelCatalog.TaskLabelKind.engineer.rawValue])
        let clearedResolution = try XCTUnwrap(MCPAgentRoleDefaultsService.effectiveSelection(
            for: .engineer,
            availability: availability,
            settingsStore: store
        ))
        XCTAssertFalse(clearedResolution.hasStoredOverride)
        XCTAssertFalse(clearedResolution.hasCustomOverride)
    }

    func testExplicitWorkspaceResetDoesNotMutateGlobalAndStaleNonCodexPinDoesNotExecute() throws {
        let workspaceID = UUID()
        let stale = AgentModelSelectionID(agentRaw: AgentProviderKind.claudeCode.rawValue, modelRaw: "removed-model").rawValue
        let global = AgentModelSelectionID(agentRaw: AgentProviderKind.codexExec.rawValue, modelRaw: "dynamic-model").rawValue
        let store = RoleDefaultsStoreStub(
            overrides: [AgentModelCatalog.TaskLabelKind.engineer.rawValue: global],
            workspaceOverrides: [workspaceID: [AgentModelCatalog.TaskLabelKind.engineer.rawValue: stale]]
        )
        let availability = AgentModelCatalog.AvailabilityContext(
            claudeCodeAvailable: true,
            codexAvailable: true,
            openCodeAvailable: false,
            cursorAvailable: false,
            zaiConfigured: false,
            kimiConfigured: false,
            customClaudeCompatibleConfigured: false
        )

        let resolution = try XCTUnwrap(MCPAgentRoleDefaultsService.effectiveSelection(
            for: .engineer,
            availability: availability,
            workspaceID: workspaceID,
            settingsStore: store
        ))
        XCTAssertTrue(resolution.overrideUnavailable)
        XCTAssertNotEqual(resolution.effective.modelRaw, "removed-model")

        MCPAgentRoleDefaultsService.clearOverride(
            for: .engineer,
            scope: .workspace(workspaceID),
            settingsStore: store
        )
        XCTAssertEqual(store.overrides?[AgentModelCatalog.TaskLabelKind.engineer.rawValue], global)
        XCTAssertNil(store.workspaceOverrides[workspaceID]?[AgentModelCatalog.TaskLabelKind.engineer.rawValue])
    }
}

@MainActor
private final class RoleDefaultsStoreStub: MCPAgentRoleDefaultsStoring {
    private(set) var overrides: [String: String]?
    private(set) var workspaceOverrides: [UUID: [String: String]]

    init(overrides: [String: String]? = nil, workspaceOverrides: [UUID: [String: String]] = [:]) {
        self.overrides = overrides
        self.workspaceOverrides = workspaceOverrides
    }

    func mcpAgentRoleOverrides(workspaceID: UUID?) -> [String: String]? {
        guard let workspaceID else { return overrides }
        return workspaceOverrides[workspaceID]
    }

    func mcpAgentRoleOverrides(scope: AgentModelsEditingScope) -> [String: String]? {
        switch scope {
        case .global:
            overrides
        case let .workspace(workspaceID):
            workspaceOverrides[workspaceID]
        }
    }

    func updateMCPAgentRoleOverrides(_ overrides: [String: String]?, scope: AgentModelsEditingScope, commit _: Bool) {
        guard case let .workspace(workspaceID) = scope else {
            self.overrides = overrides
            return
        }
        workspaceOverrides[workspaceID] = overrides
    }
}
