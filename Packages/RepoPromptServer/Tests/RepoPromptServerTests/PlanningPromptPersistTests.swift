import Foundation
import RepoPromptAgentRuntimeCore
@testable import RepoPromptHeadlessRuntime
@testable import RepoPromptServicePersistence
import RepoPromptServiceProtocol
import RepoPromptWorkspaceRuntimeCore
import XCTest

@testable import RepoPromptServerHost
@testable import RepoPromptServerExecutable
final class PlanningPromptPersistTests: XCTestCase {
    func testEmptyCustomFallsBackToArchitectAndCustomLiveReads() async throws {
        XCTAssertEqual(AdvancedServerSettings.default.customPlanningPrompt, "")
        XCTAssertTrue(AdvancedServerSettings.default.resolvedPlanningPrompt().contains("implementation-ready technical plan"))

        let legacy = try JSONDecoder.serviceDecoder.decode(
            AdvancedServerSettings.self,
            from: Data(#"{"historyIdleThresholdMinutes":10}"#.utf8)
        )
        XCTAssertEqual(legacy.customPlanningPrompt, "")
        XCTAssertEqual(legacy.historyIdleThresholdMinutes, 10)

        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let service = ServerSettingsService(
            store: store,
            providerCatalog: EmptyPlanningCatalog(),
            projectCatalog: store
        )
        let attribution = SettingsMutationAttribution(actorID: "test", actorLabel: "Test", channel: "test")
        let written = try await service.replaceAdvanced(
            .init(
                expectedRevision: 0,
                settings: .init(customPlanningPrompt: "  Custom plan system prompt  ")
            ),
            attribution: attribution
        )
        XCTAssertEqual(written.settings.customPlanningPrompt, "  Custom plan system prompt  ")
        XCTAssertEqual(written.settings.resolvedPlanningPrompt(), "Custom plan system prompt")

        let recovered = try await service.advanced()
        XCTAssertEqual(recovered.settings.resolvedPlanningPrompt(), "Custom plan system prompt")
    }

    func testPlanModeUsesStoredPlanningPromptInsteadOfOraclePreamble() async throws {
        let dispatcher = RecordingPlanningProvider()
        let runtime = ProviderOracleRuntimeService(providers: dispatcher)
        _ = try await runtime.ask(.init(
            sessionID: UUID(),
            prompt: "Plan the change",
            mode: "plan",
            selectedContext: "selected",
            priorTurns: [],
            providerSessionID: nil,
            provider: .codex,
            model: nil,
            workingDirectory: "/work",
            runID: UUID(),
            planningSystemPrompt: "Custom plan system prompt"
        ))
        let prompt = await dispatcher.lastPrompt()
        let recorded = try XCTUnwrap(prompt)
        XCTAssertTrue(recorded.contains("Custom plan system prompt"))
        XCTAssertTrue(recorded.contains("<mode>plan</mode>"))
        XCTAssertFalse(recorded.contains("You are RepoPrompt Oracle"))
    }
}

private struct EmptyPlanningCatalog: ServerSettingsProviderCatalogProviding {
    func serverSettingsProviderCatalog() async throws -> ProviderSettingsCatalogResponse {
        .init(providers: [])
    }
}

private actor RecordingPlanningProvider: AgentProviderDispatcher {
    private var prompt: String?

    func capabilities() -> [ProviderCapability] { [] }
    func preflight() -> [ProviderCapability] { [] }
    func recoverProcessFamilies() throws {}
    func cancel(runID _: UUID) throws {}
    func steer(runID _: UUID, text _: String, targetTurnEpoch _: Int64) throws {}
    func deliverInteraction(runID _: UUID, providerRequestID _: String, answer _: Data) throws {}

    func execute(
        kind _: ProviderKind,
        model _: String?,
        prompt: String,
        workingDirectory _: String,
        maximumBytes _: Int,
        runID _: UUID?,
        resumeProviderSessionID _: String?,
        onProviderSessionIdentity _: @escaping @Sendable (String) async -> Void
    ) async throws -> ProviderExecutionResult {
        self.prompt = prompt
        return .init(output: "ok", providerSessionID: "plan")
    }

    func lastPrompt() -> String? { prompt }
}
