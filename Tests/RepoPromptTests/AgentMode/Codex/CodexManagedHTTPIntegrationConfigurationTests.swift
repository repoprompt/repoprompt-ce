@testable import RepoPromptApp
import XCTest

final class CodexManagedHTTPIntegrationConfigurationTests: XCTestCase {
    func testExplicitHostedConfigurationKeepsStrictEffectivePolicy() throws {
        XCTAssertNoThrow(try CodexManagedHTTPIntegrationConfiguration.requireHostedXCTest())
        let root = URL(fileURLWithPath: "/private/tmp/sb-integration-policy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = root.appendingPathComponent("fixture.sb")
        try Data("(version 1)".utf8).write(to: profile)
        let endpoint = "http://127.0.0.1:43125/backend-api/codex"
        let configuration = try CodexManagedHTTPIntegrationConfiguration(resourcesURL: root, rootURL: root, responsesURL: endpoint, sandboxProfileURL: profile)
        var response = try CodexManagedHTTPRuntimeFixture.configuration()
        var config = try XCTUnwrap(response["config"] as? [String: Any])
        var providers = try XCTUnwrap(config["model_providers"] as? [String: Any])
        var provider = try XCTUnwrap(providers[CodexManagedHTTPPolicy.providerID] as? [String: Any])
        provider["base_url"] = endpoint
        providers[CodexManagedHTTPPolicy.providerID] = provider
        config["model_providers"] = providers
        response["config"] = config
        XCTAssertNoThrow(try CodexManagedHTTPPolicy.verifyIntegrationConfiguration(response, configuration: configuration))
        XCTAssertThrowsError(try CodexManagedHTTPPolicy.verifyEffectiveConfiguration(response))
        provider["supports_websockets"] = true
        providers[CodexManagedHTTPPolicy.providerID] = provider
        config["model_providers"] = providers
        response["config"] = config
        XCTAssertThrowsError(try CodexManagedHTTPPolicy.verifyIntegrationConfiguration(response, configuration: configuration))
        XCTAssertThrowsError(try configuration.resolve(), "Fixture construction must not manufacture bundled-runtime metadata")
        XCTAssertThrowsError(try CodexManagedHTTPIntegrationConfiguration(
            resourcesURL: URL(fileURLWithPath: CodexManagedHTTPIntegrationConfiguration.realUserHomePath()),
            rootURL: root, responsesURL: endpoint, sandboxProfileURL: profile
        ))
        XCTAssertThrowsError(try CodexManagedHTTPIntegrationConfiguration(
            resourcesURL: root, rootURL: URL(fileURLWithPath: root.path.replacingOccurrences(of: "/private/tmp/", with: "/tmp/")),
            responsesURL: endpoint, sandboxProfileURL: profile
        ))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        XCTAssertThrowsError(try CodexManagedHTTPIntegrationConfiguration(resourcesURL: root, rootURL: root, responsesURL: endpoint, sandboxProfileURL: profile))
    }

    func testOnlyCanonicalNumericLoopbackEndpointIsAccepted() throws {
        let allowed = "http://127.0.0.1:43125/backend-api/codex"
        XCTAssertEqual(try CodexManagedHTTPIntegrationConfiguration.validatedLoopbackURL(allowed), allowed)
        for rejected in [
            "https://chatgpt.com/backend-api/codex", "http://example.invalid:43125/backend-api/codex",
            "http://localhost:43125/backend-api/codex", "http://127.1:43125/backend-api/codex",
            "http://127.0.0.2:43125/backend-api/codex", "http://[::1]:43125/backend-api/codex",
            "http://127.0.0.1/backend-api/codex", "http://127.0.0.1:0/backend-api/codex",
            "http://127.0.0.1:65536/backend-api/codex", "http://127.0.0.1:43125/other",
            "http://127.0.0.1:43125/backend-api/codex?redirect=remote",
            "http://127.0.0.1:43125/backend-api/codex#fragment",
            "http://user:password@127.0.0.1:43125/backend-api/codex",
            "http://127.0.0.1:43125/backend-api/codex/", " http://127.0.0.1:43125/backend-api/codex"
        ] {
            XCTAssertThrowsError(try CodexManagedHTTPIntegrationConfiguration.validatedLoopbackURL(rejected), rejected)
        }
    }

    func testProductionPolicyStillRejectsLocalEndpoint() throws {
        var response = try CodexManagedHTTPRuntimeFixture.configuration()
        var config = try XCTUnwrap(response["config"] as? [String: Any])
        var providers = try XCTUnwrap(config["model_providers"] as? [String: Any])
        var provider = try XCTUnwrap(providers[CodexManagedHTTPPolicy.providerID] as? [String: Any])
        provider["base_url"] = "http://127.0.0.1:43125/backend-api/codex"
        providers[CodexManagedHTTPPolicy.providerID] = provider
        config["model_providers"] = providers
        response["config"] = config
        XCTAssertThrowsError(try CodexManagedHTTPPolicy.verifyEffectiveConfiguration(response))
        XCTAssertTrue(CodexManagedHTTPPolicy.launchArguments.contains("model_providers.switchboard-managed-http.base_url=\"https://chatgpt.com/backend-api/codex\""))
    }
}
