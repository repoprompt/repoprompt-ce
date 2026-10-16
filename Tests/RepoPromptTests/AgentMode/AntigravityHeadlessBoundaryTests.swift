import Foundation
import MCP
import RepoPromptSettingsCore
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

final class AntigravityHeadlessBoundaryTests: XCTestCase {
    override func setUp() {
        super.setUp()
        GlobalSettingsStore.installApplicationModelIdentityPolicy()
    }

    private let availability = AgentModelCatalog.AvailabilityContext(
        claudeCodeAvailable: true,
        codexAvailable: true,
        openCodeAvailable: true,
        cursorAvailable: true,
        grokBuildAvailable: true,
        antigravityAvailable: true
    )

    func testGeneralCatalogIncludesAntigravityButHeadlessExcludesIt() {
        XCTAssertTrue(AgentModelCatalog.selectableAgents(availability: availability).contains(.antigravity))
        XCTAssertFalse(AgentModelCatalog.selectableAgents(availability: availability, surface: .headless).contains(.antigravity))
        XCTAssertTrue(AgentModelCatalog.discoveryAgents(availability: availability).contains { $0.agent == .antigravity })
        XCTAssertFalse(AgentModelCatalog.discoveryAgents(availability: availability, surface: .headless).contains { $0.agent == .antigravity })
    }

    @MainActor
    func testExplicitSelectionAllowsGeneralButRejectsHeadlessAntigravity() throws {
        let registry = AgentACPModelRegistry.shared
        registry.test_reset(providerID: .antigravity)
        defer { registry.test_reset(providerID: .antigravity) }
        let model = "gemini-test-model"
        _ = registry.updateDiscoveredModels(
            ACPDiscoveredSessionModels(
                options: [AgentModelOption(rawValue: model, displayName: model, description: nil, isDefault: true)],
                currentModelRaw: model
            ),
            for: .antigravity
        )

        let general = try AgentMCPSelectionResolver.resolve(
            modelID: "antigravity:\(model)", availability: availability, surface: .general
        )
        XCTAssertEqual(general.agentRaw, AgentProviderKind.antigravity.rawValue)
        XCTAssertThrowsError(try AgentMCPSelectionResolver.resolve(
            modelID: "antigravity:\(model)", availability: availability, surface: .headless
        ))
    }

    @MainActor
    func testStoredExploreOverridePreservesGeneralPinButFailsClosedHeadlessly() throws {
        let registry = AgentACPModelRegistry.shared
        registry.test_reset(providerID: .antigravity)
        let settings = GlobalSettingsStore.shared
        let previousOverrides = settings.mcpAgentRoleOverrides(scope: .global)
        defer {
            settings.updateMCPAgentRoleOverrides(previousOverrides, scope: .global, commit: true)
            registry.test_reset(providerID: .antigravity)
        }
        let model = "gemini-test-model"
        _ = registry.updateDiscoveredModels(
            ACPDiscoveredSessionModels(
                options: [AgentModelOption(rawValue: model, displayName: model, description: nil, isDefault: true)],
                currentModelRaw: model
            ),
            for: .antigravity
        )
        MCPAgentRoleDefaultsService.setSelection(
            .init(agent: .antigravity, modelRaw: model), for: .explore, scope: .global
        )

        let effective = try XCTUnwrap(MCPAgentRoleDefaultsService.effectiveSelection(for: .explore, availability: availability))
        XCTAssertTrue(effective.hasStoredOverride)
        XCTAssertFalse(effective.overrideUnavailable)
        XCTAssertEqual(effective.effective.agent, .antigravity)

        let general = try AgentMCPSelectionResolver.resolve(
            modelID: "explore", availability: availability, surface: .general
        )
        XCTAssertEqual(general.agentRaw, AgentProviderKind.antigravity.rawValue)
        XCTAssertThrowsError(try AgentMCPSelectionResolver.resolve(
            modelID: "explore", availability: availability, surface: .headless
        ))
    }

    func testHeadlessFactoryRejectsAntigravity() {
        let provider = AgentRuntimeProviderService.shared.makeProvider(for: .antigravity, modelString: nil)
        XCTAssertTrue(provider is UnsupportedHeadlessAgentProvider)
    }
}
