import Foundation
@testable import RepoPromptClaudeCompatibleProvider
import XCTest

final class ProviderEndpointConsentTests: XCTestCase {
    func testRemoteCredentialHTTPRequiresExactEndpointConsent() throws {
        let endpoint = "http://provider.example/api"
        XCTAssertThrowsError(try ProviderEndpointConsentPolicy.validate(endpoint, credentialBearing: true, consentEndpoint: nil))
        XCTAssertThrowsError(try ProviderEndpointConsentPolicy.validate(endpoint, credentialBearing: true, consentEndpoint: "http://other.example/api"))
        XCTAssertThrowsError(try ProviderEndpointConsentPolicy.validate(endpoint + "/other", credentialBearing: true, consentEndpoint: endpoint))
        XCTAssertThrowsError(try ProviderEndpointConsentPolicy.validate("http://provider.example:8080/api", credentialBearing: true, consentEndpoint: endpoint))
        XCTAssertNoThrow(try ProviderEndpointConsentPolicy.validate(endpoint, credentialBearing: true, consentEndpoint: endpoint))
        XCTAssertNoThrow(try ProviderEndpointConsentPolicy.validate(endpoint, credentialBearing: false, consentEndpoint: nil))
        XCTAssertNoThrow(try ProviderEndpointConsentPolicy.validate("https://provider.example/api", credentialBearing: true, consentEndpoint: nil))
    }

    func testLocalCompatibilityUsesOnlyLiteralLoopbackClassification() throws {
        for host in ["localhost", "127.0.0.1", "127.255.1.2", "[::1]"] {
            let endpoint = "http://\(host):8080/api"
            XCTAssertNoThrow(try ProviderEndpointConsentPolicy.validate(endpoint, credentialBearing: true, consentEndpoint: nil), host)
        }
        for host in ["localhost.example", "local.example", "127.0.0.1.example", "192.168.1.2", "127.0.0.01", "2130706433", "[::ffff:127.0.0.1]"] {
            XCTAssertTrue(ProviderEndpointConsentPolicy.isRemoteHTTP("http://\(host):8080/api"), host)
        }
    }

    func testMalformedAndEmbeddedCredentialEndpointsNeverUseFallback() {
        for raw in ["not a URL", "file:///tmp/model", "http://", "https://user:password@provider.example", "http://provider.example/#fragment"] {
            XCTAssertNil(ProviderEndpointConsentPolicy.endpointIdentity(raw), raw)
            XCTAssertThrowsError(try ProviderEndpointConsentPolicy.validate(raw, credentialBearing: false, consentEndpoint: raw), raw)
        }
    }

    func testClaudeEnvironmentFailsClosedAndPreservesConsentAcrossNormalizationAndSlotOverride() throws {
        func config(_ endpoint: String, consent: String? = nil) -> ClaudeCompatibleBackendConfig {
            ClaudeCompatibleBackendConfig(
                id: .custom,
                isEnabled: true,
                displayName: "Test",
                baseURL: endpoint,
                auth: .anthropicAuthToken,
                modelBehavior: .claudeSlotMapping(.init(haiku: "h", sonnet: "s", opus: "o")),
                httpCredentialConsentEndpoint: consent
            )
        }
        let endpoint = "http://provider.example/anthropic"
        let unapproved = config(endpoint)
        XCTAssertThrowsError(try ClaudeCompatibleBackendEnvironmentBuilder.environment(config: unapproved, apiKey: "test-only-token"))
        XCTAssertThrowsError(try ClaudeCompatibleBackendEnvironmentBuilder.environment(config: config("invalid"), apiKey: "test-only-token"))
        let approved = config(endpoint, consent: endpoint).normalized.withSlotOverride(slot: "sonnet", backendModelID: "other")
        let environment = try ClaudeCompatibleBackendEnvironmentBuilder.environment(config: approved, apiKey: "test-only-token")
        XCTAssertEqual(environment["ANTHROPIC_BASE_URL"], endpoint)
        XCTAssertEqual(environment["ANTHROPIC_AUTH_TOKEN"], "test-only-token")
        XCTAssertThrowsError(try ClaudeCompatibleBackendEnvironmentBuilder.environment(config: config("http://other.example/anthropic", consent: endpoint), apiKey: "test-only-token"))
        XCTAssertNoThrow(try ClaudeCompatibleBackendEnvironmentBuilder.environment(config: config("http://127.0.0.1:8080/anthropic"), apiKey: "test-only-token"))
    }

    func testLegacyClaudeConfigDoesNotAcquireConsentOnDecode() throws {
        let config = ClaudeCompatibleBackendConfig(id: .custom, isEnabled: true, displayName: "Test", baseURL: "http://provider.example", auth: .anthropicAPIKey, modelBehavior: .noModel)
        let data = try JSONEncoder().encode(config)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "httpCredentialConsentEndpoint")
        let decoded = try JSONDecoder().decode(ClaudeCompatibleBackendConfig.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.httpCredentialConsentEndpoint)
        XCTAssertThrowsError(try ClaudeCompatibleBackendEnvironmentBuilder.environment(config: decoded, apiKey: "test-only-token"))
    }
}
