import Foundation
import MCP
import XCTest
@_spi(TestSupport) @testable import RepoPrompt

@MainActor
final class SettingsJSONOnlyPersistenceTests: XCTestCase {
    func testDefaultGlobalSettingsPathUsesCESupportRoot() {
        let path = GlobalSettingsFileStore.defaultFileURL().path
        XCTAssertTrue(path.contains("/Application Support/RepoPrompt CE/Settings/globalSettings.json"), path)
        XCTAssertFalse(path.contains("/Application Support/RepoPrompt/Settings/globalSettings.json"), path)
    }

    func testMissingGlobalSettingsCreatesCurrentDefaultsAndIgnoresLegacyDefaults() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let suiteName = "SettingsJSONOnlyPersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: "respectGitignore")

        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        let fileStore = GlobalSettingsFileStore(fileURL: fileURL)
        let store = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertTrue(store.respectGitignore())
        XCTAssertTrue(store.respectRepoIgnore())
        XCTAssertTrue(store.respectCursorignore())
        XCTAssertTrue(store.skipSymlinks())
    }

    func testExplicitJSONRespectGitignoreFalseIsPreserved() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        let fileStore = GlobalSettingsFileStore(fileURL: fileURL)
        try fileStore.save(GlobalSettingsDocument(
            scalarPreferences: GlobalScalarPreferences(
                fileSystem: .init(respectGitignore: false)
            )
        ))

        let store = try GlobalSettingsStore(
            defaults: XCTUnwrap(UserDefaults(suiteName: "SettingsJSONOnlyPersistenceTests.\(UUID().uuidString)")),
            fileStore: fileStore
        )

        XCTAssertFalse(store.respectGitignore())
    }

    func testCodexComputerUseOptInPersistsInJSONSettings() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        let fileStore = GlobalSettingsFileStore(fileURL: fileURL)
        let suiteName = "SettingsJSONOnlyPersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)

        XCTAssertFalse(store.codexComputerUseEnabled())
        store.setCodexComputerUseEnabled(true)

        let reloaded = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)
        XCTAssertTrue(reloaded.codexComputerUseEnabled())
        let rawJSON = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(rawJSON.contains("codexComputerUseEnabled"))
    }

    func testCodexDiagnosticsSettingsUseUserDefaultsNotGlobalSettingsJSON() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        let fileStore = GlobalSettingsFileStore(fileURL: fileURL)
        let suiteName = "SettingsJSONOnlyPersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)

        XCTAssertFalse(store.codexRawEventLoggingEnabled())
        XCTAssertFalse(store.codexAppServerDiagnosticsEnabled())
        store.setCodexRawEventLoggingEnabled(true)
        store.setCodexRawEventLogFilePath("/tmp/codex-raw")
        store.setCodexAppServerDiagnosticsEnabled(true)
        store.setCodexAppServerDiagnosticsLogFilePath("/tmp/codex-diag")

        let reloaded = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)
        XCTAssertTrue(reloaded.codexRawEventLoggingEnabled())
        XCTAssertEqual(reloaded.codexRawEventLogFilePath(), "/tmp/codex-raw")
        XCTAssertTrue(reloaded.codexAppServerDiagnosticsEnabled())
        XCTAssertEqual(reloaded.codexAppServerDiagnosticsLogFilePath(), "/tmp/codex-diag")

        let rawJSON = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertFalse(rawJSON.contains("codexRawEventLoggingEnabled"))
        XCTAssertFalse(rawJSON.contains("codexAppServerDiagnosticsEnabled"))
    }

    func testCodexDiagnosticsAppSettingsAreExposedAndWritable() async throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        let suiteName = "SettingsJSONOnlyPersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(fileURL: fileURL)
        )
        let service = AppSettingsMCPService(store: store)
        let tools = await service.tools
        let tool = try XCTUnwrap(tools.first { $0.name == AppSettingsMCPService.toolName })

        let listValue = try await tool(["op": .string("list"), "group": .string("agent_mode")])
        let listObject = try XCTUnwrap(listValue.objectValue)
        let settings = try XCTUnwrap(listObject["settings"]?.arrayValue)
        let keys = Set(settings.compactMap { $0.objectValue?["key"]?.stringValue })
        XCTAssertTrue(keys.contains("agent_mode.codex_raw_event_logging_enabled"))
        XCTAssertTrue(keys.contains("agent_mode.codex_app_server_diagnostics_enabled"))

        _ = try await tool([
            "op": .string("set"),
            "key": .string("agent_mode.codex_app_server_diagnostics_enabled"),
            "value": .bool(true)
        ])
        XCTAssertTrue(store.codexAppServerDiagnosticsEnabled())
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
        let futureJSON = #"{"schemaVersion":999,"updatedAt":"2026-05-20T00:00:00Z"}"#
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

        let futureJSON = #"{"schemaVersion":999,"updatedAt":"2026-05-20T00:00:00Z"}"#
        try Data(futureJSON.utf8).write(to: fileURL)

        XCTAssertThrowsError(try fileStore.load()) { error in
            XCTAssertEqual(error as? GlobalSettingsFileStore.GlobalSettingsFileStoreError, .unsupportedFutureSchema(999))
        }
        XCTAssertThrowsError(try fileStore.save(GlobalSettingsDocument())) { error in
            XCTAssertEqual(error as? GlobalSettingsFileStore.GlobalSettingsFileStoreError, .unsupportedFutureSchemaPreserved)
        }
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), futureJSON)
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SettingsJSONOnlyPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
