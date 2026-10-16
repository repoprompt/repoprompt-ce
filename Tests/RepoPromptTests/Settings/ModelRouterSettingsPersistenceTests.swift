import Foundation
@testable import RepoPromptApp
import RepoPromptProviderQuota
import RepoPromptSecureStorage
import RepoPromptSettingsCore
import XCTest

@MainActor
final class ModelRouterSettingsPersistenceTests: XCTestCase {
    func testRouterContentRequiresSchemaV9AndRoundTripsUnknownRaws() throws {
        let router = GlobalScalarPreferences.ModelRouterSettings(
            enabled: true,
            selectedBackendRawValue: "future-router",
            candidateRoleRawValues: ["explore", "future-role"],
            allowedProviderRawValues: ["codexExec", "future-provider"]
        )
        let document = GlobalSettingsDocument(scalarPreferences: GlobalScalarPreferences(modelRouter: router))
        XCTAssertEqual(document.requiredSchemaVersion, GlobalSettingsDocument.modelRouterSchemaVersion)
        let decoded = try JSONDecoder().decode(GlobalSettingsDocument.self, from: JSONEncoder().encode(document))
        XCTAssertEqual(decoded.scalarPreferences?.modelRouter, router)
    }

    func testScopedProviderPolicyAndGuidanceRequireSchemaV10AndRoundTrip() throws {
        let router = GlobalScalarPreferences.ModelRouterSettings(
            enabled: true,
            selectedBackendRawValue: "jev",
            candidateRoleRawValues: ["explore", "engineer"],
            allowedProviderRawValues: ["codexExec", "claudeCode"],
            primaryProviderRawValue: "codexExec",
            subagentProviderRawValue: "claudeCode",
            customInstructions: "Prefer Claude Opus for execution."
        )
        let document = GlobalSettingsDocument(scalarPreferences: GlobalScalarPreferences(modelRouter: router))
        XCTAssertEqual(document.requiredSchemaVersion, GlobalSettingsDocument.scopedModelRouterSchemaVersion)
        let decoded = try JSONDecoder().decode(GlobalSettingsDocument.self, from: JSONEncoder().encode(document))
        XCTAssertEqual(decoded.scalarPreferences?.modelRouter, router)
    }

    func testStoreWritesV9AndPreservesUnknownSiblingsDuringKnownEdits() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileStore = GlobalSettingsFileStore(fileURL: root.appendingPathComponent("globalSettings.json"))
        var document = GlobalSettingsDocument()
        document.scalarPreferences = GlobalScalarPreferences(modelRouter: .init(
            enabled: false,
            selectedBackendRawValue: "jev",
            candidateRoleRawValues: ["explore", "future-role"],
            allowedProviderRawValues: ["codexExec", "future-provider"]
        ))
        try fileStore.save(document)

        var rawRoot = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: fileStore.fileURL)) as? [String: Any])
        var scalarPreferences = try XCTUnwrap(rawRoot["scalarPreferences"] as? [String: Any])
        var rawRouter = try XCTUnwrap(scalarPreferences["modelRouter"] as? [String: Any])
        rawRouter["futurePolicy"] = ["mode": "strict"]
        scalarPreferences["modelRouter"] = rawRouter
        rawRoot["scalarPreferences"] = scalarPreferences
        try JSONSerialization.data(withJSONObject: rawRoot, options: [.prettyPrinted, .sortedKeys])
            .write(to: fileStore.fileURL, options: .atomic)
        XCTAssertThrowsError(try FrozenV130GlobalSettingsDocument.load(from: fileStore.fileURL)) { error in
            XCTAssertEqual(
                error as? FrozenV130GlobalSettingsDocument.CompatibilityError,
                .unsupportedFutureSchema(GlobalSettingsDocument.modelRouterSchemaVersion)
            )
        }

        let suite = "ModelRouterSettingsPersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)
        store.setModelRouterCandidateRoles([.explore, .engineer])
        store.setModelRouterAllowedProviders([.codexExec, .claudeCode])

        let loaded = try fileStore.load()
        XCTAssertEqual(loaded.schemaVersion, 9)
        XCTAssertEqual(loaded.scalarPreferences?.modelRouter?.candidateRoleRawValues, ["explore", "engineer", "future-role"])
        XCTAssertEqual(loaded.scalarPreferences?.modelRouter?.allowedProviderRawValues, ["claudeCode", "codexExec", "future-provider"])
        let savedRoot = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: fileStore.fileURL)) as? [String: Any])
        let savedRouter = ((savedRoot["scalarPreferences"] as? [String: Any])?["modelRouter"] as? [String: Any])
        XCTAssertEqual((savedRouter?["futurePolicy"] as? [String: Any])?["mode"] as? String, "strict")
    }

    func testRouterPolicySettersAndFirstEnablePreserveUnknownRawOrder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileStore = GlobalSettingsFileStore(fileURL: root.appendingPathComponent("globalSettings.json"))
        try fileStore.save(GlobalSettingsDocument(scalarPreferences: .init(modelRouter: .init(
            enabled: false,
            selectedBackendRawValue: "jev",
            candidateRoleRawValues: ["design", "future-role", "", "future-role", " Future Role "],
            allowedProviderRawValues: ["cursor", "future-provider", " ", "future-provider", " Future Provider "]
        ))))
        let suite = "ModelRouter.raw-order.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)

        store.setModelRouterCandidateRoles([.engineer, .explore])
        store.setModelRouterAllowedProviders([.codexExec, .claudeCode])
        var raw = try XCTUnwrap(try fileStore.load().scalarPreferences?.modelRouter)
        XCTAssertEqual(raw.candidateRoleRawValues, ["explore", "engineer", "future-role", "future-role", " Future Role "])
        XCTAssertEqual(raw.allowedProviderRawValues, ["claudeCode", "codexExec", "future-provider", "future-provider", " Future Provider "])

        store.enableModelRouterWithCurrentPolicy(
            backendID: .jev,
            roles: [.design, .pair],
            providers: [.cursor, .openCode]
        )
        raw = try XCTUnwrap(try fileStore.load().scalarPreferences?.modelRouter)
        XCTAssertEqual(raw.candidateRoleRawValues, ["pair", "design", "future-role", "future-role", " Future Role "])
        XCTAssertEqual(raw.allowedProviderRawValues, ["openCode", "cursor", "future-provider", "future-provider", " Future Provider "])
    }

    func testDecisionsAndFutureBackendRawRoundTripWithoutSchemaChangeOrSecret() throws {
        for raw in ["openai-decisions", "future-router", "  "] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let file = GlobalSettingsFileStore(fileURL: root.appendingPathComponent("settings.json"))
            try file.save(GlobalSettingsDocument(scalarPreferences: .init(modelRouter: .init(enabled: true, selectedBackendRawValue: raw))))
            let suite = "RouterRaw.\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = GlobalSettingsStore(defaults: defaults, fileStore: file)
            store.setModelRouterCustomInstructions("Prefer reliable choices")
            let reloaded = try file.load()
            XCTAssertEqual(reloaded.scalarPreferences?.modelRouter?.selectedBackendRawValue, raw)
            XCTAssertEqual(reloaded.schemaVersion, 10)
            let json = try String(contentsOf: file.fileURL, encoding: .utf8)
            XCTAssertFalse(json.contains("APIKey"))
            XCTAssertFalse(json.contains("Bearer"))
        }
    }

    func testKnownEditsPreserveNilBlankKnownAndUnknownBackendRawValues() throws {
        for raw in [nil, "", "  ", "jev", "openai-decisions", " future-router ", "Future-Router"] as [String?] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let file = GlobalSettingsFileStore(fileURL: root.appendingPathComponent("settings.json"))
            try file.save(GlobalSettingsDocument(
                scalarPreferences: .init(
                    modelRouter: .init(enabled: false, selectedBackendRawValue: raw)
                )
            ))
            let suite = "RouterRawPreservation.\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = GlobalSettingsStore(defaults: defaults, fileStore: file)

            store.setModelRouterCustomInstructions("Preserve exact selection")
            store.setAutoEffortEnabled(true)

            let configuration = store.modelRouterConfiguration()
            XCTAssertEqual(configuration.selectedBackendRawValue, raw)
            XCTAssertEqual(configuration.selectedBackendID, raw.flatMap { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : DecisionServiceID(rawValue: trimmed)
            })
            XCTAssertEqual(
                try file.load().scalarPreferences?.modelRouter?.selectedBackendRawValue,
                raw
            )
        }
    }

    func testBlockedFutureSchemaDoesNotMaterializeLegacyRouterDefault() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = GlobalSettingsFileStore(fileURL: root.appendingPathComponent("settings.json"))
        var document = GlobalSettingsDocument(scalarPreferences: .init(modelRouter: .init(enabled: true, selectedBackendRawValue: "future-router")))
        document.schemaVersion = GlobalSettingsDocument.currentSchemaVersion + 1
        let original = try JSONEncoder().encode(document)
        try original.write(to: file.fileURL, options: .atomic)
        let suite = "RouterBlocked.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = GlobalSettingsStore(defaults: defaults, fileStore: file)
        XCTAssertNotNil(store.persistenceBlockReason)

        let runtime = AgentTaskRouterRuntime(secureKeys: SecureKeysService(secureStorage: TestSecureStorageBackend()), settingsStore: store)
        await runtime.reconcileDemand()
        XCTAssertNil(store.routerDemandSnapshot().selectedBackendRawValue)
        XCTAssertFalse(store.routerDemandSnapshot().routerEnabled)
        XCTAssertEqual(try Data(contentsOf: file.fileURL), original)
        await runtime.teardown()
    }

    func testMissingRouterGroupRemainsBaselineSchema() {
        XCTAssertEqual(GlobalSettingsDocument().requiredSchemaVersion, GlobalSettingsDocument.baselineSchemaVersion)
    }

    func testFirstEnableMaterializesAllOnlyFromUnmaterializedPolicy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileStore = GlobalSettingsFileStore(fileURL: root.appendingPathComponent("globalSettings.json"))
        var document = GlobalSettingsDocument()
        document.scalarPreferences = GlobalScalarPreferences(modelRouter: .init(
            enabled: false,
            selectedBackendRawValue: "jev",
            candidateRoleRawValues: nil,
            allowedProviderRawValues: nil
        ))
        try fileStore.save(document)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ModelRouter.first-enable.\(UUID())"))
        let store = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)
        store.enableModelRouterWithCurrentPolicy(
            backendID: .jev,
            roles: Set(AgentModelCatalog.TaskLabelKind.allCases),
            providers: [.codexExec, .claudeCode]
        )
        let raw = try XCTUnwrap(try fileStore.load().scalarPreferences?.modelRouter)
        XCTAssertEqual(Set(raw.candidateRoleRawValues ?? []), Set(AgentModelCatalog.TaskLabelKind.allCases.map(\.rawValue)))
        XCTAssertEqual(Set(raw.allowedProviderRawValues ?? []), ["codexExec", "claudeCode"])
    }

    func testExplicitEmptyConsentSurvivesReloadAndVMDoesNotDefaultItToAll() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileStore = GlobalSettingsFileStore(fileURL: root.appendingPathComponent("globalSettings.json"))
        var document = GlobalSettingsDocument()
        document.scalarPreferences = GlobalScalarPreferences(modelRouter: .init(
            enabled: false,
            selectedBackendRawValue: "jev",
            candidateRoleRawValues: ["explore", "future-role"],
            allowedProviderRawValues: ["codexExec", "future-provider"]
        ))
        try fileStore.save(document)
        let suite = "ModelRouter.explicit-empty.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)
        store.setModelRouterCandidateRoles([])
        store.setModelRouterAllowedProviders([])

        let raw = try XCTUnwrap(try fileStore.load().scalarPreferences?.modelRouter)
        XCTAssertEqual(raw.candidateRoleRawValues, ["future-role"])
        XCTAssertEqual(raw.allowedProviderRawValues, ["future-provider"])

        let reloaded = try GlobalSettingsStore(
            defaults: XCTUnwrap(UserDefaults(suiteName: "\(suite).reload")),
            fileStore: fileStore
        ).modelRouterConfiguration()
        XCTAssertTrue(reloaded.candidateRolesMaterialized)
        XCTAssertTrue(reloaded.allowedProvidersMaterialized)
        XCTAssertTrue(reloaded.candidateRoles.isEmpty)
        XCTAssertTrue(reloaded.allowedProviders.isEmpty)
        XCTAssertTrue(RouterSettingsViewModel.effectiveRoles(reloaded).isEmpty)
        XCTAssertTrue(RouterSettingsViewModel.effectiveProviders(reloaded, available: [.codexExec]).isEmpty)
        XCTAssertEqual(reloaded.unknownRoleRawValues, ["future-role"])
        XCTAssertEqual(reloaded.unknownProviderRawValues, ["future-provider"])
    }

    func testNilConsentUsesFirstUseDefaultsWithoutMutatingStorage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try GlobalSettingsStore(
            defaults: XCTUnwrap(UserDefaults(suiteName: "ModelRouter.nil-consent.\(UUID())")),
            fileStore: GlobalSettingsFileStore(fileURL: root.appendingPathComponent("globalSettings.json"))
        )
        store.setModelRouterBackend(.jev)
        let configuration = store.modelRouterConfiguration()
        XCTAssertFalse(configuration.candidateRolesMaterialized)
        XCTAssertFalse(configuration.allowedProvidersMaterialized)
        XCTAssertEqual(RouterSettingsViewModel.effectiveRoles(configuration), Set(AgentModelCatalog.TaskLabelKind.allCases))
        XCTAssertEqual(
            RouterSettingsViewModel.effectiveProviders(configuration, available: [.codexExec, .claudeCode]),
            [.codexExec, .claudeCode]
        )
    }

    func testMaterializedProviderPolicyDoesNotAutoAuthorizeNewProvider() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "ModelRouter.new-provider.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(fileURL: root.appendingPathComponent("globalSettings.json"))
        )
        store.enableModelRouterWithCurrentPolicy(
            backendID: .jev,
            roles: [.explore, .engineer],
            providers: [.codexExec]
        )
        XCTAssertEqual(store.modelRouterConfiguration().allowedProviders, [.codexExec])
        XCTAssertFalse(store.modelRouterConfiguration().allowedProviders.contains(.claudeCode))
    }

    func testDefaultsPersistenceAndBackgroundConsentDoNotChangeRoutingRevision() throws {
        try withUsageStore { store, file in
            XCTAssertFalse(store.modelRouterConfiguration().usageBalancing.enabled)
            XCTAssertEqual(store.modelRouterConfiguration().usageBalancing.preset, .evenPace)
            XCTAssertFalse(store.modelRouterConfiguration().allowPaidFastRouting)
            store.setUsageBalancingEnabled(true)
            store.setUsageBalancingPreset(.expiringQuota)
            store.setAllowPaidFastRouting(true)
            let revision = store.modelRouterSettingsRevision
            let grant = ClaudeCLIUsageGrant(credentialProfileID: "fixture", grantedAt: Date(timeIntervalSince1970: 2_000_000_000))
            store.setClaudeBalancingRefreshGrant(grant)
            XCTAssertEqual(store.modelRouterSettingsRevision, revision, "Acquisition consent is not routing policy")
            let saved = try file.load()
            XCTAssertEqual(saved.scalarPreferences?.modelRouter?.usageBalancingPreset, "expiringQuota")
            XCTAssertEqual(saved.scalarPreferences?.modelRouter?.allowPaidFastRouting, true)
            for (old, current) in [("qualityFirst", AgentUsageBalancingPreset.nearLimits), ("balanced", .evenPace), ("favorLargerPlan", .expiringQuota)] {
                store.updateModelRouterScalar(commit: false) { $0.usageBalancingPreset = old }
                XCTAssertEqual(store.modelRouterConfiguration().usageBalancing.preset, current)
            }
            XCTAssertEqual(saved.scalarPreferences?.agentMode?.claudeBalancingRefreshGrant, grant)
            store.updateModelRouterScalar(commit: false) { $0.usageBalancingPreset = "future-policy" }
            XCTAssertFalse(store.modelRouterConfiguration().usageBalancing.enabled, "Unknown policies fail closed without discarding their raw values")
        }
    }

    func testOldGrantCompatibilityAndDeferredSetupAreExplicit() throws {
        let old = try JSONDecoder().decode(ClaudeCLIUsageGrant.self, from: Data(#"{"credentialProfileID":"fixture","grantedAt":0,"consentVersion":1}"#.utf8))
        XCTAssertTrue(old.isReady)
        let pending = ClaudeCLIUsageGrant(credentialProfileID: "fixture", grantedAt: Date(), setupCompleted: false)
        XCTAssertFalse(pending.isReady)
        let decoded = try JSONDecoder().decode(ClaudeCLIUsageGrant.self, from: JSONEncoder().encode(pending))
        XCTAssertFalse(decoded.isReady, "Pending setup must not become ready on reboot")
    }

    func testRoutingLeasesAreDefaultOffAndRespectSetupAndProfileConsent() throws {
        try withUsageStore { store, file in
            let codex = CodexProviderQuotaService(clientFactory: { UsageNoIOClient() }, accountIDProvider: { nil })
            let claude = ProviderAccountQuotaService(periodicReads: false, read: { _ in throw ProviderQuotaReadError.needsConsent })
            let advisor = AgentUsageBalancer()
            var currentProfile = "fixture"
            let owner = ProviderUsageRoutingObservation(settings: store, codex: codex, claude: claude, advisor: advisor, accountID: { nil }, profileProvider: { currentProfile }, isAppActive: { false }, budgetURL: file.fileURL.deletingLastPathComponent().appendingPathComponent("budget.json"))
            XCTAssertFalse(owner.hasObserverDemand)
            XCTAssertFalse(store.modelRouterConfiguration().enabled)
            store.setUsageBalancingEnabled(true)
            XCTAssertTrue(store.setModelRouterCustomInstructions("Prefer Claude for execution"))
            store.setClaudeCLIUsageGrant(.init(credentialProfileID: "fixture", grantedAt: Date(), setupCompleted: false), commit: false)
            advisor.onRoutingActivity?()
            XCTAssertFalse(owner.hasObserverDemand, "Grant alone cannot bypass deferred trust/setup")
            store.setClaudeCLIUsageGrant(.init(credentialProfileID: "fixture", grantedAt: Date()), commit: false)
            advisor.onRoutingActivity?()
            XCTAssertTrue(owner.hasObserverDemand)
            currentProfile = "different-profile"
            advisor.onRoutingActivity?()
            XCTAssertFalse(owner.hasObserverDemand)
            currentProfile = "fixture"
            advisor.onRoutingActivity?()
            XCTAssertTrue(owner.hasObserverDemand)
            store.setClaudeCLIUsageGrant(nil, commit: false)
            advisor.onRoutingActivity?()
            XCTAssertFalse(owner.hasObserverDemand, "Revocation is independent of presentation visibility")
            withExtendedLifetime(owner) {}
        }
    }

    private func withUsageStore(_ body: (GlobalSettingsStore, GlobalSettingsFileStore) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "ModelRouterSettingsPersistenceTests.usage.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let file = GlobalSettingsFileStore(fileURL: root.appendingPathComponent("settings.json"))
        let store = GlobalSettingsStore(defaults: defaults, fileStore: file)
        try body(store, file)
    }

    private actor UsageNoIOClient: CodexQuotaAppServerClient {
        func startIfNeeded() throws {
            XCTFail("Default-off observer must never start a provider")
        }

        func subscribeNotifications() -> AsyncStream<CodexQuotaNotification> {
            AsyncStream { $0.finish() }
        }

        func request(method _: String, params _: [String: CodexJSONValue]?, timeout _: TimeInterval?) throws -> [String: CodexJSONValue] {
            throw ProviderQuotaReadError.transport
        }

        func stop() {}
    }
}
