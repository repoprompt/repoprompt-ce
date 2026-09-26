import Foundation
@testable import RepoPromptApp
import XCTest

final class WorkspaceFileContextCatalogReconciliationBatchTests: XCTestCase {
    func testReconciliationScansBeyondServiceBatchLimit() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CatalogReconciliationBatch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        for index in 0 ..< 260 {
            let folder = rootURL.appendingPathComponent(String(format: "folder-%03d", index), isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            try "initial\n".write(
                to: folder.appendingPathComponent("marker.txt"),
                atomically: true,
                encoding: .utf8
            )
        }

        let store = WorkspaceFileContextStore(codemapGraphIndexBuildLaunchPolicyForTesting: .disabled)
        let root = try await store.loadRoot(path: rootURL.path)
        addTeardownBlock {
            await store.unloadRoot(id: root.id)
            try? FileManager.default.removeItem(at: rootURL)
        }
        let tailPath = "folder-259/new.swift"
        try "struct NewlyFound {}\n".write(
            to: rootURL.appendingPathComponent(tailPath),
            atomically: true,
            encoding: .utf8
        )

        let deltas = await store.reconcileLoadedRootCatalogWithDisk(rootID: root.id)
        XCTAssertTrue(deltas.contains(.fileAdded(tailPath)))
        let cataloged = await store.file(rootID: root.id, relativePath: tailPath)
        XCTAssertNotNil(cataloged)
    }
}
