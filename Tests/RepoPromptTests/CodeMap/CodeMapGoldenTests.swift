import Foundation
@testable import RepoPrompt
import XCTest

final class CodeMapGoldenTests: XCTestCase {
    func testFixturesMatchGoldenCodeMapDescriptions() throws {
        let groups: [(name: String, relativePaths: [String], maximumCount: Int)] = [
            ("CE/core", CodeMapFixtureRunner.fixtureRelativePaths, 5),
            ("expanded languages", CodeMapFixtureRunner.expandedLanguageFixtureRelativePaths, 5),
            ("edge fixtures", CodeMapFixtureRunner.edgeFixtureRelativePaths, 3)
        ]

        for group in groups {
            try XCTContext.runActivity(named: group.name) { _ in
                try assertFixturesMatchGoldens(
                    relativePaths: group.relativePaths,
                    maximumCount: group.maximumCount
                )
            }
        }
    }

    func testSnapshotFileTreeMarksCodeMapFixtures() throws {
        let tempRoot = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let expected = try CodeMapFixtureRunner.expectedFileTree()

        for mode in ["full", "auto"] {
            XCTContext.runActivity(named: mode) { _ in
                let actual = CodeMapFixtureRunner.renderFixtureFileTree(tempRoot: tempRoot, mode: mode)
                XCTAssertEqual(actual, expected)
            }
        }
    }

    func testSnapshotFileTreeNoneModeProducesNoOutputOrLegend() throws {
        let tempRoot = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let actual = CodeMapFixtureRunner.renderFixtureFileTree(tempRoot: tempRoot, mode: "none")
        XCTAssertEqual(actual, "")
        XCTAssertFalse(actual.contains("denotes"))
        XCTAssertFalse(actual.contains("Config:"))
    }

    func testSnapshotFileTreeSelectedModeStillRendersSelectionAndLegend() throws {
        let tempRoot = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let selectedID = try XCTUnwrap(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))

        let actual = CodeMapFixtureRunner.renderFixtureFileTree(
            tempRoot: tempRoot,
            mode: "selected",
            selectedFileIDs: [selectedID]
        )

        XCTAssertTrue(actual.contains("sample.swift * +"))
        XCTAssertTrue(actual.contains("(* denotes selected files)"))
        XCTAssertTrue(actual.contains("(+ denotes code-map available)"))
        XCTAssertFalse(actual.contains("worker.go"))
    }

    private func makeTempRoot() throws -> URL {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodeMapGoldenTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        return tempRoot
    }

    private func assertFixturesMatchGoldens(relativePaths: [String], maximumCount: Int) throws {
        let fixtures = try CodeMapFixtureRunner.loadFixtures(relativePaths: relativePaths)
        XCTAssertEqual(fixtures.map(\.relativePath), relativePaths)
        XCTAssertEqual(fixtures.count, relativePaths.count)
        XCTAssertLessThanOrEqual(fixtures.count, maximumCount)

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodeMapGoldenTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        for fixture in fixtures {
            try XCTContext.runActivity(named: fixture.relativePath) { _ in
                let rendered = try CodeMapFixtureRunner.renderArtifactCodeMap(for: fixture, tempRoot: tempRoot)
                let expected = try CodeMapFixtureRunner.expectedCodeMap(for: fixture)
                XCTAssertEqual(rendered, expected)
            }
        }
    }
}
