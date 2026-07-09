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
        {"schemaVersion":2,"updatedAt":"2026-05-20T00:00:00Z","copySettingsByWorkspaceID":{},"chatSettingsByWorkspaceID":{},"globalDefaults":{"worktreeVisualIdentitiesByRepositoryID":{"gitrepo_alpha":{"identitiesByWorktreeID":{"wt_feature":{"label":"Feature","colorHex":"#112233"}}}}},"scalarPreferences":{}}
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
        let json = #"{"schemaVersion":2,"updatedAt":"2026-05-20T00:00:00Z","copySettingsByWorkspaceID":{},"chatSettingsByWorkspaceID":{},"globalDefaults":{},"scalarPreferences":{}}"#
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: fileURL)

        let store = try GlobalSettingsStore(
            defaults: XCTUnwrap(UserDefaults(suiteName: "SettingsJSONOnlyPersistenceTests.\(UUID().uuidString)")),
            fileStore: GlobalSettingsFileStore(fileURL: fileURL)
        )

        XCTAssertEqual(GlobalSettingsDocument.currentSchemaVersion, 2)
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

        XCTAssertEqual(document.schemaVersion, GlobalSettingsDocument.currentSchemaVersion)
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

        XCTAssertEqual(document.schemaVersion, GlobalSettingsDocument.currentSchemaVersion)
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
    /// schema: surfaced, preserved byte-for-byte, and never overwritten by CE v2 saves.
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
        XCTAssertTrue(persisted.contains(#""schemaVersion" : 2"#))
        XCTAssertFalse(persisted.contains("agentModelsSettingsByWorkspaceID"))

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

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SettingsJSONOnlyPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private var obsoleteGitignorePreferenceKey: String {
        ["respect", "Git", "ignore"].joined()
    }
}
