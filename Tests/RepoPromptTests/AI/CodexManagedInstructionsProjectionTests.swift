import Foundation
@testable import RepoPromptApp
import XCTest

final class CodexManagedInstructionsProjectionTests: XCTestCase {
    private var root: URL!
    private var ordinaryHome: URL!
    private var managedHome: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexManagedInstructionsProjectionTests-\(UUID().uuidString)")
        ordinaryHome = root.appendingPathComponent("ordinary")
        managedHome = root.appendingPathComponent("managed")
        try FileManager.default.createDirectory(at: ordinaryHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testOverrideWinsAndProjectionIsARegularFile() throws {
        try "fallback".write(
            to: ordinaryHome.appendingPathComponent("AGENTS.md"),
            atomically: true,
            encoding: .utf8
        )
        let source = ordinaryHome.appendingPathComponent("AGENTS.override.md")
        try "override".write(to: source, atomically: true, encoding: .utf8)

        let state = try CodexManagedInstructionsProjection.projectBeforeLaunch(
            managedHome: managedHome,
            ordinaryHome: ordinaryHome
        )

        XCTAssertEqual(
            state,
            .projected(source: source, target: managedHome.appendingPathComponent("AGENTS.override.md"))
        )
        XCTAssertEqual(
            try String(contentsOf: managedHome.appendingPathComponent("AGENTS.override.md")),
            "override"
        )
        let attributes = try FileManager.default.attributesOfItem(
            atPath: managedHome.appendingPathComponent("AGENTS.override.md").path
        )
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeRegular)
    }

    func testForeignManagedFileIsPreservedAndReported() throws {
        try FileManager.default.createDirectory(at: managedHome, withIntermediateDirectories: true)
        let target = managedHome.appendingPathComponent("AGENTS.md")
        try "foreign".write(to: target, atomically: true, encoding: .utf8)
        try "ordinary".write(
            to: ordinaryHome.appendingPathComponent("AGENTS.md"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertThrowsError(
            try CodexManagedInstructionsProjection.projectBeforeLaunch(
                managedHome: managedHome,
                ordinaryHome: ordinaryHome
            )
        )
        XCTAssertEqual(try String(contentsOf: target), "foreign")
    }

    func testModifiedProjectionIsPreservedAndFailsClosed() throws {
        let source = ordinaryHome.appendingPathComponent("AGENTS.md")
        try "first".write(to: source, atomically: true, encoding: .utf8)
        _ = try CodexManagedInstructionsProjection.projectBeforeLaunch(
            managedHome: managedHome,
            ordinaryHome: ordinaryHome
        )
        let target = managedHome.appendingPathComponent("AGENTS.md")
        try "user edit".write(to: target, atomically: true, encoding: .utf8)
        try "second".write(to: source, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(
            try CodexManagedInstructionsProjection.projectBeforeLaunch(
                managedHome: managedHome,
                ordinaryHome: ordinaryHome
            )
        )
        XCTAssertEqual(try String(contentsOf: target), "user edit")
    }

    func testOwnedProjectionIsRemovedWhenOrdinarySourceDisappears() throws {
        let source = ordinaryHome.appendingPathComponent("AGENTS.md")
        try "ordinary".write(to: source, atomically: true, encoding: .utf8)
        _ = try CodexManagedInstructionsProjection.projectBeforeLaunch(
            managedHome: managedHome,
            ordinaryHome: ordinaryHome
        )
        try FileManager.default.removeItem(at: source)

        XCTAssertEqual(
            try CodexManagedInstructionsProjection.projectBeforeLaunch(
                managedHome: managedHome,
                ordinaryHome: ordinaryHome
            ),
            .absent(managedHome: managedHome)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: managedHome.appendingPathComponent("AGENTS.md").path))
    }
}
