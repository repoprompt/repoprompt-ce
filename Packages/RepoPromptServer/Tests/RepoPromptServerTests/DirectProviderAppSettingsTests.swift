import Foundation
@testable import RepoPromptHeadlessRuntime
import RepoPromptMCPAdapter
@testable import RepoPromptServicePersistence
import RepoPromptServiceProtocol
import XCTest

@testable import RepoPromptServerHost
@testable import RepoPromptServerExecutable
final class DirectProviderAppSettingsTests: XCTestCase {
    func testAppSettingsDirectProviderKeysWriteTheSameStoreWithoutATokenBag() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let registry = DirectProviderRegistry(
            store: store,
            transport: RecordingDirectProviderTransport(),
            deploymentAllowlist: [.openAIAPI, .openRouter]
        )
        try await registry.bootstrap()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("app-settings-direct-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ServerSettingsService(
            store: store,
            providerCatalog: StaticProviderCatalog(response: .init(providers: [])),
            projectCatalog: store
        )
        let authority = RepoPromptHeadlessAuthority(
            store: store,
            serverSettings: service,
            directProviderRegistry: registry
        )
        let actor = ExternalActor(userID: "mcp-direct", username: "mcp-direct", displayName: "MCP Direct")
        let project = try await authority.createProject(
            input: .init(name: "Direct", roots: [.init(logicalName: "root", path: root.path, writable: true)]),
            externalActor: actor,
            idempotencyKey: "direct-settings-project",
            requestDigest: "direct-settings-project"
        )
        let session = try await authority.createSession(
            input: .init(projectID: project.projectID, provider: .codex, visibility: .privateSession),
            externalActor: actor,
            idempotencyKey: "direct-settings-session",
            requestDigest: "direct-settings-session"
        )
        let adapter = RepoPromptMCPAdapter(serving: await RepoPromptAuthorityMCPService.admitted(authority: authority, portalSettings: PortalDesktopSettingsService(store: store), admissionGate: AuthorityMutationGate()))
        let binding = RepoPromptMCPBinding(sessionID: session.sessionID, actor: actor)

        func invoke(_ object: [String: Any]) async throws -> [String: Any] {
            let data = try await adapter.invoke(
                toolName: "app_settings",
                argumentsJSON: try JSONSerialization.data(withJSONObject: object),
                binding: binding
            )
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        let defaultTokens = try await invoke(["op": "get", "key": "direct_providers.openAIAPI.maximum_output_tokens"])
        XCTAssertEqual(defaultTokens["value"] as? Int, 0)

        let writtenURL = try await invoke([
            "op": "set",
            "key": "direct_providers.openAIAPI.base_url",
            "value": "https://openai.example.com/v1"
        ])
        XCTAssertEqual(writtenURL["value"] as? String, "https://openai.example.com/v1")
        _ = try await invoke(["op": "set", "key": "direct_providers.openAIAPI.api_version", "value": "v1-beta"])
        _ = try await invoke(["op": "set", "key": "direct_providers.openAIAPI.preferred_model", "value": "gpt-5"])
        _ = try await invoke(["op": "set", "key": "direct_providers.openAIAPI.maximum_output_tokens", "value": 0])
        _ = try await invoke(["op": "set", "key": "direct_providers.openAIAPI.show_service_tier_variants", "value": true])
        _ = try await invoke([
            "op": "set",
            "key": "direct_providers.openRouter.enabled_models",
            "value": ["openai/gpt-5.6"]
        ])
        _ = try await invoke([
            "op": "set",
            "key": "direct_providers.openRouter.include_default_models",
            "value": false
        ])
        _ = try await invoke([
            "op": "set",
            "key": "direct_providers.openRouter.custom_headers",
            "value": ["X-Title": "MCP"]
        ])

        let storedOpenAI = try await registry.configuration(for: .openAIAPI)
        XCTAssertEqual(storedOpenAI.baseURL, "https://openai.example.com/v1")
        XCTAssertEqual(storedOpenAI.apiVersion, "v1-beta")
        XCTAssertEqual(storedOpenAI.preferredModel, "gpt-5")
        XCTAssertEqual(storedOpenAI.maximumOutputTokens, 0)
        XCTAssertTrue(storedOpenAI.showServiceTierVariants)
        let storedRouter = try await registry.configuration(for: .openRouter)
        XCTAssertEqual(storedRouter.enabledModels, ["openai/gpt-5.6"])
        XCTAssertFalse(storedRouter.includeDefaultModels)
        XCTAssertEqual(storedRouter.customHeaders["X-Title"], "MCP")

        let readModels = try await invoke(["op": "get", "key": "direct_providers.openRouter.enabled_models"])
        XCTAssertEqual(readModels["value"] as? [String], ["openai/gpt-5.6"])

        do {
            _ = try await invoke(["op": "set", "key": "direct_providers.openAIAPI.api_key", "value": "sk-secret"])
            XCTFail("MCP must not accept a parallel token store")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .invalidRequest)
            XCTAssertTrue(error.message.contains("connection APIs"), error.message)
        }
        do {
            _ = try await invoke(["op": "set", "key": "direct_providers.openAIAPI.token", "value": "sk-secret"])
            XCTFail("MCP must not accept credential-shaped keys")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .invalidRequest)
            XCTAssertTrue(error.message.contains("connection APIs"), error.message)
        }
    }
}

private struct StaticProviderCatalog: ServerSettingsProviderCatalogProviding {
    let response: ProviderSettingsCatalogResponse

    func serverSettingsProviderCatalog() async throws -> ProviderSettingsCatalogResponse { response }
}

private actor RecordingDirectProviderTransport: ValidatedProviderEgressTransporting {
    func validateEndpoint(_ baseURL: String) async throws -> DirectProviderEndpoint {
        try ProviderEndpointPolicy.parseCustomBaseURL(baseURL)
    }

    func execute(_ request: ValidatedProviderHTTPRequest) async throws -> ValidatedProviderHTTPResponse {
        .init(statusCode: 200, contentType: "application/json", body: Data(#"{"data":[]}"#.utf8))
    }
}
