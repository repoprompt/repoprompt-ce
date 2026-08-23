import Foundation
@testable import RepoPromptHeadlessRuntime
@testable import RepoPromptServicePersistence
import RepoPromptServiceProtocol
import XCTest

@testable import RepoPromptServerHost
@testable import RepoPromptServerExecutable
final class LocalProviderURLEscapeTests: XCTestCase {
    func testDeploymentAdmissionRemainsTheDirectLaunchGate() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let empty = DirectProviderRegistry(
            store: store,
            transport: RecordingEscapeTransport(),
            deploymentAllowlist: []
        )
        try await empty.bootstrap()
        let emptyOllama = await empty.isDeploymentAllowed(.ollama)
        let emptyOpenAI = await empty.isDeploymentAllowed(.openAIAPI)
        XCTAssertFalse(emptyOllama)
        XCTAssertFalse(emptyOpenAI)
        await XCTAssertThrowsErrorAsync {
            _ = try await empty.configuration(for: .ollama)
        }

        let admitted = DirectProviderRegistry(
            store: store,
            transport: RecordingEscapeTransport(),
            deploymentAllowlist: [.ollama]
        )
        try await admitted.bootstrap()
        let ollamaAdmitted = await admitted.isDeploymentAllowed(.ollama)
        let customAdmitted = await admitted.isDeploymentAllowed(.customOpenAICompatible)
        XCTAssertTrue(ollamaAdmitted)
        XCTAssertFalse(customAdmitted)
        let ollama = try await admitted.configuration(for: .ollama)
        XCTAssertEqual(ollama.baseURL, ProviderSettingsID.desktopOllamaDefaultURL)
    }

    func testSSRFGateStaysFailClosedAndLoopbackEscapeIsExplicit() async throws {
        XCTAssertFalse(ProviderLocalURLEscape.isEnabled([:]))
        XCTAssertTrue(ProviderLocalURLEscape.isEnabled([ProviderLocalURLEscape.environmentKey: "1"]))
        XCTAssertTrue(ProviderLocalURLEscape.isLoopbackHost("localhost"))
        XCTAssertTrue(ProviderEgressAddressPolicy.isLoopbackAddress("127.0.0.1"))
        XCTAssertTrue(ProviderEgressAddressPolicy.isLoopbackAddress("::1"))
        XCTAssertFalse(ProviderEgressAddressPolicy.isLoopbackAddress("192.168.1.1"))
        XCTAssertFalse(ProviderEgressAddressPolicy.isLoopbackAddress("8.8.8.8"))

        XCTAssertThrowsError(try ProviderEndpointPolicy.parseCustomBaseURL("http://localhost:11434"))
        XCTAssertThrowsError(try ProviderEndpointPolicy.parseCustomBaseURL("https://192.168.1.1/v1", allowLocalURLs: true))
        let local = try ProviderEndpointPolicy.parseCustomBaseURL("http://localhost:11434", allowLocalURLs: true)
        XCTAssertEqual(local.scheme, "http")
        XCTAssertEqual(local.host, "localhost")
        XCTAssertEqual(local.port, 11434)

        let closed = try ValidatedProviderEgressTransport(
            resolver: EscapeHostResolver(addresses: [try resolved("127.0.0.1")]),
            allowLocalURLs: false
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await closed.validateEndpoint("http://localhost:11434")
        }

        let escaped = try ValidatedProviderEgressTransport(
            resolver: EscapeHostResolver(addresses: [try resolved("127.0.0.1")]),
            allowLocalURLs: true
        )
        let endpoint = try await escaped.validateEndpoint("http://localhost:11434")
        XCTAssertEqual(endpoint.host, "localhost")
        XCTAssertEqual(endpoint.port, 11434)

        let rebound = try ValidatedProviderEgressTransport(
            resolver: EscapeHostResolver(addresses: [try resolved("8.8.8.8")]),
            allowLocalURLs: true
        )
        do {
            _ = try await rebound.validateEndpoint("http://localhost:11434")
            XCTFail("Expected non-loopback resolution to stay fail-closed")
        } catch let error as ValidatedProviderEgressError {
            XCTAssertEqual(error, .nonPublicAddress)
        }

        XCTAssertThrowsError(try DirectProviderRegistry.validateConfiguration(
            providerID: .openAIAPI,
            baseURL: "http://localhost:8080/v1",
            preferredModel: nil,
            maximumOutputTokens: 0,
            customHeaders: [:],
            contentTypePolicy: .applicationJSON,
            revision: 1,
            updatedAt: Date(),
            allowLocalURLs: false
        ))
        let persisted = try DirectProviderRegistry.validateConfiguration(
            providerID: .openAIAPI,
            baseURL: "http://localhost:8080/v1",
            preferredModel: nil,
            maximumOutputTokens: 0,
            customHeaders: [:],
            contentTypePolicy: .applicationJSON,
            revision: 1,
            updatedAt: Date(),
            allowLocalURLs: true
        )
        XCTAssertEqual(persisted.baseURL, "http://localhost:8080/v1")
    }

    private func resolved(_ address: String) throws -> ResolvedProviderAddress {
        .init(ipAddress: address, socketAddress: try .init(ipAddress: address, port: 11434))
    }
}

private actor EscapeHostResolver: ProviderHostResolving {
    private let addresses: [ResolvedProviderAddress]

    init(addresses: [ResolvedProviderAddress]) {
        self.addresses = addresses
    }

    func resolve(host _: String, port _: Int) async throws -> [ResolvedProviderAddress] {
        addresses
    }
}

private actor RecordingEscapeTransport: ValidatedProviderEgressTransporting {
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
