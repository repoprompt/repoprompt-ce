@testable import RepoPromptCore
import XCTest

final class WorkspaceSessionPersistenceCoordinatorTests: XCTestCase {
    func testNewerSelectionMergesIntoNewerDiskWithoutOverwritingOtherFields() async throws {
        let url = URL(fileURLWithPath: "/virtual/workspace.json")
        let tabID = UUID()
        let workspaceID = UUID()
        let oldSelection = StoredSelection(selectedPaths: ["old.swift"])
        let newestSelection = StoredSelection(selectedPaths: ["new.swift"])
        let oldDate = Date(timeIntervalSinceReferenceDate: 10)
        let diskDate = Date(timeIntervalSinceReferenceDate: 20)

        let local = WorkspaceModel(
            id: workspaceID,
            dateModified: oldDate,
            name: "Local stale name",
            repoPaths: ["/local"],
            composeTabs: [ComposeTabState(id: tabID, selection: oldSelection)],
            activeComposeTabID: tabID
        )
        let disk = WorkspaceModel(
            id: workspaceID,
            dateModified: diskDate,
            name: "Newer disk name",
            repoPaths: ["/disk"],
            composeTabs: [ComposeTabState(id: tabID, selection: oldSelection)],
            activeComposeTabID: tabID
        )
        let storage = try InMemoryPersistenceStorage(initial: [url: JSONEncoder().encode(disk)])
        let coordinator = WorkspaceSessionPersistenceCoordinator(io: storage.io())
        let key = WorkspaceTabSelectionKey(workspaceID: workspaceID, tabID: tabID)

        let result = await coordinator.persist(
            WorkspaceSessionPersistenceRequest(
                url: url,
                workspace: local,
                dirtyGeneration: 4,
                selectionMetadata: WorkspacePersistenceSelectionMetadata(
                    key: key,
                    revision: 7,
                    selection: newestSelection
                )
            )
        )

        XCTAssertEqual(result, .written(dirtyGeneration: 4, selectionRevision: 7))
        let storedData = await storage.read(url)
        let writtenData = try XCTUnwrap(storedData)
        let written = try JSONDecoder().decode(WorkspaceModel.self, from: writtenData)
        XCTAssertEqual(written.name, "Newer disk name")
        XCTAssertEqual(written.repoPaths, ["/disk"])
        XCTAssertEqual(written.composeTabs.first?.selection, newestSelection)
    }

    func testNormalizationWriteRequiresExactFingerprintAndNoActiveWriter() async {
        let url = URL(fileURLWithPath: "/virtual/workspace.json")
        let bytes = Data("before".utf8)
        let storage = InMemoryPersistenceStorage(initial: [url: bytes])
        let coordinator = WorkspaceSessionPersistenceCoordinator(io: storage.io())
        let fingerprint = WorkspacePersistenceFileFingerprint(
            size: UInt64(bytes.count),
            modificationDate: storage.modificationDate
        )

        let stale = await coordinator.writeNormalizationIfUnchanged(
            data: Data("after".utf8),
            url: url,
            expectedFingerprint: WorkspacePersistenceFileFingerprint(
                size: 999,
                modificationDate: storage.modificationDate
            )
        )
        XCTAssertEqual(stale, .normalizationCompareAndSwapFailed)

        let written = await coordinator.writeNormalizationIfUnchanged(
            data: Data("after".utf8),
            url: url,
            expectedFingerprint: fingerprint
        )
        XCTAssertEqual(written, .written(dirtyGeneration: 0, selectionRevision: 0))
        let storedAfterNormalization = await storage.read(url)
        XCTAssertEqual(storedAfterNormalization, Data("after".utf8))
    }

    func testIndexPersistencePreservesOrderAndExcludesEphemeralWorkspaces() async throws {
        let url = URL(fileURLWithPath: "/virtual/workspacesIndex.json")
        let storage = InMemoryPersistenceStorage(initial: [:])
        let coordinator = WorkspaceSessionPersistenceCoordinator(io: storage.io())
        var ephemeral = WorkspaceModel(name: "Ephemeral", repoPaths: [])
        ephemeral.isEphemeral = true
        let first = WorkspaceModel(name: "First", repoPaths: [])
        let second = WorkspaceModel(name: "Second", repoPaths: [], isHiddenInMenus: true)

        let result = await coordinator.persistIndex(
            workspaces: [first, ephemeral, second],
            url: url
        )
        XCTAssertEqual(result, .written(dirtyGeneration: 0, selectionRevision: 0))
        let stored = await storage.read(url)
        let data = try XCTUnwrap(stored)
        let entries = try JSONDecoder().decode([WorkspaceIndexEntry].self, from: data)
        XCTAssertEqual(entries.map(\.id), [first.id, second.id])
        XCTAssertEqual(entries.map(\.name), ["First", "Second"])
        XCTAssertEqual(entries.map(\.isHiddenInMenus), [false, true])
    }
}

private actor InMemoryPersistenceStorage {
    private var values: [URL: Data]
    nonisolated let modificationDate = Date(timeIntervalSinceReferenceDate: 123)

    init(initial: [URL: Data]) {
        values = initial
    }

    func read(_ url: URL) -> Data? {
        values[url]
    }

    func write(_ data: Data, to url: URL) {
        values[url] = data
    }

    nonisolated func io() -> WorkspaceSessionPersistenceIO {
        WorkspaceSessionPersistenceIO(
            read: { [weak self] url in await self?.read(url) },
            atomicWrite: { [weak self] data, url in await self?.write(data, to: url) },
            fingerprint: { [weak self] url in
                guard let self, let data = await read(url) else { return nil }
                return WorkspacePersistenceFileFingerprint(
                    size: UInt64(data.count),
                    modificationDate: modificationDate
                )
            }
        )
    }
}
