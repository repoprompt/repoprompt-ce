import Foundation
@testable import RepoPromptCore
import XCTest

final class AgentSupportDirectoryContainmentSecurityTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
    }

    func testExistingSymlinksAreComparedCanonically() throws {
        let home = try makeTemporaryDirectory()
        let skillsRoot = home.appendingPathComponent(".agents/skills", isDirectory: true)
        try FileManager.default.createDirectory(at: skillsRoot, withIntermediateDirectories: true)
        let directory = AlwaysReadableDirectory(url: skillsRoot, source: .globalAgentsSkills)

        let inRootFile = skillsRoot.appendingPathComponent("real.md")
        try Data("inside".utf8).write(to: inRootFile)
        let internalLink = skillsRoot.appendingPathComponent("internal.md")
        try FileManager.default.createSymbolicLink(atPath: internalLink.path, withDestinationPath: inRootFile.path)

        let outsideFile = home.appendingPathComponent("outside.md")
        try Data("outside".utf8).write(to: outsideFile)
        let escapeLink = skillsRoot.appendingPathComponent("escape.md")
        try FileManager.default.createSymbolicLink(atPath: escapeLink.path, withDestinationPath: outsideFile.path)

        XCTAssertTrue(AgentSupportDirectoryCatalog.contains(absolutePath: internalLink.path, in: directory))
        XCTAssertFalse(AgentSupportDirectoryCatalog.contains(absolutePath: escapeLink.path, in: directory))
    }

    func testSymlinkedAllowedRootRemainsSupported() throws {
        let home = try makeTemporaryDirectory()
        let actualRoot = home.appendingPathComponent("actual-skills", isDirectory: true)
        try FileManager.default.createDirectory(at: actualRoot, withIntermediateDirectories: true)
        let file = actualRoot.appendingPathComponent("SKILL.md")
        try Data("skill".utf8).write(to: file)

        let linkedRoot = home.appendingPathComponent(".agents/skills", isDirectory: true)
        try FileManager.default.createDirectory(at: linkedRoot.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: linkedRoot.path, withDestinationPath: actualRoot.path)
        let linkedFile = linkedRoot.appendingPathComponent("SKILL.md")
        let directory = AlwaysReadableDirectory(url: linkedRoot, source: .globalAgentsSkills)

        XCTAssertTrue(AgentSupportDirectoryCatalog.contains(absolutePath: linkedFile.path, in: directory))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoPromptAgentSupportContainment-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }
}
