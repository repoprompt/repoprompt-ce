import Foundation
@testable import RepoPromptApp
import RepoPromptFoundation
import RepoPromptSettingsCore
import RepoPromptShared
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
