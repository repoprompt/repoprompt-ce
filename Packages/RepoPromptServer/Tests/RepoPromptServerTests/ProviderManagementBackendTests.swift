import Crypto
import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import RepoPromptAgentRuntimeCore
@testable import RepoPromptHeadlessRuntime
@testable import RepoPromptServicePersistence
import RepoPromptServiceHTTP
import RepoPromptServiceProtocol
import RepoPromptWorkspaceRuntimeCore
import XCTest

@testable import RepoPromptServerHost
@testable import RepoPromptServerExecutable
final class ProviderManagementBackendTests: XCTestCase {
    func testComposerCatalogReturnsBeforeProviderStatusProbeCompletes() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        _ = try await store.upsertProviderSettings(
            ProviderSettingsPreference(providerID: .codex, enabled: true, revision: 1),
            expectedRevision: 0
        )
        let runner = SlowVersionRunner()
        let configuration = ProviderCLIConfiguration(kind: .codex, executable: "/usr/bin/swift")
        let service = ProviderSettingsService(
            store: store,
            adapter: ProviderCLIAdapter(configurations: [configuration], enabledProviders: [.codex], runner: runner),
            configurations: [configuration],
            initiallyEnabled: [.codex],
            runner: runner
        )
        try await service.bootstrap()

        let startedAt = Date()
        _ = try await service.composerCatalog()
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.2)
        await runner.waitForVersionProbe()
    }

    func testBootstrapReconcilesRetiredModelToConcreteCatalogDefaultsAndPersistsRestartSafeSelection() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let currentDefault = ProviderModelCatalogEntry(
            id: "gpt-5.6-terra",
            providerRawValue: "gpt-5.6-terra",
            displayName: "GPT-5.6 Terra",
            isProviderDefault: true,
            reasoningEfforts: ["medium", "high", "xhigh"],
            defaultReasoningEffort: "high",
            supportsNativeImages: true,
            supportsSteering: true
        )
        _ = try await store.replaceProviderModelCatalog(
            providerID: .codex,
            models: [currentDefault],
            expectedRevision: 0
        )
        _ = try await store.upsertProviderSettings(
            ProviderSettingsPreference(
                providerID: .codex,
                enabled: true,
                defaultModel: "retired-model",
                reasoningEffort: "retired-effort",
                speedMode: "fast",
                serviceTier: "fast",
                revision: 1
            ),
            expectedRevision: 0
        )

        let configuration = ProviderCLIConfiguration(kind: .codex, executable: "/usr/bin/swift")
        let first = ProviderSettingsService(
            store: store,
            adapter: ProviderCLIAdapter(configurations: [configuration], enabledProviders: [.codex], runner: StaticVersionRunner()),
            configurations: [configuration],
            initiallyEnabled: [.codex],
            runner: StaticVersionRunner()
        )
        try await first.bootstrap()
        let firstCatalog = try await first.catalog()
        let firstCodex = try XCTUnwrap(firstCatalog.providers.first { $0.providerID == .codex })
        XCTAssertEqual(firstCodex.preference.defaultModel, currentDefault.id)
        XCTAssertEqual(firstCodex.preference.reasoningEffort, "high")
        XCTAssertNil(firstCodex.preference.speedMode)
        XCTAssertNil(firstCodex.preference.serviceTier)
        XCTAssertEqual(firstCodex.preference.revision, 2)

        let persistedSettings = try await store.providerSettings()
        let persisted = try XCTUnwrap(persistedSettings.first { $0.providerID == .codex })
        XCTAssertEqual(persisted, firstCodex.preference)

        let second = ProviderSettingsService(
            store: store,
            adapter: ProviderCLIAdapter(configurations: [configuration], enabledProviders: [.codex], runner: StaticVersionRunner()),
            configurations: [configuration],
            initiallyEnabled: [.codex],
            runner: StaticVersionRunner()
        )
        try await second.bootstrap()
        let secondCatalog = try await second.catalog()
        let secondCodex = try XCTUnwrap(secondCatalog.providers.first { $0.providerID == .codex })
        XCTAssertEqual(secondCodex.preference, firstCodex.preference)
    }

    func testBootstrapClearsRetiredSelectionWhenCatalogIsUnavailable() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        _ = try await store.upsertProviderSettings(
            ProviderSettingsPreference(
                providerID: .codex,
                enabled: true,
                defaultModel: "retired-model",
                reasoningEffort: "retired-effort",
                speedMode: "fast",
                serviceTier: "fast",
                revision: 1
            ),
            expectedRevision: 0
        )

        let configuration = ProviderCLIConfiguration(kind: .codex, executable: "/usr/bin/swift")
        let first = ProviderSettingsService(
            store: store,
            adapter: ProviderCLIAdapter(configurations: [configuration], enabledProviders: [.codex], runner: StaticVersionRunner()),
            configurations: [configuration],
            initiallyEnabled: [.codex],
            runner: StaticVersionRunner()
        )
        try await first.bootstrap()
        let firstCatalog = try await first.catalog()
        let firstCodex = try XCTUnwrap(firstCatalog.providers.first { $0.providerID == .codex })
        XCTAssertNil(firstCodex.preference.defaultModel)
        XCTAssertNil(firstCodex.preference.reasoningEffort)
        XCTAssertNil(firstCodex.preference.speedMode)
        XCTAssertNil(firstCodex.preference.serviceTier)
        XCTAssertEqual(firstCodex.preference.revision, 2)

        let second = ProviderSettingsService(
            store: store,
            adapter: ProviderCLIAdapter(configurations: [configuration], enabledProviders: [.codex], runner: StaticVersionRunner()),
            configurations: [configuration],
            initiallyEnabled: [.codex],
            runner: StaticVersionRunner()
        )
        try await second.bootstrap()
        let secondCatalog = try await second.catalog()
        let secondCodex = try XCTUnwrap(secondCatalog.providers.first { $0.providerID == .codex })
        XCTAssertEqual(secondCodex.preference, firstCodex.preference)
    }

    func testProviderRedactionRemovesKnownAndTokenShapedSecrets() {
        let known = "opaque-credential-value"
        let redacted = ProviderSecretRedaction.redact("Authorization bearer xai-1234567890 and \(known)", knownSecrets: [known])
        XCTAssertFalse(redacted.contains("xai-1234567890"))
        XCTAssertFalse(redacted.contains(known))
        XCTAssertTrue(redacted.contains("<redacted>"))
    }

    func testReadinessSeparatesRuntimeAvailabilityFromDisconnectedAuthentication() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let configuration = ProviderCLIConfiguration(
            kind: .codex,
            executable: "/usr/bin/swift",
            expectedVersion: "6.2",
            protocolVersion: "app-server-v2"
        )
        let adapter = ProviderCLIAdapter(
            configurations: [configuration],
            enabledProviders: [.codex],
            runner: StaticVersionRunner()
        )
        let providerSettings = ProviderSettingsService(
            store: store,
            adapter: adapter,
            configurations: [configuration],
            initiallyEnabled: [.codex],
            runner: StaticVersionRunner()
        )
        try await providerSettings.bootstrap()
        var catalog = try await providerSettings.catalog()
        var codexSettings = try XCTUnwrap(catalog.providers.first { $0.providerID == .codex })
        XCTAssertTrue(codexSettings.runtimePreflightVerified)
        _ = try await providerSettings.update(
            providerID: .codex,
            request: .init(
                expectedRevision: codexSettings.preference.revision,
                enabled: true,
                defaultModel: nil,
                reasoningEffort: nil,
                speedMode: nil,
                serviceTier: nil
            )
        )
        catalog = try await providerSettings.catalog()
        codexSettings = try XCTUnwrap(catalog.providers.first { $0.providerID == .codex })
        XCTAssertEqual(codexSettings.preflight.reason, .missingCredential)

        let readiness = RepoPromptReadinessService(
            authority: RepoPromptHeadlessAuthority(store: store, providerAdapter: adapter),
            store: store,
            requiredProviders: [.codex],
            expectedProviderProtocols: [.codex: "app-server-v2"],
            minimumFreeBytes: 0,
            minimumFreeNodes: 0,
            maximumActiveSessions: 10,
            cacheDuration: 0,
            providerSettings: providerSettings
        )
        let snapshot = await readiness.snapshot(forceRefresh: true)
        XCTAssertTrue(snapshot.ready)
        XCTAssertTrue(snapshot.providers.isEmpty)
        try await store.close()
    }

    func testVaultEncryptsAtomicallyMigratesAndRotatesWithoutPlaintext() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("credentials.vault")
        let first = try ProviderVaultKey(keyID: "key-v1", material: Data(repeating: 7, count: 32))
        let second = try ProviderVaultKey(keyID: "key-v2", material: Data(repeating: 9, count: 32))
        let connectionID = UUID()
        let secret = Data("xai-write-only-secret-value".utf8)

        let vault = try ProviderCredentialVault(fileURL: file, activeKey: first)
        try await vault.store(secret: secret, providerID: .xAI, connectionID: connectionID)
        let initiallyLoaded = try await vault.load(providerID: .xAI, connectionID: connectionID)
        XCTAssertEqual(initiallyLoaded, secret)
        XCTAssertEqual(try (FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertFalse(try String(decoding: Data(contentsOf: file), as: UTF8.self).contains("xai-write-only-secret-value"))

        try await vault.rotate(to: second)
        let rotated = try await vault.load(providerID: .xAI, connectionID: connectionID)
        XCTAssertEqual(rotated, secret)
        let reopened = try ProviderCredentialVault(fileURL: file, activeKey: second)
        let reopenedSecret = try await reopened.load(providerID: .xAI, connectionID: connectionID)
        XCTAssertEqual(reopenedSecret, secret)
        XCTAssertThrowsError(try ProviderCredentialVault(fileURL: file, activeKey: first))
    }

    func testVaultMigratesEncryptedSchemaV1Document() async throws {
        struct LegacyPayload: Codable { let providerID: ProviderSettingsID
            let secret: Data
        }
        struct LegacyDocument: Codable { let schemaVersion: Int
            let generation: Int64
            let entries: [String: String]
            let keyID: String
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("legacy.vault")
        let key = try ProviderVaultKey(keyID: "legacy", material: Data(repeating: 4, count: 32))
        let connectionID = UUID()
        let secret = Data("legacy-secret-never-plaintext".utf8)
        let clear = try JSONEncoder.serviceEncoder.encode(LegacyPayload(providerID: .codex, secret: secret))
        let sealed = try XCTUnwrap(AES.GCM.seal(clear, using: SymmetricKey(data: key.material)).combined)
        let data = try JSONEncoder.serviceEncoder.encode(LegacyDocument(schemaVersion: 1, generation: 2, entries: [connectionID.uuidString: sealed.base64EncodedString()], keyID: key.keyID))
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600]))

        let vault = try ProviderCredentialVault(fileURL: file, activeKey: key)
        let migratedSecret = try await vault.load(providerID: .codex, connectionID: connectionID)
        XCTAssertEqual(migratedSecret, secret)
        let migrated = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(migrated["schemaVersion"] as? Int, 2)
        XCTAssertFalse(try String(decoding: Data(contentsOf: file), as: UTF8.self).contains("legacy-secret-never-plaintext"))
    }

    func testMasterKeyFileRequiresStrict0600() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: Data(repeating: 1, count: 32), attributes: [.posixPermissions: 0o644]))
        XCTAssertThrowsError(try ProviderVaultKey.load(keyID: "test", filePath: file.path))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        XCTAssertNoThrow(try ProviderVaultKey.load(keyID: "test", filePath: file.path))
    }

    func testProductionCredentialValidatorUsesFixedHTTPSHeaderContractsAndClosedResults() async throws {
        let transport = RecordingCredentialHTTPTransport(statusCode: 200)
        let adapter = ProviderAuthenticationAdapter(
            configurations: [
                .init(kind: .codex, executable: "/usr/bin/true"),
                .init(kind: .claudeCompatible, executable: "/usr/bin/true"),
                .init(kind: .grokBuildACP, executable: "/usr/bin/true")
            ],
            transport: transport
        )
        let openAISecret = "sk-test-openai-secret"
        let anthropicSecret = "sk-ant-test-secret"
        let grokSecret = "xai-test-grok-secret"

        let openAI = await adapter.test(providerID: .codex, method: .apiKey, secret: Data(openAISecret.utf8))
        let anthropic = await adapter.test(providerID: .claudeCompatible, method: .apiKey, secret: Data(anthropicSecret.utf8))
        let grok = await adapter.test(providerID: .grokBuildACP, method: .apiKey, secret: Data(grokSecret.utf8))
        let requests = await transport.requests()

        XCTAssertEqual(openAI.state, .valid)
        XCTAssertEqual(openAI.detail, "OpenAI credential validated")
        XCTAssertEqual(anthropic.state, .valid)
        XCTAssertEqual(anthropic.detail, "Anthropic credential validated")
        XCTAssertEqual(grok.state, .valid)
        XCTAssertEqual(grok.detail, "Grok credential validated")
        XCTAssertEqual(requests.map { $0.url?.absoluteString }, [
            "https://api.openai.com/v1/models",
            "https://api.anthropic.com/v1/models?limit=1",
            "https://api.x.ai/v1/models"
        ])
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer \(openAISecret)")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "x-api-key"), anthropicSecret)
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(requests[2].value(forHTTPHeaderField: "Authorization"), "Bearer \(grokSecret)")
        XCTAssertFalse(requests.compactMap { $0.url?.absoluteString }.contains { $0.contains(openAISecret) || $0.contains(anthropicSecret) || $0.contains(grokSecret) })

        let unsupported = await adapter.test(providerID: .claudeCompatible, method: .authToken, secret: Data(anthropicSecret.utf8))
        XCTAssertEqual(unsupported.state, .unavailable)
        XCTAssertFalse(unsupported.detail.contains(anthropicSecret))
    }

    func testProductionCredentialValidatorClassifiesRejectionAndSanitizesTransportFailure() async {
        let rejected = ProviderAuthenticationAdapter(
            configurations: [.init(kind: .codex, executable: "/usr/bin/true")],
            transport: RecordingCredentialHTTPTransport(statusCode: 401)
        )
        let rejectedResult = await rejected.test(providerID: .codex, method: .apiKey, secret: Data("sk-rejected-secret".utf8))
        XCTAssertEqual(rejectedResult.state, .invalid)
        XCTAssertEqual(rejectedResult.detail, "Provider rejected the configured credential")

        let failed = ProviderAuthenticationAdapter(
            configurations: [.init(kind: .codex, executable: "/usr/bin/true")],
            transport: FailingCredentialHTTPTransport()
        )
        let secret = "sk-transport-secret"
        let failedResult = await failed.test(providerID: .codex, method: .apiKey, secret: Data(secret.utf8))
        XCTAssertEqual(failedResult.state, .unavailable)
        XCTAssertEqual(failedResult.detail, "Provider credential validation is temporarily unavailable")
        XCTAssertFalse(failedResult.detail.contains(secret))
    }

    func testClaudeCompatiblePresetValidatorsUseFixedHostsAndConfiguredHeaderStyles() async throws {
        let transport = RecordingCredentialHTTPTransport(statusCode: 200)
        let settings = StaticClaudeBackendSettings(configurations: [
            .claudeGLM: .init(
                providerID: .claudeGLM,
                displayName: "CC Zai",
                baseURL: "https://api.z.ai/api/anthropic",
                authHeader: .anthropicAuthToken,
                modelBehavior: .claudeSlotMapping,
                sonnetModel: "glm-5.2[1m]"
            ),
            .claudeKimi: .init(
                providerID: .claudeKimi,
                displayName: "CC Moonshot",
                baseURL: "https://api.kimi.com/coding/",
                authHeader: .anthropicAPIKey,
                modelBehavior: .noModel
            )
        ])
        let adapter = ProviderAuthenticationAdapter(
            configurations: [.init(kind: .claudeCompatible, executable: "/usr/bin/true")],
            transport: transport,
            backendSettings: settings
        )

        let glmMethods = await adapter.supportedAuthenticationMethods(for: .claudeGLM)
        let kimiMethods = await adapter.supportedAuthenticationMethods(for: .claudeKimi)
        let customMethods = await adapter.supportedAuthenticationMethods(for: .claudeCustom)
        XCTAssertEqual(glmMethods, [.authToken])
        XCTAssertEqual(kimiMethods, [.apiKey])
        XCTAssertTrue(customMethods.isEmpty)
        let zaiSecret = "zai-write-only-secret"
        let kimiSecret = "kimi-write-only-secret"
        let glmResult = await adapter.test(providerID: .claudeGLM, method: .authToken, secret: Data(zaiSecret.utf8))
        let kimiResult = await adapter.test(providerID: .claudeKimi, method: .apiKey, secret: Data(kimiSecret.utf8))
        XCTAssertEqual(glmResult.state, .valid)
        XCTAssertEqual(kimiResult.state, .valid)
        let requests = await transport.requests()
        XCTAssertEqual(requests.map { $0.url?.absoluteString }, [
            "https://api.z.ai/api/anthropic/v1/messages",
            "https://api.kimi.com/coding/v1/messages"
        ])
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer \(zaiSecret)")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "x-api-key"), kimiSecret)
        let encodedBodies = requests.compactMap(\.httpBody).map { String(decoding: $0, as: UTF8.self) }
        XCTAssertFalse(encodedBodies.contains { $0.contains(zaiSecret) || $0.contains(kimiSecret) })
    }

    func testAPIKeyConnectionIsEncryptedAuditedValidatedAndInjectedOnlyThroughEnvironment() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let vault = try ProviderCredentialVault(fileURL: directory.appendingPathComponent("vault"), activeKey: ProviderVaultKey(keyID: "test", material: Data(repeating: 3, count: 32)))
        let configuration = ProviderCLIConfiguration(kind: .codex, executable: "/usr/bin/swift")
        let adapter = ProviderCLIAdapter(configurations: [configuration], enabledProviders: [.codex], runner: StaticVersionRunner())
        let tester = RecordingCredentialTester(result: .init(state: .valid, detail: "Credential accepted"))
        let service = ProviderSettingsService(store: store, adapter: adapter, configurations: [configuration], initiallyEnabled: [.codex], vault: vault, credentialTester: tester, runner: StaticVersionRunner())
        try await service.bootstrap()
        let initialCatalog = try await service.catalog()
        let initialCodex = try XCTUnwrap(initialCatalog.providers.first { $0.providerID == .codex })
        XCTAssertEqual(Set(initialCodex.capabilities.authenticationMethods), [.deviceCodeBeta, .apiKey])
        XCTAssertTrue(initialCodex.capabilities.authFlows.contains { $0.kind == .deviceCodeBeta })
        _ = try await service.update(
            providerID: .codex,
            request: .init(
                expectedRevision: initialCodex.preference.revision,
                enabled: true,
                defaultModel: nil,
                reasoningEffort: nil,
                speedMode: nil,
                serviceTier: nil
            )
        )
        let attribution = ProviderMutationAttribution(actorID: "admin-1", actorLabel: "alice", channel: "test")
        let secret = "sk-test-write-only-value"

        var snapshot = try await service.connect(providerID: .codex, request: .init(authenticationMethod: .apiKey, credential: secret, accountLabel: "team"), attribution: attribution)
        XCTAssertEqual(snapshot.connection?.testState, .notTested)
        XCTAssertFalse(snapshot.effectiveEnabled)
        snapshot = try await service.testConnection(providerID: .codex, attribution: attribution)
        XCTAssertEqual(snapshot.connection?.testState, .valid)
        XCTAssertTrue(snapshot.effectiveEnabled)

        let environment = try await VaultProviderProcessEnvironment(store: store, vault: vault)
            .environment(for: .codex, model: nil, policy: .init())
        XCTAssertEqual(environment, ["OPENAI_API_KEY": secret])
        let encoded = try String(decoding: JSONEncoder.serviceEncoder.encode(snapshot), as: UTF8.self)
        XCTAssertFalse(encoded.contains(secret))
        let audits = try await store.providerConnectionAudit()
        XCTAssertEqual(audits.map(\.operation), ["connect", "test"])
        XCTAssertFalse(try String(decoding: JSONEncoder.serviceEncoder.encode(audits), as: UTF8.self).contains(secret))

        snapshot = try await service.disconnect(providerID: .codex, attribution: attribution)
        XCTAssertNil(snapshot.connection)
        let remainingConnections = try await store.providerConnections()
        XCTAssertTrue(remainingConnections.isEmpty)
    }

    func testGrokBuildAPIKeyConnectionInjectsXAIAPIKeyWithoutCollapsingOntoDirectXAI() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let vault = try ProviderCredentialVault(fileURL: directory.appendingPathComponent("vault"), activeKey: ProviderVaultKey(keyID: "test", material: Data(repeating: 3, count: 32)))
        let configuration = ProviderCLIConfiguration(kind: .grokBuildACP, executable: "/usr/bin/swift")
        let adapter = ProviderCLIAdapter(configurations: [configuration], enabledProviders: [.grokBuildACP], runner: StaticVersionRunner())
        let tester = RecordingCredentialTester(result: .init(state: .valid, detail: "Credential accepted"))
        let service = ProviderSettingsService(store: store, adapter: adapter, configurations: [configuration], initiallyEnabled: [.grokBuildACP], vault: vault, credentialTester: tester, runner: StaticVersionRunner())
        try await service.bootstrap()
        let initialCatalog = try await service.catalog()
        let initialGrok = try XCTUnwrap(initialCatalog.providers.first { $0.providerID == .grokBuildACP })
        XCTAssertEqual(Set(initialGrok.capabilities.authenticationMethods), [.apiKey])
        XCTAssertNotEqual(initialGrok.providerID, .xAI)
        let attribution = ProviderMutationAttribution(actorID: "admin-1", actorLabel: "alice", channel: "test")
        let secret = "xai-test-write-only-value"

        var snapshot = try await service.connect(providerID: .grokBuildACP, request: .init(authenticationMethod: .apiKey, credential: secret, accountLabel: "grok"), attribution: attribution)
        snapshot = try await service.testConnection(providerID: .grokBuildACP, attribution: attribution)
        XCTAssertEqual(snapshot.connection?.testState, .valid)

        let environment = try await VaultProviderProcessEnvironment(store: store, vault: vault)
            .environment(for: .grokBuildACP, model: nil, policy: .init())
        XCTAssertEqual(environment, ["XAI_API_KEY": secret])
        let xAIConnection = try await store.providerConnection(providerID: .xAI)
        XCTAssertNil(xAIConnection)
        let encoded = try String(decoding: JSONEncoder.serviceEncoder.encode(snapshot), as: UTF8.self)
        XCTAssertFalse(encoded.contains(secret))
    }

    func testCredentialCannotBePersistedAsAccountLabel() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let vault = try ProviderCredentialVault(fileURL: directory.appendingPathComponent("vault"), activeKey: ProviderVaultKey(keyID: "test", material: Data(repeating: 3, count: 32)))
        let configuration = ProviderCLIConfiguration(kind: .codex, executable: "/usr/bin/swift")
        let adapter = ProviderCLIAdapter(configurations: [configuration], enabledProviders: [.codex], runner: StaticVersionRunner())
        let tester = EchoingCredentialTester()
        let service = ProviderSettingsService(store: store, adapter: adapter, configurations: [configuration], initiallyEnabled: [.codex], vault: vault, credentialTester: tester, runner: StaticVersionRunner())
        try await service.bootstrap()
        let attribution = ProviderMutationAttribution(actorID: "admin-1", actorLabel: "alice", channel: "test")

        do {
            _ = try await service.connect(providerID: .codex, request: .init(authenticationMethod: .apiKey, credential: "  opaquecredential  ", accountLabel: "opaquecredential"), attribution: attribution)
            XCTFail("normalized credential was accepted as an account label")
        } catch let error as ServiceAPIError { XCTAssertEqual(error.code, .invalidRequest) }

        _ = try await service.connect(providerID: .codex, request: .init(authenticationMethod: .apiKey, credential: "opaquecredential"), attribution: attribution)
        do {
            _ = try await service.testConnection(providerID: .codex, attribution: attribution)
            XCTFail("validator-returned credential was accepted as an account label")
        } catch let error as ServiceAPIError { XCTAssertEqual(error.code, .dependencyUnavailable) }
        let persisted = try await store.providerConnection(providerID: .codex)
        let stored = try XCTUnwrap(persisted)
        XCTAssertNil(stored.record.accountLabel)
        XCTAssertEqual(stored.record.testState, .notTested)
    }

    func testMountedCLIAccountsAdvertiseSingleExternalConnectMethodsWithoutVault() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }

        let configurations: [ProviderCLIConfiguration] = try [
            (ProviderKind.claudeCompatible, "claude"),
            (.openCodeACP, "opencode"),
            (.cursorACP, "cursor"),
            (.grokBuildACP, "grok")
        ].map { kind, name in
            let credentialDirectory = directory.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: credentialDirectory, withIntermediateDirectories: true)
            return ProviderCLIConfiguration(
                kind: kind,
                executable: "/usr/bin/swift",
                credentialSourceDirectory: credentialDirectory.path
            )
        }
        let enabled = Set(configurations.map(\.kind))
        let adapter = ProviderCLIAdapter(
            configurations: configurations,
            enabledProviders: enabled,
            runner: StaticVersionRunner()
        )
        let service = ProviderSettingsService(
            store: store,
            adapter: adapter,
            configurations: configurations,
            initiallyEnabled: enabled,
            runner: StaticVersionRunner()
        )
        try await service.bootstrap()

        let catalog = try await service.catalog()
        XCTAssertEqual(
            catalog.providers.first { $0.providerID == .claudeCompatible }?.capabilities.authenticationMethods,
            [.providerSpecific]
        )
        XCTAssertEqual(
            catalog.providers.first { $0.providerID == .openCodeACP }?.capabilities.authenticationMethods,
            [.providerSpecific]
        )
        XCTAssertEqual(
            catalog.providers.first { $0.providerID == .cursorACP }?.capabilities.authenticationMethods,
            [.browserLogin]
        )
        XCTAssertEqual(
            catalog.providers.first { $0.providerID == .grokBuildACP }?.capabilities.authenticationMethods,
            [.providerSpecific]
        )
        XCTAssertTrue(
            catalog.providers.first { $0.providerID == .claudeGLM }?.capabilities.authenticationMethods.isEmpty == true
        )

        let attribution = ProviderMutationAttribution(actorID: "admin-1", actorLabel: "alice", channel: "test")
        for (providerID, method) in [
            (ProviderSettingsID.claudeCompatible, ProviderAuthenticationMethod.providerSpecific),
            (.openCodeACP, .providerSpecific),
            (.cursorACP, .browserLogin),
            (.grokBuildACP, .providerSpecific)
        ] {
            do {
                _ = try await service.connect(
                    providerID: providerID,
                    request: .init(authenticationMethod: method, credential: "must-not-proxy"),
                    attribution: attribution
                )
                XCTFail("\(providerID.rawValue) accepted raw browser credential material")
            } catch let error as ServiceAPIError {
                XCTAssertEqual(error.code, .invalidRequest)
            }
        }
        let rejectedConnections = try await store.providerConnections()
        XCTAssertTrue(rejectedConnections.isEmpty)

        for (providerID, method) in [
            (ProviderSettingsID.claudeCompatible, ProviderAuthenticationMethod.providerSpecific),
            (.openCodeACP, .providerSpecific),
            (.cursorACP, .browserLogin),
            (.grokBuildACP, .providerSpecific)
        ] {
            var snapshot = try await service.connect(
                providerID: providerID,
                request: .init(authenticationMethod: method),
                attribution: attribution
            )
            XCTAssertEqual(snapshot.connection?.testState, .valid)
            XCTAssertEqual(snapshot.connection?.state, .connected)
            if providerID == .claudeCompatible {
                XCTAssertEqual(snapshot.connection?.detail, "Claude Code account authorization verified")
                XCTAssertNil(snapshot.connection?.accountLabel)
                let encoded = try String(decoding: JSONEncoder.serviceEncoder.encode(snapshot), as: UTF8.self)
                XCTAssertFalse(encoded.contains("must-not-project"))
            }
            snapshot = try await service.testConnection(providerID: providerID, attribution: attribution)
            XCTAssertEqual(snapshot.connection?.testState, .valid)
            XCTAssertEqual(snapshot.connection?.authenticationMethod, method)
        }

        let stored = try await store.providerConnections()
        XCTAssertEqual(stored.count, 4)
        XCTAssertTrue(stored.allSatisfy { $0.credentialReference == nil })
    }

    func testClaudeExternalConnectRejectsMountedButUnauthenticatedAccount() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let configuration = ProviderCLIConfiguration(
            kind: .claudeCompatible,
            executable: "/usr/bin/swift",
            credentialSourceDirectory: directory.path
        )
        let service = ProviderSettingsService(
            store: store,
            adapter: ProviderCLIAdapter(
                configurations: [configuration],
                enabledProviders: [.claudeCompatible],
                runner: StaticVersionRunner()
            ),
            configurations: [configuration],
            initiallyEnabled: [.claudeCompatible],
            runner: UnauthenticatedClaudeRunner()
        )
        try await service.bootstrap()

        do {
            _ = try await service.connect(
                providerID: .claudeCompatible,
                request: .init(authenticationMethod: .providerSpecific),
                attribution: .init(actorID: "admin-1", actorLabel: "alice", channel: "test")
            )
            XCTFail("an unauthenticated mounted Claude account was marked connected")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .dependencyUnavailable)
            XCTAssertEqual(
                error.message,
                "Claude Code is not authenticated; run 'claude login' in the dedicated server account"
            )
        }
        let stored = try await store.providerConnections()
        XCTAssertTrue(stored.isEmpty)
    }

    func testConnectionRejectsUnsupportedControlsAndOpenCodeRawCredentialProxying() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let configuration = ProviderCLIConfiguration(kind: .codex, executable: "/usr/bin/swift")
        let adapter = ProviderCLIAdapter(configurations: [configuration], enabledProviders: [.codex], runner: StaticVersionRunner())
        let service = ProviderSettingsService(store: store, adapter: adapter, configurations: [configuration], initiallyEnabled: [.codex], runner: StaticVersionRunner())
        try await service.bootstrap()
        let catalog = try await service.catalog()
        let codex = try XCTUnwrap(catalog.providers.first { $0.providerID == .codex })
        do {
            _ = try await service.update(providerID: .codex, request: .init(expectedRevision: codex.preference.revision, enabled: true, defaultModel: "gpt-5.6-sol", reasoningEffort: "impossible", speedMode: nil, serviceTier: nil))
            XCTFail("unsupported control was accepted")
        } catch let error as ServiceAPIError { XCTAssertEqual(error.code, .invalidRequest) }
        do {
            _ = try await service.connect(providerID: .openCodeACP, request: .init(authenticationMethod: .providerSpecific, credential: "must-not-proxy"), attribution: .init(actorID: "a", actorLabel: "a", channel: "test"))
            XCTFail("OpenCode raw credential proxy was accepted")
        } catch let error as ServiceAPIError { XCTAssertEqual(error.code, .capabilityMissing) }
    }

    func testDeviceAndAPIKeyAreIndependentEqualChoicesAndExplicitSelectionSwitchesRuntimeAuth() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let vault = try ProviderCredentialVault(
            fileURL: directory.appendingPathComponent("vault"),
            activeKey: ProviderVaultKey(keyID: "test", material: Data(repeating: 5, count: 32))
        )
        let configuration = ProviderCLIConfiguration(kind: .codex, executable: "/usr/bin/swift")
        let adapter = ProviderCLIAdapter(configurations: [configuration], enabledProviders: [.codex], runner: StaticVersionRunner())
        let managed = CompletingManagedAuthDriver()
        let service = ProviderSettingsService(
            store: store,
            adapter: adapter,
            configurations: [configuration],
            initiallyEnabled: [.codex],
            authFlows: TransientProviderAuthFlowCoordinator(driver: managed),
            managedAuthentication: managed,
            vault: vault,
            credentialTester: RecordingCredentialTester(result: .init(state: .valid, detail: "Credential accepted")),
            runner: StaticVersionRunner()
        )
        try await service.bootstrap()
        let initial = try await service.catalog()
        let codex = try XCTUnwrap(initial.providers.first { $0.providerID == .codex })
        XCTAssertEqual(Set(codex.capabilities.authenticationMethods), [.deviceCodeBeta, .apiKey])
        XCTAssertEqual(codex.capabilities.authFlows.map(\.kind), [.deviceCodeBeta])

        let attribution = ProviderMutationAttribution(actorID: "admin-1", actorLabel: "alice", channel: "test")
        let pending = try await service.startAuthFlow(
            providerID: .codex,
            request: .init(kind: .deviceCodeBeta),
            attribution: attribution
        )
        let completed = try await service.pollAuthFlow(flowID: pending.flowID, ownerID: attribution.actorID)
        XCTAssertEqual(completed.state, .completed)
        let completedCatalog = try await service.catalog()
        var snapshot = completedCatalog.providers.first { $0.providerID == .codex }
        XCTAssertEqual(snapshot?.connection?.authenticationMethod, .deviceCodeBeta)
        XCTAssertEqual(snapshot?.connection?.testState, .valid)

        snapshot = try await service.connect(
            providerID: .codex,
            request: .init(authenticationMethod: .apiKey, credential: "sk-explicit-api-key"),
            attribution: attribution
        )
        XCTAssertEqual(snapshot?.connection?.authenticationMethod, .apiKey)
        XCTAssertEqual(snapshot?.connection?.testState, .notTested)
        let logoutCount = await managed.logoutCount()
        XCTAssertEqual(logoutCount, 1)
    }

    func testTransientManagedCodexProbePreservesLastVerifiedConnection() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let configuration = ProviderCLIConfiguration(
            kind: .codex,
            executable: "/usr/bin/true",
            expectedVersion: "test",
            protocolVersion: "app-server-v2"
        )
        let managed = CompletingManagedAuthDriver(state: .authenticated(accountLabel: "owner@example.com"))
        let now = Date()
        let connection = ProviderConnectionRecord(
            connectionID: UUID(),
            providerID: .codex,
            authenticationMethod: .deviceCodeBeta,
            state: .connected,
            accountLabel: "owner@example.com",
            lastTestedAt: now,
            testState: .valid,
            detail: "ChatGPT account authenticated by the server",
            keyHelperConfigured: false,
            workloadIdentityConfigured: false,
            createdAt: now,
            updatedAt: now,
            revision: 1
        )
        _ = try await store.upsertProviderConnection(
            .init(record: connection, credentialReference: nil),
            expectedRevision: 0
        )
        let service = ProviderSettingsService(
            store: store,
            adapter: ProviderCLIAdapter(configurations: [configuration], enabledProviders: [.codex]),
            configurations: [configuration],
            initiallyEnabled: [.codex],
            managedAuthentication: managed
        )
        try await service.bootstrap()
        await managed.setAuthenticationState(.unavailable)

        let snapshot = try await service.testConnection(
            providerID: .codex,
            attribution: .init(actorID: "admin-1", actorLabel: "alice", channel: "test")
        )

        XCTAssertEqual(snapshot.connection?.state, .connected)
        XCTAssertEqual(snapshot.connection?.testState, .valid)
        XCTAssertEqual(snapshot.connection?.detail, "ChatGPT account authenticated by the server")
        XCTAssertTrue(snapshot.authentication.authenticated)
    }

    func testStartupRecoveryRechecksLegacyUnavailableManagedCodexConnection() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let configuration = ProviderCLIConfiguration(
            kind: .codex,
            executable: "/usr/bin/true",
            expectedVersion: "test",
            protocolVersion: "app-server-v2"
        )
        let managed = CompletingManagedAuthDriver(state: .authenticated(accountLabel: "owner@example.com"))
        let now = Date()
        let connection = ProviderConnectionRecord(
            connectionID: UUID(),
            providerID: .codex,
            authenticationMethod: .deviceCodeBeta,
            state: .attention,
            accountLabel: "owner@example.com",
            lastTestedAt: now,
            testState: .unavailable,
            detail: "Codex authentication status is temporarily unavailable",
            keyHelperConfigured: false,
            workloadIdentityConfigured: false,
            createdAt: now,
            updatedAt: now,
            revision: 1
        )
        _ = try await store.upsertProviderConnection(
            .init(record: connection, credentialReference: nil),
            expectedRevision: 0
        )
        let service = ProviderSettingsService(
            store: store,
            adapter: ProviderCLIAdapter(configurations: [configuration], enabledProviders: [.codex]),
            configurations: [configuration],
            initiallyEnabled: [.codex],
            managedAuthentication: managed
        )
        try await service.bootstrap()

        await service.startConnectedProviderRecovery()
        var recovered = false
        for _ in 0 ..< 50 {
            let codex = try await store.providerConnection(providerID: .codex)
            if codex?.record.state == .connected, codex?.record.testState == .valid {
                recovered = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertTrue(recovered)
    }

    func testTransientAuthFlowIsOwnerFencedAndCancelRemovesState() async throws {
        let driver = FakeAuthFlowDriver()
        let coordinator = TransientProviderAuthFlowCoordinator(driver: driver)
        let status = try await coordinator.start(providerID: .codex, kind: .deviceCodeBeta, ownerID: "admin-a")
        XCTAssertEqual(status.userCode, "ABCD-EFGH")
        do {
            _ = try await coordinator.poll(flowID: status.flowID, ownerID: "admin-b")
            XCTFail("another administrator accessed the device code")
        } catch let error as ServiceAPIError { XCTAssertEqual(error.code, .notFound) }
        try await coordinator.cancel(flowID: status.flowID, ownerID: "admin-a")
        let wasCancelled = await driver.wasCancelled(status.flowID)
        XCTAssertTrue(wasCancelled)
        do {
            _ = try await coordinator.poll(flowID: status.flowID, ownerID: "admin-a")
            XCTFail("cancelled transaction remained visible")
        } catch let error as ServiceAPIError { XCTAssertEqual(error.code, .notFound) }
    }
}

private actor RecordingCredentialTester: ProviderCredentialTesting {
    let result: ProviderCredentialTestResult
    init(result: ProviderCredentialTestResult) {
        self.result = result
    }

    func supportedAuthenticationMethods(for _: ProviderSettingsID) async -> Set<ProviderAuthenticationMethod> {
        [.apiKey]
    }

    func test(providerID _: ProviderSettingsID, method _: ProviderAuthenticationMethod, secret _: Data?) async -> ProviderCredentialTestResult {
        result
    }

    func logout(providerID _: ProviderSettingsID, method _: ProviderAuthenticationMethod) async {}
}

private actor EchoingCredentialTester: ProviderCredentialTesting {
    func supportedAuthenticationMethods(for _: ProviderSettingsID) async -> Set<ProviderAuthenticationMethod> {
        [.apiKey]
    }

    func test(providerID _: ProviderSettingsID, method _: ProviderAuthenticationMethod, secret: Data?) async -> ProviderCredentialTestResult {
        .init(state: .valid, detail: "Credential accepted", accountLabel: secret.flatMap { String(data: $0, encoding: .utf8) })
    }

    func logout(providerID _: ProviderSettingsID, method _: ProviderAuthenticationMethod) async {}
}

private actor RecordingCredentialHTTPTransport: ProviderCredentialHTTPTransport {
    private let statusCode: Int
    private var captured: [URLRequest] = []

    init(statusCode: Int) {
        self.statusCode = statusCode
    }

    func statusCode(for request: URLRequest, timeout _: Duration) async throws -> Int {
        captured.append(request)
        return statusCode
    }

    func requests() -> [URLRequest] {
        captured
    }
}

private actor StaticClaudeBackendSettings: ClaudeCompatibleBackendSettingsProviding {
    let configurations: [ProviderSettingsID: ClaudeCompatibleBackendSettings]

    init(configurations: [ProviderSettingsID: ClaudeCompatibleBackendSettings]) {
        self.configurations = configurations
    }

    func backendSettings(for providerID: ProviderSettingsID) async throws -> ClaudeCompatibleBackendSettings? {
        configurations[providerID]
    }
}

private struct FailingCredentialHTTPTransport: ProviderCredentialHTTPTransport {
    private struct SecretBearingError: Error, CustomStringConvertible {
        let description = "Authorization: Bearer sk-transport-secret"
    }

    func statusCode(for _: URLRequest, timeout _: Duration) async throws -> Int {
        throw SecretBearingError()
    }
}

private actor StaticVersionRunner: WorkspaceCommandRunning {
    func run(executable _: String, arguments: [String], workingDirectory _: String, maximumBytes _: Int) async throws -> String {
        response(for: arguments)
    }

    func run(executable _: String, arguments: [String], workingDirectory _: String, maximumBytes _: Int, environment: [String: String]) async throws -> String {
        if arguments == ["auth", "status", "--json"] {
            XCTAssertNotNil(environment["CLAUDE_CONFIG_DIR"])
            XCTAssertEqual(environment["ANTHROPIC_API_KEY"], "")
            XCTAssertEqual(environment["ANTHROPIC_AUTH_TOKEN"], "")
            XCTAssertEqual(environment["CLAUDE_CODE_OAUTH_TOKEN"], "")
        }
        return response(for: arguments)
    }

    private nonisolated func response(for arguments: [String]) -> String {
        arguments == ["auth", "status", "--json"]
            ? #"{"loggedIn":true,"email":"must-not-project@example.test","tokenSource":"must-not-project"}"#
            : "Swift version 6.2"
    }
}

private actor SlowVersionRunner: WorkspaceCommandRunning {
    private var versionProbeFinished = false
    private var completionWaiters: [CheckedContinuation<Void, Never>] = []

    func run(executable _: String, arguments: [String], workingDirectory _: String, maximumBytes _: Int) async throws -> String {
        try await response(for: arguments)
    }

    func run(executable _: String, arguments: [String], workingDirectory _: String, maximumBytes _: Int, environment _: [String: String]) async throws -> String {
        try await response(for: arguments)
    }

    func waitForVersionProbe() async {
        if versionProbeFinished { return }
        await withCheckedContinuation { continuation in
            completionWaiters.append(continuation)
        }
    }

    private func response(for arguments: [String]) async throws -> String {
        guard arguments == ["--version"] else { return "" }
        try await Task.sleep(for: .milliseconds(500))
        versionProbeFinished = true
        let waiters = completionWaiters
        completionWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return "Swift version 6.2"
    }
}

private actor UnauthenticatedClaudeRunner: WorkspaceCommandRunning {
    func run(executable _: String, arguments: [String], workingDirectory _: String, maximumBytes _: Int) async throws -> String {
        response(for: arguments)
    }

    func run(executable _: String, arguments: [String], workingDirectory _: String, maximumBytes _: Int, environment _: [String: String]) async throws -> String {
        response(for: arguments)
    }

    private nonisolated func response(for arguments: [String]) -> String {
        arguments == ["auth", "status", "--json"]
            ? #"{"loggedIn":false}"#
            : "Swift version 6.2"
    }
}

private actor CompletingManagedAuthDriver: ProviderAuthFlowDriving, ProviderManagedAuthenticationDriving {
    private var state: ProviderManagedAuthenticationState
    private var statuses: [UUID: ProviderManagedAuthenticationTransaction] = [:]
    private var logoutCalls = 0

    init(state: ProviderManagedAuthenticationState = .notAuthenticated) {
        self.state = state
    }

    func setAuthenticationState(_ state: ProviderManagedAuthenticationState) {
        self.state = state
    }

    func authFlowDescriptor(providerID: ProviderSettingsID, forceRefresh _: Bool) async -> ProviderManagedAuthenticationFlowCapability? {
        guard providerID == .codex else { return nil }
        return .init(kind: .deviceCodeBeta, displayName: "ChatGPT device authorization", startable: true, detail: "Authorize on another device")
    }

    func authenticationState(providerID: ProviderSettingsID) async -> ProviderManagedAuthenticationState {
        providerID == .codex ? state : .unavailable
    }

    func logout(providerID _: ProviderSettingsID) async throws {
        state = .notAuthenticated
        logoutCalls += 1
    }

    func start(providerID: ProviderSettingsID, kind: ProviderManagedAuthenticationFlowKind) async throws -> ProviderManagedAuthenticationTransaction {
        let status = ProviderManagedAuthenticationTransaction(
            flowID: UUID(),
            providerID: providerID,
            kind: kind,
            state: .pending,
            userCode: "ABCD-EFGH",
            verificationURL: URL(string: "https://auth.openai.com/codex/device"),
            expiresAt: Date().addingTimeInterval(300),
            detail: "Awaiting authorization"
        )
        statuses[status.flowID] = status
        return status
    }

    func poll(flowID: UUID) async throws -> ProviderManagedAuthenticationTransaction {
        guard let pending = statuses.removeValue(forKey: flowID) else {
            throw ServiceAPIError(code: .notFound, message: "missing")
        }
        state = .authenticated(accountLabel: "owner@example.com")
        return .init(
            flowID: flowID,
            providerID: pending.providerID,
            kind: pending.kind,
            state: .completed,
            expiresAt: pending.expiresAt,
            detail: "Completed"
        )
    }

    func cancel(flowID: UUID) async {
        statuses[flowID] = nil
    }

    func logoutCount() -> Int { logoutCalls }
}

private actor FakeAuthFlowDriver: ProviderAuthFlowDriving {
    private var statuses: [UUID: ProviderManagedAuthenticationTransaction] = [:]
    private var cancelled: Set<UUID> = []
    func start(providerID: ProviderSettingsID, kind: ProviderManagedAuthenticationFlowKind) async throws -> ProviderManagedAuthenticationTransaction {
        let status = ProviderManagedAuthenticationTransaction(flowID: UUID(), providerID: providerID, kind: kind, state: .pending, userCode: "ABCD-EFGH", verificationURL: URL(string: "https://example.test/device"), expiresAt: Date().addingTimeInterval(300), detail: "Awaiting authorization")
        statuses[status.flowID] = status
        return status
    }

    func poll(flowID: UUID) async throws -> ProviderManagedAuthenticationTransaction {
        guard let status = statuses[flowID] else { throw ServiceAPIError(code: .notFound, message: "missing") }
        return status
    }

    func cancel(flowID: UUID) async {
        statuses[flowID] = nil
        cancelled.insert(flowID)
    }

    func wasCancelled(_ flowID: UUID) -> Bool {
        cancelled.contains(flowID)
    }
}
