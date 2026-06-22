import Foundation
@testable import RepoPromptHeadless
import XCTest

final class HeadlessWorkspaceStoreTests: XCTestCase {
    func testWorkspaceLockPathIsStableAndWorkspaceSpecific() throws {
        let paths = HeadlessStatePaths(rootDirectory: URL(fileURLWithPath: "/tmp/headless-state"))
        let firstID = try XCTUnwrap(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        let secondID = try XCTUnwrap(UUID(uuidString: "22222222-2222-2222-2222-222222222222"))

        XCTAssertEqual(
            paths.workspaceLockFile(for: firstID).path,
            "/tmp/headless-state/Workspaces/11111111-1111-1111-1111-111111111111.lock"
        )
        XCTAssertNotEqual(paths.workspaceLockFile(for: firstID), paths.workspaceLockFile(for: secondID))
    }

    func testLoadDropsAndRepairsPersistedEmptySliceEntries() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        var workspace = HeadlessWorkspaceDocument(name: "Workspace", rootIDs: [fixture.rootID])
        workspace.selection = [HeadlessSelectionEntry(
            rootID: fixture.rootID,
            relativePath: "file.txt",
            mode: .slices,
            ranges: []
        )]
        try fixture.paths.ensureBaseDirectories()
        let workspaceFile = fixture.paths.workspacesDirectory
            .appendingPathComponent("\(workspace.id.uuidString).json")
        let data = try HeadlessJSONFormatting.encoder(prettyPrinted: true).encode(workspace)
        try data.write(to: workspaceFile)

        let loaded = try XCTUnwrap(fixture.store.loadWorkspace(id: workspace.id))
        XCTAssertEqual(loaded.selection, [])

        let repairedData = try Data(contentsOf: workspaceFile)
        let repaired = try HeadlessJSONFormatting.decoder().decode(HeadlessWorkspaceDocument.self, from: repairedData)
        XCTAssertEqual(repaired.selection, [])
    }

    func testConcurrentStoreUpdatesKeepEveryTransaction() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let workspace = HeadlessWorkspaceDocument(name: "Workspace", rootIDs: [fixture.rootID])
        try fixture.store.save(workspace)

        let stores = [
            HeadlessWorkspaceStore(paths: fixture.paths),
            HeadlessWorkspaceStore(paths: fixture.paths)
        ]
        let failures = ThreadSafeFailures()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "HeadlessWorkspaceStoreTests.concurrent", attributes: .concurrent)
        for index in 0 ..< 40 {
            group.enter()
            queue.async {
                defer { group.leave() }
                do {
                    try stores[index % stores.count].update(id: workspace.id) { document in
                        document.promptText.append("x")
                    }
                } catch {
                    failures.append(error)
                }
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(failures.values.map(\.localizedDescription), [])
        XCTAssertEqual(try fixture.store.loadWorkspace(id: workspace.id)?.promptText.count, 40)
    }

    func testSnapshotRejectsWorkspaceWithUnknownConfiguredRootID() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let allowedDirectory = fixture.directory.appendingPathComponent("AllowedRoot", isDirectory: true)
        try FileManager.default.createDirectory(at: allowedDirectory, withIntermediateDirectories: true)
        let unknownRootID = UUID()
        let workspace = HeadlessWorkspaceDocument(
            name: "Unknown Root Fixture",
            rootIDs: [fixture.rootID, unknownRootID]
        )
        try fixture.store.save(workspace)

        let configurationStore = HeadlessConfigurationStore(paths: fixture.paths)
        _ = try configurationStore.update { configuration in
            configuration.allowedRoots = [HeadlessAllowedRoot(
                id: fixture.rootID,
                name: "AllowedRoot",
                path: allowedDirectory.path,
                resolvedPath: allowedDirectory.resolvingSymlinksInPath().standardizedFileURL.path,
                addedAt: Date()
            )]
            configuration.activeWorkspaceID = workspace.id
        }

        let host = HeadlessHost(configurationStore: configurationStore)
        do {
            _ = try await host.snapshot(requireWorkspace: true)
            XCTFail("Expected an unknown workspace root ID to fail closed.")
        } catch let error as HeadlessCommandError {
            XCTAssertTrue(error.message.contains(workspace.name))
            XCTAssertTrue(error.message.contains(unknownRootID.uuidString))
        }
    }

    private func makeFixture() throws -> WorkspaceStoreFixture {
        let directory = HeadlessTestTemporaryDirectory.baseURL
            .appendingPathComponent("RepoPromptHeadlessWorkspaceStoreTests-\(UUID().uuidString)", isDirectory: true)
        let paths = HeadlessStatePaths(rootDirectory: directory)
        try paths.ensureBaseDirectories()
        return WorkspaceStoreFixture(
            directory: directory,
            paths: paths,
            rootID: UUID(),
            store: HeadlessWorkspaceStore(paths: paths)
        )
    }
}

private struct WorkspaceStoreFixture {
    let directory: URL
    let paths: HeadlessStatePaths
    let rootID: UUID
    let store: HeadlessWorkspaceStore

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class ThreadSafeFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var errors: [Error] = []

    var values: [Error] {
        lock.lock()
        defer { lock.unlock() }
        return errors
    }

    func append(_ error: Error) {
        lock.lock()
        errors.append(error)
        lock.unlock()
    }
}
