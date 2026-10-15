import Foundation
import RepoPromptDomainRuntime
@testable import RepoPromptMCPCore
import RepoPromptShared
import XCTest

final class AppProfileLocationsTests: XCTestCase {
    func testReleaseLocationsStayStableAndDebugUsesSiblingNamespaces() {
        let home = URL(fileURLWithPath: "/Users/profile-fixture", isDirectory: true)
        let release = AppProfileLocations(identity: .repoPromptCE(.release), homeDirectory: home)
        let debug = AppProfileLocations(identity: .repoPromptCE(.debug), homeDirectory: home)
        XCTAssertEqual(release.applicationSupportRoot.path, "/Users/profile-fixture/Library/Application Support/RepoPrompt CE")
        XCTAssertEqual(debug.applicationSupportRoot.path, "/Users/profile-fixture/Library/Application Support/RepoPrompt CE Debug")
        XCTAssertFalse(debug.applicationSupportRoot.pathComponents.starts(with: release.applicationSupportRoot.pathComponents))
        XCTAssertEqual(release.savedPromptsRoot.lastPathComponent, "com.pvncher.repoprompt")
        XCTAssertEqual(debug.savedPromptsRoot.deletingLastPathComponent(), debug.applicationSupportRoot)
        XCTAssertNotEqual(debug.preferencesDomain, release.preferencesDomain)
        // Harmless flavor-namespaced discovery/install files do not move.
        XCTAssertEqual(debug.identity.applicationSupportDirectoryName, release.identity.applicationSupportDirectoryName)
        XCTAssertEqual(debug.identity.socketDirectoryName, release.identity.socketDirectoryName)
        XCTAssertNotEqual(debug.identity.bootstrapSocketName, release.identity.bootstrapSocketName)
        XCTAssertEqual(debug.profileIdentifier, release.profileIdentifier) // Runtime IDs/formats stay compatible; directories separate state.
        XCTAssertEqual(debug.profileIdentifier, AppProfileLocations(identity: .repoPromptCE(.debug), homeDirectory: home).profileIdentifier)
    }

    func testProtectedRootAliasesAreRejectedBeforeCreatingAnything() throws {
        try withFixture { directory, locations in
            let release = locations.releaseStateRoots[0]
            try FileManager.default.createDirectory(at: release, withIntermediateDirectories: true)
            let sentinel = release.appendingPathComponent("sentinel")
            try Data("release must survive".utf8).write(to: sentinel)
            let alias = directory.appendingPathComponent("alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: release)
            let nested = alias.appendingPathComponent("NotCreated")
            XCTAssertThrowsError(try locations.validateWritableRoot(nested))
            XCTAssertFalse(FileManager.default.fileExists(atPath: release.appendingPathComponent("NotCreated").path))
            XCTAssertEqual(try Data(contentsOf: sentinel), Data("release must survive".utf8))
            XCTAssertThrowsError(try locations.validateWritableRoot(release.deletingLastPathComponent()))
            XCTAssertNoThrow(try locations.validateWritableRoot(locations.applicationSupportRoot))
        }
    }

    func testMetadataRejectsEscapingSymlinksAndExternalAbsoluteReferences() throws {
        try withFixture { directory, locations in
            let root = locations.applicationSupportRoot
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let outside = directory.appendingPathComponent("external")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            let symlink = root.appendingPathComponent("Chats")
            try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)
            let policy = AppMetadataPathPolicy(locations: locations, roots: [root])
            XCTAssertThrowsError(try policy.validate(symlink.appendingPathComponent("chat.json")))
            XCTAssertThrowsError(try policy.validate(outside.appendingPathComponent("workspace.json")))
            XCTAssertNoThrow(try policy.validate(root.appendingPathComponent("Workspaces/new/workspace.json")))
        }
    }

    func testMetadataTargetMayShareAnAncestorButCannotMutateProductionOrItsAncestor() throws {
        try withFixture { directory, locations in
            let release = locations.releaseStateRoots[0]
            try FileManager.default.createDirectory(at: release, withIntermediateDirectories: true)
            let sentinel = release.appendingPathComponent("sentinel.json")
            let bytes = Data("production unchanged".utf8)
            try bytes.write(to: sentinel)
            let sibling = directory.appendingPathComponent("unrelated-metadata", isDirectory: true)
            XCTAssertNoThrow(try locations.validateMetadataFile(sibling))
            XCTAssertNoThrow(try locations.validateMetadataURL(sibling.appendingPathComponent("settings.json"), within: directory))
            XCTAssertThrowsError(try locations.validateMetadataFile(sentinel))
            XCTAssertThrowsError(try locations.validateMetadataFile(directory))
            XCTAssertThrowsError(try locations.validateWritableRoot(directory))
            XCTAssertEqual(try Data(contentsOf: sentinel), bytes)
            XCTAssertFalse(FileManager.default.fileExists(atPath: sibling.path))
        }
    }

    func testHeadlessRootUsesIdentityAndRefusesProductionOverride() throws {
        try withFixture { directory, locations in
            let headless = try DirectHeadlessRuntimeLocationResolver.resolve(
                environment: [:], currentDirectory: directory, homeDirectory: locations.homeDirectory,
                temporaryDirectory: directory.appendingPathComponent("tmp"), customWorkspaceStoragePath: nil, identity: .repoPromptCE(.debug)
            )
            XCTAssertEqual(headless.storageDirectory, locations.applicationSupportRoot)
            XCTAssertEqual(headless.profileIdentifier, locations.profileIdentifier)
            let protected = locations.releaseStateRoots[0]
            XCTAssertThrowsError(try DirectHeadlessRuntimeLocationResolver.resolve(
                environment: ["REPOPROMPT_MCP_HEADLESS_PROFILE_DIR": protected.path], currentDirectory: directory,
                homeDirectory: locations.homeDirectory, temporaryDirectory: directory.appendingPathComponent("tmp"),
                customWorkspaceStoragePath: nil, identity: .repoPromptCE(.debug)
            ))
            XCTAssertFalse(FileManager.default.fileExists(atPath: protected.path))
        }
    }

    func testCustomAndExplicitHeadlessParentsCannotShareWorkspaceIndexes() throws {
        try withFixture { directory, locations in
            let parent = directory.appendingPathComponent("custom")
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let sentinel = parent.appendingPathComponent("workspacesIndex.json")
            let bytes = Data("release index".utf8)
            try bytes.write(to: sentinel)
            let debugRoot = try locations.customWorkspaceRoot(selectedDirectory: parent)
            XCTAssertNotEqual(debugRoot, parent)
            XCTAssertEqual(try locations.customWorkspaceRoot(selectedDirectory: debugRoot), debugRoot)
            XCTAssertThrowsError(try locations.validateCustomWorkspaceDirectory(parent))
            let headless = try DirectHeadlessRuntimeLocationResolver.resolve(
                environment: ["REPOPROMPT_MCP_HEADLESS_PROFILE_DIR": parent.path], currentDirectory: directory,
                homeDirectory: locations.homeDirectory, temporaryDirectory: directory.appendingPathComponent("tmp"),
                customWorkspaceStoragePath: nil, identity: .repoPromptCE(.debug)
            )
            XCTAssertEqual(headless.storageDirectory, debugRoot)
            XCTAssertEqual(try Data(contentsOf: sentinel), bytes)
            XCTAssertFalse(FileManager.default.fileExists(atPath: debugRoot.path))
            let knownRelease = AppProfileLocations(
                identity: .repoPromptCE(.debug), homeDirectory: locations.homeDirectory,
                releaseCustomStorageRoots: [parent]
            )
            XCTAssertThrowsError(try knownRelease.customWorkspaceRoot(selectedDirectory: parent))
            XCTAssertEqual(try Data(contentsOf: sentinel), bytes)
            let release = try DirectHeadlessRuntimeLocationResolver.resolve(
                environment: ["REPOPROMPT_MCP_HEADLESS_PROFILE_DIR": parent.path], currentDirectory: directory,
                homeDirectory: locations.homeDirectory, temporaryDirectory: directory.appendingPathComponent("tmp"),
                customWorkspaceStoragePath: nil, identity: .repoPromptCE(.release)
            )
            XCTAssertEqual(release.storageDirectory.path, parent.path)
            XCTAssertEqual(release.profileIdentifier, "default")
        }
    }

    func testDomainWriterRejectsReleaseRootBeforeCreatingLocksOrChangingData() async throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("rpce-domain-profile-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let locations = AppProfileLocations(identity: .repoPromptCE(.debug), homeDirectory: fixture)
        let release = locations.releaseStateRoots[0]
        try FileManager.default.createDirectory(at: release, withIntermediateDirectories: true)
        let sentinel = release.appendingPathComponent("sentinel.json")
        let bytes = Data("preserve production".utf8)
        try bytes.write(to: sentinel)
        let configuration = DomainRuntimeConfiguration(
            mode: .standalone, profileIdentifier: locations.profileIdentifier,
            storageDirectory: release, eventDirectory: release.appendingPathComponent("Events"),
            temporaryDirectory: fixture.appendingPathComponent("Temporary"),
            metadataPathPolicy: AppMetadataPathPolicy(locations: locations, roots: [release])
        )
        let identity = DomainRuntimeIdentity(runtimeID: UUID(), lifecycleGeneration: 1, processID: 42, mode: .standalone, createdAt: Date())
        let persistence = DomainPersistenceCoordinator(configuration: configuration, identity: identity)
        do {
            try await persistence.compareAndSwapDirectSettingsData(expectedDigest: nil, data: Data("replacement".utf8))
            XCTFail("A debug runtime must not create even a lock in release storage")
        } catch let error as ProfileLocationError {
            XCTAssertEqual(error, .releaseAlias(release.path))
        }
        XCTAssertEqual(try Data(contentsOf: sentinel), bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: release.path), ["sentinel.json"])
    }

    private func withFixture(_ body: (URL, AppProfileLocations) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rpce-profile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory, AppProfileLocations(
            identity: .repoPromptCE(.debug),
            homeDirectory: directory.appendingPathComponent("home", isDirectory: true)
        ))
    }
}
