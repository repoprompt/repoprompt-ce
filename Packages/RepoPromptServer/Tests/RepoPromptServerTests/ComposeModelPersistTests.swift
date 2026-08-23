import Foundation
@testable import RepoPromptHeadlessRuntime
@testable import RepoPromptServicePersistence
import RepoPromptServiceProtocol
import XCTest

@testable import RepoPromptServerHost
@testable import RepoPromptServerExecutable
final class ComposeModelPersistTests: XCTestCase {
    func testMissingSyncInfersOnOnlyWhenPlanningAndComposeMatch() {
        let matching = AgentModelsProfile(
            oracle: .init(providerID: .codex, modelID: "gpt-5.6-sol"),
            preferredComposeModelRaw: "gpt-5.6-sol"
        )
        XCTAssertTrue(matching.resolvedSyncChatModelWithOracle())
        XCTAssertEqual(matching.resolvedComposeModelRaw(), "gpt-5.6-sol")

        let diverged = AgentModelsProfile(
            oracle: .init(providerID: .codex, modelID: "gpt-5.6-sol"),
            preferredComposeModelRaw: "claude-sonnet-5"
        )
        XCTAssertFalse(diverged.resolvedSyncChatModelWithOracle())
        XCTAssertEqual(diverged.resolvedComposeModelRaw(), "claude-sonnet-5")

        let empty = AgentModelsProfile()
        XCTAssertFalse(empty.resolvedSyncChatModelWithOracle())
        XCTAssertNil(empty.resolvedComposeModelRaw())
    }

    func testPersistAndLiveReadComposeAndSyncThroughAgentModelsStore() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let service = ServerSettingsService(
            store: store,
            providerCatalog: ComposeModelCatalog(),
            projectCatalog: store
        )
        let attribution = SettingsMutationAttribution(actorID: "test", actorLabel: "Test", channel: "test")

        let written = try await service.replaceGlobalAgentModels(
            .init(
                expectedRevision: 0,
                profile: .init(
                    oracle: .init(providerID: .codex, modelID: "gpt-5.6-sol"),
                    preferredComposeModelRaw: "claude-sonnet-5",
                    syncChatModelWithOracle: false
                )
            ),
            attribution: attribution
        )
        XCTAssertEqual(written.effectiveProfile.preferredComposeModelRaw, "claude-sonnet-5")
        XCTAssertEqual(written.effectiveProfile.syncChatModelWithOracle, false)
        XCTAssertEqual(written.effectiveProfile.resolvedComposeModelRaw(), "claude-sonnet-5")
        XCTAssertFalse(written.effectiveProfile.resolvedSyncChatModelWithOracle())

        let synced = try await service.replaceGlobalAgentModels(
            .init(
                expectedRevision: written.globalRevision,
                profile: written.globalProfile.replacingSyncChatModelWithOracle(true)
            ),
            attribution: attribution
        )
        XCTAssertEqual(synced.effectiveProfile.preferredComposeModelRaw, "gpt-5.6-sol")
        XCTAssertEqual(synced.effectiveProfile.syncChatModelWithOracle, true)
        XCTAssertEqual(synced.effectiveProfile.resolvedComposeModelRaw(), "gpt-5.6-sol")

        let diverged = try await service.replaceGlobalAgentModels(
            .init(
                expectedRevision: synced.globalRevision,
                profile: synced.globalProfile.replacingComposeModel("claude-sonnet-5")
            ),
            attribution: attribution
        )
        XCTAssertEqual(diverged.effectiveProfile.preferredComposeModelRaw, "claude-sonnet-5")
        XCTAssertEqual(diverged.effectiveProfile.syncChatModelWithOracle, false)
        XCTAssertEqual(diverged.effectiveProfile.resolvedComposeModelRaw(), "claude-sonnet-5")
    }

    func testApplyRecommendedWritesComposeToOracleModel() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let service = ServerSettingsService(
            store: store,
            providerCatalog: ComposeModelCatalog(),
            projectCatalog: store
        )
        let attribution = SettingsMutationAttribution(actorID: "test", actorLabel: "Test", channel: "test")
        let seeded = try await service.replaceGlobalAgentModels(
            .init(
                expectedRevision: 0,
                profile: .init(
                    oracle: .init(providerID: .claudeCompatible, modelID: "claude-sonnet-5"),
                    preferredComposeModelRaw: "claude-sonnet-5",
                    syncChatModelWithOracle: false
                )
            ),
            attribution: attribution
        )
        let applied = try await service.applyGlobalAgentModelRecommendations(
            .init(expectedRevision: seeded.globalRevision),
            attribution: attribution
        )
        XCTAssertEqual(applied.effectiveProfile.oracle?.modelID, "gpt-5.6-sol")
        XCTAssertEqual(applied.effectiveProfile.resolvedComposeModelRaw(), "gpt-5.6-sol")
    }
}

private struct ComposeModelCatalog: ServerSettingsProviderCatalogProviding {
    func serverSettingsProviderCatalog() async throws -> ProviderSettingsCatalogResponse {
        .init(providers: [
            .init(
                providerID: .codex,
                displayName: "codex",
                category: .cliProvider,
                summary: "test",
                deploymentAllowed: true,
                runtimePreflightVerified: true,
                effectiveEnabled: true,
                preference: .init(providerID: .codex, enabled: true),
                cli: nil,
                authentication: .init(state: .authenticated, authenticated: true),
                capabilities: .init(
                    supportsModelSelection: true,
                    supportsReasoningEffort: true,
                    supportsSpeedMode: false,
                    supportsServiceTier: false,
                    authenticationMethods: [],
                    authFlows: []
                ),
                models: [.init(id: "gpt-5.6-sol", displayName: "GPT-5.6 Sol", reasoningEfforts: ["high"])]
            ),
            .init(
                providerID: .claudeCompatible,
                displayName: "claude",
                category: .cliProvider,
                summary: "test",
                deploymentAllowed: true,
                runtimePreflightVerified: true,
                effectiveEnabled: true,
                preference: .init(providerID: .claudeCompatible, enabled: true),
                cli: nil,
                authentication: .init(state: .authenticated, authenticated: true),
                capabilities: .init(
                    supportsModelSelection: true,
                    supportsReasoningEffort: false,
                    supportsSpeedMode: false,
                    supportsServiceTier: false,
                    authenticationMethods: [],
                    authFlows: []
                ),
                models: [.init(id: "claude-sonnet-5", displayName: "Claude Sonnet 5")]
            )
        ])
    }
}
