import Foundation
@testable import RepoPrompt
@testable import RepoPromptCore
import XCTest

final class MCPRuntimeFileToolServicesTests: XCTestCase {
    func testRuntimeSafePathsRootsAndFilesUseOnlyFrozenQueryContext() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPRuntimeFileTools-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Sources/App.swift")
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("struct RuntimeOnly {}\n".utf8).write(to: source)

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path, kind: .primaryWorkspace)
        let runtimeID = WorkspaceRuntimeID()
        let sessionID = WorkspaceSessionID()
        let context = MCPRuntimeFileToolContext(
            adapterTicket: MCPRuntimeAdapterTicket(
                windowID: 7,
                runtimeID: runtimeID,
                sessionID: sessionID,
                adapterID: UUID(),
                mappingGeneration: 1,
                authoritativeSnapshotSequence: 1
            ),
            runtimeID: runtimeID,
            sessionID: sessionID,
            query: WorkspaceSessionStoreLifecycleFactory.makeQueryCapability(store: store),
            lookupContext: WorkspaceLookupContext(rootScope: .visibleWorkspace, bindingProjection: nil),
            filePathDisplay: .relative,
            codeMapsEnabled: true
        )

        let files = try await MCPRuntimeFileToolServices.resolveCodeStructureFiles(
            paths: [source.path],
            context: context
        )
        XCTAssertEqual(files.map(\.standardizedFullPath), [source.standardizedFileURL.path])

        let roots = try await MCPRuntimeFileToolServices.fileTree(
            type: "roots",
            mode: "full",
            maxDepth: nil,
            startPath: nil,
            context: context
        )
        XCTAssertEqual(roots.rootsCount, 1)
        XCTAssertTrue(roots.tree.contains(root.lastPathComponent))

        let tree = try await MCPRuntimeFileToolServices.fileTree(
            type: "files",
            mode: "full",
            maxDepth: nil,
            startPath: nil,
            context: context
        )
        XCTAssertTrue(tree.tree.contains("App.swift"))
    }
}
