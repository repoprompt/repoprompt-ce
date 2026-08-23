import Foundation
@testable import RepoPromptHeadlessRuntime
import RepoPromptServicePersistence
import RepoPromptServiceProtocol
import XCTest

@testable import RepoPromptServerHost
@testable import RepoPromptServerExecutable
final class DirectAdapterPersistTests: XCTestCase {
    func testDesktopDirectAdaptersPersistAndResolveFixedHosts() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let registry = DirectProviderRegistry(
            store: store,
            transport: RecordingAdapterTransport(),
            deploymentAllowlist: Set(ProviderSettingsID.directAPIProviders)
        )
        try await registry.bootstrap()

        let expectedHosts: [(ProviderSettingsID, String, String, String)] = [
            (.gemini, "gemini", "generativelanguage.googleapis.com", "/v1beta"),
            (.deepseek, "deepseek", "api.deepseek.com", "/v1"),
            (.fireworks, "fireworks", "api.fireworks.ai", "/inference/v1"),
            (.xAI, "xAI", "api.x.ai", "/v1"),
            (.groq, "groq", "api.groq.com", "/openai/v1"),
            (.zAI, "zAI", "api.z.ai", "/api/paas/v4")
        ]
        for (providerID, rawValue, host, basePath) in expectedHosts {
            XCTAssertEqual(providerID.rawValue, rawValue)
            XCTAssertTrue(providerID.isDirectAPI)
            XCTAssertTrue(providerID.requiresVaultCredential)
            XCTAssertEqual(providerID.runtimeKind, .headlessAdapter)
            let persisted = try await registry.configuration(for: providerID)
            XCTAssertNil(persisted.baseURL)
            XCTAssertNil(persisted.preferredModel)
            XCTAssertEqual(persisted.maximumOutputTokens, providerID == .groq ? 16_384 : 4096)
            let endpoint = try ProviderEndpointPolicy.fixed(providerID: providerID)
            XCTAssertEqual(endpoint.host, host)
            XCTAssertEqual(endpoint.basePath, basePath)
            let request = try DirectAPIProviderRuntime.mappedRequest(
                providerID: providerID,
                endpoint: endpoint,
                configuration: persisted,
                credential: "write-only-\(rawValue)-secret",
                model: "desktop-custom",
                prompt: "hello",
                settings: [:]
            )
            XCTAssertEqual(request.pathAndQuery, "\(basePath)/chat/completions")
            XCTAssertEqual(request.headers["Authorization"], "Bearer write-only-\(rawValue)-secret")
            XCTAssertNil(request.headers["api-key"])
        }
    }

    func testAzurePersistRequiresResourceURLAndAPIVersionAndMapsDeploymentPath() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let registry = DirectProviderRegistry(
            store: store,
            transport: RecordingAdapterTransport(),
            deploymentAllowlist: [.azure]
        )
        try await registry.bootstrap()
        let initial = try await registry.configuration(for: .azure)
        XCTAssertNil(initial.baseURL)
        XCTAssertNil(initial.apiVersion)
        XCTAssertThrowsError(try ProviderEndpointPolicy.fixed(providerID: .azure))

        await XCTAssertThrowsErrorAsync {
            _ = try await registry.endpoint(for: .azure)
        }

        let updated = try await registry.update(
            providerID: .azure,
            request: .init(
                expectedRevision: initial.revision,
                baseURL: "https://rpce-azure.openai.azure.com",
                preferredModel: "gpt-test-custom",
                maximumOutputTokens: 8192,
                customHeaders: ["X-Title": "RepoPrompt"],
                apiVersion: "2024-10-21"
            ),
            attribution: .init(actorID: "test", actorLabel: "Test", channel: "test")
        )
        XCTAssertEqual(updated.baseURL, "https://rpce-azure.openai.azure.com")
        XCTAssertEqual(updated.apiVersion, "2024-10-21")
        XCTAssertEqual(updated.preferredModel, "gpt-test-custom")
        XCTAssertEqual(updated.customHeaders["X-Title"], "RepoPrompt")

        let recovered = try await store.directProviderConfiguration(providerID: .azure)
        XCTAssertEqual(recovered?.apiVersion, "2024-10-21")
        XCTAssertEqual(recovered?.preferredModel, "gpt-test-custom")

        let endpoint = try await registry.endpoint(for: .azure)
        XCTAssertEqual(endpoint.host, "rpce-azure.openai.azure.com")
        let request = try DirectAPIProviderRuntime.mappedRequest(
            providerID: .azure,
            endpoint: endpoint,
            configuration: updated,
            credential: "write-only-azure-secret",
            model: "gpt-test-custom",
            prompt: "hello",
            settings: [:]
        )
        XCTAssertEqual(
            request.pathAndQuery,
            "/openai/deployments/gpt-test-custom/chat/completions?api-version=2024-10-21"
        )
        XCTAssertEqual(request.headers["api-key"], "write-only-azure-secret")
        XCTAssertEqual(request.headers["X-Title"], "RepoPrompt")
        XCTAssertNil(request.headers["Authorization"])
    }

    func testOllamaPersistsDesktopDefaultURLWithoutAVaultCredential() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let registry = DirectProviderRegistry(
            store: store,
            transport: RecordingAdapterTransport(),
            deploymentAllowlist: [.ollama]
        )
        try await registry.bootstrap()
        let persisted = try await registry.configuration(for: .ollama)
        XCTAssertEqual(persisted.baseURL, ProviderSettingsID.desktopOllamaDefaultURL)
        XCTAssertFalse(ProviderSettingsID.ollama.requiresVaultCredential)
        XCTAssertTrue(ProviderSettingsID.ollama.isDirectAPI)

        let endpoint = try await registry.endpoint(for: .ollama)
        XCTAssertEqual(endpoint.scheme, "http")
        XCTAssertEqual(endpoint.host, "localhost")
        XCTAssertEqual(endpoint.port, 11434)

        let request = try DirectAPIProviderRuntime.mappedRequest(
            providerID: .ollama,
            endpoint: endpoint,
            configuration: persisted,
            credential: "",
            model: "llama2",
            prompt: "hello",
            settings: [:]
        )
        XCTAssertEqual(request.pathAndQuery, "/v1/chat/completions")
        XCTAssertNil(request.headers["Authorization"])
        XCTAssertNil(request.headers["api-key"])

        let accessor = VaultDirectProviderCredentialAccessor(store: store, vault: nil)
        let empty = try await accessor.credential(for: .ollama)
        XCTAssertTrue(empty.isEmpty)
        await XCTAssertThrowsErrorAsync {
            _ = try await accessor.credential(for: .gemini)
        }
    }

    func testPreferredCustomModelMergesIntoDiscoveredCatalogAndMissingAzureConfigFailsClosed() throws {
        let discovered = [
            ProviderModelCatalogEntry(id: "gemini-2.0-flash", displayName: "Gemini 2.0 Flash")
        ]
        let merged = DirectProviderCredentialTester.mergingPreferredModel(discovered, preferredModel: "customModelGemini")
        XCTAssertEqual(merged.map(\.id), ["customModelGemini", "gemini-2.0-flash"])

        XCTAssertThrowsError(try DirectAPIProviderRuntime.mappedRequest(
            providerID: .azure,
            endpoint: .init(scheme: "https", host: "rpce-azure.openai.azure.com", port: 443, basePath: ""),
            configuration: DirectProviderConfiguration(providerID: .azure),
            credential: "write-only-azure-secret",
            model: "gpt-test",
            prompt: "hello",
            settings: [:]
        ))

        let geminiBody = try JSONSerialization.data(withJSONObject: [
            "models": [["name": "models/gemini-2.0-flash", "displayName": "Gemini 2.0 Flash"]]
        ])
        let gemini = try DirectProviderCredentialTester.parseCatalog(
            response: .init(statusCode: 200, contentType: "application/json", body: geminiBody),
            providerID: .gemini
        )
        XCTAssertEqual(gemini.map(\.id), ["gemini-2.0-flash"])
    }
}

private actor RecordingAdapterTransport: ValidatedProviderEgressTransporting {
    func validateEndpoint(_ baseURL: String) async throws -> DirectProviderEndpoint {
        try ProviderEndpointPolicy.parseCustomBaseURL(baseURL)
    }

    func execute(_ request: ValidatedProviderHTTPRequest) async throws -> ValidatedProviderHTTPResponse {
        .init(statusCode: 200, contentType: "application/json", body: Data(#"{"data":[]}"#.utf8))
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
