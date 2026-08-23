import Foundation
import Hummingbird
import HummingbirdTesting
@testable import RepoPromptAgentRuntimeCore
import RepoPromptHeadlessRuntime
@testable import RepoPromptServiceHTTP
@testable import RepoPromptServicePersistence
import RepoPromptServiceProtocol
import RepoPromptWorkspaceRuntimeCore
import XCTest

@testable import RepoPromptServerHost
@testable import RepoPromptServerExecutable
@testable import RepoPromptHeadlessRuntime
final class ProviderSettingsPortalTests: XCTestCase {
    func testProviderSettingsPersistenceIsRevisionedAndNonSecret() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }

        let initial = ProviderSettingsPreference(
            providerID: .codex,
            enabled: true,
            defaultModel: "gpt-5.6-sol",
            reasoningEffort: "high",
            serviceTier: "fast",
            revision: 1
        )
        _ = try await store.upsertProviderSettings(initial, expectedRevision: 0)
        let persisted = try await store.providerSettings()
        let metadata = try await store.metadata()
        XCTAssertEqual(persisted, [initial])
        XCTAssertEqual(metadata.schemaVersion, SchemaV9.version)

        do {
            _ = try await store.upsertProviderSettings(initial, expectedRevision: 0)
            XCTFail("expected stale revision")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .staleRevision)
        }
    }

    func testPortalDesktopSettingsAreVersionedValidatedAndAppliedToRuntimeDefaults() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let service = PortalDesktopSettingsService(store: store)

        let initial = try await service.snapshot()
        let operational = try await store.operationalSnapshot()
        XCTAssertTrue(operational.migrationsValid, "the latest persisted settings migration must keep server readiness healthy")
        XCTAssertEqual(initial.revision, 0)
        XCTAssertEqual(initial.values[PortalDesktopSettingKey.codexPermissionLevel.rawValue], "autoReview")
        XCTAssertEqual(initial.values[PortalDesktopSettingKey.claudeGLMBaseURL.rawValue], "https://api.z.ai/api/anthropic")
        XCTAssertEqual(initial.values[PortalDesktopSettingKey.claudeKimiBaseURL.rawValue], "https://api.kimi.com/coding/")
        XCTAssertNil(initial.values["appearanceMode"])

        let updated = try await service.update(.init(expectedRevision: 0, changes: [
            PortalDesktopSettingKey.codexGoalsEnabled.rawValue: "false",
            PortalDesktopSettingKey.claudeGLMSonnetModel.rawValue: "glm-4.7"
        ]))
        XCTAssertEqual(updated.revision, 1)
        do {
            _ = try await service.update(.init(expectedRevision: 1, changes: [
                PortalDesktopSettingKey.codexPermissionLevel.rawValue: "readOnly"
            ]))
            XCTFail("leftover permission keys must be read-only on the legacy authority")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .capabilityMissing)
        }
        let defaults = try await service.runtimeDefaults(for: .codex)
        XCTAssertEqual(defaults.mode, "workspaceWrite")
        XCTAssertEqual(defaults.providerSettings["codex.sandbox"], "workspace-write")
        XCTAssertEqual(defaults.providerSettings["codex.approvalPolicy"], "on-request")
        XCTAssertEqual(defaults.providerSettings["codex.approvalsReviewer"], "auto_review")
        XCTAssertEqual(defaults.providerSettings["codex.bashEnabled"], "true")
        XCTAssertEqual(defaults.providerSettings["codex.goalsEnabled"], "false")
        let glmDefaults = try await service.runtimeDefaults(for: .claudeGLM)
        XCTAssertEqual(glmDefaults.providerSettings["claude.backendID"], ProviderSettingsID.claudeGLM.rawValue)
        XCTAssertEqual(glmDefaults.providerSettings["claude.backendBaseURL"], "https://api.z.ai/api/anthropic")
        XCTAssertEqual(glmDefaults.providerSettings["claude.backendAuthHeader"], "anthropicAuthToken")
        XCTAssertEqual(glmDefaults.providerSettings["claude.backendSonnetModel"], "glm-4.7")
        let kimiSettings = try await service.backendSettings(for: .claudeKimi)
        let kimi = try XCTUnwrap(kimiSettings)
        XCTAssertEqual(kimi.modelBehavior, .noModel)
        XCTAssertEqual(kimi.authHeader, .anthropicAPIKey)
        let codexComposerProfile = try await service.composerCatalogProfile(for: .codex)
        XCTAssertEqual(codexComposerProfile.permissionControl?.selectedID, "codex.autoReview")
        XCTAssertFalse(codexComposerProfile.permissionControl?.choices.contains { $0.displayName == "Default" } == true)
        XCTAssertEqual(Self.booleanValue("codex.bash", in: codexComposerProfile.toolControls), true)
        XCTAssertEqual(Self.booleanValue("codex.goals", in: codexComposerProfile.toolControls), false)

        do {
            _ = try await service.update(.init(expectedRevision: 0, changes: [PortalDesktopSettingKey.codexGoalsEnabled.rawValue: "true"]))
            XCTFail("expected stale settings revision")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .staleRevision)
        }
        do {
            _ = try await service.update(.init(expectedRevision: 1, changes: [
                PortalDesktopSettingKey.contextBuilderBudget.rawValue: "120000"
            ]))
            XCTFail("superseded typed settings must be read-only on the legacy authority")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .capabilityMissing)
        }
        do {
            _ = try await service.update(.init(expectedRevision: 1, changes: ["appearanceMode": "dark"]))
            XCTFail("desktop-only settings must not enter the server contract")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .invalidRequest)
        }
        do {
            _ = try await service.update(.init(expectedRevision: 1, changes: [
                PortalDesktopSettingKey.claudeCustomBaseURL.rawValue: "http://unsafe.example"
            ]))
            XCTFail("compatible backend URLs must use credential-free HTTPS")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .invalidRequest)
        }
    }

    func testServerDefaultExecutionModeDoesNotReplaceTypedDirectAgentProfiles() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let service = PortalDesktopSettingsService(store: store)
        _ = try await service.update(.init(expectedRevision: 0, changes: [
            PortalDesktopSettingKey.serverDefaultExecutionMode.rawValue: "readOnly"
        ]))

        for providerID in [ProviderSettingsID.codex, .claudeCompatible, .openCodeACP, .cursorACP, .grokBuildACP] {
            let defaults = try await service.runtimeDefaults(for: providerID)
            XCTAssertEqual(defaults.mode, "workspaceWrite", providerID.rawValue)
            XCTAssertTrue(providerID.hasTypedDirectAgentProfile)
        }
        let codex = try await service.runtimeDefaults(for: .codex)
        XCTAssertEqual(codex.providerSettings["codex.sandbox"], "workspace-write")
        XCTAssertEqual(codex.providerSettings["codex.approvalsReviewer"], "auto_review")
        let api = try await service.runtimeDefaults(for: .openAIAPI)
        XCTAssertEqual(api.mode, "readOnly")
        XCTAssertFalse(ProviderSettingsID.openAIAPI.hasTypedDirectAgentProfile)
    }

    private static func booleanValue(_ id: String, in controls: [ProviderComposerControlDescriptor]) -> Bool? {
        for control in controls {
            if case let .toggle(controlID, _, _, value, _, _, _, _) = control, controlID == id {
                return value
            }
        }
        return nil
    }

    func testBrowserAuthenticationStatusContractHasNoSecretOrPathFields() throws {
        let status = ProviderAuthenticationStatus(
            state: .authenticated,
            authenticated: true,
            method: .browserOAuth,
            accountLabel: "team account",
            expiresAt: Date(timeIntervalSince1970: 2_000_000_000),
            detail: "Connected"
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder.serviceEncoder.encode(status)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["state", "authenticated", "method", "accountLabel", "expiresAt", "detail"])
        let keys = object.keys.joined(separator: " ").lowercased()
        for forbidden in ["secret", "token", "credential", "path", "helper", "raw"] {
            XCTAssertFalse(keys.contains(forbidden), "browser contract exposed forbidden key: \(forbidden)")
        }
    }

    func testRuntimeDefaultsPreserveExplicitSessionOverrides() {
        let request = ProviderExecutionRequest(
            kind: .codex,
            model: nil,
            prompt: "work",
            workingDirectory: "/tmp",
            runID: UUID(),
            policy: .init(providerSettings: ["provider.reasoningEffort": "ultra"])
        )
        let resolved = request.applying(defaults: .init(
            enabled: true,
            model: "gpt-5.6-sol",
            reasoningEffort: "medium",
            speedMode: "fast",
            serviceTier: "fast"
        ))
        XCTAssertEqual(resolved.model, "gpt-5.6-sol")
        XCTAssertEqual(resolved.policy.providerSettings["provider.reasoningEffort"], "ultra")
        XCTAssertEqual(resolved.policy.providerSettings["provider.speedMode"], "fast")
        XCTAssertEqual(resolved.policy.providerSettings["provider.serviceTier"], "fast")
    }

    func testProviderSettingsServicePublishesSanitizedHealthCatalogAndCapabilities() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let statusURL = directory.appendingPathComponent("status.json")
        try Data(#"{"authenticated":true,"method":"apiKey","accountLabel":"/run/secrets/provider-token","detail":"raw helper output"}"#.utf8).write(to: statusURL)
        let modelCatalogURL = directory.appendingPathComponent("codex-models.json")
        try JSONEncoder.serviceEncoder.encode([
            ProviderModelCatalogEntry(
                id: "gpt-5.6-sol",
                providerRawValue: "gpt-5.6-sol",
                displayName: "GPT-5.6 Sol",
                isProviderDefault: true,
                reasoningEfforts: ["low", "high"],
                defaultReasoningEffort: "high",
                supportsNativeImages: true,
                supportsSteering: true
            )
        ]).write(to: modelCatalogURL)

        let store = try await SQLiteServiceStore.open(storage: .memory)
        let configuration = ProviderCLIConfiguration(kind: .codex, executable: "/usr/bin/swift", protocolVersion: "app-server-v2")
        let adapter = ProviderCLIAdapter(configurations: [configuration], enabledProviders: [])
        let service = ProviderSettingsService(
            store: store,
            adapter: adapter,
            configurations: [configuration],
            initiallyEnabled: [],
            authenticationStatusFiles: [.codex: statusURL.path],
            modelCatalogFiles: [.codex: modelCatalogURL.path]
        )
        try await service.bootstrap()
        let catalog = try await service.catalog(refreshCLI: true)
        let codex = try XCTUnwrap(catalog.providers.first { $0.providerID == .codex })
        XCTAssertTrue(codex.cli?.installed == true)
        XCTAssertTrue(codex.cli?.healthy == true)
        XCTAssertTrue(codex.authentication.authenticated)
        XCTAssertNil(codex.authentication.accountLabel)
        XCTAssertEqual(codex.authentication.detail, "Authenticated")
        let encodedCatalog = try String(decoding: JSONEncoder.serviceEncoder.encode(catalog), as: UTF8.self)
        XCTAssertFalse(encodedCatalog.contains("/run/secrets"))
        XCTAssertFalse(encodedCatalog.contains("raw helper output"))
        XCTAssertEqual(codex.models.first?.id, "gpt-5.6-sol")
        XCTAssertTrue(codex.capabilities.supportsReasoningEffort)
        XCTAssertTrue(codex.capabilities.supportsServiceTier)
        XCTAssertFalse(codex.capabilities.supportsSpeedMode)
        XCTAssertTrue(codex.capabilities.authenticationMethods.isEmpty)
        XCTAssertTrue(codex.capabilities.authFlows.isEmpty)
        XCTAssertFalse(codex.deploymentAllowed)
        XCTAssertFalse(codex.runtimePreflightVerified)
        XCTAssertFalse(codex.effectiveEnabled)
        do {
            _ = try await service.update(providerID: .codex, request: .init(
                expectedRevision: codex.preference.revision,
                enabled: true,
                defaultModel: codex.preference.defaultModel,
                reasoningEffort: nil,
                speedMode: nil,
                serviceTier: nil
            ))
            XCTFail("deployment ceiling must reject enablement")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .capabilityMissing)
        }
        try await store.close()
    }

    func testPortalProviderContractAdvertisesEqualCodexMethodsWithoutCredentialMaterial() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let configuration = ProviderCLIConfiguration(kind: .codex, executable: "/usr/bin/swift")
        let service = ProviderSettingsService(
            store: store,
            adapter: ProviderCLIAdapter(configurations: [configuration], enabledProviders: [.codex], runner: StaticProviderVersionRunner(output: "Swift version 6.2")),
            configurations: [configuration],
            initiallyEnabled: [.codex],
            managedAuthentication: PortalManagedAuthentication(),
            vault: try ProviderCredentialVault(
                fileURL: directory.appendingPathComponent("vault"),
                activeKey: ProviderVaultKey(keyID: "test", material: Data(repeating: 8, count: 32))
            ),
            credentialTester: PortalAPIKeyTester(),
            runner: StaticProviderVersionRunner(output: "Swift version 6.2")
        )
        try await service.bootstrap()

        let catalog = try await service.catalog(refreshCLI: true, refreshRuntime: true)
        let codex = try XCTUnwrap(catalog.providers.first { $0.providerID == .codex })
        XCTAssertEqual(Set(codex.capabilities.authenticationMethods), [.deviceCodeBeta, .apiKey])
        XCTAssertEqual(codex.capabilities.authFlows.map(\.kind), [.deviceCodeBeta])
        XCTAssertEqual(codex.capabilities.authFlows.first?.startable, true)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder.serviceEncoder.encode(codex)) as? [String: Any])
        let encoded = String(describing: object).lowercased()
        XCTAssertFalse(encoded.contains("access_token"))
        XCTAssertFalse(encoded.contains("auth.json"))
        XCTAssertFalse(encoded.contains("usercode"), "catalog capability must not retain a transient device challenge")
    }

    func testPortalKeepsCodexDeviceAuthorizationVisibleWhileRuntimeProbeIsUnavailable() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let configuration = ProviderCLIConfiguration(kind: .codex, executable: "/usr/bin/swift")
        let service = ProviderSettingsService(
            store: store,
            adapter: ProviderCLIAdapter(configurations: [configuration], enabledProviders: [.codex], runner: StaticProviderVersionRunner(output: "Swift version 6.2")),
            configurations: [configuration],
            initiallyEnabled: [.codex],
            managedAuthentication: PortalManagedAuthentication(startable: false),
            runner: StaticProviderVersionRunner(output: "Swift version 6.2")
        )
        try await service.bootstrap()

        let initial = try await service.catalog()
        let initialCodex = try XCTUnwrap(initial.providers.first { $0.providerID == .codex })
        XCTAssertEqual(initialCodex.capabilities.authenticationMethods, [.deviceCodeBeta])
        XCTAssertEqual(initialCodex.capabilities.authFlows.map(\.kind), [.deviceCodeBeta])
        XCTAssertEqual(initialCodex.capabilities.authFlows.first?.startable, false)
        XCTAssertTrue(initialCodex.capabilities.authFlows.first?.detail?.contains("settings remain available") == true)

        let refreshed = try await service.catalog(refreshCLI: true)
        let refreshedCodex = try XCTUnwrap(refreshed.providers.first { $0.providerID == .codex })
        XCTAssertEqual(refreshedCodex.capabilities.authenticationMethods, [.deviceCodeBeta])
        XCTAssertEqual(refreshedCodex.capabilities.authFlows.map(\.kind), [.deviceCodeBeta])
        XCTAssertEqual(refreshedCodex.capabilities.authFlows.first?.startable, false)
        XCTAssertTrue(refreshedCodex.capabilities.authFlows.first?.detail?.contains("temporarily unavailable") == true)
    }

    func testPortalMutationProtectionRequiresSameOriginJSONAndCustomHeader() throws {
        XCTAssertNoThrow(try RepoPromptPortalRequestProtection.validateMutation(
            origin: "https://server.example:9443",
            expectedOrigin: "https://server.example:9443",
            fetchSite: "same-origin",
            contentType: "application/json; charset=utf-8",
            csrfHeader: "1"
        ))
        XCTAssertThrowsError(try RepoPromptPortalRequestProtection.validateMutation(
            origin: "https://attacker.example",
            expectedOrigin: "https://server.example:9443",
            fetchSite: "cross-site",
            contentType: "application/json",
            csrfHeader: "1"
        ))
        XCTAssertThrowsError(try RepoPromptPortalRequestProtection.validateMutation(
            origin: "https://server.example:9443",
            expectedOrigin: "https://server.example:9443",
            fetchSite: nil,
            contentType: "application/x-www-form-urlencoded",
            csrfHeader: nil
        ))
    }

    func testPortalBootstrapSerializesCanonicalMCPToolCatalogAndDecodesLegacyPayloads() throws {
        let expectedNames = [
            "app_settings", "bind_context", "manage_workspaces",
            "manage_selection", "file_actions", "get_code_structure", "get_file_tree", "read_file", "file_search",
            "workspace_context", "prompt", "apply_edits", "oracle_utils", "ask_oracle", "oracle_send",
            "oracle_chat_log", "git", "manage_worktree", "context_builder", "ask_user", "agent_explore",
            "agent_run", "agent_manage", "share_thoughts", "set_status", "wait_for_next_user_instruction", "history"
        ]
        let tools = RepoPromptPortalSessionProjection.tools()
        XCTAssertEqual(tools.map(\.name), expectedNames)
        XCTAssertEqual(Set(tools.map(\.name)).count, expectedNames.count)
        XCTAssertTrue(tools.allSatisfy {
            !$0.scope.isEmpty && !$0.capability.isEmpty && !$0.admissionClass.isEmpty
        })

        let response = PortalBootstrapResponse(projects: [], sessions: [], workflows: [], tools: tools)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder.serviceEncoder.encode(response)) as? [String: Any]
        )
        let serializedTools = try XCTUnwrap(object["tools"] as? [[String: Any]])
        XCTAssertEqual(serializedTools.compactMap { $0["name"] as? String }, expectedNames)
        XCTAssertTrue(serializedTools.allSatisfy {
            Set($0.keys) == ["name", "scope", "capability", "admissionClass"]
        })

        let legacy = try JSONDecoder.serviceDecoder.decode(
            PortalBootstrapResponse.self,
            from: Data(#"{"projects":[],"sessions":[],"workflows":[]}"#.utf8)
        )
        XCTAssertTrue(legacy.tools.isEmpty)
    }

    func testPortalAssetsPreserveDesktopHierarchyAndNeverPersistBrowserState() throws {
        let html = try String(decoding: RepoPromptPortalAssets.data(for: .index), as: UTF8.self)
        let css = try String(decoding: RepoPromptPortalAssets.data(for: .stylesheet), as: UTF8.self)
        let script = try String(decoding: RepoPromptPortalAssets.data(for: .script), as: UTF8.self)

        for term in ["Projects", "Sessions", "Ask RepoPrompt anything", "Models &amp; Providers", "Server Portal"] {
            XCTAssertTrue(html.contains(term), "missing portal term: \(term)")
        }
        for unavailablePlaceholder in ["Session creation arrives", "APIs do not exist yet", "Provider and model settings"] {
            XCTAssertFalse(html.contains(unavailablePlaceholder), "dead placeholder leaked into portal: \(unavailablePlaceholder)")
        }
        for token in ["--space-4: 4px", "--space-16: 16px", "--space-32: 32px", "ui-rounded", "ui-monospace"] {
            XCTAssertTrue(css.contains(token), "missing visual token: \(token)")
        }
        XCTAssertFalse(script.contains("localStorage"))
        XCTAssertFalse(script.contains("sessionStorage"))
        XCTAssertFalse(script.contains("console."))
        XCTAssertFalse(script.contains("style."), "strict CSP forbids inline style mutation")
        XCTAssertTrue(script.contains("flow.userCode"), "device challenge should be transiently renderable")
        XCTAssertTrue(html.contains("href=\"assets/portal.css\""))
        XCTAssertTrue(html.contains("src=\"assets/portal.js\""))
        XCTAssertFalse(html.contains("/portal/assets/"))
        XCTAssertTrue(script.contains("api(\"api/v1/bootstrap\")"))
        XCTAssertTrue(script.contains("api(\"api/v1/sessions\""))
        XCTAssertTrue(script.contains("/transcript?"))
        XCTAssertTrue(script.contains("/messages"))
        XCTAssertFalse(script.contains("api(\"/portal/"))
        XCTAssertEqual(try RepoPromptPortalAssets.response(for: .index).headers[.cacheControl], "private, no-store")
        XCTAssertEqual(try RepoPromptPortalAssets.response(for: .stylesheet).headers[.cacheControl], "private, max-age=3600")
        let redirect = RepoPromptPortalAssets.canonicalRedirect()
        XCTAssertEqual(redirect.status.code, 308)
        XCTAssertEqual(redirect.headers[.location], "/portal/")
        XCTAssertEqual(redirect.headers[.cacheControl], "private, no-store")
    }

    func testPortalSessionProjectionBoundsAndSanitizesTranscript() throws {
        let actor = ExternalActor(userID: "portal-user", username: "alice", displayName: "Alice")
        let sessionID = UUID()
        let transcript = [
            TranscriptEntry(
                entryID: UUID(),
                sessionSequence: 1,
                kind: .human,
                content: "  Build   the provider portal\nfaithfully  ",
                actor: actor,
                timestamp: Date(timeIntervalSince1970: 1),
                presentationPayload: Data("private-human-presentation".utf8)
            ),
            TranscriptEntry(
                entryID: UUID(),
                sessionSequence: 2,
                kind: .assistant,
                content: String(repeating: "x", count: RepoPromptPortalSessionProjection.maximumEntryBytes + 10),
                actor: actor,
                timestamp: Date(timeIntervalSince1970: 2),
                presentationPayload: Data("private-assistant-presentation".utf8)
            ),
        ]
        let session = SessionSnapshot(
            sessionID: sessionID,
            projectID: UUID(),
            parentSessionID: nil,
            rootSessionID: sessionID,
            creator: actor,
            provider: .codex,
            model: "gpt-5.6-sol",
            visibility: .privateSession,
            state: .idle,
            runGeneration: 1,
            turnEpoch: 1,
            revision: 3,
            transcript: transcript,
            interactions: [],
            cursor: ServiceCursor(storeID: UUID(), globalSequence: 2)
        )

        let page = try RepoPromptPortalSessionProjection.transcriptPage(
            session: session,
            limit: 2,
            beforeSequence: nil,
            afterSequence: nil
        )
        XCTAssertEqual(page.session.title, "Build the provider portal faithfully")
        XCTAssertEqual(page.items.map(\.sessionSequence), [1, 2])
        XCTAssertTrue(page.items[1].truncated)
        XCTAssertEqual(page.items[1].content.utf8.count, RepoPromptPortalSessionProjection.maximumEntryBytes)
        let encoded = try String(decoding: JSONEncoder.serviceEncoder.encode(page), as: UTF8.self)
        XCTAssertFalse(encoded.contains("portal-user"))
        XCTAssertFalse(encoded.contains("private-human-presentation"))
        XCTAssertFalse(encoded.contains("private-assistant-presentation"))
        XCTAssertTrue(encoded.contains("\"sessionId\""))
        XCTAssertTrue(encoded.contains("\"entryId\""))
        XCTAssertFalse(encoded.contains("\"sessionID\""))
        XCTAssertFalse(encoded.contains("\"entryID\""))
        XCTAssertFalse(encoded.contains("presentationPayload"))
        XCTAssertFalse(encoded.contains("actor"))
    }

    func testPortalFollowupContractOnlyMapsTextAndExpectedRevision() throws {
        let request = PortalSendMessageRequest(operationID: UUID(), expectedRevision: 9, text: "  keep both auth methods  ")
        let command = try RepoPromptPortalSessionProjection.validatedSendCommand(request)
        guard case let .sendFollowup(text, expectedSessionRevision) = command else {
            return XCTFail("portal request mapped to a broader session command")
        }
        XCTAssertEqual(text, "keep both auth methods")
        XCTAssertEqual(expectedSessionRevision, 9)
    }

    func testPortalRejectsRequestsWithoutAuthorizedCertificate() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let authority = RepoPromptHeadlessAuthority(store: store)
        let service = RepoPromptHTTPService(
            authority: authority,
            store: store,
            authenticator: InternalRequestAuthenticator(keys: [], store: store),
            eventSigningKey: InternalSigningKey(keyID: "response", role: .sync, direction: "test", secret: Data("secret".utf8))
        , mutationGate: AuthorityMutationGate()
        )
        let app = Application(router: service.internalRouter())
        try await app.test(.router) { client in
            try await client.execute(uri: "/portal", method: .get) { response in
                XCTAssertEqual(response.status.code, 308)
                XCTAssertEqual(response.headers[.location], "/portal/")
            }
            try await client.execute(uri: "/portal/", method: .get) { response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(response.headers[.cacheControl], "private, no-store")
            }
            try await client.execute(uri: "/portal/api/v1/bootstrap", method: .get) { response in
                XCTAssertEqual(response.status, .unauthorized)
                XCTAssertNil(response.headers[.init("x-internal-signature")!])
            }
        }
        try await store.close()
    }

    func testPortalCertificateRolesAllowOperatorAndAppProxyOnly() {
        XCTAssertTrue(RepoPromptPortalCertificateAuthorization.allows(.operatorRole))
        XCTAssertTrue(RepoPromptPortalCertificateAuthorization.allows(.app))
        XCTAssertFalse(RepoPromptPortalCertificateAuthorization.allows(.sync))
    }

    func testCLIHealthNeverProjectsRawVersionProbeOutput() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let configuration = ProviderCLIConfiguration(
            kind: .codex,
            executable: "/usr/bin/swift",
            expectedVersion: "9.9.9",
            protocolVersion: "app-server-v2"
        )
        let adapter = ProviderCLIAdapter(configurations: [configuration], enabledProviders: [])
        let service = ProviderSettingsService(
            store: store,
            adapter: adapter,
            configurations: [configuration],
            initiallyEnabled: [],
            runner: StaticProviderVersionRunner(output: "tool 9.9.9 /run/secrets/raw-token")
        )
        try await service.bootstrap()
        let catalog = try await service.catalog(refreshCLI: true)
        let codex = try XCTUnwrap(catalog.providers.first { $0.providerID == .codex })
        XCTAssertTrue(codex.cli?.healthy == true)
        XCTAssertEqual(codex.cli?.version, "9.9.9")
        let encoded = try String(decoding: JSONEncoder.serviceEncoder.encode(catalog), as: UTF8.self)
        XCTAssertFalse(encoded.contains("/run/secrets"))
        XCTAssertFalse(encoded.contains("raw-token"))
        try await store.close()
    }
}

private struct PortalManagedAuthentication: ProviderManagedAuthenticationDriving {
    let startable: Bool

    init(startable: Bool = true) {
        self.startable = startable
    }

    func authFlowDescriptor(providerID: ProviderSettingsID, forceRefresh _: Bool) async -> ProviderManagedAuthenticationFlowCapability? {
        guard providerID == .codex else { return nil }
        return .init(
            kind: .deviceCodeBeta,
            displayName: "ChatGPT device authorization",
            startable: startable,
            detail: startable
                ? "Authorize the server on another device"
                : "Device authorization is temporarily unavailable while RepoPrompt checks the Codex runtime."
        )
    }

    func authenticationState(providerID _: ProviderSettingsID) async -> ProviderManagedAuthenticationState {
        .notAuthenticated
    }

    func logout(providerID _: ProviderSettingsID) async throws {}
}

private struct PortalAPIKeyTester: ProviderCredentialTesting {
    func supportedAuthenticationMethods(for providerID: ProviderSettingsID) async -> Set<ProviderAuthenticationMethod> {
        providerID == .codex ? [.apiKey] : []
    }

    func test(providerID _: ProviderSettingsID, method _: ProviderAuthenticationMethod, secret _: Data?) async -> ProviderCredentialTestResult {
        .init(state: .valid, detail: "Validated")
    }

    func logout(providerID _: ProviderSettingsID, method _: ProviderAuthenticationMethod) async {}
}

private actor StaticProviderVersionRunner: WorkspaceCommandRunning {
    let output: String

    init(output: String) {
        self.output = output
    }

    func run(executable _: String, arguments _: [String], workingDirectory _: String, maximumBytes _: Int) async throws -> String {
        output
    }
}
