import Combine
import Foundation
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

@MainActor
final class SettingsJSONOnlyPersistenceTests: XCTestCase {
    func testDefaultGlobalSettingsPathUsesCESupportRoot() {
        let path = GlobalSettingsFileStore.defaultFileURL().path
        XCTAssertTrue(path.contains("/Application Support/RepoPrompt CE/Settings/globalSettings.json"), path)
        XCTAssertFalse(path.contains("/Application Support/RepoPrompt/Settings/globalSettings.json"), path)
    }

    func testMissingGlobalSettingsCreatesCurrentDefaultsAndIgnoresObsoleteDefaults() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let suiteName = "SettingsJSONOnlyPersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: obsoleteGitignorePreferenceKey)

        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        let fileStore = GlobalSettingsFileStore(fileURL: fileURL)
        let store = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertTrue(store.respectRepoIgnore())
        XCTAssertTrue(store.respectCursorignore())
        XCTAssertTrue(store.skipSymlinks())
    }

    func testNewWorkspaceDoesNotSeedLegacyContextBuilderSelection() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let store = try makeStore(at: temp.appendingPathComponent("Settings/globalSettings.json"))
        store.setGlobalContextBuilderAgentSelection(
            agentRaw: AgentProviderKind.codexExec.rawValue,
            modelRaw: AgentModel.gpt55CodexLow.rawValue,
            markUserDefined: true
        )

        let result = store.chatSettingsResult(for: UUID())

        XCTAssertTrue(result.isNew)
        XCTAssertNil(result.settings.lastUsedDiscoverAgentRaw)
        XCTAssertNil(result.settings.lastUsedDiscoverModelsByAgent)
        XCTAssertNil(result.settings.contextBuilderAgentRaw)
        XCTAssertNil(result.settings.contextBuilderAgentModelRaw)
        XCTAssertNil(result.settings.didUserSetDiscoverAgentDefaults)
        XCTAssertNil(result.settings.didUserSetContextBuilderDefaults)
        XCTAssertNil(result.settings.didAutoApplyRecommendationsAt)
    }

    func testLegacyWorkspaceContextBuilderSelectionDecodesWithoutBeingReemittedOrOverridingGlobalSelection() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        let fileStore = GlobalSettingsFileStore(fileURL: fileURL)

        let workspaceID = UUID()
        var legacySettings = ChatGlobalSettings(
            workspaceID: workspaceID,
            lastUsedDiscoverAgentRaw: AgentProviderKind.claudeCode.rawValue,
            lastUsedDiscoverModelsByAgent: [
                AgentProviderKind.claudeCode.rawValue: AgentModel.claudeSonnet.rawValue
            ],
            contextBuilderAgentRaw: AgentProviderKind.claudeCode.rawValue,
            contextBuilderAgentModelRaw: AgentModel.claudeSonnet.rawValue
        )
        legacySettings.didUserSetDiscoverAgentDefaults = true
        legacySettings.didUserSetContextBuilderDefaults = true
        legacySettings.didAutoApplyRecommendationsAt = Date(timeIntervalSince1970: 1)
        try fileStore.save(GlobalSettingsDocument(
            chatSettings: [workspaceID: legacySettings],
            globalDefaults: GlobalDefaults(
                discoverAgentRaw: AgentProviderKind.codexExec.rawValue,
                discoverModelsByAgent: [
                    AgentProviderKind.codexExec.rawValue: AgentModel.gpt55CodexLow.rawValue
                ],
                contextBuilderAgentRaw: AgentProviderKind.claudeCode.rawValue,
                didUserSetDiscoverAgentDefaults: true
            )
        ))

        let reloaded = try makeStore(at: fileURL)
        let decodedLegacySettings = reloaded.chatSettings(for: workspaceID)
        let globalSelection = reloaded.persistedGlobalContextBuilderAgentSelection()

        XCTAssertNil(decodedLegacySettings.lastUsedDiscoverAgentRaw)
        XCTAssertNil(decodedLegacySettings.lastUsedDiscoverModelsByAgent)
        XCTAssertNil(decodedLegacySettings.contextBuilderAgentRaw)
        XCTAssertNil(decodedLegacySettings.contextBuilderAgentModelRaw)
        XCTAssertNil(decodedLegacySettings.didUserSetDiscoverAgentDefaults)
        XCTAssertNil(decodedLegacySettings.didUserSetContextBuilderDefaults)
        XCTAssertNil(decodedLegacySettings.didAutoApplyRecommendationsAt)
        XCTAssertEqual(globalSelection.agentRaw, AgentProviderKind.codexExec.rawValue)
        XCTAssertEqual(globalSelection.modelRaw, AgentModel.gpt55CodexLow.rawValue)

        reloaded.setGlobalRecommendationProviderFilter([.codex])
        let rewritten = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertFalse(rewritten.contains("lastUsedDiscoverAgentRaw"))
        XCTAssertFalse(rewritten.contains("lastUsedDiscoverModelsByAgent"))
        XCTAssertFalse(rewritten.contains("contextBuilderAgentRaw"))
        XCTAssertFalse(rewritten.contains("contextBuilderAgentModelRaw"))
        XCTAssertFalse(rewritten.contains("didUserSetContextBuilderDefaults"))
        XCTAssertFalse(rewritten.contains("didAutoApplyRecommendationsAt"))
    }

    func testLegacyOnlyWorkspaceContextBuilderSelectionMigratesBeforeFieldsAreStripped() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        let fileStore = GlobalSettingsFileStore(fileURL: fileURL)

        let workspaceID = UUID()
        let legacySettings = ChatGlobalSettings(
            workspaceID: workspaceID,
            contextBuilderAgentRaw: AgentProviderKind.codexExec.rawValue,
            contextBuilderAgentModelRaw: AgentModel.gpt55CodexLow.rawValue
        )
        try fileStore.save(GlobalSettingsDocument(
            chatSettings: [workspaceID: legacySettings],
            globalDefaults: GlobalDefaults(discoverAgentRaw: nil, discoverModelsByAgent: nil)
        ))

        let reloaded = try makeStore(at: fileURL)
        let migratedSelection = reloaded.persistedGlobalContextBuilderAgentSelection()
        let strippedWorkspaceSettings = reloaded.chatSettings(for: workspaceID)

        XCTAssertEqual(migratedSelection.agentRaw, AgentProviderKind.codexExec.rawValue)
        XCTAssertEqual(migratedSelection.modelRaw, AgentModel.gpt55CodexLow.rawValue)
        XCTAssertNil(strippedWorkspaceSettings.contextBuilderAgentRaw)
        XCTAssertNil(strippedWorkspaceSettings.contextBuilderAgentModelRaw)

        reloaded.setGlobalRecommendationProviderFilter([.codex])
        let persisted = try fileStore.load()
        XCTAssertEqual(persisted.globalDefaults.discoverAgentRaw, AgentProviderKind.codexExec.rawValue)
        XCTAssertEqual(
            persisted.globalDefaults.discoverModelsByAgent?[AgentProviderKind.codexExec.rawValue],
            AgentModel.gpt55CodexLow.rawValue
        )
        XCTAssertNil(persisted.globalDefaults.contextBuilderAgentRaw)
        XCTAssertNil(persisted.chatSettings[workspaceID]?.contextBuilderAgentRaw)
        XCTAssertNil(persisted.chatSettings[workspaceID]?.contextBuilderAgentModelRaw)
    }

    func testTelemetrySettingsDefaultPersistAndMirrorMasterOptOut() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        let fileStore = GlobalSettingsFileStore(fileURL: fileURL)
        let suiteName = "SettingsJSONOnlyPersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)

        #if REPOPROMPT_SENTRY_ENABLED
            XCTAssertTrue(store.telemetryEnabled())
        #else
            XCTAssertFalse(store.telemetryEnabled())
        #endif
        XCTAssertFalse(store.telemetryAppHangReportsEnabled())
        XCTAssertFalse(store.telemetryPerformanceTracingEnabled())

        store.setTelemetryEnabled(false)
        store.setTelemetryAppHangReportsEnabled(false)
        store.setTelemetryPerformanceTracingEnabled(true)

        let document = try fileStore.load()
        XCTAssertEqual(document.scalarPreferences?.telemetry?.enabled, false)
        XCTAssertEqual(document.scalarPreferences?.telemetry?.appHangReportsEnabled, false)
        XCTAssertEqual(document.scalarPreferences?.telemetry?.performanceTracingEnabled, true)
        XCTAssertEqual(defaults.object(forKey: "telemetry.enabled") as? Bool, false)

        let reloaded = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)
        XCTAssertFalse(reloaded.telemetryEnabled())
        XCTAssertFalse(reloaded.telemetryAppHangReportsEnabled())
        XCTAssertTrue(reloaded.telemetryPerformanceTracingEnabled())
    }

    func testCorruptTelemetrySettingsFailSafeMasterOff() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: fileURL)
        let suiteName = "SettingsJSONOnlyPersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: "telemetry.enabled")
        let store = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(fileURL: fileURL, now: { Date(timeIntervalSince1970: 0) })
        )

        XCTAssertFalse(store.telemetryEnabled())
        XCTAssertEqual(defaults.object(forKey: "telemetry.enabled") as? Bool, false)
    }

    func testBlockedSchemaTelemetryMirrorPreservesExistingValueAndDefaultsAbsentMirrorOff() throws {
        let blockedDocuments: [(name: String, json: String, reason: GlobalSettingsPersistenceBlockReason)] = [
            (
                "future",
                #"{"schemaVersion":999,"schemaLineage":"repoprompt-ce.global-settings","updatedAt":"2026-07-11T00:00:00Z"}"#,
                .unsupportedFutureSchema(
                    onDiskVersion: 999,
                    supportedVersion: GlobalSettingsDocument.currentSchemaVersion
                )
            ),
            (
                "incompatible",
                #"{"schemaVersion":4,"updatedAt":"2026-07-11T00:00:00Z"}"#,
                .incompatibleSchema
            )
        ]

        for blocked in blockedDocuments {
            for priorMirror in [Optional(true), Optional(false), nil] {
                let temp = try makeTempDirectory()
                defer { try? FileManager.default.removeItem(at: temp) }
                let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Data(blocked.json.utf8).write(to: fileURL)
                let defaults = try makeIsolatedDefaults()
                if let priorMirror {
                    defaults.set(priorMirror, forKey: "telemetry.enabled")
                }

                let store = GlobalSettingsStore(
                    defaults: defaults,
                    fileStore: GlobalSettingsFileStore(fileURL: fileURL)
                )
                let expected = priorMirror ?? false

                XCTAssertEqual(store.persistenceBlockReason, blocked.reason, blocked.name)
                XCTAssertEqual(defaults.object(forKey: "telemetry.enabled") as? Bool, expected, blocked.name)
                XCTAssertEqual(store.telemetryEnabled(), expected, blocked.name)
                XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), blocked.json, blocked.name)
            }
        }
    }

    func testMissingTelemetrySettingsRemovesStaleMirrorAndUsesBuildDefault() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        let defaults = try makeIsolatedDefaults()
        defaults.set(true, forKey: "telemetry.enabled")

        let store = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(fileURL: fileURL)
        )

        XCTAssertNil(defaults.object(forKey: "telemetry.enabled"))
        #if REPOPROMPT_SENTRY_ENABLED
            XCTAssertTrue(store.telemetryEnabled())
        #else
            XCTAssertFalse(store.telemetryEnabled())
        #endif
    }

    func testSuccessfulRecoveryResynchronizesTelemetryMirror() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(
            #"{"schemaVersion":999,"schemaLineage":"repoprompt-ce.global-settings","updatedAt":"2026-07-11T00:00:00Z"}"#.utf8
        ).write(to: fileURL)
        let defaults = try makeIsolatedDefaults()
        defaults.set(true, forKey: "telemetry.enabled")
        let store = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(fileURL: fileURL)
        )
        XCTAssertTrue(store.telemetryEnabled())

        XCTAssertTrue(store.recoverBlockedPersistenceAfterBackup())

        XCTAssertNil(store.persistenceBlockReason)
        XCTAssertNil(defaults.object(forKey: "telemetry.enabled"))
        #if REPOPROMPT_SENTRY_ENABLED
            XCTAssertTrue(store.telemetryEnabled())
        #else
            XCTAssertFalse(store.telemetryEnabled())
        #endif
    }

    func testTelemetryJSONValueOverridesStaleEnabledMirror() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        let fileStore = GlobalSettingsFileStore(fileURL: fileURL)
        try fileStore.save(GlobalSettingsDocument(
            scalarPreferences: GlobalScalarPreferences(
                telemetry: .init(enabled: false, appHangReportsEnabled: true, performanceTracingEnabled: false)
            )
        ))
        let suiteName = "SettingsJSONOnlyPersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "telemetry.enabled")

        let store = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)

        XCTAssertFalse(store.telemetryEnabled())
        XCTAssertEqual(defaults.object(forKey: "telemetry.enabled") as? Bool, false)
    }

    func testTelemetryLoadClearsMirrorWhenJSONHasNoTelemetryValue() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        let fileStore = GlobalSettingsFileStore(fileURL: fileURL)
        try fileStore.save(GlobalSettingsDocument(scalarPreferences: GlobalScalarPreferences(ui: .init(showTooltips: true))))
        let suiteName = "SettingsJSONOnlyPersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "telemetry.enabled")

        _ = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)

        XCTAssertNil(defaults.object(forKey: "telemetry.enabled"))
    }

    func testSentryScrubStringRedactsSensitiveValues() {
        let raw = "token=abcdef password:sekret /Users/alice/project 192.168.1.42"
        let scrubbed = SentryTelemetryBootstrap.scrubStringForTesting(raw)

        XCTAssertFalse(scrubbed.contains("abcdef"))
        XCTAssertFalse(scrubbed.contains("sekret"))
        XCTAssertFalse(scrubbed.contains("/Users/alice"))
        XCTAssertFalse(scrubbed.contains("192.168.1.42"))
        XCTAssertFalse(scrubbed.contains("/Users/\(NSUserName())"))
        XCTAssertTrue(scrubbed.contains("token=[redacted]"))
        XCTAssertTrue(scrubbed.contains("password=[redacted]"))
        XCTAssertTrue(scrubbed.contains("[ip]"))
    }

    func testSentryScrubStringRedactsAuthorizationSchemesAndCredentialTails() {
        let raw = [
            "Authorization: Bearer sk-abc123 request failed with 401",
            "Authorization: Basic dXNlcjpwYXNzd29yZA==",
            "authorization=Bearer abc.def.ghi",
            "header was Bearer eyJhbGciOiJIUzI1NiJ9.payload.sig",
            "X-Api-Key: sk-live-9999",
            "the basic idea is simple"
        ].joined(separator: " | ")

        let scrubbed = SentryTelemetryBootstrap.scrubStringForTesting(raw)

        XCTAssertFalse(scrubbed.contains("sk-abc123"))
        XCTAssertFalse(scrubbed.contains("Bearer sk"))
        XCTAssertFalse(scrubbed.contains("dXNlcjpwYXNzd29yZA=="))
        XCTAssertFalse(scrubbed.contains("abc.def.ghi"))
        XCTAssertFalse(scrubbed.contains("eyJhbGciOiJIUzI1NiJ9.payload.sig"))
        XCTAssertFalse(scrubbed.contains("sk-live-9999"))
        XCTAssertTrue(scrubbed.contains("Authorization=[redacted] request failed with 401"))
        XCTAssertTrue(scrubbed.contains("authorization=[redacted]"))
        XCTAssertTrue(scrubbed.contains("header was [redacted]"))
        XCTAssertTrue(scrubbed.contains("X-Api-Key=[redacted]"))
        XCTAssertTrue(scrubbed.contains("the basic idea is simple"))
    }

    func testSentryScrubPayloadDropsRequestGeoUserAndStableDeviceIdentifiers() throws {
        let scrubbed = SentryTelemetryBootstrap.scrubPayloadForTesting([
            "request": [
                "url": "https://example.invalid/private?token=secret",
                "headers": ["Authorization": "Bearer abcdef"]
            ],
            "contexts": [
                "device": [
                    "id": "stable-device-id",
                    "identifier_for_vendor": "stable-vendor-id",
                    "name": "Alice’s MacBook",
                    "model": "Mac14,7"
                ],
                "os": ["name": "macOS", "version": "15.0"],
                "app": [
                    "device_app_hash": "stable-app-device-hash",
                    "app_identifier": "com.pvncher.repoprompt.ce"
                ]
            ],
            "user": [
                "id": "stable-user-id",
                "geo": ["city": "Tokyo", "country_code": "JP"]
            ],
            "extra": [
                "installation_id": "stable-installation-id",
                "safe_note": "token=abcdef 10.0.0.1"
            ]
        ])

        XCTAssertNil(scrubbed["request"])
        XCTAssertNil(scrubbed["user"])
        let contexts = try XCTUnwrap(scrubbed["contexts"] as? [String: Any])
        let device = try XCTUnwrap(contexts["device"] as? [String: Any])
        XCTAssertNil(device["id"])
        XCTAssertNil(device["identifier_for_vendor"])
        XCTAssertNil(device["name"])
        XCTAssertEqual(device["model"] as? String, "Mac14,7")
        XCTAssertNotNil(contexts["os"])
        let app = try XCTUnwrap(contexts["app"] as? [String: Any])
        XCTAssertNil(app["device_app_hash"])
        XCTAssertEqual(app["app_identifier"] as? String, "com.pvncher.repoprompt.ce")
        let extra = try XCTUnwrap(scrubbed["extra"] as? [String: Any])
        XCTAssertNil(extra["installation_id"])
        XCTAssertEqual(extra["safe_note"] as? String, "token=[redacted] [ip]")
    }

    func testSentryScrubPayloadDropsNestedRequestAndGeoFieldsWithoutDroppingSafeSiblings() throws {
        let scrubbed = SentryTelemetryBootstrap.scrubPayloadForTesting([
            "breadcrumb": [
                "category": "app.lifecycle",
                "url": "https://example.invalid/private",
                "data": [
                    "query_string": "api_key=secret",
                    "result": "ok"
                ]
            ],
            "profile": [
                "user_geo": ["region": "CA"],
                "display": "safe value"
            ]
        ])

        let breadcrumb = try XCTUnwrap(scrubbed["breadcrumb"] as? [String: Any])
        XCTAssertEqual(breadcrumb["category"] as? String, "app.lifecycle")
        XCTAssertNil(breadcrumb["url"])
        let data = try XCTUnwrap(breadcrumb["data"] as? [String: Any])
        XCTAssertNil(data["query_string"])
        XCTAssertEqual(data["result"] as? String, "ok")
        let profile = try XCTUnwrap(scrubbed["profile"] as? [String: Any])
        XCTAssertNil(profile["user_geo"])
        XCTAssertEqual(profile["display"] as? String, "safe value")
    }

    func testObsoleteGitignoreJSONKeyIsIgnoredAndNeverEmitted() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        let fileStore = GlobalSettingsFileStore(fileURL: fileURL)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json = """
        {"schemaVersion":2,"updatedAt":"2026-05-20T00:00:00Z","copySettingsByWorkspaceID":{},"chatSettingsByWorkspaceID":{},"globalDefaults":{},"scalarPreferences":{"fileSystem":{"\(obsoleteGitignorePreferenceKey)":false,"respectRepoIgnore":false}}}
        """
        try Data(json.utf8).write(to: fileURL)

        let store = try GlobalSettingsStore(
            defaults: XCTUnwrap(UserDefaults(suiteName: "SettingsJSONOnlyPersistenceTests.\(UUID().uuidString)")),
            fileStore: fileStore
        )

        XCTAssertFalse(store.respectRepoIgnore())
        store.setShowEmptyFolders(true)

        let persisted = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertFalse(persisted.contains(obsoleteGitignorePreferenceKey))
        XCTAssertEqual(try fileStore.load().scalarPreferences?.fileSystem?.showEmptyFolders, true)
    }

    func testWorktreeVisualIdentityDefaultsAreEmptyAndFallbackDoesNotPersist() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        let fileStore = GlobalSettingsFileStore(fileURL: fileURL)
        let store = try GlobalSettingsStore(
            defaults: XCTUnwrap(UserDefaults(suiteName: "SettingsJSONOnlyPersistenceTests.\(UUID().uuidString)")),
            fileStore: fileStore
        )
        let before = try String(contentsOf: fileURL, encoding: .utf8)

        XCTAssertTrue(store.worktreeVisualIdentitiesByRepositoryID().isEmpty)
        let fallback = store.resolvedWorktreeVisualIdentity(
            repositoryID: "gitrepo_alpha",
            worktreeID: "wt_feature",
            fallbackLabel: "Feature",
            fallbackIconName: "leaf.fill",
            fallbackMarkerStyle: .ring
        )

        XCTAssertEqual(fallback.label, "Feature")
        XCTAssertTrue(GlobalSettingsStore.isValidWorktreeColorHex(fallback.colorHex))
        XCTAssertEqual(fallback.iconName, "leaf.fill")
        XCTAssertEqual(fallback.markerStyle, .ring)
        XCTAssertNil(fallback.updatedAt)
        XCTAssertNil(store.worktreeVisualIdentity(repositoryID: "gitrepo_alpha", worktreeID: "wt_feature"))
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), before)
    }

    func testWorktreeVisualIdentitySavesAndLoads() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        let fileStore = GlobalSettingsFileStore(fileURL: fileURL)
        let suiteName = "SettingsJSONOnlyPersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)
        let updatedAt = Date(timeIntervalSince1970: 1800)

        let identity = try store.ensureWorktreeVisualIdentity(
            repositoryID: " gitrepo_alpha ",
            worktreeID: " wt_feature ",
            label: " Feature ",
            colorHex: "#aabbcc",
            iconName: " folder.badge.gearshape ",
            markerStyle: .capsule,
            updatedAt: updatedAt
        )

        XCTAssertEqual(identity, WorktreeVisualIdentity(
            label: "Feature",
            colorHex: "#AABBCC",
            iconName: "folder.badge.gearshape",
            markerStyle: .capsule,
            updatedAt: updatedAt
        ))

        let reloaded = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)
        XCTAssertEqual(
            reloaded.worktreeVisualIdentity(repositoryID: "gitrepo_alpha", worktreeID: "wt_feature"),
            WorktreeVisualIdentity(
                label: "Feature",
                colorHex: "#AABBCC",
                iconName: "folder.badge.gearshape",
                markerStyle: .capsule,
                updatedAt: updatedAt
            )
        )
        XCTAssertEqual(
            reloaded.worktreeVisualIdentitiesByRepositoryID()["gitrepo_alpha"]?.identitiesByWorktreeID.keys.sorted(),
            ["wt_feature"]
        )
    }

    func testWorktreeVisualIdentityRejectsInvalidColors() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        let store = try GlobalSettingsStore(
            defaults: XCTUnwrap(UserDefaults(suiteName: "SettingsJSONOnlyPersistenceTests.\(UUID().uuidString)")),
            fileStore: GlobalSettingsFileStore(fileURL: fileURL)
        )

        XCTAssertThrowsError(try store.ensureWorktreeVisualIdentity(
            repositoryID: "gitrepo_alpha",
            worktreeID: "wt_feature",
            colorHex: "AABBCC"
        )) { error in
            XCTAssertEqual(error as? GlobalSettingsStore.WorktreeVisualIdentityError, .invalidColorHex("AABBCC"))
        }
    }

    func testWorktreeVisualIdentityDecodesMissingUXFieldsWithDefaults() throws {
        let json = """
        {"schemaVersion":4,"schemaLineage":"repoprompt-ce.global-settings","updatedAt":"2026-05-20T00:00:00Z","copySettingsByWorkspaceID":{},"chatSettingsByWorkspaceID":{},"globalDefaults":{"worktreeVisualIdentitiesByRepositoryID":{"gitrepo_alpha":{"identitiesByWorktreeID":{"wt_feature":{"label":"Feature","colorHex":"#112233"}}}}},"scalarPreferences":{}}
        """
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: fileURL)

        let store = try GlobalSettingsStore(
            defaults: XCTUnwrap(UserDefaults(suiteName: "SettingsJSONOnlyPersistenceTests.\(UUID().uuidString)")),
            fileStore: GlobalSettingsFileStore(fileURL: fileURL)
        )

        XCTAssertEqual(
            store.worktreeVisualIdentity(repositoryID: "gitrepo_alpha", worktreeID: "wt_feature"),
            WorktreeVisualIdentity(
                label: "Feature",
                colorHex: "#112233",
                iconName: WorktreeVisualIdentity.defaultIconName,
                markerStyle: WorktreeVisualIdentity.defaultMarkerStyle
            )
        )
    }

    func testWorktreeVisualIdentityDecodesMissingFieldWithoutSchemaBump() throws {
        let json = #"{"schemaVersion":4,"schemaLineage":"repoprompt-ce.global-settings","updatedAt":"2026-05-20T00:00:00Z","copySettingsByWorkspaceID":{},"chatSettingsByWorkspaceID":{},"globalDefaults":{},"scalarPreferences":{}}"#
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: fileURL)

        let store = try GlobalSettingsStore(
            defaults: XCTUnwrap(UserDefaults(suiteName: "SettingsJSONOnlyPersistenceTests.\(UUID().uuidString)")),
            fileStore: GlobalSettingsFileStore(fileURL: fileURL)
        )

        XCTAssertEqual(GlobalSettingsDocument.currentSchemaVersion, 4)
        XCTAssertTrue(store.worktreeVisualIdentitiesByRepositoryID().isEmpty)
    }

    /// GUARD RAIL — do not "fix" this by raising the ceiling. Classic/internal RepoPrompt
    /// wrote unlineaged schemaVersion 3/4 globalSettings.json files into live Application
    /// Support folders before CE introduced schemaLineage. The ceiling is frozen at 2 so those
    /// foreign files stay in the incompatible/import lane even after CE reaches v3/v4.
    func testLegacyUnlineagedCeilingIsFrozenAtTwo() {
        XCTAssertEqual(GlobalSettingsDocument.legacyUnlineagedSchemaVersionCeiling, 2)
    }

    func testUnlineagedHigherSchemaStaysBlockedAfterFutureNumericSchemaCatchup() {
        XCTAssertEqual(
            GlobalSettingsFileStore.preservationBlockReason(
                schemaVersion: 4,
                schemaLineage: nil,
                supportedVersion: 4
            ),
            .incompatibleSchema
        )
        XCTAssertNil(
            GlobalSettingsFileStore.preservationBlockReason(
                schemaVersion: 4,
                schemaLineage: GlobalSettingsDocument.schemaLineage,
                supportedVersion: 4
            )
        )
        XCTAssertEqual(
            GlobalSettingsFileStore.preservationBlockReason(
                schemaVersion: 5,
                schemaLineage: GlobalSettingsDocument.schemaLineage,
                supportedVersion: 4
            ),
            .unsupportedFutureSchema(onDiskVersion: 5, supportedVersion: 4)
        )
        XCTAssertNil(
            GlobalSettingsFileStore.preservationBlockReason(
                schemaVersion: 2,
                schemaLineage: nil,
                supportedVersion: 4
            )
        )
    }

    func testCorruptGlobalSettingsIsBackedUpAndReplacedWithDefaults() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: fileURL)

        let fileStore = GlobalSettingsFileStore(fileURL: fileURL, now: { Date(timeIntervalSince1970: 0) })
        let document = fileStore.loadOrCreateDefault()

        XCTAssertEqual(document.schemaVersion, GlobalSettingsDocument.baselineSchemaVersion)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        let backupDirectory = fileURL.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true)
        let backups = try FileManager.default.contentsOfDirectory(atPath: backupDirectory.path)
        XCTAssertTrue(backups.contains { $0.hasPrefix("globalSettings.corrupt-") })
    }

    func testFutureGlobalSettingsSchemaIsPreservedAndSaveIsBlocked() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let futureJSON = #"{"schemaVersion":999,"schemaLineage":"repoprompt-ce.global-settings","updatedAt":"2026-05-20T00:00:00Z"}"#
        try Data(futureJSON.utf8).write(to: fileURL)

        let fileStore = GlobalSettingsFileStore(fileURL: fileURL)
        let document = fileStore.loadOrCreateDefault()

        XCTAssertEqual(document.schemaVersion, GlobalSettingsDocument.baselineSchemaVersion)
        let preserved = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertEqual(preserved, futureJSON)
        XCTAssertThrowsError(try fileStore.save(GlobalSettingsDocument())) { error in
            XCTAssertEqual(error as? GlobalSettingsFileStore.GlobalSettingsFileStoreError, .unsupportedFutureSchemaPreserved)
        }
    }

    func testDirectFutureGlobalSettingsLoadProtectsLaterSave() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        let fileStore = GlobalSettingsFileStore(fileURL: fileURL)
        try fileStore.save(GlobalSettingsDocument())

        let futureJSON = #"{"schemaVersion":999,"schemaLineage":"repoprompt-ce.global-settings","updatedAt":"2026-05-20T00:00:00Z"}"#
        try Data(futureJSON.utf8).write(to: fileURL)

        XCTAssertThrowsError(try fileStore.load()) { error in
            XCTAssertEqual(error as? GlobalSettingsFileStore.GlobalSettingsFileStoreError, .unsupportedFutureSchema(999))
        }
        XCTAssertThrowsError(try fileStore.save(GlobalSettingsDocument())) { error in
            XCTAssertEqual(error as? GlobalSettingsFileStore.GlobalSettingsFileStoreError, .unsupportedFutureSchemaPreserved)
        }
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), futureJSON)
    }

    func testFileMentionPickerStyleDefaultsToCompactWithoutPersistingRawSetting() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        let fileStore = GlobalSettingsFileStore(fileURL: fileURL)
        let store = try GlobalSettingsStore(
            defaults: XCTUnwrap(UserDefaults(suiteName: "SettingsJSONOnlyPersistenceTests.\(UUID().uuidString)")),
            fileStore: fileStore
        )
        let before = try String(contentsOf: fileURL, encoding: .utf8)

        XCTAssertEqual(store.fileMentionPickerStyle(), .compact)
        XCTAssertEqual(store.fileMentionPickerConfiguration(), .compact)
        XCTAssertNil(try fileStore.load().scalarPreferences?.ui?.fileMentionPickerStyle)
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), before)
    }

    func testFileMentionPickerStyleSavesAndLoadsExpandedRawValue() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        let fileStore = GlobalSettingsFileStore(fileURL: fileURL)
        let suiteName = "SettingsJSONOnlyPersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)

        store.setFileMentionPickerStyle(.expanded)

        XCTAssertEqual(try fileStore.load().scalarPreferences?.ui?.fileMentionPickerStyle, "expanded")
        let reloaded = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)
        XCTAssertEqual(reloaded.fileMentionPickerStyle(), .expanded)
        XCTAssertEqual(reloaded.fileMentionPickerConfiguration(), .expanded)
    }

    func testInvalidFileMentionPickerStyleRawDefaultsToCompactWithoutReadTimeMutation() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        let fileStore = GlobalSettingsFileStore(fileURL: fileURL)
        try fileStore.save(GlobalSettingsDocument(
            scalarPreferences: GlobalScalarPreferences(
                ui: .init(fileMentionPickerStyle: "wide")
            )
        ))

        let store = try GlobalSettingsStore(
            defaults: XCTUnwrap(UserDefaults(suiteName: "SettingsJSONOnlyPersistenceTests.\(UUID().uuidString)")),
            fileStore: fileStore
        )

        XCTAssertEqual(store.fileMentionPickerStyle(), .compact)
        XCTAssertEqual(store.fileMentionPickerConfiguration(), .compact)
        XCTAssertEqual(try fileStore.load().scalarPreferences?.ui?.fileMentionPickerStyle, "wide")
    }

    func testShowDatesInMessageTimestampsDefaultsFalseWithoutPersisting() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        let fileStore = GlobalSettingsFileStore(fileURL: fileURL)
        try fileStore.save(GlobalSettingsDocument(
            scalarPreferences: GlobalScalarPreferences(ui: .init(showTooltips: false))
        ))
        let suiteName = "SettingsJSONOnlyPersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)
        let before = try String(contentsOf: fileURL, encoding: .utf8)

        XCTAssertFalse(store.showDatesInMessageTimestamps())
        XCTAssertNil(try fileStore.load().scalarPreferences?.ui?.showDatesInMessageTimestamps)
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), before)
    }

    func testShowDatesInMessageTimestampsSavesAndLoadsTrue() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        let fileStore = GlobalSettingsFileStore(fileURL: fileURL)
        let suiteName = "SettingsJSONOnlyPersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)

        store.setShowDatesInMessageTimestamps(true)

        XCTAssertEqual(try fileStore.load().scalarPreferences?.ui?.showDatesInMessageTimestamps, true)
        let reloaded = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)
        XCTAssertTrue(reloaded.showDatesInMessageTimestamps())
    }

    // MARK: - Cross-window observability & persistence-block recovery

    private func makeStore(at fileURL: URL) throws -> GlobalSettingsStore {
        let suiteName = "SettingsJSONOnlyPersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return GlobalSettingsStore(defaults: defaults, fileStore: GlobalSettingsFileStore(fileURL: fileURL))
    }

    /// A `globalDefaults` change must publish `objectWillChange` so other windows observing
    /// `GlobalSettingsStore` re-sync. Defect: changing the Context Builder agent or MCP role
    /// defaults in one window left every other window stale.
    func testGlobalDefaultsSettersPublishObjectWillChange() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        let store = try makeStore(at: fileURL)

        var emissions = 0
        let cancellable = store.objectWillChange.sink { _ in emissions += 1 }
        defer { cancellable.cancel() }

        store.updateGlobalMCPAgentRoleOverrides(["explore": "claudeCode:haiku"])
        store.setGlobalContextBuilderAgentSelection(agentRaw: "claudeCode", modelRaw: "haiku", markUserDefined: true)
        store.setGlobalRecommendationProviderFilter([.codex])

        XCTAssertGreaterThanOrEqual(
            emissions, 3,
            "globalDefaults setters must publish objectWillChange so other windows update"
        )
    }

    /// A newer-than-supported schema must be surfaced (not silently treated as defaults) so the
    /// user understands why settings will not save. Defect: every restart silently reset all
    /// global settings because the v3 file was indistinguishable from \"no settings\".
    func testNewerSchemaFileExposesBlockReason() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"schemaVersion":999,"schemaLineage":"repoprompt-ce.global-settings","updatedAt":"2026-05-20T00:00:00Z"}"#.utf8).write(to: fileURL)

        let store = try makeStore(at: fileURL)

        XCTAssertEqual(
            store.persistenceBlockReason,
            .unsupportedFutureSchema(onDiskVersion: 999, supportedVersion: GlobalSettingsDocument.currentSchemaVersion)
        )
    }

    /// A newer-schema file must be preserved and keep saves blocked until the user explicitly
    /// recovers. Defect: the app must never overwrite an unknown schema automatically.
    func testNewerSchemaFileIsPreservedAndSaveStaysBlocked() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let futureJSON = #"{"schemaVersion":999,"schemaLineage":"repoprompt-ce.global-settings","updatedAt":"2026-05-20T00:00:00Z","copySettingsByWorkspaceID":{},"chatSettingsByWorkspaceID":{},"globalDefaults":{"discoverAgentRaw":"claudeCode"},"scalarPreferences":{}}"#
        try Data(futureJSON.utf8).write(to: fileURL)

        let store = try makeStore(at: fileURL)
        // A change attempt must not touch the preserved newer-schema file.
        store.setGlobalContextBuilderAgentSelection(agentRaw: "codexExec", modelRaw: "default", markUserDefined: true)
        let onDiskDuringBlock = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(onDiskDuringBlock.contains("\"schemaVersion\":999"))
        XCTAssertNotNil(store.persistenceBlockReason, "save must stay blocked until the user recovers")
    }

    /// A realistic unlineaged v4 settings file from another build must be treated as a foreign
    /// schema: surfaced, preserved byte-for-byte, and never overwritten by CE saves.
    func testVersionFourSettingsFileWithAgentModelsKeyIsPreserved() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let versionFourJSON = #"{"schemaVersion":4,"updatedAt":"2026-06-27T13:11:41Z","copySettingsByWorkspaceID":{},"chatSettingsByWorkspaceID":{},"agentModelsSettingsByWorkspaceID":{"workspace-1":{"selectedAgentRaw":"claudeCode"}},"globalDefaults":{"discoverAgentRaw":"claudeCode"},"scalarPreferences":{"ui":{"appearanceMode":"dark"}}}"#
        try Data(versionFourJSON.utf8).write(to: fileURL)

        let store = try makeStore(at: fileURL)
        XCTAssertEqual(
            store.persistenceBlockReason,
            .incompatibleSchema
        )

        store.setGlobalContextBuilderAgentSelection(agentRaw: "codexExec", modelRaw: "default", markUserDefined: true)
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), versionFourJSON)
    }

    /// User-initiated import should keep compatible settings from a realistic v4 file so users
    /// are not forced to re-enter everything just because newer-only fields exist.
    func testUserInitiatedCompatibleImportFromVersionFourBacksUpAndPreservesKnownSettings() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let versionFourJSON = #"{"schemaVersion":4,"updatedAt":"2026-06-27T13:11:41Z","copySettingsByWorkspaceID":{},"chatSettingsByWorkspaceID":{},"agentModelsSettingsByWorkspaceID":{"workspace-1":{"selectedAgentRaw":"claudeCode"}},"globalDefaults":{"discoverAgentRaw":"claudeCode","discoverModelsByAgent":{"claudeCode":"haiku"}},"scalarPreferences":{"ui":{"appearanceMode":"dark"},"modelSelection":{"planningModel":"haiku"}}}"#
        try Data(versionFourJSON.utf8).write(to: fileURL)

        let store = try makeStore(at: fileURL)
        XCTAssertNotNil(store.persistenceBlockReason)

        XCTAssertTrue(store.importBlockedPersistenceAfterBackup())
        XCTAssertNil(store.persistenceBlockReason)
        XCTAssertEqual(store.appearanceModeRaw(), "dark")
        XCTAssertEqual(store.globalContextBuilderAgentSelection().agentRaw, "claudeCode")
        XCTAssertEqual(store.globalContextBuilderAgentSelection().modelRaw, "haiku")
        XCTAssertEqual(store.planningModelRaw(), "haiku")

        let persisted = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(persisted.contains(#""schemaVersion" : 4"#))
        XCTAssertTrue(persisted.contains(#""schemaLineage" : "repoprompt-ce.global-settings""#))
        XCTAssertTrue(persisted.contains("agentModelsSettingsByWorkspaceID"))

        let backupDir = fileURL.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true)
        let backups = try FileManager.default.contentsOfDirectory(atPath: backupDir.path)
        let importedBackup = try XCTUnwrap(backups.first { $0.hasPrefix("globalSettings.imported-") })
        let backupURL = backupDir.appendingPathComponent(importedBackup)
        XCTAssertEqual(try String(contentsOf: backupURL, encoding: .utf8), versionFourJSON)
    }

    /// Same-lineage future CE settings are not a "compatible import" source for older builds:
    /// the backup makes reset safe, but silently down-converting a real future CE document would
    /// invite data loss during dev-build/live-folder downgrade loops.
    func testCompatibleImportRefusesSameLineageFutureSchema() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let futureJSON = #"{"schemaVersion":999,"schemaLineage":"repoprompt-ce.global-settings","updatedAt":"2026-05-20T00:00:00Z","copySettingsByWorkspaceID":{},"chatSettingsByWorkspaceID":{},"globalDefaults":{"discoverAgentRaw":"claudeCode","discoverModelsByAgent":{"claudeCode":"haiku"}},"scalarPreferences":{"ui":{"appearanceMode":"dark"}}}"#
        try Data(futureJSON.utf8).write(to: fileURL)

        let store = try makeStore(at: fileURL)
        XCTAssertEqual(
            store.persistenceBlockReason,
            .unsupportedFutureSchema(onDiskVersion: 999, supportedVersion: GlobalSettingsDocument.currentSchemaVersion)
        )

        XCTAssertFalse(store.importBlockedPersistenceAfterBackup())
        XCTAssertEqual(
            store.persistenceBlockReason,
            .unsupportedFutureSchema(onDiskVersion: 999, supportedVersion: GlobalSettingsDocument.currentSchemaVersion)
        )
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), futureJSON)
        let backupDir = fileURL.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupDir.path))
    }

    /// If a newer-schema file appears after startup, the next save attempt must surface the
    /// persistence block instead of silently failing without a banner.
    func testSaveTimeNewerSchemaFileUpdatesBlockReason() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        let store = try makeStore(at: fileURL)
        XCTAssertNil(store.persistenceBlockReason)

        let futureJSON = #"{"schemaVersion":999,"schemaLineage":"repoprompt-ce.global-settings","updatedAt":"2026-05-20T00:00:00Z","copySettingsByWorkspaceID":{},"chatSettingsByWorkspaceID":{},"globalDefaults":{"discoverAgentRaw":"claudeCode"},"scalarPreferences":{}}"#
        try Data(futureJSON.utf8).write(to: fileURL)

        store.setGlobalContextBuilderAgentSelection(agentRaw: "codexExec", modelRaw: "default", markUserDefined: true)

        XCTAssertEqual(
            store.persistenceBlockReason,
            .unsupportedFutureSchema(onDiskVersion: 999, supportedVersion: GlobalSettingsDocument.currentSchemaVersion)
        )
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), futureJSON)
    }

    /// A transient write failure must surface a save-specific block and retry the current
    /// in-memory settings without forcing a destructive reset.
    func testSaveFailureExposesBlockReasonAndRetryPersistsCurrentState() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        let store = try makeStore(at: fileURL)
        XCTAssertNil(store.persistenceBlockReason)

        try FileManager.default.removeItem(at: fileURL)
        try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: false)

        store.setGlobalContextBuilderAgentSelection(agentRaw: "codexExec", modelRaw: "default", markUserDefined: true)
        XCTAssertEqual(store.persistenceBlockReason, .saveFailed)

        try FileManager.default.removeItem(at: fileURL)
        XCTAssertTrue(store.retryBlockedPersistenceSave(), "retry should save the current in-memory settings once the file path is writable")
        XCTAssertNil(store.persistenceBlockReason)

        let reloaded = try makeStore(at: fileURL)
        XCTAssertEqual(reloaded.globalContextBuilderAgentSelection().agentRaw, "codexExec")
    }

    /// Recovery must not claim success if the offending file cannot be backed up. The
    /// future-schema file stays untouched so the user can inspect or recover it manually.
    func testUserInitiatedRecoveryReturnsFalseWhenBackupFails() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let futureJSON = #"{"schemaVersion":999,"schemaLineage":"repoprompt-ce.global-settings","updatedAt":"2026-05-20T00:00:00Z","copySettingsByWorkspaceID":{},"chatSettingsByWorkspaceID":{},"globalDefaults":{"discoverAgentRaw":"claudeCode"},"scalarPreferences":{}}"#
        try Data(futureJSON.utf8).write(to: fileURL)
        try Data("not a directory".utf8).write(
            to: fileURL.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true)
        )

        let store = try makeStore(at: fileURL)
        XCTAssertNotNil(store.persistenceBlockReason)

        XCTAssertFalse(store.recoverBlockedPersistenceAfterBackup(), "recovery must fail if the backup path cannot be created")
        XCTAssertEqual(
            store.persistenceBlockReason,
            .unsupportedFutureSchema(onDiskVersion: 999, supportedVersion: GlobalSettingsDocument.currentSchemaVersion)
        )
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), futureJSON)
    }

    /// User-initiated recovery backs up the offending file, writes current in-memory settings,
    /// clears the block, and re-enables saves. Defect: there was no way out of the blocked state
    /// without manually editing files under Application Support.
    func testUserInitiatedRecoveryBacksUpResetsAndUnblocks() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let futureJSON = #"{"schemaVersion":999,"schemaLineage":"repoprompt-ce.global-settings","updatedAt":"2026-05-20T00:00:00Z","copySettingsByWorkspaceID":{},"chatSettingsByWorkspaceID":{},"globalDefaults":{"discoverAgentRaw":"claudeCode"},"scalarPreferences":{}}"#
        try Data(futureJSON.utf8).write(to: fileURL)

        let store = try makeStore(at: fileURL)
        XCTAssertNotNil(store.persistenceBlockReason)

        XCTAssertTrue(store.recoverBlockedPersistenceAfterBackup(), "recovery should back up the offending file")
        XCTAssertNil(store.persistenceBlockReason, "recovery must clear the block")

        // Original offending file moved into Backups/.
        let backupDir = fileURL.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true)
        let backups = try FileManager.default.contentsOfDirectory(atPath: backupDir.path)
        XCTAssertTrue(backups.contains { $0.hasPrefix("globalSettings.superseded-") })

        // On-disk file is now current-schema defaults and saves work again.
        let reloaded = try makeStore(at: fileURL)
        XCTAssertNil(reloaded.persistenceBlockReason, "file must load healthy after recovery")
        reloaded.setGlobalContextBuilderAgentSelection(agentRaw: "codexExec", modelRaw: "default", markUserDefined: true)
        let post = try makeStore(at: fileURL)
        XCTAssertNil(post.persistenceBlockReason, "file must decode at current schema after recovery")
        XCTAssertEqual(post.globalContextBuilderAgentSelection().agentRaw, "codexExec", "saves must persist again after recovery")
    }

    // MARK: - Content-derived schema and compatibility repair

    func testBaselineAndDefaultContentUseSchemaV2InMemoryAndOnDisk() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        let fileStore = GlobalSettingsFileStore(fileURL: fileURL)

        let created = fileStore.loadOrCreateDefault()
        XCTAssertEqual(created.schemaVersion, GlobalSettingsDocument.baselineSchemaVersion)
        XCTAssertEqual(try fileStore.load().schemaVersion, created.schemaVersion)

        try fileStore.save(GlobalSettingsDocument(scalarPreferences: seededScalarPreferences()))
        XCTAssertEqual(try fileStore.load().schemaVersion, GlobalSettingsDocument.baselineSchemaVersion)
    }

    func testCompatibleLineagedSchemaV2LoadDoesNotRewriteBytes() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data(lineagedBaselineJSON.utf8)
        try original.write(to: fileURL)

        let loaded = try GlobalSettingsFileStore(fileURL: fileURL).load()

        XCTAssertEqual(loaded.schemaVersion, GlobalSettingsDocument.baselineSchemaVersion)
        XCTAssertEqual(try Data(contentsOf: fileURL), original)
    }

    func testWorkspaceAgentModelsUsesFixedFeatureSchemaV4() {
        let document = GlobalSettingsDocument(
            agentModelsSettings: [UUID(): WorkspaceAgentModelsSettings(inheritanceMode: .useWorkspaceOverrides)]
        )

        XCTAssertEqual(GlobalSettingsDocument.workspaceAgentModelsSchemaVersion, 4)
        XCTAssertEqual(document.requiredSchemaVersion, GlobalSettingsDocument.workspaceAgentModelsSchemaVersion)
    }

    func testFalseV4BacksUpExactBytesNormalizesOnlyHeaderAndIsIdempotent() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data(falseV4JSON(includeEmptyAgentModelsObject: true).utf8)
        try original.write(to: fileURL)
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let loaded = try GlobalSettingsFileStore(fileURL: fileURL, now: { now }).load()

        XCTAssertEqual(loaded.schemaVersion, GlobalSettingsDocument.baselineSchemaVersion)
        let backupDirectory = fileURL.deletingLastPathComponent().appendingPathComponent("Backups")
        let backups = try falseV4Backups(in: backupDirectory)
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), original)

        var expected = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        expected["schemaVersion"] = GlobalSettingsDocument.baselineSchemaVersion
        let actual = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        )
        XCTAssertEqual(
            try JSONSerialization.data(withJSONObject: actual, options: [.sortedKeys]),
            try JSONSerialization.data(withJSONObject: expected, options: [.sortedKeys])
        )

        var rollbackWriter = try FrozenV1028GlobalSettingsDocument.load(from: fileURL)
        rollbackWriter.setAppearanceMode("Light")
        try rollbackWriter.save(to: fileURL, now: now.addingTimeInterval(1))
        XCTAssertEqual(
            try GlobalSettingsFileStore(fileURL: fileURL, now: { now }).load().schemaVersion,
            GlobalSettingsDocument.baselineSchemaVersion
        )
        XCTAssertEqual(try falseV4Backups(in: backupDirectory).count, 1)
    }

    func testFalseV4WithoutWorkspaceProfilesKeyAlsoNormalizes() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(falseV4JSON(includeEmptyAgentModelsObject: false).utf8).write(to: fileURL)

        XCTAssertEqual(
            try GlobalSettingsFileStore(fileURL: fileURL).load().schemaVersion,
            GlobalSettingsDocument.baselineSchemaVersion
        )
    }

    func testFalseV4PresentNullAndWrongShapeArePreservedAndLatchSaves() throws {
        for (index, rawValue) in ["null", "[]", #""invalid""#].enumerated() {
            let temp = try makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: temp) }
            let fileURL = temp.appendingPathComponent("Settings-\(index)/globalSettings.json")
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let original = Data(falseV4JSON(rawAgentModelsValue: rawValue).utf8)
            try original.write(to: fileURL)
            let fileStore = GlobalSettingsFileStore(fileURL: fileURL)

            let store = try GlobalSettingsStore(
                defaults: makeIsolatedDefaults(),
                fileStore: fileStore
            )

            XCTAssertEqual(store.persistenceBlockReason, .automaticSchemaNormalizationFailed)
            XCTAssertFalse(fileStore.performUserInitiatedCompatibleImport())
            store.setShowTooltips(false)
            XCTAssertFalse(store.retryBlockedPersistenceSave())
            XCTAssertEqual(try Data(contentsOf: fileURL), original)
        }
    }

    func testFalseV4WorkspaceOverridesRemainV4WithoutBackup() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let workspaceID = UUID()
        let json = """
        {"schemaVersion":4,"schemaLineage":"repoprompt-ce.global-settings","updatedAt":"2026-05-20T00:00:00Z",
        "copySettingsByWorkspaceID":{},"chatSettingsByWorkspaceID":{},
        "agentModelsSettingsByWorkspaceID":{"\(workspaceID.uuidString)":{"inheritanceMode":"useWorkspaceOverrides","profile":null}},
        "globalDefaults":{},"scalarPreferences":{}}
        """
        let original = Data(json.utf8)
        try original.write(to: fileURL)

        XCTAssertThrowsError(try FrozenV1028GlobalSettingsDocument.load(from: fileURL)) { error in
            XCTAssertEqual(
                error as? FrozenV1028GlobalSettingsDocument.CompatibilityError,
                .unsupportedFutureSchema(GlobalSettingsDocument.workspaceAgentModelsSchemaVersion)
            )
        }
        let document = try GlobalSettingsFileStore(fileURL: fileURL).load()

        XCTAssertEqual(document.schemaVersion, GlobalSettingsDocument.workspaceAgentModelsSchemaVersion)
        XCTAssertEqual(try Data(contentsOf: fileURL), original)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fileURL.deletingLastPathComponent().appendingPathComponent("Backups").path
        ))
    }

    func testFalseV4PartialDecodeIsPreservedAndBlocksAutomaticSaves() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data(
            #"{"schemaVersion":4,"schemaLineage":"repoprompt-ce.global-settings","copySettingsByWorkspaceID":{},"chatSettingsByWorkspaceID":{},"globalDefaults":{},"scalarPreferences":{},"unknown":{"keep":true}}"#.utf8
        )
        try original.write(to: fileURL)

        let store = try GlobalSettingsStore(
            defaults: makeIsolatedDefaults(),
            fileStore: GlobalSettingsFileStore(fileURL: fileURL)
        )

        XCTAssertEqual(store.persistenceBlockReason, .automaticSchemaNormalizationFailed)
        store.setShowTooltips(false)
        XCTAssertEqual(try Data(contentsOf: fileURL), original)
    }

    func testFalseV4BackupFailurePreservesOriginalAndBlocksAutomaticAndLaterSaves() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data(falseV4JSON(includeEmptyAgentModelsObject: true).utf8)
        try original.write(to: fileURL)
        var atomicWriteCalled = false
        let fileStore = GlobalSettingsFileStore(
            fileURL: fileURL,
            normalizationBackupWriter: { _, _ in throw CocoaError(.fileWriteNoPermission) },
            normalizationAtomicWriter: { _, _ in atomicWriteCalled = true }
        )

        let store = try GlobalSettingsStore(defaults: makeIsolatedDefaults(), fileStore: fileStore)

        XCTAssertEqual(store.persistenceBlockReason, .automaticSchemaNormalizationFailed)
        XCTAssertFalse(atomicWriteCalled)
        store.setAppearanceModeRaw("Dark")
        XCTAssertFalse(store.retryBlockedPersistenceSave())
        XCTAssertEqual(try Data(contentsOf: fileURL), original)
    }

    func testFalseV4AtomicWriteFailurePreservesOriginalAfterExactBackup() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data(falseV4JSON(includeEmptyAgentModelsObject: false).utf8)
        try original.write(to: fileURL)
        var backedUpData: Data?
        let fileStore = GlobalSettingsFileStore(
            fileURL: fileURL,
            normalizationBackupWriter: { data, url in
                backedUpData = data
                try data.write(to: url, options: .atomic)
            },
            normalizationAtomicWriter: { _, _ in throw CocoaError(.fileWriteOutOfSpace) }
        )

        let store = try GlobalSettingsStore(defaults: makeIsolatedDefaults(), fileStore: fileStore)

        XCTAssertEqual(backedUpData, original)
        XCTAssertEqual(store.persistenceBlockReason, .automaticSchemaNormalizationFailed)
        store.setUseTransparency(false)
        XCTAssertEqual(try Data(contentsOf: fileURL), original)
    }

    func testSessionPersistenceBlockDismissalResetsOnReasonChangeAndUnblock() throws {
        let (store, fileURL) = try makeBlockedStore(
            json: #"{"schemaVersion":999,"schemaLineage":"repoprompt-ce.global-settings","updatedAt":"2026-05-20T00:00:00Z"}"#
        )
        store.dismissCurrentPersistenceBlockForSession()
        XCTAssertTrue(store.isCurrentPersistenceBlockDismissedForSession)

        try Data(#"{"unexpected":true}"#.utf8).write(to: fileURL)
        XCTAssertFalse(store.reloadFromDisk())
        XCTAssertEqual(store.persistenceBlockReason, .incompatibleSchema)
        XCTAssertFalse(store.isCurrentPersistenceBlockDismissedForSession)

        store.dismissCurrentPersistenceBlockForSession()
        try Data(lineagedBaselineJSON.utf8).write(to: fileURL)
        XCTAssertTrue(store.reloadFromDisk())
        XCTAssertNil(store.persistenceBlockReason)
        XCTAssertFalse(store.isCurrentPersistenceBlockDismissedForSession)
    }

    func testSessionPersistenceBlockDismissalAndObsoleteDurableValueDoNotSurviveRelaunch() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let blockedJSON = #"{"schemaVersion":999,"schemaLineage":"repoprompt-ce.global-settings","updatedAt":"2026-05-20T00:00:00Z"}"#
        try Data(blockedJSON.utf8).write(to: fileURL)
        let defaults = try makeIsolatedDefaults()
        defaults.set("obsolete", forKey: "settings.persistenceBlockSuppressionSignature")
        let first = GlobalSettingsStore(defaults: defaults, fileStore: GlobalSettingsFileStore(fileURL: fileURL))
        first.dismissCurrentPersistenceBlockForSession()
        XCTAssertTrue(first.isCurrentPersistenceBlockDismissedForSession)

        let relaunched = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(fileURL: fileURL)
        )

        XCTAssertFalse(relaunched.isCurrentPersistenceBlockDismissedForSession)
        XCTAssertNotNil(relaunched.persistenceBlockReason)
    }

    func testV1028ProductionStoreOldNewOldRoundTrip() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        let workspaceID = UUID()
        let fileStore = GlobalSettingsFileStore(fileURL: fileURL)
        let copy = CopyGlobalSettings(
            workspaceID: workspaceID,
            fileTreeOption: .files,
            codeMapUsage: .complete,
            gitInclusion: .all
        )
        let chat = ChatGlobalSettings(
            workspaceID: workspaceID,
            fileTreeOption: .files,
            codeMapUsage: .complete,
            gitInclusion: .all,
            planActMode: .plan,
            proFileEdits: true,
            discoveryTokenBudget: 64000,
            discoveryEnhancementMode: "enhance"
        )
        try fileStore.save(GlobalSettingsDocument(
            copySettings: [workspaceID: copy],
            chatSettings: [workspaceID: chat],
            globalDefaults: GlobalDefaults(
                discoverAgentRaw: nil,
                discoverModelsByAgent: nil,
                discoveryTokenBudget: 48000,
                discoveryEnhancementMode: "enhance",
                recommendationSchemaVersion: 7,
                tokenBudgetSchemaVersion: 3,
                codeMapsGloballyDisabled: true
            ),
            scalarPreferences: GlobalScalarPreferences(
                ui: .init(appearanceMode: "Dark", useTransparency: false, showTooltips: true),
                promptPackaging: .init(
                    promptSectionsOrder: "prompt,files",
                    duplicateUserInstructionsAtTop: true,
                    filePathDisplayOption: "Full",
                    selectedFilesSortMethod: "nameAscending",
                    fileEditFormat: "Diff",
                    modelTemperature: 0.3,
                    setModelTemperature: true
                ),
                modelSelection: .init(preferredComposeModel: "claude-sonnet", planningModel: "gpt-5"),
                mcp: .init(autoStart: true, showModelPresets: true),
                agentMode: .init(proEditAgentMode: true, maxBackgroundAgentComposeTabs: 4)
            )
        ))

        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        )
        var chats = try XCTUnwrap(root["chatSettingsByWorkspaceID"] as? [String: Any])
        var legacyChat = try XCTUnwrap(chats[workspaceID.uuidString] as? [String: Any])
        legacyChat["contextBuilderAgentRaw"] = "codexExec"
        legacyChat["contextBuilderAgentModelRaw"] = "gpt-5.2-codex"
        chats[workspaceID.uuidString] = legacyChat
        root["chatSettingsByWorkspaceID"] = chats
        try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            .write(to: fileURL, options: .atomic)

        var oldWriter = try FrozenV1028GlobalSettingsDocument.load(from: fileURL)
        XCTAssertEqual(oldWriter.schemaVersion, FrozenV1028GlobalSettingsDocument.schemaVersion)
        oldWriter.setAppearanceMode("Light")
        try oldWriter.save(to: fileURL, now: Date(timeIntervalSince1970: 1_700_000_100))

        let patched = try GlobalSettingsStore(
            defaults: makeIsolatedDefaults(),
            fileStore: GlobalSettingsFileStore(fileURL: fileURL)
        )
        XCTAssertEqual(patched.copySettings(for: workspaceID).fileTreeOption, .files)
        XCTAssertEqual(patched.chatSettings(for: workspaceID).discoveryTokenBudget, 64000)
        XCTAssertEqual(patched.globalContextBuilderAgentSelection().agentRaw, "codexExec")
        patched.setShowTooltips(false)

        var rollbackWriter = try FrozenV1028GlobalSettingsDocument.load(from: fileURL)
        XCTAssertEqual(rollbackWriter.schemaVersion, 2)
        let patchedRaw = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        )
        XCTAssertNil(patchedRaw["agentModelsSettingsByWorkspaceID"])
        rollbackWriter.setAppearanceMode("System")
        try rollbackWriter.save(to: fileURL, now: Date(timeIntervalSince1970: 1_700_000_200))

        let reloaded = try GlobalSettingsStore(
            defaults: makeIsolatedDefaults(),
            fileStore: GlobalSettingsFileStore(fileURL: fileURL)
        )
        XCTAssertEqual(reloaded.appearanceModeRaw(), "System")
        XCTAssertFalse(reloaded.showTooltips())
        XCTAssertEqual(reloaded.copySettings(for: workspaceID).fileTreeOption, .files)
        XCTAssertEqual(reloaded.chatSettings(for: workspaceID).discoveryTokenBudget, 64000)
    }

    // MARK: - Agent Models scoped settings

    func testAgentModelsMissingDefaultsResolveGlobalWithoutPersistingWorkspaceProfile() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        let fileStore = GlobalSettingsFileStore(fileURL: fileURL)
        let store = try GlobalSettingsStore(
            defaults: makeIsolatedDefaults(),
            fileStore: fileStore
        )
        let workspaceID = UUID()
        let before = try String(contentsOf: fileURL, encoding: .utf8)

        XCTAssertEqual(store.globalAgentModelsProfile(), AgentModelsSettingsProfile())
        XCTAssertEqual(
            store.workspaceAgentModelsSettings(for: workspaceID),
            WorkspaceAgentModelsSettings()
        )
        XCTAssertNil(store.workspaceAgentModelsProfile(for: workspaceID))
        XCTAssertEqual(store.effectiveAgentModelsProfile(workspaceID: workspaceID), store.globalAgentModelsProfile())
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), before)
        XCTAssertTrue(try (fileStore.load()).agentModelsSettings.isEmpty)
    }

    func testAgentModelsPreviousSchemaLoadSavesAsV4WithWorkspaceProfiles() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        let codexAgent = AgentProviderKind.codexExec.rawValue
        let codexModel = AgentModelCatalog.defaultModelRaw(for: .codexExec)
        let planningModel = AIModel.gpt54Pro.rawValue
        let composeModel = AIModel.claude4Sonnet.rawValue
        let json = """
        {
          "schemaVersion": 3,
          "schemaLineage": "repoprompt-ce.global-settings",
          "updatedAt": "2026-05-20T00:00:00Z",
          "copySettingsByWorkspaceID": {},
          "chatSettingsByWorkspaceID": {},
          "globalDefaults": {
            "discoverAgentRaw": "\(codexAgent)",
            "discoverModelsByAgent": { "\(codexAgent)": "\(codexModel)" },
            "mcpAgentRoleOverrides": { "plan": " codexExec:test-model " }
          },
          "scalarPreferences": {
            "fileSystem": { "globalIgnoreDefaults": "" },
            "modelSelection": {
              "planningModel": "\(planningModel)",
              "preferredComposeModel": "\(composeModel)",
              "syncChatModelWithOracle": false
            },
            "agentMode": { "restrictMCPAgentDiscoveryToRoleLabels": true }
          }
        }
        """
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: fileURL)

        let fileStore = GlobalSettingsFileStore(fileURL: fileURL)
        let store = try GlobalSettingsStore(defaults: makeIsolatedDefaults(), fileStore: fileStore)
        let workspaceID = UUID()
        store.setWorkspaceAgentModelsInheritanceMode(workspaceID: workspaceID, mode: .useWorkspaceOverrides)

        let saved = try fileStore.load()
        XCTAssertEqual(saved.schemaVersion, 4)
        XCTAssertEqual(
            saved.agentModelsSettings[workspaceID]?.profile,
            AgentModelsSettingsProfile(
                planningModelRaw: planningModel,
                preferredComposeModelRaw: composeModel,
                syncChatModelWithOracle: false,
                contextBuilderAgentRaw: codexAgent,
                contextBuilderModelsByAgent: [codexAgent: codexModel],
                mcpAgentRoleOverrides: ["plan": "codexExec:test-model"],
                restrictMCPAgentDiscoveryToRoleLabels: true
            )
        )
    }

    func testAgentModelsWorkspaceProfilesSurviveUnrelatedWrites() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        let fileStore = GlobalSettingsFileStore(fileURL: fileURL)
        let workspaceID = UUID()
        let profile = AgentModelsSettingsProfile(
            planningModelRaw: AIModel.gpt54Pro.rawValue,
            preferredComposeModelRaw: AIModel.claude4Sonnet.rawValue,
            syncChatModelWithOracle: false,
            contextBuilderAgentRaw: AgentProviderKind.claudeCode.rawValue,
            contextBuilderModelsByAgent: [
                AgentProviderKind.claudeCode.rawValue: AgentModelCatalog.defaultModelRaw(for: .claudeCode)
            ],
            mcpAgentRoleOverrides: ["review": "claudeCode:opus"],
            restrictMCPAgentDiscoveryToRoleLabels: true
        )
        try fileStore.save(GlobalSettingsDocument(
            agentModelsSettings: [
                workspaceID: WorkspaceAgentModelsSettings(
                    inheritanceMode: .useWorkspaceOverrides,
                    profile: profile
                )
            ],
            scalarPreferences: seededScalarPreferences()
        ))
        let store = try GlobalSettingsStore(defaults: makeIsolatedDefaults(), fileStore: fileStore)

        store.setShowDatesInMessageTimestamps(true)
        store.updateCopySettings(CopyGlobalSettings(workspaceID: UUID()))

        let saved = try fileStore.load()
        XCTAssertEqual(saved.agentModelsSettings[workspaceID]?.inheritanceMode, .useWorkspaceOverrides)
        XCTAssertEqual(saved.agentModelsSettings[workspaceID]?.profile, profile)
        XCTAssertEqual(saved.scalarPreferences?.ui?.showDatesInMessageTimestamps, true)
        XCTAssertFalse(saved.copySettings.isEmpty)
    }

    func testInvalidSynchronizedAgentModelsStateRepairsGlobalAndDormantWorkspaceProfiles() throws {
        let invalidTuples: [(planning: String?, compose: String?)] = [
            (nil, nil),
            (AIModel.gpt54Pro.rawValue, nil),
            (AIModel.gpt54Pro.rawValue, AIModel.claude4Sonnet.rawValue)
        ]

        for tuple in invalidTuples {
            let temp = try makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: temp) }
            let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
            let fileStore = GlobalSettingsFileStore(fileURL: fileURL)
            let dormantWorkspaceID = UUID()
            let workspaceProfile = AgentModelsSettingsProfile(
                planningModelRaw: tuple.planning,
                preferredComposeModelRaw: tuple.compose,
                syncChatModelWithOracle: true
            )
            let invalidDocument = GlobalSettingsDocument(
                agentModelsSettings: [
                    dormantWorkspaceID: WorkspaceAgentModelsSettings(
                        inheritanceMode: .useGlobalSettings,
                        profile: workspaceProfile
                    )
                ],
                scalarPreferences: seededScalarPreferences(modelSelection: .init(
                    preferredComposeModel: tuple.compose,
                    planningModel: tuple.planning,
                    syncChatModelWithOracle: true
                ))
            )
            try fileStore.save(invalidDocument)

            let store = try GlobalSettingsStore(defaults: makeIsolatedDefaults(), fileStore: fileStore)

            XCTAssertEqual(store.planningModelRaw(), tuple.planning)
            XCTAssertEqual(store.preferredComposeModelRaw(), tuple.compose)
            XCTAssertFalse(store.syncChatModelWithOracle())
            let repairedWorkspace = try XCTUnwrap(store.workspaceAgentModelsProfile(for: dormantWorkspaceID))
            XCTAssertEqual(repairedWorkspace.planningModelRaw, tuple.planning)
            XCTAssertEqual(repairedWorkspace.preferredComposeModelRaw, tuple.compose)
            XCTAssertFalse(repairedWorkspace.syncChatModelWithOracle)

            store.setShowDatesInMessageTimestamps(true)

            let saved = try fileStore.load()
            XCTAssertEqual(saved.scalarPreferences?.modelSelection?.planningModel, tuple.planning)
            XCTAssertEqual(saved.scalarPreferences?.modelSelection?.preferredComposeModel, tuple.compose)
            XCTAssertEqual(saved.scalarPreferences?.modelSelection?.syncChatModelWithOracle, false)
            XCTAssertEqual(saved.agentModelsSettings[dormantWorkspaceID]?.inheritanceMode, .useGlobalSettings)
            XCTAssertEqual(saved.agentModelsSettings[dormantWorkspaceID]?.profile?.planningModelRaw, tuple.planning)
            XCTAssertEqual(saved.agentModelsSettings[dormantWorkspaceID]?.profile?.preferredComposeModelRaw, tuple.compose)
            XCTAssertEqual(saved.agentModelsSettings[dormantWorkspaceID]?.profile?.syncChatModelWithOracle, false)

            let bytesAfterUnrelatedSave = try Data(contentsOf: fileURL)
            let reloaded = try GlobalSettingsStore(defaults: makeIsolatedDefaults(), fileStore: fileStore)
            XCTAssertEqual(reloaded.planningModelRaw(), tuple.planning)
            XCTAssertEqual(reloaded.preferredComposeModelRaw(), tuple.compose)
            XCTAssertFalse(reloaded.syncChatModelWithOracle())
            XCTAssertEqual(
                reloaded.workspaceAgentModelsProfile(for: dormantWorkspaceID)?.syncChatModelWithOracle,
                false
            )
            XCTAssertEqual(try Data(contentsOf: fileURL), bytesAfterUnrelatedSave)

            try fileStore.save(invalidDocument)
            XCTAssertTrue(reloaded.reloadFromDisk())
            let repairedAfterReload = try fileStore.load()
            XCTAssertEqual(repairedAfterReload.scalarPreferences?.modelSelection?.planningModel, tuple.planning)
            XCTAssertEqual(repairedAfterReload.scalarPreferences?.modelSelection?.preferredComposeModel, tuple.compose)
            XCTAssertEqual(repairedAfterReload.scalarPreferences?.modelSelection?.syncChatModelWithOracle, false)
            XCTAssertEqual(
                repairedAfterReload.agentModelsSettings[dormantWorkspaceID]?.profile?.syncChatModelWithOracle,
                false
            )
        }
    }

    func testAgentModelsProfilePreservesUnknownContextBuilderProviderAndModelRawValues() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fileStore = GlobalSettingsFileStore(
            fileURL: temp.appendingPathComponent("Settings/globalSettings.json")
        )
        let store = try GlobalSettingsStore(defaults: makeIsolatedDefaults(), fileStore: fileStore)
        let workspaceID = UUID()
        let unknownAgent = "future-agent"
        let unknownModel = "future-model-v9"
        let profile = AgentModelsSettingsProfile(
            contextBuilderAgentRaw: "  \(unknownAgent)  ",
            contextBuilderModelsByAgent: ["  \(unknownAgent)  ": "  \(unknownModel)  "]
        )

        store.setGlobalAgentModelsProfile(
            profile,
            contextBuilderWriteIntent: .preserveExistingOwnership
        )
        store.setWorkspaceAgentModelsProfile(workspaceID: workspaceID, profile: profile)
        store.setShowDatesInMessageTimestamps(true)

        let reloaded = try GlobalSettingsStore(defaults: makeIsolatedDefaults(), fileStore: fileStore)
        XCTAssertEqual(reloaded.globalAgentModelsProfile().contextBuilderAgentRaw, unknownAgent)
        XCTAssertEqual(
            reloaded.globalAgentModelsProfile().contextBuilderModelsByAgent?[unknownAgent],
            unknownModel
        )
        XCTAssertEqual(
            reloaded.workspaceAgentModelsProfile(for: workspaceID)?.contextBuilderAgentRaw,
            unknownAgent
        )
        XCTAssertEqual(
            reloaded.workspaceAgentModelsProfile(for: workspaceID)?.contextBuilderModelsByAgent?[unknownAgent],
            unknownModel
        )
    }

    func testLegacyGlobalAgentModelsBackingWritersPostGlobalNotifications() throws {
        let fileStore = CountingGlobalSettingsFileStore(document: GlobalSettingsDocument(
            globalDefaults: GlobalDefaults(discoverAgentRaw: nil, discoverModelsByAgent: nil),
            scalarPreferences: seededScalarPreferences()
        ))
        let store = try GlobalSettingsStore(defaults: makeIsolatedDefaults(), fileStore: fileStore)
        let recorder = AgentModelsNotificationRecorder(observing: store)
        defer { recorder.invalidate() }

        store.setPlanningModelRaw(AIModel.gpt54Pro.rawValue)
        XCTAssertEqual(recorder.snapshot().count, 1)
        store.setPreferredComposeModelRaw(AIModel.claude4Sonnet.rawValue)
        XCTAssertEqual(recorder.snapshot().count, 2)
        store.setSyncChatModelWithOracle(true)
        XCTAssertEqual(recorder.snapshot().count, 3)
        store.updateGlobalMCPAgentRoleOverrides(["plan": "codexExec:test-model"])
        XCTAssertEqual(recorder.snapshot().count, 4)
        store.setRestrictMCPAgentDiscoveryToRoleLabels(true)
        XCTAssertEqual(recorder.snapshot().count, 5)

        store.setPlanningModelRaw(AIModel.gpt54Pro.rawValue)
        XCTAssertEqual(recorder.snapshot().count, 5)
        store.setPreferredComposeModelRaw(AIModel.gpt54Pro.rawValue)
        XCTAssertEqual(recorder.snapshot().count, 5)
        store.setSyncChatModelWithOracle(true)
        XCTAssertEqual(recorder.snapshot().count, 5)
        store.updateGlobalMCPAgentRoleOverrides(["plan": "codexExec:test-model"])
        XCTAssertEqual(recorder.snapshot().count, 5)
        store.setRestrictMCPAgentDiscoveryToRoleLabels(true)
        XCTAssertEqual(recorder.snapshot().count, 5)

        let notifications = recorder.snapshot()
        XCTAssertEqual(notifications.count, 5)
        XCTAssertTrue(notifications.allSatisfy {
            $0.scope == AgentModelsSettingsNotification.Scope.global.rawValue
                && $0.workspaceID == nil
        })
    }

    func testPromptAgentModelsNotificationRefreshDoesNotWriteBack() async throws {
        let workspaceID = UUID()
        let fileStore = CountingGlobalSettingsFileStore(document: GlobalSettingsDocument(
            copySettings: [workspaceID: CopyGlobalSettings(workspaceID: workspaceID)],
            chatSettings: [workspaceID: ChatGlobalSettings(workspaceID: workspaceID)],
            globalDefaults: GlobalDefaults(discoverAgentRaw: nil, discoverModelsByAgent: nil),
            scalarPreferences: seededScalarPreferences()
        ))
        let store = try GlobalSettingsStore(defaults: makeIsolatedDefaults(), fileStore: fileStore)
        let manager = WindowSettingsManager(windowID: -303, store: store)
        let fileManager = WorkspaceFilesViewModel()
        fileManager.setCurrentWorkspaceID(workspaceID)
        let prompt = PromptViewModel(
            fileManager: fileManager,
            apiSettingsViewModel: makeAPISettingsViewModel(),
            windowID: -303,
            settingsManager: manager
        )
        let originalCopyFileTreeOption = fileStore.document.copySettings[workspaceID]?.fileTreeOption
        let originalChatFileTreeOption = fileStore.document.chatSettings[workspaceID]?.fileTreeOption
        fileStore.saveCount = 0
        let recorder = AgentModelsNotificationRecorder(observing: store)
        defer { recorder.invalidate() }

        store.setGlobalAgentModelsProfile(
            AgentModelsSettingsProfile(planningModelRaw: AIModel.gpt54Pro.rawValue),
            contextBuilderWriteIntent: .preserveExistingOwnership
        )
        await drainMainQueue()

        XCTAssertEqual(fileStore.saveCount, 1)
        XCTAssertEqual(recorder.snapshot().count, 1)
        XCTAssertEqual(fileStore.document.copySettings.count, 1)
        XCTAssertEqual(fileStore.document.chatSettings.count, 1)
        XCTAssertEqual(
            fileStore.document.copySettings[workspaceID]?.fileTreeOption,
            originalCopyFileTreeOption
        )
        XCTAssertEqual(
            fileStore.document.chatSettings[workspaceID]?.fileTreeOption,
            originalChatFileTreeOption
        )
        XCTAssertEqual(prompt.planningModelName, AIModel.gpt54Pro.rawValue)
    }

    func testAgentModelsViewModelDoesNotFallbackUnsyncedBuiltinChatToOracle() async throws {
        let fileStore = CountingGlobalSettingsFileStore(document: GlobalSettingsDocument(
            globalDefaults: GlobalDefaults(discoverAgentRaw: nil, discoverModelsByAgent: nil),
            scalarPreferences: seededScalarPreferences()
        ))
        let store = try GlobalSettingsStore(defaults: makeIsolatedDefaults(), fileStore: fileStore)
        let manager = WindowSettingsManager(windowID: -404, store: store)
        store.setGlobalAgentModelsProfile(
            AgentModelsSettingsProfile(
                planningModelRaw: AIModel.gpt54Pro.rawValue,
                preferredComposeModelRaw: nil,
                syncChatModelWithOracle: false
            ),
            contextBuilderWriteIntent: .preserveExistingOwnership
        )
        let viewModel = AgentModelsSettingsViewModel(
            apiSettingsVM: makeAPISettingsViewModel(),
            settingsManager: manager,
            settingsStore: store
        )

        XCTAssertEqual(viewModel.currentBuiltinChatModelName, "Select a Built-in Chat model")

        store.setGlobalAgentModelsProfile(
            AgentModelsSettingsProfile(
                planningModelRaw: AIModel.gpt54Pro.rawValue,
                preferredComposeModelRaw: AIModel.gpt54Pro.rawValue,
                syncChatModelWithOracle: true
            ),
            contextBuilderWriteIntent: .preserveExistingOwnership
        )
        await drainMainQueue()

        XCTAssertEqual(viewModel.currentBuiltinChatModelName, AIModel.gpt54Pro.displayName)
    }

    func testAgentModelsViewModelClearingSynchronizedModelDisablesSyncWithoutClearingSibling() throws {
        let fileStore = CountingGlobalSettingsFileStore(document: GlobalSettingsDocument(
            globalDefaults: GlobalDefaults(discoverAgentRaw: nil, discoverModelsByAgent: nil),
            scalarPreferences: seededScalarPreferences()
        ))
        let store = try GlobalSettingsStore(defaults: makeIsolatedDefaults(), fileStore: fileStore)
        let manager = WindowSettingsManager(windowID: -405, store: store)
        let blankRaw = " \n\t "

        store.setGlobalAgentModelsProfile(
            AgentModelsSettingsProfile(
                planningModelRaw: AIModel.gpt54Pro.rawValue,
                preferredComposeModelRaw: AIModel.gpt54Pro.rawValue,
                syncChatModelWithOracle: true
            ),
            contextBuilderWriteIntent: .preserveExistingOwnership
        )
        let globalViewModel = AgentModelsSettingsViewModel(
            apiSettingsVM: makeAPISettingsViewModel(),
            settingsManager: manager,
            settingsStore: store
        )

        globalViewModel.setBuiltinChatModel(raw: blankRaw)

        XCTAssertEqual(store.globalAgentModelsProfile().planningModelRaw, AIModel.gpt54Pro.rawValue)
        XCTAssertNil(store.globalAgentModelsProfile().preferredComposeModelRaw)
        XCTAssertFalse(store.globalAgentModelsProfile().syncChatModelWithOracle)

        store.setGlobalAgentModelsProfile(
            AgentModelsSettingsProfile(
                planningModelRaw: AIModel.gpt54Pro.rawValue,
                preferredComposeModelRaw: AIModel.gpt54Pro.rawValue,
                syncChatModelWithOracle: true
            ),
            contextBuilderWriteIntent: .preserveExistingOwnership
        )
        let globalOracleViewModel = AgentModelsSettingsViewModel(
            apiSettingsVM: makeAPISettingsViewModel(),
            settingsManager: manager,
            settingsStore: store
        )
        globalOracleViewModel.setOracleModel(raw: blankRaw)
        XCTAssertNil(store.globalAgentModelsProfile().planningModelRaw)
        XCTAssertEqual(store.globalAgentModelsProfile().preferredComposeModelRaw, AIModel.gpt54Pro.rawValue)
        XCTAssertFalse(store.globalAgentModelsProfile().syncChatModelWithOracle)

        let workspaceID = UUID()
        store.setWorkspaceAgentModelsProfile(
            workspaceID: workspaceID,
            profile: AgentModelsSettingsProfile(
                planningModelRaw: AIModel.gpt54Pro.rawValue,
                preferredComposeModelRaw: AIModel.gpt54Pro.rawValue,
                syncChatModelWithOracle: true
            )
        )
        let workspaceViewModel = AgentModelsSettingsViewModel(
            apiSettingsVM: makeAPISettingsViewModel(),
            workspaceID: workspaceID,
            workspaceName: "Scoped blank guard",
            settingsManager: manager,
            settingsStore: store
        )

        workspaceViewModel.setBuiltinChatModel(raw: blankRaw)

        XCTAssertEqual(
            store.workspaceAgentModelsProfile(for: workspaceID)?.planningModelRaw,
            AIModel.gpt54Pro.rawValue
        )
        XCTAssertNil(store.workspaceAgentModelsProfile(for: workspaceID)?.preferredComposeModelRaw)
        XCTAssertEqual(store.workspaceAgentModelsProfile(for: workspaceID)?.syncChatModelWithOracle, false)

        store.setWorkspaceAgentModelsProfile(
            workspaceID: workspaceID,
            profile: AgentModelsSettingsProfile(
                planningModelRaw: AIModel.gpt54Pro.rawValue,
                preferredComposeModelRaw: AIModel.gpt54Pro.rawValue,
                syncChatModelWithOracle: true
            )
        )
        let workspaceOracleViewModel = AgentModelsSettingsViewModel(
            apiSettingsVM: makeAPISettingsViewModel(),
            workspaceID: workspaceID,
            workspaceName: "Scoped blank guard",
            settingsManager: manager,
            settingsStore: store
        )
        workspaceOracleViewModel.setOracleModel(raw: blankRaw)
        XCTAssertNil(store.workspaceAgentModelsProfile(for: workspaceID)?.planningModelRaw)
        XCTAssertEqual(
            store.workspaceAgentModelsProfile(for: workspaceID)?.preferredComposeModelRaw,
            AIModel.gpt54Pro.rawValue
        )
        XCTAssertEqual(store.workspaceAgentModelsProfile(for: workspaceID)?.syncChatModelWithOracle, false)
    }

    func testAgentModelsViewModelRejectsSyncWhenOracleModelIsBlank() throws {
        let fileStore = CountingGlobalSettingsFileStore(document: GlobalSettingsDocument(
            globalDefaults: GlobalDefaults(discoverAgentRaw: nil, discoverModelsByAgent: nil),
            scalarPreferences: seededScalarPreferences()
        ))
        let store = try GlobalSettingsStore(defaults: makeIsolatedDefaults(), fileStore: fileStore)
        let manager = WindowSettingsManager(windowID: -406, store: store)
        let globalViewModel = AgentModelsSettingsViewModel(
            apiSettingsVM: makeAPISettingsViewModel(),
            settingsManager: manager,
            settingsStore: store
        )

        globalViewModel.syncChatWithOracle = true

        XCTAssertFalse(globalViewModel.syncChatWithOracle)
        XCTAssertFalse(store.globalAgentModelsProfile().syncChatModelWithOracle)

        let workspaceID = UUID()
        store.setWorkspaceAgentModelsProfile(
            workspaceID: workspaceID,
            profile: AgentModelsSettingsProfile(preferredComposeModelRaw: AIModel.gpt54Pro.rawValue)
        )
        let workspaceViewModel = AgentModelsSettingsViewModel(
            apiSettingsVM: makeAPISettingsViewModel(),
            workspaceID: workspaceID,
            workspaceName: "Blank Oracle",
            settingsManager: manager,
            settingsStore: store
        )

        workspaceViewModel.syncChatWithOracle = true

        XCTAssertFalse(workspaceViewModel.syncChatWithOracle)
        XCTAssertEqual(store.workspaceAgentModelsProfile(for: workspaceID)?.syncChatModelWithOracle, false)
    }

    func testDurableAgentModelsSettersDisableEveryInvalidSynchronizedTuple() throws {
        let fileStore = CountingGlobalSettingsFileStore(document: GlobalSettingsDocument(
            globalDefaults: GlobalDefaults(discoverAgentRaw: nil, discoverModelsByAgent: nil),
            scalarPreferences: seededScalarPreferences()
        ))
        var assertionMessages: [String] = []
        let store = try GlobalSettingsStore(
            defaults: makeIsolatedDefaults(),
            fileStore: fileStore,
            invalidAgentModelsProfileAssertion: { assertionMessages.append($0) }
        )
        let workspaceID = UUID()
        let invalidProfiles = [
            AgentModelsSettingsProfile(syncChatModelWithOracle: true),
            AgentModelsSettingsProfile(
                planningModelRaw: AIModel.gpt54Pro.rawValue,
                syncChatModelWithOracle: true
            ),
            AgentModelsSettingsProfile(
                planningModelRaw: AIModel.gpt54Pro.rawValue,
                preferredComposeModelRaw: AIModel.claude4Sonnet.rawValue,
                syncChatModelWithOracle: true
            )
        ]

        for profile in invalidProfiles {
            store.setGlobalAgentModelsProfile(
                profile,
                contextBuilderWriteIntent: .preserveExistingOwnership
            )
            XCTAssertEqual(store.globalAgentModelsProfile().planningModelRaw, profile.planningModelRaw)
            XCTAssertEqual(
                store.globalAgentModelsProfile().preferredComposeModelRaw,
                profile.preferredComposeModelRaw
            )
            XCTAssertFalse(store.globalAgentModelsProfile().syncChatModelWithOracle)

            store.setWorkspaceAgentModelsProfile(workspaceID: workspaceID, profile: profile)
            XCTAssertEqual(
                store.workspaceAgentModelsProfile(for: workspaceID)?.planningModelRaw,
                profile.planningModelRaw
            )
            XCTAssertEqual(
                store.workspaceAgentModelsProfile(for: workspaceID)?.preferredComposeModelRaw,
                profile.preferredComposeModelRaw
            )
            XCTAssertEqual(
                store.workspaceAgentModelsProfile(for: workspaceID)?.syncChatModelWithOracle,
                false
            )
        }

        let diagnostics = store.recentSettingsWriteDiagnostics()
        XCTAssertEqual(
            diagnostics.map(\.reason),
            ["both_blank", "both_blank", "one_blank", "one_blank", "divergent", "divergent"]
                .map { "agent_models.profile.invalid_sync.\($0)" }
        )
        XCTAssertEqual(assertionMessages.count, 6)
        for reason in ["both_blank", "one_blank", "divergent"] {
            XCTAssertEqual(assertionMessages.count(where: { $0.contains(reason) }), 2)
        }
    }

    func testLegacyScalarModelSettersPreserveSiblingAndRejectInvalidSync() throws {
        let fileStore = CountingGlobalSettingsFileStore(document: GlobalSettingsDocument(
            globalDefaults: GlobalDefaults(discoverAgentRaw: nil, discoverModelsByAgent: nil),
            scalarPreferences: seededScalarPreferences()
        ))
        let store = try GlobalSettingsStore(defaults: makeIsolatedDefaults(), fileStore: fileStore)
        let model = AIModel.gpt54Pro.rawValue
        let synchronized = AgentModelsSettingsProfile(
            planningModelRaw: model,
            preferredComposeModelRaw: model,
            syncChatModelWithOracle: true
        )

        store.setGlobalAgentModelsProfile(
            synchronized,
            contextBuilderWriteIntent: .preserveExistingOwnership
        )
        store.setPreferredComposeModelRaw(nil, honorSync: true)
        XCTAssertEqual(store.planningModelRaw(), model)
        XCTAssertNil(store.preferredComposeModelRaw())
        XCTAssertFalse(store.syncChatModelWithOracle())

        store.setGlobalAgentModelsProfile(
            synchronized,
            contextBuilderWriteIntent: .preserveExistingOwnership
        )
        store.setPlanningModelRaw(nil, honorSync: true)
        XCTAssertNil(store.planningModelRaw())
        XCTAssertEqual(store.preferredComposeModelRaw(), model)
        XCTAssertFalse(store.syncChatModelWithOracle())

        store.setSyncChatModelWithOracle(true)
        XCTAssertFalse(store.syncChatModelWithOracle())
        XCTAssertEqual(
            fileStore.document.scalarPreferences?.modelSelection?.syncChatModelWithOracle,
            false
        )
    }

    func testAgentModelsGlobalProfileRoundTripsExistingFieldsWithOneSaveAndNotification() throws {
        let fileStore = CountingGlobalSettingsFileStore(document: GlobalSettingsDocument(
            globalDefaults: GlobalDefaults(discoverAgentRaw: nil, discoverModelsByAgent: nil),
            scalarPreferences: seededScalarPreferences()
        ))
        let store = try GlobalSettingsStore(defaults: makeIsolatedDefaults(), fileStore: fileStore)
        fileStore.saveCount = 0
        let recorder = AgentModelsNotificationRecorder(observing: store)
        defer { recorder.invalidate() }
        let codexAgent = AgentProviderKind.codexExec.rawValue
        let profile = AgentModelsSettingsProfile(
            planningModelRaw: " \(AIModel.gpt54Pro.rawValue) ",
            preferredComposeModelRaw: " \(AIModel.claude4Sonnet.rawValue) ",
            syncChatModelWithOracle: false,
            contextBuilderAgentRaw: codexAgent,
            contextBuilderModelsByAgent: [codexAgent: AgentModelCatalog.defaultModelRaw(for: .codexExec)],
            mcpAgentRoleOverrides: [" plan ": " codexExec:test-model "],
            restrictMCPAgentDiscoveryToRoleLabels: true
        )

        store.setGlobalAgentModelsProfile(
            profile,
            contextBuilderWriteIntent: .preserveExistingOwnership
        )

        let expected = AgentModelsSettingsProfile(
            planningModelRaw: AIModel.gpt54Pro.rawValue,
            preferredComposeModelRaw: AIModel.claude4Sonnet.rawValue,
            syncChatModelWithOracle: false,
            contextBuilderAgentRaw: codexAgent,
            contextBuilderModelsByAgent: [codexAgent: AgentModelCatalog.defaultModelRaw(for: .codexExec)],
            mcpAgentRoleOverrides: ["plan": "codexExec:test-model"],
            restrictMCPAgentDiscoveryToRoleLabels: true
        )
        XCTAssertEqual(fileStore.saveCount, 1)
        let notifications = recorder.snapshot()
        XCTAssertEqual(notifications.count, 1)
        XCTAssertEqual(notifications.first?.scope, AgentModelsSettingsNotification.Scope.global.rawValue)
        XCTAssertNil(notifications.first?.workspaceID)
        XCTAssertEqual(store.globalAgentModelsProfile(), expected)
        let diagnostic = try XCTUnwrap(store.recentSettingsWriteDiagnostics().last)
        XCTAssertEqual(diagnostic.key, "agentModelsProfile.global")
        XCTAssertEqual(diagnostic.reason, "agent_models.profile.global")
        XCTAssertTrue(diagnostic.newValue?.contains("planning=\(AIModel.gpt54Pro.rawValue)") == true)
        XCTAssertEqual(fileStore.document.scalarPreferences?.modelSelection?.planningModel, expected.planningModelRaw)
        XCTAssertEqual(fileStore.document.scalarPreferences?.modelSelection?.preferredComposeModel, expected.preferredComposeModelRaw)
        XCTAssertEqual(fileStore.document.scalarPreferences?.modelSelection?.syncChatModelWithOracle, false)
        XCTAssertEqual(fileStore.document.scalarPreferences?.agentMode?.restrictMCPAgentDiscoveryToRoleLabels, true)
        XCTAssertEqual(fileStore.document.globalDefaults.discoverAgentRaw, codexAgent)
        XCTAssertEqual(fileStore.document.globalDefaults.discoverModelsByAgent, expected.contextBuilderModelsByAgent)
        XCTAssertEqual(fileStore.document.globalDefaults.mcpAgentRoleOverrides, expected.mcpAgentRoleOverrides)
    }

    func testLegacyGlobalContextBuilderSetterPostsAgentModelsNotification() throws {
        let fileStore = CountingGlobalSettingsFileStore(document: GlobalSettingsDocument(
            globalDefaults: GlobalDefaults(discoverAgentRaw: nil, discoverModelsByAgent: nil),
            scalarPreferences: seededScalarPreferences()
        ))
        let store = try GlobalSettingsStore(defaults: makeIsolatedDefaults(), fileStore: fileStore)
        fileStore.saveCount = 0
        let recorder = AgentModelsNotificationRecorder(observing: store)
        defer { recorder.invalidate() }
        let codexAgent = AgentProviderKind.codexExec.rawValue
        let codexModel = AgentModelCatalog.defaultModelRaw(for: .codexExec)

        store.setGlobalContextBuilderAgentSelection(
            agentRaw: codexAgent,
            modelRaw: codexModel,
            markUserDefined: true
        )

        var notifications = recorder.snapshot()
        XCTAssertEqual(fileStore.saveCount, 1)
        XCTAssertEqual(notifications.count, 1)
        XCTAssertEqual(notifications.last?.scope, AgentModelsSettingsNotification.Scope.global.rawValue)
        XCTAssertNil(notifications.last?.workspaceID)
        XCTAssertEqual(store.globalAgentModelsProfile().contextBuilderAgentRaw, codexAgent)
        XCTAssertEqual(store.globalAgentModelsProfile().contextBuilderModelsByAgent?[codexAgent], codexModel)

        store.setGlobalContextBuilderAgentSelection(
            agentRaw: AgentProviderKind.claudeCode.rawValue,
            modelRaw: String?.none,
            markUserDefined: true
        )

        notifications = recorder.snapshot()
        XCTAssertEqual(fileStore.saveCount, 2)
        XCTAssertEqual(notifications.count, 2)
        XCTAssertEqual(notifications.last?.scope, AgentModelsSettingsNotification.Scope.global.rawValue)
        XCTAssertNil(notifications.last?.workspaceID)
        XCTAssertEqual(store.globalAgentModelsProfile().contextBuilderAgentRaw, AgentProviderKind.claudeCode.rawValue)
    }

    func testAgentModelsWorkspaceOverrideMaterializesAndCopiesGlobalToWorkspace() throws {
        let fileStore = CountingGlobalSettingsFileStore(document: GlobalSettingsDocument(
            globalDefaults: GlobalDefaults(discoverAgentRaw: nil, discoverModelsByAgent: nil),
            scalarPreferences: seededScalarPreferences()
        ))
        let store = try GlobalSettingsStore(defaults: makeIsolatedDefaults(), fileStore: fileStore)
        let workspaceID = UUID()
        let globalProfile = AgentModelsSettingsProfile(
            planningModelRaw: AIModel.gpt54Pro.rawValue,
            preferredComposeModelRaw: AIModel.gpt54Pro.rawValue,
            syncChatModelWithOracle: true,
            contextBuilderAgentRaw: AgentProviderKind.claudeCode.rawValue,
            contextBuilderModelsByAgent: [
                AgentProviderKind.claudeCode.rawValue: AgentModelCatalog.defaultModelRaw(for: .claudeCode)
            ],
            mcpAgentRoleOverrides: ["code": "claudeCode:sonnet"],
            restrictMCPAgentDiscoveryToRoleLabels: true
        )
        store.setGlobalAgentModelsProfile(
            globalProfile,
            contextBuilderWriteIntent: .preserveExistingOwnership
        )
        fileStore.saveCount = 0
        let recorder = AgentModelsNotificationRecorder(observing: store)
        defer { recorder.invalidate() }

        store.setWorkspaceAgentModelsInheritanceMode(workspaceID: workspaceID, mode: .useWorkspaceOverrides)

        XCTAssertEqual(fileStore.saveCount, 1)
        XCTAssertEqual(recorder.snapshot().count, 1)
        XCTAssertEqual(
            store.workspaceAgentModelsSettings(for: workspaceID),
            WorkspaceAgentModelsSettings(inheritanceMode: .useWorkspaceOverrides, profile: globalProfile)
        )
        XCTAssertEqual(store.effectiveAgentModelsProfile(workspaceID: workspaceID), globalProfile)
        let diagnostic = try XCTUnwrap(store.recentSettingsWriteDiagnostics().last)
        XCTAssertEqual(diagnostic.key, "agentModelsProfile.workspace.\(workspaceID.uuidString)")
        XCTAssertEqual(diagnostic.reason, "agent_models.profile.workspace")

        let secondWorkspaceID = UUID()
        store.copyAgentModelsProfile(from: .global, to: .workspace(secondWorkspaceID))
        XCTAssertEqual(
            store.workspaceAgentModelsSettings(for: secondWorkspaceID),
            WorkspaceAgentModelsSettings(inheritanceMode: .useWorkspaceOverrides, profile: globalProfile)
        )
    }

    func testAgentModelsCopyWorkspaceToGlobalOverwritesContextBuilderModelMap() throws {
        let fileStore = CountingGlobalSettingsFileStore(document: GlobalSettingsDocument(
            globalDefaults: GlobalDefaults(discoverAgentRaw: nil, discoverModelsByAgent: nil),
            scalarPreferences: seededScalarPreferences()
        ))
        let store = try GlobalSettingsStore(defaults: makeIsolatedDefaults(), fileStore: fileStore)
        let workspaceID = UUID()
        let codexAgent = AgentProviderKind.codexExec.rawValue
        let claudeAgent = AgentProviderKind.claudeCode.rawValue
        store.setGlobalAgentModelsProfile(AgentModelsSettingsProfile(
            planningModelRaw: AIModel.claude4Sonnet.rawValue,
            preferredComposeModelRaw: AIModel.claude4Sonnet.rawValue,
            syncChatModelWithOracle: true,
            contextBuilderAgentRaw: codexAgent,
            contextBuilderModelsByAgent: [codexAgent: AgentModelCatalog.defaultModelRaw(for: .codexExec)],
            mcpAgentRoleOverrides: ["old": "codexExec:old"],
            restrictMCPAgentDiscoveryToRoleLabels: false
        ), contextBuilderWriteIntent: .preserveExistingOwnership)
        let workspaceProfile = AgentModelsSettingsProfile(
            planningModelRaw: AIModel.gpt54Pro.rawValue,
            preferredComposeModelRaw: nil,
            syncChatModelWithOracle: false,
            contextBuilderAgentRaw: claudeAgent,
            contextBuilderModelsByAgent: [claudeAgent: AgentModelCatalog.defaultModelRaw(for: .claudeCode)],
            mcpAgentRoleOverrides: ["new": "claudeCode:new"],
            restrictMCPAgentDiscoveryToRoleLabels: true
        )
        store.setWorkspaceAgentModelsProfile(workspaceID: workspaceID, profile: workspaceProfile)
        store.setWorkspaceAgentModelsInheritanceMode(workspaceID: workspaceID, mode: .useWorkspaceOverrides)
        fileStore.saveCount = 0
        let recorder = AgentModelsNotificationRecorder(observing: store)
        defer { recorder.invalidate() }

        store.copyAgentModelsProfile(from: .workspace(workspaceID), to: .global)

        XCTAssertEqual(fileStore.saveCount, 1)
        let notifications = recorder.snapshot()
        XCTAssertEqual(notifications.count, 1)
        XCTAssertEqual(notifications.first?.scope, AgentModelsSettingsNotification.Scope.global.rawValue)
        XCTAssertEqual(store.globalAgentModelsProfile(), workspaceProfile)
        XCTAssertEqual(fileStore.document.globalDefaults.discoverModelsByAgent, workspaceProfile.contextBuilderModelsByAgent)
        XCTAssertNil(fileStore.document.globalDefaults.discoverModelsByAgent?[codexAgent])
        XCTAssertEqual(fileStore.document.globalDefaults.mcpAgentRoleOverrides, workspaceProfile.mcpAgentRoleOverrides)
        XCTAssertTrue(store.hasUserSetGlobalContextBuilderAgentDefaults)
    }

    func testAgentModelsWindowSettingsManagerBoundaryRoutesScopedWritesAndCopies() throws {
        let fileStore = CountingGlobalSettingsFileStore(document: GlobalSettingsDocument(
            globalDefaults: GlobalDefaults(discoverAgentRaw: nil, discoverModelsByAgent: nil),
            scalarPreferences: seededScalarPreferences()
        ))
        let store = try GlobalSettingsStore(defaults: makeIsolatedDefaults(), fileStore: fileStore)
        let manager = WindowSettingsManager(windowID: -101, store: store)
        let workspaceID = UUID()
        let globalProfile = AgentModelsSettingsProfile(
            planningModelRaw: AIModel.claude4Sonnet.rawValue,
            preferredComposeModelRaw: AIModel.claude4Sonnet.rawValue,
            syncChatModelWithOracle: true
        )
        let workspaceProfile = AgentModelsSettingsProfile(
            planningModelRaw: AIModel.gpt54Pro.rawValue,
            preferredComposeModelRaw: AIModel.gpt54Pro.rawValue,
            syncChatModelWithOracle: false,
            contextBuilderAgentRaw: AgentProviderKind.claudeCode.rawValue,
            contextBuilderModelsByAgent: [
                AgentProviderKind.claudeCode.rawValue: AgentModelCatalog.defaultModelRaw(for: .claudeCode)
            ]
        )
        let recorder = AgentModelsNotificationRecorder(observing: store)
        defer { recorder.invalidate() }

        manager.setGlobalAgentModelsProfile(
            globalProfile,
            contextBuilderWriteIntent: .preserveExistingOwnership
        )
        manager.setWorkspaceAgentModelsProfile(workspaceID: workspaceID, profile: workspaceProfile)

        XCTAssertEqual(store.globalAgentModelsProfile(), globalProfile)
        XCTAssertEqual(manager.workspaceAgentModelsProfile(for: workspaceID), workspaceProfile)
        XCTAssertEqual(store.workspaceAgentModelsProfile(for: workspaceID), workspaceProfile)

        manager.copyAgentModelsProfile(from: .workspace(workspaceID), to: .global)

        XCTAssertEqual(store.globalAgentModelsProfile(), manager.workspaceAgentModelsProfile(for: workspaceID))
        let notifications = recorder.snapshot()
        XCTAssertTrue(notifications.contains { $0.scope == AgentModelsSettingsNotification.Scope.global.rawValue })
        XCTAssertTrue(notifications.contains { entry in
            entry.scope == AgentModelsSettingsNotification.Scope.workspace.rawValue && entry.workspaceID == workspaceID
        })
    }

    func testAgentModelsViewModelUsesInjectedSettingsManagerForScopedReadsWritesCopiesAndNotifications() async throws {
        let managerFileStore = CountingGlobalSettingsFileStore(document: GlobalSettingsDocument(
            globalDefaults: GlobalDefaults(discoverAgentRaw: nil, discoverModelsByAgent: nil),
            scalarPreferences: seededScalarPreferences()
        ))
        let managerStore = try GlobalSettingsStore(defaults: makeIsolatedDefaults(), fileStore: managerFileStore)
        let engineStore = try GlobalSettingsStore(
            defaults: makeIsolatedDefaults(),
            fileStore: CountingGlobalSettingsFileStore(document: GlobalSettingsDocument(
                globalDefaults: GlobalDefaults(discoverAgentRaw: nil, discoverModelsByAgent: nil),
                scalarPreferences: seededScalarPreferences()
            ))
        )
        let manager = WindowSettingsManager(windowID: -202, store: managerStore)
        let workspaceID = UUID()
        let globalProfile = AgentModelsSettingsProfile(
            planningModelRaw: AIModel.claude4Sonnet.rawValue,
            preferredComposeModelRaw: AIModel.claude4Sonnet.rawValue,
            syncChatModelWithOracle: true
        )
        var workspaceProfile = AgentModelsSettingsProfile(
            planningModelRaw: AIModel.claude4Sonnet.rawValue,
            preferredComposeModelRaw: AIModel.claude4Sonnet.rawValue,
            syncChatModelWithOracle: false,
            contextBuilderAgentRaw: AgentProviderKind.claudeCode.rawValue,
            contextBuilderModelsByAgent: [
                AgentProviderKind.claudeCode.rawValue: AgentModelCatalog.defaultModelRaw(for: .claudeCode)
            ]
        )
        manager.setGlobalAgentModelsProfile(
            globalProfile,
            contextBuilderWriteIntent: .preserveExistingOwnership
        )
        manager.setWorkspaceAgentModelsProfile(workspaceID: workspaceID, profile: workspaceProfile)
        manager.setWorkspaceAgentModelsInheritanceMode(workspaceID: workspaceID, mode: .useWorkspaceOverrides)
        let engineWorkspaceProfile = AgentModelsSettingsProfile(
            planningModelRaw: AIModel.gpt54Pro.rawValue,
            preferredComposeModelRaw: AIModel.gpt54Pro.rawValue,
            syncChatModelWithOracle: false
        )
        engineStore.setWorkspaceAgentModelsProfile(
            workspaceID: workspaceID,
            profile: engineWorkspaceProfile
        )

        let apiSettings = makeAPISettingsViewModel()
        apiSettings.isOpenAIKeyValid = true
        let viewModel = AgentModelsSettingsViewModel(
            apiSettingsVM: apiSettings,
            workspaceID: workspaceID,
            workspaceName: "Scoped test",
            settingsManager: manager,
            settingsStore: engineStore
        )

        XCTAssertTrue(viewModel.isEditingWorkspaceSettings)
        XCTAssertEqual(viewModel.profileSnapshot.planningModelRaw, workspaceProfile.planningModelRaw)
        XCTAssertFalse(
            viewModel.isOracleRecommendationSatisfied,
            "Recommendation satisfaction must read the injected manager profile, not the engine store."
        )

        viewModel.setOracleModel(raw: AIModel.codexCliGpt56SolHigh.rawValue)

        XCTAssertEqual(
            managerStore.workspaceAgentModelsProfile(for: workspaceID)?.planningModelRaw,
            AIModel.codexCliGpt56SolHigh.rawValue
        )
        XCTAssertEqual(
            engineStore.workspaceAgentModelsProfile(for: workspaceID),
            engineWorkspaceProfile,
            "Scoped writes must route through the injected SettingsManaging boundary, not the engine/global store."
        )
        XCTAssertEqual(managerStore.globalAgentModelsProfile(), globalProfile)

        viewModel.applyOracleRecommendation()

        XCTAssertEqual(
            managerStore.workspaceAgentModelsProfile(for: workspaceID)?.planningModelRaw,
            AIModel.gpt54Pro.rawValue
        )
        XCTAssertEqual(
            engineStore.workspaceAgentModelsProfile(for: workspaceID),
            engineWorkspaceProfile,
            "Recommendation apply must also route scoped Agent Models writes through the injected SettingsManaging boundary."
        )

        workspaceProfile.planningModelRaw = AIModel.claude4Opus.rawValue
        manager.setWorkspaceAgentModelsProfile(workspaceID: workspaceID, profile: workspaceProfile)
        await drainMainQueue()

        XCTAssertEqual(viewModel.profileSnapshot.planningModelRaw, AIModel.claude4Opus.rawValue)

        viewModel.copyWorkspaceSettingsToGlobal()

        XCTAssertEqual(managerStore.globalAgentModelsProfile(), workspaceProfile)
        XCTAssertNotEqual(engineStore.globalAgentModelsProfile(), workspaceProfile)
    }

    func testAgentModelsViewModelReportsStoredRecommendedRolePinAsOverrideAndClearsIt() throws {
        let fileStore = CountingGlobalSettingsFileStore(document: GlobalSettingsDocument(
            globalDefaults: GlobalDefaults(discoverAgentRaw: nil, discoverModelsByAgent: nil),
            scalarPreferences: seededScalarPreferences()
        ))
        let store = try GlobalSettingsStore(defaults: makeIsolatedDefaults(), fileStore: fileStore)
        let manager = WindowSettingsManager(windowID: -203, store: store)
        let workspaceID = UUID()
        let role = AgentModelCatalog.TaskLabelKind.explore
        let availability = AgentModelCatalog.AvailabilityContext(
            claudeCodeAvailable: false,
            codexAvailable: true,
            openCodeAvailable: false,
            cursorAvailable: false,
            zaiConfigured: false,
            kimiConfigured: false,
            customClaudeCompatibleConfigured: false
        )
        let baselineResolution = try XCTUnwrap(MCPAgentRoleDefaultsService.effectiveSelection(
            for: role,
            availability: availability,
            recommendedAvailability: availability,
            settingsStore: AgentModelsProfileRoleDefaultsStore(overrides: nil)
        ))
        let recommendedPin = AgentModelSelectionID(
            agentRaw: baselineResolution.recommended.agent.rawValue,
            modelRaw: baselineResolution.recommended.modelRaw
        ).rawValue
        let workspaceProfile = AgentModelsSettingsProfile(
            planningModelRaw: AIModel.claude4Sonnet.rawValue,
            preferredComposeModelRaw: AIModel.claude4Sonnet.rawValue,
            syncChatModelWithOracle: true,
            mcpAgentRoleOverrides: [role.rawValue: recommendedPin]
        )
        manager.setWorkspaceAgentModelsProfile(workspaceID: workspaceID, profile: workspaceProfile)
        manager.setWorkspaceAgentModelsInheritanceMode(workspaceID: workspaceID, mode: .useWorkspaceOverrides)

        let apiSettings = makeAPISettingsViewModel()
        apiSettings.isClaudeCodeConnected = false
        apiSettings.isCodexConnected = true
        apiSettings.isOpenCodeConnected = false
        apiSettings.isCursorConnected = false
        let viewModel = AgentModelsSettingsViewModel(
            apiSettingsVM: apiSettings,
            workspaceID: workspaceID,
            workspaceName: "Pinned role defaults",
            settingsManager: manager,
            settingsStore: store
        )

        let pinnedResolution = try XCTUnwrap(viewModel.roleDefaultsResolutions.first { $0.role == role })
        XCTAssertEqual(pinnedResolution.effective, pinnedResolution.recommended)
        XCTAssertTrue(pinnedResolution.hasStoredOverride)
        XCTAssertFalse(pinnedResolution.hasCustomOverride)
        XCTAssertTrue(viewModel.roleDefaultsHasOverrides)

        viewModel.applyRoleDefault(pinnedResolution)

        XCTAssertNil(viewModel.profileSnapshot.mcpAgentRoleOverrides)
        XCTAssertNil(store.workspaceAgentModelsProfile(for: workspaceID)?.mcpAgentRoleOverrides)
        let clearedResolution = try XCTUnwrap(viewModel.roleDefaultsResolutions.first { $0.role == role })
        XCTAssertFalse(clearedResolution.hasStoredOverride)
        XCTAssertFalse(clearedResolution.hasCustomOverride)
        XCTAssertFalse(viewModel.roleDefaultsHasOverrides)
    }

    private func makeAPISettingsViewModel() -> APISettingsViewModel {
        let keyManager = KeyManager(
            secureService: SecureKeysService(secureStorage: TestSecureStorageBackend())
        )
        return APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keyManager),
            keyManager: keyManager,
            loadStoredDataOnInit: false
        )
    }

    private func drainMainQueue() async {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async {
            drained.fulfill()
        }
        await fulfillment(of: [drained], timeout: 1.0)
    }

    private var lineagedBaselineJSON: String {
        #"{"schemaVersion":2,"schemaLineage":"repoprompt-ce.global-settings","updatedAt":"2026-05-20T00:00:00Z","copySettingsByWorkspaceID":{},"chatSettingsByWorkspaceID":{},"globalDefaults":{},"scalarPreferences":{}}"#
    }

    private func falseV4JSON(includeEmptyAgentModelsObject: Bool) -> String {
        let agentModels = includeEmptyAgentModelsObject
            ? #","agentModelsSettingsByWorkspaceID":{}"#
            : ""
        return """
        {
          "schemaVersion": 4,
          "schemaLineage": "repoprompt-ce.global-settings",
          "updatedAt": "2026-05-20T00:00:00Z",
          "copySettingsByWorkspaceID": {},
          "chatSettingsByWorkspaceID": {},
          "globalDefaults": {
            "discoverAgentRaw": "codexExec",
            "discoverModelsByAgent": {"codexExec": "gpt-5.2-codex"},
            "unknownNested": {"keep": [1, true, "value"]}
          },
          "scalarPreferences": {
            "ui": {"appearanceMode": "Dark", "showTooltips": true},
            "promptPackaging": {"modelTemperature": 0.25},
            "unknownGroup": {"future": "preserve"}
          },
          "unknownRoot": {"preserve": 42}
          \(agentModels)
        }
        """
    }

    private func falseV4JSON(rawAgentModelsValue: String) -> String {
        falseV4JSON(includeEmptyAgentModelsObject: false).replacingOccurrences(
            of: #""unknownRoot": {"preserve": 42}"#,
            with: #""agentModelsSettingsByWorkspaceID": \#(rawAgentModelsValue), "unknownRoot": {"preserve": 42}"#
        )
    }

    private func falseV4Backups(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("globalSettings.false-v4-") }
    }

    private func makeBlockedStore(
        json: String,
        defaults: UserDefaults? = nil
    ) throws -> (GlobalSettingsStore, URL) {
        let temp = try makeTempDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: fileURL)
        let defaults = try defaults ?? makeIsolatedDefaults()
        return (GlobalSettingsStore(defaults: defaults, fileStore: GlobalSettingsFileStore(fileURL: fileURL)), fileURL)
    }

    private func makeIsolatedDefaults() throws -> UserDefaults {
        let suiteName = "SettingsJSONOnlyPersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func seededScalarPreferences(
        ui: GlobalScalarPreferences.UISettings? = nil,
        modelSelection: GlobalScalarPreferences.ModelSelectionSettings? = nil,
        agentMode: GlobalScalarPreferences.AgentModeSettings? = nil
    ) -> GlobalScalarPreferences {
        GlobalScalarPreferences(
            ui: ui,
            modelSelection: modelSelection,
            fileSystem: .init(globalIgnoreDefaults: IgnoreSettingsDefaults.canonicalGlobalIgnoreDefaults),
            agentMode: agentMode
        )
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SettingsJSONOnlyPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testTierCleanupNormalizesAllAgentModelsProfilesInOneSaveAndNotifiesExactScopes() throws {
        let workspaceID = UUID()
        let tierRaw = AIModel.openAIServiceTierVariant(base: .gpt54Pro, tier: "flex").rawValue
        let tierSelectionRaw = AgentModelSelectionID(
            agentRaw: AgentProviderKind.codexExec.rawValue,
            modelRaw: tierRaw
        ).rawValue
        let normalizedSelectionRaw = AgentModelSelectionID(
            agentRaw: AgentProviderKind.codexExec.rawValue,
            modelRaw: AIModel.gpt54Pro.rawValue
        ).rawValue
        let emptyBaseSelectionRaw = "\(AgentProviderKind.codexExec.rawValue):openai_tier__flex__"
        let parseInvalidSelectionRaw = "agent-selection:\(AgentProviderKind.codexExec.rawValue):\(tierRaw)"
        let fileStore = CountingGlobalSettingsFileStore(document: GlobalSettingsDocument(
            agentModelsSettings: [
                workspaceID: WorkspaceAgentModelsSettings(
                    inheritanceMode: .useWorkspaceOverrides,
                    profile: AgentModelsSettingsProfile(
                        planningModelRaw: tierRaw,
                        preferredComposeModelRaw: tierRaw,
                        mcpAgentRoleOverrides: [
                            "explore": tierSelectionRaw,
                            "engineer": emptyBaseSelectionRaw
                        ]
                    )
                )
            ],
            globalDefaults: GlobalDefaults(
                discoverAgentRaw: AgentProviderKind.codexExec.rawValue,
                discoverModelsByAgent: [AgentProviderKind.codexExec.rawValue: tierRaw],
                mcpAgentRoleOverrides: [
                    "code": tierSelectionRaw,
                    "review": parseInvalidSelectionRaw
                ]
            ),
            scalarPreferences: GlobalScalarPreferences(
                modelSelection: .init(preferredComposeModel: tierRaw, planningModel: tierRaw)
            )
        ))
        let store = try GlobalSettingsStore(defaults: makeIsolatedDefaults(), fileStore: fileStore)
        fileStore.saveCount = 0
        let recorder = AgentModelsNotificationRecorder(observing: store)
        defer { recorder.invalidate() }

        store.normalizeDisabledOpenAIServiceTierVariants()

        XCTAssertEqual(fileStore.saveCount, 1)
        XCTAssertEqual(store.globalAgentModelsProfile().planningModelRaw, AIModel.gpt54Pro.rawValue)
        XCTAssertEqual(store.globalAgentModelsProfile().preferredComposeModelRaw, AIModel.gpt54Pro.rawValue)
        XCTAssertEqual(
            store.globalAgentModelsProfile().contextBuilderModelsByAgent?[AgentProviderKind.codexExec.rawValue],
            AIModel.gpt54Pro.rawValue
        )
        XCTAssertEqual(store.globalAgentModelsProfile().mcpAgentRoleOverrides?["code"], normalizedSelectionRaw)
        XCTAssertEqual(
            store.globalAgentModelsProfile().mcpAgentRoleOverrides?["review"],
            parseInvalidSelectionRaw,
            "Parse-invalid overrides must survive byte-identical"
        )
        XCTAssertEqual(store.workspaceAgentModelsProfile(for: workspaceID)?.planningModelRaw, AIModel.gpt54Pro.rawValue)
        XCTAssertEqual(
            store.workspaceAgentModelsProfile(for: workspaceID)?.mcpAgentRoleOverrides?["explore"],
            normalizedSelectionRaw
        )
        XCTAssertEqual(
            store.workspaceAgentModelsProfile(for: workspaceID)?.mcpAgentRoleOverrides?["engineer"],
            emptyBaseSelectionRaw,
            "A parsed tier wrapper with an empty base must survive without reconstruction"
        )
        XCTAssertEqual(Set(recorder.snapshot().compactMap(\.scope)), Set(["global", "workspace"]))

        store.normalizeDisabledOpenAIServiceTierVariants()
        XCTAssertEqual(fileStore.saveCount, 1, "Cleanup must be idempotent")
    }

    func testDisablingServiceTierVariantsInstallsParsingPolicyBeforeCleanup() throws {
        let defaults = try makeIsolatedDefaults()
        defaults.set(true, forKey: "openAIShowServiceTierVariants")
        var policyObservedDuringCleanup: Bool?

        APISettingsViewModel.persistOpenAIShowServiceTierVariants(
            false,
            defaults: defaults,
            normalizeDisabledVariants: {
                policyObservedDuringCleanup = defaults.bool(forKey: "openAIShowServiceTierVariants")
            }
        )

        XCTAssertEqual(policyObservedDuringCleanup, false)
        XCTAssertFalse(defaults.bool(forKey: "openAIShowServiceTierVariants"))
    }

    func testReloadNotifiesChangedAndRemovedAgentModelsScopesAfterInstallation() throws {
        let changedWorkspaceID = UUID()
        let removedWorkspaceID = UUID()
        let fileStore = CountingGlobalSettingsFileStore(document: GlobalSettingsDocument(
            agentModelsSettings: [
                changedWorkspaceID: WorkspaceAgentModelsSettings(
                    inheritanceMode: .useWorkspaceOverrides,
                    profile: AgentModelsSettingsProfile(planningModelRaw: AIModel.gpt54Pro.rawValue)
                ),
                removedWorkspaceID: WorkspaceAgentModelsSettings(
                    inheritanceMode: .useWorkspaceOverrides,
                    profile: AgentModelsSettingsProfile(planningModelRaw: AIModel.gpt54Pro.rawValue)
                )
            ],
            globalDefaults: GlobalDefaults(discoverAgentRaw: nil, discoverModelsByAgent: nil),
            scalarPreferences: GlobalScalarPreferences(
                modelSelection: .init(planningModel: AIModel.gpt54Pro.rawValue)
            )
        ))
        let store = try GlobalSettingsStore(defaults: makeIsolatedDefaults(), fileStore: fileStore)
        let recorder = AgentModelsNotificationRecorder(observing: store)
        defer { recorder.invalidate() }
        fileStore.document = GlobalSettingsDocument(
            agentModelsSettings: [
                changedWorkspaceID: WorkspaceAgentModelsSettings(
                    inheritanceMode: .useWorkspaceOverrides,
                    profile: AgentModelsSettingsProfile(planningModelRaw: AIModel.claude4Sonnet.rawValue)
                )
            ],
            globalDefaults: GlobalDefaults(discoverAgentRaw: nil, discoverModelsByAgent: nil),
            scalarPreferences: GlobalScalarPreferences(
                modelSelection: .init(planningModel: AIModel.claude4Sonnet.rawValue)
            )
        )

        XCTAssertTrue(store.reloadFromDisk())
        XCTAssertEqual(store.globalAgentModelsProfile().planningModelRaw, AIModel.claude4Sonnet.rawValue)
        let notifications = recorder.snapshot()
        XCTAssertTrue(notifications.contains { $0.scope == "global" && $0.workspaceID == nil })
        XCTAssertTrue(notifications.contains { $0.workspaceID == changedWorkspaceID })
        XCTAssertTrue(notifications.contains { $0.workspaceID == removedWorkspaceID })
    }

    private var obsoleteGitignorePreferenceKey: String {
        ["respect", "Git", "ignore"].joined()
    }
}

private final class CountingGlobalSettingsFileStore: GlobalSettingsFileStoring {
    let fileURL: URL
    var document: GlobalSettingsDocument
    var saveCount = 0
    var blockReason: GlobalSettingsPersistenceBlockReason? {
        nil
    }

    init(document: GlobalSettingsDocument) {
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CountingGlobalSettingsFileStore-\(UUID().uuidString).json")
        self.document = document
    }

    func load() throws -> GlobalSettingsDocument {
        document
    }

    func loadOrCreateDefault() -> GlobalSettingsDocument {
        document
    }

    func save(_ document: GlobalSettingsDocument) throws {
        saveCount += 1
        var saved = document
        saved.schemaVersion = saved.requiredSchemaVersion
        saved.schemaLineage = GlobalSettingsDocument.schemaLineage
        self.document = saved
    }

    func performUserInitiatedRecovery(replacementDocument _: GlobalSettingsDocument) -> Bool {
        false
    }

    func performUserInitiatedCompatibleImport() -> Bool {
        false
    }
}

private final class AgentModelsNotificationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(scope: String?, workspaceID: UUID?)] = []
    private var token: NSObjectProtocol?

    init(observing object: AnyObject) {
        token = NotificationCenter.default.addObserver(
            forName: .agentModelsSettingsDidChange,
            object: object,
            queue: nil
        ) { [weak self] notification in
            self?.record(notification)
        }
    }

    func invalidate() {
        guard let token else { return }
        NotificationCenter.default.removeObserver(token)
        self.token = nil
    }

    func snapshot() -> [(scope: String?, workspaceID: UUID?)] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    private func record(_ notification: Notification) {
        let scope = notification.userInfo?[AgentModelsSettingsNotification.scopeKey] as? String
        let workspaceID = notification.userInfo?[AgentModelsSettingsNotification.workspaceIDKey] as? UUID
        lock.lock()
        entries.append((scope: scope, workspaceID: workspaceID))
        lock.unlock()
    }
}
