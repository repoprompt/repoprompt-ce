import Foundation
@testable import RepoPromptHeadlessRuntime
import RepoPromptAgentRuntimeCore
import RepoPromptServicePersistence
import RepoPromptServiceProtocol
import XCTest

@testable import RepoPromptServerHost
@testable import RepoPromptServerExecutable
final class DirectProviderRuntimeTests: XCTestCase {
    func testCodexAutoReviewSendsDesktopApprovalsReviewer() {
        let autoReview = CodexAppServerProviderRuntime.codexPolicy(
            .init(mode: .workspaceWrite, providerSettings: [
                "provider.permissionId": "codex.autoReview",
                "codex.approvalsReviewer": "auto_review",
            ]),
            workingDirectory: "/workspace"
        )
        XCTAssertEqual(autoReview.approvalPolicy, "on-request")
        XCTAssertEqual(autoReview.sandbox, "workspace-write")
        XCTAssertEqual(autoReview.approvalsReviewer, "auto_review")

        let inferred = CodexAppServerProviderRuntime.codexPolicy(
            .init(mode: .workspaceWrite, providerSettings: ["provider.permissionId": "codex.autoReview"]),
            workingDirectory: "/workspace"
        )
        XCTAssertEqual(inferred.approvalsReviewer, "auto_review")

        let requireApproval = CodexAppServerProviderRuntime.codexPolicy(
            .init(mode: .workspaceWrite, providerSettings: ["provider.permissionId": "codex.defaultPermission"]),
            workingDirectory: "/workspace"
        )
        XCTAssertEqual(requireApproval.approvalsReviewer, "user")

        let typedWinsOverMode = CodexAppServerProviderRuntime.codexPolicy(
            .init(mode: .workspaceWrite, providerSettings: [
                "codex.sandbox": "danger-full-access",
                "codex.approvalPolicy": "never",
                "codex.approvalsReviewer": "user",
            ]),
            workingDirectory: "/workspace"
        )
        XCTAssertEqual(typedWinsOverMode.sandbox, "danger-full-access")
        XCTAssertEqual(typedWinsOverMode.approvalPolicy, "never")
        XCTAssertEqual(typedWinsOverMode.approvalsReviewer, "user")
    }

    func testSafeManagedCodexSubagentsUseAutoReviewReviewer() async {
        let resolved = await SubagentPermissionResolver(settings: nil, directDefaults: nil).resolve(providerID: .codex)
        XCTAssertEqual(resolved.mode, "workspaceWrite")
        XCTAssertEqual(resolved.policy, .safeManaged)
        XCTAssertEqual(resolved.providerSettings["codex.sandbox"], "workspace-write")
        XCTAssertEqual(resolved.providerSettings["codex.approvalsReviewer"], "auto_review")
        XCTAssertEqual(resolved.providerSettings["codex.approvalPolicy"], "on-request")
        XCTAssertEqual(resolved.providerSettings["codex.bashEnabled"], "true")
        XCTAssertEqual(resolved.providerSettings["codex.enabledMCPServers"], "[]")
    }

    func testSafeManagedSubagentsDoNotLeakDirectAgentPermissions() async {
        let leaked = StaticDirectProviderDefaults(values: [
            .codex: .init(mode: "fullAccess", providerSettings: [
                "test.marker": "codex",
                "codex.sandbox": "danger-full-access",
                "codex.approvalPolicy": "never",
                "codex.approvalsReviewer": "user",
                "codex.bashEnabled": "false",
                "provider.reasoningEffort": "high"
            ]),
            .claudeCompatible: .init(mode: "fullAccess", providerSettings: [
                "test.marker": "claude",
                "claude.permissionMode": "bypassPermissions",
                "claude.bashEnabled": "true",
                "claude.strictMCPEnabled": "false",
                "claude.backendID": ProviderSettingsID.claudeGLM.rawValue
            ])
        ])
        let resolver = SubagentPermissionResolver(settings: nil, directDefaults: leaked)
        let codex = await resolver.resolve(providerID: .codex)
        XCTAssertEqual(codex.mode, "workspaceWrite")
        XCTAssertNil(codex.providerSettings["test.marker"])
        XCTAssertEqual(codex.providerSettings["codex.sandbox"], "workspace-write")
        XCTAssertEqual(codex.providerSettings["codex.approvalPolicy"], "on-request")
        XCTAssertEqual(codex.providerSettings["codex.approvalsReviewer"], "auto_review")
        XCTAssertEqual(codex.providerSettings["codex.bashEnabled"], "true")
        XCTAssertEqual(codex.providerSettings["provider.reasoningEffort"], "high")

        let claude = await resolver.resolve(providerID: .claudeCompatible)
        XCTAssertEqual(claude.mode, "workspaceWrite")
        XCTAssertNil(claude.providerSettings["test.marker"])
        XCTAssertEqual(claude.providerSettings["claude.permissionMode"], "default")
        XCTAssertEqual(claude.providerSettings["claude.bashEnabled"], "false")
        XCTAssertEqual(claude.providerSettings["claude.strictMCPEnabled"], "true")
        XCTAssertEqual(claude.providerSettings["claude.backendID"], ProviderSettingsID.claudeGLM.rawValue)
    }

    func testPublicAddressPolicyRejectsPrivateReservedMetadataAndTranslationRanges() {
        let publicAddresses = ["8.8.8.8", "1.1.1.1", "2606:4700:4700::1111", "2001:4860:4860::8888"]
        let prohibitedAddresses = [
            "0.0.0.0", "10.0.0.1", "100.64.0.1", "127.0.0.1", "169.254.169.254",
            "172.16.0.1", "192.0.0.1", "192.0.2.1", "192.168.1.1", "198.18.0.1",
            "198.51.100.1", "203.0.113.1", "224.0.0.1", "240.0.0.1", "168.63.129.16",
            "::", "::1", "::ffff:127.0.0.1", "64:ff9b::127.0.0.1", "100::1",
            "2001:db8::1", "2002:7f00:1::", "3fff::1", "fc00::1", "fe80::1", "ff02::1"
        ]
        for address in publicAddresses {
            XCTAssertTrue(ProviderEgressAddressPolicy.isPublicAddress(address), address)
        }
        for address in prohibitedAddresses {
            XCTAssertFalse(ProviderEgressAddressPolicy.isPublicAddress(address), address)
        }
    }

    func testCustomEndpointPolicyNormalizesIDNAAndRejectsAmbiguousAuthorityAndPaths() throws {
        let normalized = try ProviderEndpointPolicy.parseCustomBaseURL("https://bücher.example/api")
        XCTAssertEqual(normalized.host, "xn--bcher-kva.example")
        XCTAssertEqual(normalized.basePath, "/api")

        let invalid = [
            "http://example.com", "https://user@example.com", "https://user:password@example.com",
            "https://example.com:8443", "https://example.com/path?query=1", "https://example.com/#fragment",
            "https://127.0.0.1/v1", "https://[::1]/v1", "https://example.com/%2e%2e/private",
            "https://example.com/a%2fb", "https://example.com/a%5cb"
        ]
        for value in invalid {
            XCTAssertThrowsError(try ProviderEndpointPolicy.parseCustomBaseURL(value), value)
        }
    }

    func testEveryRequestReResolvesAndRejectsDNSRebindingBeforeConnect() async throws {
        let resolver = SequenceHostResolver(sequences: [
            [try resolved("93.184.216.34")],
            [try resolved("127.0.0.1")]
        ])
        let transport = try ValidatedProviderEgressTransport(resolver: resolver)
        let endpoint = try await transport.validateEndpoint("https://example.com")
        do {
            _ = try await transport.execute(.init(endpoint: endpoint, method: "GET", pathAndQuery: "/v1/models", headers: [:]))
            XCTFail("Expected rebinding rejection")
        } catch let error as ValidatedProviderEgressError {
            XCTAssertEqual(error, .nonPublicAddress)
        }
        let resolutionCalls = await resolver.callCount()
        XCTAssertEqual(resolutionCalls, 2)
    }

    func testMixedPublicPrivateDNSAnswerFailsClosed() async throws {
        let resolver = SequenceHostResolver(sequences: [[
            try resolved("93.184.216.34"),
            try resolved("169.254.169.254")
        ]])
        let transport = try ValidatedProviderEgressTransport(resolver: resolver)
        do {
            _ = try await transport.validateEndpoint("https://example.com")
            XCTFail("Expected mixed-answer rejection")
        } catch let error as ValidatedProviderEgressError {
            XCTAssertEqual(error, .nonPublicAddress)
        }
    }

    func testPinnedAddressRetainsOriginalHostnameForSNIAndCertificateValidation() throws {
        let endpoint = try ProviderEndpointPolicy.fixed(providerID: .openAIAPI)
        let address = try resolved("93.184.216.34").socketAddress
        let plan = try ProviderPinnedTLSConnectionPlan(endpoint: endpoint, address: address)
        XCTAssertEqual(plan.serverHostname, "api.openai.com")
        XCTAssertTrue(String(describing: plan.address).contains("93.184.216.34"))
    }

    func testRedirectResponseAndRequestBoundsFailClosed() throws {
        var redirect = BoundedProviderResponseAccumulator(maximumHeaderBytes: 128, maximumBodyBytes: 16)
        XCTAssertThrowsError(try redirect.receiveHead(statusCode: 302, headers: [("Location", "https://elsewhere.example")])) {
            XCTAssertEqual($0 as? ValidatedProviderEgressError, .redirectRejected)
        }

        var oversizedHeaders = BoundedProviderResponseAccumulator(maximumHeaderBytes: 4, maximumBodyBytes: 16)
        XCTAssertThrowsError(try oversizedHeaders.receiveHead(statusCode: 200, headers: [("Content-Type", "application/json")])) {
            XCTAssertEqual($0 as? ValidatedProviderEgressError, .responseHeadersTooLarge)
        }

        var oversizedBody = BoundedProviderResponseAccumulator(maximumHeaderBytes: 128, maximumBodyBytes: 2)
        try oversizedBody.receiveHead(statusCode: 200, headers: [("Content-Type", "application/json")])
        XCTAssertThrowsError(try oversizedBody.receiveBody([1, 2, 3])) {
            XCTAssertEqual($0 as? ValidatedProviderEgressError, .responseBodyTooLarge)
        }

        let resolver = SequenceHostResolver(sequences: [[try resolved("93.184.216.34")]])
        let transport = try ValidatedProviderEgressTransport(resolver: resolver)
        let endpoint = try ProviderEndpointPolicy.fixed(providerID: .openAIAPI)
        XCTAssertThrowsError(try transport.validateRequest(.init(
            endpoint: endpoint,
            method: "GET",
            pathAndQuery: "/v1/models",
            headers: [:],
            connectTimeout: .zero,
            totalTimeout: .seconds(1)
        ))) {
            XCTAssertEqual($0 as? ValidatedProviderEgressError, .invalidEndpoint)
        }
        XCTAssertThrowsError(try transport.validateRequest(.init(
            endpoint: endpoint,
            method: "GET",
            pathAndQuery: "/v1/models",
            headers: [:],
            connectTimeout: .seconds(2),
            totalTimeout: .seconds(1)
        ))) {
            XCTAssertEqual($0 as? ValidatedProviderEgressError, .invalidEndpoint)
        }
    }

    func testDirectConfigurationRejectsCredentialAndForwardingHeaders() throws {
        let forbidden = [
            "Authorization", "Proxy-Authorization", "Cookie", "Host", "Forwarded",
            "X-Forwarded-For", "X-API-Key", "X-Auth-Token", "X-Credential"
        ]
        for name in forbidden {
            XCTAssertThrowsError(try DirectProviderRegistry.validateConfiguration(
                providerID: .openRouter,
                baseURL: nil,
                preferredModel: nil,
                maximumOutputTokens: 4096,
                customHeaders: [name: "not-a-real-value"],
                contentTypePolicy: .applicationJSON,
                revision: 1,
                updatedAt: Date()
            ), name)
        }
        let allowed = try DirectProviderRegistry.validateConfiguration(
            providerID: .openRouter,
            baseURL: nil,
            preferredModel: "openai/gpt-test",
            maximumOutputTokens: 8192,
                customHeaders: ["HTTP-Referer": "https://example.invalid", "X-Title": "RepoPrompt Server"],
            contentTypePolicy: .applicationJSON,
            revision: 1,
            updatedAt: Date()
        )
        XCTAssertEqual(allowed.customHeaders.count, 2)
    }

    func testDeploymentAndRuntimeTruthTableUsesOnlyStableDirectProviderIDs() async throws {
        let direct: [(ProviderSettingsID, String)] = [
            (.openAIAPI, "openAIAPI"),
            (.anthropicAPI, "anthropicAPI"),
            (.openRouter, "openRouter"),
            (.customOpenAICompatible, "customOpenAICompatible")
        ]
        for (providerID, rawValue) in direct {
            XCTAssertEqual(providerID.rawValue, rawValue)
            XCTAssertTrue(providerID.isDirectAPI)
            XCTAssertEqual(providerID.runtimeKind, .headlessAdapter)
        }
        XCTAssertTrue(ProviderSettingsID.xAI.isDirectAPI)
        XCTAssertEqual(ProviderSettingsID.xAI.runtimeKind, .headlessAdapter)

        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let registry = DirectProviderRegistry(
            store: store,
            transport: RecordingDirectTransport(),
            deploymentAllowlist: [.openAIAPI, .xAI]
        )
        try await registry.bootstrap()
        let admitted = await registry.isDeploymentAllowed(.openAIAPI)
        let anthropicAdmitted = await registry.isDeploymentAllowed(.anthropicAPI)
        let routerAdmitted = await registry.isDeploymentAllowed(.openRouter)
        let customAdmitted = await registry.isDeploymentAllowed(.customOpenAICompatible)
        let xaiAdmitted = await registry.isDeploymentAllowed(.xAI)
        XCTAssertTrue(admitted)
        XCTAssertFalse(anthropicAdmitted)
        XCTAssertFalse(routerAdmitted)
        XCTAssertFalse(customAdmitted)
        XCTAssertTrue(xaiAdmitted)
        XCTAssertThrowsError(try ProviderEndpointPolicy.fixed(providerID: .customOpenAICompatible))
        XCTAssertThrowsError(try ProviderEndpointPolicy.fixed(providerID: .azure))
        XCTAssertThrowsError(try ProviderEndpointPolicy.fixed(providerID: .ollama))
    }

    func testCatalogEndpointsAndAuthenticationAreProviderExact() throws {
        let openAI = try ProviderEndpointPolicy.fixed(providerID: .openAIAPI)
        let anthropic = try ProviderEndpointPolicy.fixed(providerID: .anthropicAPI)
        let router = try ProviderEndpointPolicy.fixed(providerID: .openRouter)
        let custom = DirectProviderEndpoint(scheme: "https", host: "example.com", port: 443, basePath: "/gateway")
        XCTAssertEqual(DirectProviderCredentialTester.catalogPath(providerID: .openAIAPI, endpoint: openAI), "/v1/models")
        XCTAssertEqual(DirectProviderCredentialTester.catalogPath(providerID: .anthropicAPI, endpoint: anthropic), "/v1/models")
        XCTAssertEqual(DirectProviderCredentialTester.catalogPath(providerID: .openRouter, endpoint: router), "/api/v1/models")
        XCTAssertEqual(DirectProviderCredentialTester.catalogPath(providerID: .customOpenAICompatible, endpoint: custom), "/gateway/v1/models")
        XCTAssertEqual(
            DirectProviderCredentialTester.authenticationHeaders(providerID: .anthropicAPI, credential: "write-only-value")["x-api-key"],
            "write-only-value"
        )
        XCTAssertEqual(
            DirectProviderCredentialTester.authenticationHeaders(providerID: .openRouter, credential: "write-only-value")["Authorization"],
            "Bearer write-only-value"
        )
    }

    func testCatalogSecretShapedMetadataFailsClosed() throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "data": [["id": "model-safe", "description": "api_key: catalog-secret-material"]]
        ])
        XCTAssertThrowsError(try DirectProviderCredentialTester.parseCatalog(
            response: .init(statusCode: 200, contentType: "application/json", body: body),
            providerID: .openAIAPI
        ))
    }

    func testRequestMappingSeparatesOpenAIAnthropicOpenRouterAndCustomProtocols() throws {
        let openAI = try DirectAPIProviderRuntime.mappedRequest(
            providerID: .openAIAPI,
            endpoint: ProviderEndpointPolicy.fixed(providerID: .openAIAPI),
            configuration: configuration(.openAIAPI, maximumTokens: 2048),
            credential: "write-only-openai-secret",
            model: "gpt-test",
            prompt: "hello",
            settings: ["provider.serviceTier": "priority", "provider.reasoningEffort": "high"]
        )
        let openAIBody = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(openAI.body)) as? [String: Any])
        XCTAssertEqual(openAI.pathAndQuery, "/v1/chat/completions")
        XCTAssertEqual(openAIBody["service_tier"] as? String, "priority")
        XCTAssertEqual(openAIBody["reasoning_effort"] as? String, "high")
        XCTAssertEqual(openAI.headers["Authorization"], "Bearer write-only-openai-secret")

        let anthropic = try DirectAPIProviderRuntime.mappedRequest(
            providerID: .anthropicAPI,
            endpoint: ProviderEndpointPolicy.fixed(providerID: .anthropicAPI),
            configuration: configuration(.anthropicAPI, maximumTokens: 3072),
            credential: "write-only-anthropic-secret",
            model: "claude-test",
            prompt: "hello",
            settings: [:]
        )
        let anthropicBody = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(anthropic.body)) as? [String: Any])
        XCTAssertEqual(anthropic.pathAndQuery, "/v1/messages")
        XCTAssertEqual(anthropic.headers["x-api-key"], "write-only-anthropic-secret")
        XCTAssertEqual(anthropicBody["max_tokens"] as? Int, 3072)

        let openRouter = try DirectAPIProviderRuntime.mappedRequest(
            providerID: .openRouter,
            endpoint: ProviderEndpointPolicy.fixed(providerID: .openRouter),
            configuration: configuration(.openRouter, maximumTokens: 6144, headers: ["X-Title": "RP"]),
            credential: "write-only-router-secret",
            model: "provider/model",
            prompt: "hello",
            settings: [:]
        )
        let openRouterBody = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(openRouter.body)) as? [String: Any])
        XCTAssertEqual(openRouter.pathAndQuery, "/api/v1/chat/completions")
        XCTAssertEqual(openRouter.headers["X-Title"], "RP")
        XCTAssertEqual(openRouterBody["max_tokens"] as? Int, 6144)

        let custom = try DirectAPIProviderRuntime.mappedRequest(
            providerID: .customOpenAICompatible,
            endpoint: .init(scheme: "https", host: "example.com", port: 443, basePath: "/gateway/v1"),
            configuration: configuration(.customOpenAICompatible, maximumTokens: 1024, baseURL: "https://example.com/gateway/v1"),
            credential: "write-only-custom-secret",
            model: "custom-model",
            prompt: "hello",
            settings: [:]
        )
        XCTAssertEqual(custom.pathAndQuery, "/gateway/v1/chat/completions")
    }

    func testCustomRuntimeUsesPersistedPreferredModelWhenLaunchOmitsModel() async throws {
        let configuration = configuration(
            .customOpenAICompatible,
            maximumTokens: 1024,
            baseURL: "https://example.com/gateway/v1"
        )
        let preferred = DirectProviderConfiguration(
            providerID: configuration.providerID,
            baseURL: configuration.baseURL,
            preferredModel: "preferred-custom-model",
            maximumOutputTokens: configuration.maximumOutputTokens,
            customHeaders: configuration.customHeaders,
            contentTypePolicy: configuration.contentTypePolicy,
            revision: configuration.revision,
            updatedAt: configuration.updatedAt
        )
        let registry = StaticDirectProviderRegistry(
            configuration: preferred,
            endpoint: .init(scheme: "https", host: "example.com", port: 443, basePath: "/gateway/v1")
        )
        let transport = RecordingDirectTransport()
        let runtime = DirectAPIProviderRuntime(
            providerID: .customOpenAICompatible,
            registry: registry,
            credentials: StaticDirectCredentialAccessor(),
            transport: transport
        )
        let launchAcknowledgement = ProviderLaunchAcknowledgementRecorder()
        let result = try await runtime.execute(.init(
            kind: .headlessAdapter,
            model: nil,
            prompt: "hello",
            workingDirectory: "/tmp",
            runID: UUID(),
            policy: .init(providerSettings: [
                "provider.settingsID": ProviderSettingsID.customOpenAICompatible.rawValue
            ]),
            launchAcknowledgement: { await launchAcknowledgement.record() }
        )) { _ in }
        XCTAssertEqual(result.output, "direct response")
        let launchAcknowledgementCount = await launchAcknowledgement.count()
        XCTAssertEqual(launchAcknowledgementCount, 1)
        let recordedBody = await transport.lastPostedBody()
        let postedBody = try XCTUnwrap(recordedBody)
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: postedBody) as? [String: Any])
        XCTAssertEqual(payload["model"] as? String, "preferred-custom-model")
    }

    func testDirectTransportDroppedResponseAcknowledgesSentRequestBeforeFailure() async throws {
        let configuration = configuration(
            .customOpenAICompatible,
            maximumTokens: 1024,
            baseURL: "https://example.com/gateway/v1"
        )
        let preferred = DirectProviderConfiguration(
            providerID: configuration.providerID,
            baseURL: configuration.baseURL,
            preferredModel: "custom-model",
            maximumOutputTokens: configuration.maximumOutputTokens,
            customHeaders: configuration.customHeaders,
            contentTypePolicy: configuration.contentTypePolicy,
            revision: configuration.revision,
            updatedAt: configuration.updatedAt
        )
        let registry = StaticDirectProviderRegistry(
            configuration: preferred,
            endpoint: .init(scheme: "https", host: "example.com", port: 443, basePath: "/gateway/v1")
        )
        let transport = RecordingDirectTransport(throwAfterRequestSent: true)
        let runtime = DirectAPIProviderRuntime(
            providerID: .customOpenAICompatible,
            registry: registry,
            credentials: StaticDirectCredentialAccessor(),
            transport: transport
        )
        let acknowledgement = ProviderLaunchAcknowledgementRecorder()
        do {
            _ = try await runtime.execute(.init(
                kind: .headlessAdapter,
                model: "custom-model",
                prompt: "hello",
                workingDirectory: "/tmp",
                runID: UUID(),
                policy: .init(providerSettings: [
                    "provider.settingsID": ProviderSettingsID.customOpenAICompatible.rawValue
                ]),
                launchAcknowledgement: { await acknowledgement.record() }
            )) { _ in }
            XCTFail("Expected dropped response")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .dependencyUnavailable)
        }
        let acknowledgementCount = await acknowledgement.count()
        let postCount = await transport.postCount()
        XCTAssertEqual(acknowledgementCount, 1)
        XCTAssertEqual(postCount, 1)
    }

    func testOpenAIAndAnthropicStreamMappingIsBoundedAndSanitized() async throws {
        let openAIData = Data("data: {\"choices\":[{\"delta\":{\"content\":\"hello\"}}]}\n\ndata: [DONE]\n\n".utf8)
        let openAIEvents = ProviderRuntimeEventRecorder()
        let openAI = try await DirectAPIProviderRuntime.parseOutput(
            response: .init(statusCode: 200, contentType: "text/event-stream", body: openAIData),
            providerID: .openAIAPI,
            maximumBytes: 32
        ) { await openAIEvents.append($0) }
        XCTAssertEqual(openAI, "hello")
        let recordedOpenAIEvents = await openAIEvents.values()
        XCTAssertTrue(recordedOpenAIEvents.contains(.assistantDelta("hello")))

        let anthropicData = Data("data: {\"delta\":{\"text\":\"world\"}}\n\n".utf8)
        let anthropic = try await DirectAPIProviderRuntime.parseOutput(
            response: .init(statusCode: 200, contentType: "text/event-stream", body: anthropicData),
            providerID: .anthropicAPI,
            maximumBytes: 32
        ) { _ in }
        XCTAssertEqual(anthropic, "world")

        await XCTAssertThrowsErrorAsync {
            _ = try await DirectAPIProviderRuntime.parseOutput(
                response: .init(statusCode: 200, contentType: "text/event-stream", body: openAIData),
                providerID: .openAIAPI,
                maximumBytes: 2
            ) { _ in }
        }
    }

    func testDirectConnectValidatesBeforeVaultLaunchesExactSessionDisconnectsAndRecovers() async throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".build/test-workspaces/\(UUID().uuidString)", isDirectory: true)
        let projectRoot = directory.appendingPathComponent("project", isDirectory: true)
        let database = directory.appendingPathComponent("service.sqlite")
        let vaultURL = directory.appendingPathComponent("provider.vault")
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = try ProviderVaultKey(keyID: "test-v1", material: Data(repeating: 7, count: 32))
        let transport = RecordingDirectTransport()

        var store = try await SQLiteServiceStore.open(storage: .file(database.path))
        var vault = try ProviderCredentialVault(fileURL: vaultURL, activeKey: key)
        var registry = DirectProviderRegistry(store: store, transport: transport, deploymentAllowlist: [.openAIAPI])
        try await registry.bootstrap()
        var accessor = VaultDirectProviderCredentialAccessor(store: store, vault: vault)
        var runtime = DirectAPIProviderRuntime(providerID: .openAIAPI, registry: registry, credentials: accessor, transport: transport)
        var adapter = ProviderCLIAdapter(runtimes: [], exactRuntimes: [.openAIAPI: runtime], enabledExactProviders: [.openAIAPI])
        var service = ProviderSettingsService(
            store: store,
            adapter: adapter,
            configurations: [],
            initiallyEnabled: [],
            vault: vault,
            credentialTester: DirectProviderCredentialTester(registry: registry, transport: transport),
            directProviderRegistry: registry,
            directProviderAllowlist: [.openAIAPI]
        )
        try await service.bootstrap()
        let attribution = ProviderMutationAttribution(actorID: "admin", actorLabel: "Admin", channel: "test")
        let initialDirect = try await service.directConfiguration(providerID: .openAIAPI)
        _ = try await service.updateDirectConfiguration(
            providerID: .openAIAPI,
            request: .init(
                expectedRevision: initialDirect.revision,
                baseURL: initialDirect.baseURL,
                preferredModel: initialDirect.preferredModel,
                maximumOutputTokens: initialDirect.maximumOutputTokens,
                customHeaders: initialDirect.customHeaders,
                apiVersion: initialDirect.apiVersion,
                showServiceTierVariants: true
            ),
            attribution: attribution
        )

        let connected = try await service.connect(
            providerID: .openAIAPI,
            request: .init(authenticationMethod: .apiKey, credential: "unit-test-write-only-credential"),
            attribution: attribution
        )
        XCTAssertEqual(connected.connection?.state, .connected)
        XCTAssertEqual(connected.models.map(\.id), ["gpt-direct-test"])
        XCTAssertFalse(String(describing: connected).contains("unit-test-write-only-credential"))
        let storedConnection = try await store.providerConnection(providerID: .openAIAPI)
        let storedReference = try XCTUnwrap(storedConnection?.credentialReference)

        let enabled = try await service.update(
            providerID: .openAIAPI,
            request: .init(
                expectedRevision: connected.preference.revision,
                enabled: true,
                defaultModel: "gpt-direct-test",
                reasoningEffort: "high",
                speedMode: nil,
                serviceTier: "priority"
            ),
            attribution: attribution
        )
        XCTAssertTrue(enabled.effectiveEnabled)

        let authority = RepoPromptHeadlessAuthority(store: store, providerAdapter: adapter)
        let actor = ExternalActor(userID: "u1", username: "alice", displayName: "Alice")
        let project = try await authority.createProject(
            input: .init(name: "Direct", roots: [.init(logicalName: "source", path: projectRoot.resolvingSymlinksInPath().path, writable: true)]),
            externalActor: actor,
            idempotencyKey: "direct-project",
            requestDigest: "direct-project"
        )
        let session = try await authority.createSession(
            input: .init(
                projectID: project.projectID,
                provider: .headlessAdapter,
                providerSettingsID: .openAIAPI,
                model: "gpt-direct-test",
                visibility: .privateSession,
                initialPrompt: "Direct provider prompt",
                initialProviderSettings: ["provider.settingsID": ProviderSettingsID.openAIAPI.rawValue]
            ),
            externalActor: actor,
            idempotencyKey: "direct-session",
            requestDigest: "direct-session"
        )
        _ = try await authority.execute(
            command: .resumeSession(expectedRunID: nil, providerResumeMode: .fresh),
            sessionID: session.sessionID,
            externalActor: actor,
            idempotencyKey: "direct-run",
            requestDigest: "direct-run"
        )
        await authority.waitForProviderRunsToSettle()
        let completed = try await authority.sessionSnapshot(sessionID: session.sessionID)
        XCTAssertEqual(completed.providerSettingsID, ProviderSettingsID.openAIAPI)
        XCTAssertTrue(completed.transcript.contains { $0.kind == TranscriptEntry.Kind.assistant && $0.content == "direct response" })
        let postCount = await transport.postCount()
        XCTAssertEqual(postCount, 1)

        let disconnected = try await service.disconnect(providerID: .openAIAPI, attribution: attribution, revoke: true)
        XCTAssertNil(disconnected.connection)
        do {
            _ = try await vault.load(providerID: .openAIAPI, connectionID: storedReference)
            XCTFail("Credential should have been deleted")
        } catch {}

        // Reconnect, close, and reconstruct every owner to prove restart recovery
        // loads only sanitized metadata/config/catalog while the credential stays vault-only.
        _ = try await service.connect(
            providerID: .openAIAPI,
            request: .init(authenticationMethod: .apiKey, credential: "unit-test-restart-credential"),
            attribution: attribution
        )
        try await store.close()

        store = try await SQLiteServiceStore.open(storage: .file(database.path))
        vault = try ProviderCredentialVault(fileURL: vaultURL, activeKey: key)
        registry = DirectProviderRegistry(store: store, transport: transport, deploymentAllowlist: [.openAIAPI])
        try await registry.bootstrap()
        accessor = VaultDirectProviderCredentialAccessor(store: store, vault: vault)
        runtime = DirectAPIProviderRuntime(providerID: .openAIAPI, registry: registry, credentials: accessor, transport: transport)
        adapter = ProviderCLIAdapter(runtimes: [], exactRuntimes: [.openAIAPI: runtime], enabledExactProviders: [.openAIAPI])
        service = ProviderSettingsService(
            store: store,
            adapter: adapter,
            configurations: [],
            initiallyEnabled: [],
            vault: vault,
            credentialTester: DirectProviderCredentialTester(registry: registry, transport: transport),
            directProviderRegistry: registry,
            directProviderAllowlist: [.openAIAPI]
        )
        try await service.bootstrap()
        let recoveredCatalog = try await service.catalog()
        let recovered = try XCTUnwrap(recoveredCatalog.providers.first { $0.providerID == .openAIAPI })
        XCTAssertEqual(recovered.connection?.state, .connected)
        XCTAssertEqual(recovered.models.map(\.id), ["gpt-direct-test"])
        XCTAssertTrue(recovered.effectiveEnabled)
        XCTAssertFalse(String(describing: recovered).contains("unit-test-restart-credential"))
        let audits = try await store.providerConnectionAudit()
        let safePersistence = try JSONEncoder.serviceEncoder.encode([
            "catalog": String(decoding: JSONEncoder.serviceEncoder.encode(recovered.models), as: UTF8.self),
            "audits": String(decoding: JSONEncoder.serviceEncoder.encode(audits), as: UTF8.self)
        ])
        let safePersistenceText = String(decoding: safePersistence, as: UTF8.self)
        XCTAssertFalse(safePersistenceText.contains("unit-test-write-only-credential"))
        XCTAssertFalse(safePersistenceText.contains("unit-test-restart-credential"))
        try await store.close()
    }

    func testDirectVaultReconcilesCrashOrphanAndCleansUpAfterConnectionCASFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let vaultURL = directory.appendingPathComponent("provider.vault")
        let vault = try ProviderCredentialVault(
            fileURL: vaultURL,
            activeKey: .init(keyID: "test", material: Data(repeating: 5, count: 32))
        )
        let orphanID = UUID()
        try await vault.store(
            secret: Data("unit-test-crash-orphan".utf8),
            providerID: .openAIAPI,
            connectionID: orphanID
        )
        let orphanInitiallyPresent = await vault.contains(providerID: .openAIAPI, connectionID: orphanID)
        XCTAssertTrue(orphanInitiallyPresent)

        let transport = RecordingDirectTransport()
        let registry = DirectProviderRegistry(store: store, transport: transport, deploymentAllowlist: [.openAIAPI])
        try await registry.bootstrap()
        let runtime = DirectAPIProviderRuntime(
            providerID: .openAIAPI,
            registry: registry,
            credentials: VaultDirectProviderCredentialAccessor(store: store, vault: vault),
            transport: transport
        )
        let adapter = ProviderCLIAdapter(runtimes: [], exactRuntimes: [.openAIAPI: runtime], enabledExactProviders: [.openAIAPI])
        let conflictTester = ConflictingDirectCredentialTester(store: store)
        let service = ProviderSettingsService(
            store: store,
            adapter: adapter,
            configurations: [],
            initiallyEnabled: [],
            vault: vault,
            credentialTester: conflictTester,
            directProviderRegistry: registry,
            directProviderAllowlist: [.openAIAPI]
        )
        try await service.bootstrap()
        let orphanPresentAfterBootstrap = await vault.contains(providerID: .openAIAPI, connectionID: orphanID)
        XCTAssertFalse(orphanPresentAfterBootstrap)

        do {
            _ = try await service.connect(
                providerID: .openAIAPI,
                request: .init(authenticationMethod: .apiKey, credential: "unit-test-cas-failure-credential"),
                attribution: .init(actorID: "admin", actorLabel: "Admin", channel: "test")
            )
            XCTFail("Expected the injected connection CAS failure")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .staleRevision)
        }
        let document = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: vaultURL)) as? [String: Any])
        let entries = try XCTUnwrap(document["entries"] as? [String: Any])
        XCTAssertTrue(entries.isEmpty)
    }

    func testFailedDirectValidationLeavesNoConnection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let vault = try ProviderCredentialVault(
            fileURL: directory.appendingPathComponent("provider.vault"),
            activeKey: .init(keyID: "test", material: Data(repeating: 3, count: 32))
        )
        let transport = RecordingDirectTransport(validationStatus: 503)
        let registry = DirectProviderRegistry(store: store, transport: transport, deploymentAllowlist: [.openAIAPI])
        try await registry.bootstrap()
        let runtime = DirectAPIProviderRuntime(
            providerID: .openAIAPI,
            registry: registry,
            credentials: VaultDirectProviderCredentialAccessor(store: store, vault: vault),
            transport: transport
        )
        let adapter = ProviderCLIAdapter(runtimes: [], exactRuntimes: [.openAIAPI: runtime], enabledExactProviders: [.openAIAPI])
        let service = ProviderSettingsService(
            store: store,
            adapter: adapter,
            configurations: [],
            initiallyEnabled: [],
            vault: vault,
            credentialTester: DirectProviderCredentialTester(registry: registry, transport: transport),
            directProviderRegistry: registry,
            directProviderAllowlist: [.openAIAPI]
        )
        try await service.bootstrap()
        do {
            _ = try await service.connect(
                providerID: .openAIAPI,
                request: .init(authenticationMethod: .apiKey, credential: "unit-test-never-persist"),
                attribution: .init(actorID: "admin", actorLabel: "Admin", channel: "test")
            )
            XCTFail("Expected validation failure")
        } catch {}
        let failedConnection = try await store.providerConnection(providerID: .openAIAPI)
        XCTAssertNil(failedConnection)
    }

    private func resolved(_ address: String) throws -> ResolvedProviderAddress {
        .init(ipAddress: address, socketAddress: try .init(ipAddress: address, port: 443))
    }

    private func configuration(
        _ providerID: ProviderSettingsID,
        maximumTokens: Int,
        headers: [String: String] = [:],
        baseURL: String? = nil
    ) -> DirectProviderConfiguration {
        .init(
            providerID: providerID,
            baseURL: baseURL,
            preferredModel: "test-model",
            maximumOutputTokens: maximumTokens,
            customHeaders: headers
        )
    }
}

private actor ProviderLaunchAcknowledgementRecorder {
    private var acknowledgements = 0

    func record() { acknowledgements += 1 }
    func count() -> Int { acknowledgements }
}

private actor ProviderRuntimeEventRecorder {
    private var events: [ProviderRuntimeEvent] = []
    func append(_ event: ProviderRuntimeEvent) { events.append(event) }
    func values() -> [ProviderRuntimeEvent] { events }
}

private actor SequenceHostResolver: ProviderHostResolving {
    private var sequences: [[ResolvedProviderAddress]]
    private var calls = 0

    init(sequences: [[ResolvedProviderAddress]]) { self.sequences = sequences }

    func resolve(host _: String, port _: Int) async throws -> [ResolvedProviderAddress] {
        let index = min(calls, sequences.count - 1)
        calls += 1
        return sequences[index]
    }

    func callCount() -> Int { calls }
}

private struct StaticDirectProviderRegistry: DirectProviderConfigurationProviding {
    let configuration: DirectProviderConfiguration
    let endpointValue: DirectProviderEndpoint

    init(configuration: DirectProviderConfiguration, endpoint: DirectProviderEndpoint) {
        self.configuration = configuration
        endpointValue = endpoint
    }

    func configuration(for providerID: ProviderSettingsID) async throws -> DirectProviderConfiguration {
        guard providerID == configuration.providerID else {
            throw ServiceAPIError(code: .providerUnavailable, message: "Provider is unavailable")
        }
        return configuration
    }

    func endpoint(for providerID: ProviderSettingsID) async throws -> DirectProviderEndpoint {
        guard providerID == configuration.providerID else {
            throw ServiceAPIError(code: .providerUnavailable, message: "Provider is unavailable")
        }
        return endpointValue
    }

    func isDeploymentAllowed(_ providerID: ProviderSettingsID) async -> Bool {
        providerID == configuration.providerID
    }
}

private struct StaticDirectCredentialAccessor: DirectProviderCredentialAccessing {
    func credential(for _: ProviderSettingsID) async throws -> Data {
        Data("unit-test-write-only-credential".utf8)
    }
}

private actor ConflictingDirectCredentialTester: ProviderCredentialTesting {
    private let store: SQLiteServiceStore

    init(store: SQLiteServiceStore) { self.store = store }

    func supportedAuthenticationMethods(for providerID: ProviderSettingsID) async -> Set<ProviderAuthenticationMethod> {
        providerID == .openAIAPI ? [.apiKey] : []
    }

    func test(
        providerID: ProviderSettingsID,
        method _: ProviderAuthenticationMethod,
        secret _: Data?
    ) async -> ProviderCredentialTestResult {
        let now = Date()
        let record = ProviderConnectionRecord(
            connectionID: UUID(),
            providerID: providerID,
            authenticationMethod: .apiKey,
            state: .attention,
            accountLabel: nil,
            expiresAt: nil,
            lastTestedAt: nil,
            testState: .notTested,
            detail: "Injected concurrent connection",
            keyHelperConfigured: false,
            workloadIdentityConfigured: false,
            createdAt: now,
            updatedAt: now,
            revision: 1
        )
        do {
            _ = try await store.upsertProviderConnection(.init(record: record, credentialReference: UUID()), expectedRevision: 0)
        } catch {
            return .init(state: .unavailable, detail: "Injected conflict failed")
        }
        return .init(
            state: .valid,
            detail: "Validated",
            models: [.init(id: "gpt-direct-test", displayName: "GPT Direct Test", reasoningEfforts: ["high"], serviceTiers: ["auto", "default", "flex", "priority", "scale"])]
        )
    }

    func logout(providerID _: ProviderSettingsID, method _: ProviderAuthenticationMethod) async {}
}

private actor RecordingDirectTransport: ValidatedProviderEgressTransporting {
    private let validationStatus: Int
    private let throwAfterRequestSent: Bool
    private var posts = 0
    private var postedBody: Data?

    init(validationStatus: Int = 200, throwAfterRequestSent: Bool = false) {
        self.validationStatus = validationStatus
        self.throwAfterRequestSent = throwAfterRequestSent
    }

    func validateEndpoint(_ baseURL: String) async throws -> DirectProviderEndpoint {
        try ProviderEndpointPolicy.parseCustomBaseURL(baseURL)
    }

    func execute(_ request: ValidatedProviderHTTPRequest) async throws -> ValidatedProviderHTTPResponse {
        try response(for: request)
    }

    func execute(
        _ request: ValidatedProviderHTTPRequest,
        onRequestSent: @escaping @Sendable () async throws -> Void
    ) async throws -> ValidatedProviderHTTPResponse {
        try await onRequestSent()
        if throwAfterRequestSent {
            posts += 1
            throw ServiceAPIError(code: .dependencyUnavailable, message: "response dropped", retryable: true)
        }
        return try response(for: request)
    }

    private func response(for request: ValidatedProviderHTTPRequest) throws -> ValidatedProviderHTTPResponse {
        if request.method == "GET" {
            let body = try JSONSerialization.data(withJSONObject: ["data": [["id": "gpt-direct-test", "name": "GPT Direct Test"]]])
            return .init(statusCode: validationStatus, contentType: "application/json", body: body)
        }
        posts += 1
        postedBody = request.body
        let body = Data("data: {\"choices\":[{\"delta\":{\"content\":\"direct response\"}}]}\n\ndata: [DONE]\n\n".utf8)
        return .init(statusCode: 200, contentType: "text/event-stream", body: body)
    }

    func postCount() -> Int { posts }
    func lastPostedBody() -> Data? { postedBody }
}

private struct StaticDirectProviderDefaults: DirectProviderRuntimeDefaultsProviding {
    let values: [ProviderSettingsID: DirectProviderRuntimeDefaults]

    func directProviderRuntimeDefaults(for providerID: ProviderSettingsID) async throws -> DirectProviderRuntimeDefaults {
        values[providerID] ?? .init(mode: "workspaceWrite", providerSettings: [:])
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
