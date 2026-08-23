import Foundation
@testable import RepoPromptHeadlessRuntime
@testable import RepoPromptServicePersistence
import RepoPromptServiceProtocol
import XCTest

@testable import RepoPromptServerHost
@testable import RepoPromptServerExecutable
final class OpenAIFamilyPersistTests: XCTestCase {
    func testOpenAIPersistsCustomURLVersionAndModelTokenDefaults() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let registry = DirectProviderRegistry(
            store: store,
            transport: RecordingFamilyTransport(),
            deploymentAllowlist: [.openAIAPI]
        )
        try await registry.bootstrap()
        let initial = try await registry.configuration(for: .openAIAPI)
        XCTAssertNil(initial.baseURL)
        XCTAssertEqual(initial.maximumOutputTokens, 0)
        XCTAssertFalse(initial.showServiceTierVariants)

        let updated = try await registry.update(
            providerID: .openAIAPI,
            request: .init(
                expectedRevision: initial.revision,
                baseURL: "https://openai.example.com/v1",
                preferredModel: "gpt-5",
                maximumOutputTokens: 0,
                customHeaders: [:],
                apiVersion: "v1-beta",
                showServiceTierVariants: true
            ),
            attribution: .init(actorID: "test", actorLabel: "Test", channel: "test")
        )
        XCTAssertEqual(updated.baseURL, "https://openai.example.com/v1")
        XCTAssertEqual(updated.apiVersion, "v1-beta")
        XCTAssertTrue(updated.showServiceTierVariants)
        let endpoint = try await registry.endpoint(for: .openAIAPI)
        XCTAssertEqual(endpoint.host, "openai.example.com")
        XCTAssertEqual(endpoint.basePath, "/v1")

        let request = try DirectAPIProviderRuntime.mappedRequest(
            providerID: .openAIAPI,
            endpoint: endpoint,
            configuration: updated,
            credential: "write-only-openai-secret",
            model: "gpt-5",
            prompt: "hello",
            settings: [:]
        )
        XCTAssertEqual(request.pathAndQuery, "/v1-beta/chat/completions")
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.body)) as? [String: Any])
        XCTAssertEqual(body["max_tokens"] as? Int, 128_000)
        XCTAssertEqual(body["service_tier"] as? String, "auto")

        let official = try DirectAPIProviderRuntime.mappedRequest(
            providerID: .openAIAPI,
            endpoint: ProviderEndpointPolicy.fixed(providerID: .openAIAPI),
            configuration: DirectProviderConfiguration(providerID: .openAIAPI, maximumOutputTokens: 0),
            credential: "write-only-openai-secret",
            model: "gpt-4.1",
            prompt: "hello",
            settings: [:]
        )
        XCTAssertEqual(official.pathAndQuery, "/v1/chat/completions")
        let officialBody = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(official.body)) as? [String: Any])
        XCTAssertEqual(officialBody["max_tokens"] as? Int, 16_384)
    }

    func testAnthropicAndOpenRouterTokenAndHeaderContracts() throws {
        XCTAssertEqual(ProviderSettingsID.anthropicAPI.desktopBootstrapMaxTokens, 8192)
        XCTAssertEqual(ProviderSettingsID.openRouter.desktopBootstrapMaxTokens, 8192)

        let anthropic = try DirectAPIProviderRuntime.mappedRequest(
            providerID: .anthropicAPI,
            endpoint: ProviderEndpointPolicy.fixed(providerID: .anthropicAPI),
            configuration: DirectProviderConfiguration(providerID: .anthropicAPI, maximumOutputTokens: 0),
            credential: "write-only-anthropic-secret",
            model: "claude-test",
            prompt: "hello",
            settings: [:]
        )
        let anthropicBody = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(anthropic.body)) as? [String: Any])
        XCTAssertEqual(anthropicBody["max_tokens"] as? Int, 8192)

        let routerDefaults = try DirectAPIProviderRuntime.mappedRequest(
            providerID: .openRouter,
            endpoint: ProviderEndpointPolicy.fixed(providerID: .openRouter),
            configuration: DirectProviderConfiguration(
                providerID: .openRouter,
                maximumOutputTokens: 4096,
                customHeaders: ["X-Title": "Custom Title"],
                useCustomSettings: false
            ),
            credential: "write-only-router-secret",
            model: "provider/model",
            prompt: "hello",
            settings: [:]
        )
        let routerBody = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(routerDefaults.body)) as? [String: Any])
        XCTAssertEqual(routerBody["max_tokens"] as? Int, 8192)
        XCTAssertEqual(routerDefaults.headers["HTTP-Referer"], "https://repoprompt.com/")
        XCTAssertEqual(routerDefaults.headers["X-Title"], "Repo Prompt")

        let routerCustom = try DirectAPIProviderRuntime.mappedRequest(
            providerID: .openRouter,
            endpoint: ProviderEndpointPolicy.fixed(providerID: .openRouter),
            configuration: DirectProviderConfiguration(
                providerID: .openRouter,
                maximumOutputTokens: 2048,
                customHeaders: ["X-Title": "Custom Title"],
                useCustomSettings: true
            ),
            credential: "write-only-router-secret",
            model: "provider/model",
            prompt: "hello",
            settings: [:]
        )
        let customBody = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(routerCustom.body)) as? [String: Any])
        XCTAssertEqual(customBody["max_tokens"] as? Int, 2048)
        XCTAssertEqual(routerCustom.headers["X-Title"], "Custom Title")
        XCTAssertEqual(routerCustom.headers["HTTP-Referer"], "https://repoprompt.com/")
    }

    func testCustomAllowlistTokensAndAPIVersionAndOpenRouterDefaultsGate() throws {
        let custom = DirectProviderConfiguration(
            providerID: .customOpenAICompatible,
            baseURL: "https://example.com/gateway",
            preferredModel: "preferred-custom",
            maximumOutputTokens: 2048,
            apiVersion: "v4",
            enabledModels: ["allowed-a"],
            includeContentTypeHeader: false
        )
        let customCatalog = custom.resolvedCatalog(discovered: [
            ProviderModelCatalogEntry(id: "allowed-a", displayName: "A"),
            ProviderModelCatalogEntry(id: "hidden-b", displayName: "B")
        ])
        XCTAssertEqual(customCatalog.map(\.id), ["allowed-a", "preferred-custom"])
        XCTAssertTrue(custom.allowsLaunchModel("allowed-a"))
        XCTAssertTrue(custom.allowsLaunchModel("preferred-custom"))
        XCTAssertFalse(custom.allowsLaunchModel("hidden-b"))

        let request = try DirectAPIProviderRuntime.mappedRequest(
            providerID: .customOpenAICompatible,
            endpoint: .init(scheme: "https", host: "example.com", port: 443, basePath: "/gateway"),
            configuration: custom,
            credential: "write-only-custom-secret",
            model: "allowed-a",
            prompt: "hello",
            settings: [:]
        )
        XCTAssertEqual(request.pathAndQuery, "/gateway/v4/chat/completions")
        XCTAssertEqual(request.headers["Content-Type"], "application/json")
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.body)) as? [String: Any])
        XCTAssertNil(body["max_tokens"])

        let omittedZero = try DirectAPIProviderRuntime.mappedRequest(
            providerID: .customOpenAICompatible,
            endpoint: .init(scheme: "https", host: "example.com", port: 443, basePath: "/gateway/v1"),
            configuration: DirectProviderConfiguration(
                providerID: .customOpenAICompatible,
                baseURL: "https://example.com/gateway/v1",
                preferredModel: "preferred-custom",
                maximumOutputTokens: 0
            ),
            credential: "write-only-custom-secret",
            model: "preferred-custom",
            prompt: "hello",
            settings: [:]
        )
        let omittedBody = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(omittedZero.body)) as? [String: Any])
        XCTAssertNil(omittedBody["max_tokens"])

        let router = DirectProviderConfiguration(
            providerID: .openRouter,
            preferredModel: "keep/preferred",
            enabledModels: ["keep/allowlisted"],
            includeDefaultModels: false
        )
        let routerCatalog = router.resolvedCatalog(discovered: [
            ProviderModelCatalogEntry(id: "openrouter/default", displayName: "Default")
        ])
        XCTAssertEqual(routerCatalog.map(\.id), ["keep/allowlisted", "keep/preferred"])
        XCTAssertFalse(router.allowsLaunchModel("openrouter/default"))
        XCTAssertTrue(router.allowsLaunchModel("keep/allowlisted"))
    }

    func testLegacyConfigurationDecodesDesktopFamilyDefaults() throws {
        let legacy = try JSONDecoder.serviceDecoder.decode(
            DirectProviderConfiguration.self,
            from: Data(#"{"providerID":"openAIAPI","maximumOutputTokens":4096,"customHeaders":{},"contentTypePolicy":"applicationJSON","revision":1,"updatedAt":"2026-01-01T00:00:00Z"}"#.utf8)
        )
        XCTAssertEqual(legacy.enabledModels, [])
        XCTAssertTrue(legacy.includeDefaultModels)
        XCTAssertTrue(legacy.useCustomSettings)
        XCTAssertFalse(legacy.includeContentTypeHeader)
        XCTAssertFalse(legacy.showServiceTierVariants)
        XCTAssertNil(legacy.apiVersion)
    }
}

private actor RecordingFamilyTransport: ValidatedProviderEgressTransporting {
    func validateEndpoint(_ baseURL: String) async throws -> DirectProviderEndpoint {
        try ProviderEndpointPolicy.parseCustomBaseURL(baseURL)
    }

    func execute(_ request: ValidatedProviderHTTPRequest) async throws -> ValidatedProviderHTTPResponse {
        .init(statusCode: 200, contentType: "application/json", body: Data(#"{"data":[]}"#.utf8))
    }
}
