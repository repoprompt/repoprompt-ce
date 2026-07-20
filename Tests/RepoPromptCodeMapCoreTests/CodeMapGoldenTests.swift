import XCTest
@testable import RepoPromptCodeMapCore

final class CodeMapGoldenTests: XCTestCase {
    func testFixturesMatchGoldenCodeMapDescriptions() throws {
        let groups: [(name: String, relativePaths: [String], maximumCount: Int)] = [
            ("CE/core", CodeMapFixtureRunner.fixtureRelativePaths, 5),
            ("expanded languages", CodeMapFixtureRunner.expandedLanguageFixtureRelativePaths, 6),
            ("edge fixtures", CodeMapFixtureRunner.edgeFixtureRelativePaths, 3)
        ]

        for group in groups {
            let fixtures = try CodeMapFixtureRunner.loadFixtures(relativePaths: group.relativePaths)
            XCTAssertEqual(fixtures.map(\.relativePath), group.relativePaths, group.name)
            XCTAssertEqual(fixtures.count, group.relativePaths.count, group.name)
            XCTAssertLessThanOrEqual(fixtures.count, group.maximumCount, group.name)

            let tempRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("CodeMapGoldenTests", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempRoot) }

            for fixture in fixtures {
                let rendered = try CodeMapFixtureRunner.renderArtifactCodeMap(
                    for: fixture,
                    tempRoot: tempRoot
                )
                let expected = try CodeMapFixtureRunner.expectedCodeMap(for: fixture)
                XCTAssertEqual(rendered, expected, fixture.relativePath)
            }
        }
    }
}
