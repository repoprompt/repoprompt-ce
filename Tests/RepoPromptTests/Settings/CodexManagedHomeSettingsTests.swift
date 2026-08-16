import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class CodexManagedHomeSettingsTests: XCTestCase {
    func testSnapshotUsesRuntimeAuthorityChannelSpecificFullPath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexManagedHomeSettingsTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("Support", isDirectory: true)
        let ordinary = root.appendingPathComponent("ordinary", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ordinary, withIntermediateDirectories: true)

        let debug = CodexManagedHomeSettingsSnapshot.load(
            applicationSupportURL: support,
            buildChannel: .debug,
            ordinaryHome: ordinary
        )
        let release = CodexManagedHomeSettingsSnapshot.load(
            applicationSupportURL: support,
            buildChannel: .release,
            ordinaryHome: ordinary
        )

        XCTAssertEqual(
            debug.managedHome.path,
            support.appendingPathComponent("RepoPrompt CE/Codex/Debug/home").path
        )
        XCTAssertEqual(
            release.managedHome.path,
            support.appendingPathComponent("RepoPrompt CE/Codex/Release/home").path
        )
        XCTAssertEqual(debug.projection.status, .absent)
        XCTAssertEqual(release.projection.status, .absent)
    }

    func testCopyAndOpenActionsReceiveExactAuthoritativePathWithoutLaunchingFinder() throws {
        let paths = CodexRuntimeAuthority.statePaths(
            applicationSupportURL: URL(fileURLWithPath: "/tmp/settings-action-support"),
            buildChannel: .debug
        )
        var prepared: CodexRuntimeAuthority.StatePaths?
        var copied: String?
        var opened: URL?
        let actions = CodexManagedHomeSettingsActions(
            prepareState: { prepared = $0 },
            copyText: {
                copied = $0
                return true
            },
            openDirectory: {
                opened = $0
                return true
            }
        )

        XCTAssertTrue(actions.copyFullPath(paths))
        XCTAssertTrue(try actions.openInFinder(paths))

        XCTAssertEqual(copied, paths.codexHome.path)
        XCTAssertEqual(prepared, paths)
        XCTAssertEqual(opened, paths.codexHome)
    }

    func testOpenActionDoesNotInvokeFinderWhenSafePreparationFails() {
        struct PreparationFailure: Error {}
        let paths = CodexRuntimeAuthority.statePaths(
            applicationSupportURL: URL(fileURLWithPath: "/tmp/settings-action-failure"),
            buildChannel: .release
        )
        var opened: URL?
        let actions = CodexManagedHomeSettingsActions(
            prepareState: { _ in throw PreparationFailure() },
            copyText: { _ in true },
            openDirectory: {
                opened = $0
                return true
            }
        )

        XCTAssertThrowsError(try actions.openInFinder(paths))
        XCTAssertNil(opened)
    }

    func testPlatformActionFailuresAreReportedToCaller() throws {
        let paths = CodexRuntimeAuthority.statePaths(
            applicationSupportURL: URL(fileURLWithPath: "/tmp/settings-platform-failure"),
            buildChannel: .debug
        )
        let actions = CodexManagedHomeSettingsActions(
            prepareState: { _ in },
            copyText: { _ in false },
            openDirectory: { _ in false }
        )

        XCTAssertFalse(actions.copyFullPath(paths))
        XCTAssertFalse(try actions.openInFinder(paths))
    }
}
