import Foundation
@testable import RepoPromptFileSystem
import XCTest

final class SubtreeRemovalTests: XCTestCase {
    func testRemovalPreservesOrderedDeltasAndInventory() async throws {
        let cases: [(name: String, top: String, items: [String: Bool])] = [
            ("top only", "folder", ["folder": true, "keep.txt": false]),
            ("nested folders", "a", ["a": true, "a/b": true, "a/b/file": false, "a/file": false, "keep": true]),
            ("absent subtree", "missing", ["a": true, "a/file": false]),
            ("slash neighbour", "a/b", ["a": true, "a/b": true, "a/b/file": false, "a/bc": true, "a/bc/file": false]),
            ("Unicode", "café/📁", ["café": true, "café/📁": true, "café/📁/文.txt": false, "café/📁extra": false]),
            ("equal length ties", "a", ["a": true, "a/b": true, "a/c": false, "a/b/x": false, "a/d": true]),
            ("empty top", "", ["": true, "/child": false, "a": true, "a/file": false])
        ]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = IgnoreRulesManager(
            globalIgnoreProvider: { "" },
            ignorePolicyResolver: { _ in .nonGitRoot },
            repositoryRootValidator: { _ in false }
        )

        for scenario in cases {
            let service = try await FileSystemService(
                path: root.path,
                testVisitedPaths: Set(scenario.items.keys),
                testVisitedItems: scenario.items,
                testIgnoreRules: IgnoreRules(policy: .nonGitRoot),
                isTestMode: true,
                ignoreRulesManager: manager
            )
            let expected = await service.referenceSubtreeRemoval(for: scenario.top)
            let actual = await service.removeSubtree(for: scenario.top)
            let remaining = await service.getTestState()

            XCTAssertEqual(actual, expected.deltas, scenario.name)
            XCTAssertEqual(remaining.visitedPaths, expected.paths, scenario.name)
            XCTAssertEqual(remaining.visitedItems, expected.items, scenario.name)
        }
    }
}

private extension FileSystemService {
    /// Snapshot the actor's iteration order so equal-length ties compare against the old implementation,
    /// not a separately constructed Set whose iteration order may differ.
    func referenceSubtreeRemoval(for topRelPath: String) -> (
        deltas: [FileSystemDelta], paths: Set<String>, items: [String: Bool]
    ) {
        let inventoryOrder = Array(visitedPaths)
        var paths = Set(inventoryOrder)
        var items = getTestState().visitedItems
        let oldSet = inventoryOrder.filter {
            $0 == topRelPath || $0.hasPrefix(topRelPath + "/")
        }
        let sortedPaths = oldSet.sorted { $0.count > $1.count }
        var deltas: [FileSystemDelta] = []

        for path in sortedPaths {
            let wasDir = items[path] ?? false
            paths.remove(path)
            items.removeValue(forKey: path)
            if wasDir {
                deltas.append(.folderRemoved(path))
            } else {
                deltas.append(.fileRemoved(path))
            }
        }
        return (deltas, paths, items)
    }
}
