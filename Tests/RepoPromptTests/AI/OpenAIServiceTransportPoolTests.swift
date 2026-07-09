import Foundation
@testable import RepoPrompt
import XCTest

final class OpenAIServiceTransportPoolTests: XCTestCase {
    func testPromptScopedProvidersReuseExactTransport() throws {
        let transportPool = OpenAIServiceTransportPool()
        let firstProvider = try OpenAIProvider(
            apiKey: "credential-a",
            baseURL: XCTUnwrap(URL(string: "https://example.com")),
            overrideVersion: "v1",
            transportPool: transportPool
        )
        let secondProvider = try OpenAIProvider(
            apiKey: "credential-a",
            baseURL: XCTUnwrap(URL(string: "https://example.com")),
            overrideVersion: "v1",
            transportPool: transportPool
        )

        XCTAssertFalse(firstProvider === secondProvider)
        XCTAssertEqual(
            ObjectIdentifier(firstProvider.getService().session),
            ObjectIdentifier(secondProvider.getService().session)
        )
        XCTAssertEqual(transportPool.retainedServiceCountForTesting, 1)
    }

    func testConcurrentExactConfigurationAcquisitionReusesOneTransport() async throws {
        let transportPool = OpenAIServiceTransportPool()
        let baseURL = try XCTUnwrap(URL(string: "https://example.com"))

        let identities = await withTaskGroup(of: ObjectIdentifier.self) { group in
            for _ in 0 ..< 20 {
                group.addTask {
                    let service = transportPool.openAIService(
                        owner: .openAI,
                        apiKey: "credential-a",
                        baseURL: baseURL,
                        apiVersion: "v1",
                        includeUsageInStream: true
                    )
                    return ObjectIdentifier(service.session)
                }
            }

            var identities = Set<ObjectIdentifier>()
            for await identity in group {
                identities.insert(identity)
            }
            return identities
        }

        XCTAssertEqual(identities.count, 1)
        XCTAssertEqual(transportPool.retainedServiceCountForTesting, 1)
    }

    func testCredentialAndConfigurationChangesRotateTransport() {
        let variants: [(OpenAIServiceTransportPool) -> (ObjectIdentifier, ObjectIdentifier)] = [
            { pool in
                self.sessionPair(pool: pool, firstCredential: "credential-a", secondCredential: "credential-b")
            },
            { pool in
                self.sessionPair(
                    pool: pool,
                    firstBaseURL: URL(string: "https://one.example")!,
                    secondBaseURL: URL(string: "https://two.example")!
                )
            },
            { pool in
                self.sessionPair(pool: pool, firstProxyPath: "api", secondProxyPath: "proxy")
            },
            { pool in
                self.sessionPair(pool: pool, firstAPIVersion: "v1", secondAPIVersion: "v2")
            },
            { pool in
                self.sessionPair(pool: pool, firstHeaders: ["X-Test": "one"], secondHeaders: ["X-Test": "two"])
            },
            { pool in
                self.sessionPair(pool: pool, firstIncludeUsage: true, secondIncludeUsage: false)
            },
            { pool in
                self.sessionPair(
                    pool: pool,
                    firstPolicy: .longRunning,
                    secondPolicy: OpenAIServiceSessionPolicy(
                        requestTimeout: 30,
                        resourceTimeout: 60,
                        waitsForConnectivity: false
                    )
                )
            }
        ]

        for variant in variants {
            let pool = OpenAIServiceTransportPool()
            let (first, second) = variant(pool)
            XCTAssertNotEqual(first, second)
            XCTAssertEqual(pool.retainedServiceCountForTesting, 1)
        }
    }

    func testSharedConfigurationSurvivesUnrelatedOwnerRotation() throws {
        let pool = OpenAIServiceTransportPool()
        let sharedOpenAI = try pool.openAIService(
            owner: .openAI,
            apiKey: "shared-credential",
            baseURL: XCTUnwrap(URL(string: "https://example.com")),
            apiVersion: "v1",
            includeUsageInStream: true
        )
        let sharedCustom = try pool.openAIService(
            owner: .customProvider,
            apiKey: "shared-credential",
            baseURL: XCTUnwrap(URL(string: "https://example.com")),
            apiVersion: "v1",
            includeUsageInStream: true
        )

        XCTAssertEqual(ObjectIdentifier(sharedOpenAI.session), ObjectIdentifier(sharedCustom.session))

        let rotatedOpenAI = try pool.openAIService(
            owner: .openAI,
            apiKey: "rotated-credential",
            baseURL: XCTUnwrap(URL(string: "https://example.com")),
            apiVersion: "v1",
            includeUsageInStream: true
        )

        XCTAssertNotEqual(ObjectIdentifier(sharedOpenAI.session), ObjectIdentifier(rotatedOpenAI.session))
        XCTAssertEqual(ObjectIdentifier(sharedCustom.session), ObjectIdentifier(sharedOpenAI.session))
        XCTAssertEqual(pool.retainedServiceCountForTesting, 2)

        let rotatedCustom = try pool.openAIService(
            owner: .customProvider,
            apiKey: "rotated-credential",
            baseURL: XCTUnwrap(URL(string: "https://example.com")),
            apiVersion: "v1",
            includeUsageInStream: true
        )

        XCTAssertEqual(ObjectIdentifier(rotatedOpenAI.session), ObjectIdentifier(rotatedCustom.session))
        XCTAssertEqual(pool.retainedServiceCountForTesting, 1)
    }

    func testOpenRouterProvidersReuseExactConfigurationAndRotateHeaders() {
        let pool = OpenAIServiceTransportPool()
        let firstProvider = OpenRouterProvider(apiKey: "openrouter-credential", transportPool: pool)
        let secondProvider = OpenRouterProvider(apiKey: "openrouter-credential", transportPool: pool)
        let configuration = OpenRouterConfiguration(
            customHeaders: ["X-Routing": "first"],
            useCustomSettings: true
        )

        let firstService = firstProvider.getService(configuration: configuration)
        let secondService = secondProvider.getService(configuration: configuration)

        XCTAssertFalse(firstProvider === secondProvider)
        XCTAssertEqual(ObjectIdentifier(firstService.session), ObjectIdentifier(secondService.session))

        let rotatedService = secondProvider.getService(
            configuration: OpenRouterConfiguration(
                customHeaders: ["X-Routing": "second"],
                useCustomSettings: true
            )
        )

        XCTAssertNotEqual(ObjectIdentifier(secondService.session), ObjectIdentifier(rotatedService.session))
        XCTAssertEqual(pool.retainedServiceCountForTesting, 1)
    }

    func testAzureReusesTransportWhenOnlyModelMetadataChanges() throws {
        let pool = OpenAIServiceTransportPool()
        let firstConfiguration = try AzureOpenAIConfiguration(
            baseURL: XCTUnwrap(URL(string: "https://resource.openai.azure.com")),
            apiKey: "azure-credential",
            apiVersion: "2025-04-01-preview",
            extraHeaders: ["X-Test": "value"],
            models: [.init(id: "deployment-one")],
            defaultModelID: "deployment-one"
        )
        let secondConfiguration = AzureOpenAIConfiguration(
            baseURL: firstConfiguration.baseURL,
            apiKey: firstConfiguration.apiKey,
            apiVersion: firstConfiguration.apiVersion,
            extraHeaders: firstConfiguration.extraHeaders,
            models: [.init(id: "deployment-two")],
            defaultModelID: "deployment-two"
        )
        let firstProvider = AzureOpenAIProvider(configuration: firstConfiguration, transportPool: pool)
        let secondProvider = AzureOpenAIProvider(configuration: secondConfiguration, transportPool: pool)

        let firstService = pool.azureService(configuration: firstConfiguration, debugEnabled: false)
        let secondService = pool.azureService(configuration: secondConfiguration, debugEnabled: false)

        XCTAssertFalse(firstProvider === secondProvider)
        XCTAssertEqual(ObjectIdentifier(firstService.session), ObjectIdentifier(secondService.session))
        XCTAssertEqual(pool.retainedServiceCountForTesting, 1)
    }

    func testDisposableProviderPoolReadsUpdatedCredentialAndKeepsProvidersPromptScoped() async throws {
        let storage = TestSecureStorageBackend(values: [.openAIAPI: "credential-a"])
        let keyManager = KeyManager(secureService: SecureKeysService(secureStorage: storage))
        let providerPool = DisposableProviderPool(keyManager: keyManager)

        let firstProvider = try await providerPool.createProvider(for: .gpt54Mini)
        let secondProvider = try await providerPool.createProvider(for: .gpt54Mini)
        let first = try XCTUnwrap(firstProvider as? OpenAIProvider)
        let second = try XCTUnwrap(secondProvider as? OpenAIProvider)

        XCTAssertFalse(first === second)
        XCTAssertEqual(ObjectIdentifier(first.getService().session), ObjectIdentifier(second.getService().session))

        try await keyManager.saveAPIKey("credential-b", for: .openAI)
        let rotatedProvider = try await providerPool.createProvider(for: .gpt54Mini)
        let rotated = try XCTUnwrap(rotatedProvider as? OpenAIProvider)

        XCTAssertFalse(second === rotated)
        XCTAssertNotEqual(ObjectIdentifier(second.getService().session), ObjectIdentifier(rotated.getService().session))
    }

    private func sessionPair(
        pool: OpenAIServiceTransportPool,
        firstCredential: String = "credential",
        secondCredential: String = "credential",
        firstBaseURL: URL = URL(string: "https://example.com")!,
        secondBaseURL: URL = URL(string: "https://example.com")!,
        firstProxyPath: String? = "api",
        secondProxyPath: String? = "api",
        firstAPIVersion: String? = "v1",
        secondAPIVersion: String? = "v1",
        firstHeaders: [String: String]? = ["X-Test": "value"],
        secondHeaders: [String: String]? = ["X-Test": "value"],
        firstIncludeUsage: Bool = true,
        secondIncludeUsage: Bool = true,
        firstPolicy: OpenAIServiceSessionPolicy = .longRunning,
        secondPolicy: OpenAIServiceSessionPolicy = .longRunning
    ) -> (ObjectIdentifier, ObjectIdentifier) {
        let first = pool.openAIService(
            owner: .openAI,
            apiKey: firstCredential,
            baseURL: firstBaseURL,
            proxyPath: firstProxyPath,
            apiVersion: firstAPIVersion,
            extraHeaders: firstHeaders,
            includeUsageInStream: firstIncludeUsage,
            sessionPolicy: firstPolicy
        )
        let second = pool.openAIService(
            owner: .openAI,
            apiKey: secondCredential,
            baseURL: secondBaseURL,
            proxyPath: secondProxyPath,
            apiVersion: secondAPIVersion,
            extraHeaders: secondHeaders,
            includeUsageInStream: secondIncludeUsage,
            sessionPolicy: secondPolicy
        )
        return (ObjectIdentifier(first.session), ObjectIdentifier(second.session))
    }
}
