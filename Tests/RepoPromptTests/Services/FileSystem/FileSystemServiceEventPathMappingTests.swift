@testable import RepoPrompt
import XCTest

final class FileSystemServiceEventPathMappingTests: XCTestCase {
    private var temporaryRoots = FileSystemTemporaryRoots()

    override func tearDownWithError() throws {
        temporaryRoots.removeAll()
        try super.tearDownWithError()
    }

    func testRoutineEventPathsMapOnlySafeRootRelativeValues() async throws {
        let parent = try temporaryRoots.makeRoot(suiteName: "FileSystemServiceEventPathMapping")
        let root = parent.appendingPathComponent("root", isDirectory: true)
        let outside = parent.appendingPathComponent("outside/file.txt")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src", isDirectory: true), withIntermediateDirectories: true)
        let service = try await makeService(root: root)
        let scenarios = [
            ("direct in-root path", root.appendingPathComponent("src/file.txt").path, true, "src/file.txt"),
            ("outside-root sibling", outside.path, false, outside.path),
            ("root-name prefix false positive", root.path + "-suffix/file.txt", false, root.path + "-suffix/file.txt"),
            ("empty input", "", false, ""),
            ("unsafe but standardizable in-root input", root.path + "//src/./file.txt", true, "src/file.txt")
        ]

        for scenario in scenarios {
            let result = await service.mapRelativeEventPathForTesting(scenario.1)

            XCTAssertEqual(result.isInside, scenario.2, scenario.0)
            XCTAssertEqual(result.value, scenario.3, scenario.0)
        }
    }

    func testSymlinkCanonicalFallbackMapsUnsafeCanonicalPathInsideRoot() async throws {
        let parent = try temporaryRoots.makeRoot(suiteName: "FileSystemServiceEventPathMapping")
        let realRoot = parent.appendingPathComponent("real-root", isDirectory: true)
        let symlinkRoot = parent.appendingPathComponent("link-root", isDirectory: true)
        try FileManager.default.createDirectory(
            at: realRoot.appendingPathComponent("src", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: symlinkRoot, withDestinationURL: realRoot)
        let service = try await makeService(root: symlinkRoot)

        let unsafeCanonicalPath = symlinkRoot
            .appendingPathComponent("../real-root/src/file.txt")
            .path
        let result = await service.mapRelativeEventPathForTesting(unsafeCanonicalPath)

        XCTAssertTrue(result.isInside)
        XCTAssertEqual(result.value, "src/file.txt")
    }

    private func makeService(root: URL) async throws -> FileSystemService {
        try await FileSystemService(
            path: root.path,
            respectRepoIgnore: false,
            respectCursorignore: false,
            skipSymlinks: true
        )
    }
}
