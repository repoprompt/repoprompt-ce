import Foundation
@_spi(TestSupport) @testable import RepoPrompt
import XCTest

@MainActor
final class GrokProviderWiringTests: XCTestCase {
    func testAgentProviderIdentityAndACPFactoryAreWired() throws {
        let agent = AgentProviderKind.grokBuild

        XCTAssertEqual(agent.commandName, "grok")
        XCTAssertEqual(agent.displayName, "Grok Build CLI")
        XCTAssertEqual(agent.mcpClientNameHint, "grok")
        XCTAssertEqual(agent.acpProviderID, .grok)
        XCTAssertEqual(agent.providerBindingID, .grok)
        XCTAssertEqual(agent.runtimeKind, "grok_acp")
        XCTAssertFalse(agent.usesClaudeNativeRuntime)
        XCTAssertFalse(agent.usesClaudeTooling)
        XCTAssertFalse(agent.requiresPrePromptAgentModeMCPRouting)
        XCTAssertTrue(AgentRuntimeProviderService.shared.makeProvider(for: .grokBuild) is GrokACPHeadlessAgentProvider)

        let provider = try XCTUnwrap(ACPAgentProviderFactory.makeProvider(for: .grokBuild, modelString: nil))
        XCTAssertEqual(provider.providerID, .grok)
    }

    func testCatalogKeepsGrokUnavailableUntilExplicitSupportIsKnown() throws {
        XCTAssertFalse(AgentModelCatalog.isAgentAvailable(.grokBuild, availability: .current))
        XCTAssertFalse(AgentModelCatalog.selectableAgents(availability: .current).contains(.grokBuild))

        let discovery = try XCTUnwrap(AgentModelCatalog.discoveryAgents(availability: .current).first { $0.agent == .grokBuild })
        XCTAssertFalse(discovery.available)
        XCTAssertNil(discovery.defaults.modelRaw)
        XCTAssertNil(discovery.defaults.selectionID)
        XCTAssertEqual(discovery.models.map(\.id), [])
    }

    func testCatalogExposesGrokWithDefaultModelForManualSelectionAndDiscovery() throws {
        let availability = AgentModelCatalog.AvailabilityContext(
            claudeCodeAvailable: false,
            codexAvailable: false,
            openCodeAvailable: false,
            cursorAvailable: false,
            grokAvailable: true,
            zaiConfigured: false,
            kimiConfigured: false,
            customClaudeCompatibleConfigured: false
        )

        XCTAssertTrue(AgentModelCatalog.selectableAgents(availability: availability).contains(.grokBuild))
        XCTAssertEqual(AgentModelCatalog.defaultModelRaw(for: .grokBuild, availability: availability), AgentModel.grokComposer25Fast.rawValue)
        XCTAssertEqual(
            AgentModelCatalog.options(for: .grokBuild, availability: availability).map(\.rawValue),
            [AgentModel.grokComposer25Fast.rawValue, AgentModel.grokBuild.rawValue]
        )
        XCTAssertTrue(AgentModelCatalog.isValid(rawModel: AgentModel.grokBuild.rawValue, for: .grokBuild, availability: availability))
        XCTAssertTrue(AgentModelCatalog.isValid(rawModel: AgentModel.grokComposer25Fast.rawValue, for: .grokBuild, availability: availability))

        let discovery = try XCTUnwrap(AgentModelCatalog.discoveryAgents(availability: availability).first { $0.agent == .grokBuild })
        XCTAssertTrue(discovery.available)
        XCTAssertEqual(discovery.runtime, "grok_acp")
        XCTAssertEqual(discovery.defaults.modelRaw, AgentModel.grokComposer25Fast.rawValue)
        XCTAssertEqual(discovery.defaults.selectionID?.rawValue, "grokBuild:\(AgentModel.grokComposer25Fast.rawValue)")
        XCTAssertEqual(discovery.models.map(\.id), [AgentModel.grokComposer25Fast.rawValue, AgentModel.grokBuild.rawValue])
    }

    func testGrokIgnoresACPDiscoveredModelsUntilModelSwitchingIsValidated() {
        AgentACPModelRegistry.shared.test_reset(providerID: .grok)
        addTeardownBlock {
            AgentACPModelRegistry.shared.test_reset(providerID: .grok)
        }

        let liveModelRaw = "grok-live-model"
        let changed = AgentACPModelRegistry.shared.updateDiscoveredModels(
            ACPDiscoveredSessionModels(
                options: [AgentModelOption(
                    rawValue: liveModelRaw,
                    displayName: "Grok Live Model",
                    description: nil,
                    isPlaceholderDefault: false,
                    isProviderDefault: true
                )],
                currentModelRaw: liveModelRaw
            ),
            for: .grok
        )
        XCTAssertFalse(changed)
        XCTAssertNil(AgentACPModelRegistry.shared.test_snapshot(providerID: .grok))

        let availability = AgentModelCatalog.AvailabilityContext(
            claudeCodeAvailable: false,
            codexAvailable: false,
            openCodeAvailable: false,
            cursorAvailable: false,
            grokAvailable: true,
            zaiConfigured: false,
            kimiConfigured: false,
            customClaudeCompatibleConfigured: false
        )
        XCTAssertEqual(AgentModelCatalog.defaultModelRaw(for: .grokBuild, availability: availability), AgentModel.grokComposer25Fast.rawValue)
        XCTAssertEqual(
            AgentModelCatalog.options(for: .grokBuild, availability: availability).map(\.rawValue),
            [AgentModel.grokComposer25Fast.rawValue, AgentModel.grokBuild.rawValue]
        )
        XCTAssertFalse(AgentModelCatalog.isValid(rawModel: liveModelRaw, for: .grokBuild, availability: availability))
    }

    func testGrokPermissionBindingIsDistinctAndControlsACPAutoApproval() throws {
        let suiteName = "GrokProviderWiringTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AgentProviderPreferenceSnapshotStore(defaults: defaults, securePermissions: nil)

        let initial = store.controlsBinding(
            selectedAgent: .grokBuild,
            permissionProfile: .userConfigured,
            isSubagent: false,
            externallyManagedReason: nil
        )
        XCTAssertEqual(initial.providerID, .grok)
        XCTAssertEqual(initial.permission.displayName, GrokAgentToolPreferences.PermissionLevel.managedDefault.displayName)
        XCTAssertFalse(initial.runtimePermission.autoApproveAllACPToolPermissions)
        XCTAssertEqual(initial.permission.options.map(\.id), [
            .grok(.managedDefault),
            .grok(.fullAccess)
        ])

        XCTAssertEqual(store.setPermissionLevel(.grok(.fullAccess)), .grok)
        let updated = store.controlsBinding(
            selectedAgent: .grokBuild,
            permissionProfile: .userConfigured,
            isSubagent: false,
            externallyManagedReason: nil
        )
        XCTAssertEqual(updated.permission.displayName, GrokAgentToolPreferences.PermissionLevel.fullAccess.displayName)
        XCTAssertTrue(updated.permission.isWarning)
        XCTAssertTrue(updated.runtimePermission.autoApproveAllACPToolPermissions)
        XCTAssertTrue(updated.runtimePermission.acceptsPendingACPApprovalWhenActivated)

        let safeManaged = store.controlsBinding(
            selectedAgent: .grokBuild,
            permissionProfile: .mcpSafeDefaults,
            isSubagent: true,
            externallyManagedReason: nil
        )
        XCTAssertEqual(safeManaged.permission.displayName, GrokAgentToolPreferences.PermissionLevel.managedDefault.displayName)
        XCTAssertFalse(safeManaged.runtimePermission.autoApproveAllACPToolPermissions)
    }
}
