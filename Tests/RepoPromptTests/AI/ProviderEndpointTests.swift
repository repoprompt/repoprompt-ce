import Foundation
@testable import RepoPromptApp
import RepoPromptFoundation
import XCTest

final class ZAIProviderEndpointTests: XCTestCase {
    func testGLM52ModelCatalogEntry() {
        XCTAssertEqual(AIModel.zaiGLM52.rawValue, "glm-5.2")
        XCTAssertEqual(AIModel.zaiGLM52.displayName, "Z.AI GLM-5.2")
        XCTAssertEqual(AIModel.fromModelName("glm-5.2"), .zaiGLM52)

        let zAIModels = AIModel.modelsForProvider(.zAI)
        XCTAssertTrue(zAIModels.contains(.zaiGLM52))
        XCTAssertTrue(zAIModels.contains(.zaiGLM5))
    }

    func testDefaultProviderUsesGeneralZAIEndpoint() {
        let provider = ZAIProvider(apiKey: "test-key")

        XCTAssertEqual(provider.endpoint, .generalAPI)
        XCTAssertEqual(provider.endpoint.baseURL.absoluteString, "https://api.z.ai/api/paas")
    }

    func testCodingPlanProviderUsesDedicatedCodingEndpoint() {
        let provider = ZAIProvider(apiKey: "test-key", endpoint: .codingPlan)

        XCTAssertEqual(provider.endpoint, .codingPlan)
        XCTAssertEqual(provider.endpoint.baseURL.absoluteString, "https://api.z.ai/api/coding/paas")
    }
}

final class ProviderEndpointConsentTests: XCTestCase {
    private final class RecordingClient: HTTPClient, @unchecked Sendable {
        enum ProbeError: Error { case reachedTransport }
        private let lock = NSLock()
        private var requests: [URLRequest] = []
        var recorded: [URLRequest] {
            lock.withLock { requests }
        }

        func data(for request: URLRequest) async throws -> HTTPResponse {
            lock.withLock { requests.append(request) }
            throw ProbeError.reachedTransport
        }

        func bytes(for request: URLRequest) async throws -> (bytes: URLSession.AsyncBytes, http: HTTPURLResponse) {
            lock.withLock { requests.append(request) }
            throw ProbeError.reachedTransport
        }
    }

    func testCustomCredentialSinksRejectBeforeTransportIncludingCustomHeaders() async throws {
        let client = RecordingClient()
        for (key, headers) in [("test-only-token", [:]), ("", ["X-Provider-Token": "test-only-token"])] {
            let provider = CustomOpenAIProvider(baseURL: "http://provider.example", apiKey: key, defaultModel: "test", customHeaders: headers, httpClient: client, streamingHttpClient: client)
            do {
                _ = try await provider.getAvailableModels()
                XCTFail("Discovery must require consent")
            } catch {
                guard case ProviderEndpointConsent.ValidationError.consentRequired = error else { return XCTFail("Wrong error: \(error)") }
            }
            let message = AIMessage(systemPrompt: "", userMessage: "Test")
            do {
                _ = try await provider.completeMessage(message, model: .customProviderUser(name: "test"), maxTokens: 1)
                XCTFail("Completion must require consent")
            } catch {
                guard case ProviderEndpointConsent.ValidationError.consentRequired = error else { return XCTFail("Wrong error: \(error)") }
            }
            do {
                let stream = try await provider.streamMessage(message, model: .customProviderUser(name: "test"), maxTokens: 1)
                for try await _ in stream {}
                XCTFail("Streaming must require consent")
            } catch {
                guard case ProviderEndpointConsent.ValidationError.consentRequired = error else { return XCTFail("Wrong error: \(error)") }
            }
        }
        XCTAssertTrue(client.recorded.isEmpty)
    }

    func testCustomApprovedAndCredentialFreeRequestsReachOnlyInjectedTransport() async throws {
        let endpoint = "http://provider.example"
        for (key, consent) in [("test-only-token", Optional(endpoint)), ("", nil)] {
            let client = RecordingClient()
            let provider = CustomOpenAIProvider(baseURL: endpoint, apiKey: key, defaultModel: "test", httpCredentialConsentEndpoint: consent, httpClient: client)
            do {
                _ = try await provider.getAvailableModels()
                XCTFail("The injected transport must terminate the request")
            } catch {
                XCTAssertTrue(error is RecordingClient.ProbeError)
            }
            let request = try XCTUnwrap(client.recorded.first)
            XCTAssertEqual(client.recorded.count, 1)
            XCTAssertEqual(request.url?.absoluteString, endpoint + "/models")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), key.isEmpty ? nil : "Bearer test-only-token")
        }
    }

    func testSDKAndAzureDiscoveryRejectUnapprovedInitialRequests() async throws {
        let url = try XCTUnwrap(URL(string: "http://provider.example"))
        XCTAssertThrowsError(try OpenAIProvider(apiKey: "test-only-token", baseURL: url).getService())
        XCTAssertNoThrow(try OpenAIProvider(apiKey: "test-only-token", baseURL: url, httpCredentialConsentEndpoint: url.absoluteString).getService())
        let azure = AzureOpenAIProvider(configuration: AzureOpenAIConfiguration(baseURL: url, apiKey: "test-only-token", apiVersion: "test"))
        do {
            _ = try await azure.fetchResponse(id: "test")
            XCTFail("SDK request must require consent before creating a service")
        } catch {
            guard case ProviderEndpointConsent.ValidationError.consentRequired = error else { return XCTFail("Wrong error: \(error)") }
        }
        do {
            _ = try await AzureOpenAIProvider.discoverDeployments(baseURL: url, apiKey: "test-only-token", apiVersions: [])
            XCTFail("Discovery must check consent even before iterating versions")
        } catch {
            guard case ProviderEndpointConsent.ValidationError.consentRequired = error else { return XCTFail("Wrong error: \(error)") }
        }
    }

    func testLegacyConfigsDecodeWithoutConsentAndCustomHeadersCountAsCredentials() throws {
        let custom = try CustomProviderConfiguration(url: "http://provider.example", defaultModel: "test", headers: [:], name: "Test")
        let azure = try AzureOpenAIConfiguration(baseURL: XCTUnwrap(URL(string: custom.url)), apiKey: "test-only-token", apiVersion: "test")
        let customData = try JSONEncoder().encode(custom)
        let azureData = try JSONEncoder().encode(azure)
        XCTAssertFalse(String(decoding: customData, as: UTF8.self).contains("httpCredentialConsentEndpoint"))
        XCTAssertFalse(String(decoding: azureData, as: UTF8.self).contains("httpCredentialConsentEndpoint"))
        XCTAssertNil(try JSONDecoder().decode(CustomProviderConfiguration.self, from: customData).httpCredentialConsentEndpoint)
        XCTAssertNil(try JSONDecoder().decode(AzureOpenAIConfiguration.self, from: azureData).httpCredentialConsentEndpoint)
        XCTAssertTrue(ProviderEndpointConsent.hasCredentials(apiKey: "", customHeaders: ["authorization": "test-only-token"]))
        XCTAssertTrue(ProviderEndpointConsent.hasCredentials(apiKey: "", customHeaders: ["X-Custom": "test-only-token"]))
        XCTAssertFalse(ProviderEndpointConsent.hasCredentials(apiKey: "", customHeaders: ["Accept": "application/json", "Content-Type": "application/json"]))
    }

    func testMalformedOpenAIOverridesNeverNormalizeToAnotherEndpoint() {
        for raw in ["http://", "http://user:password@provider.example/v1", "https://provider.example/v1#fragment", "file:///tmp/model", "not a URL"] {
            XCTAssertNil(OpenAIURLHelper.splitBaseURLAndVersion(raw).base, raw)
        }
        XCTAssertEqual(OpenAIURLHelper.normalizeBaseURLString("provider.example/v1"), "https://provider.example")
        XCTAssertEqual(OpenAIURLHelper.normalizeBaseURLString("http://[::1]:8080/v1"), "http://[::1]:8080")
    }

    func testDurableCustomRevocationAndAzureCacheCopyPreserveOtherSettings() throws {
        let suite = "ProviderEndpointConsentTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let endpoint = "http://provider.example"
        let config = try CustomProviderConfiguration(url: endpoint, defaultModel: "test", headers: ["X-Custom": "test-only-token"], name: "Test", httpCredentialConsentEndpoint: endpoint)
        try defaults.set(JSONEncoder().encode(config), forKey: "CustomProviderConfig")
        try CustomProviderConfiguration.revokeHTTPConsent(defaults: defaults)
        let revoked = try JSONDecoder().decode(CustomProviderConfiguration.self, from: XCTUnwrap(defaults.data(forKey: "CustomProviderConfig")))
        XCTAssertNil(revoked.httpCredentialConsentEndpoint)
        XCTAssertEqual(revoked.url, config.url)
        XCTAssertEqual(revoked.headers, config.headers)
        XCTAssertEqual(revoked.defaultModel, config.defaultModel)
        XCTAssertThrowsError(try ProviderEndpointConsent.validate(revoked.url, credentialBearing: true, consentEndpoint: revoked.httpCredentialConsentEndpoint))
        let azure = try AzureOpenAIConfiguration(baseURL: XCTUnwrap(URL(string: endpoint)), apiKey: "test-only-token", apiVersion: "test", extraHeaders: ["X-Custom": "test-only-token"], defaultModelID: "test", httpCredentialConsentEndpoint: endpoint)
        let cached = azure.revokingHTTPConsent()
        XCTAssertNil(cached.httpCredentialConsentEndpoint)
        XCTAssertEqual(cached.baseURL, azure.baseURL)
        XCTAssertEqual(cached.apiKey, azure.apiKey)
        XCTAssertEqual(cached.extraHeaders, azure.extraHeaders)
        XCTAssertEqual(cached.defaultModelID, azure.defaultModelID)
    }

    func testClaudePersistedEndpointEditRevokesConsentWithoutReauthorizingOnReturn() throws {
        let suite = "ProviderEndpointConsentTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ClaudeCodeCompatibleBackendStore(defaults: defaults)
        var config = ClaudeCodeCompatibleBackendID.custom.defaultPreset
        config.baseURL = "http://provider.example/anthropic"
        store.saveConfig(config)
        config = store.config(for: .custom)
        config.httpCredentialConsentEndpoint = ProviderEndpointConsent.endpointIdentity(config.baseURL)
        store.saveConfig(config)
        XCTAssertEqual(store.config(for: .custom).httpCredentialConsentEndpoint, "http://provider.example/anthropic")
        let staleApprovedConfig = config
        config.baseURL = "http://other.example/anthropic"
        store.saveConfig(config)
        XCTAssertNil(store.config(for: .custom).httpCredentialConsentEndpoint)
        config = store.config(for: .custom)
        config.baseURL = "http://provider.example/anthropic"
        store.saveConfig(config)
        XCTAssertNil(store.config(for: .custom).httpCredentialConsentEndpoint)
        config.baseURL = "http://other.example/anthropic"
        store.saveConfig(config)
        store.saveConfig(staleApprovedConfig)
        XCTAssertNil(store.config(for: .custom).httpCredentialConsentEndpoint)
    }
}
