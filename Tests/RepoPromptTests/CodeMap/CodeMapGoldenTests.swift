import Foundation
@testable import RepoPromptApp
import XCTest

final class CodeMapGoldenTests: XCTestCase {
    func testSnapshotFileTreeMarksCodeMapFixtures() throws {
        let tempRoot = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let expected = CodeMapFixtureRunner.expectedFileTree()

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
}
