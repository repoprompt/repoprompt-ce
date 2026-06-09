import Foundation
@testable import RepoPromptHeadless
import XCTest

final class HeadlessSelectionToolsTests: XCTestCase {
    func testRejectsPathWithSlicesMode() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        let error = await commandError(host: fixture.host, arguments: [
            "op": "add",
            "path": "Root/one.txt",
            "mode": "slices"
        ])

        XCTAssertEqual(error?.exitCode, 2)
        XCTAssertTrue(error?.message.contains("cannot create an empty slice selection") == true)
    }

    func testRejectsExplicitEmptySliceArrayAndEmptyRanges() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        let emptySlicesError = await commandError(host: fixture.host, arguments: [
            "op": "add",
            "slices": []
        ])
        XCTAssertEqual(emptySlicesError?.message, "Selection slices must not be empty.")

        let emptyRangesError = await commandError(host: fixture.host, arguments: [
            "op": "add",
            "slices": [[
                "path": "Root/one.txt",
                "ranges": []
            ]]
        ])
        XCTAssertEqual(emptyRangesError?.message, "Slice selection requires at least one range.")

        let invalidLineRangeError = await commandError(host: fixture.host, arguments: [
            "op": "add",
            "slices": [["path": "Root/one.txt", "lines": "1-"]]
        ])
        XCTAssertEqual(invalidLineRangeError?.message, "Invalid slice line range: 1-")
    }

    func testRangeRemovalSplitsSliceAndPreservesDescription() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        _ = try await HeadlessSelectionTools.manageSelection(host: fixture.host, arguments: [
            "op": "add",
            "slices": [[
                "path": "Root/one.txt",
                "ranges": [[
                    "start_line": 1,
                    "end_line": 10,
                    "description": "important"
                ]]
            ]]
        ])
        _ = try await HeadlessSelectionTools.manageSelection(host: fixture.host, arguments: [
            "op": "remove",
            "slices": [[
                "path": "Root/one.txt",
                "ranges": [["start_line": 4, "end_line": 6]]
            ]]
        ])

        let selection = try await fixture.host.snapshot(requireWorkspace: true).workspace?.selection
        XCTAssertEqual(selection, [HeadlessSelectionEntry(
            rootID: fixture.root.id,
            relativePath: "one.txt",
            mode: .slices,
            ranges: [
                HeadlessLineRange(startLine: 1, endLine: 3, description: "important"),
                HeadlessLineRange(startLine: 7, endLine: 10, description: "important")
            ]
        )])
    }

    func testRangeRemovalDoesNotWidenOrRemoveFullAndCodemapEntries() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        let initial = [
            HeadlessSelectionEntry(rootID: fixture.root.id, relativePath: "one.txt", mode: .full),
            HeadlessSelectionEntry(rootID: fixture.root.id, relativePath: "two.txt", mode: .codemapOnly)
        ]
        _ = try await fixture.host.replaceSelection(initial)
        _ = try await HeadlessSelectionTools.manageSelection(host: fixture.host, arguments: [
            "op": "remove",
            "slices": [
                ["path": "Root/one.txt", "lines": "1-3"],
                ["path": "Root/two.txt", "lines": "1-3"]
            ]
        ])

        let selection = try await fixture.host.snapshot(requireWorkspace: true).workspace?.selection
        XCTAssertEqual(selection, initial)
    }

    func testConcurrentHostsDoNotLoseIndependentSelectionAdds() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        _ = try await fixture.host.snapshot(requireWorkspace: true)
        let secondHost = HeadlessHost(configurationStore: HeadlessConfigurationStore(paths: fixture.paths))

        async let first: HeadlessJSONObject = HeadlessSelectionTools.manageSelection(host: fixture.host, arguments: [
            "op": "add",
            "path": "Root/one.txt"
        ])
        async let second: HeadlessJSONObject = HeadlessSelectionTools.manageSelection(host: secondHost, arguments: [
            "op": "add",
            "path": "Root/two.txt"
        ])
        _ = try await (first, second)

        let selection = try await fixture.host.snapshot(requireWorkspace: true).workspace?.selection
        XCTAssertEqual(selection?.map(\.relativePath).sorted(), ["one.txt", "two.txt"])
    }

    private func commandError(
        host: HeadlessHost,
        arguments: HeadlessJSONObject
    ) async -> HeadlessCommandError? {
        do {
            _ = try await HeadlessSelectionTools.manageSelection(host: host, arguments: arguments)
            XCTFail("Expected manage_selection to reject invalid slice input.")
            return nil
        } catch let error as HeadlessCommandError {
            return error
        } catch {
            XCTFail("Unexpected error: \(error)")
            return nil
        }
    }

    private func makeFixture() throws -> SelectionFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoPromptHeadlessSelectionTests-\(UUID().uuidString)", isDirectory: true)
        let rootDirectory = directory.appendingPathComponent("Root", isDirectory: true)
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        try Data("one\ntwo\nthree\n".utf8).write(to: rootDirectory.appendingPathComponent("one.txt"))
        try Data("alpha\nbeta\n".utf8).write(to: rootDirectory.appendingPathComponent("two.txt"))

        let paths = HeadlessStatePaths(rootDirectory: directory.appendingPathComponent("State", isDirectory: true))
        let configurationStore = HeadlessConfigurationStore(paths: paths)
        let root = try HeadlessRootAccessPolicy.makeAllowedRoot(path: rootDirectory.path, name: "Root")
        try configurationStore.update { configuration in
            configuration.allowedRoots = [root]
        }
        return SelectionFixture(
            directory: directory,
            paths: paths,
            root: root,
            host: HeadlessHost(configurationStore: configurationStore)
        )
    }
}

private struct SelectionFixture {
    let directory: URL
    let paths: HeadlessStatePaths
    let root: HeadlessAllowedRoot
    let host: HeadlessHost

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
