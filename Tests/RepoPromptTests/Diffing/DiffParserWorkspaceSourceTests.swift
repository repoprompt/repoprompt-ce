import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

@MainActor
final class DiffParserWorkspaceSourceTests: XCTestCase {
    func testRenameReadsExactRootCurrentContentWithoutChangingSelection() async throws {
        try await WorkspaceAuthorityRootTestFixture.withFixture(readmeContent: "first\r\n") { fixture in
            let firstPath = fixture.rootPaths[0] + "/README.md"
            let secondPath = fixture.rootPaths[1] + "/README.md"
            try await fixture.selectFixtureFiles([firstPath])
            let selectedPaths = fixture.files.selectedFiles.map(\.fullPath)
            // Change the physical content after root discovery, before the parser reads it.
            try "second\r\n".write(toFile: secondPath, atomically: true, encoding: .utf8)
            let parser = DiffParser(fileManager: fixture.files)
            let parsed = try await parser.parse("""
            <file path="\(secondPath)" action="rename"><new path="Renamed.md" /></file>
            """)
            let removed = try XCTUnwrap(parsed.first { $0.action == .delete })
            let created = try XCTUnwrap(parsed.first { $0.action == .create })
            XCTAssertEqual(parsed.count, 2)
            XCTAssertEqual(removed.fileName, secondPath)
            XCTAssertEqual(removed.fileContent, "second\r\n")
            XCTAssertEqual(removed.lineEnding, "\r\n")
            XCTAssertEqual(removed.changes.map(\.type), [.remove])
            XCTAssertTrue(removed.changes.allSatisfy(\.isSelected))
            XCTAssertEqual(created.fileName, "Renamed.md")
            XCTAssertEqual(created.fileContent, removed.fileContent)
            XCTAssertEqual(created.changes.map(\.type), [.add])
            XCTAssertFalse(created.canBeLoaded)
            XCTAssertEqual(fixture.files.selectedFiles.map(\.fullPath), selectedPaths)
            XCTAssertEqual(try String(contentsOfFile: firstPath, encoding: .utf8), "first\r\n")
            XCTAssertEqual(try String(contentsOfFile: secondPath, encoding: .utf8), "second\r\n")
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.rootPaths[1] + "/Renamed.md"))
        }
    }
}
