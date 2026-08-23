import Foundation
@testable import RepoPromptHeadlessRuntime
@testable import RepoPromptServicePersistence
import RepoPromptServiceProtocol
import XCTest

@testable import RepoPromptServerHost
@testable import RepoPromptServerExecutable
final class TemperaturePersistTests: XCTestCase {
    func testMissingEnableDefaultsOnAndZeroOmitsAttachment() throws {
        XCTAssertEqual(AdvancedServerSettings.default.modelTemperature, 0.0)
        XCTAssertTrue(AdvancedServerSettings.default.setModelTemperature)
        XCTAssertNil(AdvancedServerSettings.default.resolvedAttachedTemperature())

        let legacy = try JSONDecoder.serviceDecoder.decode(
            AdvancedServerSettings.self,
            from: Data(#"{"historyIdleThresholdMinutes":10}"#.utf8)
        )
        XCTAssertEqual(legacy.modelTemperature, 0.0)
        XCTAssertTrue(legacy.setModelTemperature)
        XCTAssertNil(legacy.resolvedAttachedTemperature())

        XCTAssertEqual(AdvancedServerSettings(modelTemperature: 0.7).resolvedAttachedTemperature(), 0.7)
        XCTAssertNil(AdvancedServerSettings(modelTemperature: 0.7, setModelTemperature: false).resolvedAttachedTemperature())
        XCTAssertNil(AdvancedServerSettings(modelTemperature: 0.0, setModelTemperature: true).resolvedAttachedTemperature())
    }

    func testPersistAndDirectProviderPayloadLiveReadsAttachedTemperature() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let service = ServerSettingsService(
            store: store,
            providerCatalog: EmptyTemperatureCatalog(),
            projectCatalog: store
        )
        let attribution = SettingsMutationAttribution(actorID: "test", actorLabel: "Test", channel: "test")
        let written = try await service.replaceAdvanced(
            .init(expectedRevision: 0, settings: .init(modelTemperature: 0.7)),
            attribution: attribution
        )
        XCTAssertEqual(written.settings.modelTemperature, 0.7)
        XCTAssertTrue(written.settings.setModelTemperature)
        XCTAssertEqual(written.settings.resolvedAttachedTemperature(), 0.7)

        let recovered = try await service.advanced()
        XCTAssertEqual(recovered.settings.resolvedAttachedTemperature(), 0.7)

        let attached = try DirectAPIProviderRuntime.mappedRequest(
            providerID: .openAIAPI,
            endpoint: ProviderEndpointPolicy.fixed(providerID: .openAIAPI),
            configuration: DirectProviderConfiguration(providerID: .openAIAPI, maximumOutputTokens: 2048),
            credential: "write-only-openai-secret",
            model: "gpt-test",
            prompt: "hello",
            settings: ["models.temperature": String(recovered.settings.resolvedAttachedTemperature()!)]
        )
        let attachedBody = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(attached.body)) as? [String: Any])
        XCTAssertEqual(attachedBody["temperature"] as? Double, 0.7)

        let omitted = try DirectAPIProviderRuntime.mappedRequest(
            providerID: .anthropicAPI,
            endpoint: ProviderEndpointPolicy.fixed(providerID: .anthropicAPI),
            configuration: DirectProviderConfiguration(providerID: .anthropicAPI, maximumOutputTokens: 2048),
            credential: "write-only-anthropic-secret",
            model: "claude-test",
            prompt: "hello",
            settings: [:]
        )
        let omittedBody = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(omitted.body)) as? [String: Any])
        XCTAssertNil(omittedBody["temperature"])
    }
}

private struct EmptyTemperatureCatalog: ServerSettingsProviderCatalogProviding {
    func serverSettingsProviderCatalog() async throws -> ProviderSettingsCatalogResponse {
        .init(providers: [])
    }
}
