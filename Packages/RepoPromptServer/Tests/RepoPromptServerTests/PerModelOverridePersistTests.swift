import Foundation
@testable import RepoPromptHeadlessRuntime
@testable import RepoPromptServicePersistence
import RepoPromptServiceProtocol
import XCTest

@testable import RepoPromptServerHost
@testable import RepoPromptServerExecutable
final class PerModelOverridePersistTests: XCTestCase {
    func testMissingAndEmptyMapsAreValidAndDiffOverridesAreUnused() throws {
        XCTAssertEqual(AdvancedServerSettings.default.modelOverrides, .empty)
        XCTAssertTrue(AdvancedServerSettings.default.resolvedFileEditFormat(modelCapableOfDiff: true) == .diff)

        let legacy = try JSONDecoder.serviceDecoder.decode(
            AdvancedServerSettings.self,
            from: Data(#"{"historyIdleThresholdMinutes":10}"#.utf8)
        )
        XCTAssertEqual(legacy.modelOverrides, .empty)
        XCTAssertTrue(legacy.modelOverrides.resolvedStream(for: "gpt-test"))
        XCTAssertFalse(legacy.modelOverrides.resolvedUsesResponses(for: "gpt-test", isCustomProvider: true))
        XCTAssertNil(legacy.modelOverrides.resolvedTemperature(for: "gpt-test", globalAttached: nil))

        let emptyObject = try JSONDecoder.serviceDecoder.decode(
            ModelOverrideMaps.self,
            from: Data(#"{}"#.utf8)
        )
        XCTAssertEqual(emptyObject, .empty)

        let persistedDiff = ModelOverrideMaps(diffOverrides: ["gpt-test": false])
        XCTAssertEqual(persistedDiff.diffOverrides["gpt-test"], false)
        XCTAssertEqual(
            AdvancedServerSettings(modelOverrides: persistedDiff).resolvedFileEditFormat(modelCapableOfDiff: true),
            .diff
        )
        XCTAssertFalse(ModelOverrideMaps.empty.resolvedStream(for: "gpt-5.2-pro"))
        XCTAssertTrue(ModelOverrideMaps(streamOverrides: ["gpt-5.2-pro": true]).resolvedStream(for: "gpt-5.2-pro"))
    }

    func testPersistAndDirectProviderPayloadLiveReadsStreamResponsesAndTemperatureOverrides() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let service = ServerSettingsService(
            store: store,
            providerCatalog: EmptyOverrideCatalog(),
            projectCatalog: store
        )
        let attribution = SettingsMutationAttribution(actorID: "test", actorLabel: "Test", channel: "test")
        let maps = ModelOverrideMaps(
            diffOverrides: ["gpt-test": false],
            streamOverrides: ["gpt-test": false, "custom-model": true],
            temperatureOverrides: ["gpt-test": 0.0, "custom-model": 0.4],
            responsesOverrides: ["custom-model": true, "gpt-test": true]
        )
        let written = try await service.replaceAdvanced(
            .init(
                expectedRevision: 0,
                settings: .init(modelTemperature: 0.7, modelOverrides: maps)
            ),
            attribution: attribution
        )
        XCTAssertEqual(written.settings.modelOverrides, maps)
        XCTAssertEqual(written.settings.resolvedAttachedTemperature(), 0.7)
        XCTAssertEqual(written.settings.modelOverrides.resolvedTemperature(for: "gpt-test", globalAttached: 0.7), 0.0)
        XCTAssertFalse(written.settings.modelOverrides.resolvedStream(for: "gpt-test"))
        XCTAssertTrue(written.settings.modelOverrides.resolvedUsesResponses(for: "custom-model", isCustomProvider: true))
        XCTAssertFalse(written.settings.modelOverrides.resolvedUsesResponses(for: "gpt-test", isCustomProvider: false))

        let recovered = try await service.advanced()
        XCTAssertEqual(recovered.settings.modelOverrides, maps)

        let openAISettings = recovered.settings.stampedProviderSettings(
            ["provider.settingsID": ProviderSettingsID.openAIAPI.rawValue],
            modelRaw: "gpt-test"
        )
        XCTAssertEqual(openAISettings["models.stream"], "false")
        XCTAssertEqual(openAISettings["models.responses"], "false")
        XCTAssertEqual(openAISettings["models.temperature"], "0.0")

        let openAI = try DirectAPIProviderRuntime.mappedRequest(
            providerID: .openAIAPI,
            endpoint: ProviderEndpointPolicy.fixed(providerID: .openAIAPI),
            configuration: DirectProviderConfiguration(providerID: .openAIAPI, maximumOutputTokens: 2048),
            credential: "write-only-openai-secret",
            model: "gpt-test",
            prompt: "hello",
            settings: openAISettings
        )
        let openAIBody = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(openAI.body)) as? [String: Any])
        XCTAssertEqual(openAI.pathAndQuery, "/v1/chat/completions")
        XCTAssertEqual(openAIBody["stream"] as? Bool, false)
        XCTAssertEqual(openAIBody["temperature"] as? Double, 0.0)
        XCTAssertNil(openAIBody["input"])

        let customSettings = recovered.settings.stampedProviderSettings(
            ["provider.settingsID": ProviderSettingsID.customOpenAICompatible.rawValue],
            modelRaw: "custom-model"
        )
        XCTAssertEqual(customSettings["models.stream"], "true")
        XCTAssertEqual(customSettings["models.responses"], "true")
        XCTAssertEqual(customSettings["models.temperature"], "0.4")

        let custom = try DirectAPIProviderRuntime.mappedRequest(
            providerID: .customOpenAICompatible,
            endpoint: .init(scheme: "https", host: "example.com", port: 443, basePath: "/gateway/v1"),
            configuration: DirectProviderConfiguration(
                providerID: .customOpenAICompatible,
                baseURL: "https://example.com/gateway/v1",
                maximumOutputTokens: 1024
            ),
            credential: "write-only-custom-secret",
            model: "custom-model",
            prompt: "hello",
            settings: customSettings
        )
        let customBody = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(custom.body)) as? [String: Any])
        XCTAssertEqual(custom.pathAndQuery, "/gateway/v1/responses")
        XCTAssertEqual(customBody["stream"] as? Bool, true)
        XCTAssertEqual(customBody["input"] as? String, "hello")
        XCTAssertEqual(customBody["max_output_tokens"] as? Int, 1024)
        XCTAssertEqual(customBody["temperature"] as? Double, 0.4)
        XCTAssertNil(customBody["messages"])
        XCTAssertNil(customBody["max_tokens"])

        let responsesJSON = try await DirectAPIProviderRuntime.parseOutput(
            response: .init(
                statusCode: 200,
                contentType: "application/json",
                body: Data(#"{"output_text":"done"}"#.utf8)
            ),
            providerID: .customOpenAICompatible,
            maximumBytes: 32
        ) { _ in }
        XCTAssertEqual(responsesJSON, "done")

        let responsesSSE = try await DirectAPIProviderRuntime.parseOutput(
            response: .init(
                statusCode: 200,
                contentType: "text/event-stream",
                body: Data(#"data: {"type":"response.output_text.delta","delta":"hi"}"#.utf8)
            ),
            providerID: .customOpenAICompatible,
            maximumBytes: 32
        ) { _ in }
        XCTAssertEqual(responsesSSE, "hi")
    }

    func testInvalidOverrideMapsFailClosed() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let service = ServerSettingsService(
            store: store,
            providerCatalog: EmptyOverrideCatalog(),
            projectCatalog: store
        )
        let attribution = SettingsMutationAttribution(actorID: "test", actorLabel: "Test", channel: "test")

        await XCTAssertThrowsErrorAsync {
            _ = try await service.replaceAdvanced(
                .init(expectedRevision: 0, settings: .init(modelOverrides: .init(streamOverrides: ["": false]))),
                attribution: attribution
            )
        }
        await XCTAssertThrowsErrorAsync {
            _ = try await service.replaceAdvanced(
                .init(
                    expectedRevision: 0,
                    settings: .init(modelOverrides: .init(temperatureOverrides: ["gpt-test": 2.1]))
                ),
                attribution: attribution
            )
        }
        let oversized = Dictionary(uniqueKeysWithValues: (0 ... 256).map { ("model-\($0)", false) })
        await XCTAssertThrowsErrorAsync {
            _ = try await service.replaceAdvanced(
                .init(expectedRevision: 0, settings: .init(modelOverrides: .init(streamOverrides: oversized))),
                attribution: attribution
            )
        }
    }
}

private struct EmptyOverrideCatalog: ServerSettingsProviderCatalogProviding {
    func serverSettingsProviderCatalog() async throws -> ProviderSettingsCatalogResponse {
        .init(providers: [])
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @escaping () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected async expression to throw", file: file, line: line)
    } catch {}
}
