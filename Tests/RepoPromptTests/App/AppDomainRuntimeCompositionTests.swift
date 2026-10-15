import Foundation
@testable import RepoPromptApp
import RepoPromptFoundation
import RepoPromptSettingsCore
import RepoPromptShared
import SQLite3
import XCTest

final class AppDomainRuntimeCompositionTests: XCTestCase {
    func testCollectLegacyRuntimeDefaultsSerializesBooleanScalarFragments() throws {
        for value in [true, false] {
            let (defaults, suiteName) = try makeIsolatedDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }
            defaults.set(value, forKey: "agentModeAutoEditEnabled")

            let collected = AppDomainRuntimeComposition.collectLegacyRuntimeDefaults(from: defaults)
            let data = try XCTUnwrap(collected["agentModeAutoEditEnabled"])

            XCTAssertEqual(try JSONDecoder().decode(Bool.self, from: data), value)
            XCTAssertEqual(String(decoding: data, as: UTF8.self), value ? "true" : "false")
        }
    }

    func testCollectLegacyRuntimeDefaultsPreservesRawDataAlongsideBoolean() throws {
        let (defaults, suiteName) = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let approvalBytes = Data([0x00, 0xFF, 0x7B, 0x01])
        defaults.set(approvalBytes, forKey: "workspace.approvalSettings")
        defaults.set(false, forKey: "agentModeAutoEditEnabled")

        let collected = AppDomainRuntimeComposition.collectLegacyRuntimeDefaults(from: defaults)

        XCTAssertEqual(collected["workspace.approvalSettings"], approvalBytes)
        let booleanData = try XCTUnwrap(collected["agentModeAutoEditEnabled"])
        XCTAssertFalse(try JSONDecoder().decode(Bool.self, from: booleanData))
    }

    func testCollectLegacyRuntimeDefaultsSkipsInvalidValueWithoutMutationAndIsRepeatable() throws {
        let (defaults, suiteName) = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let invalidDate = Date(timeIntervalSince1970: 1_725_000_000)
        defaults.set(invalidDate, forKey: "workspace.approvalSettings")
        defaults.set(true, forKey: "agentModeAutoEditEnabled")

        let first = AppDomainRuntimeComposition.collectLegacyRuntimeDefaults(from: defaults)
        let second = AppDomainRuntimeComposition.collectLegacyRuntimeDefaults(from: defaults)

        XCTAssertEqual(first, second)
        XCTAssertNil(first["workspace.approvalSettings"])
        let booleanData = try XCTUnwrap(first["agentModeAutoEditEnabled"])
        XCTAssertTrue(try JSONDecoder().decode(Bool.self, from: booleanData))
        XCTAssertEqual(defaults.object(forKey: "workspace.approvalSettings") as? Date, invalidDate)
        XCTAssertEqual(defaults.object(forKey: "agentModeAutoEditEnabled") as? Bool, true)
    }

    private func makeIsolatedDefaults() throws -> (defaults: UserDefaults, suiteName: String) {
        let suiteName = "AppDomainRuntimeCompositionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}

/// Profile composition must select disjoint mutable stores for both app flavors.
@MainActor
final class DebugSessionStorageLocationsTests: XCTestCase {
    func testMutableStoreLocationsUseOneStateIdentityWithoutMovingDiscovery() {
        let locations = AppProfileLocations.current
        XCTAssertEqual(WorkspaceStoragePaths.defaultRoot, locations.workspaceRoot)
        XCTAssertEqual(AgentSessionDataService.defaultWorkspaceRootURL(), locations.workspaceRoot)
        XCTAssertEqual(ChatDataService.defaultWorkspaceRootURL(), locations.workspaceRoot)
        XCTAssertEqual(AgentWorkflowStore.workflowsDirectoryURL, locations.applicationSupportRoot.appendingPathComponent("Workflows", isDirectory: true))
        XCTAssertEqual(WindowSessionStore.sessionFileURL().deletingLastPathComponent(), locations.applicationSupportRoot)
        XCTAssertEqual(PresetFileStore.appSupportDirectoryName, locations.identity.applicationStateDirectoryName)
        XCTAssertEqual(GlobalSettingsFileStore.appSupportDirectoryName, locations.identity.applicationStateDirectoryName)
        XCTAssertEqual(locations.identity.applicationSupportDirectoryName, "RepoPrompt CE")
        if locations.identity.buildFlavor == .debug {
            XCTAssertEqual(locations.applicationSupportRoot.lastPathComponent, "RepoPrompt CE Debug")
            XCTAssertEqual(WorkspaceStoragePaths.userDataBackupDirectoryName, "RepoPrompt-Debug-Backup")
        } else {
            XCTAssertEqual(WorkspaceStoragePaths.userDataBackupDirectoryName, "RepoPrompt-Backup")
        }
    }

    func testTwoFlavorsWithSameRepositoryWorkspaceAndTabCannotOverwriteSelections() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("PartitionProfiles-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let release = AppProfileLocations(identity: .repoPromptCE(.release), homeDirectory: home)
        let debug = AppProfileLocations(identity: .repoPromptCE(.debug), homeDirectory: home)
        let releaseStore = PartitionStore(profileLocations: release)
        let debugStore = PartitionStore(profileLocations: debug)
        let scope = PartitionScope(workspaceID: UUID(), tabID: UUID())
        let repository = "/fixture/shared-repository"
        let file = "/fixture/shared-repository/source.swift"
        let releaseRanges = [LineRange(start: 2, end: 5)]
        let debugRanges = [LineRange(start: 20, end: 25)]
        var data = PartitionStore.PartitionData.empty()
        data.files[file] = .init(ranges: releaseRanges, fileModificationTime: nil)
        try await releaseStore.save(forRoot: repository, scope: scope, data: data)
        let before = try snapshot(release.applicationSupportRoot)

        data.files[file] = .init(ranges: debugRanges, fileModificationTime: nil)
        try await debugStore.save(forRoot: repository, scope: scope, data: data)
        let releaseResult = await releaseStore.load(forRoot: repository, scope: scope)
        let debugResult = await debugStore.load(forRoot: repository, scope: scope)
        XCTAssertEqual(releaseResult.files[file]?.ranges, releaseRanges)
        XCTAssertEqual(debugResult.files[file]?.ranges, debugRanges)
        XCTAssertEqual(try snapshot(release.applicationSupportRoot), before)

        let aliased = PartitionStore(
            baseURL: release.applicationSupportRoot.appendingPathComponent("Partitions"),
            profileLocations: debug
        )
        do {
            try await aliased.save(forRoot: repository, scope: scope, data: data)
            XCTFail("Debug must reject a release selection-store alias")
        } catch is ProfileLocationError {}
        XCTAssertEqual(try snapshot(release.applicationSupportRoot), before)
    }

    private func snapshot(_ root: URL) throws -> [String: Data] {
        let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        var files: [String: Data] = [:]
        while let url = entries?.nextObject() as? URL {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                files[url.path] = try Data(contentsOf: url)
            }
        }
        return files
    }
}

/// Disposable fake HOME fixtures exercise the real startup publish boundary.
final class DebugStateBootstrapTests: XCTestCase {
    private struct Fixture {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("DebugSeed-\(UUID().uuidString)")
        var release: AppProfileLocations {
            .init(identity: .repoPromptCE(.release), homeDirectory: home)
        }

        var debug: AppProfileLocations {
            .init(identity: .repoPromptCE(.debug), homeDirectory: home, releaseCustomStorageRoots: [])
        }

        var recovery: URL {
            debug.applicationSupportRoot.deletingLastPathComponent().appendingPathComponent("RepoPrompt CE Debug Recovery")
        }

        func write(_ data: Data, _ url: URL) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }

        func writeJSON(_ value: Any, _ url: URL) throws {
            try write(JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), url)
        }

        func object(_ url: URL) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: home)
        }
    }

    func testEveryNormalSeedRefreshesByValueAndCleanSlateDoesNotStick() throws {
        let f = Fixture()
        defer { f.cleanup() }
        let settings = f.release.applicationSupportRoot.appendingPathComponent("Settings/globalSettings.json")
        try f.writeJSON(["schemaVersion": 1, "value": "production"], settings)
        let sourceBytes = try Data(contentsOf: settings)
        let debugSettings = f.debug.applicationSupportRoot.appendingPathComponent("Settings/globalSettings.json")
        _ = try DebugStateBootstrap.seed(locations: f.debug, cleanSlate: false, releasePreferences: ["fontSize": 14])
        XCTAssertEqual(try Data(contentsOf: debugSettings), sourceBytes)
        try f.writeJSON(["value": "debug-only"], debugSettings)
        let previousDebugBytes = try Data(contentsOf: debugSettings)
        _ = try DebugStateBootstrap.seed(locations: f.debug, cleanSlate: true, releasePreferences: ["fontSize": 14])
        XCTAssertFalse(FileManager.default.fileExists(atPath: debugSettings.path))
        let archives = try FileManager.default.contentsOfDirectory(at: f.recovery, includingPropertiesForKeys: nil)
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }
        XCTAssertEqual(archives.count, 1)
        XCTAssertEqual(try Data(contentsOf: archives[0].appendingPathComponent("Settings/globalSettings.json")), previousDebugBytes)
        _ = try DebugStateBootstrap.seed(locations: f.debug, cleanSlate: false, releasePreferences: ["fontSize": 14])
        XCTAssertEqual(try Data(contentsOf: debugSettings), sourceBytes)
        XCTAssertEqual(try Data(contentsOf: settings), sourceBytes)
        XCTAssertEqual(DebugStateBootstrap.cleanSlateArgument, "--debug-clean-slate")
    }

    func testCustomWorkspaceJournalAndConversationBackingsAreCopiedWithoutResumeAuthority() throws {
        let f = Fixture()
        defer { f.cleanup() }
        let id = UUID(), tabID = UUID(), sessionID = UUID()
        let custom = f.home.appendingPathComponent("CustomMetadata")
        let directory = custom.appendingPathComponent("original")
        let workspaceURL = directory.appendingPathComponent("workspace.json")
        let workspace: [String: Any] = [
            "id": id.uuidString,
            "name": "Fixture",
            "customStoragePath": directory.absoluteString,
            "composeTabs": [["id": tabID.uuidString, "activeAgentSessionID": sessionID.uuidString]]
        ]
        try f.writeJSON(workspace, workspaceURL)
        let backing = directory.appendingPathComponent("AgentSessions/attachments/image.bin")
        try f.write(Data([0, 1, 2, 3]), backing)
        let sessionURL = directory.appendingPathComponent("AgentSessions/AgentSession-" + sessionID.uuidString + ".json")
        try f.writeJSON([
            "id": sessionID.uuidString,
            "fileURL": sessionURL.absoluteString,
            "providerSessionID": "production-remote",
            "codexConversationID": "production-thread",
            "providerCleanupHandle": ["id": "production-remote"],
            "autoWakeOnOversightUpdates": true,
            "items": [["text": "kept history"]]
        ], sessionURL)
        try f.writeJSON([["id": id.uuidString, "name": "Fixture", "customStoragePath": directory.absoluteString]], custom.appendingPathComponent("workspacesIndex.json"))
        let runtime = f.release.applicationSupportRoot.appendingPathComponent("DomainRuntime/v1/default-37a8eec1ce19")
        var working = workspace
        working["name"] = "Unsaved"
        let workingData = try JSONSerialization.data(withJSONObject: working)
        try f.writeJSON(["version": 1, "workspaceID": id.uuidString, "fileURL": workspaceURL.absoluteString, "workingDocument": workingData.base64EncodedString()], runtime.appendingPathComponent("working-journals/" + id.uuidString + ".json"))
        _ = try DebugStateBootstrap.seed(locations: f.debug, cleanSlate: false, releasePreferences: ["GlobalCustomStorageURL": custom.path])
        let destination = f.debug.workspaceRoot.appendingPathComponent("Workspace-Unsaved-" + id.uuidString)
        let copied = try f.object(destination.appendingPathComponent("workspace.json"))
        XCTAssertEqual(copied["name"] as? String, "Unsaved")
        XCTAssertNil(copied["customStoragePath"])
        let copySession = try f.object(destination.appendingPathComponent("AgentSessions/" + sessionURL.lastPathComponent))
        XCTAssertNil(copySession["providerSessionID"])
        XCTAssertNil(copySession["providerCleanupHandle"])
        XCTAssertNil(copySession["codexConversationID"])
        XCTAssertEqual(copySession["autoWakeOnOversightUpdates"] as? Bool, false)
        XCTAssertEqual(copySession["fileURL"] as? String, destination.appendingPathComponent("AgentSessions/" + sessionURL.lastPathComponent).absoluteString)
        XCTAssertNotNil(copySession["items"])
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("AgentSessions/attachments/image.bin")), Data([0, 1, 2, 3]))
        XCTAssertEqual(try f.object(workspaceURL)["name"] as? String, "Fixture")
        XCTAssertEqual(try f.object(sessionURL)["providerSessionID"] as? String, "production-remote")
    }

    func testDeletedWorkspaceStaysDeletedAndJournalOnlyWorkspaceIsRecoverable() throws {
        let f = Fixture()
        defer { f.cleanup() }
        let removed = UUID(), recovered = UUID()
        let runtime = f.release.applicationSupportRoot.appendingPathComponent("DomainRuntime/v1/default-37a8eec1ce19")
        let dead = f.release.workspaceRoot.appendingPathComponent("Workspace-Removed-" + removed.uuidString + "/workspace.json")
        let fresh = f.release.workspaceRoot.appendingPathComponent("Workspace-Recovered-" + recovered.uuidString + "/workspace.json")
        try f.writeJSON(["id": removed.uuidString, "name": "Removed"], dead)
        try f.writeJSON([["id": removed.uuidString, "name": "Removed"]], f.release.workspaceRoot.appendingPathComponent("workspacesIndex.json"))
        try f.writeJSON(["version": 1, "workspaceID": removed.uuidString], runtime.appendingPathComponent("deletion-tombstones/" + removed.uuidString + ".json"))
        let bytes = try JSONSerialization.data(withJSONObject: ["id": recovered.uuidString, "name": "Recovered"])
        try f.writeJSON(["version": 1, "workspaceID": recovered.uuidString, "fileURL": fresh.absoluteString, "workingDocument": bytes.base64EncodedString()], runtime.appendingPathComponent("working-journals/" + recovered.uuidString + ".json"))
        _ = try DebugStateBootstrap.seed(locations: f.debug, cleanSlate: false, releasePreferences: [:])
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.debug.workspaceRoot.appendingPathComponent("Workspace-Removed-" + removed.uuidString).path))
        XCTAssertEqual(try f.object(f.debug.workspaceRoot.appendingPathComponent("Workspace-Recovered-" + recovered.uuidString + "/workspace.json"))["name"] as? String, "Recovered")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dead.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.path))
    }

    func testPersistedProductionPreferencesAreCapturedAndPriorPreferenceBytesAreRecoverable() throws {
        let f = Fixture()
        defer { f.cleanup() }
        try FileManager.default.createDirectory(at: f.release.applicationSupportRoot, withIntermediateDirectories: true)
        let preferenceSource = f.home.appendingPathComponent("Library/Preferences/production.plist")
        let previousPreference = f.home.appendingPathComponent("Library/Preferences/debug.plist")
        let sourceBytes = try PropertyListSerialization.data(fromPropertyList: ["fontSize": 19], format: .binary, options: 0)
        let priorBytes = try PropertyListSerialization.data(fromPropertyList: ["fontSize": 11], format: .xml, options: 0)
        try f.write(sourceBytes, preferenceSource)
        try f.write(priorBytes, previousPreference)
        _ = try DebugStateBootstrap.seed(locations: f.debug, cleanSlate: true, releasePreferences: [:])
        _ = try DebugStateBootstrap.seed(locations: f.debug, cleanSlate: false, releasePreferences: [:], preferenceSourceURL: preferenceSource, previousPreferenceFileURL: previousPreference)
        let url = f.debug.applicationSupportRoot.appendingPathComponent("seedPreferences.plist")
        let values = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        XCTAssertEqual(values["fontSize"] as? Int, 19)
        let records = try FileManager.default.contentsOfDirectory(at: f.recovery, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        let record = try f.object(XCTUnwrap(records.first))
        XCTAssertEqual((record["previousPreferences"] as? String).flatMap { Data(base64Encoded: $0) }, priorBytes)
        XCTAssertEqual(try Data(contentsOf: preferenceSource), sourceBytes)
        XCTAssertEqual(try Data(contentsOf: previousPreference), priorBytes)
        _ = try DebugStateBootstrap.seed(locations: f.debug, cleanSlate: true, releasePreferences: [:], preferenceSourceURL: preferenceSource)
        let cleanValues = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        XCTAssertTrue(cleanValues.isEmpty)
    }

    func testCatalogOnlyTombstoneCannotResurrectAnExistingWorkspaceFile() throws {
        let f = Fixture()
        defer { f.cleanup() }
        let id = UUID()
        let source = f.release.workspaceRoot.appendingPathComponent("Workspace-Removed-" + id.uuidString + "/workspace.json")
        try f.writeJSON(["id": id.uuidString, "name": "Removed"], source)
        let catalog = f.release.applicationSupportRoot.appendingPathComponent("DomainRuntime/v1/default-37a8eec1ce19/workspace-catalog.json")
        try f.writeJSON(["version": 1, "entries": [["workspaceID": id.uuidString, "fileURL": source.absoluteString]], "deletions": [["workspaceID": id.uuidString]]], catalog)
        _ = try DebugStateBootstrap.seed(locations: f.debug, cleanSlate: false, releasePreferences: [:])
        let index = try JSONSerialization.jsonObject(with: Data(contentsOf: f.debug.workspaceRoot.appendingPathComponent("workspacesIndex.json"))) as? [Any]
        XCTAssertEqual(index?.count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testChangedSourceAndSymlinkFailBeforeReplacingPriorDebugState() throws {
        let f = Fixture()
        defer { f.cleanup() }
        let input = f.release.applicationSupportRoot.appendingPathComponent("Settings/globalSettings.json")
        try f.write(Data("first".utf8), input)
        _ = try DebugStateBootstrap.seed(locations: f.debug, cleanSlate: true, releasePreferences: [:])
        let sentinel = f.debug.applicationSupportRoot.appendingPathComponent("prior.txt")
        try f.write(Data("prior".utf8), sentinel)
        var plan = DebugStateSnapshot.Plan()
        try plan.add(input, as: "Settings/globalSettings.json")
        try f.write(Data("source changed".utf8), input)
        XCTAssertThrowsError(try DebugStateSnapshot(locations: f.debug).publish(plan: plan, cleanSlate: false, preferences: Data(), previousPreferences: Data()))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("prior".utf8))
        let alias = f.release.applicationSupportRoot.appendingPathComponent("Presets")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.debug.applicationSupportRoot)
        XCTAssertThrowsError(try DebugStateBootstrap.seed(locations: f.debug, cleanSlate: false, releasePreferences: [:]))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("prior".utf8))
    }

    func testRecoveryRetentionIsBoundedAndUnknownRecoveryDataIsNotDeleted() throws {
        let f = Fixture()
        defer { f.cleanup() }
        try FileManager.default.createDirectory(at: f.release.applicationSupportRoot, withIntermediateDirectories: true)
        for _ in 0 ..< 6 {
            _ = try DebugStateBootstrap.seed(locations: f.debug, cleanSlate: true, releasePreferences: [:], previousPreferences: ["remember": "old debug"])
        }
        let entries = try FileManager.default.contentsOfDirectory(at: f.recovery, includingPropertiesForKeys: nil)
        XCTAssertEqual(entries.count(where: { UUID(uuidString: $0.lastPathComponent) != nil }), 3)
        let unknown = f.recovery.appendingPathComponent("unknown-user-file")
        try f.write(Data("preserve".utf8), unknown)
        _ = try DebugStateBootstrap.seed(locations: f.debug, cleanSlate: true, releasePreferences: [:])
        XCTAssertEqual(try Data(contentsOf: unknown), Data("preserve".utf8))
    }

    func testSQLiteBackupIsReadOnlyAndWrongProfileContinuityIsNotActivated() throws {
        let f = Fixture()
        defer { f.cleanup() }
        let source = f.release.applicationSupportRoot.appendingPathComponent("Overseer/continuity.sqlite")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(source.path, &db), SQLITE_OK)
        defer { sqlite3_close_v2(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE fixture(value TEXT); INSERT INTO fixture VALUES ('source');", nil, nil, nil), SQLITE_OK)
        let bytes = try Data(contentsOf: source)
        let stamp = try DebugStateSnapshot.stamp(source)
        _ = try DebugStateBootstrap.seed(locations: f.debug, cleanSlate: false, releasePreferences: [:])
        let copy = f.debug.applicationSupportRoot.appendingPathComponent("ProductionContinuity/continuity.sqlite")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.debug.applicationSupportRoot.appendingPathComponent("Overseer/continuity.sqlite").path))
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertEqual(try DebugStateSnapshot.stamp(source), stamp)
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA journal_mode=WAL; INSERT INTO fixture VALUES ('new');", nil, nil, nil), SQLITE_OK)
        let wal = URL(fileURLWithPath: source.path + "-wal")
        let walBytes = try Data(contentsOf: wal)
        XCTAssertThrowsError(try DebugStateBootstrap.seed(locations: f.debug, cleanSlate: false, releasePreferences: [:]))
        XCTAssertEqual(try Data(contentsOf: wal), walBytes)
    }
}
