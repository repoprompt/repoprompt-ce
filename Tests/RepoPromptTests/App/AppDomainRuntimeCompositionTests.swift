@testable import RepoPromptApp
import XCTest

final class AppDomainRuntimeCompositionTests: XCTestCase {
    func testDesktopSettingsContractSnapshotAndRawValueRoundTrip() throws {
        XCTAssertEqual(GlobalSettingsDocument.baselineSchemaVersion, 2)
        XCTAssertEqual(GlobalSettingsDocument.workspaceAgentModelsSchemaVersion, 4)
        XCTAssertEqual(GlobalSettingsDocument.currentSchemaVersion, 4)
        XCTAssertEqual(GlobalSettingsDocument.schemaLineage, "repoprompt-ce.global-settings")
        XCTAssertEqual(GlobalSettingsDocument.legacyUnlineagedSchemaVersionCeiling, 2)
        XCTAssertEqual(AgentModelsInheritanceMode.useGlobalSettings.rawValue, "useGlobalSettings")
        XCTAssertEqual(AgentModelsInheritanceMode.useWorkspaceOverrides.rawValue, "useWorkspaceOverrides")
        XCTAssertEqual(WorktreeVisualMarkerStyle.dot.rawValue, "dot")
        XCTAssertEqual(WorktreeVisualMarkerStyle.ring.rawValue, "ring")
        XCTAssertEqual(WorktreeVisualMarkerStyle.capsule.rawValue, "capsule")

        let behavior = ContextBuilderDefaults.behaviorSettings
        XCTAssertEqual(behavior.contextTokenBudget, 160_000)
        XCTAssertEqual(behavior.analysisTokenBudget, 120_000)
        XCTAssertEqual(behavior.enhancementMode, .fullRewrite)
        XCTAssertEqual(behavior.questionTimeoutSeconds, 300)
        XCTAssertTrue(behavior.allowUIClarifyingQuestions)
        XCTAssertFalse(behavior.allowMCPClarifyingQuestions)
        XCTAssertFalse(behavior.followUpAnalysisEnabled)

        let stored = AgentModelsSettingsProfile(
            planningModelRaw: "legacy_oracle_raw",
            preferredComposeModelRaw: "legacy_compose_raw",
            syncChatModelWithOracle: true,
            contextBuilderAgentRaw: "legacy_agent_raw",
            contextBuilderModelsByAgent: ["legacy_agent_raw": "legacy_model_raw"],
            mcpAgentRoleOverrides: ["engineer": "legacy_agent_raw:legacy_model_raw"],
            restrictMCPAgentDiscoveryToRoleLabels: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(stored)
        let decoded = try JSONDecoder().decode(AgentModelsSettingsProfile.self, from: encoded)

        XCTAssertEqual(decoded, stored)
        XCTAssertEqual(try encoder.encode(decoded), encoded)
        XCTAssertEqual(
            String(decoding: encoded, as: UTF8.self),
            #"{"contextBuilderAgentRaw":"legacy_agent_raw","contextBuilderModelsByAgent":{"legacy_agent_raw":"legacy_model_raw"},"mcpAgentRoleOverrides":{"engineer":"legacy_agent_raw:legacy_model_raw"},"planningModelRaw":"legacy_oracle_raw","preferredComposeModelRaw":"legacy_compose_raw","restrictMCPAgentDiscoveryToRoleLabels":true,"syncChatModelWithOracle":true}"#
        )
    }

    func testCollectLegacyRuntimeDefaultsSerializesBooleanScalarFragments() throws {
        for value in [true, false] {
            let (defaults, suiteName) = try makeIsolatedDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }
            defaults.set(value, forKey: "agentModeAutoEditEnabled")

            let collected = AppDomainRuntimeComposition.collectLegacyRuntimeDefaults(from: defaults)
            let data = try XCTUnwrap(collected["agentModeAutoEditEnabled"])

            XCTAssertEqual(try JSONDecoder().decode(Bool.self, from: data), value)
            XCTAssertEqual(String(decoding: data, as: UTF8.self), value ? "true" : "false")
        }
    }

    func testCollectLegacyRuntimeDefaultsPreservesRawDataAlongsideBoolean() throws {
        let (defaults, suiteName) = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let approvalBytes = Data([0x00, 0xFF, 0x7B, 0x01])
        defaults.set(approvalBytes, forKey: "workspace.approvalSettings")
        defaults.set(false, forKey: "agentModeAutoEditEnabled")

        let collected = AppDomainRuntimeComposition.collectLegacyRuntimeDefaults(from: defaults)

        XCTAssertEqual(collected["workspace.approvalSettings"], approvalBytes)
        let booleanData = try XCTUnwrap(collected["agentModeAutoEditEnabled"])
        XCTAssertFalse(try JSONDecoder().decode(Bool.self, from: booleanData))
    }

    func testCollectLegacyRuntimeDefaultsSkipsInvalidValueWithoutMutationAndIsRepeatable() throws {
        let (defaults, suiteName) = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let invalidDate = Date(timeIntervalSince1970: 1_725_000_000)
        defaults.set(invalidDate, forKey: "workspace.approvalSettings")
        defaults.set(true, forKey: "agentModeAutoEditEnabled")

        let first = AppDomainRuntimeComposition.collectLegacyRuntimeDefaults(from: defaults)
        let second = AppDomainRuntimeComposition.collectLegacyRuntimeDefaults(from: defaults)

        XCTAssertEqual(first, second)
        XCTAssertNil(first["workspace.approvalSettings"])
        let booleanData = try XCTUnwrap(first["agentModeAutoEditEnabled"])
        XCTAssertTrue(try JSONDecoder().decode(Bool.self, from: booleanData))
        XCTAssertEqual(defaults.object(forKey: "workspace.approvalSettings") as? Date, invalidDate)
        XCTAssertEqual(defaults.object(forKey: "agentModeAutoEditEnabled") as? Bool, true)
    }

    private func makeIsolatedDefaults() throws -> (defaults: UserDefaults, suiteName: String) {
        let suiteName = "AppDomainRuntimeCompositionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
