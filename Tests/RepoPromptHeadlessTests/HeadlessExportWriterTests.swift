import Foundation
@testable import RepoPromptHeadless
import XCTest

final class HeadlessExportWriterTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
    }

    func testInStateExportRemainsAnchoredWhenParentIsReplacedAfterOpen() throws {
        let directory = try makeTemporaryDirectory()
        let paths = HeadlessStatePaths(rootDirectory: directory.appendingPathComponent("State", isDirectory: true))
        try paths.ensureBaseDirectories()
        let exportParent = paths.exportsDirectory.appendingPathComponent("Nested", isDirectory: true)
        try HeadlessStateFileSecurity.ensurePrivateDirectory(at: exportParent, stateRoot: paths.rootDirectory)
        let movedParent = directory.appendingPathComponent("MovedNested", isDirectory: true)
        let replacementParent = directory.appendingPathComponent("Replacement", isDirectory: true)
        try FileManager.default.createDirectory(at: replacementParent, withIntermediateDirectories: true)
        let replacementTarget = replacementParent.appendingPathComponent("export.md")
        try Data("outside".utf8).write(to: replacementTarget)

        _ = try HeadlessExportWriter(paths: paths).write(
            Data("anchored".utf8),
            to: "Nested/export.md",
            defaultFileName: "unused.md",
            permissions: HeadlessPermissions(),
            inStateParentDirectoryOpenedHook: { _ in
                try FileManager.default.moveItem(at: exportParent, to: movedParent)
                try FileManager.default.createSymbolicLink(
                    atPath: exportParent.path,
                    withDestinationPath: replacementParent.path
                )
            }
        )

        XCTAssertEqual(
            try String(contentsOf: movedParent.appendingPathComponent("export.md"), encoding: .utf8),
            "anchored"
        )
        XCTAssertEqual(try String(contentsOf: replacementTarget, encoding: .utf8), "outside")
    }

    func testAuthorizedExternalExportRemainsAnchoredWhenParentIsReplacedAfterOpen() throws {
        let directory = try makeTemporaryDirectory()
        let paths = HeadlessStatePaths(rootDirectory: directory.appendingPathComponent("State", isDirectory: true))
        let exportParent = directory.appendingPathComponent("External", isDirectory: true)
        let movedParent = directory.appendingPathComponent("MovedExternal", isDirectory: true)
        let replacementParent = directory.appendingPathComponent("Replacement", isDirectory: true)
        try FileManager.default.createDirectory(at: exportParent, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: replacementParent, withIntermediateDirectories: true)
        let replacementTarget = replacementParent.appendingPathComponent("export.md")
        try Data("outside".utf8).write(to: replacementTarget)

        _ = try HeadlessExportWriter(paths: paths).write(
            Data("anchored".utf8),
            to: exportParent.appendingPathComponent("export.md").path,
            defaultFileName: "unused.md",
            permissions: HeadlessPermissions(exportOutsideStateDirectory: true),
            externalParentDirectoryOpenedHook: { _ in
                try FileManager.default.moveItem(at: exportParent, to: movedParent)
                try FileManager.default.createSymbolicLink(
                    atPath: exportParent.path,
                    withDestinationPath: replacementParent.path
                )
            }
        )

        XCTAssertEqual(
            try String(contentsOf: movedParent.appendingPathComponent("export.md"), encoding: .utf8),
            "anchored"
        )
        XCTAssertEqual(try String(contentsOf: replacementTarget, encoding: .utf8), "outside")
    }

    func testExportRejectsExistingSymlinkWithoutChangingDestination() throws {
        let directory = try makeTemporaryDirectory()
        let paths = HeadlessStatePaths(rootDirectory: directory.appendingPathComponent("State", isDirectory: true))
        try paths.ensureBaseDirectories()
        let outside = directory.appendingPathComponent("outside.md")
        try Data("outside".utf8).write(to: outside)
        let link = paths.exportsDirectory.appendingPathComponent("linked.md")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: outside.path)

        XCTAssertThrowsError(try HeadlessExportWriter(paths: paths).write(
            Data("replacement".utf8),
            to: "linked.md",
            defaultFileName: "unused.md",
            permissions: HeadlessPermissions()
        ))
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "outside")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = HeadlessTestTemporaryDirectory.baseURL
            .appendingPathComponent("RepoPromptHeadlessExportWriterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }
}
